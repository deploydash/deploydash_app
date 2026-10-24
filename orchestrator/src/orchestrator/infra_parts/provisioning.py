# ruff: noqa: F403, F405

from ._shared import *
from .overview import (
    _merge_plan_execution_results,
    _split_setup_steps_for_verified_handoff,
    get_hardware_specs,
)


def setup_server(
    ctx,
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
        setup_config = parse_setup_config(raw_data)
    except SetupConfigValidationError as exc:
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

    normalized_parts = normalize_setup_parts(parts)
    if normalized_parts is None:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Invalid parts format. Use comma-separated string or list.",
            stage="validate_request",
        )

    managed_connection = resolve_managed_connection(raw_data, ip, port)
    if managed_connection is None:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            (
                "Setup requires a managed ubuntu SSH connection so Deploy Dash "
                "can verify server ownership safely."
            ),
            stage="validate_request",
        )

    step_result = collect_setup_steps(normalized_parts, setup_config)
    if not step_result["ok"]:
        invalid = ", ".join(step_result["invalid_parts"])
        ctx.emit_event(
            emit,
            "validation_error",
            f"Unknown setup parts: {invalid}",
            level="error",
        )
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Unknown setup parts: {invalid}",
            stage="validate_request",
        )

    steps = step_result["steps"]
    bootstrap_steps, remaining_steps = _split_setup_steps_for_verified_handoff(
        steps,
    )
    ordered_steps = [*bootstrap_steps, *remaining_steps]

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
        specs = get_hardware_specs(ctx, session.host)
        if specs.get("status") != "success":
            ctx.emit_event(
                emit,
                "facts_error",
                specs.get("msg", "Failed to retrieve specs"),
                level="error",
            )
            return specs

        ctx.emit_event(
            emit,
            "setup_plan_ready",
            "Setup plan prepared.",
            data={
                "parts": normalized_parts,
                "step_count": len(ordered_steps),
                "dry_run": dry_run,
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
            "os": specs.get("os"),
            "cpu": specs.get("cpu"),
            "memory_mb": specs.get("memory_mb"),
            "disk_gb": specs.get("disk_gb"),
        }

        if dry_run:
            return run_plan_dry(
                steps=ordered_steps,
                parts=normalized_parts,
                summary_data=summary_data,
                emit_event=_emit_from_executor,
                is_cancelled=is_cancelled,
                message="Server setup plan ready",
            )

        bootstrap_connection = {
            "ip": ip,
            "username": username,
            "password": password,
            "key_path": key_filename,
            "port": port,
        }
        active_connection = dict(bootstrap_connection)
        bootstrap_result = None
        remaining_result = None

        if bootstrap_steps:
            bootstrap_result = run_plan_execute(
                session=session,
                steps=bootstrap_steps,
                parts=normalized_parts,
                summary_data=summary_data,
                emit_event=_emit_from_executor,
                is_cancelled=is_cancelled,
                message="Server ownership bootstrap completed",
                failure_message_prefix="Setup failed at",
            )
            if bootstrap_result.get("status") != "success":
                return bootstrap_result

            ctx.emit_event(
                emit,
                "setup_managed_connection_verification_started",
                "Checking the new ubuntu SSH login before locking down access.",
            )
            verify_result = verify_runtime_session_connection(
                managed_connection,
                open_runtime_session=ctx.open_runtime_session,
                error_result=ctx.error_result,
                emit_event=ctx.emit_event,
                emit_shell_output_lines=ctx.emit_shell_output_lines,
                emit=emit,
            )
            if not verify_result["ok"]:
                return verify_result["error"]

            ssh_hardening_result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection=bootstrap_connection,
                managed_connection=managed_connection,
                target_port=port,
                disable_root_login=setup_config.disable_root_login,
                disable_password_auth=setup_config.disable_password_auth,
                verify_connection=lambda connection, emit=None: verify_runtime_session_connection(
                    connection,
                    open_runtime_session=ctx.open_runtime_session,
                    error_result=ctx.error_result,
                    emit_event=ctx.emit_event,
                    emit_shell_output_lines=ctx.emit_shell_output_lines,
                    emit=emit,
                ),
                error_result=ctx.error_result,
                emit_event=ctx.emit_event,
                emit_shell_output_lines=ctx.emit_shell_output_lines,
                emit=emit,
            )
            if not ssh_hardening_result["ok"]:
                return ssh_hardening_result["error"]

            active_connection = {
                **managed_connection,
                "port": ssh_hardening_result["managed_port"],
            }
            ctx.emit_event(
                emit,
                "setup_managed_connection_verification_completed",
                ("Managed ubuntu access is verified. Continuing with the rest of server setup."),
            )

        # No `if remaining_steps` guard: every part contributes at least one
        # non-bootstrap step (part1 always ends with time sync) and parts
        # always normalize to a non-empty list, so remaining is never empty.
        remaining_session = session
        remaining_needs_close = False
        if active_connection != bootstrap_connection:
            remaining_opened = ctx.open_runtime_session(
                ip=active_connection["ip"],
                username=active_connection["username"],
                password=active_connection.get("password"),
                key_filename=active_connection.get("private_key")
                or active_connection.get("key_path"),
                port=active_connection["port"],
                needs_sudo=True,
                emit=emit,
            )
            if not remaining_opened["ok"]:
                return remaining_opened["error"]
            remaining_session = remaining_opened["session"]
            remaining_needs_close = True

        try:
            remaining_result = run_plan_execute(
                session=remaining_session,
                steps=remaining_steps,
                parts=normalized_parts,
                summary_data=summary_data,
                emit_event=_emit_from_executor,
                is_cancelled=is_cancelled,
                message="Server setup completed",
                failure_message_prefix="Setup failed at",
            )
        finally:
            if remaining_needs_close:
                remaining_close_result = remaining_session.close()
                remaining_disconnect_error = remaining_close_result.get(
                    "disconnect_error",
                )
                if remaining_disconnect_error:
                    ctx.emit_event(
                        emit,
                        "connection_disconnect_error",
                        remaining_disconnect_error,
                        level="warning",
                    )

        if remaining_result.get("status") != "success":
            return remaining_result

        if bootstrap_steps and "part3" in normalized_parts:
            firewall_result = apply_onboarding_firewall_baseline(
                active_connection,
                verify_connection=lambda connection, emit=None: verify_runtime_session_connection(
                    connection,
                    open_runtime_session=ctx.open_runtime_session,
                    error_result=ctx.error_result,
                    emit_event=ctx.emit_event,
                    emit_shell_output_lines=ctx.emit_shell_output_lines,
                    emit=emit,
                ),
                open_runtime_session=ctx.open_runtime_session,
                error_result=ctx.error_result,
                emit_event=ctx.emit_event,
                emit_shell_output_lines=ctx.emit_shell_output_lines,
                emit=emit,
                is_cancelled=is_cancelled,
            )
            if not firewall_result["ok"]:
                return firewall_result["error"]

        setup_result = _merge_plan_execution_results(
            bootstrap_result,
            remaining_result,
            message="Server setup completed",
        )

        layout_outcome = server_layout.verify_layout_after_setup(remaining_session.host)
        if not layout_outcome.ok:
            ctx.emit_event(
                emit,
                "setup_layout_verification_failed",
                layout_outcome.message,
                level="error",
                data={"code": layout_outcome.code},
            )
            return ctx.error_result(
                layout_outcome.code,
                layout_outcome.message,
                stage="verify_layout_version",
            )

        http_settings = dict(CANONICAL_HTTP_SETTINGS)
        http_settings["server_address"] = ip
        try:
            # Trusted: http_settings is built from CANONICAL_HTTP_SETTINGS
            # here on the server, not received from a client.
            http_config = parse_http_config(
                {"settings": http_settings},
                connection_ip=ip,
                trusted=True,
            )
        except HttpConfigValidationError as exc:
            ctx.emit_event(
                emit,
                "setup_http_bootstrap_failed",
                f"Mandatory HTTP gateway bootstrap validation failed: {exc}",
                level="error",
            )
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                ("Server setup completed but mandatory HTTP gateway bootstrap request is invalid."),
                stage="setup_http_bootstrap",
                details=str(exc),
                extra={"dependency": "http"},
            )

        http_parts = ["part1", "part2"]
        # Collection cannot fail: the parts above are hardcoded and always
        # known. If they ever become caller-supplied, reinstate the
        # not-ok branch that was collapsed here.
        http_step_result = collect_http_steps(http_parts, http_config)

        ctx.emit_event(
            emit,
            "setup_http_bootstrap_started",
            ("Server setup completed. Running mandatory HTTP gateway bootstrap."),
            data={
                "parts": http_parts,
                "step_count": len(http_step_result["steps"]),
            },
        )

        http_opened = ctx.open_runtime_session(
            ip=active_connection["ip"],
            username=active_connection["username"],
            password=active_connection.get("password"),
            key_filename=active_connection.get("private_key") or active_connection.get("key_path"),
            port=active_connection["port"],
            needs_sudo=True,
            emit=emit,
        )
        if not http_opened["ok"]:
            return http_opened["error"]

        http_session = http_opened["session"]
        try:
            http_result = run_plan_execute(
                session=http_session,
                steps=http_step_result["steps"],
                parts=http_parts,
                summary_data={
                    "stack_root": http_config.stack_root,
                    "container_name": http_config.container_name,
                    "default_hostname": http_config.default_hostname,
                    "server_address": http_config.server_address,
                    "server_ip": http_config.server_ip,
                },
                emit_event=_emit_from_executor,
                is_cancelled=is_cancelled,
                message="HTTP gateway setup completed",
                failure_message_prefix="HTTP gateway setup failed at",
            )
        finally:
            http_close_result = http_session.close()
            http_disconnect_error = http_close_result.get("disconnect_error")
            if http_disconnect_error:
                ctx.emit_event(
                    emit,
                    "connection_disconnect_error",
                    http_disconnect_error,
                    level="warning",
                )

        if http_result.get("status") != "success":
            if http_result.get("code") == "ENGINE_TASK_CANCELLED":
                return http_result
            ctx.emit_event(
                emit,
                "setup_http_bootstrap_failed",
                ("Mandatory HTTP gateway bootstrap failed; server provisioning is marked failed."),
                level="error",
                data={
                    "dependency_code": http_result.get("code"),
                    "failed_step_id": http_result.get("failed_step_id"),
                },
            )
            return ctx.error_result(
                "ENGINE_DEPENDENCY_ERROR",
                ("Server setup completed but mandatory HTTP gateway bootstrap failed."),
                stage="setup_http_bootstrap",
                details=http_result.get("msg"),
                extra={
                    "dependency": "http",
                    "dependency_code": http_result.get("code"),
                    "dependency_failed_step_id": http_result.get(
                        "failed_step_id",
                    ),
                    "dependency_details": http_result.get("details"),
                },
            )

        ctx.emit_event(
            emit,
            "setup_http_bootstrap_completed",
            "Mandatory HTTP gateway bootstrap completed successfully.",
        )

        setup_result["msg"] = "Server setup completed. HTTP gateway is installed and running."
        setup_result["managed_connection"] = build_managed_connection_result(
            active_connection,
        )
        if setup_config.managed_user_password is not None:
            setup_result["managed_user_password"] = setup_config.managed_user_password
        setup_result["http_bootstrap"] = {
            "status": "success",
            "parts": http_parts,
            "stack_root": http_config.stack_root,
            "container_name": http_config.container_name,
            "completed_step_ids": http_result.get("completed_step_ids", []),
            "scheduled_action_ids": http_result.get("scheduled_action_ids", []),
            "completed_action_ids": http_result.get("completed_action_ids", []),
        }
        return setup_result
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


