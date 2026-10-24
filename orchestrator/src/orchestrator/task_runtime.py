import contextlib
import json
import os
import queue
import tempfile
import threading
import time
import traceback
from datetime import UTC, datetime

from .embedded_runtime import (
    configure_embedded_runtime,
    create_task_process_context,
    verify_process_hardening,
)

configure_embedded_runtime()

# Must run after configure_embedded_runtime() above, which sets up the
# embedded Python environment (paths/env) that engine.py's own heavy imports
# depend on.
from . import engine as _engine_bootstrap  # noqa: E402, F401
from .api import handle_request as _engine_handle_request  # noqa: E402
from .log_sanitizer import sanitize_data  # noqa: E402

_HEARTBEAT_INTERVAL_SECONDS = 8.0
_STALL_THRESHOLD_SECONDS = 8.0
_COMPLETED_TASK_RETENTION_SECONDS = 30 * 60
_MAX_TASK_HISTORY = 200
_COOPERATIVE_CANCEL_GRACE_SECONDS = 6.0
_RESULT_CHANNEL_DRAIN_GRACE_SECONDS = 1.0
_TASK_HISTORY_FILE = os.path.join(
    tempfile.gettempdir(),
    "deploydash-task-history.json",
)


def _timestamp():
    return datetime.now(UTC).isoformat()


def _parse_task_payload_metadata(json_payload):
    metadata = {
        "action": None,
        "workflow_id": None,
        "operation_id": None,
        "client_operation_id": None,
        "idempotency_key": None,
    }
    try:
        payload = json.loads(json_payload)
    except Exception:
        return metadata
    if not isinstance(payload, dict):
        return metadata

    action = payload.get("action")
    workflow_id = payload.get("workflow_id")
    operation_id = payload.get("operation_id")
    client_operation_id = payload.get("client_operation_id")
    idempotency_key = payload.get("idempotency_key")
    metadata["action"] = str(action) if action is not None else None
    metadata["workflow_id"] = str(workflow_id) if workflow_id is not None else None
    metadata["operation_id"] = str(operation_id) if operation_id is not None else None
    metadata["client_operation_id"] = (
        str(client_operation_id) if client_operation_id is not None else None
    )
    metadata["idempotency_key"] = str(idempotency_key) if idempotency_key is not None else None
    return metadata


class _CancelSignal:
    """Cooperative cancellation flag that avoids multiprocessing semaphores.

    The macOS App Sandbox denies POSIX named semaphores, so a
    multiprocessing.Event (SemLock-backed) raises EPERM there. A one-way
    pipe carries the signal instead: Pipe() creation is fd-based and works
    sandboxed, and the buffered byte latches polls just like an Event.
    """

    def __init__(self, context):
        self._reader, self._writer = context.Pipe(duplex=False)

    def set(self):
        with contextlib.suppress(Exception):
            self._writer.send_bytes(b"\x01")

    def is_set(self):
        try:
            return bool(self._reader.poll())
        except Exception:
            return False

    def close_reader(self):
        with contextlib.suppress(Exception):
            self._reader.close()

    def close_writer(self):
        with contextlib.suppress(Exception):
            self._writer.close()


class _TaskRecord:
    def __init__(self, task_id, payload):
        self.task_id = task_id
        self.payload = payload
        metadata = _parse_task_payload_metadata(payload)
        self.action = metadata["action"]
        self.workflow_id = metadata["workflow_id"]
        self.operation_id = metadata["operation_id"]
        self.client_operation_id = metadata["client_operation_id"]
        self.idempotency_key = metadata["idempotency_key"]
        self.events = queue.Queue()
        self.result = None
        self.done = False
        self.cancelled = False
        self.cooperative_cancel = False
        self.worker_thread = None
        self.worker_process = None
        self.result_connection = None
        self.cancel_event = None
        self.started_at_monotonic = time.monotonic()
        self.started_at_iso = _timestamp()
        self.last_progress_at_monotonic = self.started_at_monotonic
        self.completed_at_monotonic = None
        self.lock = threading.Lock()


_task_lock = threading.Lock()
_tasks = {}
_task_history = []
_next_task_id = 1

