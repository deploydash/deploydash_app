import functools
from dataclasses import dataclass

from .. import config_validation, server_identifiers, server_paths
from ..shell_output import parse_bool_token

# Class A (docs/contracts/settings-ownership.md): resolved by the backend.
# `container_name`/`superuser_name` have no `server_identifiers.py` to
# resolve from yet -- see the note on RESOLVED_HTTP_DEFAULTS in
# http_config.py; same reason, same deferral to T-3.4.1. `host_port` has
# exactly one legal value (validated below); see T-1.4.1's Discovered work
# entry -- it stays here rather than in the intent half because it isn't
# real intent either way.
RESOLVED_POSTGRES_DEFAULTS = {
    "stack_root": server_paths.postgres_root(),
    "container_name": server_identifiers.postgres_container(),
    "host_port": 5432,
    "superuser_name": server_identifiers.POSTGRES_SUPERUSER,
}

# Class C: the wire's actual contract. `postgres_version` stays here per the
# owner decision recorded under T-1.4.1 (2026-08-30): it remains
# user-selectable, not release-pinned.
POSTGRES_INTENT_DEFAULTS = {
    "postgres_version": "17",
    "superuser_password": None,
    "enabled_extensions": [],
    "project_slug": None,
    "known_project_slugs": [],
    "expected_databases": [],
    "confirmed_databases": None,
    "confirmed_users": None,
    "confirmed_normalize_users": None,
    "confirmed_lost_connect_roles": None,
    "database_name": None,
    "schema_name": None,
    "table_name": None,
    "username": None,
    "password": None,
    "access_mode": "read_write",
    "sql": None,
    "max_rows": None,
    "backup_destination_type": None,
    "backup_s3_prefix": None,
    "backup_file_prefix": None,
    "backup_aws_access_key_id": None,
    "backup_aws_secret_access_key": None,
    "backup_aws_region": None,
    "backup_aws_endpoint": None,
    "backup_aws_force_path_style": False,
    "backup_policy_id": None,
    "backup_policy_name": None,
    "backup_task_id": None,
    "backup_database_name": None,
    "backup_schedule_mode": "daily_once",
    "backup_time1": "02:00",
    "backup_time2": None,
    "backup_retention_keep_last": 7,
    "enabled": True,
    "backup_artifact_path": None,
    "backup_target_database_name": None,
    "import_local_file_path": None,
    "import_ignore_ownership": False,
    "legacy_storage_volume": None,
    "legacy_storage_subpath": None,
}

# T-1.4.3 splits the dictionary; T-1.4.4 is what actually stops
# RESOLVED_POSTGRES_DEFAULTS keys from being wire-accepted. Until then this
# stays the full merge, byte-for-byte the same dictionary
# parse_postgres_service_config saw before this split.
CANONICAL_POSTGRES_SETTINGS = {
    **RESOLVED_POSTGRES_DEFAULTS,
    **POSTGRES_INTENT_DEFAULTS,
}

ALLOWED_POSTGRES_SETTING_KEYS = tuple(CANONICAL_POSTGRES_SETTINGS.keys())
SUPPORTED_POSTGRES_VERSIONS = ("16", "17", "18")
SUPPORTED_ACCESS_MODES = ("read_write", "read_only")
REQUESTED_POSTGRES_EXTENSIONS = (
    "pg_stat_statements",
    "plpgsql",
    "pgcrypto",
    "pg_trgm",
    "vector",
    "pg_search",
    "uuid-ossp",
    "pg_session_jwt",
    "hstore",
    "postgis",
    "btree_gin",
)
SUPPORTED_POSTGRES_EXTENSIONS = (
    "pg_stat_statements",
    "plpgsql",
    "pgcrypto",
    "pg_trgm",
    "vector",
    "pg_search",
    "uuid-ossp",
    "hstore",
    "postgis",
    "btree_gin",
)
UNSUPPORTED_POSTGRES_EXTENSIONS = tuple(
    ext for ext in REQUESTED_POSTGRES_EXTENSIONS if ext not in SUPPORTED_POSTGRES_EXTENSIONS
)


class PostgresConfigValidationError(ValueError):
    pass


# Bound once per module rather than passed at all 4 call sites below.
#
# These are not copies -- T-3.8.1 deleted those. Each is `config_validation`'s
# single implementation with this module's error class already supplied, which
# is the same "parameterise the original, bind the exception class" shape
# `settings_ownership.reject_server_owned_keys(raw, error_class)` established.
_required_string = functools.partial(
    config_validation.required_string,
    error_class=PostgresConfigValidationError,
)


