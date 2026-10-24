"""Named-volume storage layout and migration for the PostgreSQL service (#85).

The 16/17 images nest the real data in an anonymous volume under the old
parent mount; this module owns the inspection, safety copy, migration and
status-shape builders that move every major onto the unified layout where
``postgres_data`` carries ``PGDATA`` directly.
"""

import contextlib
import json
import re

from .. import server_paths, shell_output
from ..container_status import normalize_container_status
from ..runtime_ops import run_shell_command
from .agent_access import _run_postgres_psql_query_impl
from .backup_support import _wait_for_postgres_readiness
from .project_registry import _postgres_registry_list_databases_sql

# ruff: noqa: F403, F405
from .service_configuration import *

_ANONYMOUS_VOLUME_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def _postgres_storage_inspect_mounts_command(config):
    """Build the command recording which volumes the container mounts.

    The migration's first step: the mount list identifies the anonymous
    volume holding PGDATA under the old layout, and proves the named
    volume carries it after the move (#85).
    """
    quoted_container_name = shlex.quote(config.container_name)
    return f"set -eu; docker inspect -f '{{{{json .Mounts}}}}' {quoted_container_name}"


def _postgres_parse_storage_mounts(output):
    """Parse `docker inspect` mount JSON into mount records, failing closed.

    Every entry must be an object: silently skipping a malformed record
    could identify the wrong volume as the PGDATA source and migrate the
    wrong bytes, so anything unexpected raises instead (#85).
    """
    stdout_lines = getattr(output, "stdout_lines", None) or []
    text = "\n".join(str(line) for line in stdout_lines if str(line).strip())
    if not text:
        raise ValueError("PostgreSQL storage mounts output was empty.")
    try:
        mounts = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError("PostgreSQL storage mounts output was not valid JSON.") from exc
    if not isinstance(mounts, list):
        raise ValueError("PostgreSQL storage mounts output must be a JSON array.")
    for mount in mounts:
        if not isinstance(mount, dict):
            raise ValueError("PostgreSQL storage mounts entries must be objects.")
    return mounts


def _postgres_find_pgdata_source_volume(mounts, pgdata_path):
    """Find the mount backing PGDATA: the deepest destination containing it.

    Under the old layout that is the anonymous nested mount, not the named
    parent; after migration it is the named volume itself. The match needs
    a path boundary, so a sibling such as .../data2 never matches (#85).
    """
    normalized_pgdata = str(pgdata_path).rstrip("/") or "/"
    best = None
    best_length = -1
    for mount in mounts:
        destination = str(mount.get("Destination") or "").rstrip("/") or "/"
        if normalized_pgdata != destination and not normalized_pgdata.startswith(destination + "/"):
            continue
        if len(destination) > best_length:
            best = mount
            best_length = len(destination)
    return best


def _postgres_storage_volume_is_anonymous(volume_name):
    """Report whether a volume name is a Docker-generated anonymous id.

    Anonymous volumes carry 64 lowercase hex characters; anything else is
    a named volume. The migration refuses to treat a named volume as the
    disposable old copy (#85).
    """
    return bool(_ANONYMOUS_VOLUME_PATTERN.match(str(volume_name or "")))


def _postgres_storage_disk_space_command(config, source_volume):
    """Build the command measuring the data size against free disk.

    Emits data_bytes for the source volume's mountpoint and avail_bytes
    for its filesystem, so the migration can require room for the safety
    dump before taking it (#85).
    """
    quoted_volume = shlex.quote(source_volume)
    return (
        "set -eu; "
        f"SRC_VOLUME={quoted_volume}; "
        "SRC_MOUNT=\"$(docker volume inspect -f '{{.Mountpoint}}' "
        '"${SRC_VOLUME}")"; '
        'DATA_BYTES="$(du -sb "${SRC_MOUNT}" | cut -f1)"; '
        'AVAIL_BYTES="$(df -B1 --output=avail "${SRC_MOUNT}" '
        "| tail -n1 | tr -d ' ')\"; "
        'printf "data_bytes=%s\\n" "${DATA_BYTES}"; '
        'printf "avail_bytes=%s\\n" "${AVAIL_BYTES}"'
    )


def _postgres_storage_safety_dump_command(config, dump_path):
    """Build the command taking a break-glass pg_dumpall before migration.

    The dump runs while the service is still up and lands mode 0600 via
    umask, so unlike the #92 world-readable backups it is never exposed;
    rollback restores the compose onto the untouched source volume, and
    this file covers anything worse (#85).
    """
    quoted_dump_path = shlex.quote(dump_path)
    return (
        _postgres_base_env_prefix(config)
        + "(umask 077; "
        + 'docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" '
        + '"${CONTAINER_NAME}" '
        + 'pg_dumpall -U "${POSTGRES_USER}" '
        + f"> {quoted_dump_path})"
    )


def _postgres_storage_stop_command(config):
    """Build the command stopping the container without detaching volumes.

    `stop` keeps containers and their mounts; `down` would detach the very
    anonymous volume the migration is about to rescue. The two-minute
    grace period lets PostgreSQL checkpoint cleanly instead of being
    killed mid-write and recovering on the next start (#85).
    """
    quoted_compose_file = shlex.quote(f"{config.stack_root}/docker-compose.yml")
    return (
        f"COMPOSE_FILE={quoted_compose_file}; "
        "if docker compose version >/dev/null 2>&1; then "
        'docker compose -f "${COMPOSE_FILE}" stop -t 120; '
        "elif command -v docker-compose >/dev/null 2>&1; then "
        'docker-compose -f "${COMPOSE_FILE}" stop -t 120; '
        "else "
        "echo 'docker compose is unavailable.' >&2; "
        "exit 1; "
        "fi"
    )


_SAFE_STORAGE_SUBPATH_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$")


def _postgres_checked_storage_subpath(subpath):
    """Validate a volume-relative subpath before shell interpolation.

    The copy source derives from SHOW data_directory on the server, so a
    hostile or surprising value must fail here rather than reach the
    helper shell; empty means the volume root itself (#85).
    """
    if not subpath:
        return ""
    if not _SAFE_STORAGE_SUBPATH_PATTERN.match(str(subpath)):
        raise ValueError(
            f"Refusing unsafe storage subpath: {subpath!r}.",
        )
    if "/../" in f"/{subpath}/":
        raise ValueError(
            f"Refusing unsafe storage subpath: {subpath!r}.",
        )
    return str(subpath)


