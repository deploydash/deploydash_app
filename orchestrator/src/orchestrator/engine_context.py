"""T-2.2.1's design: see orchestrator/README.md's "Engine Dependency
Injection" section for the full rationale before changing this file.

`EngineContext` replaces the module-global `_name = None` / explicit
configure-call pattern the six `engine_*_ops.py` modules used to share
dependencies. One frozen instance is built once per engine
(see `engine.py`'s `_ENGINE_CONTEXT`) and threaded explicitly as the first
positional parameter -- named `ctx` -- to every function, public or private,
that needs any of these callables directly or transitively. A function that
touches no dependency does not take `ctx`.

T-2.2.8 extended this same type to also serve `plugins/*.py` -- see the
design doc's "Plugins use the same type" section: one type covers both
`engine.py` -> `engine_*_ops.py` (the original 11 fields) and
`engine_bootstrap.py` -> `plugins/*.py` (the 38 fields below that, added in
T-2.2.8, covering per-workflow operation entrypoints, settings extractors,
and connection-validation helpers plugins look up by name from the old
`dependencies: dict[str, Any]`).
"""

import dataclasses
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, NoReturn, Protocol, runtime_checkable

from .contracts import EmitFn
from .runtime_ops import ShellCommandOutput

EnginePayload = dict[str, Any]
CancellationCheck = Callable[[], bool]


class CreateRuntimeSession(Protocol):
    """Build a session from the normalized SSH connector payload."""

    def __call__(
        self,
        *,
        host_name: str,
        connector_data: EnginePayload,
        emit_event: EmitFn,
    ) -> Any:
        """Declare the callable protocol without providing an implementation."""
        ...


class OpenRuntimeSession(Protocol):
    """Open a runtime session and return its established-session result."""

    def __call__(
        self,
        ip: Any,
        username: Any,
        password: Any = None,
        key_filename: Any = None,
        private_key: Any = None,
        port: int = 22,
        needs_sudo: bool = False,
        emit: EmitFn | None = None,
    ) -> EnginePayload:
        """Declare the callable protocol without providing an implementation."""
        ...


class EmitEvent(Protocol):
    """Emit one sanitized engine event when an event sink is available."""

    def __call__(
        self,
        emit: EmitFn | None,
        event_type: str,
        message: Any,
        *,
        level: str = "info",
        data: EnginePayload | None = None,
    ) -> None:
        """Declare the callable protocol without providing an implementation."""
        ...


class ErrorResult(Protocol):
    """Build the engine's standard error envelope."""

    def __call__(
        self,
        code: str,
        msg: str,
        stage: str,
        details: str | None = None,
        extra: EnginePayload | None = None,
    ) -> EnginePayload:
        """Declare the callable protocol without providing an implementation."""
        ...


class PlanDescription(Protocol):
    """Describe a workflow plan from optional parts and raw settings."""

    def __call__(self, parts: Any = None, raw_data: Any = None) -> EnginePayload:
        """Declare the callable protocol without providing an implementation."""
        ...


class DescribePostgres(Protocol):
    """Describe the PostgreSQL service plan from optional raw settings."""

    def __call__(self, raw_data: Any = None) -> EnginePayload:
        """Declare the callable protocol without providing an implementation."""
        ...


class NormalizeRuntimeLogTail(Protocol):
    """Normalize an optional runtime-log tail size into its safe bounds."""

    def __call__(self, value: Any, default: int = 200, max_lines: int = 2000) -> int:
        """Declare the callable protocol without providing an implementation."""
        ...


class ConnectionCheck(Protocol):
    """Check a connection without changing the managed server."""

    def __call__(
        self,
        ip: Any,
        username: Any,
        password: Any = None,
        key_filename: Any = None,
        port: int = 22,
        emit: EmitFn | None = None,
    ) -> EnginePayload:
        """Declare the callable protocol without providing an implementation."""
        ...


class PlannedConnectionOperation(Protocol):
    """Run a setup or deploy operation with optional selected parts."""

    def __call__(
        self,
        ip: Any,
        username: Any,
        password: Any = None,
        key_filename: Any = None,
        port: int = 22,
        parts: Any = None,
        dry_run: bool = True,
        raw_data: Any = None,
        emit: EmitFn | None = None,
        is_cancelled: CancellationCheck | None = None,
    ) -> EnginePayload:
        """Declare the callable protocol without providing an implementation."""
        ...


class PrepareAppDeployKey(Protocol):
    """Prepare the deploy key for a web-app deployment."""

    def __call__(
        self,
        ip: Any,
        username: Any,
        password: Any = None,
        key_filename: Any = None,
        port: int = 22,
        dry_run: bool = True,
        raw_data: Any = None,
        emit: EmitFn | None = None,
        is_cancelled: CancellationCheck | None = None,
    ) -> EnginePayload:
        """Declare the callable protocol without providing an implementation."""
        ...


