from __future__ import annotations

import ctypes
import multiprocessing
import os
import sys
from pathlib import Path
from typing import IO, Any

try:
    import resource
except ImportError:  # pragma: no cover - unavailable on Windows
    resource = None  # type: ignore[assignment]


_PROCESS_HARDENING_REQUIRED_ENV = "DEPLOYDASH_PROCESS_HARDENING_REQUIRED"
_WINDOWS_PROCESS_IMAGE_LOAD_POLICY = 10
_WINDOWS_IMAGE_LOAD_FLAGS = 0x7
_WINDOWS_DLL_SEARCH_FLAGS = 0xE00
_windows_dll_directory_handles: list[Any] = []
_process_hardening_configured = False


class _NonInteractiveTextStream:
    def __init__(self, stream: IO[Any]) -> None:
        self._stream = stream

    def isatty(self) -> bool:
        return False

    def __getattr__(self, name: str) -> Any:
        return getattr(self._stream, name)


def _open_null_stream(mode: str) -> IO[Any]:
    return _NonInteractiveTextStream(
        open(os.devnull, mode, encoding="utf-8"),
    )


def _stream_is_usable(stream: IO[Any] | None) -> bool:
    if stream is None:
        return False

    try:
        is_tty = stream.isatty()
    except (AttributeError, OSError, ValueError):
        return False

    if not is_tty:
        return True

    try:
        os.get_terminal_size(stream.fileno())
    except (AttributeError, OSError, ValueError):
        return False
    return True


def ensure_standard_streams() -> None:
    """Provide usable non-interactive streams for a GUI-hosted Python."""

    for stream_name, mode in (
        ("stdin", "r"),
        ("stdout", "w"),
        ("stderr", "w"),
        ("__stdin__", "r"),
        ("__stdout__", "w"),
        ("__stderr__", "w"),
    ):
        if not _stream_is_usable(getattr(sys, stream_name, None)):
            setattr(sys, stream_name, _open_null_stream(mode))


def _process_hardening_required() -> bool:
    return os.environ.get(_PROCESS_HARDENING_REQUIRED_ENV) == "1"


def _windows_kernel32() -> Any:
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.SetDefaultDllDirectories.argtypes = [ctypes.c_ulong]
    kernel32.SetDefaultDllDirectories.restype = ctypes.c_int
    kernel32.SetProcessMitigationPolicy.argtypes = [
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.c_size_t,
    ]
    kernel32.SetProcessMitigationPolicy.restype = ctypes.c_int
    kernel32.GetCurrentProcess.argtypes = []
    kernel32.GetCurrentProcess.restype = ctypes.c_void_p
    kernel32.GetProcessMitigationPolicy.argtypes = [
        ctypes.c_void_p,
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.c_size_t,
    ]
    kernel32.GetProcessMitigationPolicy.restype = ctypes.c_int
    return kernel32


def _windows_error(prefix: str) -> RuntimeError:
    get_last_error = getattr(ctypes, "get_last_error", lambda: 0)
    return RuntimeError(f"{prefix} (Windows error {get_last_error()}).")


def _apply_windows_process_hardening(
    *,
    kernel32: Any | None = None,
    add_dll_directory: Any | None = None,
    base_prefix: Path | None = None,
) -> None:
    global _windows_dll_directory_handles

    kernel32 = kernel32 or _windows_kernel32()
    if not kernel32.SetDefaultDllDirectories(_WINDOWS_DLL_SEARCH_FLAGS):
        raise _windows_error("Could not restrict the Python DLL search path")

    add_dll_directory = add_dll_directory or os.add_dll_directory
    base_prefix = base_prefix or Path(sys.base_prefix)

    for directory in (base_prefix, base_prefix / "DLLs"):
        if directory.is_dir():
            _windows_dll_directory_handles.append(add_dll_directory(str(directory)))

    policy_flags = ctypes.c_ulong(_WINDOWS_IMAGE_LOAD_FLAGS)
    if not kernel32.SetProcessMitigationPolicy(
        _WINDOWS_PROCESS_IMAGE_LOAD_POLICY,
        ctypes.byref(policy_flags),
        ctypes.sizeof(policy_flags),
    ):
        raise _windows_error("Could not apply the Python image-load policy")


def _verify_windows_process_hardening(*, kernel32: Any | None = None) -> None:
    kernel32 = kernel32 or _windows_kernel32()
    policy_flags = ctypes.c_ulong(0)
    if not kernel32.GetProcessMitigationPolicy(
        kernel32.GetCurrentProcess(),
        _WINDOWS_PROCESS_IMAGE_LOAD_POLICY,
        ctypes.byref(policy_flags),
        ctypes.sizeof(policy_flags),
    ):
        raise _windows_error("Could not verify the Python image-load policy")
    if policy_flags.value & _WINDOWS_IMAGE_LOAD_FLAGS != _WINDOWS_IMAGE_LOAD_FLAGS:
        raise RuntimeError("The Python image-load policy is incomplete.")


def _apply_linux_process_hardening(
    *,
    setrlimit: Any | None = None,
    libc: Any | None = None,
) -> None:
    """Re-apply core-dump controls in this process before verifying them.

    Why this exists separately from the verify step: exec resets dumpability,
    so a spawned worker starts dumpable even when its hardened parent was
    not. Verifying alone would fail every worker at import (exit 1 with no
    result); re-applying first keeps the no-core-dump invariant without
    trusting inheritance across exec.
    """
    setrlimit = setrlimit or resource.setrlimit
    libc = libc or ctypes.CDLL(None, use_errno=True)
    setrlimit(resource.RLIMIT_CORE, (0, 0))
    if libc.prctl(4, 0) != 0:
        raise RuntimeError("Could not disable process core dumps.")


