# ruff: noqa: F403, F405

from ..engine_context import SupportsAppDeployment
from ._shared import *
from .release_lifecycle import *


def prepare_app_deploy_key(
    ctx: SupportsAppDeployment,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=True,
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
        app_config = parse_app_config(raw_data, require_domain=False)
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

    session = None
    steps = build_prepare_key_steps(app_config)
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
            "app_prepare_key_ready",
            "Web app deploy key plan prepared.",
            data={
                "step_count": len(steps),
                "dry_run": dry_run,
                "project_slug": app_config.project_slug,
            },
        )

        def _emit_from_executor(event_type, message, level="info", data=None):
            ctx.emit_event(
                emit,
                event_type,
                message,
                level=level,
                data=data,
            )

        summary_data = {
            "project_slug": app_config.project_slug,
            "key_public_path": app_config.key_public_path,
            "key_private_path": app_config.key_private_path,
        }

        if dry_run:
            return run_plan_dry(
                steps=steps,
                parts=["part0"],
                summary_data=summary_data,
                emit_event=_emit_from_executor,
                is_cancelled=is_cancelled,
                message="Web app deploy key plan ready",
            )

        result = run_plan_execute(
            session=session,
            steps=steps,
            parts=["part0"],
            summary_data=summary_data,
            emit_event=_emit_from_executor,
            is_cancelled=is_cancelled,
            message="Web app deploy key prepared",
            failure_message_prefix="Web app deploy key preparation failed at",
        )
        if result.get("status") != "success":
            return result

        try:
            deploy_public_key = ctx.read_remote_file_text(
                session.host,
                app_config.key_public_path,
            )
            deploy_private_key = ctx.read_remote_file_text(
                session.host,
                app_config.key_private_path,
            )
        except Exception as exc:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Deploy key was prepared but could not be read from server.",
                stage="read_deploy_key",
                details=ctx.sanitize_message(str(exc)),
                extra={
                    "project_slug": app_config.project_slug,
                    "key_public_path": app_config.key_public_path,
                    "key_private_path": app_config.key_private_path,
                },
            )

        cleanup_command = f"rm -rf {shlex.quote(app_config.key_dir)}"
        cleanup_ok, cleanup_output = session.host.run_shell_command(
            cleanup_command,
            _timeout=10,
            _sudo=True,
        )
        if not cleanup_ok:
            cleanup_details = ""
            if cleanup_output is not None and getattr(cleanup_output, "stderr_lines", None):
                cleanup_details = "; ".join(cleanup_output.stderr_lines).strip()
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Deploy key was copied but could not be wiped from server.",
                stage="cleanup_deploy_key",
                details=cleanup_details or "remote cleanup command failed",
                extra={
                    "project_slug": app_config.project_slug,
                    "key_dir": app_config.key_dir,
                },
            )

        result["deploy_public_key"] = deploy_public_key
        result["deploy_private_key"] = deploy_private_key
        result["key_public_path"] = app_config.key_public_path
        result["key_private_path"] = app_config.key_private_path
        result["key_dir"] = app_config.key_dir
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


