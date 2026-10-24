import json
import multiprocessing
import pickle
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import task_runtime


def _core_echo_payload(data="task-runtime-test"):
    return json.dumps(
        {
            "action": "run_workflow",
            "workflow_id": "core",
            "operation_id": "echo",
            "data": data,
        }
    )


class TestTaskRuntime(unittest.TestCase):
    def _wait_until_done(self, task_id, timeout_seconds=2.0):
        deadline = time.time() + timeout_seconds
        all_events = []

        while time.time() < deadline:
            poll = json.loads(task_runtime.poll_task_events(task_id, 50))
            self.assertEqual(poll["status"], "success")
            all_events.extend(poll["events"])
            if poll["done"]:
                return all_events
            time.sleep(0.02)

        self.fail(f"Task {task_id} did not complete in time")

    def test_echo_task_lifecycle(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "core",
                "operation_id": "echo",
                "data": "hello",
            }
        )
        start = json.loads(task_runtime.start_task(payload))
        self.assertEqual(start["status"], "success")
        task_id = start["task_id"]

        events = self._wait_until_done(task_id)
        event_types = {event["type"] for event in events}
        self.assertIn("task_started", event_types)
        self.assertIn("task_finished", event_types)

        result_payload = json.loads(task_runtime.get_task_result(task_id))
        self.assertEqual(result_payload["status"], "success")
        self.assertEqual(result_payload["result"]["status"], "success")
        self.assertEqual(result_payload["result"]["action"], "echo")
        self.assertEqual(result_payload["result"]["data"], "hello")

    def test_echo_task_lifecycle_with_spawn_context(self):
        with patch.object(
            task_runtime,
            "_TASK_PROCESS_CONTEXT",
            multiprocessing.get_context("spawn"),
        ):
            start = json.loads(
                task_runtime.start_task(
                    json.dumps(
                        {
                            "action": "run_workflow",
                            "workflow_id": "core",
                            "operation_id": "echo",
                            "data": "spawned",
                        }
                    ),
                ),
            )
            task_id = start["task_id"]
            self._wait_until_done(task_id, timeout_seconds=5.0)

        result_payload = json.loads(task_runtime.get_task_result(task_id))
        self.assertEqual(result_payload["status"], "success")
        self.assertEqual(result_payload["result"]["data"], "spawned")

    def test_poll_unknown_task(self):
        result = json.loads(task_runtime.poll_task_events(999999, 10))
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "TASK_NOT_FOUND")

    def test_cancel_unknown_task(self):
        result = json.loads(task_runtime.cancel_task(999999))
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "TASK_NOT_FOUND")

    def test_completed_task_is_recorded_in_history(self):
        start = json.loads(task_runtime.start_task(_core_echo_payload()))
        self.assertEqual(start["status"], "success")
        task_id = start["task_id"]

        self._wait_until_done(task_id)
        history = json.loads(task_runtime.get_recent_task_history(10))
        self.assertEqual(history["status"], "success")
        self.assertTrue(any(item.get("task_id") == task_id for item in history["history"]))

    def test_history_includes_operation_metadata(self):
        start = json.loads(
            task_runtime.start_task(
                json.dumps(
                    {
                        "action": "run_workflow",
                        "workflow_id": "postgres",
                        "operation_id": "service_enable",
                    }
                )
            )
        )
        task_id = start["task_id"]
        self._wait_until_done(task_id)

        history_payload = json.loads(task_runtime.get_recent_task_history(20))
        entries = history_payload["history"]
        matching = [
            item
            for item in entries
            if item.get("action") == "run_workflow"
            and item.get("workflow_id") == "postgres"
            and item.get("operation_id") == "service_enable"
        ]
        self.assertTrue(matching)

    def test_completed_tasks_are_pruned_after_retention(self):
        start = json.loads(task_runtime.start_task(_core_echo_payload()))
        task_id = start["task_id"]
        self._wait_until_done(task_id)
        time.sleep(0.02)

        original_retention = task_runtime._COMPLETED_TASK_RETENTION_SECONDS
        try:
            task_runtime._COMPLETED_TASK_RETENTION_SECONDS = 0
            json.loads(task_runtime.start_task(_core_echo_payload()))
        finally:
            task_runtime._COMPLETED_TASK_RETENTION_SECONDS = original_retention

        missing = json.loads(task_runtime.poll_task_events(task_id, 10))
        self.assertEqual(missing["status"], "error")
        self.assertEqual(missing["code"], "TASK_NOT_FOUND")

    @patch("task_runtime._STALL_THRESHOLD_SECONDS", 0.02)
    @patch("task_runtime._HEARTBEAT_INTERVAL_SECONDS", 0.02)
    @patch("task_runtime._engine_handle_request")
    def test_emits_heartbeat_when_task_has_no_output(
        self,
        mock_handle_request,
    ):
        def _slow_handle_request(*_args, **_kwargs):
            time.sleep(0.1)
            return json.dumps({"status": "success", "action": "echo", "data": "ok"})

        mock_handle_request.side_effect = _slow_handle_request

        start = json.loads(task_runtime.start_task(_core_echo_payload()))
        self.assertEqual(start["status"], "success")
        task_id = start["task_id"]

        events = self._wait_until_done(task_id, timeout_seconds=3.0)
        event_types = {event["type"] for event in events}
        self.assertIn("task_heartbeat", event_types)

    @patch("task_runtime._STALL_THRESHOLD_SECONDS", 0.02)
    @patch("task_runtime._HEARTBEAT_INTERVAL_SECONDS", 0.02)
    @patch("task_runtime._engine_handle_request")
    def test_cancelled_task_heartbeat_mentions_cancellation(
        self,
        mock_handle_request,
    ):
        def _slow_handle_request(*_args, **_kwargs):
            time.sleep(0.1)
            return json.dumps({"status": "success", "action": "echo", "data": "ok"})

        mock_handle_request.side_effect = _slow_handle_request
        start = json.loads(task_runtime.start_task(_core_echo_payload()))
        task_id = start["task_id"]
        cancel = json.loads(task_runtime.cancel_task(task_id))
        self.assertEqual(cancel["status"], "success")

        events = self._wait_until_done(task_id, timeout_seconds=3.0)
        saw_cancellation_message = any(
            "Cancellation requested" in event.get("message", "")
            or (event.get("type") == "task_finished" and event.get("message") == "Task cancelled")
            for event in events
        )
        self.assertTrue(saw_cancellation_message)

    @patch("task_runtime._engine_handle_request")
    def test_cancel_marks_task_done_immediately(self, mock_handle_request):
        def _slow_handle_request(*_args, **_kwargs):
            time.sleep(0.15)
            return json.dumps({"status": "success", "action": "echo", "data": "ok"})

        mock_handle_request.side_effect = _slow_handle_request
        start = json.loads(task_runtime.start_task(_core_echo_payload()))
        task_id = start["task_id"]
        cancel = json.loads(task_runtime.cancel_task(task_id))
        self.assertEqual(cancel["status"], "success")

        poll = json.loads(task_runtime.poll_task_events(task_id, 20))
        self.assertEqual(poll["status"], "success")
        self.assertTrue(poll["done"])

        result_payload = json.loads(task_runtime.get_task_result(task_id))
        self.assertEqual(result_payload["status"], "success")
        self.assertIn(
            result_payload["result"]["code"],
            {"ENGINE_TASK_CANCELLED", "ENGINE_TASK_CANCELLED_FORCED"},
        )

    @patch("task_runtime._terminate_worker_process", return_value=False)
    def test_cancel_reports_failure_when_worker_cannot_stop(self, _mock_terminate):
        task_id = 987654
        task = task_runtime._TaskRecord(task_id=task_id, payload=json.dumps({"action": "echo"}))
        with task_runtime._task_lock:
            task_runtime._tasks[task_id] = task
        try:
            response = json.loads(task_runtime.cancel_task(task_id))
        finally:
            with task_runtime._task_lock:
                task_runtime._tasks.pop(task_id, None)
        self.assertEqual(response["status"], "error")
        self.assertEqual(response["code"], "TASK_CANCELLATION_FAILED")

    def test_run_task_includes_exit_code_when_worker_ends_unexpectedly(self):
        class _FakeConnection:
            def poll(self, timeout=None):
                return False

            def close(self):
                return None

        class _FakeWriter:
            def close(self):
                return None

        class _FakeEvent:
            def set(self):
                return None

        class _FakeProcess:
            exitcode = 17

            def start(self):
                return None

            def is_alive(self):
                return False

            def join(self, timeout=None):
                return None

        class _FakeContext:
            def Pipe(self, duplex=False):
                self.duplex = duplex
                return _FakeConnection(), _FakeWriter()

            def Event(self):
                return _FakeEvent()

            def Process(self, target=None, args=None, daemon=None):
                return _FakeProcess()

        task = task_runtime._TaskRecord(
            task_id=123456,
            payload=json.dumps({"action": "echo"}),
        )
        with patch.object(task_runtime, "_TASK_PROCESS_CONTEXT", _FakeContext()):
            task_runtime._run_task(task)

        self.assertTrue(task.done)
        self.assertEqual(task.result["msg"], "Task ended unexpectedly.")
        self.assertIn("Exit code: 17.", task.result["details"])
        self.assertEqual(task.result["worker_exit_code"], 17)
        history = [
            item for item in task_runtime._task_history if item.get("task_id") == task.task_id
        ]
        self.assertEqual(history[-1]["worker_exit_code"], 17)

    def test_run_task_drains_result_connection_after_clean_worker_exit(self):
        class _FakeConnection:
            def __init__(self):
                self._calls = 0

            def poll(self, timeout=None):
                self._calls += 1
                return self._calls > 1

            def recv(self):
                return {
                    "kind": "result",
                    "result": {
                        "status": "success",
                        "code": "OK",
                        "msg": "Completed",
                    },
                }

            def close(self):
                return None

        class _FakeWriter:
            def close(self):
                return None

        class _FakeEvent:
            def set(self):
                return None

        class _FakeProcess:
            exitcode = 0

            def start(self):
                return None

            def is_alive(self):
                return False

            def join(self, timeout=None):
                return None

        class _FakeContext:
            def Pipe(self, duplex=False):
                self.duplex = duplex
                return _FakeConnection(), _FakeWriter()

            def Event(self):
                return _FakeEvent()

            def Process(self, target=None, args=None, daemon=None):
                return _FakeProcess()

        task = task_runtime._TaskRecord(
            task_id=123457,
            payload=json.dumps({"action": "echo"}),
        )
        with (
            patch.object(task_runtime, "_TASK_PROCESS_CONTEXT", _FakeContext()),
            patch.object(
                task_runtime,
                "_RESULT_CHANNEL_DRAIN_GRACE_SECONDS",
                0.1,
            ),
        ):
            task_runtime._run_task(task)

        self.assertTrue(task.done)
        self.assertEqual(task.result["status"], "success")
        self.assertEqual(task.result["msg"], "Completed")

    def test_receive_process_payload_handles_closed_connection(self):
        connection = MagicMock()
        connection.poll.return_value = True
        connection.recv.side_effect = EOFError

        self.assertIsNone(
            task_runtime._receive_process_payload(connection, -1.0),
        )
        connection.poll.assert_called_once_with(0.0)

    def test_metadata_and_engine_event_edge_cases(self):
        empty_metadata = {
            "action": None,
            "workflow_id": None,
            "operation_id": None,
            "client_operation_id": None,
            "idempotency_key": None,
        }
        self.assertEqual(
            task_runtime._parse_task_payload_metadata("{"),
            empty_metadata,
        )
        self.assertEqual(
            task_runtime._parse_task_payload_metadata("[]"),
            empty_metadata,
        )

        task = task_runtime._TaskRecord(1, "{}")
        task_runtime._emit_engine_event(task, "not-an-event")
        self.assertTrue(task.events.empty())

        task.done = True
        task_runtime._emit_engine_event(task, {"type": "ignored"})
        self.assertTrue(task.events.empty())

        task.done = False
        task_runtime._emit_engine_event(task, {"type": "added"})
        generated = task.events.get_nowait()
        self.assertEqual(generated["type"], "added")
        self.assertTrue(generated["ts"])

        task_runtime._emit_engine_event(
            task,
            {"type": "preserved", "ts": "existing"},
        )
        preserved = task.events.get_nowait()
        self.assertEqual(preserved["ts"], "existing")

    def test_failure_events_results_and_history_are_sanitized_at_storage(self):
        canary = "DD_TEST_SECRET_DO_NOT_LOG_7f4c"
        task = task_runtime._TaskRecord(
            700,
            json.dumps(
                {
                    "action": "run_workflow",
                    "workflow_id": "app",
                    "operation_id": "run",
                }
            ),
        )
        task_runtime._emit_engine_event(
            task,
            {
                "type": "operation_failed",
                "message": f"Authorization: Bearer {canary}",
                "data": {"runtime_env": {"FEATURE_FLAG": canary}},
            },
        )
        event = task.events.get_nowait()

        with (
            patch.object(task_runtime, "_task_history", []),
            patch.object(task_runtime, "_persist_task_history_locked"),
        ):
            task_runtime._store_task_result(
                task,
                {
                    "status": "error",
                    "code": "ENGINE_RUNTIME_ERROR",
                    "msg": f"Authorization: Bearer {canary}",
                    "details": f"runtime_env={{'FEATURE_FLAG': '{canary}'}}",
                    "runtime_env": {"FEATURE_FLAG": canary},
                },
            )
            history = list(task_runtime._task_history)

        self.assertNotIn(canary, repr(event))
        self.assertNotIn(canary, repr(task.result))
        self.assertNotIn(canary, repr(history))
        self.assertEqual(task.result["code"], "ENGINE_RUNTIME_ERROR")

    def test_success_result_preserves_explicit_credential_delivery_fields(self):
        task = task_runtime._TaskRecord(701, "{}")

        task_runtime._store_task_result(
            task,
            {
                "status": "success",
                "password": "credential-delivery-value",
            },
        )

        self.assertEqual(task.result["password"], "credential-delivery-value")

    def test_task_history_load_persist_and_retention_edges(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            history_path = Path(temp_dir) / "history.json"
            with patch.object(
                task_runtime,
                "_TASK_HISTORY_FILE",
                str(history_path),
            ):
                self.assertEqual(task_runtime._load_task_history(), [])

                history_path.write_text("{}", encoding="utf-8")
                self.assertEqual(task_runtime._load_task_history(), [])

                history_path.write_text(
                    json.dumps([{"task_id": 1}, "invalid"]),
                    encoding="utf-8",
                )
                self.assertEqual(
                    task_runtime._load_task_history(),
                    [{"task_id": 1}],
                )

                history_path.write_text("{", encoding="utf-8")
                self.assertEqual(task_runtime._load_task_history(), [])

        with patch("builtins.open", side_effect=OSError("read only")):
            task_runtime._persist_task_history_locked()

        task = task_runtime._TaskRecord(2, "{}")
        with (
            patch.object(task_runtime, "_task_history", []),
            patch.object(
                task_runtime,
                "_MAX_TASK_HISTORY",
                1,
            ),
            patch.object(task_runtime, "_persist_task_history_locked"),
        ):
            task_runtime._record_task_completion(task, "invalid")
            task_runtime._record_task_completion(
                task,
                {
                    "status": "success",
                    "code": "OK",
                    "msg": "done",
                    "worker_exit_code": True,
                },
            )
            self.assertEqual(len(task_runtime._task_history), 1)
            self.assertEqual(task_runtime._task_history[0]["status"], "success")
            self.assertIsNone(
                task_runtime._task_history[0]["worker_exit_code"],
            )

    def test_prune_tasks_skips_active_and_incomplete_completion_records(self):
        active = task_runtime._TaskRecord(10, "{}")
        incomplete = task_runtime._TaskRecord(11, "{}")
        incomplete.done = True
        fresh = task_runtime._TaskRecord(12, "{}")
        fresh.done = True
        fresh.completed_at_monotonic = 99.5
        stale = task_runtime._TaskRecord(13, "{}")
        stale.done = True
        stale.completed_at_monotonic = 0.0

        tasks = {
            10: active,
            11: incomplete,
            12: fresh,
            13: stale,
        }
        with (
            patch.object(task_runtime, "_tasks", tasks),
            patch.object(
                task_runtime.time,
                "monotonic",
                return_value=100.0,
            ),
            patch.object(
                task_runtime,
                "_COMPLETED_TASK_RETENTION_SECONDS",
                10.0,
            ),
        ):
            task_runtime._prune_tasks_locked()

        self.assertEqual(set(tasks), {10, 11, 12})

    def test_task_process_main_normalizes_events_errors_and_payloads(self):
        class _ResultConnection:
            def __init__(self):
                self.items = []
                self.closed = False

            def send(self, item):
                self.items.append(item)

            def close(self):
                self.closed = True

        cancel_event = MagicMock()
        cancel_event.is_set.return_value = False

        result_connection = _ResultConnection()

        def _emit_and_return_list(_payload, emit=None, is_cancelled=None):
            emit("ignored")
            emit({"type": "progress"})
            self.assertFalse(is_cancelled())
            return json.dumps(["not", "a", "mapping"])

        with (
            patch.object(
                task_runtime,
                "_engine_handle_request",
                side_effect=_emit_and_return_list,
            ),
            patch.object(
                task_runtime,
                "verify_process_hardening",
            ) as hardening_mock,
        ):
            task_runtime._task_process_main(
                "{}",
                result_connection,
                cancel_event,
            )

        hardening_mock.assert_called_once_with()

        self.assertEqual(result_connection.items[0]["kind"], "event")
        self.assertEqual(
            result_connection.items[1]["result"]["code"],
            "ENGINE_RUNTIME_ERROR",
        )
        self.assertTrue(result_connection.closed)

        failing_connection = _ResultConnection()
        with patch.object(
            task_runtime,
            "_engine_handle_request",
            side_effect=RuntimeError("engine failed"),
        ):
            task_runtime._task_process_main(
                "{}",
                failing_connection,
                cancel_event,
            )

        self.assertEqual(
            failing_connection.items[-1]["result"]["msg"],
            "engine failed",
        )
        self.assertTrue(failing_connection.closed)

    def test_finished_event_and_store_result_edge_cases(self):
        cancelled = task_runtime._task_finished_event_for_result(
            {
                "status": "error",
                "code": "ENGINE_TASK_CANCELLED",
                "msg": "cancelled",
            },
        )
        self.assertEqual(cancelled["message"], "cancelled")
        self.assertEqual(cancelled["level"], "warning")

        task = task_runtime._TaskRecord(20, "{}")
        task.done = True
        self.assertFalse(
            task_runtime._store_task_result(task, {"status": "success"}),
        )

        task.done = False
        with patch.object(task_runtime, "_record_task_completion") as record_mock:
            self.assertTrue(
                task_runtime._store_task_result(
                    task,
                    {"status": "success"},
                    emit_finished_event=False,
                ),
            )
        self.assertTrue(task.events.empty())
        record_mock.assert_called_once()

    def test_cleanup_task_runtime_resources_tolerates_cleanup_failures(self):
        process = MagicMock()
        process.join.side_effect = RuntimeError("join")
        result_connection = MagicMock()
        result_connection.close.side_effect = RuntimeError("close")
        cancel_event = MagicMock()
        cancel_event.set.side_effect = RuntimeError("set")
        task = task_runtime._TaskRecord(30, "{}")
        task.worker_process = process
        task.result_connection = result_connection
        task.cancel_event = cancel_event

        task_runtime._cleanup_task_runtime_resources(task)

        self.assertIsNone(task.worker_process)
        self.assertIsNone(task.result_connection)
        self.assertIsNone(task.cancel_event)

    def test_terminate_worker_process_covers_forced_and_failed_paths(self):
        task = task_runtime._TaskRecord(31, "{}")
        self.assertTrue(task_runtime._terminate_worker_process(task))

        stopped = MagicMock()
        stopped.is_alive.return_value = False
        task.worker_process = stopped
        self.assertTrue(task_runtime._terminate_worker_process(task))

        forced = MagicMock()
        forced.is_alive.side_effect = [True, True, False]
        forced.terminate.side_effect = RuntimeError("terminate")
        forced.join.side_effect = RuntimeError("join")
        forced.kill.side_effect = RuntimeError("kill")
        task.worker_process = forced
        self.assertTrue(task_runtime._terminate_worker_process(task))

        terminated = MagicMock()
        terminated.is_alive.side_effect = [True, False, False]
        task.worker_process = terminated
        self.assertTrue(task_runtime._terminate_worker_process(task))

        still_alive = MagicMock()
        still_alive.is_alive.return_value = True
        task.worker_process = still_alive
        self.assertFalse(task_runtime._terminate_worker_process(task))

    def test_terminate_worker_process_kills_real_spawned_worker(self):
        context = multiprocessing.get_context("spawn")
        worker = context.Process(target=time.sleep, args=(30.0,))
        worker.daemon = True
        worker.start()
        task = task_runtime._TaskRecord(80, "{}")
        task.worker_process = worker
        try:
            # A live spawned worker must exist here; otherwise the
            # termination below would prove nothing.
            self.assertTrue(worker.is_alive())
            self.assertTrue(task_runtime._terminate_worker_process(task))
            self.assertFalse(worker.is_alive())
        finally:
            if worker.is_alive():
                worker.kill()
                worker.join(timeout=5.0)

    def test_wait_for_cooperative_cancellation_paths(self):
        task = task_runtime._TaskRecord(32, "{}")
        task.done = True
        self.assertTrue(
            task_runtime._wait_for_cooperative_cancellation(task, 1.0),
        )

        task.done = False
        task.worker_process = None
        self.assertFalse(
            task_runtime._wait_for_cooperative_cancellation(task, 1.0),
        )

        stopped = MagicMock()
        stopped.is_alive.return_value = False
        task.worker_process = stopped
        self.assertFalse(
            task_runtime._wait_for_cooperative_cancellation(task, 1.0),
        )

        running = MagicMock()
        running.is_alive.return_value = True
        task.worker_process = running
        with (
            patch.object(
                task_runtime.time,
                "monotonic",
                side_effect=[0.0, 0.0, 2.0],
            ),
            patch.object(task_runtime.time, "sleep"),
        ):
            self.assertFalse(
                task_runtime._wait_for_cooperative_cancellation(task, 1.0),
            )

        task.done = True
        with patch.object(task_runtime.time, "monotonic", return_value=0.0):
            self.assertTrue(
                task_runtime._wait_for_cooperative_cancellation(task, 0.0),
            )

    def test_run_task_handles_precompleted_and_missing_connection(self):
        completed = task_runtime._TaskRecord(40, "{}")
        completed.done = True
        task_runtime._run_task(completed)

        writer = MagicMock()

        class _Context:
            def Pipe(self, duplex=False):
                return None, writer

            def Event(self):
                return MagicMock()

            def Process(self, **_kwargs):
                return MagicMock()

        task = task_runtime._TaskRecord(41, "{}")
        with patch.object(task_runtime, "_TASK_PROCESS_CONTEXT", _Context()):
            task_runtime._run_task(task)
        self.assertFalse(task.done)
        writer.close.assert_called_once_with()

    def test_run_task_stops_when_result_connection_is_cleared(self):
        task = task_runtime._TaskRecord(410, "{}")
        reader = MagicMock()
        writer = MagicMock()
        process = MagicMock()
        process.start.side_effect = lambda: setattr(
            task,
            "result_connection",
            None,
        )
        context = MagicMock()
        context.Pipe.return_value = (reader, writer)
        context.Event.return_value = MagicMock()
        context.Process.return_value = process

        with patch.object(task_runtime, "_TASK_PROCESS_CONTEXT", context):
            task_runtime._run_task(task)

        self.assertFalse(task.done)
        writer.close.assert_called_once_with()

    def test_run_task_handles_direct_channel_payload_variants(self):
        class _Connection:
            def __init__(self):
                self.items = [
                    "ignored",
                    {"kind": "event", "event": {"type": "progress"}},
                    {"kind": "unknown"},
                    {"kind": "result", "result": "invalid"},
                ]

            def poll(self, timeout=None):
                return True

            def recv(self):
                return self.items.pop(0)

            def close(self):
                return None

        class _Writer:
            def close(self):
                return None

        process = MagicMock()
        process.is_alive.return_value = True
        context = MagicMock()
        context.Pipe.return_value = (_Connection(), _Writer())
        context.Event.return_value = MagicMock()
        context.Process.return_value = process
        task = task_runtime._TaskRecord(42, "{}")

        with patch.object(task_runtime, "_TASK_PROCESS_CONTEXT", context):
            task_runtime._run_task(task)

        self.assertTrue(task.done)
        self.assertEqual(task.result["code"], "ENGINE_RUNTIME_ERROR")

    def test_run_task_handles_live_worker_empty_channel_and_context_failure(self):
        class _Connection:
            def __init__(self):
                self.calls = 0

            def poll(self, timeout=None):
                self.calls += 1
                return self.calls > 1

            def recv(self):
                return {
                    "kind": "result",
                    "result": {"status": "success", "msg": "done"},
                }

            def close(self):
                return None

        class _Writer:
            def close(self):
                return None

        process = MagicMock()
        process.is_alive.return_value = True
        context = MagicMock()
        context.Pipe.return_value = (_Connection(), _Writer())
        context.Event.return_value = MagicMock()
        context.Process.return_value = process
        task = task_runtime._TaskRecord(43, "{}")
        with patch.object(task_runtime, "_TASK_PROCESS_CONTEXT", context):
            task_runtime._run_task(task)
        self.assertEqual(task.result["status"], "success")

        failing_context = MagicMock()
        failing_context.Pipe.side_effect = RuntimeError("channel failed")
        failed = task_runtime._TaskRecord(44, "{}")
        with patch.object(
            task_runtime,
            "_TASK_PROCESS_CONTEXT",
            failing_context,
        ):
            task_runtime._run_task(failed)
        self.assertEqual(failed.result["msg"], "channel failed")

    def test_run_task_handles_drained_event_and_invalid_result(self):
        class _Connection:
            def __init__(self):
                self.poll_calls = 0
                self.items = [
                    {"kind": "event", "event": {"type": "drained"}},
                    {"kind": "result", "result": "invalid"},
                ]

            def poll(self, timeout=None):
                self.poll_calls += 1
                return self.poll_calls % 2 == 0

            def recv(self):
                return self.items.pop(0)

            def close(self):
                return None

        class _Writer:
            def close(self):
                return None

        process = MagicMock()
        process.exitcode = 0
        process.is_alive.return_value = False
        context = MagicMock()
        context.Pipe.return_value = (_Connection(), _Writer())
        context.Event.return_value = MagicMock()
        context.Process.return_value = process
        task = task_runtime._TaskRecord(45, "{}")
        with patch.object(task_runtime, "_TASK_PROCESS_CONTEXT", context):
            task_runtime._run_task(task)

        self.assertTrue(task.done)
        self.assertEqual(task.result["code"], "ENGINE_RUNTIME_ERROR")

    def test_run_task_unexpected_exit_without_exit_code(self):
        class _Connection:
            def poll(self, timeout=None):
                return False

            def close(self):
                return None

        class _Writer:
            def close(self):
                return None

        process = MagicMock()
        process.exitcode = None
        process.is_alive.return_value = False
        context = MagicMock()
        context.Pipe.return_value = (_Connection(), _Writer())
        context.Event.return_value = MagicMock()
        context.Process.return_value = process
        task = task_runtime._TaskRecord(46, "{}")
        with (
            patch.object(
                task_runtime,
                "_TASK_PROCESS_CONTEXT",
                context,
            ),
            patch.object(
                task_runtime,
                "_poll_result_connection_after_worker_exit",
                return_value={"kind": "unknown"},
            ),
        ):
            task_runtime._run_task(task)

        self.assertNotIn("Exit code", task.result["details"])

    def test_monitor_skips_missing_worker_and_recent_progress(self):
        task = task_runtime._TaskRecord(50, "{}")
        sleep_calls = 0

        def _finish_on_second_sleep(_seconds):
            nonlocal sleep_calls
            sleep_calls += 1
            if sleep_calls == 2:
                task.done = True

        with patch.object(
            task_runtime.time,
            "sleep",
            side_effect=_finish_on_second_sleep,
        ):
            task_runtime._monitor_task(task)

        task = task_runtime._TaskRecord(51, "{}")
        task.worker_process = MagicMock()
        sleep_calls = 0
        with (
            patch.object(
                task_runtime.time,
                "sleep",
                side_effect=_finish_on_second_sleep,
            ),
            patch.object(
                task_runtime.time,
                "monotonic",
                return_value=task.last_progress_at_monotonic,
            ),
        ):
            task_runtime._monitor_task(task)

    def test_poll_result_and_history_argument_edge_cases(self):
        task_id = 60
        task = task_runtime._TaskRecord(task_id, "{}")
        task.events.put({"type": "one"})
        with patch.dict(task_runtime._tasks, {task_id: task}):
            invalid_limit = json.loads(
                task_runtime.poll_task_events(task_id, "invalid"),
            )
            self.assertEqual(len(invalid_limit["events"]), 1)
            non_positive = json.loads(task_runtime.poll_task_events(task_id, 0))
            self.assertEqual(non_positive["events"], [])

            pending = json.loads(task_runtime.get_task_result(task_id))
            self.assertEqual(pending["status"], "pending")

        exhausted_task = task_runtime._TaskRecord(61, "{}")
        exhausted_task.events.put({"type": "only"})
        with patch.dict(task_runtime._tasks, {61: exhausted_task}):
            exhausted = json.loads(task_runtime.poll_task_events(61, 1))
        self.assertEqual(len(exhausted["events"]), 1)

        missing = json.loads(task_runtime.get_task_result(999999))
        self.assertEqual(missing["code"], "TASK_NOT_FOUND")

        with patch.object(
            task_runtime,
            "_task_history",
            [{"task_id": 1}, {"task_id": 2}],
        ):
            invalid_history = json.loads(
                task_runtime.get_recent_task_history("invalid"),
            )
            self.assertEqual(len(invalid_history["history"]), 2)
            one_history = json.loads(task_runtime.get_recent_task_history(0))
            self.assertEqual(len(one_history["history"]), 1)

    def test_cancel_completed_and_cooperative_tasks(self):
        task_id = 70
        completed = task_runtime._TaskRecord(task_id, "{}")
        completed.done = True
        with patch.dict(task_runtime._tasks, {task_id: completed}):
            response = json.loads(task_runtime.cancel_task(task_id))
        self.assertEqual(response["msg"], "Task already completed")

        cooperative = task_runtime._TaskRecord(71, "{}")
        cooperative.result = {
            "code": "ENGINE_TASK_CANCELLED",
        }
        cancel_event = MagicMock()
        cancel_event.set.side_effect = RuntimeError("set failed")
        cooperative.cancel_event = cancel_event
        with (
            patch.dict(
                task_runtime._tasks,
                {71: cooperative},
            ),
            patch.object(
                task_runtime,
                "_wait_for_cooperative_cancellation",
                return_value=True,
            ),
        ):
            response = json.loads(task_runtime.cancel_task(71))
        self.assertTrue(response["cancelled"])
        self.assertIn("cooperatively", response["msg"])
        self.assertTrue(cooperative.cooperative_cancel)

        finished = task_runtime._TaskRecord(72, "{}")
        finished.result = {"status": "success"}
        with (
            patch.dict(
                task_runtime._tasks,
                {72: finished},
            ),
            patch.object(
                task_runtime,
                "_wait_for_cooperative_cancellation",
                return_value=True,
            ),
        ):
            response = json.loads(task_runtime.cancel_task(72))
        self.assertIn("finished before", response["msg"])

    def test_cancel_forced_task_stores_forced_result(self):
        task_id = 73
        task = task_runtime._TaskRecord(task_id, "{}")
        with (
            patch.dict(
                task_runtime._tasks,
                {task_id: task},
            ),
            patch.object(
                task_runtime,
                "_wait_for_cooperative_cancellation",
                return_value=False,
            ),
            patch.object(
                task_runtime,
                "_terminate_worker_process",
                return_value=True,
            ),
        ):
            response = json.loads(task_runtime.cancel_task(task_id))

        self.assertTrue(response["cancelled"])
        self.assertEqual(
            task.result["code"],
            "ENGINE_TASK_CANCELLED_FORCED",
        )

    def _rigged_spawn_context(self):
        context = multiprocessing.get_context("spawn")

        def _forbidden(name):
            def _raise(*_args, **_kwargs):
                raise AssertionError(
                    f"task plumbing must not use context.{name} (no semaphores on macOS)",
                )

            return _raise

        for factory in (
            "Event",
            "Lock",
            "RLock",
            "Semaphore",
            "BoundedSemaphore",
            "Condition",
            "Barrier",
        ):
            patcher = patch.object(context, factory, _forbidden(factory))
            patcher.start()
            self.addCleanup(patcher.stop)
        return context

    def test_run_task_succeeds_without_context_synchronization_primitives(self):
        context = self._rigged_spawn_context()
        start = json.loads(task_runtime.start_task(_core_echo_payload("no-sem")))
        task_id = start["task_id"]
        with patch.object(task_runtime, "_TASK_PROCESS_CONTEXT", context):
            self._wait_until_done(task_id, timeout_seconds=10.0)
        result_payload = json.loads(task_runtime.get_task_result(task_id))
        self.assertEqual(result_payload["result"]["status"], "success")
        self.assertEqual(result_payload["result"]["data"], "no-sem")

    def test_cancel_signal_latches_set_and_tolerates_close(self):
        context = multiprocessing.get_context("spawn")
        signal = task_runtime._CancelSignal(context)
        self.assertFalse(signal.is_set())
        signal.set()
        self.assertTrue(signal.is_set())
        self.assertTrue(signal.is_set())
        signal.close_writer()
        signal.close_reader()
        signal.close_writer()
        signal.close_reader()
        self.assertFalse(signal.is_set())

    def test_cancel_signal_survives_spawn_pickling(self):
        context = multiprocessing.get_context("spawn")
        signal = task_runtime._CancelSignal(context)
        restored = pickle.loads(pickle.dumps(signal))
        self.assertFalse(restored.is_set())
        restored.set()
        self.assertTrue(restored.is_set())
        restored.close_reader()
        restored.close_writer()


if __name__ == "__main__":
    unittest.main()