_TASK_PROCESS_CONTEXT = create_task_process_context()


def _enqueue_event(task, event, mark_progress=True):
    with task.lock:
        if mark_progress:
            task.last_progress_at_monotonic = time.monotonic()
    task.events.put(sanitize_data(event))


def _emit(task, event_type, message=None, level="info", data=None, mark_progress=True):
    event = {
        "type": event_type,
        "level": level,
        "message": message or "",
        "data": data or {},
        "ts": _timestamp(),
    }
    _enqueue_event(task, event, mark_progress=mark_progress)


def _emit_engine_event(task, event):
    if not isinstance(event, dict):
        return
    with task.lock:
        if task.done:
            return
    payload = dict(event)
    if not payload.get("ts"):
        payload["ts"] = _timestamp()
    _enqueue_event(task, payload, mark_progress=True)


def _json_response(payload):
    return json.dumps(payload)


def _lookup_task(task_id):
    with _task_lock:
        _prune_tasks_locked()
        return _tasks.get(task_id)


def _load_task_history():
    if not os.path.exists(_TASK_HISTORY_FILE):
        return []
    try:
        with open(_TASK_HISTORY_FILE, encoding="utf-8") as file_obj:
            payload = json.load(file_obj)
        if not isinstance(payload, list):
            return []
        normalized = []
        for item in payload[-_MAX_TASK_HISTORY:]:
            if isinstance(item, dict):
                normalized.append(sanitize_data(item))
        return normalized
    except Exception:
        return []


def _persist_task_history_locked():
    try:
        with open(_TASK_HISTORY_FILE, "w", encoding="utf-8") as file_obj:
            json.dump(_task_history[-_MAX_TASK_HISTORY:], file_obj)
    except Exception:
        pass


def _record_task_completion(task, result):
    if not isinstance(result, dict):
        status = "error"
        code = "ENGINE_RUNTIME_ERROR"
        message = "Task failed with unknown result payload."
        worker_exit_code = None
    else:
        status = str(result.get("status") or "unknown")
        code = result.get("code")
        message = str(result.get("msg") or "")
        raw_worker_exit_code = result.get("worker_exit_code")
        worker_exit_code = (
            raw_worker_exit_code
            if isinstance(raw_worker_exit_code, int) and not isinstance(raw_worker_exit_code, bool)
            else None
        )

    completed_at_iso = _timestamp()
    summary = sanitize_data(
        {
            "task_id": task.task_id,
            "status": status,
            "code": code,
            "message": message,
            "cancelled": bool(task.cancelled),
            "cooperative_cancel": bool(task.cooperative_cancel),
            "started_at": task.started_at_iso,
            "completed_at": completed_at_iso,
            "action": task.action,
            "workflow_id": task.workflow_id,
            "operation_id": task.operation_id,
            "client_operation_id": task.client_operation_id,
            "idempotency_key": task.idempotency_key,
            "worker_exit_code": worker_exit_code,
        }
    )
    with _task_lock:
        _task_history.append(summary)
        if len(_task_history) > _MAX_TASK_HISTORY:
            del _task_history[:-_MAX_TASK_HISTORY]
        _persist_task_history_locked()


def _prune_tasks_locked():
    now = time.monotonic()
    stale_ids = []
    for task_id, task in _tasks.items():
        with task.lock:
            if not task.done:
                continue
            completed_at = task.completed_at_monotonic
        if completed_at is None:
            continue
        if now - completed_at > _COMPLETED_TASK_RETENTION_SECONDS:
            stale_ids.append(task_id)
    for task_id in stale_ids:
        _tasks.pop(task_id, None)


def _task_process_main(json_payload, result_connection, cancel_event):
    def _emit_to_connection(event):
        if isinstance(event, dict):
            result_connection.send({"kind": "event", "event": event})

    try:
        verify_process_hardening()
        result_json = _engine_handle_request(
            json_payload,
            emit=_emit_to_connection,
            is_cancelled=cancel_event.is_set,
        )
        result = json.loads(result_json)
    except Exception as exc:
        result = {
            "status": "error",
            "code": "ENGINE_RUNTIME_ERROR",
            "msg": str(exc),
            "details": traceback.format_exc(),
        }

    if not isinstance(result, dict):
        result = {
            "status": "error",
            "code": "ENGINE_RUNTIME_ERROR",
            "msg": "Task failed with unknown result payload.",
            "details": str(result),
        }
    try:
        result_connection.send({"kind": "result", "result": result})
    finally:
        result_connection.close()


