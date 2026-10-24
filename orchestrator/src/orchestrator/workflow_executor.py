from datetime import UTC, datetime

from .failure_evidence import (
    FAILURE_EVIDENCE_FIELD,
    FailureEvidenceInput,
    prepare_error_extra,
    select_failure_evidence,
)


def _error_result(code, msg, stage, details=None, extra=None):
    payload = {
        "status": "error",
        "code": code,
        "msg": msg,
        "stage": stage,
        "details": details,
    }
    if extra:
        payload.update(prepare_error_extra(extra))
    return payload


def _log_event(level, step, message):
    return {
        "level": level,
        "step": step,
        "message": message,
        "ts": datetime.now(UTC).isoformat(),
    }


def step_action_payloads(step):
    action_objects = getattr(step, "actions", None) or []
    payloads = []
    for action in action_objects:
        action_id = getattr(action, "id", None)
        if not isinstance(action_id, str) or not action_id.strip():
            continue
        payload = action.to_dict()
        payload["failure_phase"] = getattr(action, "failure_phase", "unknown")
        payloads.append(payload)

    if payloads:
        return payloads

    return [
        {
            "id": f"{step.id}_action_default",
            "label": step.title,
            "description": "Execute configured workflow action",
            "failure_phase": "unknown",
        },
    ]


def _failed_action_payload(step, op_result):
    actions = step_action_payloads(step)
    failed_action_id = op_result.get("failed_action_id")
    if isinstance(failed_action_id, str) and failed_action_id.strip():
        for action in actions:
            if action["id"] == failed_action_id:
                return action
    return actions[0]


def _operation_details(op_result):
    failed_operation = op_result.get("failed_operation") or {}
    stderr_lines = failed_operation.get("stderr") or []
    stdout_lines = failed_operation.get("stdout") or []

    if stderr_lines:
        return "\n".join(stderr_lines)
    if stdout_lines:
        return "\n".join(stdout_lines)
    return "No operation output captured."


def _operation_failure_evidence(op_result, failed_action):
    """Select evidence only from the failed action's bounded operation record."""
    failed_operation = op_result.get("failed_operation") or {}
    stderr_lines = tuple(failed_operation.get("stderr") or ())
    stdout_lines = tuple(failed_operation.get("stdout") or ())
    phase = "unknown"
    if failed_action is not None:
        candidate_phase = failed_action.get("failure_phase")
        if isinstance(candidate_phase, str):
            phase = candidate_phase
    return select_failure_evidence(
        FailureEvidenceInput(
            phase=phase,
            source="failed_operation" if stderr_lines or stdout_lines else "none",
            stderr_lines=stderr_lines,
            stdout_lines=stdout_lines,
            failed_step_id=op_result.get("step_id"),
            failed_action_id=(failed_action.get("id") if failed_action is not None else None),
        )
    )


def _unavailable_engine_evidence():
    """State explicitly that execution ended before an operation boundary was reached."""
    return select_failure_evidence(
        FailureEvidenceInput(
            phase="engine",
            source="none",
            boundary_reached=False,
        )
    )


def _emit_operation_output_lines(op_result, emit_event):
    if not callable(emit_event):
        return

    step_id = op_result.get("step_id")
    title = op_result.get("title", step_id)
    part = op_result.get("part")

    stdout_lines = op_result.get("stdout") or []
    stderr_lines = op_result.get("stderr") or []

    for line in stdout_lines:
        text = str(line).strip()
        if not text:
            continue
        emit_event(
            "pyinfra_operation_stdout",
            f"{title} | {text}",
            data={
                "step_id": step_id,
                "part": part,
                "stream": "stdout",
            },
        )

    for line in stderr_lines:
        text = str(line).strip()
        if not text:
            continue
        emit_event(
            "pyinfra_operation_stderr",
            f"{title} | {text}",
            level="warning",
            data={
                "step_id": step_id,
                "part": part,
                "stream": "stderr",
            },
        )


