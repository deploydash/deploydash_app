"""The wire may not carry server-owned infrastructure settings.

Written before the implementation (T-1.1.4, discipline D1 -- see the note in
the plan's Discovered work about this task's stated discipline).

`stack_root` is the first instance of a general problem: the desktop client
hardcoded the server's own managed root and sent it as a parameter. That
means the layout is defined in two codebases, and an old client can point a
new server at a stale path. Section 1.4 generalises this to every
server-owned key; these tests are the shape that generalisation must keep.

The important subtlety, and the reason these tests exist rather than relying
on the pre-existing unknown-key check: `_select_settings` merges the
canonical defaults into the client's settings *before* validation runs, so by
the time the existing check sees the dictionary, `stack_root` is always
present and indistinguishable from a default. The rejection therefore has to
happen against the raw client settings, and a test that only checked the
merged dictionary would pass against a completely broken implementation.
"""

import unittest

from orchestrator import settings_ownership
from orchestrator.app_parts.app_config import (
    AppConfigValidationError,
    parse_app_config,
)
from orchestrator.dns_parts.dns_config import (
    DnsConfigValidationError,
    parse_dns_config,
)
from orchestrator.http_parts.http_config import (
    HttpConfigValidationError,
    parse_http_config,
)
from orchestrator.postgres_parts.postgres_config import (
    PostgresConfigValidationError,
    parse_postgres_service_config,
)


class TestServerOwnedKeyRegistry(unittest.TestCase):
    def test_every_class_a_key_is_registered_as_server_owned(self):
        # T-1.4.4 generalises the stack_root special case (T-1.1.4) to every
        # class A (backend-owned) key.
        # host_port is deliberately excluded -- see T-1.4.1's Discovered work
        # entry: it has exactly one legal value already, rejecting it here
        # would make its own "must be 5432" validation permanently
        # unreachable and untestable rather than fixing the real defect
        # (deleting the key), which is out of this task's scope.
        for class_a_key in (
            "stack_root",
            "container_name",
            "caddy_image",
            "bind_image",
            "bind_service_name",
            "superuser_name",
            "apps_root",
            "railpack_build_helper",
            "railpack_env_file",
            "caddy_stack_root",
            "caddy_container_name",
            "caddy_apply_helper",
        ):
            with self.subTest(key=class_a_key):
                self.assertIn(class_a_key, settings_ownership.SERVER_OWNED_SETTING_KEYS)

    def test_a_user_intent_key_is_not_registered_as_server_owned(self):
        # Guards against the set being widened by accident into keys the user
        # is genuinely entitled to supply.
        for intent_key in ("project_slug", "primary_domain", "zone_name"):
            with self.subTest(key=intent_key):
                self.assertNotIn(intent_key, settings_ownership.SERVER_OWNED_SETTING_KEYS)

    def test_reject_server_owned_keys_is_a_no_op_for_non_dict_input(self):
        # Found while raising this module's coverage while touching it for
        # T-1.4.4: every existing call site always passes an actual dict, so
        # this defensive early return had never been exercised.
        self.assertIsNone(
            settings_ownership.reject_server_owned_keys(None, HttpConfigValidationError)
        )
        self.assertIsNone(
            settings_ownership.reject_server_owned_keys("not a dict", HttpConfigValidationError)
        )


class TestHttpRejectsServerOwnedKeys(unittest.TestCase):
    def test_sending_stack_root_is_rejected_rather_than_ignored(self):
        with self.assertRaises(HttpConfigValidationError) as caught:
            parse_http_config(
                {
                    "settings": {
                        "stack_root": "/opt/somewhere-else",
                        "default_hostname": "example.com",
                    }
                }
            )
        message = str(caught.exception)
        self.assertIn("stack_root", message)
        self.assertIn("server-owned", message)

    def test_the_resolved_root_is_used_when_the_client_sends_nothing(self):
        config = parse_http_config({"settings": {"server_address": "203.0.113.10"}})
        self.assertEqual(config.stack_root, "/opt/deploydash/stack/http")

    def test_a_stale_client_cannot_win_by_sending_the_correct_value(self):
        # Rejection is on the key, not the value. A client that happens to
        # send the right path is still a client that believes it owns the
        # layout, and the next release would silently disagree with it.
        # server_address is supplied so that the ONLY thing wrong with this
        # payload is the server-owned key. Without it the call raises for a
        # missing address instead, and the test would pass against an
        # implementation that does no rejection at all.
        with self.assertRaises(HttpConfigValidationError) as caught:
            parse_http_config(
                {
                    "settings": {
                        "stack_root": "/opt/deploydash/stack/http",
                        "server_address": "203.0.113.10",
                    }
                }
            )
        self.assertIn("server-owned", str(caught.exception))

    def test_sending_container_name_is_rejected_rather_than_ignored(self):
        with self.assertRaises(HttpConfigValidationError) as caught:
            parse_http_config(
                {
                    "settings": {
                        "container_name": "attacker-chosen",
                        "default_hostname": "example.com",
                    }
                }
            )
        message = str(caught.exception)
        self.assertIn("container_name", message)
        self.assertIn("server-owned", message)

    def test_sending_caddy_image_is_rejected_rather_than_ignored(self):
        with self.assertRaises(HttpConfigValidationError) as caught:
            parse_http_config(
                {
                    "settings": {
                        "caddy_image": "attacker/image:latest",
                        "default_hostname": "example.com",
                    }
                }
            )
        message = str(caught.exception)
        self.assertIn("caddy_image", message)
        self.assertIn("server-owned", message)

    def test_an_unknown_key_is_rejected(self):
        with self.assertRaises(HttpConfigValidationError):
            parse_http_config(
                {
                    "settings": {
                        "not_a_real_setting": "x",
                        "server_address": "203.0.113.10",
                    }
                }
            )