@dataclass(frozen=True)
class PostgresServiceConfig:
    stack_root: str
    container_name: str
    postgres_version: str
    host_port: int
    superuser_name: str
    superuser_password: str | None
    enabled_extensions: tuple[str, ...]
    project_slug: str | None
    known_project_slugs: tuple[str, ...]
    expected_databases: tuple[str, ...]
    confirmed_databases: tuple[str, ...] | None
    confirmed_users: tuple[str, ...] | None
    confirmed_normalize_users: tuple[str, ...] | None
    confirmed_lost_connect_roles: tuple[str, ...] | None
    database_name: str | None
    schema_name: str | None
    table_name: str | None
    username: str | None
    password: str | None
    access_mode: str
    sql: str | None
    max_rows: int | None
    backup_destination_type: str | None
    backup_s3_prefix: str | None
    backup_file_prefix: str | None
    backup_aws_access_key_id: str | None
    backup_aws_secret_access_key: str | None
    backup_aws_region: str | None
    backup_aws_endpoint: str | None
    backup_aws_force_path_style: bool
    backup_policy_id: str | None
    backup_policy_name: str | None
    backup_task_id: str | None
    backup_database_name: str | None
    backup_schedule_mode: str
    backup_time1: str
    backup_time2: str | None
    backup_retention_keep_last: int
    enabled: bool
    backup_artifact_path: str | None
    backup_target_database_name: str | None
    import_local_file_path: str | None
    import_ignore_ownership: bool
    legacy_storage_volume: str | None
    legacy_storage_subpath: str | None


