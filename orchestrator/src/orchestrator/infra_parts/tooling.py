# ruff: noqa: F403, F405

from .. import apt_runtime
from ..managed_software import (
    DOCKER_PACKAGE_PAYLOAD_KEYS,
    MANAGED_BACKUP_RETENTION_LIMIT,
    docker_package_patch_series,
)
from ._shared import *

# The upgrade backup copies the helper by basename into a backup directory,
# so the name is derived from the installed path rather than restated.
_RAILPACK_HELPER_NAME = server_identifiers.RAILPACK_BUILD_HELPER_NAME


def _tooling_component(
    *,
    label,
    current,
    target,
    current_flag,
    update_action,
):
    if current_flag:
        status = "current"
    elif current:
        status = "update_available"
    else:
        status = "missing"
    return {
        "label": label,
        "status": status,
        "current": current,
        "target": target,
        "update_action": update_action,
    }


def _capability_detail(
    *,
    label,
    current,
    target,
    current_flag=None,
    status=None,
):
    current = current or ""
    target = target or ""
    if status is None:
        if current_flag is True:
            status = "current"
        elif current:
            status = "update_available"
        else:
            status = "missing"
    return {
        "label": label,
        "status": status,
        "current": current,
        "target": target,
    }


def _capability(
    *,
    capability_id,
    category,
    label,
    description,
    status,
    summary,
    details,
    can_update=False,
    action_label=None,
):
    return {
        "id": capability_id,
        "category": category,
        "label": label,
        "description": description,
        "status": status,
        "summary": summary,
        "details": details,
        "can_update": bool(can_update),
        "action_label": action_label or "",
    }


def _details_status(details, *, not_configured=False):
    if not_configured:
        return "not_configured"
    if any(detail.get("status") == "missing" for detail in details):
        return "missing"
    if any(detail.get("status") == "update_available" for detail in details):
        return "update_available"
    if any(detail.get("status") == "needs_attention" for detail in details):
        return "needs_attention"
    return "current"


def _package_detail(payload, package_name, label):
    version = payload.get(f"{package_name}_version", "")
    return _capability_detail(
        label=label,
        current=version,
        target="Installed",
        current_flag=bool(version),
    )


def _stack_image_detail(payload, key, label, target):
    current = payload.get(key, "")
    if not current:
        return _capability_detail(
            label=label,
            current="",
            target=target,
            status="not_configured",
        )
    return _capability_detail(
        label=label,
        current=current,
        target=target,
        current_flag=current == target,
    )


def _docker_patch_probe_shell():
    """Report only apt candidates newer inside each app-owned Docker series."""
    probes = []
    for package_name, payload_key in DOCKER_PACKAGE_PAYLOAD_KEYS.items():
        series = docker_package_patch_series(
            platform_versions.DOCKER_PACKAGE_VERSION_PREFIXES[package_name],
        )
        candidate_key = f"{payload_key.removesuffix('_version')}_patch_candidate"
        probes.append(
            "docker_patch_candidate "
            f"{shlex.quote(package_name)} {shlex.quote(series)} "
            f"{shlex.quote(candidate_key)}; ",
        )
    return (
        'docker_patch_candidate(){ PACKAGE="$1"; SERIES="$2"; KEY="$3"; '
        'CURRENT="$(pkg "${PACKAGE}")"; BEST=""; '
        'for VERSION in $(apt-cache madison "${PACKAGE}" 2>/dev/null | '
        "awk '{print $3}'); do "
        'case "${VERSION}" in "${SERIES}"[0-9]*) '
        'if [ -z "${BEST}" ] || dpkg --compare-versions "${VERSION}" gt "${BEST}"; '
        'then BEST="${VERSION}"; fi ;; esac; done; '
        'if [ -n "${CURRENT}" ] && [ -n "${BEST}" ] '
        '&& dpkg --compare-versions "${BEST}" gt "${CURRENT}"; '
        'then kv "${KEY}" "${BEST}"; else kv "${KEY}" ""; fi; }; ' + "".join(probes)
    )


