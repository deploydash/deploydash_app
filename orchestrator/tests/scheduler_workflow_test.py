import json
import unittest
from unittest.mock import patch

from engine import handle_request


class _FakeOutput:
    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


class _SchedulerHost:
    def __init__(self):
        self.commands = []

    def run_shell_command(self, command, *_args, **_kwargs):
        self.commands.append(command)
        if "printf 'ENABLED=%s\\nACTIVE=%s" in command:
            return (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "ENABLED=enabled",
                        "ACTIVE=active",
                        "SUB_STATE=waiting",
                        "TIMER_RESULT=success",
                        "LAST_ISO=2026-02-25T10:00:00Z",
                        "NEXT_ISO=2026-02-25T10:05:00Z",
                        "SERVICE_ACTIVE=inactive",
                        "SERVICE_RESULT=success",
                    ],
                ),
            )
        if "SERVICE_ACTIVE=" in command and "SERVICE_RESULT=" in command:
            return (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "SERVICE_ACTIVE=inactive",
                        "SERVICE_RESULT=success",
                    ],
                ),
            )
        return True, _FakeOutput(stdout_lines=[])


class _FakeSession:
    def __init__(self, host):
        self.host = host

    def close(self):
        return {"disconnect_error": None}


class TestSchedulerWorkflow(unittest.TestCase):
    def test_describe_scheduler_plan(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "scheduler",
                "operation_id": "describe",
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["workflow_id"], "scheduler")
        self.assertEqual(result["operation_id"], "describe")
        self.assertIn("every_minutes", result["supported_schedule_types"])
        self.assertIn("web_app", result["supported_target_types"])

    def test_task_upsert_dry_run(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "scheduler",
                "operation_id": "task_upsert",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {
                        "project_slug": "remix-blog",
                        "task_id": "queue-restart",
                        "name": "Queue restart",
                        "target_type": "web_app",
                        "command": "php artisan queue:restart",
                        "schedule_type": "every_minutes",
                        "interval_value": 15,
                        "enabled": True,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "task_upsert")
        self.assertEqual(result["project_slug"], "remix-blog")
        self.assertEqual(result["task_id"], "queue-restart")

    @patch("engine._open_runtime_session")
    def test_task_upsert_writes_units_for_worker_target(
        self,
        mock_open_runtime_session,
    ):
        host = _SchedulerHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "scheduler",
                "operation_id": "task_upsert",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "task_id": "queue-worker-health",
                        "name": "Queue worker health",
                        "target_type": "worker",
                        "target_ref": "queue-worker",
                        "command": "node healthcheck.js",
                        "schedule_type": "every_minutes",
                        "interval_value": 5,
                        "enabled": True,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["timer_unit"], "deploydash-remix-blog-queue-worker-health.timer")
        self.assertEqual(
            result["service_unit"], "deploydash-remix-blog-queue-worker-health.service"
        )
        self.assertEqual(result["target_container"], "deploydash_worker_remix-blog_queue-worker")
        self.assertEqual(result["enabled"], True)

        joined = "\n".join(host.commands)
        self.assertIn("deploydash_worker_remix-blog_queue-worker", joined)
        self.assertIn(
            "/opt/deploydash/state/scheduler/deploydash-remix-blog-queue-worker-health.sh",
            joined,
        )
        self.assertIn("install -d -m 0755 /opt/deploydash/state/scheduler", joined)
        self.assertIn("node healthcheck.js", joined)
        self.assertIn("chmod 755", joined)
        self.assertIn(
            "/etc/systemd/system/deploydash-remix-blog-queue-worker-health.service",
            joined,
        )
        self.assertIn(
            "/etc/systemd/system/deploydash-remix-blog-queue-worker-health.timer",
            joined,
        )

    @patch("engine._open_runtime_session")
    def test_task_upsert_web_app_target_resolves_live_release_container(
        self,
        mock_open_runtime_session,
    ):
        host = _SchedulerHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "scheduler",
                "operation_id": "task_upsert",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "task_id": "artisan-schedule",
                        "name": "Laravel schedule",
                        "target_type": "web_app",
                        "command": "php artisan schedule:run",
                        "schedule_type": "every_minutes",
                        "interval_value": 5,
                        "enabled": True,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["target_container"], "deploydash_app_remix-blog")
        joined = "\n".join(host.commands)
        self.assertIn("label=deploydash.project=${PROJECT_SLUG}", joined)
        self.assertIn("label=deploydash.live=true", joined)
        self.assertIn(
            "/opt/deploydash/stack/apps/.deploydash/apps/remix-blog/releases.json",
            joined,
        )
        self.assertIn('docker exec "${LIVE_CONTAINER}" /bin/sh -lc', joined)
        self.assertNotIn(
            "docker exec deploydash_app_remix-blog /bin/sh -lc",
            joined,
        )
        self.assertIn("php artisan schedule:run", joined)

    @patch("engine._open_runtime_session")
    def test_task_delete_removes_wrapper_script(
        self,
        mock_open_runtime_session,
    ):
        host = _SchedulerHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "scheduler",
                "operation_id": "task_delete",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "task_id": "queue-worker-health",
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        joined = "\n".join(host.commands)
        self.assertIn(
            "/opt/deploydash/state/scheduler/deploydash-remix-blog-queue-worker-health.sh",
            joined,
        )

    @patch("engine._open_runtime_session")
    def test_task_status_returns_status_for_requested_tasks(
        self,
        mock_open_runtime_session,
    ):
        host = _SchedulerHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "scheduler",
                "operation_id": "task_status",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "task_ids": ["task-a", "task-b"],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "task_status")
        self.assertEqual(len(result["task_statuses"]), 2)
        self.assertEqual(result["task_statuses"][0]["task_id"], "task-a")
        self.assertEqual(result["task_statuses"][1]["task_id"], "task-b")
        self.assertEqual(result["task_statuses"][0]["enabled"], True)


if __name__ == "__main__":
    unittest.main()
