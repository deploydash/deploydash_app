from .. import settings_ownership
from ..postgres_backup import (
    postgres_parse_backup_policy_cleanup_output as _postgres_parse_backup_policy_cleanup_output,
)
from ..postgres_backup import (
    postgres_service_backup_policies_delete_command as _postgres_service_backup_policies_delete_command,
)
from ..postgres_parts import SUPPORTED_POSTGRES_VERSIONS, parse_postgres_service_config
from ..postgres_parts.postgres_config import RESOLVED_POSTGRES_DEFAULTS
from ..runtime_ops import run_shell_command
from .agent_access import _parse_postgres_service_status_output

# ruff: noqa: F403, F405
from .backup_support import *
from .service_configuration import *
from .service_storage import (
    _STORAGE_MIGRATE_ACTION_LABEL,
    _STORAGE_REMOVE_ACTION_LABEL,
    _postgres_find_pgdata_source_volume,
    _postgres_parse_storage_mounts,
    _postgres_storage_inspect_mounts_command,
    enrich_postgres_service_status,
    run_postgres_legacy_storage_removal,
    run_postgres_storage_migration,
)
from .service_upgrade import (
    _UPGRADE_ACTION_LABEL,
    refuse_postgres_major_version_change,
    run_postgres_major_upgrade,
)