def deploy_application(
    ctx: SupportsAppDeployment,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    parts=None,
    dry_run=True,
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
        app_config = parse_app_config(raw_data, require_domain=True)
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

    http_settings = dict(CANONICAL_HTTP_SETTINGS)
    # stack_root is deliberately not set here. It is server-owned (T-1.1.4),
    # so _setup_http_gateway would reject it, and setting it was already a
    # no-op: app_config.caddy_stack_root and CANONICAL_HTTP_SETTINGS
    # ["stack_root"] both resolve to server_paths.http_root(), and no client
    # or test overrides caddy_stack_root. Section 1.4 removes that key from
    # the wire too, at which point the equivalence is enforced rather than
    # merely true.
    http_settings["container_name"] = app_config.caddy_container_name
    http_settings["server_address"] = ip

    session = None
    ctx.emit_event(
        emit,
        "app_dependency_http_probe_start",
        "Checking whether HTTP gateway foundation can be skipped.",
    )
    probe_opened = ctx.open_runtime_session(
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        needs_sudo=True,
        emit=emit,
    )
    if probe_opened["ok"]:
        probe_session = probe_opened["session"]
        try:
            probe_result = ctx.probe_http_gateway_fast_path(
                probe_session.host,
                app_config,
            )
        except Exception as exc:
            probe_result = {
                "ready": False,
                "reason": "Fast-path probe failed",
                "details": ctx.sanitize_message(str(exc)),
                "failed_check": "probe_runtime_error",
            }

        if probe_result.get("ready"):
            ctx.emit_event(
                emit,
                "app_dependency_http_probe_ready",
                "HTTP gateway fast-path checks passed; skipping full foundation bootstrap.",
            )
            session = probe_session
        else:
            failed_check = probe_result.get("failed_check")
            reason = probe_result.get("reason") or "Fast-path checks did not pass"
            details = probe_result.get("details")
            if details:
                reason = f"{reason}: {details}"
            if failed_check == "caddy_dns_module":
                ctx.emit_event(
                    emit,
                    "app_dependency_http_probe_missing_dns_module",
                    reason,
                    level="error",
                    data={"failed_check": failed_check},
                )
                close_result = probe_session.close()
                disconnect_error = close_result.get("disconnect_error")
                if disconnect_error:
                    ctx.emit_event(
                        emit,
                        "connection_disconnect_error",
                        disconnect_error,
                        level="warning",
                    )
                return ctx.error_result(
                    "ENGINE_DEPENDENCY_ERROR",
                    reason,
                    stage="ensure_http_gateway",
                    extra={
                        "dependency": "http",
                        "failed_check": failed_check,
                    },
                )
            ctx.emit_event(
                emit,
                "app_dependency_http_probe_fallback",
                f"{reason}. Running full HTTP gateway foundation.",
                level="warning",
                data={"failed_check": failed_check},
            )
            close_result = probe_session.close()
            disconnect_error = close_result.get("disconnect_error")
            if disconnect_error:
                ctx.emit_event(
                    emit,
                    "connection_disconnect_error",
                    disconnect_error,
                    level="warning",
                )
    else:
        ctx.emit_event(
            emit,
            "app_dependency_http_probe_fallback",
            "Fast-path probe could not run; executing full HTTP gateway foundation.",
            level="warning",
        )

    if session is None:
        ctx.emit_event(
            emit,
            "app_dependency_http_start",
            "Ensuring HTTP gateway foundation is ready before web app deploy.",
        )
        http_result = ctx.setup_http_gateway(
            ip=ip,
            username=username,
            password=password,
            key_filename=key_filename,
            port=port,
            parts=None,
            dry_run=dry_run,
            raw_data={"settings": http_settings},
            emit=emit,
            is_cancelled=is_cancelled,
        )
        if http_result.get("status") != "success":
            return ctx.error_result(
                "ENGINE_DEPENDENCY_ERROR",
                "HTTP gateway bootstrap failed before web app deployment.",
                stage="ensure_http_gateway",
                details=http_result.get("msg"),
                extra={
                    "dependency": "http",
                    "dependency_code": http_result.get("code"),
                },
            )
        ctx.emit_event(
            emit,
            "app_dependency_http_ready",
            "HTTP gateway foundation is ready.",
        )

    normalized_parts = normalize_app_parts(parts)
    if normalized_parts is None:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Invalid parts format. Use comma-separated string or list.",
            stage="validate_request",
        )

    step_result = collect_app_steps(normalized_parts, app_config)
    if not step_result["ok"]:
        invalid = ", ".join(step_result["invalid_parts"])
        ctx.emit_event(
            emit,
            "validation_error",
            f"Unknown app parts: {invalid}",
            level="error",
        )
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Unknown app parts: {invalid}",
            stage="validate_request",
        )

    steps = step_result["steps"]

    if session is None:
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
            "app_deploy_plan_ready",
            "Web app deploy plan prepared.",
            data={
                "parts": normalized_parts,
                "step_count": len(steps),
                "dry_run": dry_run,
                "project_slug": app_config.project_slug,
                "repository_full_name": app_config.repository_full_name,
                "primary_domain": app_config.primary_domain,
                "app_subdirectory": app_config.app_subdirectory,
            },
        )

        def _emit_from_executor(event_type, message, level="info", data=None):
            ctx.emit_event(
                emit,
                event_type,
                message,
                level=level,
                data=data,
            )

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
            "resolved_config": settings_ownership.resolved_config_snapshot(
                app_config, RESOLVED_APP_DEFAULTS
            ),
        }

        if dry_run:
            return run_plan_dry(
                steps=steps,
                parts=normalized_parts,
                summary_data=summary_data,
                emit_event=_emit_from_executor,
                is_cancelled=is_cancelled,
                message="Web app deploy plan ready",
            )

        return _execute_versioned_release_deploy(
            ctx,
            session=session,
            app_config=app_config,
            normalized_parts=normalized_parts,
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
