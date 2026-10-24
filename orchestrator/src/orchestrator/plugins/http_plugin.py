from collections.abc import Callable
from functools import partial
from typing import Any

from ..contracts import EmitFn
from ..engine_context import SupportsHttpPlugin
from .base import HandlerFn, WorkflowPlugin, bind_operation, validated_connection


def build_plugin(
    *,
    operations: dict[str, dict[str, Any]],
    ctx: SupportsHttpPlugin,
) -> WorkflowPlugin:
    resolve_parts = ctx.resolve_parts
    extract_http_settings_payload = ctx.extract_http_settings_payload
    describe_http = ctx.describe_http
    emit_event = ctx.emit_event
    setup_http_gateway = ctx.setup_http_gateway
    resolve_dry_run = ctx.resolve_dry_run
    run_http_runtime_operation = ctx.run_http_runtime_operation

    def handle_describe(
        data: dict[str, Any], emit: EmitFn | None = None, **_: Any
    ) -> dict[str, Any]:
        response: dict[str, Any] = describe_http(
            parts=resolve_parts(data),
            raw_data=extract_http_settings_payload(data),
        )
        if response.get("status") == "success":
            emit_event(
                emit,
                "http_plan_ready",
                "HTTP plan described.",
                data={
                    "parts": response.get("parts", []),
                    "step_count": len(response.get("steps", [])),
                },
            )
        else:
            emit_event(
                emit,
                "validation_error",
                response.get("msg", "Invalid HTTP plan request"),
                level="error",
            )
        return response

    def _gateway_setup(
        parts_for: Callable[[dict[str, Any]], Any],
        *,
        dry_run_default: bool,
    ) -> HandlerFn:
        """Build a handler that applies the gateway with a chosen part list.

        `run`, `service_enable` and `service_configure` were three ~20-line
        copies of one `setup_http_gateway` call differing only in these two
        values.
        """

        def handler(
            data: dict[str, Any],
            emit: EmitFn | None = None,
            is_cancelled: Callable[[], bool] | None = None,
            **_: Any,
        ) -> dict[str, Any]:
            connection_data, error = validated_connection(data, ctx)
            if error is not None:
                return error
            assert connection_data is not None

            result: dict[str, Any] = setup_http_gateway(
                ip=connection_data["ip"],
                username=connection_data["username"],
                password=connection_data["password"],
                key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
                port=connection_data["port"],
                parts=parts_for(data),
                dry_run=resolve_dry_run(data, dry_run_default),
                raw_data=extract_http_settings_payload(data),
                emit=emit,
                is_cancelled=is_cancelled,
            )
            return result

        return handler

    _service_operation = partial(
        bind_operation,
        ctx,
        runner=run_http_runtime_operation,
        settings_extractor=extract_http_settings_payload,
    )

    return WorkflowPlugin(
        workflow_id="http",
        operations=operations,
        handlers={
            "describe": handle_describe,
            "run": _gateway_setup(resolve_parts, dry_run_default=True),
            "service_enable": _gateway_setup(
                lambda data: resolve_parts(data) or ["part1", "part2"],
                dry_run_default=False,
            ),
            "service_configure": _gateway_setup(
                lambda _data: ["part1", "part2"],
                dry_run_default=False,
            ),
            "service_start": _service_operation("service_start"),
            "service_stop": _service_operation("service_stop"),
            "service_restart": _service_operation("service_restart"),
            "service_status": _service_operation("service_status"),
        },
    )
