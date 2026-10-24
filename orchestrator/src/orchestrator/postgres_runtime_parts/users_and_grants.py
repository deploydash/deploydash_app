# ruff: noqa: F403, F405
from .agent_access import *
from .backup_support import *
from .local_import_support import *
from .project_registry import (
    _REGISTRY_DATABASES_TABLE,
    _postgres_registry_lookup_sql,
    _postgres_registry_unregister_role_sql,
    _require_postgres_resource_owners,
)
from .service_configuration import *


def handle_user_operation(request):
    ctx = request.ctx
    operation_id = request.operation_id
    postgres_config = request.postgres_config
    project_prefix = request.project_prefix
    session = request.session
    emit = request.emit
    is_cancelled = request.is_cancelled

    if operation_id == "project_rotate_password":
        if postgres_config.username is None:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "settings.username is required.",
                stage="validate_request",
            )
        username_name = _postgres_prefixed_name(
            project_prefix,
            postgres_config.username,
            "settings.username",
        )
        ownership_error = _require_postgres_resource_owners(
            ctx,
            session,
            postgres_config,
            emit,
            owned=(("user", username_name),),
        )
        if ownership_error is not None:
            return ownership_error
        new_password = postgres_config.password or _postgres_generated_password()
        sql = (
            f"ALTER ROLE {_postgres_sql_identifier(username_name)} "
            f"LOGIN PASSWORD {_postgres_sql_literal(new_password)};"
        )
        status, output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            sql,
            emit=emit,
        )
        if not status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not rotate user password.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(output) or "remote command failed",
            )
        return {
            "status": "success",
            "code": "OK",
            "msg": "Database user password rotated.",
            "operation_id": operation_id,
            "username": _postgres_strip_project_prefix(
                project_prefix,
                username_name,
            ),
            "remote_username": username_name,
            "password": new_password,
        }

    if operation_id == "project_delete_user":
        if postgres_config.username is None:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "settings.username is required.",
                stage="validate_request",
            )
        username_name = _postgres_prefixed_name(
            project_prefix,
            postgres_config.username,
            "settings.username",
        )
        explicit_database_name = None
        owned_names = [("user", username_name)]
        if postgres_config.database_name is not None:
            explicit_database_name = _postgres_prefixed_name(
                project_prefix,
                postgres_config.database_name,
                "settings.database_name",
            )
            owned_names.append(("database", explicit_database_name))
        ownership_error = _require_postgres_resource_owners(
            ctx,
            session,
            postgres_config,
            emit,
            owned=owned_names,
        )
        if ownership_error is not None:
            return ownership_error
        if explicit_database_name is None:
            list_db_sql = _postgres_registry_lookup_sql(
                _REGISTRY_DATABASES_TABLE,
                "datname",
                "project_slug",
                postgres_config.project_slug,
            )
            db_status, db_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                list_db_sql,
                emit=emit,
            )
            if not db_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not inspect project databases.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(db_output) or "remote command failed",
                )
            db_lines = getattr(db_output, "stdout_lines", None) or []
            database_names = [
                str(line).strip()
                for line in db_lines
                if isinstance(line, str) and str(line).strip()
            ]
        else:
            database_names = [explicit_database_name]
        for database_name in database_names:
            if callable(is_cancelled) and is_cancelled():
                return ctx.error_result(
                    "ENGINE_TASK_CANCELLED",
                    "Task cancelled during PostgreSQL operation",
                    stage="execute_runtime_operation",
                )
            sql = _postgres_reassign_owned_if_exists_sql(username_name)
            cleanup_status, cleanup_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                sql,
                database=database_name,
                emit=emit,
            )
            if not cleanup_status:
                cleanup_details = (
                    ctx.command_error_details(cleanup_output) or "remote command failed"
                )
                cleanup_lowered = cleanup_details.lower()
                if (
                    "does not exist" in cleanup_lowered
                    or "not exist" in cleanup_lowered
                    or "not found" in cleanup_lowered
                ):
                    continue
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not remove user grants from project database.",
                    stage="execute_runtime_operation",
                    details=cleanup_details,
                )

        drop_sql = f"DROP ROLE IF EXISTS {_postgres_sql_identifier(username_name)};"
        drop_status, drop_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            drop_sql,
            emit=emit,
        )
        if not drop_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not remove database user.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(drop_output) or "remote command failed",
            )
        unregister_sql = _postgres_registry_unregister_role_sql(username_name)
        unregister_status, unregister_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            unregister_sql,
            emit=emit,
        )
        if not unregister_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not remove user registration.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(unregister_output) or "remote command failed",
            )
        return {
            "status": "success",
            "code": "OK",
            "msg": "Database user removed.",
            "operation_id": operation_id,
            "database_name": (
                _postgres_strip_project_prefix(project_prefix, database_names[0])
                if len(database_names) == 1
                else None
            ),
            "deleted_database_name": (
                _postgres_strip_project_prefix(project_prefix, database_names[0])
                if len(database_names) == 1
                else None
            ),
            "remote_database_name": (database_names[0] if len(database_names) == 1 else None),
            "deleted_remote_database_name": (
                database_names[0] if len(database_names) == 1 else None
            ),
            "username": _postgres_strip_project_prefix(
                project_prefix,
                username_name,
            ),
            "deleted_username": _postgres_strip_project_prefix(
                project_prefix,
                username_name,
            ),
            "remote_username": username_name,
            "deleted_remote_username": username_name,
        }


__all__ = tuple(name for name in globals() if not name.startswith("__"))