class RuntimeOperation(Protocol):
    """Run a workflow runtime operation against one server connection."""

    def __call__(
        self,
        operation_id: str,
        ip: Any,
        username: Any,
        password: Any = None,
        key_filename: Any = None,
        port: int = 22,
        dry_run: bool = False,
        raw_data: Any = None,
        emit: EmitFn | None = None,
        is_cancelled: CancellationCheck | None = None,
    ) -> EnginePayload:
        """Invoke the runtime action identified by ``operation_id``."""
        ...


class AppRuntimeOperation(Protocol):
    """Run a web-app runtime operation with its app-specific controls."""

    def __call__(
        self,
        operation_id: str,
        ip: Any,
        username: Any,
        password: Any = None,
        key_filename: Any = None,
        port: int = 22,
        dry_run: bool = False,
        raw_data: Any = None,
        emit: EmitFn | None = None,
        is_cancelled: CancellationCheck | None = None,
        log_tail_lines: int = 200,
        worker_id: str | None = None,
        release_id: str | None = None,
        command: str | None = None,
        timeout_seconds: int | None = None,
    ) -> EnginePayload:
        """Declare the callable protocol without providing an implementation."""
        ...


class ServerOperation(Protocol):
    """Run a server operation with the common connection controls."""

    def __call__(
        self,
        ip: Any,
        username: Any,
        password: Any = None,
        key_filename: Any = None,
        port: int = 22,
        dry_run: bool = False,
        emit: EmitFn | None = None,
        is_cancelled: CancellationCheck | None = None,
    ) -> EnginePayload:
        """Declare the callable protocol without providing an implementation."""
        ...


class ServerSettingsOperation(Protocol):
    """Run a server operation with caller-owned settings."""

    def __call__(
        self,
        ip: Any,
        username: Any,
        password: Any = None,
        key_filename: Any = None,
        port: int = 22,
        settings: EnginePayload | None = None,
        dry_run: bool = False,
        emit: EmitFn | None = None,
        is_cancelled: CancellationCheck | None = None,
    ) -> EnginePayload:
        """Declare the callable protocol without providing an implementation."""
        ...


class DockerStoragePruneOperation(Protocol):
    """Prune one requested class of unused Docker storage."""

    def __call__(
        self,
        ip: Any,
        username: Any,
        password: Any = None,
        key_filename: Any = None,
        port: int = 22,
        target: Any = None,
        dry_run: bool = False,
        emit: EmitFn | None = None,
        is_cancelled: CancellationCheck | None = None,
    ) -> EnginePayload:
        """Declare the callable protocol without providing an implementation."""
        ...


class ToolingUpdateOperation(Protocol):
    """Update the selected managed server components."""

    def __call__(
        self,
        ip: Any,
        username: Any,
        password: Any = None,
        key_filename: Any = None,
        port: int = 22,
        component_ids: Any = None,
        dry_run: bool = False,
        emit: EmitFn | None = None,
        is_cancelled: CancellationCheck | None = None,
    ) -> EnginePayload:
        """Declare the callable protocol without providing an implementation."""
        ...


class ToolingRollbackOperation(Protocol):
    """Roll back one selected managed server component."""

    def __call__(
        self,
        ip: Any,
        username: Any,
        password: Any = None,
        key_filename: Any = None,
        port: int = 22,
        component_id: Any = None,
        dry_run: bool = False,
        emit: EmitFn | None = None,
        is_cancelled: CancellationCheck | None = None,
        restore_data: bool = False,
    ) -> EnginePayload:
        """Declare the callable protocol without providing an implementation."""
        ...


@runtime_checkable
class EngineCore(Protocol):
    """The nine dependencies shared by at least four engine consumers."""

    emit_event: EmitEvent
    extract_connection_payload: Callable[[EnginePayload], EnginePayload | None]
    connection_validation_error: Callable[[EnginePayload | None], EnginePayload | None]
    resolve_dry_run: Callable[[EnginePayload, bool], bool]
    error_result: ErrorResult
    emit_shell_output_lines: Callable[[EmitFn | None, ShellCommandOutput | None], None]
    open_runtime_session: OpenRuntimeSession
    resolve_parts: Callable[[EnginePayload], Any]
    command_error_details: Callable[[ShellCommandOutput | None], str]


@runtime_checkable
class SupportsRuntimeCommon(EngineCore, Protocol):
    """Dependencies used by the runtime-session helpers."""

    create_runtime_session: CreateRuntimeSession
    sanitize_message: Callable[[Any], str]


