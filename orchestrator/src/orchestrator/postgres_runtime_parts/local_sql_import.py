import contextlib
import os
import secrets
import tempfile

# ruff: noqa: F403, F405
from .agent_access import *
from .backup_support import *
from .local_import_scan import *
from .local_import_support import *
from .project_registry import _require_postgres_resource_owners
from .service_configuration import *


def _drop_temp_import_role_best_effort(
    ctx,
    session,
    config,
    *,
    temp_role_name,
    owner_name,
    database_name,
    emit=None,
):
    """Drop the temporary import login, warning instead of failing.

    Runs in the target database, where anything the temp login owns must
    live. A failed drop never fails the import itself: the role expires
    within hours through VALID UNTIL, and the warning names it (#84).
    """
    drop_status, drop_output = _run_postgres_psql_query_impl(
        ctx,
        session,
        config,
        _postgres_drop_temp_import_role_sql(temp_role_name, owner_name),
        database=database_name,
        emit=emit,
    )
    if not drop_status:
        ctx.emit_event(
            emit,
            "postgres_local_sql_role_cleanup_warning",
            "Temporary import role cleanup failed on the server. The role expires automatically.",
            level="warning",
            data={
                "import_role": temp_role_name,
                "details": ctx.command_error_details(drop_output) or "remote command failed",
            },
        )


