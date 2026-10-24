from .app_config import (
    CANONICAL_APP_SETTINGS,
    AppConfig,
    AppConfigValidationError,
    parse_app_config,
)
from .app_plan import ALL_PARTS, PART_BUILDERS, collect_steps, normalize_parts
from .part0_prepare_key import build_steps as build_prepare_key_steps

WORKFLOW_ID = "app"

# T-1.5.3: params_schema describes payload["params"]. "settings" properties
# are Class C intent keys only (APP_INTENT_DEFAULTS in app_config.py) --
# Class A keys (apps_root, railpack_build_helper, railpack_env_file,
# caddy_stack_root, caddy_container_name, caddy_apply_helper) are resolved
# server-side and rejected if sent, so they are deliberately absent here.
#
# Two conditionals apply uniformly across every operation (every operation
# routes through parse_app_config, which enforces both regardless of
# operation_id): accepted_repository_host_key_fingerprint is required when
# repository_host_key_policy != "strict"; tls_dns_provider is required when
# tls_challenge_mode == "dns". The exact per-DNS-provider required credential
# keys (app_tls_credentials.py::_validate_dns_credentials) are a five-way conditional
# not encoded here -- tls_dns_credentials is schema'd as a plain string map;
# the handler's own validation still runs regardless of what T-1.5.4 enforces.
_WORKER_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["id", "start_cmd", "cpu_limit", "memory_mb", "disk_mb"],
    "properties": {
        "id": {"type": "string", "pattern": r"^[a-z0-9]+(?:-[a-z0-9]+)*$"},
        "name": {"type": "string", "minLength": 1},
        "start_cmd": {"type": "string", "minLength": 1},
        "cpu_limit": {"type": "number", "minimum": 0.1, "maximum": 64},
        "memory_mb": {"type": "integer", "minimum": 128, "maximum": 1048576},
        "disk_mb": {"type": "integer", "minimum": 256, "maximum": 1048576},
        "enabled": {"type": "boolean"},
        "database_user": {"type": ["string", "null"]},
        "database_name": {"type": ["string", "null"]},
        "database_password": {"type": ["string", "null"]},
        "database_engine": {"type": ["string", "null"], "enum": ["postgres", None]},
        "database_host": {"type": ["string", "null"]},
        "database_port": {"type": ["integer", "null"], "minimum": 1, "maximum": 65535},
    },
    "dependentRequired": {
        "database_user": ["database_name", "database_password"],
        "database_name": ["database_user", "database_password"],
        "database_password": ["database_user", "database_name"],
    },
}