def run_plan_dry(
    *,
    steps,
    parts,
    summary_data,
    emit_event=None,
    is_cancelled=None,
    message="Workflow plan ready",
):
    logs = []
    completed_step_ids = []
    scheduled_action_ids = []
    completed_action_ids = []

    for step in steps:
        step_actions = step_action_payloads(step)
        step_action_ids = [action["id"] for action in step_actions]
        scheduled_action_ids.extend(step_action_ids)

        for action in step_actions:
            if callable(emit_event):
                emit_event(
                    "action_queued",
                    f"Queued action: {action['label']}",
                    data={
                        "step_id": step.id,
                        "part": step.part,
                        "action_id": action["id"],
                        "action_label": action["label"],
                        "action_description": action["description"],
                    },
                )

        if callable(is_cancelled) and is_cancelled():
            if callable(emit_event):
                emit_event(
                    "task_cancelled",
                    "Task cancelled during workflow execution.",
                    level="warning",
                    data={"completed_step_ids": completed_step_ids},
                )
            return _error_result(
                "ENGINE_TASK_CANCELLED",
                "Task cancelled by user",
                stage="dry_run",
                extra={
                    "parts": parts,
                    "steps": [item.to_dict() for item in steps],
                    "completed_step_ids": completed_step_ids,
                    "scheduled_action_ids": scheduled_action_ids,
                    "completed_action_ids": completed_action_ids,
                    "logs": logs,
                },
            )

        logs.append(_log_event("info", step.id, f"Starting: {step.title}"))
        if callable(emit_event):
            emit_event(
                "step_start",
                f"Starting: {step.title}",
                data={"step_id": step.id, "part": step.part},
            )
        logs.append(_log_event("info", step.id, "Dry-run: commands not executed"))
        if callable(emit_event):
            emit_event(
                "step_noop",
                f"Dry-run: {step.title}",
                data={"step_id": step.id},
            )
        completed_step_ids.append(step.id)
        completed_action_ids.extend(step_action_ids)
        for action in step_actions:
            if callable(emit_event):
                emit_event(
                    "action_done",
                    f"Completed action: {action['label']}",
                    data={
                        "step_id": step.id,
                        "part": step.part,
                        "action_id": action["id"],
                        "action_label": action["label"],
                        "action_description": action["description"],
                    },
                )
        logs.append(_log_event("info", step.id, f"Completed: {step.title}"))
        if callable(emit_event):
            emit_event(
                "step_done",
                f"Completed: {step.title}",
                data={"step_id": step.id, "part": step.part},
            )

    return {
        "status": "success",
        "msg": message,
        "code": "OK",
        "parts": parts,
        "dry_run": True,
        "steps": [step.to_dict() for step in steps],
        "completed_step_ids": completed_step_ids,
        "scheduled_action_ids": scheduled_action_ids,
        "completed_action_ids": completed_action_ids,
        "logs": logs,
        **(summary_data or {}),
    }


