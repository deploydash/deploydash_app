"""Validation for the app settings a caller sends: class C intent.

Split out of `app_config.py` by T-3.3.4. Everything here answers the same
question about a different field -- is what the client sent usable, and what
is it once normalised -- which is why forty of them in one file stopped being
navigable. The resolved half is in `app_settings_schema.py`; the per-provider
TLS credential matrix, which is the one branch-heavy rule among them, is in
`app_tls_credentials.py`.
"""

import re
from typing import Any

from .app_settings_schema import (
    _BRANCH_RE,
    _DOMAIN_ROUTING_MODES,
    _ENV_KEY_RE,
    _FQDN_RE,
    _RAILPACK_PROVIDERS,
    _REPO_RE,
    _REPOSITORY_HOST_KEY_POLICIES,
    _SLUG_RE,
    _SSH_SHA256_FINGERPRINT_RE,
    _TLS_PROVIDERS,
    _WORKER_HOST_RE,
    _WORKER_ID_RE,
    AppConfigValidationError,
    SqliteSnapshotMountConfig,
    SqliteStorageConfig,
    WorkerConfig,
    _required_string,
)


def _accept_superseded_railpack_keys(candidate: dict[str, Any]) -> dict[str, Any]:
    """Rename the two superseded Railpack spellings before anything else.

    Runs as `select_settings`'s `normalize` hook, so it happens before the
    server-owned rejection: a key renamed after that check would look like it
    arrived from the wire under its new name.
    """
    legacy_build_command = candidate.pop("railpack_build_command", None)
    if "railpack_build_cmd" not in candidate and legacy_build_command is not None:
        candidate["railpack_build_cmd"] = legacy_build_command

    legacy_run_command = candidate.pop("railpack_run_command", None)
    if "railpack_start_cmd" not in candidate and legacy_run_command is not None:
        candidate["railpack_start_cmd"] = legacy_run_command
    return candidate


def _required_public_health_path(value: Any, field_name: str) -> str:
    if not isinstance(value, str):
        raise AppConfigValidationError(f"{field_name} must be a string.")
    normalized = value.strip()
    if not normalized.startswith("/"):
        raise AppConfigValidationError(f"{field_name} must start with '/'.")
    if len(normalized) > 512:
        raise AppConfigValidationError(f"{field_name} must be 512 characters or fewer.")
    if "#" in normalized or any(
        ord(character) < 32 or ord(character) == 127 for character in normalized
    ):
        raise AppConfigValidationError(
            f"{field_name} must not contain fragments or control characters."
        )
    return normalized


def _optional_command(value: Any, field_name: str) -> str | None:
    if value is None:
        return ""
    if not isinstance(value, str):
        raise AppConfigValidationError(f"{field_name} must be a string or null.")
    return value.strip()


def _required_repository_host_key_policy(value: Any, field_name: str) -> str:
    if not isinstance(value, str):
        raise AppConfigValidationError(f"{field_name} must be a string.")
    normalized = value.strip()
    if normalized not in _REPOSITORY_HOST_KEY_POLICIES:
        allowed = ", ".join(_REPOSITORY_HOST_KEY_POLICIES)
        raise AppConfigValidationError(
            f"{field_name} must be one of: {allowed}.",
        )
    return normalized


