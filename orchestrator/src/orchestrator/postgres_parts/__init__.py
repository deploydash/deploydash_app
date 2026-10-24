from .postgres_config import (
    CANONICAL_POSTGRES_SETTINGS,
    REQUESTED_POSTGRES_EXTENSIONS,
    SUPPORTED_ACCESS_MODES,
    SUPPORTED_POSTGRES_EXTENSIONS,
    SUPPORTED_POSTGRES_VERSIONS,
    UNSUPPORTED_POSTGRES_EXTENSIONS,
    PostgresConfigValidationError,
    PostgresServiceConfig,
    parse_postgres_service_config,
)

WORKFLOW_ID = "postgres"

# T-1.5.3: params_schema describes payload["params"] for this workflow's
# operations, all sent through SSHService.runWorkflowStream (modern-nested
# shape). "settings" properties are Class C intent keys only
# (POSTGRES_INTENT_DEFAULTS in postgres_config.py) -- Class A keys
# (stack_root, container_name, host_port, superuser_name) are resolved
# server-side and rejected if sent (settings_ownership.reject_server_owned_keys),
# so they are deliberately absent here rather than merely unlisted.
_SETTINGS_PROPERTIES = {
    "postgres_version": {"type": "string", "enum": list(SUPPORTED_POSTGRES_VERSIONS)},
    "superuser_password": {"type": ["string", "null"]},
    "enabled_extensions": {
        "type": "array",
        "items": {"type": "string", "enum": list(REQUESTED_POSTGRES_EXTENSIONS)},
    },
    "project_slug": {"type": ["string", "null"]},
    "known_project_slugs": {"type": ["array", "null"], "items": {"type": "string"}},
    "expected_databases": {"type": ["array", "null"], "items": {"type": "string"}},
    "confirmed_databases": {"type": ["array", "null"], "items": {"type": "string"}},
    "confirmed_users": {"type": ["array", "null"], "items": {"type": "string"}},
    "confirmed_normalize_users": {"type": ["array", "null"], "items": {"type": "string"}},
    "confirmed_lost_connect_roles": {"type": ["array", "null"], "items": {"type": "string"}},
    "database_name": {"type": ["string", "null"]},
    "schema_name": {"type": ["string", "null"]},
    "table_name": {"type": ["string", "null"]},
    "username": {"type": ["string", "null"]},
    "password": {"type": ["string", "null"]},
    "access_mode": {"type": "string", "enum": list(SUPPORTED_ACCESS_MODES)},
    "sql": {"type": ["string", "null"]},
    "max_rows": {"type": ["integer", "null"], "minimum": 1, "maximum": 1000},
    "backup_destination_type": {
        "type": ["string", "null"],
        "enum": ["s3", "filesystem", None],
    },
    "backup_s3_prefix": {"type": ["string", "null"]},
    "backup_file_prefix": {"type": ["string", "null"]},
    "backup_aws_access_key_id": {"type": ["string", "null"]},
    "backup_aws_secret_access_key": {"type": ["string", "null"]},
    "backup_aws_region": {"type": ["string", "null"]},
    "backup_aws_endpoint": {"type": ["string", "null"]},
    "backup_aws_force_path_style": {"type": "boolean"},
    "backup_policy_id": {"type": ["string", "null"]},
    "backup_policy_name": {"type": ["string", "null"]},
    "backup_task_id": {"type": ["string", "null"]},
    "backup_database_name": {"type": ["string", "null"]},
    "backup_schedule_mode": {"type": "string", "enum": ["daily_once", "daily_twice"]},
    "backup_time1": {"type": "string", "pattern": r"^(?:[01]?\d|2[0-3]):[0-5]\d$"},
    "backup_time2": {
        "type": ["string", "null"],
        "pattern": r"^(?:[01]?\d|2[0-3]):[0-5]\d$",
    },
    "backup_retention_keep_last": {"type": "integer", "minimum": 1},
    "enabled": {"type": "boolean"},
    "backup_artifact_path": {"type": ["string", "null"]},
    "backup_target_database_name": {"type": ["string", "null"]},
    "import_local_file_path": {"type": ["string", "null"]},
    "import_ignore_ownership": {"type": ["boolean", "null"]},
    "legacy_storage_volume": {"type": ["string", "null"]},
    "legacy_storage_subpath": {"type": ["string", "null"]},
}


