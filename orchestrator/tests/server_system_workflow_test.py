import json
import unittest
from unittest.mock import patch

from engine import handle_request
from orchestrator.infra_parts import system_settings as system_settings_module


class _FakeOutput:
    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


class _FakeSystemHost:
    def __init__(
        self,
        authorized_keys_present=True,
        root_login_raw="no",
        password_auth_raw="yes",
        keyboard_interactive_raw="no",
        reboot_required=False,
        reboot_required_packages="",
        reboot_required_packages_readable=True,
        reboot_required_since="0",
        schedule_reboot_succeeds=True,
        health_check_succeeds=True,
        health_values=None,
        health_values_sequence=None,
        managed_container_ids=None,
        verify_succeeds=True,
        fail_command_contains=None,
        fail_on_match=1,
        status_succeeds=True,
    ):
        self.commands = []
        self.authorized_keys_present = authorized_keys_present
        self.root_login_raw = root_login_raw
        self.password_auth_raw = password_auth_raw
        self.keyboard_interactive_raw = keyboard_interactive_raw
        self.reboot_required = reboot_required
        self.reboot_required_packages = reboot_required_packages
        self.reboot_required_packages_readable = reboot_required_packages_readable
        self.reboot_required_since = reboot_required_since
        self.schedule_reboot_succeeds = schedule_reboot_succeeds
        self.health_check_succeeds = health_check_succeeds
        self.health_values = health_values or {
            "docker_active": "true",
            "managed_containers_running": "true",
            "firewall_ipv4_present": "true",
            "firewall_ipv6_present": "true",
            "swap_active": "true",
            "ssh_listening": "true",
            "reboot_required_cleared": "true",
        }
        self.health_values_sequence = list(health_values_sequence or [])
        self.managed_container_ids = (
            ["managed-container-1"]
            if managed_container_ids is None
            else list(managed_container_ids)
        )
        self.verify_succeeds = verify_succeeds
        self.fail_command_contains = fail_command_contains
        self.fail_on_match = fail_on_match
        self.failure_match_count = 0
        self.status_succeeds = status_succeeds
        self.firewall_stage_token = None

    def run_shell_command(self, command, _timeout=10, _sudo=False):
        self.commands.append((command, _timeout, _sudo))

        if "root_raw=" in command and "maintenance_time_raw=" in command:
            return (
                self.status_succeeds,
                _FakeOutput(
                    [
                        f"root_raw={self.root_login_raw}",
                        f"password_raw={self.password_auth_raw}",
                        f"keyboard_interactive_raw={self.keyboard_interactive_raw}",
                        "ssh_port=22",
                        "timezone=UTC",
                        "swap_bytes=2147483648",
                        "auto_reboot_raw=false",
                        "maintenance_time_raw=03:00",
                        f"reboot_required={'true' if self.reboot_required else 'false'}",
                        f"reboot_required_packages={self.reboot_required_packages}",
                        "reboot_required_packages_readable="
                        f"{'true' if self.reboot_required_packages_readable else 'false'}",
                        f"reboot_required_since={self.reboot_required_since}",
                    ]
                ),
            )

        if "DEPLOYDASH_USER" in command and "authorized_keys" in command:
            return self.authorized_keys_present, _FakeOutput([])

        if "ip route get 1.1.1.1" in command:
            return True, _FakeOutput(["IFACE=eth0"])

        if "systemd-run" in command and "systemctl reboot" in command:
            return self.schedule_reboot_succeeds, _FakeOutput(
                [f"managed_container_ids={','.join(self.managed_container_ids)}"]
                if self.schedule_reboot_succeeds
                else ["schedule failed"]
            )

        if "docker_active=" in command and "ssh_listening=" in command:
            health_values = (
                self.health_values_sequence.pop(0)
                if self.health_values_sequence
                else self.health_values
            )
            return self.health_check_succeeds, _FakeOutput(
                [f"{key}={value}" for key, value in health_values.items()]
            )

        if self.fail_command_contains and self.fail_command_contains in command:
            self.failure_match_count += 1
            if self.failure_match_count == self.fail_on_match:
                return False, _FakeOutput(stderr_lines=["injected command failure"])

        if "BACKUP_DIR=" in command:
            return True, _FakeOutput(["backup_dir=/tmp/deploydash-system-backup-1"])

        if "echo deploydash-system-verify" in command:
            return self.verify_succeeds, _FakeOutput(["deploydash-system-verify"])

        if "RESTORE_DIR=" in command:
            return True, _FakeOutput([])

        if "update_sshd_option()" in command and "sshd -t" in command:
            return True, _FakeOutput([])

        if "timedatectl set-timezone" in command:
            return True, _FakeOutput([])

        if "swapoff /swapfile" in command or "mkswap /swapfile" in command:
            return True, _FakeOutput([])

        if "/etc/apt/apt.conf.d/52unattended-upgrades-local" in command:
            return True, _FakeOutput([])

        if "/etc/apt/apt.conf.d/20auto-upgrades" in command:
            return True, _FakeOutput([])

        if "unattended-upgrades apt-listchanges" in command and "apt-get" in command:
            return True, _FakeOutput([])

        if "systemctl restart ssh" in command:
            return True, _FakeOutput([])

        if "PENDING=0" in command and "STAGE_FILE" in command:
            if self.firewall_stage_token:
                return True, _FakeOutput(
                    [
                        "PENDING=1",
                        f"TOKEN={self.firewall_stage_token}",
                        "EXPIRES_AT=2026-09-30T12:00:00+00:00",
                        f"SNAPSHOT_V4=/opt/deploydash/firewall/snapshot-{self.firewall_stage_token}.restore.v4.sh",
                        f"SNAPSHOT_V6=/opt/deploydash/firewall/snapshot-{self.firewall_stage_token}.restore.v6.sh",
                    ],
                )
            return True, _FakeOutput(["PENDING=0"])

        if 'cat > "${STAGE_FILE}" <<EOF' in command:
            self.firewall_stage_token = next(
                line.removeprefix("TOKEN=")
                for line in command.splitlines()
                if line.startswith("TOKEN=")
            )
            return True, _FakeOutput([])

        if 'ROLLBACK_SCRIPT="$(mktemp)"' in command:
            return True, _FakeOutput([])

        if 'sh -eu "${SNAPSHOT}"' in command:
            return True, _FakeOutput([])

        if "export STAGE_FILE EXPECTED_TOKEN" in command:
            self.firewall_stage_token = None
            return True, _FakeOutput([])

        if command == "mkdir -p /opt/deploydash/firewall":
            return True, _FakeOutput([])

        if "iptables" in command or "ip6tables" in command:
            return True, _FakeOutput([])

        return False, _FakeOutput(stderr_lines=["unexpected command"])


