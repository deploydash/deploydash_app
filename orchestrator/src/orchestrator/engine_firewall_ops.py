import ipaddress
import secrets
import shlex
from datetime import UTC, datetime, timedelta

from . import apt_runtime, firewall_status, firewall_ufw, server_identifiers, server_paths
from .engine_context import EngineCore
from .postgres_runtime_parts.tls_policy import postgres_tls_key_pair_check_shell
from .runtime_ops import run_shell_command as run_remote_shell_command
from .shell_output import as_int, parse_bool_token, parse_key_values

_FIREWALL_DIR = server_paths.FIREWALL_ROOT
_STAGE_FILE = f"{_FIREWALL_DIR}/staged_state.env"
_STAGE_LOCK_FILE = f"{_FIREWALL_DIR}/staged_state.lock"
_UNPROTECTED_MARKER_FILE = f"{_FIREWALL_DIR}/unprotected-after-ufw-replacement"
_IPV4_INPUT_CHAIN = "DEPLOYDASH-INPUT"
_IPV4_DOCKER_CHAIN = "DEPLOYDASH-DOCKER-USER"
_IPV6_INPUT_CHAIN = "DEPLOYDASH6-INPUT"
_IPV6_DOCKER_CHAIN = "DEPLOYDASH6-DOCKER-USER"
_DEFAULT_LOCKED_PORTS = (80, 443)
_HTTP3_PORT = 443
_RULES_V4_FILE = "/etc/iptables/rules.v4"
_RULES_V6_FILE = "/etc/iptables/rules.v6"
_FIREWALL_SPECS = (
    {
        "family": "ipv4",
        "label": "IPv4",
        "command": "iptables",
        "input_chain": _IPV4_INPUT_CHAIN,
        "docker_chain": _IPV4_DOCKER_CHAIN,
        "rules_file": _RULES_V4_FILE,
        "stage_key": "snapshot_v4",
    },
    {
        "family": "ipv6",
        "label": "IPv6",
        "command": "ip6tables",
        "input_chain": _IPV6_INPUT_CHAIN,
        "docker_chain": _IPV6_DOCKER_CHAIN,
        "rules_file": _RULES_V6_FILE,
        "stage_key": "snapshot_v6",
    },
)

# Fixed ICMP preamble, per RFC 4890 (cf. ufw's before6.rules). Connection
# tracking never matches neighbour discovery, router advertisements, or MLD --
# they are untracked -- so without these accepts a strict fallback DROP breaks
# IPv6 outright and silences ping-based uptime monitoring. Each entry is
# (short label, match fragment); numeric ICMPv6 types avoid the kernel's
# British/American spelling ambiguity. Independent of user rules by design:
# custom rules can neither add to nor remove from this list.
_IPV4_PREAMBLE_RULES = (
    ("echo-request", "-p icmp --icmp-type echo-request -m limit --limit 30/minute"),
)
_IPV6_PREAMBLE_RULES = (
    ("destination-unreachable", "-p icmpv6 --icmpv6-type 1"),
    ("packet-too-big", "-p icmpv6 --icmpv6-type 2"),
    ("time-exceeded", "-p icmpv6 --icmpv6-type 3"),
    ("parameter-problem", "-p icmpv6 --icmpv6-type 4"),
    ("router-solicitation", "-p icmpv6 --icmpv6-type 133 -m hl --hl-eq 255"),
    ("router-advertisement", "-p icmpv6 --icmpv6-type 134 -m hl --hl-eq 255"),
    ("neighbour-solicitation", "-p icmpv6 --icmpv6-type 135 -m hl --hl-eq 255"),
    ("neighbour-advertisement", "-p icmpv6 --icmpv6-type 136 -m hl --hl-eq 255"),
    ("mld-query", "-p icmpv6 --icmpv6-type 130 -s fe80::/10 -m hl --hl-eq 1"),
    ("mld-report", "-p icmpv6 --icmpv6-type 131 -s fe80::/10 -m hl --hl-eq 1"),
    ("mld-done", "-p icmpv6 --icmpv6-type 132 -s fe80::/10 -m hl --hl-eq 1"),
    ("mld-report-v2", "-p icmpv6 --icmpv6-type 143 -s fe80::/10 -m hl --hl-eq 1"),
    ("echo-request", "-p icmpv6 --icmpv6-type 128 -m limit --limit 30/minute"),
    ("dhcpv6-reply", "-p udp -s fe80::/10 --sport 547 --dport 546"),
)


class FirewallConfigValidationError(ValueError):
    pass


def _settings_payload(raw_data):
    if not isinstance(raw_data, dict):
        return {}
    settings = raw_data.get("settings")
    if isinstance(settings, dict):
        return settings
    return raw_data


def _normalize_protocol(value):
    candidate = "" if value is None else str(value).strip().lower()
    if candidate not in ("tcp", "udp"):
        raise FirewallConfigValidationError("Custom rule protocol must be tcp or udp.")
    return candidate


def _normalize_port(value, field_name):
    port = as_int(value, -1)
    if port < 1 or port > 65535:
        raise FirewallConfigValidationError(f"{field_name} must be between 1 and 65535.")
    return port


def _normalize_source_cidr(value, field_name="Custom rule source_cidr"):
    if value is None:
        return None, None
    candidate = str(value).strip()
    if not candidate:
        return None, None
    try:
        network = ipaddress.ip_network(candidate, strict=False)
    except ValueError as exc:
        raise FirewallConfigValidationError(
            f"{field_name} must be a valid IPv4 or IPv6 CIDR.",
        ) from exc
    family = "ipv4" if network.version == 4 else "ipv6"
    return str(network), family


def _normalize_postgres_source_cidrs(value):
    """Bound and canonicalize the client networks allowed to reach PostgreSQL."""
    if value is None:
        return []
    if not isinstance(value, list):
        raise FirewallConfigValidationError("postgres_source_cidrs must be a list.")
    if len(value) > 32:
        raise FirewallConfigValidationError(
            "postgres_source_cidrs must contain 32 entries or fewer.",
        )
    source_cidrs = []
    for item in value:
        source_cidr, _source_family = _normalize_source_cidr(
            item,
            "PostgreSQL source CIDR",
        )
        if source_cidr is None:
            raise FirewallConfigValidationError(
                "PostgreSQL source CIDR must not be blank.",
            )
        if source_cidr not in source_cidrs:
            source_cidrs.append(source_cidr)
    return source_cidrs


def _normalize_locked_ports(value):
    if not isinstance(value, list):
        return list(_DEFAULT_LOCKED_PORTS)
    ports = []
    for item in value:
        port = as_int(item, -1)
        if port < 1 or port > 65535:
            continue
        if port not in ports:
            ports.append(port)
    for required in _DEFAULT_LOCKED_PORTS:
        if required not in ports:
            ports.append(required)
    return sorted(ports)


def _normalize_custom_rules(raw_rules):
    if not isinstance(raw_rules, list):
        return []

    custom_rules = []
    for entry in raw_rules:
        if not isinstance(entry, dict):
            continue
        protocol = _normalize_protocol(entry.get("protocol"))
        start = _normalize_port(entry.get("port_start"), "Custom rule port_start")
        end = _normalize_port(entry.get("port_end", start), "Custom rule port_end")
        if end < start:
            raise FirewallConfigValidationError(
                "Custom rule port_end must be greater than or equal to port_start.",
            )
        source_cidr, source_family = _normalize_source_cidr(
            entry.get("source_cidr"),
        )
        enabled = parse_bool_token(entry.get("enabled"), True)
        rule_id = str(entry.get("id") or "").strip() or secrets.token_hex(8)
        description = str(entry.get("description") or "").strip() or None

        custom_rules.append(
            {
                "id": rule_id,
                "protocol": protocol,
                "port_start": start,
                "port_end": end,
                "source_cidr": source_cidr,
                "source_family": source_family,
                "description": description,
                "enabled": enabled,
            },
        )
    return custom_rules


