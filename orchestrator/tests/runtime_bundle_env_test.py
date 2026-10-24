import io
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from orchestrator import runtime_bundle


def _versioned_roots(temp_dir):
    backend_root = Path(temp_dir) / "orchestrator"
    repo_root = Path(temp_dir)
    backend_root.mkdir()
    version_file = repo_root / "ui" / "orchestrator.version"
    version_file.parent.mkdir()
    version_file.write_text("0.0.7\n", encoding="utf-8")
    return backend_root, repo_root


def _install_command(backend_root, repo_root, env):
    # Why: runs the pip-index resolution sites (1-2) and returns the built
    # install command so fallback matrices pin exact flag behavior.
    recorded = []

    def fake_run(command, cwd):
        recorded.append(command)
        return SimpleNamespace(returncode=0)

    with (
        patch.dict(runtime_bundle.os.environ, env, clear=True),
        patch.object(runtime_bundle.subprocess, "run", side_effect=fake_run),
    ):
        runtime_bundle._install_from_published_version(
            backend_root, repo_root, Path("/venv/python")
        )
    return recorded[0]


def _main_kwargs(env):
    # Why: runs the package-source resolution sites (3-4) via main() and
    # returns the kwargs main() resolved from the environment.
    with tempfile.TemporaryDirectory() as temp_dir:
        script_file = Path(temp_dir) / "orchestrator" / "src" / "orchestrator" / "runtime_bundle.py"
        script_file.parent.mkdir(parents=True)
        script_file.write_text("", encoding="utf-8")
        with (
            patch.object(runtime_bundle.Path, "resolve", return_value=script_file),
            patch.dict(runtime_bundle.os.environ, env, clear=True),
            patch.object(
                runtime_bundle,
                "prepare_runtime_bundle",
                return_value=Path("/prepared/runtime"),
            ) as prepare_mock,
            patch("sys.stdout", io.StringIO()),
        ):
            runtime_bundle.main()
        return prepare_mock.call_args.kwargs


class TestEnvFirstHelper(unittest.TestCase):
    def test_first_set_name_wins(self):
        with patch.dict(
            runtime_bundle.os.environ,
            {"OUTER_X": "outer", "INNER_X": "inner"},
            clear=True,
        ):
            self.assertEqual(
                runtime_bundle._env_first("OUTER_X", "INNER_X", default="d"),
                "outer",
            )

    def test_set_but_empty_outer_wins_over_inner(self):
        with patch.dict(
            runtime_bundle.os.environ,
            {"OUTER_X": "", "INNER_X": "inner"},
            clear=True,
        ):
            self.assertEqual(
                runtime_bundle._env_first("OUTER_X", "INNER_X", default="d"),
                "",
            )

    def test_inner_used_when_outer_unset(self):
        with patch.dict(runtime_bundle.os.environ, {"INNER_X": "inner"}, clear=True):
            self.assertEqual(
                runtime_bundle._env_first("OUTER_X", "INNER_X", default="d"),
                "inner",
            )

    def test_default_used_when_nothing_set(self):
        with patch.dict(runtime_bundle.os.environ, {}, clear=True):
            self.assertEqual(
                runtime_bundle._env_first("OUTER_X", "INNER_X", default="d"),
                "d",
            )

    def test_helper_does_not_strip(self):
        with patch.dict(runtime_bundle.os.environ, {"OUTER_X": "  padded  "}, clear=True):
            self.assertEqual(
                runtime_bundle._env_first("OUTER_X", default="d"),
                "  padded  ",
            )


class TestBundleEnvFallbackMatrices(unittest.TestCase):
    def test_pip_index_falls_back_to_inner_name(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root, repo_root = _versioned_roots(temp_dir)
            command = _install_command(
                backend_root,
                repo_root,
                {"DEPLOYDASH_ENGINE_PYPI_INDEX_URL": "https://inner.example/s"},
            )

        self.assertIn("--index-url", command)
        self.assertIn("https://inner.example/s", command)

    def test_pip_index_set_but_empty_outer_wins(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root, repo_root = _versioned_roots(temp_dir)
            command = _install_command(
                backend_root,
                repo_root,
                {
                    "ORCHESTRATOR_PYPI_INDEX_URL": "",
                    "DEPLOYDASH_ENGINE_PYPI_INDEX_URL": "https://inner.example",
                },
            )

        self.assertNotIn("--index-url", command)

    def test_pip_extra_index_set_but_empty_outer_wins(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root, repo_root = _versioned_roots(temp_dir)
            command = _install_command(
                backend_root,
                repo_root,
                {
                    "ORCHESTRATOR_PYPI_EXTRA_INDEX_URL": "",
                    "DEPLOYDASH_ENGINE_PYPI_EXTRA_INDEX_URL": ("https://extra-inner.example"),
                },
            )

        self.assertNotIn("--extra-index-url", command)

    def test_pip_index_values_are_stripped(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root, repo_root = _versioned_roots(temp_dir)
            command = _install_command(
                backend_root,
                repo_root,
                {"ORCHESTRATOR_PYPI_INDEX_URL": "  https://x.example/s  "},
            )

        self.assertIn("https://x.example/s", command)

    def test_package_source_falls_back_to_inner_name(self):
        kwargs = _main_kwargs({"DEPLOYDASH_ENGINE_PACKAGE_SOURCE": "published"})

        self.assertEqual(kwargs["package_source"], "published")

    def test_package_source_set_but_empty_outer_wins(self):
        kwargs = _main_kwargs(
            {
                "ORCHESTRATOR_PACKAGE_SOURCE": "",
                "DEPLOYDASH_ENGINE_PACKAGE_SOURCE": "published",
            }
        )

        self.assertEqual(kwargs["package_source"], "")

    def test_allow_local_fallback_set_but_empty_outer_wins(self):
        kwargs = _main_kwargs(
            {
                "ORCHESTRATOR_ALLOW_LOCAL_FALLBACK": "",
                "DEPLOYDASH_ENGINE_ALLOW_LOCAL_FALLBACK": "1",
            }
        )

        self.assertEqual(kwargs["allow_local_fallback"], "")

    def test_main_values_are_stripped(self):
        kwargs = _main_kwargs(
            {
                "ORCHESTRATOR_PACKAGE_SOURCE": "  local-wheel  ",
                "ORCHESTRATOR_ALLOW_LOCAL_FALLBACK": "  0  ",
            }
        )

        self.assertEqual(kwargs["package_source"], "local-wheel")
        self.assertEqual(kwargs["allow_local_fallback"], "0")

    def test_version_file_or_chain_uses_falsy_fallback(self):
        # Why: non-member B is an or-chain, NOT first-set-wins: a set-but-
        # empty first name falls THROUGH to the next. This semantic excludes
        # it from _env_first, so the divergence is pinned, not converted.
        with tempfile.TemporaryDirectory() as temp_dir:
            backend_root = Path(temp_dir) / "orchestrator"
            repo_root = Path(temp_dir)
            backend_root.mkdir()
            version_file = repo_root / "pinned.version"
            version_file.write_text("0.0.7\n", encoding="utf-8")
            with patch.dict(
                runtime_bundle.os.environ,
                {
                    "DEPLOYDASH_ORCHESTRATOR_VERSION_FILE": "",
                    "DEPLOYDASH_BACKEND_VERSION_FILE": str(version_file),
                },
                clear=True,
            ):
                resolved = runtime_bundle._resolve_pinned_version_file(backend_root, repo_root)

        self.assertEqual(resolved, version_file)


if __name__ == "__main__":
    unittest.main()