def _receive_process_payload(process_connection, timeout_seconds):
    if not process_connection.poll(max(0.0, timeout_seconds)):
        return None
    try:
        return process_connection.recv()
    except EOFError:
        return None


def _poll_result_connection_after_worker_exit(
    process_connection,
    grace_seconds,
):
    deadline = time.monotonic() + max(0.0, grace_seconds)
    while time.monotonic() < deadline:
        payload = _receive_process_payload(process_connection, 0.05)
        if payload is not None:
            return payload
    return None


def _task_finished_event_for_result(result):
    if result.get("status") == "success":
        return {
            "type": "task_finished",
            "level": "info",
            "message": "Task completed",
            "data": {},
            "ts": _timestamp(),
        }

    message = str(result.get("msg") or "Task finished with errors.")
    result_code = str(result.get("code") or "")
    if result_code == "ENGINE_TASK_CANCELLED":
        return {
            "type": "task_finished",
            "level": "warning",
            "message": message,
            "data": {},
            "ts": _timestamp(),
        }
    return {
        "type": "task_finished",
        "level": "warning",
        "message": message,
        "data": {
            "code": result.get("code"),
            "details": result.get("details"),
        },
        "ts": _timestamp(),
    }


def _store_task_result(task, result, emit_finished_event=True):
    stored_result = result if result.get("status") == "success" else sanitize_data(result)
    with task.lock:
        if task.done:
            return False
        if emit_finished_event:
            task.last_progress_at_monotonic = time.monotonic()
            task.events.put(_task_finished_event_for_result(stored_result))
        task.result = stored_result
        task.done = True
        task.completed_at_monotonic = time.monotonic()
        cancel_event = task.cancel_event
    if cancel_event is not None:
        with contextlib.suppress(Exception):
            cancel_event.close_writer()
    _record_task_completion(task, stored_result)
    return True


def _cleanup_task_runtime_resources(task):
    with task.lock:
        process = task.worker_process
        result_connection = task.result_connection
        cancel_event = task.cancel_event
        task.worker_process = None
        task.result_connection = None
        task.cancel_event = None

    if process is not None:
        with contextlib.suppress(Exception):
            process.join(timeout=0.1)

    if result_connection is not None:
        with contextlib.suppress(Exception):
            result_connection.close()

    if cancel_event is not None:
        with contextlib.suppress(Exception):
            cancel_event.set()
        with contextlib.suppress(Exception):
            cancel_event.close_reader()


def _terminate_worker_process(task):
    with task.lock:
        process = task.worker_process

    if process is None or not process.is_alive():
        return True

    with contextlib.suppress(Exception):
        process.terminate()
    with contextlib.suppress(Exception):
        process.join(timeout=2.0)

    if process.is_alive():
        with contextlib.suppress(Exception):
            process.kill()
        with contextlib.suppress(Exception):
            process.join(timeout=1.0)

    return not process.is_alive()


def _wait_for_cooperative_cancellation(task, timeout_seconds):
    deadline = time.monotonic() + max(0.0, timeout_seconds)
    while time.monotonic() < deadline:
        with task.lock:
            if task.done:
                return True
            process = task.worker_process
        if process is None or not process.is_alive():
            return False
        time.sleep(0.1)

    with task.lock:
        return task.done


