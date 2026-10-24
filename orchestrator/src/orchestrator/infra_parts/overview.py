# ruff: noqa: F403, F405

from .. import firewall_ufw
from ._shared import *


def _get_hardware_specs_fast(ctx, host, emit=None):
    if not hasattr(host, "run_shell_command"):
        return None

    ctx.emit_event(
        emit,
        "facts_progress",
        "Fetching OS, CPU, memory, and disk details.",
    )

    command = (
        'OS_NAME=""; '
        'if [ -f /etc/os-release ]; then . /etc/os-release; OS_NAME="$PRETTY_NAME"; fi; '
        'if [ -z "$OS_NAME" ]; then OS_NAME="$(uname -s 2>/dev/null)"; fi; '
        'CPU_ARCH="$(uname -m 2>/dev/null)"; '
        "MEM_KB=\"$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)\"; "
        "DISK_KB=\"$(df -kP / 2>/dev/null | awk 'NR==2 {print $2; exit}')\"; "
        "printf 'os=%s\\ncpu=%s\\nmemory_kb=%s\\ndisk_kb=%s\\n' "
        '"$OS_NAME" "$CPU_ARCH" "$MEM_KB" "$DISK_KB"'
    )

    try:
        status, output = host.run_shell_command(command, _timeout=4)
    except Exception:
        return None

    if not status or output is None:
        return None

    parsed = shell_output.parse_key_values(output)

    os_name = _normalized_optional_string(parsed.get("os")) or "Unknown"
    cpu_info = _normalized_optional_string(parsed.get("cpu"))
    memory_kb = _parse_positive_int(parsed.get("memory_kb"))
    disk_kb = _parse_positive_int(parsed.get("disk_kb"))

    memory_mb = round(memory_kb / 1024) if memory_kb is not None else None
    disk_gb = round(disk_kb / (1024 * 1024)) if disk_kb is not None else None

    return {
        "status": "success",
        "os": os_name,
        "cpu": cpu_info,
        "memory_mb": memory_mb,
        "disk_gb": disk_gb,
    }


def get_hardware_specs(ctx, host, emit=None):
    try:
        fast_specs = _get_hardware_specs_fast(ctx, host, emit=emit)
        if fast_specs is not None:
            return fast_specs

        ctx.emit_event(
            emit,
            "facts_progress",
            "Fast probe unavailable; collecting pyinfra facts.",
        )
        os_info = host.get_fact(facts.server.Kernel)
        ctx.emit_event(emit, "facts_progress", "Fetched operating system details.")
        linux_info = host.get_fact(facts.server.LinuxDistribution)
        ctx.emit_event(emit, "facts_progress", "Fetched Linux distribution details.")
        cpu_info = host.get_fact(facts.server.Arch)
        ctx.emit_event(emit, "facts_progress", "Fetched CPU architecture details.")
        memory_mb = host.get_fact(facts.hardware.Memory)
        ctx.emit_event(emit, "facts_progress", "Fetched memory details.")
        block_devices = host.get_fact(facts.hardware.BlockDevices) or {}
        ctx.emit_event(emit, "facts_progress", "Fetched filesystem details.")

        if linux_info:
            release_meta = linux_info.get("release_meta") or {}
            pretty_name = _normalized_optional_string(release_meta.get("PRETTY_NAME"))
            if pretty_name is not None:
                os_name = pretty_name
            else:
                distribution_name = _normalized_optional_string(linux_info.get("name")) or "Unknown"
                major = _normalized_optional_string(linux_info.get("major")) or ""
                minor = _normalized_optional_string(linux_info.get("minor")) or ""
                version = f"{major}.{minor}".strip(".")
                os_name = f"{distribution_name} {version}".strip()
        else:
            os_name = os_info

        return {
            "status": "success",
            "os": os_name,
            "cpu": cpu_info,
            "memory_mb": memory_mb,
            "disk_gb": _get_primary_disk_gb(block_devices),
        }
    except Exception as exc:
        return ctx.error_result(
            "ENGINE_FACTS_FAILED",
            f"Failed to retrieve specs: {exc}",
            stage="collect_facts",
            details=str(exc),
        )


