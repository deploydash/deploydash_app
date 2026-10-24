# ruff: noqa: F403, F405
from .. import server_identifiers, shell_output
from ..engine_context import SupportsAppRuntimeOperations
from ._shared import *
from .command_execution import *
from .release_lifecycle import *
from .runtime_operation_plans import build_runtime_operation_steps


def _prepare_runtime_operation(
    ctx: SupportsAppRuntimeOperations,
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
    log_tail_lines=200,
    worker_id=None,
    release_id=None,
    command=None,
    timeout_seconds=None,
):
    if callable(is_cancelled) and is_cancelled():
        return ctx.error_result(
            "ENGINE_TASK_CANCELLED",
            "Task cancelled before execution started",
            stage="preflight",
        )

    try:
        app_config = parse_app_config(raw_data, require_domain=False)
        normalized_exec_command = None
        normalized_exec_timeout_seconds = _APP_EXEC_DEFAULT_TIMEOUT_SECONDS
        if operation_id == "exec":
            normalized_exec_command = _normalize_exec_command(command)
            normalized_exec_timeout_seconds = _normalize_exec_timeout_seconds(timeout_seconds)
            if app_config.railpack_provider == "staticfile":
                raise AppConfigValidationError(
                    "Run one-off command is not supported for staticfile web apps."
                )
    except AppConfigValidationError as exc:
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

    normalized_worker_id = None
    if isinstance(worker_id, str):
        trimmed_worker_id = worker_id.strip()
        if trimmed_worker_id:
            normalized_worker_id = trimmed_worker_id

    sqlite_storage = app_config.sqlite_storage
    sqlite_operation_ids = (
        "sqlite_volume_ensure",
        "sqlite_volume_status",
        "sqlite_volume_delete",
    )
    if operation_id in sqlite_operation_ids and sqlite_storage is None:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "SQLite storage is not configured for this project.",
            stage="validate_request",
        )

    if operation_id == "list_releases" and dry_run:
        return {
            "status": "success",
            "code": "OK",
            "msg": "Web app release inventory plan ready",
            "operation_id": operation_id,
            "project_slug": app_config.project_slug,
            "actions": ["Read release manifest and return live/retained releases"],
        }
    if operation_id == "rollback" and dry_run:
        return {
            "status": "success",
            "code": "OK",
            "msg": "Rollback plan ready",
            "operation_id": operation_id,
            "project_slug": app_config.project_slug,
            "actions": ["Start retained release candidate", "Switch traffic", "Prune old releases"],
        }

    session = None
    release_targets = {
        "manifest": empty_release_manifest(),
        "live_release": None,
        "live_release_id": None,
        "web_container_name": app_config.container_name,
        "image_name": app_config.image_name,
        "worker_container_names": _legacy_worker_container_names(app_config),
        "legacy": True,
    }
    if not dry_run:
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
        if operation_id == "list_releases":
            try:
                manifest = _load_release_manifest(ctx, session.host, app_config)
                release_inventory = _release_inventory_response(manifest)
                return {
                    "status": "success",
                    "code": "OK",
                    "msg": "Release inventory captured.",
                    "operation_id": operation_id,
                    "project_slug": app_config.project_slug,
                    "live_release_id": release_inventory["live_release_id"],
                    "releases": release_inventory["releases"],
                    "release_inventory": release_inventory,
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
        if operation_id == "rollback":
            try:
                return _execute_release_rollback(
                    ctx,
                    session=session,
                    app_config=app_config,
                    requested_release_id=release_id,
                    emit=emit,
                    is_cancelled=is_cancelled,
                )
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
        release_targets = _release_runtime_targets(ctx, session.host, app_config)

    targeted_worker_operation_ids = (
        "worker_start",
        "worker_stop",
        "worker_restart",
        "worker_logs",
    )
    target_worker = None
    if operation_id in targeted_worker_operation_ids:
        if normalized_worker_id is None:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                "params.worker_id is required for this operation.",
                stage="validate_request",
            )
        for worker in app_config.workers:
            if worker.id == normalized_worker_id:
                target_worker = worker
                break
        if target_worker is None:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                f"Worker '{normalized_worker_id}' is not configured for this project.",
                stage="validate_request",
            )
        if operation_id in ("worker_start", "worker_restart") and target_worker.enabled is not True:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                f"Worker '{normalized_worker_id}' is disabled. Enable it before starting.",
                stage="validate_request",
            )

    effective_container_name = release_targets["web_container_name"]
    effective_image_name = release_targets["image_name"]
    live_release_id = release_targets["live_release_id"]
    quoted_container_name = shlex.quote(effective_container_name)
    worker_legacy_container_name = server_identifiers.legacy_worker_container(
        app_config.project_slug
    )
    quoted_worker_legacy_container_name = shlex.quote(worker_legacy_container_name)
    quoted_image_name = shlex.quote(effective_image_name)
    quoted_project_root = shlex.quote(app_config.project_root)
    quoted_caddy_snippet_path = shlex.quote(app_config.caddy_snippet_path)
    quoted_caddy_env_file = shlex.quote(app_config.caddy_env_file_path)
    quoted_tls_env_prefix = shlex.quote(app_config.tls_env_prefix)
    quoted_caddy_apply_helper = shlex.quote(app_config.caddy_apply_helper)
    quoted_caddy_stack_root = shlex.quote(app_config.caddy_stack_root)
    quoted_caddy_container_name = shlex.quote(app_config.caddy_container_name)
    normalized_log_tail_lines = ctx.normalize_runtime_log_tail(log_tail_lines)
    runtime_env_values = dict(app_config.runtime_env)
    if sqlite_storage is not None:
        runtime_env_values["SQLITE_PATH"] = sqlite_storage.database_path
        runtime_env_values["DATABASE_URL"] = sqlite_storage.database_url
    for mount in app_config.sqlite_snapshot_mounts:
        if mount.path_env_key:
            runtime_env_values[mount.path_env_key] = mount.database_path
        if mount.database_url_env_key:
            runtime_env_values[mount.database_url_env_key] = mount.database_url
    runtime_env_docker_flags = build_runtime_env_docker_flags(
        runtime_env_values,
        include_values=True,
    )
    sqlite_snapshot_volume_flags = []
    for mount in app_config.sqlite_snapshot_mounts:
        sqlite_snapshot_volume_flags.append(
            "-v "
            + shlex.quote(
                f"{mount.volume_name}:{mount.mount_path}:ro",
            )
        )
    sqlite_snapshot_docker_flags = " ".join(sqlite_snapshot_volume_flags)
    project_label = f"{server_identifiers.LABEL_PROJECT}={app_config.project_slug}"
    release_label = f"{server_identifiers.LABEL_RELEASE_ID}={live_release_id}"
    worker_role_filter = (
        f"--filter label={server_identifiers.LABEL_ROLE}={server_identifiers.ROLE_WORKER} "
    )
    quoted_worker_project_label = shlex.quote(project_label)
    quoted_worker_release_filter = (
        f"--filter label={shlex.quote(release_label)} "
        if not release_targets["legacy"]
        and isinstance(live_release_id, str)
        and live_release_id.strip()
        else ""
    )
    worker_cleanup_command = (
        "docker ps -a "
        f"--filter label={quoted_worker_project_label} "
        f"{quoted_worker_release_filter}"
        f"{worker_role_filter}"
        "--format '{{.Names}}' | xargs -r docker rm -f >/dev/null 2>&1 || true"
    )
    worker_network_command = (
        'WORKER_NETWORK="$(docker inspect -f '
        "'{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "
        f"{quoted_container_name} 2>/dev/null | head -n1 | tr -d '[:space:]')\"; "
        'if [ -z "${WORKER_NETWORK}" ]; then '
        'WORKER_NETWORK="$(docker inspect -f '
        "'{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "
        f"{quoted_caddy_container_name} 2>/dev/null | head -n1 | tr -d '[:space:]')\"; "
        "fi; "
        '[ -n "${WORKER_NETWORK}" ] || WORKER_NETWORK=bridge'
    )
    worker_image_check_command = (
        f"docker image inspect {quoted_image_name} >/dev/null 2>&1 || "
        "(echo 'Web app image is missing. Deploy web app first to build image.' >&2; exit 1)"
    )
    worker_precheck_command = (
        "IMAGE_EXISTS=false; "
        f"if docker image inspect {quoted_image_name} >/dev/null 2>&1; then IMAGE_EXISTS=true; fi; "
        "APP_EXISTS=false; "
        "APP_RUNNING=false; "
        f"if docker inspect {quoted_container_name} >/dev/null 2>&1; then "
        "APP_EXISTS=true; "
        f"if {container_process_running_check_shell(quoted_container_name)}; then APP_RUNNING=true; fi; "
        "fi; "
        'WORKER_NETWORK="$(docker inspect -f '
        "'{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "
        f"{quoted_container_name} 2>/dev/null | head -n1 | tr -d '[:space:]')\"; "
        'if [ -z "${WORKER_NETWORK}" ]; then '
        'WORKER_NETWORK="$(docker inspect -f '
        "'{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "
        f"{quoted_caddy_container_name} 2>/dev/null | head -n1 | tr -d '[:space:]')\"; "
        "fi; "
        "echo WORKER_PRECHECK_IMAGE_EXISTS=${IMAGE_EXISTS}; "
        "echo WORKER_PRECHECK_APP_CONTAINER_EXISTS=${APP_EXISTS}; "
        "echo WORKER_PRECHECK_APP_CONTAINER_RUNNING=${APP_RUNNING}; "
        "echo WORKER_PRECHECK_WORKER_NETWORK=${WORKER_NETWORK}"
    )

    worker_runtime_specs = build_worker_runtime_command_specs(
        project_slug=app_config.project_slug,
        image_name=effective_image_name,
        workers=app_config.workers,
        runtime_env_docker_flags=runtime_env_docker_flags,
        primary_network_env_var="WORKER_NETWORK",
        readonly_volume_docker_flags=sqlite_snapshot_docker_flags,
        trust_network_names=app_config.trust_network_names,
        log_tail_lines=normalized_log_tail_lines,
        include_disabled=True,
        release_id=live_release_id,
        live_label="true" if live_release_id is not None else None,
    )
    worker_runtime_specs_by_id = {entry.worker.id: entry for entry in worker_runtime_specs}
    worker_runtime_commands = [entry for entry in worker_runtime_specs if entry.worker.enabled]

    def _with_worker_network_resolution(command: str) -> str:
        return f"{worker_network_command}; {command}"

    target_worker_commands = (
        worker_runtime_specs_by_id.get(target_worker.id)
        if target_worker is not None
        and operation_id in ("worker_start", "worker_restart", "worker_logs")
        else None
    )
    target_worker_stop_command = None
    if target_worker is not None and operation_id == "worker_stop":
        target_spec = worker_runtime_specs_by_id.get(target_worker.id)
        if target_spec is not None:
            target_worker_stop_command = target_spec.stop_command
    worker_status_command = (
        "docker ps -a "
        f"--filter label={quoted_worker_project_label} "
        f"{quoted_worker_release_filter}"
        f"{worker_role_filter}"
        "--format 'META|{{.Names}}|{{.State}}|{{.Status}}|{{.ID}}'; "
        'RUNNING_NAMES="$(docker ps '
        f"--filter label={quoted_worker_project_label} "
        f"{quoted_worker_release_filter}"
        f"{worker_role_filter}"
        "--format '{{.Names}}')\"; "
        'if [ -n "${RUNNING_NAMES}" ]; then '
        "docker stats --no-stream --format "
        "'STAT|{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.PIDs}}' "
        "${RUNNING_NAMES}; "
        "fi"
    )

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
    cleanup_caddy_dns_env_command = (
        f"ENV_FILE={quoted_caddy_env_file}; "
        f"PREFIX={quoted_tls_env_prefix}; "
        'if [ -f "${ENV_FILE}" ]; then '
        'TMP_FILE="$(mktemp)"; '
        'grep -v "^${PREFIX}" "${ENV_FILE}" > "${TMP_FILE}" || true; '
        'mv "${TMP_FILE}" "${ENV_FILE}"; '
        'chmod 600 "${ENV_FILE}"; '
        "fi"
    )
    sqlite_meta_command = "echo SQLITE_META_ENABLED=false"
    if sqlite_storage is not None:
        quoted_sqlite_volume_name = shlex.quote(sqlite_storage.volume_name)
        quoted_sqlite_mount_path = shlex.quote(sqlite_storage.mount_path)
        quoted_sqlite_file_name = shlex.quote(sqlite_storage.file_name)
        quoted_sqlite_database_path = shlex.quote(sqlite_storage.database_path)
        quoted_sqlite_database_url = shlex.quote(sqlite_storage.database_url)
        sqlite_meta_command = (
            "SQLITE_META_ENABLED=true; "
            f"SQLITE_META_VOLUME_NAME={quoted_sqlite_volume_name}; "
            f"SQLITE_META_MOUNT_PATH={quoted_sqlite_mount_path}; "
            f"SQLITE_META_FILE_NAME={quoted_sqlite_file_name}; "
            f"SQLITE_META_DATABASE_PATH={quoted_sqlite_database_path}; "
            f"SQLITE_META_DATABASE_URL={quoted_sqlite_database_url}; "
            "SQLITE_META_VOLUME_EXISTS=false; "
            "SQLITE_META_VOLUME_MOUNTPOINT=''; "
            "SQLITE_META_VOLUME_SIZE_KB=''; "
            'if docker volume inspect "${SQLITE_META_VOLUME_NAME}" >/dev/null 2>&1; then '
            "SQLITE_META_VOLUME_EXISTS=true; "
            "SQLITE_META_VOLUME_MOUNTPOINT=\"$(docker volume inspect -f '{{.Mountpoint}}' "
            '"${SQLITE_META_VOLUME_NAME}" 2>/dev/null | head -n1)"; '
            'if [ -n "${SQLITE_META_VOLUME_MOUNTPOINT}" ] && '
            '[ -d "${SQLITE_META_VOLUME_MOUNTPOINT}" ]; then '
            'SQLITE_META_VOLUME_SIZE_KB="$(du -sk "${SQLITE_META_VOLUME_MOUNTPOINT}" '
            "2>/dev/null | awk 'NR==1 {print $1}')\"; "
            "fi; "
            "fi; "
            "echo SQLITE_META_ENABLED=${SQLITE_META_ENABLED}; "
            "echo SQLITE_META_VOLUME_NAME=${SQLITE_META_VOLUME_NAME}; "
            "echo SQLITE_META_MOUNT_PATH=${SQLITE_META_MOUNT_PATH}; "
            "echo SQLITE_META_FILE_NAME=${SQLITE_META_FILE_NAME}; "
            "echo SQLITE_META_DATABASE_PATH=${SQLITE_META_DATABASE_PATH}; "
            "echo SQLITE_META_DATABASE_URL=${SQLITE_META_DATABASE_URL}; "
            "echo SQLITE_META_VOLUME_EXISTS=${SQLITE_META_VOLUME_EXISTS}; "
            "echo SQLITE_META_VOLUME_MOUNTPOINT=${SQLITE_META_VOLUME_MOUNTPOINT}; "
            "echo SQLITE_META_VOLUME_SIZE_KB=${SQLITE_META_VOLUME_SIZE_KB}"
        )
    sqlite_volume_ensure_command = "true"
    sqlite_volume_delete_command = "true"
    if sqlite_storage is not None:
        quoted_sqlite_volume_name = shlex.quote(sqlite_storage.volume_name)
        sqlite_volume_ensure_command = (
            f"docker volume inspect {quoted_sqlite_volume_name} >/dev/null 2>&1 || "
            f"docker volume create {quoted_sqlite_volume_name} >/dev/null"
        )
        sqlite_volume_delete_command = (
            "if docker volume inspect "
            f"{quoted_sqlite_volume_name} >/dev/null 2>&1; then "
            f"docker volume rm {quoted_sqlite_volume_name} >/dev/null; "
            "fi"
        )

    resource_usage_steps = [
        (
            "Collect app container resource usage",
            "set -eu; "
            'kv(){ printf "%s=%s\\n" "$1" "$2"; }; '
            f"{container_status_kv_shell('container', quoted_container_name)}; "
            f"if {container_process_running_check_shell(quoted_container_name)}; then "
            "docker stats --no-stream --format '{{ json . }}' "
            f"{quoted_container_name}; "
            "fi",
            True,
        ),
        (
            "Collect sqlite storage metadata",
            sqlite_meta_command,
            True,
        ),
    ]
    public_health_command = _public_health_probe_command(app_config)
    if public_health_command is not None:
        resource_usage_steps.append(
            (
                f"Check public URL at {app_config.public_health_check_path}",
                public_health_command,
                True,
            )
        )

    resources = SimpleNamespace(
        app_config=app_config,
        quoted_worker_project_label=quoted_worker_project_label,
        quoted_container_name=quoted_container_name,
        worker_cleanup_command=worker_cleanup_command,
        quoted_worker_legacy_container_name=quoted_worker_legacy_container_name,
        quoted_project_root=quoted_project_root,
        quoted_release_manifest_path=shlex.quote(app_config.release_manifest_path),
        quoted_caddy_snippet_path=quoted_caddy_snippet_path,
        cleanup_caddy_dns_env_command=cleanup_caddy_dns_env_command,
        caddy_apply_command=caddy_apply_command,
        resource_usage_steps=resource_usage_steps,
        normalized_log_tail_lines=normalized_log_tail_lines,
        app_exec_command=_app_exec_shell_command(
            app_config,
            normalized_exec_command,
            container_name=effective_container_name,
        ),
        sqlite_volume_ensure_command=sqlite_volume_ensure_command,
        sqlite_meta_command=sqlite_meta_command,
        sqlite_volume_delete_command=sqlite_volume_delete_command,
        worker_network_command=worker_network_command,
        worker_image_check_command=worker_image_check_command,
        worker_runtime_commands=worker_runtime_commands,
        with_worker_network_resolution=_with_worker_network_resolution,
        worker_status_command=worker_status_command,
        worker_precheck_command=worker_precheck_command,
        normalized_worker_id=normalized_worker_id,
        target_worker_commands=target_worker_commands,
        target_worker_stop_command=target_worker_stop_command,
    )
    operation_steps = build_runtime_operation_steps(operation_id, resources)

    if operation_steps is None:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Unknown web app runtime operation: {operation_id}",
            stage="validate_request",
        )

    if dry_run:
        return {
            "status": "success",
            "code": "OK",
            "msg": f"Web app runtime operation '{operation_id}' plan ready",
            "operation_id": operation_id,
            "project_slug": app_config.project_slug,
            "actions": [step[0] for step in operation_steps],
        }

    return SimpleNamespace(
        operation_id=operation_id,
        session=session,
        app_config=app_config,
        emit=emit,
        is_cancelled=is_cancelled,
        sqlite_storage=sqlite_storage,
        sqlite_operation_ids=sqlite_operation_ids,
        operation_steps=operation_steps,
        normalized_exec_command=normalized_exec_command,
        normalized_exec_timeout_seconds=normalized_exec_timeout_seconds,
        normalized_worker_id=normalized_worker_id,
        normalized_log_tail_lines=normalized_log_tail_lines,
        targeted_worker_operation_ids=targeted_worker_operation_ids,
    )


