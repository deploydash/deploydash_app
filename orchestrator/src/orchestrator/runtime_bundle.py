from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

_RUNTIME_TEST_DIRECTORY_NAMES = frozenset({"test", "testing", "tests"})
#: Cold self-hosted Windows E2E VMs (Defender, disk, spawn) routinely need
#: more than a few seconds for the first echo task; 10s was flaking the
#: private QA slim gate after reboot while hosted windows-latest stayed green.
_RUNTIME_SMOKE_TIMEOUT_SECONDS = 60.0

_RUNTIME_SMOKE_SCRIPT = """
import json
import multiprocessing
import sys
import time

original_stderr = sys.stderr
try:
    sys.stdin = None
    sys.stdout = None
    sys.stderr = None
    sys.__stdin__ = None
    sys.__stdout__ = None
    sys.__stderr__ = None

    from orchestrator import task_runtime

    task_runtime._TASK_PROCESS_CONTEXT = multiprocessing.get_context("spawn")
    started = json.loads(
        task_runtime.start_task(
            json.dumps(
                {
                    "action": "run_workflow",
                    "workflow_id": "core",
                    "operation_id": "echo",
                    "data": "runtime-bundle-smoke",
                }
            )
        )
    )
    task_id = started["task_id"]
    deadline = time.monotonic() + __SMOKE_TIMEOUT__
    while time.monotonic() < deadline:
        poll = json.loads(task_runtime.poll_task_events(task_id, 100))
        if poll.get("done"):
            break
        time.sleep(0.05)
    else:
        raise RuntimeError("Bundled task runtime smoke task timed out.")

    completed = json.loads(task_runtime.get_task_result(task_id))
    result = completed.get("result") or {}
    if (
        completed.get("status") != "success"
        or result.get("status") != "success"
        or result.get("data") != "runtime-bundle-smoke"
    ):
        raise RuntimeError(f"Bundled task runtime smoke task failed: {completed}")
except BaseException:
    sys.stderr = original_stderr
    raise
""".replace("__SMOKE_TIMEOUT__", repr(_RUNTIME_SMOKE_TIMEOUT_SECONDS))


def _resolve_seed_python(backend_root: Path) -> Path:
    candidates = [
        os.environ.get("ORCHESTRATOR_VENV_PYTHON"),
        os.environ.get("DEPLOYDASH_ENGINE_VENV_PYTHON"),
        str(backend_root / ".venv" / "bin" / "python"),
        str(backend_root / ".venv" / "Scripts" / "python.exe"),
    ]
    for candidate in candidates:
        if candidate:
            path = Path(candidate)
            if path.exists():
                return path
    raise SystemExit(
        "Unable to locate a Python 3.13 interpreter for the backend runtime "
        "bundle. Set ORCHESTRATOR_VENV_PYTHON or run `cd orchestrator && uv sync` first."
    )


def _runtime_bundle_venv_dir(backend_root: Path) -> Path:
    return backend_root / ".runtime_bundle_venv"


def _runtime_bundle_python(backend_root: Path) -> Path:
    venv_dir = _runtime_bundle_venv_dir(backend_root)
    if os.name == "nt":
        return venv_dir / "Scripts" / "python.exe"
    return venv_dir / "bin" / "python"


def _run(
    command: list[str],
    *,
    cwd: Path,
    env_overrides: dict[str, str] | None = None,
) -> None:
    if env_overrides:
        env = os.environ.copy()
        env.update(env_overrides)
        subprocess.run(command, cwd=cwd, check=True, env=env)
        return
    subprocess.run(command, cwd=cwd, check=True)


def _prepare_runtime_bundle_environment(backend_root: Path) -> Path:
    seed_python = _resolve_seed_python(backend_root)
    runtime_python = _runtime_bundle_python(backend_root)

    _run(
        [
            "uv",
            "venv",
            "--clear",
            "--python",
            str(seed_python),
            str(_runtime_bundle_venv_dir(backend_root)),
        ],
        cwd=backend_root,
    )
    _run(
        ["uv", "sync", "--active", "--no-install-project", "--no-editable"],
        cwd=backend_root,
        env_overrides={"VIRTUAL_ENV": str(_runtime_bundle_venv_dir(backend_root))},
    )
    if not runtime_python.exists():
        raise SystemExit("Unable to locate the runtime bundle virtualenv Python interpreter.")
    return runtime_python


