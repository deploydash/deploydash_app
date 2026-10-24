from collections.abc import Callable
from functools import partial
from typing import Any

from ..contracts import EmitFn
from ..engine_context import SupportsAppPlugin
from .base import WorkflowPlugin, bind_operation, validated_connection


def build_plugin(
    *,
    operations: dict[str, dict[str, Any]],
    ctx: SupportsAppPlugin,
) -> WorkflowPlugin:
    resolve_parts = ctx.resolve_parts
    extract_app_settings_payload = ctx.extract_app_settings_payload
    describe_app = ctx.describe_app
    emit_event = ctx.emit_event
    prepare_app_deploy_key = ctx.prepare_app_deploy_key
    deploy_application = ctx.deploy_application
    run_app_runtime_operation = ctx.run_app_runtime_operation
    resolve_dry_run = ctx.resolve_dry_run
    payload_params = ctx.payload_params
    normalize_runtime_log_tail = ctx.normalize_runtime_log_tail

    def handle_describe(
        data: dict[str, Any], emit: EmitFn | None = None, **_: Any
    ) -> dict[str, Any]:
        response: dict[str, Any] = describe_app(
            parts=resolve_parts(data),
            raw_data=extract_app_settings_payload(data),
        )
        if response.get("status") == "success":
            emit_event(
                emit,
                "app_plan_ready",
                "Web app deploy plan described.",
                data={
                    "parts": response.get("parts", []),
                    "step_count": len(response.get("steps", [])),
                },
            )
        else:
            emit_event(
                emit,
                "validation_error",
                response.get("msg", "Invalid web app deploy plan request"),
                level="error",
            )
        return response

    def handle_prepare_key(
        data: dict[str, Any],
        emit: EmitFn | None = None,
        is_cancelled: Callable[[], bool] | None = None,
        **_: Any,
    ) -> dict[str, Any]:
        connection_data, error = validated_connection(data, ctx)
        if error is not None:
            return error
        assert connection_data is not None

        result: dict[str, Any] = prepare_app_deploy_key(
            ip=connection_data["ip"],
            username=connection_data["username"],
            password=connection_data["password"],
            key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
            port=connection_data["port"],
            dry_run=resolve_dry_run(data, False),
            raw_data=extract_app_settings_payload(data),
            emit=emit,
            is_cancelled=is_cancelled,
        )
        return result

    def handle_run(
        data: dict[str, Any],
        emit: EmitFn | None = None,
        is_cancelled: Callable[[], bool] | None = None,
        **_: Any,
    ) -> dict[str, Any]:
        connection_data, error = validated_connection(data, ctx)
        if error is not None:
            return error
        assert connection_data is not None

        result: dict[str, Any] = deploy_application(
            ip=connection_data["ip"],
            username=connection_data["username"],
            password=connection_data["password"],
            key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
            port=connection_data["port"],
            parts=resolve_parts(data),
            dry_run=resolve_dry_run(data, False),
            raw_data=extract_app_settings_payload(data),
            emit=emit,
            is_cancelled=is_cancelled,
        )
        return result

    def _tail_from_params(data: dict[str, Any]) -> int:
        params = payload_params(data)
        candidate = (
            params.get("log_tail_lines")
            if "log_tail_lines" in params
            else params.get("tail_lines", params.get("tail"))
        )
        return normalize_runtime_log_tail(candidate)

    def _string_param(data: dict[str, Any], name: str) -> str | None:
        candidate = payload_params(data).get(name)
        if not isinstance(candidate, str):
            return None
        return candidate.strip() or None

    _app_operation = partial(
        bind_operation,
        ctx,
        runner=run_app_runtime_operation,
        settings_extractor=extract_app_settings_payload,
    )
    _worker_operation = partial(
        _app_operation,
        extra_from_data=lambda data: {"worker_id": _string_param(data, "worker_id")},
    )

    handlers = {
        "describe": handle_describe,
        "prepare_key": handle_prepare_key,
        "run": handle_run,
        "list_releases": _app_operation("list_releases"),
        "rollback": _app_operation(
            "rollback",
            extra_from_data=lambda data: {
                "release_id": _string_param(data, "release_id"),
            },
        ),
        "disconnect": _app_operation("disconnect"),
        "resource_usage": _app_operation("resource_usage"),
        "runtime_logs": _app_operation(
            "runtime_logs",
            extra_from_data=lambda data: {"log_tail_lines": _tail_from_params(data)},
        ),
        "exec": _app_operation(
            "exec",
            extra_from_data=lambda data: {
                "command": payload_params(data).get("command"),
                "timeout_seconds": payload_params(data).get("timeout_seconds"),
            },
        ),
        "sqlite_volume_ensure": _app_operation("sqlite_volume_ensure"),
        "sqlite_volume_status": _app_operation("sqlite_volume_status"),
        "sqlite_volume_delete": _app_operation("sqlite_volume_delete"),
        "workers_apply": _app_operation("workers_apply"),
        "workers_precheck": _app_operation("workers_precheck"),
        "workers_status": _app_operation("workers_status"),
        "worker_start": _worker_operation("worker_start"),
        "worker_stop": _worker_operation("worker_stop"),
        "worker_restart": _worker_operation("worker_restart"),
        "worker_logs": _app_operation(
            "worker_logs",
            extra_from_data=lambda data: {
                "log_tail_lines": _tail_from_params(data),
                "worker_id": _string_param(data, "worker_id"),
            },
        ),
    }

    return WorkflowPlugin(
        workflow_id="app",
        operations=operations,
        handlers=handlers,
    )