def _parse_firewall_settings(raw_data):
    settings = _settings_payload(raw_data)
    rollback_timeout = as_int(settings.get("rollback_timeout_seconds"), 90)
    rollback_timeout = max(30, min(3600, rollback_timeout))

    config = {
        "strict_mode": parse_bool_token(settings.get("strict_mode"), True),
        "allow_postgres": parse_bool_token(settings.get("allow_postgres"), False),
        "postgres_source_cidrs": _normalize_postgres_source_cidrs(
            settings.get("postgres_source_cidrs"),
        ),
        "allow_dns": parse_bool_token(settings.get("allow_dns"), False),
        "allow_smtp": parse_bool_token(settings.get("allow_smtp"), False),
        "allow_mail_receive": parse_bool_token(settings.get("allow_mail_receive"), False),
        "rollback_timeout_seconds": rollback_timeout,
        "locked_ports": _normalize_locked_ports(settings.get("locked_ports")),
        "custom_rules": _normalize_custom_rules(settings.get("custom_rules")),
        "stage_token": str(settings.get("stage_token") or "").strip() or None,
    }
    return config


def _curated_rules(config):
    rules = []
    if config["allow_postgres"]:
        sources = config["postgres_source_cidrs"] or [None]
        for source in sources:
            source_cidr, source_family = _normalize_source_cidr(
                source,
                "PostgreSQL source CIDR",
            )
            rules.append(
                {
                    "protocol": "tcp",
                    "port_start": 5432,
                    "port_end": 5432,
                    "source_cidr": source_cidr,
                    "source_family": source_family,
                },
            )
    if config["allow_dns"]:
        rules.append({"protocol": "tcp", "port_start": 53, "port_end": 53, "source_cidr": None})
        rules.append({"protocol": "udp", "port_start": 53, "port_end": 53, "source_cidr": None})
    if config["allow_smtp"]:
        for port in (25, 465, 587):
            rules.append(
                {"protocol": "tcp", "port_start": port, "port_end": port, "source_cidr": None}
            )
    if config["allow_mail_receive"]:
        for port in (110, 995, 143, 993):
            rules.append(
                {"protocol": "tcp", "port_start": port, "port_end": port, "source_cidr": None}
            )
    return rules


def _effective_allow_rules(config):
    rules = []

    for port in config["locked_ports"]:
        rules.append(
            {
                "protocol": "tcp",
                "port_start": port,
                "port_end": port,
                "source_cidr": None,
                "source_family": None,
                "label": f"locked-{port}",
            },
        )

    # Caddy publishes and advertises HTTP/3 on UDP 443. Keep that transport
    # fixed with the web ports so strict mode cannot turn the advertised
    # endpoint into a browser timeout and fallback.
    rules.append(
        {
            "protocol": "udp",
            "port_start": _HTTP3_PORT,
            "port_end": _HTTP3_PORT,
            "source_cidr": None,
            "source_family": None,
            "label": "fixed-http3",
        },
    )

    for rule in _curated_rules(config):
        rules.append(
            {
                "protocol": rule["protocol"],
                "port_start": rule["port_start"],
                "port_end": rule["port_end"],
                "source_cidr": rule["source_cidr"],
                "source_family": rule.get("source_family"),
                "label": "curated",
            },
        )

    for rule in config["custom_rules"]:
        if not rule["enabled"]:
            continue
        rules.append(
            {
                "protocol": rule["protocol"],
                "port_start": rule["port_start"],
                "port_end": rule["port_end"],
                "source_cidr": rule["source_cidr"],
                "source_family": rule.get("source_family"),
                "label": f"custom:{rule['id']}",
            },
        )

    deduped = []
    seen = set()
    for rule in rules:
        families = (
            (rule["source_family"],)
            if rule.get("source_family") in ("ipv4", "ipv6")
            else ("ipv4", "ipv6")
        )
        for family in families:
            key = (
                family,
                rule["protocol"],
                rule["port_start"],
                rule["port_end"],
                rule["source_cidr"] or "",
            )
            if key in seen:
                continue
            seen.add(key)
            deduped.append({**rule, "family": family})
    return deduped


def _firewall_spec(family):
    for spec in _FIREWALL_SPECS:
        if spec["family"] == family:
            return spec
    raise ValueError(f"Unsupported firewall family: {family}")


def _run_step(ctx: EngineCore, host, emit, event_prefix, label, command, timeout=30):
    ctx.emit_event(emit, f"{event_prefix}_action_started", f"{label}: started")
    status, output = host.run_shell_command(
        command,
        _timeout=timeout,
        _sudo=True,
    )
    ctx.emit_shell_output_lines(emit, output)
    if not status:
        return False, ctx.command_error_details(output) or "remote command failed"
    ctx.emit_event(emit, f"{event_prefix}_action_completed", f"{label}: completed")
    return True, None


def _detect_external_interface(host):
    command = (
        "set -eu; "
        'IFACE="$(ip route get 1.1.1.1 2>/dev/null | '
        'awk \'{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}\')"; '
        'if [ -z "${IFACE}" ]; then '
        "IFACE=\"$(ip -4 route list default 2>/dev/null | awk 'NR==1 {print $5}')\"; "
        "fi; "
        "printf 'IFACE=%s\\n' \"${IFACE}\""
    )
    status, output = host.run_shell_command(command, _timeout=10, _sudo=True)
    if not status:
        return None
    values = parse_key_values(output)
    iface = values.get("IFACE")
    if iface is None or not iface.strip():
        return None
    return iface.strip()


def _detect_connection_source_address(host):
    """Return the client IP of this SSH session for the safe access default."""
    command = (
        "set -eu; "
        'SOURCE_ADDRESS="${SSH_CONNECTION%% *}"; '
        "printf 'SOURCE_ADDRESS=%s\\n' \"${SOURCE_ADDRESS}\""
    )
    result = run_remote_shell_command(
        host,
        command,
        timeout=10,
        sudo=False,
    )
    if not result["ok"]:
        return None
    candidate = (parse_key_values(result["output"]).get("SOURCE_ADDRESS") or "").strip()
    try:
        return str(ipaddress.ip_address(candidate))
    except ValueError:
        return None


def _read_stage_state(host):
    command = (
        "set -eu; "
        f"STAGE_FILE={shlex.quote(_STAGE_FILE)}; "
        'if [ ! -f "${STAGE_FILE}" ]; then '
        'printf "PENDING=0\\n"; '
        "exit 0; "
        "fi; "
        '. "${STAGE_FILE}"; '
        'printf "PENDING=1\\nTOKEN=%s\\nEXPIRES_AT=%s\\nSNAPSHOT_V4=%s\\nSNAPSHOT_V6=%s\\nALLOW_POSTGRES=%s\\nPOSTGRES_SOURCE_CIDRS=%s\\nUFW_ACTIVE_BEFORE=%s\\n" '
        '"${TOKEN:-}" "${EXPIRES_AT:-}" '
        '"${SNAPSHOT_V4:-${SNAPSHOT:-}}" "${SNAPSHOT_V6:-}" '
        '"${ALLOW_POSTGRES:-}" "${POSTGRES_SOURCE_CIDRS:-}" '
        '"${UFW_ACTIVE_BEFORE:-0}"'
    )
    status, output = host.run_shell_command(command, _timeout=10, _sudo=True)
    if not status:
        return {"pending": False, "token": None, "expires_at": None, "snapshot": None}

    values = parse_key_values(output)
    pending = values.get("PENDING") == "1"
    token = values.get("TOKEN") or None
    expires_at = values.get("EXPIRES_AT") or None
    snapshot_v4 = values.get("SNAPSHOT_V4") or values.get("SNAPSHOT") or None
    snapshot_v6 = values.get("SNAPSHOT_V6") or None
    allow_postgres = values.get("ALLOW_POSTGRES") == "1"
    postgres_source_cidrs = [
        item for item in (values.get("POSTGRES_SOURCE_CIDRS") or "").split(",") if item
    ]
    return {
        "pending": pending,
        "token": token,
        "expires_at": expires_at,
        "snapshot_v4": snapshot_v4,
        "snapshot_v6": snapshot_v6,
        "allow_postgres": allow_postgres,
        "postgres_source_cidrs": postgres_source_cidrs,
        "ufw_active_before": values.get("UFW_ACTIVE_BEFORE") == "1",
    }


