import secrets

from ..postgres_backup import (
    backup_env_export_block as _backup_env_export_block,
)
from ..postgres_backup import (
    backup_remote_base_path as _backup_remote_base_path,
)
from ..postgres_backup import (
    normalize_backup_policy_token as _normalize_backup_policy_token,
)
from ..postgres_backup import (
    postgres_backlog_beyond_retention as _postgres_backlog_beyond_retention,
)
from ..postgres_backup import (
    postgres_backup_backlog_cleanup_command as _postgres_backup_backlog_cleanup_command,
)
from ..postgres_backup import (
    postgres_backup_destination_test_command as _postgres_backup_destination_test_command,
)
from ..postgres_backup import (
    postgres_backup_policy_apply_command as _postgres_backup_policy_apply_command,
)
from ..postgres_backup import (
    postgres_backup_policy_delete_command as _postgres_backup_policy_delete_command,
)
from ..postgres_backup import (
    postgres_backup_restore_format_check_command as _postgres_backup_restore_format_check_command,
)
from ..postgres_backup import (
    postgres_parse_backup_artifacts_output as _postgres_parse_backup_artifacts_output,
)
from ..postgres_backup import (
    postgres_parse_backup_cleanup_output as _postgres_parse_backup_cleanup_output,
)
from ..postgres_backup import (
    postgres_parse_backup_policy_cleanup_output as _postgres_parse_backup_policy_cleanup_output,
)
from ..postgres_backup import (
    postgres_parse_backup_run_output as _postgres_parse_backup_run_output,
)
from ..postgres_backup import postgres_walg_install_command as _postgres_walg_install_command
from ..postgres_backup import resolve_backup_destination as _resolve_backup_destination
from ..shell_output import parse_key_values as _parse_key_values

# ruff: noqa: F403, F405
from .agent_access import *
from .backup_support import *
from .database_lifecycle import (
    _postgres_drop_database_failure_details,
    _postgres_force_drop_database,
)
from .local_import_support import *
from .project_registry import (
    _ensure_postgres_project_registry,
    _postgres_registry_register_database_sql,
    _require_postgres_resource_owners,
)
from .service_configuration import *

_RESTORE_TARGET_CREATED_KEY = "restore_target_created"


# Lists one policy's artifacts, treating a missing storage prefix as "no
# artifacts yet" rather than an error. One owner for the list command, the
# missing-prefix classification, and the parse, shared by the artifact
# list, the backlog report, and the confirmed cleanup so all three read
# the same listing (#95). Returns (artifacts, None) on success -- including
# the missing-prefix empty case -- or (None, error_result).
def _list_backup_artifacts(ctx, session, backup_payload, remote_base_path, *, emit=None):
    list_command = (
        "set -eu; "
        + _backup_env_export_block(backup_payload["destination"])
        + f"wal-g st ls -r {shlex.quote(remote_base_path)}"
    )
    list_status, list_output = _run_postgres_host_command(
        ctx,
        session,
        list_command,
        emit=emit,
        timeout=180,
    )
    if not list_status:
        details = ctx.command_error_details(list_output) or "remote command failed"
        lowered = details.lower()
        if (
            "not found" in lowered
            or "no such file" in lowered
            or "404" in lowered
            or "key does not exist" in lowered
        ):
            return [], None
        return None, ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not list backup artifacts.",
            stage="execute_runtime_operation",
            details=details,
        )
    return (
        _postgres_parse_backup_artifacts_output(
            list_output,
            remote_base_path=remote_base_path,
        ),
        None,
    )


def _postgres_restore_failure_with_cleanup(
    ctx,
    session,
    config,
    database_name,
    emit,
    *,
    message,
    details,
):
    """Remove a failed restore target so the requested name stays retryable."""
    cleanup_status, cleanup_output = _postgres_force_drop_database(
        ctx,
        session,
        config,
        database_name,
        emit,
    )
    if not cleanup_status:
        cleanup_details = _postgres_drop_database_failure_details(
            ctx,
            cleanup_output,
            database_name,
        )
        details = f"{details} Cleanup also failed: {cleanup_details}"
    return ctx.error_result(
        "ENGINE_RUNTIME_ERROR",
        message,
        stage="execute_runtime_operation",
        details=details,
    )


