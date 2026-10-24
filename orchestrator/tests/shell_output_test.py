"""Contract tests for the `KEY=value` shell-output protocol.

Written before `orchestrator.shell_output` existed (T-3.8.6, discipline D1).

The protocol is what managed servers speak back: a remote command emits
`printf "KEY=%s\\n"` lines and the backend reads them. It was parsed in
fifteen places under four names and eleven anonymous inline loops, and the
implementations disagreed about every edge case below -- which is the reason
this file states each one literally rather than trusting any of them.
"""

import unittest
from types import SimpleNamespace

from orchestrator import shell_output


def _output(lines):
    return SimpleNamespace(stdout_lines=lines)


class TestSplitKeyValue(unittest.TestCase):
    def test_splits_on_the_first_separator_only(self):
        # A value may contain '='; a base64 blob or a connection string will.
        self.assertEqual(
            shell_output.split_key_value("DATABASE_URL=postgres://u:p@h/db?a=b"),
            ("DATABASE_URL", "postgres://u:p@h/db?a=b"),
        )

    def test_strips_whitespace_from_both_sides(self):
        self.assertEqual(shell_output.split_key_value("  key  =  value  "), ("key", "value"))

    def test_returns_none_for_a_line_without_a_separator(self):
        # Eleven of the fifteen inline loops raised ValueError here.
        self.assertIsNone(shell_output.split_key_value("no separator here"))

    def test_returns_none_for_a_blank_line(self):
        self.assertIsNone(shell_output.split_key_value(""))
        self.assertIsNone(shell_output.split_key_value("   "))

    def test_returns_none_for_a_non_string_line(self):
        # Skipped, not coerced: `str(b"X=1")` would parse as key "b'X".
        self.assertIsNone(shell_output.split_key_value(None))
        self.assertIsNone(shell_output.split_key_value(b"X=1"))
        self.assertIsNone(shell_output.split_key_value(7))

    def test_keeps_an_empty_key_because_the_parse_it_replaces_did(self):
        # Only a malformed line produces this and no caller looks it up, but
        # firewall_status_test pins it and T-3.8.6 is characterization.
        self.assertEqual(shell_output.split_key_value(" =blank-key"), ("", "blank-key"))

    def test_keeps_an_empty_value(self):
        # `printf "KEY=%s\\n" ""` is how the server says "known but empty".
        self.assertEqual(shell_output.split_key_value("KEY="), ("KEY", ""))


class TestParseKeyValues(unittest.TestCase):
    def test_parses_every_well_formed_line(self):
        self.assertEqual(
            shell_output.parse_key_values(_output(["a=1", "b=2"])),
            {"a": "1", "b": "2"},
        )

    def test_returns_empty_for_a_missing_output_object(self):
        self.assertEqual(shell_output.parse_key_values(None), {})

    def test_returns_empty_when_the_output_has_no_stdout_lines(self):
        # Three of the fifteen sites raised AttributeError on this shape.
        self.assertEqual(shell_output.parse_key_values(SimpleNamespace()), {})

    def test_returns_empty_when_stdout_lines_is_none(self):
        self.assertEqual(shell_output.parse_key_values(_output(None)), {})

    def test_skips_malformed_blank_and_non_string_lines(self):
        self.assertEqual(
            shell_output.parse_key_values(_output(["a=1", "", "  ", "junk", None, 7, "b=2"])),
            {"a": "1", "b": "2"},
        )

    def test_a_repeated_key_takes_the_last_value(self):
        # Load-bearing: the backup runner emits one artifact line per attempt
        # and the newest is the one to restore from.
        self.assertEqual(
            shell_output.parse_key_values(_output(["k=first", "k=last"])),
            {"k": "last"},
        )

    def test_prefix_selects_a_subset_without_stripping_it(self):
        # Callers match on the full prefixed key afterwards, so the prefix
        # must survive into the returned keys.
        self.assertEqual(
            shell_output.parse_key_values(
                _output(["container_state=running", "other=1"]),
                prefix="container_",
            ),
            {"container_state": "running"},
        )

    def test_prefix_none_returns_everything(self):
        self.assertEqual(
            shell_output.parse_key_values(_output(["a=1"]), prefix=None),
            {"a": "1"},
        )


