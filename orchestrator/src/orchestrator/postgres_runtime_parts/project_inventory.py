import json

from .. import server_identifiers

# ruff: noqa: F403, F405
from .agent_access import *
from .backup_support import *
from .local_import_support import *
from .project_registry import (
    _PROJECT_USER_ROLE_KINDS,
    _REGISTRY_DATABASES_TABLE,
    _describe_postgres_registry_leftovers,
    _ensure_postgres_project_registry,
    _postgres_registry_list_roles_sql,
    _postgres_registry_lookup_sql,
    _postgres_registry_register_role_sql,
    _require_postgres_resource_owners,
)
from .service_configuration import *
from .service_storage import enrich_postgres_service_status


def _project_list_not_ready_result(postgres_config, operation_id, service_status):
    """Keep unavailable inventory responses stable across readiness checks."""
    return {
        "status": "success",
        "code": "OK",
        "msg": "Database service is not ready.",
        "operation_id": operation_id,
        "project_slug": postgres_config.project_slug,
        "databases": [],
        "users": [],
        "service_status": service_status,
    }


def handle_project_inventory(request):
    ctx = request.ctx
    operation_id = request.operation_id
    ip = request.ip
    postgres_config = request.postgres_config
    project_prefix = request.project_prefix
    session = request.session
    emit = request.emit
    is_cancelled = request.is_cancelled

    if operation_id == "project_list":
        service_status, status_error = _postgres_collect_service_status(
            ctx,
            session,
            postgres_config,
            emit,
            operation_id,
        )
        if status_error is not None:
            return status_error
        # coverage-gate: project_list_base_readiness
        if not _postgres_service_is_ready(service_status):
            return _project_list_not_ready_result(
                postgres_config,
                operation_id,
                service_status,
            )
        # end coverage-gate

        if callable(is_cancelled) and is_cancelled():
            return ctx.error_result(
                "ENGINE_TASK_CANCELLED",
                "Task cancelled during PostgreSQL operation",
                stage="execute_runtime_operation",
            )

        registry_error = _ensure_postgres_project_registry(
            ctx,
            session,
            postgres_config,
            emit,
        )
        if registry_error is not None:
            return registry_error

        # coverage-gate: project_list_storage_enrichment
        service_status = enrich_postgres_service_status(
            ctx,
            session,
            postgres_config,
            emit=emit,
            operation_id=operation_id,
            base_status=service_status,
        )
        if not _postgres_service_is_ready(service_status):
            return _project_list_not_ready_result(
                postgres_config,
                operation_id,
                service_status,
            )
        # end coverage-gate

        db_sql = _postgres_registry_lookup_sql(
            _REGISTRY_DATABASES_TABLE,
            "datname",
            "project_slug",
            postgres_config.project_slug,
        )
        db_status, db_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            db_sql,
            emit=emit,
        )
        # coverage-gate: project_list_registry_flow
        if not db_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not list project databases.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(db_output) or "remote command failed",
            )

        roles_sql = _postgres_registry_list_roles_sql(postgres_config.project_slug)
        roles_status, roles_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            roles_sql,
            emit=emit,
        )
        if not roles_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not list project database users.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(roles_output) or "remote command failed",
            )

        engine_version = _postgres_collect_engine_version(
            ctx,
            session,
            postgres_config,
            emit=emit,
        )

        db_lines = getattr(db_output, "stdout_lines", None) or []
        roles_lines = getattr(roles_output, "stdout_lines", None) or []
        databases = [
            str(line).strip() for line in db_lines if isinstance(line, str) and str(line).strip()
        ]
        users = []
        if roles_lines:
            try:
                parsed = json.loads(str(roles_lines[-1]).strip() or "[]")
                if isinstance(parsed, list):
                    for item in parsed:
                        if not isinstance(item, dict):
                            continue
                        username_value = item.get("username")
                        if not isinstance(username_value, str):
                            continue
                        role_kind_value = item.get("role_kind")
                        if (
                            role_kind_value is not None
                            and role_kind_value not in _PROJECT_USER_ROLE_KINDS
                        ):
                            continue
                        database_value = item.get("database")
                        access_value = item.get("access_mode")
                        users.append(
                            {
                                "username": username_value,
                                "database": (
                                    database_value if isinstance(database_value, str) else None
                                ),
                                "access_mode": (
                                    access_value
                                    if access_value in ("read_write", "read_only")
                                    else "read_write"
                                ),
                            },
                        )
            except json.JSONDecodeError:
                users = []

        leftovers_error, leftovers = _describe_postgres_registry_leftovers(
            ctx,
            session,
            postgres_config,
            emit,
        )
        if leftovers_error is not None:
            return leftovers_error
        # end coverage-gate

        return {
            "status": "success",
            "code": "OK",
            "msg": "Project database resources listed.",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "project_prefix": project_prefix,
            "databases": databases,
            "users": users,
            "unassigned_databases": leftovers["unassigned_databases"],
            "ownership_conflicts": leftovers["ownership_conflicts"],
            "service_status": service_status,
            "engine_version": engine_version,
            "host": ip,
            "port": postgres_config.host_port,
        }

    if operation_id in (
        "project_list_schemas",
        "project_list_tables",
        "project_describe_table",
        "project_explain_readonly_query",
        "project_execute_readonly_query",
    ):
        if postgres_config.database_name is None:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "settings.database_name is required.",
                stage="validate_request",
            )
        database_name = _postgres_prefixed_name(
            project_prefix,
            postgres_config.database_name,
            "settings.database_name",
        )
        # Every tool query below logs in as the per-database reader, never
        # the superuser; only the readiness and existence preamble still
        # runs as the superuser (#83).
        reader_name = server_identifiers.postgres_agent_reader_role_name(database_name)
        service_status, status_error = _postgres_collect_service_status(
            ctx,
            session,
            postgres_config,
            emit,
            operation_id,
        )
        if status_error is not None:
            return status_error
        if not _postgres_service_is_ready(service_status):
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Database service is not ready.",
                stage="execute_runtime_operation",
                details=("The managed PostgreSQL service has not reached its ready state."),
                extra={
                    "service_status": service_status,
                    "operation_id": operation_id,
                },
            )
        database_exists, database_error = _postgres_database_exists(
            ctx,
            session,
            postgres_config,
            database_name,
            emit,
        )
        if database_error is not None:
            database_error.setdefault("extra", {})
            database_error["extra"].update(
                {
                    "service_status": service_status,
                    "host": ip,
                    "port": postgres_config.host_port,
                }
            )
            return database_error
        if not database_exists:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "The selected project database does not exist.",
                stage="validate_request",
                details=database_name,
                extra={
                    "service_status": service_status,
                    "host": ip,
                    "port": postgres_config.host_port,
                },
            )
        ownership_error = _require_postgres_resource_owners(
            ctx,
            session,
            postgres_config,
            emit,
            owned=(("database", database_name),),
        )
        if ownership_error is not None:
            return ownership_error

        # coverage-gate: agent_reader_lazy_ensure
        # The reader is ensured on the first agent query, so adopted
        # databases that never ran creation gain it too. The owner role is
        # ensured bare first: the reader's FOR ROLE default privileges need
        # it to exist, without moving any ownership. Every statement here
        # is idempotent, so a failed ensure simply re-converges on the next
        # call and nothing needs rolling back (#83).
        registry_error = _ensure_postgres_project_registry(
            ctx,
            session,
            postgres_config,
            emit,
        )
        if registry_error is not None:
            return registry_error
        owner_name = server_identifiers.postgres_owner_role_name(database_name)
        lazy_reader_sql = " ".join(
            [
                _postgres_ensure_owner_role_sql(owner_name),
                _postgres_ensure_agent_reader_role_sql(reader_name),
                _postgres_agent_reader_grants_sql(database_name, owner_name, reader_name),
            ]
        )
        lazy_reader_status, lazy_reader_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            lazy_reader_sql,
            database=database_name,
            emit=emit,
        )
        if not lazy_reader_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not provision agent reader role.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(lazy_reader_output) or "remote command failed",
            )
        lazy_register_sql = _postgres_registry_register_role_sql(
            reader_name,
            postgres_config.project_slug,
            datname=database_name,
            access_mode="read_only",
            role_kind="agent_reader",
        )
        lazy_register_status, lazy_register_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            lazy_register_sql,
            emit=emit,
        )
        if not lazy_register_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not provision agent reader role.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(lazy_register_output) or "remote command failed",
            )
        # end coverage-gate

        engine_version = _postgres_collect_engine_version(
            ctx,
            session,
            postgres_config,
            emit=emit,
        )
        logical_database_name = _postgres_strip_project_prefix(
            project_prefix,
            database_name,
        )
        base_response = {
            "status": "success",
            "code": "OK",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "project_prefix": project_prefix,
            "database_name": logical_database_name,
            "remote_database_name": database_name,
            "service_status": service_status,
            "engine_version": engine_version,
            "host": ip,
            "port": postgres_config.host_port,
        }

        if operation_id == "project_list_schemas":
            schema_sql = (
                "SELECT COALESCE(json_agg(schema_name ORDER BY sort_order, schema_name), "
                "'[]'::json)::text "
                "FROM ("
                "SELECT nspname AS schema_name, "
                "CASE WHEN nspname = 'public' THEN 0 ELSE 1 END AS sort_order "
                "FROM pg_namespace "
                "WHERE nspname <> 'pg_catalog' "
                "AND nspname <> 'information_schema' "
                "AND nspname <> 'pg_toast' "
                "AND nspname NOT LIKE 'pg_temp_%' "
                "AND nspname NOT LIKE 'pg_toast_temp_%'"
                ") AS schemas;"
            )
            schema_status, schema_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                schema_sql,
                database=database_name,
                emit=emit,
                run_as_user=reader_name,
            )
            if not schema_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not list project database schemas.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(schema_output) or "remote command failed",
                )
            schemas = []
            schema_lines = getattr(schema_output, "stdout_lines", None) or []
            if schema_lines:
                try:
                    parsed = json.loads(str(schema_lines[-1]).strip() or "[]")
                    if isinstance(parsed, list):
                        schemas = [str(item) for item in parsed if isinstance(item, str)]
                except json.JSONDecodeError:
                    schemas = []
            return {
                **base_response,
                "msg": "Project database schemas listed.",
                "schemas": schemas,
            }

        if operation_id == "project_list_tables":
            schema_name = postgres_config.schema_name
            schema_filter = ""
            if schema_name is not None:
                normalized_schema = schema_name.strip()
                schema_filter = f" AND n.nspname = {_postgres_sql_literal(normalized_schema)}"
            table_sql = (
                "SELECT COALESCE(json_agg("
                "json_build_object("
                "'schema_name', n.nspname, "
                "'table_name', c.relname, "
                "'object_type', CASE c.relkind "
                "WHEN 'r' THEN 'table' "
                "WHEN 'p' THEN 'partitioned_table' "
                "WHEN 'v' THEN 'view' "
                "WHEN 'm' THEN 'materialized_view' "
                "WHEN 'f' THEN 'foreign_table' "
                "ELSE 'other' END"
                ") ORDER BY n.nspname, c.relname"
                "), '[]'::json)::text "
                "FROM pg_class c "
                "JOIN pg_namespace n ON n.oid = c.relnamespace "
                "WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') "
                "AND n.nspname <> 'pg_catalog' "
                "AND n.nspname <> 'information_schema' "
                "AND n.nspname <> 'pg_toast' "
                "AND n.nspname NOT LIKE 'pg_temp_%' "
                "AND n.nspname NOT LIKE 'pg_toast_temp_%'"
                f"{schema_filter};"
            )
            table_status, table_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                table_sql,
                database=database_name,
                emit=emit,
                run_as_user=reader_name,
            )
            if not table_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not list project database tables.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(table_output) or "remote command failed",
                )
            tables = []
            table_lines = getattr(table_output, "stdout_lines", None) or []
            if table_lines:
                try:
                    parsed = json.loads(str(table_lines[-1]).strip() or "[]")
                    if isinstance(parsed, list):
                        tables = [item for item in parsed if isinstance(item, dict)]
                except json.JSONDecodeError:
                    tables = []
            return {
                **base_response,
                "msg": "Project database tables listed.",
                "schema_name": postgres_config.schema_name,
                "tables": tables,
            }

        if operation_id == "project_describe_table":
            schema_name = (postgres_config.schema_name or "public").strip()
            table_name = (postgres_config.table_name or "").strip()
            if not table_name:
                return ctx.error_result(
                    "ENGINE_VALIDATION_ERROR",
                    "settings.table_name is required.",
                    stage="validate_request",
                )
            relation_exists_sql = (
                "SELECT c.relkind "
                "FROM pg_class c "
                "JOIN pg_namespace n ON n.oid = c.relnamespace "
                "WHERE n.nspname = "
                f"{_postgres_sql_literal(schema_name)} "
                "AND c.relname = "
                f"{_postgres_sql_literal(table_name)};"
            )
            relation_status, relation_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                relation_exists_sql,
                database=database_name,
                emit=emit,
                run_as_user=reader_name,
            )
            if not relation_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not inspect project database table.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(relation_output) or "remote command failed",
                )
            relation_kind = None
            for raw_line in getattr(relation_output, "stdout_lines", None) or []:
                line = str(raw_line).strip()
                if line:
                    relation_kind = line
                    break
            if relation_kind is None:
                return ctx.error_result(
                    "ENGINE_VALIDATION_ERROR",
                    "The selected table does not exist.",
                    stage="validate_request",
                    details=f"{schema_name}.{table_name}",
                )
            if relation_kind not in ("r", "p", "v", "m", "f"):
                return ctx.error_result(
                    "ENGINE_VALIDATION_ERROR",
                    "The selected relation type is not supported.",
                    stage="validate_request",
                    details=f"{schema_name}.{table_name}",
                )
            columns_sql = (
                "SELECT COALESCE(json_agg("
                "json_build_object("
                "'name', column_name, "
                "'data_type', CASE "
                "WHEN udt_name IS NOT NULL AND data_type = 'USER-DEFINED' THEN udt_name "
                "ELSE data_type END, "
                "'is_nullable', is_nullable = 'YES', "
                "'default_expression', column_default"
                ") ORDER BY ordinal_position"
                "), '[]'::json)::text "
                "FROM information_schema.columns "
                "WHERE table_schema = "
                f"{_postgres_sql_literal(schema_name)} "
                "AND table_name = "
                f"{_postgres_sql_literal(table_name)};"
            )
            pk_sql = (
                "SELECT COALESCE(json_agg(kcu.column_name ORDER BY kcu.ordinal_position), "
                "'[]'::json)::text "
                "FROM information_schema.table_constraints tc "
                "JOIN information_schema.key_column_usage kcu "
                "ON tc.constraint_name = kcu.constraint_name "
                "AND tc.table_schema = kcu.table_schema "
                "WHERE tc.constraint_type = 'PRIMARY KEY' "
                "AND tc.table_schema = "
                f"{_postgres_sql_literal(schema_name)} "
                "AND tc.table_name = "
                f"{_postgres_sql_literal(table_name)};"
            )
            indexes_sql = (
                "SELECT COALESCE(json_agg("
                "json_build_object("
                "'name', indexname, "
                "'is_unique', position(' UNIQUE INDEX ' in indexdef) > 0, "
                "'definition', indexdef"
                ") ORDER BY indexname"
                "), '[]'::json)::text "
                "FROM pg_indexes "
                "WHERE schemaname = "
                f"{_postgres_sql_literal(schema_name)} "
                "AND tablename = "
                f"{_postgres_sql_literal(table_name)};"
            )
            foreign_keys_sql = (
                "SELECT COALESCE(json_agg("
                "json_build_object("
                "'name', tc.constraint_name, "
                "'column_names', cols.column_names, "
                "'referenced_schema_name', ccu.table_schema, "
                "'referenced_table_name', ccu.table_name, "
                "'referenced_column_names', refcols.column_names"
                ") ORDER BY tc.constraint_name"
                "), '[]'::json)::text "
                "FROM information_schema.table_constraints tc "
                "JOIN information_schema.constraint_column_usage ccu "
                "ON tc.constraint_name = ccu.constraint_name "
                "AND tc.table_schema = ccu.table_schema "
                "JOIN ("
                "SELECT constraint_name, table_schema, json_agg(column_name ORDER BY ordinal_position) AS column_names "
                "FROM information_schema.key_column_usage "
                "GROUP BY constraint_name, table_schema"
                ") AS cols "
                "ON cols.constraint_name = tc.constraint_name "
                "AND cols.table_schema = tc.table_schema "
                "JOIN ("
                "SELECT rc.constraint_name, rc.constraint_schema AS table_schema, "
                "json_agg(kcu.column_name ORDER BY kcu.ordinal_position) AS column_names "
                "FROM information_schema.referential_constraints rc "
                "JOIN information_schema.key_column_usage kcu "
                "ON kcu.constraint_name = rc.unique_constraint_name "
                "AND kcu.constraint_schema = rc.unique_constraint_schema "
                "GROUP BY rc.constraint_name, rc.constraint_schema"
                ") AS refcols "
                "ON refcols.constraint_name = tc.constraint_name "
                "AND refcols.table_schema = tc.table_schema "
                "WHERE tc.constraint_type = 'FOREIGN KEY' "
                "AND tc.table_schema = "
                f"{_postgres_sql_literal(schema_name)} "
                "AND tc.table_name = "
                f"{_postgres_sql_literal(table_name)};"
            )
            metadata_queries = {
                "columns": columns_sql,
                "primary_key_columns": pk_sql,
                "indexes": indexes_sql,
                "foreign_keys": foreign_keys_sql,
            }
            metadata = {}
            for key, sql in metadata_queries.items():
                meta_status, meta_output = _run_postgres_psql_query_impl(
                    ctx,
                    session,
                    postgres_config,
                    sql,
                    database=database_name,
                    emit=emit,
                    run_as_user=reader_name,
                )
                if not meta_status:
                    return ctx.error_result(
                        "ENGINE_RUNTIME_ERROR",
                        "Could not describe project database table.",
                        stage="execute_runtime_operation",
                        details=ctx.command_error_details(meta_output) or "remote command failed",
                    )
                meta_lines = getattr(meta_output, "stdout_lines", None) or []
                value = []
                if meta_lines:
                    try:
                        value = json.loads(str(meta_lines[-1]).strip() or "[]")
                    except json.JSONDecodeError:
                        value = []
                metadata[key] = value if isinstance(value, list) else []
            return {
                **base_response,
                "msg": "Project database table described.",
                "schema_name": schema_name,
                "table_name": table_name,
                **metadata,
            }

        return _run_postgres_agent_readonly_query(
            ctx,
            session,
            postgres_config,
            operation_id=operation_id,
            database_name=database_name,
            base_response=base_response,
            service_status=service_status,
            ip=ip,
            emit=emit,
        )


__all__ = tuple(name for name in globals() if not name.startswith("__"))
