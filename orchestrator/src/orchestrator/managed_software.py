from __future__ import annotations

import json
import re
from copy import deepcopy
from datetime import UTC, datetime

from . import platform_versions, server_identifiers, server_paths
from .container_status import container_status_from_payload
from .railpack_contract import RAILPACK_VERSION_NUMBER


class ManagedSoftwareLedgerFormatError(ValueError):
    """Raised when a managed-software ledger's format_version is missing or
    is not exactly the one this build knows how to act on. The ledger drives
    update/rollback decisions, so an unrecognized format is refused outright
    rather than silently reinterpreted -- see docs/contracts/artifact-formats.md."""


LEDGER_FORMAT_VERSION = 1
MANAGED_SOFTWARE_LEDGER_PATH = server_paths.managed_software_ledger()
MANAGED_BACKUP_RETENTION_LIMIT = 3

POSTGRES_IMAGE_TAGS_BY_MAJOR = platform_versions.POSTGRES_IMAGE_TAGS_BY_MAJOR
WALG_VERSION = platform_versions.WALG_VERSION
_DOCKER_PACKAGE_VERSION_PREFIXES = platform_versions.DOCKER_PACKAGE_VERSION_PREFIXES
DOCKER_PACKAGE_PAYLOAD_KEYS = {
    "docker-ce": "docker_ce_version",
    "docker-ce-cli": "docker_ce_cli_version",
    "containerd.io": "containerd_version",
    "docker-compose-plugin": "docker_compose_plugin_version",
}
_DOCKER_DEBIAN_VERSION = re.compile(
    r"^(?P<epoch>[0-9]+:)?(?P<major>[0-9]+)\.(?P<minor>[0-9]+)\."
    r"(?P<patch>[0-9]+)(?P<suffix>[A-Za-z0-9.+:~\-]*)$",
)

MANAGED_SOFTWARE_MANIFEST = {
    "railpack_build_system": {
        "id": "railpack_build_system",
        "category": "Build and deployment",
        "label": "Railpack build system",
        "description": (
            "Builds web app images from source repositories with one managed Railpack contract."
        ),
        "target": RAILPACK_VERSION_NUMBER,
        "risk_level": "low",
        "rollback_mode": "snapshot_restore",
        "action_label": "Update Railpack build system",
        "rollback_label": "Rollback Railpack build system",
    },
    "docker_runtime": {
        "id": "docker_runtime",
        "category": "Build and deployment",
        "label": "Docker runtime",
        "description": (
            "Runs app, gateway, and database containers. Updating it may restart "
            "Docker, containerd, and managed containers."
        ),
        "target": ", ".join(
            f"{name} {version}" for name, version in _DOCKER_PACKAGE_VERSION_PREFIXES.items()
        ),
        "risk_level": "high",
        "rollback_mode": "exact_apt_versions_if_available",
        "action_label": "Update Docker runtime",
        "rollback_label": "Rollback Docker runtime",
    },
    "http_gateway": {
        "id": "http_gateway",
        "category": "Traffic",
        "label": "HTTP gateway",
        "description": "Routes HTTP and HTTPS traffic through the managed Caddy stack.",
        "target": platform_versions.CADDY_IMAGE,
        "risk_level": "medium",
        "rollback_mode": "compose_snapshot_restore",
        "action_label": "Update HTTP gateway",
        "rollback_label": "Rollback HTTP gateway",
    },
    "dns_service": {
        "id": "dns_service",
        "category": "Traffic",
        "label": "DNS service",
        "description": "Runs the managed BIND authoritative DNS stack.",
        "target": platform_versions.BIND_IMAGE,
        "risk_level": "medium",
        "rollback_mode": "compose_snapshot_restore",
        "action_label": "Update DNS service",
        "rollback_label": "Rollback DNS service",
    },
    "walg_backup_tool": {
        "id": "walg_backup_tool",
        "category": "Databases",
        "label": "WAL-G backup tool",
        "description": "Runs PostgreSQL backup and restore commands.",
        "target": WALG_VERSION,
        "risk_level": "low",
        "rollback_mode": "binary_snapshot_restore",
        "action_label": "Update WAL-G",
        "rollback_label": "Rollback WAL-G",
    },
    "postgresql_database_service": {
        "id": "postgresql_database_service",
        "category": "Databases",
        "label": "PostgreSQL database service",
        "description": "Managed PostgreSQL service, extensions, roles, and backups.",
        "target": ", ".join(
            f"{major}: {tag}" for major, tag in POSTGRES_IMAGE_TAGS_BY_MAJOR.items()
        ),
        # Managed updates never cross a major version, so the default
        # rollback changes only the image line in the current compose and
        # keeps later storage changes and every row. Replaying the pre-update
        # backup is an explicit, destructive choice described by data_restore_*.
        "risk_level": "medium",
        "rollback_mode": "same_major_image_revert",
        "data_restore_mode": "restore_recorded_pg_dumpall_backup",
        "data_restore_risk_level": "destructive",
        "data_restore_label": "Restore data from the pre-update backup",
        "action_label": "Update PostgreSQL database service",
        "rollback_label": "Rollback PostgreSQL database service",
    },
}


