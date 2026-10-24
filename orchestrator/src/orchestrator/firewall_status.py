import shlex

from .runtime_ops import run_shell_command
from .shell_output import as_int, parse_key_values

__all__ = ["as_int", "parse_key_values"]


def build_fail2ban_status_command():
    return (
        "set -eu; "
        "FAIL2BAN_ACTIVE=0; "
        "FAIL2BAN_ENABLED=0; "
        "SSHD_JAIL_ACTIVE=0; "
        "CURRENTLY_BANNED=0; "
        "TOTAL_FAILED=0; "
        "if systemctl is-active fail2ban >/dev/null 2>&1; then FAIL2BAN_ACTIVE=1; fi; "
        "if systemctl is-enabled fail2ban >/dev/null 2>&1; then FAIL2BAN_ENABLED=1; fi; "
        "if command -v fail2ban-client >/dev/null 2>&1; then "
        'STATUS="$(fail2ban-client status sshd 2>/dev/null || true)"; '
        'if [ -n "$STATUS" ]; then '
        "SSHD_JAIL_ACTIVE=1; "
        'CURRENTLY_BANNED_RAW="$(printf "%s\\n" "$STATUS" | awk -F": " \'/Currently banned/ {print $2; exit}\' || true)"; '
        'TOTAL_FAILED_RAW="$(printf "%s\\n" "$STATUS" | awk -F": " \'/Total failed/ {print $2; exit}\' || true)"; '
        'if [ -n "${CURRENTLY_BANNED_RAW}" ]; then CURRENTLY_BANNED="${CURRENTLY_BANNED_RAW}"; fi; '
        'if [ -n "${TOTAL_FAILED_RAW}" ]; then TOTAL_FAILED="${TOTAL_FAILED_RAW}"; fi; '
        "fi; "
        "fi; "
        'printf "FAIL2BAN_ACTIVE=%s\\n" "$FAIL2BAN_ACTIVE"; '
        'printf "FAIL2BAN_ENABLED=%s\\n" "$FAIL2BAN_ENABLED"; '
        'printf "SSHD_JAIL_ACTIVE=%s\\n" "$SSHD_JAIL_ACTIVE"; '
        'printf "CURRENTLY_BANNED=%s\\n" "$CURRENTLY_BANNED"; '
        'printf "TOTAL_FAILED=%s\\n" "$TOTAL_FAILED"; '
    )


def fail2ban_status_payload(host):
    status, output = host.run_shell_command(
        build_fail2ban_status_command(),
        _timeout=10,
        _sudo=True,
    )
    values = parse_key_values(output) if status else {}
    return {
        "fail2ban_active": values.get("FAIL2BAN_ACTIVE") == "1",
        "fail2ban_enabled": values.get("FAIL2BAN_ENABLED") == "1",
        "fail2ban_sshd_jail_active": values.get("SSHD_JAIL_ACTIVE") == "1",
        "fail2ban_currently_banned": as_int(values.get("CURRENTLY_BANNED"), 0),
        "fail2ban_total_failed": as_int(values.get("TOTAL_FAILED"), 0),
    }


def build_persistence_status_command(rules_v4_file, rules_v6_file):
    return (
        "set -eu; "
        f'if [ -s {shlex.quote(rules_v4_file)} ]; then printf "RULES_V4=1\\n"; '
        'else printf "RULES_V4=0\\n"; fi; '
        f'if [ -s {shlex.quote(rules_v6_file)} ]; then printf "RULES_V6=1\\n"; '
        'else printf "RULES_V6=0\\n"; fi; '
        "if systemctl is-enabled netfilter-persistent >/dev/null 2>&1; then "
        'printf "NETFILTER_PERSISTENT=1\\n"; '
        'else printf "NETFILTER_PERSISTENT=0\\n"; fi'
    )


def firewall_status_payload(
    host,
    *,
    firewall_specs,
    rules_v4_file,
    rules_v6_file,
    read_stage_state,
    detect_external_interface,
    detect_connection_source_address,
    required_input_checks,
):
    staged_state = read_stage_state(host)
    external_interface = detect_external_interface(host)
    connection_source_address = detect_connection_source_address(host)
    input_states = {}
    docker_states = {}
    required_input_states = {}
    for spec in firewall_specs:
        input_status, _ = host.run_shell_command(
            f"{spec['command']} -w -C INPUT -j {spec['input_chain']}",
            _timeout=10,
            _sudo=True,
        )
        docker_status, _ = host.run_shell_command(
            f"{spec['command']} -w -C DOCKER-USER -j {spec['docker_chain']}",
            _timeout=10,
            _sudo=True,
        )
        required_statuses = []
        for _label, command, timeout in required_input_checks(spec["family"]):
            required_result = run_shell_command(
                host,
                command,
                timeout=timeout,
                sudo=True,
            )
            required_statuses.append(required_result["ok"])
        required_input_states[spec["family"]] = all(required_statuses)
        input_states[spec["family"]] = bool(input_status) and all(required_statuses)
        docker_states[spec["family"]] = bool(docker_status)

    persistence_status, persistence_output = host.run_shell_command(
        build_persistence_status_command(rules_v4_file, rules_v6_file),
        _timeout=10,
        _sudo=True,
    )
    persistence_values = parse_key_values(persistence_output) if persistence_status else {}
    rules_v4_present = persistence_values.get("RULES_V4") == "1"
    rules_v6_present = persistence_values.get("RULES_V6") == "1"
    persistent_enabled = persistence_values.get("NETFILTER_PERSISTENT") == "1"
    fail2ban_values = fail2ban_status_payload(host)

    return {
        "firewall_enabled": all(input_states.values()) and all(docker_states.values()),
        "firewall_ipv4_enabled": input_states.get("ipv4", False)
        and docker_states.get("ipv4", False),
        "firewall_ipv6_enabled": input_states.get("ipv6", False)
        and docker_states.get("ipv6", False),
        "required_preamble_present": all(required_input_states.values()),
        "required_preamble_ipv4_present": required_input_states.get("ipv4", False),
        "required_preamble_ipv6_present": required_input_states.get("ipv6", False),
        "external_interface": external_interface,
        "connection_source_address": connection_source_address,
        "persistent_rules_present": rules_v4_present and rules_v6_present,
        "persistent_rules_v4_present": rules_v4_present,
        "persistent_rules_v6_present": rules_v6_present,
        "netfilter_persistent_enabled": persistent_enabled,
        **fail2ban_values,
        "staged_state": {
            "token": staged_state["token"],
            "expires_at": staged_state["expires_at"],
            "allow_postgres": staged_state.get("allow_postgres", False),
            "postgres_source_cidrs": staged_state.get(
                "postgres_source_cidrs",
                [],
            ),
        }
        if staged_state["pending"]
        else None,
    }
