import shlex
from io import StringIO

from pyinfra.operations import docker, files, server

from .. import server_identifiers
from ..container_status import (
    caddy_service_readiness_check_shell,
    container_process_running_check_shell,
)
from ..railpack_contract import (
    RAILPACK_FRONTEND_IMAGE,
    render_railpack_version_guard_command,
)
from ..runtime_security import (
    ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING,
    caddy_default_header_lines,
    docker_runtime_security_flags,
)
from .app_config import AppConfig
from .common import AppAction, AppStep
from .repository_host_key import render_repository_host_key_preflight_command
from .worker_runtime import (
    build_runtime_env_docker_flags,
    build_worker_runtime_command_specs,
    render_runtime_env_stdin,
)


def render_selected_branch_fetch_command(
    *,
    source_root: str,
    branch: str,
    git_ssh_command: str,
):
    quoted_source_root = shlex.quote(source_root)
    quoted_git_ssh_command = shlex.quote(git_ssh_command)
    quoted_branch_refspec = shlex.quote(
        f"+refs/heads/{branch}:refs/remotes/origin/{branch}",
    )
    return (
        f"GIT_SSH_COMMAND={quoted_git_ssh_command} "
        f"git -C {quoted_source_root} fetch --depth 1 --no-tags origin "
        f"{quoted_branch_refspec}; "
    )


def _dns_tls_block_and_env(config: AppConfig):
    if config.tls_challenge_mode != "dns":
        return None, {}
    if not config.tls_dns_provider:
        return None, {}

    provider = config.tls_dns_provider
    credentials = config.tls_dns_credentials

    def project_env_var(suffix):
        return f"{config.tls_env_prefix}{suffix}"

    if provider == "cloudflare":
        token_var = project_env_var("CLOUDFLARE_API_TOKEN")
        return (
            (f"    tls {{\n        dns cloudflare {{env.{token_var}}}\n    }}\n"),
            {token_var: credentials["api_token"]},
        )

    if provider == "porkbun":
        key_var = project_env_var("PORKBUN_API_KEY")
        secret_var = project_env_var("PORKBUN_API_SECRET_KEY")
        return (
            (
                "    tls {\n"
                "        dns porkbun {\n"
                f"            api_key {{env.{key_var}}}\n"
                f"            api_secret_key {{env.{secret_var}}}\n"
                "        }\n"
                "    }\n"
            ),
            {
                key_var: credentials["api_key"],
                secret_var: credentials["api_secret_key"],
            },
        )

    if provider == "namecheap":
        user_var = project_env_var("NAMECHEAP_API_USER")
        key_var = project_env_var("NAMECHEAP_API_KEY")
        env_vars = {
            user_var: credentials["api_user"],
            key_var: credentials["api_key"],
        }
        dns_lines = [
            "    tls {",
            "        dns namecheap {",
            f"            api_user {{env.{user_var}}}",
            f"            api_key {{env.{key_var}}}",
        ]
        client_ip = credentials.get("client_ip")
        if client_ip:
            client_ip_var = project_env_var("NAMECHEAP_CLIENT_IP")
            env_vars[client_ip_var] = client_ip
            dns_lines.append(f"            client_ip {{env.{client_ip_var}}}")
        api_endpoint = credentials.get("api_endpoint")
        if api_endpoint:
            endpoint_var = project_env_var("NAMECHEAP_API_ENDPOINT")
            env_vars[endpoint_var] = api_endpoint
            dns_lines.append(f"            endpoint {{env.{endpoint_var}}}")
        dns_lines.extend(["        }", "    }"])
        return "\n".join(dns_lines) + "\n", env_vars

    if provider == "cloudns":
        password_var = project_env_var("CLOUDNS_AUTH_PASSWORD")
        env_vars = {password_var: credentials["auth_password"]}
        dns_lines = [
            "    tls {",
            "        dns cloudns {",
            f"            auth_password {{env.{password_var}}}",
        ]
        auth_id = credentials.get("auth_id")
        if auth_id:
            auth_id_var = project_env_var("CLOUDNS_AUTH_ID")
            env_vars[auth_id_var] = auth_id
            dns_lines.append(f"            auth_id {{env.{auth_id_var}}}")
        sub_auth_id = credentials.get("sub_auth_id")
        if sub_auth_id:
            sub_auth_id_var = project_env_var("CLOUDNS_SUB_AUTH_ID")
            env_vars[sub_auth_id_var] = sub_auth_id
            dns_lines.append(f"            sub_auth_id {{env.{sub_auth_id_var}}}")
        dns_lines.extend(["        }", "    }"])
        return "\n".join(dns_lines) + "\n", env_vars

    if provider == "easydns":
        token_var = project_env_var("EASYDNS_API_TOKEN")
        key_var = project_env_var("EASYDNS_API_KEY")
        env_vars = {
            token_var: credentials["api_token"],
            key_var: credentials["api_key"],
        }
        dns_lines = [
            "    tls {",
            "        dns easydns {",
            f"            api_token {{env.{token_var}}}",
            f"            api_key {{env.{key_var}}}",
        ]
        api_url = credentials.get("api_url")
        if api_url:
            api_url_var = project_env_var("EASYDNS_API_URL")
            env_vars[api_url_var] = api_url
            dns_lines.append(f"            api_url {{env.{api_url_var}}}")
        dns_lines.extend(["        }", "    }"])
        return "\n".join(dns_lines) + "\n", env_vars

    return None, {}