def _build_server_tooling_status_command():
    quoted_frontend_image = shlex.quote(RAILPACK_FRONTEND_IMAGE)
    quoted_frontend_digest = shlex.quote(RAILPACK_FRONTEND_IMAGE_DIGEST)
    quoted_env_line = shlex.quote(
        f"RAILPACK_FRONTEND_IMAGE={RAILPACK_FRONTEND_IMAGE}",
    )
    quoted_env_digest_line = shlex.quote(
        f"RAILPACK_FRONTEND_IMAGE_DIGEST={RAILPACK_FRONTEND_IMAGE_DIGEST}",
    )
    quoted_railpack_root = shlex.quote(RAILPACK_STACK_ROOT)
    quoted_caddy_image = shlex.quote(CANONICAL_HTTP_SETTINGS["caddy_image"])
    quoted_http_stack = shlex.quote(CANONICAL_HTTP_SETTINGS["stack_root"])
    quoted_caddy_container = shlex.quote(CANONICAL_HTTP_SETTINGS["container_name"])
    quoted_dns_stack = shlex.quote(CANONICAL_DNS_SETTINGS["stack_root"])
    quoted_bind_image = shlex.quote(CANONICAL_DNS_SETTINGS["bind_image"])
    quoted_bind_container = shlex.quote(CANONICAL_DNS_SETTINGS["container_name"])
    quoted_postgres_stack = shlex.quote(CANONICAL_POSTGRES_SETTINGS["stack_root"])
    quoted_postgres_container = shlex.quote(
        CANONICAL_POSTGRES_SETTINGS["container_name"],
    )
    quoted_postgres_env_file = shlex.quote(
        f"{CANONICAL_POSTGRES_SETTINGS['stack_root']}/.env",
    )
    quoted_postgres_superuser = shlex.quote(
        CANONICAL_POSTGRES_SETTINGS["superuser_name"],
    )
    postgres_user_ref = '"$POSTGRES_USER"'
    return (
        "set -eu; "
        'kv(){ printf "%s=%s\\n" "$1" "$2"; }; '
        "pkg(){ dpkg-query -W -f='${Version}' \"$1\" 2>/dev/null || true; }; "
        "first_image(){ awk '/^[[:space:]]*image:[[:space:]]*/ {print $2; exit}' \"$1\" 2>/dev/null || true; }; "
        'image_for_service(){ awk -v svc="$1" \'$1==svc":" {in_svc=1; next} in_svc && /^[^[:space:]]/ {in_svc=0} in_svc && $1=="image:" {print $2; exit}\' "$2" 2>/dev/null || true; }; '
        'RAILPACK_VERSION=""; '
        "if command -v railpack >/dev/null 2>&1; then "
        'RAILPACK_VERSION="$(railpack --version 2>/dev/null | '
        "sed -n 's/.*\\([0-9][0-9]*\\.[0-9][0-9]*\\.[0-9][0-9]*\\).*/\\1/p' "
        '2>/dev/null | head -n1 || true)"; '
        "fi; "
        f'HELPER="{server_paths.railpack_build_helper()}"; '
        f"ENV_FILE={quoted_railpack_root}/railpack.env; "
        'kv railpack_version "$RAILPACK_VERSION"; '
        'if [ -x "$HELPER" ]; then kv helper_present 1; else kv helper_present 0; fi; '
        f'if [ -f "$HELPER" ] && grep -Fq {quoted_frontend_image} "$HELPER" '
        f'&& grep -Fq {quoted_frontend_digest} "$HELPER"; then '
        "kv helper_current 1; else kv helper_current 0; fi; "
        'if [ -f "$ENV_FILE" ]; then kv env_present 1; else kv env_present 0; fi; '
        f'if [ -f "$ENV_FILE" ] && grep -Fq {quoted_env_line} "$ENV_FILE" '
        f'&& grep -Fq {quoted_env_digest_line} "$ENV_FILE"; then '
        "kv env_current 1; else kv env_current 0; fi; "
        'DOCKER_VERSION=""; '
        "if command -v docker >/dev/null 2>&1; then "
        'DOCKER_VERSION="$(docker --version 2>/dev/null | sed -n "s/.*version \\([^, ]*\\).*/\\1/p" | head -n1 || true)"; '
        "fi; "
        'kv docker_version "$DOCKER_VERSION"; '
        'kv docker_ce_version "$(pkg docker-ce)"; '
        'kv docker_ce_cli_version "$(pkg docker-ce-cli)"; '
        'COMPOSE_VERSION=""; '
        "if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then "
        'COMPOSE_VERSION="$(docker compose version --short 2>/dev/null || docker compose version 2>/dev/null | head -n1 || true)"; '
        "elif command -v docker-compose >/dev/null 2>&1; then "
        'COMPOSE_VERSION="$(docker-compose --version 2>/dev/null | sed -n "s/.*version \\([^, ]*\\).*/\\1/p" | head -n1 || true)"; '
        "fi; "
        'kv docker_compose_version "$COMPOSE_VERSION"; '
        'kv docker_compose_plugin_version "$(pkg docker-compose-plugin)"; '
        'kv containerd_version "$(pkg containerd.io)"; '
        f"{_docker_patch_probe_shell()}"
        'DOCKER_DAEMON="/etc/docker/daemon.json"; '
        'if [ -f "$DOCKER_DAEMON" ]; then kv docker_daemon_config_present 1; else kv docker_daemon_config_present 0; fi; '
        'if [ -f "$DOCKER_DAEMON" ] && grep -Fq \'"max-size": "10m"\' "$DOCKER_DAEMON" && grep -Fq \'"max-file": "3"\' "$DOCKER_DAEMON"; then '
        "kv docker_daemon_config_current 1; else kv docker_daemon_config_current 0; fi; "
        f"HTTP_STACK={quoted_http_stack}; "
        'HTTP_COMPOSE="${HTTP_STACK}/docker-compose.yml"; '
        f'CADDY_HELPER="{server_paths.caddy_apply_helper()}"; '
        'if [ -f "$HTTP_COMPOSE" ]; then kv caddy_stack_present 1; else kv caddy_stack_present 0; fi; '
        'kv caddy_compose_image "$(first_image "$HTTP_COMPOSE")"; '
        'kv caddy_base_label "$(docker image inspect -f '
        f"'{{{{index .Config.Labels \"{server_identifiers.LABEL_CADDY_BASE}\"}}}}' "
        f"{shlex.quote(server_identifiers.caddy_custom_image())} "
        '2>/dev/null || true)"; '
        f'if [ -f "$HTTP_COMPOSE" ] && grep -Fq {quoted_caddy_image} "$HTTP_COMPOSE"; then kv caddy_image_current 1; else kv caddy_image_current 0; fi; '
        f"{container_status_kv_shell('caddy_container', quoted_caddy_container)}; "
        'CADDY_READINESS_STATUS=not_checked; CADDY_READINESS_DETAIL=""; '
        f"if {caddy_service_readiness_check_shell(quoted_caddy_container)}; then "
        "CADDY_READINESS_STATUS=ready; "
        "else "
        "CADDY_READINESS_STATUS=unhealthy; "
        "CADDY_READINESS_DETAIL='caddy validate failed'; "
        "fi; "
        'kv caddy_container_readiness_status "$CADDY_READINESS_STATUS"; '
        'kv caddy_container_readiness_detail "$CADDY_READINESS_DETAIL"; '
        'if [ -x "$CADDY_HELPER" ]; then kv caddy_helper_present 1; else kv caddy_helper_present 0; fi; '
        'if [ -f "$CADDY_HELPER" ] && grep -Fq "caddy reload" "$CADDY_HELPER"; then kv caddy_helper_current 1; else kv caddy_helper_current 0; fi; '
        f"DNS_STACK={quoted_dns_stack}; "
        'DNS_COMPOSE="${DNS_STACK}/docker-compose.yml"; '
        'if [ -f "$DNS_COMPOSE" ]; then kv bind_stack_present 1; else kv bind_stack_present 0; fi; '
        'kv bind_compose_image "$(image_for_service bind9 "$DNS_COMPOSE")"; '
        f'if [ -f "$DNS_COMPOSE" ] && grep -Fq {quoted_bind_image} "$DNS_COMPOSE"; then kv bind_image_current 1; else kv bind_image_current 0; fi; '
        f"{container_status_kv_shell('bind_container', quoted_bind_container)}; "
        'BIND_READINESS_STATUS=not_checked; BIND_READINESS_DETAIL=""; '
        f"if {bind_service_readiness_check_shell(quoted_bind_container)}; then "
        "BIND_READINESS_STATUS=ready; "
        "else "
        "BIND_READINESS_STATUS=unhealthy; "
        "BIND_READINESS_DETAIL='named process or config check failed'; "
        "fi; "
        'kv bind_container_readiness_status "$BIND_READINESS_STATUS"; '
        'kv bind_container_readiness_detail "$BIND_READINESS_DETAIL"; '
        f"POSTGRES_STACK={quoted_postgres_stack}; "
        'POSTGRES_COMPOSE="${POSTGRES_STACK}/docker-compose.yml"; '
        'if [ -f "$POSTGRES_COMPOSE" ]; then kv postgres_stack_present 1; else kv postgres_stack_present 0; fi; '
        'kv postgres_compose_image "$(first_image "$POSTGRES_COMPOSE")"; '
        f"{container_status_kv_shell('postgres_container', quoted_postgres_container)}; "
        'POSTGRES_READINESS_STATUS=not_checked; POSTGRES_READINESS_DETAIL=""; '
        f"POSTGRES_USER={quoted_postgres_superuser}; "
        f"if [ -f {quoted_postgres_env_file} ]; then "
        'POSTGRES_USER="$(awk -F= \'/^POSTGRES_USER=/ {print substr($0, index($0, "=")+1); exit}\' '
        f'{quoted_postgres_env_file} 2>/dev/null || true)"; '
        f'[ -n "$POSTGRES_USER" ] || POSTGRES_USER={quoted_postgres_superuser}; '
        "fi; "
        f"if {postgres_service_readiness_check_shell(quoted_postgres_container, postgres_user_ref)}; then "
        "POSTGRES_READINESS_STATUS=ready; "
        "else "
        "POSTGRES_READINESS_STATUS=unhealthy; "
        "POSTGRES_READINESS_DETAIL='pg_isready failed'; "
        "fi; "
        'kv postgres_container_readiness_status "$POSTGRES_READINESS_STATUS"; '
        'kv postgres_container_readiness_detail "$POSTGRES_READINESS_DETAIL"; '
        'WALG_VERSION_RAW=""; '
        "if command -v wal-g >/dev/null 2>&1; then "
        'WALG_VERSION_RAW="$(wal-g --version 2>&1 | tr "\\r\\n" "  " | head -c 500 || true)"; '
        "fi; "
        'kv walg_version_raw "$WALG_VERSION_RAW"; '
        'kv fail2ban_version "$(pkg fail2ban)"; '
        'kv auditd_version "$(pkg auditd)"; '
        'kv unattended_upgrades_version "$(pkg unattended-upgrades)"; '
        'kv sysstat_version "$(pkg sysstat)"; '
        'AUTO_FILE="/etc/apt/apt.conf.d/20auto-upgrades"; '
        'if [ -f "$AUTO_FILE" ] && grep -Fq \'APT::Periodic::Unattended-Upgrade "1"\' "$AUTO_FILE"; then kv unattended_upgrades_enabled 1; else kv unattended_upgrades_enabled 0; fi'
    )


def _tooling_status_from_payload(payload):
    railpack_version = payload.get("railpack_version", "")
    helper_present = payload.get("helper_present") == "1"
    helper_current = payload.get("helper_current") == "1"
    env_present = payload.get("env_present") == "1"
    env_current = payload.get("env_current") == "1"

    return {
        "railpack": _tooling_component(
            label="Railpack CLI",
            current=railpack_version,
            target=RAILPACK_VERSION_NUMBER,
            current_flag=railpack_version == RAILPACK_VERSION_NUMBER,
            update_action="Install pinned Railpack CLI",
        ),
        "railpack_build_helper": _tooling_component(
            label="Railpack build helper",
            current="installed" if helper_present else "",
            target=RAILPACK_FRONTEND_IMAGE,
            current_flag=helper_present and helper_current,
            update_action="Install Deploy Dash build helper",
        ),
        "railpack_defaults": _tooling_component(
            label="Railpack defaults",
            current="installed" if env_present else "",
            target=f"RAILPACK_FRONTEND_IMAGE={RAILPACK_FRONTEND_IMAGE}",
            current_flag=env_present and env_current,
            update_action="Write Deploy Dash build defaults",
        ),
    }


