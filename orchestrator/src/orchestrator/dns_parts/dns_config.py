"""Parsing the DNS settings into the config the workflow runs on.

`parse_dns_config`, the zone and record structure it builds, and the
`DnsConfig` it returns. T-3.3.4 moved the canonical defaults and value types
into `dns_settings_schema.py` and the per-field intent validators into
`dns_config_fields.py`.

Everything callers import from this module still imports from this module.
"""

from dataclasses import dataclass

from .. import config_validation
from .dns_config_fields import (
    _optional_admin_email,
    _optional_ipv4,
    _optional_ipv6,
    _optional_positive_int,
    _required_admin_email,
    _required_cidr_list,
    _required_container_name,
    _required_extra_records,
    _required_host_label,
    _required_image_ref,
    _required_ip_list,
    _required_positive_int,
    _required_service_name,
    _required_zone_name,
    _resolve_connection_addresses,
)
from .dns_settings_schema import (
    _ALLOWED_DNS_SETTING_KEYS,
    _REQUIRED_DNS_SETTING_KEYS,
    _ZONE_ITEM_ALLOWED_KEYS,
    CANONICAL_DNS_SETTINGS,
    DNS_INTENT_DEFAULTS,
    RESOLVED_DNS_DEFAULTS,
    DnsConfigValidationError,
    DnsRecord,
    DnsZone,
    _required_bool,
    _required_string,
)

__all__ = [
    "CANONICAL_DNS_SETTINGS",
    "DNS_INTENT_DEFAULTS",
    "RESOLVED_DNS_DEFAULTS",
    "DnsConfig",
    "DnsConfigValidationError",
    "DnsRecord",
    "DnsZone",
    "parse_dns_config",
]


@dataclass(frozen=True)
class DnsConfig:
    stack_root: str
    container_name: str
    bind_image: str
    bind_service_name: str
    nameserver_hostname: str
    nameserver_ipv4: str | None
    nameserver_ipv6: str | None
    listen_on_ipv6: bool
    zones: list[DnsZone]

    @property
    def zone_name(self):
        return self.zones[0].zone_name

    @property
    def nameserver_fqdn(self):
        return f"{self.nameserver_hostname}.{self.zone_name}"

    @property
    def zone_file_path(self):
        return self.zones[0].zone_file_path

    @property
    def zone_names(self):
        return [zone.zone_name for zone in self.zones]

    @property
    def zone_count(self):
        return len(self.zones)