def run_postgres_runtime_operation(
    ctx,
    operation_id,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    raw_data=None,
    emit=None,
    is_cancelled=None,
):
    if callable(is_cancelled) and is_cancelled():
        return ctx.error_result(
            "ENGINE_TASK_CANCELLED",
            "Task cancelled before execution started",
            stage="preflight",
        )

    try:
        postgres_config = parse_postgres_service_config(raw_data)
    except PostgresConfigValidationError as exc:
        ctx.emit_event(emit, "validation_error", str(exc), level="error")
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            str(exc),
            stage="validate_request",
        )
    unsupported_extensions = _postgres_enabled_unsupported_extensions(
        postgres_config,
    )
    if unsupported_extensions:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Selected PostgreSQL extensions are not currently supported: "
            + ", ".join(unsupported_extensions)
            + ".",
            stage="validate_request",
        )
    if (
        not dry_run
        and operation_id in ("service_enable", "service_configure")
        and (
            not isinstance(postgres_config.superuser_password, str)
            or not postgres_config.superuser_password.strip()
        )
    ):
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Database service credentials are missing in local settings. "
            "Configure Database service from Server management and try again.",
            stage="validate_request",
        )

    quoted_compose_file = shlex.quote(f"{postgres_config.stack_root}/docker-compose.yml")
    quoted_container_name = shlex.quote(postgres_config.container_name)
    service_setup = _postgres_base_env_bootstrap_command(
        postgres_config,
    ) + _postgres_compose_apply_command(postgres_config)

    operation_steps = {
        "service_enable": [
            (
                "Build PostgreSQL extension image",
                _postgres_extension_image_build_command(postgres_config),
                False,
            ),
            ("Prepare PostgreSQL service", service_setup, False),
            ("Verify PostgreSQL readiness", _postgres_readiness_command(postgres_config), False),
            (
                "Sync PostgreSQL superuser credentials",
                _postgres_sync_superuser_command(postgres_config),
                False,
            ),
            (
                "Apply PostgreSQL extensions",
                _postgres_apply_extensions_command(postgres_config),
                False,
            ),
        ],
        "service_configure": [
            (
                "Build PostgreSQL extension image",
                _postgres_extension_image_build_command(postgres_config),
                False,
            ),
            ("Apply PostgreSQL configuration", service_setup, False),
            ("Verify PostgreSQL readiness", _postgres_readiness_command(postgres_config), False),
            (
                "Sync PostgreSQL superuser credentials",
                _postgres_sync_superuser_command(postgres_config),
                False,
            ),
            (
                "Apply PostgreSQL extensions",
                _postgres_apply_extensions_command(postgres_config),
                False,
            ),
        ],
        "service_start": [
            (
                "Build PostgreSQL extension image",
                _postgres_extension_image_build_command(postgres_config),
                False,
            ),
            (
                "Start PostgreSQL container",
                "set -eu; "
                f"COMPOSE_FILE={quoted_compose_file}; "
                "if docker compose version >/dev/null 2>&1; then "
                'docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans; '
                "elif command -v docker-compose >/dev/null 2>&1; then "
                'docker-compose -f "${COMPOSE_FILE}" up -d --remove-orphans; '
                "else "
                "echo 'docker compose is unavailable.' >&2; "
                "exit 1; "
                "fi",
                False,
            ),
            ("Verify PostgreSQL readiness", _postgres_readiness_command(postgres_config), False),
        ],
        "service_stop": [
            (
                "Stop PostgreSQL container",
                f"if {container_process_running_check_shell(quoted_container_name)}; then "
                f"docker stop {quoted_container_name}; "
                "else "
                "echo 'PostgreSQL container is already stopped.'; "
                "fi",
                True,
            ),
        ],
        "service_restart": [
            (
                "Restart PostgreSQL container",
                f"{container_process_running_check_shell(quoted_container_name)} || "
                "(echo 'PostgreSQL container is not running. Start it first.' >&2; exit 1); "
                f"docker restart {quoted_container_name}",
                False,
            ),
            ("Verify PostgreSQL readiness", _postgres_readiness_command(postgres_config), False),
        ],
        "service_delete": [
            # coverage-gate: postgres_service_delete_cleanup_plan
            (
                "Delete PostgreSQL backup policies",
                _postgres_service_backup_policies_delete_command(postgres_config),
                False,
            ),
            # end coverage-gate
            (
                "Delete PostgreSQL service data and container",
                "set -eu; "
                f"STACK_ROOT={shlex.quote(postgres_config.stack_root)}; "
                f"CONTAINER_NAME={quoted_container_name}; "
                'COMPOSE_FILE="${STACK_ROOT}/docker-compose.yml"; '
                'if [ -f "${COMPOSE_FILE}" ]; then '
                "if docker compose version >/dev/null 2>&1; then "
                'docker compose -f "${COMPOSE_FILE}" down --remove-orphans --volumes >/dev/null 2>&1 || true; '
                "elif command -v docker-compose >/dev/null 2>&1; then "
                'docker-compose -f "${COMPOSE_FILE}" down --remove-orphans --volumes >/dev/null 2>&1 || true; '
                "fi; "
                "fi; "
                'docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true; '
                'rm -rf "${STACK_ROOT}"',
                False,
            ),
        ],
        "service_status": [
            (
                "Collect PostgreSQL service status",
                _postgres_service_status_command(postgres_config),
                True,
            ),
        ],
        "service_migrate_storage": [
            (_STORAGE_MIGRATE_ACTION_LABEL, None, False),
        ],
        "service_remove_legacy_storage": [
            (_STORAGE_REMOVE_ACTION_LABEL, None, False),
        ],
        "service_upgrade_major": [
            (_UPGRADE_ACTION_LABEL, None, False),
        ],
    }

    if operation_id not in operation_steps:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Unknown PostgreSQL runtime operation: {operation_id}",
            stage="validate_request",
        )

    if dry_run:
        return {
            "status": "success",
            "code": "OK",
            "msg": f"PostgreSQL runtime operation '{operation_id}' plan ready",
            "operation_id": operation_id,
            "actions": [step[0] for step in operation_steps[operation_id]],
            "selected_version": postgres_config.postgres_version,
            "selected_image": _postgres_runtime_image_name(postgres_config),
            "supported_versions": list(SUPPORTED_POSTGRES_VERSIONS),
            "enabled_extensions": list(
                _postgres_enabled_supported_extensions(postgres_config),
            ),
            "resolved_config": settings_ownership.resolved_config_snapshot(
                postgres_config, RESOLVED_POSTGRES_DEFAULTS
            ),
        }

    opened = ctx.open_runtime_session(
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        needs_sudo=True,
        emit=emit,
    )
    if not opened["ok"]:
        return opened["error"]

    session = opened["session"]
    service_status = None
    # coverage-gate: postgres_service_delete_cleanup_state
    removed_backup_policies = []
    # end coverage-gate
    try:
        # coverage-gate: major_version_guard
        if operation_id in ("service_enable", "service_configure"):
            guard_refusal = refuse_postgres_major_version_change(
                ctx,
                session,
                postgres_config,
                emit=emit,
                operation_id=operation_id,
            )
            if guard_refusal is not None:
                return guard_refusal
        # end coverage-gate
        # coverage-gate: preserve_live_data_volume
        if operation_id in ("service_enable", "service_configure"):
            live_volume_name = None
            try:
                inspect_result = run_shell_command(
                    session.host,
                    _postgres_storage_inspect_mounts_command(postgres_config),
                    timeout=60,
                    sudo=True,
                )
            except Exception:
                inspect_result = {"ok": False, "output": None}
            if inspect_result["ok"]:
                inspect_output = inspect_result["output"]
                ctx.emit_shell_output_lines(emit, inspect_output)
                try:
                    live_mounts = _postgres_parse_storage_mounts(inspect_output)
                except ValueError:
                    return ctx.error_result(
                        "ENGINE_RUNTIME_ERROR",
                        "Could not preserve the live PostgreSQL data volume.",
                        stage="execute_runtime_operation",
                        details="The container mounts were not valid JSON.",
                        extra={"operation_id": operation_id},
                    )
                live_mount = _postgres_find_pgdata_source_volume(
                    live_mounts,
                    _postgres_pgdata_path(postgres_config),
                )
                if live_mount is not None:
                    live_volume_name = live_mount.get("Name") or None
            setup_label = (
                "Prepare PostgreSQL service"
                if operation_id == "service_enable"
                else "Apply PostgreSQL configuration"
            )
            operation_steps[operation_id][1] = (
                setup_label,
                _postgres_base_env_bootstrap_command(
                    postgres_config,
                    data_volume_name=live_volume_name,
                )
                + _postgres_compose_apply_command(postgres_config),
                False,
            )
        # end coverage-gate
        ctx.emit_event(
            emit,
            "postgres_runtime_plan_ready",
            f"PostgreSQL operation '{operation_id}' prepared.",
            data={"operation_id": operation_id},
        )
        for label, command, allow_failure in operation_steps[operation_id]:
            if callable(is_cancelled) and is_cancelled():
                return ctx.error_result(
                    "ENGINE_TASK_CANCELLED",
                    "Task cancelled during PostgreSQL operation",
                    stage="execute_runtime_operation",
                )
            ctx.emit_event(emit, "postgres_runtime_action_started", f"{label}: started")
            if label == _STORAGE_MIGRATE_ACTION_LABEL:
                return run_postgres_storage_migration(
                    ctx,
                    session,
                    postgres_config,
                    emit=emit,
                    is_cancelled=is_cancelled,
                    operation_id=operation_id,
                )
            if label == _STORAGE_REMOVE_ACTION_LABEL:
                return run_postgres_legacy_storage_removal(
                    ctx,
                    session,
                    postgres_config,
                    emit=emit,
                    is_cancelled=is_cancelled,
                    operation_id=operation_id,
                )
            # coverage-gate: major_upgrade_dispatch
            if label == _UPGRADE_ACTION_LABEL:
                return run_postgres_major_upgrade(
                    ctx,
                    session,
                    postgres_config,
                    emit=emit,
                    is_cancelled=is_cancelled,
                    operation_id=operation_id,
                )
            # end coverage-gate
            if label == "Verify PostgreSQL readiness":
                readiness_error = _wait_for_postgres_readiness(
                    ctx,
                    session,
                    postgres_config,
                    emit=emit,
                    is_cancelled=is_cancelled,
                    operation_id=operation_id,
                )
                if readiness_error is not None:
                    return readiness_error
                ctx.emit_event(
                    emit,
                    "postgres_runtime_action_completed",
                    f"{label}: completed",
                )
                continue
            try:
                status, output = session.host.run_shell_command(
                    command,
                    _timeout=300,
                    _sudo=True,
                )
            except Exception as exc:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    f"{label} failed.",
                    stage="execute_runtime_operation",
                    details=str(exc),
                    extra={"operation_id": operation_id, "action": label},
                )
            ctx.emit_shell_output_lines(emit, output)
            # coverage-gate: postgres_service_delete_cleanup_parse
            if operation_id == "service_delete":
                removed_backup_policies.extend(
                    _postgres_parse_backup_policy_cleanup_output(output),
                )
            # end coverage-gate
            if operation_id == "service_status":
                service_status = _parse_postgres_service_status_output(output)
                # coverage-gate: storage_status_enrich
                service_status = enrich_postgres_service_status(
                    ctx,
                    session,
                    postgres_config,
                    emit=emit,
                    operation_id=operation_id,
                    base_status=service_status,
                )
                # end coverage-gate
            if not status and not allow_failure:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    f"{label} failed.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(output) or "remote command failed",
                    extra={"operation_id": operation_id, "action": label},
                )
            ctx.emit_event(
                emit,
                "postgres_runtime_action_completed",
                f"{label}: completed",
            )

        response = {
            "status": "success",
            "code": "OK",
            "operation_id": operation_id,
            "selected_version": postgres_config.postgres_version,
            "selected_image": _postgres_runtime_image_name(postgres_config),
            "enabled_extensions": list(
                _postgres_enabled_supported_extensions(postgres_config),
            ),
        }
        if operation_id == "service_status":
            response["msg"] = "Database service status collected."
            response["service_status"] = service_status or {
                "running": False,
                "health": "down",
                "version": None,
                "configured": False,
            }
        else:
            response["msg"] = "Database service operation completed."
        # coverage-gate: postgres_service_delete_cleanup_response
        if operation_id == "service_delete":
            response["removed_backup_policies"] = removed_backup_policies
            response["removed_backup_policy_count"] = len(removed_backup_policies)
            response["backup_logs_removed"] = True
        # end coverage-gate
        return response
    finally:
        close_result = session.close()
        disconnect_error = close_result.get("disconnect_error")
        if disconnect_error:
            ctx.emit_event(
                emit,
                "connection_disconnect_error",
                disconnect_error,
                level="warning",
            )


__all__ = tuple(name for name in globals() if not name.startswith("__"))