def _server_capabilities_from_payload(payload):
    railpack_details = list(_tooling_status_from_payload(payload).values())
    railpack_status = _details_status(railpack_details)

    docker_details = [
        _capability_detail(
            label="Docker engine",
            current=payload.get("docker_version", ""),
            target="Installed",
            current_flag=bool(payload.get("docker_version")),
        ),
        _capability_detail(
            label="Docker Compose plugin",
            current=payload.get("docker_compose_version", ""),
            target="Installed",
            current_flag=bool(payload.get("docker_compose_version")),
        ),
        _capability_detail(
            label="containerd runtime",
            current=payload.get("containerd_version", ""),
            target="Installed",
            current_flag=bool(payload.get("containerd_version")),
        ),
        _capability_detail(
            label="Docker log rotation",
            current=("configured" if payload.get("docker_daemon_config_present") == "1" else ""),
            target="json-file logs capped at 10m x 3 files",
            current_flag=payload.get("docker_daemon_config_current") == "1",
        ),
    ]

    caddy_image = CANONICAL_HTTP_SETTINGS["caddy_image"]
    caddy_details = [
        _stack_image_detail(
            payload,
            "caddy_compose_image",
            "Caddy image",
            caddy_image,
        ),
        _capability_detail(
            label="HTTP gateway stack",
            current=("installed" if payload.get("caddy_stack_present") == "1" else ""),
            target=CANONICAL_HTTP_SETTINGS["stack_root"],
            current_flag=payload.get("caddy_stack_present") == "1",
        ),
        _capability_detail(
            label="Gateway apply helper",
            current=("installed" if payload.get("caddy_helper_present") == "1" else ""),
            target=server_paths.caddy_apply_helper(),
            current_flag=payload.get("caddy_helper_current") == "1",
        ),
    ]

    postgres_image = payload.get("postgres_compose_image", "")
    postgres_configured = (
        payload.get("postgres_stack_present") == "1"
        or payload.get("postgres_container_present") == "1"
    )
    postgres_target = (
        f"Managed PostgreSQL {CANONICAL_POSTGRES_SETTINGS['postgres_version']} service"
    )
    postgres_container_status = container_status_from_payload(
        payload,
        "postgres_container",
    )
    postgres_effective_status = postgres_container_status["effective_status"]
    postgres_details = [
        _capability_detail(
            label="Service image",
            current=postgres_image,
            target=postgres_target,
            status="not_configured" if not postgres_configured else None,
            current_flag=(
                postgres_image.startswith(
                    f"{server_identifiers.POSTGRES_EXTENSION_IMAGE_REPOSITORY}:"
                )
                if postgres_configured
                else None
            ),
        ),
        _capability_detail(
            label="Compose stack",
            current=("installed" if payload.get("postgres_stack_present") == "1" else ""),
            target=CANONICAL_POSTGRES_SETTINGS["stack_root"],
            status="not_configured" if not postgres_configured else None,
            current_flag=payload.get("postgres_stack_present") == "1",
        ),
        _capability_detail(
            label="Container state",
            current=postgres_effective_status.replace("_", " "),
            target="Ready when PostgreSQL is enabled",
            status="not_configured" if not postgres_configured else None,
            current_flag=postgres_effective_status == "ready",
        ),
    ]

    security_details = [
        _package_detail(payload, "fail2ban", "fail2ban"),
        _package_detail(payload, "auditd", "auditd"),
        _package_detail(payload, "unattended_upgrades", "unattended upgrades"),
        _package_detail(payload, "sysstat", "sysstat"),
    ]

    ubuntu_details = [
        _capability_detail(
            label="Automatic security updates",
            current=("enabled" if payload.get("unattended_upgrades_enabled") == "1" else ""),
            target="Enabled",
            current_flag=payload.get("unattended_upgrades_enabled") == "1",
        ),
        _package_detail(payload, "unattended_upgrades", "unattended-upgrades"),
    ]

    capabilities = {
        "railpack_build_system": _capability(
            capability_id="railpack_build_system",
            category="Build and deployment",
            label="Railpack build system",
            description=(
                "Builds web app images from source repositories with one managed Railpack contract."
            ),
            status=railpack_status,
            summary=(
                f"Target Railpack {RAILPACK_VERSION_NUMBER}"
                if railpack_status != "current"
                else f"Railpack {RAILPACK_VERSION_NUMBER}"
            ),
            details=railpack_details,
            can_update=railpack_status != "current",
            action_label="Update Railpack build system",
        ),
        "docker_runtime": _capability(
            capability_id="docker_runtime",
            category="Build and deployment",
            label="Docker runtime",
            description="Runs app, gateway, and database containers.",
            status=_details_status(docker_details),
            summary="Docker engine, Compose plugin, and containerd",
            details=docker_details,
        ),
        "http_gateway": _capability(
            capability_id="http_gateway",
            category="Traffic",
            label="HTTP gateway",
            description="Routes HTTP and HTTPS traffic through the managed Caddy stack.",
            status=_details_status(caddy_details),
            summary=f"Target Caddy image {caddy_image}",
            details=caddy_details,
        ),
        "postgresql_database_service": _capability(
            capability_id="postgresql_database_service",
            category="Databases",
            label="PostgreSQL database service",
            description="Managed PostgreSQL service, extensions, roles, and backups.",
            status=_details_status(
                postgres_details,
                not_configured=not postgres_configured,
            ),
            summary=(
                "Not enabled on this server"
                if not postgres_configured
                else "Managed PostgreSQL stack"
            ),
            details=postgres_details,
        ),
        "server_security_baseline": _capability(
            capability_id="server_security_baseline",
            category="Server maintenance",
            label="Server security baseline",
            description="Security and diagnostics packages installed during onboarding.",
            status=_details_status(security_details),
            summary="fail2ban, auditd, sysstat, unattended upgrades",
            details=security_details,
        ),
        "ubuntu_system_packages": _capability(
            capability_id="ubuntu_system_packages",
            category="Server maintenance",
            label="Ubuntu system packages",
            description="Ubuntu package updates managed by apt and unattended upgrades.",
            status=_details_status(ubuntu_details),
            summary="Security updates handled by Ubuntu unattended upgrades",
            details=ubuntu_details,
        ),
    }
    return capabilities


def _capability_update_available(capabilities):
    return any(
        capability.get("can_update") is True and capability.get("status") != "current"
        for capability in capabilities.values()
    )


def _tooling_update_available(tooling):
    return any(component.get("status") != "current" for component in tooling.values())


def _stdout_text(output):
    stdout_lines = getattr(output, "stdout_lines", None) or []
    return "\n".join(str(line) for line in stdout_lines)


def _read_remote_software_ledger(ctx, session, emit=None):
    quoted_path = shlex.quote(MANAGED_SOFTWARE_LEDGER_PATH)
    result = run_shell_command(
        session.host,
        f"if [ -f {quoted_path} ]; then cat {quoted_path}; fi",
        timeout=20,
        sudo=True,
        emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
    )
    if not result["ok"]:
        return empty_software_ledger()
    return parse_software_ledger(_stdout_text(result["output"]))


def _write_remote_software_ledger(ctx, session, ledger, emit=None):
    return write_remote_text_file(
        session.host,
        path=MANAGED_SOFTWARE_LEDGER_PATH,
        content=encode_software_ledger(ledger),
        mode="600",
        timeout=20,
        sudo=True,
        emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
    )


def _software_ledger_write_error(ctx, result, message):
    """Turn a failed durable ledger write into a structured mutation error."""
    if not isinstance(result, dict) or result.get("ok") is not False:
        return None
    return ctx.error_result(
        "ENGINE_RUNTIME_ERROR",
        message,
        stage="execute_runtime_operation",
        details=result.get("details") or "managed-software ledger write failed",
    )


def _backup_dir(component_id, timestamp):
    # PostgreSQL backups are filed under "postgres" rather than the component
    # id. Pre-existing behaviour, preserved deliberately: changing it would
    # orphan the backups already taken on any server provisioned before this.
    if component_id == "postgresql_database_service":
        return server_paths.upgrade_backup_dir("postgres", timestamp)
    return server_paths.upgrade_backup_dir(component_id, timestamp)


def _private_backup_dir_command(backup_dir):
    """Create one root-owned backup directory without an exposure window."""
    quoted_backup = shlex.quote(backup_dir)
    return f"umask 077; install -d -m 700 {quoted_backup}; chown root:root {quoted_backup}"


def _managed_backup_hygiene_command():
    """Tighten every legacy managed-update snapshot before a mutation."""
    quoted_root = shlex.quote(server_paths.upgrade_backups_root())
    return (
        "set -eu; umask 077; "
        f"install -d -m 700 {quoted_root}; "
        f"chown -R root:root {quoted_root}; "
        f"find {quoted_root} -type d -exec chmod 700 {{}} +; "
        f"find {quoted_root} -type f -exec chmod 600 {{}} +"
    )


def _managed_backup_service_dirs(component_id):
    """Return every legacy and current backup namespace owned by a component."""
    service_names = (
        ("postgres", "postgresql_database_service")
        if component_id == "postgresql_database_service"
        else (component_id,)
    )
    return tuple(server_paths.upgrade_backup_service_dir(name) for name in service_names)


def _managed_backup_retention_command(component_id, *, protected_backup_dir):
    """Keep a bounded snapshot set while always retaining the ledger target."""
    service_dirs = " ".join(
        shlex.quote(path) for path in _managed_backup_service_dirs(component_id)
    )
    protected = shlex.quote(str(protected_backup_dir or ""))
    limit = MANAGED_BACKUP_RETENTION_LIMIT
    return (
        "set -eu; umask 077; "
        f"PROTECTED={protected}; LIMIT={limit}; "
        'CANDIDATES="$(mktemp)"; RETAINED="$(mktemp)"; '
        'trap \'rm -f "$CANDIDATES" "$RETAINED"\' EXIT; '
        f"for SERVICE_DIR in {service_dirs}; do "
        '[ -d "$SERVICE_DIR" ] || continue; '
        'find "$SERVICE_DIR" -mindepth 1 -maxdepth 1 -type d '
        "-printf '%T@ %p\\n' >> \"$CANDIDATES\"; done; "
        'if [ -n "$PROTECTED" ] && [ -d "$PROTECTED" ]; then '
        'printf \'%s\\n\' "$PROTECTED" >> "$RETAINED"; fi; '
        'sort -nr "$CANDIDATES" | while IFS=" " read -r _ BACKUP_DIR; do '
        '[ -n "$BACKUP_DIR" ] || continue; '
        'if grep -Fqx -- "$BACKUP_DIR" "$RETAINED"; then continue; fi; '
        'RETAINED_COUNT="$(wc -l < "$RETAINED" | tr -d \' \')"; '
        'if [ "$RETAINED_COUNT" -lt "$LIMIT" ]; then '
        'printf \'%s\\n\' "$BACKUP_DIR" >> "$RETAINED"; '
        'else rm -rf -- "$BACKUP_DIR"; '
        "printf 'removed_upgrade_backup=%s\\n' \"$BACKUP_DIR\"; fi; done; "
        "while IFS= read -r BACKUP_DIR; do "
        '[ -d "$BACKUP_DIR" ] || continue; '
        'BACKUP_BYTES="$(du -sb "$BACKUP_DIR" | awk \'{print $1}\')"; '
        "printf 'retained_upgrade_backup=%s\\t%s\\n' "
        '"$BACKUP_DIR" "$BACKUP_BYTES"; done < "$RETAINED"; '
        'rm -f "$CANDIDATES" "$RETAINED"; trap - EXIT'
    )


def _parse_managed_backup_retention_output(output):
    """Decode the retained path and byte records emitted by the pruning shell."""
    retained = []
    seen = set()
    for raw_line in getattr(output, "stdout_lines", None) or []:
        parsed = shell_output.split_key_value(raw_line)
        if parsed is None or parsed[0] != "retained_upgrade_backup":
            continue
        path, separator, raw_bytes = parsed[1].rpartition("\t")
        if not separator or not path or path in seen:
            continue
        try:
            size_bytes = int(raw_bytes)
        except (TypeError, ValueError):
            continue
        if size_bytes < 0:
            continue
        seen.add(path)
        retained.append({"path": path, "size_bytes": size_bytes})
    return retained


