import unittest

from orchestrator import settings_ownership
from orchestrator.setup_parts.setup_config import (
    CANONICAL_SETUP_SETTINGS,
    SetupConfigValidationError,
    parse_setup_config,
)


class TestSetupConfig(unittest.TestCase):
    def test_parse_uses_canonical_settings_when_missing(self):
        config = parse_setup_config({})

        self.assertEqual(config.admin_user, CANONICAL_SETUP_SETTINGS["admin_user"])
        self.assertEqual(config.hostname, CANONICAL_SETUP_SETTINGS["hostname"])
        self.assertEqual(config.timezone, CANONICAL_SETUP_SETTINGS["timezone"])
        self.assertEqual(
            config.ssh_public_key,
            CANONICAL_SETUP_SETTINGS["ssh_public_key"],
        )
        self.assertEqual(
            config.disable_password_auth,
            CANONICAL_SETUP_SETTINGS["disable_password_auth"],
        )
        self.assertEqual(
            config.disable_root_login,
            CANONICAL_SETUP_SETTINGS["disable_root_login"],
        )
        self.assertEqual(
            config.ssh_banner_text,
            CANONICAL_SETUP_SETTINGS["ssh_banner_text"],
        )
        self.assertEqual(config.bootstrap_username, None)
        self.assertEqual(config.managed_user_password, None)

    def test_parse_rejects_partial_settings(self):
        # admin_user is server-owned (T-1.4.8) and optional here for that
        # reason, so a key that is still genuinely required is needed to
        # prove incomplete settings are rejected.
        with self.assertRaises(SetupConfigValidationError):
            parse_setup_config(
                {
                    "settings": {
                        "hostname": "server.example.com",
                    },
                },
            )

    def test_parse_rejects_lockdown_without_public_key(self):
        settings = settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS)
        settings["disable_password_auth"] = True
        settings["disable_root_login"] = True
        settings["ssh_public_key"] = None

        with self.assertRaises(SetupConfigValidationError):
            parse_setup_config(
                {
                    "connection": {
                        "host": "203.0.113.10",
                        "username": "root",
                        "password": "secret",
                        "port": 22,
                    },
                    "settings": settings,
                },
            )

    def test_parse_rejects_a_request_that_would_leave_root_login_enabled(self):
        # Owner decision, 2026-09-04 (G-3). Before this, a client sending
        # false completed onboarding with root SSH still open, having already
        # run the destructive account takeover, and nothing told the user.
        settings = settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS)
        settings["ssh_public_key"] = "ssh-ed25519 AAAA test"
        settings["disable_root_login"] = False

        with self.assertRaises(SetupConfigValidationError) as raised:
            parse_setup_config(
                {
                    "connection": {"username": "root"},
                    "settings": settings,
                },
            )

        self.assertIn("disable_root_login", str(raised.exception))

    def test_password_authentication_stays_the_callers_choice(self):
        # The other half of the same decision, and the reason it is not simply
        # "reject anything unhardened": a server whose owner still needs a
        # console password is a supported shape, as long as the door root
        # comes through is shut.
        settings = settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS)
        settings["ssh_public_key"] = "ssh-ed25519 AAAA test"
        settings["disable_root_login"] = True
        settings["disable_password_auth"] = False

        config = parse_setup_config(
            {
                "connection": {"username": "root"},
                "settings": settings,
            },
        )

        self.assertFalse(config.disable_password_auth)
        self.assertTrue(config.disable_root_login)

    def test_a_describe_payload_is_not_held_to_the_hardening_rule(self):
        # `describe` carries no connection and configures nothing, so it has
        # no root login to leave enabled. Rejecting it would break the
        # operation that renders the setup form.
        settings = settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS)
        settings["disable_root_login"] = False

        config = parse_setup_config({"settings": settings})

        self.assertFalse(config.disable_root_login)

    def test_parse_accepts_complete_settings(self):
        settings = dict(CANONICAL_SETUP_SETTINGS)
        del settings["admin_user"]
        settings.update(
            {
                "hostname": "server.example.com",
                "timezone": "Asia/Kolkata",
                "ssh_public_key": "ssh-ed25519 AAAATESTEXAMPLE",
                "disable_password_auth": True,
                "disable_root_login": True,
                "ssh_banner_text": "Authorized uses only.",
            }
        )

        config = parse_setup_config({"settings": settings})

        # admin_user is server-owned (T-1.4.8): the caller cannot move it,
        # so it resolves to the canonical default regardless of what else
        # the settings carry.
        self.assertEqual(config.admin_user, CANONICAL_SETUP_SETTINGS["admin_user"])
        self.assertEqual(config.hostname, "server.example.com")
        self.assertTrue(config.disable_password_auth)
        self.assertTrue(config.disable_root_login)

    def test_parse_generates_managed_password_for_bootstrap_user_takeover(self):
        config = parse_setup_config(
            {
                "username": "root",
                "params": {
                    "managed_connection": {
                        "username": "ubuntu",
                        "key_path": "/tmp/key",
                    },
                },
                "settings": {
                    **settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS),
                    "ssh_public_key": "ssh-ed25519 AAAA test",
                },
            },
        )

        self.assertEqual(config.bootstrap_username, "root")
        self.assertIsNotNone(config.managed_user_password)

    def test_parse_requires_key_when_managed_connection_requests_hardening(self):
        with self.assertRaises(SetupConfigValidationError):
            parse_setup_config(
                {
                    "params": {
                        "managed_connection": {
                            "username": "ubuntu",
                            "key_path": "/tmp/key",
                        },
                    },
                    "settings": {
                        **settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS),
                        "ssh_public_key": None,
                    },
                },
            )

    def test_parse_accepts_describe_only_payload_without_hardening_key(self):
        config = parse_setup_config(
            {
                "settings": {
                    **settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS),
                    "ssh_public_key": None,
                },
            },
        )

        self.assertEqual(config.ssh_public_key, None)

    def test_parse_defaults_for_non_dict_payload(self):
        config = parse_setup_config(None)
        self.assertEqual(config.admin_user, "ubuntu")

    def test_parse_rejects_non_object_settings(self):
        with self.assertRaises(SetupConfigValidationError):
            parse_setup_config({"settings": "invalid"})

    def test_parse_rejects_unknown_setting_keys(self):
        with self.assertRaises(SetupConfigValidationError):
            parse_setup_config(
                {
                    "settings": {
                        **settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS),
                        "unknown": True,
                    },
                },
            )

    def test_parse_rejects_invalid_string_and_bool_fields(self):
        # timezone rather than admin_user: since T-1.4.8 admin_user is
        # server-owned and raises for that reason before the empty-string
        # check is ever reached, so this would assert nothing about
        # invalid field shapes.
        with self.assertRaises(SetupConfigValidationError):
            parse_setup_config(
                {
                    "settings": {
                        **settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS),
                        "timezone": "",
                    },
                },
            )
        with self.assertRaises(SetupConfigValidationError):
            parse_setup_config(
                {
                    "settings": {
                        **settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS),
                        "hostname": 123,
                    },
                },
            )
        with self.assertRaises(SetupConfigValidationError):
            parse_setup_config(
                {
                    "settings": {
                        **settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS),
                        "disable_root_login": "yes",
                    },
                },
            )

    def test_parse_rejects_non_string_bootstrap_username(self):
        with self.assertRaises(SetupConfigValidationError):
            parse_setup_config(
                {
                    "connection": {
                        "username": 123,
                    },
                    "settings": {
                        **settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS),
                        "ssh_public_key": "ssh-ed25519 AAAA test",
                    },
                },
            )


if __name__ == "__main__":
    unittest.main()
