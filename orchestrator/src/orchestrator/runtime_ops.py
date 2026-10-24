import shlex
import uuid
from collections.abc import Callable, Iterable, Sequence
from typing import Any, Protocol


class ShellCommandOutput(Protocol):
    """The `output` half of a pyinfra host's `run_shell_command` result.

    Structural, not the real pyinfra type: satisfied by pyinfra's own
    `StringCommandOutput` and by every fault-injecting fake host in the
    test suite (e.g. `tests.runtime_ops_test._FakeOutput`) without either
    depending on the other.
    """

    stdout_lines: list[str]
    stderr_lines: list[str]


class Host(Protocol):
    """The pyinfra `host` object as this module's functions use it.

    Narrower than pyinfra's real `Host` -- only the one method this module
    calls -- so a fault-injecting fake can implement this Protocol directly
    and be accepted anywhere a real `host` is, with no subclassing and no
    dependency on pyinfra internals.
    """

    def run_shell_command(
        self, command: str, *, _timeout: int, _sudo: bool
    ) -> tuple[bool, ShellCommandOutput]: ...


def _join_nonempty_lines(lines: Iterable[object], *, separator: str = "; ") -> str:
    """Join stripped lines, skipping blanks (#199 owner).

    First consumer is [_stderr_details]; later detail builders route here
    instead of growing their own one-liner.
    """
    return separator.join(str(line).strip() for line in lines if str(line).strip())


def _stderr_details(output: object | None) -> str:
    if output is None:
        return ""
    stderr_lines = getattr(output, "stderr_lines", None) or []
    if not stderr_lines:
        return ""
    return _join_nonempty_lines(stderr_lines)


def run_shell_command(
    host: Host,
    command: str,
    *,
    timeout: int = 60,
    sudo: bool = True,
    emit_output: Callable[[ShellCommandOutput], None] | None = None,
) -> dict[str, Any]:
    ok, output = host.run_shell_command(
        command,
        _timeout=timeout,
        _sudo=sudo,
    )
    if callable(emit_output):
        emit_output(output)

    details = _stderr_details(output)
    if not details and not ok:
        details = "remote command failed"

    return {
        "ok": bool(ok),
        "output": output,
        "details": details or None,
    }


def write_remote_text_file(
    host: Host,
    *,
    path: str,
    content: str,
    mode: str | None = None,
    timeout: int = 45,
    sudo: bool = True,
    emit_output: Callable[[ShellCommandOutput], None] | None = None,
) -> dict[str, Any]:
    quoted_path = shlex.quote(path)
    delimiter = f"__DEPLOYDASH_EOF_{uuid.uuid4().hex}__"
    rendered = content if content.endswith("\n") else f"{content}\n"

    command = f"cat > {quoted_path} <<'{delimiter}'\n{rendered}{delimiter}\n"
    if mode is not None:
        command += f"chmod {shlex.quote(str(mode))} {quoted_path}\n"

    return run_shell_command(
        host,
        command,
        timeout=timeout,
        sudo=sudo,
        emit_output=emit_output,
    )


def remove_remote_files(
    host: Host,
    *,
    paths: Sequence[str],
    timeout: int = 30,
    sudo: bool = True,
    emit_output: Callable[[ShellCommandOutput], None] | None = None,
) -> dict[str, Any]:
    quoted_paths = " ".join(shlex.quote(path) for path in paths)
    return run_shell_command(
        host,
        f"rm -f {quoted_paths}",
        timeout=timeout,
        sudo=sudo,
        emit_output=emit_output,
    )


def systemd_daemon_reload(
    host: Host,
    *,
    timeout: int = 30,
    sudo: bool = True,
    emit_output: Callable[[ShellCommandOutput], None] | None = None,
) -> dict[str, Any]:
    return run_shell_command(
        host,
        "systemctl daemon-reload",
        timeout=timeout,
        sudo=sudo,
        emit_output=emit_output,
    )


def systemd_service_action(
    host: Host,
    *,
    unit: str,
    action: str,
    timeout: int = 45,
    sudo: bool = True,
    ignore_failure: bool = False,
    emit_output: Callable[[ShellCommandOutput], None] | None = None,
) -> dict[str, Any]:
    command = f"systemctl {action} {shlex.quote(unit)}"
    if ignore_failure:
        command = f"{command} || true"
    return run_shell_command(
        host,
        command,
        timeout=timeout,
        sudo=sudo,
        emit_output=emit_output,
    )


def systemd_enable_now(
    host: Host,
    *,
    unit: str,
    timeout: int = 45,
    sudo: bool = True,
    ignore_failure: bool = False,
    emit_output: Callable[[ShellCommandOutput], None] | None = None,
) -> dict[str, Any]:
    command = f"systemctl enable --now {shlex.quote(unit)}"
    if ignore_failure:
        command = f"{command} || true"
    return run_shell_command(
        host,
        command,
        timeout=timeout,
        sudo=sudo,
        emit_output=emit_output,
    )


def systemd_disable_now(
    host: Host,
    *,
    unit: str,
    timeout: int = 45,
    sudo: bool = True,
    ignore_failure: bool = False,
    emit_output: Callable[[ShellCommandOutput], None] | None = None,
) -> dict[str, Any]:
    command = f"systemctl disable --now {shlex.quote(unit)}"
    if ignore_failure:
        command = f"{command} || true"
    return run_shell_command(
        host,
        command,
        timeout=timeout,
        sudo=sudo,
        emit_output=emit_output,
    )


def systemd_reset_failed(
    host: Host,
    *,
    units: Sequence[str],
    timeout: int = 45,
    sudo: bool = True,
    ignore_failure: bool = True,
    emit_output: Callable[[ShellCommandOutput], None] | None = None,
) -> dict[str, Any]:
    quoted_units = " ".join(shlex.quote(unit) for unit in units)
    command = f"systemctl reset-failed {quoted_units}"
    if ignore_failure:
        command = f"{command} || true"
    return run_shell_command(
        host,
        command,
        timeout=timeout,
        sudo=sudo,
        emit_output=emit_output,
    )
