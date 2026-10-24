import json
import unittest
from unittest.mock import Mock, patch

from engine import handle_request
from orchestrator.engine_firewall_ops import (
    FirewallConfigValidationError,
    _allow_check_commands,
    _apply_staged_firewall,
    _commit_ssh_port_firewall,
    _detect_connection_source_address,
    _effective_allow_rules,
    _firewall_spec,
    _normalize_custom_rules,
    _normalize_locked_ports,
    _normalize_port,
    _normalize_protocol,
    _normalize_source_cidr,
    _parse_firewall_settings,
    _parse_ss_local_endpoint,
    _postgres_tls_policy_check_command,
    _preamble_allow_steps,
    _preamble_check_commands,
    _read_stage_state,
    _restore_snapshot,
    _restore_snapshots,
    _stage_ssh_port_firewall,
    run_firewall_runtime_operation,
)
from orchestrator.shell_output import parse_bool_token


class _FakeOutput:
    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


class _FirewallHost:
    def __init__(self, staged_state=None):
        self.commands = []
        self.staged_state = staged_state

    def run_shell_command(self, command, *_args, **_kwargs):
        self.commands.append(command)
        if "SSH_CONNECTION%%" in command:
            return True, _FakeOutput(stdout_lines=["SOURCE_ADDRESS=198.51.100.24"])
        if "ip route get 1.1.1.1" in command:
            return True, _FakeOutput(stdout_lines=["IFACE=eth0"])
        if "iptables -w -C INPUT -j DEPLOYDASH-INPUT" in command:
            return True, _FakeOutput(stdout_lines=[])
        if "iptables -w -C DOCKER-USER -j DEPLOYDASH-DOCKER-USER" in command:
            return True, _FakeOutput(stdout_lines=[])
        if "ip6tables -w -C INPUT -j DEPLOYDASH6-INPUT" in command:
            return True, _FakeOutput(stdout_lines=[])
        if "ip6tables -w -C DOCKER-USER -j DEPLOYDASH6-DOCKER-USER" in command:
            return True, _FakeOutput(stdout_lines=[])
        if "RULES_V4=" in command and "NETFILTER_PERSISTENT=" in command:
            return (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "RULES_V4=1",
                        "RULES_V6=1",
                        "NETFILTER_PERSISTENT=1",
                    ],
                ),
            )
        if "FAIL2BAN_ACTIVE=" in command and "SSHD_JAIL_ACTIVE=" in command:
            return (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "FAIL2BAN_ACTIVE=1",
                        "FAIL2BAN_ENABLED=1",
                        "SSHD_JAIL_ACTIVE=1",
                        "CURRENTLY_BANNED=2",
                        "TOTAL_FAILED=17",
                    ],
                ),
            )
        if "ss -H -lntup" in command:
            return (
                True,
                _FakeOutput(
                    stdout_lines=[
                        'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))',
                        'tcp LISTEN 0 128 0.0.0.0:5432 0.0.0.0:* users:(("postgres",pid=2,fd=4))',
                    ],
                ),
            )
        if "docker ps --format" in command:
            return (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "deploydash_postgres\t0.0.0.0:5432->5432/tcp, :::5432->5432/tcp",
                    ],
                ),
            )
        if "PENDING=0" in command and "STAGE_FILE" in command:
            if self.staged_state:
                return (
                    True,
                    _FakeOutput(
                        stdout_lines=[
                            "PENDING=1",
                            f"TOKEN={self.staged_state['token']}",
                            f"EXPIRES_AT={self.staged_state['expires_at']}",
                            f"SNAPSHOT_V4={self.staged_state['snapshot_v4']}",
                            f"SNAPSHOT_V6={self.staged_state['snapshot_v6']}",
                            (
                                "UFW_ACTIVE_BEFORE=1"
                                if self.staged_state.get("ufw_active_before")
                                else "UFW_ACTIVE_BEFORE=0"
                            ),
                        ],
                    ),
                )
            return True, _FakeOutput(stdout_lines=["PENDING=0"])
        if 'cat > "${STAGE_FILE}" <<EOF' in command:
            return True, _FakeOutput(stdout_lines=[])
        if 'rm -f "${STAGE_FILE}"' in command:
            self.staged_state = None
            return True, _FakeOutput(stdout_lines=[])
        return True, _FakeOutput(stdout_lines=[])


class _FakeSession:
    def __init__(self, host):
        self.host = host

    def close(self):
        return {"disconnect_error": None}


def _run_firewall_request(
    mock_open_runtime_session, host, operation_id, settings=None, dry_run=False
):
    """Drive any firewall runtime operation against a fake host.

    Centralizes the request envelope so preamble, ordering, and failure-path
    tests differ only in host behavior and assertions rather than boilerplate.
    """
    mock_open_runtime_session.return_value = {
        "ok": True,
        "session": _FakeSession(host),
    }
    payload = json.dumps(
        {
            "action": "run_workflow",
            "workflow_id": "firewall",
            "operation_id": operation_id,
            "connection": {
                "ip": "203.0.113.10",
                "port": 22,
                "username": "ubuntu",
                "password": "secret",
            },
            "params": {
                "dry_run": dry_run,
                "settings": settings if settings is not None else {},
            },
        }
    )
    return json.loads(handle_request(payload))


def _run_apply_staged(mock_open_runtime_session, host, settings=None):
    """Drive the firewall apply_staged runtime operation against a fake host.

    Strict-mode staging with PostgreSQL allowed is the shape every onboarding
    run uses, so it is the default under test unless a test says otherwise.
    """
    if settings is None:
        settings = {
            "strict_mode": True,
            "allow_postgres": True,
            "rollback_timeout_seconds": 3600,
            "locked_ports": [22],
        }
    elif "locked_ports" not in settings:
        settings = {**settings, "locked_ports": [22]}
    return _run_firewall_request(mock_open_runtime_session, host, "apply_staged", settings=settings)


def _snapshot_restore_commands(host):
    """Select scoped restore invocations without matching timer-script source."""
    return [
        command
        for command in host.commands
        if "SNAPSHOT=" in command and 'sh -eu "${SNAPSHOT}"' in command
    ]


