import shlex
from typing import cast

from pyinfra.operations import server

from .. import server_paths
from ..container_status import bind_service_readiness_check_shell
from .common import DnsAction, DnsStep
from .dns_config import DnsConfig


def build_steps(config: DnsConfig):
    quoted_stack_root = shlex.quote(config.stack_root)
    quoted_container_name = shlex.quote(config.container_name)
    quoted_bind_image = shlex.quote(config.bind_image)
    quoted_zones_conf = shlex.quote(f"{config.stack_root}/bind/zones.conf")
    host_probe_address = cast(str, config.nameserver_ipv4 or config.nameserver_ipv6)
    quoted_host_probe_address = shlex.quote(host_probe_address)
    host_dig = f"docker run --rm --network host --entrypoint dig {quoted_bind_image}"

    zone_checks_command = (
        "set -eu; "
        f"ZONES_CONF={quoted_zones_conf}; "
        'ZONES_TMP_FILE="$(mktemp)"; '
        'cleanup() { rm -f "${ZONES_TMP_FILE}" >/dev/null 2>&1 || true; }; '
        "trap cleanup EXIT; "
        'awk -F\'"\' \'/^zone "/ {print $2}\' "${ZONES_CONF}" > "${ZONES_TMP_FILE}"; '
        "while IFS= read -r zone; do "
        '[ -n "${zone}" ] || continue; '
        f'ns="{config.nameserver_hostname}.${{zone}}"; '
        f'{host_dig} @{quoted_host_probe_address} "${{zone}}" SOA +short '
        "| grep -q . || exit 1; "
        f'{host_dig} +tcp @{quoted_host_probe_address} "${{zone}}" SOA +short '
        "| grep -q . || exit 1; "
        "docker exec "
        f"{quoted_container_name} "
        'dig @127.0.0.1 "${zone}" SOA +short | grep -q . || exit 1; '
        "docker exec "
        f"{quoted_container_name} "
        'dig @127.0.0.1 "${zone}" NS +short | grep -q . || exit 1; '
        "docker exec "
        f"{quoted_container_name} "
        'dig @127.0.0.1 "${ns}" A +short | grep -q . || exit 1; '
        'done < "${ZONES_TMP_FILE}"'
    )

    def register_step(runtime):
        runtime.add_operation(
            server.shell,
            commands=[
                "docker --version",
                "docker compose version",
            ],
        )
        runtime.ensure_service_enabled("docker")
        runtime.add_operation(
            server.shell,
            commands=[
                "systemctl is-active --quiet docker",
            ],
        )
        runtime.add_operation(
            server.shell,
            commands=[
                f"{server_paths.bind_apply_helper()} {quoted_stack_root} {quoted_container_name}",
            ],
        )
        runtime.add_operation(
            server.shell,
            commands=[
                bind_service_readiness_check_shell(quoted_container_name),
                "docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "
                f"{quoted_container_name} | grep -q unless-stopped",
                f"docker port {quoted_container_name} 53/udp | grep -q .",
                f"docker port {quoted_container_name} 53/tcp | grep -q .",
            ],
        )
        runtime.add_operation(
            server.shell,
            commands=[zone_checks_command],
            _retries=8,
            _retry_delay=2,
        )

    return [
        DnsStep(
            id="dns_part2_step1_validate_and_start_bind",
            title="Validate Bind container and enforce authoritative DNS service",
            part="part2",
            commands=[
                "Verify Docker engine and compose plugin availability",
                "Ensure Docker daemon is enabled to start at boot",
                "Run deploydash-bind-apply helper (compose/checkconf/checkzone)",
                "Verify Bind readiness, restart policy, and published DNS ports",
                "Verify host-published SOA plus container SOA/NS/A responses",
            ],
            actions=[
                DnsAction(
                    id="dns_part2_step1_action_verify_docker",
                    label="Verify Docker runtime",
                    description="Confirm Docker engine and compose availability",
                ),
                DnsAction(
                    id="dns_part2_step1_action_enable_docker_service",
                    label="Enable Docker daemon",
                    description="Ensure Docker starts at boot and is active now",
                ),
                DnsAction(
                    id="dns_part2_step1_action_apply_bind_config",
                    label="Apply Bind container config",
                    description="Validate all zones and restart Bind container",
                ),
                DnsAction(
                    id="dns_part2_step1_action_verify_container_state",
                    label="Verify Bind readiness",
                    description=(
                        "Ensure Bind is running, published on TCP/UDP, and set to restart"
                    ),
                ),
                DnsAction(
                    id="dns_part2_step1_action_verify_dns_answers",
                    label="Verify authoritative answers",
                    description=("Check published TCP/UDP SOA and container SOA/NS/A records"),
                ),
            ],
            register=register_step,
        ),
    ]