def _restore_snapshot(ctx: EngineCore, host, spec, snapshot_path):
    if snapshot_path is None:
        return False, "missing snapshot path"
    command = (
        "set -eu; "
        f"SNAPSHOT={shlex.quote(snapshot_path)}; "
        'if [ ! -f "${SNAPSHOT}" ]; then '
        'echo "snapshot file missing" >&2; '
        "exit 1; "
        "fi; "
        'sh -eu "${SNAPSHOT}"'
    )
    status, output = host.run_shell_command(command, _timeout=30, _sudo=True)
    if not status:
        return False, ctx.command_error_details(output) or "snapshot restore failed"
    return True, None


def _restore_snapshots(ctx: EngineCore, host, staged_state):
    failures = []
    for spec in _FIREWALL_SPECS:
        snapshot_path = staged_state.get(spec["stage_key"])
        if snapshot_path is None:
            continue
        restored, details = _restore_snapshot(ctx, host, spec, snapshot_path)
        if not restored:
            failures.append(f"{spec['label']}: {details or 'snapshot restore failed'}")
    if failures:
        return False, "; ".join(failures)
    return True, None


def _firewall_stage_error(
    ctx,
    host,
    code,
    message,
    *,
    stage,
    details,
    ufw_active_before,
    replacement_started,
):
    """Make loss of pre-stage UFW protection explicit on every failure path."""
    if ufw_active_before and replacement_started:
        _mark_firewall_unprotected(host)
        message = (
            f"{message} Deploy Dash replaced active ufw, so this server currently "
            "has no active firewall. Retry the firewall setup immediately."
        )
    result = ctx.error_result(code, message, stage=stage, details=details)
    if ufw_active_before and replacement_started:
        result["firewall_state"] = "unprotected"
    return result


def _mark_firewall_unprotected(host):
    """Persist the warning across the dead-man timer and later UI refreshes."""
    run_remote_shell_command(
        host,
        (f"mkdir -p {shlex.quote(_FIREWALL_DIR)}; touch {shlex.quote(_UNPROTECTED_MARKER_FILE)}"),
        timeout=10,
        sudo=True,
    )


def _has_unprotected_marker(host):
    """Read the durable warning without treating a failed probe as protection loss."""
    command = (
        f"UNPROTECTED_MARKER={shlex.quote(_UNPROTECTED_MARKER_FILE)}; "
        'if [ -f "${UNPROTECTED_MARKER}" ]; then '
        'printf "FIREWALL_UNPROTECTED=1\\n"; '
        'else printf "FIREWALL_UNPROTECTED=0\\n"; fi'
    )
    result = run_remote_shell_command(host, command, timeout=10, sudo=True)
    return bool(
        result["ok"] and parse_key_values(result["output"]).get("FIREWALL_UNPROTECTED") == "1"
    )


def _build_port_match(rule):
    if rule["port_start"] == rule["port_end"]:
        return f"--dport {rule['port_start']}"
    return f"--dport {rule['port_start']}:{rule['port_end']}"


def _build_transport_allow_match(rule):
    """Render the shared transport/source match so live rules and checks agree."""
    match = f"-p {rule['protocol']} -m {rule['protocol']} {_build_port_match(rule)}"
    if rule.get("source_cidr"):
        match += f" -s {shlex.quote(rule['source_cidr'])}"
    return match


def _build_input_allow_command(rule):
    spec = _firewall_spec(rule["family"])
    return (
        f"{spec['command']} -w -A {spec['input_chain']} "
        f"{_build_transport_allow_match(rule)} -j ACCEPT"
    )


def _build_docker_allow_command(rule):
    spec = _firewall_spec(rule["family"])
    return (
        f"{spec['command']} -w -A {spec['docker_chain']} "
        f"{_build_transport_allow_match(rule)} -j RETURN"
    )


def _firewall_status_payload(host):
    payload = firewall_status.firewall_status_payload(
        host,
        firewall_specs=_FIREWALL_SPECS,
        rules_v4_file=_RULES_V4_FILE,
        rules_v6_file=_RULES_V6_FILE,
        read_stage_state=_read_stage_state,
        detect_external_interface=_detect_external_interface,
        detect_connection_source_address=_detect_connection_source_address,
        required_input_checks=_preamble_check_commands,
    )
    if _has_unprotected_marker(host):
        payload["firewall_state"] = "unprotected"
    return payload


def _parse_ss_local_endpoint(raw_value):
    value = raw_value.strip()
    if not value:
        return None, None
    if value.startswith("["):
        bracket_end = value.rfind("]")
        if bracket_end != -1 and bracket_end + 2 <= len(value):
            host = value[1:bracket_end]
            port = value[bracket_end + 2 :]
            return host, port
    if ":" not in value:
        return value, None
    host, _, port = value.rpartition(":")
    if host == "":
        host = "*"
    return host, port


def _scan_open_ports(host):
    host_ports = []
    docker_ports = []

    ss_command = "ss -H -lntup 2>/dev/null || ss -H -lntu 2>/dev/null"
    ss_status, ss_output = host.run_shell_command(ss_command, _timeout=15, _sudo=True)
    if ss_status and ss_output is not None:
        for line in ss_output.stdout_lines or []:
            if not isinstance(line, str):
                continue
            parts = line.split()
            if len(parts) < 5:
                continue
            protocol = parts[0].strip().lower()
            if protocol not in ("tcp", "udp"):
                continue
            local = parts[4]
            bind_address, port = _parse_ss_local_endpoint(local)
            if port is None:
                continue
            details = "-"
            if len(parts) >= 7:
                details = " ".join(parts[6:]).strip() or "-"
            host_ports.append(
                {
                    "source": "host_listener",
                    "protocol": protocol,
                    "port": port,
                    "bind": bind_address or "-",
                    "details": details,
                },
            )

    docker_command = "docker ps --format '{{.Names}}\t{{.Ports}}'"
    docker_status, docker_output = host.run_shell_command(
        docker_command,
        _timeout=15,
        _sudo=True,
    )
    if docker_status and docker_output is not None:
        for line in docker_output.stdout_lines or []:
            if not isinstance(line, str) or "\t" not in line:
                continue
            container_name, ports_blob = line.split("\t", 1)
            for segment in ports_blob.split(","):
                mapping = segment.strip()
                if "->" not in mapping:
                    continue
                left, right = mapping.split("->", 1)
                right = right.strip()
                protocol = right.rsplit("/", 1)[-1].lower()
                if protocol not in ("tcp", "udp"):
                    continue

                bind_address, host_port = _parse_ss_local_endpoint(left.strip())
                if host_port is None:
                    continue

                docker_ports.append(
                    {
                        "source": "docker_published",
                        "protocol": protocol,
                        "port": host_port,
                        "bind": bind_address or "-",
                        "details": f"{container_name.strip()} ({mapping})",
                    },
                )

    deduped = []
    seen = set()
    for item in host_ports + docker_ports:
        key = (
            item["source"],
            item["protocol"],
            item["port"],
            item["bind"],
            item["details"],
        )
        if key in seen:
            continue
        seen.add(key)
        deduped.append(item)

    deduped.sort(
        key=lambda item: (
            int(item["port"]) if str(item["port"]).isdigit() else 0,
            item["protocol"],
            item["source"],
            item["bind"],
        ),
    )
    return deduped


