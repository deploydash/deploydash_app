import json
import unittest
from io import StringIO
from types import SimpleNamespace
from unittest.mock import Mock, patch

from paramiko import RSAKey
from pyinfra import facts
from pyinfra.api.exceptions import ConnectError

from engine import handle_request
from orchestrator.firewall_ufw import parse_ufw_probe, probe_ufw
from tests.pyinfra_fact_fixtures import ubuntu_linux_distribution


class _FakeHost:
    def __init__(self, fact_values=None):
        self._fact_values = fact_values or {}

    def get_fact(self, fact_class):
        return self._fact_values.get(fact_class)

    def run_shell_command(self, command, _timeout=None, _sudo=None):
        # Connect now probes the layout marker first (T-1.1.6). These fakes
        # stand in for a machine with no Deploy Dash state on it, which is
        # the unprovisioned case check_server is normally run against.
        if "LAYOUT_VERSION" in command:
            return True, _FakeShellOutput(["marker=", "legacy=0"])
        raise AssertionError(f"unexpected command: {command}")


class _FakeShellOutput:
    def __init__(self, stdout_lines=None):
        self.stdout_lines = stdout_lines or []


class _CompatibilityProbeHost(_FakeHost):
    def __init__(
        self,
        *,
        os_id="ubuntu",
        version_id="24.04",
        arch="x86_64",
        installed_services=None,
        reachability=None,
        fact_values=None,
        admin_keys="absent",
        ufw=None,
    ):
        super().__init__(fact_values=fact_values)
        self.os_id = os_id
        self.version_id = version_id
        self.arch = arch
        self.installed_services = installed_services or {}
        self.reachability = reachability or {}
        self.admin_keys = admin_keys
        self.ufw = ufw or {"installed": False, "active": False, "enabled": False}

    def run_shell_command(self, command, _timeout=0, _sudo=None):
        if "LAYOUT_VERSION" in command:
            return True, _FakeShellOutput(["marker=", "legacy=0"])
        if "VERSION_ID_VALUE" in command:
            return True, _FakeShellOutput(
                [
                    f"os_id={self.os_id}",
                    f"version_id={self.version_id}",
                    f"arch={self.arch}",
                ]
            )

        service_key = None
        if "docker-ce" in command:
            service_key = "docker"
        elif "apache2" in command:
            service_key = "apache"
        elif "nginx-common" in command:
            service_key = "nginx"
        elif " caddy " in f" {command} ":
            service_key = "caddy"
        elif "traefik" in command:
            service_key = "traefik"
        elif "postgresql-client" in command:
            service_key = "postgres"
        elif "mariadb-server" in command:
            service_key = "mysql"
        elif "bind9" in command:
            service_key = "bind9"

        if service_key is not None:
            service_data = self.installed_services.get(service_key, {})
            return True, _FakeShellOutput(
                [
                    f"command={service_data.get('command', '')}",
                    f"package={service_data.get('package', '')}",
                    f"unit={service_data.get('unit', '')}",
                    f"active={service_data.get('active', '')}",
                ]
            )

        if "ADMIN_USER=" in command:
            if self.admin_keys == "unreadable":
                return False, _FakeShellOutput([])
            if self.admin_keys == "absent":
                return True, _FakeShellOutput(["exists=0"])
            if self.admin_keys == "nocount":
                return True, _FakeShellOutput(["exists=1", "has_home=1"])
            if self.admin_keys == "nofingerprints":
                return True, _FakeShellOutput(
                    [
                        "exists=1",
                        "authorized_key_count=2",
                        "has_home=1",
                        "authorized_key_fingerprints=",
                    ]
                )
            fingerprints = "|".join(self.admin_keys)
            return True, _FakeShellOutput(
                [
                    "exists=1",
                    f"authorized_key_count={len(self.admin_keys)}",
                    "has_home=1",
                    f"authorized_key_fingerprints={fingerprints}",
                ]
            )

        if "UFW_INSTALLED=" in command:
            lines = [
                f"UFW_INSTALLED={1 if self.ufw.get('installed') else 0}",
                f"UFW_ACTIVE={1 if self.ufw.get('active') else 0}",
                f"UFW_ENABLED={1 if self.ufw.get('enabled') else 0}",
            ]
            lines.extend(f"UFW_RULE={rule}" for rule in self.ufw.get("allowed_rules", []))
            return True, _FakeShellOutput(lines)

        if "DeployDashCompatibilityCheck" in command:
            probe_ids = [
                "ubuntu_package_repository_reachable",
                "docker_package_repository_reachable",
                "github_releases_reachable",
                "ghcr_registry_reachable",
                "docker_hub_registry_reachable",
            ]
            lines = []
            for probe_id in probe_ids:
                probe_data = self.reachability.get(
                    probe_id,
                    {"passed": True, "actual": f"HTTP 200 from {probe_id}"},
                )
                lines.append(f"{probe_id}_passed={'1' if probe_data.get('passed') else '0'}")
                lines.append(f"{probe_id}_actual={probe_data.get('actual', 'No result')}")
            return True, _FakeShellOutput(lines)

        return True, _FakeShellOutput([])


