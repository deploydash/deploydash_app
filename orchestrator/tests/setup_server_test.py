import json
import socket
import unittest
from unittest.mock import patch

from pyinfra import facts

from engine import handle_request
from orchestrator.infra_parts.provisioning import setup_server
from orchestrator.setup_parts.setup_config import SSH_BANNER_TEXT
from tests.engine_context_fixtures import build_test_context
from tests.pyinfra_fact_fixtures import ubuntu_linux_distribution


class _FakeShellOutput:
    def __init__(self, stdout_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = []


class _FakeHost:
    def __init__(
        self,
        fact_values=None,
        layout_marker="2",
        existing_admin_keys=None,
        admin_probe_fails=False,
    ):
        self._fact_values = fact_values or {}
        self._layout_marker = layout_marker
        # None means the admin account does not exist yet. A list means it
        # does, and holds the SHA256 fingerprints it currently authorises.
        self._existing_admin_keys = existing_admin_keys
        self._admin_probe_fails = admin_probe_fails

    def get_fact(self, fact_class):
        return self._fact_values.get(fact_class)

    def run_shell_command(self, command, _timeout=None, _sudo=None):
        # Setup now verifies the layout marker it just wrote (T-1.1.6).
        # The default represents a correctly provisioned server.
        if "LAYOUT_VERSION" in command:
            return True, _FakeShellOutput([f"marker={self._layout_marker}", "legacy=0"])
        # Setup probes for an existing admin account before the destructive
        # takeover (G-4). These tests all bootstrap onto a fresh server, so
        # the account does not exist yet and no confirmation is required;
        # `setup_admin_takeover_test.py` covers the case where it does.
        if "authorized_key_fingerprints=" in command:
            if self._admin_probe_fails:
                return False, _FakeShellOutput([])
            return True, _FakeShellOutput(
                [
                    f"exists={1 if self._existing_admin_keys is not None else 0}",
                    f"authorized_key_count={len(self._existing_admin_keys or [])}",
                    "has_home=1",
                    "authorized_key_fingerprints=" + "|".join(self._existing_admin_keys or []),
                ],
            )
        raise AssertionError(f"unexpected command: {command}")


class _FakeSession:
    def __init__(self, host, fail_step_id=None):
        self.host = host
        self._step_records = []
        self._fail_step_id = fail_step_id

    def register_steps_deploy(self, steps):
        self._step_records = [(step.id, step.part, step.title) for step in steps]

    @property
    def step_records(self):
        """What was actually registered to run.

        Read by `setup_admin_takeover_test.py` to assert that a refused
        takeover ran nothing: a confirmation that arrives after the keys are
        gone is not a confirmation.
        """

        return list(self._step_records)

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


class _SingleExecuteSession(_FakeSession):
    def __init__(self, host, fail_step_id=None):
        super().__init__(host, fail_step_id=fail_step_id)
        self._execute_calls = 0

    def execute(self):
        self._execute_calls += 1
        if self._execute_calls > 1:
            raise RuntimeError("Cannot complete an already complete operation")
        return super().execute()


class _FactsFailingHost(_FakeHost):
    """Fake host whose fact lookups fail, simulating an unreachable prover."""

    def get_fact(self, fact_class):
        raise RuntimeError("facts unavailable")


class _LayoutProbeFailingHost(_FakeHost):
    """Fake host whose layout-marker probe fails, hiding the server state."""

    def run_shell_command(self, command, _timeout=None, _sudo=None):
        if "LAYOUT_VERSION" in command:
            return False, _FakeShellOutput([])
        return super().run_shell_command(command, _timeout, _sudo)


class _NoisyCloseSession(_FakeSession):
    """Fake session whose close reports a disconnect problem."""

    def close(self):
        return {"disconnect_error": "connection reset by peer"}


def _full_facts_host(host_class=_FakeHost, **kwargs):
    """Build a fake host with complete specs facts for the given class.

    Centralizes the facts boilerplate so failure-path tests differ only in
    the host behavior and session script, not the environment setup.
    """
    return host_class(
        {
            facts.server.Kernel: "Linux",
            facts.server.LinuxDistribution: ubuntu_linux_distribution("22.04"),
            facts.server.Arch: "x86_64",
            facts.hardware.Memory: 4096,
            facts.hardware.BlockDevices: {"/dev/vda1": {"blocks": "83886080", "mount": "/"}},
        },
        **kwargs,
    )


_FAKE_MANAGED_KEY_PATH = "/tmp/deploydash-managed-id_ed25519"
_FAKE_SSH_PUBLIC_KEY = (
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHZha2VkZXBsb3lkYXNobWFuYWdlZGtleQ== deploydash@test"
)


def _setup_settings(**overrides):
    settings = {
        # admin_user is server-owned (T-1.4.8); omitted rather than sent.
        "hostname": None,
        "timezone": "UTC",
        "ssh_public_key": _FAKE_SSH_PUBLIC_KEY,
        "disable_password_auth": True,
        "disable_root_login": True,
        "ssh_banner_text": SSH_BANNER_TEXT,
    }
    settings.update(overrides)
    return settings


def _managed_connection(**overrides):
    connection = {
        "username": "ubuntu",
        "port": 22,
        "key_path": _FAKE_MANAGED_KEY_PATH,
    }
    connection.update(overrides)
    return connection


def _with_setup_contract(payload, *, settings=None, managed_connection=None):
    data = dict(payload)
    params = dict(data.get("params") or {})
    params.setdefault(
        "managed_connection",
        _managed_connection() if managed_connection is None else managed_connection,
    )
    data["params"] = params

    merged_settings = _setup_settings()
    if settings:
        merged_settings.update(settings)
    data["settings"] = merged_settings
    return data


class TestSetupServer(unittest.TestCase):
    def test_describe_setup_returns_steps_and_actions(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "setup",
                "operation_id": "describe",
                "parts": ["part1", "part2"],
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["parts"], ["part1", "part2"])
        self.assertGreaterEqual(len(result["steps"]), 1)
        self.assertIn("actions", result["steps"][0])

    @patch("engine.create_runtime_session")
    def test_setup_server_dry_run(self, mock_create_runtime_session):
        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.LinuxDistribution: ubuntu_linux_distribution("22.04"),
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 2048,
                facts.hardware.BlockDevices: {"/dev/vda1": {"blocks": "41943040", "mount": "/"}},
            },
        )
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "dry_run": True,
                    "parts": ["part1", "part3"],
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["parts"], ["part1", "part3"])
        self.assertGreaterEqual(len(result["steps"]), 1)
        self.assertIn("actions", result["steps"][0])
        self.assertEqual(len(result["completed_step_ids"]), len(result["steps"]))
        self.assertGreaterEqual(len(result["scheduled_action_ids"]), 1)
        self.assertEqual(
            len(result["completed_action_ids"]),
            len(result["scheduled_action_ids"]),
        )
        self.assertEqual(result["os"], "Ubuntu 22.04")
        self.assertEqual(result["memory_mb"], 2048)

    @patch("engine.create_runtime_session")
    def test_setup_server_non_root_uses_sudo_connector(self, mock_create_runtime_session):
        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.LinuxDistribution: ubuntu_linux_distribution("22.04"),
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 2048,
                facts.hardware.BlockDevices: {"/dev/vda1": {"blocks": "41943040", "mount": "/"}},
            },
        )
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "ubuntu",
                    "password": "secret",
                    "dry_run": True,
                    "parts": ["part1"],
                }
            )
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "success")

        _, kwargs = mock_create_runtime_session.call_args
        connector_data = kwargs["connector_data"]
        self.assertTrue(connector_data["_sudo"])
        self.assertEqual(connector_data["_sudo_password"], "secret")

    @patch("engine.create_runtime_session")
    def test_setup_server_execute_runs_operations(self, mock_create_runtime_session):
        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.LinuxDistribution: ubuntu_linux_distribution("22.04"),
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 4096,
                facts.hardware.BlockDevices: {"/dev/vda1": {"blocks": "83886080", "mount": "/"}},
            },
        )
        mock_create_runtime_session.side_effect = [
            _SingleExecuteSession(host),
            _SingleExecuteSession(host),
        ]

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "server": {
                        "host": "1.2.3.4",
                        "port": 22,
                        "ssh_user": "root",
                        "auth": {"method": "password", "password": "secret"},
                    },
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertFalse(result["dry_run"])
        self.assertEqual(result["parts"], ["part2"])
        self.assertGreaterEqual(len(result["completed_step_ids"]), 1)
        self.assertGreaterEqual(len(result["scheduled_action_ids"]), 1)
        self.assertGreaterEqual(len(result["completed_action_ids"]), 1)
        self.assertEqual(
            result["msg"],
            "Server setup completed. HTTP gateway is installed and running.",
        )
        self.assertEqual(result["http_bootstrap"]["status"], "success")
        self.assertEqual(result["http_bootstrap"]["parts"], ["part1", "part2"])
        self.assertEqual(
            result["http_bootstrap"]["container_name"],
            "deploydash_caddy",
        )
        self.assertGreaterEqual(
            len(result["http_bootstrap"]["completed_step_ids"]),
            1,
        )
        self.assertEqual(mock_create_runtime_session.call_count, 2)

    @patch("orchestrator.http_parts.http_config.socket.getaddrinfo")
    @patch("engine.create_runtime_session")
    def test_setup_server_execute_accepts_hostname_for_http_bootstrap(
        self,
        mock_create_runtime_session,
        mock_getaddrinfo,
    ):
        mock_getaddrinfo.return_value = [
            (
                socket.AF_INET,
                socket.SOCK_STREAM,
                6,
                "",
                ("198.51.100.8", 0),
            )
        ]
        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.LinuxDistribution: ubuntu_linux_distribution("22.04"),
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 4096,
                facts.hardware.BlockDevices: {"/dev/vda1": {"blocks": "83886080", "mount": "/"}},
            },
        )
        mock_create_runtime_session.side_effect = [
            _SingleExecuteSession(host),
            _SingleExecuteSession(host),
        ]

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "server.example.com",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(
            result["http_bootstrap"]["container_name"],
            "deploydash_caddy",
        )

    @patch("engine.create_runtime_session")
    def test_setup_server_operation_failure_has_normalized_error(
        self,
        mock_create_runtime_session,
    ):
        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.LinuxDistribution: ubuntu_linux_distribution("22.04"),
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 4096,
                facts.hardware.BlockDevices: {"/dev/vda1": {"blocks": "83886080", "mount": "/"}},
            },
        )
        mock_create_runtime_session.side_effect = [
            _SingleExecuteSession(
                host,
                fail_step_id="part2_step7_swap",
            ),
        ]

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_OPERATION_FAILED")
        self.assertEqual(result["stage"], "execute_operations")
        self.assertEqual(result["failed_step_id"], "part2_step7_swap")
        self.assertEqual(mock_create_runtime_session.call_count, 1)

    @patch("engine.create_runtime_session")
    def test_setup_server_http_bootstrap_failure_fails_setup(
        self,
        mock_create_runtime_session,
    ):
        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.LinuxDistribution: ubuntu_linux_distribution("22.04"),
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 4096,
                facts.hardware.BlockDevices: {"/dev/vda1": {"blocks": "83886080", "mount": "/"}},
            },
        )
        mock_create_runtime_session.side_effect = [
            _SingleExecuteSession(host),
            _SingleExecuteSession(
                host,
                fail_step_id="http_part2_step1_start_caddy_gateway",
            ),
        ]

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_DEPENDENCY_ERROR")
        self.assertEqual(result["stage"], "setup_http_bootstrap")
        self.assertEqual(result.get("dependency"), "http")
        self.assertEqual(result.get("dependency_code"), "ENGINE_OPERATION_FAILED")
        self.assertEqual(
            result.get("dependency_failed_step_id"),
            "http_part2_step1_start_caddy_gateway",
        )
        self.assertEqual(mock_create_runtime_session.call_count, 2)

    @patch("orchestrator.infra_parts.provisioning.apply_onboarding_firewall_baseline")
    @patch("orchestrator.infra_parts.provisioning.apply_verified_onboarding_ssh_hardening")
    @patch("orchestrator.infra_parts.provisioning.verify_runtime_session_connection")
    @patch("orchestrator.infra_parts.provisioning.run_plan_execute")
    @patch("engine.create_runtime_session")
    def test_setup_server_applies_firewall_after_remaining_setup(
        self,
        mock_create_runtime_session,
        mock_run_plan_execute,
        mock_verify_runtime_session_connection,
        mock_apply_verified_onboarding_ssh_hardening,
        mock_apply_onboarding_firewall_baseline,
    ):
        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.LinuxDistribution: ubuntu_linux_distribution("24.04"),
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 4096,
                facts.hardware.BlockDevices: {"/dev/vda1": {"blocks": "83886080", "mount": "/"}},
            },
        )
        mock_create_runtime_session.side_effect = [
            _FakeSession(host),
            _FakeSession(host),
            _FakeSession(host),
        ]

        execution_order = []

        def _run_plan_execute(*, steps, message, **_kwargs):
            if steps and steps[0].id.startswith("http_"):
                execution_order.append("http")
            elif any(step.id == "part3_step11_docker_install" for step in steps):
                execution_order.append("remaining")
            elif steps and steps[0].id == "part1_step1_system_update":
                execution_order.append("bootstrap")
            else:
                execution_order.append("unknown")
            return {
                "status": "success",
                "msg": message,
                "code": "OK",
                "completed_step_ids": [step.id for step in steps],
                "scheduled_action_ids": [],
                "completed_action_ids": [],
                "logs": [],
            }

        mock_run_plan_execute.side_effect = _run_plan_execute
        mock_verify_runtime_session_connection.return_value = {"ok": True}
        mock_apply_verified_onboarding_ssh_hardening.return_value = {
            "ok": True,
            "managed_port": 22,
        }

        def _firewall(*args, **kwargs):
            execution_order.append("firewall")
            return {"ok": True}

        mock_apply_onboarding_firewall_baseline.side_effect = _firewall

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part1", "part3"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(
            execution_order,
            ["bootstrap", "remaining", "firewall", "http"],
        )
        self.assertEqual(mock_apply_onboarding_firewall_baseline.call_count, 1)

    @patch("engine.create_runtime_session")
    def test_setup_server_returns_managed_user_password_when_bootstrapping_as_root(
        self, mock_create_runtime_session
    ):
        """The generated unix password reaches the desktop for credential storage.

        Setup sets the managed user's password to a fresh random value when
        bootstrapping as somebody else; the desktop persists it alongside the
        managed key so the owner keeps a recoverable record. Without it in
        the result, the password exists only on the server and is lost.
        """
        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.LinuxDistribution: ubuntu_linux_distribution("22.04"),
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 4096,
                facts.hardware.BlockDevices: {"/dev/vda1": {"blocks": "83886080", "mount": "/"}},
            },
        )
        mock_create_runtime_session.side_effect = [
            _SingleExecuteSession(host),
            _SingleExecuteSession(host),
        ]

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        password = result.get("managed_user_password")
        self.assertIsInstance(password, str)
        self.assertGreaterEqual(len(password), 32)

    @patch("engine.create_runtime_session")
    def test_setup_server_omits_managed_user_password_when_bootstrapping_as_managed_user(
        self, mock_create_runtime_session
    ):
        """No password is generated when onboarding keeps the same account."""
        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.LinuxDistribution: ubuntu_linux_distribution("22.04"),
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 4096,
                facts.hardware.BlockDevices: {"/dev/vda1": {"blocks": "83886080", "mount": "/"}},
            },
        )
        mock_create_runtime_session.side_effect = [
            _SingleExecuteSession(host),
            _SingleExecuteSession(host),
        ]

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "ubuntu",
                    "password": "secret",
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertNotIn("managed_user_password", result)

    def test_setup_server_rejects_unknown_part_without_opening_session(self):
        """Unknown parts fail before any session opens, even for direct callers."""
        ctx = build_test_context()
        result = setup_server(
            ctx,
            ip="1.2.3.4",
            username="root",
            password="secret",
            key_filename=None,
            port=22,
            parts=["part1", "part9"],
            dry_run=False,
            raw_data=_with_setup_contract({}),
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("Unknown setup parts: part9", result["msg"])
        self.assertEqual(result["stage"], "validate_request")

    def test_setup_server_cancelled_returns_before_validating(self):
        """Cancellation wins even over settings that would fail validation."""
        ctx = build_test_context()
        result = setup_server(
            ctx,
            ip="1.2.3.4",
            username="root",
            password="secret",
            key_filename=None,
            port=22,
            parts=["part2"],
            dry_run=False,
            raw_data={"settings": {"disable_root_login": False}},
            is_cancelled=lambda: True,
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")

    def test_setup_server_rejects_invalid_parts_format(self):
        """A non-list parts value fails before any session opens.

        The engine schema rejects this shape for requests, so direct
        callers exercise setup_server's own guard here.
        """
        ctx = build_test_context()
        result = setup_server(
            ctx,
            ip="1.2.3.4",
            username="root",
            password="secret",
            key_filename=None,
            port=22,
            parts=123,
            dry_run=False,
            raw_data=_with_setup_contract({}),
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("Invalid parts format", result["msg"])

    def test_setup_server_rejects_missing_managed_connection(self):
        """Setup without a managed connection fails before opening a session."""
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "setup",
                "operation_id": "run",
                "ip": "1.2.3.4",
                "username": "root",
                "password": "secret",
                "parts": ["part2"],
                "dry_run": False,
                "settings": _setup_settings(),
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("managed ubuntu SSH connection", result["msg"])

    @patch("engine._open_runtime_session")
    def test_setup_server_returns_session_open_error(self, mock_open_runtime_session):
        """A refused bootstrap session surfaces the opener's error unchanged."""
        mock_open_runtime_session.return_value = {
            "ok": False,
            "error": {
                "status": "error",
                "code": "ENGINE_CONNECTION_ERROR",
                "msg": "refused",
            },
        }

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(
            result,
            {
                "status": "error",
                "code": "ENGINE_CONNECTION_ERROR",
                "msg": "refused",
            },
        )

    @patch("engine.create_runtime_session")
    def test_setup_server_reports_failed_specs(self, mock_create_runtime_session):
        """Uncollectable hardware specs fail setup before any step runs."""
        host = _full_facts_host(_FactsFailingHost)
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_FACTS_FAILED")
        self.assertEqual(result["stage"], "collect_facts")

    @patch("engine.create_runtime_session")
    def test_setup_server_reports_failed_bootstrap(self, mock_create_runtime_session):
        """A failed bootstrap step stops setup before the managed handoff."""
        host = _full_facts_host()
        mock_create_runtime_session.side_effect = [
            _SingleExecuteSession(host, fail_step_id="part1_step1_system_update"),
        ]

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part1"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_OPERATION_FAILED")
        self.assertEqual(result["failed_step_id"], "part1_step1_system_update")
        self.assertEqual(mock_create_runtime_session.call_count, 1)

    @patch("orchestrator.infra_parts.provisioning.verify_runtime_session_connection")
    @patch("engine.create_runtime_session")
    def test_setup_server_reports_failed_connection_verify(
        self, mock_create_runtime_session, mock_verify
    ):
        """A failed managed-login verify stops setup before hardening."""
        host = _full_facts_host()
        mock_create_runtime_session.return_value = _FakeSession(host)
        mock_verify.return_value = {
            "ok": False,
            "error": {
                "status": "error",
                "code": "ENGINE_CONNECTION_ERROR",
                "msg": "managed login failed",
            },
        }

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part1"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_CONNECTION_ERROR")
        self.assertEqual(result["msg"], "managed login failed")

    @patch("orchestrator.infra_parts.provisioning.apply_verified_onboarding_ssh_hardening")
    @patch("orchestrator.infra_parts.provisioning.verify_runtime_session_connection")
    @patch("engine.create_runtime_session")
    def test_setup_server_reports_failed_ssh_hardening(
        self,
        mock_create_runtime_session,
        mock_verify,
        mock_hardening,
    ):
        """Failed SSH hardening stops setup before the remaining steps run."""
        host = _full_facts_host()
        mock_create_runtime_session.return_value = _FakeSession(host)
        mock_verify.return_value = {"ok": True}
        mock_hardening.return_value = {
            "ok": False,
            "error": {
                "status": "error",
                "code": "ENGINE_RUNTIME_ERROR",
                "msg": "hardening failed",
            },
        }

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part1"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "hardening failed")

    @patch("orchestrator.infra_parts.provisioning.apply_verified_onboarding_ssh_hardening")
    @patch("orchestrator.infra_parts.provisioning.verify_runtime_session_connection")
    @patch("engine._open_runtime_session")
    def test_setup_server_returns_reopen_error(
        self,
        mock_open_runtime_session,
        mock_verify,
        mock_hardening,
    ):
        """A refused reconnect after hardening surfaces the opener's error."""
        host = _full_facts_host()
        reopen_error = {
            "status": "error",
            "code": "ENGINE_CONNECTION_ERROR",
            "msg": "reconnect refused",
        }
        mock_open_runtime_session.side_effect = [
            {"ok": True, "session": _FakeSession(host)},
            {"ok": False, "error": reopen_error},
        ]
        mock_verify.return_value = {"ok": True}
        mock_hardening.return_value = {"ok": True, "managed_port": 2222}

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part1"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result, reopen_error)

    @patch("orchestrator.infra_parts.provisioning.apply_verified_onboarding_ssh_hardening")
    @patch("orchestrator.infra_parts.provisioning.verify_runtime_session_connection")
    @patch("engine.create_runtime_session")
    def test_setup_server_warns_on_remaining_disconnect_without_failing(
        self,
        mock_create_runtime_session,
        mock_verify,
        mock_hardening,
    ):
        """A noisy reconnect close warns but keeps a successful setup green."""
        host = _full_facts_host()
        mock_create_runtime_session.side_effect = [
            _FakeSession(host),
            _NoisyCloseSession(host),
            _FakeSession(host),
        ]
        mock_verify.return_value = {"ok": True}
        mock_hardening.return_value = {"ok": True, "managed_port": 2222}

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part1"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")

    @patch("orchestrator.infra_parts.provisioning.apply_onboarding_firewall_baseline")
    @patch("orchestrator.infra_parts.provisioning.apply_verified_onboarding_ssh_hardening")
    @patch("orchestrator.infra_parts.provisioning.verify_runtime_session_connection")
    @patch("engine.create_runtime_session")
    def test_setup_server_reports_failed_firewall(
        self,
        mock_create_runtime_session,
        mock_verify,
        mock_hardening,
        mock_firewall,
    ):
        """A failed firewall baseline fails setup before the HTTP bootstrap."""
        host = _full_facts_host()
        mock_create_runtime_session.return_value = _FakeSession(host)
        mock_verify.return_value = {"ok": True}
        mock_hardening.return_value = {"ok": True, "managed_port": 22}
        mock_firewall.return_value = {
            "ok": False,
            "error": {
                "status": "error",
                "code": "ENGINE_RUNTIME_ERROR",
                "msg": "firewall failed",
            },
        }

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part1", "part3"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "firewall failed")

    @patch("engine.create_runtime_session")
    def test_setup_server_reports_unreadable_layout(self, mock_create_runtime_session):
        """An unreadable layout marker fails setup instead of risking a live server."""
        host = _full_facts_host(_LayoutProbeFailingHost)
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_LAYOUT_UNREADABLE")
        self.assertEqual(result["stage"], "verify_layout_version")

    @patch("orchestrator.http_parts.http_config.socket.getaddrinfo")
    @patch("engine.create_runtime_session")
    def test_setup_server_reports_invalid_http_config(
        self,
        mock_create_runtime_session,
        mock_getaddrinfo,
    ):
        """An unresolvable server address fails the HTTP bootstrap validation."""
        mock_getaddrinfo.side_effect = socket.gaierror("no such host")
        host = _full_facts_host()
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "server.example.com",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["stage"], "setup_http_bootstrap")

    @patch("engine._open_runtime_session")
    def test_setup_server_returns_http_open_error(self, mock_open_runtime_session):
        """A refused HTTP-bootstrap session surfaces the opener's error."""
        host = _full_facts_host()
        http_error = {
            "status": "error",
            "code": "ENGINE_CONNECTION_ERROR",
            "msg": "http session refused",
        }
        mock_open_runtime_session.side_effect = [
            {"ok": True, "session": _FakeSession(host)},
            {"ok": False, "error": http_error},
        ]

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result, http_error)

    @patch("engine.create_runtime_session")
    def test_setup_server_warns_on_http_disconnect_without_failing(
        self, mock_create_runtime_session
    ):
        """A noisy HTTP-bootstrap close warns but keeps setup green."""
        host = _full_facts_host()
        mock_create_runtime_session.side_effect = [
            _FakeSession(host),
            _NoisyCloseSession(host),
        ]

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")

    @patch("engine.create_runtime_session")
    def test_setup_server_passthrough_http_cancel(self, mock_create_runtime_session):
        """A cancelled HTTP bootstrap returns the cancellation unchanged."""
        from orchestrator.infra_parts import provisioning as provisioning_module

        host = _full_facts_host()
        mock_create_runtime_session.side_effect = [
            _FakeSession(host),
            _FakeSession(host),
        ]
        original_execute = provisioning_module.run_plan_execute

        def _execute(*args, **kwargs):
            steps = kwargs.get("steps", args[0] if args else [])
            if steps and steps[0].id.startswith("http_"):
                return {
                    "status": "error",
                    "code": "ENGINE_TASK_CANCELLED",
                    "msg": "cancelled during http bootstrap",
                }
            return original_execute(*args, **kwargs)

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        with patch(
            "orchestrator.infra_parts.provisioning.run_plan_execute",
            side_effect=_execute,
        ):
            result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(result["msg"], "cancelled during http bootstrap")

    @patch("engine.create_runtime_session")
    def test_setup_server_warns_on_bootstrap_disconnect_without_failing(
        self, mock_create_runtime_session
    ):
        """A noisy bootstrap close warns but keeps a successful setup green."""
        host = _full_facts_host()
        mock_create_runtime_session.side_effect = [
            _NoisyCloseSession(host),
            _FakeSession(host),
        ]

        payload = json.dumps(
            _with_setup_contract(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "run",
                    "ip": "1.2.3.4",
                    "username": "root",
                    "password": "secret",
                    "parts": ["part2"],
                    "dry_run": False,
                }
            )
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")

    def test_setup_server_rejects_unknown_part(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "setup",
                "operation_id": "run",
                "ip": "1.2.3.4",
                "username": "root",
                "parts": ["part9"],
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")

    def test_setup_server_rejects_ssh_lockdown_without_key(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "setup",
                "operation_id": "run",
                "ip": "1.2.3.4",
                "username": "root",
                "settings": {
                    "disable_password_auth": True,
                    "disable_root_login": True,
                },
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")


if __name__ == "__main__":
    unittest.main()