def _allow_check_commands(rules, *, docker):
    """Verify every effective allow at the exact host or Docker boundary.

    Replaying the complete rule with `-C` proves protocol as well as port;
    this matters for HTTP/3 because the TCP 443 allow cannot stand in for
    the required UDP 443 rule.
    """

    checks = []
    for rule in rules:
        spec = _firewall_spec(rule["family"])
        family_label = spec["label"]
        chain = spec["docker_chain"] if docker else spec["input_chain"]
        verdict = "RETURN" if docker else "ACCEPT"
        boundary = "Docker ingress" if docker else "host"
        if rule["port_start"] == rule["port_end"]:
            port_text = f"{rule['protocol']}:{rule['port_start']}"
        else:
            port_text = f"{rule['protocol']}:{rule['port_start']}-{rule['port_end']}"
        checks.append(
            (
                f"Validate {family_label} {boundary} {port_text}",
                f"{spec['command']} -w -C {chain} "
                f"{_build_transport_allow_match(rule)} -j {verdict}",
                10,
            ),
        )
    return checks


def _docker_policy_check_commands(strict_mode):
    """Verify trusted bridge bypasses and the interface-independent fallback."""
    checks = []
    for spec in _FIREWALL_SPECS:
        for interface in server_identifiers.DOCKER_BRIDGE_INTERFACE_PATTERNS:
            checks.append(
                (
                    f"Validate {spec['label']} Docker bridge {interface} bypass",
                    f"{spec['command']} -w -C {spec['docker_chain']} -i "
                    f"{shlex.quote(interface)} -j RETURN",
                    10,
                ),
            )
        fallback = "DROP" if strict_mode else "RETURN"
        checks.append(
            (
                f"Validate {spec['label']} Docker ingress fallback {fallback.lower()}",
                f"{spec['command']} -w -C {spec['docker_chain']} -j {fallback}",
                10,
            ),
        )
    return checks


def _preamble_allow_steps(spec):
    """Fixed ICMP preamble accepts for one address family.

    The preamble is what makes a strict fallback DROP safe to commit: these
    packets can never match conntrack, so they need explicit accepts ahead of
    every user rule and the DROP. One owner for both families keeps the chain
    shape identical wherever the stage runs.
    """
    family_rules = _IPV6_PREAMBLE_RULES if spec["family"] == "ipv6" else _IPV4_PREAMBLE_RULES
    return [
        (
            f"Allow {spec['label']} {label} preamble traffic",
            f"{spec['command']} -w -A {spec['input_chain']} {match} -j ACCEPT",
            10,
        )
        for label, match in family_rules
    ]


def _preamble_check_commands(selected_family=None):
    """Verify the fixed ICMP preamble in both or one managed INPUT family.

    Mirrors the Docker-ingress checks: a stage that lost its preamble (or
    never applied it) must fail validation and roll back rather than commit
    a chain whose fallback DROP would break IPv6 or echo. Each check replays
    the staged rule through `-C`, which compares parsed rules instead of
    `-S` text: `-S` normalizes `-p icmpv6` to `-p ipv6-icmp` and
    `--icmp-type echo-request` to `--icmp-type 8`, so grepping for the
    staged text would fail on a correct chain.
    """
    checks = []
    for family, rules in (
        ("ipv4", _IPV4_PREAMBLE_RULES),
        ("ipv6", _IPV6_PREAMBLE_RULES),
    ):
        if selected_family is not None and selected_family != family:
            continue
        spec = _firewall_spec(family)
        for label, match in rules:
            checks.append(
                (
                    f"Validate {spec['label']} {label} preamble",
                    f"{spec['command']} -w -C {spec['input_chain']} {match} -j ACCEPT",
                    10,
                ),
            )
    return checks


def _firewall_stage_snapshot_paths(stage_token):
    """Derive both managed-state restore scripts from one server-owned token."""
    return {
        "snapshot_v4": f"{_FIREWALL_DIR}/snapshot-{stage_token}.restore.v4.sh",
        "snapshot_v6": f"{_FIREWALL_DIR}/snapshot-{stage_token}.restore.v6.sh",
    }


def _managed_firewall_snapshot_command(spec, snapshot_path):
    """Capture only managed chains and jump ownership in a restore script.

    Docker, fail2ban, and operators own every other rule. A rollback script
    therefore removes and reconstructs only Deploy Dash's two chains and the
    two parent-chain jumps instead of replacing a whole iptables table.
    """
    command = spec["command"]
    input_chain = spec["input_chain"]
    docker_chain = spec["docker_chain"]
    snapshot = shlex.quote(snapshot_path)
    restore_header = (
        "set -eu",
        (
            f"while {command} -w -C INPUT -j {input_chain} 2>/dev/null; do "
            f"{command} -w -D INPUT -j {input_chain}; done"
        ),
        (
            f"while {command} -w -C DOCKER-USER -j {docker_chain} 2>/dev/null; do "
            f"{command} -w -D DOCKER-USER -j {docker_chain}; done"
        ),
    )
    write_header = " ".join(
        f"printf '%s\\n' {shlex.quote(line)} >> {snapshot};" for line in restore_header
    )
    chain_snapshots = []
    for chain in (input_chain, docker_chain):
        existing_lines = (
            f"printf '%s\\n' {shlex.quote(f'{command} -w -N {chain} 2>/dev/null || true')} "
            f">> {snapshot}; "
            f"printf '%s\\n' {shlex.quote(f'{command} -w -F {chain}')} >> {snapshot}; "
            f"{command} -w -S {chain} | sed -n '/^-A /p' | "
            f"sed {shlex.quote(f's/^/{command} -w /')} >> {snapshot}"
        )
        absent_lines = (
            f"printf '%s\\n' "
            f"{shlex.quote(f'{command} -w -F {chain} 2>/dev/null || true')} "
            f">> {snapshot}; "
            f"printf '%s\\n' "
            f"{shlex.quote(f'{command} -w -X {chain} 2>/dev/null || true')} "
            f">> {snapshot}"
        )
        chain_snapshots.append(
            f"if {command} -w -S {chain} >/dev/null 2>&1; then "
            f"{existing_lines}; else {absent_lines}; fi;"
        )
    jump_snapshots = " ".join(
        (
            f"if {command} -w -C {parent} -j {chain} 2>/dev/null; then "
            f"printf '%s\\n' "
            f"{shlex.quote(f'{command} -w -I {parent} 1 -j {chain}')} "
            f">> {snapshot}; fi;"
        )
        for parent, chain in (("INPUT", input_chain), ("DOCKER-USER", docker_chain))
    )
    return (
        f"set -eu; umask 077; : > {snapshot}; {write_header} "
        f"{' '.join(chain_snapshots)} {jump_snapshots} chmod 600 {snapshot}"
    )


def _postgres_tls_policy_check_command():
    """Prove PostgreSQL rejects plaintext before port 5432 can be exposed."""
    certificate = shlex.quote(server_paths.postgres_tls_certificate())
    private_key = shlex.quote(server_paths.postgres_tls_private_key())
    hba_file = shlex.quote(server_paths.postgres_hba_file())
    compose_file = shlex.quote(f"{server_paths.postgres_root()}/docker-compose.yml")
    key_pair_check = postgres_tls_key_pair_check_shell(certificate, private_key)
    return (
        "set -eu; "
        f"test -s {certificate}; "
        f"test -s {private_key}; "
        f"test -s {hba_file}; "
        f"test -s {compose_file}; "
        f"test \"$(stat -c '%a' {private_key})\" = 600; "
        f"openssl x509 -in {certificate} -noout -checkend 0 >/dev/null; "
        f"openssl pkey -in {private_key} -noout >/dev/null; "
        f"{key_pair_check}"
        f"grep -Fqx 'hostssl all all 0.0.0.0/0 scram-sha-256' {hba_file}; "
        f"grep -Fqx 'hostssl all all ::/0 scram-sha-256' {hba_file}; "
        f"grep -Fqx 'hostnossl all all 0.0.0.0/0 reject' {hba_file}; "
        f"grep -Fqx 'hostnossl all all ::/0 reject' {hba_file}; "
        f"grep -Fq -- '- ssl=on' {compose_file}; "
        f"grep -Fq -- '- hba_file=/run/deploydash-postgres-tls/pg_hba.conf' {compose_file}"
    )


