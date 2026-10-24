import unittest

from orchestrator import firewall_status


class _FakeOutput:
    def __init__(self, stdout_lines=None):
        self.stdout_lines = stdout_lines or []


class _FakeHost:
    def __init__(self, command_results):
        self.command_results = command_results
        self.commands = []

    def run_shell_command(self, command, *_args, **_kwargs):
        self.commands.append(command)
        for pattern, result in self.command_results:
            if pattern in command:
                return result
        return False, _FakeOutput([])


class TestFirewallStatus(unittest.TestCase):
    def test_as_int_handles_supported_types(self):
        self.assertEqual(firewall_status.as_int(True, 7), 7)
        self.assertEqual(firewall_status.as_int(9, 7), 9)
        self.assertEqual(firewall_status.as_int(" 11 ", 7), 11)
        self.assertEqual(firewall_status.as_int("bad", 7), 7)
        self.assertEqual(firewall_status.as_int(None, 7), 7)

    def test_parse_key_values_ignores_invalid_lines(self):
        output = _FakeOutput(
            ["A=1", "skip", 9, "B = two ", " =blank-key", "C=3=4"],
        )
        self.assertEqual(
            firewall_status.parse_key_values(output),
            {
                "A": "1",
                "B": "two",
                "": "blank-key",
                "C": "3=4",
            },
        )
        self.assertEqual(firewall_status.parse_key_values(None), {})

    def test_fail2ban_status_payload_defaults_when_command_fails(self):
        host = _FakeHost([])
        self.assertEqual(
            firewall_status.fail2ban_status_payload(host),
            {
                "fail2ban_active": False,
                "fail2ban_enabled": False,
                "fail2ban_sshd_jail_active": False,
                "fail2ban_currently_banned": 0,
                "fail2ban_total_failed": 0,
            },
        )

    def test_fail2ban_status_payload_parses_values(self):
        host = _FakeHost(
            [
                (
                    "FAIL2BAN_ACTIVE=",
                    (
                        True,
                        _FakeOutput(
                            [
                                "FAIL2BAN_ACTIVE=1",
                                "FAIL2BAN_ENABLED=1",
                                "SSHD_JAIL_ACTIVE=1",
                                "CURRENTLY_BANNED=4",
                                "TOTAL_FAILED=12",
                            ],
                        ),
                    ),
                ),
            ],
        )
        self.assertEqual(
            firewall_status.fail2ban_status_payload(host),
            {
                "fail2ban_active": True,
                "fail2ban_enabled": True,
                "fail2ban_sshd_jail_active": True,
                "fail2ban_currently_banned": 4,
                "fail2ban_total_failed": 12,
            },
        )

    def test_build_persistence_status_command_mentions_both_rules_files(self):
        command = firewall_status.build_persistence_status_command(
            "/etc/iptables/rules.v4",
            "/etc/iptables/rules.v6",
        )
        self.assertIn("/etc/iptables/rules.v4", command)
        self.assertIn("/etc/iptables/rules.v6", command)
        self.assertIn("NETFILTER_PERSISTENT=1", command)

    def test_firewall_status_payload_merges_runtime_and_stage_data(self):
        host = _FakeHost(
            [
                ("iptables -w -C INPUT -j CHAIN4", (True, _FakeOutput([]))),
                ("iptables -w -C DOCKER-USER -j DOCKER4", (True, _FakeOutput([]))),
                ("ip6tables -w -C INPUT -j CHAIN6", (True, _FakeOutput([]))),
                ("ip6tables -w -C DOCKER-USER -j DOCKER6", (True, _FakeOutput([]))),
                ("CHECK-ipv4", (True, _FakeOutput([]))),
                ("CHECK-ipv6", (True, _FakeOutput([]))),
                (
                    "RULES_V4=",
                    (
                        True,
                        _FakeOutput(
                            [
                                "RULES_V4=1",
                                "RULES_V6=1",
                                "NETFILTER_PERSISTENT=1",
                            ],
                        ),
                    ),
                ),
                (
                    "FAIL2BAN_ACTIVE=",
                    (
                        True,
                        _FakeOutput(
                            [
                                "FAIL2BAN_ACTIVE=1",
                                "FAIL2BAN_ENABLED=0",
                                "SSHD_JAIL_ACTIVE=1",
                                "CURRENTLY_BANNED=3",
                                "TOTAL_FAILED=27",
                            ],
                        ),
                    ),
                ),
            ],
        )

        result = firewall_status.firewall_status_payload(
            host,
            firewall_specs=(
                {
                    "family": "ipv4",
                    "command": "iptables",
                    "input_chain": "CHAIN4",
                    "docker_chain": "DOCKER4",
                },
                {
                    "family": "ipv6",
                    "command": "ip6tables",
                    "input_chain": "CHAIN6",
                    "docker_chain": "DOCKER6",
                },
            ),
            rules_v4_file="/etc/iptables/rules.v4",
            rules_v6_file="/etc/iptables/rules.v6",
            read_stage_state=lambda _host: {
                "pending": True,
                "token": "stage-1",
                "expires_at": "2026-04-18T13:00:00Z",
                "allow_postgres": True,
                "postgres_source_cidrs": ["198.51.100.24/32"],
            },
            detect_external_interface=lambda _host: "eth0",
            detect_connection_source_address=lambda _host: "198.51.100.24",
            required_input_checks=lambda family: [
                (f"Check {family}", f"CHECK-{family}", 10),
            ],
        )

        self.assertEqual(
            result,
            {
                "firewall_enabled": True,
                "firewall_ipv4_enabled": True,
                "firewall_ipv6_enabled": True,
                "required_preamble_present": True,
                "required_preamble_ipv4_present": True,
                "required_preamble_ipv6_present": True,
                "external_interface": "eth0",
                "connection_source_address": "198.51.100.24",
                "persistent_rules_present": True,
                "persistent_rules_v4_present": True,
                "persistent_rules_v6_present": True,
                "netfilter_persistent_enabled": True,
                "fail2ban_active": True,
                "fail2ban_enabled": False,
                "fail2ban_sshd_jail_active": True,
                "fail2ban_currently_banned": 3,
                "fail2ban_total_failed": 27,
                "staged_state": {
                    "token": "stage-1",
                    "expires_at": "2026-04-18T13:00:00Z",
                    "allow_postgres": True,
                    "postgres_source_cidrs": ["198.51.100.24/32"],
                },
            },
        )

    def test_firewall_status_payload_handles_missing_data(self):
        host = _FakeHost(
            [
                ("iptables -w -C INPUT -j CHAIN4", (False, _FakeOutput([]))),
                ("iptables -w -C DOCKER-USER -j DOCKER4", (True, _FakeOutput([]))),
                ("RULES_V4=", (False, _FakeOutput([]))),
            ],
        )

        result = firewall_status.firewall_status_payload(
            host,
            firewall_specs=(
                {
                    "family": "ipv4",
                    "command": "iptables",
                    "input_chain": "CHAIN4",
                    "docker_chain": "DOCKER4",
                },
            ),
            rules_v4_file="/rules4",
            rules_v6_file="/rules6",
            read_stage_state=lambda _host: {"pending": False},
            detect_external_interface=lambda _host: None,
            detect_connection_source_address=lambda _host: None,
            required_input_checks=lambda family: [
                (f"Check {family}", f"CHECK-{family}", 10),
            ],
        )

        self.assertEqual(result["firewall_enabled"], False)
        self.assertEqual(result["firewall_ipv4_enabled"], False)
        self.assertEqual(result["firewall_ipv6_enabled"], False)
        self.assertEqual(result["persistent_rules_present"], False)
        self.assertEqual(result["staged_state"], None)


if __name__ == "__main__":
    unittest.main()
