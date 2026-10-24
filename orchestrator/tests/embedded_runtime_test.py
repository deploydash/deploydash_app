from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from orchestrator import embedded_runtime


class TestEmbeddedRuntime(unittest.TestCase):
    def test_ensure_standard_streams_preserves_existing_streams(self):
        stdin = sys.stdin
        stdout = sys.stdout
        stderr = sys.stderr

        with patch.object(embedded_runtime, "_open_null_stream") as open_mock:
            embedded_runtime.ensure_standard_streams()

        open_mock.assert_not_called()
        self.assertIs(sys.stdin, stdin)
        self.assertIs(sys.stdout, stdout)
        self.assertIs(sys.stderr, stderr)

    def test_ensure_standard_streams_replaces_missing_streams(self):
        replacement_streams = [object(), object(), object()]
        with (
            patch.object(sys, "stdin", None),
            patch.object(
                sys,
                "stdout",
                None,
            ),
            patch.object(sys, "stderr", None),
            patch.object(
                embedded_runtime,
                "_open_null_stream",
                side_effect=replacement_streams,
            ) as open_mock,
        ):
            embedded_runtime.ensure_standard_streams()

            self.assertIs(sys.stdin, replacement_streams[0])
            self.assertIs(sys.stdout, replacement_streams[1])
            self.assertIs(sys.stderr, replacement_streams[2])

        self.assertEqual(
            [call.args[0] for call in open_mock.call_args_list],
            ["r", "w", "w"],
        )

    def test_ensure_standard_streams_replaces_missing_original_streams(self):
        replacement_streams = [object() for _ in range(6)]
        with (
            patch.object(sys, "stdin", None),
            patch.object(sys, "stdout", None),
            patch.object(sys, "stderr", None),
            patch.object(sys, "__stdin__", None),
            patch.object(sys, "__stdout__", None),
            patch.object(sys, "__stderr__", None),
            patch.object(
                embedded_runtime,
                "_open_null_stream",
                side_effect=replacement_streams,
            ) as open_mock,
        ):
            embedded_runtime.ensure_standard_streams()

            self.assertIs(sys.stdin, replacement_streams[0])
            self.assertIs(sys.stdout, replacement_streams[1])
            self.assertIs(sys.stderr, replacement_streams[2])
            self.assertIs(sys.__stdin__, replacement_streams[3])
            self.assertIs(sys.__stdout__, replacement_streams[4])
            self.assertIs(sys.__stderr__, replacement_streams[5])

        self.assertEqual(
            [call.args[0] for call in open_mock.call_args_list],
            ["r", "w", "w", "r", "w", "w"],
        )

    def test_open_null_stream_uses_text_mode(self):
        stream = embedded_runtime._open_null_stream("w")
        try:
            self.assertFalse(stream.closed)
            self.assertTrue(stream.writable())
            self.assertFalse(stream.isatty())
        finally:
            stream.close()

    def test_stream_is_usable_rejects_missing_stream(self):
        self.assertFalse(embedded_runtime._stream_is_usable(None))

    def test_stream_is_usable_accepts_non_interactive_stream(self):
        stream = MagicMock()
        stream.isatty.return_value = False

        self.assertTrue(embedded_runtime._stream_is_usable(stream))
        stream.fileno.assert_not_called()

    def test_stream_is_usable_rejects_broken_isatty(self):
        stream = MagicMock()
        stream.isatty.side_effect = OSError("invalid handle")

        self.assertFalse(embedded_runtime._stream_is_usable(stream))

    def test_stream_is_usable_accepts_valid_terminal(self):
        stream = MagicMock()
        stream.isatty.return_value = True
        stream.fileno.return_value = 7

        with patch.object(
            embedded_runtime.os,
            "get_terminal_size",
            return_value=os.terminal_size((120, 40)),
        ) as terminal_size_mock:
            self.assertTrue(embedded_runtime._stream_is_usable(stream))

        terminal_size_mock.assert_called_once_with(7)

    def test_stream_is_usable_rejects_invalid_terminal_handle(self):
        stream = MagicMock()
        stream.isatty.return_value = True
        stream.fileno.return_value = 7

        with patch.object(
            embedded_runtime.os,
            "get_terminal_size",
            side_effect=OSError("invalid handle"),
        ):
            self.assertFalse(embedded_runtime._stream_is_usable(stream))

    def test_configure_embedded_runtime_disables_pyinfra_progress(self):
        with (
            patch.dict(os.environ, {}, clear=True),
            patch.object(
                embedded_runtime,
                "ensure_standard_streams",
            ) as ensure_streams_mock,
            patch.object(
                embedded_runtime,
                "configure_process_hardening",
            ) as hardening_mock,
        ):
            embedded_runtime.configure_embedded_runtime()

            self.assertEqual(os.environ["PYINFRA_PROGRESS"], "off")

        ensure_streams_mock.assert_called_once_with()
        hardening_mock.assert_called_once_with()

    def test_configure_embedded_runtime_preserves_explicit_progress_setting(self):
        with (
            patch.dict(
                os.environ,
                {"PYINFRA_PROGRESS": "on"},
                clear=True,
            ),
            patch.object(embedded_runtime, "ensure_standard_streams"),
            patch.object(embedded_runtime, "configure_process_hardening"),
        ):
            embedded_runtime.configure_embedded_runtime()

            self.assertEqual(os.environ["PYINFRA_PROGRESS"], "on")

    def test_runtime_site_packages_dir_contains_backend_package(self):
        self.assertEqual(
            embedded_runtime._runtime_site_packages_dir(),
            Path(embedded_runtime.__file__).resolve().parent.parent,
        )

    def test_prepend_runtime_pythonpath_handles_empty_existing_value(self):
        with patch.dict(os.environ, {}, clear=True):
            embedded_runtime._prepend_runtime_pythonpath(Path("/runtime/site"))
            self.assertEqual(os.environ["PYTHONPATH"], "/runtime/site")

    def test_prepend_runtime_pythonpath_preserves_existing_entries(self):
        existing = os.pathsep.join(["/first", "/second"])
        with patch.dict(os.environ, {"PYTHONPATH": existing}, clear=True):
            embedded_runtime._prepend_runtime_pythonpath(Path("/runtime/site"))
            self.assertEqual(
                os.environ["PYTHONPATH"],
                os.pathsep.join(["/runtime/site", "/first", "/second"]),
            )

    def test_prepend_runtime_pythonpath_does_not_duplicate_runtime_path(self):
        existing = os.pathsep.join(["/runtime/site", "/other"])
        with patch.dict(os.environ, {"PYTHONPATH": existing}, clear=True):
            embedded_runtime._prepend_runtime_pythonpath(Path("/runtime/site"))
            self.assertEqual(os.environ["PYTHONPATH"], existing)

    def test_resolve_spawn_executable_uses_bundled_windows_pythonw(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            worker_python = Path(temp_dir) / "pythonw.exe"
            worker_python.write_text("", encoding="utf-8")
            with (
                patch.object(sys, "platform", "win32"),
                patch.object(
                    sys,
                    "base_prefix",
                    temp_dir,
                ),
            ):
                self.assertEqual(
                    embedded_runtime._resolve_spawn_executable(),
                    worker_python,
                )

    def test_resolve_spawn_executable_requires_existing_file(self):
        with (
            tempfile.TemporaryDirectory() as temp_dir,
            patch.object(
                sys,
                "platform",
                "win32",
            ),
            patch.object(sys, "base_prefix", temp_dir),
            self.assertRaisesRegex(
                RuntimeError,
                "embedded Python worker executable is missing",
            ),
        ):
            embedded_runtime._resolve_spawn_executable()

    def test_resolve_spawn_executable_prefers_bundled_macos_prefix_tree(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            bundle_python = (
                Path(temp_dir) / "Contents" / "Resources" / "python" / "bin" / "python3.13"
            )
            bundle_python.parent.mkdir(parents=True)
            bundle_python.write_text("", encoding="utf-8")
            fake_executable = Path(temp_dir) / "Contents" / "MacOS" / "Deploy Dash"
            with (
                patch.object(sys, "platform", "darwin"),
                patch.object(sys, "executable", str(fake_executable)),
                patch.object(sys, "base_prefix", "/nonexistent-build-prefix"),
            ):
                self.assertEqual(
                    embedded_runtime._resolve_spawn_executable(),
                    bundle_python,
                )

    def test_resolve_spawn_executable_prefers_bundled_linux_prefix_tree(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            bundle_python = Path(temp_dir) / "bundle" / "python" / "bin" / "python3.13"
            bundle_python.parent.mkdir(parents=True)
            bundle_python.write_text("", encoding="utf-8")
            fake_executable = Path(temp_dir) / "bundle" / "deploydash"
            with (
                patch.object(sys, "platform", "linux"),
                patch.object(sys, "executable", str(fake_executable)),
                patch.object(sys, "base_prefix", "/nonexistent-build-prefix"),
            ):
                self.assertEqual(
                    embedded_runtime._resolve_spawn_executable(),
                    bundle_python,
                )

    def test_resolve_spawn_executable_uses_base_prefix_interpreter(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            base_python = Path(temp_dir) / "base" / "bin" / "python3.13"
            base_python.parent.mkdir(parents=True)
            base_python.write_text("", encoding="utf-8")
            fake_executable = Path(temp_dir) / "bundle" / "deploydash"
            with (
                patch.object(sys, "platform", "linux"),
                patch.object(sys, "executable", str(fake_executable)),
                patch.object(sys, "base_prefix", str(Path(temp_dir) / "base")),
            ):
                self.assertEqual(
                    embedded_runtime._resolve_spawn_executable(),
                    base_python,
                )

    def test_resolve_spawn_executable_prefers_bundle_root_layout(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            bundle_python = Path(temp_dir) / "prefix" / "python" / "bin" / "python3.13"
            bundle_python.parent.mkdir(parents=True)
            bundle_python.write_text("", encoding="utf-8")
            fake_executable = Path(temp_dir) / "prefix" / "deploydash"
            with (
                patch.object(sys, "platform", "linux"),
                patch.object(sys, "executable", str(fake_executable)),
                patch.object(sys, "base_prefix", str(Path(temp_dir) / "prefix")),
            ):
                self.assertEqual(
                    embedded_runtime._resolve_spawn_executable(),
                    bundle_python,
                )

    def test_resolve_spawn_executable_fails_closed_without_candidates(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fake_executable = Path(temp_dir) / "bundle" / "deploydash"
            with (
                patch.object(sys, "platform", "linux"),
                patch.object(sys, "executable", str(fake_executable)),
                patch.object(sys, "base_prefix", "/nonexistent-build-prefix"),
                self.assertRaisesRegex(
                    RuntimeError,
                    "embedded Python worker executable is missing",
                ),
            ):
                embedded_runtime._resolve_spawn_executable()

    def test_resolve_spawn_executable_has_no_candidates_off_supported_platforms(
        self,
    ):
        with tempfile.TemporaryDirectory() as temp_dir:
            fake_executable = Path(temp_dir) / "deploydash"
            with (
                patch.object(sys, "platform", "sunos"),
                patch.object(sys, "executable", str(fake_executable)),
                patch.object(sys, "base_prefix", "/nonexistent-build-prefix"),
                self.assertRaisesRegex(
                    RuntimeError,
                    "embedded Python worker executable is missing",
                ),
            ):
                embedded_runtime._resolve_spawn_executable()

    def test_create_task_process_context_uses_spawn_on_all_platforms(self):
        spawn_context = object()
        worker_python = Path("/bundle/python/bin/python3.13")
        runtime_site_packages = Path("/bundle/data/py/site-packages")
        with (
            patch.object(
                embedded_runtime.multiprocessing,
                "get_context",
                return_value=spawn_context,
            ) as context_mock,
            patch.object(
                embedded_runtime,
                "_resolve_spawn_executable",
                return_value=worker_python,
            ),
            patch.object(
                embedded_runtime,
                "_runtime_site_packages_dir",
                return_value=runtime_site_packages,
            ),
            patch.object(
                embedded_runtime,
                "_prepend_runtime_pythonpath",
            ) as prepend_mock,
            patch.object(
                embedded_runtime.multiprocessing,
                "set_executable",
            ) as set_executable_mock,
        ):
            result = embedded_runtime.create_task_process_context()

        self.assertIs(result, spawn_context)
        context_mock.assert_called_once_with("spawn")
        prepend_mock.assert_called_once_with(runtime_site_packages)
        set_executable_mock.assert_called_once_with(str(worker_python))

    def test_default_task_process_context_is_spawn(self):
        with (
            patch.dict(os.environ, {}, clear=True),
            patch.object(embedded_runtime.multiprocessing, "set_executable"),
        ):
            context = embedded_runtime.create_task_process_context()
        self.assertEqual(context._name, "spawn")

    def test_create_task_process_context_propagates_spawn_runtime(self):
        worker_python = "/bundle/python/bin/python3.13"
        site_packages = "/bundle/data/py/site-packages"
        with (
            patch.object(
                embedded_runtime.multiprocessing,
                "get_context",
            ),
            patch.object(
                embedded_runtime,
                "_resolve_spawn_executable",
                return_value=Path(worker_python),
            ),
            patch.object(
                embedded_runtime,
                "_runtime_site_packages_dir",
                return_value=Path(site_packages),
            ),
            patch.object(
                embedded_runtime.multiprocessing,
                "set_executable",
            ) as set_executable_mock,
            patch.dict(os.environ, {}, clear=True),
        ):
            embedded_runtime.create_task_process_context()
            set_executable_mock.assert_called_once_with(worker_python)
            self.assertIn(
                site_packages,
                os.environ.get("PYTHONPATH", "").split(os.pathsep),
            )

    def test_task_runtime_imports_when_gui_standard_streams_are_missing(self):
        source_root = Path(__file__).resolve().parents[1] / "src"
        script = (
            "import os\n"
            "import sys\n"
            "def fail_terminal_size(*args):\n"
            "    raise OSError('invalid native console handle')\n"
            "os.get_terminal_size = fail_terminal_size\n"
            "sys.stdin = None\n"
            "sys.stdout = None\n"
            "sys.stderr = None\n"
            "sys.__stdin__ = None\n"
            "sys.__stdout__ = None\n"
            "sys.__stderr__ = None\n"
            "from orchestrator import task_runtime\n"
            "assert task_runtime._TASK_PROCESS_CONTEXT is not None\n"
            "assert sys.stdin is not None\n"
            "assert sys.stdout is not None\n"
            "assert sys.stderr is not None\n"
            "assert sys.__stdin__ is not None\n"
            "assert sys.__stdout__ is not None\n"
            "assert sys.__stderr__ is not None\n"
            "assert not sys.stdout.isatty()\n"
            "assert not sys.stderr.isatty()\n"
            "assert os.environ['PYINFRA_PROGRESS'] == 'off'\n"
        )
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(source_root)

        result = subprocess.run(
            [sys.executable, "-c", script],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(result.returncode, 0, result.stderr)


class TestProcessHardening(unittest.TestCase):
    def setUp(self):
        embedded_runtime._process_hardening_configured = False
        embedded_runtime._windows_dll_directory_handles = []

    def test_required_flag_reads_environment(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(embedded_runtime._process_hardening_required())
        with patch.dict(
            os.environ,
            {"DEPLOYDASH_PROCESS_HARDENING_REQUIRED": "1"},
            clear=True,
        ):
            self.assertTrue(embedded_runtime._process_hardening_required())

    def test_windows_error_includes_last_error(self):
        with patch.object(
            embedded_runtime.ctypes,
            "get_last_error",
            return_value=5,
            create=True,
        ):
            self.assertEqual(
                str(embedded_runtime._windows_error("failed")),
                "failed (Windows error 5).",
            )

    def test_windows_error_uses_zero_without_windows_api(self):
        self.assertEqual(
            str(embedded_runtime._windows_error("failed")),
            "failed (Windows error 0).",
        )

    def test_windows_kernel32_loads_system_library(self):
        kernel32 = MagicMock()
        with patch.object(
            embedded_runtime.ctypes,
            "WinDLL",
            return_value=kernel32,
            create=True,
        ) as win_dll_mock:
            self.assertIs(embedded_runtime._windows_kernel32(), kernel32)
        win_dll_mock.assert_called_once_with("kernel32", use_last_error=True)
        self.assertEqual(
            kernel32.SetDefaultDllDirectories.argtypes,
            [embedded_runtime.ctypes.c_ulong],
        )
        self.assertIs(
            kernel32.SetDefaultDllDirectories.restype,
            embedded_runtime.ctypes.c_int,
        )
        self.assertEqual(
            kernel32.SetProcessMitigationPolicy.argtypes,
            [
                embedded_runtime.ctypes.c_int,
                embedded_runtime.ctypes.c_void_p,
                embedded_runtime.ctypes.c_size_t,
            ],
        )
        self.assertIs(
            kernel32.SetProcessMitigationPolicy.restype,
            embedded_runtime.ctypes.c_int,
        )
        self.assertEqual(kernel32.GetCurrentProcess.argtypes, [])
        self.assertIs(
            kernel32.GetCurrentProcess.restype,
            embedded_runtime.ctypes.c_void_p,
        )
        self.assertEqual(
            kernel32.GetProcessMitigationPolicy.argtypes,
            [
                embedded_runtime.ctypes.c_void_p,
                embedded_runtime.ctypes.c_int,
                embedded_runtime.ctypes.c_void_p,
                embedded_runtime.ctypes.c_size_t,
            ],
        )
        self.assertIs(
            kernel32.GetProcessMitigationPolicy.restype,
            embedded_runtime.ctypes.c_int,
        )

    def test_apply_windows_process_hardening(self):
        kernel32 = MagicMock()
        kernel32.SetDefaultDllDirectories.return_value = 1
        kernel32.SetProcessMitigationPolicy.return_value = 1
        handles = []

        with tempfile.TemporaryDirectory() as temp_dir:
            dlls = Path(temp_dir) / "DLLs"
            dlls.mkdir()

            def add_directory(path):
                handle = f"handle:{path}"
                handles.append(handle)
                return handle

            embedded_runtime._apply_windows_process_hardening(
                kernel32=kernel32,
                add_dll_directory=add_directory,
                base_prefix=Path(temp_dir),
            )

        kernel32.SetDefaultDllDirectories.assert_called_once_with(0xE00)
        kernel32.SetProcessMitigationPolicy.assert_called_once()
        self.assertEqual(embedded_runtime._windows_dll_directory_handles, handles)
        self.assertEqual(len(handles), 2)

    def test_apply_windows_process_hardening_skips_missing_dlls_directory(self):
        kernel32 = MagicMock()
        kernel32.SetDefaultDllDirectories.return_value = 1
        kernel32.SetProcessMitigationPolicy.return_value = 1
        add_directory = MagicMock(return_value=object())
        with tempfile.TemporaryDirectory() as temp_dir:
            embedded_runtime._apply_windows_process_hardening(
                kernel32=kernel32,
                add_dll_directory=add_directory,
                base_prefix=Path(temp_dir),
            )
        add_directory.assert_called_once_with(temp_dir)

    def test_apply_windows_process_hardening_uses_runtime_defaults(self):
        kernel32 = MagicMock()
        kernel32.SetDefaultDllDirectories.return_value = 1
        kernel32.SetProcessMitigationPolicy.return_value = 1
        add_directory = MagicMock(return_value=object())
        with (
            tempfile.TemporaryDirectory() as temp_dir,
            patch.object(embedded_runtime, "_windows_kernel32", return_value=kernel32),
            patch.object(
                embedded_runtime.os,
                "add_dll_directory",
                add_directory,
                create=True,
            ),
            patch.object(sys, "base_prefix", temp_dir),
        ):
            embedded_runtime._apply_windows_process_hardening()
        add_directory.assert_called_once_with(temp_dir)

    def test_apply_windows_process_hardening_reports_dll_search_failure(self):
        kernel32 = MagicMock()
        kernel32.SetDefaultDllDirectories.return_value = 0
        with self.assertRaisesRegex(RuntimeError, "restrict the Python DLL"):
            embedded_runtime._apply_windows_process_hardening(kernel32=kernel32)

    def test_apply_windows_process_hardening_reports_policy_failure(self):
        kernel32 = MagicMock()
        kernel32.SetDefaultDllDirectories.return_value = 1
        kernel32.SetProcessMitigationPolicy.return_value = 0
        with (
            tempfile.TemporaryDirectory() as temp_dir,
            self.assertRaisesRegex(RuntimeError, "image-load policy"),
        ):
            embedded_runtime._apply_windows_process_hardening(
                kernel32=kernel32,
                add_dll_directory=MagicMock(return_value=object()),
                base_prefix=Path(temp_dir),
            )

    def test_verify_windows_process_hardening(self):
        kernel32 = MagicMock()
        kernel32.GetCurrentProcess.return_value = 99

        def set_policy(_process, _policy, pointer, _size):
            pointer._obj.value = 0x7
            return 1

        kernel32.GetProcessMitigationPolicy.side_effect = set_policy
        embedded_runtime._verify_windows_process_hardening(kernel32=kernel32)

    def test_verify_windows_process_hardening_uses_default_kernel(self):
        kernel32 = MagicMock()
        kernel32.GetProcessMitigationPolicy.side_effect = lambda _process, _policy, pointer, _size: (
            setattr(pointer._obj, "value", 0x7) or 1
        )
        with patch.object(
            embedded_runtime,
            "_windows_kernel32",
            return_value=kernel32,
        ):
            embedded_runtime._verify_windows_process_hardening()

    def test_verify_windows_process_hardening_reports_query_failure(self):
        kernel32 = MagicMock()
        kernel32.GetProcessMitigationPolicy.return_value = 0
        with self.assertRaisesRegex(RuntimeError, "verify the Python"):
            embedded_runtime._verify_windows_process_hardening(kernel32=kernel32)

    def test_verify_windows_process_hardening_rejects_incomplete_policy(self):
        kernel32 = MagicMock()
        kernel32.GetProcessMitigationPolicy.return_value = 1
        with self.assertRaisesRegex(RuntimeError, "policy is incomplete"):
            embedded_runtime._verify_windows_process_hardening(kernel32=kernel32)

    def test_verify_linux_process_hardening(self):
        libc = MagicMock()
        libc.prctl.return_value = 0
        embedded_runtime._verify_linux_process_hardening(
            getrlimit=lambda _resource: (0, 0),
            libc=libc,
        )
        libc.prctl.assert_called_once_with(3)

    def test_verify_linux_process_hardening_uses_runtime_defaults(self):
        libc = MagicMock()
        libc.prctl.return_value = 0
        with (
            patch.object(
                embedded_runtime.resource,
                "getrlimit",
                return_value=(0, 0),
            ),
            patch.object(
                embedded_runtime.ctypes,
                "CDLL",
                return_value=libc,
            ) as cdll_mock,
        ):
            embedded_runtime._verify_linux_process_hardening()
        cdll_mock.assert_called_once_with(None, use_errno=True)

    def test_verify_linux_process_hardening_rejects_core_limits(self):
        with self.assertRaisesRegex(RuntimeError, "core dumps"):
            embedded_runtime._verify_linux_process_hardening(
                getrlimit=lambda _resource: (1, 0),
                libc=MagicMock(),
            )

    def test_verify_linux_process_hardening_rejects_dumpable_process(self):
        libc = MagicMock()
        libc.prctl.return_value = 1
        with self.assertRaisesRegex(RuntimeError, "still dumpable"):
            embedded_runtime._verify_linux_process_hardening(
                getrlimit=lambda _resource: (0, 0),
                libc=libc,
            )

    def test_configure_process_hardening_noops_when_not_required_or_repeated(self):
        with (
            patch.object(
                embedded_runtime,
                "_process_hardening_required",
                side_effect=[False, True],
            ),
            patch.object(embedded_runtime.sys, "platform", "linux"),
            patch.object(
                embedded_runtime,
                "_verify_linux_process_hardening",
            ) as verify_mock,
        ):
            embedded_runtime.configure_process_hardening()
            embedded_runtime._process_hardening_configured = True
            embedded_runtime.configure_process_hardening()
        verify_mock.assert_not_called()

    def test_configure_process_hardening_applies_windows_controls(self):
        with (
            patch.object(embedded_runtime, "_process_hardening_required", return_value=True),
            patch.object(embedded_runtime.sys, "platform", "win32"),
            patch.object(embedded_runtime, "_apply_windows_process_hardening") as apply_mock,
            patch.object(embedded_runtime, "_verify_windows_process_hardening") as verify_mock,
        ):
            embedded_runtime.configure_process_hardening()
        apply_mock.assert_called_once_with()
        verify_mock.assert_called_once_with()
        self.assertTrue(embedded_runtime._process_hardening_configured)

    def test_configure_process_hardening_verifies_linux_controls(self):
        with (
            patch.object(embedded_runtime, "_process_hardening_required", return_value=True),
            patch.object(embedded_runtime.sys, "platform", "linux"),
            patch.object(
                embedded_runtime,
                "_apply_linux_process_hardening",
            ) as apply_mock,
            patch.object(embedded_runtime, "_verify_linux_process_hardening") as verify_mock,
        ):
            embedded_runtime.configure_process_hardening()
        apply_mock.assert_called_once_with()
        verify_mock.assert_called_once_with()

    def test_configure_process_hardening_reapplies_linux_controls_after_exec(self):
        # Why: exec resets dumpability, so a spawned worker that only verifies
        # dies at import with "still dumpable" (every current production task
        # fails this way). Configure must re-apply before verifying.
        prctl_state = {"dumpable": 1}
        libc = MagicMock()

        def fake_prctl(operation, *args):
            if operation == 3:
                return prctl_state["dumpable"]
            if operation == 4:
                prctl_state["dumpable"] = 0
                return 0
            raise AssertionError(f"unexpected prctl operation {operation}")

        libc.prctl.side_effect = fake_prctl
        with (
            patch.object(embedded_runtime, "_process_hardening_required", return_value=True),
            patch.object(embedded_runtime.sys, "platform", "linux"),
            patch.object(
                embedded_runtime.resource,
                "getrlimit",
                return_value=(0, 0),
            ),
            patch.object(
                embedded_runtime.resource,
                "setrlimit",
            ) as setrlimit_mock,
            patch.object(embedded_runtime.ctypes, "CDLL", return_value=libc),
        ):
            embedded_runtime.configure_process_hardening()
        setrlimit_mock.assert_called_once()
        self.assertEqual(prctl_state["dumpable"], 0)
        self.assertTrue(embedded_runtime._process_hardening_configured)

    def test_apply_linux_process_hardening_reports_prctl_failure(self):
        libc = MagicMock()
        libc.prctl.return_value = -1
        with self.assertRaisesRegex(RuntimeError, "disable process core dumps"):
            embedded_runtime._apply_linux_process_hardening(
                setrlimit=MagicMock(),
                libc=libc,
            )

    def test_spawned_worker_import_survives_exec_dumpable_reset(self):
        # Why: the exact production failure — a fresh interpreter (as re-execd
        # by spawn) starts dumpable even with the flag set, so importing the
        # worker module must re-harden instead of raising.
        source_root = Path(__file__).resolve().parents[1] / "src"
        script = (
            "import ctypes\n"
            "import resource\n"
            "libc = ctypes.CDLL(None, use_errno=True)\n"
            "resource.setrlimit(resource.RLIMIT_CORE, (0, 0))\n"
            "assert libc.prctl(4, 1) == 0\n"
            "from orchestrator import embedded_runtime\n"
            "embedded_runtime.configure_embedded_runtime()\n"
            "embedded_runtime.verify_process_hardening()\n"
            'print("hardened worker import ok")\n'
        )
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(source_root)
        environment["DEPLOYDASH_PROCESS_HARDENING_REQUIRED"] = "1"

        result = subprocess.run(
            [sys.executable, "-c", script],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("hardened worker import ok", result.stdout)

    def test_configure_process_hardening_accepts_other_supported_platform(self):
        with (
            patch.object(embedded_runtime, "_process_hardening_required", return_value=True),
            patch.object(embedded_runtime.sys, "platform", "darwin"),
        ):
            embedded_runtime.configure_process_hardening()
        self.assertTrue(embedded_runtime._process_hardening_configured)

    def test_verify_process_hardening_dispatches_by_platform(self):
        with patch.object(
            embedded_runtime,
            "_process_hardening_required",
            return_value=False,
        ):
            embedded_runtime.verify_process_hardening()

        with (
            patch.object(embedded_runtime, "_process_hardening_required", return_value=True),
            patch.object(embedded_runtime.sys, "platform", "win32"),
            patch.object(embedded_runtime, "_verify_windows_process_hardening") as windows_mock,
        ):
            embedded_runtime.verify_process_hardening()
        windows_mock.assert_called_once_with()

        with (
            patch.object(embedded_runtime, "_process_hardening_required", return_value=True),
            patch.object(embedded_runtime.sys, "platform", "linux"),
            patch.object(embedded_runtime, "_verify_linux_process_hardening") as linux_mock,
        ):
            embedded_runtime.verify_process_hardening()
        linux_mock.assert_called_once_with()

        with (
            patch.object(embedded_runtime, "_process_hardening_required", return_value=True),
            patch.object(embedded_runtime.sys, "platform", "darwin"),
        ):
            embedded_runtime.verify_process_hardening()

    def test_sync_bridge_published_env_copies_missing_data_dir(self):
        environ: dict[str, str] = {}
        embedded_runtime._sync_bridge_published_env(
            getenv=lambda name: "/tmp/profile" if name == "DEPLOYDASH_DATA_DIR" else None,
            environ=environ,
        )
        self.assertEqual(environ.get("DEPLOYDASH_DATA_DIR"), "/tmp/profile")

    def test_sync_bridge_published_env_keeps_existing_value(self):
        environ: dict[str, str] = {"DEPLOYDASH_DATA_DIR": "/tmp/old"}
        embedded_runtime._sync_bridge_published_env(
            getenv=lambda name: "/tmp/new",
            environ=environ,
        )
        self.assertEqual(environ.get("DEPLOYDASH_DATA_DIR"), "/tmp/old")

    def test_sync_bridge_published_env_ignores_missing_live_value(self):
        environ: dict[str, str] = {}
        embedded_runtime._sync_bridge_published_env(
            getenv=lambda name: None,
            environ=environ,
        )
        self.assertNotIn("DEPLOYDASH_DATA_DIR", environ)

    def test_live_process_getenv_returns_none_when_libc_unavailable(self):
        # Why: the hardened gate requires every line of the bridge-env path
        # covered; a missing/broken libc must degrade to None, not raise.
        with patch.object(
            embedded_runtime.ctypes,
            "CDLL",
            side_effect=OSError("no libc"),
        ):
            self.assertIsNone(embedded_runtime._live_process_getenv("DEPLOYDASH_DATA_DIR"))

    def test_live_process_getenv_decodes_live_block_value(self):
        libc = MagicMock()
        libc.getenv.return_value = b"/tmp/profile"
        with patch.object(embedded_runtime.ctypes, "CDLL", return_value=libc):
            self.assertEqual(
                embedded_runtime._live_process_getenv("DEPLOYDASH_DATA_DIR"),
                "/tmp/profile",
            )
        libc.getenv.assert_called_once_with(b"DEPLOYDASH_DATA_DIR")

    def test_sync_bridge_published_env_skips_failing_live_read(self):
        # Why: same gate — a throwing live-block read must skip the key,
        # leaving any existing value untouched.
        def fail_getenv(name):
            raise OSError("blocked")

        environ: dict[str, str] = {}
        embedded_runtime._sync_bridge_published_env(
            getenv=fail_getenv,
            environ=environ,
        )
        self.assertNotIn("DEPLOYDASH_DATA_DIR", environ)


if __name__ == "__main__":
    unittest.main()
