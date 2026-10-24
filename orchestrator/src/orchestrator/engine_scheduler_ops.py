import re
import shlex

from . import server_identifiers, server_paths, shell_output
from .engine_context import EngineCore
from .runtime_ops import (
    remove_remote_files,
    run_shell_command,
    systemd_daemon_reload,
    systemd_disable_now,
    systemd_enable_now,
    systemd_reset_failed,
    systemd_service_action,
    write_remote_text_file,
)


class SchedulerConfigValidationError(ValueError):
    pass


_PROJECT_SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
_TASK_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
_WORKER_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,62}$")
_DAILY_TIME_PATTERN = re.compile(r"^(?:[01]?\d|2[0-3]):[0-5]\d$")
_SCHEDULER_SCRIPT_DIR = server_paths.scheduler_script_dir()
_APPS_ROOT = server_paths.apps_root()


def _trimmed(value):
    if not isinstance(value, str):
        return ""
    return value.strip()


def _normalize_project_slug(raw_value):
    if not isinstance(raw_value, str) or not raw_value.strip():
        raise SchedulerConfigValidationError(
            "settings.project_slug must be a non-empty string.",
        )
    normalized = raw_value.strip().lower()
    if not _PROJECT_SLUG_PATTERN.match(normalized):
        raise SchedulerConfigValidationError(
            "settings.project_slug must match [a-z0-9-] and start with a letter/number.",
        )
    return normalized


def _normalize_task_id(raw_value):
    if not isinstance(raw_value, str) or not raw_value.strip():
        raise SchedulerConfigValidationError(
            "settings.task_id must be a non-empty string.",
        )
    normalized = raw_value.strip().lower()
    if not _TASK_ID_PATTERN.match(normalized):
        raise SchedulerConfigValidationError(
            "settings.task_id must match [a-z0-9-] and start with a letter/number.",
        )
    return normalized


def _normalize_target_type(raw_value):
    normalized = _trimmed(raw_value).lower()
    if normalized not in ("web_app", "worker"):
        raise SchedulerConfigValidationError(
            "settings.target_type must be one of: web_app, worker.",
        )
    return normalized


def _normalize_worker_ref(raw_value):
    if not isinstance(raw_value, str) or not raw_value.strip():
        raise SchedulerConfigValidationError(
            "settings.target_ref must be set when target_type is worker.",
        )
    normalized = raw_value.strip().lower()
    if not _WORKER_ID_PATTERN.match(normalized):
        raise SchedulerConfigValidationError(
            "settings.target_ref is invalid. Use letters, numbers, '-' or '_'.",
        )
    return normalized


def _normalize_schedule_type(raw_value):
    normalized = _trimmed(raw_value).lower()
    if normalized not in ("every_minutes", "every_hours", "daily_at"):
        raise SchedulerConfigValidationError(
            "settings.schedule_type must be one of: every_minutes, every_hours, daily_at.",
        )
    return normalized


def _normalize_interval(raw_value):
    if isinstance(raw_value, bool):
        raw_value = None
    if isinstance(raw_value, (int, float)):
        value = int(raw_value)
    elif isinstance(raw_value, str) and raw_value.strip():
        try:
            value = int(raw_value.strip())
        except ValueError as exc:
            raise SchedulerConfigValidationError(
                "settings.interval_value must be a whole number.",
            ) from exc
    else:
        value = 5
    if value < 1 or value > 1440:
        raise SchedulerConfigValidationError(
            "settings.interval_value must be between 1 and 1440.",
        )
    return value


def _normalize_daily_time(raw_value):
    if not isinstance(raw_value, str) or not raw_value.strip():
        return "02:00"
    normalized = raw_value.strip()
    if not _DAILY_TIME_PATTERN.match(normalized):
        raise SchedulerConfigValidationError(
            "settings.daily_time must match HH:MM in 24-hour time.",
        )
    hour = int(normalized.split(":", 1)[0])
    minute = int(normalized.split(":", 1)[1])
    return f"{hour:02d}:{minute:02d}"


def _settings_payload(raw_data):
    if not isinstance(raw_data, dict):
        return {}
    settings = raw_data.get("settings")
    if isinstance(settings, dict):
        return settings
    return raw_data


def _task_unit_names(project_slug, task_id):
    base_name = server_identifiers.scheduler_unit_base(project_slug, task_id)
    return {
        "base_name": base_name,
        "service_unit": server_identifiers.scheduler_service_unit(project_slug, task_id),
        "timer_unit": server_identifiers.scheduler_timer_unit(project_slug, task_id),
        "service_path": f"/etc/systemd/system/{base_name}.service",
        "timer_path": f"/etc/systemd/system/{base_name}.timer",
        "script_dir": _SCHEDULER_SCRIPT_DIR,
        "script_path": (
            f"{_SCHEDULER_SCRIPT_DIR}/"
            f"{server_identifiers.scheduler_script_name(project_slug, task_id)}"
        ),
    }