_POSTGRES_MANAGED_IMAGE_PATTERN = (
    rf"^{re.escape(server_identifiers.POSTGRES_EXTENSION_IMAGE_REPOSITORY)}:"
    r"(?P<major>16|17|18)"
    r"(?:\.[^-]+)?"
    r"-bookworm"
    r"(?:-(?P<variant>[a-z0-9-]+))?$"
)


def _postgres_compose_image_rewriter_script():
    """Own the remote PostgreSQL image rewrite for update and rollback.

    Both mutations must identify the image inside the postgres service without
    disturbing later storage, TLS, or port changes. Rollback additionally
    refuses a stale image from another major before it writes anything.
    """
    repository = server_identifiers.POSTGRES_EXTENSION_IMAGE_REPOSITORY
    return f"""import json, pathlib, re, shlex, sys
compose = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
image_pattern = sys.argv[3]
payload = sys.argv[4]
lines = compose.read_text().splitlines()
image_index = None
current = ""
in_postgres = False
service_indent = None
for index, line in enumerate(lines):
    stripped = line.strip()
    if re.match(r"^postgres:\\s*$", stripped):
        in_postgres = True
        service_indent = len(line) - len(line.lstrip())
        continue
    if in_postgres and stripped.endswith(":") and (len(line) - len(line.lstrip())) <= service_indent:
        in_postgres = False
    if in_postgres and stripped.startswith("image:"):
        image_index = index
        current = stripped.split(":", 1)[1].strip()
        break
if image_index is None:
    raise SystemExit("PostgreSQL compose image was not found.")
match = re.match(image_pattern, current)
if not match:
    raise SystemExit(f"Unsupported PostgreSQL image for managed mutation: {{current}}")
major = match.group("major")
variant = match.group("variant") or "base"
base = ""
if mode == "update":
    tag_map = json.loads(payload)
    target_tag = tag_map[major]
    target = f"{repository}:{{target_tag}}-{{variant}}"
    base = f"postgres:{{target_tag}}"
elif mode == "rollback":
    target = payload
    target_match = re.match(image_pattern, target)
    if not target_match:
        raise SystemExit(f"Unsupported previous PostgreSQL image: {{target}}")
    if target_match.group("major") != major:
        raise SystemExit(
            "PostgreSQL major version changed after this rollback snapshot; "
            "rollback is disabled to protect the live data volume."
        )
else:
    raise SystemExit(f"Unsupported PostgreSQL image mutation mode: {{mode}}")
if current == target:
    print("POSTGRES_ALREADY_CURRENT=1")
else:
    indent = lines[image_index][:len(lines[image_index]) - len(lines[image_index].lstrip())]
    lines[image_index] = f"{{indent}}image: {{target}}"
    compose.write_text("\\n".join(lines) + "\\n")
    print("POSTGRES_ALREADY_CURRENT=0")
for key, value in {{
    "POSTGRES_CURRENT_IMAGE": current,
    "POSTGRES_TARGET_IMAGE": target,
    "POSTGRES_BASE_IMAGE": base,
    "POSTGRES_MAJOR": major,
    "POSTGRES_VARIANT": variant,
}}.items():
    print(f"{{key}}={{shlex.quote(value)}}")"""


def _postgres_managed_update_target(current_image):
    current = str(current_image or "").strip()
    match = re.match(_POSTGRES_MANAGED_IMAGE_PATTERN, current)
    if not match:
        raise ValueError(f"Unsupported PostgreSQL image for managed update: {current}")
    major = match.group("major")
    variant = match.group("variant") or "base"
    target_tag = POSTGRES_IMAGE_TAGS_BY_MAJOR[major]
    return {
        "current": current,
        "target": server_identifiers.postgres_extension_image(target_tag, variant),
        "base": f"postgres:{target_tag}",
        "major": major,
        "variant": variant,
    }


def _managed_postgres_update_command(*, backup_dir):
    quoted_backup = shlex.quote(backup_dir)
    private_backup_dir = _private_backup_dir_command(backup_dir)
    stack = shlex.quote(CANONICAL_POSTGRES_SETTINGS["stack_root"])
    container_name = shlex.quote(CANONICAL_POSTGRES_SETTINGS["container_name"])
    superuser_name = shlex.quote(CANONICAL_POSTGRES_SETTINGS["superuser_name"])
    tag_map = shlex.quote(json.dumps(POSTGRES_IMAGE_TAGS_BY_MAJOR, sort_keys=True))
    image_pattern = shlex.quote(_POSTGRES_MANAGED_IMAGE_PATTERN)
    dockerfiles = shlex.quote(
        json.dumps(postgres_extension_image_dockerfiles_by_variant(), sort_keys=True),
    )
    image_rewriter = _postgres_compose_image_rewriter_script()
    return f"""set -eu
{private_backup_dir}
COMPOSE={stack}/docker-compose.yml
ENV_FILE={stack}/.env
[ -f "${{COMPOSE}}" ] || (echo 'PostgreSQL service is not configured.' >&2; exit 1)
[ -f "${{ENV_FILE}}" ] || (echo 'PostgreSQL environment file is missing.' >&2; exit 1)
cp -a "${{COMPOSE}}" {quoted_backup}/docker-compose.yml
docker inspect {container_name} >/dev/null 2>&1 || (echo 'PostgreSQL container is not available for rollback backup.' >&2; exit 1)
{postgres_service_readiness_check_shell(container_name, superuser_name)} || (echo 'PostgreSQL service must be ready before upgrade.' >&2; exit 1)
docker exec {container_name} pg_dumpall -U {superuser_name} > {quoted_backup}/pg_dumpall.sql
test -s {quoted_backup}/pg_dumpall.sql
POSTGRES_ENV_OUTPUT="$(python3 - "$COMPOSE" update {image_pattern} {tag_map} <<'PY'
{image_rewriter}
PY
)" || exit 1
eval "$POSTGRES_ENV_OUTPUT"
if [ "${{POSTGRES_ALREADY_CURRENT}}" != 1 ] && ! docker image inspect "${{POSTGRES_TARGET_IMAGE}}" >/dev/null 2>&1; then
  BUILD_DIR="$(mktemp -d)"
  cleanup_pg_build(){{ rm -rf "${{BUILD_DIR}}" >/dev/null 2>&1 || true; }}
  trap cleanup_pg_build EXIT INT TERM
  POSTGRES_DOCKERFILES_JSON={dockerfiles} \\
  POSTGRES_VARIANT="${{POSTGRES_VARIANT}}" \\
  python3 - "${{BUILD_DIR}}/Dockerfile" <<'PY'
import json, os, pathlib, sys
path = pathlib.Path(sys.argv[1])
variant = os.environ["POSTGRES_VARIANT"]
dockerfiles = json.loads(os.environ["POSTGRES_DOCKERFILES_JSON"])
try:
    body = dockerfiles[variant]
except KeyError:
    raise SystemExit(f"Unsupported PostgreSQL extension image variant: {{variant}}")
path.write_text(body)
PY
  docker build --pull --build-arg BASE_IMAGE="${{POSTGRES_BASE_IMAGE}}" --build-arg PG_MAJOR="${{POSTGRES_MAJOR}}" -t "${{POSTGRES_TARGET_IMAGE}}" "${{BUILD_DIR}}"
fi
docker compose -f "$COMPOSE" config >/dev/null
docker compose -f "$COMPOSE" up -d --remove-orphans
POSTGRES_USER="$(awk -F= '/^POSTGRES_USER=/ {{print substr($0, index($0, "=")+1); exit}}' "$ENV_FILE")"
[ -n "$POSTGRES_USER" ] || POSTGRES_USER={superuser_name}
{postgres_service_readiness_wait_shell(container_name, '"$POSTGRES_USER"')}
docker inspect -f '{{{{.Config.Image}}}}' {container_name} | grep -Fx "$POSTGRES_TARGET_IMAGE" >/dev/null
docker exec {container_name} psql -U "$POSTGRES_USER" postgres -c '\\l' >/dev/null
docker exec {container_name} psql -U "$POSTGRES_USER" postgres -c '\\du' >/dev/null"""


def _managed_railpack_update_command(*, backup_dir):
    quoted_backup = shlex.quote(backup_dir)
    quoted_stack = shlex.quote(RAILPACK_STACK_ROOT)
    return (
        "set -eu; "
        f"{_private_backup_dir_command(backup_dir)}; "
        "[ ! -f /usr/local/bin/railpack ] || "
        f"cp -a /usr/local/bin/railpack {quoted_backup}/railpack; "
        f"[ ! -f {server_paths.railpack_build_helper()} ] || "
        f"cp -a {server_paths.railpack_build_helper()} "
        f"{quoted_backup}/{_RAILPACK_HELPER_NAME}; "
        f"[ ! -f {quoted_stack}/railpack.env ] || "
        f"cp -a {quoted_stack}/railpack.env {quoted_backup}/railpack.env"
    )