# backup_destination_type selects between two mutually exclusive required
# field groups -- expressed as if/then rather than a flat "required" list,
# since only one group is actually required for any given request.
_BACKUP_DESTINATION_CONDITIONAL = {
    "if": {
        "properties": {"backup_destination_type": {"const": "s3"}},
        "required": ["backup_destination_type"],
    },
    "then": {
        "required": [
            "backup_s3_prefix",
            "backup_aws_access_key_id",
            "backup_aws_secret_access_key",
            "backup_aws_region",
        ]
    },
    "else": {
        "if": {
            "properties": {"backup_destination_type": {"const": "filesystem"}},
            "required": ["backup_destination_type"],
        },
        "then": {"required": ["backup_file_prefix"]},
    },
}


def _params_schema(required_settings=(), needs_backup_destination=False):
    settings_schema = {
        "type": "object",
        "additionalProperties": False,
        "properties": _SETTINGS_PROPERTIES,
        "required": list(required_settings),
    }
    if needs_backup_destination:
        settings_schema["required"] = [*required_settings, "backup_destination_type"]
        settings_schema["allOf"] = [_BACKUP_DESTINATION_CONDITIONAL]
    schema = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "dry_run": {"type": "boolean"},
            "settings": settings_schema,
        },
    }
    if required_settings or needs_backup_destination:
        schema["required"] = ["settings"]
    return schema


_BACKUP_DESTINATION_REQUIRED = (
    "backup_destination_type",
    "backup_s3_prefix",
    "backup_aws_access_key_id",
    "backup_aws_secret_access_key",
    "backup_aws_region",
    "backup_file_prefix",
)

# Service start/stop/status/delete act only on server-owned identifiers, but
# enabling the service must receive the user's selected service configuration.
# Parser defaults remain useful for optional fields and for the pure lifecycle
# operations; they are not a substitute for the operation's required intent.
_SERVICE_ENABLE_REQUIRED_SETTINGS = (
    "postgres_version",
    "superuser_password",
    "enabled_extensions",
)

_SERVICE_CONFIGURE_REQUIRED_SETTINGS = (
    "postgres_version",
    "enabled_extensions",
)