_SETTINGS_PROPERTIES = {
    "project_slug": {"type": "string", "pattern": r"^[a-z0-9]+(?:-[a-z0-9]+)*$"},
    "repository_full_name": {"type": "string", "pattern": r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"},
    "branch": {"type": "string", "pattern": r"^[A-Za-z0-9._/-]+$"},
    "primary_domain": {"type": ["string", "null"]},
    "domain_routing_mode": {
        "type": "string",
        "enum": ["single_host", "redirect_www_to_apex", "redirect_apex_to_www"],
    },
    "app_port": {"type": "integer", "minimum": 1, "maximum": 65535},
    "public_health_check_enabled": {"type": "boolean"},
    "public_health_check_path": {"type": "string", "minLength": 1, "maxLength": 512},
    "repo_host": {"type": "string"},
    "railpack_build_cmd": {"type": ["string", "null"]},
    "railpack_start_cmd": {"type": ["string", "null"]},
    "railpack_provider": {
        "type": ["string", "null"],
        "enum": [
            "node",
            "python",
            "php",
            "ruby",
            "golang",
            "java",
            "rust",
            "dotnet",
            "deno",
            "elixir",
            "shell",
            "staticfile",
            None,
        ],
    },
    "app_subdirectory": {"type": ["string", "null"]},
    "worker_start_cmd": {"type": ["string", "null"]},
    "workers": {"type": ["array", "null"], "items": _WORKER_SCHEMA},
    "railpack_node_mode": {"type": "string", "enum": ["auto", "runtime"]},
    "deploy_private_key": {"type": ["string", "null"]},
    "repository_host_key_policy": {
        "type": "string",
        "enum": ["strict", "accept_new", "replace_confirmed"],
    },
    "accepted_repository_host_key_fingerprint": {
        "type": ["string", "null"],
        "pattern": r"^SHA256:[A-Za-z0-9+/=]+$",
    },
    "runtime_env": {
        "type": ["object", "null"],
        "propertyNames": {"pattern": r"^[A-Za-z_][A-Za-z0-9_]*$"},
        "additionalProperties": {"type": "string"},
    },
    "sqlite_storage": {
        "type": ["object", "null"],
        "additionalProperties": False,
        "properties": {
            "enabled": {"type": "boolean"},
            "volume_name": {"type": "string", "pattern": r"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$"},
            "mount_path": {"type": "string", "pattern": r"^/"},
            "file_name": {"type": "string", "pattern": r"^[A-Za-z0-9][A-Za-z0-9_.-]*$"},
        },
    },
    "sqlite_snapshot_mounts": {
        "type": ["array", "null"],
        "items": {
            "type": "object",
            "additionalProperties": False,
            "required": ["volume_name", "mount_path", "file_name"],
            "properties": {
                "volume_name": {
                    "type": "string",
                    "pattern": r"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$",
                },
                "mount_path": {"type": "string", "pattern": r"^/"},
                "file_name": {
                    "type": "string",
                    "pattern": r"^[A-Za-z0-9][A-Za-z0-9_.-]*$",
                },
                "path_env_key": {
                    "type": ["string", "null"],
                    "pattern": r"^[A-Za-z_][A-Za-z0-9_]*$",
                },
                "database_url_env_key": {
                    "type": ["string", "null"],
                    "pattern": r"^[A-Za-z_][A-Za-z0-9_]*$",
                },
            },
        },
    },
    "trust_network_names": {"type": ["array", "null"], "items": {"type": "string"}},
    "tls_challenge_mode": {"type": "string", "enum": ["http", "dns"]},
    "tls_dns_provider": {
        "type": ["string", "null"],
        "enum": ["cloudflare", "porkbun", "namecheap", "cloudns", "easydns", None],
    },
    "tls_dns_credentials": {
        "type": ["object", "null"],
        "additionalProperties": {"type": "string"},
    },
}

# Conditionals that apply regardless of operation_id, since every operation
# routes through parse_app_config.
#
# The first conditional deliberately omits `"required":
# ["repository_host_key_policy"]` from its `if` -- unlike every other
# conditional in this file, "absent" and "explicitly strict" really are
# equivalent here (repository_host_key_policy defaults to "strict"), so
# the vacuous match when the field is missing gives the correct answer.
# Every other conditional below requires its trigger field explicitly, or
# an absent field would vacuously satisfy `if` (JSON Schema `properties`
# only constrains keys that are present) and wrongly fire `then`.
_CROSS_FIELD_CONDITIONALS = [
    {
        "if": {
            "properties": {
                "repository_host_key_policy": {"const": "strict"},
            },
        },
        "then": {},
        "else": {"required": ["accepted_repository_host_key_fingerprint"]},
    },
    {
        "if": {
            "properties": {"tls_challenge_mode": {"const": "dns"}},
            "required": ["tls_challenge_mode"],
        },
        "then": {"required": ["tls_dns_provider"]},
    },
]


def _params_schema(
    required_settings=(),
    needs_extra_top_level=None,
    required_top_level=(),
):
    required = list(required_settings)
    settings_schema = {
        "type": "object",
        "additionalProperties": False,
        "properties": _SETTINGS_PROPERTIES,
        "required": required,
        "allOf": _CROSS_FIELD_CONDITIONALS,
    }
    properties = {
        "dry_run": {"type": "boolean"},
        "settings": settings_schema,
    }
    if needs_extra_top_level:
        properties.update(needs_extra_top_level)
    schema = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "properties": properties,
    }
    required_params = list(required_top_level)
    if required_settings:
        required_params.append("settings")
    if required_params:
        schema["required"] = required_params
    return schema