def _persist_firewall_stage(
    ctx,
    host,
    *,
    stage_token,
    staged_state,
    rollback_timeout_seconds,
    allow_postgres,
    postgres_source_cidrs,
    ufw_active_before=False,
    emit=None,
):
    """Persist one timed rollback owner after live rules have been staged."""
    expires_at = datetime.now(UTC) + timedelta(seconds=rollback_timeout_seconds)
    write_state_command = (
        "set -eu; "
        f"STAGE_FILE={shlex.quote(_STAGE_FILE)}; "
        f"UNPROTECTED_MARKER={shlex.quote(_UNPROTECTED_MARKER_FILE)}; "
        'cat > "${STAGE_FILE}" <<EOF\n'
        f"TOKEN={stage_token}\n"
        f"SNAPSHOT_V4={staged_state['snapshot_v4']}\n"
        f"SNAPSHOT_V6={staged_state['snapshot_v6']}\n"
        f"EXPIRES_AT={expires_at.isoformat()}\n"
        f"ALLOW_POSTGRES={1 if allow_postgres else 0}\n"
        f"POSTGRES_SOURCE_CIDRS={shlex.quote(','.join(postgres_source_cidrs))}\n"
        f"UFW_ACTIVE_BEFORE={1 if ufw_active_before else 0}\n"
        "EOF\n"
        'chmod 600 "${STAGE_FILE}"; '
        'rm -f "${UNPROTECTED_MARKER}"'
    )
    status, details = _run_step(
        ctx,
        host,
        emit,
        "firewall_runtime",
        "Persist staged firewall state",
        write_state_command,
        timeout=10,
    )
    if not status:
        _restore_snapshots(ctx, host, staged_state)
        return _firewall_stage_error(
            ctx,
            host,
            "ENGINE_RUNTIME_ERROR",
            "Persist staged firewall state failed.",
            stage="execute_runtime_operation",
            details=details,
            ufw_active_before=ufw_active_before,
            replacement_started=True,
        )

    schedule_rollback_command = (
        "set -eu; "
        f"STAGE_FILE={shlex.quote(_STAGE_FILE)}; "
        f"LOCK_FILE={shlex.quote(_STAGE_LOCK_FILE)}; "
        f"UNPROTECTED_MARKER={shlex.quote(_UNPROTECTED_MARKER_FILE)}; "
        f"EXPECTED_TOKEN={shlex.quote(stage_token)}; "
        f"SLEEP_SECONDS={rollback_timeout_seconds}; "
        'ROLLBACK_SCRIPT="$(mktemp)"; '
        "cat > \"${ROLLBACK_SCRIPT}\" <<'EOS'\n"
        'sleep "${SLEEP_SECONDS}"\n'
        'flock -x "${LOCK_FILE}" sh -eu -c \'\n'
        'if [ -f "${STAGE_FILE}" ]; then\n'
        '. "${STAGE_FILE}"\n'
        'if [ "${TOKEN:-}" = "${EXPECTED_TOKEN}" ]; then\n'
        'if [ -n "${SNAPSHOT_V4:-${SNAPSHOT:-}}" ] && '
        '[ -f "${SNAPSHOT_V4:-${SNAPSHOT:-}}" ]; then\n'
        'sh -eu "${SNAPSHOT_V4:-${SNAPSHOT:-}}" || true\n'
        "fi\n"
        'if [ -n "${SNAPSHOT_V6:-}" ] && [ -f "${SNAPSHOT_V6}" ]; then\n'
        'sh -eu "${SNAPSHOT_V6}" || true\n'
        "fi\n"
        'if [ "${UFW_ACTIVE_BEFORE:-0}" = 1 ]; then\n'
        'touch "${UNPROTECTED_MARKER}"\n'
        "fi\n"
        "fi\n"
        'if [ "${TOKEN:-}" = "${EXPECTED_TOKEN}" ]; then rm -f "${STAGE_FILE}"; fi\n'
        "fi\n"
        "'\n"
        'rm -f "${ROLLBACK_SCRIPT}"\n'
        "EOS\n"
        'chmod 700 "${ROLLBACK_SCRIPT}"; '
        "nohup env "
        'STAGE_FILE="${STAGE_FILE}" '
        'LOCK_FILE="${LOCK_FILE}" '
        'UNPROTECTED_MARKER="${UNPROTECTED_MARKER}" '
        'EXPECTED_TOKEN="${EXPECTED_TOKEN}" '
        'SLEEP_SECONDS="${SLEEP_SECONDS}" '
        'ROLLBACK_SCRIPT="${ROLLBACK_SCRIPT}" '
        'sh "${ROLLBACK_SCRIPT}" >/dev/null 2>&1 &'
    )
    status, details = _run_step(
        ctx,
        host,
        emit,
        "firewall_runtime",
        "Schedule rollback safety timer",
        schedule_rollback_command,
        timeout=10,
    )
    if not status:
        _restore_snapshots(ctx, host, staged_state)
        return _firewall_stage_error(
            ctx,
            host,
            "ENGINE_RUNTIME_ERROR",
            "Schedule rollback safety timer failed.",
            stage="execute_runtime_operation",
            details=details,
            ufw_active_before=ufw_active_before,
            replacement_started=True,
        )
    return {
        "status": "success",
        "stage_token": stage_token,
        "expires_at": expires_at.isoformat(),
    }


def _stage_ssh_port_firewall(ctx, host, current_port, target_port, emit=None):
    """Temporarily allow both SSH ports without rebuilding unrelated rules."""
    staged_state = _read_stage_state(host)
    if staged_state["pending"]:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "A staged firewall change is already pending. Commit or rollback first.",
            stage="validate_request",
        )

    managed_families = []
    for spec in _FIREWALL_SPECS:
        result = run_remote_shell_command(
            host,
            f"{spec['command']} -w -C INPUT -j {spec['input_chain']}",
            timeout=10,
            emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
        )
        managed_families.append(result["ok"])
    if not any(managed_families):
        return {"status": "success", "managed": False, "stage_token": None}
    if not all(managed_families):
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Managed firewall is only active for one address family; refusing an SSH port change.",
            stage="prepare_runtime_operation",
        )
    stage_token = f"ssh-port-{secrets.token_hex(8)}"
    staged_state = _firewall_stage_snapshot_paths(stage_token)
    steps = [
        (
            "Prepare firewall workspace for SSH port transition",
            f"mkdir -p {shlex.quote(_FIREWALL_DIR)}",
            15,
        ),
        (
            "Snapshot managed firewall state before SSH port transition",
            f"{_managed_firewall_snapshot_command(_FIREWALL_SPECS[0], staged_state['snapshot_v4'])}; "
            f"{_managed_firewall_snapshot_command(_FIREWALL_SPECS[1], staged_state['snapshot_v6'])}",
            20,
        ),
    ]
    for spec in _FIREWALL_SPECS:
        allow = f"-p tcp -m tcp --dport {int(target_port)} -j ACCEPT"
        docker_allow = f"-p tcp -m tcp --dport {int(target_port)} -j RETURN"
        steps.append(
            (
                f"Temporarily allow new SSH port {target_port} for {spec['label']}",
                f"{spec['command']} -w -C {spec['input_chain']} {allow} 2>/dev/null || "
                f"{spec['command']} -w -I {spec['input_chain']} 1 {allow}",
                10,
            ),
        )
        steps.append(
            (
                f"Temporarily allow new SSH port {target_port} for {spec['label']} Docker ingress",
                f"{spec['command']} -w -C {spec['docker_chain']} {docker_allow} "
                f"2>/dev/null || {spec['command']} -w -I {spec['docker_chain']} 1 "
                f"{docker_allow}",
                10,
            ),
        )

    for index, (label, command, timeout) in enumerate(steps):
        status, details = _run_step(
            ctx,
            host,
            emit,
            "ssh_port_firewall",
            label,
            command,
            timeout=timeout,
        )
        if not status:
            if index > 1:
                _restore_snapshots(ctx, host, staged_state)
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                f"{label} failed.",
                stage="execute_runtime_operation",
                details=details,
            )

    persisted = _persist_firewall_stage(
        ctx,
        host,
        stage_token=stage_token,
        staged_state=staged_state,
        rollback_timeout_seconds=180,
        allow_postgres=False,
        postgres_source_cidrs=[],
        emit=emit,
    )
    if persisted["status"] != "success":
        return persisted
    return {
        "status": "success",
        "managed": True,
        "stage_token": stage_token,
        "current_port": int(current_port),
        "target_port": int(target_port),
    }


