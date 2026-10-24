import json
import unittest
from unittest.mock import patch

from engine import handle_request


class _FakeSession:
    def __init__(self, fail_step_id=None):
        self._step_records = []
        self._fail_step_id = fail_step_id
        self.host = _FakeHost()

    def register_steps_deploy(self, steps):
        self._step_records = [(step.id, step.part, step.title) for step in steps]

    def execute(self):
        operations = []
        for step_id, part, title in self._step_records:
            failed = step_id == self._fail_step_id
            operations.append(
                {
                    "step_id": step_id,
                    "part": part,
                    "title": title,
                    "complete": True,
                    "success": not failed,
                    "changed": True,
                    "stdout": ["ok"] if not failed else [],
                    "stderr": ["failed"] if failed else [],
                }
            )
        return {
            "ops": len(operations),
            "success_ops": len([op for op in operations if op["success"]]),
            "error_ops": len([op for op in operations if not op["success"]]),
            "ignored_error_ops": 0,
            "partial_ops": 0,
            "run_error": None,
            "operations": operations,
        }

    def close(self):
        return {"disconnect_error": None}


class _FakeOutput:
    def __init__(self, lines):
        self.stdout_lines = lines
        self.stderr_lines = []


class _FakeHost:
    def run_shell_command(self, command, _timeout=10, _sudo=False):
        return True, _FakeOutput([f"ran: {command}"])


class TestHttpWorkflow(unittest.TestCase):
    def test_describe_http_returns_steps(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "http",
                "operation_id": "describe",
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertGreaterEqual(len(result["steps"]), 1)
        self.assertIn("actions", result["steps"][0])
        self.assertEqual(
            result["resolved_config"],
            {
                "stack_root": "/opt/deploydash/stack/http",
                "container_name": "deploydash_caddy",
                "caddy_image": "caddy:2.11.2-alpine",
            },
        )

    @patch("engine.create_runtime_session")
    def test_run_http_dry_run(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "http",
                "operation_id": "run",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "parts": ["part1"],
                    "settings": {
                        # container_name/caddy_image are server-owned
                        # (T-1.4.4); omitted rather than sent.
                        "default_hostname": "server1.example.com",
                        "server_ip": None,
                        "default_page_title": "Deploy Dash HTTP gateway is online",
                        "default_page_message": "Caddy gateway ready.",
                        "serve_ip_over_https": True,
                        "enable_on_demand_tls": False,
                        "on_demand_tls_ask_endpoint": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["parts"], ["part1"])
        self.assertEqual(
            result["resolved_config"],
            {
                "stack_root": "/opt/deploydash/stack/http",
                "container_name": "deploydash_caddy",
                "caddy_image": "caddy:2.11.2-alpine",
            },
        )
        self.assertGreaterEqual(len(result["scheduled_action_ids"]), 1)
        self.assertEqual(
            len(result["completed_action_ids"]),
            len(result["scheduled_action_ids"]),
        )

    @patch("engine.create_runtime_session")
    def test_run_http_execute(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "http",
                "operation_id": "run",
                "connection": {
                    "ip": "198.51.100.8",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertFalse(result["dry_run"])
        self.assertGreaterEqual(len(result["completed_step_ids"]), 1)

    @patch("engine.create_runtime_session")
    def test_run_http_unknown_part(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "http",
                "operation_id": "run",
                "connection": {
                    "ip": "198.51.100.8",
                    "port": 22,
                    "username": "root",
                },
                "params": {"parts": ["part9"]},
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")

    @patch("engine.create_runtime_session")
    def test_http_service_enable_execute(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "http",
                "operation_id": "service_enable",
                "connection": {
                    "ip": "198.51.100.8",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertFalse(result["dry_run"])
        self.assertGreaterEqual(len(result["completed_step_ids"]), 1)

    @patch("engine.create_runtime_session")
    def test_http_service_start_execute(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "http",
                "operation_id": "service_start",
                "connection": {
                    "ip": "198.51.100.8",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "service_start")

    @patch("engine.create_runtime_session")
    def test_http_service_configure_dry_run(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "http",
                "operation_id": "service_configure",
                "connection": {
                    "ip": "198.51.100.8",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {
                        # container_name/caddy_image are server-owned
                        # (T-1.4.4); omitted rather than sent.
                        "default_hostname": "localhost",
                        "server_ip": None,
                        "default_page_title": "All systems ready",
                        "default_page_message": "Web server is online.",
                        "serve_ip_over_https": True,
                        "enable_https_redirect": True,
                        "enable_response_compression": True,
                        "enable_access_logs": False,
                        "enable_on_demand_tls": False,
                        "on_demand_tls_ask_endpoint": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertTrue(result["dry_run"])

    @patch("engine.create_runtime_session")
    def test_http_service_status_execute(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "http",
                "operation_id": "service_status",
                "connection": {
                    "ip": "198.51.100.8",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "service_status")
        self.assertIsInstance(result.get("service_status"), dict)
        self.assertIn("running", result["service_status"])
        self.assertIn("container_status", result["service_status"])
        self.assertIn(
            result["service_status"]["container_status"]["effective_status"],
            {"missing", "stopped", "ready", "unknown"},
        )


if __name__ == "__main__":
    unittest.main()