def _split_setup_steps_for_verified_handoff(steps):
    bootstrap = []
    remaining = []
    for step in steps:
        if step.id in _SETUP_BOOTSTRAP_HANDOFF_STEP_IDS:
            bootstrap.append(step)
        else:
            remaining.append(step)
    return bootstrap, remaining


def _merge_plan_execution_results(*results, message):
    merged = None
    for result in results:
        if result is None:
            continue
        if merged is None:
            merged = dict(result)
            merged["completed_step_ids"] = list(result.get("completed_step_ids", []))
            merged["scheduled_action_ids"] = list(result.get("scheduled_action_ids", []))
            merged["completed_action_ids"] = list(result.get("completed_action_ids", []))
            merged["logs"] = list(result.get("logs", []))
            continue

        merged["completed_step_ids"].extend(result.get("completed_step_ids", []))
        merged["scheduled_action_ids"].extend(result.get("scheduled_action_ids", []))
        merged["completed_action_ids"].extend(result.get("completed_action_ids", []))
        merged["logs"].extend(result.get("logs", []))

    if merged is None:
        return {
            "status": "success",
            "msg": message,
            "code": "OK",
            "completed_step_ids": [],
            "scheduled_action_ids": [],
            "completed_action_ids": [],
            "logs": [],
        }

    merged["msg"] = message
    merged["status"] = "success"
    merged["code"] = "OK"
    return merged


def _probe_os_identity(ctx, host):
    if not hasattr(host, "run_shell_command"):
        return None, "Host connector does not support shell probes."

    command = (
        'OS_ID=""; '
        'VERSION_ID_VALUE=""; '
        "if [ -f /etc/os-release ]; then . /etc/os-release; "
        'OS_ID="${ID:-}"; VERSION_ID_VALUE="${VERSION_ID:-}"; fi; '
        'ARCH="$(uname -m 2>/dev/null || true)"; '
        "printf 'os_id=%s\\nversion_id=%s\\narch=%s\\n' "
        '"$OS_ID" "$VERSION_ID_VALUE" "$ARCH"'
    )
    try:
        status, output = host.run_shell_command(command, _timeout=6)
    except Exception as exc:
        return None, str(exc)

    if not status or output is None:
        return None, ctx.command_error_details(output)

    parsed = shell_output.parse_key_values(output)
    return {
        "os_id": _normalized_optional_string(parsed.get("os_id")) or "",
        "version_id": _normalized_optional_string(parsed.get("version_id")) or "",
        "arch": _normalized_optional_string(parsed.get("arch")) or "",
    }, None


def _probe_service_installation(ctx, host, probe):
    if not hasattr(host, "run_shell_command"):
        return None, "Host connector does not support shell probes."

    command_candidates = " ".join(shlex.quote(value) for value in probe["commands"])
    package_candidates = " ".join(shlex.quote(value) for value in probe["packages"])
    unit_candidates = " ".join(shlex.quote(value) for value in probe["units"])
    command = (
        "set +e; "
        'CMD_HIT=""; PKG_HIT=""; UNIT_HIT=""; ACTIVE_HIT=""; '
        f"for c in {command_candidates}; do "
        'if command -v "$c" >/dev/null 2>&1; then CMD_HIT="$c"; break; fi; '
        "done; "
        f"for p in {package_candidates}; do "
        "if dpkg-query -W -f='${Status}' \"$p\" 2>/dev/null | "
        'grep -q "install ok installed"; then PKG_HIT="$p"; break; fi; '
        "done; "
        f"for u in {unit_candidates}; do "
        'if systemctl list-unit-files "$u" >/dev/null 2>&1; then '
        'UNIT_HIT="$u"; break; fi; '
        "done; "
        f"for u in {unit_candidates}; do "
        'if systemctl is-active --quiet "$u" >/dev/null 2>&1; then '
        'ACTIVE_HIT="$u"; break; fi; '
        "done; "
        "printf 'command=%s\\npackage=%s\\nunit=%s\\nactive=%s\\n' "
        '"$CMD_HIT" "$PKG_HIT" "$UNIT_HIT" "$ACTIVE_HIT"'
    )
    try:
        status, output = host.run_shell_command(command, _timeout=6)
    except Exception as exc:
        return None, str(exc)

    if not status or output is None:
        return None, ctx.command_error_details(output)

    parsed = shell_output.parse_key_values(output)
    return {
        "command": _normalized_optional_string(parsed.get("command")) or "",
        "package": _normalized_optional_string(parsed.get("package")) or "",
        "unit": _normalized_optional_string(parsed.get("unit")) or "",
        "active": _normalized_optional_string(parsed.get("active")) or "",
    }, None


