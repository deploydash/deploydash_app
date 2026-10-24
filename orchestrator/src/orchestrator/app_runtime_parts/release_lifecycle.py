# ruff: noqa: F403, F405

from .. import server_identifiers
from ..engine_context import SupportsAppReleaseLifecycle
from ..failure_evidence import FAILURE_EVIDENCE_FIELD
from ._shared import *
from .release_failure_evidence import *
from .release_observability import *


def _worker_container_name(project_slug, worker_id):
    return server_identifiers.worker_container(project_slug, worker_id)


def _run_remote_command(
    ctx: SupportsAppReleaseLifecycle,
    session,
    label,
    command,
    *,
    emit=None,
    timeout=60,
    stdin=None,
    allow_failure=False,
):
    ctx.emit_event(
        emit,
        "app_runtime_action_started",
        f"{label}: started",
    )
    try:
        status, output = session.host.run_shell_command(
            command,
            _timeout=timeout,
            _sudo=True,
            **({"_stdin": stdin} if stdin is not None else {}),
        )
    except Exception as exc:
        sanitize = ctx.sanitize_message or (lambda value: value)
        details = sanitize(str(exc)).strip() or "remote command failed unexpectedly"
        ctx.emit_event(
            emit,
            "app_runtime_action_failed",
            f"{label}: failed",
            level="error",
        )
        return {
            "ok": False,
            "details": details,
            "output": None,
            "exception": details,
        }
    ctx.emit_shell_output_lines(emit, output)
    if not status:
        details = ctx.command_error_details(output)
        if not allow_failure:
            return {
                "ok": False,
                "details": details or "remote command failed",
                "output": output,
            }
        ctx.emit_event(
            emit,
            "app_runtime_action_completed",
            f"{label}: completed",
        )
        return {
            "ok": False,
            "details": details or "remote command failed",
            "output": output,
        }
    ctx.emit_event(
        emit,
        "app_runtime_action_completed",
        f"{label}: completed",
    )
    return {"ok": True, "output": output, "details": None}


def _load_release_manifest(ctx: SupportsAppReleaseLifecycle, host, app_config):
    try:
        manifest_text = ctx.read_remote_file_text(
            host,
            app_config.release_manifest_path,
            timeout=10,
        )
    except RuntimeError as exc:
        details = str(exc).lower()
        if "no such file or directory" in details:
            return empty_release_manifest()
        raise
    return load_manifest_from_text(manifest_text)


def _write_release_manifest(host, app_config, manifest):
    return host.run_shell_command(
        render_manifest_write_command(app_config),
        _timeout=20,
        _sudo=True,
        _stdin=render_manifest_write_payload(manifest),
    )


def _release_inventory_response(manifest):
    releases = sort_releases_newest_first(list(manifest.get("releases", [])))
    return {
        "live_release_id": (live_release_entry(manifest) or {}).get("release_id"),
        "releases": releases,
    }


def _release_failure_inventory_extra(manifest, release_id):
    release_inventory = _release_inventory_response(manifest)
    return {
        "live_release_id": release_inventory["live_release_id"],
        "release_entry": find_release_entry(manifest, release_id),
        "releases": release_inventory["releases"],
        "release_inventory": release_inventory,
    }


def _release_runtime_targets(ctx: SupportsAppReleaseLifecycle, host, app_config):
    manifest = _load_release_manifest(ctx, host, app_config)
    live_release = live_release_entry(manifest)
    if live_release is not None:
        live_release_id = live_release.get("release_id")
        return {
            "manifest": manifest,
            "live_release": live_release,
            "live_release_id": live_release_id,
            "web_container_name": live_release.get("web_container_name")
            or app_config.release_container_name(live_release_id),
            "image_name": live_release.get("image_name")
            or app_config.release_image_name(live_release_id),
            "worker_container_names": [
                item
                for item in live_release.get("worker_container_names", [])
                if isinstance(item, str) and item.strip()
            ],
            "legacy": False,
            "has_previous_live_route": True,
        }
    legacy_container_name = app_config.container_name
    legacy_container_running = _legacy_container_is_running(
        host,
        legacy_container_name,
    )
    return {
        "manifest": manifest,
        "live_release": None,
        "live_release_id": None,
        "web_container_name": legacy_container_name,
        "image_name": app_config.image_name,
        "worker_container_names": [
            _worker_container_name(app_config.project_slug, worker.id)
            for worker in app_config.workers
        ],
        "legacy": True,
        "has_previous_live_route": legacy_container_running,
    }


def _legacy_container_is_running(host, container_name):
    quoted_container_name = shlex.quote(container_name)
    try:
        status, _ = host.run_shell_command(
            "docker inspect -f '{{.State.Running}}' "
            f"{quoted_container_name} 2>/dev/null | grep -qx true",
            _timeout=10,
            _sudo=True,
        )
    except Exception:
        return False
    return bool(status)


def _resolve_commit_sha(ctx: SupportsAppReleaseLifecycle, session, app_config, *, emit=None):
    quoted_source_root = shlex.quote(app_config.source_root)
    command = (
        f"if [ -d {quoted_source_root}/.git ]; then git -C {quoted_source_root} rev-parse HEAD; fi"
    )
    result = _run_remote_command(
        ctx,
        session,
        "Resolve repository commit",
        command,
        emit=emit,
        allow_failure=True,
    )
    if not result["ok"]:
        return None
    output_lines = getattr(result["output"], "stdout_lines", None) or []
    for raw_line in reversed(output_lines):
        line = str(raw_line).strip()
        match = _RELEASE_COMMIT_SHA_RE.search(line)
        if match is not None:
            normalized = normalize_commit_sha(match.group(0))
            if normalized is not None:
                return normalized
    return None