class TestFirewallWorkflow(unittest.TestCase):
    def test_describe_firewall_plan(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "firewall",
                "operation_id": "describe",
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["workflow_id"], "firewall")
        self.assertIn("status", result["supported_operations"])
        self.assertNotIn(22, result["locked_ports"])
        self.assertEqual(result["locked_ports"], [80, 443])

    @patch("engine._open_runtime_session")
    def test_firewall_status(self, mock_open_runtime_session):
        host = _FirewallHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "firewall",
                "operation_id": "status",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "status")
        self.assertEqual(result["firewall_enabled"], True)
        self.assertEqual(result["firewall_ipv4_enabled"], True)
        self.assertEqual(result["firewall_ipv6_enabled"], True)
        self.assertEqual(result["external_interface"], "eth0")
        self.assertEqual(result["connection_source_address"], "198.51.100.24")
        self.assertEqual(result["persistent_rules_present"], True)
        self.assertEqual(result["netfilter_persistent_enabled"], True)
        self.assertEqual(result["fail2ban_active"], True)
        self.assertEqual(result["fail2ban_enabled"], True)
        self.assertEqual(result["fail2ban_sshd_jail_active"], True)
        self.assertEqual(result["fail2ban_currently_banned"], 2)
        self.assertEqual(result["fail2ban_total_failed"], 17)

    @patch("engine._open_runtime_session")
    def test_firewall_status_marks_a_missing_required_preamble_as_disabled(
        self,
        mock_open_runtime_session,
    ):
        """Existing servers missing the IPv6 safety rules must prompt re-apply."""
        host = _FailingFirewallHost(
            "-C DEPLOYDASH6-INPUT -p icmpv6 --icmpv6-type 135",
        )

        result = _run_firewall_request(
            mock_open_runtime_session,
            host,
            "status",
        )

        self.assertEqual(result["status"], "success")
        self.assertFalse(result["firewall_enabled"])
        self.assertFalse(result["firewall_ipv6_enabled"])
        self.assertFalse(result["required_preamble_present"])

    @patch("engine._open_runtime_session")
    def test_firewall_scan_open_ports(self, mock_open_runtime_session):
        host = _FirewallHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "firewall",
                "operation_id": "scan_open_ports",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "scan_open_ports")
        self.assertGreaterEqual(len(result["open_ports"]), 2)
        sources = {item["source"] for item in result["open_ports"]}
        self.assertIn("host_listener", sources)
        self.assertIn("docker_published", sources)

    def test_firewall_apply_staged_dry_run(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "firewall",
                "operation_id": "apply_staged",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {
                        "strict_mode": True,
                        "allow_postgres": True,
                        "locked_ports": [22],
                        "custom_rules": [
                            {
                                "id": "custom-webhook",
                                "protocol": "tcp",
                                "port_start": 8443,
                                "port_end": 8443,
                                "source_cidr": "203.0.113.0/24",
                            },
                        ],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "apply_staged")
        self.assertIn(
            "Snapshot only Deploy Dash-managed chains and jump ownership",
            result["actions"],
        )
        self.assertIn(
            "Replace ufw with the Deploy Dash firewall",
            result["actions"],
        )

    def test_firewall_apply_staged_dry_run_accepts_ipv6_cidr(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "firewall",
                "operation_id": "apply_staged",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {
                        "locked_ports": [22],
                        "custom_rules": [
                            {
                                "id": "custom-admin-ipv6",
                                "protocol": "tcp",
                                "port_start": 9443,
                                "port_end": 9443,
                                "source_cidr": "2001:db8::/64",
                            },
                        ],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "apply_staged")

    @patch("engine._open_runtime_session")
    def test_firewall_apply_staged_runtime(self, mock_open_runtime_session):
        host = _FirewallHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "firewall",
                "operation_id": "apply_staged",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "strict_mode": True,
                        "allow_postgres": True,
                        "rollback_timeout_seconds": 3600,
                        "locked_ports": [22],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "apply_staged")
        self.assertEqual(result["rollback_timeout_seconds"], 3600)
        self.assertIn("staged_state", result)
        self.assertIsInstance(result["staged_state"], dict)
        self.assertTrue(result["staged_state"].get("token"))
        self.assertEqual(result["staged_state"].get("allow_postgres"), True)
        self.assertTrue(any("ip6tables -w -S DEPLOYDASH6-INPUT" in cmd for cmd in host.commands))
        self.assertTrue(
            any("dpkg -s iptables-persistent" in cmd for cmd in host.commands),
        )
        self.assertTrue(any("ALLOW_POSTGRES=1" in cmd for cmd in host.commands))
        self.assertTrue(any("SLEEP_SECONDS=3600" in cmd for cmd in host.commands))
        self.assertTrue(
            any('flock -x "${LOCK_FILE}" sh -eu -c' in cmd for cmd in host.commands),
        )
        self.assertTrue(
            any("ip6tables -w -A DEPLOYDASH6-INPUT" in cmd for cmd in host.commands),
        )
        self.assertTrue(
            any("ip6tables -w -A DEPLOYDASH6-DOCKER-USER" in cmd for cmd in host.commands),
        )

    @patch("engine._open_runtime_session")
    def test_apply_staged_accepts_icmpv6_preamble_before_strict_drop(
        self, mock_open_runtime_session
    ):
        """IPv6 stays up behind a strict firewall: ND/RA and errors precede the DROP."""
        host = _FirewallHost()
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "success")
        drop_index = next(
            index
            for index, command in enumerate(host.commands)
            if "ip6tables -w -A DEPLOYDASH6-INPUT -j DROP" in command
        )
        for fragment in (
            "--icmpv6-type 2 ",
            "--icmpv6-type 134 ",
            "--icmpv6-type 135 ",
            "--icmpv6-type 136 ",
            "-m hl --hl-eq 255",
            "--sport 547 --dport 546",
        ):
            with self.subTest(fragment=fragment):
                accept_index = next(
                    index
                    for index, command in enumerate(host.commands)
                    if fragment in command and "-A DEPLOYDASH6-INPUT" in command
                )
                self.assertLess(accept_index, drop_index)

    @patch("engine._open_runtime_session")
    def test_apply_staged_accepts_ipv4_echo_before_strict_drop(self, mock_open_runtime_session):
        """Ping-based uptime monitoring survives a strict firewall stage."""
        host = _FirewallHost()
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "success")
        drop_index = next(
            index
            for index, command in enumerate(host.commands)
            if "iptables -w -A DEPLOYDASH-INPUT -j DROP" in command and "ip6tables" not in command
        )
        accept_index = next(
            index
            for index, command in enumerate(host.commands)
            if "--icmp-type echo-request" in command
            and "-A DEPLOYDASH-INPUT" in command
            and "ip6tables" not in command
        )
        self.assertLess(accept_index, drop_index)

    @patch("engine._open_runtime_session")
    def test_apply_staged_allows_and_validates_http3_udp_443(
        self,
        mock_open_runtime_session,
    ):
        """Caddy's published HTTP/3 endpoint must survive strict filtering."""
        host = _FirewallHost()

        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "success")
        command_blob = "\n".join(host.commands)
        for binary, input_chain, docker_chain in (
            ("iptables", "DEPLOYDASH-INPUT", "DEPLOYDASH-DOCKER-USER"),
            ("ip6tables", "DEPLOYDASH6-INPUT", "DEPLOYDASH6-DOCKER-USER"),
        ):
            with self.subTest(binary=binary):
                input_match = f"{binary} -w -A {input_chain} -p udp -m udp --dport 443 -j ACCEPT"
                docker_match = f"{binary} -w -A {docker_chain} -p udp -m udp --dport 443 -j RETURN"
                self.assertIn(input_match, command_blob)
                self.assertIn(docker_match, command_blob)
                self.assertIn(input_match.replace(" -A ", " -C "), command_blob)
                self.assertIn(docker_match.replace(" -A ", " -C "), command_blob)

    @patch("engine._open_runtime_session")
    def test_apply_staged_validates_icmp_preamble_before_committing(
        self, mock_open_runtime_session
    ):
        """A stage missing its ICMP preamble must be detectable before commit."""
        host = _FirewallHost()
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "success")
        self.assertTrue(
            any(
                "ip6tables -w -C DEPLOYDASH6-INPUT" in command and "icmpv6-type" in command
                for command in host.commands
            ),
            "expected a live-chain check for the ICMPv6 preamble",
        )
        self.assertTrue(
            any(
                "iptables -w -C DEPLOYDASH-INPUT" in command
                and "icmp-type" in command
                and "ip6tables" not in command
                for command in host.commands
            ),
            "expected a live-chain check for the IPv4 ICMP preamble",
        )

    @patch("engine._open_runtime_session")
    def test_firewall_commit_persists_dual_stack_rules(self, mock_open_runtime_session):
        host = _FirewallHost(
            staged_state={
                "token": "fw-commit-token",
                "expires_at": "2026-03-14T10:00:00+00:00",
                "snapshot_v4": "/opt/deploydash/firewall/snapshot-fw-commit-token.rules.v4",
                "snapshot_v6": "/opt/deploydash/firewall/snapshot-fw-commit-token.rules.v6",
            },
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "firewall",
                "operation_id": "commit",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "stage_token": "fw-commit-token",
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "commit")
        self.assertTrue(
            any("iptables-save > /etc/iptables/rules.v4" in cmd for cmd in host.commands),
        )
        self.assertTrue(
            any("ip6tables-save > /etc/iptables/rules.v6" in cmd for cmd in host.commands),
        )
        self.assertTrue(
            any("systemctl enable netfilter-persistent" in cmd for cmd in host.commands),
        )
        commit_commands = [
            command
            for command in host.commands
            if "systemctl enable netfilter-persistent" in command
        ]
        self.assertEqual(len(commit_commands), 1)
        self.assertIn('flock -x "${LOCK_FILE}"', commit_commands[0])
        self.assertNotIn("apt-get", commit_commands[0])
        self.assertLess(
            commit_commands[0].index("flock -x"),
            commit_commands[0].index("iptables-save"),
        )
        self.assertIn('rm -f "${STAGE_FILE}"', commit_commands[0])
        self.assertEqual(result["persistent_rules_present"], True)

    @patch("engine._open_runtime_session")
    def test_firewall_commit_with_vanished_stage_fails_loudly(self, mock_open_runtime_session):
        host = _FirewallHost(staged_state=None)
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "firewall",
                "operation_id": "commit",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "stage_token": "fw-vanished-token",
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertIn("reverted", result["msg"])

    def test_allow_checks_cover_every_effective_rule_at_each_boundary(self):
        """One exact checker owns both host and Docker allow validation."""
        rules = [
            {
                "protocol": "tcp",
                "port_start": 2222,
                "port_end": 2222,
                "family": "ipv4",
            },
            {
                "protocol": "tcp",
                "port_start": 8000,
                "port_end": 8010,
                "family": "ipv6",
            },
        ]
        specs = _allow_check_commands(rules, docker=True)

        self.assertEqual(len(specs), 2)
        ipv4_label, ipv4_command, ipv4_timeout = specs[0]
        self.assertIn("2222", ipv4_label)
        self.assertIn("DEPLOYDASH-DOCKER-USER", ipv4_command)
        self.assertIn("--dport 2222", ipv4_command)
        self.assertIn("-w -C DEPLOYDASH-DOCKER-USER", ipv4_command)
        self.assertIn("-j RETURN", ipv4_command)
        self.assertNotIn("-S ", ipv4_command)
        self.assertEqual(ipv4_timeout, 10)
        _ipv6_label, ipv6_command, _ipv6_timeout = specs[1]
        self.assertIn("DEPLOYDASH6-DOCKER-USER", ipv6_command)
        self.assertIn("--dport 8000:8010", ipv6_command)

        host_specs = _allow_check_commands(rules, docker=False)
        self.assertIn("DEPLOYDASH-INPUT", host_specs[0][1])
        self.assertIn("-j ACCEPT", host_specs[0][1])
        self.assertIn("DEPLOYDASH6-INPUT", host_specs[1][1])


