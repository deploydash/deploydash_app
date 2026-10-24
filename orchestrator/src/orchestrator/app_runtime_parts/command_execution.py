# ruff: noqa: F403, F405

from ..engine_context import SupportsAppCommandExecution
from ._shared import *


def _normalize_exec_command(command):
    if not isinstance(command, str):
        raise AppConfigValidationError("params.command must be a non-empty string.")

    normalized = command.strip()
    if not normalized:
        raise AppConfigValidationError("params.command must be a non-empty string.")
    if len(normalized) > _APP_EXEC_MAX_COMMAND_LENGTH:
        raise AppConfigValidationError("params.command must be 2000 characters or fewer.")
    return normalized


def _normalize_exec_timeout_seconds(value):
    if value is None:
        return _APP_EXEC_DEFAULT_TIMEOUT_SECONDS
    if isinstance(value, bool):
        raise AppConfigValidationError(
            "params.timeout_seconds must be an integer between 1 and 3600."
        )
    if isinstance(value, str):
        value = value.strip()
        if not value:
            raise AppConfigValidationError(
                "params.timeout_seconds must be an integer between 1 and 3600."
            )
    try:
        normalized = int(value)
    except (TypeError, ValueError):
        raise AppConfigValidationError(
            "params.timeout_seconds must be an integer between 1 and 3600."
        ) from None
    if normalized < 1 or normalized > _APP_EXEC_MAX_TIMEOUT_SECONDS:
        raise AppConfigValidationError(
            "params.timeout_seconds must be an integer between 1 and 3600."
        )
    return normalized


def _app_exec_shell_command(app_config, command, *, container_name=None):
    resolved_container_name = (
        container_name
        if isinstance(container_name, str) and container_name.strip()
        else app_config.container_name
    )
    quoted_container_name = shlex.quote(resolved_container_name)
    normalized_command = command if isinstance(command, str) else ""
    runtime_path_bootstrap = (
        "APP_EXEC_RUNTIME_PATH=\"$(tr '\\0' '\\n' </proc/1/environ | "
        "sed -n 's/^PATH=//p')\"; "
        'if [ -n "${APP_EXEC_RUNTIME_PATH}" ]; then '
        'export PATH="${APP_EXEC_RUNTIME_PATH}"; '
        "fi; "
    )
    quoted_command = shlex.quote(runtime_path_bootstrap + normalized_command)
    return (
        "APP_EXEC_STATUS=0; "
        f"if {container_process_running_check_shell(quoted_container_name)}; then "
        f"docker exec {quoted_container_name} /bin/sh -lc {quoted_command}; "
        "APP_EXEC_STATUS=$?; "
        "else "
        "echo 'App container is not running on server.' >&2; "
        "APP_EXEC_STATUS=126; "
        "fi; "
        f"echo {_APP_EXEC_EXIT_MARKER}${{APP_EXEC_STATUS}}; "
        "exit 0"
    )


def _parse_app_exec_output(output):
    stdout_lines = list(getattr(output, "stdout_lines", None) or [])
    stderr_lines = [str(line) for line in (getattr(output, "stderr_lines", None) or [])]
    filtered_stdout_lines = []
    exit_code = None

    for raw_line in stdout_lines:
        line = str(raw_line)
        stripped = line.strip()
        if stripped.startswith(_APP_EXEC_EXIT_MARKER):
            try:
                exit_code = int(stripped[len(_APP_EXEC_EXIT_MARKER) :])
            except ValueError:
                exit_code = None
            continue
        filtered_stdout_lines.append(line)

    return exit_code, filtered_stdout_lines, stderr_lines


def _emit_app_exec_output_lines(ctx: SupportsAppCommandExecution, emit, stdout_lines, stderr_lines):
    if emit is None:
        return

    for line in stdout_lines:
        normalized = ctx.sanitize_message(line)
        if normalized:
            ctx.emit_event(
                emit,
                "pyinfra_operation_stdout",
                normalized,
                level="info",
            )

    for line in stderr_lines:
        normalized = ctx.sanitize_message(line)
        if normalized:
            ctx.emit_event(
                emit,
                "pyinfra_operation_stderr",
                normalized,
                level="warning",
            )


def _emit_app_exec_result_event(
    ctx: SupportsAppCommandExecution,
    emit,
    *,
    command,
    terminal_status,
    exit_code=None,
    message=None,
    started_at=None,
    completed_at=None,
    duration_ms=None,
):
    if emit is None:
        return

    status_message = message or "Run one-off app command finished."
    ctx.emit_event(
        emit,
        "app_exec_result",
        status_message,
        level="info" if terminal_status == "success" else "warning",
        data={
            "command": command,
            "terminal_status": terminal_status,
            "exit_code": exit_code,
            "started_at": started_at.isoformat() if started_at else None,
            "completed_at": completed_at.isoformat() if completed_at else None,
            "duration_ms": duration_ms,
        },
    )


__all__ = tuple(name for name in globals() if not name.startswith("__"))