# The parser deliberately keeps defaults for optional controls, but the
# identifying intent must always be explicit at the wire boundary. A deploy
# must not silently target the sample app/repository/domain defaults; runtime
# operations need only the selected project's slug. Keep these sets adjacent
# to the operations below, rather than deriving them from APP_INTENT_DEFAULTS:
# one operation never needs every app setting.
_DEPLOYMENT_REQUIRED_SETTINGS = (
    "project_slug",
    "repository_full_name",
    "branch",
    "primary_domain",
)
_RUNTIME_REQUIRED_SETTINGS = ("project_slug",)

_LOG_TAIL_PROPERTIES = {
    "log_tail_lines": {"type": "integer", "minimum": 1},
    "tail_lines": {"type": "integer", "minimum": 1},
    "tail": {"type": "integer", "minimum": 1},
}

OPERATIONS = {
    "describe": {
        "id": "describe",
        "label": "Describe web app deploy plan",
        "description": "Preview repository build, container run, and Caddy publish actions",
        "params_schema": _params_schema(
            required_settings=_DEPLOYMENT_REQUIRED_SETTINGS,
            needs_extra_top_level={
                "parts": {"type": "array", "items": {"type": "string", "enum": ["part1"]}},
            },
        ),
    },
    "prepare_key": {
        "id": "prepare_key",
        "label": "Prepare deploy key",
        "description": "Generate/reuse project deploy key and GitHub host trust on server",
        "params_schema": _params_schema(required_settings=_RUNTIME_REQUIRED_SETTINGS),
    },
    "run": {
        "id": "run",
        "label": "Deploy web app",
        "description": "Clone private repo, build with Railpack, run container, and publish via Caddy",
        "params_schema": _params_schema(
            required_settings=_DEPLOYMENT_REQUIRED_SETTINGS,
            needs_extra_top_level={
                "parts": {"type": "array", "items": {"type": "string", "enum": ["part1"]}},
            },
        ),
    },
    "disconnect": {
        "id": "disconnect",
        "label": "Disconnect web app runtime",
        "description": "Remove web app runtime containers/code and detach Caddy route without deleting project resources",
        "params_schema": _params_schema(required_settings=_RUNTIME_REQUIRED_SETTINGS),
    },
    "resource_usage": {
        "id": "resource_usage",
        "label": "Read web app resource usage",
        "description": "Capture one-shot Docker stats for the managed web app container",
        "params_schema": _params_schema(required_settings=_RUNTIME_REQUIRED_SETTINGS),
    },
    "runtime_logs": {
        "id": "runtime_logs",
        "label": "Read web app runtime logs",
        "description": "Capture recent Docker logs from the managed web app container",
        "params_schema": _params_schema(
            required_settings=_RUNTIME_REQUIRED_SETTINGS,
            needs_extra_top_level=_LOG_TAIL_PROPERTIES,
        ),
    },
    "exec": {
        "id": "exec",
        "label": "Run one-off app command",
        "description": "Run a one-off non-interactive command inside the managed web app container",
        "params_schema": _params_schema(
            required_settings=_RUNTIME_REQUIRED_SETTINGS,
            needs_extra_top_level={
                "command": {"type": "string", "minLength": 1, "maxLength": 2000},
                "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 3600},
            },
            required_top_level=("command",),
        ),
    },
    "list_releases": {
        "id": "list_releases",
        "label": "Read release inventory",
        "description": "Read live, retained, and failed release metadata for this web app",
        "params_schema": _params_schema(required_settings=_RUNTIME_REQUIRED_SETTINGS),
    },
    "rollback": {
        "id": "rollback",
        "label": "Rollback web app",
        "description": "Start a retained release, switch live traffic after health checks, and keep the previous live release as fallback",
        "params_schema": _params_schema(
            required_settings=_RUNTIME_REQUIRED_SETTINGS,
            needs_extra_top_level={
                "release_id": {"type": "string", "minLength": 1},
            },
        ),
    },
    "sqlite_volume_ensure": {
        "id": "sqlite_volume_ensure",
        "label": "Ensure SQLite volume",
        "description": "Create SQLite Docker volume when missing and return volume metadata",
        "params_schema": _params_schema(required_settings=_RUNTIME_REQUIRED_SETTINGS),
    },
    "sqlite_volume_status": {
        "id": "sqlite_volume_status",
        "label": "Read SQLite volume status",
        "description": "Inspect configured SQLite Docker volume metadata",
        "params_schema": _params_schema(required_settings=_RUNTIME_REQUIRED_SETTINGS),
    },
    "sqlite_volume_delete": {
        "id": "sqlite_volume_delete",
        "label": "Delete SQLite volume",
        "description": "Delete configured SQLite Docker volume and return resulting status",
        "params_schema": _params_schema(required_settings=_RUNTIME_REQUIRED_SETTINGS),
    },
    "workers_apply": {
        "id": "workers_apply",
        "label": "Apply workers runtime",
        "description": "Create/update managed worker containers for this project",
        "params_schema": _params_schema(required_settings=_RUNTIME_REQUIRED_SETTINGS),
    },
    "workers_precheck": {
        "id": "workers_precheck",
        "label": "Check workers runtime prerequisites",
        "description": "Inspect image/container/network readiness for worker operations",
        "params_schema": _params_schema(required_settings=_RUNTIME_REQUIRED_SETTINGS),
    },
    "workers_status": {
        "id": "workers_status",
        "label": "Read workers runtime status",
        "description": "Read managed worker container states and one-shot stats",
        "params_schema": _params_schema(required_settings=_RUNTIME_REQUIRED_SETTINGS),
    },
    "worker_start": {
        "id": "worker_start",
        "label": "Start a worker runtime",
        "description": "Start a specific managed worker container",
        "params_schema": _params_schema(
            required_settings=_RUNTIME_REQUIRED_SETTINGS,
            needs_extra_top_level={
                "worker_id": {"type": "string", "minLength": 1},
            },
            required_top_level=("worker_id",),
        ),
    },
    "worker_stop": {
        "id": "worker_stop",
        "label": "Stop a worker runtime",
        "description": "Stop and remove a specific managed worker container",
        "params_schema": _params_schema(
            required_settings=_RUNTIME_REQUIRED_SETTINGS,
            needs_extra_top_level={
                "worker_id": {"type": "string", "minLength": 1},
            },
            required_top_level=("worker_id",),
        ),
    },
    "worker_restart": {
        "id": "worker_restart",
        "label": "Restart a worker runtime",
        "description": "Restart a specific managed worker container",
        "params_schema": _params_schema(
            required_settings=_RUNTIME_REQUIRED_SETTINGS,
            needs_extra_top_level={
                "worker_id": {"type": "string", "minLength": 1},
            },
            required_top_level=("worker_id",),
        ),
    },
    "worker_logs": {
        "id": "worker_logs",
        "label": "Read worker runtime logs",
        "description": "Capture recent Docker logs from a managed worker container",
        "params_schema": _params_schema(
            required_settings=_RUNTIME_REQUIRED_SETTINGS,
            needs_extra_top_level={
                "worker_id": {"type": "string", "minLength": 1},
                **_LOG_TAIL_PROPERTIES,
            },
            required_top_level=("worker_id",),
        ),
    },
}