def _commit_ssh_port_firewall(
    ctx,
    host,
    *,
    stage_token,
    current_port,
    target_port,
    emit=None,
):
    """Close the old SSH allow only after the new login has been verified."""
    if not stage_token:
        return {"status": "success", "managed": False}
    staged_state = _read_stage_state(host)
    if not staged_state["pending"] or staged_state["token"] != stage_token:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "The SSH port firewall stage vanished before it could be committed.",
            stage="execute_runtime_operation",
        )
    steps = []
    if int(current_port) not in _DEFAULT_LOCKED_PORTS:
        for spec in _FIREWALL_SPECS:
            old_allow = f"-p tcp -m tcp --dport {int(current_port)} -j ACCEPT"
            old_docker_allow = f"-p tcp -m tcp --dport {int(current_port)} -j RETURN"
            steps.append(
                (
                    f"Remove old SSH port {current_port} for {spec['label']}",
                    f"while {spec['command']} -w -C {spec['input_chain']} {old_allow} "
                    f"2>/dev/null; do {spec['command']} -w -D {spec['input_chain']} "
                    f"{old_allow}; done",
                    10,
                ),
            )
            steps.append(
                (
                    f"Remove old SSH port {current_port} for {spec['label']} Docker ingress",
                    f"while {spec['command']} -w -C {spec['docker_chain']} "
                    f"{old_docker_allow} 2>/dev/null; do {spec['command']} -w -D "
                    f"{spec['docker_chain']} {old_docker_allow}; done",
                    10,
                ),
            )
    for spec in _FIREWALL_SPECS:
        target_docker_allow = f"-p tcp -m tcp --dport {int(target_port)} -j RETURN"
        steps.append(
            (
                f"Verify new SSH port {target_port} for {spec['label']}",
                f"{spec['command']} -w -C {spec['input_chain']} -p tcp -m tcp "
                f"--dport {int(target_port)} -j ACCEPT",
                10,
            ),
        )
        steps.append(
            (
                f"Verify new SSH port {target_port} for {spec['label']} Docker ingress",
                f"{spec['command']} -w -C {spec['docker_chain']} {target_docker_allow}",
                10,
            ),
        )

    for label, command, timeout in steps:
        status, details = _run_step(
            ctx,
            host,
            emit,
            "ssh_port_firewall",
            label,
            command,
            timeout=timeout,
        )
        if not status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                f"{label} failed.",
                stage="execute_runtime_operation",
                details=details,
            )
    return _commit_staged_firewall(ctx, host, stage_token, emit=emit)