def run_plan_execute(
    *,
    session,
    steps,
    parts,
    summary_data,
    emit_event=None,
    is_cancelled=None,
    message="Workflow completed",
    failure_message_prefix="Execution failed at",
):
    logs = []
    completed_step_ids = []
    scheduled_action_ids = []
    completed_action_ids = []
    step_lookup = {step.id: step for step in steps}

    for step in steps:
        step_actions = step_action_payloads(step)
        for action in step_actions:
            scheduled_action_ids.append(action["id"])
            if callable(emit_event):
                emit_event(
                    "action_queued",
                    f"Queued action: {action['label']}",
                    data={
                        "step_id": step.id,
                        "part": step.part,
                        "action_id": action["id"],
                        "action_label": action["label"],
                        "action_description": action["description"],
                    },
                )

        if callable(is_cancelled) and is_cancelled():
            if callable(emit_event):
                emit_event(
                    "task_cancelled",
                    "Task cancelled before operation registration.",
                    level="warning",
                    data={"completed_step_ids": completed_step_ids},
                )
            return _error_result(
                "ENGINE_TASK_CANCELLED",
                "Task cancelled by user",
                stage="prepare_operations",
                extra={
                    "parts": parts,
                    "steps": [item.to_dict() for item in steps],
                    "completed_step_ids": completed_step_ids,
                    "scheduled_action_ids": scheduled_action_ids,
                    "completed_action_ids": completed_action_ids,
                    "logs": logs,
                },
            )

        logs.append(_log_event("info", step.id, f"Queued: {step.title}"))
        if callable(emit_event):
            emit_event(
                "step_queued",
                f"Queued: {step.title}",
                data={"step_id": step.id, "part": step.part},
            )

    try:
        session.register_steps_deploy(steps)
    except Exception as exc:
        details = str(exc).strip()
        if callable(emit_event):
            emit_event("runtime_error", details, level="error")
        return _error_result(
            "ENGINE_RUNTIME_ERROR",
            "Failed to prepare pyinfra deploy operations.",
            stage="prepare_operations",
            details=details,
            extra={
                "parts": parts,
                "steps": [item.to_dict() for item in steps],
                "completed_step_ids": completed_step_ids,
                "scheduled_action_ids": scheduled_action_ids,
                "completed_action_ids": completed_action_ids,
                "logs": logs,
                FAILURE_EVIDENCE_FIELD: _unavailable_engine_evidence(),
            },
        )

    execution = session.execute()

    for op_result in execution.get("operations", []):
        step_id = op_result.get("step_id")
        title = op_result.get("title", step_id)
        part = op_result.get("part")
        success = bool(op_result.get("success"))
        _emit_operation_output_lines(op_result, emit_event)

        if success:
            completed_step_ids.append(step_id)
            step = step_lookup.get(step_id)
            if step is not None:
                step_actions = step_action_payloads(step)
                for action in step_actions:
                    completed_action_ids.append(action["id"])
                    if callable(emit_event):
                        emit_event(
                            "action_done",
                            f"Completed action: {action['label']}",
                            data={
                                "step_id": step.id,
                                "part": step.part,
                                "action_id": action["id"],
                                "action_label": action["label"],
                                "action_description": action["description"],
                            },
                        )
            logs.append(_log_event("info", step_id, f"Completed: {title}"))
            if callable(emit_event):
                emit_event(
                    "step_done",
                    f"Completed: {title}",
                    data={"step_id": step_id, "part": part},
                )
            continue

        details = _operation_details(op_result)
        logs.append(_log_event("error", step_id, f"Failed: {title}"))
        if callable(emit_event):
            emit_event(
                "step_error",
                f"Failed: {title}",
                level="error",
                data={
                    "step_id": step_id,
                    "part": part,
                    "details": details,
                },
            )
        step = step_lookup.get(step_id)
        failed_action = None
        if step is not None:
            failed_action = _failed_action_payload(step, op_result)
            if callable(emit_event):
                emit_event(
                    "action_error",
                    f"Failed action: {failed_action['label']}",
                    level="error",
                    data={
                        "step_id": step.id,
                        "part": step.part,
                        "action_id": failed_action["id"],
                        "action_label": failed_action["label"],
                        "action_description": failed_action["description"],
                        "details": details,
                    },
                )
        return _error_result(
            "ENGINE_OPERATION_FAILED",
            f"{failure_message_prefix} {step_id}",
            stage="execute_operations",
            details=details,
            extra={
                "failed_step_id": step_id,
                **({"failed_action_id": failed_action["id"]} if failed_action is not None else {}),
                "parts": parts,
                "steps": [item.to_dict() for item in steps],
                "completed_step_ids": completed_step_ids,
                "scheduled_action_ids": scheduled_action_ids,
                "completed_action_ids": completed_action_ids,
                "logs": logs,
                FAILURE_EVIDENCE_FIELD: _operation_failure_evidence(
                    op_result,
                    failed_action,
                ),
            },
        )

    run_error = execution.get("run_error")
    if run_error:
        if callable(emit_event):
            emit_event("runtime_error", run_error, level="error")
        return _error_result(
            "ENGINE_RUNTIME_ERROR",
            "Execution failed in runtime.",
            stage="execute_operations",
            details=run_error,
            extra={
                "parts": parts,
                "steps": [item.to_dict() for item in steps],
                "completed_step_ids": completed_step_ids,
                "scheduled_action_ids": scheduled_action_ids,
                "completed_action_ids": completed_action_ids,
                "logs": logs,
                FAILURE_EVIDENCE_FIELD: _unavailable_engine_evidence(),
            },
        )

    return {
        "status": "success",
        "msg": message,
        "code": "OK",
        "parts": parts,
        "dry_run": False,
        "steps": [step.to_dict() for step in steps],
        "completed_step_ids": completed_step_ids,
        "scheduled_action_ids": scheduled_action_ids,
        "completed_action_ids": completed_action_ids,
        "logs": logs,
        **(summary_data or {}),
    }
