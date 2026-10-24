import shlex
import time

from . import engine_firewall_ops, server_paths, shell_output
from .engine_context import build_partial_context
from .runtime_ops import run_shell_command
from .setup_security import build_onboarding_firewall_config

_FIREWALL_VERIFY_ATTEMPTS = 6
_FIREWALL_VERIFY_RETRY_DELAYS = (5.0, 10.0, 15.0, 20.0, 25.0)


def _close_runtime_session(session, *, emit_event, emit=None):
    close_result = session.close()
    disconnect_error = close_result.get("disconnect_error")
    if disconnect_error:
        emit_event(
            emit,
            "connection_disconnect_error",
            disconnect_error,
            level="warning",
        )


def verify_runtime_session_connection(
    connection,
    *,
    open_runtime_session,
    error_result,
    emit_event,
    emit_shell_output_lines,
    emit=None,
):
    opened = open_runtime_session(
        ip=connection["ip"],
        username=connection["username"],
        password=connection.get("password"),
        key_filename=connection.get("private_key") or connection.get("key_path"),
        port=connection.get("port", 22),
        needs_sudo=True,
        emit=emit,
    )
    if not opened["ok"]:
        return opened

    session = opened["session"]
    try:
        verify_result = run_shell_command(
            session.host,
            "echo deploydash-setup-verify",
            timeout=10,
            sudo=True,
            emit_output=lambda output: emit_shell_output_lines(emit, output),
        )
        if not verify_result["ok"]:
            return {
                "ok": False,
                "error": error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Managed SSH verification command failed.",
                    stage="verify_runtime_operation",
                    details=verify_result["details"],
                ),
            }
        return {"ok": True}
    finally:
        _close_runtime_session(session, emit_event=emit_event, emit=emit)


def render_sshd_restart_command(port=None):
    """Restart the listener owner and prove a requested SSH port is bound."""
    if port is None:
        return "systemctl restart ssh || systemctl restart sshd"
    listener_port = int(port)
    return (
        "if systemctl is-active --quiet ssh.socket || "
        "systemctl is-enabled --quiet ssh.socket; then "
        "systemctl daemon-reload; "
        "systemctl restart ssh.socket; "
        "systemctl restart ssh.service; "
        "else systemctl restart ssh || systemctl restart sshd; fi; "
        f"ss -ltnH 'sport = :{listener_port}' | grep -q ."
    )


def set_sshd_options_command(options, *, restart=True):
    normalized_options = tuple(options)
    if not normalized_options:
        raise ValueError("At least one SSH daemon option is required.")
    update_commands = " ".join(
        f"update_sshd_option {shlex.quote(option_name)} {shlex.quote(option_value)};"
        for option_name, option_value in normalized_options
    )
    verify_commands = " ".join(
        f"verify_sshd_option {shlex.quote(option_name)} {shlex.quote(option_value)};"
        for option_name, option_value in normalized_options
    )
    requested_port = next(
        (
            option_value
            for option_name, option_value in reversed(normalized_options)
            if option_name.lower() == "port"
        ),
        None,
    )
    restart_command = (
        render_sshd_restart_command(requested_port if requested_port is not None else None)
        if restart
        else ":"
    )
    return (
        "set -eu; "
        'MAIN_FILE="/etc/ssh/sshd_config"; '
        f'MANAGED_FILE="{server_paths.SSHD_DROPIN_FILE}"; '
        "update_sshd_option() { "
        'KEY="$1"; VALUE="$2"; '
        'if [ "$KEY" = "Port" ]; then '
        "sed -i -E '/^[[:space:]]*Port[[:space:]]+/d' \"$MAIN_FILE\"; fi; "
        'case "$KEY" in PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|Port) '
        'mkdir -p "$(dirname "$MANAGED_FILE")"; '
        'touch "$MANAGED_FILE"; chmod 600 "$MANAGED_FILE"; FILE="$MANAGED_FILE" ;; '
        '*) FILE="$MAIN_FILE" ;; esac; '
        'if grep -Eq "^[[:space:]#]*${KEY}[[:space:]]+" "$FILE"; then '
        'sed -i -E "s|^[[:space:]#]*${KEY}[[:space:]]+.*$|${KEY} ${VALUE}|g" "$FILE"; '
        'else printf "\\n%s %s\\n" "$KEY" "$VALUE" >> "$FILE"; fi; '
        "}; "
        "verify_sshd_option() { "
        'KEY="$1"; VALUE="$2"; '
        'KEY_LOWER="$(printf "%s" "$KEY" | tr "[:upper:]" "[:lower:]")"; '
        'ACTUAL="$(sshd -T | awk -v key="$KEY_LOWER" '
        "'$1 == key {print $2; exit}')\"; "
        'if [ "$ACTUAL" != "$VALUE" ]; then '
        'printf "Effective sshd option %s is %s, expected %s.\\n" '
        '"$KEY" "${ACTUAL:-missing}" "$VALUE" >&2; exit 1; fi; '
        "}; "
        f"{update_commands} "
        "sshd -t; "
        f"{verify_commands} "
        f"{restart_command}"
    )