def _run_task(task):
    _emit(task, "task_started", "Task started")
    try:
        with task.lock:
            if task.done:
                return

        result_connection, child_result_connection = _TASK_PROCESS_CONTEXT.Pipe(
            duplex=False,
        )
        if result_connection is None:
            child_result_connection.close()
            return
        cancel_event = _CancelSignal(_TASK_PROCESS_CONTEXT)
        worker_process = _TASK_PROCESS_CONTEXT.Process(
            target=_task_process_main,
            args=(task.payload, child_result_connection, cancel_event),
            daemon=True,
        )
        with task.lock:
            task.result_connection = result_connection
            task.worker_process = worker_process
            task.cancel_event = cancel_event
        try:
            worker_process.start()
        finally:
            child_result_connection.close()

        while True:
            with task.lock:
                if task.done:
                    return
                process = task.worker_process
                process_connection = task.result_connection

            if process_connection is None:
                return

            payload = _receive_process_payload(process_connection, 0.2)
            if payload is None:
                if process is not None and not process.is_alive():
                    payload = _poll_result_connection_after_worker_exit(
                        process_connection,
                        _RESULT_CHANNEL_DRAIN_GRACE_SECONDS,
                    )
                    if isinstance(payload, dict):
                        kind = payload.get("kind")
                        if kind == "event":
                            _emit_engine_event(task, payload.get("event"))
                            continue
                        if kind == "result":
                            result = payload.get("result")
                            if not isinstance(result, dict):
                                result = {
                                    "status": "error",
                                    "code": "ENGINE_RUNTIME_ERROR",
                                    "msg": "Task failed with unknown result payload.",
                                    "details": str(result),
                                }
                            _store_task_result(task, result)
                            return
                    exit_code = getattr(process, "exitcode", None)
                    details = "Worker process terminated before returning a result."
                    if exit_code is not None:
                        details += f" Exit code: {exit_code}."
                    error_result = {
                        "status": "error",
                        "code": "ENGINE_RUNTIME_ERROR",
                        "msg": "Task ended unexpectedly.",
                        "details": details,
                        "worker_exit_code": exit_code,
                    }
                    _store_task_result(task, error_result)
                    return
                continue

            if not isinstance(payload, dict):
                continue
            kind = payload.get("kind")
            if kind == "event":
                _emit_engine_event(task, payload.get("event"))
                continue
            if kind != "result":
                continue

            result = payload.get("result")
            if not isinstance(result, dict):
                result = {
                    "status": "error",
                    "code": "ENGINE_RUNTIME_ERROR",
                    "msg": "Task failed with unknown result payload.",
                    "details": str(result),
                }
            _store_task_result(task, result)
            return
    except Exception as exc:
        error_result = {
            "status": "error",
            "code": "ENGINE_RUNTIME_ERROR",
            "msg": str(exc),
            "details": traceback.format_exc(),
        }
        _store_task_result(task, error_result)
    finally:
        _cleanup_task_runtime_resources(task)


def _monitor_task(task):
    while True:
        time.sleep(_HEARTBEAT_INTERVAL_SECONDS)
        with task.lock:
            done = task.done
            cancelled = task.cancelled
            worker_process = task.worker_process
            started_at = task.started_at_monotonic
            last_progress_at = task.last_progress_at_monotonic

        if done:
            return

        if worker_process is None:
            continue

        now = time.monotonic()
        quiet_duration = max(0.0, now - last_progress_at)
        if quiet_duration < _STALL_THRESHOLD_SECONDS:
            continue

        elapsed_seconds = int(max(0, now - started_at))
        quiet_seconds = int(quiet_duration)
        _emit(
            task,
            "task_heartbeat",
            (
                "Cancellation requested; waiting for current operation to finish."
                if cancelled
                else "Task is still running."
            ),
            level="warning" if cancelled else "info",
            data={
                "elapsed_seconds": elapsed_seconds,
                "quiet_seconds": quiet_seconds,
                "cancelled": cancelled,
                "worker_alive": bool(worker_process.is_alive()),
            },
            mark_progress=False,
        )


def start_task(json_payload):
    global _next_task_id
    with _task_lock:
        _prune_tasks_locked()
        task_id = _next_task_id
        _next_task_id += 1
        task = _TaskRecord(task_id=task_id, payload=json_payload)
        _tasks[task_id] = task

    worker_thread = threading.Thread(target=_run_task, args=(task,), daemon=True)
    with task.lock:
        task.worker_thread = worker_thread
    worker_thread.start()

    monitor_thread = threading.Thread(target=_monitor_task, args=(task,), daemon=True)
    monitor_thread.start()

    return _json_response(
        {
            "status": "success",
            "task_id": task_id,
        },
    )