def empty_software_ledger():
    return {
        "format_version": LEDGER_FORMAT_VERSION,
        "components": {},
    }


def parse_software_ledger(raw):
    if not raw:
        return empty_software_ledger()
    try:
        decoded = json.loads(raw)
    except (TypeError, ValueError):
        return empty_software_ledger()
    if not isinstance(decoded, dict):
        return empty_software_ledger()
    if "format_version" not in decoded:
        raise ManagedSoftwareLedgerFormatError(
            "Managed-software ledger has no format_version. Refusing to "
            "read it rather than guessing its compatibility."
        )
    version = decoded.get("format_version")
    if version != LEDGER_FORMAT_VERSION:
        raise ManagedSoftwareLedgerFormatError(
            f"Managed-software ledger format_version {version!r} is not "
            f"supported by this build (expected {LEDGER_FORMAT_VERSION})."
        )
    components = decoded.get("components")
    if not isinstance(components, dict):
        components = {}
    return {
        "format_version": LEDGER_FORMAT_VERSION,
        "components": {
            str(key): value for key, value in components.items() if isinstance(value, dict)
        },
    }


def encode_software_ledger(ledger):
    normalized = parse_software_ledger(json.dumps(ledger))
    return json.dumps(normalized, sort_keys=True, separators=(",", ":"))


def managed_software_manifest():
    return deepcopy(MANAGED_SOFTWARE_MANIFEST)


def managed_component_ids():
    return tuple(MANAGED_SOFTWARE_MANIFEST.keys())


def normalize_component_ids(raw_ids):
    if raw_ids is None:
        return list(managed_component_ids())
    if isinstance(raw_ids, str):
        candidates = [raw_ids]
    elif isinstance(raw_ids, (list, tuple, set)):
        candidates = list(raw_ids)
    else:
        raise ValueError("component_ids must be a list of managed component ids.")

    normalized = []
    for raw in candidates:
        component_id = str(raw).strip()
        if not component_id:
            continue
        if component_id not in MANAGED_SOFTWARE_MANIFEST:
            raise ValueError(f"Unknown managed software component: {component_id}.")
        if component_id not in normalized:
            normalized.append(component_id)
    if not normalized:
        raise ValueError("Choose at least one managed software component.")
    return normalized


def _status_from_current(current, target, *, configured=True):
    if not configured:
        return "not_configured"
    if not current:
        return "missing"
    if current == target:
        return "current"
    return "update_available"


def docker_package_patch_series(pinned_version):
    """Return the epoch and major/minor prefix that bounds patch updates."""
    pinned = str(pinned_version or "").strip()
    pinned_match = _DOCKER_DEBIAN_VERSION.fullmatch(pinned)
    if pinned_match is None:
        return ""
    epoch = pinned_match.group("epoch") or ""
    return f"{epoch}{pinned_match.group('major')}.{pinned_match.group('minor')}."


def docker_package_series_version(raw_version, pinned_version):
    """Accept one Debian version only when it stays in the app-owned series."""
    candidate = str(raw_version or "").strip()
    candidate_match = _DOCKER_DEBIAN_VERSION.fullmatch(candidate)
    series = docker_package_patch_series(pinned_version)
    if candidate_match is None or not series:
        return ""
    candidate_epoch = candidate_match.group("epoch") or ""
    candidate_series = (
        f"{candidate_epoch}{candidate_match.group('major')}.{candidate_match.group('minor')}."
    )
    if candidate_series != series:
        return ""
    return candidate


def caddy_image_is_current(compose_image, base_label):
    """Decide whether the gateway image counts as the pinned Caddy base.

    A stock stack names the pinned image directly. A custom (DNS-plugin)
    stack names the local build instead, so its base label -- stamped
    into the image at build time -- is compared against the pin. A build
    from before labels existed reads back empty and counts as stale.
    """
    current = str(compose_image or "").strip()
    if current == platform_versions.CADDY_IMAGE:
        return True
    return (
        current == server_identifiers.caddy_custom_image()
        and str(base_label or "").strip() == platform_versions.CADDY_IMAGE
    )


