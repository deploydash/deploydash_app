import shlex
import unittest
from unittest.mock import patch

from orchestrator import engine_scheduler_ops, shell_output
from orchestrator.engine_scheduler_ops import SchedulerConfigValidationError
from tests.engine_context_fixtures import build_test_context


class _FakeOutput:
    def __init__(self, stdout_lines=None):
        self.stdout_lines = stdout_lines or []


class _FakeSession:
    def __init__(self, disconnect_error=None):
        self.host = object()
        self._disconnect_error = disconnect_error

    def close(self):
        return {"disconnect_error": self._disconnect_error}


def _error_result(code, msg, stage=None, details=None, extra=None):
    return {
        "status": "error",
        "code": code,
        "msg": msg,
        "stage": stage,
        "details": details,
        "extra": extra or {},
    }


class TestSchedulerHelpers(unittest.TestCase):
    def test_normalize_project_slug_rejects_invalid(self):
        with self.assertRaises(SchedulerConfigValidationError):
            engine_scheduler_ops._normalize_project_slug("Bad Slug")

    def test_normalize_interval_bounds(self):
        self.assertEqual(engine_scheduler_ops._normalize_interval("15"), 15)
        with self.assertRaises(SchedulerConfigValidationError):
            engine_scheduler_ops._normalize_interval("0")
        with self.assertRaises(SchedulerConfigValidationError):
            engine_scheduler_ops._normalize_interval("1500")

    def test_normalize_daily_time(self):
        self.assertEqual(engine_scheduler_ops._normalize_daily_time("2:05"), "02:05")
        with self.assertRaises(SchedulerConfigValidationError):
            engine_scheduler_ops._normalize_daily_time("25:00")

    def test_settings_payload_prefers_nested_settings(self):
        payload = {"settings": {"project_slug": "abc"}, "project_slug": "def"}
        parsed = engine_scheduler_ops._settings_payload(payload)
        self.assertEqual(parsed["project_slug"], "abc")

    def test_task_unit_names_and_container_name(self):
        names = engine_scheduler_ops._task_unit_names("project-a", "daily-backup")
        self.assertEqual(
            names["service_unit"],
            "deploydash-project-a-daily-backup.service",
        )
        self.assertEqual(
            engine_scheduler_ops._task_container_name(
                "project-a",
                "worker",
                "queue",
            ),
            "deploydash_worker_project-a_queue",
        )

    def test_scheduler_script_text_preserves_shell_command_arguments(self):
        commands = [
            "php -v",
            "php artisan schedule:run",
            'php -r "echo 1;"',
            "npm run queue && echo ok",
            "printf 100%",
        ]
        for command in commands:
            with self.subTest(command=command):
                text = engine_scheduler_ops._scheduler_script_text(
                    "deploydash_app_test",
                    command,
                )
                self.assertIn("#!/bin/sh", text)
                self.assertIn(
                    "docker exec deploydash_app_test /bin/sh -lc",
                    text,
                )
                self.assertIn(shlex.quote(command), text)

    def test_web_app_scheduler_script_resolves_current_live_container(self):
        text = engine_scheduler_ops._web_app_scheduler_script_text(
            "test-app",
            "php -v",
        )

        self.assertIn("label=deploydash.project=${PROJECT_SLUG}", text)
        self.assertIn("label=deploydash.live=true", text)
        self.assertIn("/opt/deploydash/stack/apps/.deploydash/apps/test-app/releases.json", text)
        self.assertIn("web_container_name", text)
        self.assertIn("LEGACY_CONTAINER=deploydash_app_test-app", text)
        self.assertIn(
            "Deploy Dash could not find the live web app container",
            text,
        )
        self.assertIn('docker exec "${LIVE_CONTAINER}" /bin/sh -lc', text)
        self.assertIn(shlex.quote("php -v"), text)
        self.assertNotIn(
            "docker exec deploydash_app_test-app /bin/sh -lc",
            text,
        )

    def test_service_unit_text_runs_wrapper_script(self):
        text = engine_scheduler_ops._service_unit_text(
            "Task Name",
            "/opt/deploydash/state/scheduler/deploydash-app-task.sh",
        )
        self.assertIn("Description=Deploy Dash task: Task Name", text)
        self.assertNotIn("DEPLOYDASH_TASK_COMMAND", text)
        self.assertIn(
            "ExecStart=/opt/deploydash/state/scheduler/deploydash-app-task.sh",
            text,
        )

    def test_timer_unit_text_for_daily(self):
        text = engine_scheduler_ops._timer_unit_text(
            "deploydash.service",
            "daily_at",
            None,
            "03:45",
        )
        self.assertIn("OnCalendar=*-*-* 03:45:00", text)

    def test_parse_kv_lines_and_empty_iso(self):
        output = _FakeOutput(
            stdout_lines=["ENABLED=enabled", "ACTIVE=active", "NOPE"],
        )
        parsed = shell_output.parse_key_values(output)
        self.assertEqual(parsed["ENABLED"], "enabled")
        self.assertIsNone(engine_scheduler_ops._empty_if_not_iso(""))
        self.assertEqual(
            engine_scheduler_ops._empty_if_not_iso("2026-01-01T00:00:00Z"),
            "2026-01-01T00:00:00Z",
        )

    def test_parse_task_status_settings_deduplicates_ids(self):
        parsed = engine_scheduler_ops._parse_task_status_settings(
            {
                "project_slug": "my-project",
                "task_ids": ["a-task", "a-task", "b-task"],
                "tasks": [
                    {
                        "task_id": "a-task",
                        "target_type": "web_app",
                        "command": "php -v",
                    }
                ],
            }
        )
        self.assertEqual(parsed["task_ids"], ["a-task", "b-task"])
        self.assertEqual(
            parsed["repair_tasks"],
            [
                {
                    "task_id": "a-task",
                    "target_type": "web_app",
                    "target_ref": None,
                    "command": "php -v",
                }
            ],
        )

    def test_parse_task_run_now_settings_accepts_optional_repair_payload(self):
        parsed = engine_scheduler_ops._parse_task_run_now_settings(
            {
                "project_slug": "my-project",
                "task_id": "queue-health-check",
                "target_type": "worker",
                "target_ref": "queue-worker",
                "command": "php -v",
            }
        )

        self.assertEqual(parsed["project_slug"], "my-project")
        self.assertEqual(parsed["task_id"], "queue-health-check")
        self.assertEqual(parsed["target_type"], "worker")
        self.assertEqual(parsed["target_ref"], "queue-worker")
        self.assertEqual(parsed["command"], "php -v")

    def test_parse_task_run_now_settings_keeps_legacy_minimal_payload(self):
        parsed = engine_scheduler_ops._parse_task_run_now_settings(
            {
                "project_slug": "my-project",
                "task_id": "queue-health-check",
            }
        )

        self.assertEqual(parsed["project_slug"], "my-project")
        self.assertEqual(parsed["task_id"], "queue-health-check")
        self.assertNotIn("command", parsed)

    def test_parse_run_now_output_collects_status_and_journal_lines(self):
        kv, run_lines = engine_scheduler_ops._parse_run_now_output(
            _FakeOutput(
                stdout_lines=[
                    "START_STATUS=0",
                    "SERVICE_RESULT=success",
                    "RUN_OUTPUT_BEGIN",
                    "PHP 8.3.1",
                    "RUN_OUTPUT_END",
                ],
            )
        )

        self.assertEqual(kv["START_STATUS"], "0")
        self.assertEqual(kv["SERVICE_RESULT"], "success")
        self.assertEqual(run_lines, ["PHP 8.3.1"])
        self.assertTrue(engine_scheduler_ops._scheduler_run_succeeded(kv))

    def test_run_operation_task_delete_success(self):
        emitted = []

        def emit_event(_emit, event_type, message, level="info", data=None):
            emitted.append((event_type, message, level, data))

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=emit_event,
            emit_shell_output_lines=lambda _emit, _output: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": _FakeSession()},
        )
        with patch.multiple(
            engine_scheduler_ops,
            systemd_disable_now=lambda *_args, **_kwargs: {"ok": True, "output": _FakeOutput()},
            systemd_service_action=lambda *_args, **_kwargs: {"ok": True, "output": _FakeOutput()},
            remove_remote_files=lambda *_args, **_kwargs: {"ok": True, "output": _FakeOutput()},
            systemd_daemon_reload=lambda *_args, **_kwargs: {"ok": True, "output": _FakeOutput()},
            systemd_reset_failed=lambda *_args, **_kwargs: {"ok": True, "output": _FakeOutput()},
            run_shell_command=lambda *_args, **_kwargs: {"ok": True, "output": _FakeOutput()},
        ):
            result = engine_scheduler_ops.run_scheduler_runtime_operation(
                ctx,
                "task_delete",
                ip="198.51.100.10",
                username="ubuntu",
                password="secret",
                raw_data={"settings": {"project_slug": "my-app", "task_id": "cleanup"}},
            )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "task_delete")
        self.assertTrue(any(event[0] == "scheduler_runtime_plan_ready" for event in emitted))

    def test_run_operation_task_set_enabled_false(self):
        status_output = _FakeOutput(
            stdout_lines=[
                "ENABLED=disabled",
                "ACTIVE=inactive",
                "SUB_STATE=dead",
                "SERVICE_RESULT=success",
                "LAST_ISO=",
                "NEXT_ISO=2026-02-28T12:00:00Z",
            ],
        )

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": _FakeSession()},
        )
        with patch.multiple(
            engine_scheduler_ops,
            systemd_daemon_reload=lambda *_args, **_kwargs: {"ok": True, "output": _FakeOutput()},
            systemd_enable_now=lambda *_args, **_kwargs: {"ok": True, "output": _FakeOutput()},
            systemd_disable_now=lambda *_args, **_kwargs: {"ok": True, "output": _FakeOutput()},
            run_shell_command=lambda *_args, **_kwargs: {"ok": True, "output": status_output},
        ):
            result = engine_scheduler_ops.run_scheduler_runtime_operation(
                ctx,
                "task_set_enabled",
                ip="198.51.100.10",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "my-app",
                        "task_id": "cleanup",
                        "enabled": False,
                    },
                },
            )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["enabled"], False)
        self.assertEqual(result["timer_active_state"], "inactive")

    def test_run_operation_task_run_now_reads_service_state(self):
        service_output = _FakeOutput(
            stdout_lines=[
                "START_STATUS=0",
                "SERVICE_ACTIVE=inactive",
                "SERVICE_RESULT=success",
                "EXIT_CODE=0",
                "FINISHED_ISO=2026-02-25T10:00:00Z",
                "RUN_OUTPUT_BEGIN",
                "PHP 8.3.1",
                "RUN_OUTPUT_END",
            ],
        )

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": _FakeSession()},
        )
        with patch.multiple(
            engine_scheduler_ops,
            systemd_service_action=lambda *_args, **_kwargs: {"ok": True, "output": _FakeOutput()},
            run_shell_command=lambda *_args, **_kwargs: {"ok": True, "output": service_output},
        ):
            result = engine_scheduler_ops.run_scheduler_runtime_operation(
                ctx,
                "task_run_now",
                ip="198.51.100.10",
                username="ubuntu",
                password="secret",
                raw_data={"settings": {"project_slug": "my-app", "task_id": "cleanup"}},
            )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["msg"], "Scheduled job completed.")
        self.assertEqual(result["service_active_state"], "inactive")
        self.assertEqual(result["service_result"], "success")
        self.assertEqual(result["exit_code"], "0")
        self.assertTrue(result["run_succeeded"])
        self.assertEqual(result["run_output_lines"], ["PHP 8.3.1"])
        self.assertEqual(result["run_output"], "PHP 8.3.1")
        self.assertEqual(result["finished_at"], "2026-02-25T10:00:00Z")

    def test_run_operation_task_run_now_repairs_wrapper_before_start(self):
        written_scripts = []
        shell_outputs = [
            _FakeOutput(),
            _FakeOutput(
                stdout_lines=[
                    "START_STATUS=0",
                    "SERVICE_ACTIVE=inactive",
                    "SERVICE_RESULT=success",
                    "EXIT_CODE=0",
                    "FINISHED_ISO=2026-02-25T10:00:00Z",
                    "RUN_OUTPUT_BEGIN",
                    "PHP 8.3.1",
                    "RUN_OUTPUT_END",
                ],
            ),
        ]

        def write_script(_host, *, path, content, **_kwargs):
            written_scripts.append((path, content))
            return {"ok": True, "output": _FakeOutput()}

        def run_shell(_host, _command, **_kwargs):
            return {"ok": True, "output": shell_outputs.pop(0)}

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": _FakeSession()},
        )
        with patch.multiple(
            engine_scheduler_ops,
            write_remote_text_file=write_script,
            run_shell_command=run_shell,
        ):
            result = engine_scheduler_ops.run_scheduler_runtime_operation(
                ctx,
                "task_run_now",
                ip="198.51.100.10",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "my-app",
                        "task_id": "cleanup",
                        "target_type": "web_app",
                        "command": "php -v",
                    }
                },
            )

        self.assertEqual(result["status"], "success")
        self.assertEqual(len(written_scripts), 1)
        self.assertEqual(
            written_scripts[0][0],
            "/opt/deploydash/state/scheduler/deploydash-my-app-cleanup.sh",
        )
        self.assertIn('docker exec "${LIVE_CONTAINER}" /bin/sh -lc', written_scripts[0][1])
        self.assertIn(shlex.quote("php -v"), written_scripts[0][1])

    def test_run_operation_task_run_now_returns_failure_with_output(self):
        service_output = _FakeOutput(
            stdout_lines=[
                "START_STATUS=1",
                "SERVICE_ACTIVE=failed",
                "SERVICE_RESULT=exit-code",
                "EXIT_CODE=127",
                "FINISHED_ISO=2026-02-25T10:00:00Z",
                "RUN_OUTPUT_BEGIN",
                "php: not found",
                "RUN_OUTPUT_END",
            ],
        )

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": _FakeSession()},
        )
        with patch.multiple(
            engine_scheduler_ops,
            run_shell_command=lambda *_args, **_kwargs: {"ok": True, "output": service_output},
        ):
            result = engine_scheduler_ops.run_scheduler_runtime_operation(
                ctx,
                "task_run_now",
                ip="198.51.100.10",
                username="ubuntu",
                password="secret",
                raw_data={"settings": {"project_slug": "my-app", "task_id": "cleanup"}},
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "SCHEDULER_RUN_FAILED")
        self.assertFalse(result["run_succeeded"])
        self.assertEqual(result["run_output_lines"], ["php: not found"])
        self.assertIn("exit code 127", result["details"])
        self.assertIn("php: not found", result["details"])

    def test_run_operation_task_status_repairs_wrappers_before_status(self):
        written_scripts = []
        shell_outputs = [
            _FakeOutput(),
            _FakeOutput(
                stdout_lines=[
                    "ENABLED=enabled",
                    "ACTIVE=active",
                    "SUB_STATE=waiting",
                    "SERVICE_RESULT=success",
                    "LAST_ISO=2026-02-25T10:00:00Z",
                    "NEXT_ISO=2026-02-25T10:05:00Z",
                ],
            ),
        ]

        def write_script(_host, *, path, content, **_kwargs):
            written_scripts.append((path, content))
            return {"ok": True, "output": _FakeOutput()}

        def run_shell(_host, _command, **_kwargs):
            return {"ok": True, "output": shell_outputs.pop(0)}

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": _FakeSession()},
        )
        with patch.multiple(
            engine_scheduler_ops,
            write_remote_text_file=write_script,
            run_shell_command=run_shell,
        ):
            result = engine_scheduler_ops.run_scheduler_runtime_operation(
                ctx,
                "task_status",
                ip="198.51.100.10",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "my-app",
                        "task_ids": ["cleanup"],
                        "tasks": [
                            {
                                "task_id": "cleanup",
                                "target_type": "web_app",
                                "command": "php -v",
                            }
                        ],
                    }
                },
            )

        self.assertEqual(result["status"], "success")
        self.assertEqual(len(written_scripts), 1)
        self.assertEqual(
            written_scripts[0][0],
            "/opt/deploydash/state/scheduler/deploydash-my-app-cleanup.sh",
        )
        self.assertIn('docker exec "${LIVE_CONTAINER}" /bin/sh -lc', written_scripts[0][1])
        self.assertIn(shlex.quote("php -v"), written_scripts[0][1])
        self.assertEqual(result["task_statuses"][0]["task_id"], "cleanup")

    def test_run_operation_preflight_cancelled(self):
        ctx = build_test_context(error_result=_error_result)
        result = engine_scheduler_ops.run_scheduler_runtime_operation(
            ctx,
            "task_delete",
            ip="198.51.100.10",
            username="ubuntu",
            raw_data={"settings": {"project_slug": "my-app", "task_id": "cleanup"}},
            is_cancelled=lambda: True,
        )
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")

    def test_run_operation_unknown_returns_validation_error(self):
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
        )
        result = engine_scheduler_ops.run_scheduler_runtime_operation(
            ctx,
            "invalid-op",
            ip="198.51.100.10",
            username="ubuntu",
            raw_data={"settings": {"project_slug": "my-app", "task_id": "cleanup"}},
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")

    def test_run_operation_open_session_error_is_returned(self):
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            open_runtime_session=lambda **_kwargs: {
                "ok": False,
                "error": _error_result("ENGINE_RUNTIME_ERROR", "cannot connect"),
            },
        )
        result = engine_scheduler_ops.run_scheduler_runtime_operation(
            ctx,
            "task_delete",
            ip="198.51.100.10",
            username="ubuntu",
            raw_data={"settings": {"project_slug": "my-app", "task_id": "cleanup"}},
        )
        self.assertEqual(result["msg"], "cannot connect")


if __name__ == "__main__":
    unittest.main()