def _managed_caddy_rebuild_command(*, backup_dir):
    quoted_backup = shlex.quote(backup_dir)
    stack = shlex.quote(CANONICAL_HTTP_SETTINGS["stack_root"])
    container_name = shlex.quote(CANONICAL_HTTP_SETTINGS["container_name"])
    base_image = shlex.quote(CANONICAL_HTTP_SETTINGS["caddy_image"])
    builder_image = shlex.quote(caddy_builder_image(CANONICAL_HTTP_SETTINGS["caddy_image"]))
    custom_image = shlex.quote(server_identifiers.caddy_custom_image())
    previous_image = shlex.quote(server_identifiers.caddy_custom_previous_image())
    label_key = server_identifiers.LABEL_CADDY_BASE
    return (
        "set -eu; "
        f"{_private_backup_dir_command(backup_dir)}; "
        f"COMPOSE={stack}/docker-compose.yml; "
        f"DOCKERFILE={stack}/caddy/Dockerfile; "
        f"[ -f \"${{COMPOSE}}\" ] || (echo 'HTTP gateway is not configured.' >&2; exit 1); "
        f"[ -f \"${{DOCKERFILE}}\" ] || (echo 'Custom Caddy Dockerfile is missing.' >&2; exit 1); "
        f"grep -Fq 'image: {custom_image}' \"${{COMPOSE}}\" || (echo 'Custom Caddy image line is missing.' >&2; exit 1); "
        f"grep -q '^ *build:' \"${{COMPOSE}}\" || (echo 'Custom Caddy build section is missing.' >&2; exit 1); "
        f'cp -a "${{COMPOSE}}" {quoted_backup}/docker-compose.yml; '
        f"[ ! -f {stack}/caddy/Caddyfile ] || cp -a {stack}/caddy/Caddyfile {quoted_backup}/Caddyfile; "
        f'cp -a "${{DOCKERFILE}}" {quoted_backup}/Dockerfile; '
        'python3 - "$DOCKERFILE" '
        f"{builder_image} {base_image} {label_key} <<'PY'\n"
        "import pathlib, sys\n"
        "path = pathlib.Path(sys.argv[1])\n"
        "builder, base, label_key = sys.argv[2], sys.argv[3], sys.argv[4]\n"
        "lines = path.read_text().splitlines()\n"
        "out = []\n"
        "replaced_builder = replaced_base = False\n"
        "label_line = f'LABEL {label_key}=\"{base}\"'\n"
        "for line in lines:\n"
        "    stripped = line.strip()\n"
        '    if stripped.startswith("FROM ") and stripped.endswith(" AS builder"):\n'
        '        out.append(f"FROM {builder} AS builder")\n'
        "        replaced_builder = True\n"
        "        continue\n"
        '    if stripped.startswith("FROM "):\n'
        '        out.append(f"FROM {base}")\n'
        "        out.append(label_line)\n"
        "        replaced_base = True\n"
        "        continue\n"
        '    if stripped.startswith("LABEL "):\n'
        '        rest = stripped[len("LABEL "):]\n'
        '        if rest == label_key or rest.startswith(label_key + "=") or rest.startswith(label_key + " "):\n'
        "            continue\n"
        "    out.append(line)\n"
        "if not replaced_builder or not replaced_base:\n"
        '    raise SystemExit("Custom Caddy Dockerfile has an unexpected shape.")\n'
        'path.write_text("\\n".join(out) + "\\n")\n'
        "PY\n"
        f"if docker image inspect {custom_image} >/dev/null 2>&1; then docker tag {custom_image} {previous_image}; fi; "
        "restore_caddy_snapshot(){ "
        f'cp -a {quoted_backup}/docker-compose.yml "${{COMPOSE}}"; '
        f'cp -a {quoted_backup}/Dockerfile "${{DOCKERFILE}}"; '
        f"if docker image inspect {previous_image} >/dev/null 2>&1; then docker tag {previous_image} {custom_image}; fi; "
        "}; "
        "resurrect_caddy(){ restore_caddy_snapshot; "
        'docker compose -f "$COMPOSE" up -d --remove-orphans; '
        "}; "
        "docker compose -f \"$COMPOSE\" build --pull || (restore_caddy_snapshot; echo 'Custom Caddy rebuild failed; stack left unchanged.' >&2; exit 1); "
        "docker compose -f \"$COMPOSE\" up -d --remove-orphans || (resurrect_caddy >/dev/null 2>&1 || true; echo 'Custom Caddy update failed after rebuild; previous build restored.' >&2; exit 1); "
        f"{caddy_service_readiness_check_shell(container_name)} || (resurrect_caddy >/dev/null 2>&1 || true; echo 'Custom Caddy update failed readiness; previous build restored.' >&2; exit 1); "
        "MODULES_OK=1; for PROVIDER in $(grep -o 'caddy-dns/[a-z][a-z0-9]*' \"$DOCKERFILE\" | cut -d/ -f2 | sort -u); do "
        f'docker exec {container_name} caddy list-modules 2>/dev/null | grep -q "dns.providers.${{PROVIDER}}" || MODULES_OK=0; done; '
        "[ \"$MODULES_OK\" = 1 ] || (resurrect_caddy >/dev/null 2>&1 || true; echo 'Custom Caddy build is missing provider modules; previous build restored.' >&2; exit 1)"
    )


def _docker_patch_install_command():
    """Install newest in-series Docker patches while restoring every package hold."""
    package_names = " ".join(DOCKER_PACKAGE_PAYLOAD_KEYS)
    package_series = " ".join(
        f"{name}={docker_package_patch_series(version)}"
        for name, version in platform_versions.DOCKER_PACKAGE_VERSION_PREFIXES.items()
    )
    managed_label = shlex.quote(server_identifiers.MANAGED_LABEL_PAIR)
    return (
        "set -eu; "
        f"DOCKER_PACKAGE_SERIES={shlex.quote(package_series)}; "
        f"DOCKER_PACKAGE_NAMES={shlex.quote(package_names)}; "
        f'RUNNING_MANAGED_CONTAINERS="$(docker ps --filter label={managed_label} '
        "--format '{{.ID}}')\"; "
        "restore_docker_holds(){ apt-mark hold ${DOCKER_PACKAGE_NAMES} "
        ">/dev/null 2>&1 || true; }; "
        "trap restore_docker_holds EXIT INT TERM; "
        'PACKAGE_SPECS=""; '
        "for PACKAGE_SERIES_SPEC in ${DOCKER_PACKAGE_SERIES}; do "
        'PACKAGE="${PACKAGE_SERIES_SPEC%%=*}"; '
        'SERIES="${PACKAGE_SERIES_SPEC#*=}"; BEST=""; '
        'for VERSION in $(apt-cache madison "${PACKAGE}" 2>/dev/null | '
        "awk '{print $3}'); do "
        'case "${VERSION}" in "${SERIES}"[0-9]*) '
        'if [ -z "${BEST}" ] || dpkg --compare-versions "${VERSION}" gt "${BEST}"; '
        'then BEST="${VERSION}"; fi ;; esac; done; '
        '[ -n "${BEST}" ] || (echo "No package in the supported series for ${PACKAGE}." '
        ">&2; exit 1); "
        'PACKAGE_SPECS="${PACKAGE_SPECS} ${PACKAGE}=${BEST}"; '
        "done; "
        "apt-mark unhold ${DOCKER_PACKAGE_NAMES} >/dev/null 2>&1 || true; "
        f"{apt_runtime.apt_get_command('install -y --allow-change-held-packages --allow-downgrades ${PACKAGE_SPECS}')}; "
        "apt-mark hold ${DOCKER_PACKAGE_NAMES} >/dev/null; "
        "trap - EXIT INT TERM; "
        "for SPEC in ${PACKAGE_SPECS}; do "
        'test "$(dpkg-query -W -f=\'${Version}\' "${SPEC%%=*}")" = "${SPEC#*=}"; '
        "done; "
        "systemctl restart docker; "
        "docker ps >/dev/null; "
        "containerd --version >/dev/null; "
        "docker compose version >/dev/null; "
        "for CONTAINER_ID in ${RUNNING_MANAGED_CONTAINERS}; do "
        "docker inspect -f '{{.State.Running}}' \"${CONTAINER_ID}\" | "
        "grep -Fx true >/dev/null; "
        "done"
    )