def _build_caddy_apply_command(app_config):
    quoted_caddy_apply_helper = shlex.quote(app_config.caddy_apply_helper)
    quoted_caddy_stack_root = shlex.quote(app_config.caddy_stack_root)
    quoted_caddy_container_name = shlex.quote(app_config.caddy_container_name)
    return (
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


def _build_clone_or_update_command(app_config):
    quoted_source_root = shlex.quote(app_config.source_root)
    quoted_repo_url = shlex.quote(app_config.repository_ssh_url)
    quoted_branch = shlex.quote(app_config.branch)
    quoted_branch_ref = shlex.quote(f"origin/{app_config.branch}")
    quoted_private_key = shlex.quote(app_config.key_private_path)
    quoted_known_hosts = shlex.quote(app_config.key_known_hosts_path)
    quoted_repository_known_hosts = shlex.quote(app_config.repository_known_hosts_path)
    has_inline_key = (
        isinstance(app_config.deploy_private_key, str)
        and app_config.deploy_private_key.strip() != ""
    )
    if has_inline_key:
        repository_host_key_preflight_command = render_repository_host_key_preflight_command(
            app_config
        )
        git_ssh_command = (
            "ssh "
            "-o IdentitiesOnly=no "
            "-o StrictHostKeyChecking=yes "
            f"-o UserKnownHostsFile={quoted_repository_known_hosts} "
            "-o GlobalKnownHostsFile=/dev/null "
        )
        quoted_git_ssh_command = shlex.quote(git_ssh_command)
        selected_branch_fetch_command = render_selected_branch_fetch_command(
            source_root=app_config.source_root,
            branch=app_config.branch,
            git_ssh_command=git_ssh_command,
        )
        command = (
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
        return command, f"{app_config.deploy_private_key.rstrip()}\n"

    git_ssh_command = (
        "ssh "
        f"-i {quoted_private_key} "
        "-o IdentitiesOnly=yes "
        "-o StrictHostKeyChecking=yes "
        f"-o UserKnownHostsFile={quoted_known_hosts}"
    )
    quoted_git_ssh_command = shlex.quote(git_ssh_command)
    selected_branch_fetch_command = render_selected_branch_fetch_command(
        source_root=app_config.source_root,
        branch=app_config.branch,
        git_ssh_command=git_ssh_command,
    )
    command = (
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
    return command, None


def _build_release_image_command(app_config, image_name):
    quoted_source_app_root = shlex.quote(app_config.source_app_root)
    quoted_build_helper = shlex.quote(app_config.railpack_build_helper)
    quoted_railpack_env_file = shlex.quote(app_config.railpack_env_file)
    quoted_railpack_build_command = shlex.quote(app_config.railpack_build_command)
    quoted_railpack_run_command = shlex.quote(app_config.railpack_run_command)
    quoted_plan_path = shlex.quote(app_config.railpack_plan_path)
    quoted_info_path = shlex.quote(app_config.railpack_info_path)
    quoted_image_name = shlex.quote(image_name)
    quoted_provider = (
        shlex.quote(app_config.railpack_provider)
        if app_config.railpack_provider is not None and app_config.railpack_provider.strip()
        else None
    )
    source_subdirectory_guard_command = (
        f"[ -d {quoted_source_app_root} ] || "
        "(echo 'Configured app subdirectory was not found in repository checkout.' "
        ">&2; exit 1)"
    )
    build_env_parts = [f"RAILPACK_ENV_FILE={quoted_railpack_env_file}"]
    if quoted_provider is not None:
        build_env_parts.append(f"RAILPACK_PROVIDER={quoted_provider}")
    if app_config.railpack_build_command.strip():
        build_env_parts.append(f"RAILPACK_BUILD_CMD={quoted_railpack_build_command}")
        build_env_parts.append(f"NIXPACKS_BUILD_CMD={quoted_railpack_build_command}")
    if app_config.railpack_run_command.strip():
        build_env_parts.append(f"RAILPACK_START_CMD={quoted_railpack_run_command}")
        build_env_parts.append(f"NIXPACKS_START_CMD={quoted_railpack_run_command}")
    build_env_prefix = " ".join(build_env_parts) + " "
    if app_config.railpack_node_mode == "runtime":
        build_env_prefix += "RAILPACK_NO_SPA=1 "
    build_command = (
        f"{build_env_prefix}"
        f"{quoted_build_helper} "
        f"{quoted_source_app_root} "
        f"{quoted_image_name} "
        f"{quoted_plan_path} "
        f"{quoted_info_path}"
    )
    return f"{source_subdirectory_guard_command}; {build_command}"


def _build_runtime_env_values(app_config, *, release_entry=None):
    runtime_env_values = dict(app_config.runtime_env)
    if isinstance(release_entry, dict):
        release_runtime_env = release_entry.get("runtime_env")
        if isinstance(release_runtime_env, dict):
            runtime_env_values = {
                str(key): str(value)
                for key, value in release_runtime_env.items()
                if str(key).strip()
            }
    sqlite_storage = app_config.sqlite_storage
    if sqlite_storage is not None:
        runtime_env_values["SQLITE_PATH"] = sqlite_storage.database_path
        runtime_env_values["DATABASE_URL"] = sqlite_storage.database_url
    for mount in app_config.sqlite_snapshot_mounts:
        if mount.path_env_key is not None:
            runtime_env_values[mount.path_env_key] = mount.database_path
        if mount.database_url_env_key is not None:
            runtime_env_values[mount.database_url_env_key] = mount.database_url
    return runtime_env_values


def _build_sqlite_volume_flags(app_config):
    sqlite_storage = app_config.sqlite_storage
    if sqlite_storage is None:
        return ("true", "")
    quoted_sqlite_volume_name = shlex.quote(sqlite_storage.volume_name)
    quoted_sqlite_mount_path = shlex.quote(sqlite_storage.mount_path)
    prepare_command = (
        f"docker volume inspect {quoted_sqlite_volume_name} >/dev/null 2>&1 || "
        f"docker volume create {quoted_sqlite_volume_name} >/dev/null"
    )
    flags = f"-v {quoted_sqlite_volume_name}:{quoted_sqlite_mount_path} "
    return prepare_command, flags


def _build_sqlite_snapshot_flags(app_config):
    prepare_parts = []
    flags = []
    for mount in app_config.sqlite_snapshot_mounts:
        quoted_snapshot_volume = shlex.quote(mount.volume_name)
        quoted_snapshot_mount_path = shlex.quote(mount.mount_path)
        prepare_parts.append(
            f"docker volume inspect {quoted_snapshot_volume} >/dev/null 2>&1 || "
            f"docker volume create {quoted_snapshot_volume} >/dev/null"
        )
        flags.append(f"-v {quoted_snapshot_volume}:{quoted_snapshot_mount_path}:ro")
    prepare_command = "; ".join(prepare_parts) if prepare_parts else "true"
    rendered_flags = " ".join(flags) + (" " if flags else "")
    return prepare_command, rendered_flags


def _build_release_run_command(app_config, *, release_id, image_name, live_label):
    runtime_env_values = _build_runtime_env_values(app_config)
    runtime_env_docker_flags = build_runtime_env_docker_flags(runtime_env_values)
    runtime_env_stdin = render_runtime_env_stdin(runtime_env_values)
    sqlite_prepare_command, sqlite_volume_flags = _build_sqlite_volume_flags(app_config)
    sqlite_snapshot_prepare_command, sqlite_snapshot_flags = _build_sqlite_snapshot_flags(
        app_config
    )
    quoted_container_name = shlex.quote(app_config.release_container_name(release_id))
    quoted_upstream_name = shlex.quote(app_config.release_upstream_name(release_id))
    quoted_caddy_container_name = shlex.quote(app_config.caddy_container_name)
    quoted_image_name = shlex.quote(image_name)
    quoted_app_port = shlex.quote(str(app_config.app_port))
    quoted_project_slug = shlex.quote(app_config.project_slug)
    worker_specs = build_worker_runtime_command_specs(
        project_slug=app_config.project_slug,
        image_name=image_name,
        workers=app_config.workers,
        runtime_env_docker_flags=runtime_env_docker_flags,
        primary_network_env_var="CADDY_NETWORK",
        readonly_volume_docker_flags=sqlite_snapshot_flags,
        trust_network_names=app_config.trust_network_names,
        release_id=release_id,
        live_label=live_label,
    )
    trust_network_suffix = ""
    if app_config.trust_network_names:
        trust_network_list = " ".join(
            shlex.quote(network_name) for network_name in app_config.trust_network_names
        )
        trust_network_suffix += (
            f"for TRUST_NETWORK in {trust_network_list}; do "
            'if [ "${TRUST_NETWORK}" != "${CADDY_NETWORK}" ]; then '
            'docker network inspect "${TRUST_NETWORK}" >/dev/null 2>&1 || '
            'docker network create "${TRUST_NETWORK}" >/dev/null 2>&1; '
            f'docker network connect "${{TRUST_NETWORK}}" {quoted_container_name} '
            ">/dev/null 2>&1 || true; "
            "fi; "
            "done; "
        )
    run_command = (
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
        f"{sqlite_prepare_command}; "
        f"{sqlite_snapshot_prepare_command}; "
        f"docker rm -f {quoted_container_name} >/dev/null 2>&1 || true; "
        "docker run -d "
        f"--name {quoted_container_name} "
        "--restart unless-stopped "
        '--network "${CADDY_NETWORK}" '
        f"--network-alias {quoted_upstream_name} "
        "--add-host host.docker.internal:host-gateway "
        f"{docker_runtime_security_flags(profile=ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING)} "
        f"{sqlite_volume_flags} "
        f"{sqlite_snapshot_flags} "
        f"{runtime_env_docker_flags} "
        f"-e PORT={quoted_app_port} "
        f"--label {server_identifiers.MANAGED_LABEL_PAIR} "
        f"--label {server_identifiers.LABEL_PROJECT}={quoted_project_slug} "
        f"--label {server_identifiers.LABEL_RELEASE_ID}={shlex.quote(release_id)} "
        f"--label {server_identifiers.LABEL_LIVE}={shlex.quote(live_label)} "
        f"{quoted_image_name}; "
        f"{trust_network_suffix}"
        f"{container_process_running_check_shell(quoted_container_name)}"
    )
    worker_run_commands = [spec.run_command for spec in worker_specs if spec.worker.enabled]
    worker_verify_commands = [spec.verify_command for spec in worker_specs if spec.worker.enabled]
    project_label = f"{server_identifiers.LABEL_PROJECT}={app_config.project_slug}"
    release_label = f"{server_identifiers.LABEL_RELEASE_ID}={release_id}"
    role_label = f"{server_identifiers.LABEL_ROLE}={server_identifiers.ROLE_WORKER}"
    worker_cleanup_command = (
        "docker ps -a "
        f"--filter label={shlex.quote(project_label)} "
        f"--filter label={shlex.quote(release_label)} "
        f"--filter label={role_label} "
        "--format '{{.Names}}' | xargs -r docker rm -f >/dev/null 2>&1 || true"
    )
    return {
        "run_command": run_command,
        "worker_cleanup_command": worker_cleanup_command,
        "worker_run_commands": worker_run_commands,
        "worker_verify_commands": worker_verify_commands,
        "runtime_env_stdin": runtime_env_stdin,
    }


def _release_route_target(app_config, *, release_id=None, container_name=None, legacy=False):
    if not legacy and isinstance(release_id, str) and release_id.strip():
        return app_config.release_upstream_name(release_id)
    if isinstance(container_name, str) and container_name.strip():
        return container_name
    return app_config.container_name


def _public_health_probe_command(app_config):
    canonical_domain = app_config.canonical_domain
    if not app_config.public_health_check_enabled or not canonical_domain:
        return None
    quoted_http_resolve = shlex.quote(f"{canonical_domain}:80:127.0.0.1")
    quoted_https_resolve = shlex.quote(f"{canonical_domain}:443:127.0.0.1")
    quoted_url = shlex.quote(f"http://{canonical_domain}{app_config.public_health_check_path}")
    return (
        "CURL_EXIT=0; CODE=000; "
        'CODE="$(curl -sS -L --max-redirs 5 --connect-timeout 5 '
        "--max-time 20 -o /dev/null -w '%{http_code}' "
        f"--resolve {quoted_http_resolve} --resolve {quoted_https_resolve} "
        f'{quoted_url} 2>/dev/null)" || CURL_EXIT=$?; '
        f'printf \'{_PUBLIC_HEALTH_MARKER}%s|%s\\n\' "${{CURL_EXIT}}" "${{CODE}}"'
    )


def _public_health_error(curl_exit):
    if curl_exit == 6:
        return "dns"
    if curl_exit == 7:
        return "connection"
    if curl_exit == 28:
        return "timeout"
    if curl_exit in (35, 51, 58, 60):
        return "tls"
    return "request_failed"


def _public_health_from_output(app_config, output):
    checked_at = utc_now_iso()
    if not app_config.public_health_check_enabled:
        return {
            "enabled": False,
            "status": "skipped",
            "path": app_config.public_health_check_path,
            "http_status": None,
            "checked_at": None,
            "error": None,
        }
    if not app_config.canonical_domain:
        return {
            "enabled": True,
            "status": "unknown",
            "path": app_config.public_health_check_path,
            "http_status": None,
            "checked_at": checked_at,
            "error": "domain_not_configured",
        }

    output_lines = getattr(output, "stdout_lines", None) or []
    for raw_line in output_lines:
        line = str(raw_line).strip()
        if not line.startswith(_PUBLIC_HEALTH_MARKER):
            continue
        parts = line[len(_PUBLIC_HEALTH_MARKER) :].split("|", 1)
        if len(parts) != 2:
            break
        try:
            curl_exit = int(parts[0])
        except (TypeError, ValueError):
            break
        try:
            http_status = int(parts[1])
        except (TypeError, ValueError):
            http_status = None
        if http_status is not None and not 100 <= http_status <= 599:
            http_status = None
        healthy = curl_exit == 0 and http_status is not None and 200 <= http_status < 400
        return {
            "enabled": True,
            "status": "healthy" if healthy else "unhealthy",
            "path": app_config.public_health_check_path,
            "http_status": http_status,
            "checked_at": checked_at,
            "error": None
            if healthy
            else ("http_error" if curl_exit == 0 else _public_health_error(curl_exit)),
        }

    return {
        "enabled": True,
        "status": "unknown",
        "path": app_config.public_health_check_path,
        "http_status": None,
        "checked_at": checked_at,
        "error": "result_unavailable",
    }


def _probe_public_health(ctx: SupportsAppReleaseLifecycle, session, app_config, *, emit=None):
    command = _public_health_probe_command(app_config)
    if command is None:
        return _public_health_from_output(app_config, None)
    result = _run_remote_command(
        ctx,
        session,
        f"Check public URL at {app_config.public_health_check_path}",
        command,
        emit=emit,
        allow_failure=True,
    )
    return _public_health_from_output(app_config, result.get("output"))


def _release_worker_container_names(app_config, release_id):
    return [
        app_config.release_worker_container_name(release_id, worker.id)
        for worker in app_config.workers
    ]


def _legacy_worker_container_names(app_config):
    # Same per-worker name, not the pre-worker-id shape; a twin function until T-3.4.2.
    return [_worker_container_name(app_config.project_slug, w.id) for w in app_config.workers]


def _write_caddy_route(
    ctx: SupportsAppReleaseLifecycle, session, app_config, *, target_container_name, emit=None
):
    tls_block, dns_env_vars = _dns_tls_block_and_env(app_config)
    sync_caddy_env_command = _build_caddy_env_sync_command(app_config, dns_env_vars)
    quoted_snippet_path = shlex.quote(app_config.caddy_snippet_path)
    rendered_snippet = _render_caddy_snippet(
        app_config,
        tls_block=tls_block,
        upstream_container_name=target_container_name,
    )
    write_command = (
        f"mkdir -p {shlex.quote(app_config.caddy_stack_root + '/caddy/conf.d')}; "
        f"cat > {quoted_snippet_path} <<'EOF'\n{rendered_snippet}\nEOF\n"
    )
    result = _run_remote_command(
        ctx,
        session,
        "Write Caddy route",
        write_command,
        emit=emit,
    )
    if not result["ok"]:
        return result
    result = _run_remote_command(
        ctx,
        session,
        "Sync Caddy DNS environment",
        sync_caddy_env_command,
        emit=emit,
    )
    if not result["ok"]:
        return result
    return _run_remote_command(
        ctx,
        session,
        "Reload Caddy",
        _build_caddy_apply_command(app_config),
        emit=emit,
    )


def _restore_or_remove_caddy_route(
    ctx: SupportsAppReleaseLifecycle,
    session,
    app_config,
    *,
    previous_route_target=None,
    emit=None,
):
    if isinstance(previous_route_target, str) and previous_route_target.strip():
        result = _write_caddy_route(
            ctx,
            session,
            app_config,
            target_container_name=previous_route_target,
            emit=emit,
        )
        return {
            **result,
            "action": "restored" if result.get("ok") else "failed",
        }

    remove_result = _run_remote_command(
        ctx,
        session,
        "Remove candidate Caddy route",
        f"rm -f {shlex.quote(app_config.caddy_snippet_path)}",
        emit=emit,
        allow_failure=True,
    )
    if not remove_result["ok"]:
        return {**remove_result, "action": "failed"}

    reload_result = _run_remote_command(
        ctx,
        session,
        "Reload Caddy after route cleanup",
        _build_caddy_apply_command(app_config),
        emit=emit,
        allow_failure=True,
    )
    return {
        **reload_result,
        "action": "removed" if reload_result["ok"] else "failed",
    }


def _cleanup_failed_release_after_route_cutover(
    ctx: SupportsAppReleaseLifecycle,
    session,
    app_config,
    *,
    manifest,
    release_id,
    rollback_from_release_id,
    previous_route_target=None,
    image_name,
    rollback_reason,
    emit=None,
):
    try:
        route_cleanup = _restore_or_remove_caddy_route(
            ctx,
            session,
            app_config,
            previous_route_target=previous_route_target,
            emit=emit,
        )
    except Exception as exc:
        sanitize = ctx.sanitize_message or (lambda value: value)
        route_cleanup = {
            "ok": False,
            "action": "failed",
            "details": sanitize(str(exc)),
            "output": None,
        }
    _remove_release_runtime(
        ctx,
        session,
        web_container_name=app_config.release_container_name(release_id),
        worker_container_names=_release_worker_container_names(app_config, release_id),
        image_name=image_name,
        emit=emit,
        remove_image=False,
    )
    manifest = mark_release_failed(
        manifest,
        release_id=release_id,
        rollback_from_release_id=rollback_from_release_id,
        rollback_reason=rollback_reason,
    )
    _write_release_manifest(session.host, app_config, manifest)
    return {"manifest": manifest, "route_cleanup": route_cleanup}


def _route_cleanup_extra(route_cleanup):
    if not isinstance(route_cleanup, dict):
        return {"route_cleanup_status": "failed", "route_cleanup_details": None}
    result = {"route_cleanup_status": route_cleanup.get("action", "failed")}
    if not route_cleanup.get("ok"):
        result["route_cleanup_details"] = route_cleanup.get("details")
    return result


def _set_release_live_labels(
    ctx: SupportsAppReleaseLifecycle,
    session,
    *,
    web_container_name,
    worker_container_names,
    live_value,
    emit=None,
):
    ctx.emit_event(
        emit,
        "app_runtime_action_started",
        "Update release labels: skipped",
    )
    ctx.emit_event(
        emit,
        "app_runtime_action_completed",
        "Update release labels: completed",
    )
    return {"ok": True, "details": None, "output": None}


def _remove_release_runtime(
    ctx: SupportsAppReleaseLifecycle,
    session,
    *,
    web_container_name,
    worker_container_names,
    image_name=None,
    emit=None,
    remove_image=False,
):
    commands = [f"docker rm -f {shlex.quote(web_container_name)} >/dev/null 2>&1 || true"]
    for worker_container_name in worker_container_names:
        commands.append(
            f"docker rm -f {shlex.quote(worker_container_name)} >/dev/null 2>&1 || true"
        )
    if remove_image and isinstance(image_name, str) and image_name.strip():
        commands.append(f"docker image rm {shlex.quote(image_name)} >/dev/null 2>&1 || true")
    return _run_remote_command(
        ctx,
        session,
        "Remove release runtime",
        "; ".join(commands),
        emit=emit,
        allow_failure=True,
    )


def _stop_release_runtime(
    ctx: SupportsAppReleaseLifecycle,
    session,
    *,
    web_container_name,
    worker_container_names,
    emit=None,
):
    commands = [f"docker rm -f {shlex.quote(web_container_name)} >/dev/null 2>&1 || true"]
    for worker_container_name in worker_container_names:
        commands.append(
            f"docker rm -f {shlex.quote(worker_container_name)} >/dev/null 2>&1 || true"
        )
    return _run_remote_command(
        ctx,
        session,
        "Stop previous release runtime",
        "; ".join(commands),
        emit=emit,
        allow_failure=True,
    )


def _probe_candidate_release(
    ctx: SupportsAppReleaseLifecycle,
    session,
    app_config,
    *,
    container_name,
    emit=None,
    capture_evidence=False,
):
    commands = list(
        zip(
            _RELEASE_PROBE_PATHS,
            _candidate_probe_commands(app_config, container_name=container_name),
            strict=False,
        )
    )
    last_result = None
    last_probe = None
    for attempt in range(_RELEASE_CANDIDATE_PROBE_ATTEMPTS):
        for path, command in commands:
            result = _run_remote_command(
                ctx,
                session,
                f"Probe candidate release at {path}",
                command,
                emit=emit,
                allow_failure=True,
            )
            last_result = result
            last_probe = _release_probe_from_result(result, fallback_path=path)
            if result["ok"]:
                payload = {"ok": True, "path": path}
                if capture_evidence:
                    payload.update({"result": result, "probe": last_probe})
                return payload
        if attempt < _RELEASE_CANDIDATE_PROBE_ATTEMPTS - 1:
            release_sleep(_RELEASE_CANDIDATE_PROBE_DELAY_SECONDS)
    payload = {"ok": False, "path": None}
    if capture_evidence:
        payload.update({"result": last_result, "probe": last_probe})
    return payload


def _probe_routed_release(
    ctx: SupportsAppReleaseLifecycle,
    session,
    app_config,
    *,
    path,
    emit=None,
    capture_evidence=False,
):
    routed_commands = dict(
        zip(
            _RELEASE_PROBE_PATHS,
            _routed_probe_commands(app_config),
            strict=False,
        )
    )
    if path not in routed_commands:
        payload = {"ok": False, "path": None}
        if capture_evidence:
            payload.update({"result": None, "probe": None})
        return payload
    probe_paths = (
        path,
        *(
            candidate_path
            for candidate_path in _RELEASE_PROBE_PATHS
            if candidate_path != path and candidate_path in routed_commands
        ),
    )
    last_result = None
    last_probe = None
    for attempt in range(_RELEASE_ROUTED_PROBE_ATTEMPTS):
        for candidate_path in probe_paths:
            result = _run_remote_command(
                ctx,
                session,
                f"Probe routed release at {candidate_path}",
                routed_commands[candidate_path],
                emit=emit,
                allow_failure=True,
            )
            last_result = result
            last_probe = _release_probe_from_result(
                result,
                fallback_path=candidate_path,
            )
            if result["ok"]:
                payload = {"ok": True, "path": candidate_path}
                if capture_evidence:
                    payload.update({"result": result, "probe": last_probe})
                return payload
        if attempt < _RELEASE_ROUTED_PROBE_ATTEMPTS - 1:
            release_sleep(_RELEASE_ROUTED_PROBE_DELAY_SECONDS)
    payload = {"ok": False, "path": None}
    if capture_evidence:
        payload.update({"result": last_result, "probe": last_probe})
    return payload


def _collect_release_runtime_logs(
    ctx: SupportsAppReleaseLifecycle,
    session,
    *,
    container_name,
    emit=None,
    tail_lines=80,
):
    quoted_container_name = shlex.quote(container_name)
    return _run_remote_command(
        ctx,
        session,
        "Collect candidate release runtime logs",
        "if docker inspect "
        f"{quoted_container_name} >/dev/null 2>&1; then "
        f"docker logs --tail {tail_lines} --timestamps {quoted_container_name}; "
        "else "
        "echo 'Candidate app container is not present on server.' >&2; "
        "exit 1; "
        "fi",
        emit=emit,
        allow_failure=True,
    )


def _verify_release_workers_running(
    ctx: SupportsAppReleaseLifecycle,
    session,
    *,
    worker_container_names,
    emit=None,
    capture_evidence=False,
):
    for worker_container_name in worker_container_names:
        result = _run_remote_command(
            ctx,
            session,
            f"Verify worker process {worker_container_name}",
            worker_process_check_shell(shlex.quote(worker_container_name)),
            emit=emit,
            allow_failure=True,
        )
        if not result["ok"]:
            payload = {
                "ok": False,
                "worker_container_name": worker_container_name,
            }
            if capture_evidence:
                payload["result"] = result
            return payload
    payload = {"ok": True, "worker_container_name": None}
    if capture_evidence:
        payload["result"] = None
    return payload


def _prune_release_artifacts(
    ctx: SupportsAppReleaseLifecycle, session, app_config, manifest, *, emit=None
):
    prune_candidates = release_prune_candidates(manifest)
    if not prune_candidates:
        return {"manifest": manifest, "pruned_release_ids": []}
    pruned_release_ids = []
    for entry in prune_candidates:
        release_id = entry.get("release_id")
        if not isinstance(release_id, str) or not release_id:
            continue
        _remove_release_runtime(
            ctx,
            session,
            web_container_name=entry.get("web_container_name")
            or app_config.release_container_name(release_id),
            worker_container_names=[
                item
                for item in entry.get("worker_container_names", [])
                if isinstance(item, str) and item.strip()
            ],
            image_name=entry.get("image_name"),
            emit=emit,
            remove_image=True,
        )
        pruned_release_ids.append(release_id)
    manifest = prune_release_entries(manifest, pruned_release_ids)
    return {"manifest": manifest, "pruned_release_ids": pruned_release_ids}


def _execute_versioned_release_deploy(
    ctx: SupportsAppReleaseLifecycle,
    *,
    session,
    app_config,
    normalized_parts,
    emit=None,
    is_cancelled=None,
):
    summary_data = {
        "project_slug": app_config.project_slug,
        "repository_full_name": app_config.repository_full_name,
        "branch": app_config.branch,
        "primary_domain": app_config.primary_domain,
        "app_port": app_config.app_port,
        "app_subdirectory": app_config.app_subdirectory,
        "container_name": app_config.container_name,
        "image_name": app_config.image_name,
        "http_url": app_config.app_http_url,
        "https_url": app_config.app_https_url,
        "parts": normalized_parts,
    }
    clone_command, clone_stdin = _build_clone_or_update_command(app_config)
    clone_result = _run_remote_command(
        ctx,
        session,
        "Sync repository",
        clone_command,
        emit=emit,
        stdin=clone_stdin,
    )
    if not clone_result["ok"]:
        confirmation = parse_repository_host_key_confirmation_output(
            clone_result.get("output"),
        )
        if confirmation is not None:
            return ctx.error_result(
                REPOSITORY_HOST_KEY_CONFIRMATION_CODE,
                "Confirm the repository SSH identity before Deploy Dash clones this app.",
                stage="sync_repository",
                details=clone_result["details"],
                extra={
                    **summary_data,
                    "repository_host_key_confirmation_required": True,
                    "repository_host_key_confirmation": confirmation,
                },
            )
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Sync repository failed.",
            stage="execute_runtime_operation",
            details=clone_result["details"],
            extra={
                FAILURE_EVIDENCE_FIELD: _failure_evidence_from_result(
                    ctx,
                    phase="repository_sync",
                    source="failed_operation",
                    result=clone_result,
                ),
            },
        )

    commit_sha = _resolve_commit_sha(ctx, session, app_config, emit=emit)
    release_id = build_release_id(commit_sha)
    release_image_name = app_config.release_image_name(release_id)
    previous_targets = _release_runtime_targets(ctx, session.host, app_config)
    previous_live_release = previous_targets["live_release"]
    previous_live_release_id = previous_targets["live_release_id"]
    previous_web_container_name = previous_targets["web_container_name"]
    previous_worker_container_names = previous_targets["worker_container_names"]
    has_previous_live_route = previous_targets.get(
        "has_previous_live_route",
        previous_live_release is not None,
    )
    previous_route_target = _release_route_target(
        app_config,
        release_id=previous_live_release_id,
        container_name=previous_web_container_name,
        legacy=previous_targets["legacy"],
    )

    candidate_release_entry = release_entry_from_config(
        app_config,
        release_id=release_id,
        commit_sha=commit_sha,
        status="candidate",
        deployment_kind="deploy",
        image_name=release_image_name,
    )
    manifest = append_or_replace_release(
        previous_targets["manifest"],
        candidate_release_entry,
    )
    _write_release_manifest(session.host, app_config, manifest)

    build_result = _run_remote_command(
        ctx,
        session,
        "Build release image",
        _build_release_image_command(app_config, release_image_name),
        emit=emit,
        timeout=1800,
    )
    if not build_result["ok"]:
        manifest = mark_release_failed(
            manifest,
            release_id=release_id,
            rollback_from_release_id=previous_live_release_id,
            rollback_reason="build_failed",
        )
        _write_release_manifest(session.host, app_config, manifest)
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Build release image failed.",
            stage="execute_runtime_operation",
            details=build_result["details"],
            extra={
                **summary_data,
                "release_id": release_id,
                "commit_sha": commit_sha,
                "cutover_status": "not_started",
                "rollback_status": "not_required",
                FAILURE_EVIDENCE_FIELD: _failure_evidence_from_result(
                    ctx,
                    phase="build",
                    source="failed_operation",
                    result=build_result,
                ),
                **_release_failure_inventory_extra(manifest, release_id),
            },
        )

    candidate_runtime = _build_release_run_command(
        app_config,
        release_id=release_id,
        image_name=release_image_name,
        live_label="false",
    )
    _run_remote_command(
        ctx,
        session,
        "Remove stale candidate workers",
        candidate_runtime["worker_cleanup_command"],
        emit=emit,
        allow_failure=True,
    )
    candidate_run_result = _run_remote_command(
        ctx,
        session,
        "Start candidate release runtime",
        candidate_runtime["run_command"],
        emit=emit,
        stdin=candidate_runtime["runtime_env_stdin"],
    )
    if not candidate_run_result["ok"]:
        manifest = mark_release_failed(
            manifest,
            release_id=release_id,
            rollback_from_release_id=previous_live_release_id,
            rollback_reason="candidate_start_failed",
        )
        _remove_release_runtime(
            ctx,
            session,
            web_container_name=app_config.release_container_name(release_id),
            worker_container_names=_release_worker_container_names(
                app_config,
                release_id,
            ),
            image_name=release_image_name,
            emit=emit,
            remove_image=False,
        )
        _write_release_manifest(session.host, app_config, manifest)
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Start candidate release runtime failed.",
            stage="execute_runtime_operation",
            details=candidate_run_result["details"],
            extra={
                **summary_data,
                "release_id": release_id,
                "commit_sha": commit_sha,
                "cutover_status": "not_started",
                "rollback_status": "not_required",
                FAILURE_EVIDENCE_FIELD: _failure_evidence_from_result(
                    ctx,
                    phase="candidate_start",
                    source="failed_operation",
                    result=candidate_run_result,
                ),
                **_release_failure_inventory_extra(manifest, release_id),
            },
        )

    for worker_run_command in candidate_runtime["worker_run_commands"]:
        worker_run_result = _run_remote_command(
            ctx,
            session,
            "Start candidate worker",
            worker_run_command,
            emit=emit,
            allow_failure=True,
        )
        if not worker_run_result["ok"]:
            manifest = mark_release_failed(
                manifest,
                release_id=release_id,
                rollback_from_release_id=previous_live_release_id,
                rollback_reason="candidate_worker_start_failed",
            )
            _remove_release_runtime(
                ctx,
                session,
                web_container_name=app_config.release_container_name(release_id),
                worker_container_names=_release_worker_container_names(
                    app_config,
                    release_id,
                ),
                image_name=release_image_name,
                emit=emit,
                remove_image=False,
            )
            _write_release_manifest(session.host, app_config, manifest)
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Start candidate worker failed.",
                stage="execute_runtime_operation",
                details=worker_run_result["details"],
                extra={
                    **summary_data,
                    "release_id": release_id,
                    "commit_sha": commit_sha,
                    "cutover_status": "not_started",
                    "rollback_status": "not_required",
                    FAILURE_EVIDENCE_FIELD: _failure_evidence_from_result(
                        ctx,
                        phase="candidate_start",
                        source="failed_operation",
                        result=worker_run_result,
                    ),
                    **_release_failure_inventory_extra(manifest, release_id),
                },
            )
    worker_verify_result = _verify_release_workers_running(
        ctx,
        session,
        worker_container_names=_release_worker_container_names(app_config, release_id),
        emit=emit,
        capture_evidence=True,
    )
    if not worker_verify_result["ok"]:
        manifest = mark_release_failed(
            manifest,
            release_id=release_id,
            rollback_from_release_id=previous_live_release_id,
            rollback_reason="candidate_worker_verify_failed",
        )
        _remove_release_runtime(
            ctx,
            session,
            web_container_name=app_config.release_container_name(release_id),
            worker_container_names=_release_worker_container_names(
                app_config,
                release_id,
            ),
            image_name=release_image_name,
            emit=emit,
            remove_image=False,
        )
        _write_release_manifest(session.host, app_config, manifest)
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Verify candidate worker process state failed.",
            stage="execute_runtime_operation",
            details=worker_verify_result["worker_container_name"],
            extra={
                **summary_data,
                "release_id": release_id,
                "commit_sha": commit_sha,
                "cutover_status": "not_started",
                "rollback_status": "not_required",
                FAILURE_EVIDENCE_FIELD: _failure_evidence_from_result(
                    ctx,
                    phase="candidate_start",
                    source="failed_operation",
                    result=worker_verify_result.get("result"),
                ),
                **_release_failure_inventory_extra(manifest, release_id),
            },
        )

    candidate_probe_result = _probe_candidate_release(
        ctx,
        session,
        app_config,
        container_name=app_config.release_container_name(release_id),
        emit=emit,
        capture_evidence=True,
    )
    if not candidate_probe_result["ok"]:
        log_result = _collect_release_runtime_logs(
            ctx,
            session,
            container_name=app_config.release_container_name(release_id),
            emit=emit,
        )
        failure_evidence = _failure_evidence_from_result(
            ctx,
            phase="candidate_readiness",
            source="candidate_runtime",
            result=log_result,
            probe=candidate_probe_result.get("probe"),
            probe_source="candidate_probe",
        )
        runtime_log_excerpt = _runtime_log_excerpt_from_evidence(failure_evidence)
        manifest = mark_release_failed(
            manifest,
            release_id=release_id,
            rollback_from_release_id=previous_live_release_id,
            rollback_reason="candidate_probe_failed",
        )
        _remove_release_runtime(
            ctx,
            session,
            web_container_name=app_config.release_container_name(release_id),
            worker_container_names=_release_worker_container_names(
                app_config,
                release_id,
            ),
            image_name=release_image_name,
            emit=emit,
            remove_image=False,
        )
        _write_release_manifest(session.host, app_config, manifest)
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Candidate release did not pass readiness probes.",
            stage="execute_runtime_operation",
            extra={
                **summary_data,
                "release_id": release_id,
                "commit_sha": commit_sha,
                "cutover_status": "pre_cutover_probe_failed",
                "rollback_status": "not_required",
                "readiness_failure_summary": _readiness_failure_summary(
                    runtime_log_excerpt,
                ),
                "runtime_log_excerpt": runtime_log_excerpt,
                "runtime_log_source": "failed_candidate",
                "runtime_log_container_name": app_config.release_container_name(release_id),
                FAILURE_EVIDENCE_FIELD: failure_evidence,
                **_release_failure_inventory_extra(manifest, release_id),
            },
        )

    try:
        caddy_result = _write_caddy_route(
            ctx,
            session,
            app_config,
            target_container_name=app_config.release_upstream_name(release_id),
            emit=emit,
        )
    except Exception as exc:
        sanitize = ctx.sanitize_message or (lambda value: value)
        failure_evidence = _failure_evidence_from_result(
            ctx,
            phase="traffic_switch",
            source="exception",
            result={"exception": sanitize(str(exc))},
        )
        cleanup_result = _cleanup_failed_release_after_route_cutover(
            ctx,
            session,
            app_config,
            manifest=manifest,
            release_id=release_id,
            rollback_from_release_id=previous_live_release_id,
            previous_route_target=(previous_route_target if has_previous_live_route else None),
            image_name=release_image_name,
            rollback_reason="caddy_cutover_exception",
            emit=emit,
        )
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Switch live traffic to candidate release failed.",
            stage="execute_runtime_operation",
            details=sanitize(str(exc)),
            extra={
                **summary_data,
                "release_id": release_id,
                "commit_sha": commit_sha,
                "cutover_status": "traffic_switch_failed",
                "rollback_status": "reverted_to_previous_live"
                if has_previous_live_route
                else "not_required",
                FAILURE_EVIDENCE_FIELD: failure_evidence,
                **_route_cleanup_extra(cleanup_result["route_cleanup"]),
                **_release_failure_inventory_extra(cleanup_result["manifest"], release_id),
            },
        )
    if not caddy_result["ok"]:
        failure_evidence = _failure_evidence_from_result(
            ctx,
            phase="traffic_switch",
            source="failed_operation",
            result=caddy_result,
        )
        cleanup_result = _cleanup_failed_release_after_route_cutover(
            ctx,
            session,
            app_config,
            manifest=manifest,
            release_id=release_id,
            rollback_from_release_id=previous_live_release_id,
            previous_route_target=(previous_route_target if has_previous_live_route else None),
            image_name=release_image_name,
            rollback_reason="caddy_cutover_failed",
            emit=emit,
        )
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Switch live traffic to candidate release failed.",
            stage="execute_runtime_operation",
            details=caddy_result["details"],
            extra={
                **summary_data,
                "release_id": release_id,
                "commit_sha": commit_sha,
                "cutover_status": "traffic_switch_failed",
                "rollback_status": "reverted_to_previous_live"
                if has_previous_live_route
                else "not_required",
                FAILURE_EVIDENCE_FIELD: failure_evidence,
                **_route_cleanup_extra(cleanup_result["route_cleanup"]),
                **_release_failure_inventory_extra(cleanup_result["manifest"], release_id),
            },
        )

    try:
        for attempt in range(_RELEASE_STABILIZATION_ATTEMPTS):
            if callable(is_cancelled) and is_cancelled():
                cleanup_result = _cleanup_failed_release_after_route_cutover(
                    ctx,
                    session,
                    app_config,
                    manifest=manifest,
                    release_id=release_id,
                    rollback_from_release_id=previous_live_release_id,
                    previous_route_target=(
                        previous_route_target if has_previous_live_route else None
                    ),
                    image_name=release_image_name,
                    rollback_reason="candidate_cancelled_after_cutover",
                    emit=emit,
                )
                return ctx.error_result(
                    "ENGINE_TASK_CANCELLED",
                    "Web app deployment cancelled after traffic switch.",
                    stage="execute_runtime_operation",
                    extra={
                        **summary_data,
                        "release_id": release_id,
                        "commit_sha": commit_sha,
                        "cutover_status": "cancelled_after_traffic_switch",
                        "rollback_status": "reverted_to_previous_live"
                        if has_previous_live_route
                        else "not_required",
                        "rollback_from_release_id": previous_live_release_id,
                        **_route_cleanup_extra(cleanup_result["route_cleanup"]),
                        **_release_failure_inventory_extra(cleanup_result["manifest"], release_id),
                    },
                )
            routed_probe_result = _probe_routed_release(
                ctx,
                session,
                app_config,
                path=candidate_probe_result["path"],
                emit=emit,
                capture_evidence=True,
            )
            worker_verify_result = _verify_release_workers_running(
                ctx,
                session,
                worker_container_names=_release_worker_container_names(
                    app_config,
                    release_id,
                ),
                emit=emit,
                capture_evidence=True,
            )
            if not routed_probe_result["ok"] or not worker_verify_result["ok"]:
                if attempt < _RELEASE_STABILIZATION_ATTEMPTS - 1:
                    ctx.emit_event(
                        emit,
                        "app_release_stabilization_retry",
                        "Traffic switch is still settling; retrying routed readiness check.",
                    )
                    release_sleep(_RELEASE_STABILIZATION_DELAY_SECONDS)
                    continue
                log_result = _collect_release_runtime_logs(
                    ctx,
                    session,
                    container_name=app_config.release_container_name(release_id),
                    emit=emit,
                )
                evidence_result, evidence_source = _stabilization_evidence_result(
                    ctx,
                    log_result,
                    worker_verify_result,
                )
                failure_evidence = _failure_evidence_from_result(
                    ctx,
                    phase="post_cutover_stabilization",
                    source=evidence_source,
                    result=evidence_result,
                    probe=(
                        routed_probe_result.get("probe") if not routed_probe_result["ok"] else None
                    ),
                    probe_source="routed_probe",
                )
                cleanup_result = _cleanup_failed_release_after_route_cutover(
                    ctx,
                    session,
                    app_config,
                    manifest=manifest,
                    release_id=release_id,
                    rollback_from_release_id=previous_live_release_id,
                    previous_route_target=(
                        previous_route_target if has_previous_live_route else None
                    ),
                    image_name=release_image_name,
                    rollback_reason="post_cutover_stabilization_failed",
                    emit=emit,
                )
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Candidate release failed post-cutover stabilization and was reverted.",
                    stage="execute_runtime_operation",
                    extra={
                        **summary_data,
                        "release_id": release_id,
                        "commit_sha": commit_sha,
                        "cutover_status": "reverted_after_stabilization_failure",
                        "rollback_status": "reverted_to_previous_live"
                        if has_previous_live_route
                        else "not_required",
                        "rollback_from_release_id": previous_live_release_id,
                        FAILURE_EVIDENCE_FIELD: failure_evidence,
                        **_route_cleanup_extra(cleanup_result["route_cleanup"]),
                        **_release_failure_inventory_extra(cleanup_result["manifest"], release_id),
                    },
                )
            if attempt < _RELEASE_STABILIZATION_ATTEMPTS - 1:
                release_sleep(_RELEASE_STABILIZATION_DELAY_SECONDS)
    except Exception as exc:
        sanitize = ctx.sanitize_message or (lambda value: value)
        failure_evidence = _failure_evidence_from_result(
            ctx,
            phase="post_cutover_stabilization",
            source="exception",
            result={"exception": sanitize(str(exc))},
        )
        cleanup_result = _cleanup_failed_release_after_route_cutover(
            ctx,
            session,
            app_config,
            manifest=manifest,
            release_id=release_id,
            rollback_from_release_id=previous_live_release_id,
            previous_route_target=(previous_route_target if has_previous_live_route else None),
            image_name=release_image_name,
            rollback_reason="post_cutover_exception",
            emit=emit,
        )
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Candidate release ended unexpectedly after traffic was switched.",
            stage="execute_runtime_operation",
            details=sanitize(str(exc)),
            extra={
                **summary_data,
                "release_id": release_id,
                "commit_sha": commit_sha,
                "cutover_status": "reverted_after_unexpected_error",
                "rollback_status": "reverted_to_previous_live"
                if has_previous_live_route
                else "not_required",
                "rollback_from_release_id": previous_live_release_id,
                FAILURE_EVIDENCE_FIELD: failure_evidence,
                **_route_cleanup_extra(cleanup_result["route_cleanup"]),
                **_release_failure_inventory_extra(cleanup_result["manifest"], release_id),
            },
        )

    public_health = _probe_public_health(ctx, session, app_config, emit=emit)

    manifest = set_live_release(
        manifest,
        live_release_id=release_id,
        retained_release_id=previous_live_release_id,
    )
    append_or_replace_release(
        manifest,
        {
            **find_release_entry(manifest, release_id),
            "status": "live",
            "live_at": utc_now_iso(),
        },
    )
    _set_release_live_labels(
        ctx,
        session,
        web_container_name=app_config.release_container_name(release_id),
        worker_container_names=_release_worker_container_names(app_config, release_id),
        live_value="true",
        emit=emit,
    )
    if previous_live_release is not None:
        _set_release_live_labels(
            ctx,
            session,
            web_container_name=previous_live_release.get("web_container_name")
            or previous_web_container_name,
            worker_container_names=previous_live_release.get("worker_container_names", []),
            live_value="false",
            emit=emit,
        )
    _run_remote_command(
        ctx,
        session,
        "Retag live image alias",
        f"docker tag {shlex.quote(release_image_name)} {shlex.quote(app_config.image_name)}",
        emit=emit,
        allow_failure=True,
    )
    if has_previous_live_route:
        _stop_release_runtime(
            ctx,
            session,
            web_container_name=previous_web_container_name,
            worker_container_names=previous_worker_container_names,
            emit=emit,
        )
    prune_result = _prune_release_artifacts(
        ctx,
        session,
        app_config,
        manifest,
        emit=emit,
    )
    manifest = prune_result["manifest"]
    _write_release_manifest(session.host, app_config, manifest)
    release_inventory = _release_inventory_response(manifest)
    successful_releases = [
        entry
        for entry in manifest.get("releases", [])
        if entry.get("status") in ("live", "retained")
    ]
    return {
        "status": "success",
        "msg": "Web app deployed successfully",
        "code": "OK",
        **summary_data,
        "release_id": release_id,
        "commit_sha": commit_sha,
        "deployment_kind": "deploy",
        "cutover_status": "live",
        "rollback_status": "not_required",
        "process_readiness": {
            "status": "ready",
            "path": candidate_probe_result["path"],
        },
        "public_health": public_health,
        "live_release_id": release_id,
        "release_entry": find_release_entry(manifest, release_id),
        "releases": release_inventory["releases"],
        "release_inventory": release_inventory,
        "retained_release_count": len(successful_releases),
        "pruned_release_ids": prune_result["pruned_release_ids"],
    }


