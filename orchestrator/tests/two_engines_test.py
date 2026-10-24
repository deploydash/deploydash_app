"""T-2.2.9 acceptance test for the whole T-2.2 engine-DI migration group.

Two engine instances -- two independently constructed `EngineContext`
objects, each wired to its own fake host -- must not share any state.
Before T-2.2.2-T-2.2.8, every `engine_*_ops.py` module kept its runtime
dependencies as module globals (`_open_runtime_session = None`, etc.) set by
`configure_runtime_dependencies()`. Under that design, constructing a second
"engine" and calling an operation on it would silently overwrite the first
engine's globals, so an *interleaved* call back on the first engine would
route through the second engine's host. That failure mode is what this test
targets, not merely "two different Python objects stay different objects,"
which would be true and uninteresting even with the shared-global bug still
present.
"""

import unittest

from orchestrator import engine_postgres_ops
from tests.engine_context_fixtures import build_test_context


class _FakeOutput:
    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


class _RecordingHost:
    def __init__(self, version):
        self.commands = []
        self._status_output = _FakeOutput(
            stdout_lines=[
                f'{{"running":true,"health":"healthy","version":"{version}","configured":true}}'
            ],
        )

    def run_shell_command(self, command, *_args, **_kwargs):
        self.commands.append(command)
        if "CONFIGURED='false'" in command:
            return True, self._status_output
        return True, _FakeOutput()


class _FakeSession:
    def __init__(self, host):
        self.host = host

    def close(self):
        return {"disconnect_error": None}


def _error_result(code, msg, stage=None, details=None, extra=None):
    return {
        "status": "error",
        "code": code,
        "msg": msg,
        "stage": stage,
        "details": details,
        "extra": extra or {},
    }


class TestTwoEnginesInOneProcess(unittest.TestCase):
    def test_interleaved_operations_do_not_cross_contaminate(self):
        host_a = _RecordingHost("17.8")
        host_b = _RecordingHost("16.4")
        events_a = []
        events_b = []

        ctx_a = build_test_context(
            error_result=_error_result,
            emit_event=lambda *args, **kwargs: events_a.append((args, kwargs)),
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "engine-a command failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host_a),
            },
        )
        ctx_b = build_test_context(
            error_result=_error_result,
            emit_event=lambda *args, **kwargs: events_b.append((args, kwargs)),
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "engine-b command failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host_b),
            },
        )

        def run(ctx, version):
            return engine_postgres_ops.run_postgres_runtime_operation(
                ctx,
                "service_status",
                ip="198.51.100.10",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "postgres_version": version,
                        "superuser_password": "secret",
                    },
                },
            )

        result_a1 = run(ctx_a, "17")
        result_b = run(ctx_b, "16")

        # Snapshot engine B's state right after its own call, then run
        # engine A again. Under the pre-T-2.2 module-global design,
        # constructing/using ctx_b would have overwritten the shared
        # `_open_runtime_session`/`_emit_event` globals, so this second
        # engine-A call would silently route through host B and events_b
        # instead of host A and events_a -- the counts below would grow.
        host_b_commands_before = len(host_b.commands)
        events_b_before = len(events_b)

        result_a2 = run(ctx_a, "17")

        for result in (result_a1, result_b, result_a2):
            self.assertEqual(result["status"], "success")

        self.assertEqual(result_a1["service_status"]["version"], "17.8")
        self.assertEqual(result_a2["service_status"]["version"], "17.8")
        self.assertEqual(result_b["service_status"]["version"], "16.4")

        # The second engine-A call added commands/events to engine A's own
        # host and event log...
        self.assertGreater(len(host_a.commands), 0)
        self.assertGreater(len(events_a), 0)
        host_a_status_commands = [c for c in host_a.commands if "CONFIGURED='false'" in c]
        self.assertEqual(len(host_a_status_commands), 2)

        # ...and did not add anything to engine B's, even though it ran
        # after engine B's own call.
        self.assertEqual(len(host_b.commands), host_b_commands_before)
        self.assertEqual(len(events_b), events_b_before)


if __name__ == "__main__":
    unittest.main()
