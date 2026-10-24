"""Shared `EngineContext` test construction helper (T-2.2.2).

Not itself a test module (no `*_test.py` name, so `unittest discover` never
collects it). `EngineContext` is a frozen dataclass with 11 required fields
and no defaults by design -- see orchestrator/README.md's "Engine Dependency
Injection" section -- so a test exercising one field still has to supply all
11. `build_test_context(**overrides)` fills in safe stand-ins for the rest:
fields most tests never touch raise loudly if called, so a test that
accidentally depends on an untested seam fails with a clear message instead
of silently returning `None`.
"""

from collections.abc import Callable
from typing import Any, NoReturn

from orchestrator.engine_context import EngineContext


def _unexpected_call(field_name: str) -> Callable[..., NoReturn]:
    def _raise(*_args: Any, **_kwargs: Any) -> NoReturn:
        raise AssertionError(
            f"EngineContext.{field_name} was called but this test did not "
            "provide it -- pass an override to build_test_context()."
        )

    return _raise


def build_test_context(**overrides: Any) -> EngineContext:
    defaults: dict[str, Any] = {
        "create_runtime_session": _unexpected_call("create_runtime_session"),
        "open_runtime_session": _unexpected_call("open_runtime_session"),
        "error_result": lambda code, msg, stage, details=None, extra=None: {
            "status": "error",
            "code": code,
            "msg": msg,
            "stage": stage,
            "details": details,
        },
        "emit_event": lambda *args, **kwargs: None,
        "sanitize_message": lambda message: str(message),
        "emit_shell_output_lines": lambda *args, **kwargs: None,
        "command_error_details": lambda output: "",
        "read_remote_file_text": _unexpected_call("read_remote_file_text"),
        "probe_http_gateway_fast_path": _unexpected_call("probe_http_gateway_fast_path"),
        "setup_http_gateway": _unexpected_call("setup_http_gateway"),
        "normalize_runtime_log_tail": lambda value, default=200, max_lines=2000: default,
        # T-2.2.8: plugin-level dependencies, all default to a loud
        # failure -- a plugin test that needs one overrides it explicitly.
        "check_ssh_and_specs": _unexpected_call("check_ssh_and_specs"),
        "connection_validation_error": _unexpected_call("connection_validation_error"),
        "deploy_application": _unexpected_call("deploy_application"),
        "describe_app": _unexpected_call("describe_app"),
        "describe_dns": _unexpected_call("describe_dns"),
        "describe_http": _unexpected_call("describe_http"),
        "describe_postgres": _unexpected_call("describe_postgres"),
        "describe_setup": _unexpected_call("describe_setup"),
        "extract_app_settings_payload": _unexpected_call("extract_app_settings_payload"),
        "extract_connection_payload": _unexpected_call("extract_connection_payload"),
        "extract_dns_settings_payload": _unexpected_call("extract_dns_settings_payload"),
        "extract_firewall_settings_payload": _unexpected_call("extract_firewall_settings_payload"),
        "extract_http_settings_payload": _unexpected_call("extract_http_settings_payload"),
        "extract_postgres_settings_payload": _unexpected_call("extract_postgres_settings_payload"),
        "extract_scheduler_settings_payload": _unexpected_call(
            "extract_scheduler_settings_payload"
        ),
        "extract_setup_settings_payload": _unexpected_call("extract_setup_settings_payload"),
        "payload_params": _unexpected_call("payload_params"),
        "prepare_app_deploy_key": _unexpected_call("prepare_app_deploy_key"),
        "refresh_known_host_entry": _unexpected_call("refresh_known_host_entry"),
        "resolve_dry_run": _unexpected_call("resolve_dry_run"),
        "resolve_known_hosts_file": _unexpected_call("resolve_known_hosts_file"),
        "resolve_parts": _unexpected_call("resolve_parts"),
        "run_app_runtime_operation": _unexpected_call("run_app_runtime_operation"),
        "run_firewall_runtime_operation": _unexpected_call("run_firewall_runtime_operation"),
        "run_http_runtime_operation": _unexpected_call("run_http_runtime_operation"),
        "run_postgres_project_operation": _unexpected_call("run_postgres_project_operation"),
        "run_postgres_runtime_operation": _unexpected_call("run_postgres_runtime_operation"),
        "run_scheduler_runtime_operation": _unexpected_call("run_scheduler_runtime_operation"),
        "run_server_docker_storage_prune_operation": _unexpected_call(
            "run_server_docker_storage_prune_operation"
        ),
        "run_server_docker_storage_status_operation": _unexpected_call(
            "run_server_docker_storage_status_operation"
        ),
        "run_server_overview_operation": _unexpected_call("run_server_overview_operation"),
        "run_server_system_apply_operation": _unexpected_call("run_server_system_apply_operation"),
        "run_server_system_restart_operation": _unexpected_call(
            "run_server_system_restart_operation"
        ),
        "run_server_system_status_operation": _unexpected_call(
            "run_server_system_status_operation"
        ),
        "run_server_tooling_rollback_operation": _unexpected_call(
            "run_server_tooling_rollback_operation"
        ),
        "run_server_tooling_status_operation": _unexpected_call(
            "run_server_tooling_status_operation"
        ),
        "run_server_tooling_update_operation": _unexpected_call(
            "run_server_tooling_update_operation"
        ),
        "setup_dns_server": _unexpected_call("setup_dns_server"),
        "setup_server": _unexpected_call("setup_server"),
    }
    defaults.update(overrides)
    return EngineContext(**defaults)
