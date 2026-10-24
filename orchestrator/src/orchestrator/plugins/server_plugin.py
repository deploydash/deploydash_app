from collections.abc import Callable
from typing import Any

from ..addressing import format_host_port
from ..contracts import EmitFn
from ..engine_context import ServerOperation, SupportsServerPlugin
from .base import WorkflowPlugin, validated_connection


def build_plugin(
    *,
    operations: dict[str, dict[str, Any]],
    ctx: SupportsServerPlugin,
) -> WorkflowPlugin:
    check_ssh_and_specs = ctx.check_ssh_and_specs
    run_server_overview_operation = ctx.run_server_overview_operation
    run_server_system_status_operation = ctx.run_server_system_status_operation
    run_server_system_apply_operation = ctx.run_server_system_apply_operation
    run_server_system_restart_operation = ctx.run_server_system_restart_operation
    run_server_docker_storage_status_operation = ctx.run_server_docker_storage_status_operation
    run_server_docker_storage_prune_operation = ctx.run_server_docker_storage_prune_operation
    run_server_tooling_status_operation = ctx.run_server_tooling_status_operation
    run_server_tooling_update_operation = ctx.run_server_tooling_update_operation
    run_server_tooling_rollback_operation = ctx.run_server_tooling_rollback_operation
    resolve_dry_run = ctx.resolve_dry_run
    error_result = ctx.error_result
    resolve_known_hosts_file = ctx.resolve_known_hosts_file
    refresh_known_host_entry = ctx.refresh_known_host_entry
    emit_event = ctx.emit_event

    def handle_check(data: dict[str, Any], emit: EmitFn | None = None, **_: Any) -> dict[str, Any]:
        connection_data, error = validated_connection(data, ctx)
        if error is not None:
            return error
        assert connection_data is not None
        result: dict[str, Any] = check_ssh_and_specs(
            ip=connection_data["ip"],
            username=connection_data["username"],
            password=connection_data["password"],
            key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
            port=connection_data["port"],
            emit=emit,
        )
        return result

    def handle_refresh_host_key(
        data: dict[str, Any], emit: EmitFn | None = None, **_: Any
    ) -> dict[str, Any]:
        connection_data, error = validated_connection(data, ctx)
        if error is not None:
            return error
        assert connection_data is not None

        ip = connection_data["ip"]
        port = connection_data["port"]
        known_hosts_file = resolve_known_hosts_file()
        if not known_hosts_file:
            error_response: dict[str, Any] = error_result(
                "ENGINE_RUNTIME_ERROR",
                "Unable to resolve DeployDash known_hosts file.",
                stage="connect",
            )
            return error_response

        refreshed = refresh_known_host_entry(ip, port, known_hosts_file)
        if not refreshed:
            failure_response: dict[str, Any] = error_result(
                "ENGINE_RUNTIME_ERROR",
                "Failed to refresh SSH host key entries.",
                stage="connect",
            )
            return failure_response

        emit_event(
            emit,
            "connection_info",
            (
                "Removed stale SSH host key entries for "
                f"{format_host_port(ip, port)} from {known_hosts_file}."
            ),
        )
        return {
            "status": "success",
            "code": "OK",
            "workflow_id": "server",
            "operation_id": "refresh_host_key",
            "msg": "SSH host key entries refreshed successfully.",
            "known_hosts_file": known_hosts_file,
            "host": ip,
            "port": port,
        }

    def handle_overview_metrics(
        data: dict[str, Any],
        emit: EmitFn | None = None,
        is_cancelled: Callable[[], bool] | None = None,
        **_: Any,
    ) -> dict[str, Any]:
        connection_data, error = validated_connection(data, ctx)
        if error is not None:
            return error
        assert connection_data is not None
        result: dict[str, Any] = run_server_overview_operation(
            ip=connection_data["ip"],
            username=connection_data["username"],
            password=connection_data["password"],
            key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
            port=connection_data["port"],
            dry_run=resolve_dry_run(data, False),
            emit=emit,
            is_cancelled=is_cancelled,
        )
        return result

    def build_server_operation_handler(operation: ServerOperation) -> Callable[..., dict[str, Any]]:
        """Share validated server connection forwarding for no-parameter operations."""

        def handle(
            data: dict[str, Any],
            emit: EmitFn | None = None,
            is_cancelled: Callable[[], bool] | None = None,
            **_: Any,
        ) -> dict[str, Any]:
            """Forward one operation only after the shared connection contract passes."""
            connection_data, error = validated_connection(data, ctx)
            if error is not None:
                return error
            assert connection_data is not None
            result: dict[str, Any] = operation(
                ip=connection_data["ip"],
                username=connection_data["username"],
                password=connection_data["password"],
                key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
                port=connection_data["port"],
                dry_run=resolve_dry_run(data, False),
                emit=emit,
                is_cancelled=is_cancelled,
            )
            return result

        return handle

    handle_system_status = build_server_operation_handler(run_server_system_status_operation)
    handle_system_restart = build_server_operation_handler(run_server_system_restart_operation)

    def handle_system_apply(
        data: dict[str, Any],
        emit: EmitFn | None = None,
        is_cancelled: Callable[[], bool] | None = None,
        **_: Any,
    ) -> dict[str, Any]:
        connection_data, error = validated_connection(data, ctx)
        if error is not None:
            return error
        assert connection_data is not None

        params = data.get("params")
        if not isinstance(params, dict):
            params = {}
        raw_settings = params.get("settings")
        if not isinstance(raw_settings, dict):
            raw_settings = {}

        result: dict[str, Any] = run_server_system_apply_operation(
            ip=connection_data["ip"],
            username=connection_data["username"],
            password=connection_data["password"],
            key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
            port=connection_data["port"],
            settings=raw_settings,
            dry_run=resolve_dry_run(data, False),
            emit=emit,
            is_cancelled=is_cancelled,
        )
        return result

    def handle_docker_storage_status(
        data: dict[str, Any],
        emit: EmitFn | None = None,
        is_cancelled: Callable[[], bool] | None = None,
        **_: Any,
    ) -> dict[str, Any]:
        connection_data, error = validated_connection(data, ctx)
        if error is not None:
            return error
        assert connection_data is not None
        result: dict[str, Any] = run_server_docker_storage_status_operation(
            ip=connection_data["ip"],
            username=connection_data["username"],
            password=connection_data["password"],
            key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
            port=connection_data["port"],
            dry_run=resolve_dry_run(data, False),
            emit=emit,
            is_cancelled=is_cancelled,
        )
        return result

    def handle_docker_storage_prune(
        data: dict[str, Any],
        emit: EmitFn | None = None,
        is_cancelled: Callable[[], bool] | None = None,
        **_: Any,
    ) -> dict[str, Any]:
        connection_data, error = validated_connection(data, ctx)
        if error is not None:
            return error
        assert connection_data is not None
        params = data.get("params")
        if not isinstance(params, dict):
            params = {}

        result: dict[str, Any] = run_server_docker_storage_prune_operation(
            ip=connection_data["ip"],
            username=connection_data["username"],
            password=connection_data["password"],
            key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
            port=connection_data["port"],
            target=params.get("target"),
            dry_run=resolve_dry_run(data, False),
            emit=emit,
            is_cancelled=is_cancelled,
        )
        return result

    def handle_tooling_status(
        data: dict[str, Any],
        emit: EmitFn | None = None,
        is_cancelled: Callable[[], bool] | None = None,
        **_: Any,
    ) -> dict[str, Any]:
        connection_data, error = validated_connection(data, ctx)
        if error is not None:
            return error
        assert connection_data is not None
        result: dict[str, Any] = run_server_tooling_status_operation(
            ip=connection_data["ip"],
            username=connection_data["username"],
            password=connection_data["password"],
            key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
            port=connection_data["port"],
            dry_run=resolve_dry_run(data, False),
            emit=emit,
            is_cancelled=is_cancelled,
        )
        return result

    def handle_tooling_update(
        data: dict[str, Any],
        emit: EmitFn | None = None,
        is_cancelled: Callable[[], bool] | None = None,
        **_: Any,
    ) -> dict[str, Any]:
        connection_data, error = validated_connection(data, ctx)
        if error is not None:
            return error
        assert connection_data is not None
        params = data.get("params")
        if not isinstance(params, dict):
            params = {}
        result: dict[str, Any] = run_server_tooling_update_operation(
            ip=connection_data["ip"],
            username=connection_data["username"],
            password=connection_data["password"],
            key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
            port=connection_data["port"],
            component_ids=params.get("component_ids"),
            dry_run=resolve_dry_run(data, False),
            emit=emit,
            is_cancelled=is_cancelled,
        )
        return result

    def handle_tooling_rollback(
        data: dict[str, Any],
        emit: EmitFn | None = None,
        is_cancelled: Callable[[], bool] | None = None,
        **_: Any,
    ) -> dict[str, Any]:
        connection_data, error = validated_connection(data, ctx)
        if error is not None:
            return error
        assert connection_data is not None
        params = data.get("params")
        if not isinstance(params, dict):
            params = {}
        result: dict[str, Any] = run_server_tooling_rollback_operation(
            ip=connection_data["ip"],
            username=connection_data["username"],
            password=connection_data["password"],
            key_filename=connection_data.get("private_key") or connection_data.get("key_path"),
            port=connection_data["port"],
            component_id=params.get("component_id"),
            dry_run=resolve_dry_run(data, False),
            emit=emit,
            is_cancelled=is_cancelled,
            restore_data=params.get("restore_data", False),
        )
        return result

    return WorkflowPlugin(
        workflow_id="server",
        operations=operations,
        handlers={
            "check": handle_check,
            "refresh_host_key": handle_refresh_host_key,
            "overview_metrics": handle_overview_metrics,
            "system_status": handle_system_status,
            "system_apply": handle_system_apply,
            "system_restart": handle_system_restart,
            "docker_storage_status": handle_docker_storage_status,
            "docker_storage_prune": handle_docker_storage_prune,
            "tooling_status": handle_tooling_status,
            "tooling_update": handle_tooling_update,
            "tooling_rollback": handle_tooling_rollback,
        },
    )