def _verify_linux_process_hardening(
    *,
    getrlimit: Any | None = None,
    libc: Any | None = None,
) -> None:
    getrlimit = getrlimit or resource.getrlimit
    libc = libc or ctypes.CDLL(None, use_errno=True)
    core_soft, core_hard = getrlimit(resource.RLIMIT_CORE)
    if core_soft != 0 or core_hard != 0:
        raise RuntimeError("Process core dumps are not disabled.")
    if libc.prctl(3) != 0:
        raise RuntimeError("The process is still dumpable.")


def configure_process_hardening() -> None:
    global _process_hardening_configured

    if _process_hardening_configured or not _process_hardening_required():
        return
    if sys.platform == "win32":
        _apply_windows_process_hardening()
        _verify_windows_process_hardening()
    elif sys.platform.startswith("linux"):
        _apply_linux_process_hardening()
        _verify_linux_process_hardening()
    _process_hardening_configured = True


def verify_process_hardening() -> None:
    if not _process_hardening_required():
        return
    if sys.platform == "win32":
        _verify_windows_process_hardening()
    elif sys.platform.startswith("linux"):
        _verify_linux_process_hardening()


def configure_embedded_runtime() -> None:
    """Configure Python for Deploy Dash's non-interactive runtime host."""

    ensure_standard_streams()
    configure_process_hardening()
    _sync_bridge_published_env(getenv=_live_process_getenv, environ=os.environ)
    os.environ.setdefault("PYINFRA_PROGRESS", "off")


_BRIDGE_PUBLISHED_ENV_VARS = ("DEPLOYDASH_DATA_DIR",)


def _live_process_getenv(name: str) -> str | None:
    """Read the live process environ block, bypassing the os.environ snapshot.

    The native bridge publishes variables with setenv(3) after the embedded
    interpreter has already started, so the os.environ snapshot (populated at
    interpreter init) never sees them. The C-level block is authoritative.
    """

    try:
        libc = ctypes.CDLL(None)
        libc.getenv.argtypes = [ctypes.c_char_p]
        libc.getenv.restype = ctypes.c_char_p
        raw = libc.getenv(name.encode("utf-8"))
    except Exception:
        return None
    if not raw:
        return None
    return raw.decode("utf-8", "surrogateescape")


def _sync_bridge_published_env(*, getenv, environ) -> None:
    """Copy bridge-published variables missing from the os.environ snapshot."""

    for name in _BRIDGE_PUBLISHED_ENV_VARS:
        if name in environ:
            continue
        try:
            value = getenv(name)
        except Exception:
            continue
        if value:
            environ[name] = value


def _runtime_site_packages_dir() -> Path:
    return Path(__file__).resolve().parent.parent


def _prepend_runtime_pythonpath(site_packages_dir: Path) -> None:
    runtime_path = str(site_packages_dir)
    existing_entries = [
        entry for entry in os.environ.get("PYTHONPATH", "").split(os.pathsep) if entry
    ]
    if runtime_path in existing_entries:
        return
    os.environ["PYTHONPATH"] = os.pathsep.join(
        [runtime_path, *existing_entries],
    )


def _resolve_spawn_executable() -> Path:
    if sys.platform == "win32":
        candidate = Path(sys.base_prefix) / "pythonw.exe"
        if not candidate.is_file():
            raise RuntimeError(
                "The embedded Python worker executable is missing: "
                f"{candidate}. Rebuild the desktop runtime bundle."
            )
        return candidate

    candidates = _spawn_executable_search_paths()
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise RuntimeError(
        "The embedded Python worker executable is missing: "
        f"{candidates[0] if candidates else sys.executable}. "
        "Rebuild the desktop runtime bundle."
    )


def _spawn_executable_search_paths() -> list[Path]:
    """Ordered interpreter candidates for non-Windows spawn workers.

    Bundle-relative entries come first so they resolve on user machines,
    where ``sys.base_prefix`` still names the build machine. The
    ``sys.executable`` fallback is added by the caller, gated on the name
    looking like a Python interpreter (never the app binary).
    """

    executable_dir = Path(sys.executable).parent
    base_prefix = Path(sys.base_prefix)
    if sys.platform == "darwin":
        contents_dir = executable_dir.parent
        return [
            contents_dir / "Resources" / "python" / "bin" / "python3.13",
            contents_dir / "Resources" / "python" / "bin" / "python3",
            base_prefix / "python" / "bin" / "python3.13",
            base_prefix / "python" / "bin" / "python3",
            base_prefix / "bin" / "python3.13",
            base_prefix / "bin" / "python3",
            base_prefix / "Python",
        ]
    if sys.platform.startswith("linux"):
        return [
            executable_dir / "python" / "bin" / "python3.13",
            executable_dir / "python" / "bin" / "python3",
            base_prefix / "python" / "bin" / "python3.13",
            base_prefix / "python" / "bin" / "python3",
            base_prefix / "bin" / "python3.13",
            base_prefix / "bin" / "python3",
        ]
    return []


def create_task_process_context():
    """Create the worker-process context shared by every engine task.

    Spawn on every platform: fork-without-exec is unsafe in GUI processes
    (macOS sandbox breakage — the child inherits broken Mach/bootstrap
    state), unavailable on Windows, and unnecessary on Linux. One mechanism
    everywhere; fail closed when no worker interpreter resolves instead of
    falling back to a fork that silently misbehaves on macOS.
    """

    worker_executable = _resolve_spawn_executable()
    _prepend_runtime_pythonpath(_runtime_site_packages_dir())
    multiprocessing.set_executable(str(worker_executable))
    return multiprocessing.get_context("spawn")