def setup_http_gateway(
    ctx,
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
        http_config = parse_http_config(raw_data, connection_ip=ip)
    except HttpConfigValidationError as exc:
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

    normalized_parts = normalize_http_parts(parts)
    if normalized_parts is None:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Invalid parts format. Use comma-separated string or list.",
            stage="validate_request",
        )

    step_result = collect_http_steps(normalized_parts, http_config)
    if not step_result["ok"]:
        invalid = ", ".join(step_result["invalid_parts"])
        ctx.emit_event(
            emit,
            "validation_error",
            f"Unknown HTTP parts: {invalid}",
            level="error",
        )
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Unknown HTTP parts: {invalid}",
            stage="validate_request",
        )

    steps = step_result["steps"]

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
            "http_plan_ready",
            "HTTP service plan prepared.",
            data={
                "parts": normalized_parts,
                "step_count": len(steps),
                "dry_run": dry_run,
                "stack_root": http_config.stack_root,
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
            "stack_root": http_config.stack_root,
            "container_name": http_config.container_name,
            "default_hostname": http_config.default_hostname,
            "server_address": http_config.server_address,
            "server_ip": http_config.server_ip,
            "resolved_config": settings_ownership.resolved_config_snapshot(
                http_config, RESOLVED_HTTP_DEFAULTS
            ),
        }

        if dry_run:
            return run_plan_dry(
                steps=steps,
                parts=normalized_parts,
                summary_data=summary_data,
                emit_event=_emit_from_executor,
                is_cancelled=is_cancelled,
                message="HTTP gateway plan ready",
            )

        return run_plan_execute(
            session=session,
            steps=steps,
            parts=normalized_parts,
            summary_data=summary_data,
            emit_event=_emit_from_executor,
            is_cancelled=is_cancelled,
            message="HTTP gateway setup completed",
            failure_message_prefix="HTTP gateway setup failed at",
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


def run_http_runtime_operation(
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
        http_config = parse_http_config(raw_data, connection_ip=ip)
    except HttpConfigValidationError as exc:
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

    quoted_container_name = shlex.quote(http_config.container_name)
    quoted_stack_root = shlex.quote(http_config.stack_root)
    quoted_apply_helper = shlex.quote(server_paths.caddy_apply_helper())
    caddy_status_command = (
        "set -eu; "
        'kv(){ printf "%s=%s\\n" "$1" "$2"; }; '
        f"{container_status_kv_shell('container', quoted_container_name)}; "
        "READINESS_STATUS='not_checked'; "
        "READINESS_DETAIL=''; "
        f"if {caddy_service_readiness_check_shell(quoted_container_name)}; then "
        "READINESS_STATUS='ready'; "
        "else "
        "READINESS_STATUS='unhealthy'; "
        "READINESS_DETAIL='caddy validate failed'; "
        "fi; "
        'kv container_readiness_status "${READINESS_STATUS}"; '
        'kv container_readiness_detail "${READINESS_DETAIL}"'
    )

    caddy_apply_command = (
        f"if [ -x {quoted_apply_helper} ]; then "
        f"{quoted_apply_helper} {quoted_stack_root} {quoted_container_name}; "
        "else "
        f"COMPOSE_FILE={quoted_stack_root}/docker-compose.yml; "
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
        f"{caddy_service_readiness_check_shell(quoted_container_name)}; "
        "docker exec "
        f"{quoted_container_name} "
        "caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; "
        "fi"
    )

    operation_steps = {
        "service_start": [
            ("Start web server", caddy_apply_command, False),
            (
                "Verify web server readiness",
                caddy_service_readiness_check_shell(quoted_container_name),
                False,
            ),
        ],
        "service_stop": [
            (
                "Stop web server",
                f"if {container_process_running_check_shell(quoted_container_name)}; then "
                f"docker stop {quoted_container_name}; "
                "else "
                "echo 'Web server container is already stopped.'; "
                "fi",
                True,
            ),
        ],
        "service_restart": [
            (
                "Restart web server",
                f"{container_process_running_check_shell(quoted_container_name)} || "
                "(echo 'Web server container is not running. Start it first.' >&2; exit 1); "
                f"docker restart {quoted_container_name}",
                False,
            ),
            (
                "Verify web server readiness",
                caddy_service_readiness_check_shell(quoted_container_name),
                False,
            ),
        ],
        "service_status": [
            (
                "Collect web server status",
                caddy_status_command,
                True,
            ),
        ],
    }

    if operation_id not in operation_steps:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Unknown web server runtime operation: {operation_id}",
            stage="validate_request",
        )

    if dry_run:
        return {
            "status": "success",
            "code": "OK",
            "msg": f"Web server runtime operation '{operation_id}' plan ready",
            "operation_id": operation_id,
            "actions": [step[0] for step in operation_steps[operation_id]],
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
    service_status = None
    try:
        ctx.emit_event(
            emit,
            "http_runtime_plan_ready",
            f"Runtime operation '{operation_id}' prepared.",
            data={"operation_id": operation_id},
        )

        for label, command, allow_failure in operation_steps[operation_id]:
            if callable(is_cancelled) and is_cancelled():
                return ctx.error_result(
                    "ENGINE_TASK_CANCELLED",
                    "Task cancelled during runtime operation",
                    stage="execute_runtime_operation",
                )

            ctx.emit_event(
                emit,
                "http_runtime_action_started",
                f"{label}: started",
            )
            status, output = session.host.run_shell_command(
                command,
                _timeout=60,
                _sudo=True,
            )
            ctx.emit_shell_output_lines(emit, output)
            if operation_id == "service_status":
                service_status = _parse_http_service_status_output(output)

            if not status and not allow_failure:
                details = ctx.command_error_details(output)
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    f"{label} failed.",
                    stage="execute_runtime_operation",
                    details=details or "remote command failed",
                    extra={
                        "operation_id": operation_id,
                        "action": label,
                    },
                )

            ctx.emit_event(
                emit,
                "http_runtime_action_completed",
                f"{label}: completed",
            )

        success_messages = {
            "service_start": "Web server started.",
            "service_stop": "Web server stopped.",
            "service_restart": "Web server restarted.",
            "service_status": "Web server status collected.",
        }
        response = {
            "status": "success",
            "code": "OK",
            "msg": success_messages.get(
                operation_id,
                "Web server runtime operation completed.",
            ),
            "operation_id": operation_id,
        }
        if operation_id == "service_status":
            response["service_status"] = service_status or {"running": False}
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


def setup_dns_server(
    ctx,
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
        dns_config = parse_dns_config(raw_data, connection_ip=ip)
    except DnsConfigValidationError as exc:
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

    normalized_parts = normalize_dns_parts(parts)
    if normalized_parts is None:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Invalid parts format. Use comma-separated string or list.",
            stage="validate_request",
        )

    step_result = collect_dns_steps(normalized_parts, dns_config)
    if not step_result["ok"]:
        invalid = ", ".join(step_result["invalid_parts"])
        ctx.emit_event(
            emit,
            "validation_error",
            f"Unknown DNS parts: {invalid}",
            level="error",
        )
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Unknown DNS parts: {invalid}",
            stage="validate_request",
        )

    steps = step_result["steps"]

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
            "dns_plan_ready",
            "DNS service plan prepared.",
            data={
                "parts": normalized_parts,
                "step_count": len(steps),
                "dry_run": dry_run,
                "zone_name": dns_config.zone_name,
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
            "zone_name": dns_config.zone_name,
            "zone_count": dns_config.zone_count,
            "zone_names": dns_config.zone_names,
            "nameserver_fqdn": dns_config.nameserver_fqdn,
            "nameserver_ipv4": dns_config.nameserver_ipv4,
            "nameserver_ipv6": dns_config.nameserver_ipv6,
            "container_name": dns_config.container_name,
            "bind_image": dns_config.bind_image,
            "bind_service_name": dns_config.bind_service_name,
            "resolved_config": settings_ownership.resolved_config_snapshot(
                dns_config, RESOLVED_DNS_DEFAULTS
            ),
        }

        if dry_run:
            return run_plan_dry(
                steps=steps,
                parts=normalized_parts,
                summary_data=summary_data,
                emit_event=_emit_from_executor,
                is_cancelled=is_cancelled,
                message="DNS server plan ready",
            )

        return run_plan_execute(
            session=session,
            steps=steps,
            parts=normalized_parts,
            summary_data=summary_data,
            emit_event=_emit_from_executor,
            is_cancelled=is_cancelled,
            message="DNS server setup completed",
            failure_message_prefix="DNS server setup failed at",
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