def parse_postgres_service_config(raw_data):
    settings = config_validation.select_settings(
        raw_data,
        canonical=CANONICAL_POSTGRES_SETTINGS,
        error_class=PostgresConfigValidationError,
    )
    config_validation.validate_unknown_setting_keys(
        settings,
        allowed=ALLOWED_POSTGRES_SETTING_KEYS,
        error_class=PostgresConfigValidationError,
    )

    stack_root = _required_string(settings["stack_root"], "settings.stack_root")
    container_name = _required_string(
        settings["container_name"],
        "settings.container_name",
    )
    postgres_version = _required_string(
        settings["postgres_version"],
        "settings.postgres_version",
    )
    if postgres_version not in SUPPORTED_POSTGRES_VERSIONS:
        raise PostgresConfigValidationError(
            "settings.postgres_version must be one of: 16, 17, 18.",
        )

    host_port = _required_int(settings["host_port"], "settings.host_port")
    if host_port != 5432:
        raise PostgresConfigValidationError("settings.host_port must be 5432.")

    superuser_name = _required_string(
        settings["superuser_name"],
        "settings.superuser_name",
    )
    superuser_password = _optional_string(
        settings.get("superuser_password"),
        "settings.superuser_password",
    )
    enabled_extensions = _optional_extension_list(
        settings.get("enabled_extensions"),
        "settings.enabled_extensions",
    )
    project_slug = _optional_string(settings.get("project_slug"), "settings.project_slug")
    known_project_slugs = (
        _optional_string_list(
            settings.get("known_project_slugs"),
            "settings.known_project_slugs",
        )
        or ()
    )
    expected_databases = (
        _optional_string_list(
            settings.get("expected_databases"),
            "settings.expected_databases",
        )
        or ()
    )
    confirmed_databases = _optional_string_list(
        settings.get("confirmed_databases"),
        "settings.confirmed_databases",
    )
    confirmed_users = _optional_string_list(
        settings.get("confirmed_users"),
        "settings.confirmed_users",
    )
    confirmed_normalize_users = _optional_string_list(
        settings.get("confirmed_normalize_users"),
        "settings.confirmed_normalize_users",
    )
    confirmed_lost_connect_roles = _optional_string_list(
        settings.get("confirmed_lost_connect_roles"),
        "settings.confirmed_lost_connect_roles",
    )
    database_name = _optional_string(
        settings.get("database_name"),
        "settings.database_name",
    )
    schema_name = _optional_string(settings.get("schema_name"), "settings.schema_name")
    table_name = _optional_string(settings.get("table_name"), "settings.table_name")
    username = _optional_string(settings.get("username"), "settings.username")
    password = _optional_string(settings.get("password"), "settings.password")
    access_mode = _optional_string(settings.get("access_mode"), "settings.access_mode")
    if access_mode is None:
        access_mode = CANONICAL_POSTGRES_SETTINGS["access_mode"]
    if access_mode not in SUPPORTED_ACCESS_MODES:
        raise PostgresConfigValidationError(
            "settings.access_mode must be either read_write or read_only.",
        )
    sql = _optional_string(settings.get("sql"), "settings.sql")
    max_rows = _optional_int(settings.get("max_rows"), "settings.max_rows")
    backup_destination_type = _optional_string(
        settings.get("backup_destination_type"),
        "settings.backup_destination_type",
    )
    backup_s3_prefix = _optional_string(
        settings.get("backup_s3_prefix"),
        "settings.backup_s3_prefix",
    )
    backup_file_prefix = _optional_string(
        settings.get("backup_file_prefix"),
        "settings.backup_file_prefix",
    )
    backup_aws_access_key_id = _optional_string(
        settings.get("backup_aws_access_key_id"),
        "settings.backup_aws_access_key_id",
    )
    backup_aws_secret_access_key = _optional_string(
        settings.get("backup_aws_secret_access_key"),
        "settings.backup_aws_secret_access_key",
    )
    backup_aws_region = _optional_string(
        settings.get("backup_aws_region"),
        "settings.backup_aws_region",
    )
    backup_aws_endpoint = _optional_string(
        settings.get("backup_aws_endpoint"),
        "settings.backup_aws_endpoint",
    )
    backup_aws_force_path_style = _optional_bool(
        settings.get("backup_aws_force_path_style"),
        "settings.backup_aws_force_path_style",
    )
    backup_policy_id = _optional_string(
        settings.get("backup_policy_id"),
        "settings.backup_policy_id",
    )
    backup_policy_name = _optional_string(
        settings.get("backup_policy_name"),
        "settings.backup_policy_name",
    )
    backup_task_id = _optional_string(
        settings.get("backup_task_id"),
        "settings.backup_task_id",
    )
    backup_database_name = _optional_string(
        settings.get("backup_database_name"),
        "settings.backup_database_name",
    )
    backup_schedule_mode = _optional_string(
        settings.get("backup_schedule_mode"),
        "settings.backup_schedule_mode",
    )
    if backup_schedule_mode is None:
        backup_schedule_mode = CANONICAL_POSTGRES_SETTINGS["backup_schedule_mode"]
    if backup_schedule_mode not in ("daily_once", "daily_twice"):
        raise PostgresConfigValidationError(
            "settings.backup_schedule_mode must be one of: daily_once, daily_twice.",
        )
    backup_time1 = _optional_string(
        settings.get("backup_time1"),
        "settings.backup_time1",
    )
    if backup_time1 is None:
        backup_time1 = CANONICAL_POSTGRES_SETTINGS["backup_time1"]
    backup_time2 = _optional_string(
        settings.get("backup_time2"),
        "settings.backup_time2",
    )
    backup_retention_keep_last = _required_int(
        settings.get("backup_retention_keep_last"),
        "settings.backup_retention_keep_last",
    )
    enabled = _optional_bool(
        settings.get("enabled"),
        "settings.enabled",
        default=bool(CANONICAL_POSTGRES_SETTINGS["enabled"]),
    )
    backup_artifact_path = _optional_string(
        settings.get("backup_artifact_path"),
        "settings.backup_artifact_path",
    )
    backup_target_database_name = _optional_string(
        settings.get("backup_target_database_name"),
        "settings.backup_target_database_name",
    )
    import_local_file_path = _optional_string(
        settings.get("import_local_file_path"),
        "settings.import_local_file_path",
    )
    import_ignore_ownership = _optional_bool(
        settings.get("import_ignore_ownership"),
        "settings.import_ignore_ownership",
    )
    legacy_storage_volume = _optional_string(
        settings.get("legacy_storage_volume"),
        "settings.legacy_storage_volume",
    )
    legacy_storage_subpath = _optional_string(
        settings.get("legacy_storage_subpath"),
        "settings.legacy_storage_subpath",
    )

    return PostgresServiceConfig(
        stack_root=stack_root,
        container_name=container_name,
        postgres_version=postgres_version,
        host_port=host_port,
        superuser_name=superuser_name,
        superuser_password=superuser_password,
        enabled_extensions=enabled_extensions,
        project_slug=project_slug,
        known_project_slugs=known_project_slugs,
        expected_databases=expected_databases,
        confirmed_databases=confirmed_databases,
        confirmed_users=confirmed_users,
        confirmed_normalize_users=confirmed_normalize_users,
        confirmed_lost_connect_roles=confirmed_lost_connect_roles,
        database_name=database_name,
        schema_name=schema_name,
        table_name=table_name,
        username=username,
        password=password,
        access_mode=access_mode,
        sql=sql,
        max_rows=max_rows,
        backup_destination_type=backup_destination_type,
        backup_s3_prefix=backup_s3_prefix,
        backup_file_prefix=backup_file_prefix,
        backup_aws_access_key_id=backup_aws_access_key_id,
        backup_aws_secret_access_key=backup_aws_secret_access_key,
        backup_aws_region=backup_aws_region,
        backup_aws_endpoint=backup_aws_endpoint,
        backup_aws_force_path_style=backup_aws_force_path_style,
        backup_policy_id=backup_policy_id,
        backup_policy_name=backup_policy_name,
        backup_task_id=backup_task_id,
        backup_database_name=backup_database_name,
        backup_schedule_mode=backup_schedule_mode,
        backup_time1=backup_time1,
        backup_time2=backup_time2,
        backup_retention_keep_last=backup_retention_keep_last,
        enabled=enabled,
        backup_artifact_path=backup_artifact_path,
        backup_target_database_name=backup_target_database_name,
        import_local_file_path=import_local_file_path,
        import_ignore_ownership=import_ignore_ownership,
        legacy_storage_volume=legacy_storage_volume,
        legacy_storage_subpath=legacy_storage_subpath,
    )