def _task_container_name(project_slug, target_type, target_ref):
    if target_type == "worker":
        return server_identifiers.worker_container(project_slug, target_ref)
    return server_identifiers.app_container(project_slug)


def _scheduler_script_text(container_name, command_text):
    quoted_container = shlex.quote(container_name)
    quoted_command = shlex.quote(command_text)
    return (
        "#!/bin/sh\n"
        "set -eu\n"
        f"exec /usr/bin/docker exec {quoted_container} /bin/sh -lc {quoted_command}\n"
    )


def _web_app_scheduler_script_text(project_slug, command_text):
    quoted_project_slug = shlex.quote(project_slug)
    quoted_legacy_container = shlex.quote(server_identifiers.app_container(project_slug))
    quoted_manifest_path = shlex.quote(
        f"{_APPS_ROOT}/.deploydash/apps/{project_slug}/releases.json",
    )
    quoted_command = shlex.quote(command_text)
    return (
        "#!/bin/sh\n"
        "set -eu\n"
        f"PROJECT_SLUG={quoted_project_slug}\n"
        f"RELEASE_MANIFEST={quoted_manifest_path}\n"
        f"LEGACY_CONTAINER={quoted_legacy_container}\n"
        'LIVE_CONTAINER="$(/usr/bin/docker ps '
        f'--filter "label={server_identifiers.MANAGED_LABEL_PAIR}" '
        f'--filter "label={server_identifiers.LABEL_LIVE}=true" '
        f'--filter "label={server_identifiers.LABEL_PROJECT}=${{PROJECT_SLUG}}" '
        "--format '{{.Names}}' | head -n1)\"\n"
        'if [ -z "${LIVE_CONTAINER}" ] && [ -f "${RELEASE_MANIFEST}" ]; then\n'
        '  LIVE_CONTAINER="$(python3 - "${RELEASE_MANIFEST}" <<\'PY\'\n'
        "import json\n"
        "import sys\n"
        "\n"
        "try:\n"
        "    with open(sys.argv[1], 'r', encoding='utf-8') as handle:\n"
        "        manifest = json.load(handle)\n"
        "except Exception:\n"
        "    raise SystemExit(0)\n"
        "\n"
        "for entry in manifest.get('releases', []):\n"
        "    if not isinstance(entry, dict):\n"
        "        continue\n"
        "    if entry.get('status') != 'live':\n"
        "        continue\n"
        "    container = str(entry.get('web_container_name') or '').strip()\n"
        "    if container:\n"
        "        print(container)\n"
        "    break\n"
        "PY\n"
        ')"\n'
        "fi\n"
        'if [ -z "${LIVE_CONTAINER}" ] && '
        '/usr/bin/docker inspect "${LEGACY_CONTAINER}" >/dev/null 2>&1; then\n'
        '  LIVE_CONTAINER="${LEGACY_CONTAINER}"\n'
        "fi\n"
        'if [ -z "${LIVE_CONTAINER}" ]; then\n'
        "  echo 'Deploy Dash could not find the live web app container for this scheduled job.' >&2\n"
        "  exit 1\n"
        "fi\n"
        f'exec /usr/bin/docker exec "${{LIVE_CONTAINER}}" /bin/sh -lc {quoted_command}\n'
    )


def _scheduler_target_script_text(project_slug, target_type, target_ref, command_text):
    if target_type == "web_app":
        return _web_app_scheduler_script_text(project_slug, command_text)
    return _scheduler_script_text(
        _task_container_name(project_slug, target_type, target_ref),
        command_text,
    )


def _systemd_escape_value(value):
    return value.replace("%", "%%").replace("\n", " ").strip()


def _service_unit_text(task_name, script_path):
    escaped_name = task_name.replace("\n", " ").strip()
    escaped_script_path = _systemd_escape_value(script_path)
    return (
        "[Unit]\n"
        f"Description=Deploy Dash task: {escaped_name}\n"
        "After=docker.service\n"
        "Requires=docker.service\n"
        "\n"
        "[Service]\n"
        "Type=oneshot\n"
        f"ExecStart={escaped_script_path}\n"
        "\n"
        "[Install]\n"
        "WantedBy=multi-user.target\n"
    )


def _timer_unit_text(service_unit, schedule_type, interval_value, daily_time):
    if schedule_type == "every_minutes":
        schedule_lines = f"OnBootSec=1min\nOnUnitActiveSec={interval_value}min\n"
    elif schedule_type == "every_hours":
        schedule_lines = f"OnBootSec=1min\nOnUnitActiveSec={interval_value}h\n"
    else:
        schedule_lines = f"OnCalendar=*-*-* {daily_time}:00\n"

    return (
        "[Unit]\n"
        f"Description=Deploy Dash timer for {service_unit}\n"
        "\n"
        "[Timer]\n"
        f"Unit={service_unit}\n"
        f"{schedule_lines}"
        "Persistent=true\n"
        "\n"
        "[Install]\n"
        "WantedBy=timers.target\n"
    )


