"""PostgreSQL major-version guard and upgrade operations (#86)."""

import re
import shlex
from datetime import UTC, datetime

from .. import server_paths, shell_output
from ..postgres_parts import SUPPORTED_POSTGRES_VERSIONS
from .backup_support import _wait_for_postgres_readiness
from .service_configuration import (
    _normalize_postgres_identifier,
    _postgres_apply_extensions_command,
    _postgres_base_env_bootstrap_command,
    _postgres_base_env_prefix,
    _postgres_compose_apply_command,
    _postgres_data_volume_target,
    _postgres_extension_image_build_command,
    _postgres_image_tag,
    _postgres_readiness_probe_command,
)
from .service_storage import (
    _fail_storage_migration_with_rollback,
    _postgres_find_pgdata_source_volume,
    _postgres_parse_storage_mounts,
    _postgres_storage_backup_compose_command,
    _postgres_storage_clean_name_lines,
    _postgres_storage_cleanup_compose_backup_command,
    _postgres_storage_detached_description,
    _postgres_storage_disk_space_command,
    _postgres_storage_expected_databases,
    _postgres_storage_first_output_line,
    _postgres_storage_inspect_mounts_command,
    _postgres_storage_inventory_queries,
    _postgres_storage_missing_expected_databases,
    _postgres_storage_stop_command,
    _postgres_storage_verify_final_mount,
    _postgres_upgrade_empty_ledger,
    _postgres_upgrade_encode_ledger,
    _postgres_upgrade_parse_ledger,
    _postgres_upgrade_read_ledger_command,
    _postgres_upgrade_write_ledger_command,
    _run_storage_host_command,
    _run_storage_psql_query,
    _storage_migration_cancelled,
)

_CONTAINER_IMAGE_MAJOR_PATTERN = re.compile(r":(\d+)\.")

_UPGRADE_ACTION_LABEL = "Upgrade PostgreSQL major version"
_UPGRADE_COMPOSE_BACKUP_SUFFIX = ".pre-major-upgrade"
_UPGRADE_GLOBALS_DUMP_NAME = "globals.sql"
_UPGRADE_SNAPSHOT_TABLE_LIMIT = 100


def _postgres_container_image_probe_command(config):
    """Build the probe printing the container's image, if it exists.

    The image tag names the major the container's binaries speak, running
    or stopped: Deploy Dash renders every tag as <major>.<patch>-bookworm,
    so one inspect answers the guard without touching the database (#86).
    """
    quoted_container_name = shlex.quote(config.container_name)
    # Quadrupled: the f-string renders two, which is what the Go template
    # needs. Single braces print literally with rc=0 (see the probe test).
    return f"docker inspect -f '{{{{.Config.Image}}}}' {quoted_container_name}"


def _postgres_parse_container_image_major(image):
    """Return the supported major an image tag names, else None.

    Matches the `:<digits>.` tag shape both the stock `postgres:17.x` tags
    and the `deploydash/postgres-ext:17.x-...` build tags share; anything
    else cannot be proven safe and parses as unknown (#86).
    """
    if not isinstance(image, str):
        return None
    match = _CONTAINER_IMAGE_MAJOR_PATTERN.search(image.strip())
    if match is None:
        return None
    major = match.group(1)
    if major not in SUPPORTED_POSTGRES_VERSIONS:
        return None
    return major


