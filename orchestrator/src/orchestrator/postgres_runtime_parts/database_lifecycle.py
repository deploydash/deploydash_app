import json

from .. import server_identifiers
from ..addressing import format_host
from ..postgres_backup import (
    postgres_parse_backup_policy_cleanup_output as _postgres_parse_backup_policy_cleanup_output,
)
from ..postgres_backup import (
    postgres_project_backup_policies_delete_command as _postgres_project_backup_policies_delete_command,
)

# ruff: noqa: F403, F405
from .agent_access import *
from .backup_support import *
from .local_import_support import *
from .project_registry import (
    _REGISTRY_DATABASES_TABLE,
    _REGISTRY_ROLES_TABLE,
    _ensure_postgres_project_registry,
    _postgres_registry_database_roles_sql,
    _postgres_registry_lookup_sql,
    _postgres_registry_register_database_sql,
    _postgres_registry_register_role_sql,
    _postgres_registry_unregister_database_sql,
    _postgres_registry_unregister_role_sql,
    _require_postgres_resource_owners,
)
from .service_configuration import *


def _postgres_force_drop_database(ctx, session, config, database_name, emit):
    """Own forced database deletion so every lifecycle path closes reconnect races."""
    command = (
        _postgres_base_env_prefix(config) + 'docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" '
        '"${CONTAINER_NAME}" dropdb -U "${POSTGRES_USER}" --force --if-exists '
        + shlex.quote(database_name)
    )
    status, output = session.host.run_shell_command(
        command,
        _timeout=120,
        _sudo=True,
    )
    ctx.emit_shell_output_lines(emit, output)
    return status, output


def _postgres_drop_database_failure_details(ctx, output, database_name):
    """Explain the likely reconnect race when forced deletion still cannot finish."""
    remote_details = ctx.command_error_details(output) or "remote command failed"
    return (
        f"Database '{database_name}' could not be dropped because a client may still be "
        "reconnecting. Stop the app or worker using this database, then try again. "
        f"Server response: {remote_details}"
    )


