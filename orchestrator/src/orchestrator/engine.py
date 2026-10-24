# Not referenced by name in this module -- tests patch it via
# unittest.mock.patch("engine.time.sleep", ...), which resolves through this
# module's own `time` attribute rather than importing the stdlib module
# directly.
import time  # noqa: F401
from datetime import UTC, datetime

from orchestrator import settings_ownership
from orchestrator.app_parts import (
    AppConfigValidationError,
    parse_app_config,
)
from orchestrator.app_parts import (
    collect_steps as collect_app_steps,
)
from orchestrator.app_parts import (
    normalize_parts as normalize_app_parts,
)
from orchestrator.app_parts.app_config import RESOLVED_APP_DEFAULTS
from orchestrator.dns_parts import (
    DnsConfigValidationError,
    parse_dns_config,
)
from orchestrator.dns_parts import (
    collect_steps as collect_dns_steps,
)
from orchestrator.dns_parts import (
    normalize_parts as normalize_dns_parts,
)
from orchestrator.dns_parts.dns_config import RESOLVED_DNS_DEFAULTS
from orchestrator.failure_evidence import prepare_error_extra
from orchestrator.http_parts import (
    HttpConfigValidationError,
    parse_http_config,
)
from orchestrator.http_parts import (
    collect_steps as collect_http_steps,
)
from orchestrator.http_parts import (
    normalize_parts as normalize_http_parts,
)
from orchestrator.http_parts.http_config import RESOLVED_HTTP_DEFAULTS
from orchestrator.log_sanitizer import sanitize_data, sanitize_text
from orchestrator.postgres_parts import (
    REQUESTED_POSTGRES_EXTENSIONS,
    SUPPORTED_POSTGRES_EXTENSIONS,
    SUPPORTED_POSTGRES_VERSIONS,
    UNSUPPORTED_POSTGRES_EXTENSIONS,
    PostgresConfigValidationError,
    parse_postgres_service_config,
)
from orchestrator.postgres_parts.postgres_config import RESOLVED_POSTGRES_DEFAULTS
from orchestrator.pyinfra_runtime import create_runtime_session
from orchestrator.setup_parts import (
    SetupConfigValidationError,
    parse_setup_config,
)
from orchestrator.setup_parts import (
    collect_steps as collect_setup_steps,
)
from orchestrator.setup_parts import (
    normalize_parts as normalize_setup_parts,
)

from . import (
    engine_app_ops,
    engine_firewall_ops,
    engine_infra_ops,
    engine_metrics_parsers,
    engine_postgres_ops,
    engine_runtime_common,
    engine_scheduler_ops,
)
from .engine_bootstrap import build_engine_bootstrap
from .engine_context import EngineContext
from .engine_dispatch_support import (
    build_unimplemented_workflow_handler,
    connection_validation_error,
    extract_settings_payload,
    payload_params,
    resolve_dry_run,
    resolve_parts,
)
from .shell_output import parse_bool_token
from .workflow_registry import WORKFLOW_REGISTRY


def _sanitize_message(message):
    return sanitize_text(message)


def _emit_event(emit, event_type, message, level="info", data=None):
    if emit is None:
        return
    sanitized_message = _sanitize_message(message)
    sanitized_data = sanitize_data(data or {})
    emit(
        {
            "type": event_type,
            "level": level,
            "message": sanitized_message,
            "data": sanitized_data,
            "ts": datetime.now(UTC).isoformat(),
        },
    )


def _error_result(code, msg, stage, details=None, extra=None):
    payload = {
        "status": "error",
        "code": code,
        "msg": _sanitize_message(msg),
        "stage": stage,
        "details": _sanitize_message(details) if details else details,
    }
    if extra:
        payload.update(sanitize_data(prepare_error_extra(extra)))
    return payload


def _normalized_optional_string(value):
    return engine_runtime_common._normalized_optional_string(value)


def _normalized_port(value):
    return engine_runtime_common._normalized_port(value)


