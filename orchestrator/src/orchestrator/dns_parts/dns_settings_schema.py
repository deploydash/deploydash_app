"""Canonical DNS settings and the value types validated settings become.

Split out of `dns_config.py` by T-3.3.4 along the boundary §1.4 introduced --
resolved (class A/B) here, caller intent (class C) in `dns_config_fields.py`.

`DnsRecord` and `DnsZone` live here rather than beside `parse_dns_config`
because the field validators construct them and `dns_config.py` imports those
validators; keeping them together made a cycle. `DnsConfig` stays there,
since nothing but the parser builds it.

`dns_config.py` re-exports what callers import, so the public path is
unchanged.
"""

import functools
import re
from dataclasses import dataclass

from .. import (
    config_validation,
    platform_versions,
    server_identifiers,
    server_paths,
)

# Class A (docs/contracts/settings-ownership.md): resolved by the backend.
# `container_name`/`bind_service_name` have no `server_identifiers.py` to
# resolve from yet -- see the note on RESOLVED_HTTP_DEFAULTS in
# http_config.py; same reason, same deferral to T-3.4.1.
RESOLVED_DNS_DEFAULTS = {
    "stack_root": server_paths.dns_root(),
    "container_name": server_identifiers.bind_container(),
    "bind_image": platform_versions.BIND_IMAGE,
    "bind_service_name": "bind9",
}

# Class C: the wire's actual contract.
DNS_INTENT_DEFAULTS = {
    "zone_name": "example.com",
    "nameserver_hostname": "ns1",
    "nameserver_ipv4": None,
    "nameserver_ipv6": None,
    "default_a_ipv4": None,
    "default_aaaa_ipv6": None,
    "admin_email": "hostmaster.example.com",
    "zone_serial": 2026010101,
    "zone_ttl": 300,
    "zone_refresh": 3600,
    "zone_retry": 900,
    "zone_expire": 604800,
    "zone_negative_ttl": 300,
    "allow_recursion": False,
    "recursion_cidrs": ["127.0.0.1/32"],
    "forwarders": [],
    "listen_on_ipv6": False,
    "extra_records": [],
    "zones": [],
}

# T-1.4.3 splits the dictionary; T-1.4.4 is what actually stops
# RESOLVED_DNS_DEFAULTS keys from being wire-accepted. Until then this stays
# the full merge, byte-for-byte the same dictionary parse_dns_config saw
# before this split.
CANONICAL_DNS_SETTINGS = {**RESOLVED_DNS_DEFAULTS, **DNS_INTENT_DEFAULTS}

_REQUIRED_DNS_SETTING_KEYS = tuple(CANONICAL_DNS_SETTINGS.keys())
_ALLOWED_DNS_SETTING_KEYS = (*_REQUIRED_DNS_SETTING_KEYS, "extra_a_records")

_FQDN_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$"
)
_HOST_LABEL_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
_SOA_MAILBOX_LABEL_RE = re.compile(r"^[a-z0-9._-]+$")
_ZONE_ITEM_ALLOWED_KEYS = {
    "zone_name",
    "default_a_ipv4",
    "default_aaaa_ipv6",
    "admin_email",
    "zone_serial",
    "zone_ttl",
    "zone_refresh",
    "zone_retry",
    "zone_expire",
    "zone_negative_ttl",
    "extra_records",
    "extra_a_records",
}


class DnsConfigValidationError(ValueError):
    pass


# Bound once per module rather than passed at all 11 call sites below.
#
# These are not copies -- T-3.8.1 deleted those. Each is `config_validation`'s
# single implementation with this module's error class already supplied, which
# is the same "parameterise the original, bind the exception class" shape
# `settings_ownership.reject_server_owned_keys(raw, error_class)` established.
_required_string = functools.partial(
    config_validation.required_string,
    error_class=DnsConfigValidationError,
)
_required_bool = functools.partial(
    config_validation.required_bool,
    error_class=DnsConfigValidationError,
)


@dataclass(frozen=True)
class DnsRecord:
    name: str
    type: str
    value: str


@dataclass(frozen=True)
class DnsZone:
    zone_name: str
    default_a_ipv4: str | None
    default_aaaa_ipv6: str | None
    admin_email: str
    zone_serial: int
    zone_ttl: int
    zone_refresh: int
    zone_retry: int
    zone_expire: int
    zone_negative_ttl: int
    extra_records: list[DnsRecord]

    @property
    def zone_file_path(self) -> str:
        return f"/zones/db.{self.zone_name}"

    @property
    def extra_a_records(self) -> list[dict[str, str]]:
        return [
            {"name": record.name, "ip": record.value}
            for record in self.extra_records
            if record.type == "A"
        ]