def _install_from_local_wheel(
    backend_root: Path,
    venv_python: Path,
) -> None:
    dist_dir = backend_root / "dist"
    for existing in dist_dir.glob("orchestrator-*.whl"):
        existing.unlink()

    _run(["uv", "build", "--wheel"], cwd=backend_root)
    wheels = sorted(dist_dir.glob("orchestrator-*.whl"), reverse=True)
    if not wheels:
        raise SystemExit(f"No orchestrator wheel found in {dist_dir}")

    _run(
        [
            "uv",
            "pip",
            "install",
            "--python",
            str(venv_python),
            "--reinstall",
            "--upgrade",
            "--no-deps",
            str(wheels[0]),
        ],
        cwd=backend_root,
    )


def _env_first(*names: str, default: str = "") -> str:
    """Return the first SET env var in `names`, else `default` (B-37 owner).

    Membership-based (first present wins even when empty), matching the
    nested environ.get(X, environ.get(Y, default)) shape it replaces --
    NOT truthiness-based like the or-chain at _resolve_pinned_version_file.
    """
    for name in names:
        if name in os.environ:
            return os.environ[name]
    return default


def _install_from_published_version(
    backend_root: Path,
    repo_root: Path,
    venv_python: Path,
) -> bool:
    pinned_version_file = _resolve_pinned_version_file(backend_root, repo_root)

    pinned_version = pinned_version_file.read_text(encoding="utf-8").strip()
    if not pinned_version:
        raise SystemExit(f"Pinned version file is empty: {pinned_version_file}")

    command = [
        "uv",
        "pip",
        "install",
        "--python",
        str(venv_python),
        "--reinstall",
        "--upgrade",
        "--no-deps",
    ]
    pip_index_url = _env_first(
        "ORCHESTRATOR_PYPI_INDEX_URL",
        "DEPLOYDASH_ENGINE_PYPI_INDEX_URL",
        default="",
    ).strip()
    if pip_index_url:
        command.extend(["--index-url", pip_index_url])

    pip_extra_index_url = _env_first(
        "ORCHESTRATOR_PYPI_EXTRA_INDEX_URL",
        "DEPLOYDASH_ENGINE_PYPI_EXTRA_INDEX_URL",
        default="",
    ).strip()
    if pip_extra_index_url:
        command.extend(["--extra-index-url", pip_extra_index_url])

    command.append(f"orchestrator=={pinned_version}")
    result = subprocess.run(command, cwd=backend_root)
    return result.returncode == 0


def _resolve_pinned_version_file(backend_root: Path, repo_root: Path) -> Path:
    env_version_file = (
        os.environ.get("DEPLOYDASH_ORCHESTRATOR_VERSION_FILE")
        or os.environ.get("DEPLOYDASH_BACKEND_VERSION_FILE")
        or os.environ.get("ORCHESTRATOR_VERSION_FILE")
        or ""
    ).strip()
    if env_version_file:
        candidate = Path(env_version_file)
        if not candidate.is_absolute():
            candidate = repo_root / candidate
        if not candidate.exists():
            raise SystemExit(f"Pinned version file not found: {candidate}")
        return candidate

    for candidate in (
        backend_root / "orchestrator.version",
        repo_root / "ui" / "orchestrator.version",
        repo_root / "orchestrator.version",
    ):
        if candidate.exists():
            return candidate

    raise SystemExit(
        "Pinned version file not found. Looked for: "
        f"{backend_root / 'orchestrator.version'}, "
        f"{repo_root / 'ui' / 'orchestrator.version'}, "
        f"{repo_root / 'orchestrator.version'}"
    )


def _site_packages_dir(venv_python: Path) -> Path:
    script = (
        "import site\n"
        "for path in site.getsitepackages():\n"
        "    if path.endswith('site-packages'):\n"
        "        print(path)\n"
        "        break\n"
    )
    result = subprocess.run(
        [str(venv_python), "-c", script],
        check=True,
        capture_output=True,
        text=True,
    )
    path = result.stdout.strip()
    if not path:
        raise SystemExit("Unable to locate the virtualenv site-packages directory.")
    return Path(path)