class TestAsInt(unittest.TestCase):
    def test_returns_an_integer_unchanged(self):
        self.assertEqual(shell_output.as_int(42, 0), 42)

    def test_parses_a_numeric_string_and_tolerates_padding(self):
        self.assertEqual(shell_output.as_int(" 42 ", 0), 42)

    def test_falls_back_for_a_non_numeric_string(self):
        self.assertEqual(shell_output.as_int("not a number", -1), -1)

    def test_falls_back_for_none_and_other_types(self):
        self.assertEqual(shell_output.as_int(None, 5), 5)
        self.assertEqual(shell_output.as_int([], 5), 5)

    def test_rejects_bool_even_though_it_is_an_int_in_python(self):
        # `True` reaching an int field means the caller confused a flag for a
        # count; returning 1 would hide that.
        self.assertEqual(shell_output.as_int(True, 9), 9)
        self.assertEqual(shell_output.as_int(False, 9), 9)


class TestParseBoolToken(unittest.TestCase):
    def test_bools_pass_through_untouched(self):
        self.assertTrue(shell_output.parse_bool_token(True, False))
        self.assertFalse(shell_output.parse_bool_token(False, True))

    def test_none_yields_the_default(self):
        self.assertTrue(shell_output.parse_bool_token(None, True))
        self.assertFalse(shell_output.parse_bool_token(None, False))

    def test_default_tokens_accept_on_and_off(self):
        self.assertTrue(shell_output.parse_bool_token("on", False))
        self.assertTrue(shell_output.parse_bool_token("  YES ", False))
        self.assertFalse(shell_output.parse_bool_token("off", True))
        self.assertFalse(shell_output.parse_bool_token("0", True))

    def test_unknown_tokens_yield_the_default(self):
        self.assertTrue(shell_output.parse_bool_token("bogus", True))
        self.assertFalse(shell_output.parse_bool_token("bogus", False))
        # Empty string is unknown to the default sets (only the postgres
        # member extends its false set with ""); it yields the default.
        self.assertTrue(shell_output.parse_bool_token("", True))
        self.assertFalse(
            shell_output.parse_bool_token("", True, false_tokens=("0", "false", "no", "off", ""))
        )

    def test_custom_tokens_cover_the_engine_y_n_vocabulary(self):
        # The dry_run path is the only member that reads y/n; every other
        # member reads on/off, so the token set stays a parameter.
        self.assertTrue(
            shell_output.parse_bool_token(
                "y",
                False,
                true_tokens=("true", "1", "yes", "y"),
                false_tokens=("false", "0", "no", "n"),
            )
        )
        self.assertFalse(
            shell_output.parse_bool_token(
                "n",
                True,
                true_tokens=("true", "1", "yes", "y"),
                false_tokens=("false", "0", "no", "n"),
            )
        )
        self.assertTrue(
            shell_output.parse_bool_token(
                "on",
                True,
                true_tokens=("true", "1", "yes", "y"),
                false_tokens=("false", "0", "no", "n"),
            )
        )

    def test_non_strings_yield_the_default_unless_coerced(self):
        # Firewall reads int 1 as its fallback, not as true; only the
        # container-status member str-coerces.
        self.assertTrue(shell_output.parse_bool_token(1, True))
        self.assertFalse(shell_output.parse_bool_token(1, False))
        self.assertTrue(shell_output.parse_bool_token(1, False, coerce_non_string=True))
        self.assertFalse(shell_output.parse_bool_token(2, False, coerce_non_string=True))

    def test_unknown_error_factory_raises_for_strict_members(self):
        # Postgres validates settings: an unrecognized token is a caller
        # error, not a default.
        with self.assertRaisesRegex(ValueError, "must be a boolean"):
            shell_output.parse_bool_token(
                "bogus",
                False,
                unknown_error=lambda: ValueError("enabled must be a boolean."),
            )


if __name__ == "__main__":
    unittest.main()