class TestDnsRejectsServerOwnedKeys(unittest.TestCase):
    def test_sending_stack_root_is_rejected_rather_than_ignored(self):
        with self.assertRaises(DnsConfigValidationError) as caught:
            parse_dns_config(
                {
                    "settings": {
                        "stack_root": "/opt/somewhere-else",
                        "zone_name": "example.com",
                        "nameserver_hostname": "ns1",
                    }
                }
            )
        self.assertIn("stack_root", str(caught.exception))
        self.assertIn("server-owned", str(caught.exception))

    def test_the_resolved_root_is_used_when_the_client_sends_nothing(self):
        config = parse_dns_config(
            {
                "settings": {
                    "zone_name": "example.com",
                    "nameserver_hostname": "ns1",
                }
            },
            connection_ip="203.0.113.10",
        )
        self.assertEqual(config.stack_root, "/opt/deploydash/stack/dns")

    def test_sending_container_name_is_rejected_rather_than_ignored(self):
        with self.assertRaises(DnsConfigValidationError) as caught:
            parse_dns_config(
                {
                    "settings": {
                        "container_name": "attacker-chosen",
                        "zone_name": "example.com",
                        "nameserver_hostname": "ns1",
                    }
                }
            )
        self.assertIn("container_name", str(caught.exception))
        self.assertIn("server-owned", str(caught.exception))

    def test_sending_bind_image_is_rejected_rather_than_ignored(self):
        with self.assertRaises(DnsConfigValidationError) as caught:
            parse_dns_config(
                {
                    "settings": {
                        "bind_image": "attacker/image:latest",
                        "zone_name": "example.com",
                        "nameserver_hostname": "ns1",
                    }
                }
            )
        self.assertIn("bind_image", str(caught.exception))
        self.assertIn("server-owned", str(caught.exception))

    def test_sending_bind_service_name_is_rejected_rather_than_ignored(self):
        with self.assertRaises(DnsConfigValidationError) as caught:
            parse_dns_config(
                {
                    "settings": {
                        "bind_service_name": "attacker-service",
                        "zone_name": "example.com",
                        "nameserver_hostname": "ns1",
                    }
                }
            )
        self.assertIn("bind_service_name", str(caught.exception))
        self.assertIn("server-owned", str(caught.exception))

    def test_an_unknown_key_is_rejected(self):
        with self.assertRaises(DnsConfigValidationError):
            parse_dns_config(
                {
                    "settings": {
                        "not_a_real_setting": "x",
                        "zone_name": "example.com",
                        "nameserver_hostname": "ns1",
                    }
                },
                connection_ip="203.0.113.10",
            )


class TestPostgresRejectsServerOwnedKeys(unittest.TestCase):
    def test_sending_stack_root_is_rejected_rather_than_ignored(self):
        with self.assertRaises(PostgresConfigValidationError) as caught:
            parse_postgres_service_config({"settings": {"stack_root": "/opt/somewhere-else"}})
        self.assertIn("stack_root", str(caught.exception))
        self.assertIn("server-owned", str(caught.exception))

    def test_the_resolved_root_is_used_when_the_client_sends_nothing(self):
        config = parse_postgres_service_config({"settings": {}})
        self.assertEqual(config.stack_root, "/opt/deploydash/stack/postgres")

    def test_sending_container_name_is_rejected_rather_than_ignored(self):
        with self.assertRaises(PostgresConfigValidationError) as caught:
            parse_postgres_service_config({"settings": {"container_name": "attacker-chosen"}})
        self.assertIn("container_name", str(caught.exception))
        self.assertIn("server-owned", str(caught.exception))

    def test_sending_superuser_name_is_rejected_rather_than_ignored(self):
        with self.assertRaises(PostgresConfigValidationError) as caught:
            parse_postgres_service_config({"settings": {"superuser_name": "attacker"}})
        self.assertIn("superuser_name", str(caught.exception))
        self.assertIn("server-owned", str(caught.exception))

    def test_an_unknown_key_is_rejected(self):
        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config({"settings": {"not_a_real_setting": "x"}})


