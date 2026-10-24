from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from ..contracts import EmitFn
from ..engine_context import EngineCore

HandlerFn = Callable[..., dict[str, Any]]


@dataclass(frozen=True)
class WorkflowPlugin:
    workflow_id: str
    operations: dict[str, dict[str, Any]]
    handlers: dict[str, HandlerFn]


def validated_connection(
    data: dict[str, Any],
    ctx: EngineCore,
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    """Return the normalized connection payload, or the error to return instead.

    Exactly one of the two is not `None`. Eight byte-identical closures did
    this before T-3.8.2, one per plugin; taking `ctx` as an argument is what
    lets one function serve all of them without any plugin having to bind
    the two callables itself.
    """
    connection_data = ctx.extract_connection_payload(data)
    error = ctx.connection_validation_error(connection_data)
    if error is not None:
        return None, error
    return connection_data, None


def runtime_operation(
    ctx: EngineCore,
    data: dict[str, Any],
    operation_id: str,
    *,
    runner: Callable[..., dict[str, Any]],
    settings_extractor: Callable[[dict[str, Any]], dict[str, Any]],
    emit: EmitFn | None = None,
    is_cancelled: Callable[[], bool] | None = None,
    **extra: Any,
) -> dict[str, Any]:
    """Run one workflow runtime operation against a validated connection.

    The one dispatcher. Six near-identical copies of this preceded it under
    three names -- `_runtime_operation`, `_run_runtime_operation` and
    `_project_operation` -- two of them twenty-five lines apart in the same
    file. Taking `runner` and `settings_extractor` as arguments is what lets
    one function serve every workflow; `extra` carries the per-workflow
    controls (log tail, worker id, release id, command, timeout) that only
    the app workflow passes.
    """
    connection_data, error = validated_connection(data, ctx)
    if error is not None:
        return error
    assert connection_data is not None

    result: dict[str, Any] = runner(
        operation_id=operation_id,
        ip=connection_data["ip"],
        username=connection_data["username"],
        password=connection_data["password"],
        key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
        port=connection_data["port"],
        dry_run=ctx.resolve_dry_run(data, False),
        raw_data=settings_extractor(data),
        emit=emit,
        is_cancelled=is_cancelled,
        **extra,
    )
    return result


def bind_operation(
    ctx: EngineCore,
    operation_id: str,
    *,
    runner: Callable[..., dict[str, Any]],
    settings_extractor: Callable[[dict[str, Any]], dict[str, Any]],
    extra_from_data: Callable[[dict[str, Any]], dict[str, Any]] | None = None,
) -> HandlerFn:
    """Return the handler for one operation id.

    The one binder. Five copies preceded it, under four names.

    `extra_from_data` is what keeps it one rather than two: the web-app
    workflow reads a worker id, release id, command or log tail out of the
    request before dispatching, and every other workflow reads nothing.
    """

    def handler(
        data: dict[str, Any],
        emit: EmitFn | None = None,
        is_cancelled: Callable[[], bool] | None = None,
        **_: Any,
    ) -> dict[str, Any]:
        extra = extra_from_data(data) if extra_from_data is not None else {}
        return runtime_operation(
            ctx,
            data,
            operation_id,
            runner=runner,
            settings_extractor=settings_extractor,
            emit=emit,
            is_cancelled=is_cancelled,
            **extra,
        )

    return handler
