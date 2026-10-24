# ruff: noqa: F403, F405

import time

from .. import apt_runtime, engine_firewall_ops
from ..setup_postflight import render_sshd_restart_command
from ..shell_output import parse_bool_token
from ..swap_management import render_swap_reconcile_command, swap_size_changed
from ._shared import *

# The backup copies the drop-in into a directory keyed by its own basename,
# so the name is derived from the path rather than restated beside it.
_SSHD_DROPIN_BASENAME = server_paths.SSHD_DROPIN_FILE.rsplit("/", 1)[-1]
_ROOT_LOGIN_MODE_TO_SSHD_VALUE = {
    "disabled": "no",
    "key_only": "prohibit-password",
    "password_allowed": "yes",
    "restricted": "forced-commands-only",
}
_REBOOT_POLL_ATTEMPTS = 60
_REBOOT_POLL_INTERVAL_SECONDS = 5.0
_REBOOT_HEALTH_ATTEMPTS = 12
_REBOOT_HEALTH_POLL_INTERVAL_SECONDS = 5.0
_REBOOT_HEALTH_LABELS = {
    "docker_active": "Docker service is active",
    "managed_containers_running": "Managed containers are running",
    "firewall_ipv4_present": "IPv4 firewall chain is present",
    "firewall_ipv6_present": "IPv6 firewall chain is present",
    "swap_active": "Configured swap is active",
    "ssh_listening": "SSH is listening on the configured port",
    "reboot_required_cleared": "Restart requirement was cleared",
}


def _normalize_time_hhmm(value, default="03:00"):
    if not isinstance(value, str):
        return default
    candidate = value.strip()
    if len(candidate) != 5 or ":" not in candidate:
        return default
    hour_raw, minute_raw = candidate.split(":", 1)
    if not hour_raw.isdigit() or not minute_raw.isdigit():
        return default
    hour = int(hour_raw)
    minute = int(minute_raw)
    if hour < 0 or hour > 23 or minute < 0 or minute > 59:
        return default
    return f"{hour:02d}:{minute:02d}"


def _safe_int(raw, fallback):
    parsed = _parse_positive_int(raw)
    if parsed is None:
        return fallback
    return parsed


def _safe_float(raw, fallback):
    try:
        if isinstance(raw, (int, float)):
            return float(raw)
        if isinstance(raw, str):
            return float(raw.strip())
    except (TypeError, ValueError):
        return fallback
    return fallback


def _root_login_mode_from_sshd(raw_value):
    """Preserve sshd's access semantics instead of collapsing them to a boolean."""
    normalized = str(raw_value or "").strip().lower()
    if normalized in ("", "no", "false", "0"):
        return "disabled"
    if normalized in ("prohibit-password", "without-password"):
        return "key_only"
    if normalized in ("yes", "true", "1"):
        return "password_allowed"
    return "restricted"


def _reboot_status_from_parsed(parsed):
    """Keep absent or unreadable package evidence explicit without hiding the reboot."""
    reboot_required = parse_bool_token(parsed.get("reboot_required"), False)
    packages_readable = parse_bool_token(
        parsed.get("reboot_required_packages_readable"),
        True,
    )
    packages = []
    if reboot_required and packages_readable:
        packages = [
            package.strip()
            for package in parsed.get("reboot_required_packages", "").split(",")
            if package.strip()
        ]
    since = _parse_positive_int(parsed.get("reboot_required_since"))
    if since is not None and since <= 0:
        since = None
    return {
        "reboot_required": reboot_required,
        "reboot_required_packages": packages,
        "reboot_required_packages_readable": packages_readable,
        "reboot_required_since": since,
    }


