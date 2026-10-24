from dataclasses import dataclass
from typing import Any

from .api import build_default_runtime
from .engine_context import EngineContext
from .plugins import (
    WorkflowPlugin,
    build_app_plugin,
    build_core_plugin,
    build_dns_plugin,
    build_firewall_plugin,
    build_http_plugin,
    build_postgres_plugin,
    build_scheduler_plugin,
    build_server_plugin,
    build_setup_plugin,
)
from .registry import (
    build_handler_map,
    build_plugins_from_handlers,
    validate_plugin_coverage,
)


@dataclass(frozen=True)
class EngineBootstrap:
    extracted_workflow_plugins: list[WorkflowPlugin]
    extracted_workflow_handler_map: dict[tuple[str, str], Any]
    workflow_operation_handlers: dict[tuple[str, str], Any]
    workflow_plugins: list[WorkflowPlugin]
    workflow_plugin_coverage_gaps: dict[str, list[str]]
    runtime: Any


def build_engine_bootstrap(
    *,
    workflow_registry: dict[str, dict[str, dict[str, Any]]],
    ctx: EngineContext,
    unimplemented_handler,
):
    extracted_workflow_plugins = [
        build_core_plugin(operations=workflow_registry["core"], ctx=ctx),
        build_server_plugin(operations=workflow_registry["server"], ctx=ctx),
        build_setup_plugin(operations=workflow_registry["setup"], ctx=ctx),
        build_http_plugin(operations=workflow_registry["http"], ctx=ctx),
        build_dns_plugin(operations=workflow_registry["dns"], ctx=ctx),
        build_postgres_plugin(operations=workflow_registry["postgres"], ctx=ctx),
        build_app_plugin(operations=workflow_registry["app"], ctx=ctx),
        build_firewall_plugin(operations=workflow_registry["firewall"], ctx=ctx),
        build_scheduler_plugin(operations=workflow_registry["scheduler"], ctx=ctx),
    ]
    extracted_workflow_handler_map = build_handler_map(extracted_workflow_plugins)
    workflow_operation_handlers = dict(extracted_workflow_handler_map)
    workflow_plugins = build_plugins_from_handlers(
        workflow_registry,
        workflow_operation_handlers,
    )
    workflow_plugin_coverage_gaps = validate_plugin_coverage(
        workflow_registry,
        workflow_plugins,
    )
    runtime = build_default_runtime(
        workflow_registry_getter=lambda: workflow_registry,
        workflow_handlers_getter=lambda: workflow_operation_handlers,
        error_result=ctx.error_result,
        emit_event=ctx.emit_event,
        unimplemented_handler=unimplemented_handler,
    )
    return EngineBootstrap(
        extracted_workflow_plugins=extracted_workflow_plugins,
        extracted_workflow_handler_map=extracted_workflow_handler_map,
        workflow_operation_handlers=workflow_operation_handlers,
        workflow_plugins=workflow_plugins,
        workflow_plugin_coverage_gaps=workflow_plugin_coverage_gaps,
        runtime=runtime,
    )