def _postgres_storage_copy_command(config, source_volume, target_volume, source_subpath=""):
    """Build the helper-container command copying PGDATA into place.

    Mounts the source read-only and the named volume read-write, wipes
    any partial target from an earlier run, then copies with ownership
    preserved and fixes the result to postgres:postgres 0700. The source
    subpath is empty for 16/17 (PGDATA is the volume root) and 18/docker
    for old-layout 18, where source and target are the same volume (#85).
    """
    checked_subpath = _postgres_checked_storage_subpath(source_subpath)
    quoted_source = shlex.quote(source_volume)
    quoted_target = shlex.quote(target_volume)
    quoted_image = shlex.quote(_postgres_runtime_image_name(config))
    from_path = "/from" if not checked_subpath else f"/from/{checked_subpath}"
    return (
        "set -eu; "
        "docker run --rm --network none "
        f"-v {quoted_source}:/from:ro "
        f"-v {quoted_target}:/to "
        f"{quoted_image} "
        + "sh -c 'rm -rf /to/pgdata && mkdir -p /to/pgdata && "
        + f"cp -a {from_path}/. /to/pgdata/ && "
        + "chown -R postgres:postgres /to/pgdata && chmod 0700 /to/pgdata'"
    )


def _postgres_storage_backup_compose_command(config, backup_path):
    """Build the command snapshotting the compose file before migration.

    First backup wins across re-runs: after a failed migration the live
    compose may already be the new one, and overwriting the snapshot
    would lose the original rollback target (#85).
    """
    quoted_compose_file = shlex.quote(f"{config.stack_root}/docker-compose.yml")
    quoted_backup = shlex.quote(backup_path)
    return (
        "set -eu; "
        f"COMPOSE_FILE={quoted_compose_file}; "
        f"BACKUP_FILE={quoted_backup}; "
        'cp -n "${COMPOSE_FILE}" "${BACKUP_FILE}"'
    )


def _postgres_storage_restore_compose_command(config, backup_path):
    """Build the command restoring the pre-migration compose on failure."""
    quoted_compose_file = shlex.quote(f"{config.stack_root}/docker-compose.yml")
    quoted_backup = shlex.quote(backup_path)
    return (
        "set -eu; "
        f"COMPOSE_FILE={quoted_compose_file}; "
        f"BACKUP_FILE={quoted_backup}; "
        'cp "${BACKUP_FILE}" "${COMPOSE_FILE}"'
    )


def _postgres_storage_cleanup_compose_backup_command(config, backup_path):
    """Build the command dropping the compose snapshot after success."""
    quoted_backup = shlex.quote(backup_path)
    return "set -eu; " + f"rm -f {quoted_backup}"


def _postgres_storage_inventory_queries():
    """Return the database and user-role listings compared across a move.

    Both run before the stop and again after the move; the ordered lists
    must match exactly, proving no database or role was lost (#85).
    Predefined pg_* roles are excluded: they ship with the binaries and
    change between majors (17 adds pg_maintain), so comparing them would
    fail every cross-version move on system noise (#86).
    """
    return {
        "databases": ("SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname;"),
        "roles": ("SELECT rolname FROM pg_roles WHERE rolname NOT LIKE 'pg\\_%' ORDER BY rolname;"),
    }


def _postgres_storage_data_size_sql():
    """Return the query totaling live database sizes in bytes.

    Pure SQL beats shelling du into the container: one read the status
    flow already knows how to make, with no mountpoint to resolve (#85).
    """
    return "SELECT COALESCE(sum(pg_database_size(datname)), 0) FROM pg_database;"


def _postgres_storage_dangling_volumes_command(config):
    """Build the command listing detached volumes for ledger reconciliation.

    Docker cannot attribute a dangling volume to Deploy Dash. Status therefore
    intersects this raw list with the retained-volume ledger before exposing
    any cleanup candidate; the global list is never user-actionable (#85).
    """
    return "set -eu; docker volume ls -q -f dangling=true"


def _postgres_storage_detached_description(missing, expected_count):
    """Describe expected databases absent from the live cluster.

    One owner for the detachment wording: the migration refusal and the
    status error share it, naming what is missing and how to recover
    without pruning anything (#85).
    """
    if len(missing) == expected_count:
        expectation = f"none of the {expected_count} databases Deploy Dash expects"
    else:
        expectation = (
            f"{len(missing)} of the {expected_count} "
            f"databases Deploy Dash expects ({', '.join(missing)})"
        )
    return (
        f"this cluster has {expectation}; "
        "the data volume may be detached. List candidates with "
        "`docker volume ls -f dangling=true`, and do not run "
        "`docker volume prune` until it is resolved."
    )


_POSTGRES_UPGRADE_LEDGER_FORMAT_VERSION = 1
_POSTGRES_UPGRADE_LEDGER_WRITE_DELIMITER = "__DEPLOYDASH_POSTGRES_UPGRADE_EOF__"


def _postgres_upgrade_empty_ledger():
    """Return a ledger recording no retained volumes (#86)."""
    return {
        "format_version": _POSTGRES_UPGRADE_LEDGER_FORMAT_VERSION,
        "retained_volumes": [],
    }


