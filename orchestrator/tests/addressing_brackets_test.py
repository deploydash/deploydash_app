import ipaddress
import socket
import unittest
from unittest.mock import patch

from orchestrator.addressing import (
    format_host,
    format_url_host,
    normalize_host,
    parse_ip_literal,
)
from orchestrator.http_parts.http_config import (
    HttpConfigValidationError,
    _optional_ip_or_hostname,
)


def _http(value):
    # Why: pins site 4's exact outputs; DNS is forced to fail so hostname
    # tails are deterministic without network access.
    with patch(
        "orchestrator.http_parts.http_config.socket.getaddrinfo",
        side_effect=socket.gaierror(),
    ):
        return _optional_ip_or_hostname(value, "server.host")


class TestBracketStripMatrix(unittest.TestCase):
    def test_empty_brackets_yield_per_site_empty_tails(self):
        self.assertIsNone(parse_ip_literal("[]"))
        self.assertEqual(format_host("[]"), "")
        self.assertIsNone(normalize_host("[]"))
        self.assertIsNone(_http("[]"))

    def test_bracketed_ipv6_strips_then_parses(self):
        self.assertEqual(parse_ip_literal("[::1]"), ipaddress.ip_address("::1"))
        self.assertEqual(format_host("[::1]"), "[::1]")
        self.assertEqual(normalize_host("[::1]"), "::1")
        self.assertEqual(_http("[::1]"), "::1")

    def test_double_brackets_strip_one_layer_only(self):
        self.assertIsNone(parse_ip_literal("[[a]]"))
        self.assertEqual(format_host("[[a]]"), "[a]")
        self.assertEqual(normalize_host("[[a]]"), "[a]")
        with self.assertRaises(HttpConfigValidationError):
            _http("[[a]]")

    def test_half_brackets_are_left_untouched(self):
        for value in ("[x", "x]", "[", "]"):
            self.assertIsNone(parse_ip_literal(value))
            self.assertEqual(format_host(value), value)
            self.assertEqual(normalize_host(value), value)
            with self.assertRaises(HttpConfigValidationError):
                _http(value)

    def test_whitespace_padded_brackets_strip(self):
        self.assertEqual(
            parse_ip_literal("  [2001:db8::1]  "),
            ipaddress.ip_address("2001:db8::1"),
        )
        self.assertEqual(format_host("  [::1]  "), "[::1]")
        self.assertEqual(normalize_host("\t[::1]\n"), "::1")
        self.assertEqual(_http("  [::1]  "), "::1")

    def test_inner_whitespace_is_trimmed_after_strip(self):
        self.assertEqual(parse_ip_literal("[  ::1  ]"), ipaddress.ip_address("::1"))
        self.assertEqual(format_host("[  ::1  ]"), "[::1]")
        self.assertEqual(normalize_host("[  ::1  ]"), "::1")
        self.assertEqual(_http("[  ::1  ]"), "::1")

    def test_none_keeps_per_site_divergence(self):
        self.assertIsNone(parse_ip_literal(None))
        self.assertEqual(format_host(None), "")
        self.assertIsNone(normalize_host(None))
        self.assertIsNone(_http(None))

    def test_non_string_inputs_coerce_before_strip(self):
        self.assertIsNone(parse_ip_literal(12345))
        self.assertEqual(format_host(12345), "12345")
        self.assertEqual(normalize_host(12345), "12345")
        with self.assertRaises(HttpConfigValidationError):
            _http(12345)

    def test_plain_hostnames_pass_through_addressing(self):
        self.assertIsNone(parse_ip_literal("edge.example.com"))
        self.assertEqual(format_host("edge.example.com"), "edge.example.com")
        self.assertEqual(normalize_host("edge.example.com"), "edge.example.com")

    def test_format_url_host_matches_format_host_exactly(self):
        for value in (None, "", "[]", "[::1]", "[[a]]", "[x", "edge.example.com"):
            self.assertEqual(format_url_host(value), format_host(value))


if __name__ == "__main__":
    unittest.main()
