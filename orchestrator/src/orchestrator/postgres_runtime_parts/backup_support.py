import time

from ..postgres_backup import (
    resolve_backup_policy_payload as _shared_resolve_backup_policy_payload,
)
from ..postgres_backup import (
    resolve_backup_restore_payload as _shared_resolve_backup_restore_payload,
)

# ruff: noqa: F403, F405
from .service_configuration import *


def _resolve_backup_policy_payload(config, project_prefix):
    return _shared_resolve_backup_policy_payload(
        config,
        project_prefix,
        postgres_prefixed_name=_postgres_prefixed_name,
        normalize_postgres_identifier=_normalize_postgres_identifier,
    )


def _resolve_backup_restore_payload(config, project_prefix):
    return _shared_resolve_backup_restore_payload(
        config,
        project_prefix,
        postgres_prefixed_name=_postgres_prefixed_name,
        normalize_postgres_identifier=_normalize_postgres_identifier,
    )


def _wait_for_postgres_readiness(
    ctx,
    session,
    config,
    emit=None,
    is_cancelled=None,
    operation_id="service_enable",
):
    probe_command = _postgres_readiness_probe_command(config)
    diagnostics_command = _postgres_readiness_diagnostics_command(config)
    max_attempts = 45

    for attempt in range(1, max_attempts + 1):
        if callable(is_cancelled) and is_cancelled():
            return ctx.error_result(
                "ENGINE_TASK_CANCELLED",
                "Task cancelled during PostgreSQL operation",
                stage="execute_runtime_operation",
            )
        try:
            status, output = session.host.run_shell_command(
                probe_command,
                _timeout=20,
                _sudo=True,
            )
        except Exception as exc:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Verify PostgreSQL readiness failed.",
                stage="execute_runtime_operation",
                details=f"Readiness probe attempt {attempt}/{max_attempts} failed: {exc}",
                extra={"operation_id": operation_id, "action": "Verify PostgreSQL readiness"},
            )
        ctx.emit_shell_output_lines(emit, output)
        if status:
            return None

        if attempt % 10 == 0:
            ctx.emit_event(
                emit,
                "postgres_runtime_readiness_waiting",
                f"Waiting for PostgreSQL to become ready ({attempt}/{max_attempts}).",
            )
        time.sleep(2)

    try:
        diag_status, diag_output = session.host.run_shell_command(
            diagnostics_command,
            _timeout=30,
            _sudo=True,
        )
        ctx.emit_shell_output_lines(emit, diag_output)
        details = ctx.command_error_details(diag_output)
        if not details:
            details = (
                "PostgreSQL readiness probe timed out waiting for container readiness."
                if diag_status
                else "PostgreSQL readiness diagnostics command failed."
            )
    except Exception as exc:
        details = f"PostgreSQL readiness probe timed out and diagnostics failed: {exc}"

    return ctx.error_result(
        "ENGINE_RUNTIME_ERROR",
        "Verify PostgreSQL readiness failed.",
        stage="execute_runtime_operation",
        details=details,
        extra={"operation_id": operation_id, "action": "Verify PostgreSQL readiness"},
    )


__all__ = tuple(name for name in globals() if not name.startswith("__"))