def _empty_if_not_iso(candidate):
    if not isinstance(candidate, str):
        return None
    value = candidate.strip()
    if not value:
        return None
    return value


def _build_status_command(timer_unit, service_unit):
    quoted_timer = shlex.quote(timer_unit)
    quoted_service = shlex.quote(service_unit)
    return (
        "set -eu; "
        f"TIMER={quoted_timer}; "
        f"SERVICE={quoted_service}; "
        'ENABLED="$(systemctl is-enabled "${TIMER}" 2>/dev/null || true)"; '
        'ACTIVE="$(systemctl is-active "${TIMER}" 2>/dev/null || true)"; '
        'SUB_STATE="$(systemctl show "${TIMER}" -p SubState --value 2>/dev/null || true)"; '
        'TIMER_RESULT="$(systemctl show "${TIMER}" -p Result --value 2>/dev/null || true)"; '
        'LAST_RAW="$(systemctl show "${TIMER}" -p LastTriggerUSec --value 2>/dev/null || true)"; '
        'NEXT_RAW="$(systemctl show "${TIMER}" -p NextElapseUSecRealtime --value 2>/dev/null || true)"; '
        "LAST_ISO=''; "
        'if [ -n "${LAST_RAW}" ] && [ "${LAST_RAW}" != \'n/a\' ]; then '
        'LAST_ISO="$(date -u -d "${LAST_RAW}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"; '
        "fi; "
        "NEXT_ISO=''; "
        'if [ -n "${NEXT_RAW}" ] && [ "${NEXT_RAW}" != \'n/a\' ]; then '
        'NEXT_ISO="$(date -u -d "${NEXT_RAW}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"; '
        "fi; "
        'SERVICE_ACTIVE="$(systemctl is-active "${SERVICE}" 2>/dev/null || true)"; '
        'SERVICE_RESULT="$(systemctl show "${SERVICE}" -p Result --value 2>/dev/null || true)"; '
        "printf 'ENABLED=%s\\nACTIVE=%s\\nSUB_STATE=%s\\nTIMER_RESULT=%s\\nLAST_ISO=%s\\nNEXT_ISO=%s\\nSERVICE_ACTIVE=%s\\nSERVICE_RESULT=%s\\n' "
        '"${ENABLED}" "${ACTIVE}" "${SUB_STATE}" "${TIMER_RESULT}" "${LAST_ISO}" "${NEXT_ISO}" "${SERVICE_ACTIVE}" "${SERVICE_RESULT}"'
    )


def _build_run_now_command(service_unit):
    quoted_service = shlex.quote(service_unit)
    return (
        "set -u; "
        f"SERVICE={quoted_service}; "
        'systemctl reset-failed "${SERVICE}" >/dev/null 2>&1 || true; '
        'START_OUTPUT=""; '
        "START_STATUS=0; "
        'START_OUTPUT="$(systemctl start "${SERVICE}" 2>&1)" || START_STATUS=$?; '
        "ATTEMPT=1; "
        'while [ "${ATTEMPT}" -le 5 ]; do '
        'SERVICE_ACTIVE="$(systemctl is-active "${SERVICE}" 2>/dev/null || true)"; '
        'if [ "${SERVICE_ACTIVE}" != active ] && [ "${SERVICE_ACTIVE}" != activating ]; then break; fi; '
        "sleep 1; "
        "ATTEMPT=$((ATTEMPT + 1)); "
        "done; "
        'SERVICE_ACTIVE="$(systemctl is-active "${SERVICE}" 2>/dev/null || true)"; '
        'SERVICE_RESULT="$(systemctl show "${SERVICE}" -p Result --value 2>/dev/null || true)"; '
        'EXIT_CODE="$(systemctl show "${SERVICE}" -p ExecMainStatus --value 2>/dev/null || true)"; '
        'FINISHED_RAW="$(systemctl show "${SERVICE}" -p InactiveExitTimestamp --value 2>/dev/null || true)"; '
        "FINISHED_ISO=''; "
        'if [ -n "${FINISHED_RAW}" ] && [ "${FINISHED_RAW}" != \'n/a\' ]; then '
        'FINISHED_ISO="$(date -u -d "${FINISHED_RAW}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"; '
        "fi; "
        "printf 'START_STATUS=%s\\nSERVICE_ACTIVE=%s\\nSERVICE_RESULT=%s\\nEXIT_CODE=%s\\nFINISHED_ISO=%s\\n' "
        '"${START_STATUS}" "${SERVICE_ACTIVE}" "${SERVICE_RESULT}" "${EXIT_CODE}" "${FINISHED_ISO}"; '
        "printf 'RUN_OUTPUT_BEGIN\\n'; "
        'if [ -n "${START_OUTPUT}" ]; then printf \'%s\\n\' "${START_OUTPUT}"; fi; '
        'journalctl -u "${SERVICE}" -n 80 --no-pager -o cat 2>/dev/null || true; '
        "printf 'RUN_OUTPUT_END\\n'"
    )