def _postgres_upgrade_parse_ledger(raw):
    """Parse the retained-volumes ledger, failing only on versions.

    Mirrors the managed-software ledger contract: missing, corrupt, or
    misshapen content reads as empty (a fresh server has no file), while
    a missing or unknown format_version raises rather than guessing
    compatibility, so writers never silently append to a newer shape
    (#86).
    """
    if not raw:
        return _postgres_upgrade_empty_ledger()
    try:
        decoded = json.loads(raw)
    except (TypeError, ValueError):
        return _postgres_upgrade_empty_ledger()
    if not isinstance(decoded, dict):
        return _postgres_upgrade_empty_ledger()
    if decoded.get("format_version") != _POSTGRES_UPGRADE_LEDGER_FORMAT_VERSION:
        raise ValueError(
            "PostgreSQL upgrade ledger format_version "
            f"{decoded.get('format_version')!r} is not supported by this "
            "build (expected "
            f"{_POSTGRES_UPGRADE_LEDGER_FORMAT_VERSION})."
        )
    entries = decoded.get("retained_volumes")
    if not isinstance(entries, list):
        entries = []
    return {
        "format_version": _POSTGRES_UPGRADE_LEDGER_FORMAT_VERSION,
        "retained_volumes": [
            entry
            for entry in entries
            if isinstance(entry, dict) and isinstance(entry.get("volume"), str) and entry["volume"]
        ],
    }


def _postgres_upgrade_encode_ledger(ledger):
    """Encode the ledger canonically after normalizing it (#86)."""
    normalized = _postgres_upgrade_parse_ledger(json.dumps(ledger))
    return json.dumps(normalized, sort_keys=True, separators=(",", ":"))


def _postgres_upgrade_read_ledger_command():
    """Build the best-effort command printing the ledger, if any (#86)."""
    quoted_ledger = shlex.quote(server_paths.postgres_upgrade_ledger())
    return f"cat {quoted_ledger} 2>/dev/null || true"


def _postgres_upgrade_write_ledger_command(content):
    """Build the command replacing the ledger with content (#86).

    The heredoc delimiter cannot appear in the content by construction:
    canonical ledger JSON holds only volume names (docker charset),
    major digits, UTC stamps, and state-root paths.
    """
    quoted_ledger = shlex.quote(server_paths.postgres_upgrade_ledger())
    delimiter = _POSTGRES_UPGRADE_LEDGER_WRITE_DELIMITER
    return f"cat > {quoted_ledger} <<'{delimiter}'\n{content}\n{delimiter}\n"


def _postgres_storage_detached_container_status(container_status, storage_error):
    """Rebuild a container status with detachment as failed readiness.

    The container is up but the data is not: every status consumer must
    see unhealthy rather than ready, with the recovery pointers carried
    as the readiness detail. Rebuilt through the container-status owner
    so the verdict derives from the same fields, never a forged word
    (#85).
    """
    return normalize_container_status(
        present=container_status.get("present"),
        docker_state=container_status.get("docker_state"),
        running=container_status.get("running"),
        health=container_status.get("health"),
        exit_code=container_status.get("exit_code"),
        image=container_status.get("image"),
        started_at=container_status.get("started_at"),
        readiness_status="unhealthy",
        readiness_detail=storage_error,
    )


def _postgres_storage_expected_databases(ctx, session, config, *, emit, operation_id):
    """Return (ok, expected_list, details) for the managed databases.

    A readable registry is the live source of truth. A missing schema
    means a fresh service or a detached cluster, so the desktop's known
    databases stand in: the registry travels with the data and cannot
    report on its own absence. Any other read failure is real. Both the
    migration guard and status enrichment use this, so detachment is
    assessed the same way in both (#85).
    """
    ok, output, details = _run_storage_psql_query(
        ctx,
        session,
        config,
        _postgres_registry_list_databases_sql(),
        emit=emit,
        operation_id=operation_id,
    )
    if not ok and "does not exist" in details:
        # No registry schema: a fresh service or a detached cluster,
        # indistinguishable from inside. The registry travels with the
        # data, so only the desktop's known databases can tell them
        # apart: empty for a fresh service (silent), naming the lost
        # databases for a detached one (fire) (#85).
        return (True, list(config.expected_databases or ()), "")
    if not ok:
        return (False, [], details)
    return (True, _postgres_storage_clean_name_lines(output), "")


def _postgres_storage_remove_volume_command(config, volume_name):
    """Build the guarded command removing a detached legacy volume.

    Refuses when any container still references the volume, so the
    "remove old copy" action cannot delete data that is still live (#85).
    """
    quoted_volume = shlex.quote(volume_name)
    return (
        "set -eu; "
        f"VOL={quoted_volume}; "
        'if [ -n "$(docker ps -q --filter "volume=${VOL}")" ]; then '
        "(echo 'Storage volume is still in use; refusing to remove it.' >&2; exit 1); "
        "fi; "
        'docker volume rm "${VOL}"'
    )


def _postgres_storage_remove_legacy_subdir_command(config, volume_name, subpath):
    """Build the helper-container command clearing a versioned leftover.

    Old-layout 18 keeps its previous data at 18/docker inside the named
    volume, which must stay; only the leftover subdirectory goes (#85).
    """
    checked_subpath = _postgres_checked_storage_subpath(subpath)
    if not checked_subpath:
        raise ValueError("Refusing unsafe storage subpath: ''.")
    quoted_volume = shlex.quote(volume_name)
    quoted_image = shlex.quote(_postgres_runtime_image_name(config))
    return (
        "set -eu; "
        "docker run --rm --network none "
        f"-v {quoted_volume}:/data "
        f"{quoted_image} " + f"sh -c 'rm -rf /data/{checked_subpath}'"
    )


def _postgres_storage_missing_expected_databases(expected_datnames, live_datnames):
    """Return the expected databases absent from the live cluster, sorted.

    Both sides are exact identifiers, so membership is exact too: no
    prefix or pattern matching that could cross database boundaries. An
    empty expectation means nothing can be missing, which keeps a fresh
    service silent (#85).
    """
    live = set(live_datnames or ())
    return sorted(name for name in (expected_datnames or ()) if name not in live)


def _postgres_storage_clean_name_lines(output):
    """Return stripped non-blank psql -tA lines as a name list."""
    stdout_lines = getattr(output, "stdout_lines", None) or []
    return [str(line).strip() for line in stdout_lines if str(line).strip()]


def _postgres_storage_first_output_line(output):
    """Return the first non-blank psql -tA line, or None when absent."""
    for raw_line in getattr(output, "stdout_lines", None) or []:
        line = str(raw_line).strip()
        if line:
            return line
    return None


