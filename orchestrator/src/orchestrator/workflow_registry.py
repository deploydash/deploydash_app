from .app_parts import OPERATIONS as APP_OPERATIONS
from .dns_parts import OPERATIONS as DNS_OPERATIONS
from .firewall_parts import OPERATIONS as FIREWALL_OPERATIONS
from .http_parts import OPERATIONS as HTTP_OPERATIONS
from .mail_parts import OPERATIONS as MAIL_OPERATIONS
from .postgres_parts import OPERATIONS as POSTGRES_OPERATIONS
from .scheduler_parts import OPERATIONS as SCHEDULER_OPERATIONS

# T-1.5.3: params_schema conventions.
#
# For every workflow except "setup" and the "check"/"refresh_host_key"
# operations of "server", params_schema describes payload["params"] as sent
# by SSHService.runWorkflowStream (params_schema/dry_run.settings.*, plus
# any operation-specific top-level params keys).
#
# "setup" (both operations) and "server"/"check"/"refresh_host_key" are the
# four operations T-1.5.2 migrated from bespoke pre-run_workflow action
# strings to run_workflow addressing without changing their payload shape,
# to avoid a settings-nesting hazard (setup_config.py's _select_settings has
# no params-nested fallback for "settings", unlike every other workflow's
# extraction helper). Their fields still sit at the TOP LEVEL of the request
# payload, not nested under "params" -- so their params_schema below
# describes that top-level shape instead. This is a real, flagged
# architectural inconsistency (see T-1.5.2's evidence comment and this
# task's own note in the plan), not an oversight; T-1.5.4 will need to
# decide where each operation's schema is actually validated against.
_SETUP_SETTINGS_PROPERTIES = {
    "hostname": {"type": ["string", "null"]},
    "timezone": {"type": "string", "minLength": 1},
    "ssh_public_key": {"type": ["string", "null"]},
    "disable_password_auth": {"type": "boolean"},
    "disable_root_login": {"type": "boolean"},
    "ssh_banner_text": {"type": "string", "minLength": 1},
}

# The four operations below are intentionally validated against the entire
# request instead of ``payload["params"]``.  Keep this list in the registry:
# ``runtime.py`` selects these schemas before any plugin is allowed to inspect
# the payload, so a field omitted here is a rejected wire-contract change.
#
# ``task_id`` is accepted for recorded/replayed task envelopes.  The desktop
# task runtime normally allocates it after accepting the request, but it is an
# envelope field rather than an operation parameter and must not be mistaken
# for an unknown setup or server setting.
_FLAT_ENVELOPE_PROPERTIES = {
    "protocol": {"type": "integer", "minimum": 1},
    "action": {"const": "run_workflow"},
    "workflow_id": {"type": "string", "minLength": 1},
    "operation_id": {"type": "string", "minLength": 1},
    "task_id": {"type": "integer", "minimum": 1},
    "client_operation_id": {"type": "string", "minLength": 1},
    "idempotency_key": {"type": "string", "minLength": 1},
}

_FLAT_CONNECTION_PROPERTIES = {
    "connection": {"type": "object"},
    "server": {"type": "object"},
    "host": {"type": "string", "minLength": 1},
    "ip": {"type": "string", "minLength": 1},
    "port": {"type": "integer", "minimum": 1, "maximum": 65535},
    "username": {"type": "string", "minLength": 1},
    "password": {"type": ["string", "null"]},
    "private_key": {"type": ["string", "null"]},
    # Retained for legacy replay compatibility.  The connection extractor
    # deliberately ignores workstation paths, but old flat envelopes may
    # still carry this field and must not fail before that compatibility path.
    "key_path": {"type": ["string", "null"]},
}

_SETUP_OPERATION_PROPERTIES = {
    "parts": {"type": "array", "items": {"type": "string"}},
    "dry_run": {"type": "boolean"},
    "managed_connection": {"type": "object"},
}

# Unlike every other workflow, setup_config.py's _select_settings does not
# merge over a canonical-defaults dict before parsing -- callers must send a
# complete settings object (every key below present, values nullable where
# noted) or the parse rejects it as missing keys.
_SETUP_TOP_LEVEL_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "additionalProperties": False,
    "properties": {
        **_FLAT_ENVELOPE_PROPERTIES,
        **_FLAT_CONNECTION_PROPERTIES,
        **_SETUP_OPERATION_PROPERTIES,
        # "settings" itself is optional -- if entirely absent (or null),
        # _select_settings returns the full canonical defaults dict. Only
        # if the caller DOES send "settings" must it be complete (every key
        # below present; only admin_user gets defaulted at that point).
        "settings": {
            "type": "object",
            "additionalProperties": False,
            "properties": _SETUP_SETTINGS_PROPERTIES,
            "required": list(_SETUP_SETTINGS_PROPERTIES.keys()),
        },
        # setup's extraction helpers still read this legacy compatibility
        # fallback.  Close it separately so it cannot re-open the flat
        # contract through arbitrary nested fields.
        "params": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                **_SETUP_OPERATION_PROPERTIES,
                "settings": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": _SETUP_SETTINGS_PROPERTIES,
                    "required": list(_SETUP_SETTINGS_PROPERTIES.keys()),
                },
            },
        },
    },
}

_LEGACY_FLAT_NO_PARAMS_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "additionalProperties": False,
    "properties": {
        **_FLAT_ENVELOPE_PROPERTIES,
        **_FLAT_CONNECTION_PROPERTIES,
    },
}

_MANAGED_COMPONENT_IDS = (
    "railpack_build_system",
    "docker_runtime",
    "http_gateway",
    "dns_service",
    "walg_backup_tool",
    "postgresql_database_service",
)