class _FakeSession:
    def __init__(self, host):
        self.host = host

    def close(self):
        return {"disconnect_error": None}


class TestSSHConnectivity(unittest.TestCase):
    def test_ufw_probe_parser_and_failure_boundaries(self):
        """The shared probe must preserve rules and make every failure diagnosable."""
        parsed = parse_ufw_probe(
            SimpleNamespace(
                stdout_lines=[
                    None,
                    "not-a-rule",
                    "UFW_INSTALLED=1",
                    "UFW_ACTIVE=1",
                    "UFW_ENABLED=0",
                    "UFW_RULE=   ",
                    "UFW_RULE=80/tcp ALLOW IN Anywhere",
                ],
            ),
        )
        self.assertEqual(
            parsed,
            {
                "installed": True,
                "active": True,
                "enabled": False,
                "allowed_rules": ["80/tcp ALLOW IN Anywhere"],
            },
        )

        unsupported = Mock(spec=[])
        self.assertIn("does not support", probe_ufw(unsupported)[1])

        throwing = Mock()
        throwing.run_shell_command.side_effect = RuntimeError("probe exploded")
        self.assertEqual(probe_ufw(throwing), (None, "probe exploded"))

        failure_cases = (
            ((False, None), "returned no output"),
            (
                (False, SimpleNamespace(stderr_lines=["permission denied"], stdout_lines=[])),
                "permission denied",
            ),
            (
                (False, SimpleNamespace(stderr_lines=[], stdout_lines=["bad status"])),
                "bad status",
            ),
            (
                (False, SimpleNamespace(stderr_lines=[], stdout_lines=[])),
                "probe command failed",
            ),
            ((True, None), "returned no output"),
        )
        for response, expected in failure_cases:
            with self.subTest(response=response):
                host = Mock()
                host.run_shell_command.return_value = response
                state, error = probe_ufw(host)
                self.assertIsNone(state)
                self.assertIn(expected, error)

    @patch("engine.create_runtime_session")
    @patch("engine.engine_runtime_common.subprocess.run")
    def test_handle_request_check_server_host_key_mismatch_returns_confirmation(
        self,
        mock_subprocess_run,
        mock_create_runtime_session,
    ):
        def _subprocess_side_effect(args, **kwargs):
            if args[:3] == ["ssh-keygen", "-F", "1.2.3.4"]:

                class _Result:
                    returncode = 0
                    stdout = "# Host 1.2.3.4 found: line 1\n1.2.3.4 ssh-ed25519 AAAAOLD\n"
                    stderr = ""

                return _Result()
            if args[:3] == ["ssh-keygen", "-lf", "-"]:
                input_blob = kwargs.get("input", "")

                class _Result:
                    returncode = 0
                    stdout = (
                        "256 SHA256:newfingerprint host (ED25519)\n"
                        if "AAAANEW" in input_blob
                        else "256 SHA256:oldfingerprint host (ED25519)\n"
                    )
                    stderr = ""

                return _Result()
            if args and args[0] == "ssh-keyscan":

                class _Result:
                    returncode = 0
                    stdout = "1.2.3.4 ssh-ed25519 AAAANEW\n"
                    stderr = ""

                return _Result()
            raise AssertionError(args)

        mock_subprocess_run.side_effect = _subprocess_side_effect
        mock_create_runtime_session.side_effect = ConnectError(
            "Host key for 1.2.3.4 does not match.",
        )

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

        self.assertEqual(result["status"], "error")
        self.assertTrue(result["host_key_confirmation_required"])
        self.assertEqual(
            result["host_key_mismatch"]["old_fingerprint"],
            "SHA256:oldfingerprint",
        )
        self.assertEqual(
            result["host_key_mismatch"]["new_fingerprint"],
            "SHA256:newfingerprint",
        )
        self.assertEqual(mock_create_runtime_session.call_count, 1)

    @patch("engine.create_runtime_session")
    @patch("engine.engine_runtime_common.subprocess.run")
    def test_handle_request_check_server_host_key_mismatch_helpful_message(
        self,
        mock_subprocess_run,
        mock_create_runtime_session,
    ):
        mock_create_runtime_session.side_effect = [
            ConnectError("Host key for 1.2.3.4 does not match."),
            ConnectError("Host key for 1.2.3.4 does not match."),
        ]

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

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_AUTH_FAILED")
        self.assertIn("identity looks different", result["msg"])
        self.assertIn("host_key_mismatch", result)

    @patch("engine.engine_runtime_common.subprocess.run")
    def test_handle_request_refresh_server_host_key_success(self, mock_subprocess_run):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "refresh_host_key",
                "ip": "1.2.3.4",
                "username": "user",
                "port": 22,
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["workflow_id"], "server")
        self.assertEqual(result["operation_id"], "refresh_host_key")
        self.assertIn("known_hosts_file", result)
        self.assertGreaterEqual(mock_subprocess_run.call_count, 1)

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_success(self, mock_create_runtime_session):
        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.LinuxDistribution: ubuntu_linux_distribution(
                    "24.04",
                    pretty_name="Ubuntu 24.04.1 LTS",
                ),
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 4096,
                facts.hardware.BlockDevices: {"/dev/vda1": {"blocks": "83886080", "mount": "/"}},
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
        self.assertEqual(result["os"], "Ubuntu 24.04.1 LTS")
        self.assertEqual(result["cpu"], "x86_64")
        self.assertEqual(result["memory_mb"], 4096)

        _, kwargs = mock_create_runtime_session.call_args
        self.assertEqual(kwargs["host_name"], "1.2.3.4")
        connector_data = kwargs["connector_data"]
        self.assertEqual(connector_data["ssh_user"], "user")
        self.assertEqual(connector_data["ssh_password"], "pwd")
        self.assertEqual(connector_data["ssh_port"], 22)
        self.assertFalse(connector_data["ssh_allow_agent"])
        self.assertFalse(connector_data["ssh_look_for_keys"])
        self.assertEqual(connector_data["ssh_connect_retries"], 0)
        self.assertEqual(
            connector_data["ssh_paramiko_connect_kwargs"]["auth_timeout"],
            3,
        )
        self.assertEqual(
            connector_data["ssh_paramiko_connect_kwargs"]["banner_timeout"],
            3,
        )
        self.assertEqual(
            connector_data["ssh_strict_host_key_checking"],
            "accept-new",
        )
        self.assertIn("ssh_known_hosts_file", connector_data)
        self.assertTrue(connector_data["ssh_known_hosts_file"])
        self.assertNotIn("ssh_key", connector_data)

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_ignores_key_path_auth(
        self,
        mock_create_runtime_session,
    ):
        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 2048,
                facts.hardware.BlockDevices: {},
            },
        )
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "1.2.3.4",
                "username": "root",
                "key_path": "/tmp/id_ed25519",
                "port": 2222,
            }
        )
        _ = json.loads(handle_request(payload))

        _, kwargs = mock_create_runtime_session.call_args
        connector_data = kwargs["connector_data"]
        self.assertEqual(connector_data["ssh_user"], "root")
        self.assertEqual(connector_data["ssh_port"], 2222)
        self.assertNotIn("ssh_key", connector_data)
        self.assertFalse(connector_data["ssh_allow_agent"])
        self.assertFalse(connector_data["ssh_look_for_keys"])
        self.assertEqual(connector_data["ssh_connect_retries"], 0)
        self.assertEqual(
            connector_data["ssh_paramiko_connect_kwargs"]["auth_timeout"],
            3,
        )
        self.assertEqual(
            connector_data["ssh_paramiko_connect_kwargs"]["banner_timeout"],
            3,
        )
        self.assertEqual(
            connector_data["ssh_strict_host_key_checking"],
            "accept-new",
        )
        self.assertIn("ssh_known_hosts_file", connector_data)
        self.assertTrue(connector_data["ssh_known_hosts_file"])
        self.assertNotIn("ssh_password", connector_data)

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_inline_private_key_uses_paramiko_pkey(
        self,
        mock_create_runtime_session,
    ):
        host = _FakeHost(
            {
                facts.server.Kernel: "Linux",
                facts.server.Arch: "x86_64",
                facts.hardware.Memory: 2048,
                facts.hardware.BlockDevices: {},
            },
        )
        mock_create_runtime_session.return_value = _FakeSession(host)

        private_key_buffer = StringIO()
        RSAKey.generate(1024).write_private_key(private_key_buffer)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "1.2.3.4",
                "username": "root",
                "private_key": private_key_buffer.getvalue(),
                "port": 2222,
            }
        )
        _ = json.loads(handle_request(payload))

        _, kwargs = mock_create_runtime_session.call_args
        connector_data = kwargs["connector_data"]
        self.assertEqual(connector_data["ssh_user"], "root")
        self.assertEqual(connector_data["ssh_port"], 2222)
        self.assertNotIn("ssh_key", connector_data)
        self.assertIn("ssh_paramiko_connect_kwargs", connector_data)
        self.assertIsNotNone(connector_data["ssh_paramiko_connect_kwargs"].get("pkey"))
        self.assertFalse(connector_data["ssh_allow_agent"])
        self.assertFalse(connector_data["ssh_look_for_keys"])
        self.assertEqual(connector_data["ssh_connect_retries"], 0)

    def test_handle_request_check_server_invalid_port(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "1.2.3.4",
                "username": "root",
                "port": 70000,
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["stage"], "validate_request")

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_auth_error_message(
        self,
        mock_create_runtime_session,
    ):
        mock_create_runtime_session.side_effect = ConnectError(
            "Authentication error (username=root, password=bad) (Authentication failed.)",
        )

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "1.2.3.4",
                "username": "root",
                "password": "bad",
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_AUTH_FAILED")
        self.assertIn("Authentication failed. Verify the SSH username", result["msg"])

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_host_resolution_message(
        self,
        mock_create_runtime_session,
    ):
        mock_create_runtime_session.side_effect = ConnectError(
            "Could not resolve hostname invalid-hostname: Name or service not known",
        )

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "invalid-hostname",
                "username": "root",
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_AUTH_FAILED")
        self.assertIn("Could not resolve hostname", result["msg"])

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_no_hosts_remaining_message(
        self,
        mock_create_runtime_session,
    ):
        mock_create_runtime_session.side_effect = ConnectError("No hosts remaining!")

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "1.2.3.4",
                "username": "root",
                "password": "bad",
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_AUTH_FAILED")
        self.assertIn("Could not establish SSH connection", result["msg"])

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_compatibility_pass_for_clean_host(
        self,
        mock_create_runtime_session,
    ):
        host = _CompatibilityProbeHost()
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "203.0.113.10",
                "username": "root",
                "password": "pwd",
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        compatibility = result.get("compatibility", {})
        self.assertEqual(compatibility.get("status"), "pass")
        checks = {entry["id"]: entry for entry in compatibility.get("checks", [])}
        self.assertTrue(checks["os_ubuntu_24_04"]["passed"])
        self.assertTrue(checks["arch_x86_64"]["passed"])
        self.assertTrue(checks["docker_absent"]["passed"])
        self.assertTrue(checks["ubuntu_package_repository_reachable"]["passed"])
        self.assertTrue(checks["docker_package_repository_reachable"]["passed"])
        self.assertTrue(checks["github_releases_reachable"]["passed"])
        self.assertTrue(checks["ghcr_registry_reachable"]["passed"])
        self.assertTrue(checks["docker_hub_registry_reachable"]["passed"])

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_compatibility_fail_for_conflicts(
        self,
        mock_create_runtime_session,
    ):
        host = _CompatibilityProbeHost(
            arch="arm64",
            installed_services={
                "docker": {"command": "docker", "package": "docker-ce"},
                "nginx": {"package": "nginx"},
            },
        )
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "203.0.113.11",
                "username": "root",
                "password": "pwd",
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        compatibility = result.get("compatibility", {})
        self.assertEqual(compatibility.get("status"), "fail")
        failed_ids = {entry.get("id") for entry in compatibility.get("failed_checks", [])}
        self.assertIn("arch_x86_64", failed_ids)
        self.assertIn("docker_absent", failed_ids)
        self.assertIn("nginx_absent", failed_ids)

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_discloses_ufw_replacement(
        self,
        mock_create_runtime_session,
    ):
        """The review must explain every UFW state without blocking onboarding."""
        cases = (
            (
                {"installed": False, "active": False, "enabled": False},
                "ufw is not installed",
                "No ufw rules detected.",
            ),
            (
                {"installed": True, "active": False, "enabled": True},
                "ufw is installed but inactive",
                "No active ufw allow rules.",
            ),
            (
                {
                    "installed": True,
                    "active": True,
                    "enabled": True,
                    "allowed_rules": [
                        "22/tcp ALLOW IN Anywhere",
                        "3000/tcp ALLOW IN 198.51.100.0/24",
                    ],
                },
                "Deploy Dash will replace active ufw",
                "22/tcp ALLOW IN Anywhere\n3000/tcp ALLOW IN 198.51.100.0/24",
            ),
        )

        for ufw, message, actual in cases:
            with self.subTest(ufw=ufw):
                mock_create_runtime_session.return_value = _FakeSession(
                    _CompatibilityProbeHost(ufw=ufw),
                )
                payload = json.dumps(
                    {
                        "action": "run_workflow",
                        "workflow_id": "server",
                        "operation_id": "check",
                        "ip": "203.0.113.19",
                        "username": "root",
                        "password": "pwd",
                    }
                )

                result = json.loads(handle_request(payload))
                checks = {entry["id"]: entry for entry in result["compatibility"]["checks"]}
                entry = checks["ufw_replacement"]
                self.assertTrue(entry["passed"])
                self.assertIn(message, entry["message"])
                self.assertEqual(entry["actual"], actual)

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_compatibility_fails_for_unreachable_package_sources(
        self,
        mock_create_runtime_session,
    ):
        host = _CompatibilityProbeHost(
            reachability={
                "docker_package_repository_reachable": {
                    "passed": False,
                    "actual": "TimeoutError: timed out from Docker repository",
                }
            }
        )
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "203.0.113.12",
                "username": "root",
                "password": "pwd",
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        compatibility = result.get("compatibility", {})
        self.assertEqual(compatibility.get("status"), "fail")
        checks = {entry["id"]: entry for entry in compatibility.get("checks", [])}
        self.assertFalse(checks["docker_package_repository_reachable"]["passed"])
        self.assertIn(
            "Setup would fail while installing Docker",
            checks["docker_package_repository_reachable"]["message"],
        )
        failed_ids = {entry.get("id") for entry in compatibility.get("failed_checks", [])}
        self.assertIn("docker_package_repository_reachable", failed_ids)

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_reports_existing_admin_keys(
        self,
        mock_create_runtime_session,
    ):
        host = _CompatibilityProbeHost(admin_keys=["SHA256:aaa", "SHA256:bbb"])
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "203.0.113.13",
                "username": "root",
                "password": "pwd",
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        compatibility = result.get("compatibility", {})
        self.assertEqual(compatibility.get("status"), "pass")
        checks = {entry["id"]: entry for entry in compatibility.get("checks", [])}
        entry = checks["existing_admin_keys"]
        self.assertTrue(entry["passed"])
        self.assertEqual(entry["label"], "Deploy Dash adds 1 SSH key")
        self.assertIn("already has 2 SSH keys", entry["message"])
        self.assertIn("SHA256:aaa", entry["actual"])
        self.assertIn("SHA256:bbb", entry["actual"])

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_reports_absent_admin_account(
        self,
        mock_create_runtime_session,
    ):
        host = _CompatibilityProbeHost(admin_keys="absent")
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "203.0.113.14",
                "username": "root",
                "password": "pwd",
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        compatibility = result.get("compatibility", {})
        checks = {entry["id"]: entry for entry in compatibility.get("checks", [])}
        entry = checks["existing_admin_keys"]
        self.assertTrue(entry["passed"])
        self.assertIn("No existing ubuntu account", entry["message"])

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_reports_unreadable_admin_probe_as_unknown(
        self,
        mock_create_runtime_session,
    ):
        host = _CompatibilityProbeHost(admin_keys="unreadable")
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "203.0.113.15",
                "username": "root",
                "password": "pwd",
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        compatibility = result.get("compatibility", {})
        self.assertEqual(compatibility.get("status"), "pass")
        checks = {entry["id"]: entry for entry in compatibility.get("checks", [])}
        entry = checks["existing_admin_keys"]
        self.assertTrue(entry["passed"])
        self.assertNotIn(
            "existing_admin_keys", {e.get("id") for e in compatibility.get("failed_checks", [])}
        )

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_reports_keyless_admin_account(
        self,
        mock_create_runtime_session,
    ):
        host = _CompatibilityProbeHost(admin_keys=[])
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "203.0.113.16",
                "username": "root",
                "password": "pwd",
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        compatibility = result.get("compatibility", {})
        checks = {entry["id"]: entry for entry in compatibility.get("checks", [])}
        entry = checks["existing_admin_keys"]
        self.assertTrue(entry["passed"])
        self.assertIn("exists with no SSH keys", entry["message"])

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_reports_countless_admin_probe_as_unknown(
        self,
        mock_create_runtime_session,
    ):
        host = _CompatibilityProbeHost(admin_keys="nocount")
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "203.0.113.17",
                "username": "root",
                "password": "pwd",
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        compatibility = result.get("compatibility", {})
        self.assertEqual(compatibility.get("status"), "pass")
        checks = {entry["id"]: entry for entry in compatibility.get("checks", [])}
        entry = checks["existing_admin_keys"]
        self.assertTrue(entry["passed"])
        self.assertIn("Could not determine the existing SSH keys", entry["message"])

    @patch("engine.create_runtime_session")
    def test_handle_request_check_server_reports_missing_key_fingerprints(
        self,
        mock_create_runtime_session,
    ):
        host = _CompatibilityProbeHost(admin_keys="nofingerprints")
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "check",
                "ip": "203.0.113.18",
                "username": "root",
                "password": "pwd",
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        compatibility = result.get("compatibility", {})
        checks = {entry["id"]: entry for entry in compatibility.get("checks", [])}
        entry = checks["existing_admin_keys"]
        self.assertTrue(entry["passed"])
        self.assertIn("already has 2 SSH keys", entry["message"])
        self.assertEqual(entry["actual"], "No key fingerprints listed.")


if __name__ == "__main__":
    unittest.main()
