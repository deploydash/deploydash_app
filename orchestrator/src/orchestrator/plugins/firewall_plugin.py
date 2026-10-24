from functools import partial
from typing import Any

from ..contracts import EmitFn
from ..engine_context import SupportsFirewallPlugin
from .base import WorkflowPlugin, bind_operation


def build_plugin(
    *,
    operations: dict[str, dict[str, Any]],
    ctx: SupportsFirewallPlugin,
) -> WorkflowPlugin:
    emit_event = ctx.emit_event
    run_firewall_runtime_operation = ctx.run_firewall_runtime_operation
    extract_firewall_settings_payload = ctx.extract_firewall_settings_payload

    def handle_describe(
        _data: dict[str, Any], emit: EmitFn | None = None, **_: Any
    ) -> dict[str, Any]:
        response: dict[str, Any] = {
            "status": "success",
            "code": "OK",
            "workflow_id": "firewall",
            "operation_id": "describe",
            "msg": "Firewall plan described.",
            "steps": [
                {
                    "id": "firewall_step_manage_ingress",
                    "title": (
                        "Manage dual-stack host and Docker ingress with staged rollback safety"
                    ),
                    "commands": [
                        "List host listeners and Docker published ports",
                        "Apply Deploy Dash managed IPv4 and IPv6 INPUT and DOCKER-USER chains",
                        "Enforce the active SSH port and locked HTTP/HTTPS ports",
                        (
                            "Use staged apply with timed rollback, commit durable "
                            "rules for reboot, and rollback actions"
                        ),
                    ],
                },
            ],
            "locked_ports": [80, 443],
            "supported_operations": [
                "status",
                "scan_open_ports",
                "apply_staged",
                "commit",
                "rollback",
            ],
        }
        emit_event(
            emit,
            "firewall_plan_ready",
            "Firewall plan described.",
            data={"step_count": len(response.get("steps", []))},
        )
        return response

    _operation = partial(
        bind_operation,
        ctx,
        runner=run_firewall_runtime_operation,
        settings_extractor=extract_firewall_settings_payload,
    )

    handlers = {
        "describe": handle_describe,
        "status": _operation("status"),
        "scan_open_ports": _operation("scan_open_ports"),
        "apply_staged": _operation("apply_staged"),
        "commit": _operation("commit"),
        "rollback": _operation("rollback"),
    }

    return WorkflowPlugin(
        workflow_id="firewall",
        operations=operations,
        handlers=handlers,
    )