_SYSTEM_APPLY_SETTINGS_PROPERTIES = {
    "root_login_mode": {
        "type": "string",
        "enum": ["disabled", "key_only", "password_allowed", "restricted"],
    },
    "root_login_enabled": {"type": "boolean"},
    "password_auth_enabled": {"type": "boolean"},
    "ssh_port": {"type": "integer", "minimum": 1, "maximum": 65535},
    "timezone": {"type": "string"},
    "swap_gb": {"type": "number", "minimum": 0, "maximum": 64},
    "automatic_security_updates_enabled": {"type": "boolean"},
    "auto_reboot_enabled": {"type": "boolean"},
    "maintenance_time": {
        "type": "string",
        "pattern": r"^(?:[01]?\d|2[0-3]):[0-5]\d$",
    },
}


def _no_extra_params_schema():
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "properties": {"dry_run": {"type": "boolean"}},
    }


WORKFLOW_REGISTRY = {
    "setup": {
        "describe": {
            "id": "describe",
            "label": "Describe setup plan",
            "description": "Preview server foundation actions before applying them",
            "params_schema": _SETUP_TOP_LEVEL_SCHEMA,
        },
        "run": {
            "id": "run",
            "label": "Run setup plan",
            "description": "Apply selected server foundation actions",
            "params_schema": _SETUP_TOP_LEVEL_SCHEMA,
        },
    },
    "postgres": POSTGRES_OPERATIONS,
    "mail": MAIL_OPERATIONS,
    "dns": DNS_OPERATIONS,
    "http": HTTP_OPERATIONS,
    "app": APP_OPERATIONS,
    "firewall": FIREWALL_OPERATIONS,
    "scheduler": SCHEDULER_OPERATIONS,
    "server": {
        "check": {
            "id": "check",
            "label": "Check server connection",
            "description": "Verify SSH access and collect server facts",
            "params_schema": _LEGACY_FLAT_NO_PARAMS_SCHEMA,
        },
        "refresh_host_key": {
            "id": "refresh_host_key",
            "label": "Refresh SSH host key",
            "description": ("Remove stale SSH known_hosts entries after a server rebuild"),
            "params_schema": _LEGACY_FLAT_NO_PARAMS_SCHEMA,
        },
        "overview_metrics": {
            "id": "overview_metrics",
            "label": "Read server overview metrics",
            "description": "Collect CPU, memory, disk, and network metrics from a provisioned server",
            "params_schema": _no_extra_params_schema(),
        },
        "system_status": {
            "id": "system_status",
            "label": "Read system settings",
            "description": "Collect effective SSH, timezone, swap, and maintenance settings",
            "params_schema": _no_extra_params_schema(),
        },
        "system_apply": {
            "id": "system_apply",
            "label": "Apply system settings",
            "description": "Apply SSH, timezone, swap, and maintenance settings with guardrails",
            "params_schema": {
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "dry_run": {"type": "boolean"},
                    "settings": {
                        "type": "object",
                        "additionalProperties": False,
                        "properties": _SYSTEM_APPLY_SETTINGS_PROPERTIES,
                    },
                },
            },
        },
        "system_restart": {
            "id": "system_restart",
            "label": "Restart server",
            "description": "Restart the server and verify managed services after SSH returns",
            "params_schema": _no_extra_params_schema(),
        },
        "docker_storage_status": {
            "id": "docker_storage_status",
            "label": "Read Docker storage status",
            "description": "Collect Docker image and build cache disk usage from the server",
            "params_schema": _no_extra_params_schema(),
        },
        "docker_storage_prune": {
            "id": "docker_storage_prune",
            "label": "Clean Docker storage",
            "description": "Remove unused Docker images or clear the Docker build cache",
            "params_schema": {
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "additionalProperties": False,
                "required": ["target"],
                "properties": {
                    "dry_run": {"type": "boolean"},
                    "target": {
                        "type": "string",
                        "enum": ["unused_images", "build_cache"],
                    },
                },
            },
        },
        "tooling_status": {
            "id": "tooling_status",
            "label": "Read managed software status",
            "description": "Check managed server software versions, helper files, and rollback records",
            "params_schema": _no_extra_params_schema(),
        },
        "tooling_update": {
            "id": "tooling_update",
            "label": "Update managed software",
            "description": "Install pinned Deploy Dash managed server software",
            "params_schema": {
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "dry_run": {"type": "boolean"},
                    "component_ids": {
                        "type": "array",
                        "items": {"type": "string", "enum": list(_MANAGED_COMPONENT_IDS)},
                    },
                },
            },
        },
        "tooling_rollback": {
            "id": "tooling_rollback",
            "label": "Rollback managed software",
            "description": "Rollback one managed server software component from its recorded snapshot",
            "params_schema": {
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "additionalProperties": False,
                "required": ["component_id"],
                "properties": {
                    "dry_run": {"type": "boolean"},
                    "component_id": {
                        "type": "string",
                        "enum": list(_MANAGED_COMPONENT_IDS),
                    },
                    "restore_data": {"type": "boolean"},
                },
            },
        },
    },
    "core": {
        "echo": {
            "id": "echo",
            "label": "Echo payload",
            "description": "Return payload unchanged for diagnostics",
            # core/echo is a diagnostic passthrough of arbitrary JSON
            # (core_plugin.py::handle_echo reads data.get("data") at the top
            # level and echoes it back) -- there is no shape to schema.
            "params_schema": {
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "properties": {},
            },
        },
    },
}


def workflow_operation_exists(workflow_id, operation_id):
    workflow = WORKFLOW_REGISTRY.get(workflow_id)
    if not isinstance(workflow, dict):
        return False
    return operation_id in workflow