def parse_dns_config(raw_data, connection_ip=None):
    settings = config_validation.select_settings(
        raw_data,
        canonical=CANONICAL_DNS_SETTINGS,
        error_class=DnsConfigValidationError,
    )
    config_validation.validate_setting_keys(
        settings,
        allowed=_ALLOWED_DNS_SETTING_KEYS,
        required=_REQUIRED_DNS_SETTING_KEYS,
        error_class=DnsConfigValidationError,
    )

    stack_root = _required_string(settings["stack_root"], "settings.stack_root")
    container_name = _required_container_name(
        settings["container_name"],
        "settings.container_name",
    )
    bind_image = _required_image_ref(
        settings["bind_image"],
        "settings.bind_image",
    )
    bind_service_name = _required_service_name(
        settings["bind_service_name"],
        "settings.bind_service_name",
    )
    nameserver_hostname = _required_host_label(
        settings["nameserver_hostname"],
        "settings.nameserver_hostname",
    )

    fallback_ipv4, fallback_ipv6 = _resolve_connection_addresses(connection_ip)
    nameserver_ipv4 = _optional_ipv4(
        settings["nameserver_ipv4"],
        "settings.nameserver_ipv4",
    )
    if nameserver_ipv4 is None:
        nameserver_ipv4 = fallback_ipv4

    nameserver_ipv6 = _optional_ipv6(
        settings["nameserver_ipv6"],
        "settings.nameserver_ipv6",
    )
    if nameserver_ipv6 is None:
        nameserver_ipv6 = fallback_ipv6

    if nameserver_ipv4 is None and nameserver_ipv6 is None:
        raise DnsConfigValidationError(
            "At least one of settings.nameserver_ipv4 or "
            "settings.nameserver_ipv6 is required when connection.host is missing "
            "or cannot be resolved.",
        )

    allow_recursion = _required_bool(
        settings["allow_recursion"],
        "settings.allow_recursion",
    )
    if allow_recursion:
        raise DnsConfigValidationError(
            "Authoritative Bind9 workflow requires settings.allow_recursion=false.",
        )

    _required_cidr_list(
        settings["recursion_cidrs"],
        "settings.recursion_cidrs",
    )

    forwarders = _required_ip_list(
        settings["forwarders"],
        "settings.forwarders",
    )
    if forwarders:
        raise DnsConfigValidationError(
            "Authoritative Bind9 workflow does not allow settings.forwarders.",
        )

    listen_on_ipv6 = _required_bool(
        settings["listen_on_ipv6"],
        "settings.listen_on_ipv6",
    )

    legacy_zone = _parse_legacy_zone(
        settings,
        nameserver_ipv4=nameserver_ipv4,
        nameserver_ipv6=nameserver_ipv6,
    )
    configured_zones = _parse_zone_items(
        settings["zones"],
        "settings.zones",
        nameserver_ipv4=nameserver_ipv4,
        nameserver_ipv6=nameserver_ipv6,
        defaults=legacy_zone,
    )
    zones = configured_zones or [legacy_zone]

    _validate_unique_zone_names(zones)

    return DnsConfig(
        stack_root=stack_root,
        container_name=container_name,
        bind_image=bind_image,
        bind_service_name=bind_service_name,
        nameserver_hostname=nameserver_hostname,
        nameserver_ipv4=nameserver_ipv4,
        nameserver_ipv6=nameserver_ipv6,
        listen_on_ipv6=listen_on_ipv6,
        zones=zones,
    )


def _parse_legacy_zone(settings, *, nameserver_ipv4, nameserver_ipv6):
    zone_name = _required_zone_name(settings["zone_name"], "settings.zone_name")

    default_a_ipv4 = _optional_ipv4(
        settings["default_a_ipv4"],
        "settings.default_a_ipv4",
    )
    if default_a_ipv4 is None:
        default_a_ipv4 = nameserver_ipv4

    default_aaaa_ipv6 = _optional_ipv6(
        settings["default_aaaa_ipv6"],
        "settings.default_aaaa_ipv6",
    )
    if default_aaaa_ipv6 is None:
        default_aaaa_ipv6 = nameserver_ipv6

    admin_email = _required_admin_email(
        settings["admin_email"],
        "settings.admin_email",
    )
    zone_serial = _required_positive_int(
        settings["zone_serial"],
        "settings.zone_serial",
    )
    zone_ttl = _required_positive_int(settings["zone_ttl"], "settings.zone_ttl")
    zone_refresh = _required_positive_int(
        settings["zone_refresh"],
        "settings.zone_refresh",
    )
    zone_retry = _required_positive_int(settings["zone_retry"], "settings.zone_retry")
    zone_expire = _required_positive_int(
        settings["zone_expire"],
        "settings.zone_expire",
    )
    zone_negative_ttl = _required_positive_int(
        settings["zone_negative_ttl"],
        "settings.zone_negative_ttl",
    )
    extra_records = _required_extra_records(
        settings.get("extra_records"),
        settings.get("extra_a_records"),
        "settings.extra_records",
    )

    return DnsZone(
        zone_name=zone_name,
        default_a_ipv4=default_a_ipv4,
        default_aaaa_ipv6=default_aaaa_ipv6,
        admin_email=admin_email,
        zone_serial=zone_serial,
        zone_ttl=zone_ttl,
        zone_refresh=zone_refresh,
        zone_retry=zone_retry,
        zone_expire=zone_expire,
        zone_negative_ttl=zone_negative_ttl,
        extra_records=extra_records,
    )


