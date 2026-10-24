import functools
import ipaddress
import re
import socket
from dataclasses import dataclass
from urllib.parse import urlparse

from .. import (
    config_validation,
    platform_versions,
    server_identifiers,
    server_paths,
)
from ..addressing import strip_address_brackets

# Class A/B (docs/contracts/settings-ownership.md): resolved by the backend,
# never intent. `container_name` has no `server_identifiers.py` to resolve
# from yet -- that module doesn't exist until T-3.4.1, whose own text notes
# it is "completing" what T-1.4 starts, not a T-1.4.3 prerequisite. Kept as a
# literal here until then.
RESOLVED_HTTP_DEFAULTS = {
    "stack_root": server_paths.http_root(),
    "container_name": server_identifiers.caddy_container(),
    "caddy_image": platform_versions.CADDY_IMAGE,
}

# Class C: the wire's actual contract. `server_address` is here, not in the
# resolved half, despite an early classification pass calling it class B --
# `test_parse_accepts_complete_settings` and
# `test_parse_resolves_hostname_server_ip` below both send it and expect the
# override honored, the same fallback-to-discovery shape already classified
# C for DNS's `nameserver_ipv4`/`nameserver_ipv6`. Reclassified; see T-1.4.3's
# note in the plan.
HTTP_INTENT_DEFAULTS = {
    "default_hostname": "localhost",
    "server_address": None,
    "default_page_title": "Deploy Dash HTTP gateway is online",
    "default_page_message": (
        "Caddy is running and ready to proxy Django/Laravel/Rails/Next.js apps."
    ),
    "serve_ip_over_https": True,
    "enable_https_redirect": True,
    "enable_response_compression": True,
    "enable_access_logs": False,
    "enable_on_demand_tls": False,
    "on_demand_tls_ask_endpoint": None,
    "enable_dns_plugin_cloudflare": False,
    "enable_dns_plugin_porkbun": False,
    "enable_dns_plugin_namecheap": False,
    "enable_dns_plugin_cloudns": False,
    "enable_dns_plugin_easydns": False,
}

# T-1.4.3 splits the dictionary; T-1.4.4 is what actually stops
# RESOLVED_HTTP_DEFAULTS keys from being wire-accepted (today,
# `container_name`/`caddy_image` still are -- see
# `test_parse_accepts_complete_settings`). Until then this stays the full
# merge, byte-for-byte the same dictionary parse_http_config saw before this
# split.
CANONICAL_HTTP_SETTINGS = {**RESOLVED_HTTP_DEFAULTS, **HTTP_INTENT_DEFAULTS}

REQUIRED_HTTP_SETTING_KEYS = (
    "stack_root",
    "container_name",
    "caddy_image",
    "default_hostname",
    "server_address",
    "default_page_title",
    "default_page_message",
    "serve_ip_over_https",
)
ALLOWED_HTTP_SETTING_KEYS = (*CANONICAL_HTTP_SETTINGS.keys(), "server_ip")


class HttpConfigValidationError(ValueError):
    pass


# Bound once per module rather than passed at all 7 call sites below.
#
# These are not copies -- T-3.8.1 deleted those. Each is `config_validation`'s
# single implementation with this module's error class already supplied, which
# is the same "parameterise the original, bind the exception class" shape
# `settings_ownership.reject_server_owned_keys(raw, error_class)` established.
_required_string = functools.partial(
    config_validation.required_string,
    error_class=HttpConfigValidationError,
)
_required_bool = functools.partial(
    config_validation.required_bool,
    error_class=HttpConfigValidationError,
)


@dataclass(frozen=True)
class HttpConfig:
    stack_root: str
    container_name: str
    caddy_image: str
    default_hostname: str
    server_address: str
    default_page_title: str
    default_page_message: str
    serve_ip_over_https: bool
    enable_https_redirect: bool
    enable_response_compression: bool
    enable_access_logs: bool
    enable_on_demand_tls: bool
    on_demand_tls_ask_endpoint: str | None
    enable_dns_plugin_cloudflare: bool
    enable_dns_plugin_porkbun: bool
    enable_dns_plugin_namecheap: bool
    enable_dns_plugin_cloudns: bool
    enable_dns_plugin_easydns: bool

    @property
    def server_ip(self):
        return self.server_address