def _read_server_system_status(ctx, session, emit=None):
    command = (
        "set -eu; "
        "ROOT_RAW=\"$(sshd -T 2>/dev/null | awk '/^permitrootlogin / {print $2; exit}' || true)\"; "
        "PASS_RAW=\"$(sshd -T 2>/dev/null | awk '/^passwordauthentication / {print $2; exit}' || true)\"; "
        "KBD_RAW=\"$(sshd -T 2>/dev/null | awk '/^kbdinteractiveauthentication / {print $2; exit}' || true)\"; "
        "PORT_RAW=\"$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)\"; "
        'TZ_RAW="$(timedatectl show -p Timezone --value 2>/dev/null || true)"; '
        'if [ -z "$TZ_RAW" ] && [ -f /etc/timezone ]; then TZ_RAW="$(cat /etc/timezone 2>/dev/null || true)"; fi; '
        'SWAP_BYTES="$(swapon --noheadings --bytes --show=SIZE,NAME 2>/dev/null | awk \'$2=="/swapfile" {print $1; exit}\' || true)"; '
        'if [ -z "$SWAP_BYTES" ]; then SWAP_BYTES=0; fi; '
        'AUTO_UPDATES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"; '
        'AUTO_FILE="/etc/apt/apt.conf.d/52unattended-upgrades-local"; '
        'AUTO_UPDATES_RAW=""; '
        'AUTO_REBOOT_RAW=""; '
        'AUTO_REBOOT_TIME_RAW=""; '
        'if [ -f "$AUTO_UPDATES_FILE" ]; then '
        'AUTO_UPDATES_RAW="$(awk -F\'"\' \'/Unattended-Upgrade/ {print $2; exit}\' "$AUTO_UPDATES_FILE" 2>/dev/null || true)"; '
        "fi; "
        'if [ -f "$AUTO_FILE" ]; then '
        'AUTO_REBOOT_RAW="$(awk -F\'"\' \'/Automatic-Reboot/ {print $2; exit}\' "$AUTO_FILE" 2>/dev/null || true)"; '
        'AUTO_REBOOT_TIME_RAW="$(awk -F\'"\' \'/Automatic-Reboot-Time/ {print $2; exit}\' "$AUTO_FILE" 2>/dev/null || true)"; '
        "fi; "
        'REBOOT_REQUIRED=false; REBOOT_REQUIRED_PACKAGES=""; '
        "REBOOT_REQUIRED_PACKAGES_READABLE=true; REBOOT_REQUIRED_SINCE=0; "
        "if [ -e /var/run/reboot-required ]; then "
        "REBOOT_REQUIRED=true; "
        'REBOOT_REQUIRED_SINCE="$(stat -c %Y /var/run/reboot-required 2>/dev/null || true)"; '
        "if [ -e /var/run/reboot-required.pkgs ]; then "
        "if [ -r /var/run/reboot-required.pkgs ]; then "
        'REBOOT_REQUIRED_PACKAGES="$(tr "\\n" "," < /var/run/reboot-required.pkgs | sed "s/,$//")"; '
        "else REBOOT_REQUIRED_PACKAGES_READABLE=false; fi; "
        "fi; fi; "
        "printf 'root_raw=%s\\n' \"$ROOT_RAW\"; "
        "printf 'password_raw=%s\\n' \"$PASS_RAW\"; "
        "printf 'keyboard_interactive_raw=%s\\n' \"$KBD_RAW\"; "
        "printf 'ssh_port=%s\\n' \"$PORT_RAW\"; "
        "printf 'timezone=%s\\n' \"$TZ_RAW\"; "
        "printf 'swap_bytes=%s\\n' \"$SWAP_BYTES\"; "
        "printf 'auto_updates_raw=%s\\n' \"$AUTO_UPDATES_RAW\"; "
        "printf 'auto_reboot_raw=%s\\n' \"$AUTO_REBOOT_RAW\"; "
        "printf 'maintenance_time_raw=%s\\n' \"$AUTO_REBOOT_TIME_RAW\"; "
        "printf 'reboot_required=%s\\n' \"$REBOOT_REQUIRED\"; "
        "printf 'reboot_required_packages=%s\\n' \"$REBOOT_REQUIRED_PACKAGES\"; "
        "printf 'reboot_required_packages_readable=%s\\n' \"$REBOOT_REQUIRED_PACKAGES_READABLE\"; "
        "printf 'reboot_required_since=%s\\n' \"$REBOOT_REQUIRED_SINCE\"; "
    )
    status, output = session.host.run_shell_command(
        command,
        _timeout=20,
        _sudo=True,
    )
    ctx.emit_shell_output_lines(emit, output)
    if not status:
        return {
            "ok": False,
            "error": ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Failed to read system settings from remote host.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(output) or "remote command failed",
            ),
        }

    parsed = shell_output.parse_key_values(output)
    root_raw = parsed.get("root_raw", "").strip().lower()
    password_raw = parsed.get("password_raw", "").strip().lower()
    keyboard_interactive_raw = parsed.get("keyboard_interactive_raw", "").strip().lower()
    root_login_mode = _root_login_mode_from_sshd(root_raw)
    root_login_enabled = root_login_mode != "disabled"
    password_auth_enabled = password_raw in ("yes", "true", "1") or (
        keyboard_interactive_raw in ("yes", "true", "1")
    )
    ssh_port = _safe_int(parsed.get("ssh_port"), 22)
    timezone = parsed.get("timezone", "").strip() or "UTC"
    swap_bytes = _safe_int(parsed.get("swap_bytes"), 0)
    automatic_security_updates_enabled = parse_bool_token(
        parsed.get("auto_updates_raw"),
        True,
    )
    auto_reboot_enabled = parse_bool_token(parsed.get("auto_reboot_raw"), False)
    maintenance_time = _normalize_time_hhmm(parsed.get("maintenance_time_raw"))
    swap_gb = round(float(swap_bytes) / float(1024**3), 1)
    reboot_status = _reboot_status_from_parsed(parsed)

    return {
        "ok": True,
        "settings": {
            "root_login_mode": root_login_mode,
            "root_login_enabled": root_login_enabled,
            "password_auth_enabled": password_auth_enabled,
            "ssh_port": ssh_port,
            "timezone": timezone,
            "swap_gb": swap_gb,
            "automatic_security_updates_enabled": (automatic_security_updates_enabled),
            "auto_reboot_enabled": auto_reboot_enabled,
            "maintenance_time": maintenance_time,
            **reboot_status,
        },
    }


