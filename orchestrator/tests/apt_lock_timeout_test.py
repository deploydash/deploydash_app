import importlib
import pathlib
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from pyinfra.operations import apt, files, server

from orchestrator import engine_firewall_ops
from orchestrator.infra_parts import system_settings, tooling
from orchestrator.pyinfra_runtime import PyinfraRuntimeSession
from orchestrator.setup_parts import part1_system_foundation, part3_docker_prep
from orchestrator.setup_parts.setup_config import parse_setup_config


class TestAptLockTimeoutOwner(unittest.TestCase):
    def test_host_apt_commands_cannot_bypass_shared_owner(self):
        """A source-wide guard keeps every host APT command behind one lock policy."""
        source_root = pathlib.Path(__file__).parents[1] / "src/orchestrator"
        exemptions = {
            pathlib.Path("apt_runtime.py"),
            pathlib.Path("postgres_supply_chain.py"),
        }
        violations = []

        for source_path in sorted(source_root.rglob("*.py")):
            relative_path = source_path.relative_to(source_root)
            if relative_path in exemptions:
                continue
            for line_number, line in enumerate(
                source_path.read_text(encoding="utf-8").splitlines(),
                start=1,
            ):
                if "apt-get" in line:
                    violations.append(f"{relative_path}:{line_number}: {line.strip()}")

        self.assertEqual(
            violations,
            [],
            "Host apt-get commands must be rendered by orchestrator.apt_runtime; "
            "postgres_supply_chain.py is exempt because it renders container builds.",
        )

    def test_shared_owner_builds_waiting_notice_and_bounded_apt_commands(self):
        """One owner must make every raw host apt invocation wait for dpkg."""
        owner_path = pathlib.Path(__file__).parents[1] / "src/orchestrator/apt_runtime.py"
        self.assertTrue(owner_path.is_file(), "shared APT lock policy owner is missing")
        apt_runtime = importlib.import_module("orchestrator.apt_runtime")

        notice = apt_runtime.apt_lock_notice_command()
        update = apt_runtime.apt_get_command("update -y")
        install = apt_runtime.apt_get_command("install -y example-package")

        self.assertIn("fuser /var/lib/dpkg/lock-frontend", notice)
        self.assertIn("Waiting for Ubuntu's package manager", notice)
        self.assertIn("apt-get -o DPkg::Lock::Timeout=300 update -y", update)
        self.assertIn(
            "apt-get -o DPkg::Lock::Timeout=300 install -y example-package",
            install,
        )

    def test_setup_preview_and_pinned_docker_install_use_the_shared_timeout(self):
        """Setup previews and the real pinned install must promise the same wait."""
        system_step = next(
            step
            for step in part1_system_foundation.build_steps(parse_setup_config({}))
            if step.id == "part1_step1_system_update"
        )
        apt_commands = [command for command in system_step.commands if "apt-get" in command]

        self.assertEqual(len(apt_commands), 2)
        self.assertTrue(
            all("-o DPkg::Lock::Timeout=300" in command for command in apt_commands),
        )
        self.assertIn(
            "apt-get -o DPkg::Lock::Timeout=300 install",
            part3_docker_prep._docker_pinned_install_command(),
        )

    def test_pyinfra_installs_timeout_policy_before_its_first_update(self):
        """Pyinfra package operations need the managed drop-in before apt runs."""
        session = PyinfraRuntimeSession(
            state=None,
            host_name="server",
            emit_event=None,
            log_handler=Mock(),
        )
        session._active_step = SimpleNamespace(id="step", part="part1", title="Step")
        operations = []

        def record_operation(operation, **kwargs):
            """Capture registration order without contacting a real server."""
            operations.append((operation, kwargs))
            return SimpleNamespace(did_change=False)

        session.add_operation = record_operation

        session.ensure_apt_updated(cache_time=123)

        self.assertEqual(
            [operation for operation, _ in operations], [server.shell, files.put, apt.update]
        )
        self.assertIn("fuser /var/lib/dpkg/lock-frontend", operations[0][1]["commands"][0])
        self.assertEqual(
            operations[1][1]["dest"],
            "/etc/apt/apt.conf.d/50deploydash-lock-timeout",
        )
        self.assertEqual(
            operations[1][1]["src"].getvalue(),
            'DPkg::Lock::Timeout "300";\n',
        )
        self.assertEqual(operations[1][1]["mode"], "644")
        self.assertEqual(operations[2][1]["cache_time"], 123)

    def test_firewall_bootstrap_waits_for_dpkg_before_installing_tools(self):
        """Firewall staging must not fail merely because unattended APT holds dpkg."""
        captured_commands = []

        def run_step(_ctx, _host, _emit, _operation, label, command, *, timeout):
            """Stop after capturing the package step so no firewall state is modeled."""
            captured_commands.append((label, command, timeout))
            return (label != "Install firewall persistence tools", "injected stop")

        ctx = Mock()
        ctx.error_result.side_effect = lambda code, msg, **kwargs: {
            "status": "error",
            "code": code,
            "msg": msg,
            **kwargs,
        }
        with (
            patch.object(
                engine_firewall_ops,
                "_read_stage_state",
                return_value={"pending": False},
            ),
            patch.object(
                engine_firewall_ops,
                "_detect_external_interface",
                return_value="eth0",
            ),
            patch.object(engine_firewall_ops, "_run_step", side_effect=run_step),
        ):
            engine_firewall_ops._apply_staged_firewall(
                ctx,
                Mock(),
                engine_firewall_ops._parse_firewall_settings(
                    {"settings": {"rollback_timeout_seconds": 300}},
                ),
            )

        install_step = next(
            step for step in captured_commands if step[0] == "Install firewall persistence tools"
        )
        install_command = install_step[1]
        self.assertGreater(install_step[2], 300)
        self.assertIn("apt-get -o DPkg::Lock::Timeout=300 update -y", install_command)
        self.assertIn(
            "apt-get -o DPkg::Lock::Timeout=300 install -y",
            install_command,
        )
        self.assertIn("Waiting for Ubuntu's package manager", install_command)

    def test_system_settings_resolves_packages_before_backing_up_or_mutating(self):
        """A dpkg wait or package failure must precede every reversible setting change."""
        shell_commands = []

        def run_shell_command(_host, command, **_kwargs):
            """Return the backup path while recording the exact mutation order."""
            shell_commands.append(command)
            stdout_lines = []
            if "BACKUP_DIR=" in command:
                stdout_lines = ["backup_dir=/tmp/deploydash-system-backup-1"]
            return {
                "ok": True,
                "output": SimpleNamespace(stdout_lines=stdout_lines, stderr_lines=[]),
                "details": None,
            }

        settings = {
            "root_login_mode": "disabled",
            "password_auth_enabled": True,
            "ssh_port": 22,
            "timezone": "UTC",
            "swap_gb": 2,
            "automatic_security_updates_enabled": True,
            "auto_reboot_enabled": False,
            "maintenance_time": "03:00",
        }
        with (
            patch.object(system_settings, "run_shell_command", side_effect=run_shell_command),
            patch.object(
                system_settings,
                "write_remote_text_file",
                return_value={"ok": True, "details": None},
            ),
        ):
            result = system_settings._run_server_system_apply_commands(
                Mock(),
                SimpleNamespace(host=Mock()),
                settings,
                settings,
            )

        self.assertTrue(result["ok"])
        package_index = next(
            index
            for index, command in enumerate(shell_commands)
            if "unattended-upgrades" in command and "apt-get" in command
        )
        backup_index = next(
            index for index, command in enumerate(shell_commands) if "BACKUP_DIR=" in command
        )
        ssh_index = next(
            index
            for index, command in enumerate(shell_commands)
            if "update_sshd_option()" in command
        )
        self.assertLess(package_index, backup_index)
        self.assertLess(package_index, ssh_index)
        package_command = shell_commands[package_index]
        self.assertIn("dpkg -s unattended-upgrades apt-listchanges", package_command)
        self.assertIn("apt-get -o DPkg::Lock::Timeout=300 update -y", package_command)
        self.assertIn("apt-get -o DPkg::Lock::Timeout=300 install -y", package_command)

    def test_docker_runtime_rollback_waits_for_dpkg(self):
        """Rollback must use the same bounded package-manager wait as installation."""
        command = tooling._managed_rollback_command(
            "docker_runtime",
            {
                "package_versions": {
                    "docker-ce": "1",
                    "docker-ce-cli": "1",
                    "containerd.io": "1",
                    "docker-compose-plugin": "1",
                },
            },
        )

        self.assertIn("Waiting for Ubuntu's package manager", command)
        self.assertIn(
            "apt-get -o DPkg::Lock::Timeout=300 install -y",
            command,
        )


if __name__ == "__main__":
    unittest.main()
