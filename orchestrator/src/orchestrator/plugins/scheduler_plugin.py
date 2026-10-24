from functools import partial
from typing import Any

from ..contracts import EmitFn
from ..engine_context import SupportsSchedulerPlugin
from .base import WorkflowPlugin, bind_operation


def build_plugin(
    *,
    operations: dict[str, dict[str, Any]],
    ctx: SupportsSchedulerPlugin,
) -> WorkflowPlugin:
    emit_event = ctx.emit_event
    run_scheduler_runtime_operation = ctx.run_scheduler_runtime_operation
    extract_scheduler_settings_payload = ctx.extract_scheduler_settings_payload

    def handle_describe(
        _data: dict[str, Any], emit: EmitFn | None = None, **_: Any
    ) -> dict[str, Any]:
        response: dict[str, Any] = {
            "status": "success",
            "code": "OK",
            "workflow_id": "scheduler",
            "operation_id": "describe",
            "msg": "Scheduler plan described.",
            "steps": [
                {
                    "id": "scheduler_step_manage_tasks",
                    "title": "Manage project scheduled tasks with systemd timers",
                    "commands": [
                        "Write one-shot systemd service units for container commands",
                        "Write matching systemd timer units",
                        "Enable/disable timers and reload daemon",
                        "Read runtime status from timer and service units",
                    ],
                },
            ],
            "supported_schedule_types": ["every_minutes", "every_hours", "daily_at"],
            "supported_target_types": ["web_app", "worker"],
        }
        emit_event(
            emit,
            "scheduler_plan_ready",
            "Scheduler plan described.",
            data={"step_count": len(response.get("steps", []))},
        )
        return response

    _operation = partial(
        bind_operation,
        ctx,
        runner=run_scheduler_runtime_operation,
        settings_extractor=extract_scheduler_settings_payload,
    )

    handlers = {
        "describe": handle_describe,
        "task_upsert": _operation("task_upsert"),
        "task_delete": _operation("task_delete"),
        "task_set_enabled": _operation("task_set_enabled"),
        "task_run_now": _operation("task_run_now"),
        "task_status": _operation("task_status"),
    }

    return WorkflowPlugin(
        workflow_id="scheduler",
        operations=operations,
        handlers=handlers,
    )