@runtime_checkable
class SupportsAppCommandExecution(EngineCore, Protocol):
    """Dependencies used by app command-output rendering."""

    sanitize_message: Callable[[Any], str]


@runtime_checkable
class SupportsAppDeployment(EngineCore, Protocol):
    """Dependencies used to prepare and deploy a web app."""

    sanitize_message: Callable[[Any], str]
    probe_http_gateway_fast_path: Callable[[Any, Any], EnginePayload]
    read_remote_file_text: Callable[[Any, str], str]
    setup_http_gateway: PlannedConnectionOperation


@runtime_checkable
class SupportsAppReleaseLifecycle(EngineCore, Protocol):
    """Dependencies used by release cutover and rollback handling."""

    sanitize_message: Callable[[Any], str]
    read_remote_file_text: Callable[[Any, str, int], str]


@runtime_checkable
class SupportsAppRuntimeOperations(EngineCore, Protocol):
    """Dependencies used by web-app runtime operation planning and execution."""

    normalize_runtime_log_tail: NormalizeRuntimeLogTail


@runtime_checkable
class SupportsAppPlugin(EngineCore, Protocol):
    """The web-app workflow plugin's dependency surface."""

    deploy_application: PlannedConnectionOperation
    describe_app: PlanDescription
    extract_app_settings_payload: Callable[[EnginePayload], EnginePayload]
    normalize_runtime_log_tail: NormalizeRuntimeLogTail
    payload_params: Callable[[EnginePayload], EnginePayload]
    prepare_app_deploy_key: PrepareAppDeployKey
    run_app_runtime_operation: AppRuntimeOperation


@runtime_checkable
class SupportsDnsPlugin(EngineCore, Protocol):
    """The DNS workflow plugin's dependency surface."""

    describe_dns: PlanDescription
    extract_dns_settings_payload: Callable[[EnginePayload], EnginePayload]
    setup_dns_server: PlannedConnectionOperation


@runtime_checkable
class SupportsFirewallPlugin(EngineCore, Protocol):
    """The firewall workflow plugin's dependency surface."""

    extract_firewall_settings_payload: Callable[[EnginePayload], EnginePayload]
    run_firewall_runtime_operation: RuntimeOperation


@runtime_checkable
class SupportsHttpPlugin(EngineCore, Protocol):
    """The HTTP workflow plugin's dependency surface."""

    describe_http: PlanDescription
    extract_http_settings_payload: Callable[[EnginePayload], EnginePayload]
    run_http_runtime_operation: RuntimeOperation
    setup_http_gateway: PlannedConnectionOperation


@runtime_checkable
class SupportsPostgresPlugin(EngineCore, Protocol):
    """The PostgreSQL workflow plugin's dependency surface."""

    describe_postgres: DescribePostgres
    extract_postgres_settings_payload: Callable[[EnginePayload], EnginePayload]
    run_postgres_project_operation: RuntimeOperation
    run_postgres_runtime_operation: RuntimeOperation


@runtime_checkable
class SupportsSchedulerPlugin(EngineCore, Protocol):
    """The scheduler workflow plugin's dependency surface."""

    extract_scheduler_settings_payload: Callable[[EnginePayload], EnginePayload]
    run_scheduler_runtime_operation: RuntimeOperation


@runtime_checkable
class SupportsServerPlugin(EngineCore, Protocol):
    """The server workflow plugin's dependency surface."""

    check_ssh_and_specs: ConnectionCheck
    refresh_known_host_entry: Callable[[str, int, str], bool]
    resolve_known_hosts_file: Callable[[], str | None]
    run_server_docker_storage_prune_operation: DockerStoragePruneOperation
    run_server_docker_storage_status_operation: ServerOperation
    run_server_overview_operation: ServerOperation
    run_server_system_apply_operation: ServerSettingsOperation
    run_server_system_restart_operation: ServerOperation
    run_server_system_status_operation: ServerOperation
    run_server_tooling_rollback_operation: ToolingRollbackOperation
    run_server_tooling_status_operation: ServerOperation
    run_server_tooling_update_operation: ToolingUpdateOperation


@runtime_checkable
class SupportsSetupPlugin(EngineCore, Protocol):
    """The onboarding workflow plugin's dependency surface."""

    describe_setup: PlanDescription
    extract_setup_settings_payload: Callable[[EnginePayload], EnginePayload]
    setup_server: PlannedConnectionOperation


