import unittest
import xml.etree.ElementTree as ET

from orchestrator.backup_error_details import (
    format_command_error_details,
)
from orchestrator.failure_evidence import (
    _combine_error_code_and_message,
    _first_nonempty_value,
    _structured_json_error_message,
    _structured_xml_error_message,
    _xml_error_field,
)


class _FakeOutput:
    def __init__(self, stderr_lines=None):
        self.stderr_lines = stderr_lines or []


class TestBackupErrorDetails(unittest.TestCase):
    def test_format_command_error_details_handles_empty_values(self):
        self.assertEqual(format_command_error_details(None, str), "")
        self.assertEqual(format_command_error_details(_FakeOutput(), str), "")

    def test_format_command_error_details_parses_xml_and_deduplicates(self):
        output = _FakeOutput(
            stderr_lines=[
                (
                    "<Error><Code>InvalidAccessKeyId</Code>"
                    "<Message>The AWS Access Key Id you provided does not "
                    "exist in our records.</Message></Error>"
                ),
                (
                    "<Error><Code>InvalidAccessKeyId</Code>"
                    "<Message>The AWS Access Key Id you provided does not "
                    "exist in our records.</Message></Error>"
                ),
                (
                    "wal-g failed "
                    "<Error><Code>AccessDenied</Code>"
                    "<Message>Access Denied.</Message></Error>"
                ),
            ],
        )

        details = format_command_error_details(output, str)

        self.assertEqual(
            details,
            (
                "InvalidAccessKeyId: The AWS Access Key Id you provided does not "
                "exist in our records.; wal-g failed: AccessDenied: Access Denied."
            ),
        )

    def test_format_command_error_details_parses_json_and_plain_text(self):
        output = _FakeOutput(
            stderr_lines=[
                '{"error":{"code":"ExpiredToken","message":"The provided token has expired."}}',
                "plain failure",
                " plain failure ",
            ],
        )

        details = format_command_error_details(output, str)

        self.assertEqual(
            details,
            "ExpiredToken: The provided token has expired.; plain failure",
        )

    def test_format_command_error_details_skips_blank_sanitized_lines(self):
        output = _FakeOutput(stderr_lines=["  keep me  ", "drop me"])

        details = format_command_error_details(
            output,
            lambda value: "" if "drop" in value else value,
        )

        self.assertEqual(details, "keep me")

    def test_structured_json_error_message_covers_fallback_branches(self):
        self.assertIsNone(_structured_json_error_message("plain text"))
        self.assertIsNone(_structured_json_error_message("{not-json}"))
        self.assertIsNone(_structured_json_error_message('["array"]'))
        self.assertIsNone(_structured_json_error_message("{}"))
        self.assertEqual(
            _structured_json_error_message('{"error":{"Code":"AccessDenied"}}'),
            "AccessDenied",
        )
        self.assertEqual(
            _structured_json_error_message(
                '{"errors":{"message":"Already prefixed: detail","code":"Already prefixed"}}',
            ),
            "Already prefixed: detail",
        )

    def test_structured_xml_error_message_covers_parse_and_prefix_paths(self):
        self.assertIsNone(_structured_xml_error_message("prefix without xml"))
        self.assertIsNone(_structured_xml_error_message("<Error>broken"))
        self.assertIsNone(
            _structured_xml_error_message("<Error><RequestId>abc</RequestId></Error>"),
        )
        self.assertEqual(
            _structured_xml_error_message(
                "<Error><Code>AccessDenied</Code><Message>Denied</Message></Error>",
            ),
            "AccessDenied: Denied",
        )

    # Empty and blank structured fields fall through to the next
    # candidate instead of producing blank details (#95 coverage of the
    # fall-through branches).
    def test_xml_field_and_value_helpers_skip_blank_values(self):
        root = ET.fromstring("<Error><Code>  </Code><Code>AccessDenied</Code></Error>")
        self.assertEqual(_xml_error_field(root, "Code"), "AccessDenied")
        self.assertEqual(
            _first_nonempty_value(
                {"primary": "   ", "fallback": "usable"},
                "primary",
                "fallback",
            ),
            "usable",
        )

    def test_xml_field_and_value_helpers_cover_non_string_paths(self):
        root = ET.fromstring("<Error><RequestId>abc</RequestId></Error>")
        self.assertIsNone(_xml_error_field(root, "Code"))
        self.assertEqual(_first_nonempty_value({"count": 4}, "count"), "4")
        self.assertEqual(
            _combine_error_code_and_message("ExpiredToken", "token expired"),
            "ExpiredToken: token expired",
        )
        self.assertEqual(
            _combine_error_code_and_message(None, "message only"),
            "message only",
        )
        self.assertEqual(_combine_error_code_and_message("code-only", None), "code-only")


if __name__ == "__main__":
    unittest.main()
