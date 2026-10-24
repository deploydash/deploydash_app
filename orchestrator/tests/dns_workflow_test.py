import json
import unittest
from unittest.mock import patch

from engine import handle_request


class _FakeSession:
    def __init__(self, fail_step_id=None):
        self._step_records = []
        self._fail_step_id = fail_step_id

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


class TestDnsWorkflow(unittest.TestCase):
    def test_describe_dns_returns_steps(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "dns",
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
                "stack_root": "/opt/deploydash/stack/dns",
                "container_name": "deploydash_bind9",
                "bind_image": "internetsystemsconsortium/bind9:9.20",
                "bind_service_name": "bind9",
            },
        )

    @patch("engine.create_runtime_session")
    def test_run_dns_dry_run(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "dns",
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
                        # container_name/bind_image/bind_service_name are
                        # server-owned (T-1.4.4); omitted rather than sent.
                        "zone_name": "example.com",
                        "nameserver_hostname": "ns1",
                        "nameserver_ipv4": None,
                        "default_a_ipv4": None,
                        "admin_email": "hostmaster.example.com",
                        "zone_serial": 2026010101,
                        "zone_ttl": 300,
                        "zone_refresh": 3600,
                        "zone_retry": 900,
                        "zone_expire": 604800,
                        "zone_negative_ttl": 300,
                        "allow_recursion": False,
                        "recursion_cidrs": ["127.0.0.1/32"],
                        "forwarders": [],
                        "listen_on_ipv6": False,
                        "extra_a_records": [],
                        "zones": [],
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
                "stack_root": "/opt/deploydash/stack/dns",
                "container_name": "deploydash_bind9",
                "bind_image": "internetsystemsconsortium/bind9:9.20",
                "bind_service_name": "bind9",
            },
        )
        self.assertGreaterEqual(len(result["scheduled_action_ids"]), 1)
        self.assertEqual(
            len(result["completed_action_ids"]),
            len(result["scheduled_action_ids"]),
        )

    @patch("engine.create_runtime_session")
    def test_run_dns_execute(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "dns",
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
    def test_run_dns_unknown_part(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "dns",
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


if __name__ == "__main__":
    unittest.main()