# T-3.3.5 intentionally gives every Protocol field a parameterized callable
# signature. There are zero ``Callable[..., Any]`` declarations in the
# Protocol layer; the remaining broad construction annotations stay isolated
# on the concrete compatibility dataclass below until their owners are typed.
ENGINE_CONTEXT_PROTOCOLS = (
    EngineCore,
    SupportsRuntimeCommon,
    SupportsAppCommandExecution,
    SupportsAppDeployment,
    SupportsAppReleaseLifecycle,
    SupportsAppRuntimeOperations,
    SupportsAppPlugin,
    SupportsDnsPlugin,
    SupportsFirewallPlugin,
    SupportsHttpPlugin,
    SupportsPostgresPlugin,
    SupportsSchedulerPlugin,
    SupportsServerPlugin,
    SupportsSetupPlugin,
)


@dataclass(frozen=True)
class EngineContext:
    create_runtime_session: Callable[..., Any]
    open_runtime_session: Callable[..., dict[str, Any]]
    error_result: Callable[..., dict[str, Any]]
    emit_event: Callable[..., None]
    sanitize_message: Callable[[Any], str]
    emit_shell_output_lines: Callable[[EmitFn | None, ShellCommandOutput | None], None]
    command_error_details: Callable[[ShellCommandOutput | None], str]
    read_remote_file_text: Callable[..., str]
    probe_http_gateway_fast_path: Callable[..., dict[str, Any]]
    setup_http_gateway: Callable[..., dict[str, Any]]
    normalize_runtime_log_tail: Callable[..., int]

    # T-2.2.8: plugin-level dependencies (formerly plugins/*.py's
    # `dependencies: dict[str, Any]`, keyed by these same 38 names).
    check_ssh_and_specs: Callable[..., Any]
    connection_validation_error: Callable[..., Any]
    deploy_application: Callable[..., Any]
    describe_app: Callable[..., Any]
    describe_dns: Callable[..., Any]
    describe_http: Callable[..., Any]
    describe_postgres: Callable[..., Any]
    describe_setup: Callable[..., Any]
    extract_app_settings_payload: Callable[..., Any]
    extract_connection_payload: Callable[..., Any]
    extract_dns_settings_payload: Callable[..., Any]
    extract_firewall_settings_payload: Callable[..., Any]
    extract_http_settings_payload: Callable[..., Any]
    extract_postgres_settings_payload: Callable[..., Any]
    extract_scheduler_settings_payload: Callable[..., Any]
    extract_setup_settings_payload: Callable[..., Any]
    payload_params: Callable[..., Any]
    prepare_app_deploy_key: Callable[..., Any]
    refresh_known_host_entry: Callable[..., Any]
    resolve_dry_run: Callable[..., Any]
    resolve_known_hosts_file: Callable[..., Any]
    resolve_parts: Callable[..., Any]
    run_app_runtime_operation: Callable[..., Any]
    run_firewall_runtime_operation: Callable[..., Any]
    run_http_runtime_operation: Callable[..., Any]
    run_postgres_project_operation: Callable[..., Any]
    run_postgres_runtime_operation: Callable[..., Any]
    run_scheduler_runtime_operation: Callable[..., Any]
    run_server_docker_storage_prune_operation: Callable[..., Any]
    run_server_docker_storage_status_operation: Callable[..., Any]
    run_server_overview_operation: Callable[..., Any]
    run_server_system_apply_operation: Callable[..., Any]
    run_server_system_restart_operation: Callable[..., Any]
    run_server_system_status_operation: Callable[..., Any]
    run_server_tooling_rollback_operation: Callable[..., Any]
    run_server_tooling_status_operation: Callable[..., Any]
    run_server_tooling_update_operation: Callable[..., Any]
    setup_dns_server: Callable[..., Any]
    setup_server: Callable[..., Any]


def _not_provided(field_name: str) -> Callable[..., NoReturn]:
    def _raise(*_args: Any, **_kwargs: Any) -> NoReturn:
        raise NotImplementedError(
            f"EngineContext.{field_name} was not provided to this partial context "
            "(built via build_partial_context) and was called anyway."
        )

    return _raise


def build_partial_context(**overrides: Any) -> EngineContext:
    """Build an `EngineContext` from a subset of real callables.

    For a caller that only has some of the 11 dependencies available and
    only ever reaches functions that use that subset -- e.g.
    `setup_postflight.py` calling `engine_firewall_ops._apply_staged_firewall`
    directly, which needs only `error_result`/`emit_event`/
    `emit_shell_output_lines`/`command_error_details`, never the other seven.
    Every field not passed as an override raises `NotImplementedError`
    naming itself if it is ever actually called, so a caller that turns out
    to need a field it did not provide gets an immediate, clear failure
    instead of a silent bug or an unrelated `AttributeError`.
    """
    defaults: dict[str, Any] = {
        field.name: _not_provided(field.name) for field in dataclasses.fields(EngineContext)
    }
    defaults.update(overrides)
    return EngineContext(**defaults)