def _parse_run_now_output(output):
    kv = {}
    run_output_lines = []
    collecting_output = False
    for raw_line in getattr(output, "stdout_lines", []) or []:
        if not isinstance(raw_line, str):
            continue
        line = raw_line.rstrip("\n")
        marker = line.strip()
        if marker == "RUN_OUTPUT_BEGIN":
            collecting_output = True
            continue
        if marker == "RUN_OUTPUT_END":
            collecting_output = False
            continue
        if collecting_output:
            run_output_lines.append(line)
            continue
        parsed = shell_output.split_key_value(marker)
        if parsed is None:
            continue
        kv[parsed[0]] = parsed[1]
    return kv, run_output_lines


def _scheduler_run_succeeded(kv):
    start_status = (kv.get("START_STATUS") or "").strip()
    service_result = (kv.get("SERVICE_RESULT") or "").strip()
    exit_code = (kv.get("EXIT_CODE") or "").strip()
    return (
        start_status in ("", "0") and service_result in ("", "success") and exit_code in ("", "0")
    )


def _scheduler_run_failure_details(kv, run_output_lines):
    service_result = kv.get("SERVICE_RESULT") or "unknown"
    exit_code = kv.get("EXIT_CODE") or "unknown"
    summary = (
        "The scheduled job finished with "
        f"service result {service_result} and exit code {exit_code}."
    )
    output = "\n".join(
        line for line in run_output_lines if isinstance(line, str) and line.strip()
    ).strip()
    if not output:
        return summary
    return f"{summary}\n\n{output}"


def _parse_task_upsert_settings(settings):
    project_slug = _normalize_project_slug(settings.get("project_slug"))
    task_id = _normalize_task_id(settings.get("task_id"))

    name = _trimmed(settings.get("name"))
    if not name:
        raise SchedulerConfigValidationError(
            "settings.name must be a non-empty string.",
        )

    command = _trimmed(settings.get("command"))
    if not command:
        raise SchedulerConfigValidationError(
            "settings.command must be a non-empty string.",
        )

    target_type = _normalize_target_type(settings.get("target_type"))
    if target_type == "worker":
        target_ref = _normalize_worker_ref(settings.get("target_ref"))
    else:
        target_ref = None

    schedule_type = _normalize_schedule_type(settings.get("schedule_type"))
    if schedule_type in ("every_minutes", "every_hours"):
        interval_value = _normalize_interval(settings.get("interval_value"))
        daily_time = None
    else:
        interval_value = None
        daily_time = _normalize_daily_time(settings.get("daily_time"))

    enabled = shell_output.parse_bool_token(settings.get("enabled"), True)

    return {
        "project_slug": project_slug,
        "task_id": task_id,
        "name": name,
        "command": command,
        "target_type": target_type,
        "target_ref": target_ref,
        "schedule_type": schedule_type,
        "interval_value": interval_value,
        "daily_time": daily_time,
        "enabled": enabled,
    }


def _parse_single_task_settings(settings):
    project_slug = _normalize_project_slug(settings.get("project_slug"))
    task_id = _normalize_task_id(settings.get("task_id"))
    return {
        "project_slug": project_slug,
        "task_id": task_id,
    }


def _parse_task_run_now_settings(settings):
    parsed = _parse_single_task_settings(settings)
    command = _trimmed(settings.get("command"))
    target_type = _trimmed(settings.get("target_type")).lower()
    if not command or target_type not in ("web_app", "worker"):
        return parsed

    parsed["command"] = command
    parsed["target_type"] = _normalize_target_type(target_type)
    parsed["target_ref"] = (
        _normalize_worker_ref(settings.get("target_ref"))
        if parsed["target_type"] == "worker"
        else None
    )
    return parsed


def _parse_task_enabled_settings(settings):
    parsed = _parse_single_task_settings(settings)
    parsed["enabled"] = shell_output.parse_bool_token(settings.get("enabled"), True)
    return parsed


