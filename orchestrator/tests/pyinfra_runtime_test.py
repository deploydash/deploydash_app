import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from pyinfra import logger as pyinfra_logger
from pyinfra.api import Config, Inventory, State
from pyinfra.api.connect import connect_all
from pyinfra.operations import files, server

from orchestrator.pyinfra_runtime import (
    PyinfraRuntimeSession,
    _bounded_failure_lines,
    _PyinfraLogHandler,
    _StateEventCallback,
    create_runtime_session,
)
from orchestrator.setup_parts.common import SetupStep


def _build_local_session():
    inventory = Inventory((["@local"], {}))
    state = State(inventory=inventory, config=Config())
    connect_all(state)

    log_handler = _PyinfraLogHandler(None)
    pyinfra_logger.addHandler(log_handler)

    return PyinfraRuntimeSession(
        state=state,
        host_name="@local",
        emit_event=None,
        log_handler=log_handler,
    )


class TestPyinfraRuntimeSession(unittest.TestCase):
    def setUp(self):
        self._temp_dir = tempfile.TemporaryDirectory()
        self.base_path = Path(self._temp_dir.name)

    def tearDown(self):
        self._temp_dir.cleanup()

    def _run_step(self, step):
        session = _build_local_session()
        try:
            session.register_steps_deploy([step])
            result = session.execute()
            self.assertEqual(result["error_ops"], 0)
            self.assertEqual(result["run_error"], None)
            self.assertEqual(len(result["operations"]), 1)
            return result["operations"][0]
        finally:
            session.close()

    def test_idempotent_step_change_reporting(self):
        target_file = self.base_path / "idempotent.txt"

        def register(runtime):
            runtime.add_operation(
                files.file,
                path=str(target_file),
                mode="600",
            )

        step = SetupStep(
            id="idempotent_file_step",
            title="Idempotent file step",
            part="test",
            commands=[],
            register=register,
        )

        first_run = self._run_step(step)
        self.assertTrue(first_run["success"])
        self.assertTrue(first_run["changed"])
        self.assertNotIn("op_hash", first_run)
        self.assertNotIn("op_hashes", first_run)

        second_run = self._run_step(step)
        self.assertTrue(second_run["success"])
        self.assertFalse(second_run["changed"])
        self.assertNotIn("op_hash", second_run)
        self.assertNotIn("op_hashes", second_run)

    def test_if_gated_followup_operation(self):
        target_file = self.base_path / "gated_step.conf"

        def register(runtime):
            runtime.add_operation(
                files.file,
                path=str(target_file),
                mode="644",
            )
            primary_line = runtime.add_operation(
                files.line,
                path=str(target_file),
                line=r"^MODE=.*$",
                replace="MODE=secure",
            )
            runtime.add_operation(
                files.line,
                path=str(target_file),
                line=r"^LAST_UPDATED=.*$",
                replace="LAST_UPDATED=true",
                _if=primary_line.did_change,
            )

        step = SetupStep(
            id="if_gate_step",
            title="If gate step",
            part="test",
            commands=[],
            register=register,
        )

        first_run = self._run_step(step)
        self.assertTrue(first_run["success"])
        self.assertTrue(first_run["changed"])
        self.assertNotIn("op_hashes", first_run)
        self.assertIn("MODE=secure", target_file.read_text())
        self.assertIn("LAST_UPDATED=true", target_file.read_text())

        second_run = self._run_step(step)
        self.assertTrue(second_run["success"])
        self.assertFalse(second_run["changed"])
        self.assertNotIn("op_hashes", second_run)

    def test_run_once_registers_single_operation(self):
        target_file = self.base_path / "run_once.txt"

        def register(runtime):
            runtime.run_once(
                "test:shared:file",
                lambda: runtime.add_operation(
                    files.file,
                    path=str(target_file),
                    mode="600",
                ),
            )
            runtime.run_once(
                "test:shared:file",
                lambda: runtime.add_operation(
                    files.file,
                    path=str(target_file),
                    mode="600",
                ),
            )

        step = SetupStep(
            id="run_once_step",
            title="Run once step",
            part="test",
            commands=[],
            register=register,
        )

        result = self._run_step(step)
        self.assertTrue(result["success"])
        self.assertNotIn("op_hash", result)
        self.assertNotIn("op_hashes", result)

    def test_failed_operation_reports_action_id(self):
        def register(runtime):
            runtime.add_operation(
                server.shell,
                commands=["true"],
                deploydash_action_id="step_action_first",
            )
            runtime.add_operation(
                server.shell,
                commands=["false"],
                deploydash_action_id="step_action_second",
            )

        step = SetupStep(
            id="action_step",
            title="Action step",
            part="test",
            commands=[],
            register=register,
        )

        session = _build_local_session()
        try:
            session.register_steps_deploy([step])
            result = session.execute()
            self.assertEqual(len(result["operations"]), 1)
            operation = result["operations"][0]
            self.assertFalse(operation["success"])
            self.assertEqual(
                operation["failed_action_id"],
                "step_action_second",
            )
        finally:
            session.close()

    def test_failed_operation_output_is_bounded_to_the_failed_action(self):
        """Keep successful action output out of the bounded failure record."""

        def register(runtime):
            runtime.add_operation(
                server.shell,
                commands=["printf 'earlier success noise\\n'"],
                deploydash_action_id="step_action_first",
            )
            runtime.add_operation(
                server.shell,
                commands=[
                    "for index in $(seq 1 90); do "
                    "printf 'failed line %s\\n' \"$index\" >&2; done; false"
                ],
                deploydash_action_id="step_action_second",
            )

        step = SetupStep(
            id="action_step",
            title="Action step",
            part="test",
            commands=[],
            register=register,
        )

        session = _build_local_session()
        try:
            session.register_steps_deploy([step])
            result = session.execute()
            failed_operation = result["operations"][0]["failed_operation"]

            self.assertEqual(failed_operation["action_id"], "step_action_second")
            self.assertEqual(failed_operation["stdout"], [])
            self.assertEqual(len(failed_operation["stderr"]), 80)
            self.assertEqual(failed_operation["stderr"][0], "failed line 11")
            self.assertEqual(failed_operation["stderr"][-1], "failed line 90")
            self.assertNotIn("earlier success noise", failed_operation["stderr"])
        finally:
            session.close()

    def test_failed_operation_and_event_stream_share_sanitized_lines(self):
        """Expose the same redacted line to the executor event and evidence paths."""

        def register(runtime):
            runtime.add_operation(
                server.shell,
                commands=["printf 'fatal TOKEN=secret-canary\\n' >&2; false"],
                deploydash_action_id="step_action_failed",
            )

        step = SetupStep(
            id="sanitized_action_step",
            title="Sanitized action step",
            part="test",
            commands=[],
            register=register,
        )

        session = _build_local_session()
        try:
            session.register_steps_deploy([step])
            operation = session.execute()["operations"][0]

            self.assertEqual(operation["stderr"], operation["failed_operation"]["stderr"])
            self.assertEqual(operation["stderr"], ["fatal TOKEN=***"])
            self.assertNotIn("secret-canary", repr(operation))
        finally:
            session.close()

    def test_bounded_failure_lines_fail_closed_when_sanitization_breaks(self):
        """Return no diagnostic text if the shared sanitizer cannot process it."""
        with patch(
            "orchestrator.pyinfra_runtime.sanitize_text",
            side_effect=RuntimeError("sanitizer failed"),
        ):
            self.assertEqual(_bounded_failure_lines(["unsafe"]), [])

    def test_add_operation_requires_active_step(self):
        session = _build_local_session()
        try:
            with self.assertRaisesRegex(RuntimeError, "without an active step"):
                session.add_operation(files.file, path=str(self.base_path / "x"))
        finally:
            session.close()

    def test_add_operation_raises_when_metadata_missing(self):
        session = _build_local_session()
        try:
            session._set_active_step(
                SimpleNamespace(id="s1", part="p1", title="step"),
            )
            with self.assertRaisesRegex(RuntimeError, "No operation metadata"):
                session.add_operation(lambda **_kwargs: None)
        finally:
            session._clear_active_step()
            session.close()

    def test_add_operation_accepts_metadata_without_private_hash(self):
        session = _build_local_session()
        try:
            session._set_active_step(
                SimpleNamespace(id="s1", part="p1", title="step"),
            )
            operation_meta = SimpleNamespace()
            result = session.add_operation(lambda **_kwargs: operation_meta)
            self.assertIs(result, operation_meta)
            self.assertEqual(len(session._operations), 1)
        finally:
            session._clear_active_step()
            session.close()

    def test_execute_returns_run_error_when_run_ops_raises(self):
        session = _build_local_session()
        try:
            with patch(
                "orchestrator.pyinfra_runtime.run_ops",
                side_effect=RuntimeError("boom"),
            ):
                result = session.execute()
            self.assertEqual(result["run_error"], "boom")
        finally:
            session.close()

    def test_close_reports_disconnect_error(self):
        session = _build_local_session()
        with patch(
            "orchestrator.pyinfra_runtime.disconnect_all",
            side_effect=RuntimeError("disconnect"),
        ):
            result = session.close()
        self.assertEqual(result["disconnect_error"], "disconnect")

    def test_collect_operation_results_handles_broken_and_unregistered_metadata(self):
        class IncompleteMetadata:
            def is_complete(self):
                raise RuntimeError("completion unavailable")

        class BrokenCompleteMetadata:
            def is_complete(self):
                return True

            def did_succeed(self):
                raise RuntimeError("success unavailable")

            def did_change(self):
                raise RuntimeError("change unavailable")

            @property
            def stdout_lines(self):
                raise RuntimeError("stdout unavailable")

            @property
            def stderr_lines(self):
                raise RuntimeError("stderr unavailable")

        session = _build_local_session()
        try:
            session._step_sequence = [("known", "part1", "Known step")]
            session._operations = [
                SimpleNamespace(
                    step_id="known",
                    part="part1",
                    title="Known step",
                    action_id="known_action",
                    operation_meta=IncompleteMetadata(),
                ),
                SimpleNamespace(
                    step_id="unregistered",
                    part="part2",
                    title="Unregistered step",
                    action_id="unregistered_action",
                    operation_meta=BrokenCompleteMetadata(),
                ),
            ]

            results = session._collect_operation_results()

            self.assertEqual(
                [result["step_id"] for result in results],
                ["known", "unregistered"],
            )
            self.assertFalse(results[0]["complete"])
            self.assertTrue(results[1]["complete"])
            for result in results:
                self.assertFalse(result["success"])
                self.assertFalse(result["changed"])
                self.assertEqual(result["stdout"], [])
                self.assertEqual(result["stderr"], [])
                self.assertIsNotNone(result["failed_action_id"])
        finally:
            session.close()

    def test_collect_operation_results_sanitizes_streams_before_returning_them(self):
        canary = "DD_TEST_SECRET_DO_NOT_LOG_7f4c"
        metadata = SimpleNamespace(
            is_complete=lambda: True,
            did_succeed=lambda: False,
            did_change=lambda: False,
            stdout_lines=[f"Authorization: Bearer {canary}"],
            stderr_lines=[
                "runtime_env={'FEATURE_FLAG': '" + canary + "'}",
                "compiler=/workspace/lib/main.dart code=ERR_BUILD_42",
            ],
        )
        session = _build_local_session()
        try:
            session._step_sequence = [("release", "app", "Build release")]
            session._operations = [
                SimpleNamespace(
                    step_id="release",
                    part="app",
                    title="Build release",
                    action_id="build_release",
                    operation_meta=metadata,
                )
            ]

            result = session._collect_operation_results()[0]

            self.assertNotIn(canary, repr(result))
            self.assertEqual(result["stdout"], ["Authorization: Bearer ***"])
            self.assertEqual(
                result["stderr"][-1],
                "compiler=/workspace/lib/main.dart code=ERR_BUILD_42",
            )
        finally:
            session.close()