def refuse_postgres_major_version_change(
    ctx,
    session,
    config,
    *,
    emit,
    operation_id,
):
    """Refuse a configure that would swap the image major under live data.

    Returns an error result when the existing container's image names a
    different major than requested, or names none at all; otherwise None.
    A missing container means no live data, so a first configure proceeds,
    and a probe transport failure defers to the later steps, which report
    it with their own labels (#86).
    """
    status, output, _ = _run_storage_host_command(
        ctx,
        session,
        _postgres_container_image_probe_command(config),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    if not status:
        return None
    current_major = _postgres_parse_container_image_major(
        _postgres_storage_first_output_line(output),
    )
    if current_major is None:
        return ctx.error_result(
            "POSTGRES_MAJOR_VERSION_CHANGE_BLOCKED",
            "Could not determine the running PostgreSQL major version from "
            "the container image. Reconfigure with the current version, or "
            "run the service_upgrade_major operation to move versions.",
            stage="validate_request",
            extra={"operation_id": operation_id},
        )
    if current_major == config.postgres_version:
        return None
    return ctx.error_result(
        "POSTGRES_MAJOR_VERSION_CHANGE_BLOCKED",
        f"Database service is running PostgreSQL {current_major}; "
        f"configuring version {config.postgres_version} would start those "
        "binaries on the existing data directory and break the cluster. "
        "Run the service_upgrade_major operation to move versions.",
        stage="validate_request",
        extra={
            "operation_id": operation_id,
            "current_major": current_major,
            "requested_major": config.postgres_version,
        },
    )


def _postgres_upgrade_timestamp():
    """Stamp the dump directory in UTC basic format.

    Matches the managed-update backup stamps so pre-upgrade dumps sort
    and prune with the same tooling (#86).
    """
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def _postgres_upgrade_dump_dir(timestamp):
    """Return the STATE_ROOT directory holding one upgrade's dumps.

    The dumps live beside the managed-update safety backups rather than
    in the stack directory, so a failed upgrade's evidence survives
    compose rewrites and restores (#86).
    """
    return server_paths.upgrade_backup_dir("postgres", timestamp)


def _postgres_upgrade_makedir_command(dump_dir):
    """Create the dump directory readable only by its owner (#86)."""
    quoted_dump_dir = shlex.quote(dump_dir)
    return f"set -eu; mkdir -p {quoted_dump_dir} && chmod 700 {quoted_dump_dir}"


def _postgres_upgrade_target_volume_name(live_name, target_major, *, upgrade_stamp):
    """Derive the fresh volume name from the live one and the target.

    The major keeps pre-upgrade volumes identifiable and the attempt stamp
    guarantees a failed partial restore is never reused by a retry (#86).
    """
    return f"{live_name}_pg{target_major}_{upgrade_stamp.lower()}"


def _postgres_upgrade_throwaway_prefix(config):
    """Build the prelude running target-version clients over TCP.

    pg_dump must speak the TARGET major: dumping with the newer client
    is the supported cross-version direction. Same hardening as the
    local-import throwaway (#84): removed afterwards, read-only,
    no-new-privileges, reaching the server over the published port.
    """
    quoted_user = shlex.quote(
        _normalize_postgres_identifier(
            config.superuser_name,
            "settings.superuser_name",
        )
    )
    quoted_password = shlex.quote(config.superuser_password or "")
    quoted_image = shlex.quote(f"postgres:{_postgres_image_tag(config)}")
    quoted_port = shlex.quote(str(config.host_port))
    return (
        f"UPGRADE_USER={quoted_user}; "
        f"UPGRADE_PASSWORD={quoted_password}; "
        f"UPGRADE_IMAGE={quoted_image}; "
        f"UPGRADE_PORT={quoted_port}; "
        "docker run --rm -i --read-only --cap-drop ALL "
        "--security-opt no-new-privileges "
        "--add-host host.docker.internal:host-gateway "
        '-e PGPASSWORD="${UPGRADE_PASSWORD}" '
        '"${UPGRADE_IMAGE}" '
    )


def _postgres_upgrade_dump_globals_command(config, dump_path):
    """Dump roles and globals with the target binaries into 0600 (#86)."""
    quoted_dump = shlex.quote(dump_path)
    return (
        _postgres_base_env_prefix(config)
        + "(umask 077; "
        + _postgres_upgrade_throwaway_prefix(config)
        + 'pg_dumpall --globals-only -U "${UPGRADE_USER}" '
        + '-h host.docker.internal -p "${UPGRADE_PORT}" '
        + f"> {quoted_dump})"
    )


def _postgres_upgrade_dump_database_command(config, database, dump_path):
    """Dump one database in custom format with the target binaries (#86)."""
    quoted_database = shlex.quote(database)
    quoted_dump = shlex.quote(dump_path)
    return (
        _postgres_base_env_prefix(config)
        + "(umask 077; "
        + _postgres_upgrade_throwaway_prefix(config)
        + "pg_dump -Fc "
        + '-U "${UPGRADE_USER}" '
        + f"-d {quoted_database} "
        + '-h host.docker.internal -p "${UPGRADE_PORT}" '
        + f"> {quoted_dump})"
    )


def _postgres_upgrade_create_volume_command(volume_name):
    """Create the fresh named volume the target cluster will own (#86)."""
    return "set -eu; docker volume create " + shlex.quote(volume_name)


def _postgres_upgrade_restore_globals_command(config, dump_path):
    """Restore roles and globals into the target cluster.

    Runs without ON_ERROR_STOP: the fresh cluster already owns the
    superuser lines, so those specific errors are tolerated by the
    caller while any other failure rolls the upgrade back (#86).
    """
    quoted_dump = shlex.quote(dump_path)
    return (
        _postgres_base_env_prefix(config)
        + 'docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" '
        + '"${CONTAINER_NAME}" '
        + 'psql -U "${POSTGRES_USER}" -d postgres '
        + f"< {quoted_dump}"
    )


def _postgres_upgrade_restore_database_command(config, database, dump_path):
    """Restore one custom-format dump into the target cluster (#86).

    pg_restore runs inside the target container, so its binaries always
    match the server. Native create/clean restores the database owner,
    database ACL, comments and per-database settings from archive metadata;
    template1 is only the maintenance connection (#81, #82, #86).
    """
    quoted_dump = shlex.quote(dump_path)
    return (
        _postgres_base_env_prefix(config)
        + 'docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" '
        + '"${CONTAINER_NAME}" '
        + "pg_restore --exit-on-error --clean --create --if-exists "
        + '-U "${POSTGRES_USER}" '
        + "-d template1 "
        + f"< {quoted_dump}"
    )


def _postgres_upgrade_relations_snapshot_sql():
    """List every user relation with its kind for shape comparison (#86)."""
    return (
        "SELECT n.nspname || '.' || c.relname || ':' || c.relkind::text "
        "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') "
        "AND n.nspname NOT LIKE 'pg\\_%' "
        "AND c.relkind IN ('r', 'v', 'm', 'f', 'p') "
        "ORDER BY 1;"
    )


def _postgres_upgrade_user_tables_sql():
    """List the user tables row counts run over, bounded for sanity (#86)."""
    return (
        "SELECT format('%I.%I', n.nspname, c.relname) "
        "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') "
        "AND n.nspname NOT LIKE 'pg\\_%' "
        f"AND c.relkind = 'r' AND NOT c.relispartition "
        f"ORDER BY 1 LIMIT {_UPGRADE_SNAPSHOT_TABLE_LIMIT};"
    )


def _postgres_upgrade_row_counts_sql(tables):
    """Build one query counting every listed table, or None when empty.

    The table names arrive pre-quoted from the list query above, so the
    builder interpolates them verbatim; an empty list means there is
    nothing to count rather than an empty query (#86).
    """
    if not tables:
        return None
    parts = [f"SELECT {index} AS n, count(*) FROM {table}" for index, table in enumerate(tables)]
    return " UNION ALL ".join(parts) + " ORDER BY n;"


def _postgres_upgrade_extensions_snapshot_sql():
    """List installed extensions per database for re-apply comparison (#86)."""
    return "SELECT extname FROM pg_extension WHERE extname <> 'plpgsql' ORDER BY 1;"


def _postgres_upgrade_database_metadata_snapshot_sql():
    """Canonically list database ownership and effective database ACL entries.

    Major-upgrade verification must detect both an owner change and restored
    PostgreSQL defaults that silently reopen CONNECT or TEMP to PUBLIC (#81,
    #82, #86).
    """
    return (
        "SELECT 'owner=' || pg_get_userbyid(d.datdba) "
        "FROM pg_database d WHERE d.datname = current_database() "
        "UNION ALL "
        "SELECT 'acl=' || "
        "CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(acl.grantee) END "
        "|| '|' || pg_get_userbyid(acl.grantor) "
        "|| '|' || acl.privilege_type "
        "|| '|' || acl.is_grantable::text "
        "FROM pg_database d "
        "CROSS JOIN LATERAL aclexplode("
        "COALESCE(d.datacl, acldefault('d', d.datdba))"
        ") AS acl "
        "WHERE d.datname = current_database() "
        "ORDER BY 1;"
    )


def _postgres_upgrade_globals_tolerable(stderr_lines):
    """Report whether a failed globals restore failed only on existing roles.

    The fresh cluster already has the superuser, so its CREATE ROLE
    lines fail with "already exists" while every other line applies;
    that specific noise is tolerated, an empty or foreign stderr is
    not (#86).
    """
    meaningful = [str(line) for line in (stderr_lines or []) if str(line).strip()]
    if not meaningful:
        return False
    return all("already exists" in line for line in meaningful)


def _postgres_upgrade_output_line(output):
    """Return the first non-blank stdout line, or "" when absent (#86)."""
    return _postgres_storage_first_output_line(output) or ""


def _postgres_upgrade_snapshot_database(ctx, session, config, database, *, emit, operation_id):
    """Snapshot one database's restorable shape; (ok, snapshot, details).

    Relations, exact row counts over the user tables, and installed
    extensions run before the stop and again after the restore, and
    every list must match exactly, so the comparison proves the data
    moved rather than merely the container (#86).
    """
    relations_ok, relations_output, relations_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        _postgres_upgrade_relations_snapshot_sql(),
        emit=emit,
        operation_id=operation_id,
        database=database,
    )
    if not relations_ok:
        return (False, {}, relations_details)
    tables_ok, tables_output, tables_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        _postgres_upgrade_user_tables_sql(),
        emit=emit,
        operation_id=operation_id,
        database=database,
    )
    if not tables_ok:
        return (False, {}, tables_details)
    tables = _postgres_storage_clean_name_lines(tables_output)
    counts_sql = _postgres_upgrade_row_counts_sql(tables)
    if counts_sql is None:
        counts = None
    else:
        counts_ok, counts_output, counts_details = _run_storage_psql_query(
            ctx,
            session,
            config,
            counts_sql,
            emit=emit,
            operation_id=operation_id,
            database=database,
        )
        if not counts_ok:
            return (False, {}, counts_details)
        counts = _postgres_storage_clean_name_lines(counts_output)
    extensions_ok, extensions_output, extensions_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        _postgres_upgrade_extensions_snapshot_sql(),
        emit=emit,
        operation_id=operation_id,
        database=database,
    )
    if not extensions_ok:
        return (False, {}, extensions_details)
    metadata_ok, metadata_output, metadata_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        _postgres_upgrade_database_metadata_snapshot_sql(),
        emit=emit,
        operation_id=operation_id,
        database=database,
    )
    if not metadata_ok:
        return (False, {}, metadata_details)
    return (
        True,
        {
            "relations": _postgres_storage_clean_name_lines(relations_output),
            "counts": counts,
            "extensions": _postgres_storage_clean_name_lines(extensions_output),
            "database_metadata": _postgres_storage_clean_name_lines(metadata_output),
        },
        "",
    )


