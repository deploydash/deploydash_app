from .dns_config import (
    CANONICAL_DNS_SETTINGS,
    DnsConfig,
    DnsConfigValidationError,
    parse_dns_config,
)
from .dns_plan import ALL_PARTS, PART_BUILDERS, collect_steps, normalize_parts

WORKFLOW_ID = "dns"

# T-1.5.3: params_schema describes payload["params"]. "settings" properties
# are Class C intent keys only (DNS_INTENT_DEFAULTS in dns_config.py) --
# Class A keys (stack_root, container_name, bind_image, bind_service_name)
# are resolved server-side and rejected if sent, so they are deliberately
# absent here. This is an authoritative-only Bind9 workflow:
# allow_recursion must be false and forwarders must be empty (hard errors
# otherwise), encoded as const/maxItems rather than a soft default.
_RECORD_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["name", "type", "value"],
    "properties": {
        "name": {"type": "string"},
        "type": {"type": "string", "enum": ["A", "AAAA"]},
        "value": {"type": "string"},
    },
}

_ZONE_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "zone_name": {"type": "string"},
        "default_a_ipv4": {"type": ["string", "null"]},
        "default_aaaa_ipv6": {"type": ["string", "null"]},
        "admin_email": {"type": "string"},
        "zone_serial": {"type": "integer", "minimum": 1},
        "zone_ttl": {"type": "integer", "minimum": 1},
        "zone_refresh": {"type": "integer", "minimum": 1},
        "zone_retry": {"type": "integer", "minimum": 1},
        "zone_expire": {"type": "integer", "minimum": 1},
        "zone_negative_ttl": {"type": "integer", "minimum": 1},
        "extra_records": {"type": "array", "items": _RECORD_SCHEMA},
        # Legacy alias for extra_records, A-only shorthand (accepted at
        # both zone level and top-level settings below).
        "extra_a_records": {"type": "array"},
    },
}

_SETTINGS_PROPERTIES = {
    "zone_name": {"type": "string"},
    "nameserver_hostname": {"type": "string"},
    "nameserver_ipv4": {"type": ["string", "null"]},
    "nameserver_ipv6": {"type": ["string", "null"]},
    "default_a_ipv4": {"type": ["string", "null"]},
    "default_aaaa_ipv6": {"type": ["string", "null"]},
    "admin_email": {"type": "string"},
    "zone_serial": {"type": "integer", "minimum": 1},
    "zone_ttl": {"type": "integer", "minimum": 1},
    "zone_refresh": {"type": "integer", "minimum": 1},
    "zone_retry": {"type": "integer", "minimum": 1},
    "zone_expire": {"type": "integer", "minimum": 1},
    "zone_negative_ttl": {"type": "integer", "minimum": 1},
    "allow_recursion": {"const": False},
    "recursion_cidrs": {"type": "array", "items": {"type": "string"}},
    "forwarders": {"type": "array", "maxItems": 0},
    "listen_on_ipv6": {"type": "boolean"},
    "extra_records": {"type": "array", "items": _RECORD_SCHEMA},
    "extra_a_records": {"type": "array"},
    "zones": {"type": "array", "items": _ZONE_SCHEMA},
}


def _params_schema():
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "dry_run": {"type": "boolean"},
            "parts": {"type": "array", "items": {"type": "string", "enum": list(ALL_PARTS)}},
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
        "label": "Describe DNS plan",
        "description": "Preview Bind9 installation and zone configuration actions",
        "params_schema": _params_schema(),
    },
    "run": {
        "id": "run",
        "label": "Run DNS plan",
        "description": "Apply Bind9 installation and authoritative zone actions",
        "params_schema": _params_schema(),
    },
}