def _managed_update_command(component_id, *, backup_dir, caddy_compose_image=""):
    quoted_backup = shlex.quote(backup_dir)
    if component_id == "railpack_build_system":
        return _managed_railpack_update_command(backup_dir=backup_dir)

    if component_id == "http_gateway":
        # A custom (DNS-plugin) stack names the local build: it updates by
        # rebuilding, never by rewriting the image line to stock (#91).
        if str(caddy_compose_image or "").strip() == server_identifiers.caddy_custom_image():
            return _managed_caddy_rebuild_command(backup_dir=backup_dir)
        target = shlex.quote(CANONICAL_HTTP_SETTINGS["caddy_image"])
        stack = shlex.quote(CANONICAL_HTTP_SETTINGS["stack_root"])
        container_name = shlex.quote(CANONICAL_HTTP_SETTINGS["container_name"])
        return (
            "set -eu; "
            f"{_private_backup_dir_command(backup_dir)}; "
            f"COMPOSE={stack}/docker-compose.yml; "
            f"[ -f \"${{COMPOSE}}\" ] || (echo 'HTTP gateway is not configured.' >&2; exit 1); "
            f"if grep -Fq 'image: {server_identifiers.caddy_custom_image()}' \"${{COMPOSE}}\"; then echo 'Custom Caddy build detected; refusing to rewrite the image line.' >&2; exit 1; fi; "
            f'cp -a "${{COMPOSE}}" {quoted_backup}/docker-compose.yml; '
            f"[ ! -f {stack}/caddy/Caddyfile ] || cp -a {stack}/caddy/Caddyfile {quoted_backup}/Caddyfile; "
            'python3 - "$COMPOSE" '
            f"{target} <<'PY'\n"
            "import pathlib, sys\n"
            "path = pathlib.Path(sys.argv[1])\n"
            "target = sys.argv[2]\n"
            "lines = path.read_text().splitlines()\n"
            "for index, line in enumerate(lines):\n"
            "    if line.lstrip().startswith('image:'):\n"
            "        indent = line[:len(line)-len(line.lstrip())]\n"
            "        lines[index] = f'{indent}image: {target}'\n"
            "        break\n"
            "path.write_text('\\n'.join(lines) + '\\n')\n"
            "PY\n"
            'docker compose -f "$COMPOSE" up -d --remove-orphans; '
            f"{caddy_service_readiness_check_shell(container_name)}"
        )

    if component_id == "dns_service":
        target = shlex.quote(CANONICAL_DNS_SETTINGS["bind_image"])
        stack = shlex.quote(CANONICAL_DNS_SETTINGS["stack_root"])
        container_name = shlex.quote(CANONICAL_DNS_SETTINGS["container_name"])
        return (
            "set -eu; "
            f"{_private_backup_dir_command(backup_dir)}; "
            f"COMPOSE={stack}/docker-compose.yml; "
            f"[ -f \"${{COMPOSE}}\" ] || (echo 'DNS service is not configured.' >&2; exit 1); "
            f'cp -a "${{COMPOSE}}" {quoted_backup}/docker-compose.yml; '
            'python3 - "$COMPOSE" '
            f"{target} <<'PY'\n"
            "import pathlib, sys\n"
            "path = pathlib.Path(sys.argv[1])\n"
            "target = sys.argv[2]\n"
            "lines = path.read_text().splitlines()\n"
            "for index, line in enumerate(lines):\n"
            "    if line.lstrip().startswith('image:'):\n"
            "        indent = line[:len(line)-len(line.lstrip())]\n"
            "        lines[index] = f'{indent}image: {target}'\n"
            "        break\n"
            "path.write_text('\\n'.join(lines) + '\\n')\n"
            "PY\n"
            'docker compose -f "$COMPOSE" up -d --remove-orphans; '
            f"{bind_service_readiness_check_shell(container_name)}"
        )

    if component_id == "walg_backup_tool":
        install_command = postgres_walg_install_command(reinstall_existing=True)
        expected_version = re.escape(WALG_VERSION)
        return (
            "set -eu; "
            f"{_private_backup_dir_command(backup_dir)}; "
            f"[ ! -f /usr/local/bin/wal-g ] || cp -a /usr/local/bin/wal-g {quoted_backup}/wal-g; "
            f"{install_command}; "
            "command -v wal-g >/dev/null; "
            f"wal-g --version | grep -E '^wal-g version {expected_version}([[:space:]]|$)' >/dev/null"
        )

    if component_id == "docker_runtime":
        return _docker_patch_install_command()

    if component_id == "postgresql_database_service":
        return _managed_postgres_update_command(backup_dir=backup_dir)

    raise ValueError(f"Unknown managed software component: {component_id}.")


def _managed_rollback_command(component_id, ledger_record, *, restore_data=False):
    backup_dir = str(ledger_record.get("backup_dir") or "").strip()
    backup_path = str(ledger_record.get("backup_path") or "").strip()
    if (
        component_id
        in {"railpack_build_system", "http_gateway", "dns_service", "postgresql_database_service"}
        and not backup_dir
    ):
        raise ValueError("No rollback snapshot is recorded for this component.")
    if component_id == "walg_backup_tool" and not backup_dir and not backup_path:
        raise ValueError("No WAL-G rollback binary is recorded.")

    quoted_backup = shlex.quote(backup_dir)
    if component_id == "railpack_build_system":
        expected_version = shlex.quote(str(ledger_record.get("previous_version") or ""))
        return (
            "set -eu; "
            f"[ -d {quoted_backup} ] || (echo 'Rollback snapshot is missing.' >&2; exit 1); "
            f"[ ! -f {quoted_backup}/railpack ] || cp -a {quoted_backup}/railpack /usr/local/bin/railpack; "
            f"[ ! -f {quoted_backup}/{_RAILPACK_HELPER_NAME} ] || "
            f"cp -a {quoted_backup}/{_RAILPACK_HELPER_NAME} {server_paths.railpack_build_helper()}; "
            f"[ ! -f {quoted_backup}/railpack.env ] || cp -a {quoted_backup}/railpack.env {shlex.quote(RAILPACK_STACK_ROOT)}/railpack.env; "
            "command -v railpack >/dev/null; "
            f"test -x {server_paths.railpack_build_helper()}; "
            f"if [ -f {quoted_backup}/railpack.env ]; then test -f {shlex.quote(RAILPACK_STACK_ROOT)}/railpack.env; fi; "
            f"EXPECTED={expected_version}; "
            'if [ -n "$EXPECTED" ]; then railpack --version | grep -F "$EXPECTED" >/dev/null; '
            "else railpack --version >/dev/null; fi"
        )
    if component_id == "http_gateway":
        stack = shlex.quote(CANONICAL_HTTP_SETTINGS["stack_root"])
        container_name = shlex.quote(CANONICAL_HTTP_SETTINGS["container_name"])
        custom_image = shlex.quote(server_identifiers.caddy_custom_image())
        previous_image = shlex.quote(server_identifiers.caddy_custom_previous_image())
        return (
            "set -eu; "
            f"[ -f {quoted_backup}/docker-compose.yml ] || (echo 'HTTP rollback snapshot is missing.' >&2; exit 1); "
            f"cp -a {quoted_backup}/docker-compose.yml {stack}/docker-compose.yml; "
            f"[ ! -f {quoted_backup}/Caddyfile ] || cp -a {quoted_backup}/Caddyfile {stack}/caddy/Caddyfile; "
            # Custom stacks snapshot the Dockerfile too, and the last
            # working build sits on the :previous tag; both restores are
            # guarded so stock rollbacks behave exactly as before (#91).
            f"[ ! -f {quoted_backup}/Dockerfile ] || cp -a {quoted_backup}/Dockerfile {stack}/caddy/Dockerfile; "
            f"if docker image inspect {previous_image} >/dev/null 2>&1; then docker tag {previous_image} {custom_image}; fi; "
            f"docker compose -f {stack}/docker-compose.yml up -d --remove-orphans; "
            f"{caddy_service_readiness_check_shell(container_name)}"
        )
    if component_id == "dns_service":
        stack = shlex.quote(CANONICAL_DNS_SETTINGS["stack_root"])
        container_name = shlex.quote(CANONICAL_DNS_SETTINGS["container_name"])
        return (
            "set -eu; "
            f"[ -f {quoted_backup}/docker-compose.yml ] || (echo 'DNS rollback snapshot is missing.' >&2; exit 1); "
            f"cp -a {quoted_backup}/docker-compose.yml {stack}/docker-compose.yml; "
            f"docker compose -f {stack}/docker-compose.yml up -d --remove-orphans; "
            f"{bind_service_readiness_check_shell(container_name)}"
        )
    if component_id == "walg_backup_tool":
        restore_path = shlex.quote(backup_path or f"{backup_dir}/wal-g")
        return (
            "set -eu; "
            f"[ -f {restore_path} ] || (echo 'WAL-G rollback binary is missing.' >&2; exit 1); "
            f"cp -a {restore_path} /usr/local/bin/wal-g; "
            "chmod 755 /usr/local/bin/wal-g; "
            "command -v wal-g >/dev/null; "
            "(wal-g --version >/dev/null 2>&1 || command -v wal-g >/dev/null)"
        )
    if component_id == "docker_runtime":
        package_versions = ledger_record.get("package_versions")
        if not isinstance(package_versions, dict) or not package_versions:
            raise ValueError("No previous Docker package versions are recorded.")
        package_specs = " ".join(
            shlex.quote(f"{name}={version}")
            for name, version in package_versions.items()
            if str(version).strip()
        )
        package_names = " ".join(shlex.quote(name) for name in package_versions)
        return (
            "set -eu; "
            f'for SPEC in {package_specs}; do apt-cache policy "${{SPEC%%=*}}" | grep -F "${{SPEC#*=}}" >/dev/null; done; '
            f"apt-mark unhold {package_names} >/dev/null 2>&1 || true; "
            f"{apt_runtime.apt_get_command('install -y --allow-change-held-packages --allow-downgrades ' + package_specs)}; "
            f"apt-mark hold {package_names} >/dev/null; "
            "systemctl restart docker; "
            "docker ps >/dev/null; "
            "containerd --version >/dev/null; "
            "docker compose version >/dev/null; "
            f"docker ps --filter label={server_identifiers.MANAGED_LABEL_PAIR} "
            "--format '{{.Names}}' >/dev/null"
        )
    if component_id == "postgresql_database_service":
        stack = shlex.quote(CANONICAL_POSTGRES_SETTINGS["stack_root"])
        container_name = shlex.quote(CANONICAL_POSTGRES_SETTINGS["container_name"])
        superuser_name = shlex.quote(CANONICAL_POSTGRES_SETTINGS["superuser_name"])
        if restore_data:
            return (
                "set -eu; umask 077; "
                f"[ -f {quoted_backup}/docker-compose.yml ] || (echo 'PostgreSQL rollback compose snapshot is missing.' >&2; exit 1); "
                f"[ -s {quoted_backup}/pg_dumpall.sql ] || (echo 'PostgreSQL rollback backup is missing.' >&2; exit 1); "
                f"SAFETY={shlex.quote(server_paths.upgrade_backup_service_dir('postgresql_database_service'))}/pre-rollback-$(date -u +%Y%m%dT%H%M%SZ); "
                'install -d -m 700 "$SAFETY"; chown root:root "$SAFETY"; '
                f"docker inspect {container_name} >/dev/null 2>&1 || "
                "(echo 'PostgreSQL container is not available for safety backup.' >&2; exit 1); "
                f"{postgres_service_readiness_check_shell(container_name, superuser_name)} || "
                "(echo 'PostgreSQL service must be ready before rollback.' >&2; exit 1); "
                f'docker exec {container_name} pg_dumpall -U {superuser_name} > "$SAFETY/pg_dumpall.sql"; '
                'test -s "$SAFETY/pg_dumpall.sql"; '
                f"cp -a {quoted_backup}/docker-compose.yml {stack}/docker-compose.yml; "
                f"docker compose -f {stack}/docker-compose.yml down --remove-orphans --volumes >/dev/null 2>&1 || true; "
                f"docker compose -f {stack}/docker-compose.yml up -d --remove-orphans; "
                f"{postgres_service_readiness_wait_shell(container_name, superuser_name)}; "
                f"sed '/^CREATE ROLE {superuser_name};$/d' {quoted_backup}/pg_dumpall.sql | "
                f"docker exec -i {container_name} psql -v ON_ERROR_STOP=1 -U {superuser_name} postgres; "
                f"docker exec {container_name} psql -U {superuser_name} postgres -c '\\l' >/dev/null; "
                f"docker exec {container_name} psql -U {superuser_name} postgres -c '\\du' >/dev/null"
            )
        # Same-major rollback changes only the image in the current compose.
        # A stale snapshot may predate a storage migration or major upgrade;
        # restoring it would retarget the live service at old data.
        previous_version = str(ledger_record.get("previous_version") or "").strip()
        if not previous_version:
            raise ValueError("No previous PostgreSQL image is recorded.")
        image_pattern = shlex.quote(_POSTGRES_MANAGED_IMAGE_PATTERN)
        quoted_previous = shlex.quote(previous_version)
        image_rewriter = _postgres_compose_image_rewriter_script()
        safety_root = shlex.quote(
            server_paths.upgrade_backup_service_dir("postgresql_database_service")
        )
        return f"""set -eu
umask 077
COMPOSE={stack}/docker-compose.yml
[ -f "$COMPOSE" ] || (echo 'PostgreSQL current compose file is missing.' >&2; exit 1)
SAFETY={safety_root}/pre-rollback-$(date -u +%Y%m%dT%H%M%SZ)
install -d -m 700 "$SAFETY"
chown root:root "$SAFETY"
docker inspect {container_name} >/dev/null 2>&1 || (echo 'PostgreSQL container is not available for safety backup.' >&2; exit 1)
{postgres_service_readiness_check_shell(container_name, superuser_name)} || (echo 'PostgreSQL service must be ready before rollback.' >&2; exit 1)
docker exec {container_name} pg_dumpall -U {superuser_name} > "$SAFETY/pg_dumpall.sql"
test -s "$SAFETY/pg_dumpall.sql"
cp -a "$COMPOSE" "$SAFETY/docker-compose.yml"
POSTGRES_ENV_OUTPUT="$(python3 - "$COMPOSE" rollback {image_pattern} {quoted_previous} <<'PY'
{image_rewriter}
PY
)" || exit 1
eval "$POSTGRES_ENV_OUTPUT"
restore_current_compose(){{
  cp -a "$SAFETY/docker-compose.yml" "$COMPOSE"
  docker compose -f "$COMPOSE" up -d --remove-orphans >/dev/null 2>&1 || true
}}
trap restore_current_compose EXIT INT TERM
docker compose -f "$COMPOSE" config >/dev/null
docker compose -f "$COMPOSE" up -d --remove-orphans
{postgres_service_readiness_wait_shell(container_name, superuser_name)}
docker inspect -f '{{{{.Config.Image}}}}' {container_name} | grep -Fx "$POSTGRES_TARGET_IMAGE" >/dev/null
docker exec {container_name} psql -U {superuser_name} postgres -c '\\l' >/dev/null
docker exec {container_name} psql -U {superuser_name} postgres -c '\\du' >/dev/null
trap - EXIT INT TERM"""
    raise ValueError(f"Unknown managed software component: {component_id}.")