class _FakeState:
    def __init__(self, op_meta):
        self._op_meta = op_meta

    def get_op_meta(self, _op_hash):
        if isinstance(self._op_meta, Exception):
            raise self._op_meta
        return self._op_meta


class _UnreadableOperationStreams:
    def __init__(self):
        self.names = {"operation"}

    @property
    def stdout_lines(self):
        raise RuntimeError("stdout is unavailable")

    @property
    def stderr_lines(self):
        raise RuntimeError("stderr is unavailable")


class TestPyinfraCallbacks(unittest.TestCase):
    def test_display_operation_name_parses_pipe_separator(self):
        op_meta = SimpleNamespace(names={"part1 | final operation"})
        state = _FakeState(op_meta)
        display = _StateEventCallback._display_operation_name(state, "op-1")
        self.assertEqual(display, "final operation")

    def test_display_operation_name_uses_generic_fallback_without_metadata(self):
        state = _FakeState(RuntimeError("missing"))
        display = _StateEventCallback._display_operation_name(state, "op-1")
        self.assertEqual(display, "operation")

    def test_display_operation_name_uses_generic_fallback_without_names(self):
        op_meta = SimpleNamespace(names=set())
        state = _FakeState(op_meta)
        display = _StateEventCallback._display_operation_name(state, "op-1")
        self.assertEqual(display, "operation")

    def test_emit_operation_output_publishes_stdout_and_stderr(self):
        events = []

        def emit(event_type, message, level="info", data=None):
            events.append((event_type, message, level, data))

        callback = _StateEventCallback(emit)
        op_meta = SimpleNamespace(
            names={"operation"},
            stdout_lines=["ok line", ""],
            stderr_lines=["warn line", ""],
        )
        state = _FakeState(op_meta)
        callback.operation_end(state, "op-hash")

        event_types = [event[0] for event in events]
        self.assertIn("pyinfra_operation_stdout", event_types)
        self.assertIn("pyinfra_operation_stderr", event_types)
        self.assertIn("pyinfra_operation_end", event_types)

        stdout_event = next(event for event in events if event[0] == "pyinfra_operation_stdout")
        stderr_event = next(event for event in events if event[0] == "pyinfra_operation_stderr")
        end_event = next(event for event in events if event[0] == "pyinfra_operation_end")
        self.assertEqual(stdout_event[3]["name"], "operation")
        self.assertEqual(stdout_event[3]["stream"], "stdout")
        self.assertEqual(stderr_event[3]["name"], "operation")
        self.assertEqual(stderr_event[3]["stream"], "stderr")
        self.assertEqual(end_event[3]["name"], "operation")
        self.assertEqual(
            len([event for event in events if event[0] == "pyinfra_operation_stderr"]),
            1,
        )

        for event_type, _message, _level, data in events:
            if event_type.startswith("pyinfra_operation_"):
                self.assertNotIn("op_hash", data or {})

    def test_emit_operation_output_ignores_missing_metadata(self):
        events = []
        callback = _StateEventCallback(lambda *args, **kwargs: events.append(args))

        callback._emit_operation_output(
            _FakeState(RuntimeError("missing metadata")),
            "server-1",
            "op-hash",
            "operation",
        )

        self.assertEqual(events, [])

    def test_emit_operation_output_ignores_unreadable_streams(self):
        events = []
        callback = _StateEventCallback(lambda *args, **kwargs: events.append(args))

        callback._emit_operation_output(
            _FakeState(_UnreadableOperationStreams()),
            "server-1",
            "op-hash",
            "operation",
        )

        self.assertEqual(events, [])

    def test_log_handler_filters_noisy_messages(self):
        events = []

        def emit(event_type, message, level="info", data=None):
            events.append((event_type, message, level, data))

        handler = _PyinfraLogHandler(emit)
        noisy = pyinfra_logger.makeRecord(
            "pyinfra",
            20,
            __file__,
            1,
            "Authentication error while connecting",
            (),
            None,
        )
        handler.emit(noisy)
        self.assertEqual(events, [])

        normal = pyinfra_logger.makeRecord(
            "pyinfra",
            20,
            __file__,
            1,
            "Command finished successfully",
            (),
            None,
        )
        handler.emit(normal)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0][0], "pyinfra_log")
        self.assertIn("Command finished successfully", events[0][1])

    def test_state_callback_emits_core_operation_events(self):
        events = []

        def emit(event_type, message, level="info", data=None):
            events.append((event_type, message, level, data))

        callback = _StateEventCallback(emit)
        op_meta = SimpleNamespace(names={"part | my-op"}, stdout_lines=[], stderr_lines=[])
        state = _FakeState(op_meta)
        host = SimpleNamespace(name="server-1")

        callback.host_before_connect(state, host)
        callback.host_connect(state, host)
        callback.operation_start(state, "op-1")
        callback.operation_host_start(state, host, "op-1")
        callback.operation_host_success(state, host, "op-1", retry_count=1)
        callback.operation_host_error(state, host, "op-1", retry_count=1, max_retries=3)
        callback.operation_host_retry(state, host, "op-1", 2, 3)
        callback.host_disconnect(state, host)

        event_types = [event[0] for event in events]
        self.assertIn("pyinfra_host_before_connect", event_types)
        self.assertIn("pyinfra_host_connected", event_types)
        self.assertIn("pyinfra_operation_start", event_types)
        self.assertIn("pyinfra_operation_host_start", event_types)
        self.assertIn("pyinfra_operation_host_success", event_types)
        self.assertIn("pyinfra_operation_host_error", event_types)
        self.assertIn("pyinfra_operation_host_retry", event_types)
        self.assertIn("pyinfra_host_disconnected", event_types)

        operation_events = [event for event in events if event[0].startswith("pyinfra_operation_")]
        self.assertTrue(operation_events)
        for _event_type, _message, _level, data in operation_events:
            self.assertEqual(data.get("name"), "my-op")
            if "host" in data:
                self.assertEqual(data["host"], "server-1")

        for event_type, _message, _level, data in events:
            if event_type.startswith("pyinfra_operation_"):
                self.assertNotIn("op_hash", data or {})