def set_sshd_option_command(option_name, option_value):
    return set_sshd_options_command(((option_name, option_value),))


def _restore_sshd_configuration(
    host,
    *,
    backup_path,
    dropin_restore_command,
    bootstrap_port,
    emit_shell_output_lines,
    emit,
):
    """Restore the pre-hardening SSH state after any post-backup failure."""
    return run_shell_command(
        host,
        (
            "set -eu; "
            f"cp {shlex.quote(backup_path or '')} /etc/ssh/sshd_config; "
            f"{dropin_restore_command}"
            "sshd -t; "
            f"{render_sshd_restart_command(bootstrap_port)}"
        ),
        timeout=30,
        sudo=True,
        emit_output=lambda output: emit_shell_output_lines(emit, output),
    )


def _sshd_rollback_failed_result(
    error_result,
    *,
    message,
    stage,
    details,
    backup_path,
    dropin_backup_path,
    dropin_present,
):
    """Expose the durable recovery data when automatic SSH restoration fails."""
    return {
        "ok": False,
        "error": error_result(
            "ENGINE_SSH_HARDENING_ROLLBACK_FAILED",
            message,
            stage=stage,
            details=details,
            extra={
                "rollback_performed": False,
                "sshd_backup_path": backup_path,
                "sshd_dropin_backup_path": dropin_backup_path if dropin_present else None,
                "recovery_hint": (
                    "Restore the backup over /etc/ssh/sshd_config through the hosting "
                    "provider's console, then run `sshd -t` and restart the SSH service."
                ),
            },
        ),
    }