def _probe_setup_reachability(ctx, host):
    if not hasattr(host, "run_shell_command"):
        return None, "Host connector does not support shell probes."

    probes_json = json.dumps(
        [{"id": probe["id"], "url": probe["url"]} for probe in _COMPATIBILITY_REACHABILITY_PROBES]
    )
    command = (
        "set +e; "
        'CODENAME=""; '
        "if [ -f /etc/os-release ]; then . /etc/os-release; "
        'CODENAME="${VERSION_CODENAME:-}"; fi; '
        '[ -n "$CODENAME" ] || CODENAME="noble"; '
        f"python3 - {shlex.quote(probes_json)} \"$CODENAME\" <<'PY'\n"
        "import json\n"
        "import sys\n"
        "import urllib.error\n"
        "import urllib.request\n"
        "\n"
        "probes = json.loads(sys.argv[1])\n"
        "codename = sys.argv[2]\n"
        "for probe in probes:\n"
        "    probe_id = probe['id']\n"
        "    url = probe['url'].format(codename=codename)\n"
        "    request = urllib.request.Request(\n"
        "        url,\n"
        "        headers={'User-Agent': 'DeployDashCompatibilityCheck/1.0'},\n"
        "    )\n"
        "    try:\n"
        "        with urllib.request.urlopen(request, timeout=8) as response:\n"
        "            status = response.getcode()\n"
        "            response.read(1)\n"
        "        passed = status < 500\n"
        "        actual = f'HTTP {status} from {url}'\n"
        "    except urllib.error.HTTPError as exc:\n"
        "        passed = exc.code < 500\n"
        "        actual = f'HTTP {exc.code} from {url}'\n"
        "    except Exception as exc:\n"
        "        passed = False\n"
        "        actual = f'{type(exc).__name__}: {str(exc)[:180]} from {url}'\n"
        "    print(f'{probe_id}_passed={1 if passed else 0}')\n"
        "    print(f'{probe_id}_actual={actual}')\n"
        "PY"
    )
    try:
        status, output = host.run_shell_command(command, _timeout=45)
    except Exception as exc:
        return None, str(exc)

    if not status or output is None:
        return None, ctx.command_error_details(output)

    parsed = shell_output.parse_key_values(output)
    reachability = {}
    for probe in _COMPATIBILITY_REACHABILITY_PROBES:
        probe_id = probe["id"]
        reachability[probe_id] = {
            "passed": parsed.get(f"{probe_id}_passed") == "1",
            "actual": (
                _normalized_optional_string(parsed.get(f"{probe_id}_actual"))
                or "Reachability probe did not return a result."
            ),
        }
    return reachability, None


def _probe_existing_admin_account(ctx, host):
    if not hasattr(host, "run_shell_command"):
        return None, "Host connector does not support shell probes."

    admin_user = CANONICAL_SETUP_SETTINGS["admin_user"]
    command = existing_admin_account_probe_command(admin_user)
    try:
        result = run_shell_command(host, command, timeout=6, sudo=True)
    except Exception as exc:
        return None, str(exc)

    output = result["output"]
    if not result["ok"] or output is None:
        return None, ctx.command_error_details(output)

    return parse_existing_admin_account(shell_output.parse_key_values(output)), None


