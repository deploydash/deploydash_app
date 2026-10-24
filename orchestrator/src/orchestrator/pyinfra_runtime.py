import logging
import os
from dataclasses import dataclass, field
from io import StringIO

from pyinfra import logger as pyinfra_logger
from pyinfra.api import Config, Inventory, State
from pyinfra.api.connect import connect_all, disconnect_all
from pyinfra.api.deploy import add_deploy, deploy
from pyinfra.api.operations import run_ops
from pyinfra.api.state import BaseStateCallback
from pyinfra.operations import apt, files, server

from . import apt_runtime, server_paths
from .log_sanitizer import sanitize_data, sanitize_text

_FAILED_OPERATION_MAX_LINES_PER_STREAM = 80


def _bounded_failure_lines(values):
    """Retain only a safe recent window for the one failed operation."""
    try:
        sanitized = [sanitize_text(line) for line in values]
    except Exception:
        return []
    return [line for line in sanitized if line][-_FAILED_OPERATION_MAX_LINES_PER_STREAM:]


def _sanitize_log_message(message):
    return sanitize_text(message)


def _is_noisy_connection_log(message):
    lowered = message.lower()
    return "authentication error" in lowered or "no hosts remaining" in lowered


class _StateEventCallback(BaseStateCallback):
    def __init__(self, emit_event):
        self._emit_event = emit_event

    def _emit(self, event_type, message, level="info", data=None):
        if self._emit_event is None:
            return
        sanitized_message = _sanitize_log_message(message)
        sanitized_data = sanitize_data(data or {})
        self._emit_event(
            event_type,
            sanitized_message,
            level=level,
            data=sanitized_data,
        )

    @staticmethod
    def _operation_name(state, op_hash):
        try:
            op_meta = state.get_op_meta(op_hash)
            names = sorted(op_meta.names)
            if names:
                return names[0]
        except Exception:
            return "operation"
        return "operation"

    @staticmethod
    def _display_operation_name(state, op_hash):
        operation_name = _StateEventCallback._operation_name(state, op_hash)
        if not isinstance(operation_name, str):
            return str(operation_name)

        if "|" in operation_name:
            parts = [part.strip() for part in operation_name.split("|") if part.strip()]
            if parts:
                return parts[-1]

        return operation_name

    def _emit_operation_output(self, state, host_name, op_hash, op_name):
        try:
            op_meta = state.get_op_meta(op_hash)
        except Exception:
            return

        try:
            stdout_lines = list(getattr(op_meta, "stdout_lines", []) or [])
        except Exception:
            stdout_lines = []

        try:
            stderr_lines = list(getattr(op_meta, "stderr_lines", []) or [])
        except Exception:
            stderr_lines = []

        for line in stdout_lines:
            clean_line = _sanitize_log_message(line)
            if not clean_line:
                continue
            self._emit(
                "pyinfra_operation_stdout",
                f"{op_name} | {clean_line}",
                data={
                    "host": host_name,
                    "name": op_name,
                    "stream": "stdout",
                },
            )

        for line in stderr_lines:
            clean_line = _sanitize_log_message(line)
            if not clean_line:
                continue
            self._emit(
                "pyinfra_operation_stderr",
                f"{op_name} | {clean_line}",
                level="warning",
                data={
                    "host": host_name,
                    "name": op_name,
                    "stream": "stderr",
                },
            )

    def host_before_connect(self, state, host):
        self._emit(
            "pyinfra_host_before_connect",
            f"Preparing connection for {host.name}",
            data={"host": host.name},
        )

    def host_connect(self, state, host):
        self._emit(
            "pyinfra_host_connected",
            f"Connected to {host.name}",
            data={"host": host.name},
        )

    def host_connect_error(self, state, host, error):
        self._emit(
            "pyinfra_host_connect_error",
            f"Connection failed for {host.name}.",
            level="warning",
            data={
                "host": host.name,
                "details": _sanitize_log_message(error),
            },
        )

    def host_disconnect(self, state, host):
        self._emit(
            "pyinfra_host_disconnected",
            f"Disconnected from {host.name}",
            data={"host": host.name},
        )

    def operation_start(self, state, op_hash):
        op_name = self._display_operation_name(state, op_hash)
        self._emit(
            "pyinfra_operation_start",
            f"Running operation: {op_name}",
            data={"name": op_name},
        )

    def operation_host_start(self, state, host, op_hash, *_):
        op_name = self._display_operation_name(state, op_hash)
        self._emit(
            "pyinfra_operation_host_start",
            f"{op_name}: started",
            data={"host": host.name, "name": op_name},
        )

    def operation_host_success(self, state, host, op_hash, retry_count=0, *_):
        op_name = self._display_operation_name(state, op_hash)
        message = f"{op_name}: succeeded"
        if retry_count:
            message = f"{message} (retry {retry_count})"
        self._emit(
            "pyinfra_operation_host_success",
            message,
            data={
                "host": host.name,
                "name": op_name,
                "retry_count": retry_count,
            },
        )

    def operation_host_error(
        self,
        state,
        host,
        op_hash,
        retry_count=0,
        max_retries=0,
        *_,
    ):
        op_name = self._display_operation_name(state, op_hash)
        message = f"{op_name}: failed"
        if max_retries:
            message = f"{message} (retry {retry_count}/{max_retries})"
        self._emit(
            "pyinfra_operation_host_error",
            message,
            level="error",
            data={
                "host": host.name,
                "name": op_name,
                "retry_count": retry_count,
                "max_retries": max_retries,
            },
        )

    def operation_host_retry(self, state, host, op_hash, retry_num, max_retries, *_):
        op_name = self._display_operation_name(state, op_hash)
        self._emit(
            "pyinfra_operation_host_retry",
            f"{op_name}: retry {retry_num}/{max_retries}",
            level="warning",
            data={
                "host": host.name,
                "name": op_name,
                "retry_count": retry_num,
                "max_retries": max_retries,
            },
        )

    def operation_end(self, state, op_hash):
        op_name = self._display_operation_name(state, op_hash)
        self._emit_operation_output(state, None, op_hash, op_name)
        self._emit(
            "pyinfra_operation_end",
            f"{op_name}: completed",
            data={"name": op_name},
        )