def _post_reboot_health_command(port, managed_container_ids):
    """Prove recovery against the managed-container inventory captured before reboot."""
    quoted_container_ids = " ".join(
        shlex.quote(container_id) for container_id in managed_container_ids
    )
    return (
        "set -u; "
        f"SSH_PORT={int(port)}; "
        "DOCKER_ACTIVE=false; "
        "if systemctl is-active --quiet docker; then DOCKER_ACTIVE=true; fi; "
        "MANAGED_CONTAINERS_RUNNING=true; "
        f"for MANAGED_CONTAINER_ID in {quoted_container_ids}; do "
        "if [ \"$(docker inspect --format '{{.State.Running}}' "
        '"$MANAGED_CONTAINER_ID" 2>/dev/null)" != "true" ]; then '
        "MANAGED_CONTAINERS_RUNNING=false; fi; "
        "done; "
        "FIREWALL_IPV4_PRESENT=false; "
        "if iptables -w 5 -n -L DEPLOYDASH-INPUT >/dev/null 2>&1; then "
        "FIREWALL_IPV4_PRESENT=true; fi; "
        "FIREWALL_IPV6_PRESENT=false; "
        "if ip6tables -w 5 -n -L DEPLOYDASH6-INPUT >/dev/null 2>&1; then "
        "FIREWALL_IPV6_PRESENT=true; fi; "
        "SWAP_ACTIVE=true; "
        "if grep -Eq '^/swapfile[[:space:]]' /etc/fstab; then "
        "SWAP_ACTIVE=false; "
        "if swapon --noheadings --show=NAME | grep -qx /swapfile; then SWAP_ACTIVE=true; fi; "
        "fi; "
        "SSH_LISTENING=false; "
        'if ss -H -ltn "sport = :${SSH_PORT}" | grep -q .; then SSH_LISTENING=true; fi; '
        "REBOOT_REQUIRED_CLEARED=false; "
        "if [ ! -e /var/run/reboot-required ]; then REBOOT_REQUIRED_CLEARED=true; fi; "
        "printf 'docker_active=%s\\n' \"$DOCKER_ACTIVE\"; "
        "printf 'managed_containers_running=%s\\n' \"$MANAGED_CONTAINERS_RUNNING\"; "
        "printf 'firewall_ipv4_present=%s\\n' \"$FIREWALL_IPV4_PRESENT\"; "
        "printf 'firewall_ipv6_present=%s\\n' \"$FIREWALL_IPV6_PRESENT\"; "
        "printf 'swap_active=%s\\n' \"$SWAP_ACTIVE\"; "
        "printf 'ssh_listening=%s\\n' \"$SSH_LISTENING\"; "
        "printf 'reboot_required_cleared=%s\\n' \"$REBOOT_REQUIRED_CLEARED\""
    )


def _normalize_requested_system_settings(settings):
    payload = settings if isinstance(settings, dict) else {}
    if "root_login_mode" in payload:
        root_login_mode_raw = payload.get("root_login_mode")
        root_login_mode = (
            root_login_mode_raw.strip().lower()
            if isinstance(root_login_mode_raw, str)
            else root_login_mode_raw
        )
    else:
        # Legacy booleans could mean either key-only or password access. Bias
        # to key-only so an older caller can never silently widen root access.
        root_login_mode = (
            "key_only" if parse_bool_token(payload.get("root_login_enabled"), False) else "disabled"
        )
    timezone = _normalized_optional_string(payload.get("timezone")) or "UTC"
    ssh_port = _safe_int(payload.get("ssh_port"), 22)
    swap_gb = (
        _safe_float(payload.get("swap_gb"), payload.get("swap_gb"))
        if "swap_gb" in payload
        else None
    )
    maintenance_time = _normalize_time_hhmm(
        payload.get("maintenance_time"),
        default="03:00",
    )
    return {
        "root_login_mode": root_login_mode,
        "root_login_enabled": root_login_mode != "disabled",
        "password_auth_enabled": parse_bool_token(
            payload.get("password_auth_enabled"),
            False,
        ),
        "ssh_port": ssh_port,
        "timezone": timezone,
        "swap_gb": swap_gb,
        "automatic_security_updates_enabled": parse_bool_token(
            payload.get("automatic_security_updates_enabled"),
            True,
        ),
        "auto_reboot_enabled": parse_bool_token(
            payload.get("auto_reboot_enabled"),
            False,
        ),
        "maintenance_time": maintenance_time,
    }