def _optional_ssh_sha256_fingerprint(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise AppConfigValidationError(f"{field_name} must be a string or null.")
    normalized = value.strip()
    if not normalized:
        return None
    if not _SSH_SHA256_FINGERPRINT_RE.match(normalized):
        raise AppConfigValidationError(
            f"{field_name} must be an SSH SHA256 fingerprint.",
        )
    return normalized


def _required_project_slug(value: Any, field_name: str) -> str:
    slug = _required_string(value, field_name).lower()
    if not _SLUG_RE.match(slug):
        raise AppConfigValidationError(
            f"{field_name} must be lowercase kebab-case (example: my-app).",
        )
    return slug


def _required_repo_full_name(value: Any, field_name: str) -> str:
    repo = _required_string(value, field_name)
    if not _REPO_RE.match(repo):
        raise AppConfigValidationError(
            f"{field_name} must be in owner/repository format.",
        )
    return repo


def _required_branch(value: Any, field_name: str) -> str:
    branch = _required_string(value, field_name)
    if not _BRANCH_RE.match(branch):
        raise AppConfigValidationError(
            f"{field_name} contains invalid characters.",
        )
    return branch


def _optional_domain(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise AppConfigValidationError(f"{field_name} must be a string or null.")

    domain = value.strip().lower().rstrip(".")
    if not domain:
        return None
    if not _FQDN_RE.match(domain):
        raise AppConfigValidationError(f"{field_name} must be a valid FQDN.")
    return domain


def _strip_leading_www(domain: str) -> str:
    if domain.startswith("www.") and len(domain) > 4:
        return domain[4:]
    return domain


def _required_port(value: Any, field_name: str) -> int:
    if not isinstance(value, int):
        raise AppConfigValidationError(f"{field_name} must be an integer.")
    if value < 1 or value > 65535:
        raise AppConfigValidationError(
            f"{field_name} must be between 1 and 65535.",
        )
    return value


def _required_node_mode(value: Any, field_name: str) -> str:
    mode = _required_string(value, field_name).lower()
    if mode not in ("auto", "runtime"):
        raise AppConfigValidationError(
            f"{field_name} must be one of: auto, runtime.",
        )
    return mode


def _optional_railpack_provider(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    provider = _required_string(value, field_name).lower()
    if provider not in _RAILPACK_PROVIDERS:
        raise AppConfigValidationError(
            f"{field_name} must be one of: {', '.join(_RAILPACK_PROVIDERS)}.",
        )
    return provider


def _required_domain_routing_mode(value: Any, field_name: str) -> str:
    mode = _required_string(value, field_name).lower()
    if mode not in _DOMAIN_ROUTING_MODES:
        raise AppConfigValidationError(
            f"{field_name} must be one of: {', '.join(_DOMAIN_ROUTING_MODES)}.",
        )
    return mode


def _optional_private_key(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise AppConfigValidationError(f"{field_name} must be a string or null.")

    key_data = value.strip()
    if not key_data:
        return None
    return key_data


def _optional_worker_command(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise AppConfigValidationError(f"{field_name} must be a string or null.")
    command = value.strip()
    if not command:
        return None
    return command


def _optional_workers(value: Any, field_name: str) -> tuple[WorkerConfig, ...]:
    if value is None:
        return tuple()
    if not isinstance(value, list):
        raise AppConfigValidationError(f"{field_name} must be an array or null.")

    normalized = []
    seen_ids = set()
    for index, item in enumerate(value):
        entry_field = f"{field_name}[{index}]"
        if not isinstance(item, dict):
            raise AppConfigValidationError(f"{entry_field} must be an object.")

        worker_id = _required_worker_id(item.get("id"), f"{entry_field}.id")
        if worker_id in seen_ids:
            raise AppConfigValidationError(
                f"{entry_field}.id '{worker_id}' is duplicated.",
            )
        seen_ids.add(worker_id)

        name_raw = item.get("name")
        if name_raw is None:
            name = worker_id
        elif isinstance(name_raw, str) and name_raw.strip():
            name = name_raw.strip()
        else:
            raise AppConfigValidationError(
                f"{entry_field}.name must be a non-empty string when provided.",
            )

        start_command = _required_string(
            item.get("start_cmd"),
            f"{entry_field}.start_cmd",
        )
        cpu_limit = _required_worker_cpu_limit(
            item.get("cpu_limit"),
            f"{entry_field}.cpu_limit",
        )
        memory_mb = _required_worker_memory(
            item.get("memory_mb"),
            f"{entry_field}.memory_mb",
        )
        disk_mb = _required_worker_disk(
            item.get("disk_mb"),
            f"{entry_field}.disk_mb",
        )
        enabled = _optional_worker_enabled(
            item.get("enabled"),
            f"{entry_field}.enabled",
        )
        database_user = _optional_worker_database_value(
            item.get("database_user"),
            f"{entry_field}.database_user",
        )
        database_name = _optional_worker_database_value(
            item.get("database_name"),
            f"{entry_field}.database_name",
        )
        database_password = _optional_worker_database_value(
            item.get("database_password"),
            f"{entry_field}.database_password",
        )
        database_engine = _optional_worker_database_engine(
            item.get("database_engine"),
            f"{entry_field}.database_engine",
        )
        database_host = _optional_worker_database_host(
            item.get("database_host"),
            f"{entry_field}.database_host",
        )
        database_port = _optional_worker_database_port(
            item.get("database_port"),
            f"{entry_field}.database_port",
        )

        has_any_database_field = any(
            entry is not None
            for entry in (
                database_user,
                database_name,
                database_password,
                database_engine,
                database_host,
                database_port,
            )
        )
        if has_any_database_field:
            if database_user is None:
                raise AppConfigValidationError(
                    f"{entry_field}.database_user is required when database settings are provided.",
                )
            if database_name is None:
                raise AppConfigValidationError(
                    f"{entry_field}.database_name is required when database_user is set.",
                )
            if database_password is None:
                raise AppConfigValidationError(
                    f"{entry_field}.database_password is required when database_user is set.",
                )
            if database_host is None:
                database_host = "host.docker.internal"
            if database_engine is None:
                database_engine = "postgres"
            if database_port is None:
                database_port = 5432

        normalized.append(
            WorkerConfig(
                id=worker_id,
                name=name,
                start_command=start_command,
                cpu_limit=cpu_limit,
                memory_mb=memory_mb,
                disk_mb=disk_mb,
                enabled=enabled,
                database_user=database_user,
                database_name=database_name,
                database_password=database_password,
                database_engine=database_engine,
                database_host=database_host,
                database_port=database_port,
            )
        )

    return tuple(normalized)


def _required_worker_id(value: Any, field_name: str) -> str:
    worker_id = _required_string(value, field_name).lower()
    if not _WORKER_ID_RE.match(worker_id):
        raise AppConfigValidationError(
            f"{field_name} must be lowercase kebab-case (example: queue-worker).",
        )
    return worker_id


def _required_worker_cpu_limit(value: Any, field_name: str) -> float:
    if isinstance(value, bool):
        raise AppConfigValidationError(f"{field_name} must be a number.")
    if isinstance(value, int):
        cpu_limit = float(value)
    elif isinstance(value, float):
        cpu_limit = value
    else:
        raise AppConfigValidationError(f"{field_name} must be a number.")

    if cpu_limit < 0.1 or cpu_limit > 64:
        raise AppConfigValidationError(
            f"{field_name} must be between 0.1 and 64.",
        )
    return cpu_limit


def _required_worker_memory(value: Any, field_name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise AppConfigValidationError(f"{field_name} must be an integer.")
    if value < 128 or value > 1024 * 1024:
        raise AppConfigValidationError(
            f"{field_name} must be between 128 and 1048576.",
        )
    return value


def _required_worker_disk(value: Any, field_name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise AppConfigValidationError(f"{field_name} must be an integer.")
    if value < 256 or value > 1024 * 1024:
        raise AppConfigValidationError(
            f"{field_name} must be between 256 and 1048576.",
        )
    return value


def _optional_worker_enabled(value: Any, field_name: str) -> bool:
    if value is None:
        return True
    if not isinstance(value, bool):
        raise AppConfigValidationError(f"{field_name} must be a boolean.")
    return value


def _optional_worker_database_value(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise AppConfigValidationError(f"{field_name} must be a string or null.")
    normalized = value.strip()
    return normalized or None


def _optional_worker_database_host(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise AppConfigValidationError(f"{field_name} must be a string or null.")
    normalized = value.strip().lower().rstrip(".")
    if not normalized:
        return None
    if not _WORKER_HOST_RE.match(normalized):
        raise AppConfigValidationError(f"{field_name} must be a valid hostname.")
    return normalized


def _optional_worker_database_engine(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise AppConfigValidationError(f"{field_name} must be a string or null.")
    normalized = value.strip().lower()
    if not normalized:
        return None
    if normalized != "postgres":
        raise AppConfigValidationError(
            f"{field_name} must be one of: postgres.",
        )
    return normalized


def _optional_worker_database_port(value: Any, field_name: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise AppConfigValidationError(f"{field_name} must be an integer or null.")
    if value < 1 or value > 65535:
        raise AppConfigValidationError(
            f"{field_name} must be between 1 and 65535.",
        )
    return value


def _optional_app_subdirectory(value: Any, field_name: str) -> str | None:
    if value is None:
        return ""
    if not isinstance(value, str):
        raise AppConfigValidationError(f"{field_name} must be a string or null.")
    normalized = value.strip().replace("\\", "/")
    normalized = re.sub(r"^/+|/+$", "", normalized)
    if not normalized:
        return ""

    parts = normalized.split("/")
    cleaned = []
    for part in parts:
        segment = part.strip()
        if not segment or segment in (".", ".."):
            raise AppConfigValidationError(
                f"{field_name} must be a relative path without '.' or '..' segments.",
            )
        cleaned.append(segment)
    return "/".join(cleaned)


def _required_tls_challenge_mode(value: Any, field_name: str) -> str:
    mode = _required_string(value, field_name).lower()
    if mode not in ("http", "dns"):
        raise AppConfigValidationError(
            f"{field_name} must be one of: http, dns.",
        )
    return mode


def _optional_tls_dns_provider(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    provider = _required_string(value, field_name).lower()
    if provider not in _TLS_PROVIDERS:
        raise AppConfigValidationError(
            f"{field_name} must be one of: {', '.join(_TLS_PROVIDERS)}.",
        )
    return provider


def _optional_tls_dns_credentials(value: Any, field_name: str) -> dict[str, str]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise AppConfigValidationError(f"{field_name} must be an object or null.")

    normalized = {}
    for raw_key, raw_value in value.items():
        if not isinstance(raw_key, str):
            raise AppConfigValidationError(f"{field_name} keys must be strings.")
        key = raw_key.strip().lower()
        if not key:
            raise AppConfigValidationError(f"{field_name} keys must not be blank.")
        if not isinstance(raw_value, str):
            raise AppConfigValidationError(
                f"{field_name}.{key} must be a non-empty string.",
            )
        normalized_value = raw_value.strip()
        if not normalized_value:
            raise AppConfigValidationError(
                f"{field_name}.{key} must be a non-empty string.",
            )
        normalized[key] = normalized_value
    return normalized


def _optional_runtime_env(value: Any, field_name: str) -> dict[str, str]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise AppConfigValidationError(f"{field_name} must be an object or null.")

    normalized = {}
    for raw_key, raw_value in value.items():
        if not isinstance(raw_key, str):
            raise AppConfigValidationError(f"{field_name} keys must be strings.")
        key = raw_key.strip()
        if not key:
            raise AppConfigValidationError(f"{field_name} keys must not be blank.")
        if not _ENV_KEY_RE.match(key):
            raise AppConfigValidationError(
                f"{field_name}.{key} must match [A-Za-z_][A-Za-z0-9_]*.",
            )
        if not isinstance(raw_value, str):
            raise AppConfigValidationError(
                f"{field_name}.{key} must be a string.",
            )
        if "\n" in raw_value or "\r" in raw_value or "\x00" in raw_value:
            raise AppConfigValidationError(
                f"{field_name}.{key} must not contain newlines or null bytes.",
            )
        normalized[key] = raw_value
    return normalized


def _optional_sqlite_storage(value: Any, field_name: str) -> SqliteStorageConfig | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise AppConfigValidationError(f"{field_name} must be an object or null.")

    enabled = value.get("enabled")
    if enabled is None:
        enabled = False
    if not isinstance(enabled, bool):
        raise AppConfigValidationError(f"{field_name}.enabled must be a boolean.")
    if not enabled:
        return None

    volume_name = _required_sqlite_volume_name(
        value.get("volume_name"),
        f"{field_name}.volume_name",
    )
    mount_path = _required_sqlite_mount_path(
        value.get("mount_path"),
        f"{field_name}.mount_path",
    )
    file_name = _required_sqlite_file_name(
        value.get("file_name"),
        f"{field_name}.file_name",
    )
    return SqliteStorageConfig(
        volume_name=volume_name,
        mount_path=mount_path,
        file_name=file_name,
    )


def _optional_sqlite_snapshot_mounts(
    value: Any, field_name: str
) -> tuple[SqliteSnapshotMountConfig, ...]:
    if value is None:
        return tuple()
    if not isinstance(value, list):
        raise AppConfigValidationError(f"{field_name} must be an array or null.")

    mounts = []
    seen_mount_paths = set()
    for index, item in enumerate(value):
        item_field = f"{field_name}[{index}]"
        if not isinstance(item, dict):
            raise AppConfigValidationError(f"{item_field} must be an object.")
        volume_name = _required_sqlite_volume_name(
            item.get("volume_name"),
            f"{item_field}.volume_name",
        )
        mount_path = _required_sqlite_mount_path(
            item.get("mount_path"),
            f"{item_field}.mount_path",
        )
        file_name = _required_sqlite_file_name(
            item.get("file_name"),
            f"{item_field}.file_name",
        )
        if mount_path in seen_mount_paths:
            raise AppConfigValidationError(
                f"{item_field}.mount_path duplicates another SQLite snapshot mount.",
            )
        seen_mount_paths.add(mount_path)
        path_env_key = _optional_env_key(
            item.get("path_env_key"),
            f"{item_field}.path_env_key",
        )
        database_url_env_key = _optional_env_key(
            item.get("database_url_env_key"),
            f"{item_field}.database_url_env_key",
        )
        mounts.append(
            SqliteSnapshotMountConfig(
                volume_name=volume_name,
                mount_path=mount_path,
                file_name=file_name,
                path_env_key=path_env_key,
                database_url_env_key=database_url_env_key,
            )
        )
    return tuple(mounts)


def _optional_env_key(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise AppConfigValidationError(f"{field_name} must be a string or null.")
    key = value.strip()
    if not key:
        return None
    if not _ENV_KEY_RE.match(key):
        raise AppConfigValidationError(
            f"{field_name} must match [A-Za-z_][A-Za-z0-9_]*.",
        )
    return key


def _required_sqlite_volume_name(value: Any, field_name: str) -> str:
    volume_name = _required_string(value, field_name)
    if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", volume_name):
        raise AppConfigValidationError(
            f"{field_name} must be a valid Docker volume name.",
        )
    return volume_name


def _required_sqlite_mount_path(value: Any, field_name: str) -> str:
    mount_path = _required_string(value, field_name)
    if not mount_path.startswith("/"):
        raise AppConfigValidationError(
            f"{field_name} must be an absolute path.",
        )
    parts = mount_path.split("/")
    cleaned = []
    for part in parts:
        segment = part.strip()
        if not segment:
            continue
        if segment in (".", ".."):
            raise AppConfigValidationError(
                f"{field_name} must not include '.' or '..' segments.",
            )
        cleaned.append(segment)
    if not cleaned:
        raise AppConfigValidationError(
            f"{field_name} must include at least one path segment.",
        )
    return "/" + "/".join(cleaned)


def _required_sqlite_file_name(value: Any, field_name: str) -> str:
    file_name = _required_string(value, field_name)
    if "/" in file_name:
        raise AppConfigValidationError(
            f"{field_name} must be a filename, not a path.",
        )
    if file_name in (".", ".."):
        raise AppConfigValidationError(
            f"{field_name} must be a valid filename.",
        )
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$", file_name):
        raise AppConfigValidationError(
            f"{field_name} must use letters, numbers, dot, dash, or underscore.",
        )
    return file_name