def _render_caddy_snippet(
    config: AppConfig,
    tls_block=None,
    upstream_container_name: str | None = None,
):
    def render_block(hostname, *body_lines):
        rendered = [f"{hostname} {{\n"]
        if isinstance(tls_block, str) and tls_block.strip():
            rendered.append(tls_block)
        for line in body_lines:
            rendered.append(f"    {line}\n")
        rendered.append("}\n")
        return "".join(rendered)

    canonical_domain = config.canonical_domain
    redirect_domain = config.redirect_domain
    resolved_upstream_container = (
        upstream_container_name.strip()
        if isinstance(upstream_container_name, str) and upstream_container_name.strip()
        else config.container_name
    )
    reverse_proxy_lines = [
        f"reverse_proxy {resolved_upstream_container}:{config.app_port} {{",
        "    header_down -Server",
        "    header_down -Via",
        "    header_down -X-Powered-By",
        "}",
    ]
    reverse_proxy_lines.extend(caddy_default_header_lines(include_hsts=True))

    if redirect_domain is None:
        return render_block(canonical_domain, *reverse_proxy_lines)

    redirect_target = f"https://{canonical_domain}{{uri}}"
    return "".join(
        [
            render_block(
                redirect_domain,
                *caddy_default_header_lines(include_hsts=True),
                f"redir {redirect_target} permanent",
            ),
            render_block(canonical_domain, *reverse_proxy_lines),
        ]
    )


def _build_caddy_env_sync_command(config: AppConfig, env_vars):
    quoted_env_file = shlex.quote(config.caddy_env_file_path)
    quoted_prefix = shlex.quote(config.tls_env_prefix)

    command = (
        f"ENV_FILE={quoted_env_file}; "
        f"PREFIX={quoted_prefix}; "
        'TMP_FILE="$(mktemp)"; '
        'touch "${ENV_FILE}"; '
        'chmod 600 "${ENV_FILE}"; '
        'grep -v "^${PREFIX}" "${ENV_FILE}" > "${TMP_FILE}" || true; '
    )
    for env_key in sorted(env_vars.keys()):
        env_value = env_vars[env_key]
        command += (
            f"printf '%s=%s\\n' {shlex.quote(env_key)} {shlex.quote(env_value)} "
            '>> "${TMP_FILE}"; '
        )
    command += 'mv "${TMP_FILE}" "${ENV_FILE}"; chmod 600 "${ENV_FILE}"'
    return command


