from types import SimpleNamespace

from ..postgres_backup import (
    normalize_backup_policy_token as _normalize_backup_policy_token,
)
from ..postgres_backup import resolve_backup_destination as _resolve_backup_destination
from ..postgres_parts import parse_postgres_service_config
from .agent_access import _postgres_strip_project_prefix
from .backup_operations import handle_backup_operation
from .backup_support import (
    _resolve_backup_policy_payload,
    _resolve_backup_restore_payload,
)
from .database_lifecycle import handle_database_lifecycle
from .local_import_support import _resolve_local_sql_import_payload
from .local_sql_import import handle_local_sql_import
from .project_inventory import handle_project_inventory
from .service_configuration import (
    PostgresConfigValidationError,
    _postgres_enabled_supported_extensions,
    _postgres_enabled_unsupported_extensions,
    _postgres_project_prefix,
)
from .users_and_grants import handle_user_operation

_PROJECT_OPERATION_HANDLERS = {
    "project_list": handle_project_inventory,
    "project_list_schemas": handle_project_inventory,
    "project_list_tables": handle_project_inventory,
    "project_describe_table": handle_project_inventory,
    "project_explain_readonly_query": handle_project_inventory,
    "project_execute_readonly_query": handle_project_inventory,
    "project_create_database": handle_database_lifecycle,
    "project_create_user": handle_database_lifecycle,
    "project_delete_database": handle_database_lifecycle,
    "project_delete": handle_database_lifecycle,
    "project_normalize_database": handle_database_lifecycle,
    "project_rotate_password": handle_user_operation,
    "project_delete_user": handle_user_operation,
    "backup_policy_apply": handle_backup_operation,
    "backup_policy_delete": handle_backup_operation,
    "backup_destination_test": handle_backup_operation,
    "backup_run_now": handle_backup_operation,
    "backup_artifact_list": handle_backup_operation,
    "backup_backlog_report": handle_backup_operation,
    "backup_backlog_cleanup": handle_backup_operation,
    "restore_run_now": handle_backup_operation,
    "import_local_sql": handle_local_sql_import,
}


def run_project_operation(
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
    # project_delete and project_normalize_database dry runs read live
    # state, so they need a session and credentials like an execute does;
    # every other dry run stays offline.
    if (not dry_run or operation_id in ("project_delete", "project_normalize_database")) and (
        not isinstance(postgres_config.superuser_password, str)
        or not postgres_config.superuser_password.strip()
    ):
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Database service credentials are missing in local settings. "
            "Configure Database service from Server management and try again.",
            stage="validate_request",
        )

    try:
        project_prefix = _postgres_project_prefix(postgres_config.project_slug)
    except PostgresConfigValidationError as exc:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            str(exc),
            stage="validate_request",
        )

    if dry_run and operation_id not in ("project_delete", "project_normalize_database"):
        response = {
            "status": "success",
            "code": "OK",
            "msg": f"PostgreSQL project operation '{operation_id}' plan ready",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "project_prefix": project_prefix,
            "enabled_extensions": list(
                _postgres_enabled_supported_extensions(postgres_config),
            ),
        }
        if operation_id in (
            "backup_policy_apply",
            "backup_policy_delete",
            "backup_destination_test",
            "backup_run_now",
            "backup_artifact_list",
            "backup_backlog_report",
            "backup_backlog_cleanup",
            "restore_run_now",
            "import_local_sql",
        ):
            try:
                if operation_id == "restore_run_now":
                    restore_payload = _resolve_backup_restore_payload(
                        postgres_config,
                        project_prefix,
                    )
                    response["database_name"] = _postgres_strip_project_prefix(
                        project_prefix,
                        restore_payload["target_database_name"],
                    )
                    response["restore_target_database_name"] = restore_payload[
                        "target_database_name"
                    ]
                    response["backup_artifact_path"] = restore_payload["artifact_path"]
                    response["backup_destination_type"] = restore_payload["destination"]["type"]
                elif operation_id == "import_local_sql":
                    import_payload = _resolve_local_sql_import_payload(
                        postgres_config,
                        project_prefix,
                        validate_local_file=False,
                    )
                    response["database_name"] = _postgres_strip_project_prefix(
                        project_prefix,
                        import_payload["database_name"],
                    )
                    response["remote_database_name"] = import_payload["database_name"]
                    response["target_database_name"] = import_payload["database_name"]
                    response["import_local_file_path"] = import_payload["local_file_path"]
                elif operation_id == "backup_policy_delete":
                    response["backup_policy_id"] = _normalize_backup_policy_token(
                        postgres_config.backup_policy_id,
                        "settings.backup_policy_id",
                    )
                elif operation_id == "backup_destination_test":
                    destination = _resolve_backup_destination(postgres_config)
                    response["backup_destination_type"] = destination["type"]
                else:
                    backup_payload = _resolve_backup_policy_payload(
                        postgres_config,
                        project_prefix,
                    )
                    response["backup_policy_id"] = backup_payload["policy_token"]
                    response["backup_task_id"] = backup_payload["task_token"]
                    response["backup_database_name"] = backup_payload["database_name"]
                    response["backup_destination_type"] = backup_payload["destination"]["type"]
            except PostgresConfigValidationError as exc:
                return ctx.error_result(
                    "ENGINE_VALIDATION_ERROR",
                    str(exc),
                    stage="validate_request",
                )
        return response

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
    request = SimpleNamespace(
        ctx=ctx,
        operation_id=operation_id,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        postgres_config=postgres_config,
        project_prefix=project_prefix,
        session=session,
        emit=emit,
        is_cancelled=is_cancelled,
    )
    try:
        handler = _PROJECT_OPERATION_HANDLERS.get(operation_id)
        if handler is None:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                f"Unknown PostgreSQL project operation: {operation_id}",
                stage="validate_request",
            )
        return handler(request)
    except PostgresConfigValidationError as exc:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            str(exc),
            stage="validate_request",
        )
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