def _parse_task_status_settings(settings):
    project_slug = _normalize_project_slug(settings.get("project_slug"))
    task_ids_payload = settings.get("task_ids")
    if not isinstance(task_ids_payload, list) or not task_ids_payload:
        raise SchedulerConfigValidationError(
            "settings.task_ids must be a non-empty list.",
        )

    task_ids = []
    seen = set()
    for item in task_ids_payload:
        task_id = _normalize_task_id(item)
        if task_id in seen:
            continue
        seen.add(task_id)
        task_ids.append(task_id)

    if not task_ids:
        raise SchedulerConfigValidationError(
            "settings.task_ids must include at least one valid task id.",
        )

    repair_tasks = []
    tasks_payload = settings.get("tasks")
    if isinstance(tasks_payload, list):
        for item in tasks_payload:
            if not isinstance(item, dict):
                continue
            task_id = _normalize_task_id(item.get("task_id") or item.get("id"))
            command = _trimmed(item.get("command"))
            target_type = _trimmed(item.get("target_type")).lower()
            if not command or target_type not in ("web_app", "worker"):
                continue
            repair_tasks.append(
                {
                    "task_id": task_id,
                    "command": command,
                    "target_type": _normalize_target_type(target_type),
                    "target_ref": (
                        _normalize_worker_ref(item.get("target_ref"))
                        if target_type == "worker"
                        else None
                    ),
                }
            )

    return {
        "project_slug": project_slug,
        "task_ids": task_ids,
        "repair_tasks": repair_tasks,
    }


def _run_shell_step(
    ctx: EngineCore, session, emit, operation_id, action_label, command, timeout=60
):
    return _run_runtime_step(
        ctx,
        session,
        emit,
        operation_id,
        action_label,
        lambda: run_shell_command(
            session.host,
            command,
            timeout=timeout,
            sudo=True,
            emit_output=lambda output: ctx.emit_shell_output_lines(emit, output),
        ),
    )


def _run_runtime_step(ctx: EngineCore, session, emit, operation_id, action_label, runner):
    ctx.emit_event(
        emit,
        "scheduler_runtime_action_started",
        f"{action_label}: started",
        data={
            "operation_id": operation_id,
            "action": action_label,
        },
    )
    result = runner()
    if not result["ok"]:
        return {
            "ok": False,
            "error": ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                f"{action_label} failed.",
                stage="execute_runtime_operation",
                details=result.get("details") or "remote command failed",
                extra={
                    "workflow_id": "scheduler",
                    "operation_id": operation_id,
                    "action": action_label,
                },
            ),
        }

    ctx.emit_event(
        emit,
        "scheduler_runtime_action_completed",
        f"{action_label}: completed",
        data={
            "operation_id": operation_id,
            "action": action_label,
        },
    )
    return {
        "ok": True,
        "output": result.get("output"),
    }


