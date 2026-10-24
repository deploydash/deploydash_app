from .http_config import (
    CANONICAL_HTTP_SETTINGS,
    HttpConfig,
    HttpConfigValidationError,
    parse_http_config,
)
from .http_plan import ALL_PARTS, PART_BUILDERS, collect_steps, normalize_parts

WORKFLOW_ID = "http"

# T-1.5.3: params_schema describes payload["params"]. "settings" properties
# are Class C intent keys only (HTTP_INTENT_DEFAULTS in http_config.py) --
# Class A keys (stack_root, container_name, caddy_image) are resolved
# server-side and rejected if sent, so they are deliberately absent here.
# Every intent key has a canonical default merged in server-side
# (parse_http_config's _select_settings), so nothing is unconditionally
# required from the wire, except on_demand_tls_ask_endpoint when
# enable_on_demand_tls is true. server_address falls back to connection.host
# when absent -- a cross-object condition this schema (scoped to "params",
# not "connection") cannot express, so it stays optional here. server_ip is
# a still-accepted legacy alias for server_address
# (ALLOWED_HTTP_SETTING_KEYS explicitly includes it).
_SETTINGS_PROPERTIES = {
    "default_hostname": {"type": "string"},
    "server_address": {"type": ["string", "null"]},
    "server_ip": {"type": ["string", "null"]},
    "default_page_title": {"type": "string"},
    "default_page_message": {"type": "string"},
    "serve_ip_over_https": {"type": "boolean"},
    "enable_https_redirect": {"type": "boolean"},
    "enable_response_compression": {"type": "boolean"},
    "enable_access_logs": {"type": "boolean"},
    "enable_on_demand_tls": {"type": "boolean"},
    "on_demand_tls_ask_endpoint": {"type": ["string", "null"], "format": "uri"},
    "enable_dns_plugin_cloudflare": {"type": "boolean"},
    "enable_dns_plugin_porkbun": {"type": "boolean"},
    "enable_dns_plugin_namecheap": {"type": "boolean"},
    "enable_dns_plugin_cloudns": {"type": "boolean"},
    "enable_dns_plugin_easydns": {"type": "boolean"},
}

_ON_DEMAND_TLS_CONDITIONAL = {
    "if": {
        "properties": {"enable_on_demand_tls": {"const": True}},
        "required": ["enable_on_demand_tls"],
    },
    "then": {"required": ["on_demand_tls_ask_endpoint"]},
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
                "allOf": [_ON_DEMAND_TLS_CONDITIONAL],
            },
        },
    }


OPERATIONS = {
    "describe": {
        "id": "describe",
        "label": "Describe HTTP service plan",
        "description": "Preview modular Caddy gateway actions",
        "params_schema": _params_schema(),
    },
    "run": {
        "id": "run",
        "label": "Run HTTP service plan",
        "description": "Apply modular Caddy gateway actions",
        "params_schema": _params_schema(),
    },
    "service_enable": {
        "id": "service_enable",
        "label": "Enable Web server service",
        "description": "Install and start Caddy web server stack",
        "params_schema": _params_schema(),
    },
    "service_start": {
        "id": "service_start",
        "label": "Start Web server service",
        "description": "Start the Caddy container if it is stopped",
        "params_schema": _params_schema(),
    },
    "service_stop": {
        "id": "service_stop",
        "label": "Stop Web server service",
        "description": "Stop the Caddy container",
        "params_schema": _params_schema(),
    },
    "service_restart": {
        "id": "service_restart",
        "label": "Restart Web server service",
        "description": "Restart the Caddy container",
        "params_schema": _params_schema(),
    },
    "service_configure": {
        "id": "service_configure",
        "label": "Configure Web server service",
        "description": "Apply safe defaults for Caddy behavior and fallback page",
        "params_schema": _params_schema(),
    },
    "service_status": {
        "id": "service_status",
        "label": "Get Web server status",
        "description": "Read current Caddy container runtime status",
        "params_schema": _params_schema(),
    },
}