def normalize_walg_version(raw):
    value = str(raw or "").strip()
    if not value:
        return ""
    normalized = " ".join(value.replace("\r", " ").replace("\n", " ").split())
    patterns = (
        r"(?i)\bwal-g\s+version\s*:?\s*v?([0-9]+)\.([0-9]+)\.([0-9]+)\b",
        r"(?i)\bwal-g\s+v?([0-9]+)\.([0-9]+)\.([0-9]+)\b",
        r"(?i)\bWALG\s+version\s*:?\s*v?([0-9]+)\.([0-9]+)\.([0-9]+)\b",
    )
    for pattern in patterns:
        match = re.search(pattern, normalized)
        if match:
            major, minor, patch = match.groups()
            return f"v{int(major)}.{int(minor)}.{int(patch)}"
    return ""


def _ledger_component(ledger, component_id):
    components = ledger.get("components") if isinstance(ledger, dict) else None
    if not isinstance(components, dict):
        return {}
    value = components.get(component_id)
    return value if isinstance(value, dict) else {}


def _retained_backup_records(ledger_record):
    """Normalize untrusted ledger backup entries for status and size totals."""
    raw_records = ledger_record.get("retained_backups")
    if not isinstance(raw_records, list):
        return []
    retained = []
    seen = set()
    for raw_record in raw_records:
        if not isinstance(raw_record, dict):
            continue
        path = str(raw_record.get("path") or "").strip()
        if not path or path in seen:
            continue
        try:
            size_bytes = int(raw_record.get("size_bytes", 0))
        except (TypeError, ValueError):
            continue
        if size_bytes < 0:
            continue
        seen.add(path)
        retained.append({"path": path, "size_bytes": size_bytes})
    return retained