_STORAGE_MIGRATE_ACTION_LABEL = "Migrate PostgreSQL storage layout"
_STORAGE_REMOVE_ACTION_LABEL = "Remove legacy PostgreSQL storage"
_STORAGE_MIGRATION_COMPOSE_BACKUP_SUFFIX = ".pre-storage-migration"
_STORAGE_MIGRATION_SAFETY_DUMP_NAME = "storage-migration-safety.sql"
_STORAGE_LEGACY_PARENT_MOUNT = "/var/lib/postgresql"


def _storage_migration_cancelled(ctx, is_cancelled):
    """Return a cancellation error when the task was cancelled, else None.

    One owner for the between-steps cancel checks: the migration runs
    several long shell steps, and each window between them must stop the
    same way (#85).
    """
    if callable(is_cancelled) and is_cancelled():
        return ctx.error_result(
            "ENGINE_TASK_CANCELLED",
            "Task cancelled during PostgreSQL operation",
            stage="execute_runtime_operation",
        )
    return None


def _run_storage_host_command(ctx, session, command, *, emit, timeout, operation_id):
    """Run one storage shell step; return (ok, output, details).

    Goes through the shared runtime_ops helper so the result shape is
    the same everywhere. Exceptions from the transport become failures
    with the exception text, so a dropped SSH connection reports instead
    of escaping the handler and skipping the migration rollback (#85).
    """
    try:
        result = run_shell_command(
            session.host,
            command,
            timeout=timeout,
            sudo=True,
            emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
        )
    except Exception as exc:
        return (False, None, str(exc))
    if not result["ok"]:
        return (False, result["output"], result["details"])
    return (True, result["output"], "")


def _run_storage_psql_query(ctx, session, config, sql, *, emit, operation_id, database="postgres"):
    """Run one storage SQL read; return (ok, output, details).

    Same failure contract as the shell step above: the migration issues
    inventory and verification reads throughout, and every one of them
    must fail into an error result rather than out of the handler (#85).
    The database defaults to postgres; per-database verification reads
    pass their own (#86).
    """
    try:
        status, output = _run_postgres_psql_query_impl(
            ctx,
            session,
            config,
            sql,
            emit=emit,
            database=database,
        )
    except Exception as exc:
        return (False, None, str(exc))
    if not status:
        return (
            False,
            output,
            ctx.command_error_details(output) or "remote command failed",
        )
    return (True, output, "")


