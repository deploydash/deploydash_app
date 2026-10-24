from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

# The `emit` parameter threaded through request handling and workflow
# operations: an opaque sink that `_emit_event`/`emit_event` implementations
# call with a single event dict, or `None` to discard events. Handlers never
# call it directly -- they always go through an `emit_event` helper that
# accepts `emit` and does the actual dict-shaping and `None` check.
EmitFn = Callable[[dict[str, Any]], None]


@dataclass(frozen=True)
class RequestTarget:
    workflow_id: str
    operation_id: str


@dataclass(frozen=True)
class EngineEvent:
    event_type: str
    level: str
    message: str
    data: dict[str, Any]