def run_scheduler_runtime_operation(
    ctx: EngineCore,
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

    settings = _settings_payload(raw_data)

    try:
        if operation_id == "task_upsert":
            parsed = _parse_task_upsert_settings(settings)
        elif operation_id == "task_run_now":
            parsed = _parse_task_run_now_settings(settings)
        elif operation_id == "task_delete":
            parsed = _parse_single_task_settings(settings)
        elif operation_id == "task_set_enabled":
            parsed = _parse_task_enabled_settings(settings)
        elif operation_id == "task_status":
            parsed = _parse_task_status_settings(settings)
        else:
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                f"Unknown scheduler operation: {operation_id}",
                stage="validate_request",
            )
    except SchedulerConfigValidationError as exc:
        ctx.emit_event(
            emit,
            "validation_error",
            str(exc),
            level="error",
            data={"workflow_id": "scheduler", "operation_id": operation_id},
        )
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            str(exc),
            stage="validate_request",
            extra={"workflow_id": "scheduler", "operation_id": operation_id},
        )

    if dry_run:
        return {
            "status": "success",
            "code": "OK",
            "msg": f"Scheduler operation '{operation_id}' plan ready",
            "workflow_id": "scheduler",
            "operation_id": operation_id,
            "project_slug": parsed.get("project_slug"),
            "task_id": parsed.get("task_id"),
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
            "scheduler_runtime_plan_ready",
            f"Scheduler operation '{operation_id}' prepared.",
            data={
                "workflow_id": "scheduler",
                "operation_id": operation_id,
                "project_slug": parsed.get("project_slug"),
            },
        )

        if operation_id == "task_upsert":
            names = _task_unit_names(parsed["project_slug"], parsed["task_id"])
            container_name = _task_container_name(
                parsed["project_slug"],
                parsed["target_type"],
                parsed["target_ref"],
            )
            script_text = _scheduler_target_script_text(
                parsed["project_slug"],
                parsed["target_type"],
                parsed["target_ref"],
                parsed["command"],
            )
            service_text = _service_unit_text(
                parsed["name"],
                names["script_path"],
            )
            timer_text = _timer_unit_text(
                names["service_unit"],
                parsed["schedule_type"],
                parsed["interval_value"],
                parsed["daily_time"],
            )
            status_command = _build_status_command(
                names["timer_unit"],
                names["service_unit"],
            )

            step_result = _run_shell_step(
                ctx,
                session,
                emit,
                operation_id,
                "Create scheduler script directory",
                f"install -d -m 0755 {shlex.quote(names['script_dir'])}",
                timeout=30,
            )
            if not step_result["ok"]:
                return step_result["error"]

            step_result = _run_runtime_step(
                ctx,
                session,
                emit,
                operation_id,
                "Write scheduler command script",
                lambda: write_remote_text_file(
                    session.host,
                    path=names["script_path"],
                    content=script_text,
                    mode="755",
                    timeout=90,
                    emit_output=lambda output: ctx.emit_shell_output_lines(
                        emit,
                        output,
                    ),
                ),
            )
            if not step_result["ok"]:
                return step_result["error"]

            step_result = _run_runtime_step(
                ctx,
                session,
                emit,
                operation_id,
                "Write scheduler service unit",
                lambda: write_remote_text_file(
                    session.host,
                    path=names["service_path"],
                    content=service_text,
                    mode="644",
                    timeout=90,
                    emit_output=lambda output: ctx.emit_shell_output_lines(
                        emit,
                        output,
                    ),
                ),
            )
            if not step_result["ok"]:
                return step_result["error"]

            step_result = _run_runtime_step(
                ctx,
                session,
                emit,
                operation_id,
                "Write scheduler timer unit",
                lambda: write_remote_text_file(
                    session.host,
                    path=names["timer_path"],
                    content=timer_text,
                    mode="644",
                    timeout=90,
                    emit_output=lambda output: ctx.emit_shell_output_lines(
                        emit,
                        output,
                    ),
                ),
            )
            if not step_result["ok"]:
                return step_result["error"]

            step_result = _run_runtime_step(
                ctx,
                session,
                emit,
                operation_id,
                "Reload systemd daemon",
                lambda: systemd_daemon_reload(
                    session.host,
                    timeout=45,
                    emit_output=lambda output: ctx.emit_shell_output_lines(
                        emit,
                        output,
                    ),
                ),
            )
            if not step_result["ok"]:
                return step_result["error"]

            if parsed["enabled"]:
                step_result = _run_runtime_step(
                    ctx,
                    session,
                    emit,
                    operation_id,
                    "Enable scheduler timer",
                    lambda: systemd_enable_now(
                        session.host,
                        unit=names["timer_unit"],
                        timeout=45,
                        emit_output=lambda output: ctx.emit_shell_output_lines(
                            emit,
                            output,
                        ),
                    ),
                )
            else:
                step_result = _run_runtime_step(
                    ctx,
                    session,
                    emit,
                    operation_id,
                    "Disable scheduler timer",
                    lambda: systemd_disable_now(
                        session.host,
                        unit=names["timer_unit"],
                        timeout=45,
                        ignore_failure=True,
                        emit_output=lambda output: ctx.emit_shell_output_lines(
                            emit,
                            output,
                        ),
                    ),
                )
            if not step_result["ok"]:
                return step_result["error"]

            step_result = _run_shell_step(
                ctx,
                session,
                emit,
                operation_id,
                "Read scheduler status",
                status_command,
                timeout=45,
            )
            if not step_result["ok"]:
                return step_result["error"]

            kv = shell_output.parse_key_values(step_result["output"])

            return {
                "status": "success",
                "code": "OK",
                "msg": "Scheduled task saved.",
                "workflow_id": "scheduler",
                "operation_id": operation_id,
                "project_slug": parsed["project_slug"],
                "task_id": parsed["task_id"],
                "service_unit": names["service_unit"],
                "timer_unit": names["timer_unit"],
                "target_container": container_name,
                "timer_active_state": kv.get("ACTIVE"),
                "timer_sub_state": kv.get("SUB_STATE"),
                "service_result": kv.get("SERVICE_RESULT"),
                "enabled": kv.get("ENABLED") == "enabled",
                "last_run_at": _empty_if_not_iso(kv.get("LAST_ISO")),
                "next_run_at": _empty_if_not_iso(kv.get("NEXT_ISO")),
            }

        if operation_id == "task_delete":
            names = _task_unit_names(parsed["project_slug"], parsed["task_id"])

            step_result = _run_runtime_step(
                ctx,
                session,
                emit,
                operation_id,
                "Disable scheduler timer",
                lambda: systemd_disable_now(
                    session.host,
                    unit=names["timer_unit"],
                    timeout=45,
                    ignore_failure=True,
                    emit_output=lambda output: ctx.emit_shell_output_lines(
                        emit,
                        output,
                    ),
                ),
            )
            if not step_result["ok"]:
                return step_result["error"]

            step_result = _run_runtime_step(
                ctx,
                session,
                emit,
                operation_id,
                "Stop scheduler service",
                lambda: systemd_service_action(
                    session.host,
                    unit=names["service_unit"],
                    action="stop",
                    timeout=45,
                    ignore_failure=True,
                    emit_output=lambda output: ctx.emit_shell_output_lines(
                        emit,
                        output,
                    ),
                ),
            )
            if not step_result["ok"]:
                return step_result["error"]

            step_result = _run_runtime_step(
                ctx,
                session,
                emit,
                operation_id,
                "Remove scheduler units",
                lambda: remove_remote_files(
                    session.host,
                    paths=[
                        names["timer_path"],
                        names["service_path"],
                        names["script_path"],
                    ],
                    timeout=30,
                    emit_output=lambda output: ctx.emit_shell_output_lines(
                        emit,
                        output,
                    ),
                ),
            )
            if not step_result["ok"]:
                return step_result["error"]

            step_result = _run_runtime_step(
                ctx,
                session,
                emit,
                operation_id,
                "Reload systemd daemon",
                lambda: systemd_daemon_reload(
                    session.host,
                    timeout=45,
                    emit_output=lambda output: ctx.emit_shell_output_lines(
                        emit,
                        output,
                    ),
                ),
            )
            if not step_result["ok"]:
                return step_result["error"]

            step_result = _run_runtime_step(
                ctx,
                session,
                emit,
                operation_id,
                "Reset failed scheduler units",
                lambda: systemd_reset_failed(
                    session.host,
                    units=[names["timer_unit"], names["service_unit"]],
                    timeout=45,
                    ignore_failure=True,
                    emit_output=lambda output: ctx.emit_shell_output_lines(
                        emit,
                        output,
                    ),
                ),
            )
            if not step_result["ok"]:
                return step_result["error"]

            return {
                "status": "success",
                "code": "OK",
                "msg": "Scheduled task deleted.",
                "workflow_id": "scheduler",
                "operation_id": operation_id,
                "project_slug": parsed["project_slug"],
                "task_id": parsed["task_id"],
            }

        if operation_id == "task_set_enabled":
            names = _task_unit_names(parsed["project_slug"], parsed["task_id"])
            step_result = _run_runtime_step(
                ctx,
                session,
                emit,
                operation_id,
                "Reload systemd daemon",
                lambda: systemd_daemon_reload(
                    session.host,
                    timeout=45,
                    emit_output=lambda output: ctx.emit_shell_output_lines(
                        emit,
                        output,
                    ),
                ),
            )
            if not step_result["ok"]:
                return step_result["error"]

            if parsed["enabled"]:
                step_result = _run_runtime_step(
                    ctx,
                    session,
                    emit,
                    operation_id,
                    "Enable scheduler timer",
                    lambda: systemd_enable_now(
                        session.host,
                        unit=names["timer_unit"],
                        timeout=45,
                        emit_output=lambda output: ctx.emit_shell_output_lines(
                            emit,
                            output,
                        ),
                    ),
                )
            else:
                step_result = _run_runtime_step(
                    ctx,
                    session,
                    emit,
                    operation_id,
                    "Disable scheduler timer",
                    lambda: systemd_disable_now(
                        session.host,
                        unit=names["timer_unit"],
                        timeout=45,
                        ignore_failure=True,
                        emit_output=lambda output: ctx.emit_shell_output_lines(
                            emit,
                            output,
                        ),
                    ),
                )
            if not step_result["ok"]:
                return step_result["error"]

            status_command = _build_status_command(
                names["timer_unit"],
                names["service_unit"],
            )
            step_result = _run_shell_step(
                ctx,
                session,
                emit,
                operation_id,
                "Read scheduler status",
                status_command,
                timeout=45,
            )
            if not step_result["ok"]:
                return step_result["error"]

            kv = shell_output.parse_key_values(step_result["output"])
            return {
                "status": "success",
                "code": "OK",
                "msg": "Task enabled state updated.",
                "workflow_id": "scheduler",
                "operation_id": operation_id,
                "project_slug": parsed["project_slug"],
                "task_id": parsed["task_id"],
                "enabled": kv.get("ENABLED") == "enabled",
                "timer_active_state": kv.get("ACTIVE"),
                "timer_sub_state": kv.get("SUB_STATE"),
                "service_result": kv.get("SERVICE_RESULT"),
                "last_run_at": _empty_if_not_iso(kv.get("LAST_ISO")),
                "next_run_at": _empty_if_not_iso(kv.get("NEXT_ISO")),
            }

        if operation_id == "task_run_now":
            names = _task_unit_names(parsed["project_slug"], parsed["task_id"])
            if parsed.get("command") and parsed.get("target_type"):
                repair_script_text = _scheduler_target_script_text(
                    parsed["project_slug"],
                    parsed["target_type"],
                    parsed.get("target_ref"),
                    parsed["command"],
                )
                step_result = _run_shell_step(
                    ctx,
                    session,
                    emit,
                    operation_id,
                    "Create scheduler script directory",
                    f"install -d -m 0755 {shlex.quote(names['script_dir'])}",
                    timeout=30,
                )
                if not step_result["ok"]:
                    return step_result["error"]

                step_result = _run_runtime_step(
                    ctx,
                    session,
                    emit,
                    operation_id,
                    "Repair scheduler command script",
                    lambda: write_remote_text_file(
                        session.host,
                        path=names["script_path"],
                        content=repair_script_text,
                        mode="755",
                        timeout=90,
                        emit_output=lambda output: ctx.emit_shell_output_lines(
                            emit,
                            output,
                        ),
                    ),
                )
                if not step_result["ok"]:
                    return step_result["error"]

            run_command = _build_run_now_command(names["service_unit"])
            step_result = _run_shell_step(
                ctx,
                session,
                emit,
                operation_id,
                "Run scheduler task service",
                run_command,
                timeout=180,
            )
            if not step_result["ok"]:
                return step_result["error"]

            kv, run_output_lines = _parse_run_now_output(step_result["output"])
            run_succeeded = _scheduler_run_succeeded(kv)
            run_output = "\n".join(run_output_lines).strip()
            base_response = {
                "workflow_id": "scheduler",
                "operation_id": operation_id,
                "project_slug": parsed["project_slug"],
                "task_id": parsed["task_id"],
                "service_active_state": kv.get("SERVICE_ACTIVE"),
                "service_result": kv.get("SERVICE_RESULT"),
                "exit_code": kv.get("EXIT_CODE"),
                "finished_at": _empty_if_not_iso(kv.get("FINISHED_ISO")),
                "run_succeeded": run_succeeded,
                "run_output_lines": run_output_lines,
                "run_output": run_output,
            }
            if not run_succeeded:
                return {
                    "status": "error",
                    "code": "SCHEDULER_RUN_FAILED",
                    "msg": "Scheduled job failed.",
                    "details": _scheduler_run_failure_details(kv, run_output_lines),
                    **base_response,
                }

            return {
                "status": "success",
                "code": "OK",
                "msg": "Scheduled job completed.",
                **base_response,
            }

        if operation_id == "task_status":
            if parsed.get("repair_tasks"):
                step_result = _run_shell_step(
                    ctx,
                    session,
                    emit,
                    operation_id,
                    "Create scheduler script directory",
                    f"install -d -m 0755 {shlex.quote(_SCHEDULER_SCRIPT_DIR)}",
                    timeout=30,
                )
                if not step_result["ok"]:
                    return step_result["error"]

                for task in parsed["repair_tasks"]:
                    names = _task_unit_names(parsed["project_slug"], task["task_id"])
                    repair_script_text = _scheduler_target_script_text(
                        parsed["project_slug"],
                        task["target_type"],
                        task.get("target_ref"),
                        task["command"],
                    )
                    step_result = _run_runtime_step(
                        ctx,
                        session,
                        emit,
                        operation_id,
                        f"Repair scheduler command script for {task['task_id']}",
                        lambda names=names, repair_script_text=repair_script_text: (
                            write_remote_text_file(
                                session.host,
                                path=names["script_path"],
                                content=repair_script_text,
                                mode="755",
                                timeout=90,
                                emit_output=lambda output: ctx.emit_shell_output_lines(
                                    emit,
                                    output,
                                ),
                            )
                        ),
                    )
                    if not step_result["ok"]:
                        return step_result["error"]

            statuses = []
            for task_id in parsed["task_ids"]:
                names = _task_unit_names(parsed["project_slug"], task_id)
                status_command = _build_status_command(
                    names["timer_unit"],
                    names["service_unit"],
                )
                step_result = _run_shell_step(
                    ctx,
                    session,
                    emit,
                    operation_id,
                    f"Read scheduler status for {task_id}",
                    status_command,
                    timeout=45,
                )
                if not step_result["ok"]:
                    return step_result["error"]

                kv = shell_output.parse_key_values(step_result["output"])
                statuses.append(
                    {
                        "task_id": task_id,
                        "timer_unit": names["timer_unit"],
                        "service_unit": names["service_unit"],
                        "enabled": kv.get("ENABLED") == "enabled",
                        "timer_active_state": kv.get("ACTIVE") or "inactive",
                        "timer_sub_state": kv.get("SUB_STATE") or "dead",
                        "timer_result": kv.get("TIMER_RESULT") or None,
                        "service_active_state": kv.get("SERVICE_ACTIVE") or "inactive",
                        "service_result": kv.get("SERVICE_RESULT") or None,
                        "last_run_at": _empty_if_not_iso(kv.get("LAST_ISO")),
                        "next_run_at": _empty_if_not_iso(kv.get("NEXT_ISO")),
                    }
                )

            return {
                "status": "success",
                "code": "OK",
                "msg": "Scheduler task status read.",
                "workflow_id": "scheduler",
                "operation_id": operation_id,
                "project_slug": parsed["project_slug"],
                "task_statuses": statuses,
            }

        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Unknown scheduler operation: {operation_id}",
            stage="validate_request",
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