def _rollback_storage_migration_to_backup(ctx, session, config, *, emit, backup_path, operation_id):
    """Restore the pre-migration compose and restart; (ok, detail).

    Runs to completion even when the task was cancelled: a failed
    migration must leave a running service or a precise error, never a
    maybe-state. The source volume was only ever read, so the previous
    compose brings back the previous data (#85).
    """
    restore_ok, _, restore_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_storage_restore_compose_command(config, backup_path),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    if not restore_ok:
        return (
            False,
            f"could not restore the previous compose file: {restore_details}",
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
        return (
            False,
            f"previous compose restored but start failed: {up_details}",
        )
    readiness_error = _wait_for_postgres_readiness(
        ctx,
        session,
        config,
        emit=emit,
        operation_id=operation_id,
    )
    if readiness_error is not None:
        return (
            False,
            f"previous compose restored but service is not ready: {readiness_error.get('details')}",
        )
    return (True, "previous compose restored and service restarted")


def _fail_storage_migration_with_rollback(
    ctx, session, config, *, emit, backup_path, operation_id, msg, details
):
    """Roll back a failed migration step and report both outcomes.

    One owner for the rollback error shape: the step's own message stays
    the headline, and the details append whether the rollback back to the
    previous compose succeeded (#85).
    """
    rolled_back, rollback_detail = _rollback_storage_migration_to_backup(
        ctx,
        session,
        config,
        emit=emit,
        backup_path=backup_path,
        operation_id=operation_id,
    )
    outcome = "succeeded" if rolled_back else "failed"
    return ctx.error_result(
        "ENGINE_RUNTIME_ERROR",
        msg,
        stage="execute_runtime_operation",
        details=f"{details}; Rollback {outcome}: {rollback_detail}",
        extra={"operation_id": operation_id},
    )


def _postgres_storage_is_migrated_layout(source_mount, datadir, config):
    """Report whether the live mounts already are the migrated layout.

    PGDATA must equal the configured pgdata path, carried by a named
    volume mounted at the data path. Anonymous, unnamed, or parent
    mounts all mean migration still has work to do (#85).
    """
    source_name = source_mount.get("Name") or ""
    destination = str(source_mount.get("Destination") or "").rstrip("/")
    return (
        datadir == _postgres_pgdata_path(config)
        and destination == _postgres_data_volume_target(config)
        and bool(source_name)
        and not _postgres_storage_volume_is_anonymous(source_name)
    )


def _postgres_storage_verify_final_mount(mounts, new_pgdata, new_target):
    """Check the migrated mounts carry PGDATA on the named volume.

    Returns (ok, detail, mount): the data directory and inventory
    comparisons already proved the data, and this proves the layout
    carries it in the named volume rather than a fresh anonymous one.
    The returned mount lets removal compare against the live volume
    without re-deriving it (#85).
    """
    final_mount = _postgres_find_pgdata_source_volume(mounts, new_pgdata)
    if final_mount is None:
        return (False, "No mounted volume backs PGDATA.", None)
    final_name = final_mount.get("Name") or ""
    if not final_name or _postgres_storage_volume_is_anonymous(final_name):
        return (False, "PGDATA is not on the named data volume.", None)
    destination = str(final_mount.get("Destination")).rstrip("/")
    if destination != new_target:
        return (False, "PGDATA is not mounted at the data path.", None)
    return (True, "", final_mount)


def run_postgres_storage_migration(ctx, session, config, *, emit, is_cancelled, operation_id):
    """Move PGDATA from the legacy layout into the named volume (#85).

    Records the mounts, verifies the running major matches the settings,
    refuses detached clusters, takes a 0600 safety dump, stops cleanly,
    copies through a helper container with ownership preserved, rewrites
    the compose onto the unified layout, and verifies the data directory,
    the database inventory, and the final mounts. Anything failing after
    the stop rolls back to the snapshotted compose; the source volume is
    only ever read, and the old copy stays until the user removes it.
    """
    cancelled = _storage_migration_cancelled(ctx, is_cancelled)
    if cancelled is not None:
        return cancelled
    ctx.emit_event(
        emit,
        "postgres_storage_migration_phase",
        "Recording the current storage layout.",
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
            "Could not inspect PostgreSQL storage layout.",
            stage="execute_runtime_operation",
            details=inspect_details,
            extra={"operation_id": operation_id},
        )
    try:
        mounts = _postgres_parse_storage_mounts(inspect_output)
    except ValueError as exc:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not inspect PostgreSQL storage layout.",
            stage="execute_runtime_operation",
            details=str(exc),
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
    datadir = _postgres_storage_first_output_line(datadir_output) if datadir_ok else None
    if not datadir_ok or not datadir:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not read the PostgreSQL data directory. "
            "Start the Database service and try again.",
            stage="execute_runtime_operation",
            details=datadir_details,
            extra={"operation_id": operation_id},
        )
    source_mount = _postgres_find_pgdata_source_volume(mounts, datadir)
    if source_mount is None:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "No mounted volume backs the PostgreSQL data directory.",
            stage="execute_runtime_operation",
            extra={"operation_id": operation_id},
        )
    new_pgdata = _postgres_pgdata_path(config)
    if _postgres_storage_is_migrated_layout(source_mount, datadir, config):
        return {
            "status": "success",
            "code": "OK",
            "msg": "PostgreSQL storage is already on the named-volume layout.",
            "operation_id": operation_id,
            "already_migrated": True,
            "data_directory": datadir,
            "storage_volume": source_mount.get("Name"),
            "legacy_volume": None,
            "legacy_subpath": None,
        }
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
            "Could not read the PostgreSQL server version.",
            stage="execute_runtime_operation",
            details=version_details,
            extra={"operation_id": operation_id},
        )
    version_match = re.match(r"\d+", _postgres_storage_first_output_line(version_output) or "")
    if version_match is None:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not determine the running PostgreSQL major version.",
            stage="execute_runtime_operation",
            extra={"operation_id": operation_id},
        )
    if version_match.group() != config.postgres_version:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"settings.postgres_version requests {config.postgres_version} "
            f"but the server runs PostgreSQL {version_match.group()}. "
            "Storage migration keeps the running major; change versions "
            "separately.",
            stage="validate_request",
            extra={"operation_id": operation_id},
        )
    queries = _postgres_storage_inventory_queries()
    databases_ok, databases_output, databases_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        queries["databases"],
        emit=emit,
        operation_id=operation_id,
    )
    if not databases_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not record the pre-migration database inventory.",
            stage="execute_runtime_operation",
            details=databases_details,
            extra={"operation_id": operation_id},
        )
    roles_ok, roles_output, roles_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        queries["roles"],
        emit=emit,
        operation_id=operation_id,
    )
    if not roles_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not record the pre-migration database inventory.",
            stage="execute_runtime_operation",
            details=roles_details,
            extra={"operation_id": operation_id},
        )
    databases = _postgres_storage_clean_name_lines(databases_output)
    roles = _postgres_storage_clean_name_lines(roles_output)
    registry_ok, expected_databases, registry_details = _postgres_storage_expected_databases(
        ctx,
        session,
        config,
        emit=emit,
        operation_id=operation_id,
    )
    if not registry_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not read the managed database registry.",
            stage="execute_runtime_operation",
            details=registry_details,
            extra={"operation_id": operation_id},
        )
    missing = _postgres_storage_missing_expected_databases(expected_databases, databases)
    if missing:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Refusing to migrate: "
            + _postgres_storage_detached_description(missing, len(expected_databases)),
            stage="validate_request",
            extra={"operation_id": operation_id},
        )
    source_name = source_mount.get("Name") or ""
    if not source_name:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not identify the volume backing the PostgreSQL data directory.",
            stage="execute_runtime_operation",
            extra={"operation_id": operation_id},
        )
    source_destination = str(source_mount.get("Destination")).rstrip("/")
    try:
        source_subpath = _postgres_checked_storage_subpath(
            datadir[len(source_destination) :].lstrip("/")
        )
    except ValueError as exc:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "The PostgreSQL data directory has an unexpected layout.",
            stage="execute_runtime_operation",
            details=str(exc),
            extra={"operation_id": operation_id},
        )
    target_mount = None
    for mount in mounts:
        if str(mount.get("Destination")).rstrip("/") == _STORAGE_LEGACY_PARENT_MOUNT:
            target_mount = mount
            break
    if target_mount is None:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not find the named data volume at /var/lib/postgresql.",
            stage="execute_runtime_operation",
            extra={"operation_id": operation_id},
        )
    target_name = target_mount.get("Name") or ""
    if not target_name or _postgres_storage_volume_is_anonymous(target_name):
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Unexpected storage layout: the /var/lib/postgresql mount is not "
            "the named data volume.",
            stage="execute_runtime_operation",
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
            "Could not measure free disk space for the safety dump.",
            stage="execute_runtime_operation",
            details=disk_details,
            extra={"operation_id": operation_id},
        )
    disk_values = shell_output.parse_key_values(disk_output)
    try:
        data_bytes = int(disk_values.get("data_bytes"))
        avail_bytes = int(disk_values.get("avail_bytes"))
    except (TypeError, ValueError):
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not measure free disk space for the safety dump.",
            stage="execute_runtime_operation",
            details=f"unparsable disk output: {sorted(disk_values)}",
            extra={"operation_id": operation_id},
        )
    if avail_bytes < data_bytes:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Not enough free disk space for the safety dump: need at least "
            f"{data_bytes} bytes, have {avail_bytes}.",
            stage="validate_request",
            extra={"operation_id": operation_id},
        )
    dump_path = f"{config.stack_root}/{_STORAGE_MIGRATION_SAFETY_DUMP_NAME}"
    ctx.emit_event(
        emit,
        "postgres_storage_migration_phase",
        "Taking a safety backup of all databases.",
        data={"phase": "safety_dump"},
    )
    dump_ok, _, dump_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_storage_safety_dump_command(config, dump_path),
        emit=emit,
        timeout=1800,
        operation_id=operation_id,
    )
    if not dump_ok:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "PostgreSQL safety dump failed; the service is untouched.",
            stage="execute_runtime_operation",
            details=dump_details,
            extra={"operation_id": operation_id},
        )
    backup_path = (
        f"{config.stack_root}/docker-compose.yml{_STORAGE_MIGRATION_COMPOSE_BACKUP_SUFFIX}"
    )
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
            "Could not back up the compose file.",
            stage="execute_runtime_operation",
            details=backup_details,
            extra={"operation_id": operation_id},
        )
    cancelled = _storage_migration_cancelled(ctx, is_cancelled)
    if cancelled is not None:
        return cancelled
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
            "Could not stop the PostgreSQL container.",
            stage="execute_runtime_operation",
            details=stop_details,
            extra={"operation_id": operation_id},
        )
    cancelled = _storage_migration_cancelled(ctx, is_cancelled)
    if cancelled is not None:
        return cancelled
    ctx.emit_event(
        emit,
        "postgres_storage_migration_phase",
        "Copying the data directory into the named volume.",
        data={"phase": "copy"},
    )
    copy_ok, _, copy_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_storage_copy_command(config, source_name, target_name, source_subpath),
        emit=emit,
        timeout=3600,
        operation_id=operation_id,
    )
    if not copy_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="PostgreSQL data copy failed.",
            details=copy_details,
        )
    rewrite_ok, _, rewrite_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_base_env_bootstrap_command(config),
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
            msg="Could not write the migrated compose file.",
            details=rewrite_details,
        )
    cancelled = _storage_migration_cancelled(ctx, is_cancelled)
    if cancelled is not None:
        return cancelled
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
            msg="Could not start PostgreSQL on the migrated layout.",
            details=up_details,
        )
    readiness_error = _wait_for_postgres_readiness(
        ctx,
        session,
        config,
        emit=emit,
        is_cancelled=is_cancelled,
        operation_id=operation_id,
    )
    if readiness_error is not None:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="PostgreSQL did not become ready on the migrated layout.",
            details=readiness_error.get("details"),
        )
    ctx.emit_event(
        emit,
        "postgres_storage_migration_phase",
        "Verifying the migrated data.",
        data={"phase": "verify"},
    )
    verify_datadir_ok, verify_datadir_output, verify_datadir_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        "SHOW data_directory;",
        emit=emit,
        operation_id=operation_id,
    )
    if not verify_datadir_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Migration verification failed: could not re-read the data directory.",
            details=verify_datadir_details,
        )
    new_datadir = _postgres_storage_first_output_line(verify_datadir_output)
    if new_datadir != new_pgdata:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Migration verification failed: data directory mismatch.",
            details=f"data_directory is {new_datadir}, expected {new_pgdata}",
        )
    verify_dbs_ok, verify_dbs_output, verify_dbs_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        queries["databases"],
        emit=emit,
        operation_id=operation_id,
    )
    if not verify_dbs_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Migration verification failed: could not re-read the database inventory.",
            details=verify_dbs_details,
        )
    verify_roles_ok, verify_roles_output, verify_roles_details = _run_storage_psql_query(
        ctx,
        session,
        config,
        queries["roles"],
        emit=emit,
        operation_id=operation_id,
    )
    if not verify_roles_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Migration verification failed: could not re-read the role inventory.",
            details=verify_roles_details,
        )
    new_databases = _postgres_storage_clean_name_lines(verify_dbs_output)
    new_roles = _postgres_storage_clean_name_lines(verify_roles_output)
    if new_databases != databases or new_roles != roles:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Migration verification failed: database inventory changed during migration.",
            details=f"expected {databases}/{roles}, found {new_databases}/{new_roles}",
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
            msg="Migration verification failed: could not verify the migrated storage mounts.",
            details=final_details,
        )
    try:
        final_mounts = _postgres_parse_storage_mounts(final_output)
    except ValueError as exc:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Migration verification failed: could not verify the migrated storage mounts.",
            details=str(exc),
        )
    mounts_ok, mounts_detail, _live_mount = _postgres_storage_verify_final_mount(
        final_mounts, new_pgdata, _postgres_data_volume_target(config)
    )
    if not mounts_ok:
        return _fail_storage_migration_with_rollback(
            ctx,
            session,
            config,
            emit=emit,
            backup_path=backup_path,
            operation_id=operation_id,
            msg="Migration verification failed: could not verify the migrated storage mounts.",
            details=mounts_detail,
        )
    ledger_recorded = False
    ledger_ok, ledger_output, ledger_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_upgrade_read_ledger_command(),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    ledger = None
    if ledger_ok:
        try:
            ledger = _postgres_upgrade_parse_ledger(
                _postgres_storage_first_output_line(ledger_output)
            )
        except ValueError as exc:
            ledger_details = str(exc)
    if ledger is not None:
        retained_entry = {
            "volume": source_name,
            "kind": "storage_migration",
            "subpath": source_subpath,
        }
        ledger["retained_volumes"] = [
            entry
            for entry in ledger["retained_volumes"]
            if not (
                entry.get("kind") == "storage_migration"
                and entry.get("volume") == source_name
                and (entry.get("subpath") or "") == source_subpath
            )
        ]
        ledger["retained_volumes"].append(retained_entry)
        ledger_write_ok, _, ledger_write_details = _run_storage_host_command(
            ctx,
            session,
            _postgres_upgrade_write_ledger_command(_postgres_upgrade_encode_ledger(ledger)),
            emit=emit,
            timeout=60,
            operation_id=operation_id,
        )
        if ledger_write_ok:
            ledger_recorded = True
        else:
            ledger_details = ledger_write_details
    if not ledger_recorded:
        ctx.emit_event(
            emit,
            "postgres_storage_ledger_warning",
            "Migration succeeded but its retained copy could not be recorded; "
            "Deploy Dash will not offer that copy for removal.",
            level="warning",
            data={
                "volume": source_name,
                "subpath": source_subpath,
                "details": ledger_details or "ledger unavailable",
            },
        )
    cleanup_ok, _, cleanup_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_storage_cleanup_compose_backup_command(config, backup_path),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    backup_removed = True
    if not cleanup_ok:
        backup_removed = False
        ctx.emit_event(
            emit,
            "postgres_storage_compose_backup_warning",
            f"Migration succeeded but the compose backup could not be removed: {cleanup_details}",
            level="warning",
            data={"backup_path": backup_path},
        )
    return {
        "status": "success",
        "code": "OK",
        "msg": "PostgreSQL storage migration completed.",
        "operation_id": operation_id,
        "already_migrated": False,
        "data_directory": new_pgdata,
        "storage_volume": target_name,
        "legacy_volume": source_name,
        "legacy_subpath": source_subpath,
        "migrated_databases": new_databases,
        "migrated_roles": new_roles,
        "safety_dump_path": dump_path,
        "compose_backup_removed": backup_removed,
        "ledger_recorded": ledger_recorded,
    }


