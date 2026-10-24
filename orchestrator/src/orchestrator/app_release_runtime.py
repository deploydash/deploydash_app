from __future__ import annotations

import json
import re
import shlex
from dataclasses import asdict
from datetime import UTC, datetime
from typing import Any, cast

from .app_parts.app_config import AppConfig, WorkerConfig

RELEASE_MANIFEST_SCHEMA_VERSION = 1
DEFAULT_RELEASE_RETENTION = 5

_RELEASE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
_COMMIT_SHA_RE = re.compile(r"^[a-f0-9]{7,40}$", re.IGNORECASE)


def utc_now_iso() -> str:
    return datetime.now(UTC).isoformat()


def normalize_commit_sha(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip().lower()
    if not _COMMIT_SHA_RE.fullmatch(normalized):
        return None
    return normalized


def build_release_id(commit_sha: str | None, *, now: datetime | None = None) -> str:
    current = now or datetime.now(UTC)
    prefix = current.strftime("%Y%m%dT%H%M%SZ").lower()
    short_commit = normalize_commit_sha(commit_sha)
    if short_commit is None:
        return f"{prefix}-manual"
    return f"{prefix}-{short_commit[:12]}"


def empty_release_manifest() -> dict[str, Any]:
    return {
        "schema_version": RELEASE_MANIFEST_SCHEMA_VERSION,
        "retention_success_limit": DEFAULT_RELEASE_RETENTION,
        "releases": [],
    }


def normalize_release_manifest(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        return empty_release_manifest()
    releases = payload.get("releases")
    if not isinstance(releases, list):
        releases = []
    normalized = {
        "schema_version": RELEASE_MANIFEST_SCHEMA_VERSION,
        "retention_success_limit": DEFAULT_RELEASE_RETENTION,
        "releases": [],
    }
    retention = payload.get("retention_success_limit")
    if isinstance(retention, int) and retention >= 2:
        normalized["retention_success_limit"] = retention
    for entry in releases:
        normalized_entry = normalize_release_entry(entry)
        if normalized_entry is not None:
            normalized["releases"].append(normalized_entry)
    return normalized


def normalize_release_entry(entry: Any) -> dict[str, Any] | None:
    if not isinstance(entry, dict):
        return None
    release_id = entry.get("release_id")
    if not isinstance(release_id, str):
        return None
    normalized_release_id = release_id.strip().lower()
    if not normalized_release_id or not _RELEASE_ID_RE.fullmatch(normalized_release_id):
        return None
    status = entry.get("status")
    if status not in ("candidate", "live", "retained", "failed"):
        status = "failed"
    worker_specs = []
    raw_worker_specs = entry.get("worker_specs")
    if isinstance(raw_worker_specs, list):
        for worker_spec in raw_worker_specs:
            normalized_worker = normalize_worker_spec(worker_spec)
            if normalized_worker is not None:
                worker_specs.append(normalized_worker)
    runtime_env = entry.get("runtime_env")
    if not isinstance(runtime_env, dict):
        runtime_env = {}
    trust_network_names = entry.get("trust_network_names")
    if not isinstance(trust_network_names, list):
        trust_network_names = []
    sqlite_snapshot_mounts = entry.get("sqlite_snapshot_mounts")
    if not isinstance(sqlite_snapshot_mounts, list):
        sqlite_snapshot_mounts = []
    result = {
        "release_id": normalized_release_id,
        "commit_sha": normalize_commit_sha(entry.get("commit_sha")),
        "branch": entry.get("branch") if isinstance(entry.get("branch"), str) else "main",
        "created_at": entry.get("created_at")
        if isinstance(entry.get("created_at"), str)
        else utc_now_iso(),
        "status": status,
        "deployment_kind": entry.get("deployment_kind")
        if isinstance(entry.get("deployment_kind"), str)
        else "deploy",
        "web_container_name": entry.get("web_container_name")
        if isinstance(entry.get("web_container_name"), str)
        else "",
        "worker_container_names": [
            item.strip()
            for item in entry.get("worker_container_names", [])
            if isinstance(item, str) and item.strip()
        ],
        "image_name": entry.get("image_name") if isinstance(entry.get("image_name"), str) else "",
        "runtime_env": {
            str(key): str(value) for key, value in runtime_env.items() if str(key).strip()
        },
        "app_port": entry.get("app_port") if isinstance(entry.get("app_port"), int) else None,
        "workers": worker_specs,
        "sqlite_storage": entry.get("sqlite_storage")
        if isinstance(entry.get("sqlite_storage"), dict)
        else None,
        "sqlite_snapshot_mounts": sqlite_snapshot_mounts,
        "trust_network_names": [
            item.strip() for item in trust_network_names if isinstance(item, str) and item.strip()
        ],
        "rollback_from_release_id": entry.get("rollback_from_release_id")
        if isinstance(entry.get("rollback_from_release_id"), str)
        else None,
        "rollback_reason": entry.get("rollback_reason")
        if isinstance(entry.get("rollback_reason"), str)
        else None,
        "live_at": entry.get("live_at") if isinstance(entry.get("live_at"), str) else None,
    }
    return result


def normalize_worker_spec(worker_spec: Any) -> dict[str, Any] | None:
    if not isinstance(worker_spec, dict):
        return None
    worker_id = worker_spec.get("id")
    start_command = worker_spec.get("start_command")
    name = worker_spec.get("name")
    if not isinstance(worker_id, str) or not worker_id.strip():
        return None
    if not isinstance(start_command, str) or not start_command.strip():
        return None
    if not isinstance(name, str) or not name.strip():
        return None
    return {
        "id": worker_id.strip(),
        "name": name.strip(),
        "start_command": start_command.strip(),
        "cpu_limit": float(worker_spec.get("cpu_limit") or 0.5),
        "memory_mb": int(worker_spec.get("memory_mb") or 256),
        "disk_mb": int(worker_spec.get("disk_mb") or 1024),
        "enabled": bool(worker_spec.get("enabled", True)),
        "database_user": worker_spec.get("database_user"),
        "database_name": worker_spec.get("database_name"),
        "database_password": worker_spec.get("database_password"),
        "database_engine": worker_spec.get("database_engine"),
        "database_host": worker_spec.get("database_host"),
        "database_port": worker_spec.get("database_port"),
    }


def release_entry_from_config(
    app_config: AppConfig,
    *,
    release_id: str,
    commit_sha: str | None,
    status: str,
    deployment_kind: str,
    image_name: str,
    rollback_from_release_id: str | None = None,
    rollback_reason: str | None = None,
) -> dict[str, Any]:
    worker_specs = [asdict(worker) for worker in app_config.workers]
    return {
        "release_id": release_id,
        "commit_sha": normalize_commit_sha(commit_sha),
        "branch": app_config.branch,
        "created_at": utc_now_iso(),
        "status": status,
        "deployment_kind": deployment_kind,
        "web_container_name": app_config.release_container_name(release_id),
        "worker_container_names": [
            app_config.release_worker_container_name(release_id, worker.id)
            for worker in app_config.workers
        ],
        "image_name": image_name,
        "runtime_env": dict(app_config.runtime_env),
        "app_port": app_config.app_port,
        "workers": worker_specs,
        "sqlite_storage": (
            {
                "volume_name": app_config.sqlite_storage.volume_name,
                "mount_path": app_config.sqlite_storage.mount_path,
                "file_name": app_config.sqlite_storage.file_name,
            }
            if app_config.sqlite_storage is not None
            else None
        ),
        "sqlite_snapshot_mounts": [
            {
                "volume_name": mount.volume_name,
                "mount_path": mount.mount_path,
                "file_name": mount.file_name,
                "path_env_key": mount.path_env_key,
                "database_url_env_key": mount.database_url_env_key,
            }
            for mount in app_config.sqlite_snapshot_mounts
        ],
        "trust_network_names": list(app_config.trust_network_names),
        "rollback_from_release_id": rollback_from_release_id,
        "rollback_reason": rollback_reason,
        "live_at": None,
    }


def live_release_entry(manifest: dict[str, Any]) -> dict[str, Any] | None:
    for entry in manifest.get("releases", []):
        if entry.get("status") == "live":
            return entry
    return None


def successful_release_entries(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        entry
        for entry in manifest.get("releases", [])
        if entry.get("status") in ("live", "retained")
    ]


def find_release_entry(manifest: dict[str, Any], release_id: str | None) -> dict[str, Any] | None:
    if not isinstance(release_id, str) or not release_id.strip():
        return None
    normalized = release_id.strip().lower()
    for entry in manifest.get("releases", []):
        if entry.get("release_id") == normalized:
            return entry
    return None


def sort_releases_newest_first(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        entries,
        key=lambda item: (
            str(item.get("created_at") or ""),
            str(item.get("release_id") or ""),
        ),
        reverse=True,
    )


def previous_successful_release(
    manifest: dict[str, Any],
    *,
    excluding_release_id: str | None = None,
) -> dict[str, Any] | None:
    successful = sort_releases_newest_first(successful_release_entries(manifest))
    for entry in successful:
        release_id = entry.get("release_id")
        if excluding_release_id and release_id == excluding_release_id:
            continue
        if entry.get("status") == "live":
            continue
        return entry
    live = live_release_entry(manifest)
    if live is not None and (
        excluding_release_id is None or live.get("release_id") != excluding_release_id
    ):
        return live
    return None


def set_live_release(
    manifest: dict[str, Any],
    *,
    live_release_id: str,
    retained_release_id: str | None = None,
) -> dict[str, Any]:
    now_iso = utc_now_iso()
    for entry in manifest.get("releases", []):
        release_id = entry.get("release_id")
        if release_id == live_release_id:
            entry["status"] = "live"
            entry["live_at"] = now_iso
            continue
        if retained_release_id is not None and release_id == retained_release_id:
            entry["status"] = "retained"
            continue
        if entry.get("status") == "live":
            entry["status"] = "retained"
    return manifest


def mark_release_failed(
    manifest: dict[str, Any],
    *,
    release_id: str,
    rollback_from_release_id: str | None = None,
    rollback_reason: str | None = None,
) -> dict[str, Any]:
    entry = find_release_entry(manifest, release_id)
    if entry is None:
        return manifest
    entry["status"] = "failed"
    if rollback_from_release_id:
        entry["rollback_from_release_id"] = rollback_from_release_id
    if rollback_reason:
        entry["rollback_reason"] = rollback_reason
    return manifest


def append_or_replace_release(
    manifest: dict[str, Any], release_entry: dict[str, Any]
) -> dict[str, Any]:
    releases = manifest.get("releases", [])
    releases = [
        entry for entry in releases if entry.get("release_id") != release_entry.get("release_id")
    ]
    releases.append(release_entry)
    manifest["releases"] = sort_releases_newest_first(releases)
    return manifest


def release_prune_candidates(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    successful = sort_releases_newest_first(successful_release_entries(manifest))
    if not successful:
        return []
    retention = manifest.get("retention_success_limit")
    if not isinstance(retention, int) or retention < 2:
        retention = DEFAULT_RELEASE_RETENTION
    keep_ids = set()
    live_entry = live_release_entry(manifest)
    if live_entry is not None:
        keep_ids.add(live_entry.get("release_id"))
    # A non-empty successful list guarantees a retained or live fallback.
    previous_entry = cast(dict[str, Any], previous_successful_release(manifest))
    keep_ids.add(previous_entry.get("release_id"))
    for entry in successful[:retention]:
        keep_ids.add(entry.get("release_id"))
    return [entry for entry in successful if entry.get("release_id") not in keep_ids]


def prune_release_entries(
    manifest: dict[str, Any],
    pruned_release_ids: list[str],
) -> dict[str, Any]:
    pruned = {item for item in pruned_release_ids if isinstance(item, str)}
    manifest["releases"] = [
        entry for entry in manifest.get("releases", []) if entry.get("release_id") not in pruned
    ]
    return manifest


def render_manifest_write_command(
    app_config: AppConfig,
    _manifest: dict[str, Any] | None = None,
) -> str:
    """Build an atomic manifest write command whose text can never hold JSON."""
    quoted_dir = shlex.quote(app_config.release_data_root)
    quoted_path = shlex.quote(app_config.release_manifest_path)
    return (
        "set -eu; "
        f"mkdir -p {quoted_dir}; "
        f"manifest_path={quoted_path}; "
        'manifest_tmp="$(mktemp "${manifest_path}.tmp.XXXXXX")"; '
        "trap 'rm -f \"${manifest_tmp}\"' EXIT; "
        'cat > "${manifest_tmp}"; '
        'chmod 600 "${manifest_tmp}"; '
        'mv -f "${manifest_tmp}" "${manifest_path}"; '
        "trap - EXIT"
    )


def render_manifest_write_payload(manifest: dict[str, Any]) -> str:
    """Serialize the complete manifest only for the non-logged stdin channel."""
    return json.dumps(manifest, sort_keys=True, separators=(",", ":"))


def load_manifest_from_text(payload: str | None) -> dict[str, Any]:
    if not isinstance(payload, str) or not payload.strip():
        return empty_release_manifest()
    try:
        decoded = json.loads(payload)
    except json.JSONDecodeError:
        return empty_release_manifest()
    return normalize_release_manifest(decoded)


def worker_specs_to_configs(worker_specs: list[dict[str, Any]]) -> list[WorkerConfig]:
    configs = []
    for item in worker_specs:
        normalized = normalize_worker_spec(item)
        if normalized is None:
            continue
        configs.append(
            WorkerConfig(
                id=normalized["id"],
                name=normalized["name"],
                start_command=normalized["start_command"],
                cpu_limit=normalized["cpu_limit"],
                memory_mb=normalized["memory_mb"],
                disk_mb=normalized["disk_mb"],
                enabled=normalized["enabled"],
                database_user=normalized["database_user"],
                database_name=normalized["database_name"],
                database_password=normalized["database_password"],
                database_engine=normalized["database_engine"],
                database_host=normalized["database_host"],
                database_port=normalized["database_port"],
            )
        )
    return configs
