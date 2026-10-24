"""Parse and assemble release runtime observability snapshots."""

from .. import server_identifiers, shell_output
from ..container_status import container_status_from_payload, container_status_from_worker_row


def _parse_worker_status_lines(output_lines, project_slug):
    """Normalize Docker metadata and statistics into worker runtime rows."""
    if not output_lines:
        return []

    prefix = server_identifiers.worker_container_prefix(project_slug)
    metadata_by_name = {}
    stats_by_name = {}

    for raw_line in output_lines:
        if not isinstance(raw_line, str):
            continue
        line = raw_line.strip()
        if not line:
            continue

        if line.startswith("META|"):
            parts = line.split("|", 4)
            if len(parts) < 5:
                continue
            _, container_name, state, status, container_id = parts
            worker_id = None
            if container_name.startswith(prefix):
                worker_ref = container_name[len(prefix) :]
                worker_id = worker_ref.rsplit("_", 1)[0] if "_" in worker_ref else worker_ref
            metadata_by_name[container_name] = {
                "container_name": container_name,
                "container_id": container_id,
                "worker_id": worker_id,
                "state": state,
                "status": status,
            }
            continue

        if line.startswith("STAT|"):
            parts = line.split("|", 5)
            if len(parts) < 6:
                continue
            _, container_name, cpu_perc, mem_usage, mem_perc, pids = parts
            stats_by_name[container_name] = {
                "cpu_perc": cpu_perc,
                "mem_usage": mem_usage,
                "mem_perc": mem_perc,
                "pids": pids,
            }

    rows = []
    for container_name in sorted(metadata_by_name.keys()):
        row = dict(metadata_by_name[container_name])
        row["running"] = row.get("state") == "running"
        row["container_status"] = container_status_from_worker_row(row)
        stats = stats_by_name.get(container_name)
        if stats:
            row["stats"] = stats
        rows.append(row)
    return rows


def _parse_container_status_output(output, prefix="container"):
    """Decode the shared key-value container-status protocol once."""
    parsed = shell_output.parse_key_values(output, prefix=f"{prefix}_")
    if not parsed:
        return None
    return container_status_from_payload(parsed, prefix)


def _build_worker_runtime_snapshot(app_config, runtime_rows):
    """Join configured workers to runtime rows while retaining unmanaged orphans."""
    runtime_by_worker_id = {}
    runtime_orphans = []
    for row in runtime_rows:
        worker_id = row.get("worker_id")
        if isinstance(worker_id, str) and worker_id:
            runtime_by_worker_id[worker_id] = row
            continue
        runtime_orphans.append(row)

    configured = []
    for worker in app_config.workers:
        runtime = runtime_by_worker_id.pop(worker.id, None)
        configured.append(
            {
                "id": worker.id,
                "name": worker.name,
                "enabled": worker.enabled,
                "start_cmd": worker.start_command,
                "cpu_limit": worker.cpu_limit,
                "memory_mb": worker.memory_mb,
                "disk_mb": worker.disk_mb,
                "database_user": worker.database_user,
                "database_name": worker.database_name,
                "container_name": (
                    runtime.get("container_name")
                    if isinstance(runtime, dict)
                    and isinstance(runtime.get("container_name"), str)
                    and runtime.get("container_name").strip()
                    else server_identifiers.worker_container(
                        app_config.project_slug,
                        worker.id,
                    )
                ),
                "runtime": runtime,
            }
        )

    for orphan in runtime_by_worker_id.values():
        runtime_orphans.append(orphan)

    return {
        "configured": configured,
        "orphans": sorted(
            runtime_orphans,
            key=lambda row: row.get("container_name", ""),
        ),
    }


def _parse_sqlite_meta_output(output):
    """Decode bounded SQLite volume metadata from the shared key-value protocol."""
    meta = shell_output.parse_key_values(output, prefix="SQLITE_META_")
    if not meta:
        return None

    enabled_text = meta.get("SQLITE_META_ENABLED", "").lower()
    enabled = enabled_text == "true"
    if not enabled:
        return {"enabled": False}

    exists = None
    exists_raw = meta.get("SQLITE_META_VOLUME_EXISTS", "").lower()
    if exists_raw in ("true", "false"):
        exists = exists_raw == "true"

    volume_size_bytes = None
    size_kb_raw = meta.get("SQLITE_META_VOLUME_SIZE_KB")
    if size_kb_raw:
        try:
            size_kb = int(size_kb_raw)
            if size_kb >= 0:
                volume_size_bytes = size_kb * 1024
        except (TypeError, ValueError):
            volume_size_bytes = None

    return {
        "enabled": True,
        "volume_name": meta.get("SQLITE_META_VOLUME_NAME", ""),
        "mount_path": meta.get("SQLITE_META_MOUNT_PATH", ""),
        "file_name": meta.get("SQLITE_META_FILE_NAME", ""),
        "database_path": meta.get("SQLITE_META_DATABASE_PATH", ""),
        "database_url": meta.get("SQLITE_META_DATABASE_URL", ""),
        "volume_exists": exists,
        "volume_mountpoint": meta.get("SQLITE_META_VOLUME_MOUNTPOINT"),
        "volume_size_bytes": volume_size_bytes,
    }


__all__ = (
    "_build_worker_runtime_snapshot",
    "_parse_container_status_output",
    "_parse_sqlite_meta_output",
    "_parse_worker_status_lines",
)