def _optional_string(value, field_name):
    if value is None:
        return None
    if not isinstance(value, str):
        raise PostgresConfigValidationError(f"{field_name} must be a string.")
    trimmed = value.strip()
    if not trimmed:
        return None
    return trimmed


def _required_int(value, field_name):
    if isinstance(value, bool):
        raise PostgresConfigValidationError(f"{field_name} must be an integer.")
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        trimmed = value.strip()
        if not trimmed:
            raise PostgresConfigValidationError(f"{field_name} must be an integer.")
        try:
            return int(trimmed)
        except ValueError as exc:
            raise PostgresConfigValidationError(
                f"{field_name} must be an integer.",
            ) from exc
    raise PostgresConfigValidationError(f"{field_name} must be an integer.")


def _optional_int(value, field_name):
    if value is None:
        return None
    return _required_int(value, field_name)


def _optional_bool(value, field_name, default=False):
    if value is None:
        return bool(default)
    return parse_bool_token(
        value,
        False,
        false_tokens=("0", "false", "no", "off", ""),
        unknown_error=lambda: PostgresConfigValidationError(f"{field_name} must be a boolean."),
    )


def _optional_string_list(value, field_name):
    """Parse an optional list of non-empty strings; None stays None.

    Backfill's longest-prefix match reads the desktop's project slugs through
    this shape, and project deletes read their confirmed lists through it.
    Entries are trimmed and de-duplicated so one careless client cannot skew
    classification with blanks or repeats.
    """
    if value is None:
        return None
    if not isinstance(value, list):
        raise PostgresConfigValidationError(f"{field_name} must be an array.")

    parsed = []
    seen = set()
    for item in value:
        if not isinstance(item, str):
            raise PostgresConfigValidationError(
                f"{field_name} must contain only strings.",
            )
        normalized = item.strip()
        if not normalized:
            continue
        if normalized in seen:
            continue
        seen.add(normalized)
        parsed.append(normalized)

    return tuple(parsed)


def _optional_extension_list(value, field_name):
    if value is None:
        return ()
    if not isinstance(value, list):
        raise PostgresConfigValidationError(f"{field_name} must be an array.")

    parsed = []
    seen = set()
    for item in value:
        if not isinstance(item, str):
            raise PostgresConfigValidationError(
                f"{field_name} must contain only extension name strings.",
            )
        normalized = item.strip()
        if not normalized:
            continue
        if normalized not in REQUESTED_POSTGRES_EXTENSIONS:
            raise PostgresConfigValidationError(
                f"{field_name} contains unknown extension: {normalized}.",
            )
        if normalized in seen:
            continue
        seen.add(normalized)
        parsed.append(normalized)

    return tuple(parsed)
