import json
from collections.abc import Callable
from typing import Any

from .contracts import EmitFn
from .runtime import EngineRuntime

_DEFAULT_RUNTIME: EngineRuntime | None = None


def build_runtime(
    *,
    workflow_registry_getter: Callable[[], dict[str, dict[str, dict[str, Any]]]],
    workflow_handlers_getter: Callable[[], dict[tuple[str, str], Any]],
    error_result: Callable[..., dict[str, Any]],
    emit_event: Callable[..., None],
    unimplemented_handler: Callable[[str, str], dict[str, Any]],
) -> EngineRuntime:
    return EngineRuntime(
        workflow_registry_getter=workflow_registry_getter,
        workflow_handlers_getter=workflow_handlers_getter,
        error_result=error_result,
        emit_event=emit_event,
        unimplemented_handler=unimplemented_handler,
    )


def set_default_runtime(runtime: EngineRuntime) -> EngineRuntime:
    global _DEFAULT_RUNTIME
    _DEFAULT_RUNTIME = runtime
    return runtime


def get_default_runtime() -> EngineRuntime | None:
    return _DEFAULT_RUNTIME


def build_default_runtime(
    *,
    workflow_registry_getter: Callable[[], dict[str, dict[str, dict[str, Any]]]],
    workflow_handlers_getter: Callable[[], dict[tuple[str, str], Any]],
    error_result: Callable[..., dict[str, Any]],
    emit_event: Callable[..., None],
    unimplemented_handler: Callable[[str, str], dict[str, Any]],
) -> EngineRuntime:
    runtime = build_runtime(
        workflow_registry_getter=workflow_registry_getter,
        workflow_handlers_getter=workflow_handlers_getter,
        error_result=error_result,
        emit_event=emit_event,
        unimplemented_handler=unimplemented_handler,
    )
    return set_default_runtime(runtime)


def handle_request(
    json_str: str,
    emit: EmitFn | None = None,
    is_cancelled: Callable[[], bool] | None = None,
) -> str:
    runtime = get_default_runtime()
    if runtime is None:
        return json.dumps(
            {
                "status": "error",
                "code": "ENGINE_RUNTIME_NOT_CONFIGURED",
                "msg": "orchestrator default runtime is not configured.",
                "stage": "dispatch",
            }
        )
    return runtime.handle_request_json(
        json_str,
        emit=emit,
        is_cancelled=is_cancelled,
    )
