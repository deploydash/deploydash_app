import socket
import unittest
from unittest.mock import patch

from orchestrator.http_parts.http_config import (
    CANONICAL_HTTP_SETTINGS,
    HttpConfigValidationError,
    parse_http_config,
)
from orchestrator.settings_ownership import wire_defaults


class TestHttpConfig(unittest.TestCase):
    def test_parse_uses_canonical_settings(self):
        config = parse_http_config({}, connection_ip="203.0.113.10")

        self.assertEqual(config.stack_root, CANONICAL_HTTP_SETTINGS["stack_root"])
        self.assertEqual(
            config.container_name,
            CANONICAL_HTTP_SETTINGS["container_name"],
        )
        self.assertEqual(config.caddy_image, CANONICAL_HTTP_SETTINGS["caddy_image"])
        self.assertEqual(
            config.default_hostname,
            CANONICAL_HTTP_SETTINGS["default_hostname"],
        )
        self.assertEqual(config.server_ip, "203.0.113.10")
        self.assertEqual(
            config.default_page_title,
            CANONICAL_HTTP_SETTINGS["default_page_title"],
        )
        self.assertEqual(
            config.default_page_message,
            CANONICAL_HTTP_SETTINGS["default_page_message"],
        )
        self.assertEqual(
            config.serve_ip_over_https,
            CANONICAL_HTTP_SETTINGS["serve_ip_over_https"],
        )
        self.assertEqual(
            config.enable_https_redirect,
            CANONICAL_HTTP_SETTINGS["enable_https_redirect"],
        )
        self.assertEqual(
            config.enable_response_compression,
            CANONICAL_HTTP_SETTINGS["enable_response_compression"],
        )
        self.assertEqual(
            config.enable_access_logs,
            CANONICAL_HTTP_SETTINGS["enable_access_logs"],
        )
        self.assertEqual(
            config.enable_on_demand_tls,
            CANONICAL_HTTP_SETTINGS["enable_on_demand_tls"],
        )
        self.assertEqual(
            config.on_demand_tls_ask_endpoint,
            CANONICAL_HTTP_SETTINGS["on_demand_tls_ask_endpoint"],
        )
        self.assertEqual(
            config.enable_dns_plugin_cloudflare,
            CANONICAL_HTTP_SETTINGS["enable_dns_plugin_cloudflare"],
        )
        self.assertEqual(
            config.enable_dns_plugin_porkbun,
            CANONICAL_HTTP_SETTINGS["enable_dns_plugin_porkbun"],
        )
        self.assertEqual(
            config.enable_dns_plugin_namecheap,
            CANONICAL_HTTP_SETTINGS["enable_dns_plugin_namecheap"],
        )
        self.assertEqual(
            config.enable_dns_plugin_cloudns,
            CANONICAL_HTTP_SETTINGS["enable_dns_plugin_cloudns"],
        )
        self.assertEqual(
            config.enable_dns_plugin_easydns,
            CANONICAL_HTTP_SETTINGS["enable_dns_plugin_easydns"],
        )

    def test_parse_rejects_partial_settings(self):
        # Uses default_hostname rather than stack_root: since T-1.1.4 a
        # stack_root here raises for being server-owned, which would make
        # this test pass without ever exercising the partial-settings path.
        with self.assertRaises(HttpConfigValidationError):
            parse_http_config({"settings": {"default_hostname": "edge.example.com"}})

    def test_parse_rejects_invalid_hostname(self):
        settings = wire_defaults(CANONICAL_HTTP_SETTINGS)
        settings["default_hostname"] = "not a hostname"

        with self.assertRaises(HttpConfigValidationError):
            parse_http_config({"settings": settings}, connection_ip="203.0.113.10")

    def test_parse_accepts_complete_settings(self):
        settings = wire_defaults(CANONICAL_HTTP_SETTINGS)
        settings.update(
            {
                "default_hostname": "edge.example.com",
                "server_address": "198.51.100.8",
                "default_page_title": "Edge Gateway Ready",
                "default_page_message": "Gateway online.",
                "serve_ip_over_https": False,
            },
        )

        config = parse_http_config({"settings": settings})

        # stack_root/container_name/caddy_image are server-owned (T-1.1.4,
        # T-1.4.4): the caller cannot move them, so they resolve from
        # server_paths/platform_versions regardless of what else the
        # settings carry.
        self.assertEqual(config.stack_root, "/opt/deploydash/stack/http")
        self.assertEqual(config.container_name, "deploydash_caddy")
        self.assertEqual(config.default_hostname, "edge.example.com")
        self.assertEqual(config.server_ip, "198.51.100.8")
        self.assertFalse(config.serve_ip_over_https)
        self.assertFalse(config.enable_on_demand_tls)
        self.assertIsNone(config.on_demand_tls_ask_endpoint)
        self.assertFalse(config.enable_dns_plugin_cloudflare)

    @patch("orchestrator.http_parts.http_config.socket.getaddrinfo")
    def test_parse_resolves_hostname_server_ip(self, mock_getaddrinfo):
        mock_getaddrinfo.return_value = [
            (
                socket.AF_INET,
                socket.SOCK_STREAM,
                6,
                "",
                ("198.51.100.8", 0),
            )
        ]

        settings = wire_defaults(CANONICAL_HTTP_SETTINGS)
        settings["server_address"] = "server.example.com"

        config = parse_http_config({"settings": settings})

        self.assertEqual(config.server_ip, "198.51.100.8")

    def test_parse_accepts_legacy_server_ip_key(self):
        settings = wire_defaults(CANONICAL_HTTP_SETTINGS)
        settings["server_ip"] = "198.51.100.8"

        config = parse_http_config({"settings": settings})

        self.assertEqual(config.server_address, "198.51.100.8")

    @patch("orchestrator.http_parts.http_config.socket.getaddrinfo")
    def test_parse_resolves_hostname_connection_ip(self, mock_getaddrinfo):
        mock_getaddrinfo.return_value = [
            (
                socket.AF_INET,
                socket.SOCK_STREAM,
                6,
                "",
                ("203.0.113.10", 0),
            )
        ]

        config = parse_http_config({}, connection_ip="server.example.com")

        self.assertEqual(config.server_ip, "203.0.113.10")

    def test_parse_on_demand_tls_requires_ask_endpoint(self):
        settings = wire_defaults(CANONICAL_HTTP_SETTINGS)
        settings["enable_on_demand_tls"] = True
        settings["on_demand_tls_ask_endpoint"] = None

        with self.assertRaises(HttpConfigValidationError):
            parse_http_config({"settings": settings}, connection_ip="203.0.113.10")

    def test_parse_on_demand_tls_accepts_valid_ask_endpoint(self):
        settings = wire_defaults(CANONICAL_HTTP_SETTINGS)
        settings["enable_on_demand_tls"] = True
        settings["on_demand_tls_ask_endpoint"] = "http://127.0.0.1:9123/ask"

        config = parse_http_config({"settings": settings}, connection_ip="203.0.113.10")

        self.assertTrue(config.enable_on_demand_tls)
        self.assertEqual(
            config.on_demand_tls_ask_endpoint,
            "http://127.0.0.1:9123/ask",
        )

    def test_parse_accepts_optional_dns_plugin_flags(self):
        settings = wire_defaults(CANONICAL_HTTP_SETTINGS)
        settings["enable_dns_plugin_cloudflare"] = True
        settings["enable_dns_plugin_porkbun"] = True

        config = parse_http_config({"settings": settings}, connection_ip="203.0.113.10")

        self.assertTrue(config.enable_dns_plugin_cloudflare)
        self.assertTrue(config.enable_dns_plugin_porkbun)
        self.assertFalse(config.enable_dns_plugin_namecheap)

    def test_parse_rejects_removed_dnsimple_plugin_flag(self):
        settings = wire_defaults(CANONICAL_HTTP_SETTINGS)
        settings["enable_dns_plugin_dnsimple"] = True

        with self.assertRaises(HttpConfigValidationError):
            parse_http_config({"settings": settings}, connection_ip="203.0.113.10")


if __name__ == "__main__":
    unittest.main()