def parse_http_config(raw_data, connection_ip=None, trusted=False):
    """Parse an HTTP gateway configuration request.

    `trusted=True` skips the server-owned-key rejection and is only for
    callers inside the backend that build settings from the canonical
    defaults themselves -- the setup HTTP bootstrap and the app deploy path.
    Requests arriving over the wire must never set it. Section 1.4 of the
    pre-1.0 plan removes the need for it by making the remaining
    infrastructure keys server-owned at their source.
    """
    settings = config_validation.select_settings(
        raw_data,
        canonical=CANONICAL_HTTP_SETTINGS,
        error_class=HttpConfigValidationError,
        trusted=trusted,
    )
    # After the merge, not inside it: the fallback reads a key the canonical
    # defaults supply, so it has nothing to read until they are underneath.
    if (
        settings.get("server_address") is None or settings.get("server_address") == ""
    ) and "server_ip" in settings:
        settings["server_address"] = settings.get("server_ip")
    config_validation.validate_setting_keys(
        settings,
        allowed=ALLOWED_HTTP_SETTING_KEYS,
        required=REQUIRED_HTTP_SETTING_KEYS,
        error_class=HttpConfigValidationError,
    )

    stack_root = _required_string(settings["stack_root"], "settings.stack_root")
    container_name = _required_string(
        settings["container_name"],
        "settings.container_name",
    )
    caddy_image = _required_string(settings["caddy_image"], "settings.caddy_image")
    default_hostname = _required_hostname(
        settings["default_hostname"],
        "settings.default_hostname",
    )
    server_address = _optional_ip_or_hostname(
        settings["server_address"],
        "settings.server_address",
    )
    if server_address is None:
        server_address = _optional_ip_or_hostname(connection_ip, "connection.host")
    if server_address is None:
        raise HttpConfigValidationError(
            "settings.server_address is required when connection.host is missing.",
        )

    default_page_title = _required_string(
        settings["default_page_title"],
        "settings.default_page_title",
    )
    default_page_message = _required_string(
        settings["default_page_message"],
        "settings.default_page_message",
    )
    serve_ip_over_https = _required_bool(
        settings["serve_ip_over_https"],
        "settings.serve_ip_over_https",
    )
    enable_https_redirect = _bool_with_default(
        settings.get("enable_https_redirect"),
        "settings.enable_https_redirect",
        CANONICAL_HTTP_SETTINGS["enable_https_redirect"],
    )
    enable_response_compression = _bool_with_default(
        settings.get("enable_response_compression"),
        "settings.enable_response_compression",
        CANONICAL_HTTP_SETTINGS["enable_response_compression"],
    )
    enable_access_logs = _bool_with_default(
        settings.get("enable_access_logs"),
        "settings.enable_access_logs",
        CANONICAL_HTTP_SETTINGS["enable_access_logs"],
    )
    enable_on_demand_tls = _bool_with_default(
        settings.get("enable_on_demand_tls"),
        "settings.enable_on_demand_tls",
        CANONICAL_HTTP_SETTINGS["enable_on_demand_tls"],
    )
    on_demand_tls_ask_endpoint = _optional_http_url(
        settings.get("on_demand_tls_ask_endpoint"),
        "settings.on_demand_tls_ask_endpoint",
    )
    if enable_on_demand_tls and not on_demand_tls_ask_endpoint:
        raise HttpConfigValidationError(
            "settings.on_demand_tls_ask_endpoint is required when "
            "settings.enable_on_demand_tls is true.",
        )
    enable_dns_plugin_cloudflare = _bool_with_default(
        settings.get("enable_dns_plugin_cloudflare"),
        "settings.enable_dns_plugin_cloudflare",
        CANONICAL_HTTP_SETTINGS["enable_dns_plugin_cloudflare"],
    )
    enable_dns_plugin_porkbun = _bool_with_default(
        settings.get("enable_dns_plugin_porkbun"),
        "settings.enable_dns_plugin_porkbun",
        CANONICAL_HTTP_SETTINGS["enable_dns_plugin_porkbun"],
    )
    enable_dns_plugin_namecheap = _bool_with_default(
        settings.get("enable_dns_plugin_namecheap"),
        "settings.enable_dns_plugin_namecheap",
        CANONICAL_HTTP_SETTINGS["enable_dns_plugin_namecheap"],
    )
    enable_dns_plugin_cloudns = _bool_with_default(
        settings.get("enable_dns_plugin_cloudns"),
        "settings.enable_dns_plugin_cloudns",
        CANONICAL_HTTP_SETTINGS["enable_dns_plugin_cloudns"],
    )
    enable_dns_plugin_easydns = _bool_with_default(
        settings.get("enable_dns_plugin_easydns"),
        "settings.enable_dns_plugin_easydns",
        CANONICAL_HTTP_SETTINGS["enable_dns_plugin_easydns"],
    )
    return HttpConfig(
        stack_root=stack_root,
        container_name=container_name,
        caddy_image=caddy_image,
        default_hostname=default_hostname,
        server_address=server_address,
        default_page_title=default_page_title,
        default_page_message=default_page_message,
        serve_ip_over_https=serve_ip_over_https,
        enable_https_redirect=enable_https_redirect,
        enable_response_compression=enable_response_compression,
        enable_access_logs=enable_access_logs,
        enable_on_demand_tls=enable_on_demand_tls,
        on_demand_tls_ask_endpoint=on_demand_tls_ask_endpoint,
        enable_dns_plugin_cloudflare=enable_dns_plugin_cloudflare,
        enable_dns_plugin_porkbun=enable_dns_plugin_porkbun,
        enable_dns_plugin_namecheap=enable_dns_plugin_namecheap,
        enable_dns_plugin_cloudns=enable_dns_plugin_cloudns,
        enable_dns_plugin_easydns=enable_dns_plugin_easydns,
    )


