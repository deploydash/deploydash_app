from typing import Any

from ..contracts import EmitFn
from ..engine_context import EngineCore
from .base import WorkflowPlugin


def build_plugin(
    *,
    operations: dict[str, dict[str, Any]],
    ctx: EngineCore,
) -> WorkflowPlugin:
    emit_event = ctx.emit_event

    def handle_echo(data: dict[str, Any], emit: EmitFn | None = None, **_: Any) -> dict[str, Any]:
        response = {
            "status": "success",
            "action": "echo",
            "workflow_id": "core",
            "operation_id": "echo",
            "data": data.get("data"),
        }
        emit_event(emit, "echo", "Echo action executed")
        return response

    return WorkflowPlugin(
        workflow_id="core",
        operations=operations,
        handlers={
            "echo": handle_echo,
        },
    )
