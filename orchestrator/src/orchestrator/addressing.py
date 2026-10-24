import ipaddress


def strip_address_brackets(candidate: str) -> str:
    # Why: single owner of the one-layer bracket strip. Callers keep their
    # own None/empty handling (contracts differ: "" vs None tails). Public
    # because http_config shares it; a private cross-module import is worse.
    # Dart mirror note: ui normalizeHostInput keeps "[]" as "[]" (non-empty
    # guard), so it stays the Dart-side owner -- sync-only, do not unify.
    if candidate.startswith("[") and candidate.endswith("]"):
        return candidate[1:-1].strip()
    return candidate


def parse_ip_literal(value: object) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    if value is None:
        return None
    candidate = str(value).strip()
    candidate = strip_address_brackets(candidate)
    if not candidate:
        return None
    try:
        return ipaddress.ip_address(candidate)
    except ValueError:
        return None


def is_ipv6_literal(value: object) -> bool:
    address = parse_ip_literal(value)
    return address is not None and address.version == 6


def format_host(value: object) -> str:
    candidate = "" if value is None else str(value).strip()
    candidate = strip_address_brackets(candidate)
    if not candidate:
        return candidate
    address = parse_ip_literal(candidate)
    if address is not None and address.version == 6:
        return f"[{address}]"
    return candidate


def format_url_host(value: object) -> str:
    # Pure delegate of format_host -- kept for the URL call-site name (B-33 verdict).
    return format_host(value)


def format_host_port(host: object, port: int | str | None) -> str:
    if port is None:
        return format_host(host)
    return f"{format_host(host)}:{int(port)}"


def normalize_host(value: object) -> str | None:
    candidate = "" if value is None else str(value).strip()
    candidate = strip_address_brackets(candidate)
    if not candidate:
        return None
    address = parse_ip_literal(candidate)
    if address is not None:
        return str(address)
    return candidate