def _required_hostname(value, field_name):
    hostname = _required_string(value, field_name).lower()
    if hostname == "localhost":
        return hostname

    fqdn_pattern = re.compile(
        r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
        r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$"
    )
    if not fqdn_pattern.match(hostname):
        raise HttpConfigValidationError(
            f"{field_name} must be a valid FQDN or localhost.",
        )
    return hostname


def _optional_ip_or_hostname(value, field_name):
    if value is None:
        return None

    candidate = value.strip() if isinstance(value, str) else str(value).strip()

    candidate = strip_address_brackets(candidate)

    if not candidate:
        return None

    try:
        return str(ipaddress.ip_address(candidate))
    except ValueError:
        resolved_ip = _resolve_hostname_to_ip(candidate)
        if resolved_ip is not None:
            return resolved_ip
        raise HttpConfigValidationError(
            f"{field_name} must be a valid IP or resolvable hostname.",
        ) from None


def _resolve_hostname_to_ip(hostname):
    try:
        addrinfo = socket.getaddrinfo(hostname, None, type=socket.SOCK_STREAM)
    except socket.gaierror:
        return None

    ipv6_fallback = None
    for family, _, _, _, sockaddr in addrinfo:
        if family == socket.AF_INET:
            return str(ipaddress.ip_address(sockaddr[0]))
        if family == socket.AF_INET6 and ipv6_fallback is None:
            ipv6_fallback = str(ipaddress.ip_address(sockaddr[0]))
    return ipv6_fallback


def _bool_with_default(value, field_name, default):
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    raise HttpConfigValidationError(f"{field_name} must be a boolean.")


def _optional_http_url(value, field_name):
    if value is None:
        return None

    if not isinstance(value, str):
        raise HttpConfigValidationError(f"{field_name} must be a string URL.")

    candidate = value.strip()
    if not candidate:
        return None

    parsed = urlparse(candidate)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise HttpConfigValidationError(
            f"{field_name} must be an absolute http(s) URL.",
        )
    return candidate