def _existing_admin_keys_check(admin_account, probe_error):
    admin_user = CANONICAL_SETUP_SETTINGS["admin_user"]
    expected = "Pre-existing SSH access is left untouched."
    if admin_account is None:
        return _compatibility_check(
            check_id="existing_admin_keys",
            label="Deploy Dash adds 1 SSH key",
            category="access",
            passed=True,
            expected=expected,
            actual=probe_error or "The existing SSH access could not be read.",
            message=(
                f"Could not determine the existing SSH keys for {admin_user} — "
                "setup leaves whatever is there untouched."
            ),
        )
    if not admin_account["exists"]:
        return _compatibility_check(
            check_id="existing_admin_keys",
            label="Deploy Dash adds 1 SSH key",
            category="access",
            passed=True,
            expected=expected,
            actual=f"No {admin_user} account on this server.",
            message=f"No existing {admin_user} account — Deploy Dash creates it.",
        )
    key_count = admin_account["authorized_key_count"]
    if key_count is None:
        return _compatibility_check(
            check_id="existing_admin_keys",
            label="Deploy Dash adds 1 SSH key",
            category="access",
            passed=True,
            expected=expected,
            actual="The probe answered without a key count.",
            message=(
                f"Could not determine the existing SSH keys for {admin_user} — "
                "setup leaves whatever is there untouched."
            ),
        )
    fingerprints = admin_account["authorized_key_fingerprints"]
    if key_count == 0:
        message = f"{admin_user} exists with no SSH keys."
        actual = f"{admin_user} exists with no authorized keys."
    else:
        noun = "SSH key" if key_count == 1 else "SSH keys"
        message = f"{admin_user} already has {key_count} {noun} — they stay untouched."
        actual = "\n".join(fingerprints) if fingerprints else "No key fingerprints listed."
    return _compatibility_check(
        check_id="existing_admin_keys",
        label="Deploy Dash adds 1 SSH key",
        category="access",
        passed=True,
        expected=expected,
        actual=actual,
        message=message,
    )


def _ufw_replacement_check(ufw_state, probe_error):
    """Describe firewall ownership transfer without making UFW a blocker."""
    expected = "Deploy Dash replaces ufw and owns the server firewall."
    if ufw_state is None:
        return _compatibility_check(
            check_id="ufw_replacement",
            label="Deploy Dash replaces ufw",
            category="firewall",
            passed=True,
            expected=expected,
            actual=probe_error or "UFW state could not be read.",
            message=(
                "Deploy Dash could not determine the current ufw state. Setup will "
                "still replace ufw if it is installed."
            ),
        )

    if not ufw_state["installed"]:
        message = "ufw is not installed; Deploy Dash will install and own the firewall."
        actual = "No ufw rules detected."
    elif not ufw_state["active"]:
        message = "ufw is installed but inactive; Deploy Dash will replace it."
        actual = "No active ufw allow rules."
    else:
        message = (
            "Deploy Dash will replace active ufw. These ports will be closed unless "
            "you add matching rules in Deploy Dash."
        )
        actual = (
            "\n".join(ufw_state["allowed_rules"])
            if ufw_state["allowed_rules"]
            else "Active ufw reported no allow rules."
        )
    return _compatibility_check(
        check_id="ufw_replacement",
        label="Deploy Dash replaces ufw",
        category="firewall",
        passed=True,
        expected=expected,
        actual=actual,
        message=message,
    )


def _build_service_probe_actual_label(signal_data):
    parts = []
    if signal_data.get("command"):
        parts.append(f"command: {signal_data['command']}")
    if signal_data.get("package"):
        parts.append(f"package: {signal_data['package']}")
    if signal_data.get("unit"):
        parts.append(f"unit: {signal_data['unit']}")
    if signal_data.get("active"):
        parts.append(f"active: {signal_data['active']}")
    if not parts:
        return "No installation signals detected."
    return ", ".join(parts)


def _compatibility_check(
    *,
    check_id,
    label,
    category,
    passed,
    expected,
    actual,
    message,
):
    return {
        "id": check_id,
        "label": label,
        "category": category,
        "passed": bool(passed),
        "expected": expected,
        "actual": actual,
        "message": message,
    }


