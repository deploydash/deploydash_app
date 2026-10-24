# ruff: noqa: F403, F405

from ._shared import *

_DOCKER_STORAGE_TARGETS = {
    "unused_images": {
        "label": "unused Docker images",
        "command": "docker image prune -af",
        "storage_key": "images",
    },
    "build_cache": {
        "label": "the Docker build cache",
        "command": "docker builder prune -af",
        "storage_key": "build_cache",
    },
}


def _parse_docker_size_bytes(raw_value):
    if raw_value is None:
        return None
    text = str(raw_value).strip()
    if not text:
        return None
    text = text.split("(", 1)[0].strip()
    match = re.match(r"^([0-9]+(?:\.[0-9]+)?)\s*([kmgtp]?b)$", text, re.IGNORECASE)
    if not match:
        return None

    value = float(match.group(1))
    unit = match.group(2).lower()
    multipliers = {
        "b": 1,
        "kb": 1000,
        "mb": 1000**2,
        "gb": 1000**3,
        "tb": 1000**4,
        "pb": 1000**5,
    }
    return round(value * multipliers[unit])


# Why: single owner of the `docker system df` row-type -> storage-key mapping.
# Separate from _DOCKER_STORAGE_TARGETS above, whose keys are prune-target
# names ("unused_images"/"build_cache"), not df row-type strings.
_STORAGE_KEY_BY_ROW_TYPE = {"images": "images", "build cache": "build_cache"}


def _docker_storage_row(row):
    # Why: single owner of the storage row -> four-field dict mapping.
    return {
        "size_bytes": _parse_docker_size_bytes(row.get("Size")),
        "reclaimable_bytes": _parse_docker_size_bytes(row.get("Reclaimable")),
        "total_count": _parse_positive_int(row.get("TotalCount")),
        "active_count": _parse_positive_int(row.get("Active")),
    }


def _parse_docker_storage_status_output(output):
    stdout_lines = getattr(output, "stdout_lines", None) or []
    storage = {
        "checked_at": datetime.now(UTC).isoformat(),
        "images": {},
        "build_cache": {},
    }

    for raw_line in stdout_lines:
        line = str(raw_line).strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(row, dict):
            continue

        row_type = str(row.get("Type", "")).strip().lower()
        storage_key = _STORAGE_KEY_BY_ROW_TYPE.get(row_type)
        if storage_key is not None:
            storage[storage_key] = _docker_storage_row(row)

    return storage


def _build_server_docker_storage_status_command():
    return (
        "command -v docker >/dev/null 2>&1 || "
        "(echo 'Docker is not available on this server yet.' >&2; exit 1); "
        "docker system df --format '{{json .}}'"
    )


def _read_server_docker_storage_status(ctx, session, emit=None):
    status, output = session.host.run_shell_command(
        _build_server_docker_storage_status_command(),
        _timeout=20,
        _sudo=True,
    )
    ctx.emit_shell_output_lines(emit, output)
    if not status:
        return {
            "ok": False,
            "error": ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Couldn't read Docker storage usage.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(output) or "remote command failed",
            ),
        }
    return {
        "ok": True,
        "storage": _parse_docker_storage_status_output(output),
    }


def run_server_docker_storage_status_operation(
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
            "msg": "Docker storage status plan ready",
            "operation_id": "docker_storage_status",
            "actions": [
                "Verify Docker is available",
                "Read Docker image and build cache disk usage",
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
            "server_docker_storage_status_started",
            "Collecting Docker storage usage.",
        )
        storage_result = _read_server_docker_storage_status(ctx, session, emit=emit)
        if not storage_result["ok"]:
            return storage_result["error"]
        return {
            "status": "success",
            "code": "OK",
            "msg": "Docker storage usage refreshed.",
            "operation_id": "docker_storage_status",
            "storage": storage_result["storage"],
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


def run_server_docker_storage_prune_operation(
    ctx,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    target=None,
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

    target_key = str(target or "").strip()
    target_config = _DOCKER_STORAGE_TARGETS.get(target_key)
    if target_config is None:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            "Choose either unused_images or build_cache for Docker cleanup.",
            stage="validate_request",
        )

    if dry_run:
        return {
            "status": "success",
            "code": "OK",
            "msg": "Docker cleanup plan ready",
            "operation_id": "docker_storage_prune",
            "target": target_key,
            "actions": [
                "Read current Docker storage usage",
                f"Remove {target_config['label']}",
                "Read Docker storage usage again",
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
        before_result = _read_server_docker_storage_status(ctx, session, emit=emit)
        if not before_result["ok"]:
            return before_result["error"]

        ctx.emit_event(
            emit,
            "server_docker_storage_prune_started",
            f"Removing {target_config['label']}.",
            data={"target": target_key},
        )
        status, output = session.host.run_shell_command(
            target_config["command"],
            _timeout=120,
            _sudo=True,
        )
        ctx.emit_shell_output_lines(emit, output)
        if not status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                f"Couldn't remove {target_config['label']}.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(output) or "remote command failed",
            )

        after_result = _read_server_docker_storage_status(ctx, session, emit=emit)
        if not after_result["ok"]:
            return after_result["error"]

        storage_key = target_config["storage_key"]
        before_storage = before_result["storage"].get(storage_key, {})
        after_storage = after_result["storage"].get(storage_key, {})
        before_bytes = before_storage.get("size_bytes")
        after_bytes = after_storage.get("size_bytes")
        reclaimed_bytes = None
        if isinstance(before_bytes, int) and isinstance(after_bytes, int):
            reclaimed_bytes = max(0, before_bytes - after_bytes)

        return {
            "status": "success",
            "code": "OK",
            "msg": f"Finished removing {target_config['label']}.",
            "operation_id": "docker_storage_prune",
            "target": target_key,
            "reclaimed_bytes": reclaimed_bytes,
            "storage_before": before_result["storage"],
            "storage_after": after_result["storage"],
            "storage": after_result["storage"],
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
