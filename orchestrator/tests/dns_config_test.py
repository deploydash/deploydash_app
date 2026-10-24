import unittest

from orchestrator.dns_parts.dns_config import (
    CANONICAL_DNS_SETTINGS,
    DnsConfigValidationError,
    parse_dns_config,
)
from orchestrator.settings_ownership import wire_defaults


class TestDnsConfig(unittest.TestCase):
    def test_parse_uses_canonical_settings(self):
        config = parse_dns_config({}, connection_ip="203.0.113.10")

        self.assertEqual(config.stack_root, CANONICAL_DNS_SETTINGS["stack_root"])
        self.assertEqual(
            config.container_name,
            CANONICAL_DNS_SETTINGS["container_name"],
        )
        self.assertEqual(config.bind_image, CANONICAL_DNS_SETTINGS["bind_image"])
        self.assertEqual(
            config.bind_service_name,
            CANONICAL_DNS_SETTINGS["bind_service_name"],
        )
        self.assertEqual(config.zone_name, CANONICAL_DNS_SETTINGS["zone_name"])
        self.assertEqual(config.zone_count, 1)
        self.assertEqual(config.zone_names, ["example.com"])
        self.assertEqual(config.nameserver_fqdn, "ns1.example.com")
        self.assertEqual(config.nameserver_ipv4, "203.0.113.10")

    def test_parse_rejects_partial_settings(self):
        with self.assertRaises(DnsConfigValidationError):
            parse_dns_config({"settings": {"zone_name": "example.com"}})

    def test_parse_rejects_invalid_zone_name(self):
        settings = wire_defaults(CANONICAL_DNS_SETTINGS)
        settings["zone_name"] = "not a zone"

        with self.assertRaises(DnsConfigValidationError):
            parse_dns_config({"settings": settings}, connection_ip="203.0.113.10")

    def test_parse_rejects_non_authoritative_recursion(self):
        settings = wire_defaults(CANONICAL_DNS_SETTINGS)
        settings["allow_recursion"] = True

        with self.assertRaises(DnsConfigValidationError):
            parse_dns_config({"settings": settings}, connection_ip="203.0.113.10")

    def test_parse_rejects_forwarders_for_authoritative_mode(self):
        settings = wire_defaults(CANONICAL_DNS_SETTINGS)
        settings["forwarders"] = ["1.1.1.1"]

        with self.assertRaises(DnsConfigValidationError):
            parse_dns_config({"settings": settings}, connection_ip="203.0.113.10")

    def test_parse_accepts_multi_zone_settings(self):
        settings = wire_defaults(CANONICAL_DNS_SETTINGS)
        settings.update(
            {
                "zone_name": "legacy.example.net",
                "nameserver_hostname": "ns2",
                "nameserver_ipv4": "198.51.100.10",
                "default_a_ipv4": "198.51.100.20",
                "admin_email": "dns-admin@example.net",
                "zone_serial": 2026021101,
                "zone_ttl": 600,
                "zone_refresh": 7200,
                "zone_retry": 1200,
                "zone_expire": 1209600,
                "zone_negative_ttl": 600,
                "allow_recursion": False,
                "recursion_cidrs": ["127.0.0.1/32"],
                "forwarders": [],
                "listen_on_ipv6": True,
                "extra_a_records": [],
                "zones": [
                    {
                        "zone_name": "example.net",
                        "default_a_ipv4": "198.51.100.30",
                        "admin_email": "dns-admin@example.net",
                        "zone_serial": 2026021102,
                        "zone_ttl": 600,
                        "zone_refresh": 7200,
                        "zone_retry": 1200,
                        "zone_expire": 1209600,
                        "zone_negative_ttl": 600,
                        "extra_a_records": [
                            {"name": "www", "ip": "198.51.100.31"},
                            {"name": "*.apps", "ip": "198.51.100.32"},
                        ],
                    },
                    {
                        "zone_name": "example.org",
                        "default_a_ipv4": "198.51.100.40",
                        "admin_email": "hostmaster.example.org",
                        "zone_serial": 2026021103,
                        "zone_ttl": 600,
                        "zone_refresh": 7200,
                        "zone_retry": 1200,
                        "zone_expire": 1209600,
                        "zone_negative_ttl": 600,
                        "extra_a_records": [],
                    },
                ],
            },
        )

        config = parse_dns_config({"settings": settings})

        # stack_root/container_name/bind_image are server-owned (T-1.1.4,
        # T-1.4.4): the caller cannot move them, so they resolve from
        # server_paths/platform_versions regardless of what else the
        # settings carry.
        self.assertEqual(config.stack_root, "/opt/deploydash/stack/dns")
        self.assertEqual(config.container_name, "deploydash_bind9")
        self.assertEqual(config.bind_image, "internetsystemsconsortium/bind9:9.20")
        self.assertEqual(config.zone_count, 2)
        self.assertEqual(config.zone_names, ["example.net", "example.org"])
        self.assertEqual(config.zone_name, "example.net")
        self.assertEqual(config.nameserver_fqdn, "ns2.example.net")
        self.assertEqual(config.zones[0].default_a_ipv4, "198.51.100.30")
        self.assertEqual(
            config.zones[0].extra_a_records,
            [
                {"name": "www", "ip": "198.51.100.31"},
                {"name": "*.apps", "ip": "198.51.100.32"},
            ],
        )

    def test_parse_requires_nameserver_ip_when_connection_missing(self):
        settings = wire_defaults(CANONICAL_DNS_SETTINGS)
        settings["nameserver_ipv4"] = None

        with self.assertRaises(DnsConfigValidationError):
            parse_dns_config({"settings": settings}, connection_ip=None)


if __name__ == "__main__":
    unittest.main()