class TestAppRejectsServerOwnedKeys(unittest.TestCase):
    def test_sending_apps_root_is_rejected_rather_than_ignored(self):
        with self.assertRaises(AppConfigValidationError) as caught:
            parse_app_config(
                {"settings": {"apps_root": "/opt/somewhere-else"}},
                require_domain=False,
            )
        self.assertIn("apps_root", str(caught.exception))
        self.assertIn("server-owned", str(caught.exception))

    def test_sending_railpack_build_helper_is_rejected_rather_than_ignored(self):
        with self.assertRaises(AppConfigValidationError) as caught:
            parse_app_config(
                {"settings": {"railpack_build_helper": "/tmp/evil"}},
                require_domain=False,
            )
        self.assertIn("railpack_build_helper", str(caught.exception))
        self.assertIn("server-owned", str(caught.exception))

    def test_sending_railpack_env_file_is_rejected_rather_than_ignored(self):
        with self.assertRaises(AppConfigValidationError) as caught:
            parse_app_config(
                {"settings": {"railpack_env_file": "/tmp/evil.env"}},
                require_domain=False,
            )
        self.assertIn("railpack_env_file", str(caught.exception))
        self.assertIn("server-owned", str(caught.exception))

    def test_sending_caddy_stack_root_is_rejected_rather_than_ignored(self):
        with self.assertRaises(AppConfigValidationError) as caught:
            parse_app_config(
                {"settings": {"caddy_stack_root": "/opt/somewhere-else"}},
                require_domain=False,
            )
        self.assertIn("caddy_stack_root", str(caught.exception))
        self.assertIn("server-owned", str(caught.exception))

    def test_sending_caddy_container_name_is_rejected_rather_than_ignored(self):
        with self.assertRaises(AppConfigValidationError) as caught:
            parse_app_config(
                {"settings": {"caddy_container_name": "attacker"}},
                require_domain=False,
            )
        self.assertIn("caddy_container_name", str(caught.exception))
        self.assertIn("server-owned", str(caught.exception))

    def test_sending_caddy_apply_helper_is_rejected_rather_than_ignored(self):
        with self.assertRaises(AppConfigValidationError) as caught:
            parse_app_config(
                {"settings": {"caddy_apply_helper": "/tmp/evil"}},
                require_domain=False,
            )
        self.assertIn("caddy_apply_helper", str(caught.exception))
        self.assertIn("server-owned", str(caught.exception))

    def test_the_resolved_roots_are_used_when_the_client_sends_nothing(self):
        config = parse_app_config({"settings": {}}, require_domain=False)
        self.assertEqual(config.apps_root, "/opt/deploydash/stack/apps")
        self.assertEqual(config.caddy_stack_root, "/opt/deploydash/stack/http")

    def test_an_unknown_key_is_rejected(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {"settings": {"not_a_real_setting": "x"}},
                require_domain=False,
            )


class TestResolvedConfigSnapshot(unittest.TestCase):
    def test_reads_only_the_named_resolved_keys_off_the_config(self):
        config = parse_http_config(
            {"settings": {"default_hostname": "edge.example.com"}},
            connection_ip="203.0.113.10",
        )
        snapshot = settings_ownership.resolved_config_snapshot(
            config, ("stack_root", "container_name", "caddy_image")
        )
        self.assertEqual(
            snapshot,
            {
                "stack_root": "/opt/deploydash/stack/http",
                "container_name": "deploydash_caddy",
                "caddy_image": "caddy:2.11.2-alpine",
            },
        )
        # Intent values the caller supplied are not part of the snapshot,
        # even though they are attributes of the same config object.
        self.assertNotIn("default_hostname", snapshot)

    def test_works_for_any_config_object_not_just_http(self):
        config = parse_postgres_service_config({"settings": {}})
        snapshot = settings_ownership.resolved_config_snapshot(
            config, ("container_name", "superuser_name")
        )
        self.assertEqual(
            snapshot,
            {"container_name": "deploydash_postgres", "superuser_name": "deploydash"},
        )


if __name__ == "__main__":
    unittest.main()