def _copy_runtime_bundle(site_packages_dir: Path, runtime_bundle_dir: Path) -> None:
    shim = site_packages_dir / "_orchestrator.pth"
    if shim.exists():
        shim.unlink()

    if not (site_packages_dir / "orchestrator" / "__init__.py").exists():
        raise SystemExit("orchestrator package is not fully installed in site-packages.")

    if runtime_bundle_dir.exists():
        shutil.rmtree(runtime_bundle_dir)
    runtime_bundle_dir.mkdir(parents=True, exist_ok=True)
    shutil.copytree(
        site_packages_dir,
        runtime_bundle_dir / "site-packages",
        dirs_exist_ok=True,
    )

    for cache_dir in runtime_bundle_dir.rglob("__pycache__"):
        shutil.rmtree(cache_dir)

    bundled_site_packages = runtime_bundle_dir / "site-packages"
    test_directories = sorted(
        (
            path
            for path in bundled_site_packages.rglob("*")
            if path.is_dir() and path.name.casefold() in _RUNTIME_TEST_DIRECTORY_NAMES
        ),
        key=lambda path: len(path.parts),
        reverse=True,
    )
    for test_directory in test_directories:
        shutil.rmtree(test_directory)

    for dist_info_dir in bundled_site_packages.glob("orchestrator-*.dist-info"):
        for metadata_name in ("RECORD", "uv_cache.json"):
            metadata_path = dist_info_dir / metadata_name
            if metadata_path.exists():
                metadata_path.unlink()


def _verify_runtime_bundle(
    venv_python: Path,
    runtime_bundle_dir: Path,
) -> None:
    bundled_site_packages = runtime_bundle_dir / "site-packages"
    _run(
        [str(venv_python), "-c", _RUNTIME_SMOKE_SCRIPT],
        cwd=runtime_bundle_dir,
        env_overrides={"PYTHONPATH": str(bundled_site_packages)},
    )


def prepare_runtime_bundle(
    *,
    backend_root: Path,
    repo_root: Path,
    runtime_bundle_dir: Path,
    package_source: str,
    allow_local_fallback: str,
) -> Path:
    venv_python = _prepare_runtime_bundle_environment(backend_root)

    if package_source == "published":
        if not _install_from_published_version(backend_root, repo_root, venv_python):
            if allow_local_fallback != "1":
                raise SystemExit("Published package install failed and local fallback is disabled.")
            print(
                "Published package install failed; falling back to local wheel build.",
                file=sys.stderr,
            )
            _install_from_local_wheel(backend_root, venv_python)
    elif package_source == "local-wheel":
        _install_from_local_wheel(backend_root, venv_python)
    else:
        raise SystemExit(
            f"Unsupported ORCHESTRATOR_PACKAGE_SOURCE: {package_source}. "
            "Allowed values: published, local-wheel"
        )

    site_packages_dir = _site_packages_dir(venv_python)
    _copy_runtime_bundle(site_packages_dir, runtime_bundle_dir)
    _verify_runtime_bundle(venv_python, runtime_bundle_dir)
    return runtime_bundle_dir


def main() -> None:
    backend_root = Path(__file__).resolve().parent.parent.parent
    repo_root = backend_root.parent
    runtime_bundle_dir = backend_root / "runtime_bundle" / "py"

    package_source = _env_first(
        "ORCHESTRATOR_PACKAGE_SOURCE",
        "DEPLOYDASH_ENGINE_PACKAGE_SOURCE",
        default="local-wheel",
    ).strip()
    allow_local_fallback = _env_first(
        "ORCHESTRATOR_ALLOW_LOCAL_FALLBACK",
        "DEPLOYDASH_ENGINE_ALLOW_LOCAL_FALLBACK",
        default="0",
    ).strip()

    runtime_bundle_path = prepare_runtime_bundle(
        backend_root=backend_root,
        repo_root=repo_root,
        runtime_bundle_dir=runtime_bundle_dir,
        package_source=package_source,
        allow_local_fallback=allow_local_fallback,
    )
    print(f"Prepared desktop runtime bundle at {runtime_bundle_path}")


if __name__ == "__main__":  # pragma: no cover
    main()