def _validate_system_settings(ctx, settings):
    if settings.get("root_login_mode") not in _ROOT_LOGIN_MODE_TO_SSHD_VALUE:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Root login mode must be disabled, key_only, password_allowed, or restricted.",
            stage="validate_request",
        )

    ssh_port = settings.get("ssh_port")
    if not isinstance(ssh_port, int) or ssh_port < 1 or ssh_port > 65535:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "SSH port must be between 1 and 65535.",
            stage="validate_request",
        )

    timezone = settings.get("timezone")
    if not isinstance(timezone, str) or not timezone.strip():
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Timezone is required.",
            stage="validate_request",
        )

    swap_gb = settings.get("swap_gb")
    if swap_gb is not None and (
        not isinstance(swap_gb, (int, float)) or swap_gb < 0 or swap_gb > 64
    ):
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Swap size must be between 0 and 64 GB.",
            stage="validate_request",
        )

    maintenance_time = settings.get("maintenance_time")
    if (
        not isinstance(maintenance_time, str)
        or _normalize_time_hhmm(maintenance_time, default="") == ""
    ):
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Maintenance time must be formatted as HH:MM (24-hour).",
            stage="validate_request",
        )
    return None


def _has_authorized_key(ctx, session, username, emit=None):
    command = (
        "set -eu; "
        f"DEPLOYDASH_USER={shlex.quote(username)}; "
        'if [ "$DEPLOYDASH_USER" = "root" ]; then TARGET_HOME="/root"; '
        'else TARGET_HOME="$(getent passwd "$DEPLOYDASH_USER" | cut -d: -f6 || true)"; fi; '
        'if [ -z "${TARGET_HOME:-}" ]; then exit 1; fi; '
        'test -s "$TARGET_HOME/.ssh/authorized_keys"; '
    )
    status, output = session.host.run_shell_command(
        command,
        _timeout=10,
        _sudo=True,
    )
    ctx.emit_shell_output_lines(emit, output)
    return bool(status)