class _FakeCreateInventory:
    def get_host(self, host_name):
        return SimpleNamespace(name=host_name)


class _FakeCreateState:
    def __init__(self):
        self.inventory = _FakeCreateInventory()
        self.callbacks = []

    def add_callback_handler(self, callback):
        self.callbacks.append(callback)


class TestCreateRuntimeSession(unittest.TestCase):
    def test_create_runtime_session_uses_env_connect_timeout(self):
        fake_state = _FakeCreateState()
        captured_config = {}

        def _fake_config(**kwargs):
            captured_config.update(kwargs)
            return SimpleNamespace(**kwargs)

        with (
            patch(
                "orchestrator.pyinfra_runtime.Inventory",
                return_value=SimpleNamespace(),
            ),
            patch(
                "orchestrator.pyinfra_runtime.Config",
                side_effect=_fake_config,
            ),
            patch(
                "orchestrator.pyinfra_runtime.State",
                return_value=fake_state,
            ),
            patch(
                "orchestrator.pyinfra_runtime.connect_all",
                return_value=None,
            ),
            patch.dict(
                "os.environ",
                {"DEPLOYDASH_SSH_CONNECT_TIMEOUT": "7"},
                clear=False,
            ),
        ):
            session = create_runtime_session(
                host_name="server-1",
                connector_data={"ssh_hostname": "198.51.100.10"},
            )

        self.assertIsInstance(session, PyinfraRuntimeSession)
        self.assertEqual(captured_config["CONNECT_TIMEOUT"], 7)
        session.close()

    def test_create_runtime_session_falls_back_on_invalid_timeout(self):
        fake_state = _FakeCreateState()
        captured_config = {}

        def _fake_config(**kwargs):
            captured_config.update(kwargs)
            return SimpleNamespace(**kwargs)

        with (
            patch(
                "orchestrator.pyinfra_runtime.Inventory",
                return_value=SimpleNamespace(),
            ),
            patch(
                "orchestrator.pyinfra_runtime.Config",
                side_effect=_fake_config,
            ),
            patch(
                "orchestrator.pyinfra_runtime.State",
                return_value=fake_state,
            ),
            patch(
                "orchestrator.pyinfra_runtime.connect_all",
                return_value=None,
            ),
            patch.dict(
                "os.environ",
                {"DEPLOYDASH_SSH_CONNECT_TIMEOUT": "not-int"},
                clear=False,
            ),
        ):
            session = create_runtime_session(
                host_name="server-1",
                connector_data={"ssh_hostname": "198.51.100.10"},
            )

        self.assertEqual(captured_config["CONNECT_TIMEOUT"], 4)
        session.close()


if __name__ == "__main__":
    unittest.main()