def run_postgres_major_upgrade(ctx, session, config, *, emit, is_cancelled, operation_id):
    """Move the cluster to another major by dump and restore (#86).

    Preflights the live layout, version, readiness, inventory and disk,
    dumps globals plus every database with the target binaries, switches
    to a fresh named volume, restores, re-applies extensions, and
    verifies shape and counts before declaring success. Anything after
    the stop rolls back to the snapshotted compose; the old volume is
    kept for rollback and explicit removal only.
    """
    cancelled = _storage_migration_cancelled(ctx, is_cancelled)
    if cancelled is not None:
        return cancelled
    ctx.emit_event(
        emit,
        "postgres_major_upgrade_phase",
        "Inspecting the live PostgreSQL layout.",
        data={"phase": "inspect"},
    )
    inspect_ok, inspect_output, inspect_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_storage_inspect_mounts_command(config),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    if not inspect_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not inspect the PostgreSQL storage layout.",
            stage="execute_runtime_operation",
            details=inspect_details,
            extra={"operation_id": operation_id},
        )
    try:
        mounts = _postgres_parse_storage_mounts(inspect_output)
    except ValueError:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not inspect the PostgreSQL storage layout.",
            stage="execute_runtime_operation",
            details="The container mounts were not valid JSON.",
            extra={"operation_id": operation_id},
        )
    datadir_ok, datadir_output, datadir_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        "SHOW data_directory;",
        emit=emit,
        operation_id=operation_id,
    )
    if not datadir_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not read the PostgreSQL data directory.",
            stage="execute_runtime_operation",
            details=datadir_details,
            extra={"operation_id": operation_id},
        )
    datadir = _postgres_upgrade_output_line(datadir_output)
    if not datadir:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not read the PostgreSQL data directory.",
            stage="execute_runtime_operation",
            details="The data directory query returned no output.",
            extra={"operation_id": operation_id},
        )
    source_mount = _postgres_find_pgdata_source_volume(mounts, datadir)
    if source_mount is None:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "No mounted volume backs PGDATA.",
            stage="execute_runtime_operation",
            details=f"The data directory {datadir} is not on a volume.",
            extra={"operation_id": operation_id},
        )
    source_name = source_mount.get("Name") or ""
    version_ok, version_output, version_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        "SHOW server_version;",
        emit=emit,
        operation_id=operation_id,
    )
    if not version_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not read the running PostgreSQL server version.",
            stage="execute_runtime_operation",
            details=version_details,
            extra={"operation_id": operation_id},
        )
    version_match = re.match(r"\d+", _postgres_upgrade_output_line(version_output))
    if version_match is None:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not parse the running PostgreSQL major version.",
            stage="execute_runtime_operation",
            details="The server version query returned no leading digits.",
            extra={"operation_id": operation_id},
        )
    source_major = version_match.group(0)
    requested_major = config.postgres_version
    if source_major == requested_major:
        return {
            "status": "success",
            "operation_id": operation_id,
            "already_on_version": True,
            "previous_major": source_major,
            "new_major": requested_major,
            "previous_volume": None,
            "new_volume": None,
            "upgraded_databases": [],
            "upgraded_roles": [],
            "dump_dir": None,
            "compose_backup_removed": True,
            "ledger_recorded": True,
        }
    ready_ok, _, ready_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_readiness_probe_command(config),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    if not ready_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "PostgreSQL service is not ready; start it before upgrading.",
            stage="execute_runtime_operation",
            details=ready_details,
            extra={"operation_id": operation_id},
        )
    inventory = _postgres_storage_inventory_queries()
    databases_ok, databases_output, databases_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        inventory["databases"],
        emit=emit,
        operation_id=operation_id,
    )
    if not databases_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not record the pre-upgrade inventory.",
            stage="execute_runtime_operation",
            details=databases_details,
            extra={"operation_id": operation_id},
        )
    roles_ok, roles_output, roles_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        inventory["roles"],
        emit=emit,
        operation_id=operation_id,
    )
    if not roles_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not record the pre-upgrade inventory.",
            stage="execute_runtime_operation",
            details=roles_details,
            extra={"operation_id": operation_id},
        )
    databases = _postgres_storage_clean_name_lines(databases_output)
    roles = _postgres_storage_clean_name_lines(roles_output)
    expected_ok, expected, expected_details = _postgres_storage_expected_databases(
        ctx, session, config, emit=emit, operation_id=operation_id
    )
    if not expected_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not read the managed database registry.",
            stage="execute_runtime_operation",
            details=expected_details,
            extra={"operation_id": operation_id},
        )
    missing = _postgres_storage_missing_expected_databases(expected, databases)
    if missing:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Refusing to upgrade: "
            + _postgres_storage_detached_description(missing, len(expected)),
            stage="validate_request",
            extra={"operation_id": operation_id},
        )
    disk_ok, disk_output, disk_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_storage_disk_space_command(config, source_name),
        emit=emit,
        timeout=300,
        operation_id=operation_id,
    )
    if not disk_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not measure the PostgreSQL disk space.",
            stage="execute_runtime_operation",
            details=disk_details,
            extra={"operation_id": operation_id},
        )
    disk_values = shell_output.parse_key_values(disk_output)
    try:
        data_bytes = int(disk_values["data_bytes"])
        avail_bytes = int(disk_values["avail_bytes"])
    except (TypeError, ValueError, KeyError):
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not measure the PostgreSQL disk space.",
            stage="execute_runtime_operation",
            details="The disk space output was not numeric.",
            extra={"operation_id": operation_id},
        )
    if avail_bytes < 2 * data_bytes:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Refusing to upgrade: free disk must be at least twice the "
            f"data size ({data_bytes} bytes); only {avail_bytes} available.",
            stage="validate_request",
            extra={"operation_id": operation_id},
        )
    pre_snapshots = {}
    for database in databases:
        snapshot_ok, snapshot, snapshot_details = _postgres_upgrade_snapshot_database(
            ctx,
            session,
            config,
            database,
            emit=emit,
            operation_id=operation_id,
        )
        if not snapshot_ok:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not record the pre-upgrade verification snapshot.",
                stage="execute_runtime_operation",
                details=snapshot_details,
                extra={"operation_id": operation_id},
            )
        pre_snapshots[database] = snapshot
    cancelled = _storage_migration_cancelled(ctx, is_cancelled)
    if cancelled is not None:
        return cancelled
    ctx.emit_event(
        emit,
        "postgres_major_upgrade_phase",
        "Dumping the cluster with the target binaries.",
        data={"phase": "dump"},
    )
    upgrade_stamp = _postgres_upgrade_timestamp()
    dump_dir = _postgres_upgrade_dump_dir(upgrade_stamp)
    mkdir_ok, _, mkdir_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_upgrade_makedir_command(dump_dir),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    if not mkdir_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not create the upgrade dump directory.",
            stage="execute_runtime_operation",
            details=mkdir_details,
            extra={"operation_id": operation_id},
        )
    globals_dump = f"{dump_dir}/{_UPGRADE_GLOBALS_DUMP_NAME}"
    globals_ok, _, globals_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_upgrade_dump_globals_command(config, globals_dump),
        emit=emit,
        timeout=1800,
        operation_id=operation_id,
    )
    if not globals_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not dump the PostgreSQL globals.",
            stage="execute_runtime_operation",
            details=globals_details,
            extra={"operation_id": operation_id},
        )
    for database in databases:
        dump_ok, _, dump_details = _run_storage_host_command(
            ctx,
            session,
            _postgres_upgrade_dump_database_command(
                config, database, f"{dump_dir}/{database}.dump"
            ),
            emit=emit,
            timeout=1800,
            operation_id=operation_id,
        )
        if not dump_ok:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                f"Could not dump the {database} database.",
                stage="execute_runtime_operation",
                details=dump_details,
                extra={"operation_id": operation_id},
            )
    cancelled = _storage_migration_cancelled(ctx, is_cancelled)
    if cancelled is not None:
        return cancelled
    build_ok, _, build_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_extension_image_build_command(config),
        emit=emit,
        timeout=1800,
        operation_id=operation_id,
    )
    if not build_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not build the PostgreSQL extension image.",
            stage="execute_runtime_operation",
            details=build_details,
            extra={"operation_id": operation_id},
        )
    cancelled = _storage_migration_cancelled(ctx, is_cancelled)
    if cancelled is not None:
        return cancelled
    backup_path = f"{config.stack_root}/docker-compose.yml{_UPGRADE_COMPOSE_BACKUP_SUFFIX}"
    backup_ok, _, backup_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_storage_backup_compose_command(config, backup_path),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    if not backup_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not back up the compose file before upgrading.",
            stage="execute_runtime_operation",
            details=backup_details,
            extra={"operation_id": operation_id},
        )
    stop_ok, _, stop_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_storage_stop_command(config),
        emit=emit,
        timeout=300,
        operation_id=operation_id,
    )
    if not stop_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not stop the PostgreSQL service before upgrading.",
            stage="execute_runtime_operation",
            details=stop_details,
            extra={"operation_id": operation_id},
        )
    ctx.emit_event(
        emit,
        "postgres_major_upgrade_phase",
        "Switching to the fresh target volume.",
        data={"phase": "switch"},
    )
    target_volume = _postgres_upgrade_target_volume_name(
        source_name,
        requested_major,
        upgrade_stamp=upgrade_stamp,
    )
    volume_ok, _, volume_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_upgrade_create_volume_command(target_volume),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    if not volume_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Could not create the target data volume.",
            details=volume_details,
        )
    rewrite_ok, _, rewrite_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_base_env_bootstrap_command(config, data_volume_name=target_volume),
        emit=emit,
        timeout=120,
        operation_id=operation_id,
    )
    if not rewrite_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Could not rewrite the compose file for the new volume.",
            details=rewrite_details,
        )
    up_ok, _, up_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_compose_apply_command(config),
        emit=emit,
        timeout=300,
        operation_id=operation_id,
    )
    if not up_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Could not start PostgreSQL on the new volume.",
            details=up_details,
        )
    ready = _wait_for_postgres_readiness(
        ctx,
        session,
        config,
        emit=emit,
        is_cancelled=is_cancelled,
        operation_id=operation_id,
    )
    if ready is not None:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="PostgreSQL did not become ready on the new volume.",
            details=ready["msg"],
        )
    ctx.emit_event(
        emit,
        "postgres_major_upgrade_phase",
        "Restoring the dumps into the target cluster.",
        data={"phase": "restore"},
    )
    restore_globals_ok, restore_globals_output, restore_globals_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_upgrade_restore_globals_command(config, globals_dump),
        emit=emit,
        timeout=600,
        operation_id=operation_id,
    )
    if not restore_globals_ok and not _postgres_upgrade_globals_tolerable(
        getattr(restore_globals_output, "stderr_lines", None)
    ):
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Could not restore the PostgreSQL globals.",
            details=restore_globals_details,
        )
    for database in databases:
        restore_ok, _, restore_details = _run_storage_host_command(
            ctx,
            session,
            _postgres_upgrade_restore_database_command(
                config, database, f"{dump_dir}/{database}.dump"
            ),
            emit=emit,
            timeout=1800,
            operation_id=operation_id,
        )
        if not restore_ok:
            return _fail_storage_migration_with_rollback(
                ctx,
                session,
                config,
                emit=emit,
                backup_path=backup_path,
                operation_id=operation_id,
                msg=f"Could not restore the {database} database.",
                details=restore_details,
            )
    cancelled = _storage_migration_cancelled(ctx, is_cancelled)
    if cancelled is not None:
        return cancelled
    extensions_ok, _, extensions_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_apply_extensions_command(config),
        emit=emit,
        timeout=600,
        operation_id=operation_id,
    )
    if not extensions_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Could not apply the PostgreSQL extensions.",
            details=extensions_details,
        )
    cancelled = _storage_migration_cancelled(ctx, is_cancelled)
    if cancelled is not None:
        return cancelled
    ctx.emit_event(
        emit,
        "postgres_major_upgrade_phase",
        "Verifying the upgraded cluster.",
        data={"phase": "verify"},
    )
    version_post_ok, version_post_output, version_post_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        "SHOW server_version;",
        emit=emit,
        operation_id=operation_id,
    )
    if not version_post_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Upgrade verification failed: could not read the target version.",
            details=version_post_details,
        )
    version_post_match = re.match(r"\d+", _postgres_upgrade_output_line(version_post_output))
    if version_post_match is None or version_post_match.group(0) != requested_major:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Upgrade verification failed: the target cluster does not "
            f"report PostgreSQL {requested_major}.",
            details="The server version query disagreed with the target.",
        )
    datadir_post_ok, datadir_post_output, datadir_post_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        "SHOW data_directory;",
        emit=emit,
        operation_id=operation_id,
    )
    if not datadir_post_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Upgrade verification failed: could not read the data directory.",
            details=datadir_post_details,
        )
    if _postgres_upgrade_output_line(datadir_post_output) != datadir:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Upgrade verification failed: the data directory moved.",
            details="The target cluster reports a different data directory.",
        )
    databases_post_ok, databases_post_output, databases_post_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        inventory["databases"],
        emit=emit,
        operation_id=operation_id,
    )
    if not databases_post_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Upgrade verification failed: could not list databases.",
            details=databases_post_details,
        )
    roles_post_ok, roles_post_output, roles_post_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        inventory["roles"],
        emit=emit,
        operation_id=operation_id,
    )
    if not roles_post_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Upgrade verification failed: could not list roles.",
            details=roles_post_details,
        )
    new_databases = _postgres_storage_clean_name_lines(databases_post_output)
    new_roles = _postgres_storage_clean_name_lines(roles_post_output)
    if new_databases != databases or new_roles != roles:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Upgrade verification failed: the database or role inventory "
            "differs from the pre-upgrade snapshot.",
            details="Inventory comparison failed.",
        )
    for database in databases:
        snapshot_ok, snapshot, snapshot_details = _postgres_upgrade_snapshot_database(
            ctx,
            session,
            config,
            database,
            emit=emit,
            operation_id=operation_id,
        )
        if not snapshot_ok:
            return _fail_storage_migration_with_rollback(
                ctx,
                session,
                config,
                emit=emit,
                backup_path=backup_path,
                operation_id=operation_id,
                msg=f"Upgrade verification failed: could not re-snapshot the {database} database.",
                details=snapshot_details,
            )
        if snapshot != pre_snapshots[database]:
            return _fail_storage_migration_with_rollback(
                ctx,
                session,
                config,
                emit=emit,
                backup_path=backup_path,
                operation_id=operation_id,
                msg="Upgrade verification failed: the restored data differs "
                f"from the pre-upgrade snapshot of {database}.",
                details="Snapshot comparison failed.",
            )
    final_ok, final_output, final_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_storage_inspect_mounts_command(config),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    if not final_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Upgrade verification failed: could not re-inspect the mounts.",
            details=final_details,
        )
    try:
        final_mounts = _postgres_parse_storage_mounts(final_output)
    except ValueError:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Upgrade verification failed: the final mounts are not valid JSON.",
            details="Mount inspection output could not be parsed.",
        )
    live_mounts_ok, live_mounts_detail, live_mount = _postgres_storage_verify_final_mount(
        final_mounts, datadir, _postgres_data_volume_target(config)
    )
    if not live_mounts_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Upgrade verification failed: " + live_mounts_detail,
            details="Final mount comparison failed.",
        )
    if (live_mount.get("Name") or "") != target_volume:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Upgrade verification failed: PGDATA is not on the new volume.",
            details="Final mount comparison failed.",
        )
    ledger_recorded = False
    retain_ok, retain_output, _ = _run_storage_host_command(
        ctx,
        session,
        _postgres_upgrade_read_ledger_command(),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    retain_raw = _postgres_upgrade_output_line(retain_output) if retain_ok else None
    retain_base = None
    if retain_raw is None:
        retain_error = "the upgrade ledger could not be read"
    elif not retain_raw.strip():
        retain_base = _postgres_upgrade_empty_ledger()
        retain_error = None
    else:
        try:
            retain_base = _postgres_upgrade_parse_ledger(retain_raw)
            retain_error = None
        except ValueError as exc:
            retain_error = str(exc)
    if retain_error is not None:
        ctx.emit_event(
            emit,
            "postgres_upgrade_ledger_warning",
            "The upgrade succeeded but the previous volume could not be "
            f"recorded in the upgrade ledger ({retain_error}); remove that "
            "volume only explicitly.",
            data={"volume": source_name},
        )
    else:
        retain_base["retained_volumes"].append(
            {
                "volume": source_name,
                "from_major": source_major,
                "to_major": requested_major,
                "upgraded_at": upgrade_stamp,
                "dump_dir": dump_dir,
            }
        )
        retain_write_ok, _, _ = _run_storage_host_command(
            ctx,
            session,
            _postgres_upgrade_write_ledger_command(_postgres_upgrade_encode_ledger(retain_base)),
            emit=emit,
            timeout=60,
            operation_id=operation_id,
        )
        if retain_write_ok:
            ledger_recorded = True
        else:
            ctx.emit_event(
                emit,
                "postgres_upgrade_ledger_warning",
                "The upgrade succeeded but the previous volume could not be "
                "recorded in the upgrade ledger (the ledger could not be "
                "written); remove that volume only explicitly.",
                data={"volume": source_name},
            )
    cleanup_ok, _, _ = _run_storage_host_command(
        ctx,
        session,
        _postgres_storage_cleanup_compose_backup_command(config, backup_path),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    if not cleanup_ok:
        ctx.emit_event(
            emit,
            "postgres_upgrade_compose_backup_warning",
            "Upgrade succeeded but the compose backup could not be removed.",
            data={"phase": "cleanup", "backup_path": backup_path},
        )
    return {
        "status": "success",
        "operation_id": operation_id,
        "already_on_version": False,
        "previous_major": source_major,
        "new_major": requested_major,
        "previous_volume": source_name,
        "new_volume": target_volume,
        "upgraded_databases": databases,
        "upgraded_roles": roles,
        "dump_dir": dump_dir,
        "compose_backup_removed": bool(cleanup_ok),
        "ledger_recorded": ledger_recorded,
    }


__all__ = tuple(name for name in globals() if not name.startswith("__"))