def _build_caddy_domain_index_command(config: AppConfig, validate_desired=False):
    quoted_caddy_conf_d = shlex.quote(f"{config.caddy_stack_root}/caddy/conf.d")
    quoted_domain_index = shlex.quote(
        f"{config.caddy_stack_root}/caddy/conf.d/.deploydash-domain-owners.tsv"
    )
    quoted_project_slug = shlex.quote(config.project_slug)
    quoted_managed_domains = shlex.quote(" ".join(config.managed_domains))

    command = (
        f"CONFD_DIR={quoted_caddy_conf_d}; "
        f"OWNERS_FILE={quoted_domain_index}; "
        f"PROJECT_SLUG={quoted_project_slug}; "
        f"DESIRED_DOMAINS={quoted_managed_domains}; "
        'TMP_SCAN="$(mktemp)"; '
        'TMP_SORTED="$(mktemp)"; '
        'trap \'rm -f "${TMP_SCAN}" "${TMP_SORTED}"\' EXIT INT TERM; '
        ': > "${TMP_SCAN}"; '
        'for file in "${CONFD_DIR}"/20-*.caddy; do '
        '[ -e "${file}" ] || continue; '
        'owner="$(basename "${file}" .caddy)"; '
        'owner="${owner#20-}"; '
        "while IFS= read -r line; do "
        "trimmed=\"$(printf '%s' \"${line}\" | sed 's/^[[:space:]]*//')\"; "
        '[ -n "${trimmed}" ] || continue; '
        'case "${trimmed}" in \\#*) continue ;; esac; '
        'candidate="${trimmed%%\\{}"; '
        "candidate=\"$(printf '%s' \"${candidate}\" | sed 's/[[:space:]]*$//')\"; "
        'case "${candidate}" in http://*) candidate="${candidate#http://}" ;; '
        'https://*) candidate="${candidate#https://}" ;; esac; '
        'case "${candidate}" in *,*) continue ;; esac; '
        "case \"${candidate}\" in ''|*[!A-Za-z0-9.-]*) continue ;; esac; "
        "printf '%s\\t%s\\n' "
        "\"$(printf '%s' \"${candidate}\" | tr '[:upper:]' '[:lower:]')\" "
        '"${owner}" >> "${TMP_SCAN}"; '
        'done < "${file}"; '
        "done; "
        'sort -u "${TMP_SCAN}" > "${TMP_SORTED}"; '
        "awk -F '\\t' '"
        "NF != 2 { next } "
        "{ "
        "if (($1 in owner) && owner[$1] != $2) { "
        'printf "Domain ownership conflict detected: %s is managed by both %s and %s.\\n", '
        '$1, owner[$1], $2 > "/dev/stderr"; '
        "exit 1; "
        "} "
        "owner[$1] = $2; "
        "} "
        '\' "${TMP_SORTED}"; '
        'cat "${TMP_SORTED}" > "${OWNERS_FILE}"; '
        'chmod 600 "${OWNERS_FILE}"'
    )
    if validate_desired:
        command += (
            "; "
            "for domain in ${DESIRED_DOMAINS}; do "
            'owner="$(awk -F \'\\t\' -v target="${domain}" '
            '\'$1 == target { print $2; exit }\' "${OWNERS_FILE}")"; '
            'if [ -n "${owner}" ] && [ "${owner}" != "${PROJECT_SLUG}" ]; then '
            'echo "Domain ownership conflict: ${domain} is already managed by project '
            '${owner}. Disconnect or reconfigure the other project first." >&2; '
            "exit 1; "
            "fi; "
            "done"
        )
    return command


def _build_redirect_probe_command(config: AppConfig):
    if config.redirect_domain is None:
        return None

    redirect_domain = config.redirect_domain
    quoted_redirect_host_header = shlex.quote(f"Host: {redirect_domain}")
    quoted_redirect_resolve = shlex.quote(f"{redirect_domain}:443:127.0.0.1")
    quoted_redirect_https_url = shlex.quote(f"https://{redirect_domain}/")
    quoted_canonical_https_prefix = shlex.quote(f"https://{config.canonical_domain}")
    quoted_redirect_https_prefix = shlex.quote(f"https://{redirect_domain}")

    return (
        "REDIRECT_CODE=\"$(curl -sS -o /dev/null -w '%{http_code}' -H "
        f"{quoted_redirect_host_header} "
        'http://127.0.0.1/ 2>/dev/null || echo 000)"; '
        'REDIRECT_LOCATION="$(curl -sSI -H '
        f"{quoted_redirect_host_header} "
        "http://127.0.0.1/ 2>/dev/null | "
        "awk 'BEGIN{IGNORECASE=1} /^location: / {print $2; exit}' | tr -d '\\r')\"; "
        '[ "${REDIRECT_CODE}" -ge 300 ] && [ "${REDIRECT_CODE}" -lt 400 ] && '
        "( if printf '%s' \"${REDIRECT_LOCATION}\" | grep -Fq "
        f"{quoted_canonical_https_prefix}; then "
        "true; "
        "else "
        "printf '%s' \"${REDIRECT_LOCATION}\" | grep -Fq "
        f"{quoted_redirect_https_prefix} && "
        "HTTPS_REDIRECT_CODE=\"$(curl -ksS -o /dev/null -w '%{http_code}' "
        f"--resolve {quoted_redirect_resolve} "
        f'{quoted_redirect_https_url} 2>/dev/null || echo 000)"; '
        'HTTPS_REDIRECT_LOCATION="$(curl -ksSI '
        f"--resolve {quoted_redirect_resolve} "
        f"{quoted_redirect_https_url} 2>/dev/null | "
        "awk 'BEGIN{IGNORECASE=1} /^location: / {print $2; exit}' | tr -d '\\r')\"; "
        '[ "${HTTPS_REDIRECT_CODE}" -ge 300 ] && '
        '[ "${HTTPS_REDIRECT_CODE}" -lt 400 ] && '
        "printf '%s' \"${HTTPS_REDIRECT_LOCATION}\" | grep -Fq "
        f"{quoted_canonical_https_prefix}; "
        "fi )"
    )


