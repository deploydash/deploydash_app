import json
import unittest
from unittest.mock import Mock, patch

from pyinfra import facts

from engine import handle_request
from orchestrator import server_layout
from orchestrator.infra_parts.overview import check_ssh_and_specs, get_hardware_specs
from tests.engine_context_fixtures import build_test_context
from tests.pyinfra_fact_fixtures import ubuntu_linux_distribution


class _FakeShellOutput:
    def __init__(self, stdout_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = []


class _FakeHost:
    def __init__(self, fact_values, *, layout_marker=""):
        self._fact_values = fact_values
        self._layout_marker = layout_marker

    def get_fact(self, fact_class):
        return self._fact_values.get(fact_class)

    def run_shell_command(self, command, _timeout=None, _sudo=None):
        # Connect now probes the layout marker first (T-1.1.6). These fakes
        # stand in for a machine with no Deploy Dash state on it, which is
        # the unprovisioned case check_server is normally run against.
        if "LAYOUT_VERSION" in command:
            return True, _FakeShellOutput([f"marker={self._layout_marker}", "legacy=0"])
        raise AssertionError(f"unexpected command: {command}")


class _FakeSession:
    def __init__(self, host):
        self.host = host

    def close(self):
        return {"disconnect_error": None}


class TestHardwareSpecs(unittest.TestCase):
    @patch("orchestrator.infra_parts.overview.collect_server_compatibility")
    @patch("orchestrator.infra_parts.overview.get_hardware_specs")
    @patch("orchestrator.infra_parts.overview.server_layout.migrate_layout")
    def test_check_server_migrates_layout_one_before_collecting_facts(
        self,
        mock_migrate_layout,
        mock_get_hardware_specs,
        mock_collect_server_compatibility,
    ):
        """A normal reconnect is the safe entry point for the layout bump."""
        host = _FakeHost({}, layout_marker="1")
        session = _FakeSession(host)
        events = []
        mock_migrate_layout.return_value = server_layout.LayoutOutcome(ok=True, version=2)
        mock_get_hardware_specs.return_value = {
            "status": "success",
            "os": "Ubuntu 24.04",
            "cpu": "x86_64",
            "memory_mb": 4096,
            "disk_gb": 80,
        }
        mock_collect_server_compatibility.return_value = {"status": "pass"}
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda _emit, event, _message, **_kwargs: events.append(event),
        )

        result = check_ssh_and_specs(ctx, "1.2.3.4", "ubuntu")

        self.assertEqual(result["status"], "success")
        mock_migrate_layout.assert_called_once_with(
            host,
            server_layout.LayoutState(marker_text="1", legacy_root_present=False),
        )
        self.assertIn("layout_migration_start", events)
        self.assertIn("layout_migration_complete", events)

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_success(self, mock_create_runtime_session):
        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.LinuxDistribution: ubuntu_linux_distribution("22.04"),
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 4096,
                facts.hardware.BlockDevices: {
                    "/dev/vda1": {
                        "blocks": "83886080",
                        "used": "1024",
                        "available": "83885056",
                        "used_percent": "1",
                        "mount": "/",
                    }
                },
            },
        )
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "1.2.3.4",
                "username": "user",
                "password": "pwd",
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["os"], "Ubuntu 22.04")
        self.assertEqual(result["cpu"], "x86_64")
        self.assertEqual(result["memory_mb"], 4096)
        self.assertEqual(result["disk_gb"], 80)

    def test_fast_probe_returns_pretty_os_without_loading_facts(self):
        """The one-shot probe remains the preferred low-latency source."""

        host = Mock()
        host.run_shell_command.return_value = (
            True,
            _FakeShellOutput(
                [
                    "os=Ubuntu 24.04.1 LTS",
                    "cpu=x86_64",
                    "memory_kb=4194304",
                    "disk_kb=83886080",
                ]
            ),
        )

        result = get_hardware_specs(build_test_context(), host)

        self.assertEqual(result["os"], "Ubuntu 24.04.1 LTS")
        self.assertEqual(result["memory_mb"], 4096)
        self.assertEqual(result["disk_gb"], 80)
        host.get_fact.assert_not_called()

    def test_fact_fallback_uses_major_and_minor_without_pretty_name(self):
        """Older fact payloads retain their version through typed fields."""

        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.LinuxDistribution: {
                    "name": "Ubuntu",
                    "major": "24",
                    "minor": "04",
                    "release_meta": {},
                },
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 4096,
                facts.hardware.BlockDevices: {},
            }
        )

        result = get_hardware_specs(build_test_context(), host)

        self.assertEqual(result["os"], "Ubuntu 24.04")

    def test_fact_fallback_uses_kernel_when_distribution_is_missing(self):
        """A missing distribution fact still reports the current kernel fact."""

        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 4096,
                facts.hardware.BlockDevices: {},
            }
        )

        result = get_hardware_specs(build_test_context(), host)

        self.assertEqual(result["os"], "Linux")

    def test_fact_fallback_normalizes_fact_failures(self):
        """A failed fallback keeps the engine's typed fact error contract."""

        host = Mock()
        host.run_shell_command.side_effect = RuntimeError("probe unavailable")
        host.get_fact.side_effect = RuntimeError("facts unavailable")

        result = get_hardware_specs(build_test_context(), host)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_FACTS_FAILED")
        self.assertEqual(result["stage"], "collect_facts")


if __name__ == "__main__":
    unittest.main()