def build_managed_software_status(payload, ledger=None):
    ledger = ledger or empty_software_ledger()
    status = {}

    railpack_current = str(payload.get("railpack_version") or "")
    caddy_current = str(payload.get("caddy_compose_image") or "")
    bind_current = str(payload.get("bind_compose_image") or "")
    walg_current = normalize_walg_version(
        payload.get("walg_version_raw") or payload.get("walg_version") or ""
    )
    postgres_current = str(payload.get("postgres_compose_image") or "")
    postgres_configured = (
        payload.get("postgres_stack_present") == "1"
        or payload.get("postgres_container_present") == "1"
    )

    docker_current_parts = {
        name: str(payload.get(payload_key) or "")
        for name, payload_key in DOCKER_PACKAGE_PAYLOAD_KEYS.items()
    }
    docker_current = ", ".join(
        f"{name} {version or 'missing'}" for name, version in docker_current_parts.items()
    )
    docker_series_versions = {
        name: docker_package_series_version(
            docker_current_parts[name],
            pinned_version,
        )
        for name, pinned_version in _DOCKER_PACKAGE_VERSION_PREFIXES.items()
    }
    docker_patch_candidates = {
        name: docker_package_series_version(
            payload.get(f"{payload_key.removesuffix('_version')}_patch_candidate"),
            _DOCKER_PACKAGE_VERSION_PREFIXES[name],
        )
        for name, payload_key in DOCKER_PACKAGE_PAYLOAD_KEYS.items()
    }
    docker_target_parts = {
        name: (docker_patch_candidates[name] or docker_series_versions[name] or pinned_version)
        for name, pinned_version in _DOCKER_PACKAGE_VERSION_PREFIXES.items()
    }
    docker_target = ", ".join(f"{name} {version}" for name, version in docker_target_parts.items())
    docker_patch_update_available = all(docker_series_versions.values()) and any(
        docker_patch_candidates.values()
    )
    docker_current_flag = all(docker_series_versions.values()) and not any(
        docker_patch_candidates.values()
    )

    current_values = {
        "railpack_build_system": railpack_current,
        "docker_runtime": docker_current,
        "http_gateway": caddy_current,
        "dns_service": bind_current,
        "walg_backup_tool": walg_current,
        "postgresql_database_service": postgres_current,
    }
    current_flags = {
        "railpack_build_system": railpack_current == RAILPACK_VERSION_NUMBER,
        "docker_runtime": docker_current_flag,
        "http_gateway": caddy_image_is_current(
            caddy_current,
            str(payload.get("caddy_base_label", "") or ""),
        ),
        "dns_service": bind_current == platform_versions.BIND_IMAGE,
        "walg_backup_tool": walg_current == WALG_VERSION,
        "postgresql_database_service": any(
            postgres_current.startswith(
                f"{server_identifiers.POSTGRES_EXTENSION_IMAGE_REPOSITORY}:{tag}"
            )
            for tag in POSTGRES_IMAGE_TAGS_BY_MAJOR.values()
        ),
    }
    configured_flags = {
        "railpack_build_system": True,
        "docker_runtime": True,
        "http_gateway": payload.get("caddy_stack_present") == "1",
        "dns_service": payload.get("bind_stack_present") == "1",
        "walg_backup_tool": bool(walg_current),
        "postgresql_database_service": postgres_configured,
    }
    service_statuses = {
        "http_gateway": container_status_from_payload(payload, "caddy_container"),
        "dns_service": container_status_from_payload(payload, "bind_container"),
        "postgresql_database_service": container_status_from_payload(
            payload,
            "postgres_container",
        ),
    }

    for component_id, manifest in MANAGED_SOFTWARE_MANIFEST.items():
        ledger_record = _ledger_component(ledger, component_id)
        retained_backups = _retained_backup_records(ledger_record)
        retained_backup_bytes = sum(record["size_bytes"] for record in retained_backups)
        configured = configured_flags[component_id]
        current = current_values[component_id]
        target = docker_target if component_id == "docker_runtime" else manifest["target"]
        component_status = (
            "current"
            if current_flags[component_id] and configured
            else _status_from_current(current, target, configured=configured)
        )
        can_update = configured and component_status in {"missing", "update_available"}
        rollback_available = bool(
            ledger_record.get("previous_version")
            or ledger_record.get("backup_path")
            or ledger_record.get("backup_dir")
            or ledger_record.get("package_versions")
        )
        service_status = service_statuses.get(component_id)
        details = [
            {
                "label": manifest["label"],
                "status": component_status,
                "current": current,
                "target": target,
            }
        ]
        if retained_backups:
            backup_label = "backup" if len(retained_backups) == 1 else "backups"
            details.append(
                {
                    "label": "Retained rollback backups",
                    "status": "current",
                    "current": (
                        f"{len(retained_backups)} {backup_label} using "
                        f"{retained_backup_bytes:,} bytes"
                    ),
                    "target": f"Keep at most {MANAGED_BACKUP_RETENTION_LIMIT}",
                }
            )
        component_payload = {
            **deepcopy(manifest),
            "status": component_status,
            "current": current,
            "target": target,
            "installed_version": str(ledger_record.get("installed_version") or current),
            "can_update": can_update,
            "can_rollback": rollback_available,
            "rollback_available": rollback_available,
            "previous_version": str(ledger_record.get("previous_version") or ""),
            "last_action": str(ledger_record.get("last_action") or ""),
            "last_status": str(ledger_record.get("status") or ""),
            "last_changed_at": str(ledger_record.get("changed_at") or ""),
            "backup_path": str(ledger_record.get("backup_path") or ""),
            "backup_dir": str(ledger_record.get("backup_dir") or ""),
            "retained_backups": retained_backups,
            "retained_backup_count": len(retained_backups),
            "retained_backup_bytes": retained_backup_bytes,
            **({"service_status": service_status} if service_status else {}),
            "details": details,
        }
        if component_id == "docker_runtime":
            component_payload["patch_update_available"] = bool(
                docker_patch_update_available,
            )
            if docker_patch_update_available:
                component_payload["action_label"] = "Install Docker runtime patch update"
        status[component_id] = component_payload
    return status


def record_component_action(
    ledger,
    component_id,
    *,
    action,
    status,
    previous_version="",
    installed_version="",
    target_version="",
    backup_path="",
    backup_dir="",
    package_versions=None,
    rollback_path="",
    retained_backups=None,
):
    normalized = parse_software_ledger(json.dumps(ledger or empty_software_ledger()))
    components = normalized.setdefault("components", {})
    record = dict(components.get(component_id) or {})
    record.update(
        {
            "component_id": component_id,
            "last_action": action,
            "status": status,
            "installed_version": installed_version
            or record.get("installed_version", "")
            or previous_version
            or record.get("previous_version", ""),
            "previous_version": previous_version or record.get("previous_version", ""),
            "target_version": target_version or record.get("target_version", ""),
            "backup_path": backup_path or record.get("backup_path", ""),
            "backup_dir": backup_dir or record.get("backup_dir", ""),
            # The rollback path most recently run for this component, so a
            # image revert can be told apart from a data restore later.
            # Preserved across other actions like the sibling fields: the
            # most recent rollback is still the most recent rollback.
            "rollback_path": rollback_path or record.get("rollback_path", ""),
            "changed_at": datetime.now(UTC).isoformat(),
        }
    )
    if package_versions is not None:
        record["package_versions"] = package_versions
    if retained_backups is not None:
        record["retained_backups"] = deepcopy(list(retained_backups))
    components[component_id] = record
    return normalized
