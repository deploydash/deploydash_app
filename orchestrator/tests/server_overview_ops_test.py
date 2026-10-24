import unittest
from unittest.mock import patch

from orchestrator.infra_parts import overview as engine_infra_ops
from tests.engine_context_fixtures import build_test_context


class _FakeOutput:
    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


class _FakeHost:
    def __init__(self, responses):
        self._responses = list(responses)
        self.commands = []

    def run_shell_command(self, command, _timeout=10, _sudo=False):
        self.commands.append((command, _timeout, _sudo))
        return self._responses.pop(0)


class _FakeSession:
    def __init__(self, host):
        self.host = host

    def close(self):
        return {"disconnect_error": None}


class _FakeSessionWithDisconnect(_FakeSession):
    def close(self):
        return {"disconnect_error": "disconnect failed"}


def _error_result(code, msg, stage=None, details=None, extra=None):
    return {
        "status": "error",
        "code": code,
        "msg": msg,
        "stage": stage,
        "details": details,
        "extra": extra or {},
    }


class TestServerOverviewOps(unittest.TestCase):
    def test_overview_operation_honors_preflight_cancellation(self):
        ctx = build_test_context(error_result=_error_result)
        result = engine_infra_ops.run_server_overview_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            is_cancelled=lambda: True,
        )

        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(result["stage"], "preflight")

    def test_overview_operation_returns_open_session_error(self):
        open_error = _error_result(
            "ENGINE_CONNECTION_FAILED",
            "Could not connect.",
            stage="open_runtime_session",
        )
        ctx = build_test_context(
            error_result=_error_result,
            open_runtime_session=lambda **_kwargs: {"ok": False, "error": open_error},
        )
        result = engine_infra_ops.run_server_overview_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
        )

        self.assertEqual(result, open_error)

    def test_overview_operation_honors_runtime_cancellation(self):
        host = _FakeHost(
            [
                (True, _FakeOutput()),
            ]
        )
        cancel_checks = {"count": 0}

        def is_cancelled():
            cancel_checks["count"] += 1
            return cancel_checks["count"] > 1

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host),
            },
        )
        result = engine_infra_ops.run_server_overview_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            is_cancelled=is_cancelled,
        )

        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(result["stage"], "execute_runtime_operation")
        self.assertEqual(len(host.commands), 0)

    def test_overview_operation_returns_runtime_error_for_failed_command(self):
        host = _FakeHost(
            [
                (True, _FakeOutput()),
                (False, _FakeOutput(stderr_lines=["collect failed"])),
            ]
        )

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "collect failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host),
            },
        )
        with patch.object(
            engine_infra_ops,
            "_parse_server_overview_metrics_output",
            lambda _output: {"cpu": {}},
        ):
            result = engine_infra_ops.run_server_overview_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
            )

        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["details"], "collect failed")
        self.assertEqual(result["stage"], "execute_runtime_operation")

    def test_overview_operation_reports_disconnect_error_after_success(self):
        host = _FakeHost([(True, _FakeOutput()), (True, _FakeOutput())])
        emitted = []
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda emit, event_type, message, level="info", data=None: emit(
                {
                    "type": event_type,
                    "message": message,
                    "level": level,
                    "data": data or {},
                }
            ),
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSessionWithDisconnect(host),
            },
        )

        with patch.object(
            engine_infra_ops,
            "_parse_server_overview_metrics_output",
            lambda _output: {"cpu": {}},
        ):
            result = engine_infra_ops.run_server_overview_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                emit=emitted.append,
            )

        self.assertEqual(result["status"], "success")
        self.assertEqual(emitted[-1]["type"], "connection_disconnect_error")
        self.assertEqual(emitted[-1]["level"], "warning")


if __name__ == "__main__":
    unittest.main()
