import unittest
from types import SimpleNamespace
from unittest.mock import ANY, call, patch

from orchestrator import shell_output
from orchestrator.setup_postflight import (
    _is_retryable_verify_error,
    _verify_staged_connection_with_retries,
    apply_onboarding_firewall_baseline,
    apply_verified_onboarding_ssh_hardening,
    set_sshd_option_command,
    set_sshd_options_command,
    verify_runtime_session_connection,
)


class _FakeSession:
    def __init__(self):
        self.host = object()
        self.closed = False

    def close(self):
        self.closed = True
        return {"disconnect_error": None}


def _error_result(code, msg, **kwargs):
    return {"code": code, "msg": msg, **kwargs}


class TestSetupPostflight(unittest.TestCase):
    def test_verify_runtime_session_connection_success(self):
        session = _FakeSession()

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.return_value = {"ok": True, "details": None}
            result = verify_runtime_session_connection(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertEqual(result, {"ok": True})
        self.assertTrue(session.closed)
        run_mock.assert_called_once()

    def test_verify_runtime_session_connection_returns_open_error(self):
        result = verify_runtime_session_connection(
            {
                "ip": "203.0.113.10",
                "username": "ubuntu",
                "key_path": "/tmp/key",
                "port": 22,
            },
            open_runtime_session=lambda **_kwargs: {"ok": False, "error": {"msg": "nope"}},
            error_result=_error_result,
            emit_event=lambda *args, **kwargs: None,
            emit_shell_output_lines=lambda *args, **kwargs: None,
        )

        self.assertEqual(result, {"ok": False, "error": {"msg": "nope"}})

    def test_verify_runtime_session_connection_handles_shell_failure(self):
        session = _FakeSession()

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.return_value = {"ok": False, "details": "permission denied"}
            result = verify_runtime_session_connection(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["details"], "permission denied")

    def test_verify_runtime_session_connection_emits_disconnect_warning(self):
        class _DisconnectingSession(_FakeSession):
            def close(self):
                return {"disconnect_error": "disconnect failed"}

        events = []
        session = _DisconnectingSession()
        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.return_value = {"ok": True, "details": None}
            verify_runtime_session_connection(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: events.append(args[1]),
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertIn("connection_disconnect_error", events)

    def test_set_sshd_option_command(self):
        command = set_sshd_option_command("PermitRootLogin", "no")
        self.assertIn("PermitRootLogin", command)
        self.assertIn("/etc/ssh/sshd_config.d/00-deploydash.conf", command)
        self.assertIn("verify_sshd_option", command)
        self.assertIn("sshd -T", command)
        self.assertIn("systemctl restart ssh", command)

    def test_set_sshd_options_command_supports_batch_without_restart(self):
        command = set_sshd_options_command(
            (
                ("PasswordAuthentication", "no"),
                ("KbdInteractiveAuthentication", "no"),
                ("Port", "2022"),
            ),
            restart=False,
        )

        self.assertIn("update_sshd_option PasswordAuthentication no", command)
        self.assertIn("update_sshd_option KbdInteractiveAuthentication no", command)
        self.assertIn(
            "PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|Port",
            command,
        )
        self.assertIn("update_sshd_option Port 2022", command)
        self.assertIn(
            "sed -i -E '/^[[:space:]]*Port[[:space:]]+/d' \"$MAIN_FILE\"",
            command,
        )
        self.assertNotIn("systemctl restart", command)
        with self.assertRaisesRegex(ValueError, "At least one"):
            set_sshd_options_command(())

    def test_set_sshd_port_reloads_socket_activation_and_verifies_listener(self):
        """A port edit must move Ubuntu socket activation before reporting success."""
        command = set_sshd_option_command("Port", "2022")

        self.assertIn("systemctl is-active --quiet ssh.socket", command)
        self.assertIn("systemctl daemon-reload", command)
        self.assertIn("systemctl restart ssh.socket", command)
        self.assertIn("systemctl restart ssh.service", command)
        self.assertIn("ss -ltnH 'sport = :2022'", command)
        self.assertLess(
            command.index("systemctl restart ssh.socket"),
            command.index("ss -ltnH 'sport = :2022'"),
        )

    def test_onboarding_disables_both_password_authentication_methods_together(self):
        """The password-off choice must close direct and PAM password prompts."""
        session = _FakeSession()
        verify_calls = []

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.side_effect = [
                {
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=["backup_path=/opt/deploydash/state/sshd.bak"],
                    ),
                },
                {"ok": True, "details": None},
                {"ok": True, "details": None},
            ]
            result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=22,
                disable_root_login=False,
                disable_password_auth=True,
                verify_connection=lambda connection, emit=None: (
                    verify_calls.append(connection) or {"ok": True}
                ),
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertTrue(result["ok"])
        self.assertEqual(len(verify_calls), 1)
        hardening_command = run_mock.call_args_list[1].args[1]
        self.assertIn("update_sshd_option PasswordAuthentication no", hardening_command)
        self.assertIn("update_sshd_option KbdInteractiveAuthentication no", hardening_command)
        self.assertIn("verify_sshd_option PasswordAuthentication no", hardening_command)
        self.assertIn("verify_sshd_option KbdInteractiveAuthentication no", hardening_command)

    def test_apply_verified_onboarding_ssh_hardening_success(self):
        session = _FakeSession()
        verify_calls = []

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.side_effect = [
                {
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=["backup_path=/tmp/sshd.bak"],
                    ),
                },
                {"ok": True, "details": None},
                {"ok": True, "details": None},
                # The backup cleanup that runs once every step verified (G-2).
                {"ok": True, "details": None},
            ]
            result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=22,
                disable_root_login=True,
                disable_password_auth=True,
                verify_connection=lambda connection, emit=None: (
                    verify_calls.append(connection) or {"ok": True}
                ),
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertEqual(result, {"ok": True, "managed_port": 22})
        self.assertEqual(len(verify_calls), 2)
        self.assertEqual(run_mock.call_count, 4)
        backup_command = run_mock.call_args_list[0].args[1]
        self.assertIn("dropin_backup_path", backup_command)
        self.assertIn("dropin_present", backup_command)

    def test_apply_verified_onboarding_ssh_hardening_supports_port_change(self):
        session = _FakeSession()
        verify_calls = []

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.side_effect = [
                {
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=["backup_path=/tmp/sshd.bak"],
                    ),
                },
                {"ok": True, "details": None},
                # The backup cleanup that runs once every step verified (G-2).
                {"ok": True, "details": None},
            ]
            result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=2022,
                disable_root_login=False,
                disable_password_auth=False,
                verify_connection=lambda connection, emit=None: (
                    verify_calls.append(connection) or {"ok": True}
                ),
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertEqual(result, {"ok": True, "managed_port": 2022})
        self.assertEqual(verify_calls[0]["port"], 2022)

    def test_apply_verified_onboarding_ssh_hardening_rolls_back_on_verify_failure(
        self,
    ):
        session = _FakeSession()

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.side_effect = [
                {
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=["backup_path=/tmp/sshd.bak"],
                    ),
                },
                {"ok": True, "details": None},
                {"ok": True, "details": None},
            ]
            result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=22,
                disable_root_login=True,
                disable_password_auth=False,
                verify_connection=lambda connection, emit=None: {
                    "ok": False,
                    "error": {"msg": "verify failed"},
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertFalse(result["ok"])
        self.assertTrue(result["error"]["extra"]["rollback_performed"])
        self.assertEqual(run_mock.call_count, 3)
        rollback_command = run_mock.call_args_list[2].args[1]
        self.assertIn(
            "rm -f /etc/ssh/sshd_config.d/00-deploydash.conf",
            rollback_command,
        )

    def test_a_failed_rollback_is_not_reported_as_an_ordinary_setup_failure(self):
        # G-1. This is the outcome the entire onboarding sequence exists to
        # prevent: an option applied, the managed login unverified, and the
        # restore that was supposed to undo it also failed. It used to arrive
        # as ENGINE_RUNTIME_ERROR carrying `rollback_performed: False` -- the
        # same code as a failed package install, and the same shape the
        # desktop renders as an ordinary retryable error.
        session = _FakeSession()

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.side_effect = [
                {
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=[
                            "backup_path=/opt/deploydash/state/setup-sshd-backup/"
                            "deploydash-setup-sshd-1.bak",
                            "dropin_backup_path=/opt/deploydash/state/"
                            "setup-sshd-backup/deploydash-setup-sshd-1.bak"
                            ".deploydash-dropin",
                            "dropin_present=1",
                        ],
                    ),
                },
                {"ok": True, "details": None},
                {"ok": False, "details": "cp: read-only file system"},
            ]
            result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=22,
                disable_root_login=True,
                disable_password_auth=False,
                verify_connection=lambda connection, emit=None: {
                    "ok": False,
                    "error": {"msg": "verify failed"},
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertFalse(result["ok"])
        error = result["error"]
        self.assertEqual(error["code"], "ENGINE_SSH_HARDENING_ROLLBACK_FAILED")
        self.assertFalse(error["extra"]["rollback_performed"])
        # The operator recovering through a provider console has no shell
        # history to read the path out of, so the error has to carry it.
        self.assertEqual(
            error["extra"]["sshd_backup_path"],
            "/opt/deploydash/state/setup-sshd-backup/deploydash-setup-sshd-1.bak",
        )
        self.assertEqual(
            error["extra"]["sshd_dropin_backup_path"],
            "/opt/deploydash/state/setup-sshd-backup/deploydash-setup-sshd-1.bak.deploydash-dropin",
        )
        self.assertIn("/etc/ssh/sshd_config", error["extra"]["recovery_hint"])
        # No cleanup after a failed rollback: the backup is the only way back.
        self.assertEqual(run_mock.call_count, 3)

    def test_a_failed_rollback_reports_no_dropin_backup_when_there_was_none(self):
        # The restore removes the drop-in rather than restoring it in this
        # case, so naming a drop-in backup path would send the operator after
        # a file that was never written.
        session = _FakeSession()

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.side_effect = [
                {
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=[
                            "backup_path=/opt/deploydash/state/setup-sshd-backup/x.bak",
                            "dropin_backup_path=/opt/deploydash/state/"
                            "setup-sshd-backup/x.bak.deploydash-dropin",
                            "dropin_present=0",
                        ],
                    ),
                },
                {"ok": True, "details": None},
                {"ok": False, "details": "cp: read-only file system"},
            ]
            result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=22,
                disable_root_login=True,
                disable_password_auth=False,
                verify_connection=lambda connection, emit=None: {
                    "ok": False,
                    "error": {"msg": "verify failed"},
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertIsNone(result["error"]["extra"]["sshd_dropin_backup_path"])

    def test_the_sshd_backup_path_is_announced_and_survives_a_reboot(self):
        # G-2. The path used to exist only as a local variable in a process
        # that may be about to die, under a /tmp that a reboot clears. Both
        # halves matter: written somewhere durable, and said out loud.
        session = _FakeSession()
        events = []

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.side_effect = [
                {
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=[
                            "backup_path=/opt/deploydash/state/setup-sshd-backup/x.bak",
                        ],
                    ),
                },
                {"ok": True, "details": None},
                {"ok": True, "details": None},
            ]
            apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=22,
                disable_root_login=True,
                disable_password_auth=False,
                verify_connection=lambda connection, emit=None: {"ok": True},
                error_result=_error_result,
                emit_event=lambda _emit, name, message, **kwargs: events.append(
                    (name, message),
                ),
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        backup_command = run_mock.call_args_list[0].args[1]
        self.assertIn(
            "/opt/deploydash/state/setup-sshd-backup/deploydash-setup-sshd-",
            backup_command,
        )
        self.assertNotIn("/tmp/deploydash-setup-sshd-", backup_command)
        # The directory has to exist before cp writes into it, and it holds a
        # copy of sshd_config, so it is not world-readable.
        self.assertIn("mkdir -p", backup_command)
        self.assertIn("chmod 700", backup_command)
        self.assertIn(
            (
                "setup_sshd_backup_captured",
                "SSH daemon configuration backed up to "
                "/opt/deploydash/state/setup-sshd-backup/x.bak.",
            ),
            events,
        )

    def test_a_verified_hardening_removes_the_backup_it_no_longer_needs(self):
        # The other half of G-2: durable is not the same as forever. Once
        # every step has verified, the backup protects nothing and would
        # otherwise accumulate one file per onboarding under STATE_ROOT.
        session = _FakeSession()

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.side_effect = [
                {
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=[
                            "backup_path=/opt/deploydash/state/setup-sshd-backup/x.bak",
                            "dropin_backup_path=/opt/deploydash/state/"
                            "setup-sshd-backup/x.bak.deploydash-dropin",
                            "dropin_present=1",
                        ],
                    ),
                },
                {"ok": True, "details": None},
                {"ok": True, "details": None},
            ]
            result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=22,
                disable_root_login=True,
                disable_password_auth=False,
                verify_connection=lambda connection, emit=None: {"ok": True},
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertTrue(result["ok"])
        cleanup_command = run_mock.call_args_list[-1].args[1]
        self.assertEqual(
            cleanup_command,
            "rm -f /opt/deploydash/state/setup-sshd-backup/x.bak "
            "/opt/deploydash/state/setup-sshd-backup/x.bak.deploydash-dropin",
        )

    def test_a_failed_cleanup_does_not_fail_a_verified_hardening(self):
        # The hardening is complete and verified by this point. Reporting a
        # leftover file as a setup failure would send the user to retry an
        # operation that actually succeeded.
        session = _FakeSession()

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.side_effect = [
                {
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=["backup_path=/opt/deploydash/state/x.bak"],
                    ),
                },
                {"ok": True, "details": None},
                {"ok": False, "details": "rm: permission denied"},
            ]
            result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=22,
                disable_root_login=True,
                disable_password_auth=False,
                verify_connection=lambda connection, emit=None: {"ok": True},
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertEqual(result, {"ok": True, "managed_port": 22})

    def test_onboarding_hardening_restores_an_existing_dropin(self):
        session = _FakeSession()
        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.side_effect = [
                {
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=[
                            "backup_path=/tmp/sshd.bak",
                            "dropin_backup_path=/tmp/sshd.bak.deploydash-dropin",
                            "dropin_present=1",
                        ],
                    ),
                },
                {"ok": True, "details": None},
                {"ok": True, "details": None},
            ]
            result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=22,
                disable_root_login=True,
                disable_password_auth=False,
                verify_connection=lambda connection, emit=None: {
                    "ok": False,
                    "error": {"msg": "verify failed"},
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertFalse(result["ok"])
        rollback_command = run_mock.call_args_list[2].args[1]
        self.assertIn(
            "cp /tmp/sshd.bak.deploydash-dropin /etc/ssh/sshd_config.d/00-deploydash.conf",
            rollback_command,
        )

    def test_apply_verified_onboarding_ssh_hardening_handles_backup_and_apply_failures(
        self,
    ):
        session = _FakeSession()

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.return_value = {"ok": False, "details": "backup failed"}
            backup_result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=22,
                disable_root_login=True,
                disable_password_auth=False,
                verify_connection=lambda connection, emit=None: {"ok": True},
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertFalse(backup_result["ok"])
        self.assertEqual(backup_result["error"]["details"], "backup failed")

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.side_effect = [
                {
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=[
                            "backup_path=/tmp/sshd.bak",
                            "dropin_backup_path=/tmp/sshd.bak.deploydash-dropin",
                            "dropin_present=1",
                        ],
                    ),
                },
                {"ok": False, "details": "apply failed"},
                {"ok": True, "details": None},
            ]
            apply_result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=22,
                disable_root_login=True,
                disable_password_auth=False,
                verify_connection=lambda connection, emit=None: {"ok": True},
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertFalse(apply_result["ok"])
        self.assertEqual(apply_result["error"]["details"], "apply failed")
        self.assertTrue(apply_result["error"]["extra"]["rollback_performed"])
        self.assertEqual(run_mock.call_count, 3)
        rollback_command = run_mock.call_args_list[2].args[1]
        self.assertIn("cp /tmp/sshd.bak /etc/ssh/sshd_config", rollback_command)
        self.assertIn(
            "cp /tmp/sshd.bak.deploydash-dropin /etc/ssh/sshd_config.d/00-deploydash.conf",
            rollback_command,
        )

    def test_apply_failure_reports_when_automatic_sshd_restore_also_fails(self):
        """A failed apply and restore must expose the durable recovery path."""
        session = _FakeSession()

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.side_effect = [
                {
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=[
                            "backup_path=/opt/deploydash/state/setup-sshd-backup/x.bak",
                            "dropin_backup_path=/opt/deploydash/state/"
                            "setup-sshd-backup/x.bak.deploydash-dropin",
                            "dropin_present=0",
                        ],
                    ),
                },
                {"ok": False, "details": "sshd -t failed"},
                {"ok": False, "details": "restore failed"},
            ]

            result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=22,
                disable_root_login=True,
                disable_password_auth=False,
                verify_connection=lambda connection, emit=None: {"ok": True},
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertFalse(result["ok"])
        error = result["error"]
        self.assertEqual(error["code"], "ENGINE_SSH_HARDENING_ROLLBACK_FAILED")
        self.assertEqual(error["details"], "restore failed")
        self.assertFalse(error["extra"]["rollback_performed"])
        self.assertEqual(
            error["extra"]["sshd_backup_path"],
            "/opt/deploydash/state/setup-sshd-backup/x.bak",
        )
        self.assertIsNone(error["extra"]["sshd_dropin_backup_path"])

    def test_apply_exception_still_restores_the_sshd_backup(self):
        """A dropped bootstrap command must not bypass the only lockout recovery."""
        session = _FakeSession()

        with patch("orchestrator.setup_postflight.run_shell_command") as run_mock:
            run_mock.side_effect = [
                {
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=[
                            "backup_path=/tmp/sshd.bak",
                            "dropin_backup_path=/tmp/sshd.bak.deploydash-dropin",
                            "dropin_present=1",
                        ],
                    ),
                },
                RuntimeError("bootstrap session dropped"),
                {"ok": True, "details": None},
            ]

            result = apply_verified_onboarding_ssh_hardening(
                bootstrap_session=session,
                bootstrap_connection={"port": 22},
                managed_connection={"username": "ubuntu", "port": 22},
                target_port=22,
                disable_root_login=True,
                disable_password_auth=False,
                verify_connection=lambda connection, emit=None: {"ok": True},
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "ENGINE_RUNTIME_ERROR")
        self.assertTrue(result["error"]["extra"]["rollback_performed"])
        self.assertIn("did not return a result", result["error"]["details"])
        self.assertEqual(run_mock.call_count, 3)

    def test_apply_onboarding_firewall_baseline_success(self):
        stage_session = _FakeSession()
        commit_session = _FakeSession()
        sessions = iter((stage_session, commit_session))

        def verify_connection(_connection, emit=None):
            self.assertTrue(stage_session.closed)
            return {"ok": True}

        with (
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
            ) as apply_mock,
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._commit_staged_firewall",
            ) as commit_mock,
        ):
            apply_mock.return_value = {
                "status": "success",
                "staged_state": {"token": "abc"},
            }
            commit_mock.return_value = {"status": "success"}
            result = apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=verify_connection,
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": next(sessions),
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertEqual(result, {"ok": True})
        self.assertTrue(stage_session.closed)
        self.assertTrue(commit_session.closed)
        apply_mock.assert_called_once_with(
            ANY,
            stage_session.host,
            ANY,
            emit=None,
            active_ssh_port=22,
        )
        commit_mock.assert_called_once_with(ANY, commit_session.host, "abc", emit=None)

    def test_apply_onboarding_firewall_baseline_handles_open_stage_and_commit_failures(
        self,
    ):
        result = apply_onboarding_firewall_baseline(
            {
                "ip": "203.0.113.10",
                "username": "ubuntu",
                "key_path": "/tmp/key",
                "port": 22,
            },
            verify_connection=lambda connection, emit=None: {"ok": True},
            open_runtime_session=lambda **_kwargs: {"ok": False, "error": {"msg": "nope"}},
            error_result=_error_result,
            emit_event=lambda *args, **kwargs: None,
            emit_shell_output_lines=lambda *args, **kwargs: None,
        )
        self.assertEqual(result, {"ok": False, "error": {"msg": "nope"}})

        session = _FakeSession()
        with patch(
            "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
        ) as apply_mock:
            apply_mock.return_value = {"status": "error", "msg": "stage failed"}
            stage_result = apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=lambda connection, emit=None: {"ok": True},
                open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )
        self.assertFalse(stage_result["ok"])
        self.assertEqual(stage_result["error"]["msg"], "stage failed")

        stage_session = _FakeSession()
        commit_session = _FakeSession()
        sessions = iter((stage_session, commit_session))
        with (
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
            ) as apply_mock,
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._commit_staged_firewall",
            ) as commit_mock,
        ):
            apply_mock.return_value = {
                "status": "success",
                "staged_state": {"token": "abc"},
            }
            commit_mock.return_value = {"status": "error", "msg": "commit failed"}
            commit_result = apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=lambda connection, emit=None: {"ok": True},
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": next(sessions),
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )
        self.assertFalse(commit_result["ok"])
        self.assertEqual(commit_result["error"]["msg"], "commit failed")
        self.assertTrue(stage_session.closed)
        self.assertTrue(commit_session.closed)

        stage_session = _FakeSession()
        open_results = iter(
            (
                {"ok": True, "session": stage_session},
                {"ok": False, "error": {"msg": "commit connection failed"}},
            )
        )
        with patch(
            "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
        ) as apply_mock:
            apply_mock.return_value = {
                "status": "success",
                "staged_state": {"token": "abc"},
            }
            commit_open_result = apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=lambda connection, emit=None: {"ok": True},
                open_runtime_session=lambda **_kwargs: next(open_results),
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertEqual(
            commit_open_result,
            {"ok": False, "error": {"msg": "commit connection failed"}},
        )
        self.assertTrue(stage_session.closed)

    def test_apply_onboarding_firewall_baseline_rolls_back_on_verify_failure(self):
        stage_session = _FakeSession()
        rollback_session = _FakeSession()
        sessions = iter((stage_session, rollback_session))

        with (
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
            ) as apply_mock,
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._rollback_staged_firewall",
            ) as rollback_mock,
        ):
            apply_mock.return_value = {
                "status": "success",
                "staged_state": {"token": "abc"},
            }
            rollback_mock.return_value = {
                "status": "success",
                "firewall_state": "unprotected",
            }
            result = apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=lambda connection, emit=None: {
                    "ok": False,
                    "error": {"msg": "ssh broke"},
                },
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": next(sessions),
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertFalse(result["ok"])
        self.assertTrue(result["error"]["extra"]["rollback_performed"])
        self.assertEqual(result["error"]["extra"]["firewall_state"], "unprotected")
        self.assertIn("currently has no active firewall", result["error"]["msg"])
        self.assertTrue(stage_session.closed)
        self.assertTrue(rollback_session.closed)
        rollback_mock.assert_called_once_with(ANY, rollback_session.host, "abc", emit=None)

        stage_session = _FakeSession()
        open_results = iter(
            (
                {"ok": True, "session": stage_session},
                {"ok": False, "error": {"msg": "rollback connection failed"}},
            )
        )
        with patch(
            "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
        ) as apply_mock:
            apply_mock.return_value = {
                "status": "success",
                "staged_state": {"token": "abc"},
            }
            result = apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=lambda connection, emit=None: {
                    "ok": False,
                    "error": {"msg": "ssh broke"},
                },
                open_runtime_session=lambda **_kwargs: next(open_results),
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertFalse(result["error"]["extra"]["rollback_performed"])
        self.assertTrue(stage_session.closed)

    def test_apply_onboarding_firewall_baseline_emits_disconnect_warning_and_helper_parses(
        self,
    ):
        class _DisconnectingSession(_FakeSession):
            def close(self):
                return {"disconnect_error": "disconnect failed"}

        stage_session = _DisconnectingSession()
        commit_session = _FakeSession()
        sessions = iter((stage_session, commit_session))
        events = []
        with (
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
            ) as apply_mock,
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._commit_staged_firewall",
            ) as commit_mock,
        ):
            apply_mock.return_value = {
                "status": "success",
                "staged_state": {"token": "abc"},
            }
            commit_mock.return_value = {"status": "success"}
            result = apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=lambda connection, emit=None: {"ok": True},
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": next(sessions),
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: events.append(args[1]),
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertEqual(result, {"ok": True})
        self.assertIn("connection_disconnect_error", events)
        self.assertEqual(
            {"alpha": "1"},
            shell_output.parse_key_values(SimpleNamespace(stdout_lines=["alpha=1", "skip"])),
        )
        self.assertEqual({}, shell_output.parse_key_values(None))

    def test_apply_onboarding_firewall_baseline_passes_emit_to_commit_and_rollback(self):
        stage_session = _FakeSession()
        commit_session = _FakeSession()
        sessions = iter((stage_session, commit_session))
        with (
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
            ) as apply_mock,
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._commit_staged_firewall",
            ) as commit_mock,
        ):
            apply_mock.return_value = {
                "status": "success",
                "staged_state": {"token": "abc"},
            }
            commit_mock.return_value = {"status": "success"}
            apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=lambda connection, emit=None: {"ok": True},
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": next(sessions),
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
                emit="event-sink",
            )

        commit_mock.assert_called_once_with(
            ANY,
            commit_session.host,
            "abc",
            emit="event-sink",
        )

        stage_session = _FakeSession()
        rollback_session = _FakeSession()
        sessions = iter((stage_session, rollback_session))
        with (
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
            ) as apply_mock,
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._rollback_staged_firewall",
            ) as rollback_mock,
        ):
            apply_mock.return_value = {
                "status": "success",
                "staged_state": {"token": "abc"},
            }
            rollback_mock.return_value = {"status": "success"}
            apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=lambda connection, emit=None: {
                    "ok": False,
                    "error": {"msg": "ssh broke"},
                },
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": next(sessions),
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
                emit="event-sink",
            )

        rollback_mock.assert_called_once_with(
            ANY,
            rollback_session.host,
            "abc",
            emit="event-sink",
        )

    def test_firewall_verify_retries_transient_connection_failures(self):
        stage_session = _FakeSession()
        commit_session = _FakeSession()
        sessions = iter((stage_session, commit_session))
        verify_calls = []
        flaky = iter(
            (
                {
                    "ok": False,
                    "error": {"msg": "No hosts remaining", "stage": "connect"},
                },
                {
                    "ok": False,
                    "error": {"msg": "No hosts remaining", "stage": "connect"},
                },
                {
                    "ok": False,
                    "error": {"msg": "No hosts remaining", "stage": "connect"},
                },
                {
                    "ok": False,
                    "error": {"msg": "No hosts remaining", "stage": "connect"},
                },
                {
                    "ok": False,
                    "error": {"msg": "No hosts remaining", "stage": "connect"},
                },
                {"ok": True},
            )
        )

        def verify_connection(_connection, emit=None):
            verify_calls.append(1)
            return next(flaky)

        with (
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
            ) as apply_mock,
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._commit_staged_firewall",
            ) as commit_mock,
            patch("orchestrator.setup_postflight.time.sleep") as sleep_mock,
        ):
            apply_mock.return_value = {
                "status": "success",
                "staged_state": {"token": "abc"},
            }
            commit_mock.return_value = {"status": "success"}
            result = apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=verify_connection,
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": next(sessions),
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertEqual(result, {"ok": True})
        self.assertEqual(len(verify_calls), 6)
        sleep_mock.assert_has_calls([call(5.0), call(10.0), call(15.0), call(20.0), call(25.0)])
        commit_mock.assert_called_once()

    def test_firewall_verify_does_not_retry_command_failures(self):
        stage_session = _FakeSession()
        rollback_session = _FakeSession()
        sessions = iter((stage_session, rollback_session))
        verify_calls = []

        def verify_connection(_connection, emit=None):
            verify_calls.append(1)
            return {
                "ok": False,
                "error": {
                    "msg": "Managed SSH verification command failed.",
                    "stage": "verify_runtime_operation",
                },
            }

        with (
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
            ) as apply_mock,
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._rollback_staged_firewall",
            ) as rollback_mock,
            patch("orchestrator.setup_postflight.time.sleep") as sleep_mock,
        ):
            apply_mock.return_value = {
                "status": "success",
                "staged_state": {"token": "abc"},
            }
            rollback_mock.return_value = {"status": "success"}
            result = apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=verify_connection,
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": next(sessions),
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertFalse(result["ok"])
        self.assertEqual(len(verify_calls), 1)
        sleep_mock.assert_not_called()
        self.assertTrue(result["error"]["extra"]["rollback_performed"])

    def test_firewall_verify_gives_up_after_retries_and_rolls_back(self):
        stage_session = _FakeSession()
        rollback_session = _FakeSession()
        sessions = iter((stage_session, rollback_session))
        verify_calls = []

        def verify_connection(_connection, emit=None):
            verify_calls.append(1)
            return {
                "ok": False,
                "error": {"msg": "No hosts remaining", "stage": "connect"},
            }

        with (
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
            ) as apply_mock,
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._rollback_staged_firewall",
            ) as rollback_mock,
            patch("orchestrator.setup_postflight.time.sleep") as sleep_mock,
        ):
            apply_mock.return_value = {
                "status": "success",
                "staged_state": {"token": "abc"},
            }
            rollback_mock.return_value = {"status": "success"}
            result = apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=verify_connection,
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": next(sessions),
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertFalse(result["ok"])
        self.assertEqual(len(verify_calls), 6)
        sleep_mock.assert_has_calls([call(5.0), call(10.0), call(15.0), call(20.0), call(25.0)])
        self.assertTrue(result["error"]["extra"]["rollback_performed"])

    def test_is_retryable_verify_error_truth_table(self):
        # Only connection-level failures deserve another attempt. A
        # non-dict error, a non-connect stage, and a host-key confirmation
        # are all definitive answers that must fall through to rollback
        # immediately; a connect-stage dict without the confirmation flag
        # (including an empty extra mapping) retries.
        self.assertFalse(_is_retryable_verify_error("boom"))
        self.assertFalse(_is_retryable_verify_error(None))
        self.assertFalse(_is_retryable_verify_error({"msg": "No hosts remaining"}))
        self.assertFalse(
            _is_retryable_verify_error(
                {"msg": "command failed", "stage": "verify_runtime_operation"}
            ),
        )
        self.assertFalse(
            _is_retryable_verify_error(
                {
                    "msg": "host key changed",
                    "stage": "connect",
                    "extra": {"host_key_confirmation_required": True},
                },
            ),
        )
        self.assertTrue(
            _is_retryable_verify_error({"msg": "No hosts remaining", "stage": "connect"})
        )
        self.assertTrue(
            _is_retryable_verify_error(
                {"msg": "No hosts remaining", "stage": "connect", "extra": {}}
            ),
        )

    def test_firewall_verify_does_not_retry_host_key_confirmation(self):
        stage_session = _FakeSession()
        rollback_session = _FakeSession()
        sessions = iter((stage_session, rollback_session))
        verify_calls = []

        def verify_connection(_connection, emit=None):
            verify_calls.append(1)
            return {
                "ok": False,
                "error": {
                    "msg": "host key changed",
                    "stage": "connect",
                    "extra": {"host_key_confirmation_required": True},
                },
            }

        with (
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
            ) as apply_mock,
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._rollback_staged_firewall",
            ) as rollback_mock,
            patch("orchestrator.setup_postflight.time.sleep") as sleep_mock,
        ):
            apply_mock.return_value = {
                "status": "success",
                "staged_state": {"token": "abc"},
            }
            rollback_mock.return_value = {"status": "success"}
            result = apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=verify_connection,
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": next(sessions),
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        # A host-key answer must not burn six attempts and 75 seconds of
        # backoff before rolling back.
        self.assertFalse(result["ok"])
        self.assertEqual(len(verify_calls), 1)
        sleep_mock.assert_not_called()
        self.assertTrue(result["error"]["extra"]["rollback_performed"])

    def test_firewall_verify_retries_connect_errors_carrying_an_empty_extra(self):
        stage_session = _FakeSession()
        commit_session = _FakeSession()
        sessions = iter((stage_session, commit_session))
        verify_calls = []
        flaky = iter(
            (
                {
                    "ok": False,
                    "error": {"msg": "No hosts remaining", "stage": "connect", "extra": {}},
                },
                {"ok": True},
            )
        )

        def verify_connection(_connection, emit=None):
            verify_calls.append(1)
            return next(flaky)

        with (
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._apply_staged_firewall",
            ) as apply_mock,
            patch(
                "orchestrator.setup_postflight.engine_firewall_ops._commit_staged_firewall",
            ) as commit_mock,
            patch("orchestrator.setup_postflight.time.sleep") as sleep_mock,
        ):
            apply_mock.return_value = {
                "status": "success",
                "staged_state": {"token": "abc"},
            }
            commit_mock.return_value = {"status": "success"}
            result = apply_onboarding_firewall_baseline(
                {
                    "ip": "203.0.113.10",
                    "username": "ubuntu",
                    "key_path": "/tmp/key",
                    "port": 22,
                },
                verify_connection=verify_connection,
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": next(sessions),
                },
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                emit_shell_output_lines=lambda *args, **kwargs: None,
            )

        self.assertEqual(result, {"ok": True})
        self.assertEqual(len(verify_calls), 2)
        sleep_mock.assert_called_once_with(5.0)
        commit_mock.assert_called_once()

    def test_firewall_verify_stops_when_cancelled_mid_retry(self):
        cancelled = iter((False, True))
        verify_calls = []

        def verify_connection(_connection, emit=None):
            verify_calls.append(1)
            return {
                "ok": False,
                "error": {"msg": "No hosts remaining", "stage": "connect"},
            }

        with patch("orchestrator.setup_postflight.time.sleep") as sleep_mock:
            result = _verify_staged_connection_with_retries(
                {"ip": "203.0.113.10"},
                verify_connection=verify_connection,
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: None,
                is_cancelled=lambda: next(cancelled),
            )

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(len(verify_calls), 1)
        sleep_mock.assert_called_once_with(5.0)


if __name__ == "__main__":
    unittest.main()