def handle_backup_operation(request):
    ctx = request.ctx
    operation_id = request.operation_id
    postgres_config = request.postgres_config
    project_prefix = request.project_prefix
    session = request.session
    emit = request.emit

    if operation_id == "backup_policy_apply":
        try:
            backup_payload = _resolve_backup_policy_payload(
                postgres_config,
                project_prefix,
            )
        except PostgresConfigValidationError as exc:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                str(exc),
                stage="validate_request",
            )
        ownership_error = _require_postgres_resource_owners(
            ctx,
            session,
            postgres_config,
            emit,
            owned=(("database", backup_payload["database_name"]),),
        )
        if ownership_error is not None:
            return ownership_error

        install_status, install_output = _run_postgres_host_command(
            ctx,
            session,
            _postgres_walg_install_command(),
            emit=emit,
            timeout=300,
        )
        if not install_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not install wal-g.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(install_output) or "remote command failed",
            )

        apply_plan = _postgres_backup_policy_apply_command(
            postgres_config,
            policy_token=backup_payload["policy_token"],
            task_token=backup_payload["task_token"],
            policy_name=backup_payload["policy_name"],
            project_slug=backup_payload["project_slug"],
            database_name=backup_payload["database_name"],
            schedule_mode=backup_payload["schedule_mode"],
            time1=backup_payload["time1"],
            time2=backup_payload["time2"],
            retention_keep_last=backup_payload["retention_keep_last"],
            enabled=backup_payload["enabled"],
            destination=backup_payload["destination"],
        )
        apply_status, apply_output = _run_postgres_host_command(
            ctx,
            session,
            apply_plan["command"],
            emit=emit,
            timeout=180,
        )
        if not apply_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not apply backup policy.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(apply_output) or "remote command failed",
            )

        return {
            "status": "success",
            "code": "OK",
            "msg": "PostgreSQL backup policy applied.",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "backup_policy_id": backup_payload["policy_token"],
            "backup_task_id": backup_payload["task_token"],
            "backup_database_name": backup_payload["database_name"],
            "backup_destination_type": backup_payload["destination"]["type"],
            "backup_remote_base_path": apply_plan["remote_base_path"],
            "enabled": backup_payload["enabled"],
        }

    # coverage-gate: backup_policy_delete_cleanup
    if operation_id == "backup_policy_delete":
        try:
            policy_token = _normalize_backup_policy_token(
                postgres_config.backup_policy_id,
                "settings.backup_policy_id",
            )
        except PostgresConfigValidationError as exc:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                str(exc),
                stage="validate_request",
            )

        delete_command = _postgres_backup_policy_delete_command(
            postgres_config,
            policy_token,
        )
        delete_status, delete_output = _run_postgres_host_command(
            ctx,
            session,
            delete_command,
            emit=emit,
            timeout=90,
        )
        if not delete_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not delete backup policy.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(delete_output) or "remote command failed",
            )

        removed_policies = _postgres_parse_backup_policy_cleanup_output(delete_output)

        return {
            "status": "success",
            "code": "OK",
            "msg": "PostgreSQL backup policy deleted.",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "backup_policy_id": policy_token,
            "removed_backup_policies": removed_policies,
            "removed_backup_policy_count": len(removed_policies),
            "backup_logs_removed": True,
        }
    # end coverage-gate

    if operation_id == "backup_destination_test":
        try:
            destination = _resolve_backup_destination(postgres_config)
        except PostgresConfigValidationError as exc:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                str(exc),
                stage="validate_request",
            )

        if destination["type"] == "s3":
            install_status, install_output = _run_postgres_host_command(
                ctx,
                session,
                _postgres_walg_install_command(),
                emit=emit,
                timeout=300,
            )
            if not install_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not install wal-g.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(install_output) or "remote command failed",
                )

        test_plan = _postgres_backup_destination_test_command(destination)
        test_status, test_output = _run_postgres_host_command(
            ctx,
            session,
            test_plan["command"],
            emit=emit,
            timeout=180,
        )
        if not test_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "PostgreSQL backup destination test failed.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(test_output) or "remote command failed",
            )

        return {
            "status": "success",
            "code": "OK",
            "msg": "PostgreSQL backup destination test succeeded.",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "backup_destination_type": destination["type"],
            "tested_remote_path": test_plan["tested_remote_path"],
        }

    if operation_id == "backup_run_now":
        try:
            backup_payload = _resolve_backup_policy_payload(
                postgres_config,
                project_prefix,
            )
        except PostgresConfigValidationError as exc:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                str(exc),
                stage="validate_request",
            )
        ownership_error = _require_postgres_resource_owners(
            ctx,
            session,
            postgres_config,
            emit,
            owned=(("database", backup_payload["database_name"]),),
        )
        if ownership_error is not None:
            return ownership_error

        install_status, install_output = _run_postgres_host_command(
            ctx,
            session,
            _postgres_walg_install_command(),
            emit=emit,
            timeout=300,
        )
        if not install_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not install wal-g.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(install_output) or "remote command failed",
            )

        apply_plan = _postgres_backup_policy_apply_command(
            postgres_config,
            policy_token=backup_payload["policy_token"],
            task_token=backup_payload["task_token"],
            policy_name=backup_payload["policy_name"],
            project_slug=backup_payload["project_slug"],
            database_name=backup_payload["database_name"],
            schedule_mode=backup_payload["schedule_mode"],
            time1=backup_payload["time1"],
            time2=backup_payload["time2"],
            retention_keep_last=backup_payload["retention_keep_last"],
            enabled=backup_payload["enabled"],
            destination=backup_payload["destination"],
        )
        apply_status, apply_output = _run_postgres_host_command(
            ctx,
            session,
            apply_plan["command"],
            emit=emit,
            timeout=180,
        )
        if not apply_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not prepare backup runner.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(apply_output) or "remote command failed",
            )

        run_command = "set -eu; " + f"/bin/bash {shlex.quote(apply_plan['script_path'])}"
        run_status, run_output = _run_postgres_host_command(
            ctx,
            session,
            run_command,
            emit=emit,
            timeout=900,
        )
        if not run_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "PostgreSQL backup run failed.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(run_output) or "remote command failed",
            )

        artifact_path = _postgres_parse_backup_run_output(run_output)
        return {
            "status": "success",
            "code": "OK",
            "msg": "PostgreSQL logical backup completed.",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "backup_policy_id": backup_payload["policy_token"],
            "backup_task_id": backup_payload["task_token"],
            "backup_database_name": backup_payload["database_name"],
            "backup_artifact_path": artifact_path,
        }

    if operation_id == "backup_artifact_list":
        try:
            backup_payload = _resolve_backup_policy_payload(
                postgres_config,
                project_prefix,
            )
        except PostgresConfigValidationError as exc:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                str(exc),
                stage="validate_request",
            )
        install_status, install_output = _run_postgres_host_command(
            ctx,
            session,
            _postgres_walg_install_command(),
            emit=emit,
            timeout=300,
        )
        if not install_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not install wal-g.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(install_output) or "remote command failed",
            )

        remote_base_path = _backup_remote_base_path(
            backup_payload["project_slug"],
            backup_payload["policy_token"],
        )
        artifacts, list_error = _list_backup_artifacts(
            ctx,
            session,
            backup_payload,
            remote_base_path,
            emit=emit,
        )
        if list_error is not None:
            return list_error
        return {
            "status": "success",
            "code": "OK",
            "msg": "Backup artifacts listed.",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "backup_policy_id": backup_payload["policy_token"],
            "backup_remote_base_path": remote_base_path,
            "artifacts": artifacts,
        }

    if operation_id == "backup_backlog_report":
        try:
            backup_payload = _resolve_backup_policy_payload(
                postgres_config,
                project_prefix,
            )
        except PostgresConfigValidationError as exc:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                str(exc),
                stage="validate_request",
            )

        install_status, install_output = _run_postgres_host_command(
            ctx,
            session,
            _postgres_walg_install_command(),
            emit=emit,
            timeout=300,
        )
        if not install_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not install wal-g.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(install_output) or "remote command failed",
            )

        remote_base_path = _backup_remote_base_path(
            backup_payload["project_slug"],
            backup_payload["policy_token"],
        )
        artifacts, list_error = _list_backup_artifacts(
            ctx,
            session,
            backup_payload,
            remote_base_path,
            emit=emit,
        )
        if list_error is not None:
            return list_error
        backlog = _postgres_backlog_beyond_retention(
            artifacts,
            backup_payload["retention_keep_last"],
        )
        return {
            "status": "success",
            "code": "OK",
            "msg": "Backup backlog reported.",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "backup_policy_id": backup_payload["policy_token"],
            "backup_remote_base_path": remote_base_path,
            "retention_keep_last": backup_payload["retention_keep_last"],
            "retained_count": len(backlog["retained"]),
            "beyond_retention_count": backlog["beyond_retention_count"],
            "beyond_retention_bytes": backlog["beyond_retention_bytes"],
            "beyond_retention_unknown_size_count": backlog["beyond_retention_unknown_size_count"],
            "beyond_retention": backlog["beyond_retention"],
        }

    if operation_id == "backup_backlog_cleanup":
        try:
            backup_payload = _resolve_backup_policy_payload(
                postgres_config,
                project_prefix,
            )
        except PostgresConfigValidationError as exc:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                str(exc),
                stage="validate_request",
            )

        install_status, install_output = _run_postgres_host_command(
            ctx,
            session,
            _postgres_walg_install_command(),
            emit=emit,
            timeout=300,
        )
        if not install_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not install wal-g.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(install_output) or "remote command failed",
            )

        remote_base_path = _backup_remote_base_path(
            backup_payload["project_slug"],
            backup_payload["policy_token"],
        )
        artifacts, list_error = _list_backup_artifacts(
            ctx,
            session,
            backup_payload,
            remote_base_path,
            emit=emit,
        )
        if list_error is not None:
            return list_error
        # The doomed set is recomputed from a fresh listing here, never
        # taken from the report call: only beyond-retention artifacts from
        # this listing can be deleted, and the newest N can never be (#95).
        backlog = _postgres_backlog_beyond_retention(
            artifacts,
            backup_payload["retention_keep_last"],
        )
        beyond = backlog["beyond_retention"]
        if not beyond:
            return {
                "status": "success",
                "code": "OK",
                "msg": "No backup backlog beyond retention.",
                "operation_id": operation_id,
                "project_slug": postgres_config.project_slug,
                "backup_policy_id": backup_payload["policy_token"],
                "retention_keep_last": backup_payload["retention_keep_last"],
                "deleted_count": 0,
                "deleted_bytes": 0,
                "deleted": [],
                "manifests_missing": [],
            }
        cleanup_plan = _postgres_backup_backlog_cleanup_command(
            backup_payload["destination"],
            [item["remote_path"] for item in beyond],
        )
        cleanup_status, cleanup_output = _run_postgres_host_command(
            ctx,
            session,
            cleanup_plan["command"],
            emit=emit,
            timeout=1800,
        )
        parsed = _postgres_parse_backup_cleanup_output(cleanup_output)
        if not cleanup_status and not parsed["deleted"] and not parsed["failed"]:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "PostgreSQL backup backlog cleanup failed.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(cleanup_output) or "remote command failed",
            )
        if parsed["failed"]:
            if parsed["deleted"]:
                details = (
                    f"Deleted {len(parsed['deleted'])} artifact(s) before failing on: "
                    + ", ".join(parsed["failed"])
                )
            else:
                details = "Failed to delete: " + ", ".join(parsed["failed"])
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "PostgreSQL backup backlog cleanup failed.",
                stage="execute_runtime_operation",
                details=details,
            )
        sizes_by_key = {item["remote_path"]: item.get("size_bytes") for item in beyond}
        deleted_bytes = sum(
            size
            for size in (sizes_by_key.get(key) for key in parsed["deleted"])
            if isinstance(size, int)
        )
        return {
            "status": "success",
            "code": "OK",
            "msg": "Backup backlog cleaned up.",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "backup_policy_id": backup_payload["policy_token"],
            "retention_keep_last": backup_payload["retention_keep_last"],
            "deleted_count": len(parsed["deleted"]),
            "deleted_bytes": deleted_bytes,
            "deleted": parsed["deleted"],
            "manifests_missing": parsed["manifests_missing"],
        }

    if operation_id == "restore_run_now":
        # coverage-gate: restore_run_now_atomic_flow
        try:
            restore_payload = _resolve_backup_restore_payload(
                postgres_config,
                project_prefix,
            )
        except PostgresConfigValidationError as exc:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                str(exc),
                stage="validate_request",
            )
        ownership_error = _require_postgres_resource_owners(
            ctx,
            session,
            postgres_config,
            emit,
            creating=(("database", restore_payload["target_database_name"]),),
        )
        if ownership_error is not None:
            return ownership_error

        install_status, install_output = _run_postgres_host_command(
            ctx,
            session,
            _postgres_walg_install_command(),
            emit=emit,
            timeout=300,
        )
        if not install_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not install wal-g.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(install_output) or "remote command failed",
            )

        exists_sql = (
            "SELECT 1 FROM pg_database WHERE datname = "
            f"{_postgres_sql_literal(restore_payload['target_database_name'])};"
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
                "Could not validate restore target database.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(exists_output) or "remote command failed",
            )
        if _postgres_output_has_one(exists_output):
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "Target database already exists. Choose a new database name.",
                stage="validate_request",
            )

        registry_error = _ensure_postgres_project_registry(
            ctx,
            session,
            postgres_config,
            emit,
        )
        if registry_error is not None:
            return registry_error

        remote_restore_dir = f"/tmp/deploydash-postgres-restore-{secrets.token_hex(8)}.d"
        remote_dump_path = f"{remote_restore_dir}/restore.dump"
        revoke_public_sql = _postgres_revoke_public_connect_sql(
            restore_payload["target_database_name"],
        )
        restore_command = (
            _postgres_base_env_prefix(postgres_config)
            + _backup_env_export_block(restore_payload["destination"])
            + f"TARGET_DB={shlex.quote(restore_payload['target_database_name'])}; "
            + f"ARTIFACT_PATH={shlex.quote(restore_payload['artifact_path'])}; "
            + f"TMP_DIR={shlex.quote(remote_restore_dir)}; "
            + 'install -d -m 700 "${TMP_DIR}"; '
            + 'cleanup(){ rm -rf "${TMP_DIR}" >/dev/null 2>&1 || true; }; '
            + "trap cleanup EXIT INT TERM; "
            + _postgres_backup_restore_format_check_command()
            + "wal-g st get --no-decompress --no-decrypt "
            + '"${ARTIFACT_PATH}" '
            + shlex.quote(remote_dump_path)
            + "; "
            + 'docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" '
            + '"${CONTAINER_NAME}" '
            + 'createdb -U "${POSTGRES_USER}" "${TARGET_DB}"; '
            + "printf 'restore_target_created=1\\n'; "
            + 'docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" '
            + '"${CONTAINER_NAME}" psql -v ON_ERROR_STOP=1 '
            + '-U "${POSTGRES_USER}" -d postgres -c '
            + shlex.quote(revoke_public_sql)
            + "; "
            + _postgres_local_pg_restore_command(
                postgres_config,
                database_name=restore_payload["target_database_name"],
                remote_path=remote_dump_path,
                import_role=postgres_config.superuser_name,
                import_password=postgres_config.superuser_password,
                owner_role=postgres_config.superuser_name,
            )
        )
        restore_status, restore_output = _run_postgres_host_command(
            ctx,
            session,
            restore_command,
            emit=emit,
            timeout=1800,
        )
        if not restore_status:
            restore_details = ctx.command_error_details(restore_output) or "remote command failed"
            restore_values = _parse_key_values(restore_output)
            if restore_values.get(_RESTORE_TARGET_CREATED_KEY) == "1":
                return _postgres_restore_failure_with_cleanup(
                    ctx,
                    session,
                    postgres_config,
                    restore_payload["target_database_name"],
                    emit,
                    message="PostgreSQL restore failed.",
                    details=restore_details,
                )
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "PostgreSQL restore failed.",
                stage="execute_runtime_operation",
                details=restore_details,
            )

        verify_status, verify_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            "SELECT 1;",
            database=restore_payload["target_database_name"],
            emit=emit,
        )
        if not verify_status or not _postgres_output_has_one(verify_output):
            verify_details = ctx.command_error_details(verify_output)
            if not verify_details:
                verify_details = "PostgreSQL did not confirm the restored database is queryable."
            return _postgres_restore_failure_with_cleanup(
                ctx,
                session,
                postgres_config,
                restore_payload["target_database_name"],
                emit,
                message="Could not verify PostgreSQL restore.",
                details=verify_details,
            )

        register_status, register_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            _postgres_registry_register_database_sql(
                restore_payload["target_database_name"],
                postgres_config.project_slug,
            ),
            emit=emit,
        )
        if not register_status:
            return _postgres_restore_failure_with_cleanup(
                ctx,
                session,
                postgres_config,
                restore_payload["target_database_name"],
                emit,
                message="Could not register restored PostgreSQL database.",
                details=(ctx.command_error_details(register_output) or "remote command failed"),
            )

        return {
            "status": "success",
            "code": "OK",
            "msg": "PostgreSQL restore completed.",
            "operation_id": operation_id,
            "project_slug": postgres_config.project_slug,
            "backup_artifact_path": restore_payload["artifact_path"],
            "database_name": _postgres_strip_project_prefix(
                project_prefix,
                restore_payload["target_database_name"],
            ),
            "target_database_name": restore_payload["target_database_name"],
        }
        # end coverage-gate


__all__ = tuple(name for name in globals() if not name.startswith("__"))