def _execute_release_rollback(
    ctx: SupportsAppReleaseLifecycle,
    *,
    session,
    app_config,
    requested_release_id=None,
    emit=None,
    is_cancelled=None,
):
    release_targets = _release_runtime_targets(ctx, session.host, app_config)
    manifest = release_targets["manifest"]
    current_live_release_id = release_targets["live_release_id"]
    current_live_route_target = _release_route_target(
        app_config,
        release_id=current_live_release_id,
        container_name=release_targets["web_container_name"],
        legacy=release_targets["legacy"],
    )
    target_release = (
        find_release_entry(manifest, requested_release_id)
        if requested_release_id
        else previous_successful_release(
            manifest,
            excluding_release_id=current_live_release_id,
        )
    )
    if target_release is None:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "No retained release is available for rollback.",
            stage="validate_request",
        )

    target_image_name = target_release.get("image_name")
    if not isinstance(target_image_name, str) or not target_image_name.strip():
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Selected release does not have a retained image reference.",
            stage="validate_request",
        )
    target_commit_sha = normalize_commit_sha(target_release.get("commit_sha"))
    rollback_release_id = build_release_id(target_commit_sha)
    rollback_worker_configs = worker_specs_to_configs(target_release.get("workers", []))
    rollback_runtime_env = target_release.get("runtime_env")
    rollback_app_config = replace(
        app_config,
        workers=tuple(rollback_worker_configs) or app_config.workers,
        runtime_env=rollback_runtime_env
        if isinstance(rollback_runtime_env, dict)
        else app_config.runtime_env,
    )
    rollback_release_entry = release_entry_from_config(
        rollback_app_config,
        release_id=rollback_release_id,
        commit_sha=target_commit_sha,
        status="candidate",
        deployment_kind="rollback",
        image_name=target_image_name,
        rollback_from_release_id=current_live_release_id,
    )
    manifest = append_or_replace_release(manifest, rollback_release_entry)
    _write_release_manifest(session.host, rollback_app_config, manifest)

    candidate_runtime = _build_release_run_command(
        rollback_app_config,
        release_id=rollback_release_id,
        image_name=target_image_name,
        live_label="false",
    )
    _run_remote_command(
        ctx,
        session,
        "Remove stale rollback workers",
        candidate_runtime["worker_cleanup_command"],
        emit=emit,
        allow_failure=True,
    )
    web_result = _run_remote_command(
        ctx,
        session,
        "Start rollback candidate runtime",
        candidate_runtime["run_command"],
        emit=emit,
        stdin=candidate_runtime["runtime_env_stdin"],
    )
    if not web_result["ok"]:
        manifest = mark_release_failed(
            manifest,
            release_id=rollback_release_id,
            rollback_from_release_id=current_live_release_id,
            rollback_reason="rollback_candidate_start_failed",
        )
        _write_release_manifest(session.host, rollback_app_config, manifest)
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Start rollback candidate runtime failed.",
            stage="execute_runtime_operation",
            details=web_result["details"],
            extra={
                FAILURE_EVIDENCE_FIELD: _failure_evidence_from_result(
                    ctx,
                    phase="rollback",
                    source="failed_operation",
                    result=web_result,
                ),
            },
        )
    for worker_run_command in candidate_runtime["worker_run_commands"]:
        result = _run_remote_command(
            ctx,
            session,
            "Start rollback worker",
            worker_run_command,
            emit=emit,
            allow_failure=True,
        )
        if not result["ok"]:
            manifest = mark_release_failed(
                manifest,
                release_id=rollback_release_id,
                rollback_from_release_id=current_live_release_id,
                rollback_reason="rollback_worker_start_failed",
            )
            _remove_release_runtime(
                ctx,
                session,
                web_container_name=rollback_app_config.release_container_name(rollback_release_id),
                worker_container_names=_release_worker_container_names(
                    rollback_app_config,
                    rollback_release_id,
                ),
                image_name=target_image_name,
                emit=emit,
                remove_image=False,
            )
            _write_release_manifest(session.host, rollback_app_config, manifest)
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Start rollback worker failed.",
                stage="execute_runtime_operation",
                details=result["details"],
                extra={
                    FAILURE_EVIDENCE_FIELD: _failure_evidence_from_result(
                        ctx,
                        phase="rollback",
                        source="failed_operation",
                        result=result,
                    ),
                },
            )
    worker_verify_result = _verify_release_workers_running(
        ctx,
        session,
        worker_container_names=_release_worker_container_names(
            rollback_app_config,
            rollback_release_id,
        ),
        emit=emit,
        capture_evidence=True,
    )
    if not worker_verify_result["ok"]:
        manifest = mark_release_failed(
            manifest,
            release_id=rollback_release_id,
            rollback_from_release_id=current_live_release_id,
            rollback_reason="rollback_worker_verify_failed",
        )
        _remove_release_runtime(
            ctx,
            session,
            web_container_name=rollback_app_config.release_container_name(rollback_release_id),
            worker_container_names=_release_worker_container_names(
                rollback_app_config,
                rollback_release_id,
            ),
            image_name=target_image_name,
            emit=emit,
            remove_image=False,
        )
        _write_release_manifest(session.host, rollback_app_config, manifest)
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Verify rollback worker process state failed.",
            stage="execute_runtime_operation",
            details=worker_verify_result["worker_container_name"],
            extra={
                FAILURE_EVIDENCE_FIELD: _failure_evidence_from_result(
                    ctx,
                    phase="rollback",
                    source="failed_operation",
                    result=worker_verify_result.get("result"),
                ),
            },
        )
    probe_result = _probe_candidate_release(
        ctx,
        session,
        rollback_app_config,
        container_name=rollback_app_config.release_container_name(rollback_release_id),
        emit=emit,
        capture_evidence=True,
    )
    if not probe_result["ok"]:
        log_result = _collect_release_runtime_logs(
            ctx,
            session,
            container_name=rollback_app_config.release_container_name(rollback_release_id),
            emit=emit,
        )
        failure_evidence = _failure_evidence_from_result(
            ctx,
            phase="rollback",
            source="candidate_runtime",
            result=log_result,
            probe=probe_result.get("probe"),
            probe_source="candidate_probe",
        )
        runtime_log_excerpt = _runtime_log_excerpt_from_evidence(failure_evidence)
        manifest = mark_release_failed(
            manifest,
            release_id=rollback_release_id,
            rollback_from_release_id=current_live_release_id,
            rollback_reason="rollback_candidate_probe_failed",
        )
        _remove_release_runtime(
            ctx,
            session,
            web_container_name=rollback_app_config.release_container_name(rollback_release_id),
            worker_container_names=_release_worker_container_names(
                rollback_app_config,
                rollback_release_id,
            ),
            image_name=target_image_name,
            emit=emit,
            remove_image=False,
        )
        _write_release_manifest(session.host, rollback_app_config, manifest)
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Rollback candidate did not pass readiness probes.",
            stage="execute_runtime_operation",
            extra={
                "release_id": rollback_release_id,
                "readiness_failure_summary": _readiness_failure_summary(
                    runtime_log_excerpt,
                ),
                "runtime_log_excerpt": runtime_log_excerpt,
                "runtime_log_source": "failed_rollback_candidate",
                "runtime_log_container_name": rollback_app_config.release_container_name(
                    rollback_release_id
                ),
                FAILURE_EVIDENCE_FIELD: failure_evidence,
            },
        )
    try:
        caddy_result = _write_caddy_route(
            ctx,
            session,
            rollback_app_config,
            target_container_name=rollback_app_config.release_upstream_name(rollback_release_id),
            emit=emit,
        )
    except Exception as exc:
        sanitize = ctx.sanitize_message or (lambda value: value)
        failure_evidence = _failure_evidence_from_result(
            ctx,
            phase="rollback",
            source="exception",
            result={"exception": sanitize(str(exc))},
        )
        cleanup_result = _cleanup_failed_release_after_route_cutover(
            ctx,
            session,
            rollback_app_config,
            manifest=manifest,
            release_id=rollback_release_id,
            rollback_from_release_id=current_live_release_id,
            previous_route_target=(
                current_live_route_target if release_targets["web_container_name"] else None
            ),
            image_name=target_image_name,
            rollback_reason="rollback_cutover_exception",
            emit=emit,
        )
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Rollback traffic switch failed.",
            stage="execute_runtime_operation",
            details=sanitize(str(exc)),
            extra={
                FAILURE_EVIDENCE_FIELD: failure_evidence,
                **_route_cleanup_extra(cleanup_result["route_cleanup"]),
            },
        )
    if not caddy_result["ok"]:
        failure_evidence = _failure_evidence_from_result(
            ctx,
            phase="rollback",
            source="failed_operation",
            result=caddy_result,
        )
        cleanup_result = _cleanup_failed_release_after_route_cutover(
            ctx,
            session,
            rollback_app_config,
            manifest=manifest,
            release_id=rollback_release_id,
            rollback_from_release_id=current_live_release_id,
            previous_route_target=(
                current_live_route_target if release_targets["web_container_name"] else None
            ),
            image_name=target_image_name,
            rollback_reason="rollback_cutover_failed",
            emit=emit,
        )
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Rollback traffic switch failed.",
            stage="execute_runtime_operation",
            details=caddy_result["details"],
            extra={
                FAILURE_EVIDENCE_FIELD: failure_evidence,
                **_route_cleanup_extra(cleanup_result["route_cleanup"]),
            },
        )
    try:
        for attempt in range(_RELEASE_STABILIZATION_ATTEMPTS):
            if callable(is_cancelled) and is_cancelled():
                cleanup_result = _cleanup_failed_release_after_route_cutover(
                    ctx,
                    session,
                    rollback_app_config,
                    manifest=manifest,
                    release_id=rollback_release_id,
                    rollback_from_release_id=current_live_release_id,
                    previous_route_target=(
                        current_live_route_target if release_targets["web_container_name"] else None
                    ),
                    image_name=target_image_name,
                    rollback_reason="rollback_cancelled_after_cutover",
                    emit=emit,
                )
                return ctx.error_result(
                    "ENGINE_TASK_CANCELLED",
                    "Rollback cancelled after traffic switch.",
                    stage="execute_runtime_operation",
                    extra={
                        "release_id": rollback_release_id,
                        "rollback_status": "reverted_to_previous_live",
                        "rollback_from_release_id": current_live_release_id,
                        **_route_cleanup_extra(cleanup_result["route_cleanup"]),
                    },
                )
            routed_probe_result = _probe_routed_release(
                ctx,
                session,
                rollback_app_config,
                path=probe_result["path"],
                emit=emit,
                capture_evidence=True,
            )
            worker_verify_result = _verify_release_workers_running(
                ctx,
                session,
                worker_container_names=_release_worker_container_names(
                    rollback_app_config,
                    rollback_release_id,
                ),
                emit=emit,
                capture_evidence=True,
            )
            if not routed_probe_result["ok"] or not worker_verify_result["ok"]:
                if attempt < _RELEASE_STABILIZATION_ATTEMPTS - 1:
                    ctx.emit_event(
                        emit,
                        "app_release_stabilization_retry",
                        "Traffic switch is still settling; retrying routed readiness check.",
                    )
                    release_sleep(_RELEASE_STABILIZATION_DELAY_SECONDS)
                    continue
                log_result = _collect_release_runtime_logs(
                    ctx,
                    session,
                    container_name=rollback_app_config.release_container_name(rollback_release_id),
                    emit=emit,
                )
                evidence_result, evidence_source = _stabilization_evidence_result(
                    ctx,
                    log_result,
                    worker_verify_result,
                )
                failure_evidence = _failure_evidence_from_result(
                    ctx,
                    phase="rollback",
                    source=evidence_source,
                    result=evidence_result,
                    probe=(
                        routed_probe_result.get("probe") if not routed_probe_result["ok"] else None
                    ),
                    probe_source="routed_probe",
                )
                cleanup_result = _cleanup_failed_release_after_route_cutover(
                    ctx,
                    session,
                    rollback_app_config,
                    manifest=manifest,
                    release_id=rollback_release_id,
                    rollback_from_release_id=current_live_release_id,
                    previous_route_target=(
                        current_live_route_target if release_targets["web_container_name"] else None
                    ),
                    image_name=target_image_name,
                    rollback_reason="rollback_stabilization_failed",
                    emit=emit,
                )
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Rollback candidate failed post-cutover stabilization and was reverted.",
                    stage="execute_runtime_operation",
                    extra={
                        "release_id": rollback_release_id,
                        "rollback_status": "reverted_to_previous_live",
                        "rollback_from_release_id": current_live_release_id,
                        FAILURE_EVIDENCE_FIELD: failure_evidence,
                        **_route_cleanup_extra(cleanup_result["route_cleanup"]),
                    },
                )
            if attempt < _RELEASE_STABILIZATION_ATTEMPTS - 1:
                release_sleep(_RELEASE_STABILIZATION_DELAY_SECONDS)
    except Exception as exc:
        sanitize = ctx.sanitize_message or (lambda value: value)
        failure_evidence = _failure_evidence_from_result(
            ctx,
            phase="rollback",
            source="exception",
            result={"exception": sanitize(str(exc))},
        )
        cleanup_result = _cleanup_failed_release_after_route_cutover(
            ctx,
            session,
            rollback_app_config,
            manifest=manifest,
            release_id=rollback_release_id,
            rollback_from_release_id=current_live_release_id,
            previous_route_target=(
                current_live_route_target if release_targets["web_container_name"] else None
            ),
            image_name=target_image_name,
            rollback_reason="rollback_post_cutover_exception",
            emit=emit,
        )
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Rollback ended unexpectedly after traffic was switched.",
            stage="execute_runtime_operation",
            details=sanitize(str(exc)),
            extra={
                "release_id": rollback_release_id,
                "rollback_status": "reverted_to_previous_live",
                "rollback_from_release_id": current_live_release_id,
                FAILURE_EVIDENCE_FIELD: failure_evidence,
                **_route_cleanup_extra(cleanup_result["route_cleanup"]),
            },
        )

    public_health = _probe_public_health(ctx, session, rollback_app_config, emit=emit)

    manifest = set_live_release(
        manifest,
        live_release_id=rollback_release_id,
        retained_release_id=current_live_release_id,
    )
    _set_release_live_labels(
        ctx,
        session,
        web_container_name=rollback_app_config.release_container_name(rollback_release_id),
        worker_container_names=_release_worker_container_names(
            rollback_app_config,
            rollback_release_id,
        ),
        live_value="true",
        emit=emit,
    )
    _run_remote_command(
        ctx,
        session,
        "Retag live image alias",
        f"docker tag {shlex.quote(target_image_name)} {shlex.quote(app_config.image_name)}",
        emit=emit,
        allow_failure=True,
    )
    _stop_release_runtime(
        ctx,
        session,
        web_container_name=release_targets["web_container_name"],
        worker_container_names=release_targets["worker_container_names"],
        emit=emit,
    )
    prune_result = _prune_release_artifacts(
        ctx,
        session,
        rollback_app_config,
        manifest,
        emit=emit,
    )
    manifest = prune_result["manifest"]
    _write_release_manifest(session.host, rollback_app_config, manifest)
    release_inventory = _release_inventory_response(manifest)
    successful_releases = [
        entry
        for entry in manifest.get("releases", [])
        if entry.get("status") in ("live", "retained")
    ]
    return {
        "status": "success",
        "code": "OK",
        "msg": "Rollback completed.",
        "operation_id": "rollback",
        "project_slug": app_config.project_slug,
        "release_id": rollback_release_id,
        "commit_sha": target_commit_sha,
        "deployment_kind": "rollback",
        "cutover_status": "live",
        "rollback_status": "completed",
        "process_readiness": {
            "status": "ready",
            "path": probe_result["path"],
        },
        "public_health": public_health,
        "rollback_from_release_id": current_live_release_id,
        "live_release_id": rollback_release_id,
        "target_release_id": target_release.get("release_id"),
        "release_entry": find_release_entry(manifest, rollback_release_id),
        "releases": release_inventory["releases"],
        "release_inventory": release_inventory,
        "retained_release_count": len(successful_releases),
        "pruned_release_ids": prune_result["pruned_release_ids"],
    }


__all__ = tuple(name for name in globals() if not name.startswith("__"))