def build_steps(config: AppConfig):
    if config.domain_routing_mode == "single_host" and config.redirect_domain is not None:
        raise ValueError(
            "single_host routing cannot set a redirect domain.",
        )
    if config.domain_routing_mode != "single_host" and config.redirect_domain is None:
        raise ValueError(
            "redirect routing mode requires a redirect domain.",
        )
    if config.redirect_domain == config.canonical_domain:
        raise ValueError(
            "redirect domain and canonical domain must be distinct.",
        )

    quoted_source_root = shlex.quote(config.source_root)
    quoted_source_app_root = shlex.quote(config.source_app_root)
    quoted_repo_url = shlex.quote(config.repository_ssh_url)
    quoted_branch = shlex.quote(config.branch)
    quoted_branch_ref = shlex.quote(f"origin/{config.branch}")
    quoted_private_key = shlex.quote(config.key_private_path)
    quoted_known_hosts = shlex.quote(config.key_known_hosts_path)
    quoted_repository_known_hosts = shlex.quote(
        config.repository_known_hosts_path,
    )
    quoted_build_helper = shlex.quote(config.railpack_build_helper)
    quoted_railpack_env_file = shlex.quote(config.railpack_env_file)
    quoted_railpack_build_command = shlex.quote(config.railpack_build_command)
    quoted_railpack_run_command = shlex.quote(config.railpack_run_command)
    quoted_railpack_provider = (
        shlex.quote(config.railpack_provider)
        if config.railpack_provider is not None and config.railpack_provider.strip()
        else None
    )
    quoted_image_name = shlex.quote(config.image_name)
    quoted_plan_path = shlex.quote(config.railpack_plan_path)
    quoted_info_path = shlex.quote(config.railpack_info_path)
    quoted_container_name = shlex.quote(config.container_name)
    quoted_caddy_container_name = shlex.quote(config.caddy_container_name)
    quoted_caddy_apply_helper = shlex.quote(config.caddy_apply_helper)
    quoted_caddy_stack_root = shlex.quote(config.caddy_stack_root)
    quoted_app_port = shlex.quote(str(config.app_port))
    quoted_project_slug = shlex.quote(config.project_slug)
    quoted_canonical_domain = shlex.quote(config.canonical_domain)
    quoted_legacy_runtime_env_file = shlex.quote(f"{config.project_root}/runtime.env")
    quoted_sqlite_volume_name = (
        shlex.quote(config.sqlite_storage.volume_name)
        if config.sqlite_storage is not None
        else None
    )
    quoted_sqlite_mount_path = (
        shlex.quote(config.sqlite_storage.mount_path) if config.sqlite_storage is not None else None
    )
    tls_block, dns_env_vars = _dns_tls_block_and_env(config)
    sync_caddy_env_command = _build_caddy_env_sync_command(config, dns_env_vars)
    runtime_env_values = dict(config.runtime_env)
    if config.sqlite_storage is not None:
        runtime_env_values["SQLITE_PATH"] = config.sqlite_storage.database_path
        runtime_env_values["DATABASE_URL"] = config.sqlite_storage.database_url
    for mount in config.sqlite_snapshot_mounts:
        if mount.path_env_key is not None:
            runtime_env_values[mount.path_env_key] = mount.database_path
        if mount.database_url_env_key is not None:
            runtime_env_values[mount.database_url_env_key] = mount.database_url
    runtime_env_stdin = render_runtime_env_stdin(runtime_env_values)
    runtime_env_docker_flags = build_runtime_env_docker_flags(
        runtime_env_values,
    )
    sqlite_volume_names = []
    sqlite_volume_docker_flags = ""
    if quoted_sqlite_volume_name is not None and quoted_sqlite_mount_path is not None:
        sqlite_volume_names.append(config.sqlite_storage.volume_name)
        sqlite_volume_docker_flags = f"-v {quoted_sqlite_volume_name}:{quoted_sqlite_mount_path} "
    sqlite_snapshot_volume_flags = []
    for mount in config.sqlite_snapshot_mounts:
        quoted_snapshot_volume = shlex.quote(mount.volume_name)
        quoted_snapshot_mount_path = shlex.quote(mount.mount_path)
        sqlite_volume_names.append(mount.volume_name)
        sqlite_snapshot_volume_flags.append(
            f"-v {quoted_snapshot_volume}:{quoted_snapshot_mount_path}:ro"
        )
    sqlite_snapshot_docker_flags = (
        " ".join(sqlite_snapshot_volume_flags) + " " if sqlite_snapshot_volume_flags else ""
    )
    worker_cleanup_command = (
        "docker ps -a "
        f"--filter label={shlex.quote(f'{server_identifiers.LABEL_PROJECT}={config.project_slug}')} "
        f"--filter label={server_identifiers.LABEL_ROLE}={server_identifiers.ROLE_WORKER} "
        "--format '{{.Names}}' | xargs -r docker rm -f >/dev/null 2>&1 || true"
    )
    worker_command_specs = build_worker_runtime_command_specs(
        project_slug=config.project_slug,
        image_name=config.image_name,
        workers=config.workers,
        runtime_env_docker_flags=runtime_env_docker_flags,
        readonly_volume_docker_flags=sqlite_snapshot_docker_flags,
        primary_network_env_var="CADDY_NETWORK",
        trust_network_names=config.trust_network_names,
    )
    worker_run_commands = [spec.run_command for spec in worker_command_specs]
    worker_verify_commands = [spec.verify_command for spec in worker_command_specs]

    has_inline_key = (
        isinstance(config.deploy_private_key, str) and config.deploy_private_key.strip() != ""
    )

    if has_inline_key:
        repository_host_key_preflight_command = render_repository_host_key_preflight_command(config)
        git_ssh_command = (
            "ssh "
            "-o IdentitiesOnly=no "
            "-o StrictHostKeyChecking=yes "
            f"-o UserKnownHostsFile={quoted_repository_known_hosts} "
            "-o GlobalKnownHostsFile=/dev/null "
        )
        quoted_git_ssh_command = shlex.quote(git_ssh_command)
        selected_branch_fetch_command = render_selected_branch_fetch_command(
            source_root=config.source_root,
            branch=config.branch,
            git_ssh_command=git_ssh_command,
        )
        clone_or_update_command = (
            "set -eu; "
            f"{repository_host_key_preflight_command}\n"
            'eval "$(ssh-agent -s)" >/dev/null; '
            "cleanup(){ ssh-agent -k >/dev/null 2>&1 || true; }; "
            "trap cleanup EXIT INT TERM; "
            "ssh-add - >/dev/null; "
            f"if [ ! -d {quoted_source_root}/.git ]; then "
            f"GIT_SSH_COMMAND={quoted_git_ssh_command} "
            f"git clone --depth 1 --branch {quoted_branch} "
            f"{quoted_repo_url} {quoted_source_root}; "
            "else "
            f"GIT_SSH_COMMAND={quoted_git_ssh_command} "
            f"git -C {quoted_source_root} remote set-url origin {quoted_repo_url}; "
            f"{selected_branch_fetch_command}"
            f"git -C {quoted_source_root} checkout -B {quoted_branch} {quoted_branch_ref}; "
            f"git -C {quoted_source_root} reset --hard {quoted_branch_ref}; "
            "fi"
        )
    else:
        git_ssh_command = (
            "ssh "
            f"-i {quoted_private_key} "
            "-o IdentitiesOnly=yes "
            "-o StrictHostKeyChecking=yes "
            f"-o UserKnownHostsFile={quoted_known_hosts}"
        )
        quoted_git_ssh_command = shlex.quote(git_ssh_command)
        selected_branch_fetch_command = render_selected_branch_fetch_command(
            source_root=config.source_root,
            branch=config.branch,
            git_ssh_command=git_ssh_command,
        )
        clone_or_update_command = (
            f"if [ ! -d {quoted_source_root}/.git ]; then "
            f"GIT_SSH_COMMAND={quoted_git_ssh_command} "
            f"git clone --depth 1 --branch {quoted_branch} "
            f"{quoted_repo_url} {quoted_source_root}; "
            "else "
            f"GIT_SSH_COMMAND={quoted_git_ssh_command} "
            f"git -C {quoted_source_root} remote set-url origin {quoted_repo_url}; "
            f"{selected_branch_fetch_command}"
            f"git -C {quoted_source_root} checkout -B {quoted_branch} {quoted_branch_ref}; "
            f"git -C {quoted_source_root} reset --hard {quoted_branch_ref}; "
            "fi"
        )

    build_env_parts = [f"RAILPACK_ENV_FILE={quoted_railpack_env_file}"]
    if quoted_railpack_provider is not None:
        build_env_parts.append(f"RAILPACK_PROVIDER={quoted_railpack_provider}")
    if config.railpack_build_command.strip():
        build_env_parts.append(f"RAILPACK_BUILD_CMD={quoted_railpack_build_command}")
        build_env_parts.append(f"NIXPACKS_BUILD_CMD={quoted_railpack_build_command}")
    if config.railpack_run_command.strip():
        build_env_parts.append(f"RAILPACK_START_CMD={quoted_railpack_run_command}")
        build_env_parts.append(f"NIXPACKS_START_CMD={quoted_railpack_run_command}")
    build_env_prefix = " ".join(build_env_parts) + " "
    if config.railpack_node_mode == "runtime":
        build_env_prefix += "RAILPACK_NO_SPA=1 "
    build_command = (
        f"{build_env_prefix}"
        f"{quoted_build_helper} "
        f"{quoted_source_app_root} "
        f"{quoted_image_name} "
        f"{quoted_plan_path} "
        f"{quoted_info_path}"
    )
    source_subdirectory_guard_command = (
        f"[ -d {quoted_source_app_root} ] || "
        "(echo 'Configured app subdirectory was not found in repository checkout.' "
        ">&2; exit 1)"
    )

    run_container_command = (
        "while IFS=\"$(printf '\\t')\" read -r key value_b64; do "
        '[ -n "${key}" ] || continue; '
        'value="$(printf \'%s\' "${value_b64}" | base64 -d)"; '
        'export "${key}=${value}"; '
        "done; "
        'CADDY_NETWORK="$(docker inspect -f '
        "'{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "
        f"{quoted_caddy_container_name} | head -n1 | tr -d '[:space:]')\"; "
        '[ -n "${CADDY_NETWORK}" ] || '
        "(echo 'Could not detect Caddy network. Ensure HTTP workflow is applied.' >&2; exit 1); "
        f"rm -f {quoted_legacy_runtime_env_file} >/dev/null 2>&1 || true; "
        f"docker rm -f {quoted_container_name} >/dev/null 2>&1 || true; "
        "docker run -d "
        f"--name {quoted_container_name} "
        "--restart unless-stopped "
        '--network "${CADDY_NETWORK}" '
        "--add-host host.docker.internal:host-gateway "
        f"{docker_runtime_security_flags(profile=ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING)} "
        f"{sqlite_volume_docker_flags} "
        f"{sqlite_snapshot_docker_flags} "
        f"{runtime_env_docker_flags} "
        f"-e PORT={quoted_app_port} "
        f"--label {server_identifiers.MANAGED_LABEL_PAIR} "
        f"--label {server_identifiers.LABEL_PROJECT}={quoted_project_slug} "
        f"{quoted_image_name}; "
    )
    if config.trust_network_names:
        trust_network_list = " ".join(
            shlex.quote(network_name) for network_name in config.trust_network_names
        )
        run_container_command += (
            f"for TRUST_NETWORK in {trust_network_list}; do "
            'if [ "${TRUST_NETWORK}" != "${CADDY_NETWORK}" ]; then '
            'docker network inspect "${TRUST_NETWORK}" >/dev/null 2>&1 || '
            'docker network create "${TRUST_NETWORK}" >/dev/null 2>&1; '
            f'docker network connect "${{TRUST_NETWORK}}" {quoted_container_name} '
            ">/dev/null 2>&1 || true; "
            "fi; "
            "done; "
        )
    run_container_command += "true"

    caddy_apply_command = (
        f"if [ -x {quoted_caddy_apply_helper} ]; then "
        f"{quoted_caddy_apply_helper} {quoted_caddy_stack_root} {quoted_caddy_container_name} >/dev/null; "
        "else "
        f"COMPOSE_FILE={quoted_caddy_stack_root}/docker-compose.yml; "
        "if docker compose version >/dev/null 2>&1; then "
        'docker compose -f "${COMPOSE_FILE}" config >/dev/null; '
        'docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans; '
        "elif command -v docker-compose >/dev/null 2>&1; then "
        'docker-compose -f "${COMPOSE_FILE}" config >/dev/null; '
        'docker-compose -f "${COMPOSE_FILE}" up -d --remove-orphans; '
        "else "
        "echo 'Caddy helper missing and docker compose is unavailable.' >&2; "
        "exit 1; "
        "fi; "
        f"{caddy_service_readiness_check_shell(quoted_caddy_container_name)}; "
        "docker exec "
        f"{quoted_caddy_container_name} "
        "caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null; "
        "fi"
    )
    disk_guard_command = (
        "DOCKER_ROOT=\"$(docker info --format '{{.DockerRootDir}}' "
        '2>/dev/null || echo /var/lib/docker)"; '
        'FREE_KB="$(df -Pk "${DOCKER_ROOT}" | awk \'NR==2 {print $4}\')"; '
        '[ -n "${FREE_KB}" ] || '
        "(echo 'Unable to determine free disk space for Docker root.' >&2; exit 1); "
        '[ "${FREE_KB}" -ge 5242880 ] || '
        '(echo "Insufficient free disk in ${DOCKER_ROOT} for Railpack build '
        '(need at least 5GiB free)." >&2; exit 1)'
    )
    railpack_helper_guard_command = (
        f"grep -Fq {shlex.quote(RAILPACK_FRONTEND_IMAGE)} {quoted_build_helper} || "
        "(echo 'Deploy Dash Railpack build helper is out of date. Open Server "
        "Management and run setup again to update build tooling, then redeploy.' "
        ">&2; exit 1)"
    )
    railpack_env_guard_command = (
        f"[ ! -f {quoted_railpack_env_file} ] || "
        f"grep -Fq {shlex.quote(f'RAILPACK_FRONTEND_IMAGE={RAILPACK_FRONTEND_IMAGE}')} "
        f"{quoted_railpack_env_file} || "
        "(echo 'Deploy Dash Railpack defaults are out of date. Open Server "
        "Management and run setup again to update build tooling, then redeploy.' "
        ">&2; exit 1)"
    )
    validate_domain_ownership_command = _build_caddy_domain_index_command(
        config,
        validate_desired=True,
    )
    refresh_domain_index_command = _build_caddy_domain_index_command(
        config,
        validate_desired=False,
    )
    redirect_probe_command = _build_redirect_probe_command(config)
    https_probe_info_command = (
        "HTTPS_CODE=\"$(curl -ksS -o /dev/null -w '%{http_code}' "
        f"--resolve {quoted_canonical_domain}:443:127.0.0.1 "
        f'https://{config.canonical_domain}/ 2>/dev/null || echo 000)"; '
        'if [ "${HTTPS_CODE}" -ge 200 ] && [ "${HTTPS_CODE}" -lt 500 ]; then '
        "echo 'HTTPS probe succeeded.'; "
        "else "
        "echo 'HTTPS probe did not pass yet; this can happen before DNS/certificate propagation. "
        "HTTP route is active and deploy will continue.'; "
        "fi"
    )

    def register_step1(runtime):
        preflight_commands = [
            "command -v docker >/dev/null",
            "command -v git >/dev/null",
            "command -v railpack >/dev/null",
            render_railpack_version_guard_command(),
            f"test -x {quoted_build_helper}",
            railpack_helper_guard_command,
            railpack_env_guard_command,
            f"test -f {quoted_caddy_stack_root}/docker-compose.yml",
            disk_guard_command,
        ]
        if has_inline_key:
            preflight_commands.insert(3, "command -v ssh-agent >/dev/null")
            preflight_commands.insert(4, "command -v ssh-add >/dev/null")
        else:
            preflight_commands.insert(4, f"test -f {quoted_private_key}")
            preflight_commands.insert(5, f"test -f {quoted_known_hosts}")

        runtime.add_operation(
            server.shell,
            commands=preflight_commands,
        )
        runtime.ensure_service_enabled("docker")
        runtime.add_operation(
            server.shell,
            commands=[
                caddy_apply_command,
                caddy_service_readiness_check_shell(quoted_caddy_container_name),
            ],
        )

    def register_step2(runtime):
        run_commands = [
            run_container_command,
            container_process_running_check_shell(quoted_container_name),
            worker_cleanup_command,
            *worker_run_commands,
            *worker_verify_commands,
        ]
        run_kwargs = {"commands": run_commands}
        if runtime_env_stdin:
            run_kwargs["_stdin"] = runtime_env_stdin

        if has_inline_key:
            runtime.add_operation(
                server.shell,
                commands=[clone_or_update_command],
                _stdin=f"{config.deploy_private_key.rstrip()}\n",
                deploydash_action_id="app_part1_step2_action_sync_repository",
            )
        else:
            runtime.add_operation(
                server.shell,
                commands=[clone_or_update_command],
                deploydash_action_id="app_part1_step2_action_sync_repository",
            )
        runtime.add_operation(
            server.shell,
            commands=[
                source_subdirectory_guard_command,
                build_command,
            ],
            deploydash_action_id="app_part1_step2_action_build_image",
        )
        for volume_name in sqlite_volume_names:
            runtime.add_operation(
                docker.volume,
                volume=volume_name,
                deploydash_action_id="app_part1_step2_action_run_container",
            )
        runtime.add_operation(
            server.shell,
            deploydash_action_id="app_part1_step2_action_run_container",
            **run_kwargs,
        )

    def register_step3(runtime):
        runtime.add_operation(
            server.shell,
            commands=[validate_domain_ownership_command],
        )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_caddy_snippet(config, tls_block=tls_block)),
            dest=config.caddy_snippet_path,
            mode="644",
        )
        runtime.add_operation(
            server.shell,
            commands=[
                sync_caddy_env_command,
                caddy_apply_command,
                caddy_service_readiness_check_shell(quoted_caddy_container_name),
                "HTTP_CODE=\"$(curl -sS -o /dev/null -w '%{http_code}' -H "
                f"'Host: {config.canonical_domain}' "
                'http://127.0.0.1/ 2>/dev/null || echo 000)"; '
                '[ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 500 ]',
                *([redirect_probe_command] if redirect_probe_command is not None else []),
                https_probe_info_command,
                refresh_domain_index_command,
            ],
            _retries=8,
            _retry_delay=3,
        )

    return [
        AppStep(
            id="app_part1_step1_preflight",
            title="Verify prerequisites and ensure Caddy is running",
            part="part1",
            commands=[
                "Verify docker, git, railpack, and deploy prerequisites",
                "Verify Docker root has enough free disk space for image build",
                "Ensure Docker service is active",
                "Validate/start Caddy stack and ensure Caddy container is running",
            ],
            actions=[
                AppAction(
                    id="app_part1_step1_action_verify_prerequisites",
                    label="Verify prerequisites",
                    description="Check deploy binaries, keys, and helper scripts",
                ),
                AppAction(
                    id="app_part1_step1_action_start_caddy",
                    label="Ensure Caddy is running",
                    description="Validate and start/reload Caddy when needed",
                ),
                AppAction(
                    id="app_part1_step1_action_check_disk_space",
                    label="Check Docker disk space",
                    description="Ensure enough free space before Railpack build",
                ),
            ],
            register=register_step1,
        ),
        AppStep(
            id="app_part1_step2_sync_and_build",
            title="Sync repository, build image with Railpack, and run container",
            part="part1",
            commands=[
                "Clone/pull private GitHub repository using project deploy key",
                "Inject runtime environment variables into app container at launch",
                "Reconcile managed worker containers for this project",
                "Prune unused BuildKit cache",
                "Run Railpack prepare + BuildKit frontend build",
                "Run app container with restart policy on Caddy network",
            ],
            actions=[
                AppAction(
                    id="app_part1_step2_action_sync_repository",
                    label="Sync repository",
                    description="Clone or fast-forward repository branch on server",
                ),
                AppAction(
                    id="app_part1_step2_action_sync_runtime_env",
                    label="Inject runtime env",
                    description="Pass app environment variables to docker run",
                ),
                AppAction(
                    id="app_part1_step2_action_build_image",
                    label="Build app image",
                    description="Build container image using Railpack production flow",
                ),
                AppAction(
                    id="app_part1_step2_action_run_container",
                    label="Run app container",
                    description="Start app container with unless-stopped policy",
                ),
                AppAction(
                    id="app_part1_step2_action_run_workers",
                    label="Run worker containers",
                    description="Start configured worker containers with resource limits",
                ),
            ],
            register=register_step2,
        ),
        AppStep(
            id="app_part1_step3_publish_via_caddy",
            title="Publish app through Caddy over HTTP and HTTPS",
            part="part1",
            commands=[
                "Write/update per-project Caddy reverse-proxy snippet",
                "Sync Caddy DNS credential environment variables for this project",
                "Reload Caddy and verify HTTP + HTTPS responses",
            ],
            notes=(
                "HTTP routing is verified immediately after publish. HTTPS may take "
                "a moment longer while certificates are issued; verify DNS A/AAAA "
                "records and firewall 80/443 if issuance does not complete."
            ),
            actions=[
                AppAction(
                    id="app_part1_step3_action_write_caddy_snippet",
                    label="Write Caddy snippet",
                    description="Map primary domain to app container reverse proxy",
                ),
                AppAction(
                    id="app_part1_step3_action_validate_domain_ownership",
                    label="Validate domain ownership",
                    description="Abort if another project already manages requested domains",
                ),
                AppAction(
                    id="app_part1_step3_action_reload_caddy",
                    label="Reload and verify Caddy",
                    description="Apply Caddy config and confirm HTTP routing and redirects",
                ),
            ],
            register=register_step3,
        ),
    ]
