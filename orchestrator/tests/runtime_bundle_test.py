from __future__ import annotations

import io
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from orchestrator import runtime_bundle


class TestRuntimeBundle(unittest.TestCase):
    def test_run_invokes_subprocess_with_check(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            cwd = Path(temp_dir)
            with patch.object(runtime_bundle.subprocess, "run") as run_mock:
                runtime_bundle._run(["uv", "sync"], cwd=cwd)
            run_mock.assert_called_once_with(["uv", "sync"], cwd=cwd, check=True)

    def test_run_merges_environment_overrides(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            cwd = Path(temp_dir)
            with (
                patch.dict(runtime_bundle.os.environ, {"BASE": "value"}, clear=True),
                patch.object(runtime_bundle.subprocess, "run") as run_mock,
            ):
                runtime_bundle._run(
                    ["uv", "sync"],
                    cwd=cwd,
                    env_overrides={"VIRTUAL_ENV": "/tmp/venv"},
                )

            run_mock.assert_called_once()
            args, kwargs = run_mock.call_args
            self.assertEqual(args[0], ["uv", "sync"])
            self.assertEqual(kwargs["cwd"], cwd)
            self.assertTrue(kwargs["check"])
            self.assertEqual(kwargs["env"]["BASE"], "value")
            self.assertEqual(kwargs["env"]["VIRTUAL_ENV"], "/tmp/venv")

    def test_resolve_seed_python_prefers_env_override(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir)
            env_python = backend_root / "custom-python"
            env_python.write_text("", encoding="utf-8")
            with patch.dict(
                runtime_bundle.os.environ,
                {"ORCHESTRATOR_VENV_PYTHON": str(env_python)},
                clear=False,
            ):
                self.assertEqual(
                    runtime_bundle._resolve_seed_python(backend_root),
                    env_python,
                )

    def test_resolve_seed_python_falls_back_to_default_locations(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir)
            default_python = backend_root / ".venv" / "bin" / "python"
            default_python.parent.mkdir(parents=True)
            default_python.write_text("", encoding="utf-8")
            with patch.dict(runtime_bundle.os.environ, {}, clear=True):
                self.assertEqual(
                    runtime_bundle._resolve_seed_python(backend_root),
                    default_python,
                )

    def test_resolve_seed_python_requires_existing_candidate(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir)
            with (
                patch.dict(runtime_bundle.os.environ, {}, clear=True),
                self.assertRaisesRegex(
                    SystemExit,
                    "Unable to locate a Python 3.13 interpreter",
                ),
            ):
                runtime_bundle._resolve_seed_python(backend_root)

    def test_runtime_bundle_python_uses_platform_path(self):
        backend_root = Path("/tmp/backend")
        with patch.object(runtime_bundle, "os") as os_mock:
            os_mock.name = "nt"
            self.assertEqual(
                runtime_bundle._runtime_bundle_python(backend_root),
                backend_root / ".runtime_bundle_venv" / "Scripts" / "python.exe",
            )
        with patch.object(runtime_bundle, "os") as os_mock:
            os_mock.name = "posix"
            self.assertEqual(
                runtime_bundle._runtime_bundle_python(backend_root),
                backend_root / ".runtime_bundle_venv" / "bin" / "python",
            )

    def test_prepare_runtime_bundle_environment_creates_and_syncs_runtime_venv(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir)
            runtime_python = backend_root / ".runtime_bundle_venv" / "bin" / "python"
            runtime_python.parent.mkdir(parents=True)
            runtime_python.write_text("", encoding="utf-8")

            with (
                patch.object(
                    runtime_bundle,
                    "_resolve_seed_python",
                    return_value=Path("/seed/python"),
                ),
                patch.object(runtime_bundle, "_run") as run_mock,
            ):
                result = runtime_bundle._prepare_runtime_bundle_environment(backend_root)

            self.assertEqual(result, runtime_python)
            self.assertEqual(run_mock.call_count, 2)
            self.assertEqual(
                run_mock.call_args_list[0].args[0],
                [
                    "uv",
                    "venv",
                    "--clear",
                    "--python",
                    "/seed/python",
                    str(backend_root / ".runtime_bundle_venv"),
                ],
            )
            self.assertEqual(run_mock.call_args_list[0].kwargs, {"cwd": backend_root})
            self.assertEqual(
                run_mock.call_args_list[1].args[0],
                ["uv", "sync", "--active", "--no-install-project", "--no-editable"],
            )
            self.assertEqual(
                run_mock.call_args_list[1].kwargs,
                {
                    "cwd": backend_root,
                    "env_overrides": {
                        "VIRTUAL_ENV": str(backend_root / ".runtime_bundle_venv"),
                    },
                },
            )

    def test_prepare_runtime_bundle_environment_requires_runtime_python(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir)
            with (
                patch.object(
                    runtime_bundle,
                    "_resolve_seed_python",
                    return_value=Path("/seed/python"),
                ),
                patch.object(runtime_bundle, "_run"),
                self.assertRaisesRegex(
                    SystemExit,
                    "Unable to locate the runtime bundle virtualenv Python interpreter",
                ),
            ):
                runtime_bundle._prepare_runtime_bundle_environment(backend_root)

    def test_install_from_local_wheel_rebuilds_and_installs_latest_wheel(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir)
            dist_dir = backend_root / "dist"
            dist_dir.mkdir()
            old_wheel = dist_dir / "orchestrator-0.0.1.whl"
            old_wheel.write_text("old", encoding="utf-8")

            calls: list[list[str]] = []

            def fake_run(command: list[str], *, cwd: Path) -> None:
                calls.append(command)
                if command[:3] == ["uv", "build", "--wheel"]:
                    (dist_dir / "orchestrator-0.0.2.whl").write_text(
                        "new",
                        encoding="utf-8",
                    )

            with patch.object(runtime_bundle, "_run", side_effect=fake_run):
                runtime_bundle._install_from_local_wheel(
                    backend_root,
                    Path("/venv/python"),
                )

            self.assertFalse(old_wheel.exists())
            self.assertEqual(calls[0], ["uv", "build", "--wheel"])
            self.assertEqual(
                calls[1],
                [
                    "uv",
                    "pip",
                    "install",
                    "--python",
                    "/venv/python",
                    "--reinstall",
                    "--upgrade",
                    "--no-deps",
                    str(dist_dir / "orchestrator-0.0.2.whl"),
                ],
            )

    def test_install_from_local_wheel_requires_built_wheel(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir)
            (backend_root / "dist").mkdir()
            with (
                patch.object(runtime_bundle, "_run"),
                self.assertRaisesRegex(SystemExit, "No orchestrator wheel found"),
            ):
                runtime_bundle._install_from_local_wheel(
                    backend_root,
                    Path("/venv/python"),
                )

    def test_install_from_published_version_requires_non_empty_pin(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir) / "orchestrator"
            repo_root = Path(temp_dir)
            backend_root.mkdir()
            version_file = repo_root / "ui" / "orchestrator.version"
            version_file.parent.mkdir()
            version_file.write_text("", encoding="utf-8")

            with self.assertRaisesRegex(SystemExit, "Pinned version file is empty"):
                runtime_bundle._install_from_published_version(
                    backend_root,
                    repo_root,
                    Path("/venv/python"),
                )

    def test_install_from_published_version_requires_pin_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir) / "orchestrator"
            repo_root = Path(temp_dir)
            backend_root.mkdir()

            with self.assertRaisesRegex(SystemExit, "Pinned version file not found"):
                runtime_bundle._install_from_published_version(
                    backend_root,
                    repo_root,
                    Path("/venv/python"),
                )

    def test_install_from_published_version_requires_relative_env_pin_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir) / "orchestrator"
            repo_root = Path(temp_dir)
            backend_root.mkdir()

            with (
                patch.dict(
                    runtime_bundle.os.environ,
                    {"DEPLOYDASH_BACKEND_VERSION_FILE": "missing/orchestrator.version"},
                    clear=False,
                ),
                self.assertRaisesRegex(
                    SystemExit,
                    "Pinned version file not found",
                ),
            ):
                runtime_bundle._install_from_published_version(
                    backend_root,
                    repo_root,
                    Path("/venv/python"),
                )

    def test_install_from_published_version_prefers_env_override(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir) / "orchestrator"
            repo_root = Path(temp_dir)
            backend_root.mkdir()
            version_file = repo_root / "custom" / "orchestrator.version"
            version_file.parent.mkdir()
            version_file.write_text("1.2.3\n", encoding="utf-8")

            recorded_commands: list[list[str]] = []

            def fake_run(command: list[str], cwd: Path):
                recorded_commands.append(command)
                return SimpleNamespace(returncode=0)

            with (
                patch.dict(
                    runtime_bundle.os.environ,
                    {"DEPLOYDASH_BACKEND_VERSION_FILE": str(version_file)},
                    clear=False,
                ),
                patch.object(runtime_bundle.subprocess, "run", side_effect=fake_run),
            ):
                result = runtime_bundle._install_from_published_version(
                    backend_root,
                    repo_root,
                    Path("/venv/python"),
                )

            self.assertTrue(result)
            self.assertEqual(
                recorded_commands[0],
                [
                    "uv",
                    "pip",
                    "install",
                    "--python",
                    "/venv/python",
                    "--reinstall",
                    "--upgrade",
                    "--no-deps",
                    "orchestrator==1.2.3",
                ],
            )

    def test_install_from_published_version_resolves_relative_env_override(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir) / "orchestrator"
            repo_root = Path(temp_dir)
            backend_root.mkdir()
            version_file = repo_root / "pins" / "orchestrator.version"
            version_file.parent.mkdir()
            version_file.write_text("4.5.6\n", encoding="utf-8")

            recorded_commands: list[list[str]] = []

            def fake_run(command: list[str], cwd: Path):
                recorded_commands.append(command)
                return SimpleNamespace(returncode=0)

            with (
                patch.dict(
                    runtime_bundle.os.environ,
                    {"DEPLOYDASH_BACKEND_VERSION_FILE": "pins/orchestrator.version"},
                    clear=False,
                ),
                patch.object(
                    runtime_bundle.subprocess,
                    "run",
                    side_effect=fake_run,
                ),
            ):
                result = runtime_bundle._install_from_published_version(
                    backend_root,
                    repo_root,
                    Path("/venv/python"),
                )

            self.assertTrue(result)
            self.assertIn("orchestrator==4.5.6", recorded_commands[0])

    def test_install_from_published_version_falls_back_to_repo_root_version_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir) / "orchestrator"
            repo_root = Path(temp_dir)
            backend_root.mkdir()
            version_file = repo_root / "orchestrator.version"
            version_file.write_text("2.3.4\n", encoding="utf-8")

            recorded_commands: list[list[str]] = []

            def fake_run(command: list[str], cwd: Path):
                recorded_commands.append(command)
                return SimpleNamespace(returncode=0)

            with (
                patch.dict(runtime_bundle.os.environ, {}, clear=True),
                patch.object(runtime_bundle.subprocess, "run", side_effect=fake_run),
            ):
                result = runtime_bundle._install_from_published_version(
                    backend_root,
                    repo_root,
                    Path("/venv/python"),
                )

            self.assertTrue(result)
            self.assertEqual(
                recorded_commands[0],
                [
                    "uv",
                    "pip",
                    "install",
                    "--python",
                    "/venv/python",
                    "--reinstall",
                    "--upgrade",
                    "--no-deps",
                    "orchestrator==2.3.4",
                ],
            )

    def test_install_from_published_version_uses_index_configuration(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir) / "orchestrator"
            repo_root = Path(temp_dir)
            backend_root.mkdir()
            version_file = repo_root / "ui" / "orchestrator.version"
            version_file.parent.mkdir()
            version_file.write_text("0.0.7\n", encoding="utf-8")

            recorded_commands: list[list[str]] = []

            def fake_run(command: list[str], cwd: Path):
                recorded_commands.append(command)
                return SimpleNamespace(returncode=0)

            with (
                patch.dict(
                    runtime_bundle.os.environ,
                    {
                        "ORCHESTRATOR_PYPI_INDEX_URL": "https://index.example/simple",
                        "ORCHESTRATOR_PYPI_EXTRA_INDEX_URL": "https://extra.example/simple",
                    },
                    clear=False,
                ),
                patch.object(runtime_bundle.subprocess, "run", side_effect=fake_run),
            ):
                result = runtime_bundle._install_from_published_version(
                    backend_root,
                    repo_root,
                    Path("/venv/python"),
                )

            self.assertTrue(result)
            self.assertEqual(
                recorded_commands[0],
                [
                    "uv",
                    "pip",
                    "install",
                    "--python",
                    "/venv/python",
                    "--reinstall",
                    "--upgrade",
                    "--no-deps",
                    "--index-url",
                    "https://index.example/simple",
                    "--extra-index-url",
                    "https://extra.example/simple",
                    "orchestrator==0.0.7",
                ],
            )

    def test_install_from_published_version_handles_missing_indexes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir) / "orchestrator"
            repo_root = Path(temp_dir)
            backend_root.mkdir()
            version_file = repo_root / "ui" / "orchestrator.version"
            version_file.parent.mkdir()
            version_file.write_text("0.0.7\n", encoding="utf-8")

            def fake_run(command: list[str], cwd: Path):
                self.assertEqual(
                    command,
                    [
                        "uv",
                        "pip",
                        "install",
                        "--python",
                        "/venv/python",
                        "--reinstall",
                        "--upgrade",
                        "--no-deps",
                        "orchestrator==0.0.7",
                    ],
                )
                return SimpleNamespace(returncode=1)

            with (
                patch.dict(runtime_bundle.os.environ, {}, clear=True),
                patch.object(runtime_bundle.subprocess, "run", side_effect=fake_run),
            ):
                result = runtime_bundle._install_from_published_version(
                    backend_root,
                    repo_root,
                    Path("/venv/python"),
                )

            self.assertFalse(result)

    def test_site_packages_dir_reads_python_output(self):
        fake_result = SimpleNamespace(stdout="/tmp/site-packages\n")
        with patch.object(runtime_bundle.subprocess, "run", return_value=fake_result):
            self.assertEqual(
                runtime_bundle._site_packages_dir(Path("/venv/python")),
                Path("/tmp/site-packages"),
            )

    def test_site_packages_dir_requires_output(self):
        fake_result = SimpleNamespace(stdout="\n")
        with (
            patch.object(runtime_bundle.subprocess, "run", return_value=fake_result),
            self.assertRaisesRegex(
                SystemExit,
                "Unable to locate the virtualenv site-packages directory",
            ),
        ):
            runtime_bundle._site_packages_dir(Path("/venv/python"))

    def test_copy_runtime_bundle_copies_site_packages_and_clears_cache(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            site_packages_dir = Path(temp_dir) / "site-packages"
            runtime_bundle_dir = Path(temp_dir) / "runtime"
            backend_pkg = site_packages_dir / "orchestrator"
            pycache_dir = backend_pkg / "__pycache__"
            dist_info_dir = site_packages_dir / "orchestrator-0.1.0.dist-info"
            backend_pkg.mkdir(parents=True)
            pycache_dir.mkdir()
            dist_info_dir.mkdir()
            (backend_pkg / "__init__.py").write_text("", encoding="utf-8")
            (pycache_dir / "cached.pyc").write_text("", encoding="utf-8")
            (site_packages_dir / "_orchestrator.pth").write_text("", encoding="utf-8")
            (dist_info_dir / "RECORD").write_text("record", encoding="utf-8")
            (dist_info_dir / "uv_cache.json").write_text("{}", encoding="utf-8")
            (site_packages_dir / "orchestrator-0.1.1.dist-info").mkdir()
            dependency_tests = site_packages_dir / "dependency" / "tests"
            dependency_tests.mkdir(parents=True)
            (dependency_tests / "server.key").write_text("secret", encoding="utf-8")
            nested_testing = site_packages_dir / "dependency" / "nested" / "testing"
            nested_testing.mkdir(parents=True)
            (nested_testing / "fixture.txt").write_text("fixture", encoding="utf-8")
            top_level_test = site_packages_dir / "test"
            top_level_test.mkdir()
            (top_level_test / "fixture.txt").write_text("fixture", encoding="utf-8")
            runtime_bundle_dir.mkdir()
            (runtime_bundle_dir / "stale.txt").write_text("stale", encoding="utf-8")

            runtime_bundle._copy_runtime_bundle(site_packages_dir, runtime_bundle_dir)

            self.assertFalse((site_packages_dir / "_orchestrator.pth").exists())
            self.assertTrue(
                (runtime_bundle_dir / "site-packages" / "orchestrator" / "__init__.py").exists()
            )
            self.assertFalse(
                (runtime_bundle_dir / "site-packages" / "orchestrator" / "__pycache__").exists()
            )
            self.assertFalse(
                (runtime_bundle_dir / "site-packages" / "dependency" / "tests").exists()
            )
            self.assertFalse(
                (
                    runtime_bundle_dir / "site-packages" / "dependency" / "nested" / "testing"
                ).exists()
            )
            self.assertFalse((runtime_bundle_dir / "site-packages" / "test").exists())
            self.assertFalse(
                (
                    runtime_bundle_dir / "site-packages" / "orchestrator-0.1.0.dist-info" / "RECORD"
                ).exists()
            )
            self.assertFalse(
                (
                    runtime_bundle_dir
                    / "site-packages"
                    / "orchestrator-0.1.0.dist-info"
                    / "uv_cache.json"
                ).exists()
            )

    def test_copy_runtime_bundle_creates_missing_destination(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            site_packages_dir = Path(temp_dir) / "site-packages"
            runtime_bundle_dir = Path(temp_dir) / "runtime"
            backend_pkg = site_packages_dir / "orchestrator"
            backend_pkg.mkdir(parents=True)
            (backend_pkg / "__init__.py").write_text("", encoding="utf-8")

            runtime_bundle._copy_runtime_bundle(site_packages_dir, runtime_bundle_dir)

            self.assertTrue(
                (runtime_bundle_dir / "site-packages" / "orchestrator" / "__init__.py").exists()
            )

    def test_copy_runtime_bundle_requires_backend_package(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            site_packages_dir = Path(temp_dir) / "site-packages"
            site_packages_dir.mkdir()
            with self.assertRaisesRegex(
                SystemExit,
                "orchestrator package is not fully installed in site-packages",
            ):
                runtime_bundle._copy_runtime_bundle(
                    site_packages_dir,
                    Path(temp_dir) / "runtime",
                )

    def test_verify_runtime_bundle_runs_packaged_task_smoke(self):
        runtime_bundle_dir = Path("/runtime")
        venv_python = Path("/venv/python")
        with patch.object(runtime_bundle, "_run") as run_mock:
            runtime_bundle._verify_runtime_bundle(
                venv_python,
                runtime_bundle_dir,
            )

        run_mock.assert_called_once_with(
            [
                str(venv_python),
                "-c",
                runtime_bundle._RUNTIME_SMOKE_SCRIPT,
            ],
            cwd=runtime_bundle_dir,
            env_overrides={
                "PYTHONPATH": str(runtime_bundle_dir / "site-packages"),
            },
        )

    def test_runtime_smoke_timeout_covers_cold_windows_vms(self):
        self.assertGreaterEqual(runtime_bundle._RUNTIME_SMOKE_TIMEOUT_SECONDS, 60.0)
        self.assertIn(
            str(runtime_bundle._RUNTIME_SMOKE_TIMEOUT_SECONDS),
            runtime_bundle._RUNTIME_SMOKE_SCRIPT,
        )
        self.assertNotIn(
            "time.monotonic() + 10.0",
            runtime_bundle._RUNTIME_SMOKE_SCRIPT,
        )

    def test_prepare_runtime_bundle_uses_published_package_when_available(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir) / "orchestrator"
            repo_root = Path(temp_dir)
            runtime_bundle_dir = backend_root / "runtime_bundle" / "py"
            backend_root.mkdir()

            with (
                patch.object(runtime_bundle, "_run") as run_mock,
                patch.object(
                    runtime_bundle,
                    "_prepare_runtime_bundle_environment",
                    return_value=Path("/venv/python"),
                ),
                patch.object(
                    runtime_bundle, "_install_from_published_version", return_value=True
                ) as install_published_mock,
                patch.object(
                    runtime_bundle,
                    "_site_packages_dir",
                    return_value=Path("/site-packages"),
                ),
                patch.object(
                    runtime_bundle,
                    "_copy_runtime_bundle",
                ) as copy_mock,
                patch.object(
                    runtime_bundle,
                    "_verify_runtime_bundle",
                ) as verify_mock,
            ):
                result = runtime_bundle.prepare_runtime_bundle(
                    backend_root=backend_root,
                    repo_root=repo_root,
                    runtime_bundle_dir=runtime_bundle_dir,
                    package_source="published",
                    allow_local_fallback="1",
                )

            run_mock.assert_not_called()
            install_published_mock.assert_called_once()
            copy_mock.assert_called_once_with(Path("/site-packages"), runtime_bundle_dir)
            verify_mock.assert_called_once_with(
                Path("/venv/python"),
                runtime_bundle_dir,
            )
            self.assertEqual(result, runtime_bundle_dir)

    def test_prepare_runtime_bundle_falls_back_to_local_wheel(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir) / "orchestrator"
            repo_root = Path(temp_dir)
            runtime_bundle_dir = backend_root / "runtime_bundle" / "py"
            backend_root.mkdir()

            stderr = io.StringIO()
            with (
                patch.object(
                    runtime_bundle,
                    "_prepare_runtime_bundle_environment",
                    return_value=Path("/venv/python"),
                ),
                patch.object(
                    runtime_bundle,
                    "_install_from_published_version",
                    return_value=False,
                ),
                patch.object(runtime_bundle, "_install_from_local_wheel") as local_install_mock,
                patch.object(
                    runtime_bundle,
                    "_site_packages_dir",
                    return_value=Path("/site-packages"),
                ),
                patch.object(runtime_bundle, "_copy_runtime_bundle"),
                patch.object(
                    runtime_bundle,
                    "_verify_runtime_bundle",
                ) as verify_mock,
                patch(
                    "sys.stderr",
                    stderr,
                ),
            ):
                runtime_bundle.prepare_runtime_bundle(
                    backend_root=backend_root,
                    repo_root=repo_root,
                    runtime_bundle_dir=runtime_bundle_dir,
                    package_source="published",
                    allow_local_fallback="1",
                )

            local_install_mock.assert_called_once_with(
                backend_root,
                Path("/venv/python"),
            )
            verify_mock.assert_called_once_with(
                Path("/venv/python"),
                runtime_bundle_dir,
            )
            self.assertIn("Published package install failed", stderr.getvalue())

    def test_prepare_runtime_bundle_respects_disabled_fallback(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir) / "orchestrator"
            repo_root = Path(temp_dir)
            runtime_bundle_dir = backend_root / "runtime_bundle" / "py"
            backend_root.mkdir()

            with (
                patch.object(
                    runtime_bundle,
                    "_prepare_runtime_bundle_environment",
                    return_value=Path("/venv/python"),
                ),
                patch.object(
                    runtime_bundle,
                    "_install_from_published_version",
                    return_value=False,
                ),
                self.assertRaisesRegex(
                    SystemExit,
                    "Published package install failed and local fallback is disabled",
                ),
            ):
                runtime_bundle.prepare_runtime_bundle(
                    backend_root=backend_root,
                    repo_root=repo_root,
                    runtime_bundle_dir=runtime_bundle_dir,
                    package_source="published",
                    allow_local_fallback="0",
                )

    def test_prepare_runtime_bundle_supports_local_wheel_and_rejects_unknown_source(
        self,
    ):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir) / "orchestrator"
            repo_root = Path(temp_dir)
            runtime_bundle_dir = backend_root / "runtime_bundle" / "py"
            backend_root.mkdir()

            with (
                patch.object(
                    runtime_bundle,
                    "_prepare_runtime_bundle_environment",
                    return_value=Path("/venv/python"),
                ),
                patch.object(runtime_bundle, "_install_from_local_wheel") as local_install_mock,
                patch.object(
                    runtime_bundle,
                    "_site_packages_dir",
                    return_value=Path("/site-packages"),
                ),
                patch.object(runtime_bundle, "_copy_runtime_bundle"),
                patch.object(
                    runtime_bundle,
                    "_verify_runtime_bundle",
                ) as verify_mock,
            ):
                runtime_bundle.prepare_runtime_bundle(
                    backend_root=backend_root,
                    repo_root=repo_root,
                    runtime_bundle_dir=runtime_bundle_dir,
                    package_source="local-wheel",
                    allow_local_fallback="1",
                )
            local_install_mock.assert_called_once_with(
                backend_root,
                Path("/venv/python"),
            )
            verify_mock.assert_called_once_with(
                Path("/venv/python"),
                runtime_bundle_dir,
            )

            with (
                patch.object(
                    runtime_bundle,
                    "_prepare_runtime_bundle_environment",
                    return_value=Path("/venv/python"),
                ),
                self.assertRaisesRegex(
                    SystemExit,
                    "Unsupported ORCHESTRATOR_PACKAGE_SOURCE: bad-source",
                ),
            ):
                runtime_bundle.prepare_runtime_bundle(
                    backend_root=backend_root,
                    repo_root=repo_root,
                    runtime_bundle_dir=runtime_bundle_dir,
                    package_source="bad-source",
                    allow_local_fallback="1",
                )

    def test_main_reads_environment_and_prints_result(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script_file = (
                Path(temp_dir) / "orchestrator" / "src" / "orchestrator" / "runtime_bundle.py"
            )
            script_file.parent.mkdir(parents=True)
            script_file.write_text("", encoding="utf-8")
            captured = io.StringIO()

            with (
                patch.object(
                    runtime_bundle.Path,
                    "resolve",
                    return_value=script_file,
                ),
                patch.dict(
                    runtime_bundle.os.environ,
                    {
                        "ORCHESTRATOR_PACKAGE_SOURCE": "local-wheel",
                        "ORCHESTRATOR_ALLOW_LOCAL_FALLBACK": "0",
                    },
                    clear=False,
                ),
                patch.object(
                    runtime_bundle,
                    "prepare_runtime_bundle",
                    return_value=Path("/prepared/runtime"),
                ) as prepare_mock,
                patch("sys.stdout", captured),
            ):
                runtime_bundle.main()

            prepare_mock.assert_called_once()
            self.assertIn(
                "Prepared desktop runtime bundle at /prepared/runtime",
                captured.getvalue(),
            )

    def test_main_defaults_to_current_local_wheel_without_fallback(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            script_file = (
                Path(temp_dir) / "orchestrator" / "src" / "orchestrator" / "runtime_bundle.py"
            )
            script_file.parent.mkdir(parents=True)
            script_file.write_text("", encoding="utf-8")

            with (
                patch.object(
                    runtime_bundle.Path,
                    "resolve",
                    return_value=script_file,
                ),
                patch.dict(runtime_bundle.os.environ, {}, clear=True),
                patch.object(
                    runtime_bundle,
                    "prepare_runtime_bundle",
                    return_value=Path("/prepared/runtime"),
                ) as prepare_mock,
                patch("sys.stdout", io.StringIO()),
            ):
                runtime_bundle.main()

            self.assertEqual(
                prepare_mock.call_args.kwargs["package_source"],
                "local-wheel",
            )
            self.assertEqual(
                prepare_mock.call_args.kwargs["allow_local_fallback"],
                "0",
            )


if __name__ == "__main__":
    unittest.main()