def _run_server_system_apply_commands(
    ctx,
    session,
    settings,
    original_settings,
    emit=None,
):
    permit_root_value = _ROOT_LOGIN_MODE_TO_SSHD_VALUE[settings["root_login_mode"]]
    password_auth_value = "yes" if settings["password_auth_enabled"] else "no"
    ssh_port_value = str(settings["ssh_port"])
    timezone_value = shlex.quote(settings["timezone"])
    auto_reboot_value = "true" if settings["auto_reboot_enabled"] else "false"
    auto_updates_value = "1" if settings["automatic_security_updates_enabled"] else "0"
    maintenance_value = settings["maintenance_time"]
    swap_changed = False

    def failed(details, backup_dir):
        """Tell rollback whether this apply actually replaced the active swap file."""
        return {
            "ok": False,
            "details": details,
            "backup_dir": backup_dir,
            "swap_changed": swap_changed,
        }

    updates_tooling_result = run_shell_command(
        session.host,
        (
            "set -eu; "
            "if ! dpkg -s unattended-upgrades apt-listchanges >/dev/null 2>&1; then "
            f"{apt_runtime.apt_get_command('update -y')}; "
            f"{apt_runtime.apt_get_command('install -y unattended-upgrades apt-listchanges')}; "
            "fi; "
            "systemctl enable --now apt-daily.timer; "
            "systemctl enable --now apt-daily-upgrade.timer"
        ),
        timeout=720,
        sudo=True,
        emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
    )
    if not updates_tooling_result["ok"]:
        return failed(updates_tooling_result["details"], None)

    backup_command = (
        "set -eu; "
        f'BACKUP_DIR="{server_paths.SYSTEM_BACKUP_TEMP_PREFIX}$(date +%s)-$$"; '
        'mkdir -p "$BACKUP_DIR"; '
        'cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config"; '
        f"if [ -f {server_paths.SSHD_DROPIN_FILE} ]; then "
        f"cp {server_paths.SSHD_DROPIN_FILE} "
        f'"$BACKUP_DIR/{_SSHD_DROPIN_BASENAME}"; '
        f'else touch "$BACKUP_DIR/{_SSHD_DROPIN_BASENAME}.absent"; fi; '
        "if [ -f /etc/apt/apt.conf.d/20auto-upgrades ]; then "
        'cp /etc/apt/apt.conf.d/20auto-upgrades "$BACKUP_DIR/auto_updates"; '
        'else touch "$BACKUP_DIR/auto_updates.absent"; fi; '
        "if [ -f /etc/apt/apt.conf.d/52unattended-upgrades-local ]; then "
        'cp /etc/apt/apt.conf.d/52unattended-upgrades-local "$BACKUP_DIR/auto_reboot"; '
        'else touch "$BACKUP_DIR/auto_reboot.absent"; fi; '
        "printf 'backup_dir=%s\\n' \"$BACKUP_DIR\"; "
    )
    backup_result = run_shell_command(
        session.host,
        backup_command,
        timeout=30,
        sudo=True,
        emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
    )
    if not backup_result["ok"]:
        return failed(backup_result["details"], None)
    parsed = shell_output.parse_key_values(backup_result["output"])
    backup_dir = parsed.get("backup_dir")

    sshd_command = set_sshd_options_command(
        (
            ("PermitRootLogin", permit_root_value),
            ("PasswordAuthentication", password_auth_value),
            ("KbdInteractiveAuthentication", "no"),
            ("Port", ssh_port_value),
        ),
        restart=False,
    )
    sshd_result = run_shell_command(
        session.host,
        sshd_command,
        timeout=30,
        sudo=True,
        emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
    )
    if not sshd_result["ok"]:
        return failed(sshd_result["details"], backup_dir)

    timezone_result = run_shell_command(
        session.host,
        f"timedatectl set-timezone {timezone_value}; ",
        timeout=30,
        sudo=True,
        emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
    )
    if not timezone_result["ok"]:
        return failed(timezone_result["details"], backup_dir)

    if swap_size_changed(original_settings["swap_gb"], settings["swap_gb"]):
        swap_result = run_shell_command(
            session.host,
            render_swap_reconcile_command(settings["swap_gb"]),
            timeout=120,
            sudo=True,
            emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
        )
        if not swap_result["ok"]:
            return failed(swap_result["details"], backup_dir)
        swap_changed = True

    unattended_content = (
        f'APT::Periodic::Update-Package-Lists "{auto_updates_value}";\n'
        f'APT::Periodic::Unattended-Upgrade "{auto_updates_value}";\n'
        'APT::Periodic::AutocleanInterval "7";\n'
    )
    auto_updates_result = write_remote_text_file(
        session.host,
        path="/etc/apt/apt.conf.d/20auto-upgrades",
        content=unattended_content,
        mode="644",
        timeout=45,
        sudo=True,
        emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
    )
    if not auto_updates_result["ok"]:
        return failed(auto_updates_result["details"], backup_dir)

    unattended_local_content = (
        f'Unattended-Upgrade::Automatic-Reboot "{auto_reboot_value}";\n'
        f'Unattended-Upgrade::Automatic-Reboot-Time "{maintenance_value}";\n'
        'Unattended-Upgrade::Automatic-Reboot-WithUsers "true";\n'
    )
    unattended_result = write_remote_text_file(
        session.host,
        path="/etc/apt/apt.conf.d/52unattended-upgrades-local",
        content=unattended_local_content,
        mode="644",
        timeout=45,
        sudo=True,
        emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
    )
    if not unattended_result["ok"]:
        return failed(unattended_result["details"], backup_dir)

    restart_result = run_shell_command(
        session.host,
        render_sshd_restart_command(settings["ssh_port"]),
        timeout=45,
        sudo=True,
        emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
    )
    if not restart_result["ok"]:
        return failed(restart_result["details"], backup_dir)

    return {
        "ok": True,
        "details": None,
        "backup_dir": backup_dir,
        "swap_changed": swap_changed,
    }


