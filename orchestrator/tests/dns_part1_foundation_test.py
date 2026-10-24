import unittest

from orchestrator.dns_parts.dns_config import parse_dns_config
from orchestrator.dns_parts.part1_foundation import (
    _render_apply_script,
    _render_compose,
    _render_named_conf,
    _render_named_options,
    _render_zone_file,
    _render_zones_conf,
    build_steps,
)


def _config():
    return parse_dns_config({"settings": _settings()})


def _settings():
    return {
        # container_name/bind_image/bind_service_name are server-owned
        # (T-1.4.4) and were set here to their own default values anyway;
        # omitted rather than sent, since sending them now raises.
        "zone_name": "legacy.example.com",
        "nameserver_hostname": "ns1",
        "nameserver_ipv4": "198.51.100.10",
        "default_a_ipv4": "198.51.100.10",
        "admin_email": "hostmaster.example.com",
        "zone_serial": 2026021101,
        "zone_ttl": 300,
        "zone_refresh": 3600,
        "zone_retry": 900,
        "zone_expire": 604800,
        "zone_negative_ttl": 300,
        "allow_recursion": False,
        "recursion_cidrs": ["127.0.0.1/32"],
        "forwarders": [],
        "listen_on_ipv6": False,
        "extra_a_records": [],
        "zones": [
            {
                "zone_name": "example.com",
                "default_a_ipv4": "198.51.100.10",
                "admin_email": "hostmaster.example.com",
                "zone_serial": 2026021101,
                "zone_ttl": 300,
                "zone_refresh": 3600,
                "zone_retry": 900,
                "zone_expire": 604800,
                "zone_negative_ttl": 300,
                "extra_a_records": [],
            },
            {
                "zone_name": "example.org",
                "default_a_ipv4": "198.51.100.20",
                "admin_email": "hostmaster.example.org",
                "zone_serial": 2026021102,
                "zone_ttl": 300,
                "zone_refresh": 3600,
                "zone_retry": 900,
                "zone_expire": 604800,
                "zone_negative_ttl": 300,
                "extra_a_records": [],
            },
        ],
    }


class TestDnsPart1Foundation(unittest.TestCase):
    def test_named_conf_includes_options_and_zones(self):
        rendered = _render_named_conf()
        self.assertIn('include "/etc/bind/options.conf";', rendered)
        self.assertIn('include "/etc/bind/zones.conf";', rendered)

    def test_named_options_are_authoritative_only(self):
        rendered = _render_named_options(_config())

        self.assertIn("recursion no;", rendered)
        self.assertIn("allow-recursion { none; };", rendered)
        self.assertIn("allow-query-cache { none; };", rendered)

    def test_named_options_uses_ipv6_any_when_enabled(self):
        cfg = parse_dns_config(
            {
                "settings": {
                    **_settings(),
                    "listen_on_ipv6": True,
                }
            }
        )
        rendered = _render_named_options(cfg)
        self.assertIn("listen-on-v6 { any; };", rendered)

    def test_zones_conf_renders_all_zones(self):
        rendered = _render_zones_conf(_config())

        self.assertIn('zone "example.com"', rendered)
        self.assertIn('zone "example.org"', rendered)

    def test_zone_file_includes_extra_records(self):
        cfg = parse_dns_config(
            {
                "settings": {
                    **_settings(),
                    "zones": [
                        {
                            **_settings()["zones"][0],
                            "extra_a_records": [
                                {"name": "api", "ip": "198.51.100.30"},
                                {"name": "www", "ip": "198.51.100.31"},
                            ],
                        },
                        _settings()["zones"][1],
                    ],
                }
            }
        )
        zone = cfg.zones[0]
        rendered = _render_zone_file(cfg, zone)
        self.assertIn("api IN A 198.51.100.30", rendered)
        self.assertIn("www IN A 198.51.100.31", rendered)

    def test_compose_includes_bind_container_and_mounts(self):
        cfg = _config()
        rendered = _render_compose(cfg)
        self.assertIn("container_name: deploydash_bind9", rendered)
        self.assertIn("image: internetsystemsconsortium/bind9:9.20", rendered)
        self.assertIn("security_opt:\n      - no-new-privileges:true", rendered)
        self.assertIn("cap_drop:\n      - ALL", rendered)
        self.assertIn(
            "cap_add:\n      - NET_BIND_SERVICE\n      - SETUID\n      - SETGID",
            rendered,
        )
        self.assertIn("command:\n      - -g", rendered)
        self.assertNotIn("command:\n      - named", rendered)
        self.assertIn("pids_limit: 512", rendered)
        self.assertIn("/opt/deploydash/stack/dns/bind:/etc/bind:ro", rendered)
        self.assertIn("/opt/deploydash/stack/dns/zones:/zones:ro", rendered)

    def test_apply_script_contains_validation_steps(self):
        rendered = _render_apply_script(_config())
        self.assertIn("named-checkconf /etc/bind/named.conf", rendered)
        self.assertIn("named-checkzone", rendered)
        self.assertIn('docker compose -f "${COMPOSE_FILE}" restart bind9', rendered)
        self.assertIn('ZONES_CONF="${STACK_ROOT}/bind/zones.conf"', rendered)
        self.assertIn("awk -F'\"' '/^zone \"", rendered)

    def test_build_steps_registers_expected_operation_count(self):
        class _Runtime:
            def __init__(self):
                self.calls = []

            def add_operation(self, op, **kwargs):
                self.calls.append((op.__name__, kwargs))

        cfg = _config()
        step = build_steps(cfg)[0]
        runtime = _Runtime()
        step.register(runtime)

        # 3 directories + 3 config files + 2 zone files + prune shell
        # + compose + readme + apply helper
        self.assertEqual(len(runtime.calls), 12)
        put_destinations = [kwargs.get("dest") for name, kwargs in runtime.calls if name == "put"]
        self.assertIn("/usr/local/bin/deploydash-bind-apply", put_destinations)


if __name__ == "__main__":
    unittest.main()
