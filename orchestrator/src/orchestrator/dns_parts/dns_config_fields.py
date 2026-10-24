"""Validation for the DNS settings a caller sends: class C intent.

Split out of `dns_config.py` by T-3.3.4. Zone and record parsing stays with
`parse_dns_config`, because it is the structure the parser builds rather than
a per-field rule.
"""

import ipaddress
import re
import socket
from typing import Any

from .dns_settings_schema import (
    _FQDN_RE,
    _HOST_LABEL_RE,
    _SOA_MAILBOX_LABEL_RE,
    DnsConfigValidationError,
    DnsRecord,
    _required_string,
)


def _required_service_name(value: Any, field_name: str) -> str:
    service_name = _required_string(value, field_name)
    if not re.match(r"^[a-zA-Z0-9_.@-]+$", service_name):
        raise DnsConfigValidationError(
            f"{field_name} must be a valid systemd service unit base name.",
        )
    return service_name


def _required_container_name(value: Any, field_name: str) -> str:
    name = _required_string(value, field_name)
    if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", name):
        raise DnsConfigValidationError(
            f"{field_name} must be a valid Docker container name.",
        )
    return name


def _required_image_ref(value: Any, field_name: str) -> str:
    image_ref = _required_string(value, field_name)
    if ":" not in image_ref:
        raise DnsConfigValidationError(
            f"{field_name} must include a pinned tag (for example, :9.20).",
        )
    return image_ref


def _required_zone_name(value: Any, field_name: str) -> str:
    zone = _required_string(value, field_name).lower().rstrip(".")
    if not _FQDN_RE.match(zone):
        raise DnsConfigValidationError(f"{field_name} must be a valid DNS zone FQDN.")
    return zone


def _required_host_label(value: Any, field_name: str) -> str:
    label = _required_string(value, field_name).lower().strip(".")
    if not _HOST_LABEL_RE.match(label):
        raise DnsConfigValidationError(
            f"{field_name} must be a valid DNS host label (example: ns1).",
        )
    return label


def _optional_ip(value: Any, field_name: str, *, version: int) -> str | None:
    if value is None:
        return None

    ip_text = value.strip() if isinstance(value, str) else str(value).strip()

    if not ip_text:
        return None

    try:
        address = ipaddress.ip_address(ip_text)
    except ValueError as exc:
        raise DnsConfigValidationError(
            f"{field_name} must be a valid IPv{version}.",
        ) from exc

    if address.version != version:
        raise DnsConfigValidationError(
            f"{field_name} must be an IPv{version} address.",
        )
    return str(address)


def _optional_ipv4(value: Any, field_name: str) -> str | None:
    return _optional_ip(value, field_name, version=4)


def _optional_ipv6(value: Any, field_name: str) -> str | None:
    return _optional_ip(value, field_name, version=6)


def _resolve_connection_addresses(value: Any) -> tuple[str | None, str | None]:
    if value is None:
        return None, None

    candidate = str(value).strip()
    if not candidate:
        return None, None

    try:
        address = ipaddress.ip_address(candidate)
    except ValueError:
        try:
            addrinfo = socket.getaddrinfo(candidate, None, type=socket.SOCK_STREAM)
        except socket.gaierror:
            return None, None

        ipv4 = None
        ipv6 = None
        for family, _, _, _, sockaddr in addrinfo:
            if family == socket.AF_INET and ipv4 is None:
                ipv4 = str(ipaddress.ip_address(sockaddr[0]))
            if family == socket.AF_INET6 and ipv6 is None:
                ipv6 = str(ipaddress.ip_address(sockaddr[0]))
        return ipv4, ipv6

    if address.version == 4:
        return str(address), None
    return None, str(address)


def _required_positive_int(value: Any, field_name: str) -> int:
    if not isinstance(value, int) or value <= 0:
        raise DnsConfigValidationError(f"{field_name} must be a positive integer.")
    return value


def _optional_positive_int(value: Any, field_name: str) -> int | None:
    if value is None:
        return None
    return _required_positive_int(value, field_name)


def _required_cidr_list(value: Any, field_name: str) -> list[str]:
    if not isinstance(value, list):
        raise DnsConfigValidationError(f"{field_name} must be a list of CIDR values.")

    cidrs = []
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item.strip():
            raise DnsConfigValidationError(
                f"{field_name}[{index}] must be a non-empty CIDR string.",
            )
        candidate = item.strip()
        try:
            network = ipaddress.ip_network(candidate, strict=False)
        except ValueError as exc:
            raise DnsConfigValidationError(
                f"{field_name}[{index}] is not a valid CIDR.",
            ) from exc
        cidrs.append(str(network))
    return cidrs


def _required_ip_list(value: Any, field_name: str) -> list[str]:
    if not isinstance(value, list):
        raise DnsConfigValidationError(
            f"{field_name} must be a list of IP addresses.",
        )

    values = []
    for index, item in enumerate(value):
        if item is None or not str(item).strip():
            raise DnsConfigValidationError(
                f"{field_name}[{index}] must be a non-empty IP value.",
            )
        try:
            values.append(str(ipaddress.ip_address(str(item).strip())))
        except ValueError as exc:
            raise DnsConfigValidationError(
                f"{field_name}[{index}] must be a valid IP address.",
            ) from exc
    return values


