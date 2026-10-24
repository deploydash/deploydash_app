from io import StringIO

from pyinfra.operations import files, server

from .. import server_paths
from ..container_status import bind_service_readiness_check_shell
from ..runtime_security import docker_compose_security_lines
from .common import DnsAction, DnsStep
from .dns_config import DnsConfig, DnsZone

_CONTAINER_ZONES_DIR = "/zones"


def _zones_host_dir(config: DnsConfig):
    return f"{config.stack_root}/zones"


def _bind_host_dir(config: DnsConfig):
    return f"{config.stack_root}/bind"


def _render_named_conf():
    return 'include "/etc/bind/options.conf";\ninclude "/etc/bind/zones.conf";\n'


def _render_named_options(config: DnsConfig):
    listen_on_v6 = "any" if config.listen_on_ipv6 else "none"
    return (
        "options {\n"
        f'    directory "{_CONTAINER_ZONES_DIR}";\n'
        "    recursion no;\n"
        "    allow-recursion { none; };\n"
        "    allow-query { any; };\n"
        "    allow-query-cache { none; };\n"
        "    dnssec-validation auto;\n"
        "    listen-on { any; };\n"
        "    listen-on-v6 { "
        f"{listen_on_v6}; }};\n"
        "};\n"
    )


def _render_zones_conf(config: DnsConfig):
    blocks = []
    for zone in config.zones:
        blocks.append(
            f'zone "{zone.zone_name}" {{\n'
            "    type master;\n"
            f'    file "{zone.zone_file_path}";\n'
            "    allow-update { none; };\n"
            "};\n"
        )
    return "\n".join(blocks)


def _render_zone_file(config: DnsConfig, zone: DnsZone):
    ns_fqdn = f"{config.nameserver_hostname}.{zone.zone_name}."
    admin_mailbox = f"{zone.admin_email}."

    lines = [
        f"$TTL {zone.zone_ttl}",
        f"@ IN SOA {ns_fqdn} {admin_mailbox} (",
        f"    {zone.zone_serial} ; serial",
        f"    {zone.zone_refresh} ; refresh",
        f"    {zone.zone_retry} ; retry",
        f"    {zone.zone_expire} ; expire",
        f"    {zone.zone_negative_ttl} ; minimum",
        ")",
        "",
        f"@ IN NS {ns_fqdn}",
    ]
    if config.nameserver_ipv4:
        lines.append(f"{config.nameserver_hostname} IN A {config.nameserver_ipv4}")
    if config.nameserver_ipv6:
        lines.append(f"{config.nameserver_hostname} IN AAAA {config.nameserver_ipv6}")
    if zone.default_a_ipv4:
        lines.append(f"@ IN A {zone.default_a_ipv4}")
    if zone.default_aaaa_ipv6:
        lines.append(f"@ IN AAAA {zone.default_aaaa_ipv6}")

    for record in zone.extra_records:
        lines.append(f"{record.name} IN {record.type} {record.value}")

    return "\n".join(lines) + "\n"


def _render_compose(config: DnsConfig):
    return (
        "services:\n"
        "  bind9:\n"
        f"    container_name: {config.container_name}\n"
        f"    image: {config.bind_image}\n"
        "    restart: unless-stopped\n"
        f"{docker_compose_security_lines(cap_add=('NET_BIND_SERVICE', 'SETUID', 'SETGID'))}"
        "    ports:\n"
        '      - "53:53/tcp"\n'
        '      - "53:53/udp"\n'
        "    command:\n"
        "      - -g\n"
        "      - -c\n"
        "      - /etc/bind/named.conf\n"
        "    volumes:\n"
        f"      - {_bind_host_dir(config)}:/etc/bind:ro\n"
        f"      - {_zones_host_dir(config)}:{_CONTAINER_ZONES_DIR}:ro\n"
    )


def _render_stack_readme(config: DnsConfig):
    zones_body = "\n".join(f"- `{zone_name}`" for zone_name in config.zone_names)
    return (
        "# DeployDash Bind9 authoritative DNS stack (Docker)\n\n"
        "This workflow writes managed Bind9 config files for authoritative zones,\n"
        "validates/reloads them via Docker, and enforces container restart policy.\n\n"
        f"- Bind image: `{config.bind_image}`\n"
        f"- Container: `{config.container_name}`\n"
        f"- Nameserver host label: `{config.nameserver_hostname}`\n"
        f"- Nameserver IPv4: `{config.nameserver_ipv4 or 'disabled'}`\n"
        f"- Nameserver IPv6: `{config.nameserver_ipv6 or 'disabled'}`\n"
        f"- Managed zones: {config.zone_count}\n"
        f"{zones_body}\n\n"
        "Apply helper:\n\n"
        f"`{server_paths.bind_apply_helper()} {config.stack_root}`\n"
    )