def apply_verified_onboarding_ssh_hardening(
    *,
    bootstrap_session,
    bootstrap_connection,
    managed_connection,
    target_port,
    disable_root_login,
    disable_password_auth,
    verify_connection,
    error_result,
    emit_event,
    emit_shell_output_lines,
    emit=None,
):
    backup_result = run_shell_command(
        bootstrap_session.host,
        (
            "set -eu; "
            f'BACKUP_DIR="$(dirname "{server_paths.SETUP_SSHD_BACKUP_PREFIX}x")"; '
            'mkdir -p "${BACKUP_DIR}"; chmod 700 "${BACKUP_DIR}"; '
            f'BACKUP_PATH="{server_paths.SETUP_SSHD_BACKUP_PREFIX}$(date +%s)-$$.bak"; '
            f'DROPIN_PATH="{server_paths.SSHD_DROPIN_FILE}"; '
            'DROPIN_BACKUP_PATH="${BACKUP_PATH}.deploydash-dropin"; '
            "DROPIN_PRESENT=0; "
            'cp /etc/ssh/sshd_config "${BACKUP_PATH}"; '
            'if [ -f "${DROPIN_PATH}" ]; then '
            'cp "${DROPIN_PATH}" "${DROPIN_BACKUP_PATH}"; DROPIN_PRESENT=1; fi; '
            'printf "backup_path=%s\\n" "${BACKUP_PATH}"; '
            'printf "dropin_backup_path=%s\\n" "${DROPIN_BACKUP_PATH}"; '
            'printf "dropin_present=%s\\n" "${DROPIN_PRESENT}"'
        ),
        timeout=20,
        sudo=True,
        emit_output=lambda output: emit_shell_output_lines(emit, output),
    )
    if not backup_result["ok"]:
        return {
            "ok": False,
            "error": error_result(
                "ENGINE_RUNTIME_ERROR",
                "Unable to back up SSH daemon configuration before hardening.",
                stage="prepare_runtime_operation",
                details=backup_result["details"],
            ),
        }

    backup_values = shell_output.parse_key_values(backup_result["output"])
    backup_path = backup_values.get("backup_path")
    dropin_backup_path = backup_values.get("dropin_backup_path")
    dropin_present = backup_values.get("dropin_present") == "1"
    # Announced, not just held in a local. If this process dies between here
    # and the restore, the path is the only way anyone finds the backup, and
    # nothing else records it. G-2.
    emit_event(
        emit,
        "setup_sshd_backup_captured",
        f"SSH daemon configuration backed up to {backup_path}.",
    )
    dropin_restore_command = (
        f"cp {shlex.quote(dropin_backup_path or '')} {server_paths.SSHD_DROPIN_FILE}; "
        if dropin_present
        else f"rm -f {server_paths.SSHD_DROPIN_FILE}; "
    )
    apply_steps = []
    if disable_root_login:
        apply_steps.append(
            ("Disable SSH root login", (("PermitRootLogin", "no"),)),
        )
    if disable_password_auth:
        apply_steps.append(
            (
                "Disable SSH password authentication",
                (
                    ("PasswordAuthentication", "no"),
                    ("KbdInteractiveAuthentication", "no"),
                ),
            ),
        )
    if target_port != bootstrap_connection["port"]:
        apply_steps.append(
            ("Update SSH port", (("Port", str(target_port)),)),
        )

    for label, options in apply_steps:
        emit_event(emit, "setup_postflight_action_started", f"{label}: started")
        try:
            apply_result = run_shell_command(
                bootstrap_session.host,
                set_sshd_options_command(options),
                timeout=30,
                sudo=True,
                emit_output=lambda output: emit_shell_output_lines(emit, output),
            )
        except Exception:
            apply_result = {
                "ok": False,
                "details": "SSH hardening command did not return a result.",
            }
        if not apply_result["ok"]:
            rollback_result = _restore_sshd_configuration(
                bootstrap_session.host,
                backup_path=backup_path,
                dropin_restore_command=dropin_restore_command,
                bootstrap_port=bootstrap_connection["port"],
                emit_shell_output_lines=emit_shell_output_lines,
                emit=emit,
            )
            if not rollback_result["ok"]:
                return _sshd_rollback_failed_result(
                    error_result,
                    message=(
                        f"{label} failed, and restoring the previous SSH configuration "
                        "also failed. This server may now refuse the connections it "
                        "accepted before."
                    ),
                    stage="execute_runtime_operation",
                    details=rollback_result["details"],
                    backup_path=backup_path,
                    dropin_backup_path=dropin_backup_path,
                    dropin_present=dropin_present,
                )
            return {
                "ok": False,
                "error": error_result(
                    "ENGINE_RUNTIME_ERROR",
                    f"{label} failed, so SSH settings were restored.",
                    stage="execute_runtime_operation",
                    details=apply_result["details"],
                    extra={"rollback_performed": True},
                ),
            }

        verify_result = verify_connection(
            {
                **managed_connection,
                "port": target_port,
            },
            emit=emit,
        )
        if not verify_result["ok"]:
            rollback_result = _restore_sshd_configuration(
                bootstrap_session.host,
                backup_path=backup_path,
                dropin_restore_command=dropin_restore_command,
                bootstrap_port=bootstrap_connection["port"],
                emit_shell_output_lines=emit_shell_output_lines,
                emit=emit,
            )
            if not rollback_result["ok"]:
                # G-1. The restore is the last line of defence against a
                # lockout, and it failed. Reporting this with the same code as
                # an ordinary setup failure buries the one outcome the whole
                # sequence exists to prevent, so it gets its own code, names
                # the backup path the operator needs, and says plainly what
                # state the machine is in.
                return _sshd_rollback_failed_result(
                    error_result,
                    message=(
                        f"{label} was applied, the managed ubuntu connection could "
                        "not be verified, and restoring the previous SSH configuration "
                        "also failed. This server may now refuse the connections it "
                        "accepted before."
                    ),
                    stage="verify_runtime_operation",
                    details=rollback_result["details"],
                    backup_path=backup_path,
                    dropin_backup_path=dropin_backup_path,
                    dropin_present=dropin_present,
                )
            return {
                "ok": False,
                "error": error_result(
                    "ENGINE_RUNTIME_ERROR",
                    (
                        f"{label} was applied but Deploy Dash could not verify the "
                        "managed ubuntu connection, so SSH settings were restored."
                    ),
                    stage="verify_runtime_operation",
                    details=verify_result["error"].get("msg"),
                    extra={"rollback_performed": True},
                ),
            }

        emit_event(
            emit,
            "setup_postflight_action_completed",
            f"{label}: completed",
        )

    # Hardening succeeded and every step verified, so the backup has nothing
    # left to protect. Removing it stops one file accumulating per onboarding
    # under STATE_ROOT. Failure to clean up is not a setup failure. G-2.
    run_shell_command(
        bootstrap_session.host,
        f"rm -f {shlex.quote(backup_path or '')} {shlex.quote(dropin_backup_path or '')}",
        timeout=15,
        sudo=True,
        emit_output=lambda output: emit_shell_output_lines(emit, output),
    )
    return {
        "ok": True,
        "managed_port": target_port,
    }