def _run_server_system_rollback_commands(
    ctx,
    session,
    backup_dir,
    original_settings,
    restore_swap=False,
    emit=None,
):
    """Restore exact backed-up config files so rollback cannot widen SSH access."""
    if not backup_dir:
        return {"ok": False, "details": "system settings backup path is missing"}

    restore_dir = shlex.quote(backup_dir)
    restore_command = (
        "set -eu; "
        f"RESTORE_DIR={restore_dir}; "
        'test -f "$RESTORE_DIR/sshd_config"; '
        'cp "$RESTORE_DIR/sshd_config" /etc/ssh/sshd_config; '
        f'if [ -f "$RESTORE_DIR/{_SSHD_DROPIN_BASENAME}.absent" ]; then '
        f"rm -f {server_paths.SSHD_DROPIN_FILE}; "
        f'else cp "$RESTORE_DIR/{_SSHD_DROPIN_BASENAME}" '
        f"{server_paths.SSHD_DROPIN_FILE}; fi; "
        'if [ -f "$RESTORE_DIR/auto_updates.absent" ]; then '
        "rm -f /etc/apt/apt.conf.d/20auto-upgrades; "
        'else cp "$RESTORE_DIR/auto_updates" '
        "/etc/apt/apt.conf.d/20auto-upgrades; fi; "
        'if [ -f "$RESTORE_DIR/auto_reboot.absent" ]; then '
        "rm -f /etc/apt/apt.conf.d/52unattended-upgrades-local; "
        'else cp "$RESTORE_DIR/auto_reboot" '
        "/etc/apt/apt.conf.d/52unattended-upgrades-local; fi; "
        f"sshd -t; {render_sshd_restart_command(original_settings['ssh_port'])}"
    )
    restore_result = run_shell_command(
        session.host,
        restore_command,
        timeout=45,
        sudo=True,
        emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
    )
    if not restore_result["ok"]:
        return {"ok": False, "details": restore_result["details"]}

    timezone_result = run_shell_command(
        session.host,
        f"timedatectl set-timezone {shlex.quote(original_settings['timezone'])}; ",
        timeout=30,
        sudo=True,
        emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
    )
    if not timezone_result["ok"]:
        return {"ok": False, "details": timezone_result["details"]}

    if restore_swap:
        swap_result = run_shell_command(
            session.host,
            render_swap_reconcile_command(original_settings["swap_gb"]),
            timeout=120,
            sudo=True,
            emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
        )
        if not swap_result["ok"]:
            return {"ok": False, "details": swap_result["details"]}
    return {"ok": True, "details": None}


def _rollback_system_apply(
    ctx,
    session,
    apply_result,
    original_settings,
    firewall_stage,
    emit=None,
):
    """Restore SSH settings before closing the temporary dual-port firewall stage."""
    system_result = _run_server_system_rollback_commands(
        ctx,
        session,
        apply_result["backup_dir"],
        original_settings,
        restore_swap=apply_result["swap_changed"],
        emit=emit,
    )
    firewall_result = {"status": "success"}
    stage_token = firewall_stage.get("stage_token")
    if stage_token:
        firewall_result = engine_firewall_ops._rollback_staged_firewall(
            ctx,
            session.host,
            stage_token,
            emit=emit,
        )
    return system_result["ok"] and firewall_result.get("status") == "success"