def _execute_runtime_plan(ctx: SupportsAppRuntimeOperations, request):
    operation_id = request.operation_id
    session = request.session
    app_config = request.app_config
    emit = request.emit
    is_cancelled = request.is_cancelled
    sqlite_storage = request.sqlite_storage
    sqlite_operation_ids = request.sqlite_operation_ids
    operation_steps = request.operation_steps
    normalized_exec_command = request.normalized_exec_command
    normalized_exec_timeout_seconds = request.normalized_exec_timeout_seconds
    normalized_worker_id = request.normalized_worker_id
    normalized_log_tail_lines = request.normalized_log_tail_lines
    targeted_worker_operation_ids = request.targeted_worker_operation_ids

    app_container_status = normalize_container_status()
    resource_usage = None
    public_health = _public_health_from_output(app_config, None)
    sqlite_storage_payload = (
        {
            "enabled": True,
            "volume_name": sqlite_storage.volume_name,
            "mount_path": sqlite_storage.mount_path,
            "file_name": sqlite_storage.file_name,
            "database_path": sqlite_storage.database_path,
            "database_url": sqlite_storage.database_url,
            "volume_exists": None,
            "volume_mountpoint": None,
            "volume_size_bytes": None,
        }
        if sqlite_storage is not None
        else None
    )
    worker_runtime_rows = []
    worker_precheck_payload = None
    runtime_log_lines = []
    worker_log_lines = []
    app_exec_stdout_lines = []
    app_exec_stderr_lines = []
    app_exec_exit_code = None
    app_exec_started_at = None
    app_exec_completed_at = None
    app_exec_duration_ms = None
    worker_runtime_snapshot_operation_ids = (
        "workers_apply",
        "workers_status",
        "worker_start",
        "worker_stop",
        "worker_restart",
    )
    try:
        ctx.emit_event(
            emit,
            "app_runtime_plan_ready",
            f"Runtime operation '{operation_id}' prepared.",
            data={
                "operation_id": operation_id,
                "project_slug": app_config.project_slug,
            },
        )

        for label, command, allow_failure in operation_steps:
            if callable(is_cancelled) and is_cancelled():
                if operation_id == "exec":
                    _emit_app_exec_result_event(
                        ctx,
                        emit,
                        command=normalized_exec_command,
                        terminal_status="cancelled",
                        message="Run one-off app command cancelled.",
                    )
                return ctx.error_result(
                    "ENGINE_TASK_CANCELLED",
                    "Task cancelled during runtime operation",
                    stage="execute_runtime_operation",
                )

            ctx.emit_event(
                emit,
                "app_runtime_action_started",
                f"{label}: started",
            )
            command_timeout_seconds = (
                normalized_exec_timeout_seconds if operation_id == "exec" else 60
            )
            if operation_id == "exec":
                app_exec_started_at = datetime.now(UTC)
            status, output = session.host.run_shell_command(
                command,
                _timeout=command_timeout_seconds,
                _sudo=True,
            )
            if operation_id == "exec":
                app_exec_completed_at = datetime.now(UTC)
                app_exec_duration_ms = int(
                    (app_exec_completed_at - app_exec_started_at).total_seconds() * 1000
                )
                (
                    app_exec_exit_code,
                    app_exec_stdout_lines,
                    app_exec_stderr_lines,
                ) = _parse_app_exec_output(output)
                _emit_app_exec_output_lines(
                    ctx,
                    emit,
                    app_exec_stdout_lines,
                    app_exec_stderr_lines,
                )
            else:
                ctx.emit_shell_output_lines(emit, output)

            if operation_id == "resource_usage":
                parsed_container_status = _parse_container_status_output(output)
                if parsed_container_status is not None:
                    app_container_status = parsed_container_status
                parsed_usage = _parse_docker_stats_output(output)
                if parsed_usage is not None:
                    resource_usage = parsed_usage
                parsed_sqlite_payload = _parse_sqlite_meta_output(output)
                if parsed_sqlite_payload is not None:
                    sqlite_storage_payload = parsed_sqlite_payload
                if label.startswith("Check public URL at "):
                    public_health = _public_health_from_output(app_config, output)
            if operation_id in sqlite_operation_ids:
                parsed_sqlite_payload = _parse_sqlite_meta_output(output)
                if parsed_sqlite_payload is not None:
                    sqlite_storage_payload = parsed_sqlite_payload
            if operation_id in worker_runtime_snapshot_operation_ids:
                output_lines = getattr(output, "stdout_lines", None)
                worker_runtime_rows = _parse_worker_status_lines(
                    output_lines,
                    app_config.project_slug,
                )
            if operation_id == "workers_precheck":
                precheck_map = shell_output.parse_key_values(
                    output,
                    prefix="WORKER_PRECHECK_",
                )
                worker_precheck_payload = {
                    "image_exists": precheck_map.get("WORKER_PRECHECK_IMAGE_EXISTS", "").lower()
                    == "true",
                    "app_container_exists": precheck_map.get(
                        "WORKER_PRECHECK_APP_CONTAINER_EXISTS",
                        "",
                    ).lower()
                    == "true",
                    "app_container_running": precheck_map.get(
                        "WORKER_PRECHECK_APP_CONTAINER_RUNNING",
                        "",
                    ).lower()
                    == "true",
                    "worker_network": precheck_map.get("WORKER_PRECHECK_WORKER_NETWORK") or None,
                }
            if operation_id == "worker_logs":
                output_lines = getattr(output, "stdout_lines", None) or []
                worker_log_lines = [str(line) for line in output_lines]
            if operation_id == "runtime_logs":
                output_lines = getattr(output, "stdout_lines", None) or []
                runtime_log_lines = [str(line) for line in output_lines]

            if not status and not allow_failure:
                details = ctx.command_error_details(output)
                if operation_id == "exec":
                    _emit_app_exec_result_event(
                        ctx,
                        emit,
                        command=normalized_exec_command,
                        terminal_status="error",
                        message=f"{label} failed.",
                        started_at=app_exec_started_at,
                        completed_at=app_exec_completed_at,
                        duration_ms=app_exec_duration_ms,
                    )
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    f"{label} failed.",
                    stage="execute_runtime_operation",
                    details=details or "remote command failed",
                    extra={
                        "operation_id": operation_id,
                        "project_slug": app_config.project_slug,
                        "action": label,
                        **(
                            {
                                "command": normalized_exec_command,
                                "timeout_seconds": normalized_exec_timeout_seconds,
                                "started_at": app_exec_started_at.isoformat()
                                if app_exec_started_at is not None
                                else None,
                                "completed_at": app_exec_completed_at.isoformat()
                                if app_exec_completed_at is not None
                                else None,
                                "duration_ms": app_exec_duration_ms,
                            }
                            if operation_id == "exec"
                            else {}
                        ),
                    },
                )
            if operation_id == "exec" and app_exec_exit_code is None:
                _emit_app_exec_result_event(
                    ctx,
                    emit,
                    command=normalized_exec_command,
                    terminal_status="error",
                    message="Run one-off app command failed.",
                    started_at=app_exec_started_at,
                    completed_at=app_exec_completed_at,
                    duration_ms=app_exec_duration_ms,
                )
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Run one-off app command failed.",
                    stage="execute_runtime_operation",
                    details="exit code marker missing from app command output",
                    extra={
                        "operation_id": operation_id,
                        "project_slug": app_config.project_slug,
                        "action": label,
                        "command": normalized_exec_command,
                        "timeout_seconds": normalized_exec_timeout_seconds,
                        "started_at": app_exec_started_at.isoformat()
                        if app_exec_started_at is not None
                        else None,
                        "completed_at": app_exec_completed_at.isoformat()
                        if app_exec_completed_at is not None
                        else None,
                        "duration_ms": app_exec_duration_ms,
                    },
                )
            if operation_id == "exec" and app_exec_exit_code != 0:
                details = "; ".join(
                    line.strip()
                    for line in (app_exec_stderr_lines + app_exec_stdout_lines)
                    if isinstance(line, str) and line.strip()
                )
                failure_message = (
                    "Run one-off command requires the app container to be running."
                    if app_exec_exit_code == 126
                    and any(
                        isinstance(line, str) and "App container is not running on server." in line
                        for line in app_exec_stderr_lines
                    )
                    else f"One-off app command failed with exit code {app_exec_exit_code}."
                )
                _emit_app_exec_result_event(
                    ctx,
                    emit,
                    command=normalized_exec_command,
                    terminal_status="error",
                    exit_code=app_exec_exit_code,
                    message=failure_message,
                    started_at=app_exec_started_at,
                    completed_at=app_exec_completed_at,
                    duration_ms=app_exec_duration_ms,
                )
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    failure_message,
                    stage="execute_runtime_operation",
                    details=details or "remote command failed",
                    extra={
                        "operation_id": operation_id,
                        "project_slug": app_config.project_slug,
                        "action": label,
                        "command": normalized_exec_command,
                        "timeout_seconds": normalized_exec_timeout_seconds,
                        "exit_code": app_exec_exit_code,
                        "started_at": app_exec_started_at.isoformat()
                        if app_exec_started_at is not None
                        else None,
                        "completed_at": app_exec_completed_at.isoformat()
                        if app_exec_completed_at is not None
                        else None,
                        "duration_ms": app_exec_duration_ms,
                        "stdout_lines": app_exec_stdout_lines,
                        "stderr_lines": app_exec_stderr_lines,
                    },
                )

            ctx.emit_event(
                emit,
                "app_runtime_action_completed",
                f"{label}: completed",
            )

        success_messages = {
            "disconnect": "Web app runtime disconnected.",
            "resource_usage": "Web app resource usage captured.",
            "runtime_logs": "Web app runtime logs captured.",
            "exec": "One-off app command completed.",
            "sqlite_volume_ensure": "SQLite volume ensured.",
            "sqlite_volume_status": "SQLite volume status captured.",
            "sqlite_volume_delete": "SQLite volume deleted.",
            "workers_apply": "Worker runtime applied.",
            "workers_precheck": "Worker runtime prerequisites captured.",
            "workers_status": "Worker runtime status captured.",
            "worker_start": "Worker started.",
            "worker_stop": "Worker stopped.",
            "worker_restart": "Worker restarted.",
            "worker_logs": "Worker logs captured.",
        }
        response = {
            "status": "success",
            "code": "OK",
            "msg": success_messages.get(operation_id, "Runtime operation completed."),
            "operation_id": operation_id,
            "project_slug": app_config.project_slug,
        }
        if operation_id == "resource_usage":
            response["resource_usage"] = resource_usage
            response["sqlite_storage"] = sqlite_storage_payload
            response["container_status"] = app_container_status
            response["public_health"] = public_health
        if operation_id in sqlite_operation_ids:
            response["sqlite_storage"] = sqlite_storage_payload
        if operation_id == "runtime_logs":
            response["log_tail_lines"] = normalized_log_tail_lines
            response["runtime_log_lines"] = runtime_log_lines
        if operation_id == "exec":
            _emit_app_exec_result_event(
                ctx,
                emit,
                command=normalized_exec_command,
                terminal_status="success",
                exit_code=app_exec_exit_code,
                message=response["msg"],
                started_at=app_exec_started_at,
                completed_at=app_exec_completed_at,
                duration_ms=app_exec_duration_ms,
            )
            response["command"] = normalized_exec_command
            response["timeout_seconds"] = normalized_exec_timeout_seconds
            response["exit_code"] = app_exec_exit_code
            response["started_at"] = (
                app_exec_started_at.isoformat() if app_exec_started_at else None
            )
            response["completed_at"] = (
                app_exec_completed_at.isoformat() if app_exec_completed_at else None
            )
            response["duration_ms"] = app_exec_duration_ms
            response["stdout_lines"] = app_exec_stdout_lines
            response["stderr_lines"] = app_exec_stderr_lines
        if operation_id in worker_runtime_snapshot_operation_ids:
            response["workers"] = _build_worker_runtime_snapshot(
                app_config,
                worker_runtime_rows,
            )
        if operation_id in targeted_worker_operation_ids and normalized_worker_id is not None:
            response["worker_id"] = normalized_worker_id
        if operation_id == "workers_precheck":
            response["workers_precheck"] = worker_precheck_payload or {
                "image_exists": False,
                "app_container_exists": False,
                "app_container_running": False,
                "worker_network": None,
            }
        if operation_id == "worker_logs":
            response["worker_id"] = normalized_worker_id
            response["log_tail_lines"] = normalized_log_tail_lines
            response["logs"] = worker_log_lines
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


def run_app_runtime_operation(
    ctx: SupportsAppRuntimeOperations,
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
    log_tail_lines=200,
    worker_id=None,
    release_id=None,
    command=None,
    timeout_seconds=None,
):
    """Route an app runtime request through preparation and shared execution."""
    prepared = _prepare_runtime_operation(
        ctx,
        operation_id=operation_id,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        raw_data=raw_data,
        emit=emit,
        is_cancelled=is_cancelled,
        log_tail_lines=log_tail_lines,
        worker_id=worker_id,
        release_id=release_id,
        command=command,
        timeout_seconds=timeout_seconds,
    )
    if isinstance(prepared, dict):
        return prepared
    return _execute_runtime_plan(ctx, prepared)