def _render_apply_script(config: DnsConfig):
    container_ref = '"${CONTAINER_NAME}"'
    return (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n\n"
        f'STACK_ROOT="${{1:-{config.stack_root}}}"\n'
        f'CONTAINER_NAME="${{2:-{config.container_name}}}"\n'
        'COMPOSE_FILE="${STACK_ROOT}/docker-compose.yml"\n'
        f'LEGACY_BIND_SERVICE="${{3:-{config.bind_service_name}}}"\n'
        'ZONES_CONF="${STACK_ROOT}/bind/zones.conf"\n'
        'ZONES_TMP_FILE="$(mktemp)"\n'
        "cleanup() {\n"
        '    rm -f "${ZONES_TMP_FILE}" || true\n'
        "}\n"
        "trap cleanup EXIT\n\n"
        'if systemctl list-unit-files | grep -q "^${LEGACY_BIND_SERVICE}\\.service"; then\n'
        '    systemctl stop "${LEGACY_BIND_SERVICE}" || true\n'
        '    systemctl disable "${LEGACY_BIND_SERVICE}" || true\n'
        "fi\n"
        'docker compose -f "${COMPOSE_FILE}" config -q\n'
        'docker compose -f "${COMPOSE_FILE}" up -d bind9\n'
        'docker exec "${CONTAINER_NAME}" named-checkconf /etc/bind/named.conf\n'
        'awk -F\'"\' \'/^zone "/ {print $2}\' "${ZONES_CONF}" > "${ZONES_TMP_FILE}"\n'
        "while IFS= read -r zone; do\n"
        '    [ -n "${zone}" ] || continue\n'
        '    docker exec "${CONTAINER_NAME}" named-checkzone "${zone}" "/zones/db.${zone}"\n'
        'done < "${ZONES_TMP_FILE}"\n'
        'docker compose -f "${COMPOSE_FILE}" restart bind9\n'
        f"{bind_service_readiness_check_shell(container_ref)}\n"
        'docker inspect -f "{{.HostConfig.RestartPolicy.Name}}" "${CONTAINER_NAME}" | grep -q unless-stopped\n'
        'if [ -s "${ZONES_TMP_FILE}" ]; then\n'
        '    first_zone="$(head -n1 "${ZONES_TMP_FILE}")"\n'
        '    docker exec "${CONTAINER_NAME}" dig @127.0.0.1 "${first_zone}" SOA +short | grep -q .\n'
        "fi\n"
    )


def build_steps(config: DnsConfig):
    stack_root = config.stack_root
    bind_host_dir = _bind_host_dir(config)
    zones_host_dir = _zones_host_dir(config)

    def register_step(runtime):
        for path in (
            stack_root,
            bind_host_dir,
            zones_host_dir,
        ):
            runtime.add_operation(
                files.directory,
                path=path,
                mode="755",
            )

        runtime.add_operation(
            files.put,
            src=StringIO(_render_named_conf()),
            dest=f"{bind_host_dir}/named.conf",
            mode="644",
        )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_named_options(config)),
            dest=f"{bind_host_dir}/options.conf",
            mode="644",
        )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_zones_conf(config)),
            dest=f"{bind_host_dir}/zones.conf",
            mode="644",
        )
        for zone in config.zones:
            runtime.add_operation(
                files.put,
                src=StringIO(_render_zone_file(config, zone)),
                dest=f"{zones_host_dir}/db.{zone.zone_name}",
                mode="644",
            )
        runtime.add_operation(
            server.shell,
            commands=[
                (
                    f'for file in "{zones_host_dir}"/db.*; do '
                    '[ -e "${file}" ] || continue; '
                    'zone="${file##*/db.}"; '
                    'case "${zone}" in '
                    + "|".join(f'"{zone_name}"' for zone_name in config.zone_names)
                    + ') ;; *) rm -f "${file}" ;; esac; '
                    "done"
                ),
            ],
        )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_compose(config)),
            dest=f"{stack_root}/docker-compose.yml",
            mode="644",
        )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_stack_readme(config)),
            dest=f"{stack_root}/README.md",
            mode="644",
        )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_apply_script(config)),
            dest=server_paths.bind_apply_helper(),
            mode="755",
        )

    return [
        DnsStep(
            id="dns_part1_step1_install_and_write_bind_config",
            title="Write Docker-based Bind9 authoritative configuration",
            part="part1",
            commands=[
                "Create Docker stack directories for Bind config and zones",
                "Write authoritative named.conf/options/zones configuration files",
                "Write managed zone files and remove stale deleted zone files",
                "Write pinned Bind9 docker-compose stack",
                f"Install {server_paths.bind_apply_helper()} helper",
            ],
            actions=[
                DnsAction(
                    id="dns_part1_step1_action_write_named_configs",
                    label="Write Bind config files",
                    description="Render authoritative Bind configuration files",
                ),
                DnsAction(
                    id="dns_part1_step1_action_sync_zone_files",
                    label="Sync zone files",
                    description="Write current zones and remove deleted ones safely",
                ),
                DnsAction(
                    id="dns_part1_step1_action_write_compose",
                    label="Write Docker Compose stack",
                    description="Pin stable ISC Bind9 image and restart policy",
                ),
                DnsAction(
                    id="dns_part1_step1_action_write_apply_helper",
                    label="Install apply helper",
                    description="Validate all zones and restart Bind container safely",
                ),
            ],
            register=register_step,
        ),
    ]