def run_server_system_status_operation(
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
            "msg": "Server system status plan ready",
            "operation_id": "system_status",
            "actions": [
                "Read effective sshd settings",
                "Read timezone and swap configuration",
                "Read automatic security update settings",
                "Read unattended-upgrades maintenance settings",
                "Read whether installed updates require a restart",
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
            "server_system_status_started",
            "Collecting server system settings.",
        )
        status_result = _read_server_system_status(ctx, session, emit=emit)
        if not status_result["ok"]:
            return status_result["error"]
        return {
            "status": "success",
            "code": "OK",
            "msg": "Server system settings refreshed.",
            "operation_id": "system_status",
            "settings": status_result["settings"],
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


def run_server_system_restart_operation(
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
    """Reboot only with observed downtime, reconnection, and explicit health proof."""
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
            "msg": "Server restart plan ready",
            "operation_id": "system_restart",
            "actions": [
                "Schedule a server restart after a short delay",
                "Wait for SSH to stop and return",
                "Verify managed server health",
            ],
        }

    connection = {
        "ip": ip,
        "username": username,
        "password": password,
        "key_filename": key_filename,
        "port": port,
        "needs_sudo": True,
        "emit": emit,
    }
    opened = ctx.open_runtime_session(**connection)
    if not opened["ok"]:
        return opened["error"]

    session = opened["session"]
    try:
        schedule_result = run_shell_command(
            session.host,
            (
                "set -eu; "
                f'MANAGED_CONTAINER_LINES="$(docker ps -a --filter label={server_identifiers.MANAGED_LABEL_PAIR} '
                "--format '{{.ID}}')\"; "
                'MANAGED_CONTAINER_IDS="$(printf \'%s\\n\' "$MANAGED_CONTAINER_LINES" '
                "| sed '/^$/d' | paste -sd, -)\"; "
                "systemd-run --quiet --collect --unit=deploydash-reboot-$(date +%s) "
                "--on-active=5s systemctl reboot; "
                "printf 'managed_container_ids=%s\\n' \"$MANAGED_CONTAINER_IDS\""
            ),
            timeout=20,
            sudo=True,
            emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
        )
    finally:
        session.close()
    if not schedule_result["ok"]:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Failed to schedule the server restart.",
            stage="execute_runtime_operation",
            details=schedule_result["details"],
        )
    schedule_values = shell_output.parse_key_values(schedule_result["output"])
    managed_container_ids = tuple(
        container_id.strip()
        for container_id in schedule_values.get("managed_container_ids", "").split(",")
        if container_id.strip()
    )

    ctx.emit_event(
        emit,
        "server_system_restart_scheduled",
        "Server restart scheduled; waiting for SSH to stop.",
    )
    observed_down = False
    for _attempt in range(_REBOOT_POLL_ATTEMPTS):
        if callable(is_cancelled) and is_cancelled():
            return ctx.error_result(
                "ENGINE_TASK_CANCELLED",
                "Task cancelled while waiting for the server to restart",
                stage="verify_runtime_operation",
            )
        probe = ctx.open_runtime_session(**connection)
        if not probe["ok"]:
            observed_down = True
            break
        probe["session"].close()
        time.sleep(_REBOOT_POLL_INTERVAL_SECONDS)
    if not observed_down:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "The server did not go offline after the restart was scheduled.",
            stage="verify_runtime_operation",
        )

    ctx.emit_event(
        emit,
        "server_system_restart_offline",
        "Server is offline; waiting for SSH to return.",
    )
    recovered_session = None
    for _attempt in range(_REBOOT_POLL_ATTEMPTS):
        if callable(is_cancelled) and is_cancelled():
            return ctx.error_result(
                "ENGINE_TASK_CANCELLED",
                "Task cancelled while waiting for SSH to return",
                stage="verify_runtime_operation",
            )
        probe = ctx.open_runtime_session(**connection)
        if probe["ok"]:
            recovered_session = probe["session"]
            break
        time.sleep(_REBOOT_POLL_INTERVAL_SECONDS)
    if recovered_session is None:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "SSH did not return after the server restart.",
            stage="verify_runtime_operation",
        )

    health_result = {"ok": False, "details": "post-restart health checks did not run"}
    health_checks = {}
    failed_checks = []
    try:
        for attempt in range(_REBOOT_HEALTH_ATTEMPTS):
            if callable(is_cancelled) and is_cancelled():
                return ctx.error_result(
                    "ENGINE_TASK_CANCELLED",
                    "Task cancelled while waiting for post-restart health",
                    stage="verify_runtime_operation",
                )
            health_result = run_shell_command(
                recovered_session.host,
                _post_reboot_health_command(port, managed_container_ids),
                timeout=45,
                sudo=True,
                emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
            )
            if health_result["ok"]:
                parsed = shell_output.parse_key_values(health_result["output"])
                health_checks = {
                    label: parse_bool_token(parsed.get(check_id), False)
                    for check_id, label in _REBOOT_HEALTH_LABELS.items()
                }
                failed_checks = [label for label, passed in health_checks.items() if not passed]
                if not failed_checks:
                    return {
                        "status": "success",
                        "code": "OK",
                        "msg": "Server restarted and health checks passed.",
                        "operation_id": "system_restart",
                        "health_checks": health_checks,
                    }
            if attempt + 1 < _REBOOT_HEALTH_ATTEMPTS:
                time.sleep(_REBOOT_HEALTH_POLL_INTERVAL_SECONDS)
    finally:
        recovered_session.close()

    if not health_result["ok"]:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "The server returned, but post-restart health checks could not run.",
            stage="verify_runtime_operation",
            details=health_result["details"],
        )

    return ctx.error_result(
        "ENGINE_RUNTIME_ERROR",
        "The server restarted, but one or more health checks failed.",
        stage="verify_runtime_operation",
        details="; ".join(failed_checks),
        extra={
            "health_checks": health_checks,
            "failed_checks": failed_checks,
        },
    )