def collect_server_compatibility(ctx, host, emit=None):
    ctx.emit_event(
        emit,
        "compatibility_check_start",
        "Running compatibility checks for add-server requirements.",
    )

    checks = []

    os_identity, os_probe_error = _probe_os_identity(ctx, host)
    if os_probe_error is not None:
        checks.append(
            _compatibility_check(
                check_id="compatibility_probe",
                label="Compatibility probe available",
                category="probe",
                passed=False,
                expected="OS and package probe command must execute successfully.",
                actual=os_probe_error,
                message=(
                    "Compatibility probe failed. Re-run connect once SSH shell access is stable."
                ),
            )
        )
    else:
        os_id = (os_identity.get("os_id") or "").lower()
        version_id = os_identity.get("version_id") or ""
        arch = (os_identity.get("arch") or "").lower()

        os_passed = os_id == "ubuntu" and version_id.startswith("24.04")
        checks.append(
            _compatibility_check(
                check_id="os_ubuntu_24_04",
                label="Operating system is Ubuntu 24.04.x",
                category="os",
                passed=os_passed,
                expected="Ubuntu 24.04.x",
                actual=f"{os_id or 'unknown'} {version_id or 'unknown'}".strip(),
                message=(
                    "OS requirement satisfied."
                    if os_passed
                    else "Only Ubuntu 24.04.x is currently supported."
                ),
            )
        )

        arch_passed = arch in {"x86_64", "amd64"}
        checks.append(
            _compatibility_check(
                check_id="arch_x86_64",
                label="CPU architecture is 64-bit x86",
                category="arch",
                passed=arch_passed,
                expected="x86_64 or amd64",
                actual=arch or "unknown",
                message=(
                    "CPU architecture requirement satisfied."
                    if arch_passed
                    else "Only x86_64/amd64 servers are currently supported."
                ),
            )
        )

    for service_probe in _COMPATIBILITY_SERVICE_PROBES:
        signal_data, probe_error = _probe_service_installation(ctx, host, service_probe)
        if probe_error is not None:
            checks.append(
                _compatibility_check(
                    check_id=service_probe["id"],
                    label=service_probe["label"],
                    category="service",
                    passed=False,
                    expected=f"No pre-existing {service_probe['service_name']} installation.",
                    actual=probe_error,
                    message=(
                        f"Could not verify {service_probe['service_name']} installation status."
                    ),
                )
            )
            continue

        has_install_signals = any(signal_data.values())
        checks.append(
            _compatibility_check(
                check_id=service_probe["id"],
                label=service_probe["label"],
                category="service",
                passed=not has_install_signals,
                expected=f"No pre-existing {service_probe['service_name']} installation.",
                actual=_build_service_probe_actual_label(signal_data),
                message=(
                    f"{service_probe['service_name']} is not installed."
                    if not has_install_signals
                    else (f"{service_probe['service_name']} appears to already be installed.")
                ),
            )
        )

    reachability_results, reachability_error = _probe_setup_reachability(ctx, host)
    for reachability_probe in _COMPATIBILITY_REACHABILITY_PROBES:
        probe_id = reachability_probe["id"]
        if reachability_error is not None:
            checks.append(
                _compatibility_check(
                    check_id=probe_id,
                    label=reachability_probe["label"],
                    category="network",
                    passed=False,
                    expected=reachability_probe["expected"],
                    actual=reachability_error,
                    message=(
                        "Could not run package repository reachability checks on this server."
                    ),
                )
            )
            continue

        result = reachability_results.get(probe_id, {})
        passed = result.get("passed") is True
        checks.append(
            _compatibility_check(
                check_id=probe_id,
                label=reachability_probe["label"],
                category="network",
                passed=passed,
                expected=reachability_probe["expected"],
                actual=result.get("actual") or "No reachability result.",
                message=(
                    reachability_probe["success_message"]
                    if passed
                    else reachability_probe["failure_message"]
                ),
            )
        )

    admin_account, admin_probe_error = _probe_existing_admin_account(ctx, host)
    checks.append(_existing_admin_keys_check(admin_account, admin_probe_error))

    ufw_state, ufw_probe_error = firewall_ufw.probe_ufw(host)
    checks.append(_ufw_replacement_check(ufw_state, ufw_probe_error))

    failed_checks = [check for check in checks if check.get("passed") is not True]
    status = "pass" if not failed_checks else "fail"
    summary = (
        "Server meets add-server compatibility requirements."
        if status == "pass"
        else (
            f"{len(failed_checks)} compatibility check(s) failed. "
            "Resolve them before adding this server."
        )
    )

    ctx.emit_event(
        emit,
        "compatibility_check_complete",
        summary,
        level="info" if status == "pass" else "warning",
        data={
            "status": status,
            "total_checks": len(checks),
            "failed_checks": len(failed_checks),
        },
    )

    return {
        "status": status,
        "summary": summary,
        "checks": checks,
        "failed_checks": failed_checks,
    }


