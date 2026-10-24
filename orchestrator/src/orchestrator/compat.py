from collections.abc import Callable
from typing import Any

from .contracts import RequestTarget


def resolve_request_target(
    payload: dict[str, Any],
    *,
    error_result: Callable[..., dict[str, Any]],
) -> tuple[RequestTarget | None, dict[str, Any] | None]:
    """`run_workflow` is the only action the engine accepts (T-1.5.2).

    The five legacy action aliases (`echo`, `check_server`,
    `refresh_server_host_key`, `describe_setup`, `setup_server`) were
    backwards-compatibility shims for a client that predates every user --
    deleted along with the alias table that mapped them, not carried
    forward.
    """
    action = payload.get("action")
    if action != "run_workflow":
        return None, None

    workflow_id = payload.get("workflow_id")
    operation_id = payload.get("operation_id")
    if not isinstance(workflow_id, str) or not workflow_id.strip():
        return None, error_result(
            "ENGINE_VALIDATION_ERROR",
            "workflow_id is required for run_workflow action.",
            stage="validate_request",
        )
    if not isinstance(operation_id, str) or not operation_id.strip():
        return None, error_result(
            "ENGINE_VALIDATION_ERROR",
            "operation_id is required for run_workflow action.",
            stage="validate_request",
        )
    return RequestTarget(workflow_id.strip(), operation_id.strip()), None