def run_server_system_apply_operation(
    ctx,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    settings=None,
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

    normalized = _normalize_requested_system_settings(settings)
    validation_error = _validate_system_settings(ctx, normalized)
    if validation_error is not None:
        return validation_error

    if dry_run:
        return {
            "status": "success",
            "code": "OK",
            "msg": "Server system apply plan ready",
            "operation_id": "system_apply",
            "settings": normalized,
            "actions": [
                "Stage the managed firewall for both old and new SSH ports",
                "Apply sshd authentication and port settings",
                "Apply timezone and swap settings",
                "Apply automatic security update settings",
                "Apply unattended-upgrades maintenance settings",
                "Verify SSH connectivity and rollback on failure",
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

    rollback_performed = False
    session = opened["session"]
    try:
        original_result = _read_server_system_status(ctx, session, emit=emit)
        if not original_result["ok"]:
            return original_result["error"]
        original_settings = original_result["settings"]
        if normalized["swap_gb"] is None:
            normalized = {
                **normalized,
                "swap_gb": original_settings["swap_gb"],
            }

        if (
            normalized["root_login_mode"] == "disabled"
            and not normalized["password_auth_enabled"]
            and not _has_authorized_key(ctx, session, username=username, emit=emit)
        ):
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                (
                    "Refusing to disable both root login and password authentication "
                    "without an authorized SSH key for the active user."
                ),
                stage="validate_request",
            )

        ctx.emit_event(
            emit,
            "server_system_apply_started",
            "Applying staged system settings.",
            data={"settings": normalized},
        )

        port_changed = normalized["ssh_port"] != port
        firewall_stage = {
            "status": "success",
            "managed": False,
            "stage_token": None,
        }
        if port_changed:
            firewall_stage = engine_firewall_ops._stage_ssh_port_firewall(
                ctx,
                session.host,
                port,
                normalized["ssh_port"],
                emit=emit,
            )
            if firewall_stage.get("status") != "success":
                return firewall_stage

        apply_result = _run_server_system_apply_commands(
            ctx,
            session,
            normalized,
            original_settings,
            emit=emit,
        )
        if not apply_result["ok"]:
            rollback_performed = _rollback_system_apply(
                ctx,
                session,
                apply_result,
                original_settings,
                firewall_stage,
                emit=emit,
            )
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Failed to apply server system settings.",
                stage="execute_runtime_operation",
                details=apply_result["details"],
                extra={"rollback_performed": rollback_performed},
            )

        verify_opened = ctx.open_runtime_session(
            ip=ip,
            username=username,
            password=password,
            key_filename=key_filename,
            port=normalized["ssh_port"],
            needs_sudo=True,
            emit=emit,
        )
        if not verify_opened["ok"]:
            rollback_performed = _rollback_system_apply(
                ctx,
                session,
                apply_result,
                original_settings,
                firewall_stage,
                emit=emit,
            )
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                (
                    "Applied settings but SSH verification failed on the target "
                    "port. Original settings were restored."
                ),
                stage="verify_runtime_operation",
                details=verify_opened["error"].get("msg"),
                extra={"rollback_performed": rollback_performed},
            )

        verify_session = verify_opened["session"]
        try:
            verify_status, verify_output = verify_session.host.run_shell_command(
                "echo deploydash-system-verify",
                _timeout=10,
                _sudo=True,
            )
            ctx.emit_shell_output_lines(emit, verify_output)
            if not verify_status:
                rollback_performed = _rollback_system_apply(
                    ctx,
                    session,
                    apply_result,
                    original_settings,
                    firewall_stage,
                    emit=emit,
                )
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    (
                        "Applied settings but verification command failed. "
                        "Original settings were restored."
                    ),
                    stage="verify_runtime_operation",
                    details=ctx.command_error_details(verify_output),
                    extra={"rollback_performed": rollback_performed},
                )
        finally:
            verify_close_result = verify_session.close()
            verify_disconnect_error = verify_close_result.get("disconnect_error")
            if verify_disconnect_error:
                ctx.emit_event(
                    emit,
                    "connection_disconnect_error",
                    verify_disconnect_error,
                    level="warning",
                )

        if port_changed:
            firewall_commit = engine_firewall_ops._commit_ssh_port_firewall(
                ctx,
                session.host,
                stage_token=firewall_stage.get("stage_token"),
                current_port=port,
                target_port=normalized["ssh_port"],
                emit=emit,
            )
            if firewall_commit.get("status") != "success":
                rollback_performed = _rollback_system_apply(
                    ctx,
                    session,
                    apply_result,
                    original_settings,
                    firewall_stage,
                    emit=emit,
                )
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    (
                        "SSH worked on the target port, but finalizing its firewall "
                        "rules failed. Original settings were restored."
                    ),
                    stage="execute_runtime_operation",
                    details=firewall_commit.get("msg"),
                    extra={"rollback_performed": rollback_performed},
                )

        response = {
            "status": "success",
            "code": "OK",
            "msg": "Server system settings applied successfully.",
            "operation_id": "system_apply",
            "applied_settings": normalized,
            "rollback_performed": False,
        }
        if port_changed:
            response["msg"] = (
                f"Server system settings applied; SSH moved to port "
                f"{normalized['ssh_port']} and its firewall rule was updated."
            )
            response["connection_update"] = {"port": normalized["ssh_port"]}
            response["ssh_port_transition"] = {
                "from": port,
                "to": normalized["ssh_port"],
                "firewall_updated": bool(firewall_stage.get("managed")),
            }
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
