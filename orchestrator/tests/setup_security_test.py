import unittest

from orchestrator.setup_security import (
    build_managed_connection_result,
    build_onboarding_firewall_config,
    existing_admin_account_probe_command,
    parse_existing_admin_account,
    resolve_managed_connection,
    unknown_admin_account,
)


class TestSetupSecurity(unittest.TestCase):
    def test_resolve_managed_connection_returns_expected_payload(self):
        result = resolve_managed_connection(
            {
                "params": {
                    "managed_connection": {
                        "username": "ubuntu",
                        "private_key": "PRIVATE KEY",
                    },
                },
            },
            "203.0.113.10",
            22,
        )

        self.assertEqual(
            result,
            {
                "ip": "203.0.113.10",
                "username": "ubuntu",
                "password": None,
                "key_path": None,
                "private_key": "PRIVATE KEY",
                "port": 22,
            },
        )

    def test_resolve_managed_connection_uses_explicit_port(self):
        result = resolve_managed_connection(
            {
                "params": {
                    "managed_connection": {
                        "ssh_user": "ubuntu",
                        "private_key": "PRIVATE KEY",
                        "port": 2022,
                    },
                },
            },
            "203.0.113.10",
            22,
        )

        self.assertEqual(result["port"], 2022)

    def test_resolve_managed_connection_accepts_top_level_payload(self):
        result = resolve_managed_connection(
            {
                "managed_connection": {
                    "username": "ubuntu",
                    "private_key": "PRIVATE KEY",
                },
            },
            "203.0.113.10",
            22,
        )

        self.assertEqual(result["username"], "ubuntu")
        self.assertEqual(result["private_key"], "PRIVATE KEY")
        self.assertIsNone(result["key_path"])

    def test_resolve_managed_connection_accepts_managed_key_path(self):
        result = resolve_managed_connection(
            {
                "params": {
                    "managed_connection": {
                        "username": "ubuntu",
                        "key_path": "/tmp/deploydash-managed-id_ed25519",
                    },
                },
            },
            "203.0.113.10",
            22,
        )

        self.assertEqual(
            result,
            {
                "ip": "203.0.113.10",
                "username": "ubuntu",
                "password": None,
                "key_path": "/tmp/deploydash-managed-id_ed25519",
                "private_key": None,
                "port": 22,
            },
        )

    def test_resolve_managed_connection_rejects_incomplete_payloads(self):
        self.assertIsNone(resolve_managed_connection(None, "203.0.113.10", 22))
        self.assertIsNone(resolve_managed_connection({}, "203.0.113.10", 22))
        self.assertIsNone(
            resolve_managed_connection(
                {"params": {"managed_connection": "invalid"}},
                "203.0.113.10",
                22,
            ),
        )
        self.assertIsNone(
            resolve_managed_connection(
                {"params": {"managed_connection": {"username": "ubuntu"}}},
                "203.0.113.10",
                22,
            ),
        )

    def test_build_onboarding_firewall_config_locks_ssh_and_web_ports(self):
        config = build_onboarding_firewall_config(2222)

        self.assertEqual(
            config,
            {
                "strict_mode": True,
                "allow_postgres": False,
                "postgres_source_cidrs": [],
                "allow_dns": False,
                "allow_smtp": False,
                "allow_mail_receive": False,
                "rollback_timeout_seconds": 180,
                "locked_ports": [80, 443, 2222],
                "custom_rules": [],
                "stage_token": None,
            },
        )

    def test_onboarding_firewall_config_matches_runtime_settings_shape(self):
        """Pin the shared firewall-config shape across its two builders.

        The staged-apply path reads postgres_source_cidrs unconditionally;
        an onboarding config without that key fails every fresh setup with
        KeyError after an hour of provisioning. Any key added to the runtime
        parser must appear here too.
        """
        from orchestrator.engine_firewall_ops import _parse_firewall_settings

        runtime_keys = set(_parse_firewall_settings({}).keys())
        onboarding_keys = set(build_onboarding_firewall_config(22).keys())
        self.assertEqual(onboarding_keys, runtime_keys)

    def test_build_managed_connection_result_strips_to_public_fields(self):
        result = build_managed_connection_result(
            {
                "username": "ubuntu",
                "port": 2022,
                "key_path": "/tmp/key",
            },
        )

        self.assertEqual(result, {"username": "ubuntu", "port": 2022})


class TestExistingAdminAccountProbe(unittest.TestCase):
    """The read-only admin probe, now display infrastructure (I-9).

    Setup is additive-only, so nothing is gated on the answer anymore: the
    probe reports what access already exists so the review screen can show
    it. It runs before the user has consented to anything, so it must not
    be able to change the server.
    """

    def test_the_probe_asks_only_about_the_account_it_names(self):
        command = existing_admin_account_probe_command("ubuntu")

        self.assertIn("ADMIN_USER=ubuntu", command)
        self.assertIn("exists=", command)
        self.assertIn("authorized_key_count=", command)
        self.assertIn("authorized_key_fingerprints=", command)
        # Reads, never writes. This runs before the user has consented to
        # anything, so it must not be able to change the server.
        for destructive in ("rm ", "adduser", "usermod", "chpasswd", "chown"):
            self.assertNotIn(destructive, command)

    def test_the_probe_quotes_a_hostile_account_name(self):
        command = existing_admin_account_probe_command("ubuntu; rm -rf /")

        self.assertIn("'ubuntu; rm -rf /'", command)
        self.assertNotIn("ADMIN_USER=ubuntu; rm -rf /;", command)

    def test_parse_reports_key_count_and_fingerprints(self):
        account = parse_existing_admin_account(
            {
                "exists": "1",
                "authorized_key_count": "2",
                "has_home": "1",
                "authorized_key_fingerprints": "SHA256:aaa|SHA256:bbb",
            },
        )

        self.assertEqual(
            account,
            {
                "exists": True,
                "authorized_key_count": 2,
                "has_home": True,
                "authorized_key_fingerprints": ["SHA256:aaa", "SHA256:bbb"],
            },
        )

    def test_parse_reports_an_absent_account(self):
        # Nothing exists yet: the step creates the account instead.
        account = parse_existing_admin_account({"exists": "0"})

        self.assertEqual(
            account,
            {
                "exists": False,
                "authorized_key_count": 0,
                "has_home": False,
                "authorized_key_fingerprints": [],
            },
        )

    def test_parse_reports_an_account_with_no_keys(self):
        account = parse_existing_admin_account(
            {"exists": "1", "authorized_key_count": "0", "has_home": "1"},
        )

        self.assertEqual(account["authorized_key_count"], 0)
        self.assertEqual(account["authorized_key_fingerprints"], [])

    def test_parse_reports_an_unreadable_answer_as_unknown(self):
        # Not knowing is not the same as knowing there is nothing there.
        # Absent keys parse as a count of zero, so a truncated or garbled
        # answer must never read as "no keys" on the review screen.
        account = parse_existing_admin_account({"exists": "1", "unrelated": "x"})

        self.assertTrue(account["exists"])
        self.assertIsNone(account["authorized_key_count"])

    def test_parse_reports_a_non_mapping_as_unknown(self):
        # The probe has two ways to be unreadable -- the command failing, and
        # its answer not parsing -- and both must reach the same shape.
        for garbled in (None, "exists=1", [], 0):
            with self.subTest(garbled=garbled):
                account = parse_existing_admin_account(garbled)

                self.assertEqual(account, unknown_admin_account())


if __name__ == "__main__":
    unittest.main()