def _apply_staged_firewall(ctx, host, config, emit=None, active_ssh_port=None):
    if active_ssh_port is not None and int(active_ssh_port) not in config["locked_ports"]:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Firewall locked ports must include active SSH port {int(active_ssh_port)}.",
            stage="validate_request",
        )
    staged_state = _read_stage_state(host)
    if staged_state["pending"]:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "A staged firewall change is already pending. Commit or rollback first.",
            stage="validate_request",
        )

    if config["allow_postgres"]:
        status, details = _run_step(
            ctx,
            host,
            emit,
            "firewall_runtime",
            "Verify PostgreSQL TLS policy",
            _postgres_tls_policy_check_command(),
            timeout=15,
        )
        if not status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "PostgreSQL TLS policy could not be verified; remote access was not opened.",
                stage="prepare_runtime_operation",
                details=details,
            )

    ufw_state, _ufw_probe_error = firewall_ufw.probe_ufw(host)
    ufw_active_before = bool(ufw_state and ufw_state["active"])

    stage_token = f"fw-{secrets.token_hex(8)}"
    staged_state = _firewall_stage_snapshot_paths(stage_token)

    initial_steps = [
        (
            "Prepare firewall workspace",
            f"mkdir -p {shlex.quote(_FIREWALL_DIR)}",
            15,
        ),
        (
            "Install firewall persistence tools",
            "set -eu; command -v flock >/dev/null 2>&1; "
            "if ! dpkg -s iptables-persistent >/dev/null 2>&1; then "
            f"{apt_runtime.apt_get_command('update -y')}; "
            f"{apt_runtime.apt_get_command('install -y iptables-persistent netfilter-persistent')}; "
            "fi",
            apt_runtime.APT_LOCK_TIMEOUT_SECONDS + 120,
        ),
        (
            "Snapshot Deploy Dash-managed IPv4 and IPv6 firewall state",
            f"{_managed_firewall_snapshot_command(_FIREWALL_SPECS[0], staged_state['snapshot_v4'])}; "
            f"{_managed_firewall_snapshot_command(_FIREWALL_SPECS[1], staged_state['snapshot_v6'])}",
            20,
        ),
    ]
    for spec in _FIREWALL_SPECS:
        initial_steps.extend(
            [
                (
                    f"Create managed {spec['label']} INPUT chain",
                    f"{spec['command']} -w -N {spec['input_chain']} 2>/dev/null || true; "
                    f"{spec['command']} -w -F {spec['input_chain']}",
                    10,
                ),
                (
                    f"Create managed {spec['label']} DOCKER-USER chain",
                    f"{spec['command']} -w -N {spec['docker_chain']} 2>/dev/null || true; "
                    f"{spec['command']} -w -F {spec['docker_chain']}",
                    10,
                ),
                (
                    f"Hook managed {spec['label']} INPUT chain",
                    f"{spec['command']} -w -C INPUT -j {spec['input_chain']} 2>/dev/null || "
                    f"{spec['command']} -w -I INPUT 1 -j {spec['input_chain']}",
                    10,
                ),
                (
                    f"Hook managed {spec['label']} DOCKER-USER chain",
                    f"{spec['command']} -w -C DOCKER-USER -j {spec['docker_chain']} "
                    f"2>/dev/null || {spec['command']} -w -I DOCKER-USER 1 -j "
                    f"{spec['docker_chain']}",
                    10,
                ),
                (
                    f"Allow established {spec['label']} host traffic",
                    f"{spec['command']} -w -A {spec['input_chain']} -m conntrack "
                    "--ctstate ESTABLISHED,RELATED -j ACCEPT",
                    10,
                ),
                (
                    f"Allow established {spec['label']} Docker-forwarded traffic",
                    f"{spec['command']} -w -A {spec['docker_chain']} -m conntrack "
                    "--ctstate ESTABLISHED,RELATED -j RETURN",
                    10,
                ),
            ],
        )
        initial_steps.extend(
            [
                (
                    f"Bypass {spec['label']} Docker bridge {interface} traffic",
                    f"{spec['command']} -w -A {spec['docker_chain']} -i "
                    f"{shlex.quote(interface)} -j RETURN",
                    10,
                )
                for interface in server_identifiers.DOCKER_BRIDGE_INTERFACE_PATTERNS
            ],
        )
        initial_steps.append(
            (
                f"Allow localhost {spec['label']} host traffic",
                f"{spec['command']} -w -A {spec['input_chain']} -i lo -j ACCEPT",
                10,
            ),
        )
        initial_steps.extend(_preamble_allow_steps(spec))

    for index, (label, command, timeout) in enumerate(initial_steps):
        status, details = _run_step(
            ctx,
            host,
            emit,
            "firewall_runtime",
            label,
            command,
            timeout=timeout,
        )
        if not status:
            if index > 2:
                _restore_snapshots(ctx, host, staged_state)
            return _firewall_stage_error(
                ctx,
                host,
                "ENGINE_RUNTIME_ERROR",
                f"{label} failed.",
                stage="execute_runtime_operation",
                details=details,
                ufw_active_before=ufw_active_before,
                replacement_started=index >= 1,
            )

    rules = _effective_allow_rules(config)
    for rule in rules:
        family_label = _firewall_spec(rule["family"])["label"]
        host_label = (
            f"Allow {family_label} host {rule['protocol']}:{rule['port_start']}"
            if rule["port_start"] == rule["port_end"]
            else (
                f"Allow {family_label} host "
                f"{rule['protocol']}:{rule['port_start']}-{rule['port_end']}"
            )
        )
        status, details = _run_step(
            ctx,
            host,
            emit,
            "firewall_runtime",
            host_label,
            _build_input_allow_command(rule),
            timeout=10,
        )
        if not status:
            _restore_snapshots(ctx, host, staged_state)
            return _firewall_stage_error(
                ctx,
                host,
                "ENGINE_RUNTIME_ERROR",
                f"{host_label} failed.",
                stage="execute_runtime_operation",
                details=details,
                ufw_active_before=ufw_active_before,
                replacement_started=True,
            )

        docker_label = (
            f"Allow {family_label} Docker ingress {rule['protocol']}:{rule['port_start']}"
            if rule["port_start"] == rule["port_end"]
            else (
                f"Allow {family_label} Docker ingress "
                f"{rule['protocol']}:{rule['port_start']}-{rule['port_end']}"
            )
        )
        status, details = _run_step(
            ctx,
            host,
            emit,
            "firewall_runtime",
            docker_label,
            _build_docker_allow_command(rule),
            timeout=10,
        )
        if not status:
            _restore_snapshots(ctx, host, staged_state)
            return _firewall_stage_error(
                ctx,
                host,
                "ENGINE_RUNTIME_ERROR",
                f"{docker_label} failed.",
                stage="execute_runtime_operation",
                details=details,
                ufw_active_before=ufw_active_before,
                replacement_started=True,
            )

    drop_steps = []
    if config["strict_mode"]:
        for spec in _FIREWALL_SPECS:
            drop_steps.extend(
                [
                    (
                        f"Apply strict {spec['label']} host fallback deny",
                        f"{spec['command']} -w -A {spec['input_chain']} -j DROP",
                        10,
                    ),
                    (
                        f"Apply strict {spec['label']} Docker ingress fallback deny",
                        f"{spec['command']} -w -A {spec['docker_chain']} -j DROP",
                        10,
                    ),
                ],
            )

    for label, command, timeout in drop_steps:
        status, details = _run_step(
            ctx,
            host,
            emit,
            "firewall_runtime",
            label,
            command,
            timeout=timeout,
        )
        if not status:
            _restore_snapshots(ctx, host, staged_state)
            return _firewall_stage_error(
                ctx,
                host,
                "ENGINE_RUNTIME_ERROR",
                f"{label} failed.",
                stage="execute_runtime_operation",
                details=details,
                ufw_active_before=ufw_active_before,
                replacement_started=True,
            )

    finalize_steps = []
    for spec in _FIREWALL_SPECS:
        finalize_steps.append(
            (
                f"Return unmatched {spec['label']} Docker-forwarded traffic",
                f"{spec['command']} -w -A {spec['docker_chain']} -j RETURN",
                10,
            ),
        )

    for label, command, timeout in finalize_steps:
        status, details = _run_step(
            ctx,
            host,
            emit,
            "firewall_runtime",
            label,
            command,
            timeout=timeout,
        )
        if not status:
            _restore_snapshots(ctx, host, staged_state)
            return _firewall_stage_error(
                ctx,
                host,
                "ENGINE_RUNTIME_ERROR",
                f"{label} failed.",
                stage="execute_runtime_operation",
                details=details,
                ufw_active_before=ufw_active_before,
                replacement_started=True,
            )

    for label, command, timeout in _allow_check_commands(rules, docker=False):
        status, details = _run_step(
            ctx,
            host,
            emit,
            "firewall_runtime",
            label,
            command,
            timeout=timeout,
        )
        if not status:
            _restore_snapshots(ctx, host, staged_state)
            return _firewall_stage_error(
                ctx,
                host,
                "ENGINE_RUNTIME_ERROR",
                f"{label} failed.",
                stage="execute_runtime_operation",
                details=details,
                ufw_active_before=ufw_active_before,
                replacement_started=True,
            )

    for label, command, timeout in _allow_check_commands(rules, docker=True):
        status, details = _run_step(
            ctx,
            host,
            emit,
            "firewall_runtime",
            label,
            command,
            timeout=timeout,
        )
        if not status:
            _restore_snapshots(ctx, host, staged_state)
            return _firewall_stage_error(
                ctx,
                host,
                "ENGINE_RUNTIME_ERROR",
                f"{label} failed.",
                stage="execute_runtime_operation",
                details=details,
                ufw_active_before=ufw_active_before,
                replacement_started=True,
            )

    for label, command, timeout in _docker_policy_check_commands(config["strict_mode"]):
        status, details = _run_step(
            ctx,
            host,
            emit,
            "firewall_runtime",
            label,
            command,
            timeout=timeout,
        )
        if not status:
            _restore_snapshots(ctx, host, staged_state)
            return _firewall_stage_error(
                ctx,
                host,
                "ENGINE_RUNTIME_ERROR",
                f"{label} failed.",
                stage="execute_runtime_operation",
                details=details,
                ufw_active_before=ufw_active_before,
                replacement_started=True,
            )

    for label, command, timeout in _preamble_check_commands():
        status, details = _run_step(
            ctx,
            host,
            emit,
            "firewall_runtime",
            label,
            command,
            timeout=timeout,
        )
        if not status:
            _restore_snapshots(ctx, host, staged_state)
            return _firewall_stage_error(
                ctx,
                host,
                "ENGINE_RUNTIME_ERROR",
                f"{label} failed.",
                stage="execute_runtime_operation",
                details=details,
                ufw_active_before=ufw_active_before,
                replacement_started=True,
            )

    persisted = _persist_firewall_stage(
        ctx,
        host,
        stage_token=stage_token,
        staged_state=staged_state,
        rollback_timeout_seconds=config["rollback_timeout_seconds"],
        allow_postgres=config["allow_postgres"],
        postgres_source_cidrs=config["postgres_source_cidrs"],
        ufw_active_before=ufw_active_before,
        emit=emit,
    )
    if persisted["status"] != "success":
        return persisted

    payload = _firewall_status_payload(host)
    payload["staged_state"] = {
        "token": stage_token,
        "expires_at": persisted["expires_at"],
        "allow_postgres": config["allow_postgres"],
        "postgres_source_cidrs": config["postgres_source_cidrs"],
        "ufw_replaced": ufw_active_before,
    }

    return {
        "status": "success",
        "code": "OK",
        "msg": "Firewall rules staged. Commit before rollback deadline.",
        "operation_id": "apply_staged",
        "strict_mode": config["strict_mode"],
        "rollback_timeout_seconds": config["rollback_timeout_seconds"],
        "allowed_rule_count": len(rules),
        **payload,
    }


