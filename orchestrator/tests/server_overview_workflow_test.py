import json
import unittest
from unittest.mock import patch

from engine import handle_request


class _FakeOutput:
    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


class _FakeHost:
    def __init__(self):
        self.commands = []

    def run_shell_command(self, command, _timeout=10, _sudo=False):
        self.commands.append((command, _timeout, _sudo))

        if "command -v sar >/dev/null 2>&1" in command:
            return True, _FakeOutput([])

        if "retention_days=" in command and "sar -n DEV" in command:
            return (
                True,
                _FakeOutput(
                    [
                        "retention_days=90",
                        "uptime_seconds=93784",
                        "booted_at=2026-02-19T10:15:00Z",
                        "cpu_idle=84.50",
                        "load_avg=0.14 0.09 0.06",
                        "mem=4096 2048 1024 1700",
                        "swap=2048 128 1920",
                        "disk_root=21474836480 10737418240 10737418240 50%",
                        "inode_root=11%",
                        "sysstat_files=27",
                        "sysstat_oldest=/var/log/sysstat/sa20251122",
                        "sysstat_newest=/var/log/sysstat/sa20260220",
                        "net_dev=eth0,12.4,7.8",
                        "net_dev=ens5,4.1,2.2",
                        "disk_dev=sda,120.0,95.0,40.2",
                        "disk_dev=nvme0n1,240.5,210.8,88.1",
                    ]
                ),
            )

        return False, _FakeOutput(stderr_lines=["unexpected command"])


class _FakeSession:
    def __init__(self, host):
        self.host = host

    def close(self):
        return {"disconnect_error": None}


class TestServerOverviewWorkflow(unittest.TestCase):
    def test_overview_metrics_dry_run_returns_plan_and_retention(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "overview_metrics",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {"dry_run": True},
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "overview_metrics")
        self.assertEqual(result["retention_days"], 90)
        self.assertGreaterEqual(len(result.get("actions", [])), 2)

    @patch("engine.create_runtime_session")
    def test_overview_metrics_collects_and_parses_metrics(self, mock_create_runtime_session):
        fake_host = _FakeHost()
        mock_create_runtime_session.return_value = _FakeSession(fake_host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "overview_metrics",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {"dry_run": False},
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "overview_metrics")
        self.assertEqual(result["retention_days"], 90)

        metrics = result.get("metrics")
        self.assertIsInstance(metrics, dict)
        self.assertIn("cpu", metrics)
        self.assertIn("memory", metrics)
        self.assertIn("disk", metrics)
        self.assertIn("network", metrics)
        self.assertIn("io", metrics)
        self.assertIn("system", metrics)

        self.assertAlmostEqual(metrics["cpu"]["usage_percent"], 15.5, places=2)
        self.assertEqual(metrics["system"]["uptime_seconds"], 93784)
        self.assertEqual(metrics["system"]["booted_at"], "2026-02-19T10:15:00Z")
        self.assertEqual(metrics["memory"]["used_mb"], 2048)
        self.assertEqual(metrics["collection"]["retention_days"], 90)
        self.assertEqual(metrics["collection"]["sysstat_file_count"], 27)

        top_network = metrics["network"].get("top_interface", {})
        self.assertEqual(top_network.get("name"), "eth0")

        top_io = metrics["io"].get("top_device", {})
        self.assertEqual(top_io.get("name"), "nvme0n1")

        self.assertTrue(any(use_sudo for _, _, use_sudo in fake_host.commands))
        self.assertTrue(
            any("command -v sar >/dev/null 2>&1" in command for command, _, _ in fake_host.commands)
        )
        self.assertFalse(any("HISTORY=90" in command for command, _, _ in fake_host.commands))


if __name__ == "__main__":
    unittest.main()