def poll_task_events(task_id, max_events=100):
    task = _lookup_task(task_id)
    if task is None:
        return _json_response(
            {
                "status": "error",
                "code": "TASK_NOT_FOUND",
                "msg": f"No task found for id={task_id}",
            },
        )

    try:
        max_events_int = int(max_events)
    except (TypeError, ValueError):
        max_events_int = 100
    if max_events_int <= 0:
        max_events_int = 1

    events = []
    for _ in range(max_events_int):
        try:
            events.append(task.events.get_nowait())
        except queue.Empty:
            break

    with task.lock:
        done = task.done
        cancelled = task.cancelled

    return _json_response(
        {
            "status": "success",
            "task_id": task_id,
            "done": done,
            "cancelled": cancelled,
            "events": events,
        },
    )


def get_task_result(task_id):
    task = _lookup_task(task_id)
    if task is None:
        return _json_response(
            {
                "status": "error",
                "code": "TASK_NOT_FOUND",
                "msg": f"No task found for id={task_id}",
            },
        )

    with task.lock:
        done = task.done
        result = task.result

    if not done:
        return _json_response(
            {
                "status": "pending",
                "task_id": task_id,
                "msg": "Task still running",
            },
        )

    return _json_response(
        {
            "status": "success",
            "task_id": task_id,
            "result": result,
        },
    )


def cancel_task(task_id):
    task = _lookup_task(task_id)
    if task is None:
        return _json_response(
            {
                "status": "error",
                "code": "TASK_NOT_FOUND",
                "msg": f"No task found for id={task_id}",
            },
        )

    with task.lock:
        if task.done:
            return _json_response(
                {
                    "status": "success",
                    "task_id": task_id,
                    "cancelled": False,
                    "msg": "Task already completed",
                },
            )
        task.cancelled = True
        cancel_event = task.cancel_event

    if cancel_event is not None:
        with contextlib.suppress(Exception):
            cancel_event.set()

    _emit(task, "task_cancel_requested", "Cancellation requested", level="warning")
    if _wait_for_cooperative_cancellation(task, _COOPERATIVE_CANCEL_GRACE_SECONDS):
        with task.lock:
            cooperative_result = task.result
        is_cancelled = isinstance(cooperative_result, dict) and (
            cooperative_result.get("code") == "ENGINE_TASK_CANCELLED"
            or cooperative_result.get("code") == "ENGINE_TASK_CANCELLED_FORCED"
        )
        with task.lock:
            task.cooperative_cancel = True
        return _json_response(
            {
                "status": "success",
                "task_id": task_id,
                "cancelled": is_cancelled or task.cancelled,
                "msg": (
                    "Task cancellation completed cooperatively."
                    if is_cancelled
                    else "Task finished before cancellation completed."
                ),
            },
        )

    if not _terminate_worker_process(task):
        with task.lock:
            task.cancelled = False
        return _json_response(
            {
                "status": "error",
                "code": "TASK_CANCELLATION_FAILED",
                "msg": "Unable to stop the running task process.",
            },
        )

    cancel_result = {
        "status": "error",
        "code": "ENGINE_TASK_CANCELLED_FORCED",
        "msg": "Task cancelled (forced termination)",
        "details": None,
    }
    _emit(
        task,
        "task_cancel_forced",
        "Cancellation forced after grace period.",
        level="warning",
    )
    cancelled = _store_task_result(task, cancel_result)
    return _json_response(
        {
            "status": "success",
            "task_id": task_id,
            "cancelled": cancelled,
        },
    )


def get_recent_task_history(limit=50):
    try:
        limit_int = int(limit)
    except (TypeError, ValueError):
        limit_int = 50
    if limit_int <= 0:
        limit_int = 1
    with _task_lock:
        history = list(_task_history[-limit_int:])
    return _json_response(
        {
            "status": "success",
            "history": history,
        },
    )


_task_history = _load_task_history()