def _parse_zone_items(value, field_name, *, nameserver_ipv4, nameserver_ipv6, defaults: DnsZone):
    if not isinstance(value, list):
        raise DnsConfigValidationError(
            f"{field_name} must be a list of zone configuration objects.",
        )

    parsed = []
    for index, item in enumerate(value):
        path = f"{field_name}[{index}]"
        if not isinstance(item, dict):
            raise DnsConfigValidationError(f"{path} must be an object.")

        unknown = sorted(set(item.keys()) - _ZONE_ITEM_ALLOWED_KEYS)
        if unknown:
            raise DnsConfigValidationError(
                f"{path} has unknown keys: {', '.join(unknown)}",
            )

        zone_name = _required_zone_name(item.get("zone_name"), f"{path}.zone_name")
        default_a_ipv4 = _optional_ipv4(
            item.get("default_a_ipv4"),
            f"{path}.default_a_ipv4",
        )
        if default_a_ipv4 is None:
            default_a_ipv4 = defaults.default_a_ipv4 or nameserver_ipv4

        default_aaaa_ipv6 = _optional_ipv6(
            item.get("default_aaaa_ipv6"),
            f"{path}.default_aaaa_ipv6",
        )
        if default_aaaa_ipv6 is None:
            default_aaaa_ipv6 = defaults.default_aaaa_ipv6 or nameserver_ipv6

        admin_email = _optional_admin_email(item.get("admin_email"), f"{path}.admin_email")
        if admin_email is None:
            admin_email = defaults.admin_email

        zone_serial = _optional_positive_int(item.get("zone_serial"), f"{path}.zone_serial")
        if zone_serial is None:
            zone_serial = defaults.zone_serial

        zone_ttl = _optional_positive_int(item.get("zone_ttl"), f"{path}.zone_ttl")
        if zone_ttl is None:
            zone_ttl = defaults.zone_ttl

        zone_refresh = _optional_positive_int(item.get("zone_refresh"), f"{path}.zone_refresh")
        if zone_refresh is None:
            zone_refresh = defaults.zone_refresh

        zone_retry = _optional_positive_int(item.get("zone_retry"), f"{path}.zone_retry")
        if zone_retry is None:
            zone_retry = defaults.zone_retry

        zone_expire = _optional_positive_int(item.get("zone_expire"), f"{path}.zone_expire")
        if zone_expire is None:
            zone_expire = defaults.zone_expire

        zone_negative_ttl = _optional_positive_int(
            item.get("zone_negative_ttl"),
            f"{path}.zone_negative_ttl",
        )
        if zone_negative_ttl is None:
            zone_negative_ttl = defaults.zone_negative_ttl

        extra_records = _required_extra_records(
            item.get("extra_records"),
            item.get("extra_a_records"),
            f"{path}.extra_records",
        )
        if not extra_records:
            extra_records = list(defaults.extra_records)

        parsed.append(
            DnsZone(
                zone_name=zone_name,
                default_a_ipv4=default_a_ipv4,
                default_aaaa_ipv6=default_aaaa_ipv6,
                admin_email=admin_email,
                zone_serial=zone_serial,
                zone_ttl=zone_ttl,
                zone_refresh=zone_refresh,
                zone_retry=zone_retry,
                zone_expire=zone_expire,
                zone_negative_ttl=zone_negative_ttl,
                extra_records=extra_records,
            )
        )

    return parsed


def _validate_unique_zone_names(zones):
    seen = set()
    duplicates = set()
    for zone in zones:
        if zone.zone_name in seen:
            duplicates.add(zone.zone_name)
        seen.add(zone.zone_name)
    if duplicates:
        raise DnsConfigValidationError(
            f"Duplicate zone_name values are not allowed: {', '.join(sorted(duplicates))}",
        )
