import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from pyinfra.operations import server

from orchestrator import server_paths, settings_ownership
from orchestrator.setup_parts import part1_system_foundation
from orchestrator.setup_parts.part1_system_foundation import build_steps
from orchestrator.setup_parts.setup_config import CANONICAL_SETUP_SETTINGS, parse_setup_config


class _OperationMeta:
    def __init__(self, did_change=False):
        self.did_change = did_change


class _Runtime:
    def __init__(self):
        self.calls = []
        self._line_count = 0

    def ensure_apt_updated(self, *args, **kwargs):
        self.calls.append(("ensure_apt_updated", args, kwargs))
        return _OperationMeta(did_change=False)

    def add_operation(self, op, **kwargs):
        name = getattr(op, "__name__", str(op))
        self.calls.append((name, kwargs))
        if name == "line":
            self._line_count += 1
        if name == "line" and self._line_count <= 2:
            return _OperationMeta(did_change=True)
        return _OperationMeta(did_change=False)


class TestSetupPart1SystemFoundation(unittest.TestCase):
    def _config(self, **overrides):
        settings = settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS)
        settings.update(overrides)
        return parse_setup_config({"settings": settings})

    def test_build_steps_includes_hostname_when_present(self):
        config = self._config(hostname="srv.example.com")
        steps = build_steps(config)
        step_ids = [step.id for step in steps]
        self.assertIn("part1_step4_hostname_alignment", step_ids)

    def test_build_steps_omits_hostname_when_absent(self):
        config = self._config(hostname=None)
        steps = build_steps(config)
        step_ids = [step.id for step in steps]
        self.assertNotIn("part1_step4_hostname_alignment", step_ids)

    def test_register_step3_uses_service_restart_and_shell_validation(self):
        config = self._config(
            ssh_public_key="ssh-ed25519 AAAA test",
            disable_password_auth=True,
            disable_root_login=True,
        )
        steps = build_steps(config)
        ssh_step = next(step for step in steps if step.id == "part1_step3_ssh_hardening")
        runtime = _Runtime()
        ssh_step.register(runtime)

        op_names = [name for name, _kwargs in runtime.calls if name != "ensure_apt_updated"]
        self.assertIn("user_authorized_keys", op_names)
        self.assertIn("directory", op_names)
        self.assertIn("shell", op_names)  # sshd -t
        self.assertIn("service", op_names)  # ssh restart via server.service

        directory_calls = [kwargs for name, kwargs in runtime.calls if name == "directory"]
        shell_calls = [kwargs for name, kwargs in runtime.calls if name == "shell"]
        self.assertEqual(len(directory_calls), 1)
        self.assertEqual(directory_calls[0]["path"], "/run/sshd")
        self.assertEqual(directory_calls[0]["mode"], "755")
        self.assertEqual(len(shell_calls), 1)
        self.assertEqual(shell_calls[0]["commands"], ["sshd -t"])
        self.assertIs(directory_calls[0]["_if"], shell_calls[0]["_if"])

        service_calls = [kwargs for name, kwargs in runtime.calls if name == "service"]
        self.assertTrue(any(call.get("service") == "ssh" for call in service_calls))

        authorized_keys_calls = [
            kwargs for name, kwargs in runtime.calls if name == "user_authorized_keys"
        ]
        self.assertEqual(len(authorized_keys_calls), 1)
        self.assertFalse(authorized_keys_calls[0].get("delete_keys"))

    def test_register_step2_leaves_existing_ubuntu_access_untouched(self):
        config = parse_setup_config(
            {
                "username": "root",
                "settings": {
                    **settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS),
                    "ssh_public_key": "ssh-ed25519 AAAA test",
                },
            },
        )
        steps = build_steps(config)
        user_step = next(step for step in steps if step.id == "part1_step2_user_sanitization")
        runtime = _Runtime()
        user_step.register(runtime)

        shell_call = next(kwargs for name, kwargs in runtime.calls if name == "shell")
        command = shell_call["commands"][0]
        self.assertIn("BOOTSTRAP_USER=root", command)
        self.assertNotIn('find "${TARGET_HOME}/.ssh"', command)
        self.assertNotIn("/etc/skel/${shell_file}", command)
        self.assertIsNotNone(config.managed_user_password)

    def test_register_step2_grants_passwordless_sudo_with_validated_dropin(self):
        """Onboarding-created users get passwordless sudo via a validated drop-in.

        Every post-handoff step runs through `sudo -n`, which fails rather
        than prompting, so group-only sudo cannot work where onboarding
        creates the user. The drop-in has a fixed filename (no username
        interpolation into a sudoers path) and is validated with visudo
        before it is installed, since a malformed drop-in breaks all sudo.
        """
        config = parse_setup_config(
            {
                "username": "root",
                "settings": {
                    **settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS),
                    "ssh_public_key": "ssh-ed25519 AAAA test",
                },
            },
        )
        steps = build_steps(config)
        user_step = next(step for step in steps if step.id == "part1_step2_user_sanitization")
        runtime = _Runtime()
        user_step.register(runtime)

        shell_call = next(kwargs for name, kwargs in runtime.calls if name == "shell")
        command = shell_call["commands"][0]
        self.assertIn("ALL=(ALL) NOPASSWD:ALL", command)
        self.assertIn('"$ADMIN_USER" > "$SUDOERS_TMP"', command)
        # Routed through the owner: server_paths_test pins the literal, so
        # this assertion proves the step reads it rather than retyping it.
        self.assertIn(server_paths.SUDOERS_MANAGED_DROPIN_FILE, command)
        self.assertIn("visudo -c", command)
        self.assertIn("0440", command)
        self.assertLess(command.index("visudo -c"), command.index("install -m 0440"))

    def test_register_step2_reads_the_sudoers_path_from_its_owner(self):
        """The sudoers drop-in path lives in server_paths, not in the step.

        A managed path literal may appear in server_paths.py and nowhere
        else; the step interpolates the owned constant instead of retyping
        the path. Source-shape guard: behavior is unchanged, the literal
        moves.
        """
        source = pathlib.Path(part1_system_foundation.__file__).read_text(
            encoding="utf-8",
        )
        self.assertNotIn("/etc/sudoers.d/", source)
        self.assertIn("SUDOERS_MANAGED_DROPIN_FILE", source)

    def test_register_step3_adds_key_without_deleting_existing_keys(self):
        config = parse_setup_config(
            {
                "username": "root",
                "settings": {
                    **settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS),
                    "ssh_public_key": "ssh-ed25519 AAAA test",
                },
            },
        )
        steps = build_steps(config)
        ssh_step = next(step for step in steps if step.id == "part1_step3_ssh_hardening")
        runtime = _Runtime()
        ssh_step.register(runtime)

        authorized_keys_call = next(
            kwargs for name, kwargs in runtime.calls if name == "user_authorized_keys"
        )
        self.assertFalse(authorized_keys_call.get("delete_keys"))

    def test_plan_shows_additive_key_action_and_no_reset_action(self):
        config = self._config(ssh_public_key="ssh-ed25519 AAAA test")
        steps = build_steps(config)
        ssh_step = next(step for step in steps if step.id == "part1_step3_ssh_hardening")

        actions = ssh_step.actions
        install_action = next(
            action for action in actions if action.id == "part1_step3_action_authorize_admin_key"
        )
        self.assertEqual(install_action.label, "Deploy Dash adds 1 SSH key")

        user_step = next(step for step in steps if step.id == "part1_step2_user_sanitization")
        reset_actions = [
            action
            for action in user_step.actions
            if action.id == "part1_step2_action_reset_existing_user"
        ]
        self.assertEqual(reset_actions, [])

    def test_register_step3_skips_authorized_keys_when_public_key_missing(self):
        config = self._config(ssh_public_key=None)
        step = next(item for item in build_steps(config) if item.id == "part1_step3_ssh_hardening")
        runtime = _Runtime()
        step.register(runtime)

        op_names = [name for name, _kwargs in runtime.calls if name != "ensure_apt_updated"]
        self.assertNotIn("user_authorized_keys", op_names)
        self.assertIn("shell", op_names)
        self.assertIn("service", op_names)

    def test_register_step1_updates_and_upgrades_system(self):
        config = self._config()
        step = next(item for item in build_steps(config) if item.id == "part1_step1_system_update")
        runtime = _Runtime()
        step.register(runtime)

        self.assertEqual(runtime.calls[0][0], "ensure_apt_updated")
        self.assertEqual(runtime.calls[0][2]["cache_time"], 0)
        self.assertEqual(runtime.calls[1][0], "upgrade")

    def test_register_step4_sets_hostname_and_hosts_file(self):
        """Hostname alignment must use Ubuntu's conventional non-mail mapping."""
        config = self._config(hostname="srv.example.com")
        step = next(
            item for item in build_steps(config) if item.id == "part1_step4_hostname_alignment"
        )
        runtime = _Runtime()
        step.register(runtime)

        hostname_call = next(kwargs for name, kwargs in runtime.calls if name == "hostname")
        self.assertEqual(hostname_call["hostname"], "srv.example.com")
        shell_calls = [kwargs for name, kwargs in runtime.calls if name == "shell"]
        self.assertEqual(len(shell_calls), 1)
        command = shell_calls[0]["commands"][0]
        self.assertIn("127.0.1.1 srv.example.com srv", command)
        self.assertNotIn("127.0.0.1 srv.example.com mail", command)
        source = pathlib.Path(part1_system_foundation.__file__).read_text(encoding="utf-8")
        self.assertNotIn('hosts_path="/etc/hosts"', source)
        self.assertIn("server_paths.HOSTS_FILE", source)

    def test_hosts_alignment_replaces_old_names_and_collapses_managed_rows(self):
        """A rerun must leave one current mapping and remove only the legacy footprint."""
        command_builder = getattr(
            part1_system_foundation,
            "_hosts_alignment_command",
            None,
        )
        self.assertIsNotNone(command_builder, "hostname hosts-command owner is missing")

        with tempfile.TemporaryDirectory() as temp_dir:
            hosts_path = pathlib.Path(temp_dir) / "hosts"
            cloud_paths = {
                "cloud_config_path": pathlib.Path(temp_dir) / "missing-cloud.cfg",
                "cloud_config_dir": pathlib.Path(temp_dir) / "missing-cloud.cfg.d",
                "cloud_hosts_template_path": pathlib.Path(temp_dir) / "missing-hosts.tmpl",
            }
            hosts_path.write_text(
                "127.0.0.1 localhost\n"
                "127.0.0.1 srv.example.com mail\n"
                "127.0.0.1 operator.example.com mail\n"
                "127.0.0.1 keep.example.com app\n"
                "127.0.1.1 old.example.com old\n"
                "127.0.1.1 duplicate.example.com duplicate\n"
                "::1 localhost ip6-localhost\n",
                encoding="utf-8",
            )

            subprocess.run(
                [
                    "sh",
                    "-c",
                    command_builder("srv.example.com", hosts_path, **cloud_paths),
                ],
                check=True,
            )
            first = hosts_path.read_text(encoding="utf-8")
            self.assertEqual(first.count("127.0.1.1"), 1)
            self.assertIn("127.0.1.1 srv.example.com srv\n", first)
            self.assertNotIn("srv.example.com mail", first)
            self.assertIn("127.0.0.1 operator.example.com mail\n", first)
            self.assertIn("127.0.0.1 keep.example.com app\n", first)

            subprocess.run(
                [
                    "sh",
                    "-c",
                    command_builder("next.example.com", hosts_path, **cloud_paths),
                ],
                check=True,
            )
            second = hosts_path.read_text(encoding="utf-8")
            self.assertEqual(second.count("127.0.1.1"), 1)
            self.assertIn("127.0.1.1 next.example.com next\n", second)
            self.assertNotIn("srv.example.com", second)

            subprocess.run(
                [
                    "sh",
                    "-c",
                    command_builder("next.example.com", hosts_path, **cloud_paths),
                ],
                check=True,
            )
            self.assertEqual(hosts_path.read_text(encoding="utf-8"), second)

            subprocess.run(
                ["sh", "-c", command_builder("node", hosts_path, **cloud_paths)],
                check=True,
            )
            short = hosts_path.read_text(encoding="utf-8")
            self.assertIn("127.0.1.1 node\n", short)
            self.assertNotIn("127.0.1.1 node node", short)

    def test_hosts_alignment_updates_the_cloud_init_template_when_enabled(self):
        """Cloud-init ownership must receive the same mapping it restores at boot."""
        with tempfile.TemporaryDirectory() as temp_dir:
            root = pathlib.Path(temp_dir)
            hosts_path = root / "hosts"
            cloud_config = root / "cloud.cfg"
            cloud_config_dir = root / "cloud.cfg.d"
            cloud_template = root / "hosts.debian.tmpl"
            hosts_path.write_text("127.0.0.1 localhost\n", encoding="utf-8")
            cloud_config.write_text("manage_etc_hosts: false\n", encoding="utf-8")
            cloud_config_dir.mkdir()
            (cloud_config_dir / "99-hosts.cfg").write_text(
                "manage_etc_hosts: true\n",
                encoding="utf-8",
            )
            cloud_template.write_text(
                "127.0.0.1 localhost\n127.0.1.1 {{fqdn}} {{hostname}}\n",
                encoding="utf-8",
            )

            command = part1_system_foundation._hosts_alignment_command(
                "srv.example.com",
                hosts_path,
                cloud_config_path=cloud_config,
                cloud_config_dir=cloud_config_dir,
                cloud_hosts_template_path=cloud_template,
            )
            subprocess.run(["sh", "-c", command], check=True)

            self.assertIn(
                "127.0.1.1 srv.example.com srv\n",
                cloud_template.read_text(encoding="utf-8"),
            )

    def test_hosts_alignment_preserves_cloud_template_when_management_is_disabled(self):
        """A later cloud-init opt-out must leave its dormant template operator-owned."""
        with tempfile.TemporaryDirectory() as temp_dir:
            root = pathlib.Path(temp_dir)
            hosts_path = root / "hosts"
            cloud_config = root / "cloud.cfg"
            cloud_config_dir = root / "cloud.cfg.d"
            cloud_template = root / "hosts.debian.tmpl"
            hosts_path.write_text("127.0.0.1 localhost\n", encoding="utf-8")
            cloud_config.write_text("manage_etc_hosts: true\n", encoding="utf-8")
            cloud_config_dir.mkdir()
            (cloud_config_dir / "99-hosts.cfg").write_text(
                "manage_etc_hosts: false\n",
                encoding="utf-8",
            )
            original_template = "127.0.1.1 {{fqdn}} {{hostname}}\n"
            cloud_template.write_text(original_template, encoding="utf-8")

            command = part1_system_foundation._hosts_alignment_command(
                "srv.example.com",
                hosts_path,
                cloud_config_path=cloud_config,
                cloud_config_dir=cloud_config_dir,
                cloud_hosts_template_path=cloud_template,
            )
            subprocess.run(["sh", "-c", command], check=True)

            self.assertEqual(
                cloud_template.read_text(encoding="utf-8"),
                original_template,
            )

    def test_register_step5_enables_timesyncd_service(self):
        config = self._config(timezone="Europe/Amsterdam")
        steps = build_steps(config)
        step5 = next(step for step in steps if step.id == "part1_step5_time_sync")
        runtime = _Runtime()
        step5.register(runtime)

        timezone_calls = [kwargs for name, kwargs in runtime.calls if name == "timezone"]
        self.assertEqual(timezone_calls, [{"timezone": "Europe/Amsterdam"}])
        service_calls = [kwargs for name, kwargs in runtime.calls if name == "service"]
        self.assertTrue(
            any(
                call.get("service") == "systemd-timesyncd"
                and call.get("running") is True
                and call.get("enabled") is True
                for call in service_calls
            )
        )

    def test_pyinfra_timezone_quotes_hostile_config_value(self):
        """Pin the upgraded dependency's shell-argument safety boundary."""
        fake_host = Mock()
        fake_host.get_fact.side_effect = ["Europe/London", "/usr/bin/timedatectl"]

        with patch.object(server, "host", fake_host):
            commands = list(server.timezone.__wrapped__("UTC; touch /tmp/x"))

        self.assertEqual(
            [command.get_raw_value() for command in commands],
            ["timedatectl set-timezone 'UTC; touch /tmp/x'"],
        )


if __name__ == "__main__":
    unittest.main()