def handle_database_lifecycle(request):
    ctx = request.ctx
    operation_id = request.operation_id
    ip = request.ip
    postgres_config = request.postgres_config
    project_prefix = request.project_prefix
    session = request.session
    emit = request.emit
    is_cancelled = request.is_cancelled

    if operation_id in ("project_create_database", "project_create_user"):
        if operation_id == "project_create_database":
            if postgres_config.database_name is None:
                return ctx.error_result(
                    "ENGINE_VALIDATION_ERROR",
                    "settings.database_name is required.",
                    stage="validate_request",
                )
            default_username = f"{postgres_config.database_name}_user"
            desired_username = postgres_config.username or default_username
        else:
            if postgres_config.database_name is None:
                return ctx.error_result(
                    "ENGINE_VALIDATION_ERROR",
                    "settings.database_name is required.",
                    stage="validate_request",
                )
            if postgres_config.username is None:
                return ctx.error_result(
                    "ENGINE_VALIDATION_ERROR",
                    "settings.username is required.",
                    stage="validate_request",
                )
            desired_username = postgres_config.username

        database_name = _postgres_prefixed_name(
            project_prefix,
            postgres_config.database_name,
            "settings.database_name",
        )
        username_name = _postgres_prefixed_name(
            project_prefix,
            desired_username,
            "settings.username",
        )
        access_mode = postgres_config.access_mode
        user_password = postgres_config.password or _postgres_generated_password()

        if operation_id == "project_create_database":
            owned_names = ()
            creating_names = (("database", database_name), ("user", username_name))
        else:
            # A new user is only ever added to this project's own database.
            owned_names = (("database", database_name),)
            creating_names = (("user", username_name),)
        ownership_error = _require_postgres_resource_owners(
            ctx,
            session,
            postgres_config,
            emit,
            owned=owned_names,
            creating=creating_names,
        )
        if ownership_error is not None:
            return ownership_error
        database_created_in_flow = False
        role_exists_sql = (
            f"SELECT 1 FROM pg_roles WHERE rolname = {_postgres_sql_literal(username_name)};"
        )
        role_exists_status, role_exists_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            role_exists_sql,
            emit=emit,
        )
        if not role_exists_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not inspect existing database users.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(role_exists_output) or "remote command failed",
            )
        role_existed_before = _postgres_output_has_one(role_exists_output)

        def _cleanup_after_create_failure(
            ctx,
            *,
            drop_database=False,
            drop_role=False,
        ):
            cleanup_errors = []
            if drop_database:
                db_cleanup_status, db_cleanup_output = _postgres_force_drop_database(
                    ctx,
                    session,
                    postgres_config,
                    database_name,
                    emit,
                )
                if not db_cleanup_status:
                    cleanup_errors.append(
                        "rollback "
                        + _postgres_drop_database_failure_details(
                            ctx,
                            db_cleanup_output,
                            database_name,
                        ),
                    )
                unregister_db_sql = _postgres_registry_unregister_database_sql(
                    database_name,
                )
                unregister_db_status, unregister_db_output = _run_postgres_psql_query_impl(
                    ctx,
                    session,
                    postgres_config,
                    unregister_db_sql,
                    emit=emit,
                )
                if not unregister_db_status:
                    cleanup_errors.append(
                        "rollback could not remove database registration: "
                        + (
                            ctx.command_error_details(unregister_db_output)
                            or "remote command failed"
                        ),
                    )

            if drop_role:
                drop_role_sql = f"DROP ROLE IF EXISTS {_postgres_sql_identifier(username_name)};"
                role_cleanup_status, role_cleanup_output = _run_postgres_psql_query_impl(
                    ctx,
                    session,
                    postgres_config,
                    drop_role_sql,
                    emit=emit,
                )
                if not role_cleanup_status:
                    cleanup_errors.append(
                        "rollback could not drop role: "
                        + (
                            ctx.command_error_details(role_cleanup_output)
                            or "remote command failed"
                        ),
                    )
                # coverage-gate: create_rollback_unregister_role
                unregister_role_sql = _postgres_registry_unregister_role_sql(
                    username_name,
                )
                (
                    unregister_role_status,
                    unregister_role_output,
                ) = _run_postgres_psql_query_impl(
                    ctx,
                    session,
                    postgres_config,
                    unregister_role_sql,
                    emit=emit,
                )
                if not unregister_role_status:
                    cleanup_errors.append(
                        "rollback could not remove role registration: "
                        + (
                            ctx.command_error_details(unregister_role_output)
                            or "remote command failed"
                        ),
                    )
                # end coverage-gate

            return cleanup_errors

        if operation_id == "project_create_database":
            db_exists_sql = (
                f"SELECT 1 FROM pg_database WHERE datname = {_postgres_sql_literal(database_name)};"
            )
            db_exists_status, db_exists_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                db_exists_sql,
                emit=emit,
            )
            if not db_exists_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not inspect existing databases.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(db_exists_output) or "remote command failed",
                )
            database_existed_before = _postgres_output_has_one(db_exists_output)
            if not database_existed_before:
                create_db_command = (
                    _postgres_base_env_prefix(postgres_config)
                    + 'docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" '
                    '"${CONTAINER_NAME}" createdb -U "${POSTGRES_USER}" '
                    + shlex.quote(database_name)
                )
                db_status, db_output = session.host.run_shell_command(
                    create_db_command,
                    _timeout=120,
                    _sudo=True,
                )
                ctx.emit_shell_output_lines(emit, db_output)
                if not db_status:
                    return ctx.error_result(
                        "ENGINE_RUNTIME_ERROR",
                        "Could not create database.",
                        stage="execute_runtime_operation",
                        details=ctx.command_error_details(db_output) or "remote command failed",
                    )
                database_created_in_flow = True

            # coverage-gate: create_public_revoke
            # Only databases created here are revoked. A pre-existing database
            # adopted by this flow keeps its PUBLIC rights until the
            # normalization dry-run report covers it (#82).
            if database_created_in_flow:
                revoke_sql = _postgres_revoke_public_connect_sql(database_name)
                revoke_status, revoke_output = _run_postgres_psql_query_impl(
                    ctx,
                    session,
                    postgres_config,
                    revoke_sql,
                    emit=emit,
                )
                if not revoke_status:
                    cleanup_errors = _cleanup_after_create_failure(
                        ctx,
                        drop_database=database_created_in_flow,
                        drop_role=False,
                    )
                    details = ctx.command_error_details(revoke_output) or "remote command failed"
                    if cleanup_errors:
                        details = f"{details}; " + "; ".join(cleanup_errors)
                    return ctx.error_result(
                        "ENGINE_RUNTIME_ERROR",
                        "Could not revoke public database access.",
                        stage="execute_runtime_operation",
                        details=details,
                    )
            # end coverage-gate

            apply_extensions_command = _postgres_apply_extensions_command(
                postgres_config,
                database_name=database_name,
            )
            ext_status, ext_output = session.host.run_shell_command(
                apply_extensions_command,
                _timeout=180,
                _sudo=True,
            )
            ctx.emit_shell_output_lines(emit, ext_output)
            if not ext_status:
                cleanup_errors = _cleanup_after_create_failure(
                    ctx,
                    drop_database=database_created_in_flow,
                    drop_role=False,
                )
                details = ctx.command_error_details(ext_output) or "remote command failed"
                if cleanup_errors:
                    details = f"{details}; " + "; ".join(cleanup_errors)
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not enable database extensions.",
                    stage="execute_runtime_operation",
                    details=details,
                )

        role_literal = _postgres_sql_literal(username_name)
        password_literal = _postgres_sql_literal(user_password)
        role_comment = _postgres_sql_literal(
            server_identifiers.postgres_role_comment(
                postgres_config.project_slug,
                database_name,
                access_mode,
            ),
        )
        owner_name = server_identifiers.postgres_owner_role_name(database_name)

        # coverage-gate: create_owner_provisioning
        # The owner is ensured before the user-creation statement below: the
        # membership GRANT it carries names the owner role, so PostgreSQL
        # rejects the whole statement when the owner does not exist yet (#81).
        # The owner role itself is left behind when a later step fails: the
        # ensure is idempotent, so the next create adopts it, and only the
        # delete flows drop roles.
        ensure_sql = _postgres_ensure_owner_role_sql(owner_name)
        ensure_status, ensure_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            ensure_sql,
            emit=emit,
        )
        if not ensure_status:
            cleanup_errors = _cleanup_after_create_failure(
                ctx,
                drop_database=database_created_in_flow,
                drop_role=not role_existed_before,
            )
            details = ctx.command_error_details(ensure_output) or "remote command failed"
            if cleanup_errors:
                details = f"{details}; " + "; ".join(cleanup_errors)
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not provision database owner role.",
                stage="execute_runtime_operation",
                details=details,
            )
        # end coverage-gate

        membership_sql = (
            _postgres_owner_membership_sql(
                owner_name,
                username_name,
                database_name=database_name,
            )
            + " "
            if access_mode == "read_write"
            else ""
        )

        role_sql = (
            "BEGIN; "
            "DO $$ "
            "BEGIN "
            f"IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = {role_literal}) THEN "
            f"CREATE ROLE {_postgres_sql_identifier(username_name)} LOGIN PASSWORD {password_literal}; "
            "ELSE "
            f"ALTER ROLE {_postgres_sql_identifier(username_name)} LOGIN PASSWORD {password_literal}; "
            "END IF; "
            "END "
            "$$; "
            f"COMMENT ON ROLE {_postgres_sql_identifier(username_name)} IS {role_comment}; "
            f"GRANT CONNECT, TEMP ON DATABASE {_postgres_sql_identifier(database_name)} "
            f"TO {_postgres_sql_identifier(username_name)}; "
            f"{membership_sql}"
            "COMMIT;"
        )
        role_status, role_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            role_sql,
            emit=emit,
        )
        if not role_status:
            cleanup_errors = _cleanup_after_create_failure(
                ctx,
                drop_database=database_created_in_flow,
                drop_role=not role_existed_before,
            )
            details = ctx.command_error_details(role_output) or "remote command failed"
            if cleanup_errors:
                details = f"{details}; " + "; ".join(cleanup_errors)
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not create database user.",
                stage="execute_runtime_operation",
                details=details,
            )

        if operation_id == "project_create_database":
            ownership_prefix = _postgres_assign_ddl_ownership_sql(database_name, owner_name) + " "
        else:
            ownership_prefix = ""

        read_only_grants = (
            ownership_prefix
            + _postgres_reclaim_ddl_ownership_sql(database_name, username_name)
            + " "
            f"GRANT USAGE ON SCHEMA public TO {_postgres_sql_identifier(username_name)}; "
            f"REVOKE CREATE ON SCHEMA public FROM {_postgres_sql_identifier(username_name)}; "
            f"REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM {_postgres_sql_identifier(username_name)}; "
            f"REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM {_postgres_sql_identifier(username_name)}; "
            f"ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM {_postgres_sql_identifier(username_name)}; "
            f"ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM {_postgres_sql_identifier(username_name)}; "
            f"GRANT SELECT ON ALL TABLES IN SCHEMA public TO {_postgres_sql_identifier(username_name)}; "
            f"GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {_postgres_sql_identifier(username_name)}; "
            + _postgres_owner_default_privileges_sql(owner_name, username_name)
        )
        read_write_grants = (
            ownership_prefix
            + f"GRANT USAGE, CREATE ON SCHEMA public TO {_postgres_sql_identifier(username_name)}; "
            f"GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER "
            f"ON ALL TABLES IN SCHEMA public TO {_postgres_sql_identifier(username_name)}; "
            f"GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO {_postgres_sql_identifier(username_name)}; "
            f"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT "
            f"SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER "
            f"ON TABLES TO {_postgres_sql_identifier(username_name)}; "
            f"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT, UPDATE "
            f"ON SEQUENCES TO {_postgres_sql_identifier(username_name)};"
        )
        grant_body = read_only_grants if access_mode == "read_only" else read_write_grants
        # The owner needs schema access on databases created before it
        # existed; on new databases it already owns the schema, so this is a
        # harmless no-op there.
        owner_schema_grant = (
            f"GRANT USAGE, CREATE ON SCHEMA public TO {_postgres_sql_identifier(owner_name)}; "
        )
        grant_sql = f"BEGIN; {owner_schema_grant}{grant_body} COMMIT;"
        grant_status, grant_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            grant_sql,
            database=database_name,
            emit=emit,
        )
        if not grant_status:
            cleanup_errors = _cleanup_after_create_failure(
                ctx,
                drop_database=database_created_in_flow,
                drop_role=not role_existed_before,
            )
            details = ctx.command_error_details(grant_output) or "remote command failed"
            if cleanup_errors:
                details = f"{details}; " + "; ".join(cleanup_errors)
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not grant database access.",
                stage="execute_runtime_operation",
                details=details,
            )

        # coverage-gate: create_reader_provisioning
        # The agent reader is provisioned once per database, after the owner
        # its default privileges reference. Adding a user never
        # re-provisions it; adopted databases gain it lazily on the first
        # agent query. Like the owner, the reader is left behind when a
        # later step fails and only the delete flows drop roles (#83).
        reader_name = None
        if operation_id == "project_create_database":
            reader_name = server_identifiers.postgres_agent_reader_role_name(database_name)
            reader_sql = " ".join(
                [
                    _postgres_ensure_agent_reader_role_sql(reader_name),
                    _postgres_agent_reader_grants_sql(database_name, owner_name, reader_name),
                ]
            )
            reader_status, reader_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                reader_sql,
                database=database_name,
                emit=emit,
            )
            if not reader_status:
                cleanup_errors = _cleanup_after_create_failure(
                    ctx,
                    drop_database=database_created_in_flow,
                    drop_role=not role_existed_before,
                )
                details = ctx.command_error_details(reader_output) or "remote command failed"
                if cleanup_errors:
                    details = f"{details}; " + "; ".join(cleanup_errors)
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not provision agent reader role.",
                    stage="execute_runtime_operation",
                    details=details,
                )
        # end coverage-gate

        # coverage-gate: create_ownership_registration
        register_statements = [
            _postgres_registry_register_database_sql(
                database_name,
                postgres_config.project_slug,
            ),
            _postgres_registry_register_role_sql(
                username_name,
                postgres_config.project_slug,
                datname=database_name,
                access_mode=access_mode,
                role_kind=("readonly" if access_mode == "read_only" else "app"),
            ),
            _postgres_registry_register_role_sql(
                owner_name,
                postgres_config.project_slug,
                datname=database_name,
                access_mode="owner",
                role_kind="owner",
            ),
        ]
        if reader_name is not None:
            register_statements.append(
                _postgres_registry_register_role_sql(
                    reader_name,
                    postgres_config.project_slug,
                    datname=database_name,
                    access_mode="read_only",
                    role_kind="agent_reader",
                )
            )
        register_sql = " ".join(register_statements)
        register_status, register_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            register_sql,
            emit=emit,
        )
        if not register_status:
            cleanup_errors = _cleanup_after_create_failure(
                ctx,
                drop_database=database_created_in_flow,
                drop_role=not role_existed_before,
            )
            details = ctx.command_error_details(register_output) or "remote command failed"
            if cleanup_errors:
                details = f"{details}; " + "; ".join(cleanup_errors)
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not register database ownership.",
                stage="execute_runtime_operation",
                details=details,
            )
        # end coverage-gate

        connection_uri = (
            "postgresql://"
            f"{username_name}:{user_password}"
            "@"
            f"{format_host(_postgres_connection_uri_host_for_managed_apps())}:"
            f"{postgres_config.host_port}/{database_name}"
        )
        return {
            "status": "success",
            "code": "OK",
            "msg": "Database access created successfully.",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "database_name": _postgres_strip_project_prefix(
                project_prefix,
                database_name,
            ),
            "remote_database_name": database_name,
            "username": _postgres_strip_project_prefix(
                project_prefix,
                username_name,
            ),
            "remote_username": username_name,
            "password": user_password,
            "access_mode": access_mode,
            "connection_uri": connection_uri,
            "host": ip,
            "port": postgres_config.host_port,
        }

    if operation_id == "project_delete_database":
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

        ownership_error = _require_postgres_resource_owners(
            ctx,
            session,
            postgres_config,
            emit,
            owned=(("database", database_name),),
        )
        if ownership_error is not None:
            return ownership_error

        db_exists_sql = (
            f"SELECT 1 FROM pg_database WHERE datname = {_postgres_sql_literal(database_name)};"
        )
        db_exists_status, db_exists_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            db_exists_sql,
            emit=emit,
        )
        if not db_exists_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not inspect target database.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(db_exists_output) or "remote command failed",
            )
        database_exists = _postgres_output_has_one(db_exists_output)

        roles_sql = _postgres_registry_lookup_sql(
            _REGISTRY_ROLES_TABLE,
            "rolname",
            "datname",
            database_name,
        )
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
                "Could not inspect project database users.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(roles_output) or "remote command failed",
            )

        def users_for_database_from_roles_output(output):
            role_lines = getattr(output, "stdout_lines", None) or []
            return [
                str(line).strip()
                for line in role_lines
                if isinstance(line, str) and str(line).strip()
            ]

        users_to_drop = users_for_database_from_roles_output(roles_output)

        # coverage-gate: delete_database_derived_roles_cleanup
        # The owner and the agent reader are derived from the database name,
        # so they are dropped even when their registry rows are missing (#81,
        # #83).
        owner_name = server_identifiers.postgres_owner_role_name(database_name)
        if owner_name not in users_to_drop:
            users_to_drop.append(owner_name)
        reader_name = server_identifiers.postgres_agent_reader_role_name(database_name)
        if reader_name not in users_to_drop:
            users_to_drop.append(reader_name)
        # end coverage-gate

        if database_exists:
            for username_name in users_to_drop:
                if callable(is_cancelled) and is_cancelled():
                    return ctx.error_result(
                        "ENGINE_TASK_CANCELLED",
                        "Task cancelled during PostgreSQL operation",
                        stage="execute_runtime_operation",
                    )
                cleanup_sql = _postgres_reassign_owned_if_exists_sql(username_name)
                cleanup_status, cleanup_output = _run_postgres_psql_query_impl(
                    ctx,
                    session,
                    postgres_config,
                    cleanup_sql,
                    database=database_name,
                    emit=emit,
                )
                if not cleanup_status:
                    return ctx.error_result(
                        "ENGINE_RUNTIME_ERROR",
                        "Could not remove user grants from database.",
                        stage="execute_runtime_operation",
                        details=ctx.command_error_details(cleanup_output)
                        or "remote command failed",
                    )

            terminate_sql = (
                "SELECT pg_terminate_backend(pid) "
                "FROM pg_stat_activity "
                "WHERE datname = "
                f"{_postgres_sql_literal(database_name)} "
                "AND pid <> pg_backend_pid();"
            )
            terminate_status, terminate_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                terminate_sql,
                emit=emit,
            )
            if not terminate_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not terminate active database sessions.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(terminate_output) or "remote command failed",
                )

            drop_db_status, drop_db_output = _postgres_force_drop_database(
                ctx,
                session,
                postgres_config,
                database_name,
                emit,
            )
            if not drop_db_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not drop database.",
                    stage="execute_runtime_operation",
                    details=_postgres_drop_database_failure_details(
                        ctx,
                        drop_db_output,
                        database_name,
                    ),
                )

        dropped_users = []
        for username_name in users_to_drop:
            if callable(is_cancelled) and is_cancelled():
                return ctx.error_result(
                    "ENGINE_TASK_CANCELLED",
                    "Task cancelled during PostgreSQL operation",
                    stage="execute_runtime_operation",
                )
            drop_role_sql = f"DROP ROLE IF EXISTS {_postgres_sql_identifier(username_name)};"
            drop_role_status, drop_role_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                drop_role_sql,
                emit=emit,
            )
            if not drop_role_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not drop database user.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(drop_role_output) or "remote command failed",
                )
            dropped_users.append(username_name)

        # The dropped users are verified against live pg_roles, not the
        # registry: their registry rows still exist until the unregister
        # step below, so re-reading the registry would fail every delete
        # whose roles were registered (#80, #81).
        verify_sql = _postgres_existing_roles_sql(dropped_users)
        verify_roles_status, verify_roles_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            verify_sql,
            emit=emit,
        )
        if not verify_roles_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not verify database user cleanup.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(verify_roles_output) or "remote command failed",
            )
        remaining_users = users_for_database_from_roles_output(verify_roles_output)
        if remaining_users:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not verify database user cleanup.",
                stage="execute_runtime_operation",
                details=("Users still exist: " + ", ".join(sorted(remaining_users))),
            )

        unregister_statements = [
            _postgres_registry_unregister_database_sql(database_name),
        ]
        unregister_statements.extend(
            _postgres_registry_unregister_role_sql(username_name) for username_name in dropped_users
        )
        unregister_status, unregister_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            " ".join(unregister_statements),
            emit=emit,
        )
        if not unregister_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not remove database ownership registration.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(unregister_output) or "remote command failed",
            )

        return {
            "status": "success",
            "code": "OK",
            "msg": "Database deleted.",
            "operation_id": operation_id,
            "database_name": _postgres_strip_project_prefix(
                project_prefix,
                database_name,
            ),
            "deleted_database_name": _postgres_strip_project_prefix(
                project_prefix,
                database_name,
            ),
            "remote_database_name": database_name,
            "deleted_remote_database_name": database_name,
            "database_existed": database_exists,
            "dropped_users": dropped_users,
        }

    if operation_id == "project_normalize_database":
        # coverage-gate: normalize_database_flow
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
        owner_name = server_identifiers.postgres_owner_role_name(database_name)

        registry_error = _ensure_postgres_project_registry(
            ctx,
            session,
            postgres_config,
            emit,
        )
        if registry_error is not None:
            return registry_error

        database_exists, database_error = _postgres_database_exists(
            ctx,
            session,
            postgres_config,
            database_name,
            emit,
        )
        if database_error is not None:
            return database_error
        if not database_exists:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "The selected project database does not exist.",
                stage="validate_request",
                details=database_name,
            )

        ownership_error = _require_postgres_resource_owners(
            ctx,
            session,
            postgres_config,
            emit,
            owned=(("database", database_name),),
            ensure_registry=False,
        )
        if ownership_error is not None:
            return ownership_error

        roles_sql = _postgres_registry_database_roles_sql(database_name)
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
                "Could not inspect project database users.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(roles_output) or "remote command failed",
            )
        roles_lines = getattr(roles_output, "stdout_lines", None) or []
        roles_text = "".join(str(line) for line in roles_lines).strip() or "[]"
        try:
            role_rows = json.loads(roles_text)
            if not isinstance(role_rows, list):
                raise ValueError("role listing was not a JSON array")
        except ValueError as exc:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not inspect project database users.",
                stage="execute_runtime_operation",
                details=str(exc),
            )
        read_write_users = []
        read_only_users = []
        for item in role_rows:
            if not isinstance(item, dict):
                continue
            username_value = item.get("username")
            if not isinstance(username_value, str):
                continue
            if username_value == owner_name:
                continue
            if item.get("role_kind") not in ("app", "readonly"):
                continue
            if item.get("access_mode") == "read_only":
                read_only_users.append(username_value)
            elif item.get("access_mode") == "read_write":
                read_write_users.append(username_value)
        fresh_users = sorted(set(read_write_users + read_only_users))

        implicit_sql = _postgres_implicit_connect_roles_sql(database_name)
        implicit_status, implicit_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            implicit_sql,
            emit=emit,
        )
        if not implicit_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not inspect implicit CONNECT rights.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(implicit_output) or "remote command failed",
            )
        implicit_lines = getattr(implicit_output, "stdout_lines", None) or []
        roles_losing_connect = sorted(
            {
                str(line).strip()
                for line in implicit_lines
                if isinstance(line, str)
                and str(line).strip()
                and str(line).strip() not in fresh_users
            }
        )

        if request.dry_run:
            return {
                "status": "success",
                "code": "OK",
                "msg": f"PostgreSQL project operation '{operation_id}' plan ready",
                "operation_id": operation_id,
                "project_slug": postgres_config.project_slug,
                "project_prefix": project_prefix,
                "database_name": _postgres_strip_project_prefix(
                    project_prefix,
                    database_name,
                ),
                "remote_database_name": database_name,
                "owner_name": owner_name,
                "read_write_users": sorted(read_write_users),
                "read_only_users": sorted(read_only_users),
                "roles_losing_connect": roles_losing_connect,
            }

        confirmed_users = postgres_config.confirmed_normalize_users
        confirmed_lost = postgres_config.confirmed_lost_connect_roles
        if confirmed_users is None or confirmed_lost is None:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "Project normalize requires the confirmed users and roles from its dry run.",
                stage="validate_request",
            )
        # The apply re-read everything above, so this compares the fresh
        # membership against what was reviewed: a user or implicit role that
        # appeared after the dry run refuses the whole apply.
        if sorted(confirmed_users) != fresh_users or sorted(confirmed_lost) != sorted(
            roles_losing_connect
        ):
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "The confirmed normalize plan no longer matches the database. "
                "Review the current plan, then confirm again.",
                stage="validate_request",
            )

        if callable(is_cancelled) and is_cancelled():
            return ctx.error_result(
                "ENGINE_TASK_CANCELLED",
                "Task cancelled during PostgreSQL operation",
                stage="execute_runtime_operation",
            )

        if fresh_users:
            existing_roles_sql = _postgres_existing_roles_sql(fresh_users)
            existing_roles_status, existing_roles_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                existing_roles_sql,
                emit=emit,
            )
            if not existing_roles_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not inspect live database users.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(existing_roles_output)
                    or "remote command failed",
                )
            existing_roles = {
                str(line).strip()
                for line in getattr(existing_roles_output, "stdout_lines", None) or []
                if isinstance(line, str) and str(line).strip()
            }
            missing_roles = sorted(set(fresh_users) - existing_roles)
            if missing_roles:
                return ctx.error_result(
                    "ENGINE_VALIDATION_ERROR",
                    "One or more registered database users no longer exist in PostgreSQL. "
                    "Remove the stale user from Deploy Dash, review the normalize plan, "
                    "then try again.",
                    stage="validate_request",
                    details="Missing PostgreSQL roles: " + ", ".join(missing_roles),
                )

        ctx.emit_event(
            emit,
            "normalize_progress",
            "Provisioning the database owner role.",
        )
        ensure_sql = _postgres_ensure_owner_role_sql(owner_name)
        ensure_status, ensure_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            ensure_sql,
            emit=emit,
        )
        if not ensure_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not provision the database owner role.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(ensure_output) or "remote command failed",
            )

        ctx.emit_event(
            emit,
            "normalize_progress",
            "Reassigning database objects to the owner role. "
            "This can take a while on large databases.",
        )
        reassign_sql = ""
        if read_write_users or read_only_users:
            reassign_sql = (
                "REASSIGN OWNED BY "
                + ", ".join(_postgres_sql_identifier(user) for user in fresh_users)
                + f" TO {_postgres_sql_identifier(owner_name)}; "
            )
        readonly_sql = "".join(
            f"GRANT USAGE ON SCHEMA public TO {_postgres_sql_identifier(user)}; "
            f"GRANT SELECT ON ALL TABLES IN SCHEMA public TO {_postgres_sql_identifier(user)}; "
            f"GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {_postgres_sql_identifier(user)}; "
            + _postgres_owner_default_privileges_sql(owner_name, user)
            + " "
            for user in sorted(read_only_users)
        )
        ownership_sql = (
            "BEGIN; "
            f"{reassign_sql}"
            f"{_postgres_assign_ddl_ownership_sql(database_name, owner_name)} "
            f"{readonly_sql}"
            "COMMIT;"
        )
        ownership_status, ownership_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            ownership_sql,
            database=database_name,
            emit=emit,
        )
        if not ownership_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not transfer object ownership to the owner role.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(ownership_output) or "remote command failed",
            )

        ctx.emit_event(
            emit,
            "normalize_progress",
            "Applying database access changes.",
        )
        membership_sql = "".join(
            _postgres_owner_membership_sql(
                owner_name,
                user,
                database_name=database_name,
            )
            + " "
            for user in sorted(read_write_users)
        )
        connect_sql = "".join(
            f"GRANT CONNECT, TEMP ON DATABASE {_postgres_sql_identifier(database_name)} "
            f"TO {_postgres_sql_identifier(user)}; "
            for user in fresh_users
        )
        access_sql = (
            "BEGIN; "
            f"{membership_sql}"
            f"{connect_sql}"
            f"{_postgres_revoke_public_connect_sql(database_name)} "
            "COMMIT;"
        )
        access_status, access_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            access_sql,
            emit=emit,
        )
        if not access_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not apply database access changes.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(access_output) or "remote command failed",
            )

        register_sql = _postgres_registry_register_role_sql(
            owner_name,
            postgres_config.project_slug,
            datname=database_name,
            access_mode="owner",
            role_kind="owner",
        )
        register_status, register_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            register_sql,
            emit=emit,
        )
        if not register_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not register the database owner role.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(register_output) or "remote command failed",
            )

        verify_status, verify_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            implicit_sql,
            emit=emit,
        )
        if not verify_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not verify database normalization.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(verify_output) or "remote command failed",
            )
        verify_lines = getattr(verify_output, "stdout_lines", None) or []
        still_implicit = sorted(
            {
                str(line).strip()
                for line in verify_lines
                if isinstance(line, str) and str(line).strip()
            }
        )
        if still_implicit:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Database normalization could not be verified.",
                stage="execute_runtime_operation",
                details=("Roles still connecting implicitly: " + ", ".join(still_implicit)),
            )

        normalized_set = set(fresh_users)
        return {
            "status": "success",
            "code": "OK",
            "msg": "Database isolation normalized.",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "project_prefix": project_prefix,
            "database_name": _postgres_strip_project_prefix(
                project_prefix,
                database_name,
            ),
            "remote_database_name": database_name,
            "owner_name": owner_name,
            "normalized_users": fresh_users,
            "roles_losing_connect": roles_losing_connect,
            "roles_lost_connect": [
                role for role in roles_losing_connect if role not in normalized_set
            ],
        }
        # end coverage-gate

    if operation_id == "project_delete":
        # coverage-gate: project_delete_registry_ensure
        registry_error = _ensure_postgres_project_registry(
            ctx,
            session,
            postgres_config,
            emit,
        )
        if registry_error is not None:
            return registry_error
        # end coverage-gate

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
            str(line).strip() for line in db_lines if isinstance(line, str) and str(line).strip()
        ]

        list_roles_sql = _postgres_registry_lookup_sql(
            _REGISTRY_ROLES_TABLE,
            "rolname",
            "project_slug",
            postgres_config.project_slug,
        )
        role_status, role_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            list_roles_sql,
            emit=emit,
        )
        if not role_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not inspect project database users.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(role_output) or "remote command failed",
            )
        role_lines = getattr(role_output, "stdout_lines", None) or []
        role_names = [
            str(line).strip() for line in role_lines if isinstance(line, str) and str(line).strip()
        ]

        if request.dry_run:
            return {
                "status": "success",
                "code": "OK",
                "msg": f"PostgreSQL project operation '{operation_id}' plan ready",
                "operation_id": operation_id,
                "project_slug": postgres_config.project_slug,
                "project_prefix": project_prefix,
                "databases": database_names,
                "users": role_names,
            }

        confirmed_databases = postgres_config.confirmed_databases
        confirmed_users = postgres_config.confirmed_users
        if confirmed_databases is None or confirmed_users is None:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "Project delete requires the confirmed databases and users from its dry run.",
                stage="validate_request",
            )
        if sorted(confirmed_databases) != sorted(database_names) or sorted(
            confirmed_users
        ) != sorted(role_names):
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "The confirmed delete list no longer matches the registry. "
                "Review the current databases and users, then confirm again.",
                stage="validate_request",
            )

        dropped_databases = []

        for database_name in database_names:
            if callable(is_cancelled) and is_cancelled():
                return ctx.error_result(
                    "ENGINE_TASK_CANCELLED",
                    "Task cancelled during PostgreSQL operation",
                    stage="execute_runtime_operation",
                )

            terminate_sql = (
                "SELECT pg_terminate_backend(pid) "
                "FROM pg_stat_activity "
                "WHERE datname = "
                f"{_postgres_sql_literal(database_name)} "
                "AND pid <> pg_backend_pid();"
            )
            terminate_status, terminate_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                terminate_sql,
                emit=emit,
            )
            if not terminate_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not terminate active project DB sessions.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(terminate_output) or "remote command failed",
                )

            drop_db_status, drop_db_output = _postgres_force_drop_database(
                ctx,
                session,
                postgres_config,
                database_name,
                emit,
            )
            if not drop_db_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not drop project database.",
                    stage="execute_runtime_operation",
                    details=_postgres_drop_database_failure_details(
                        ctx,
                        drop_db_output,
                        database_name,
                    ),
                )
            dropped_databases.append(database_name)

        dropped_users = []

        for role_name in role_names:
            if callable(is_cancelled) and is_cancelled():
                return ctx.error_result(
                    "ENGINE_TASK_CANCELLED",
                    "Task cancelled during PostgreSQL operation",
                    stage="execute_runtime_operation",
                )

            drop_role_sql = f"DROP ROLE IF EXISTS {_postgres_sql_identifier(role_name)};"
            drop_role_status, drop_role_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                drop_role_sql,
                emit=emit,
            )
            if not drop_role_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not drop project database user.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(drop_role_output) or "remote command failed",
                )
            dropped_users.append(role_name)

        # coverage-gate: project_delete_ownership_unregister
        unregister_statements = [
            _postgres_registry_unregister_database_sql(database_name)
            for database_name in dropped_databases
        ]
        unregister_statements.extend(
            _postgres_registry_unregister_role_sql(role_name) for role_name in dropped_users
        )
        if unregister_statements:
            unregister_status, unregister_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                " ".join(unregister_statements),
                emit=emit,
            )
            if not unregister_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not remove project ownership registrations.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(unregister_output) or "remote command failed",
                )

        # end coverage-gate

        # coverage-gate: project_delete_backup_cleanup
        cleanup_status, cleanup_output = _run_postgres_host_command(
            ctx,
            session,
            _postgres_project_backup_policies_delete_command(
                postgres_config,
                postgres_config.project_slug,
            ),
            emit=emit,
            timeout=90,
        )
        if not cleanup_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not remove project backup policies.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(cleanup_output) or "remote command failed",
            )
        removed_backup_policies = _postgres_parse_backup_policy_cleanup_output(
            cleanup_output,
        )

        return {
            "status": "success",
            "code": "OK",
            "msg": "Project database resources deleted.",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "project_prefix": project_prefix,
            "dropped_databases": dropped_databases,
            "dropped_users": dropped_users,
            "removed_backup_policies": removed_backup_policies,
            "removed_backup_policy_count": len(removed_backup_policies),
            "backup_logs_removed": True,
        }
        # end coverage-gate


__all__ = tuple(name for name in globals() if not name.startswith("__"))