def _normalized_bool(value, default):
    # The dry_run path is the only bool member that reads y/n; the token
    # set travels with the call (T-128 audit, #197).
    return parse_bool_token(
        value,
        default,
        true_tokens=("true", "1", "yes", "y"),
        false_tokens=("false", "0", "no", "n"),
    )


def _int_from_env(name, default):
    return engine_runtime_common._int_from_env(name, default)


def _friendly_connect_error_message(error_message):
    return engine_runtime_common._friendly_connect_error_message(_ENGINE_CONTEXT, error_message)


def _build_connector_data(
    username,
    password=None,
    key_filename=None,
    port=22,
    needs_sudo=False,
):
    return engine_runtime_common._build_connector_data(
        username,
        password=password,
        key_filename=key_filename,
        port=port,
        needs_sudo=needs_sudo,
    )


def _resolve_known_hosts_file():
    return engine_runtime_common._resolve_known_hosts_file()


def _refresh_known_host_entry(host, port, known_hosts_file):
    return engine_runtime_common._refresh_known_host_entry(
        host,
        port,
        known_hosts_file,
    )


def _extract_connection_payload(data):
    return engine_runtime_common._extract_connection_payload(data)


def _normalize_runtime_log_tail(value, default=200, max_lines=2000):
    return engine_runtime_common._normalize_runtime_log_tail(
        value,
        default=default,
        max_lines=max_lines,
    )


def _runtime_event_emitter(emit):
    return engine_runtime_common._runtime_event_emitter(_ENGINE_CONTEXT, emit)


def _open_runtime_session(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    needs_sudo=False,
    emit=None,
):
    return engine_runtime_common._open_runtime_session(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        needs_sudo=needs_sudo,
        emit=emit,
    )


def _read_remote_file_text(host, path, timeout=10):
    return engine_runtime_common._read_remote_file_text(host, path, timeout=timeout)


def _command_error_details(output):
    return engine_runtime_common._command_error_details(_ENGINE_CONTEXT, output)


def _probe_http_gateway_fast_path(host, app_config, timeout=8):
    return engine_runtime_common._probe_http_gateway_fast_path(
        _ENGINE_CONTEXT,
        host,
        app_config,
        timeout=timeout,
    )


def _emit_shell_output_lines(emit, output):
    return engine_runtime_common._emit_shell_output_lines(_ENGINE_CONTEXT, emit, output)


def _get_primary_disk_gb(block_devices):
    return engine_metrics_parsers._get_primary_disk_gb(block_devices)


def _parse_positive_int(value):
    return engine_metrics_parsers._parse_positive_int(value)


def _parse_float(value):
    return engine_metrics_parsers._parse_float(value)


def _parse_percent(value):
    return engine_metrics_parsers._parse_percent(value)


def _parse_docker_stats_output(output):
    return engine_metrics_parsers._parse_docker_stats_output(output)


def _parse_http_service_status_output(output):
    return engine_metrics_parsers._parse_http_service_status_output(output)


def _parse_server_overview_metrics_output(output):
    return engine_metrics_parsers._parse_server_overview_metrics_output(output)


def _get_hardware_specs_fast(host, emit=None):
    return engine_infra_ops._get_hardware_specs_fast(_ENGINE_CONTEXT, host, emit=emit)


def get_hardware_specs(host, emit=None):
    return engine_infra_ops.get_hardware_specs(_ENGINE_CONTEXT, host, emit=emit)


def check_ssh_and_specs(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    emit=None,
):
    return engine_infra_ops.check_ssh_and_specs(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        emit=emit,
    )


