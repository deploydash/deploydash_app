from collections.abc import Callable
from typing import Any

from ..contracts import EmitFn
from ..engine_context import SupportsDnsPlugin
from .base import WorkflowPlugin, validated_connection


def build_plugin(
    *,
    operations: dict[str, dict[str, Any]],
    ctx: SupportsDnsPlugin,
) -> WorkflowPlugin:
    resolve_parts = ctx.resolve_parts
    extract_dns_settings_payload = ctx.extract_dns_settings_payload
    describe_dns = ctx.describe_dns
    emit_event = ctx.emit_event
    setup_dns_server = ctx.setup_dns_server
    resolve_dry_run = ctx.resolve_dry_run

    def handle_describe(
        data: dict[str, Any], emit: EmitFn | None = None, **_: Any
    ) -> dict[str, Any]:
        response: dict[str, Any] = describe_dns(
            parts=resolve_parts(data),
            raw_data=extract_dns_settings_payload(data),
        )
        if response.get("status") == "success":
            emit_event(
                emit,
                "dns_plan_ready",
                "DNS plan described.",
                data={
                    "parts": response.get("parts", []),
                    "step_count": len(response.get("steps", [])),
                },
            )
        else:
            emit_event(
                emit,
                "validation_error",
                response.get("msg", "Invalid DNS plan request"),
                level="error",
            )
        return response

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

        result: dict[str, Any] = setup_dns_server(
            ip=connection_data["ip"],
            username=connection_data["username"],
            password=connection_data["password"],
            key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
            port=connection_data["port"],
            parts=resolve_parts(data),
            dry_run=resolve_dry_run(data, True),
            raw_data=extract_dns_settings_payload(data),
            emit=emit,
            is_cancelled=is_cancelled,
        )
        return result

    return WorkflowPlugin(
        workflow_id="dns",
        operations=operations,
        handlers={
            "describe": handle_describe,
            "run": handle_run,
        },
    )