def _read_server_tooling_status(ctx, session, emit=None):
    result = run_shell_command(
        session.host,
        _build_server_tooling_status_command(),
        timeout=20,
        sudo=True,
        emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
    )
    if not result["ok"]:
        return {
            "ok": False,
            "error": ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Failed to read server tooling status.",
                stage="execute_runtime_operation",
                details=result["details"],
            ),
        }
    payload = shell_output.parse_key_values(result["output"])
    ledger = _read_remote_software_ledger(ctx, session, emit=emit)
    tooling = _tooling_status_from_payload(payload)
    capabilities = _server_capabilities_from_payload(payload)
    managed_software = build_managed_software_status(payload, ledger)
    return {
        "ok": True,
        "payload": payload,
        "tooling": tooling,
        "capabilities": capabilities,
        "managed_software": managed_software,
        "software_ledger": ledger,
    }


def run_server_tooling_status_operation(
    ctx,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    emit=None,
    is_cancelled=None,
):
    if callable(is_cancelled) and is_cancelled():
        return ctx.error_result(
            "ENGINE_TASK_CANCELLED",
            "Task cancelled before execution started",
            stage="preflight",
        )

    if dry_run:
        return {
            "status": "success",
            "code": "OK",
            "msg": "Server tooling status plan ready",
            "operation_id": "tooling_status",
            "actions": [
                "Read Railpack CLI version",
                "Check Deploy Dash Railpack build helper",
                "Check Deploy Dash Railpack defaults",
            ],
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
            "server_tooling_status_started",
            "Checking Deploy Dash server tooling.",
        )
        status_result = _read_server_tooling_status(ctx, session, emit=emit)
        if not status_result["ok"]:
            return status_result["error"]
        tooling = status_result["tooling"]
        capabilities = status_result["capabilities"]
        managed_software = status_result["managed_software"]
        managed_update_available = any(
            component.get("can_update") is True for component in managed_software.values()
        )
        return {
            "status": "success",
            "code": "OK",
            "msg": (
                "Server capability updates are available."
                if _capability_update_available(capabilities) or managed_update_available
                else "Server capabilities are up to date."
            ),
            "operation_id": "tooling_status",
            "tooling": tooling,
            "capabilities": capabilities,
            "managed_software": managed_software,
            "software_ledger": status_result["software_ledger"],
            "update_available": _capability_update_available(capabilities)
            or managed_update_available,
        }
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