class _FailingFirewallHost(_FirewallHost):
    """Fake host that fails staged commands containing a chosen fragment.

    Gives each failure-path test one deterministic fault while every other
    command succeeds, mirroring Tier 0 fault injection at the host seam.
    """

    def __init__(self, fail_fragment, staged_state=None):
        super().__init__(staged_state=staged_state)
        self.fail_fragment = fail_fragment

    def run_shell_command(self, command, *_args, **_kwargs):
        if self.fail_fragment in command:
            self.commands.append(command)
            return False, _FakeOutput(stderr_lines=["boom"])
        return super().run_shell_command(command, *_args, **_kwargs)


class _FailingLiveFirewallHost(_FirewallHost):
    """Fake host that faults only a live command, not snapshot script text."""

    def __init__(self, fail_prefix, staged_state=None):
        super().__init__(staged_state=staged_state)
        self.fail_prefix = fail_prefix

    def run_shell_command(self, command, *_args, **_kwargs):
        if command.startswith(self.fail_prefix):
            self.commands.append(command)
            return False, _FakeOutput(stderr_lines=["boom"])
        return super().run_shell_command(command, *_args, **_kwargs)


class _UfwActiveFailingFirewallHost(_FailingFirewallHost):
    """Model a protected UFW host whose Deploy Dash stage later fails."""

    def run_shell_command(self, command, *_args, **_kwargs):
        if "UFW_INSTALLED=" in command:
            self.commands.append(command)
            return True, _FakeOutput(
                stdout_lines=[
                    "UFW_INSTALLED=1",
                    "UFW_ACTIVE=1",
                    "UFW_ENABLED=1",
                    "UFW_RULE=22/tcp ALLOW IN Anywhere",
                ],
            )
        return super().run_shell_command(command, *_args, **_kwargs)


class _IfaceScriptedHost(_FirewallHost):
    """Fake host serving a scripted interface-detection answer."""

    def __init__(self, iface_lines):
        super().__init__()
        self.iface_lines = iface_lines

    def run_shell_command(self, command, *_args, **_kwargs):
        if "ip route get 1.1.1.1" in command:
            self.commands.append(command)
            return True, _FakeOutput(stdout_lines=self.iface_lines)
        return super().run_shell_command(command, *_args, **_kwargs)


class _UnprotectedMarkerHost(_FirewallHost):
    """Model the durable marker left by a timed rollback after UFW removal."""

    def run_shell_command(self, command, *_args, **_kwargs):
        if "UNPROTECTED_MARKER=" in command:
            self.commands.append(command)
            return True, _FakeOutput(stdout_lines=["FIREWALL_UNPROTECTED=1"])
        return super().run_shell_command(command, *_args, **_kwargs)


class _PartialStageHost(_FirewallHost):
    """Fake host whose staged state omits the IPv6 snapshot path."""

    def run_shell_command(self, command, *_args, **_kwargs):
        if "PENDING=0" in command and "STAGE_FILE" in command:
            self.commands.append(command)
            return True, _FakeOutput(
                stdout_lines=[
                    "PENDING=1",
                    "TOKEN=fw-partial",
                    "EXPIRES_AT=2026-03-14T10:00:00+00:00",
                    "SNAPSHOT_V4=/tmp/snap.v4",
                ]
            )
        return super().run_shell_command(command, *_args, **_kwargs)


class _ScanScriptedHost(_FirewallHost):
    """Fake host serving crafted listener listings for the port scanner."""

    def __init__(self, ss_lines, docker_lines):
        super().__init__()
        self.ss_lines = ss_lines
        self.docker_lines = docker_lines

    def run_shell_command(self, command, *_args, **_kwargs):
        if command.startswith("ss -H"):
            self.commands.append(command)
            return True, _FakeOutput(stdout_lines=self.ss_lines)
        if command.startswith("docker ps"):
            self.commands.append(command)
            return True, _FakeOutput(stdout_lines=self.docker_lines)
        return super().run_shell_command(command, *_args, **_kwargs)


class _NoisyDisconnectSession(_FakeSession):
    """Fake session whose close reports a disconnect problem."""

    def close(self):
        return {"disconnect_error": "connection reset by peer"}


class _StubFirewallSession:
    """Session stub that opens without touching the network or a host."""

    def __init__(self):
        self.closed = False
        self.host = _FirewallHost()

    def close(self):
        self.closed = True
        return {"disconnect_error": None}


class _StubFirewallContext:
    """Minimal ctx for direct operation tests: stub session, recorded events."""

    def __init__(self):
        self.events = []
        self.sessions_opened = 0
        self.last_session = None

    def error_result(self, code, msg, stage=None, details=None):
        return {
            "status": "error",
            "code": code,
            "msg": msg,
            "stage": stage,
            "details": details,
        }

    def emit_event(self, emit, name, msg, level=None, data=None):
        self.events.append((name, msg))

    def emit_shell_output_lines(self, emit, output):
        """Accept fake shell output because direct operation tests need no sink."""

    def command_error_details(self, output):
        """Give injected command failures a stable detail at the context seam."""
        return "remote command failed"

    def open_runtime_session(self, **_kwargs):
        self.sessions_opened += 1
        self.last_session = _StubFirewallSession()
        return {"ok": True, "session": self.last_session}