def handle_local_sql_import(request):
    ctx = request.ctx
    operation_id = request.operation_id
    ip = request.ip
    username = request.username
    password = request.password
    key_filename = request.key_filename
    port = request.port
    postgres_config = request.postgres_config
    project_prefix = request.project_prefix
    session = request.session
    emit = request.emit
    is_cancelled = request.is_cancelled

    if operation_id == "import_local_sql":
        try:
            import_payload = _resolve_local_sql_import_payload(
                postgres_config,
                project_prefix,
                validate_local_file=True,
            )
        except PostgresConfigValidationError as exc:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                str(exc),
                stage="validate_request",
            )

        # coverage-gate: import_preflight_scan
        is_custom_format = import_payload["dump_format"] == "custom"
        upload_path = import_payload["local_file_path"]
        import_size_bytes = import_payload["size_bytes"]
        filtered_path = None
        if not is_custom_format:
            try:
                scan_report = _scan_local_sql_dump(
                    import_payload["local_file_path"],
                    enabled_extensions=postgres_config.enabled_extensions,
                )
            except OSError as exc:
                return ctx.error_result(
                    "ENGINE_VALIDATION_ERROR",
                    "Could not read the local SQL file for pre-flight scan.",
                    stage="validate_request",
                    details=str(exc),
                )
            blocking_findings = scan_report["blocking"]
            if blocking_findings:
                first_finding = blocking_findings[0]
                finding_details = f"{first_finding['code']} at line {first_finding['line']}"
                if len(blocking_findings) > 1:
                    finding_details += f" ({len(blocking_findings) - 1} more)"
                return ctx.error_result(
                    "ENGINE_VALIDATION_ERROR",
                    first_finding["message"],
                    stage="validate_request",
                    details=finding_details,
                )
            ownership_count = scan_report["ownership_statement_count"]
            extension_count = scan_report["extension_statement_count"]
            if ownership_count and not postgres_config.import_ignore_ownership:
                return ctx.error_result(
                    "ENGINE_VALIDATION_ERROR",
                    f"The dump contains ownership or privilege statements "
                    f"({ownership_count} found) that the import cannot apply. "
                    "Enable the 'Ignore ownership and permission statements' "
                    "option, or re-export with pg_dump --no-owner --no-privileges.",
                    stage="validate_request",
                )
            if ownership_count or extension_count:
                try:
                    with tempfile.NamedTemporaryFile(
                        suffix=".sql",
                        delete=False,
                    ) as filtered_handle:
                        filtered_path = filtered_handle.name
                    filter_report = _write_filtered_sql_dump(
                        upload_path,
                        filtered_path,
                        enabled_extensions=postgres_config.enabled_extensions,
                        drop_ownership=postgres_config.import_ignore_ownership,
                        drop_extensions=bool(extension_count),
                    )
                    upload_path = filtered_path
                    import_size_bytes = os.path.getsize(filtered_path)
                except OSError as exc:
                    if filtered_path is not None:
                        with contextlib.suppress(OSError):
                            os.remove(filtered_path)
                    return ctx.error_result(
                        "ENGINE_VALIDATION_ERROR",
                        "Could not stage the filtered SQL file for upload.",
                        stage="validate_request",
                        details=str(exc),
                    )
                if ownership_count:
                    ctx.emit_event(
                        emit,
                        "postgres_local_sql_ownership_filtered",
                        "Ignored ownership and permission statements before upload.",
                        data={
                            "dropped_statements": filter_report["dropped_ownership_statements"],
                        },
                    )
                if extension_count:
                    ctx.emit_event(
                        emit,
                        "postgres_local_sql_extensions_filtered",
                        "Kept Deploy Dash-managed extension setup out of the import.",
                        data={
                            "dropped_statements": filter_report["dropped_extension_statements"],
                        },
                    )
            for notice in scan_report["notices"]:
                ctx.emit_event(
                    emit,
                    "postgres_local_sql_import_notice",
                    notice["message"],
                    level="warning",
                    data={
                        "code": notice["code"],
                        "line": notice["line"],
                    },
                )
        # end coverage-gate

        exists_sql = (
            "SELECT 1 FROM pg_database WHERE datname = "
            f"{_postgres_sql_literal(import_payload['database_name'])};"
        )
        exists_status, exists_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            exists_sql,
            emit=emit,
        )
        if not exists_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not validate import target database.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(exists_output) or "remote command failed",
            )
        if not _postgres_output_has_one(exists_output):
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "Target database does not exist. Create it first, then retry the import.",
                stage="validate_request",
            )
        ownership_error = _require_postgres_resource_owners(
            ctx,
            session,
            postgres_config,
            emit,
            owned=(("database", import_payload["database_name"]),),
        )
        if ownership_error is not None:
            return ownership_error

        # coverage-gate: import_owner_role_preflight
        owner_name = server_identifiers.postgres_owner_role_name(
            import_payload["database_name"],
        )
        owner_exists_sql = (
            "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = "
            f"{_postgres_sql_literal(owner_name)}) THEN 1 ELSE 0 END;"
        )
        owner_exists_status, owner_exists_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            owner_exists_sql,
            emit=emit,
        )
        if not owner_exists_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not validate the database owner role.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(owner_exists_output) or "remote command failed",
            )
        if not _postgres_output_has_one(owner_exists_output):
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "This database predates managed ownership. Use Normalize isolation "
                "for this database, then retry the import.",
                stage="validate_request",
            )
        # end coverage-gate

        remote_path = import_payload["remote_path"]
        # coverage-gate: import_staging_dir_local
        remote_dir = import_payload["remote_dir"]
        # end coverage-gate
        try:
            try:
                _upload_local_sql_import_file(
                    ctx,
                    ip=ip,
                    username=username,
                    password=password,
                    key_filename=key_filename,
                    port=port,
                    # coverage-gate: import_upload_staging_arg
                    local_path=upload_path,
                    remote_path=remote_path,
                    remote_dir=remote_dir,
                    # end coverage-gate
                    emit=emit,
                    is_cancelled=is_cancelled,
                )
            finally:
                # coverage-gate: import_filtered_temp_cleanup
                if filtered_path is not None:
                    with contextlib.suppress(OSError):
                        os.remove(filtered_path)
                # end coverage-gate
        except _PostgresLocalImportCancelled as exc:
            _run_postgres_host_command(
                ctx,
                session,
                # coverage-gate: import_cancel_cleanup
                _postgres_local_sql_cleanup_command(remote_dir),
                # end coverage-gate
                emit=emit,
                timeout=30,
            )
            return ctx.error_result(
                "ENGINE_TASK_CANCELLED",
                str(exc),
                stage="execute_runtime_operation",
            )
        except Exception as exc:
            _run_postgres_host_command(
                ctx,
                session,
                # coverage-gate: import_upload_error_cleanup
                _postgres_local_sql_cleanup_command(remote_dir),
                # end coverage-gate
                emit=emit,
                timeout=30,
            )
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not upload local SQL file.",
                stage="execute_runtime_operation",
                details=str(exc),
            )

        try:
            # coverage-gate: import_temp_role_provision
            temp_role_name = f"{server_identifiers.MANAGED_PREFIX}_import_{secrets.token_hex(8)}"
            temp_password = _postgres_generated_password()
            create_status, create_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                _postgres_temp_import_role_sql(
                    temp_role_name,
                    temp_password,
                    import_payload["database_name"],
                    owner_name,
                ),
                emit=emit,
            )
            if not create_status:
                _drop_temp_import_role_best_effort(
                    ctx,
                    session,
                    postgres_config,
                    temp_role_name=temp_role_name,
                    owner_name=owner_name,
                    database_name=import_payload["database_name"],
                    emit=emit,
                )
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not prepare the temporary import role.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(create_output) or "remote command failed",
                )
            # end coverage-gate

            try:
                ctx.emit_event(
                    emit,
                    "postgres_local_sql_import_started",
                    "Importing uploaded SQL file into PostgreSQL.",
                    data={
                        "target_database_name": import_payload["database_name"],
                        "remote_path": remote_path,
                    },
                )
                # coverage-gate: import_command_by_format
                if is_custom_format:
                    import_command = _postgres_local_pg_restore_command(
                        postgres_config,
                        database_name=import_payload["database_name"],
                        remote_path=remote_path,
                        import_role=temp_role_name,
                        import_password=temp_password,
                        owner_role=owner_name,
                    )
                else:
                    import_command = _postgres_local_sql_import_command(
                        postgres_config,
                        database_name=import_payload["database_name"],
                        remote_path=remote_path,
                        import_role=temp_role_name,
                        import_password=temp_password,
                        owner_role=owner_name,
                    )
                # end coverage-gate
                import_status, import_output = _run_postgres_host_command(
                    ctx,
                    session,
                    import_command,
                    emit=emit,
                    timeout=10800,
                )
                if not import_status or not _postgres_local_sql_import_confirmed(import_output):
                    return ctx.error_result(
                        "ENGINE_RUNTIME_ERROR",
                        "PostgreSQL local SQL restore failed.",
                        stage="execute_runtime_operation",
                        details=ctx.command_error_details(import_output)
                        or "PostgreSQL did not confirm SQL import completion.",
                    )
            finally:
                # coverage-gate: import_temp_role_drop
                _drop_temp_import_role_best_effort(
                    ctx,
                    session,
                    postgres_config,
                    temp_role_name=temp_role_name,
                    owner_name=owner_name,
                    database_name=import_payload["database_name"],
                    emit=emit,
                )
                # end coverage-gate
        finally:
            cleanup_status, cleanup_output = _run_postgres_host_command(
                ctx,
                session,
                # coverage-gate: import_finally_cleanup
                _postgres_local_sql_cleanup_command(remote_dir),
                # end coverage-gate
                emit=emit,
                timeout=30,
            )
            if not cleanup_status:
                ctx.emit_event(
                    emit,
                    "postgres_local_sql_cleanup_warning",
                    "Uploaded SQL file cleanup failed on the server.",
                    level="warning",
                    data={
                        "remote_path": remote_path,
                        "details": ctx.command_error_details(cleanup_output)
                        or "remote command failed",
                    },
                )

        return {
            "status": "success",
            "code": "OK",
            "msg": "Local SQL restore completed.",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "database_name": _postgres_strip_project_prefix(
                project_prefix,
                import_payload["database_name"],
            ),
            "remote_database_name": import_payload["database_name"],
            "target_database_name": import_payload["database_name"],
            "import_local_file_path": import_payload["local_file_path"],
            "imported_size_bytes": import_size_bytes,
        }


__all__ = tuple(name for name in globals() if not name.startswith("__"))