def run_postgres_legacy_storage_removal(ctx, session, config, *, emit, is_cancelled, operation_id):
    """Remove the old copy a storage migration kept behind (#85).

    Only runs once the service is verified on the migrated layout and the
    exact volume/subpath is present in Deploy Dash's retained-copy ledger.
    It also refuses attached volumes or anything resembling live data, so
    global Docker state can never authorize a deletion.
    """
    cancelled = _storage_migration_cancelled(ctx, is_cancelled)
    if cancelled is not None:
        return cancelled
    volume = config.legacy_storage_volume
    if not volume:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "settings.legacy_storage_volume is required to remove the old copy.",
            stage="validate_request",
            extra={"operation_id": operation_id},
        )
    subpath = config.legacy_storage_subpath or ""
    if subpath:
        try:
            checked_subpath = _postgres_checked_storage_subpath(subpath)
        except ValueError as exc:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                str(exc),
                stage="validate_request",
                extra={"operation_id": operation_id},
            )
        if checked_subpath == "pgdata" or checked_subpath.startswith("pgdata/"):
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "Refusing to remove the live data directory (pgdata).",
                stage="validate_request",
                extra={"operation_id": operation_id},
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
            "Could not inspect PostgreSQL storage layout.",
            stage="execute_runtime_operation",
            details=inspect_details,
            extra={"operation_id": operation_id},
        )
    try:
        mounts = _postgres_parse_storage_mounts(inspect_output)
    except ValueError as exc:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not inspect PostgreSQL storage layout.",
            stage="execute_runtime_operation",
            details=str(exc),
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
    datadir = _postgres_storage_first_output_line(datadir_output) if datadir_ok else None
    new_pgdata = _postgres_pgdata_path(config)
    if not datadir_ok or not datadir:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not read the PostgreSQL data directory. "
            "Start the Database service and try again.",
            stage="execute_runtime_operation",
            details=datadir_details,
            extra={"operation_id": operation_id},
        )
    if datadir != new_pgdata:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "The Database service is not on the migrated storage layout. "
            "Migrate storage before removing the legacy copy.",
            stage="validate_request",
            extra={"operation_id": operation_id},
        )
    mounts_ok, mounts_detail, live_mount = _postgres_storage_verify_final_mount(
        mounts, new_pgdata, _postgres_data_volume_target(config)
    )
    if not mounts_ok:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "The Database service is not on the migrated storage layout. "
            "Migrate storage before removing the legacy copy.",
            stage="validate_request",
            details=mounts_detail,
            extra={"operation_id": operation_id},
        )
    if subpath and volume != live_mount.get("Name"):
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"The legacy volume {volume} does not match the live data "
            f"volume {live_mount.get('Name')}; refusing.",
            stage="validate_request",
            extra={"operation_id": operation_id},
        )
    ledger_ok, ledger_output, ledger_details = _run_storage_host_command(
        ctx,
        session,
        _postgres_upgrade_read_ledger_command(),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    ledger = None
    if ledger_ok:
        try:
            ledger = _postgres_upgrade_parse_ledger(
                _postgres_storage_first_output_line(ledger_output)
            )
        except ValueError as exc:
            ledger_details = str(exc)
    if ledger is None:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not verify that this storage copy belongs to Deploy Dash.",
            stage="execute_runtime_operation",
            details=ledger_details or "retained-volume ledger unavailable",
            extra={"operation_id": operation_id},
        )
    retained_index = next(
        (
            index
            for index, entry in enumerate(ledger["retained_volumes"])
            if entry.get("volume") == volume and (entry.get("subpath") or "") == subpath
        ),
        None,
    )
    if retained_index is None:
        volume_kind = (
            f"named volume {volume}"
            if not _postgres_storage_volume_is_anonymous(volume)
            else f"volume {volume}"
        )
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Refusing to remove {volume_kind}; it is not recorded as a Deploy Dash retained copy.",
            stage="validate_request",
            extra={"operation_id": operation_id},
        )
    retained_entry = ledger["retained_volumes"][retained_index]
    if subpath:
        remove_ok, _, remove_details = _run_storage_host_command(
            ctx,
            session,
            _postgres_storage_remove_legacy_subdir_command(config, volume, checked_subpath),
            emit=emit,
            timeout=300,
            operation_id=operation_id,
        )
        if not remove_ok:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not remove the legacy data subdirectory.",
                stage="execute_runtime_operation",
                details=remove_details,
                extra={"operation_id": operation_id},
            )
        result = {
            "status": "success",
            "code": "OK",
            "msg": "Legacy storage subdirectory removed.",
            "operation_id": operation_id,
            "volume": volume,
            "removed_subpath": checked_subpath,
        }
    else:
        attached = any(
            mount.get("Name") == volume or mount.get("Source") == volume for mount in mounts
        )
        if attached:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                f"Storage volume {volume} is still attached; refusing to remove it.",
                stage="validate_request",
                extra={"operation_id": operation_id},
            )
        remove_ok, _, remove_details = _run_storage_host_command(
            ctx,
            session,
            _postgres_storage_remove_volume_command(config, volume),
            emit=emit,
            timeout=120,
            operation_id=operation_id,
        )
        if not remove_ok:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not remove the legacy storage volume.",
                stage="execute_runtime_operation",
                details=remove_details,
                extra={"operation_id": operation_id},
            )
        result = {
            "status": "success",
            "code": "OK",
            "msg": (
                "Retained pre-upgrade volume removed."
                if retained_entry.get("kind") != "storage_migration"
                else "Legacy storage volume removed."
            ),
            "operation_id": operation_id,
            "removed_volume": volume,
        }
    del ledger["retained_volumes"][retained_index]
    write_ok, _, _ = _run_storage_host_command(
        ctx,
        session,
        _postgres_upgrade_write_ledger_command(_postgres_upgrade_encode_ledger(ledger)),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    result["ledger_updated"] = bool(write_ok)
    if not write_ok:
        ctx.emit_event(
            emit,
            "postgres_storage_ledger_warning",
            "The retained copy was removed but its ledger entry could not be updated.",
            level="warning",
            data={"volume": volume, "subpath": subpath},
        )
    return result


def enrich_postgres_service_status(ctx, session, config, *, emit, operation_id, base_status):
    """Merge storage shape into a service status payload, best effort.

    Adds the backing volume, data directory, size, layout currency, any
    missing expected databases with a detached-volume error, and only the
    ledger-attributed volumes or subpaths a later cleanup may remove. A
    detached cluster also fails the readiness verdict, so no consumer reports it ready.
    Every read stands alone: a failure leaves its fields unknown
    without touching the base status or crying wolf (#85).
    """
    storage = {
        "data_directory": None,
        "storage_volume": None,
        "storage_volume_anonymous": None,
        "data_size_bytes": None,
        "storage_layout_current": None,
        "missing_expected_databases": [],
        "storage_error": None,
        "detached_storage_volumes": [],
        "retained_upgrade_volumes": [],
        "retained_storage_subpaths": [],
    }
    mounts = None
    inspect_ok, inspect_output, _ = _run_storage_host_command(
        ctx,
        session,
        _postgres_storage_inspect_mounts_command(config),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    if inspect_ok:
        try:
            mounts = _postgres_parse_storage_mounts(inspect_output)
        except ValueError:
            mounts = None
    datadir = None
    datadir_ok, datadir_output, _ = _run_storage_psql_query(
        ctx,
        session,
        config,
        "SHOW data_directory;",
        emit=emit,
        operation_id=operation_id,
    )
    if datadir_ok:
        datadir = _postgres_storage_first_output_line(datadir_output)
    if datadir:
        storage["data_directory"] = datadir
    if mounts is not None and datadir:
        source = _postgres_find_pgdata_source_volume(mounts, datadir)
        if source is not None:
            source_name = source.get("Name") or ""
            if source_name:
                storage["storage_volume"] = source_name
                storage["storage_volume_anonymous"] = _postgres_storage_volume_is_anonymous(
                    source_name
                )
            storage["storage_layout_current"] = _postgres_storage_is_migrated_layout(
                source, datadir, config
            )
    size_ok, size_output, _ = _run_storage_psql_query(
        ctx,
        session,
        config,
        _postgres_storage_data_size_sql(),
        emit=emit,
        operation_id=operation_id,
    )
    if size_ok:
        with contextlib.suppress(TypeError, ValueError):
            storage["data_size_bytes"] = int(_postgres_storage_first_output_line(size_output) or "")
    expected_ok, expected, _ = _postgres_storage_expected_databases(
        ctx,
        session,
        config,
        emit=emit,
        operation_id=operation_id,
    )
    live_ok, live_output, _ = _run_storage_psql_query(
        ctx,
        session,
        config,
        _postgres_storage_inventory_queries()["databases"],
        emit=emit,
        operation_id=operation_id,
    )
    if expected_ok and live_ok:
        missing = _postgres_storage_missing_expected_databases(
            expected, _postgres_storage_clean_name_lines(live_output)
        )
    else:
        missing = []
    container_override = {}
    if missing:
        storage["missing_expected_databases"] = missing
        storage["storage_error"] = (
            "Detached data volume: "
            + _postgres_storage_detached_description(missing, len(expected))
        )
        base_container_status = base_status.get("container_status")
        if isinstance(base_container_status, dict):
            container_override = {
                "container_status": _postgres_storage_detached_container_status(
                    base_container_status, storage["storage_error"]
                )
            }
    dangling_ok, dangling_output, _ = _run_storage_host_command(
        ctx,
        session,
        _postgres_storage_dangling_volumes_command(config),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    dangling_volumes = _postgres_storage_clean_name_lines(dangling_output) if dangling_ok else []
    ledger_ok, ledger_output, _ = _run_storage_host_command(
        ctx,
        session,
        _postgres_upgrade_read_ledger_command(),
        emit=emit,
        timeout=60,
        operation_id=operation_id,
    )
    if ledger_ok:
        try:
            ledger = _postgres_upgrade_parse_ledger(
                _postgres_storage_first_output_line(ledger_output)
            )
        except ValueError:
            ledger = None
        if ledger is not None:
            retained_migrations = {
                entry.get("volume")
                for entry in ledger["retained_volumes"]
                if entry.get("kind") == "storage_migration" and not (entry.get("subpath") or "")
            }
            storage["detached_storage_volumes"] = [
                volume for volume in dangling_volumes if volume in retained_migrations
            ]
            storage["retained_upgrade_volumes"] = [
                {
                    "volume": entry.get("volume"),
                    "from_major": entry.get("from_major"),
                    "to_major": entry.get("to_major"),
                    "upgraded_at": entry.get("upgraded_at"),
                }
                for entry in ledger["retained_volumes"]
                if entry.get("kind") != "storage_migration"
            ]
            storage["retained_storage_subpaths"] = [
                {
                    "volume": entry.get("volume"),
                    "subpath": entry.get("subpath"),
                }
                for entry in ledger["retained_volumes"]
                if entry.get("kind") == "storage_migration" and (entry.get("subpath") or "")
            ]
    return {**base_status, **storage, **container_override}


__all__ = tuple(name for name in globals() if not name.startswith("__"))
