import ipaddress
import unittest

from orchestrator.addressing import (
    format_host,
    format_host_port,
    format_url_host,
    is_ipv6_literal,
    normalize_host,
    parse_ip_literal,
)


class TestParseIpLiteral(unittest.TestCase):
    def test_returns_none_for_none(self):
        self.assertIsNone(parse_ip_literal(None))

    def test_returns_none_for_empty_string(self):
        self.assertIsNone(parse_ip_literal(""))

    def test_returns_none_for_non_ip_string(self):
        self.assertIsNone(parse_ip_literal("edge.example.com"))

    def test_parses_ipv4_literal(self):
        self.assertEqual(parse_ip_literal("203.0.113.10"), ipaddress.ip_address("203.0.113.10"))

    def test_strips_brackets_around_ipv6_literal(self):
        self.assertEqual(
            parse_ip_literal("[2001:db8::1]"),
            ipaddress.ip_address("2001:db8::1"),
        )


class TestIsIpv6Literal(unittest.TestCase):
    def test_true_for_ipv6_address(self):
        self.assertTrue(is_ipv6_literal("2001:db8::1"))

    def test_false_for_ipv4_address(self):
        self.assertFalse(is_ipv6_literal("203.0.113.10"))

    def test_false_for_non_ip_value(self):
        self.assertFalse(is_ipv6_literal("edge.example.com"))


class TestFormatHost(unittest.TestCase):
    def test_returns_empty_string_for_none(self):
        self.assertEqual(format_host(None), "")

    def test_returns_empty_string_for_blank_value(self):
        self.assertEqual(format_host("   "), "")

    def test_passes_through_hostname(self):
        self.assertEqual(format_host("edge.example.com"), "edge.example.com")

    def test_passes_through_ipv4_literal(self):
        self.assertEqual(format_host("203.0.113.10"), "203.0.113.10")

    def test_brackets_ipv6_literal(self):
        self.assertEqual(format_host("2001:db8::1"), "[2001:db8::1]")

    def test_normalizes_already_bracketed_ipv6_literal(self):
        self.assertEqual(format_host("[2001:db8::1]"), "[2001:db8::1]")


class TestFormatUrlHost(unittest.TestCase):
    def test_delegates_to_format_host(self):
        self.assertEqual(format_url_host("2001:db8::1"), "[2001:db8::1]")


class TestFormatHostPort(unittest.TestCase):
    def test_omits_port_when_none(self):
        self.assertEqual(format_host_port("edge.example.com", None), "edge.example.com")

    def test_appends_int_port(self):
        self.assertEqual(format_host_port("edge.example.com", 22), "edge.example.com:22")

    def test_appends_string_port(self):
        self.assertEqual(format_host_port("edge.example.com", "22"), "edge.example.com:22")

    def test_brackets_ipv6_host_with_port(self):
        self.assertEqual(format_host_port("2001:db8::1", 22), "[2001:db8::1]:22")


class TestNormalizeHost(unittest.TestCase):
    def test_returns_none_for_none(self):
        self.assertIsNone(normalize_host(None))

    def test_returns_none_for_blank_value(self):
        self.assertIsNone(normalize_host("   "))

    def test_normalizes_bracketed_ipv6_literal_to_canonical_form(self):
        self.assertEqual(normalize_host("[2001:0db8::0001]"), "2001:db8::1")

    def test_normalizes_ipv4_literal(self):
        self.assertEqual(normalize_host("203.0.113.10"), "203.0.113.10")

    def test_passes_through_hostname_unchanged(self):
        self.assertEqual(normalize_host("Edge.Example.com"), "Edge.Example.com")


if __name__ == "__main__":
    unittest.main()
