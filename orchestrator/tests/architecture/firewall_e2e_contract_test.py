import re
import unittest
from pathlib import Path

from orchestrator.engine_firewall_ops import _preamble_check_commands

_APP_ROOT = Path(__file__).resolve().parents[3]
_FIREWALL_E2E = _APP_ROOT / "ui/integration_test/journeys/firewall_recovery.dart"


class TestFirewallE2eContract(unittest.TestCase):
    def test_e2e_preamble_matches_the_python_rule_owner(self):
        """The live proof cannot silently drift from the production rule owner."""
        source = _FIREWALL_E2E.read_text(encoding="utf-8")
        start = source.index("Future<void> _verifyIcmpPreamble()")
        end = source.index("Future<void> _verifyIpv6Traffic()", start)
        actual_matches = re.findall(r"'(-p [^']+)'", source[start:end])
        expected_matches = []
        for _label, command, _timeout in _preamble_check_commands():
            chain_marker = "DEPLOYDASH6-INPUT " if "ip6tables" in command else "DEPLOYDASH-INPUT "
            expected_matches.append(
                command.split(chain_marker, 1)[1].rsplit(" -j ACCEPT", 1)[0],
            )

        self.assertEqual(actual_matches, expected_matches)

    def test_ipv6_live_proof_never_records_a_missing_route_as_passed(self):
        """A non-dual-stack target must fail rather than certify untested IPv6."""
        source = _FIREWALL_E2E.read_text(encoding="utf-8")
        start = source.index("Future<void> _verifyIpv6Traffic()")
        end = source.index("Future<void> _verifyFirewallPort", start)
        block = source[start:end]

        self.assertIn("fail(", block)
        self.assertNotIn("gateway traffic skipped", block)
        self.assertIn("DEPLOYDASH_E2E_IPV6_SITE_URL", block)
        self.assertIn("'--ipv6'", block)


if __name__ == "__main__":
    unittest.main()