class TestFirewallOpsUnits(unittest.TestCase):
    def test_connection_source_detection_accepts_only_an_ip_address(self):
        """Only a validated SSH peer address may become the UI safety default."""
        host = _FirewallHost()
        self.assertEqual(
            _detect_connection_source_address(host),
            "198.51.100.24",
        )
        host.run_shell_command = Mock(
            return_value=(True, _FakeOutput(stdout_lines=["SOURCE_ADDRESS=not-an-ip"])),
        )
        self.assertIsNone(_detect_connection_source_address(host))
        host.run_shell_command = Mock(
            return_value=(False, _FakeOutput(stderr_lines=["missing session"])),
        )
        self.assertIsNone(_detect_connection_source_address(host))

    def test_settings_payload_handles_all_envelope_shapes(self):
        """Missing, bare, and wrapped settings all resolve to a usable config."""
        self.assertTrue(_parse_firewall_settings(None)["strict_mode"])
        self.assertEqual(_parse_firewall_settings(None)["rollback_timeout_seconds"], 90)
        self.assertFalse(_parse_firewall_settings({"strict_mode": False})["strict_mode"])
        self.assertFalse(
            _parse_firewall_settings({"settings": {"strict_mode": False}})["strict_mode"]
        )

    def test_bool_tokens_read_switch_strings(self):
        """String toggles from older callers keep their meaning."""
        for truthy in ("1", "true", "yes", "on", " YeS "):
            self.assertTrue(parse_bool_token(truthy))
        for falsy in ("0", "false", "no", "off"):
            self.assertFalse(parse_bool_token(falsy))
        self.assertTrue(parse_bool_token("bogus", True))
        self.assertFalse(parse_bool_token("bogus"))
        self.assertTrue(parse_bool_token(1, True))

    def test_normalize_protocol_rejects_non_tcp_udp(self):
        """Only TCP and UDP can become firewall rules."""
        self.assertEqual(_normalize_protocol("TCP"), "tcp")
        with self.assertRaises(FirewallConfigValidationError) as raised:
            _normalize_protocol("icmp")
        self.assertEqual(str(raised.exception), "Custom rule protocol must be tcp or udp.")

    def test_normalize_port_rejects_out_of_range(self):
        """Rule ports stay inside the 16-bit range."""
        self.assertEqual(_normalize_port("80", "port"), 80)
        for bad in (0, 70000, "x", None):
            with (
                self.subTest(value=bad),
                self.assertRaises(FirewallConfigValidationError),
            ):
                _normalize_port(bad, "port")

    def test_normalize_source_cidr_handles_blank_and_invalid(self):
        """Blank sources mean anywhere; malformed ones fail loudly."""
        self.assertEqual(_normalize_source_cidr(None), (None, None))
        self.assertEqual(_normalize_source_cidr("  "), (None, None))
        self.assertEqual(_normalize_source_cidr("10.0.0.0/8"), ("10.0.0.0/8", "ipv4"))
        self.assertEqual(_normalize_source_cidr("2001:db8::/32"), ("2001:db8::/32", "ipv6"))
        with self.assertRaises(FirewallConfigValidationError):
            _normalize_source_cidr("bogus")

    def test_normalize_locked_ports_skips_invalid_and_duplicates(self):
        """Web ports stay fixed while SSH is included only when explicitly active."""
        self.assertEqual(
            _normalize_locked_ports([0, "x", 70000, 22, 22, 8080]),
            [22, 80, 443, 8080],
        )
        self.assertEqual(_normalize_locked_ports(None), [80, 443])

    def test_normalize_custom_rules_skips_non_dict_entries(self):
        """Malformed custom-rule entries are ignored, valid ones kept."""
        rules = _normalize_custom_rules(
            [
                "nope",
                None,
                {
                    "id": "ok",
                    "protocol": "tcp",
                    "port_start": 8443,
                    "port_end": 8443,
                },
            ]
        )
        self.assertEqual([rule["id"] for rule in rules], ["ok"])
        self.assertEqual(_normalize_custom_rules(None), [])

    def test_normalize_custom_rules_rejects_inverted_range(self):
        """A port range ending before it starts is a validation error."""
        with self.assertRaises(FirewallConfigValidationError) as raised:
            _normalize_custom_rules(
                [
                    {
                        "id": "bad",
                        "protocol": "tcp",
                        "port_start": 90,
                        "port_end": 80,
                    }
                ]
            )
        self.assertIn("port_end must be greater than or equal", str(raised.exception))

    def test_effective_allow_rules_skips_disabled_and_dedupes(self):
        """Disabled rules vanish; a custom copy of a locked port adds nothing."""
        config = _parse_firewall_settings(
            {
                "settings": {
                    "custom_rules": [
                        {
                            "id": "off",
                            "protocol": "tcp",
                            "port_start": 9999,
                            "port_end": 9999,
                            "enabled": False,
                        },
                        {
                            "id": "dup-https",
                            "protocol": "tcp",
                            "port_start": 443,
                            "port_end": 443,
                        },
                    ]
                }
            }
        )
        rules = _effective_allow_rules(config)
        self.assertFalse(any(rule["port_start"] == 9999 for rule in rules))
        https = [rule for rule in rules if rule["port_start"] == 443]
        self.assertEqual(len(https), 4)
        self.assertEqual({rule["family"] for rule in https}, {"ipv4", "ipv6"})
        self.assertEqual(
            {(rule["protocol"], rule["label"]) for rule in https},
            {("tcp", "locked-443"), ("udp", "fixed-http3")},
        )

    def test_postgres_source_cidrs_restrict_the_curated_rule(self):
        """The temporary Postgres toggle must not broaden past chosen clients."""
        config = _parse_firewall_settings(
            {
                "allow_postgres": True,
                "postgres_source_cidrs": [
                    "198.51.100.24/32",
                    "198.51.100.24",
                    "2001:db8::24/128",
                ],
                "locked_ports": [],
            },
        )

        postgres_rules = [
            rule for rule in _effective_allow_rules(config) if rule["port_start"] == 5432
        ]

        self.assertEqual(
            postgres_rules,
            [
                {
                    "protocol": "tcp",
                    "port_start": 5432,
                    "port_end": 5432,
                    "source_cidr": "198.51.100.24/32",
                    "source_family": "ipv4",
                    "label": "curated",
                    "family": "ipv4",
                },
                {
                    "protocol": "tcp",
                    "port_start": 5432,
                    "port_end": 5432,
                    "source_cidr": "2001:db8::24/128",
                    "source_family": "ipv6",
                    "label": "curated",
                    "family": "ipv6",
                },
            ],
        )

    def test_postgres_source_cidrs_reject_invalid_or_oversized_lists(self):
        """A malformed or unbounded allowlist must fail before any firewall change."""
        for source_cidrs in (
            "198.51.100.24/32",
            ["   "],
            ["not-a-network"],
            [f"198.51.100.{index}/32" for index in range(33)],
        ):
            with (
                self.subTest(source_cidrs=source_cidrs),
                self.assertRaises(
                    FirewallConfigValidationError,
                ),
            ):
                _parse_firewall_settings(
                    {
                        "allow_postgres": True,
                        "postgres_source_cidrs": source_cidrs,
                    },
                )

    def test_firewall_spec_rejects_unknown_family(self):
        """Only the two managed families have a chain spec."""
        self.assertEqual(_firewall_spec("ipv6")["input_chain"], "DEPLOYDASH6-INPUT")
        with self.assertRaises(ValueError):
            _firewall_spec("nope")

    def test_parse_ss_local_endpoint_handles_edge_shapes(self):
        """Empty, unbracketed, and bracketed endpoints all parse exactly."""
        self.assertEqual(_parse_ss_local_endpoint(""), (None, None))
        self.assertEqual(_parse_ss_local_endpoint("[abc"), ("[abc", None))
        self.assertEqual(_parse_ss_local_endpoint("1.2.3.4:80"), ("1.2.3.4", "80"))
        self.assertEqual(_parse_ss_local_endpoint("[::1]:443"), ("::1", "443"))

    def test_restore_snapshot_rejects_missing_path(self):
        """Restoring without a snapshot path fails closed, never half-applies."""
        restored, details = _restore_snapshot(
            _StubFirewallContext(), None, _firewall_spec("ipv4"), None
        )
        self.assertFalse(restored)
        self.assertEqual(details, "missing snapshot path")

    def test_restore_snapshots_attempts_every_family_after_a_failure(self):
        """Rollback must try both families so one failure cannot strand the other."""
        host = Mock()
        host.run_shell_command.side_effect = [
            (False, _FakeOutput(stderr_lines=["IPv4 restore failed"])),
            (True, _FakeOutput()),
        ]

        restored, details = _restore_snapshots(
            _StubFirewallContext(),
            host,
            {
                "snapshot_v4": "/tmp/snap.v4",
                "snapshot_v6": "/tmp/snap.v6",
            },
        )

        self.assertFalse(restored)
        self.assertIn("IPv4", details)
        self.assertEqual(host.run_shell_command.call_count, 2)
        commands = [call.args[0] for call in host.run_shell_command.call_args_list]
        self.assertIn("/tmp/snap.v4", commands[0])
        self.assertIn("/tmp/snap.v6", commands[1])

    def test_read_stage_state_defaults_when_command_fails(self):
        """A failed stage read means no pending stage, not a crash."""
        host = _FailingFirewallHost("PENDING=0")
        self.assertEqual(
            _read_stage_state(host),
            {"pending": False, "token": None, "expires_at": None, "snapshot": None},
        )

    def test_preamble_allow_steps_emit_exact_chain_commands(self):
        """The ICMP preamble is fixed data: one known command per rule."""
        v6_steps = _preamble_allow_steps(_firewall_spec("ipv6"))
        self.assertEqual(len(v6_steps), 14)
        v6_commands = [command for _, command, _ in v6_steps]
        self.assertIn(
            "ip6tables -w -A DEPLOYDASH6-INPUT -p icmpv6 --icmpv6-type 135 "
            "-m hl --hl-eq 255 -j ACCEPT",
            v6_commands,
        )
        self.assertIn(
            "ip6tables -w -A DEPLOYDASH6-INPUT -p udp -s fe80::/10 "
            "--sport 547 --dport 546 -j ACCEPT",
            v6_commands,
        )
        v4_steps = _preamble_allow_steps(_firewall_spec("ipv4"))
        self.assertEqual(
            v4_steps,
            [
                (
                    "Allow IPv4 echo-request preamble traffic",
                    "iptables -w -A DEPLOYDASH-INPUT -p icmp "
                    "--icmp-type echo-request -m limit --limit 30/minute -j ACCEPT",
                    10,
                )
            ],
        )

    def test_preamble_check_commands_cover_every_preamble_rule(self):
        """Every preamble rule replays through -C, immune to -S normalization."""
        checks = _preamble_check_commands()
        self.assertEqual(len(checks), 15)
        label, command, timeout = checks[0]
        self.assertEqual(label, "Validate IPv4 echo-request preamble")
        self.assertEqual(
            command,
            "iptables -w -C DEPLOYDASH-INPUT -p icmp "
            "--icmp-type echo-request -m limit --limit 30/minute -j ACCEPT",
        )
        self.assertEqual(timeout, 10)
        nd_checks = [c for _, c, _ in checks if "icmpv6-type 135" in c]
        self.assertEqual(
            nd_checks,
            [
                "ip6tables -w -C DEPLOYDASH6-INPUT -p icmpv6 --icmpv6-type 135 "
                "-m hl --hl-eq 255 -j ACCEPT"
            ],
        )
        self.assertTrue(all(t == 10 for _, _, t in checks))

    def test_mld_accepts_require_the_protocol_hop_limit(self):
        """MLD uses hop limit 1, so a 255-only accept can never match it."""
        mld_commands = [
            command
            for _label, command, _timeout in _preamble_check_commands()
            if "icmpv6-type" in command
            and any(
                f"icmpv6-type {message_type}" in command for message_type in (130, 131, 132, 143)
            )
        ]

        self.assertEqual(len(mld_commands), 4)
        self.assertTrue(all("-m hl --hl-eq 1" in command for command in mld_commands))
        self.assertTrue(all("--hl-eq 255" not in command for command in mld_commands))

    def test_unknown_operation_fails_before_connecting(self):
        """An unknown operation is a local validation error, never a host action."""
        ctx = _StubFirewallContext()
        result = run_firewall_runtime_operation(
            ctx,
            "bogus",
            "203.0.113.10",
            "ubuntu",
            raw_data={"settings": {}},
        )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("Unknown firewall runtime operation", result["msg"])
        self.assertEqual(ctx.sessions_opened, 0)
        self.assertIsNone(ctx.last_session)
        self.assertNotIn("firewall_runtime_plan_ready", [n for n, _ in ctx.events])

    def test_unknown_operation_dry_run_fails_during_planning(self):
        """An unknown dry-run operation errors before opening a session."""
        ctx = _StubFirewallContext()
        result = run_firewall_runtime_operation(
            ctx,
            "bogus",
            "203.0.113.10",
            "ubuntu",
            dry_run=True,
            raw_data={"settings": {}},
        )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("Unknown firewall runtime operation", result["msg"])
        self.assertEqual(ctx.sessions_opened, 0)

    def test_cancelled_operation_returns_before_parsing(self):
        """Cancellation wins even over settings that would fail validation."""
        ctx = _StubFirewallContext()
        result = run_firewall_runtime_operation(
            ctx,
            "apply_staged",
            "203.0.113.10",
            "ubuntu",
            raw_data={"settings": {"custom_rules": [{"protocol": "bogus"}]}},
            is_cancelled=lambda: True,
        )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(ctx.sessions_opened, 0)

    def test_apply_stage_refuses_to_omit_the_active_ssh_port(self):
        """A crafted client cannot stage rules that lock out its own SSH session."""
        ctx = _StubFirewallContext()
        result = run_firewall_runtime_operation(
            ctx,
            "apply_staged",
            "203.0.113.10",
            "ubuntu",
            port=2222,
            raw_data={"settings": {"locked_ports": [80, 443]}},
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("active SSH port 2222", result["msg"])
        self.assertEqual(ctx.sessions_opened, 0)


class TestFirewallOpsFlows(unittest.TestCase):
    @patch("engine._open_runtime_session")
    def test_status_reports_timed_rollback_unprotected_marker(
        self,
        mock_open_runtime_session,
    ):
        """A later refresh must surface protection lost by the dead-man timer."""
        result = _run_firewall_request(
            mock_open_runtime_session,
            _UnprotectedMarkerHost(),
            "status",
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["firewall_state"], "unprotected")

    @patch("engine._open_runtime_session")
    def test_staging_and_timer_rollback_never_replace_unmanaged_tables(
        self,
        mock_open_runtime_session,
    ):
        """Rollback must preserve Docker and fail2ban changes made after staging."""
        host = _FirewallHost()

        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "success")
        commands = "\n".join(host.commands)
        self.assertNotIn("iptables-save >", commands)
        self.assertNotIn("ip6tables-save >", commands)
        self.assertNotIn("iptables-restore <", commands)
        self.assertNotIn("ip6tables-restore <", commands)
        self.assertIn("iptables -w -S DEPLOYDASH-INPUT", commands)
        self.assertIn("ip6tables -w -S DEPLOYDASH6-INPUT", commands)

    @patch("engine._open_runtime_session")
    def test_apply_staged_refuses_postgres_without_tls_policy(
        self,
        mock_open_runtime_session,
    ):
        """Direct callers cannot expose a legacy plaintext PostgreSQL service."""
        host = _FailingFirewallHost("test -s /opt/deploydash/stack/postgres/tls/server.crt")

        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertIn("PostgreSQL TLS policy", result["msg"])
        policy_command = _postgres_tls_policy_check_command()
        self.assertIn("TLS_CERTIFICATE_PUBLIC_KEY", policy_command)
        self.assertIn("TLS_PRIVATE_KEY_PUBLIC_KEY", policy_command)
        self.assertIn('test "${TLS_CERTIFICATE_PUBLIC_KEY}" =', policy_command)
        self.assertFalse(any("iptables-save" in command for command in host.commands))

    @patch("engine._open_runtime_session")
    def test_apply_staged_filters_every_non_bridge_docker_interface(
        self,
        mock_open_runtime_session,
    ):
        """Only Docker bridge traffic bypasses rules; every other interface is filtered."""
        host = _FirewallHost()
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "success")
        command_blob = "\n".join(host.commands)
        for chain in ("DEPLOYDASH-DOCKER-USER", "DEPLOYDASH6-DOCKER-USER"):
            with self.subTest(chain=chain):
                self.assertIn(f"-A {chain} -i docker0 -j RETURN", command_blob)
                self.assertIn(f"-A {chain} -i br-+ -j RETURN", command_blob)
                self.assertIn(f"-A {chain} -j DROP", command_blob)
                self.assertIn(f"-C {chain} -i docker0 -j RETURN", command_blob)
                self.assertIn(f"-C {chain} -i br-+ -j RETURN", command_blob)
                self.assertIn(f"-C {chain} -j DROP", command_blob)
        self.assertNotIn("! -i", command_blob)
        docker_allows = [
            command
            for command in host.commands
            if "DOCKER-USER" in command and "--dport" in command and " -A " in command
        ]
        self.assertTrue(docker_allows)
        self.assertTrue(all(" -i " not in command for command in docker_allows))

    def test_apply_stage_enforces_active_ssh_port_at_internal_boundary(self):
        """The staging seam remains safe even when called outside request parsing."""
        result = _apply_staged_firewall(
            _StubFirewallContext(),
            _FirewallHost(),
            _parse_firewall_settings({"locked_ports": [80, 443]}),
            active_ssh_port=2222,
        )

        self.assertEqual(result["status"], "error")
        self.assertIn("active SSH port 2222", result["msg"])

    def test_ssh_port_stage_handles_managed_firewall_states(self):
        """SSH transitions proceed only when both firewall families share ownership."""
        ctx = _StubFirewallContext()
        pending = _FirewallHost(
            staged_state={
                "token": "fw-live",
                "expires_at": "2026-03-14T10:00:00+00:00",
                "snapshot_v4": "/tmp/snap.v4",
                "snapshot_v6": "/tmp/snap.v6",
            }
        )
        unmanaged = _FailingFirewallHost(" -w -C INPUT -j ")
        partial = _FailingFirewallHost("iptables -w -C INPUT -j")

        pending_result = _stage_ssh_port_firewall(ctx, pending, 22, 2222)
        unmanaged_result = _stage_ssh_port_firewall(ctx, unmanaged, 22, 2222)
        partial_result = _stage_ssh_port_firewall(ctx, partial, 22, 2222)

        self.assertEqual(pending_result["status"], "error")
        self.assertIn("already pending", pending_result["msg"])
        self.assertEqual(
            unmanaged_result,
            {"status": "success", "managed": False, "stage_token": None},
        )
        self.assertEqual(partial_result["status"], "error")
        self.assertIn("only active for one address family", partial_result["msg"])

    @patch("orchestrator.engine_firewall_ops.secrets.token_hex", return_value="fixed")
    def test_ssh_port_stage_adds_both_families_and_safety_timer(self, _mock_token_hex):
        """A managed transition keeps both ports open behind a timed rollback."""
        ctx = _StubFirewallContext()
        host = _FirewallHost()

        result = _stage_ssh_port_firewall(ctx, host, 22, 2222)

        self.assertEqual(
            result,
            {
                "status": "success",
                "managed": True,
                "stage_token": "ssh-port-fixed",
                "current_port": 22,
                "target_port": 2222,
            },
        )
        self.assertTrue(
            any("iptables -w -S DEPLOYDASH-INPUT" in command for command in host.commands)
        )
        self.assertTrue(any("--dport 2222" in command for command in host.commands))
        self.assertTrue(
            any(
                "DEPLOYDASH-DOCKER-USER" in command and "--dport 2222" in command
                for command in host.commands
            )
        )
        self.assertFalse(
            any(
                "DEPLOYDASH-DOCKER-USER" in command
                and "--dport 2222" in command
                and " -i " in command
                for command in host.commands
            )
        )
        self.assertTrue(any("mktemp" in command for command in host.commands))

    def test_ssh_port_stage_reports_each_preparation_failure_safely(self):
        """Early failures avoid restore while live-rule failures restore snapshots."""
        ctx = _StubFirewallContext()
        cases = (
            ("mkdir -p ", "Prepare firewall workspace", False),
            ("umask 077", "Snapshot managed firewall", False),
            ("iptables -w -C DEPLOYDASH-INPUT", "Temporarily allow", True),
            ("ip6tables -w -C DEPLOYDASH6-INPUT", "Temporarily allow", True),
        )

        for fragment, expected_message, expects_restore in cases:
            with self.subTest(fragment=fragment):
                host = _FailingFirewallHost(fragment)
                result = _stage_ssh_port_firewall(ctx, host, 22, 2222)

                self.assertEqual(result["status"], "error")
                self.assertIn(expected_message, result["msg"])
                self.assertEqual(
                    bool(_snapshot_restore_commands(host)),
                    expects_restore,
                )

    def test_ssh_port_stage_reports_persistence_failures(self):
        """A transition is rejected if its state or rollback timer cannot persist."""
        ctx = _StubFirewallContext()
        for fragment, expected_message in (
            ('cat > "${STAGE_FILE}" <<EOF', "Persist staged firewall state failed."),
            ("mktemp", "Schedule rollback safety timer failed."),
        ):
            with self.subTest(fragment=fragment):
                host = _FailingFirewallHost(fragment)
                result = _stage_ssh_port_firewall(ctx, host, 22, 2222)

                self.assertEqual(result["status"], "error")
                self.assertIn(expected_message, result["msg"])
                self.assertTrue(_snapshot_restore_commands(host))

    def test_ssh_port_transition_does_not_depend_on_external_interface_detection(self):
        """Temporary SSH rules remain safe when route-based status detection fails."""
        ctx = _StubFirewallContext()
        staged_state = {
            "token": "ssh-port-live",
            "expires_at": "2026-03-14T10:00:00+00:00",
            "snapshot_v4": "/tmp/snap.v4",
            "snapshot_v6": "/tmp/snap.v6",
        }
        stage_result = _stage_ssh_port_firewall(
            ctx,
            _FailingFirewallHost("ip route get"),
            22,
            2222,
        )
        commit_result = _commit_ssh_port_firewall(
            ctx,
            _FailingFirewallHost("ip route get", staged_state=staged_state),
            stage_token="ssh-port-live",
            current_port=22,
            target_port=2222,
        )

        self.assertEqual(stage_result["status"], "success")
        self.assertEqual(commit_result["status"], "success")
        self.assertIsNone(commit_result["external_interface"])

    def test_ssh_port_commit_handles_absent_and_vanished_stages(self):
        """No-op firewalls succeed while lost managed stages fail closed."""
        ctx = _StubFirewallContext()
        no_stage = _commit_ssh_port_firewall(
            ctx,
            _FirewallHost(),
            stage_token=None,
            current_port=22,
            target_port=2222,
        )
        vanished = _commit_ssh_port_firewall(
            ctx,
            _FirewallHost(),
            stage_token="ssh-port-lost",
            current_port=22,
            target_port=2222,
        )
        mismatched = _commit_ssh_port_firewall(
            ctx,
            _FirewallHost(
                staged_state={
                    "token": "ssh-port-other",
                    "expires_at": "2026-03-14T10:00:00+00:00",
                    "snapshot_v4": "/tmp/snap.v4",
                    "snapshot_v6": "/tmp/snap.v6",
                }
            ),
            stage_token="ssh-port-live",
            current_port=22,
            target_port=2222,
        )

        self.assertEqual(no_stage, {"status": "success", "managed": False})
        self.assertEqual(vanished["status"], "error")
        self.assertEqual(mismatched["status"], "error")

    def test_ssh_port_commit_removes_only_non_web_old_ports(self):
        """Commit closes the retired SSH port without removing fixed web access."""
        ctx = _StubFirewallContext()
        for current_port, expects_removal in ((22, True), (80, False)):
            with self.subTest(current_port=current_port):
                token = f"ssh-port-{current_port}"
                host = _FirewallHost(
                    staged_state={
                        "token": token,
                        "expires_at": "2026-03-14T10:00:00+00:00",
                        "snapshot_v4": "/tmp/snap.v4",
                        "snapshot_v6": "/tmp/snap.v6",
                    }
                )
                result = _commit_ssh_port_firewall(
                    ctx,
                    host,
                    stage_token=token,
                    current_port=current_port,
                    target_port=2222,
                )

                self.assertEqual(result["status"], "success")
                self.assertEqual(
                    any(
                        f"--dport {current_port}" in command and " -D " in command
                        for command in host.commands
                    ),
                    expects_removal,
                )
                self.assertEqual(
                    any(
                        "DEPLOYDASH-DOCKER-USER" in command
                        and f"--dport {current_port}" in command
                        and " -D " in command
                        for command in host.commands
                    ),
                    expects_removal,
                )
                self.assertTrue(any("--dport 2222" in command for command in host.commands))

    def test_ssh_port_commit_reports_rule_removal_and_verification_failures(self):
        """A failed old-port removal or new-port proof leaves the stage uncommitted."""
        ctx = _StubFirewallContext()
        state = {
            "token": "ssh-port-live",
            "expires_at": "2026-03-14T10:00:00+00:00",
            "snapshot_v4": "/tmp/snap.v4",
            "snapshot_v6": "/tmp/snap.v6",
        }
        cases = (
            ("while iptables", "Remove old SSH port"),
            ("--dport 2222", "Verify new SSH port"),
        )

        for fragment, expected_message in cases:
            with self.subTest(fragment=fragment):
                host = _FailingFirewallHost(fragment, staged_state=state)
                result = _commit_ssh_port_firewall(
                    ctx,
                    host,
                    stage_token="ssh-port-live",
                    current_port=22,
                    target_port=2222,
                )

                self.assertEqual(result["status"], "error")
                self.assertIn(expected_message, result["msg"])

    @patch("engine._open_runtime_session")
    def test_apply_staged_rejects_when_a_stage_is_pending(self, mock_open_runtime_session):
        """A second stage cannot start before the first commits or rolls back."""
        host = _FirewallHost(
            staged_state={
                "token": "fw-live",
                "expires_at": "2026-03-14T10:00:00+00:00",
                "snapshot_v4": "/tmp/snap.v4",
                "snapshot_v6": "/tmp/snap.v6",
            }
        )
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("already pending", result["msg"])

    @patch("engine._open_runtime_session")
    def test_apply_staged_ignores_interface_detection_failure(self, mock_open_runtime_session):
        """Route detection is status-only and cannot weaken or block firewall staging."""
        host = _FailingFirewallHost("ip route get")
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "success")
        self.assertIsNone(result["external_interface"])

    @patch("engine._open_runtime_session")
    def test_apply_staged_treats_blank_interface_as_status_only(self, mock_open_runtime_session):
        """Blank route answers do not affect the interface-independent policy."""
        for lines in ([], ["SOMETHING_ELSE=1"], ["IFACE="], ["IFACE=   "]):
            with self.subTest(lines=lines):
                host = _IfaceScriptedHost(lines)
                result = _run_apply_staged(mock_open_runtime_session, host)

                self.assertEqual(result["status"], "success")
                self.assertIsNone(result["external_interface"])

    @patch("engine._open_runtime_session")
    def test_apply_staged_restores_snapshot_when_late_setup_step_fails(
        self, mock_open_runtime_session
    ):
        """Once live chains change, a failed step restores the snapshot."""
        host = _FailingLiveFirewallHost("ip6tables -w -N DEPLOYDASH6-INPUT")
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Create managed IPv6 INPUT chain failed.", result["msg"])
        self.assertTrue(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_apply_staged_skips_restore_when_early_setup_step_fails(
        self, mock_open_runtime_session
    ):
        """Before live chains change, there is nothing to restore."""
        host = _FailingFirewallHost("mkdir -p ")
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertIn("Prepare firewall workspace failed.", result["msg"])
        self.assertFalse(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_apply_staged_restores_when_host_allow_fails(self, mock_open_runtime_session):
        """A failed host allow leaves the pre-stage rules in place."""
        host = _FailingFirewallHost("--dport 22")
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertIn("Allow IPv4 host tcp:22 failed.", result["msg"])
        self.assertTrue(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_apply_staged_reports_unprotected_after_replacing_active_ufw(
        self,
        mock_open_runtime_session,
    ):
        """A post-replacement failure must identify the lost firewall protection."""
        host = _UfwActiveFailingFirewallHost("--dport 22")

        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["firewall_state"], "unprotected")
        self.assertIn("currently has no active firewall", result["msg"])
        self.assertTrue(
            any("touch" in command and "unprotected" in command for command in host.commands),
        )

    @patch("engine._open_runtime_session")
    def test_apply_staged_restores_when_docker_allow_fails(self, mock_open_runtime_session):
        """A failed Docker-ingress allow leaves the pre-stage rules in place."""
        host = _FailingFirewallHost("-A DEPLOYDASH-DOCKER-USER -p tcp")
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertIn("Allow IPv4 Docker ingress tcp:22 failed.", result["msg"])
        self.assertTrue(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_apply_staged_restores_when_bridge_policy_validation_fails(
        self,
        mock_open_runtime_session,
    ):
        """A missing bridge bypass fails validation and restores both snapshots."""
        host = _FailingFirewallHost("-C DEPLOYDASH6-DOCKER-USER -i br-+")
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertIn("Validate IPv6 Docker bridge br-+ bypass failed.", result["msg"])
        self.assertTrue(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_apply_staged_restores_when_docker_fallback_validation_fails(
        self,
        mock_open_runtime_session,
    ):
        """A missing interface-independent fallback cannot be committed."""
        host = _FailingFirewallHost("-C DEPLOYDASH-DOCKER-USER -j DROP")
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertIn("Validate IPv4 Docker ingress fallback drop failed.", result["msg"])
        self.assertTrue(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_apply_staged_without_strict_mode_skips_fallback_drop(self, mock_open_runtime_session):
        """Non-strict stages return unmatched Docker traffic instead of dropping."""
        host = _FirewallHost()
        result = _run_apply_staged(
            mock_open_runtime_session,
            host,
            settings={"strict_mode": False, "allow_postgres": False},
        )

        self.assertEqual(result["status"], "success")
        self.assertFalse(any("-j DROP" in command for command in host.commands))
        self.assertTrue(
            any("-A DEPLOYDASH-DOCKER-USER -j RETURN" in command for command in host.commands)
        )

    @patch("engine._open_runtime_session")
    def test_apply_staged_restores_when_strict_drop_fails(self, mock_open_runtime_session):
        """A failed fallback deny restores rather than leaving chains half-set."""
        host = _FailingFirewallHost("-j DROP")
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertIn("Apply strict IPv4 host fallback deny failed.", result["msg"])
        self.assertTrue(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_apply_staged_restores_when_finalize_return_fails(self, mock_open_runtime_session):
        """A failed finalize step restores the pre-stage rules."""
        host = _FailingFirewallHost("-A DEPLOYDASH-DOCKER-USER -j RETURN")
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertIn("Return unmatched IPv4 Docker-forwarded traffic failed.", result["msg"])
        self.assertTrue(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_apply_staged_restores_when_locked_check_fails(self, mock_open_runtime_session):
        """A missing locked port fails validation and restores the snapshot."""
        host = _FailingFirewallHost("-C DEPLOYDASH-INPUT -p tcp -m tcp --dport 22")
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertIn("Validate IPv4 host tcp:22 failed.", result["msg"])
        self.assertTrue(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_apply_staged_restores_when_docker_ingress_check_fails(self, mock_open_runtime_session):
        """A missing Docker-ingress allow fails validation and restores."""
        host = _FailingFirewallHost("-C DEPLOYDASH-DOCKER-USER -p tcp -m tcp --dport 22")
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertIn("Validate IPv4 Docker ingress tcp:22 failed.", result["msg"])
        self.assertTrue(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_apply_staged_restores_when_preamble_check_fails(self, mock_open_runtime_session):
        """A missing ICMP preamble fails validation and restores the snapshot."""
        host = _FailingFirewallHost("-C DEPLOYDASH6-INPUT -p icmpv6 --icmpv6-type 135")
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertIn("Validate IPv6 neighbour-solicitation preamble failed.", result["msg"])
        self.assertTrue(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_preamble_failure_reports_unprotected_after_replacing_active_ufw(
        self,
        mock_open_runtime_session,
    ):
        """Every post-UFW validation failure must persist the protection warning."""
        host = _UfwActiveFailingFirewallHost(
            "-C DEPLOYDASH6-INPUT -p icmpv6 --icmpv6-type 135",
        )

        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["firewall_state"], "unprotected")
        self.assertIn("currently has no active firewall", result["msg"])
        self.assertTrue(
            any("touch" in command and "unprotected" in command for command in host.commands),
        )

    @patch("engine._open_runtime_session")
    def test_apply_staged_restores_when_state_persist_fails(self, mock_open_runtime_session):
        """An unpersisted stage cannot be committed later, so it is restored."""
        host = _FailingFirewallHost('cat > "${STAGE_FILE}" <<EOF')
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertIn("Persist staged firewall state failed.", result["msg"])
        self.assertTrue(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_apply_staged_restores_when_rollback_timer_fails(self, mock_open_runtime_session):
        """A stage without its safety timer is restored, not left to linger."""
        host = _FailingFirewallHost("mktemp")
        result = _run_apply_staged(mock_open_runtime_session, host)

        self.assertEqual(result["status"], "error")
        self.assertIn("Schedule rollback safety timer failed.", result["msg"])
        self.assertTrue(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_apply_staged_rejects_invalid_custom_rule(self, mock_open_runtime_session):
        """A malformed custom rule fails validation before touching the server."""
        host = _FirewallHost()
        result = _run_apply_staged(
            mock_open_runtime_session,
            host,
            settings={
                "custom_rules": [
                    {
                        "protocol": "tcp",
                        "port_start": 9000,
                        "port_end": 8000,
                    }
                ]
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("port_end must be greater than or equal", result["msg"])
        self.assertEqual(host.commands, [])

    @patch("engine._open_runtime_session")
    def test_source_restricted_custom_rule_scopes_both_chains(self, mock_open_runtime_session):
        """A source CIDR restricts the host allow and the Docker-ingress allow."""
        host = _FirewallHost()
        result = _run_apply_staged(
            mock_open_runtime_session,
            host,
            settings={
                "strict_mode": True,
                "custom_rules": [
                    {
                        "id": "v4-office",
                        "protocol": "tcp",
                        "port_start": 8443,
                        "port_end": 8443,
                        "source_cidr": "203.0.113.0/24",
                    },
                    {
                        "id": "v6-office",
                        "protocol": "udp",
                        "port_start": 9443,
                        "port_end": 9443,
                        "source_cidr": "2001:db8::/64",
                    },
                ],
            },
        )

        self.assertEqual(result["status"], "success")
        self.assertTrue(
            any(
                "-A DEPLOYDASH-INPUT" in command
                and "--dport 8443" in command
                and "-s 203.0.113.0/24" in command
                for command in host.commands
            )
        )
        self.assertTrue(
            any(
                "-A DEPLOYDASH-DOCKER-USER" in command
                and "--dport 8443" in command
                and "-s 203.0.113.0/24" in command
                for command in host.commands
            )
        )
        self.assertTrue(
            any(
                "-A DEPLOYDASH6-INPUT" in command
                and "--dport 9443" in command
                and "-s 2001:db8::/64" in command
                for command in host.commands
            )
        )

    @patch("engine._open_runtime_session")
    def test_commit_reports_no_pending_stage_without_token(self, mock_open_runtime_session):
        """Committing with nothing staged succeeds without changing rules."""
        host = _FirewallHost()
        result = _run_firewall_request(mock_open_runtime_session, host, "commit", settings={})

        self.assertEqual(result["status"], "success")
        self.assertIn("No staged firewall changes were pending.", result["msg"])
        self.assertFalse(
            any("iptables-save > /etc/iptables" in command for command in host.commands)
        )

    @patch("engine._open_runtime_session")
    def test_commit_rejects_mismatched_stage_token(self, mock_open_runtime_session):
        """A commit for a different stage cannot confirm these rules."""
        host = _FirewallHost(
            staged_state={
                "token": "fw-live",
                "expires_at": "2026-03-14T10:00:00+00:00",
                "snapshot_v4": "/tmp/snap.v4",
                "snapshot_v6": "/tmp/snap.v6",
            }
        )
        result = _run_firewall_request(
            mock_open_runtime_session,
            host,
            "commit",
            settings={"stage_token": "fw-other"},
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("does not match", result["msg"])

    @patch("engine._open_runtime_session")
    def test_commit_reports_failed_persist(self, mock_open_runtime_session):
        """A commit that cannot persist rules reports the failure loudly."""
        host = _FailingFirewallHost(
            "netfilter-persistent save",
            staged_state={
                "token": "fw-live",
                "expires_at": "2026-03-14T10:00:00+00:00",
                "snapshot_v4": "/tmp/snap.v4",
                "snapshot_v6": "/tmp/snap.v6",
            },
        )
        result = _run_firewall_request(
            mock_open_runtime_session,
            host,
            "commit",
            settings={"stage_token": "fw-live"},
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Failed to commit staged firewall changes.", result["msg"])

    @patch("engine._open_runtime_session")
    def test_rollback_reports_no_pending_stage(self, mock_open_runtime_session):
        """Rolling back with nothing staged succeeds without touching rules."""
        host = _FirewallHost()
        result = _run_firewall_request(mock_open_runtime_session, host, "rollback", settings={})

        self.assertEqual(result["status"], "success")
        self.assertIn("No staged firewall changes were pending.", result["msg"])
        self.assertFalse(_snapshot_restore_commands(host))

    @patch("engine._open_runtime_session")
    def test_rollback_rejects_mismatched_stage_token(self, mock_open_runtime_session):
        """A rollback for a different stage cannot discard these rules."""
        host = _FirewallHost(
            staged_state={
                "token": "fw-live",
                "expires_at": "2026-03-14T10:00:00+00:00",
                "snapshot_v4": "/tmp/snap.v4",
                "snapshot_v6": "/tmp/snap.v6",
            }
        )
        result = _run_firewall_request(
            mock_open_runtime_session,
            host,
            "rollback",
            settings={"stage_token": "fw-other"},
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("does not match", result["msg"])

    @patch("engine._open_runtime_session")
    def test_rollback_restores_snapshots_and_clears_state(self, mock_open_runtime_session):
        """Rollback reinstates both snapshots and clears the staged state."""
        host = _FirewallHost(
            staged_state={
                "token": "fw-live",
                "expires_at": "2026-03-14T10:00:00+00:00",
                "snapshot_v4": "/tmp/snap.v4",
                "snapshot_v6": "/tmp/snap.v6",
            }
        )
        result = _run_firewall_request(
            mock_open_runtime_session,
            host,
            "rollback",
            settings={"stage_token": "fw-live"},
        )

        self.assertEqual(result["status"], "success")
        self.assertIn("rolled back", result["msg"])
        restore_commands = _snapshot_restore_commands(host)
        self.assertEqual(len(restore_commands), 2)
        self.assertTrue(any("/tmp/snap.v4" in command for command in restore_commands))
        self.assertTrue(any("/tmp/snap.v6" in command for command in restore_commands))
        self.assertTrue(any('rm -f "${STAGE_FILE}"' in command for command in host.commands))

    @patch("engine._open_runtime_session")
    def test_rollback_reports_unprotected_after_replacing_active_ufw(
        self,
        mock_open_runtime_session,
    ):
        """Rollback must warn when its pre-stage protection belonged to removed UFW."""
        host = _FirewallHost(
            staged_state={
                "token": "fw-ufw",
                "expires_at": "2026-03-14T10:00:00+00:00",
                "snapshot_v4": "/tmp/snap.v4",
                "snapshot_v6": "/tmp/snap.v6",
                "ufw_active_before": True,
            },
        )

        result = _run_firewall_request(
            mock_open_runtime_session,
            host,
            "rollback",
            settings={"stage_token": "fw-ufw"},
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["firewall_state"], "unprotected")
        self.assertIn("currently has no active firewall", result["msg"])

    @patch("engine._open_runtime_session")
    def test_rollback_partial_snapshot_skips_missing_family(self, mock_open_runtime_session):
        """A stage without an IPv6 snapshot still rolls IPv4 back."""
        host = _PartialStageHost()
        result = _run_firewall_request(
            mock_open_runtime_session,
            host,
            "rollback",
            settings={"stage_token": "fw-partial"},
        )

        self.assertEqual(result["status"], "success")
        restore_commands = _snapshot_restore_commands(host)
        self.assertEqual(len(restore_commands), 1)
        self.assertIn("/tmp/snap.v4", restore_commands[0])

    @patch("engine._open_runtime_session")
    def test_rollback_reports_failed_snapshot_restore(self, mock_open_runtime_session):
        """A rollback that cannot restore reports the failure loudly."""
        host = _FailingFirewallHost(
            'sh -eu "${SNAPSHOT}"',
            staged_state={
                "token": "fw-live",
                "expires_at": "2026-03-14T10:00:00+00:00",
                "snapshot_v4": "/tmp/snap.v4",
                "snapshot_v6": "/tmp/snap.v6",
            },
        )
        result = _run_firewall_request(
            mock_open_runtime_session,
            host,
            "rollback",
            settings={"stage_token": "fw-live"},
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Failed to restore firewall snapshot.", result["msg"])

    @patch("engine._open_runtime_session")
    def test_scan_open_ports_tolerates_malformed_listings(self, mock_open_runtime_session):
        """Malformed listener rows are skipped; good rows parse exactly."""
        host = _ScanScriptedHost(
            ss_lines=[
                12345,
                "tcp",
                "unix a b c d",
                "tcp LISTEN 0 128 * 0.0.0.0:*",
                "tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*",
                'tcp LISTEN 0 128 [::]:80 [::]:* users:(("caddy",pid=9,fd=7))',
                "tcp LISTEN 0 128 :8080 0.0.0.0:*",
            ],
            docker_lines=[
                "no-tab-line",
                "c1\t0.0.0.0:90->90/tcp",
                "c1\t0.0.0.0:90->90/tcp",
                "c2\tunmapped",
                "c3\t0.0.0.0:91->91/sctp",
                "c4\t:92->92/tcp",
                "c5\tnocolon->x/tcp",
            ],
        )
        result = _run_firewall_request(
            mock_open_runtime_session, host, "scan_open_ports", settings={}
        )

        self.assertEqual(result["status"], "success")
        ports = result["open_ports"]
        by_port = {item["port"]: item for item in ports}
        self.assertEqual(by_port["22"]["details"], "-")
        self.assertEqual(by_port["80"]["bind"], "::")
        self.assertIn("caddy", by_port["80"]["details"])
        self.assertEqual(by_port["8080"]["bind"], "*")
        self.assertEqual(
            [item for item in ports if item["port"] == "90"],
            [
                {
                    "source": "docker_published",
                    "protocol": "tcp",
                    "port": "90",
                    "bind": "0.0.0.0",
                    "details": "c1 (0.0.0.0:90->90/tcp)",
                }
            ],
        )
        self.assertNotIn("91", by_port)
        self.assertEqual(by_port["92"]["bind"], "*")

    @patch("engine._open_runtime_session")
    def test_scan_open_ports_without_ss_output_uses_docker_only(self, mock_open_runtime_session):
        """When ss fails, Docker-published ports still inventory."""
        host = _FailingFirewallHost("ss -H")
        result = _run_firewall_request(
            mock_open_runtime_session, host, "scan_open_ports", settings={}
        )

        self.assertEqual(result["status"], "success")
        self.assertTrue(len(result["open_ports"]) > 0)
        self.assertTrue(all(item["source"] == "docker_published" for item in result["open_ports"]))

    @patch("engine._open_runtime_session")
    def test_scan_open_ports_without_docker_output_uses_host_only(self, mock_open_runtime_session):
        """When docker fails, host listeners still inventory."""
        host = _FailingFirewallHost("docker ps")
        result = _run_firewall_request(
            mock_open_runtime_session, host, "scan_open_ports", settings={}
        )

        self.assertEqual(result["status"], "success")
        self.assertTrue(len(result["open_ports"]) > 0)
        self.assertTrue(all(item["source"] == "host_listener" for item in result["open_ports"]))

    @patch("engine._open_runtime_session")
    def test_status_reports_disconnect_warning_without_failing(self, mock_open_runtime_session):
        """A noisy disconnect surfaces as a warning on an otherwise good status."""
        host = _FirewallHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _NoisyDisconnectSession(host),
        }
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "firewall",
                "operation_id": "status",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {"dry_run": False, "settings": {}},
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "status")

    @patch("engine._open_runtime_session")
    def test_session_open_failure_returns_open_error(self, mock_open_runtime_session):
        """A refused session surfaces the opener's error unchanged."""
        mock_open_runtime_session.return_value = {
            "ok": False,
            "error": {
                "status": "error",
                "code": "ENGINE_CONNECTION_ERROR",
                "msg": "refused",
            },
        }
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "firewall",
                "operation_id": "status",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {"dry_run": False, "settings": {}},
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_CONNECTION_ERROR")


if __name__ == "__main__":
    unittest.main()