def run_server_overview_operation(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    emit=None,
    is_cancelled=None,
):
    return engine_infra_ops.run_server_overview_operation(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def run_server_system_status_operation(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    emit=None,
    is_cancelled=None,
):
    return engine_infra_ops.run_server_system_status_operation(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def run_server_system_apply_operation(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    settings=None,
    dry_run=False,
    emit=None,
    is_cancelled=None,
):
    return engine_infra_ops.run_server_system_apply_operation(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        settings=settings,
        dry_run=dry_run,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def run_server_system_restart_operation(*args, **kwargs):
    """Delegate a guarded reboot to the server system-settings owner."""
    return engine_infra_ops.run_server_system_restart_operation(
        _ENGINE_CONTEXT,
        *args,
        **kwargs,
    )


def run_server_docker_storage_status_operation(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    emit=None,
    is_cancelled=None,
):
    return engine_infra_ops.run_server_docker_storage_status_operation(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def run_server_docker_storage_prune_operation(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    target=None,
    dry_run=False,
    emit=None,
    is_cancelled=None,
):
    return engine_infra_ops.run_server_docker_storage_prune_operation(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        target=target,
        dry_run=dry_run,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def run_server_tooling_status_operation(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    emit=None,
    is_cancelled=None,
):
    return engine_infra_ops.run_server_tooling_status_operation(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def run_server_tooling_update_operation(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    component_ids=None,
    dry_run=False,
    emit=None,
    is_cancelled=None,
):
    return engine_infra_ops.run_server_tooling_update_operation(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        component_ids=component_ids,
        dry_run=dry_run,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def run_server_tooling_rollback_operation(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    component_id=None,
    dry_run=False,
    emit=None,
    is_cancelled=None,
    restore_data=False,
):
    return engine_infra_ops.run_server_tooling_rollback_operation(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        component_id=component_id,
        dry_run=dry_run,
        emit=emit,
        is_cancelled=is_cancelled,
        restore_data=restore_data,
    )


def setup_server(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    parts=None,
    dry_run=True,
    raw_data=None,
    emit=None,
    is_cancelled=None,
):
    return engine_infra_ops.setup_server(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        parts=parts,
        dry_run=dry_run,
        raw_data=raw_data,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def setup_http_gateway(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    parts=None,
    dry_run=True,
    raw_data=None,
    emit=None,
    is_cancelled=None,
):
    return engine_infra_ops.setup_http_gateway(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        parts=parts,
        dry_run=dry_run,
        raw_data=raw_data,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def run_http_runtime_operation(
    operation_id,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    raw_data=None,
    emit=None,
    is_cancelled=None,
):
    return engine_infra_ops.run_http_runtime_operation(
        _ENGINE_CONTEXT,
        operation_id=operation_id,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        raw_data=raw_data,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def setup_dns_server(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    parts=None,
    dry_run=True,
    raw_data=None,
    emit=None,
    is_cancelled=None,
):
    return engine_infra_ops.setup_dns_server(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        parts=parts,
        dry_run=dry_run,
        raw_data=raw_data,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def describe_setup(parts=None, raw_data=None):
    try:
        setup_config = parse_setup_config(raw_data)
    except SetupConfigValidationError as exc:
        return _error_result(
            "ENGINE_VALIDATION_ERROR",
            str(exc),
            stage="validate_request",
        )

    normalized_parts = normalize_setup_parts(parts)
    if normalized_parts is None:
        return _error_result(
            "ENGINE_VALIDATION_ERROR",
            "Invalid parts format. Use comma-separated string or list.",
            stage="validate_request",
        )

    step_result = collect_setup_steps(normalized_parts, setup_config)
    if not step_result["ok"]:
        invalid = ", ".join(step_result["invalid_parts"])
        return _error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Unknown setup parts: {invalid}",
            stage="validate_request",
        )

    steps = step_result["steps"]
    return {
        "status": "success",
        "msg": "Setup plan described",
        "code": "OK",
        "parts": normalized_parts,
        "steps": [step.to_dict() for step in steps],
    }


def describe_http(parts=None, raw_data=None):
    try:
        http_config = parse_http_config(raw_data, connection_ip="127.0.0.1")
    except HttpConfigValidationError as exc:
        return _error_result(
            "ENGINE_VALIDATION_ERROR",
            str(exc),
            stage="validate_request",
        )

    normalized_parts = normalize_http_parts(parts)
    if normalized_parts is None:
        return _error_result(
            "ENGINE_VALIDATION_ERROR",
            "Invalid parts format. Use comma-separated string or list.",
            stage="validate_request",
        )

    step_result = collect_http_steps(normalized_parts, http_config)
    if not step_result["ok"]:
        invalid = ", ".join(step_result["invalid_parts"])
        return _error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Unknown HTTP parts: {invalid}",
            stage="validate_request",
        )

    steps = step_result["steps"]
    return {
        "status": "success",
        "msg": "HTTP plan described",
        "code": "OK",
        "parts": normalized_parts,
        "steps": [step.to_dict() for step in steps],
        "stack_root": http_config.stack_root,
        "container_name": http_config.container_name,
        "default_hostname": http_config.default_hostname,
        "server_address": http_config.server_address,
        "server_ip": http_config.server_ip,
        "resolved_config": settings_ownership.resolved_config_snapshot(
            http_config, RESOLVED_HTTP_DEFAULTS
        ),
    }


def describe_dns(parts=None, raw_data=None):
    try:
        dns_config = parse_dns_config(raw_data, connection_ip="127.0.0.1")
    except DnsConfigValidationError as exc:
        return _error_result(
            "ENGINE_VALIDATION_ERROR",
            str(exc),
            stage="validate_request",
        )

    normalized_parts = normalize_dns_parts(parts)
    if normalized_parts is None:
        return _error_result(
            "ENGINE_VALIDATION_ERROR",
            "Invalid parts format. Use comma-separated string or list.",
            stage="validate_request",
        )

    step_result = collect_dns_steps(normalized_parts, dns_config)
    if not step_result["ok"]:
        invalid = ", ".join(step_result["invalid_parts"])
        return _error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Unknown DNS parts: {invalid}",
            stage="validate_request",
        )

    steps = step_result["steps"]
    return {
        "status": "success",
        "msg": "DNS plan described",
        "code": "OK",
        "parts": normalized_parts,
        "steps": [step.to_dict() for step in steps],
        "zone_name": dns_config.zone_name,
        "zone_count": dns_config.zone_count,
        "zone_names": dns_config.zone_names,
        "nameserver_fqdn": dns_config.nameserver_fqdn,
        "nameserver_ipv4": dns_config.nameserver_ipv4,
        "nameserver_ipv6": dns_config.nameserver_ipv6,
        "container_name": dns_config.container_name,
        "bind_image": dns_config.bind_image,
        "bind_service_name": dns_config.bind_service_name,
        "resolved_config": settings_ownership.resolved_config_snapshot(
            dns_config, RESOLVED_DNS_DEFAULTS
        ),
    }


def describe_app(parts=None, raw_data=None):
    try:
        app_config = parse_app_config(raw_data, require_domain=True)
    except AppConfigValidationError as exc:
        return _error_result(
            "ENGINE_VALIDATION_ERROR",
            str(exc),
            stage="validate_request",
        )

    normalized_parts = normalize_app_parts(parts)
    if normalized_parts is None:
        return _error_result(
            "ENGINE_VALIDATION_ERROR",
            "Invalid parts format. Use comma-separated string or list.",
            stage="validate_request",
        )

    step_result = collect_app_steps(normalized_parts, app_config)
    if not step_result["ok"]:
        invalid = ", ".join(step_result["invalid_parts"])
        return _error_result(
            "ENGINE_VALIDATION_ERROR",
            f"Unknown app parts: {invalid}",
            stage="validate_request",
        )

    steps = step_result["steps"]
    return {
        "status": "success",
        "msg": "Web app deploy plan described",
        "code": "OK",
        "parts": normalized_parts,
        "steps": [step.to_dict() for step in steps],
        "project_slug": app_config.project_slug,
        "repository_full_name": app_config.repository_full_name,
        "branch": app_config.branch,
        "primary_domain": app_config.primary_domain,
        "app_port": app_config.app_port,
        "container_name": app_config.container_name,
        "image_name": app_config.image_name,
        "http_url": app_config.app_http_url,
        "https_url": app_config.app_https_url,
        "resolved_config": settings_ownership.resolved_config_snapshot(
            app_config, RESOLVED_APP_DEFAULTS
        ),
    }


def describe_postgres(raw_data=None):
    try:
        postgres_config = parse_postgres_service_config(raw_data)
    except PostgresConfigValidationError as exc:
        return _error_result(
            "ENGINE_VALIDATION_ERROR",
            str(exc),
            stage="validate_request",
        )

    steps = [
        {
            "id": "postgres_step1_service_foundation",
            "title": "Prepare managed PostgreSQL service",
            "commands": [
                "Create PostgreSQL stack directories",
                "Write docker-compose.yml for selected PostgreSQL version",
                "Persist superuser credentials for the managed container",
                "Start PostgreSQL container and verify readiness",
            ],
            "part": "service",
            "actions": [
                {
                    "id": "postgres_action_prepare_stack",
                    "label": "Prepare stack",
                    "description": "Ensure PostgreSQL stack directories exist",
                },
                {
                    "id": "postgres_action_write_compose",
                    "label": "Write compose file",
                    "description": "Pin container to selected PostgreSQL major version",
                },
                {
                    "id": "postgres_action_write_env",
                    "label": "Write credentials",
                    "description": "Persist managed superuser credentials in stack env",
                },
                {
                    "id": "postgres_action_start_container",
                    "label": "Start service",
                    "description": "Boot PostgreSQL container and wait for readiness",
                },
            ],
        },
    ]

    return {
        "status": "success",
        "msg": "PostgreSQL plan described",
        "code": "OK",
        "workflow_id": "postgres",
        "operation_id": "describe",
        "steps": steps,
        "supported_versions": list(SUPPORTED_POSTGRES_VERSIONS),
        "requested_extensions": list(REQUESTED_POSTGRES_EXTENSIONS),
        "supported_extensions": list(SUPPORTED_POSTGRES_EXTENSIONS),
        "unsupported_extensions": list(UNSUPPORTED_POSTGRES_EXTENSIONS),
        "enabled_extensions": list(_postgres_enabled_supported_extensions(postgres_config)),
        "selected_version": postgres_config.postgres_version,
        "selected_image": _postgres_runtime_image_name(postgres_config),
        "stack_root": postgres_config.stack_root,
        "container_name": postgres_config.container_name,
        "host_port": postgres_config.host_port,
        "resolved_config": settings_ownership.resolved_config_snapshot(
            postgres_config, RESOLVED_POSTGRES_DEFAULTS
        ),
    }


def prepare_app_deploy_key(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=True,
    raw_data=None,
    emit=None,
    is_cancelled=None,
):
    return engine_app_ops.prepare_app_deploy_key(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        raw_data=raw_data,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def deploy_application(
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    parts=None,
    dry_run=True,
    raw_data=None,
    emit=None,
    is_cancelled=None,
):
    return engine_app_ops.deploy_application(
        _ENGINE_CONTEXT,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        parts=parts,
        dry_run=dry_run,
        raw_data=raw_data,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def run_app_runtime_operation(
    operation_id,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    raw_data=None,
    emit=None,
    is_cancelled=None,
    log_tail_lines=200,
    worker_id=None,
    release_id=None,
    command=None,
    timeout_seconds=None,
):
    return engine_app_ops.run_app_runtime_operation(
        _ENGINE_CONTEXT,
        operation_id=operation_id,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        raw_data=raw_data,
        emit=emit,
        is_cancelled=is_cancelled,
        log_tail_lines=log_tail_lines,
        worker_id=worker_id,
        release_id=release_id,
        command=command,
        timeout_seconds=timeout_seconds,
    )


_PG_IDENTIFIER_PATTERN = engine_postgres_ops._PG_IDENTIFIER_PATTERN
_normalize_postgres_identifier = engine_postgres_ops._normalize_postgres_identifier
_postgres_project_prefix = engine_postgres_ops._postgres_project_prefix
_postgres_prefixed_name = engine_postgres_ops._postgres_prefixed_name
_postgres_sql_identifier = engine_postgres_ops._postgres_sql_identifier
_postgres_sql_literal = engine_postgres_ops._postgres_sql_literal
_postgres_generated_password = engine_postgres_ops._postgres_generated_password
_postgres_enabled_supported_extensions = engine_postgres_ops._postgres_enabled_supported_extensions
_postgres_enabled_unsupported_extensions = (
    engine_postgres_ops._postgres_enabled_unsupported_extensions
)
_postgres_shared_preload_libraries = engine_postgres_ops._postgres_shared_preload_libraries
_postgres_extensions_requiring_custom_image = (
    engine_postgres_ops._postgres_extensions_requiring_custom_image
)
_postgres_runtime_image_name = engine_postgres_ops._postgres_runtime_image_name
_postgres_extension_image_build_command = (
    engine_postgres_ops._postgres_extension_image_build_command
)
_postgres_service_compose_text = engine_postgres_ops._postgres_service_compose_text
_postgres_base_env_bootstrap_command = engine_postgres_ops._postgres_base_env_bootstrap_command
_postgres_compose_apply_command = engine_postgres_ops._postgres_compose_apply_command
_postgres_readiness_command = engine_postgres_ops._postgres_readiness_command
_postgres_readiness_probe_command = engine_postgres_ops._postgres_readiness_probe_command
_postgres_readiness_diagnostics_command = (
    engine_postgres_ops._postgres_readiness_diagnostics_command
)
_postgres_sync_superuser_command = engine_postgres_ops._postgres_sync_superuser_command
_postgres_apply_extensions_command = engine_postgres_ops._postgres_apply_extensions_command
_postgres_base_env_prefix = engine_postgres_ops._postgres_base_env_prefix
_postgres_service_status_command = engine_postgres_ops._postgres_service_status_command
_parse_postgres_service_status_output = engine_postgres_ops._parse_postgres_service_status_output
_postgres_output_has_one = engine_postgres_ops._postgres_output_has_one
_parse_postgres_role_comment = engine_postgres_ops._parse_postgres_role_comment


def _wait_for_postgres_readiness(
    session,
    config,
    emit=None,
    is_cancelled=None,
    operation_id="service_enable",
):
    return engine_postgres_ops._wait_for_postgres_readiness(
        _ENGINE_CONTEXT,
        session,
        config,
        emit=emit,
        is_cancelled=is_cancelled,
        operation_id=operation_id,
    )


def run_postgres_runtime_operation(
    operation_id,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    raw_data=None,
    emit=None,
    is_cancelled=None,
):
    return engine_postgres_ops.run_postgres_runtime_operation(
        _ENGINE_CONTEXT,
        operation_id=operation_id,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        raw_data=raw_data,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def run_postgres_project_operation(
    operation_id,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    raw_data=None,
    emit=None,
    is_cancelled=None,
):
    return engine_postgres_ops.run_postgres_project_operation(
        _ENGINE_CONTEXT,
        operation_id=operation_id,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        raw_data=raw_data,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def run_scheduler_runtime_operation(
    operation_id,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    raw_data=None,
    emit=None,
    is_cancelled=None,
):
    return engine_scheduler_ops.run_scheduler_runtime_operation(
        _ENGINE_CONTEXT,
        operation_id=operation_id,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        raw_data=raw_data,
        emit=emit,
        is_cancelled=is_cancelled,
    )


def run_firewall_runtime_operation(
    operation_id,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    raw_data=None,
    emit=None,
    is_cancelled=None,
):
    return engine_firewall_ops.run_firewall_runtime_operation(
        _ENGINE_CONTEXT,
        operation_id=operation_id,
        ip=ip,
        username=username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        raw_data=raw_data,
        emit=emit,
        is_cancelled=is_cancelled,
    )


_UNIMPLEMENTED_WORKFLOW_HANDLER = build_unimplemented_workflow_handler(
    workflow_registry=WORKFLOW_REGISTRY,
    error_result=_error_result,
)

# T-2.2.2 through T-2.2.7 migrated all six engine_*_ops.py modules, and
# T-2.2.8 migrated plugins/*.py, off the old per-module dependency-injection
# functions (module globals populated by an explicit configure call at
# import time) and onto explicit `ctx: EngineContext` threading -- see
# orchestrator/README.md's "Engine Dependency Injection" section.
# `_open_runtime_session`, `_command_error_details`, etc. above are forward
# references to this name; that's safe because their bodies only run when
# called, by which point this module has finished executing top to bottom
# and `_ENGINE_CONTEXT` exists.
#
# Every field below is a forwarding lambda, not a direct reference, and that
# is deliberate, not decoration: dozens of existing tests do
# `@patch("engine.create_runtime_session")` / `@patch("engine._open_runtime_session")`
# / etc. to intercept these names. A direct reference here would capture
# today's function object at import time, before any test's patch takes
# effect, silently breaking every one of those tests (several attempt a real
# SSH connection and hang instead of failing). A lambda re-reads the current
# module-global by name on every call, so `unittest.mock.patch` -- which
# replaces the module attribute -- keeps working exactly as it did before
# this migration. This indirection exists purely for that test-patch
# compatibility, independent of T-2.2.10's cleanup of the now-unused old
# per-module DI functions; it stays for as long as tests patch these names
# by string.
_ENGINE_CONTEXT = EngineContext(
    create_runtime_session=lambda *args, **kwargs: create_runtime_session(*args, **kwargs),
    open_runtime_session=lambda *args, **kwargs: _open_runtime_session(*args, **kwargs),
    error_result=lambda *args, **kwargs: _error_result(*args, **kwargs),
    emit_event=lambda *args, **kwargs: _emit_event(*args, **kwargs),
    sanitize_message=lambda *args, **kwargs: _sanitize_message(*args, **kwargs),
    emit_shell_output_lines=lambda *args, **kwargs: _emit_shell_output_lines(*args, **kwargs),
    command_error_details=lambda *args, **kwargs: _command_error_details(*args, **kwargs),
    read_remote_file_text=lambda *args, **kwargs: _read_remote_file_text(*args, **kwargs),
    probe_http_gateway_fast_path=(
        lambda *args, **kwargs: _probe_http_gateway_fast_path(*args, **kwargs)
    ),
    setup_http_gateway=lambda *args, **kwargs: setup_http_gateway(*args, **kwargs),
    normalize_runtime_log_tail=lambda *args, **kwargs: _normalize_runtime_log_tail(*args, **kwargs),
    # T-2.2.8: plugin-level dependencies, formerly engine_bootstrap.py's own
    # per-plugin `dependencies={...}` dict construction (see that module's
    # git history). Several fields below share one underlying callable under
    # different names because that is what each plugin's old dict key
    # happened to be called; this preserves that exactly rather than
    # deduplicating plugin-facing names, which is a separate, larger
    # refactor out of scope here.
    check_ssh_and_specs=lambda *args, **kwargs: check_ssh_and_specs(*args, **kwargs),
    connection_validation_error=lambda connection_data: connection_validation_error(
        connection_data,
        error_result=_error_result,
    ),
    deploy_application=lambda *args, **kwargs: deploy_application(*args, **kwargs),
    describe_app=lambda *args, **kwargs: describe_app(*args, **kwargs),
    describe_dns=lambda *args, **kwargs: describe_dns(*args, **kwargs),
    describe_http=lambda *args, **kwargs: describe_http(*args, **kwargs),
    describe_postgres=lambda *args, **kwargs: describe_postgres(*args, **kwargs),
    describe_setup=lambda *args, **kwargs: describe_setup(*args, **kwargs),
    extract_app_settings_payload=lambda *args, **kwargs: extract_settings_payload(*args, **kwargs),
    extract_connection_payload=lambda *args, **kwargs: _extract_connection_payload(*args, **kwargs),
    extract_dns_settings_payload=lambda *args, **kwargs: extract_settings_payload(*args, **kwargs),
    extract_firewall_settings_payload=lambda *args, **kwargs: extract_settings_payload(
        *args, **kwargs
    ),
    extract_http_settings_payload=lambda *args, **kwargs: extract_settings_payload(*args, **kwargs),
    extract_postgres_settings_payload=lambda *args, **kwargs: extract_settings_payload(
        *args, **kwargs
    ),
    extract_scheduler_settings_payload=lambda *args, **kwargs: extract_settings_payload(
        *args, **kwargs
    ),
    extract_setup_settings_payload=lambda *args, **kwargs: extract_settings_payload(
        *args, **kwargs
    ),
    payload_params=lambda *args, **kwargs: payload_params(*args, **kwargs),
    prepare_app_deploy_key=lambda *args, **kwargs: prepare_app_deploy_key(*args, **kwargs),
    refresh_known_host_entry=lambda *args, **kwargs: _refresh_known_host_entry(*args, **kwargs),
    resolve_dry_run=lambda data, default_value=True: resolve_dry_run(
        data,
        default_value=default_value,
        normalized_bool=_normalized_bool,
    ),
    resolve_known_hosts_file=lambda *args, **kwargs: _resolve_known_hosts_file(*args, **kwargs),
    resolve_parts=lambda *args, **kwargs: resolve_parts(*args, **kwargs),
    run_app_runtime_operation=lambda *args, **kwargs: run_app_runtime_operation(*args, **kwargs),
    run_firewall_runtime_operation=(
        lambda *args, **kwargs: run_firewall_runtime_operation(*args, **kwargs)
    ),
    run_http_runtime_operation=lambda *args, **kwargs: run_http_runtime_operation(*args, **kwargs),
    run_postgres_project_operation=(
        lambda *args, **kwargs: run_postgres_project_operation(*args, **kwargs)
    ),
    run_postgres_runtime_operation=(
        lambda *args, **kwargs: run_postgres_runtime_operation(*args, **kwargs)
    ),
    run_scheduler_runtime_operation=(
        lambda *args, **kwargs: run_scheduler_runtime_operation(*args, **kwargs)
    ),
    run_server_docker_storage_prune_operation=(
        lambda *args, **kwargs: run_server_docker_storage_prune_operation(*args, **kwargs)
    ),
    run_server_docker_storage_status_operation=(
        lambda *args, **kwargs: run_server_docker_storage_status_operation(*args, **kwargs)
    ),
    run_server_overview_operation=(
        lambda *args, **kwargs: run_server_overview_operation(*args, **kwargs)
    ),
    run_server_system_apply_operation=(
        lambda *args, **kwargs: run_server_system_apply_operation(*args, **kwargs)
    ),
    run_server_system_restart_operation=(
        lambda *args, **kwargs: run_server_system_restart_operation(*args, **kwargs)
    ),
    run_server_system_status_operation=(
        lambda *args, **kwargs: run_server_system_status_operation(*args, **kwargs)
    ),
    run_server_tooling_rollback_operation=(
        lambda *args, **kwargs: run_server_tooling_rollback_operation(*args, **kwargs)
    ),
    run_server_tooling_status_operation=(
        lambda *args, **kwargs: run_server_tooling_status_operation(*args, **kwargs)
    ),
    run_server_tooling_update_operation=(
        lambda *args, **kwargs: run_server_tooling_update_operation(*args, **kwargs)
    ),
    setup_dns_server=lambda *args, **kwargs: setup_dns_server(*args, **kwargs),
    setup_server=lambda *args, **kwargs: setup_server(*args, **kwargs),
)

_BOOTSTRAP = build_engine_bootstrap(
    workflow_registry=WORKFLOW_REGISTRY,
    ctx=_ENGINE_CONTEXT,
    unimplemented_handler=_UNIMPLEMENTED_WORKFLOW_HANDLER,
)

EXTRACTED_WORKFLOW_PLUGINS = _BOOTSTRAP.extracted_workflow_plugins
EXTRACTED_WORKFLOW_HANDLER_MAP = _BOOTSTRAP.extracted_workflow_handler_map
WORKFLOW_OPERATION_HANDLERS = _BOOTSTRAP.workflow_operation_handlers
WORKFLOW_PLUGINS = _BOOTSTRAP.workflow_plugins
WORKFLOW_PLUGIN_COVERAGE_GAPS = _BOOTSTRAP.workflow_plugin_coverage_gaps
_ENGINE_RUNTIME = _BOOTSTRAP.runtime


def handle_request(json_str, emit=None, is_cancelled=None):
    return _ENGINE_RUNTIME.handle_request_json(
        json_str,
        emit=emit,
        is_cancelled=is_cancelled,
    )