def _required_admin_email(value: Any, field_name: str) -> str:
    candidate = _required_string(value, field_name).lower().rstrip(".")

    if "@" in candidate:
        local_part, domain_part = candidate.split("@", 1)
        if not local_part or not domain_part:
            raise DnsConfigValidationError(
                f"{field_name} must be a valid email or SOA mailbox name.",
            )
        if not _SOA_MAILBOX_LABEL_RE.match(local_part):
            raise DnsConfigValidationError(
                f"{field_name} local part contains invalid characters.",
            )
        if not _FQDN_RE.match(domain_part):
            raise DnsConfigValidationError(
                f"{field_name} domain must be a valid FQDN.",
            )
        return f"{local_part}.{domain_part}"

    if not _FQDN_RE.match(candidate):
        raise DnsConfigValidationError(
            f"{field_name} must be a valid SOA mailbox FQDN.",
        )
    return candidate


def _optional_admin_email(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    return _required_admin_email(value, field_name)


def _required_extra_records(
    value: Any,
    legacy_value: Any,
    field_name: str,
) -> list[DnsRecord]:
    if value == []:
        value = None
    if legacy_value == []:
        legacy_value = None

    records = []
    if value is not None:
        if not isinstance(value, list):
            raise DnsConfigValidationError(
                f"{field_name} must be a list of record objects.",
            )
        for index, item in enumerate(value):
            path = f"{field_name}[{index}]"
            if not isinstance(item, dict):
                raise DnsConfigValidationError(
                    f"{path} must be an object with name/type/value fields.",
                )

            unknown = sorted(set(item.keys()) - {"name", "type", "value"})
            if unknown:
                raise DnsConfigValidationError(
                    f"{path} has unknown keys: {', '.join(unknown)}",
                )

            record_name = _required_record_name(item.get("name"), f"{path}.name")
            record_type = _required_record_type(item.get("type"), f"{path}.type")
            record_value = _required_record_value(
                item.get("value"),
                record_type,
                f"{path}.value",
            )
            records.append(
                DnsRecord(
                    name=record_name,
                    type=record_type,
                    value=record_value,
                )
            )

    if legacy_value is not None:
        if not isinstance(legacy_value, list):
            raise DnsConfigValidationError(
                f"{field_name} legacy A records must be a list.",
            )
        for index, item in enumerate(legacy_value):
            path = f"{field_name}.legacy_a_records[{index}]"
            if not isinstance(item, dict):
                raise DnsConfigValidationError(
                    f"{path} must be an object with name/ip fields.",
                )

            unknown = sorted(set(item.keys()) - {"name", "ip"})
            if unknown:
                raise DnsConfigValidationError(
                    f"{path} has unknown keys: {', '.join(unknown)}",
                )

            record_name = _required_record_name(item.get("name"), f"{path}.name")
            # A distinct local from the `record_value` above: this branch reads
            # the superseded `ip` key, which may be absent, while that one
            # reads a `value` that may not. Same name, different nullability.
            legacy_ip = _optional_ipv4(item.get("ip"), f"{path}.ip")
            if legacy_ip is None:
                raise DnsConfigValidationError(
                    f"{path}.ip must be a valid IPv4 address.",
                )
            records.append(DnsRecord(name=record_name, type="A", value=legacy_ip))

    return records


def _required_record_type(value: Any, field_name: str) -> str:
    candidate = _required_string(value, field_name).upper()
    if candidate not in {"A", "AAAA"}:
        raise DnsConfigValidationError(
            f"{field_name} must be either A or AAAA.",
        )
    return candidate


def _required_record_value(value: Any, record_type: str, field_name: str) -> str:
    if record_type == "A":
        record_value = _optional_ipv4(value, field_name)
        if record_value is None:
            raise DnsConfigValidationError(
                f"{field_name} must be a valid IPv4 address.",
            )
        return record_value

    record_value = _optional_ipv6(value, field_name)
    if record_value is None:
        raise DnsConfigValidationError(
            f"{field_name} must be a valid IPv6 address.",
        )
    return record_value


def _required_record_name(value: Any, field_name: str) -> str:
    name = _required_string(value, field_name).lower().rstrip(".")
    if name == "@":
        return name
    if name == "*":
        return name

    if name.startswith("*."):
        suffix = name[2:]
        if not suffix:
            raise DnsConfigValidationError(
                f"{field_name} wildcard record must include a suffix name.",
            )
        _validate_record_labels(suffix, field_name)
        return name

    _validate_record_labels(name, field_name)
    return name


def _validate_record_labels(value: str, field_name: str) -> None:
    labels = value.split(".")
    if any(not label for label in labels):
        raise DnsConfigValidationError(
            f"{field_name} must not contain empty DNS labels.",
        )
    for label in labels:
        if not _HOST_LABEL_RE.match(label):
            raise DnsConfigValidationError(
                f"{field_name} has invalid DNS label: {label}",
            )