def _is_retryable_verify_error(error):
    """Whether a failed firewall verify deserves another connection attempt.

    Only connection-level failures (stage "connect") are retried: a host-key
    mismatch is a definitive answer, and a failed verification command means
    sudo is broken rather than the network flapping. Both must fall through
    to rollback immediately.
    """

    if not isinstance(error, dict):
        return False
    if error.get("stage") != "connect":
        return False
    extra = error.get("extra")
    return not (isinstance(extra, dict) and extra.get("host_key_confirmation_required"))


def _verify_staged_connection_with_retries(
    connection,
    *,
    verify_connection,
    error_result,
    emit_event,
    emit=None,
    is_cancelled=None,
):
    """Verify the managed connection after staging, riding out flap windows.

    Rewriting live firewall rules can briefly blackhole even allowed traffic
    (chain surgery, conntrack re-resolution), so a single fast verify after
    staging turns a transient into a failed setup plus rollback. Retry
    connect-stage failures with backoff; anything else fails fast.
    """

    last_result = None
    for attempt in range(1, _FIREWALL_VERIFY_ATTEMPTS + 1):
        if callable(is_cancelled) and is_cancelled():
            return {
                "ok": False,
                "error": error_result(
                    "ENGINE_TASK_CANCELLED",
                    "Task cancelled during firewall verification.",
                    stage="verify_runtime_operation",
                ),
            }
        if attempt > 1:
            emit_event(
                emit,
                "firewall_verify_retry",
                (
                    "Managed connection verification retrying "
                    f"(attempt {attempt}/{_FIREWALL_VERIFY_ATTEMPTS})."
                ),
                level="warning",
            )
        last_result = verify_connection(connection, emit=emit)
        if last_result.get("ok"):
            return last_result
        if not _is_retryable_verify_error(last_result.get("error")):
            return last_result
        if attempt < _FIREWALL_VERIFY_ATTEMPTS:
            delay_index = min(attempt - 1, len(_FIREWALL_VERIFY_RETRY_DELAYS) - 1)
            time.sleep(_FIREWALL_VERIFY_RETRY_DELAYS[delay_index])
    return last_result


