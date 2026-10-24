import unittest
from types import SimpleNamespace

from orchestrator.setup_parts.common import SetupStep, StepAction
from orchestrator.workflow_executor import (
    _failed_action_payload,
    _operation_failure_evidence,
    run_plan_execute,
    step_action_payloads,
)


class _FakeSession:
    def __init__(self, execution_payload):
        self.execution_payload = execution_payload
        self.registered_steps = None

    def register_steps_deploy(self, steps):
        self.registered_steps = steps

    def execute(self):
        return self.execution_payload


class _RegistrationFailureSession(_FakeSession):
    def register_steps_deploy(self, steps):
        raise RuntimeError("registration failed")


class TestWorkflowExecutor(unittest.TestCase):
    @staticmethod
    def _step():
        return SetupStep(
            id="step_1",
            title="Step 1",
            commands=[],
            part="part1",
        )

    def test_failed_action_payload_falls_back_to_first_action(self):
        step = SetupStep(
            id="step_1",
            title="Step 1",
            commands=[],
            part="part1",
            actions=[
                StepAction(
                    id="step_1_action_clone",
                    label="Clone repository",
                    description="Clone repository",
                ),
                StepAction(
                    id="step_1_action_build",
                    label="Build image",
                    description="Build image",
                ),
            ],
        )

        self.assertEqual(
            _failed_action_payload(step, {})["id"],
            "step_1_action_clone",
        )
        self.assertEqual(
            _failed_action_payload(
                step,
                {"failed_action_id": "step_1_action_missing"},
            )["id"],
            "step_1_action_clone",
        )

    def test_action_metadata_rejects_blank_ids_and_invalid_phases(self):
        """Fall back safely when producer metadata cannot identify an action phase."""
        step = SimpleNamespace(
            id="step_1",
            title="Step 1",
            actions=[SimpleNamespace(id=" ")],
        )
        self.assertEqual(
            step_action_payloads(step)[0]["id"],
            "step_1_action_default",
        )

        evidence = _operation_failure_evidence(
            {
                "step_id": "step_1",
                "failed_operation": {
                    "stdout": ["build failed on stdout"],
                    "stderr": [],
                },
            },
            {"id": "action_1", "failure_phase": None},
        )
        self.assertEqual(evidence.phase, "unknown")
        self.assertEqual(evidence.lines, ("build failed on stdout",))

    def test_run_plan_execute_emits_operation_output_lines(self):
        step = SetupStep(
            id="step_1",
            title="Step 1",
            commands=[],
            part="part1",
            actions=[
                StepAction(
                    id="step_1_action_first",
                    label="First action",
                    description="First action",
                ),
                StepAction(
                    id="step_1_action_second",
                    label="Second action",
                    description="Second action",
                ),
            ],
        )
        session = _FakeSession(
            {
                "operations": [
                    {
                        "step_id": "step_1",
                        "title": "Step 1",
                        "part": "part1",
                        "success": True,
                        "stdout": ["stdout line"],
                        "stderr": ["stderr line"],
                    }
                ],
                "run_error": None,
            }
        )

        events = []

        def emit_event(event_type, message, level="info", data=None):
            events.append(
                {
                    "type": event_type,
                    "message": message,
                    "level": level,
                    "data": data or {},
                }
            )

        result = run_plan_execute(
            session=session,
            steps=[step],
            parts=["part1"],
            summary_data={},
            emit_event=emit_event,
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(session.registered_steps, [step])
        self.assertTrue(
            any(
                event["type"] == "pyinfra_operation_stdout" and "stdout line" in event["message"]
                for event in events
            )
        )
        self.assertTrue(
            any(
                event["type"] == "pyinfra_operation_stderr" and "stderr line" in event["message"]
                for event in events
            )
        )

    def test_run_plan_execute_uses_failed_operation_action_id(self):
        step = SetupStep(
            id="step_1",
            title="Step 1",
            commands=[],
            part="part1",
            actions=[
                StepAction(
                    id="step_1_action_clone",
                    label="Clone repository",
                    description="Clone repository",
                ),
                StepAction(
                    id="step_1_action_build",
                    label="Build image",
                    description="Build image",
                ),
            ],
        )
        session = _FakeSession(
            {
                "operations": [
                    {
                        "step_id": "step_1",
                        "title": "Step 1",
                        "part": "part1",
                        "success": False,
                        "stdout": [],
                        "stderr": ["build failed"],
                        "failed_action_id": "step_1_action_build",
                    }
                ],
                "run_error": None,
            }
        )

        events = []

        def emit_event(event_type, message, level="info", data=None):
            events.append(
                {
                    "type": event_type,
                    "message": message,
                    "level": level,
                    "data": data or {},
                }
            )

        result = run_plan_execute(
            session=session,
            steps=[step],
            parts=["part1"],
            summary_data={},
            emit_event=emit_event,
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["failed_action_id"], "step_1_action_build")
        action_errors = [event for event in events if event["type"] == "action_error"]
        self.assertEqual(len(action_errors), 1)
        self.assertEqual(action_errors[0]["message"], "Failed action: Build image")
        self.assertEqual(
            action_errors[0]["data"]["action_id"],
            "step_1_action_build",
        )

    def test_run_plan_execute_selects_only_failed_action_evidence(self):
        """Attach diagnostic evidence from the failed action and its declared phase."""
        build_action = StepAction(
            id="step_1_action_build",
            label="Build image",
            description="Build image",
        )
        build_action.failure_phase = "build"
        step = SetupStep(
            id="step_1",
            title="Step 1",
            commands=[],
            part="part1",
            actions=[build_action],
        )
        session = _FakeSession(
            {
                "operations": [
                    {
                        "step_id": "step_1",
                        "title": "Step 1",
                        "part": "part1",
                        "success": False,
                        "stdout": ["earlier success noise"],
                        "stderr": ["earlier warning noise"],
                        "failed_action_id": "step_1_action_build",
                        "failed_operation": {
                            "action_id": "step_1_action_build",
                            "stdout": [],
                            "stderr": ["fatal: build failed"],
                        },
                    }
                ],
                "run_error": None,
            }
        )

        result = run_plan_execute(
            session=session,
            steps=[step],
            parts=["part1"],
            summary_data={},
        )

        self.assertEqual(result["details"], "fatal: build failed")
        self.assertEqual(
            result["failure_evidence"],
            {
                "schema_version": 1,
                "phase": "build",
                "source": "failed_operation",
                "completeness": "diagnostic",
                "lines": ["fatal: build failed"],
                "failed_step_id": "step_1",
                "failed_action_id": "step_1_action_build",
                "probe": None,
            },
        )

    def test_run_plan_execute_marks_empty_failed_action_at_the_boundary(self):
        """Represent a reached failure boundary even when pyinfra captured no output."""
        step = self._step()
        result = run_plan_execute(
            session=_FakeSession(
                {
                    "operations": [
                        {
                            "step_id": "step_1",
                            "title": "Step 1",
                            "part": "part1",
                            "success": False,
                            "stdout": [],
                            "stderr": [],
                            "failed_action_id": None,
                            "failed_operation": {
                                "action_id": None,
                                "stdout": [],
                                "stderr": [],
                            },
                        }
                    ],
                    "run_error": None,
                }
            ),
            steps=[step],
            parts=["part1"],
            summary_data={},
        )

        self.assertEqual(result["failure_evidence"]["phase"], "unknown")
        self.assertEqual(result["failure_evidence"]["source"], "none")
        self.assertEqual(result["failure_evidence"]["completeness"], "boundary_only")
        self.assertEqual(result["failure_evidence"]["lines"], [])
        self.assertEqual(result["failure_evidence"]["failed_step_id"], "step_1")
        self.assertEqual(
            result["failure_evidence"]["failed_action_id"],
            "step_1_action_default",
        )
        self.assertIsNone(result["failure_evidence"]["probe"])

    def test_run_plan_execute_reports_cancellation_before_registration(self):
        events = []

        result = run_plan_execute(
            session=_FakeSession({}),
            steps=[self._step()],
            parts=["part1"],
            summary_data={},
            emit_event=lambda event_type, message, **kwargs: events.append(
                (event_type, message, kwargs)
            ),
            is_cancelled=lambda: True,
        )

        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(result["stage"], "prepare_operations")
        self.assertNotIn("failure_evidence", result)
        cancelled_event = next(event for event in events if event[0] == "task_cancelled")
        self.assertEqual(cancelled_event[2]["level"], "warning")

    def test_run_plan_execute_reports_registration_failure(self):
        events = []

        result = run_plan_execute(
            session=_RegistrationFailureSession({}),
            steps=[self._step()],
            parts=["part1"],
            summary_data={},
            emit_event=lambda event_type, message, **kwargs: events.append(
                (event_type, message, kwargs)
            ),
        )

        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["details"], "registration failed")
        self.assertEqual(
            result["failure_evidence"],
            {
                "schema_version": 1,
                "phase": "engine",
                "source": "none",
                "completeness": "unavailable",
                "lines": [],
                "failed_step_id": None,
                "failed_action_id": None,
                "probe": None,
            },
        )
        self.assertEqual(events[-1][0], "runtime_error")
        self.assertEqual(events[-1][2]["level"], "error")

    def test_run_plan_execute_reports_runtime_failure(self):
        events = []
        session = _FakeSession(
            {
                "operations": [],
                "run_error": "runtime failed",
            }
        )

        result = run_plan_execute(
            session=session,
            steps=[self._step()],
            parts=["part1"],
            summary_data={},
            emit_event=lambda event_type, message, **kwargs: events.append(
                (event_type, message, kwargs)
            ),
        )

        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["details"], "runtime failed")
        self.assertEqual(
            result["failure_evidence"],
            {
                "schema_version": 1,
                "phase": "engine",
                "source": "none",
                "completeness": "unavailable",
                "lines": [],
                "failed_step_id": None,
                "failed_action_id": None,
                "probe": None,
            },
        )
        self.assertEqual(events[-1][0], "runtime_error")
        self.assertEqual(events[-1][2]["level"], "error")

    def test_run_plan_execute_handles_silent_and_unknown_boundaries(self):
        """Preserve evidence when callers omit events or runtime step metadata is stale."""
        cancelled = run_plan_execute(
            session=_FakeSession({}),
            steps=[self._step()],
            parts=["part1"],
            summary_data={},
            is_cancelled=lambda: True,
        )
        registration = run_plan_execute(
            session=_RegistrationFailureSession({}),
            steps=[self._step()],
            parts=["part1"],
            summary_data={},
        )
        runtime = run_plan_execute(
            session=_FakeSession({"operations": [], "run_error": "runtime failed"}),
            steps=[self._step()],
            parts=["part1"],
            summary_data={},
        )
        multi_action_step = SetupStep(
            id="step_1",
            title="Step 1",
            commands=[],
            part="part1",
            actions=[
                StepAction(id="action_1", label="One", description="One"),
                StepAction(id="action_2", label="Two", description="Two"),
            ],
        )
        unknown_failure = run_plan_execute(
            session=_FakeSession(
                {
                    "operations": [
                        {
                            "step_id": "step_1",
                            "success": True,
                            "stdout": [],
                            "stderr": [],
                        },
                        {
                            "step_id": "completed_step_missing_from_plan",
                            "success": True,
                            "stdout": [],
                            "stderr": [],
                        },
                        {
                            "step_id": "failed_step_missing_from_plan",
                            "success": False,
                            "stdout": [],
                            "stderr": [],
                            "failed_operation": {
                                "stdout": ["fatal from an unknown step"],
                                "stderr": [],
                            },
                        },
                    ],
                    "run_error": None,
                }
            ),
            steps=[multi_action_step],
            parts=["part1"],
            summary_data={},
        )

        self.assertEqual(cancelled["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(registration["failure_evidence"]["completeness"], "unavailable")
        self.assertEqual(runtime["failure_evidence"]["completeness"], "unavailable")
        self.assertEqual(unknown_failure["details"], "fatal from an unknown step")
        self.assertIsNone(unknown_failure["failure_evidence"]["failed_action_id"])


if __name__ == "__main__":
    unittest.main()