def check_ssh_and_specs(
    ctx,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    emit=None,
):
    opened = ctx.open_runtime_session(
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        needs_sudo=False,
        emit=emit,
    )
    if not opened["ok"]:
        return opened["error"]

    session = opened["session"]
    try:
        ctx.emit_event(
            emit,
            "layout_check_start",
            "Checking how this server is set up.",
        )
        layout_state = server_layout.read_layout_state(session.host)
        layout_outcome = server_layout.classify_state(layout_state)
        if layout_outcome.code == "ENGINE_LAYOUT_MIGRATION_REQUIRED":
            ctx.emit_event(
                emit,
                "layout_migration_start",
                "Upgrading this server's Deploy Dash layout.",
                data={
                    "from_version": layout_outcome.version,
                    "to_version": server_paths.LAYOUT_VERSION,
                },
            )
            layout_outcome = server_layout.migrate_layout(session.host, layout_state)
            if layout_outcome.ok:
                ctx.emit_event(
                    emit,
                    "layout_migration_complete",
                    "Server layout upgraded.",
                    data={"layout_version": layout_outcome.version},
                )
        if not layout_outcome.ok:
            ctx.emit_event(
                emit,
                "layout_check_failed",
                layout_outcome.message,
                level="error",
                data={"code": layout_outcome.code},
            )
            return ctx.error_result(
                layout_outcome.code,
                layout_outcome.message,
                stage="check_layout_version",
                details=(
                    f"layout_version={layout_outcome.version}"
                    if layout_outcome.version is not None
                    else None
                ),
                extra={"layout_version": layout_outcome.version},
            )

        ctx.emit_event(
            emit,
            "facts_start",
            "Collecting server hardware facts.",
        )
        result = get_hardware_specs(ctx, session.host, emit=emit)
        if result.get("status") == "success":
            compatibility = collect_server_compatibility(ctx, session.host, emit=emit)
            result = {**result, "compatibility": compatibility}
            ctx.emit_event(
                emit,
                "facts_collected",
                "Collected server hardware facts.",
                data={
                    "os": result.get("os"),
                    "cpu": result.get("cpu"),
                    "memory_mb": result.get("memory_mb"),
                    "disk_gb": result.get("disk_gb"),
                },
            )
            return result

        ctx.emit_event(
            emit,
            "facts_error",
            result.get("msg", "Failed to collect facts"),
            level="error",
            data={"code": result.get("code")},
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


def run_server_overview_operation(
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

    retention_days = 90
    prerequisite_command = (
        "command -v sar >/dev/null 2>&1 || "
        "(echo 'sysstat is required for overview metrics. "
        "Run server provisioning (setup part2) on this host.' >&2; exit 1)"
    )

    collect_command = (
        "set -eu; "
        'UPTIME_SECONDS="$(cut -d. -f1 /proc/uptime 2>/dev/null || true)"; '
        'BOOTED_AT="$(date -u -d "$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0) seconds ago" \'+%Y-%m-%dT%H:%M:%SZ\' 2>/dev/null || true)"; '
        'CPU_IDLE="$(LC_ALL=C sar -u 1 1 2>/dev/null | awk \'/Average:/ && $2=="all" {print $NF; exit}\')"; '
        'LOAD_AVG="$(awk \'{print $1" "$2" "$3}\' /proc/loadavg 2>/dev/null || true)"; '
        'MEM_LINE="$(free -m 2>/dev/null | awk \'/Mem:/ {print $2" "$3" "$4" "$7; exit}\')"; '
        'SWAP_LINE="$(free -m 2>/dev/null | awk \'/Swap:/ {print $2" "$3" "$4; exit}\')"; '
        'DISK_ROOT_LINE="$(df -B1 --output=size,used,avail,pcent / 2>/dev/null | awk \'NR==2 {print $1" "$2" "$3" "$4; exit}\')"; '
        "INODE_ROOT_LINE=\"$(df -i --output=ipcent / 2>/dev/null | awk 'NR==2 {print $1; exit}')\"; "
        "SYSSTAT_FILE_COUNT=\"$(find /var/log/sysstat -maxdepth 1 -type f \\( -name 'sa*' -o -name 'sar*' \\) 2>/dev/null | wc -l | tr -d '[:space:]')\"; "
        'SYSSTAT_OLDEST="$(ls -1 /var/log/sysstat/sa* /var/log/sysstat/sar* 2>/dev/null | head -n1 || true)"; '
        'SYSSTAT_NEWEST="$(ls -1t /var/log/sysstat/sa* /var/log/sysstat/sar* 2>/dev/null | head -n1 || true)"; '
        f"printf 'retention_days={retention_days}\\n'; "
        "printf 'uptime_seconds=%s\\n' \"${UPTIME_SECONDS}\"; "
        "printf 'booted_at=%s\\n' \"${BOOTED_AT}\"; "
        "printf 'cpu_idle=%s\\n' \"${CPU_IDLE}\"; "
        "printf 'load_avg=%s\\n' \"${LOAD_AVG}\"; "
        "printf 'mem=%s\\n' \"${MEM_LINE}\"; "
        "printf 'swap=%s\\n' \"${SWAP_LINE}\"; "
        "printf 'disk_root=%s\\n' \"${DISK_ROOT_LINE}\"; "
        "printf 'inode_root=%s\\n' \"${INODE_ROOT_LINE}\"; "
        "printf 'sysstat_files=%s\\n' \"${SYSSTAT_FILE_COUNT}\"; "
        "printf 'sysstat_oldest=%s\\n' \"${SYSSTAT_OLDEST}\"; "
        "printf 'sysstat_newest=%s\\n' \"${SYSSTAT_NEWEST}\"; "
        "LC_ALL=C sar -n DEV 1 1 2>/dev/null | "
        'awk \'/Average:/ && $2 != "IFACE" && $2 != "lo" {printf "net_dev=%s,%s,%s\\n", $2, $5, $6}\'; '
        "LC_ALL=C sar -d 1 1 2>/dev/null | "
        'awk \'/Average:/ && $2 != "DEV" {printf "disk_dev=%s,%s,%s,%s\\n", $2, $4, $5, $NF}\';'
    )

    operation_steps = [
        ("Verify overview metrics prerequisites", prerequisite_command, 10),
        ("Collect server overview metrics", collect_command, 60),
    ]

    if dry_run:
        return {
            "status": "success",
            "code": "OK",
            "msg": "Server overview metrics plan ready",
            "operation_id": "overview_metrics",
            "actions": [step[0] for step in operation_steps],
            "retention_days": retention_days,
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
    metrics = None
    try:
        ctx.emit_event(
            emit,
            "server_overview_plan_ready",
            "Server overview metrics operation prepared.",
            data={"retention_days": retention_days},
        )

        for label, command, timeout_seconds in operation_steps:
            if callable(is_cancelled) and is_cancelled():
                return ctx.error_result(
                    "ENGINE_TASK_CANCELLED",
                    "Task cancelled during server overview metrics operation",
                    stage="execute_runtime_operation",
                )

            ctx.emit_event(emit, "server_overview_action_started", f"{label}: started")
            status, output = session.host.run_shell_command(
                command,
                _timeout=timeout_seconds,
                _sudo=True,
            )
            ctx.emit_shell_output_lines(emit, output)

            if label == "Collect server overview metrics":
                metrics = _parse_server_overview_metrics_output(output)

            if not status:
                details = ctx.command_error_details(output)
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    f"{label} failed.",
                    stage="execute_runtime_operation",
                    details=details or "remote command failed",
                )

            ctx.emit_event(
                emit,
                "server_overview_action_completed",
                f"{label}: completed",
            )

        return {
            "status": "success",
            "code": "OK",
            "msg": "Server overview metrics captured.",
            "operation_id": "overview_metrics",
            "retention_days": retention_days,
            "metrics": metrics or {},
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