class _PyinfraLogHandler(logging.Handler):
    def __init__(self, emit_event):
        super().__init__()
        self._emit_event = emit_event

    def emit(self, record):
        if self._emit_event is None:
            return
        try:
            message = self.format(record)
        except Exception:
            message = record.getMessage()
        message = _sanitize_log_message(message)
        if not message:
            return
        if _is_noisy_connection_log(message):
            return
        level = record.levelname.lower() if record.levelname else "info"
        self._emit_event("pyinfra_log", message, level=level)


@dataclass
class _OperationRecord:
    step_id: str
    part: str
    title: str
    operation_meta: object
    action_id: str | None = None


@dataclass
class PyinfraRuntimeSession:
    state: State
    host_name: str
    emit_event: object
    log_handler: _PyinfraLogHandler
    _operations: list[_OperationRecord] = field(default_factory=list)
    _active_step: object | None = None
    _step_sequence: list[tuple[str, str, str]] = field(default_factory=list)
    _seen_step_ids: set[str] = field(default_factory=set)
    _run_once_results: dict[str, object] = field(default_factory=dict)

    @property
    def host(self):
        return self.state.inventory.get_host(self.host_name)

    def _set_active_step(self, step):
        self._active_step = step
        if step.id not in self._seen_step_ids:
            self._step_sequence.append((step.id, step.part, step.title))
            self._seen_step_ids.add(step.id)

    def _clear_active_step(self):
        self._active_step = None

    def add_operation(self, operation_func, **kwargs):
        if self._active_step is None:
            raise RuntimeError("add_operation called without an active step context")

        step = self._active_step
        action_id = kwargs.pop("deploydash_action_id", None)
        action_id = action_id.strip() or None if isinstance(action_id, str) else None
        operation_name = kwargs.get("name", step.title)
        kwargs["name"] = operation_name

        op_meta = operation_func(**kwargs)
        if op_meta is None:
            raise RuntimeError(f"No operation metadata returned for host {self.host_name}")

        self._operations.append(
            _OperationRecord(
                step_id=step.id,
                part=step.part,
                title=step.title,
                operation_meta=op_meta,
                action_id=action_id,
            )
        )
        return op_meta

    def add_shell_step(self, step):
        self._set_active_step(step)
        try:
            return self.add_operation(
                server.shell,
                commands=step.commands,
            )
        finally:
            self._clear_active_step()

    def register_steps_deploy(self, steps):
        @deploy("deploydash_setup")
        def _deploy_setup():
            for step in steps:
                self._set_active_step(step)
                try:
                    if step.register is None:
                        self.add_operation(
                            server.shell,
                            commands=step.commands,
                        )
                    else:
                        step.register(self)
                finally:
                    self._clear_active_step()

        add_deploy(self.state, _deploy_setup, host=self.host)

    def run_once(self, key, register_operation):
        if key in self._run_once_results:
            return self._run_once_results[key]
        operation_meta = register_operation()
        self._run_once_results[key] = operation_meta
        return operation_meta

    def ensure_apt_updated(self, cache_time=3600):
        self.run_once(
            "setup:apt_lock_notice",
            lambda: self.add_operation(
                server.shell,
                commands=[apt_runtime.apt_lock_notice_command()],
                name="Check Ubuntu package manager availability",
            ),
        )
        self.run_once(
            "setup:apt_lock_timeout",
            lambda: self.add_operation(
                files.put,
                src=StringIO(apt_runtime.APT_LOCK_TIMEOUT_CONFIG),
                dest=server_paths.APT_LOCK_TIMEOUT_DROPIN_FILE,
                mode="644",
                name="Configure Ubuntu package manager lock timeout",
            ),
        )
        return self.run_once(
            "setup:apt_update",
            lambda: self.add_operation(
                apt.update,
                cache_time=cache_time,
            ),
        )

    def ensure_service_enabled(self, service_name):
        token = f"setup:service_enabled:{service_name}"
        return self.run_once(
            token,
            lambda: self.add_operation(
                server.service,
                service=service_name,
                running=True,
                enabled=True,
            ),
        )

    def _collect_operation_results(self):
        grouped = {}
        for step_id, part, title in self._step_sequence:
            grouped[step_id] = {
                "step_id": step_id,
                "part": part,
                "title": title,
                "complete": True,
                "success": True,
                "changed": False,
                "stdout": [],
                "stderr": [],
                "failed_action_id": None,
                "failed_operation": None,
            }

        for operation in self._operations:
            meta = operation.operation_meta
            is_complete = False
            did_succeed = None
            did_change = None
            stdout_lines = []
            stderr_lines = []

            try:
                is_complete = meta.is_complete()
            except Exception:
                is_complete = False

            if is_complete:
                try:
                    did_succeed = bool(meta.did_succeed())
                except Exception:
                    did_succeed = False

                try:
                    did_change = bool(meta.did_change())
                except Exception:
                    did_change = None

                try:
                    stdout_lines = [sanitize_text(line) for line in meta.stdout_lines]
                except Exception:
                    stdout_lines = []

                try:
                    stderr_lines = [sanitize_text(line) for line in meta.stderr_lines]
                except Exception:
                    stderr_lines = []

            step_result = grouped.get(operation.step_id)
            if step_result is None:
                step_result = {
                    "step_id": operation.step_id,
                    "part": operation.part,
                    "title": operation.title,
                    "complete": True,
                    "success": True,
                    "changed": False,
                    "stdout": [],
                    "stderr": [],
                    "failed_action_id": None,
                    "failed_operation": None,
                }
                grouped[operation.step_id] = step_result

            operation_succeeded = bool(did_succeed)
            step_result["complete"] = step_result["complete"] and is_complete
            step_result["success"] = step_result["success"] and operation_succeeded
            step_result["changed"] = step_result["changed"] or bool(did_change)
            step_result["stdout"].extend(stdout_lines)
            step_result["stderr"].extend(stderr_lines)
            if not operation_succeeded and step_result["failed_action_id"] is None:
                step_result["failed_action_id"] = operation.action_id
                step_result["failed_operation"] = {
                    "action_id": operation.action_id,
                    "stdout": _bounded_failure_lines(stdout_lines),
                    "stderr": _bounded_failure_lines(stderr_lines),
                }

        ordered_step_ids = [step_id for step_id, _, _ in self._step_sequence]
        for operation in self._operations:
            if operation.step_id not in ordered_step_ids:
                ordered_step_ids.append(operation.step_id)

        return [grouped[step_id] for step_id in ordered_step_ids]

    def execute(self):
        run_error = None

        try:
            run_ops(self.state)
        except Exception as exc:
            run_error = sanitize_text(exc)

        host_results = self.state.get_results_for_host(self.host)
        return {
            "ops": host_results.ops,
            "success_ops": host_results.success_ops,
            "error_ops": host_results.error_ops,
            "ignored_error_ops": host_results.ignored_error_ops,
            "partial_ops": host_results.partial_ops,
            "run_error": run_error,
            "operations": self._collect_operation_results(),
        }

    def close(self):
        disconnect_error = None
        try:
            disconnect_all(self.state)
        except Exception as exc:
            disconnect_error = sanitize_text(exc)
        finally:
            pyinfra_logger.removeHandler(self.log_handler)

        return {"disconnect_error": disconnect_error}


def create_runtime_session(
    host_name,
    connector_data,
    emit_event=None,
):
    inventory = Inventory(([(host_name, connector_data)], {}))
    connect_timeout = 4
    raw_timeout = os.getenv("DEPLOYDASH_SSH_CONNECT_TIMEOUT", "").strip()
    if raw_timeout:
        try:
            parsed_timeout = int(raw_timeout)
            if parsed_timeout > 0:
                connect_timeout = parsed_timeout
        except ValueError:
            pass

    config = Config(CONNECT_TIMEOUT=connect_timeout)
    state = State(inventory=inventory, config=config)

    callback = _StateEventCallback(emit_event)
    state.add_callback_handler(callback)

    configured_level = os.getenv("DEPLOYDASH_PYINFRA_LOG_LEVEL", "DEBUG").strip().upper()
    logger_level = getattr(logging, configured_level, logging.INFO)
    pyinfra_logger.setLevel(logger_level)

    log_handler = _PyinfraLogHandler(emit_event)
    pyinfra_logger.addHandler(log_handler)

    connect_all(state)

    return PyinfraRuntimeSession(
        state=state,
        host_name=host_name,
        emit_event=emit_event,
        log_handler=log_handler,
    )
