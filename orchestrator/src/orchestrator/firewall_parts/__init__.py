WORKFLOW_ID = "firewall"

# T-1.5.3: params_schema describes payload["params"]. Source of truth is
# engine_firewall_ops.py::_parse_firewall_settings, which is soft-typed --
# every top-level field silently falls back to a default rather than
# raising, so nothing here is required at the top level. The one hard
# validation is inside custom_rules items: protocol and port_start raise on
# a malformed value if the item is present at all (a malformed item outside
# a dict, or a whole non-list custom_rules, is silently dropped/ignored
# rather than rejected -- not encoded here since JSON Schema validates the
# declared shape, not "ignore if wrong type").
_CUSTOM_RULE_SCHEMA = {
    "type": "object",
    "required": ["protocol", "port_start"],
    "properties": {
        "id": {"type": "string"},
        "protocol": {"type": "string", "enum": ["tcp", "udp"]},
        "port_start": {"type": "integer", "minimum": 1, "maximum": 65535},
        "port_end": {"type": "integer", "minimum": 1, "maximum": 65535},
        "source_cidr": {"type": ["string", "null"]},
        "enabled": {"type": "boolean"},
        "description": {"type": ["string", "null"]},
    },
}

_SETTINGS_PROPERTIES = {
    "strict_mode": {"type": "boolean"},
    "allow_postgres": {"type": "boolean"},
    "postgres_source_cidrs": {
        "type": "array",
        "maxItems": 32,
        "items": {"type": "string"},
    },
    "allow_dns": {"type": "boolean"},
    "allow_smtp": {"type": "boolean"},
    "allow_mail_receive": {"type": "boolean"},
    "rollback_timeout_seconds": {"type": "integer", "minimum": 30, "maximum": 3600},
    "locked_ports": {
        "type": "array",
        "items": {"type": "integer", "minimum": 1, "maximum": 65535},
    },
    "custom_rules": {"type": "array", "items": _CUSTOM_RULE_SCHEMA},
    "stage_token": {"type": ["string", "null"]},
}


def _params_schema():
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "dry_run": {"type": "boolean"},
            "settings": {
                "type": "object",
                "additionalProperties": False,
                "properties": _SETTINGS_PROPERTIES,
            },
        },
    }


OPERATIONS = {
    "describe": {
        "id": "describe",
        "label": "Describe firewall plan",
        "description": (
            "Describe Docker-safe firewall management operations for host and container ingress"
        ),
        "params_schema": _params_schema(),
    },
    "status": {
        "id": "status",
        "label": "Read firewall status",
        "description": "Read managed firewall chain status and staged apply state",
        "params_schema": _params_schema(),
    },
    "scan_open_ports": {
        "id": "scan_open_ports",
        "label": "Scan open ports",
        "description": "List host listeners and Docker published ports",
        "params_schema": _params_schema(),
    },
    "apply_staged": {
        "id": "apply_staged",
        "label": "Apply staged firewall policy",
        "description": "Apply strict policy with timed auto-rollback safety",
        "params_schema": _params_schema(),
    },
    "commit": {
        "id": "commit",
        "label": "Commit staged firewall policy",
        "description": "Confirm staged firewall changes and cancel rollback timer",
        "params_schema": _params_schema(),
    },
    "rollback": {
        "id": "rollback",
        "label": "Rollback staged firewall policy",
        "description": "Restore pre-stage firewall snapshot immediately",
        "params_schema": _params_schema(),
    },
}