class _FakeSession:
    def __init__(self, host, disconnect_error=None):
        self.host = host
        self.disconnect_error = disconnect_error

    def close(self):
        return {"disconnect_error": self.disconnect_error}


class TestServerSystemWorkflow(unittest.TestCase):
    def test_system_settings_normalization_keeps_modes_and_safe_legacy_defaults(self):
        """Request normalization must distinguish explicit modes from legacy booleans."""
        normalize = system_settings_module._normalize_requested_system_settings

        self.assertEqual(normalize(None)["root_login_mode"], "disabled")
        self.assertEqual(
            normalize({"root_login_enabled": "yes"})["root_login_mode"],
            "key_only",
        )
        self.assertEqual(
            normalize({"root_login_mode": " PASSWORD_ALLOWED "})["root_login_mode"],
            "password_allowed",
        )
        self.assertEqual(normalize({"root_login_mode": 7})["root_login_mode"], 7)
        self.assertFalse(normalize({"password_auth_enabled": "off"})["password_auth_enabled"])
        self.assertFalse(
            normalize({"password_auth_enabled": "not-a-bool"})["password_auth_enabled"]
        )
        self.assertEqual(normalize({"maintenance_time": "3:00"})["maintenance_time"], "03:00")
        self.assertEqual(normalize({"maintenance_time": "ab:cd"})["maintenance_time"], "03:00")
        self.assertIsNone(normalize({})["swap_gb"])
        self.assertEqual(normalize({"swap_gb": "4.5"})["swap_gb"], 4.5)
        self.assertEqual(normalize({"swap_gb": "invalid"})["swap_gb"], "invalid")
        self.assertEqual(normalize({"swap_gb": []})["swap_gb"], [])

    @patch("engine.create_runtime_session")
    def test_system_apply_never_touches_unchanged_swap_on_apply_or_rollback(
        self,
        mock_create_runtime_session,
    ):
        """Unrelated saves and their rollback must leave active swap untouched."""
        for verify_succeeds in (True, False):
            with self.subTest(verify_succeeds=verify_succeeds):
                host = _FakeSystemHost(verify_succeeds=verify_succeeds)
                mock_create_runtime_session.return_value = _FakeSession(host)
                payload = json.dumps(
                    {
                        "action": "run_workflow",
                        "workflow_id": "server",
                        "operation_id": "system_apply",
                        "connection": {
                            "ip": "203.0.113.44",
                            "port": 22,
                            "username": "ubuntu",
                            "password": "secret",
                        },
                        "params": {
                            "dry_run": False,
                            "settings": {
                                "root_login_mode": "disabled",
                                "password_auth_enabled": True,
                                "ssh_port": 22,
                                "timezone": "UTC",
                                "swap_gb": 2,
                                "auto_reboot_enabled": False,
                                "maintenance_time": "03:00",
                            },
                        },
                    }
                )

                handle_request(payload)

                command_blob = "\n".join(command for command, *_ in host.commands)
                self.assertNotIn("swapoff /swapfile", command_blob)
                self.assertNotIn("mkswap /swapfile", command_blob)

    def test_system_settings_validation_rejects_each_invalid_field(self):
        """Every invalid mode or supporting setting must stop before SSH is opened."""
        ctx = unittest.mock.Mock()
        ctx.error_result.side_effect = lambda code, msg, **kwargs: {
            "code": code,
            "msg": msg,
            **kwargs,
        }
        valid = {
            "root_login_mode": "disabled",
            "ssh_port": 22,
            "timezone": "UTC",
            "swap_gb": 2.0,
            "maintenance_time": "03:00",
        }
        invalid_fields = {
            "root_login_mode": "unknown",
            "ssh_port": 0,
            "timezone": "",
            "swap_gb": 65,
            "maintenance_time": "25:00",
        }

        for field, value in invalid_fields.items():
            with self.subTest(field=field):
                settings = {**valid, field: value}
                result = system_settings_module._validate_system_settings(ctx, settings)
                self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")

        self.assertIsNone(system_settings_module._validate_system_settings(ctx, valid))

    def test_system_status_dry_run_returns_plan(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_status",
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
        self.assertEqual(result["operation_id"], "system_status")
        self.assertGreaterEqual(len(result.get("actions", [])), 3)

    @patch("engine.create_runtime_session")
    def test_system_status_reads_settings(self, mock_create_runtime_session):
        host = _FakeSystemHost()
        mock_create_runtime_session.return_value = _FakeSession(host)
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_status",
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
        settings = result.get("settings", {})
        self.assertEqual(settings.get("ssh_port"), 22)
        self.assertEqual(settings.get("timezone"), "UTC")
        self.assertEqual(settings.get("swap_gb"), 2.0)
        self.assertEqual(settings.get("password_auth_enabled"), True)

    @patch("engine.create_runtime_session")
    def test_system_status_reports_password_access_when_pam_prompts_are_enabled(
        self,
        mock_create_runtime_session,
    ):
        """The UI must not claim passwords are off while PAM can still prompt."""
        host = _FakeSystemHost(
            password_auth_raw="no",
            keyboard_interactive_raw="yes",
        )
        mock_create_runtime_session.return_value = _FakeSession(host)
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_status",
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

        self.assertTrue(result["settings"]["password_auth_enabled"])

    @patch("engine.create_runtime_session")
    def test_system_status_reports_reboot_required_details(
        self,
        mock_create_runtime_session,
    ):
        """A restart prompt needs exact package and marker evidence from the host."""
        required_host = _FakeSystemHost(
            reboot_required=True,
            reboot_required_packages="linux-image-6.8.0-85-generic,libc6",
            reboot_required_since="1790784000",
        )
        mock_create_runtime_session.return_value = _FakeSession(required_host)
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_status",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {"dry_run": False},
            }
        )

        required = json.loads(handle_request(payload))["settings"]

        self.assertTrue(required["reboot_required"])
        self.assertEqual(
            required["reboot_required_packages"],
            ["linux-image-6.8.0-85-generic", "libc6"],
        )
        self.assertTrue(required["reboot_required_packages_readable"])
        self.assertEqual(required["reboot_required_since"], 1790784000)

        unreadable_host = _FakeSystemHost(
            reboot_required=True,
            reboot_required_packages="ignored",
            reboot_required_packages_readable=False,
            reboot_required_since="not-a-number",
        )
        mock_create_runtime_session.return_value = _FakeSession(unreadable_host)

        unreadable = json.loads(handle_request(payload))["settings"]

        self.assertTrue(unreadable["reboot_required"])
        self.assertEqual(unreadable["reboot_required_packages"], [])
        self.assertFalse(unreadable["reboot_required_packages_readable"])
        self.assertIsNone(unreadable["reboot_required_since"])

        healthy_host = _FakeSystemHost()
        mock_create_runtime_session.return_value = _FakeSession(healthy_host)

        healthy = json.loads(handle_request(payload))["settings"]

        self.assertFalse(healthy["reboot_required"])
        self.assertEqual(healthy["reboot_required_packages"], [])
        self.assertTrue(healthy["reboot_required_packages_readable"])
        self.assertIsNone(healthy["reboot_required_since"])

    def test_system_restart_dry_run_describes_reboot_and_health_proof(self):
        """Dry-run review must expose downtime and every post-reboot check."""
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_restart",
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
        self.assertEqual(result["operation_id"], "system_restart")
        self.assertIn("Wait for SSH to stop and return", result["actions"])
        self.assertIn("Verify managed server health", result["actions"])

    @patch("orchestrator.infra_parts.system_settings.time.sleep")
    @patch("engine.create_runtime_session")
    def test_system_restart_waits_for_disconnect_then_proves_health(
        self,
        mock_create_runtime_session,
        mock_sleep,
    ):
        """A successful restart requires observed downtime and independent health checks."""
        initial_host = _FakeSystemHost()
        health_host = _FakeSystemHost()
        mock_create_runtime_session.side_effect = [
            _FakeSession(initial_host),
            _FakeSession(_FakeSystemHost()),
            RuntimeError("connection refused"),
            RuntimeError("connection refused"),
            _FakeSession(health_host),
        ]
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_restart",
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
        self.assertEqual(result["operation_id"], "system_restart")
        self.assertTrue(all(result["health_checks"].values()))
        self.assertEqual(mock_create_runtime_session.call_count, 5)
        self.assertEqual(mock_sleep.call_count, 2)
        health_command = next(
            command
            for command, _timeout, _sudo in health_host.commands
            if "docker_active=" in command
        )
        self.assertIn("managed-container-1", health_command)

    def test_post_reboot_health_targets_the_pre_reboot_managed_containers(self):
        """Container recovery must be grounded in the inventory taken before reboot."""
        command = system_settings_module._post_reboot_health_command(
            22,
            ("managed-one", "managed-two"),
        )

        self.assertIn("docker inspect", command)
        self.assertIn("managed-one", command)
        self.assertIn("managed-two", command)
        self.assertNotIn('MANAGED_TOTAL" = "$MANAGED_RUNNING', command)

    @patch("orchestrator.infra_parts.system_settings._REBOOT_POLL_ATTEMPTS", 1)
    @patch("orchestrator.infra_parts.system_settings.time.sleep")
    def test_system_restart_retries_transient_unhealthy_state(self, mock_sleep):
        """A newly reachable SSH daemon must not make transient service startup fatal."""
        transient_values = {
            "docker_active": "false",
            "managed_containers_running": "false",
            "firewall_ipv4_present": "true",
            "firewall_ipv6_present": "true",
            "swap_active": "true",
            "ssh_listening": "true",
            "reboot_required_cleared": "true",
        }
        healthy_values = dict(transient_values)
        healthy_values["docker_active"] = "true"
        healthy_values["managed_containers_running"] = "true"
        health_host = _FakeSystemHost(health_values_sequence=[transient_values, healthy_values])
        ctx = unittest.mock.Mock()
        ctx.error_result.side_effect = lambda code, msg, **kwargs: {
            "status": "error",
            "code": code,
            "msg": msg,
            **kwargs,
            **(kwargs.get("extra") or {}),
        }
        ctx.open_runtime_session.side_effect = [
            {"ok": True, "session": _FakeSession(_FakeSystemHost())},
            {"ok": False, "error": {"status": "error"}},
            {"ok": True, "session": _FakeSession(health_host)},
        ]

        result = system_settings_module.run_server_system_restart_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
        )

        self.assertEqual(result["status"], "success")
        health_commands = [
            command
            for command, _timeout, _sudo in health_host.commands
            if "docker_active=" in command
        ]
        self.assertEqual(len(health_commands), 2)
        mock_sleep.assert_called_once()

    @patch("orchestrator.infra_parts.system_settings._REBOOT_POLL_ATTEMPTS", 1)
    @patch("orchestrator.infra_parts.system_settings.time.sleep")
    def test_system_restart_can_be_cancelled_before_health_retry(self, _mock_sleep):
        """Cancellation must remain responsive while post-reboot services are settling."""
        ctx = unittest.mock.Mock()
        ctx.error_result.side_effect = lambda code, msg, **kwargs: {
            "status": "error",
            "code": code,
            "msg": msg,
            **kwargs,
        }
        health_host = _FakeSystemHost()
        ctx.open_runtime_session.side_effect = [
            {"ok": True, "session": _FakeSession(_FakeSystemHost())},
            {"ok": False, "error": {"status": "error"}},
            {"ok": True, "session": _FakeSession(health_host)},
        ]
        cancellation_checks = iter((False, False, False, True))

        result = system_settings_module.run_server_system_restart_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
            is_cancelled=lambda: next(cancellation_checks),
        )

        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertIn("post-restart health", result["msg"])
        self.assertEqual(health_host.commands, [])

    @patch("orchestrator.infra_parts.system_settings._REBOOT_POLL_ATTEMPTS", 1)
    @patch("orchestrator.infra_parts.system_settings.time.sleep")
    def test_system_restart_reports_preflight_open_and_schedule_failures(
        self,
        _mock_sleep,
    ):
        """Restart must fail before polling when cancellation, SSH, or scheduling fails."""
        ctx = unittest.mock.Mock()
        ctx.error_result.side_effect = lambda code, msg, **kwargs: {
            "status": "error",
            "code": code,
            "msg": msg,
            **kwargs,
        }

        cancelled = system_settings_module.run_server_system_restart_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
            is_cancelled=lambda: True,
        )
        self.assertEqual(cancelled["code"], "ENGINE_TASK_CANCELLED")

        connection_error = {"status": "error", "code": "ENGINE_RUNTIME_ERROR"}
        ctx.open_runtime_session.return_value = {
            "ok": False,
            "error": connection_error,
        }
        unopened = system_settings_module.run_server_system_restart_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
        )
        self.assertIs(unopened, connection_error)

        schedule_host = _FakeSystemHost(schedule_reboot_succeeds=False)
        ctx.open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(schedule_host),
        }
        unscheduled = system_settings_module.run_server_system_restart_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
        )
        self.assertEqual(unscheduled["stage"], "execute_runtime_operation")
        self.assertIn("schedule", unscheduled["msg"])

    @patch("orchestrator.infra_parts.system_settings._REBOOT_POLL_ATTEMPTS", 1)
    @patch("orchestrator.infra_parts.system_settings.time.sleep")
    def test_system_restart_reports_polling_and_health_failures(
        self,
        _mock_sleep,
    ):
        """Every wait timeout and health failure must remain distinguishable."""
        ctx = unittest.mock.Mock()
        ctx.error_result.side_effect = lambda code, msg, **kwargs: {
            "status": "error",
            "code": code,
            "msg": msg,
            **kwargs,
            **(kwargs.get("extra") or {}),
        }
        initial = {"ok": True, "session": _FakeSession(_FakeSystemHost())}
        down = {"ok": False, "error": {"status": "error"}}
        connected = {"ok": True, "session": _FakeSession(_FakeSystemHost())}

        cancellation_checks = iter((False, True))
        ctx.open_runtime_session.side_effect = [initial]
        cancelled_down = system_settings_module.run_server_system_restart_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
            is_cancelled=lambda: next(cancellation_checks),
        )
        self.assertEqual(cancelled_down["code"], "ENGINE_TASK_CANCELLED")
        self.assertIn("waiting for the server", cancelled_down["msg"])

        ctx.open_runtime_session.reset_mock(side_effect=True)
        ctx.open_runtime_session.side_effect = [initial, connected]
        never_down = system_settings_module.run_server_system_restart_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
        )
        self.assertIn("did not go offline", never_down["msg"])

        cancellation_checks = iter((False, False, True))
        ctx.open_runtime_session.reset_mock(side_effect=True)
        ctx.open_runtime_session.side_effect = [initial, down]
        cancelled_up = system_settings_module.run_server_system_restart_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
            is_cancelled=lambda: next(cancellation_checks),
        )
        self.assertEqual(cancelled_up["code"], "ENGINE_TASK_CANCELLED")
        self.assertIn("SSH to return", cancelled_up["msg"])

        ctx.open_runtime_session.reset_mock(side_effect=True)
        ctx.open_runtime_session.side_effect = [initial, down, down]
        never_up = system_settings_module.run_server_system_restart_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
        )
        self.assertIn("SSH did not return", never_up["msg"])

        failed_health = {
            "ok": True,
            "session": _FakeSession(_FakeSystemHost(health_check_succeeds=False)),
        }
        ctx.open_runtime_session.reset_mock(side_effect=True)
        ctx.open_runtime_session.side_effect = [initial, down, failed_health]
        unavailable_health = system_settings_module.run_server_system_restart_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
        )
        self.assertIn("could not run", unavailable_health["msg"])

        unhealthy = {
            "ok": True,
            "session": _FakeSession(
                _FakeSystemHost(
                    health_values={
                        "docker_active": "false",
                        "managed_containers_running": "true",
                        "firewall_ipv4_present": "true",
                        "firewall_ipv6_present": "true",
                        "swap_active": "true",
                        "ssh_listening": "true",
                        "reboot_required_cleared": "true",
                    }
                )
            ),
        }
        ctx.open_runtime_session.reset_mock(side_effect=True)
        ctx.open_runtime_session.side_effect = [initial, down, unhealthy]
        failed_proof = system_settings_module.run_server_system_restart_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
        )
        self.assertIn("health checks failed", failed_proof["msg"])
        self.assertEqual(failed_proof["failed_checks"], ["Docker service is active"])

    @patch("engine.create_runtime_session")
    def test_system_status_reports_read_and_disconnect_failures(
        self,
        mock_create_runtime_session,
    ):
        """Status errors stay explicit and disconnect warnings do not replace success."""
        failing_host = _FakeSystemHost(status_succeeds=False)
        mock_create_runtime_session.return_value = _FakeSession(failing_host)
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_status",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {"dry_run": False},
            }
        )
        failed = json.loads(handle_request(payload))
        self.assertEqual(failed["status"], "error")

        healthy_host = _FakeSystemHost()
        mock_create_runtime_session.return_value = _FakeSession(
            healthy_host,
            disconnect_error="disconnect warning",
        )
        succeeded = json.loads(handle_request(payload))
        self.assertEqual(succeeded["status"], "success")

    def test_system_operations_cover_preflight_validation_and_open_failures(self):
        """Early exits must remain deterministic before any remote mutation occurs."""
        ctx = unittest.mock.Mock()
        ctx.error_result.side_effect = lambda code, msg, **kwargs: {
            "status": "error",
            "code": code,
            "msg": msg,
            **kwargs,
        }

        cancelled_status = system_settings_module.run_server_system_status_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
            is_cancelled=lambda: True,
        )
        cancelled_apply = system_settings_module.run_server_system_apply_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
            is_cancelled=lambda: True,
        )
        self.assertEqual(cancelled_status["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(cancelled_apply["code"], "ENGINE_TASK_CANCELLED")

        invalid_apply = system_settings_module.run_server_system_apply_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
            settings={"root_login_mode": "invalid"},
        )
        self.assertEqual(invalid_apply["code"], "ENGINE_VALIDATION_ERROR")

        connection_error = {"status": "error", "code": "ENGINE_RUNTIME_ERROR"}
        ctx.open_runtime_session.return_value = {
            "ok": False,
            "error": connection_error,
        }
        open_status = system_settings_module.run_server_system_status_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
        )
        open_apply = system_settings_module.run_server_system_apply_operation(
            ctx,
            "203.0.113.44",
            "ubuntu",
            settings={"root_login_mode": "disabled"},
        )
        self.assertIs(open_status, connection_error)
        self.assertIs(open_apply, connection_error)

    def test_system_apply_dry_run_returns_the_lossless_mode(self):
        """Dry-run review must expose the same root policy the real apply will use."""
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_apply",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {"root_login_mode": "key_only"},
                },
            }
        )

        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["settings"]["root_login_mode"], "key_only")

    @patch("engine.create_runtime_session")
    def test_system_apply_stops_when_original_settings_cannot_be_read(
        self,
        mock_create_runtime_session,
    ):
        """Apply must not mutate a server when its rollback baseline is unknown."""
        host = _FakeSystemHost(status_succeeds=False)
        mock_create_runtime_session.return_value = _FakeSession(host)
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_apply",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {"root_login_mode": "disabled"},
                },
            }
        )

        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["stage"], "execute_runtime_operation")

    @patch("engine.create_runtime_session")
    def test_system_status_reports_each_root_login_mode(self, mock_create_runtime_session):
        """Effective sshd values must survive the status boundary without boolean loss."""
        expected_modes = {
            "no": "disabled",
            "prohibit-password": "key_only",
            "without-password": "key_only",
            "yes": "password_allowed",
            "forced-commands-only": "restricted",
        }

        for raw_value, expected_mode in expected_modes.items():
            with self.subTest(raw_value=raw_value):
                host = _FakeSystemHost(root_login_raw=raw_value)
                mock_create_runtime_session.return_value = _FakeSession(host)
                payload = json.dumps(
                    {
                        "action": "run_workflow",
                        "workflow_id": "server",
                        "operation_id": "system_status",
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
                self.assertEqual(result["settings"]["root_login_mode"], expected_mode)

    @patch("engine.create_runtime_session")
    def test_system_apply_updates_port_and_returns_connection_update(
        self,
        mock_create_runtime_session,
    ):
        host = _FakeSystemHost(authorized_keys_present=True)
        opened_ports = []

        def _session_factory(host_name, connector_data, emit_event):
            del host_name, emit_event
            opened_ports.append(connector_data.get("ssh_port"))
            return _FakeSession(host)

        mock_create_runtime_session.side_effect = _session_factory
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_apply",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "root_login_enabled": False,
                        "password_auth_enabled": True,
                        "ssh_port": 2022,
                        "timezone": "UTC",
                        "swap_gb": 2,
                        "auto_reboot_enabled": True,
                        "maintenance_time": "01:00",
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "system_apply")
        self.assertEqual(result.get("connection_update", {}).get("port"), 2022)
        self.assertEqual(opened_ports, [22, 2022])
        sshd_commands = [
            command
            for command, _timeout, _sudo in host.commands
            if "update_sshd_option()" in command
        ]
        self.assertEqual(len(sshd_commands), 1)
        self.assertIn("/etc/ssh/sshd_config.d/00-deploydash.conf", sshd_commands[0])
        self.assertIn(
            "verify_sshd_option PasswordAuthentication yes",
            sshd_commands[0],
        )
        self.assertIn(
            "verify_sshd_option KbdInteractiveAuthentication no",
            sshd_commands[0],
        )
        command_blob = "\n".join(command for command, *_ in host.commands)
        self.assertIn("iptables -w -S DEPLOYDASH-INPUT", command_blob)
        self.assertIn("--dport 2022", command_blob)
        self.assertIn("systemctl restart ssh.socket", command_blob)
        self.assertIn("-D DEPLOYDASH-INPUT", command_blob)
        self.assertIn("--dport 22", command_blob)
        self.assertLess(
            command_blob.index("--dport 2022"),
            command_blob.index("systemctl restart ssh.socket"),
        )
        self.assertLess(
            command_blob.index("echo deploydash-system-verify"),
            command_blob.index("-D DEPLOYDASH-INPUT"),
        )
        backup_commands = [
            command for command, _timeout, _sudo in host.commands if "BACKUP_DIR=" in command
        ]
        self.assertIn("00-deploydash.conf.absent", backup_commands[0])

    @patch("orchestrator.infra_parts.system_settings.engine_firewall_ops._stage_ssh_port_firewall")
    @patch("engine.create_runtime_session")
    def test_system_apply_stops_before_mutation_when_firewall_stage_fails(
        self,
        mock_create_runtime_session,
        mock_stage_firewall,
    ):
        """A target port is never configured when its temporary allow cannot stage."""
        host = _FakeSystemHost()
        mock_create_runtime_session.return_value = _FakeSession(host)
        mock_stage_firewall.return_value = {
            "status": "error",
            "code": "ENGINE_RUNTIME_ERROR",
            "msg": "firewall stage failed",
        }

        result = json.loads(
            handle_request(
                json.dumps(
                    {
                        "action": "run_workflow",
                        "workflow_id": "server",
                        "operation_id": "system_apply",
                        "connection": {
                            "ip": "203.0.113.44",
                            "port": 22,
                            "username": "ubuntu",
                            "password": "secret",
                        },
                        "params": {
                            "settings": {
                                "root_login_mode": "disabled",
                                "password_auth_enabled": True,
                                "ssh_port": 2022,
                            }
                        },
                    }
                )
            )
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "firewall stage failed")
        self.assertFalse(any("BACKUP_DIR=" in command for command, *_ in host.commands))

    @patch("orchestrator.infra_parts.system_settings.engine_firewall_ops._commit_ssh_port_firewall")
    @patch("orchestrator.infra_parts.system_settings.engine_firewall_ops._stage_ssh_port_firewall")
    @patch("engine.create_runtime_session")
    def test_system_apply_restores_settings_when_firewall_commit_fails(
        self,
        mock_create_runtime_session,
        mock_stage_firewall,
        mock_commit_firewall,
    ):
        """A failed old-port removal restores SSH before reporting the apply failed."""
        host = _FakeSystemHost()
        mock_create_runtime_session.return_value = _FakeSession(host)
        mock_stage_firewall.return_value = {
            "status": "success",
            "managed": True,
            "stage_token": "ssh-port-test",
        }
        mock_commit_firewall.return_value = {
            "status": "error",
            "msg": "old port cleanup failed",
        }

        result = json.loads(
            handle_request(
                json.dumps(
                    {
                        "action": "run_workflow",
                        "workflow_id": "server",
                        "operation_id": "system_apply",
                        "connection": {
                            "ip": "203.0.113.44",
                            "port": 22,
                            "username": "ubuntu",
                            "password": "secret",
                        },
                        "params": {
                            "settings": {
                                "root_login_mode": "disabled",
                                "password_auth_enabled": True,
                                "ssh_port": 2022,
                            }
                        },
                    }
                )
            )
        )

        self.assertEqual(result["status"], "error")
        self.assertTrue(result["rollback_performed"])
        self.assertIn("finalizing its firewall rules failed", result["msg"])
        self.assertTrue(any("RESTORE_DIR=" in command for command, *_ in host.commands))

    @patch("engine.create_runtime_session")
    def test_system_apply_preserves_legacy_key_only_root_login(
        self,
        mock_create_runtime_session,
    ):
        """An unchanged legacy true value must preserve key-only access, never widen it."""
        host = _FakeSystemHost(root_login_raw="prohibit-password")
        mock_create_runtime_session.return_value = _FakeSession(host)
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_apply",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "root_login_enabled": True,
                        "password_auth_enabled": True,
                        "ssh_port": 22,
                        "timezone": "UTC",
                        "swap_gb": 2,
                        "auto_reboot_enabled": False,
                        "maintenance_time": "03:00",
                    },
                },
            }
        )

        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        sshd_command = next(
            command
            for command, _timeout, _sudo in host.commands
            if "update_sshd_option()" in command
        )
        self.assertIn("verify_sshd_option PermitRootLogin prohibit-password", sshd_command)
        self.assertNotIn("PermitRootLogin yes", sshd_command)

    @patch("engine.create_runtime_session")
    def test_system_apply_writes_yes_only_for_explicit_password_mode(
        self,
        mock_create_runtime_session,
    ):
        """Password root login requires the new explicit mode rather than a lossy bool."""
        host = _FakeSystemHost(root_login_raw="no")
        mock_create_runtime_session.return_value = _FakeSession(host)
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_apply",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "root_login_mode": "password_allowed",
                        "root_login_enabled": True,
                        "password_auth_enabled": True,
                        "ssh_port": 22,
                        "timezone": "UTC",
                        "swap_gb": 2,
                        "auto_reboot_enabled": False,
                        "maintenance_time": "03:00",
                    },
                },
            }
        )

        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        sshd_command = next(
            command
            for command, _timeout, _sudo in host.commands
            if "update_sshd_option()" in command
        )
        self.assertIn("verify_sshd_option PermitRootLogin yes", sshd_command)

    @patch("engine.create_runtime_session")
    def test_system_apply_rollback_restores_the_exact_sshd_backup(
        self,
        mock_create_runtime_session,
    ):
        """A verification failure must restore files instead of re-rendering a boolean."""
        host = _FakeSystemHost(
            root_login_raw="prohibit-password",
            verify_succeeds=False,
        )
        mock_create_runtime_session.return_value = _FakeSession(host)
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_apply",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "root_login_mode": "key_only",
                        "root_login_enabled": True,
                        "password_auth_enabled": True,
                        "ssh_port": 22,
                        "timezone": "UTC",
                        "swap_gb": 4,
                        "auto_reboot_enabled": False,
                        "maintenance_time": "03:00",
                    },
                },
            }
        )

        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertTrue(result["rollback_performed"])
        restore_commands = [
            command for command, _timeout, _sudo in host.commands if "RESTORE_DIR=" in command
        ]
        self.assertEqual(len(restore_commands), 1)
        self.assertIn("00-deploydash.conf.absent", restore_commands[0])
        self.assertNotIn("PermitRootLogin yes", "\n".join(command for command, *_ in host.commands))

    @patch("engine.create_runtime_session")
    def test_system_apply_rolls_back_each_failed_apply_stage(
        self,
        mock_create_runtime_session,
    ):
        """Every apply-stage failure must enter the backup-backed rollback path."""
        failure_markers = (
            ("BACKUP_DIR=", 1),
            ("update_sshd_option()", 1),
            ("timedatectl set-timezone", 1),
            ("swapoff /swapfile", 1),
            ("unattended-upgrades apt-listchanges", 1),
            ("/etc/apt/apt.conf.d/20auto-upgrades", 2),
            ("/etc/apt/apt.conf.d/52unattended-upgrades-local", 2),
            ("systemctl restart ssh || systemctl restart sshd", 1),
        )

        for marker, occurrence in failure_markers:
            with self.subTest(marker=marker):
                host = _FakeSystemHost(
                    fail_command_contains=marker,
                    fail_on_match=occurrence,
                )
                mock_create_runtime_session.return_value = _FakeSession(host)
                payload = json.dumps(
                    {
                        "action": "run_workflow",
                        "workflow_id": "server",
                        "operation_id": "system_apply",
                        "connection": {
                            "ip": "203.0.113.44",
                            "port": 22,
                            "username": "ubuntu",
                            "password": "secret",
                        },
                        "params": {
                            "dry_run": False,
                            "settings": {
                                "root_login_mode": "disabled",
                                "password_auth_enabled": True,
                                "ssh_port": 22,
                                "timezone": "UTC",
                                "swap_gb": 4 if marker == "swapoff /swapfile" else 2,
                                "auto_reboot_enabled": False,
                                "maintenance_time": "03:00",
                            },
                        },
                    }
                )

                result = json.loads(handle_request(payload))

                self.assertEqual(result["status"], "error")
                self.assertEqual(result["stage"], "execute_runtime_operation")
                self.assertEqual(
                    result["rollback_performed"],
                    marker not in {"BACKUP_DIR=", "unattended-upgrades apt-listchanges"},
                )

    @patch("engine.create_runtime_session")
    def test_system_apply_reports_each_backup_restore_failure(
        self,
        mock_create_runtime_session,
    ):
        """Rollback success is false when file, timezone, or swap restoration fails."""
        rollback_failures = (
            ("RESTORE_DIR=", 1),
            ("timedatectl set-timezone", 2),
            ("swapoff /swapfile", 2),
        )

        for marker, occurrence in rollback_failures:
            with self.subTest(marker=marker):
                host = _FakeSystemHost(
                    verify_succeeds=False,
                    fail_command_contains=marker,
                    fail_on_match=occurrence,
                )
                mock_create_runtime_session.return_value = _FakeSession(host)
                payload = json.dumps(
                    {
                        "action": "run_workflow",
                        "workflow_id": "server",
                        "operation_id": "system_apply",
                        "connection": {
                            "ip": "203.0.113.44",
                            "port": 22,
                            "username": "ubuntu",
                            "password": "secret",
                        },
                        "params": {
                            "dry_run": False,
                            "settings": {
                                "root_login_mode": "key_only",
                                "password_auth_enabled": True,
                                "ssh_port": 22,
                                "timezone": "UTC",
                                "swap_gb": 4,
                                "auto_reboot_enabled": False,
                                "maintenance_time": "03:00",
                            },
                        },
                    }
                )

                result = json.loads(handle_request(payload))

                self.assertEqual(result["status"], "error")
                self.assertFalse(result["rollback_performed"])

    @patch("engine.create_runtime_session")
    def test_system_apply_rolls_back_when_verification_session_cannot_open(
        self,
        mock_create_runtime_session,
    ):
        """A failed connection on the new port must restore the captured backup."""
        host = _FakeSystemHost()
        session_count = 0

        def _session_factory(host_name, connector_data, emit_event):
            """Fail only the verification connection so the apply itself completes."""
            del host_name, connector_data, emit_event
            nonlocal session_count
            session_count += 1
            if session_count == 2:
                raise RuntimeError("verification connection failed")
            return _FakeSession(host)

        mock_create_runtime_session.side_effect = _session_factory
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_apply",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "root_login_mode": "key_only",
                        "password_auth_enabled": True,
                        "ssh_port": 2022,
                    },
                },
            }
        )

        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["stage"], "verify_runtime_operation")
        self.assertTrue(result["rollback_performed"])

    @patch("engine.create_runtime_session")
    def test_system_apply_keeps_success_when_both_sessions_warn_on_disconnect(
        self,
        mock_create_runtime_session,
    ):
        """Cleanup warnings must not overwrite an already verified apply result."""
        host = _FakeSystemHost()
        sessions = iter(
            (
                _FakeSession(host, disconnect_error="main disconnect warning"),
                _FakeSession(host, disconnect_error="verify disconnect warning"),
            )
        )
        mock_create_runtime_session.side_effect = lambda **_kwargs: next(sessions)
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_apply",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "root_login_mode": "disabled",
                        "password_auth_enabled": True,
                        "ssh_port": 22,
                    },
                },
            }
        )

        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")

    @patch("engine.create_runtime_session")
    def test_system_apply_rejects_lockout_without_authorized_key(
        self,
        mock_create_runtime_session,
    ):
        host = _FakeSystemHost(authorized_keys_present=False)
        mock_create_runtime_session.return_value = _FakeSession(host)
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "system_apply",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "root_login_enabled": False,
                        "password_auth_enabled": False,
                        "ssh_port": 22,
                        "timezone": "UTC",
                        "swap_gb": 2,
                        "auto_reboot_enabled": False,
                        "maintenance_time": "03:00",
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("Refusing to disable", result["msg"])


if __name__ == "__main__":
    unittest.main()