def _commit_staged_firewall(ctx, host, stage_token, emit=None):
    staged_state = _read_stage_state(host)
    if not staged_state["pending"]:
        if stage_token:
            # The stage vanished (rollback timer or operator) after it was
            # created: the live rules are the pre-stage ones, so reporting
            # success here would mark an unfirewalled server provisioned.
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                ("Staged firewall changes are gone; they were reverted, not committed."),
                stage="execute_runtime_operation",
            )
        return {
            "status": "success",
            "code": "OK",
            "msg": "No staged firewall changes were pending.",
            "operation_id": "commit",
            **_firewall_status_payload(host),
        }

    if stage_token and staged_state["token"] != stage_token:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Provided stage token does not match pending firewall stage.",
            stage="validate_request",
        )

    commit_command = (
        "set -eu; "
        f"STAGE_FILE={shlex.quote(_STAGE_FILE)}; "
        f"LOCK_FILE={shlex.quote(_STAGE_LOCK_FILE)}; "
        f"EXPECTED_TOKEN={shlex.quote(staged_state['token'] or '')}; "
        "export STAGE_FILE EXPECTED_TOKEN; "
        'touch "${LOCK_FILE}"; chmod 600 "${LOCK_FILE}"; '
        'flock -x "${LOCK_FILE}" sh -eu -c \' '
        '[ -f "${STAGE_FILE}" ]; '
        '. "${STAGE_FILE}"; '
        '[ "${TOKEN:-}" = "${EXPECTED_TOKEN}" ]; '
        'SNAPSHOT_PATH_V4="${SNAPSHOT_V4:-${SNAPSHOT:-}}"; '
        'SNAPSHOT_PATH_V6="${SNAPSHOT_V6:-}"; '
        "mkdir -p /etc/iptables; "
        f"iptables-save > {shlex.quote(_RULES_V4_FILE)}; "
        f"ip6tables-save > {shlex.quote(_RULES_V6_FILE)}; "
        "systemctl enable netfilter-persistent; "
        "netfilter-persistent save >/dev/null 2>&1 || true; "
        'rm -f "${STAGE_FILE}"; '
        'if [ -n "${SNAPSHOT_PATH_V4}" ]; then rm -f "${SNAPSHOT_PATH_V4}"; fi; '
        'if [ -n "${SNAPSHOT_PATH_V6}" ]; then rm -f "${SNAPSHOT_PATH_V6}"; fi\''
    )
    status, output = host.run_shell_command(
        commit_command,
        _timeout=30,
        _sudo=True,
    )
    ctx.emit_shell_output_lines(emit, output)
    if not status:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Failed to commit staged firewall changes.",
            stage="execute_runtime_operation",
            details=ctx.command_error_details(output) or "commit cleanup failed",
        )

    return {
        "status": "success",
        "code": "OK",
        "msg": "Staged firewall changes committed.",
        "operation_id": "commit",
        **_firewall_status_payload(host),
    }


def _rollback_staged_firewall(ctx, host, stage_token, emit=None):
    staged_state = _read_stage_state(host)
    if not staged_state["pending"]:
        return {
            "status": "success",
            "code": "OK",
            "msg": "No staged firewall changes were pending.",
            "operation_id": "rollback",
            **_firewall_status_payload(host),
        }

    if stage_token and staged_state["token"] != stage_token:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Provided stage token does not match pending firewall stage.",
            stage="validate_request",
        )

    restored, details = _restore_snapshots(ctx, host, staged_state)
    if not restored:
        return _firewall_stage_error(
            ctx,
            host,
            "ENGINE_RUNTIME_ERROR",
            "Failed to restore firewall snapshot.",
            stage="execute_runtime_operation",
            details=details,
            ufw_active_before=staged_state["ufw_active_before"],
            replacement_started=True,
        )

    cleanup_command = (
        "set -eu; "
        f"STAGE_FILE={shlex.quote(_STAGE_FILE)}; "
        f"SNAPSHOT_V4={shlex.quote(staged_state['snapshot_v4'] or '')}; "
        f"SNAPSHOT_V6={shlex.quote(staged_state['snapshot_v6'] or '')}; "
        'rm -f "${STAGE_FILE}"; '
        'if [ -n "${SNAPSHOT_V4}" ]; then rm -f "${SNAPSHOT_V4}"; fi; '
        'if [ -n "${SNAPSHOT_V6}" ]; then rm -f "${SNAPSHOT_V6}"; fi'
    )
    _, cleanup_output = host.run_shell_command(cleanup_command, _timeout=10, _sudo=True)
    ctx.emit_shell_output_lines(emit, cleanup_output)

    message = "Staged firewall changes rolled back."
    if staged_state["ufw_active_before"]:
        _mark_firewall_unprotected(host)
        message += (
            " Deploy Dash replaced active ufw, so this server currently has no "
            "active firewall. Retry the firewall setup immediately."
        )
    result = {
        "status": "success",
        "code": "OK",
        "msg": message,
        "operation_id": "rollback",
        **_firewall_status_payload(host),
    }
    if staged_state["ufw_active_before"]:
        result["firewall_state"] = "unprotected"
    return result


def run_firewall_runtime_operation(
    ctx,
    operation_id,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    raw_data=None,
    emit=None,
    is_cancelled=None,
):
    if callable(is_cancelled) and is_cancelled():
        return ctx.error_result(
            "ENGINE_TASK_CANCELLED",
            "Task cancelled before execution started",
            stage="preflight",
        )

    try:
        config = _parse_firewall_settings(raw_data)
    except FirewallConfigValidationError as exc:
        ctx.emit_event(
            emit,
            "validation_error",
            str(exc),
            level="error",
        )
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            str(exc),
            stage="validate_request",
        )

    if operation_id == "apply_staged" and int(port) not in config["locked_ports"]:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Firewall locked ports must include active SSH port {int(port)}.",
            stage="validate_request",
        )

    operation_actions = {
        "status": [
            "Read managed IPv4 and IPv6 firewall chains",
            "Read staged apply state",
            "Read persisted firewall state",
        ],
        "scan_open_ports": ["Read host listeners", "Read Docker published ports"],
        "apply_staged": [
            "Replace ufw with the Deploy Dash firewall",
            "Install firewall persistence tools before changing live rules",
            "Snapshot only Deploy Dash-managed chains and jump ownership",
            "Apply DeployDash-managed IPv4 and IPv6 INPUT and DOCKER-USER chains",
            "Schedule rollback safety timer",
        ],
        "commit": [
            "Persist committed IPv4 and IPv6 firewall rules",
            "Enable restore-on-boot with netfilter-persistent",
            "Cancel rollback timer and keep staged rules",
        ],
        "rollback": ["Restore managed IPv4 and IPv6 state and clear staged state"],
    }
    actions = operation_actions.get(operation_id)
    if actions is None:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Unknown firewall runtime operation: {operation_id}",
            stage="validate_request",
        )

    if dry_run:
        return {
            "status": "success",
            "code": "OK",
            "msg": f"Firewall runtime operation '{operation_id}' plan ready",
            "operation_id": operation_id,
            "actions": actions,
        }

    opened = ctx.open_runtime_session(
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        needs_sudo=True,
        emit=emit,
    )
    if not opened["ok"]:
        return opened["error"]

    session = opened["session"]
    try:
        ctx.emit_event(
            emit,
            "firewall_runtime_plan_ready",
            f"Runtime operation '{operation_id}' prepared.",
            data={"operation_id": operation_id},
        )

        if operation_id == "status":
            payload = _firewall_status_payload(session.host)
            return {
                "status": "success",
                "code": "OK",
                "msg": "Firewall status collected.",
                "operation_id": operation_id,
                **payload,
            }

        elif operation_id == "scan_open_ports":
            return {
                "status": "success",
                "code": "OK",
                "msg": "Open ports inventory collected.",
                "operation_id": operation_id,
                "open_ports": _scan_open_ports(session.host),
            }

        elif operation_id == "apply_staged":
            return _apply_staged_firewall(
                ctx,
                session.host,
                config,
                emit=emit,
                active_ssh_port=port,
            )

        elif operation_id == "commit":
            return _commit_staged_firewall(ctx, session.host, config["stage_token"])

        else:
            return _rollback_staged_firewall(ctx, session.host, config["stage_token"])
    finally:
        close_result = session.close()
        disconnect_error = close_result.get("disconnect_error")
        if disconnect_error:
            ctx.emit_event(
                emit,
                "connection_disconnect_error",
                disconnect_error,
                level="warning",
            )
