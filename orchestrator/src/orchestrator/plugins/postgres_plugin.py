from functools import partial
from typing import Any

from ..contracts import EmitFn
from ..engine_context import SupportsPostgresPlugin
from .base import WorkflowPlugin, bind_operation


def build_plugin(
    *,
    operations: dict[str, dict[str, Any]],
    ctx: SupportsPostgresPlugin,
) -> WorkflowPlugin:
    describe_postgres = ctx.describe_postgres
    extract_postgres_settings_payload = ctx.extract_postgres_settings_payload
    emit_event = ctx.emit_event
    run_postgres_runtime_operation = ctx.run_postgres_runtime_operation
    run_postgres_project_operation = ctx.run_postgres_project_operation

    def handle_describe(
        data: dict[str, Any], emit: EmitFn | None = None, **_: Any
    ) -> dict[str, Any]:
        response: dict[str, Any] = describe_postgres(
            raw_data=extract_postgres_settings_payload(data),
        )
        if response.get("status") == "success":
            emit_event(
                emit,
                "postgres_plan_ready",
                "Database service plan described.",
                data={
                    "selected_version": response.get("selected_version"),
                    "supported_versions": response.get("supported_versions"),
                },
            )
        else:
            emit_event(
                emit,
                "validation_error",
                response.get("msg", "Invalid PostgreSQL plan request"),
                level="error",
            )
        return response

    _service = partial(
        bind_operation,
        ctx,
        runner=run_postgres_runtime_operation,
        settings_extractor=extract_postgres_settings_payload,
    )

    _project = partial(
        bind_operation,
        ctx,
        runner=run_postgres_project_operation,
        settings_extractor=extract_postgres_settings_payload,
    )

    handlers = {
        "describe": handle_describe,
        "run": _service("service_enable"),
        "service_enable": _service("service_enable"),
        "service_start": _service("service_start"),
        "service_stop": _service("service_stop"),
        "service_restart": _service("service_restart"),
        "service_configure": _service("service_configure"),
        "service_status": _service("service_status"),
        "service_delete": _service("service_delete"),
        "service_migrate_storage": _service("service_migrate_storage"),
        "service_remove_legacy_storage": _service("service_remove_legacy_storage"),
        "service_upgrade_major": _service("service_upgrade_major"),
        "project_list": _project("project_list"),
        "project_list_schemas": _project("project_list_schemas"),
        "project_list_tables": _project("project_list_tables"),
        "project_describe_table": _project("project_describe_table"),
        "project_explain_readonly_query": _project("project_explain_readonly_query"),
        "project_execute_readonly_query": _project("project_execute_readonly_query"),
        "project_create_database": _project("project_create_database"),
        "project_create_user": _project("project_create_user"),
        "project_delete_database": _project("project_delete_database"),
        "project_rotate_password": _project("project_rotate_password"),
        "project_delete_user": _project("project_delete_user"),
        "project_delete": _project("project_delete"),
        "project_normalize_database": _project("project_normalize_database"),
        "backup_policy_apply": _project("backup_policy_apply"),
        "backup_policy_delete": _project("backup_policy_delete"),
        "backup_destination_test": _project("backup_destination_test"),
        "backup_run_now": _project("backup_run_now"),
        "backup_artifact_list": _project("backup_artifact_list"),
        "backup_backlog_report": _project("backup_backlog_report"),
        "backup_backlog_cleanup": _project("backup_backlog_cleanup"),
        "restore_run_now": _project("restore_run_now"),
        "import_local_sql": _project("import_local_sql"),
    }

    return WorkflowPlugin(
        workflow_id="postgres",
        operations=operations,
        handlers=handlers,
    )