def run_server_tooling_update_operation(
    ctx,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    component_ids=None,
    dry_run=False,
    emit=None,
    is_cancelled=None,
):
    if callable(is_cancelled) and is_cancelled():
        return ctx.error_result(
            "ENGINE_TASK_CANCELLED",
            "Task cancelled before execution started",
            stage="preflight",
        )

    requested_component_ids = component_ids
    try:
        selected_component_ids = normalize_component_ids(component_ids)
    except ValueError as error:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            str(error),
            stage="validate_request",
        )

    def _emit_from_executor(event_type, message, level="info", data=None):
        ctx.emit_event(
            emit,
            event_type,
            message,
            level=level,
            data=data,
        )

    if dry_run:
        manifest = managed_software_manifest()
        return {
            "status": "success",
            "code": "OK",
            "msg": "Managed server software update plan ready",
            "operation_id": "tooling_update",
            "component_ids": selected_component_ids,
            "actions": [
                f"Update {manifest[component_id]['label']}"
                for component_id in selected_component_ids
            ],
            "managed_software_manifest": manifest,
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
            "server_tooling_update_started",
            "Updating Deploy Dash managed server software.",
            data={"component_ids": selected_component_ids},
        )

        status_before = _read_server_tooling_status(ctx, session, emit=emit)
        if not status_before["ok"]:
            return status_before["error"]
        ledger = status_before["software_ledger"]
        payload = status_before["payload"]
        managed_before = status_before["managed_software"]
        if requested_component_ids is None:
            selected_component_ids = [
                component_id
                for component_id in selected_component_ids
                if managed_before.get(component_id, {}).get("can_update") is True
            ]

        for component_id in selected_component_ids:
            if callable(is_cancelled) and is_cancelled():
                return ctx.error_result(
                    "ENGINE_TASK_CANCELLED",
                    "Task cancelled during managed server software update",
                    stage="execute_runtime_operation",
                )
            component = managed_before.get(component_id, {})
            if component.get("status") == "not_configured":
                continue
            timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
            backup_dir = _backup_dir(component_id, timestamp)
            package_versions = None
            if component_id == "docker_runtime":
                package_versions = {
                    "docker-ce": payload.get("docker_ce_version", ""),
                    "docker-ce-cli": payload.get("docker_ce_cli_version", ""),
                    "containerd.io": payload.get("containerd_version", ""),
                    "docker-compose-plugin": payload.get(
                        "docker_compose_plugin_version",
                        "",
                    ),
                }
            ledger = record_component_action(
                ledger,
                component_id,
                action="update",
                status="in_progress",
                installed_version=component.get("current", ""),
                previous_version=component.get("current", ""),
                target_version=component.get("target", ""),
                package_versions=package_versions,
            )
            ledger_write_result = _write_remote_software_ledger(
                ctx,
                session,
                ledger,
                emit=emit,
            )
            ledger_write_error = _software_ledger_write_error(
                ctx,
                ledger_write_result,
                "Could not record the managed-software update state.",
            )
            if ledger_write_error is not None:
                return ledger_write_error

            preflight_command = _managed_update_command(
                component_id,
                backup_dir=backup_dir,
                caddy_compose_image=payload.get("caddy_compose_image", ""),
            )
            preflight_command = f"{_managed_backup_hygiene_command()}; {preflight_command}"
            command_result = run_shell_command(
                session.host,
                preflight_command,
                timeout=900,
                sudo=True,
                emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
            )
            if not command_result["ok"]:
                ledger = record_component_action(
                    ledger,
                    component_id,
                    action="update",
                    status="failed",
                    installed_version=component.get("current", ""),
                    previous_version=component.get("current", ""),
                    target_version=component.get("target", ""),
                    package_versions=package_versions,
                )
                _write_remote_software_ledger(ctx, session, ledger, emit=emit)
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    f"Failed to update {component.get('label', component_id)}.",
                    stage="execute_runtime_operation",
                    details=command_result["details"] or "remote command failed",
                )

            if component_id == "railpack_build_system":
                setup_config = parse_setup_config({})
                step_result = collect_setup_steps(["part5"], setup_config)
                result = run_plan_execute(
                    session=session,
                    steps=step_result["steps"],
                    parts=["part5"],
                    summary_data={
                        "target_railpack_version": RAILPACK_VERSION_NUMBER,
                        "railpack_frontend_image": RAILPACK_FRONTEND_IMAGE,
                    },
                    emit_event=_emit_from_executor,
                    is_cancelled=is_cancelled,
                    message="Railpack build system updated successfully.",
                    failure_message_prefix="Railpack update failed at",
                )
                if result.get("status") != "success":
                    ledger = record_component_action(
                        ledger,
                        component_id,
                        action="update",
                        status="failed",
                        installed_version=component.get("current", ""),
                        previous_version=component.get("current", ""),
                        target_version=component.get("target", ""),
                        backup_dir=backup_dir,
                    )
                    _write_remote_software_ledger(ctx, session, ledger, emit=emit)
                    return result

            ledger = record_component_action(
                ledger,
                component_id,
                action="update",
                status="success",
                installed_version=component.get("current", ""),
                previous_version=component.get("current", ""),
                target_version=component.get("target", ""),
                backup_dir=backup_dir,
                backup_path=(f"{backup_dir}/wal-g" if component_id == "walg_backup_tool" else ""),
                package_versions=package_versions,
            )
            ledger_write_result = _write_remote_software_ledger(
                ctx,
                session,
                ledger,
                emit=emit,
            )
            ledger_write_error = _software_ledger_write_error(
                ctx,
                ledger_write_result,
                "Updated managed software, but could not record its rollback snapshot.",
            )
            if ledger_write_error is not None:
                return ledger_write_error

            if component_id != "docker_runtime":
                retention_result = run_shell_command(
                    session.host,
                    _managed_backup_retention_command(
                        component_id,
                        protected_backup_dir=backup_dir,
                    ),
                    timeout=120,
                    sudo=True,
                    emit_output=lambda output: ctx.emit_shell_output_lines(
                        emit,
                        output,
                    ),
                )
                if not retention_result["ok"]:
                    return ctx.error_result(
                        "ENGINE_RUNTIME_ERROR",
                        (
                            f"Updated {component.get('label', component_id)}, "
                            "but could not enforce rollback-backup retention."
                        ),
                        stage="execute_runtime_operation",
                        details=retention_result["details"] or "remote retention command failed",
                    )
                retained_backups = _parse_managed_backup_retention_output(
                    retention_result["output"],
                )
                ledger = record_component_action(
                    ledger,
                    component_id,
                    action="update",
                    status="success",
                    retained_backups=retained_backups,
                )
                ledger_write_result = _write_remote_software_ledger(
                    ctx,
                    session,
                    ledger,
                    emit=emit,
                )
                ledger_write_error = _software_ledger_write_error(
                    ctx,
                    ledger_write_result,
                    "Pruned rollback backups, but could not record the retained set.",
                )
                if ledger_write_error is not None:
                    return ledger_write_error

        status_result = _read_server_tooling_status(ctx, session, emit=emit)
        result = {
            "status": "success",
            "code": "OK",
            "msg": "Managed server software updated successfully.",
            "operation_id": "tooling_update",
            "component_ids": selected_component_ids,
        }
        if status_result["ok"]:
            result["tooling"] = status_result["tooling"]
            result["capabilities"] = status_result["capabilities"]
            result["managed_software"] = status_result["managed_software"]
            result["software_ledger"] = status_result["software_ledger"]
            result["update_available"] = _capability_update_available(
                status_result["capabilities"],
            ) or any(
                component.get("can_update") is True
                for component in status_result["managed_software"].values()
            )
        return result
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


def run_server_tooling_rollback_operation(
    ctx,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    component_id=None,
    dry_run=False,
    emit=None,
    is_cancelled=None,
    restore_data=False,
):
    if callable(is_cancelled) and is_cancelled():
        return ctx.error_result(
            "ENGINE_TASK_CANCELLED",
            "Task cancelled before execution started",
            stage="preflight",
        )

    try:
        selected_component_id = normalize_component_ids([component_id])[0]
    except ValueError as error:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            str(error),
            stage="validate_request",
        )

    manifest = managed_software_manifest()
    # Only PostgreSQL has a second rollback path; the flag is ignored for
    # every other component, which has exactly one way to roll back.
    restore_postgres_data = selected_component_id == "postgresql_database_service" and bool(
        restore_data
    )
    if restore_postgres_data:
        rollback_path = manifest[selected_component_id]["data_restore_mode"]
    else:
        rollback_path = manifest[selected_component_id]["rollback_mode"]
    if dry_run:
        risk_level = manifest[selected_component_id]["risk_level"]
        if restore_postgres_data:
            risk_level = manifest[selected_component_id]["data_restore_risk_level"]
        return {
            "status": "success",
            "code": "OK",
            "msg": "Managed server software rollback plan ready",
            "operation_id": "tooling_rollback",
            "component_id": selected_component_id,
            "risk_level": risk_level,
            "destructive": risk_level in {"high", "destructive"},
            "actions": [f"Rollback {manifest[selected_component_id]['label']}"],
            "managed_software_manifest": manifest,
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
            "server_tooling_rollback_started",
            "Rolling back Deploy Dash managed server software.",
            data={"component_id": selected_component_id},
        )
        ledger = _read_remote_software_ledger(ctx, session, emit=emit)
        ledger_record = ledger.get("components", {}).get(selected_component_id, {})
        if not ledger_record:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "No rollback record is available for this component.",
                stage="validate_request",
            )
        try:
            rollback_command = _managed_rollback_command(
                selected_component_id,
                ledger_record,
                restore_data=restore_postgres_data,
            )
        except ValueError as error:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                str(error),
                stage="validate_request",
            )
        rollback_command = f"{_managed_backup_hygiene_command()}; {rollback_command}"
        result = run_shell_command(
            session.host,
            rollback_command,
            timeout=1200,
            sudo=True,
            emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
        )
        if not result["ok"]:
            ledger = record_component_action(
                ledger,
                selected_component_id,
                action="rollback",
                status="failed",
                rollback_path=rollback_path,
            )
            _write_remote_software_ledger(ctx, session, ledger, emit=emit)
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                f"Failed to rollback {manifest[selected_component_id]['label']}.",
                stage="execute_runtime_operation",
                details=result["details"] or "remote command failed",
            )
        ledger = record_component_action(
            ledger,
            selected_component_id,
            action="rollback",
            status="success",
            rollback_path=rollback_path,
        )
        ledger_write_result = _write_remote_software_ledger(
            ctx,
            session,
            ledger,
            emit=emit,
        )
        ledger_write_error = _software_ledger_write_error(
            ctx,
            ledger_write_result,
            "Rolled back managed software, but could not record the result.",
        )
        if ledger_write_error is not None:
            return ledger_write_error
        if selected_component_id != "docker_runtime":
            retention_result = run_shell_command(
                session.host,
                _managed_backup_retention_command(
                    selected_component_id,
                    protected_backup_dir=str(ledger_record.get("backup_dir") or ""),
                ),
                timeout=120,
                sudo=True,
                emit_output=lambda output: ctx.emit_shell_output_lines(
                    emit,
                    output,
                ),
            )
            if not retention_result["ok"]:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    (
                        f"Rolled back {manifest[selected_component_id]['label']}, "
                        "but could not enforce rollback-backup retention."
                    ),
                    stage="execute_runtime_operation",
                    details=retention_result["details"] or "remote retention command failed",
                )
            ledger = record_component_action(
                ledger,
                selected_component_id,
                action="rollback",
                status="success",
                rollback_path=rollback_path,
                retained_backups=_parse_managed_backup_retention_output(
                    retention_result["output"],
                ),
            )
            ledger_write_result = _write_remote_software_ledger(
                ctx,
                session,
                ledger,
                emit=emit,
            )
            ledger_write_error = _software_ledger_write_error(
                ctx,
                ledger_write_result,
                "Pruned rollback backups, but could not record the retained set.",
            )
            if ledger_write_error is not None:
                return ledger_write_error
        status_result = _read_server_tooling_status(ctx, session, emit=emit)
        response = {
            "status": "success",
            "code": "OK",
            "msg": "Managed server software rollback completed.",
            "operation_id": "tooling_rollback",
            "component_id": selected_component_id,
        }
        if status_result["ok"]:
            response["tooling"] = status_result["tooling"]
            response["capabilities"] = status_result["capabilities"]
            response["managed_software"] = status_result["managed_software"]
            response["software_ledger"] = status_result["software_ledger"]
            response["update_available"] = _capability_update_available(
                status_result["capabilities"],
            ) or any(
                component.get("can_update") is True
                for component in status_result["managed_software"].values()
            )
        return response
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