def apply_onboarding_firewall_baseline(
    connection,
    *,
    verify_connection,
    open_runtime_session,
    error_result,
    emit_event,
    emit_shell_output_lines,
    emit=None,
    is_cancelled=None,
):
    # engine_firewall_ops's staging functions below only ever use these four
    # fields (never open_runtime_session -- this function opens its own
    # sessions directly, see below); the other seven EngineContext fields
    # raise NotImplementedError if called, which would be a genuine bug here.
    firewall_ctx = build_partial_context(
        error_result=error_result,
        emit_event=emit_event,
        emit_shell_output_lines=emit_shell_output_lines,
        command_error_details=lambda output: (
            None
            if output is None
            else "\n".join(getattr(output, "stderr_lines", []) or [])
            or "\n".join(getattr(output, "stdout_lines", []) or [])
            or "remote command failed"
        ),
    )
    opened = open_runtime_session(
        ip=connection["ip"],
        username=connection["username"],
        password=connection.get("password"),
        key_filename=connection.get("private_key") or connection.get("key_path"),
        port=connection.get("port", 22),
        needs_sudo=True,
        emit=emit,
    )
    if not opened["ok"]:
        return opened

    stage_session = opened["session"]
    try:
        config = build_onboarding_firewall_config(connection.get("port", 22))
        stage_result = engine_firewall_ops._apply_staged_firewall(
            firewall_ctx,
            stage_session.host,
            config,
            emit=emit,
            active_ssh_port=connection.get("port", 22),
        )
    finally:
        _close_runtime_session(
            stage_session,
            emit_event=emit_event,
            emit=emit,
        )

    if stage_result.get("status") != "success":
        return {"ok": False, "error": stage_result}

    staged_token = stage_result.get("staged_state", {}).get("token")
    verify_result = _verify_staged_connection_with_retries(
        connection,
        verify_connection=verify_connection,
        error_result=error_result,
        emit_event=emit_event,
        emit=emit,
        is_cancelled=is_cancelled,
    )
    if not verify_result["ok"]:
        rollback_performed = False
        rollback_result = {}
        rollback_opened = open_runtime_session(
            ip=connection["ip"],
            username=connection["username"],
            password=connection.get("password"),
            key_filename=connection.get("private_key") or connection.get("key_path"),
            port=connection.get("port", 22),
            needs_sudo=True,
            emit=emit,
        )
        if rollback_opened["ok"]:
            rollback_session = rollback_opened["session"]
            try:
                rollback_result = engine_firewall_ops._rollback_staged_firewall(
                    firewall_ctx,
                    rollback_session.host,
                    staged_token,
                    emit=emit,
                )
                rollback_performed = rollback_result.get("status") == "success"
            finally:
                _close_runtime_session(
                    rollback_session,
                    emit_event=emit_event,
                    emit=emit,
                )
        firewall_state = rollback_result.get("firewall_state")
        message = (
            "Firewall baseline was staged but the managed connection "
            "could not be verified, so the firewall change was rolled back."
        )
        if firewall_state == "unprotected":
            message += (
                " Deploy Dash replaced active ufw, so this server currently has no "
                "active firewall. Retry server setup immediately."
            )
        extra = {"rollback_performed": rollback_performed}
        if firewall_state is not None:
            extra["firewall_state"] = firewall_state
        return {
            "ok": False,
            "error": error_result(
                "ENGINE_RUNTIME_ERROR",
                message,
                stage="verify_runtime_operation",
                details=verify_result["error"].get("msg"),
                extra=extra,
            ),
        }

    commit_opened = open_runtime_session(
        ip=connection["ip"],
        username=connection["username"],
        password=connection.get("password"),
        key_filename=connection.get("private_key") or connection.get("key_path"),
        port=connection.get("port", 22),
        needs_sudo=True,
        emit=emit,
    )
    if not commit_opened["ok"]:
        return commit_opened

    commit_session = commit_opened["session"]
    try:
        commit_result = engine_firewall_ops._commit_staged_firewall(
            firewall_ctx,
            commit_session.host,
            staged_token,
            emit=emit,
        )
        if commit_result.get("status") != "success":
            return {"ok": False, "error": commit_result}
        return {"ok": True}
    finally:
        _close_runtime_session(
            commit_session,
            emit_event=emit_event,
            emit=emit,
        )