OPERATIONS = {
    "describe": {
        "id": "describe",
        "label": "Describe PostgreSQL plan",
        "description": "Preview PostgreSQL service setup and project DB actions",
        "params_schema": _params_schema(),
    },
    "run": {
        "id": "run",
        "label": "Run PostgreSQL plan",
        "description": "Apply PostgreSQL service setup",
        "params_schema": _params_schema(required_settings=_SERVICE_ENABLE_REQUIRED_SETTINGS),
    },
    "service_enable": {
        "id": "service_enable",
        "label": "Enable Database service",
        "description": "Install and start the managed PostgreSQL container",
        "params_schema": _params_schema(required_settings=_SERVICE_ENABLE_REQUIRED_SETTINGS),
    },
    "service_start": {
        "id": "service_start",
        "label": "Start Database service",
        "description": "Start the PostgreSQL container if stopped",
        "params_schema": _params_schema(),
    },
    "service_stop": {
        "id": "service_stop",
        "label": "Stop Database service",
        "description": "Stop the PostgreSQL container",
        "params_schema": _params_schema(),
    },
    "service_restart": {
        "id": "service_restart",
        "label": "Restart Database service",
        "description": "Restart the PostgreSQL container",
        "params_schema": _params_schema(),
    },
    "service_configure": {
        "id": "service_configure",
        "label": "Configure Database service",
        "description": "Apply PostgreSQL version and service defaults",
        "params_schema": _params_schema(required_settings=_SERVICE_CONFIGURE_REQUIRED_SETTINGS),
    },
    "service_status": {
        "id": "service_status",
        "label": "Get Database service status",
        "description": "Collect PostgreSQL runtime and health details",
        "params_schema": _params_schema(),
    },
    "service_delete": {
        "id": "service_delete",
        "label": "Delete Database service",
        "description": "Permanently remove PostgreSQL container, config, and data",
        "params_schema": _params_schema(),
    },
    "service_migrate_storage": {
        "id": "service_migrate_storage",
        "label": "Migrate Database storage layout",
        "description": "Move PostgreSQL data into the named volume at the data path",
        "params_schema": _params_schema(required_settings=_SERVICE_ENABLE_REQUIRED_SETTINGS),
    },
    "service_remove_legacy_storage": {
        "id": "service_remove_legacy_storage",
        "label": "Remove legacy Database storage",
        "description": "Delete the old copy a storage migration kept behind",
        "params_schema": _params_schema(required_settings=("legacy_storage_volume",)),
    },
    "service_upgrade_major": {
        "id": "service_upgrade_major",
        "label": "Upgrade Database major version",
        "description": "Move PostgreSQL to another major version by dump and restore",
        "params_schema": _params_schema(required_settings=_SERVICE_ENABLE_REQUIRED_SETTINGS),
    },
    # Every operation from here through import_local_sql routes through
    # engine_postgres_ops.py::run_postgres_project_operation, which calls
    # _postgres_project_prefix(postgres_config.project_slug) unconditionally
    # before doing anything else -- so project_slug is required for all of
    # them, not just the ones with an obvious per-database target. Found
    # the hard way: project_create_database's own dry-run test payload
    # (database_name only) reached the handler and failed there with
    # "settings.project_slug must be a non-empty string" even though this
    # schema had accepted it.
    "project_list": {
        "id": "project_list",
        "label": "List project databases and users",
        "description": "List databases/users managed for one project",
        "params_schema": _params_schema(required_settings=("project_slug",)),
    },
    "project_list_schemas": {
        "id": "project_list_schemas",
        "label": "List project database schemas",
        "description": "List non-system schemas for one project database",
        "params_schema": _params_schema(required_settings=("project_slug", "database_name")),
    },
    "project_list_tables": {
        "id": "project_list_tables",
        "label": "List project database tables",
        "description": "List relations for one project database",
        "params_schema": _params_schema(required_settings=("project_slug", "database_name")),
    },
    "project_describe_table": {
        "id": "project_describe_table",
        "label": "Describe project database table",
        "description": "Read columns, indexes, and foreign keys for one table",
        "params_schema": _params_schema(
            required_settings=("project_slug", "database_name", "table_name")
        ),
    },
    "project_explain_readonly_query": {
        "id": "project_explain_readonly_query",
        "label": "Explain project read-only query",
        "description": "Run EXPLAIN FORMAT JSON for one read-only query",
        "params_schema": _params_schema(required_settings=("project_slug", "database_name", "sql")),
    },
    "project_execute_readonly_query": {
        "id": "project_execute_readonly_query",
        "label": "Execute project read-only query",
        "description": "Run one bounded read-only query and return rows",
        "params_schema": _params_schema(required_settings=("project_slug", "database_name", "sql")),
    },
    "project_create_database": {
        "id": "project_create_database",
        "label": "Create project database",
        "description": "Create a project database and owner user",
        "params_schema": _params_schema(required_settings=("project_slug", "database_name")),
    },
    "project_create_user": {
        "id": "project_create_user",
        "label": "Create project DB user",
        "description": "Create a user and grant scoped access to a project database",
        "params_schema": _params_schema(
            required_settings=("project_slug", "database_name", "username")
        ),
    },
    "project_delete_database": {
        "id": "project_delete_database",
        "label": "Delete project database",
        "description": "Drop one PostgreSQL database and its managed users",
        "params_schema": _params_schema(required_settings=("project_slug", "database_name")),
    },
    "project_rotate_password": {
        "id": "project_rotate_password",
        "label": "Rotate project DB user password",
        "description": "Reset password for an existing project DB user",
        "params_schema": _params_schema(required_settings=("project_slug", "username")),
    },
    "project_delete_user": {
        "id": "project_delete_user",
        "label": "Delete project DB user",
        "description": "Revoke access and delete one project DB user",
        "params_schema": _params_schema(required_settings=("project_slug", "username")),
    },
    "project_delete": {
        "id": "project_delete",
        "label": "Delete project databases and users",
        "description": "Drop all PostgreSQL databases and users managed for one project",
        "params_schema": _params_schema(required_settings=("project_slug",)),
    },
    "project_normalize_database": {
        "id": "project_normalize_database",
        "label": "Normalize project database isolation",
        "description": (
            "Move one database to its owner role and revoke PUBLIC CONNECT, "
            "with a dry-run report first"
        ),
        "params_schema": _params_schema(required_settings=("project_slug", "database_name")),
    },
    "backup_policy_apply": {
        "id": "backup_policy_apply",
        "label": "Apply PostgreSQL backup policy",
        "description": (
            "Configure wal-g destination, cron schedule, and policy runner for "
            "logical PostgreSQL backups"
        ),
        "params_schema": _params_schema(
            required_settings=(
                "project_slug",
                "backup_policy_id",
                "backup_database_name",
            ),
            needs_backup_destination=True,
        ),
    },
    "backup_policy_delete": {
        "id": "backup_policy_delete",
        "label": "Delete PostgreSQL backup policy",
        "description": "Remove wal-g backup policy runner and schedule",
        "params_schema": _params_schema(required_settings=("project_slug", "backup_policy_id")),
    },
    "backup_destination_test": {
        "id": "backup_destination_test",
        "label": "Test PostgreSQL backup destination",
        "description": (
            "Write, read, and clean up a temporary object at the configured backup destination"
        ),
        "params_schema": _params_schema(
            required_settings=("project_slug",),
            needs_backup_destination=True,
        ),
    },
    "backup_run_now": {
        "id": "backup_run_now",
        "label": "Run PostgreSQL backup now",
        "description": "Run a logical PostgreSQL backup immediately via wal-g",
        "params_schema": _params_schema(
            required_settings=(
                "project_slug",
                "backup_policy_id",
                "backup_database_name",
            ),
            needs_backup_destination=True,
        ),
    },
    "backup_artifact_list": {
        "id": "backup_artifact_list",
        "label": "List PostgreSQL backup artifacts",
        "description": "List logical backup artifacts available in wal-g storage",
        "params_schema": _params_schema(
            required_settings=(
                "project_slug",
                "backup_policy_id",
                "backup_database_name",
            ),
            needs_backup_destination=True,
        ),
    },
    "backup_backlog_report": {
        "id": "backup_backlog_report",
        "label": "Report PostgreSQL backup backlog",
        "description": ("Report backup artifacts beyond the policy retention with their sizes"),
        "params_schema": _params_schema(
            required_settings=(
                "project_slug",
                "backup_policy_id",
                "backup_database_name",
            ),
            needs_backup_destination=True,
        ),
    },
    "backup_backlog_cleanup": {
        "id": "backup_backlog_cleanup",
        "label": "Clean up PostgreSQL backup backlog",
        "description": (
            "Delete backup artifacts beyond the policy retention, keeping the newest N"
        ),
        "params_schema": _params_schema(
            required_settings=(
                "project_slug",
                "backup_policy_id",
                "backup_database_name",
            ),
            needs_backup_destination=True,
        ),
    },
    "restore_run_now": {
        "id": "restore_run_now",
        "label": "Restore PostgreSQL backup now",
        "description": "Restore a logical PostgreSQL backup artifact into a database",
        "params_schema": _params_schema(
            required_settings=(
                "project_slug",
                "backup_target_database_name",
                "backup_artifact_path",
            ),
            needs_backup_destination=True,
        ),
    },
    "import_local_sql": {
        "id": "import_local_sql",
        "label": "Import local PostgreSQL .sql file",
        "description": (
            "Upload a local plain .sql file from the workstation and import it "
            "into an existing project database"
        ),
        "params_schema": _params_schema(
            required_settings=(
                "project_slug",
                "database_name",
                "import_local_file_path",
            )
        ),
    },
}
