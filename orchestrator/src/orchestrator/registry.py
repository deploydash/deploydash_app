from collections import defaultdict
from typing import Any

from .plugins import WorkflowPlugin


def build_plugins_from_handlers(
    workflow_registry: dict[str, dict[str, dict[str, Any]]],
    workflow_handlers: dict[tuple[str, str], Any],
) -> list[WorkflowPlugin]:
    grouped_handlers: dict[str, dict[str, Any]] = defaultdict(dict)
    for (workflow_id, operation_id), handler in workflow_handlers.items():
        grouped_handlers[workflow_id][operation_id] = handler

    plugins: list[WorkflowPlugin] = []
    for workflow_id, operations in workflow_registry.items():
        handlers = grouped_handlers.get(workflow_id, {})
        plugins.append(
            WorkflowPlugin(
                workflow_id=workflow_id,
                operations=operations,
                handlers=handlers,
            ),
        )
    return plugins


def build_handler_map(plugins: list[WorkflowPlugin]) -> dict[tuple[str, str], Any]:
    handler_map: dict[tuple[str, str], Any] = {}
    for plugin in plugins:
        for operation_id, handler in plugin.handlers.items():
            key = (plugin.workflow_id, operation_id)
            if key in handler_map:
                raise ValueError(
                    f"Duplicate handler registration for {plugin.workflow_id}/{operation_id}",
                )
            handler_map[key] = handler
    return handler_map


def validate_plugin_coverage(
    workflow_registry: dict[str, dict[str, dict[str, Any]]],
    plugins: list[WorkflowPlugin],
) -> dict[str, list[str]]:
    workflow_coverage: dict[str, list[str]] = {}
    plugin_index = {plugin.workflow_id: plugin for plugin in plugins}
    for workflow_id, operations in workflow_registry.items():
        plugin = plugin_index.get(workflow_id)
        if plugin is None:
            workflow_coverage[workflow_id] = sorted(operations.keys())
            continue
        missing = [
            operation_id for operation_id in operations if operation_id not in plugin.handlers
        ]
        if missing:
            workflow_coverage[workflow_id] = sorted(missing)
    return workflow_coverage
