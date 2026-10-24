import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from orchestrator import engine_runtime_common
from tests.engine_context_fixtures import build_test_context


class _FakeOutput:
    def __init__(self, stderr_lines=None):
        self.stderr_lines = stderr_lines or []


class TestEngineRuntimeCommon(unittest.TestCase):
    def setUp(self):
        self.ctx = build_test_context()

    def test_command_error_details_parses_s3_xml_error(self):
        output = _FakeOutput(
            stderr_lines=[
                (
                    "<Error><Code>InvalidAccessKeyId</Code>"
                    "<Message>The AWS Access Key Id you provided does not "
                    "exist in our records.</Message></Error>"
                ),
            ],
        )

        details = engine_runtime_common._command_error_details(self.ctx, output)

        self.assertEqual(
            details,
            (
                "InvalidAccessKeyId: The AWS Access Key Id you provided does "
                "not exist in our records."
            ),
        )

    def test_command_error_details_parses_prefixed_xml_error(self):
        output = _FakeOutput(
            stderr_lines=[
                (
                    "wal-g failed to reach storage "
                    "<Error><Code>AccessDenied</Code>"
                    "<Message>Access Denied.</Message></Error>"
                ),
            ],
        )

        details = engine_runtime_common._command_error_details(self.ctx, output)

        self.assertEqual(
            details,
            "wal-g failed to reach storage: AccessDenied: Access Denied.",
        )

    def test_command_error_details_parses_json_error_payload(self):
        output = _FakeOutput(
            stderr_lines=[
                '{"error":{"code":"ExpiredToken","message":"The provided token has expired."}}',
            ],
        )

        details = engine_runtime_common._command_error_details(self.ctx, output)

        self.assertEqual(
            details,
            "ExpiredToken: The provided token has expired.",
        )

    def test_command_error_details_preserves_plain_text_lines(self):
        output = _FakeOutput(
            stderr_lines=[
                "plain failure",
                "plain failure",
                "second line",
            ],
        )

        details = engine_runtime_common._command_error_details(self.ctx, output)

        self.assertEqual(details, "plain failure; second line")


class TestResolveKnownHostsFile(unittest.TestCase):
    def test_prefers_explicit_known_hosts_override(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            override = Path(temp_dir) / "custom" / "known_hosts"
            with mock.patch.dict(
                os.environ,
                {
                    "DEPLOYDASH_SSH_KNOWN_HOSTS_FILE": str(override),
                    "DEPLOYDASH_DATA_DIR": str(Path(temp_dir) / "data"),
                },
                clear=False,
            ):
                resolved = engine_runtime_common._resolve_known_hosts_file()

            self.assertEqual(resolved, str(override))
            self.assertTrue(override.is_file())

    def test_uses_deploydash_data_dir_ssh_known_hosts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            data_dir = Path(temp_dir) / "app-support"
            expected = data_dir / "ssh" / "known_hosts"
            with mock.patch.dict(
                os.environ,
                {"DEPLOYDASH_DATA_DIR": str(data_dir)},
                clear=False,
            ):
                os.environ.pop("DEPLOYDASH_SSH_KNOWN_HOSTS_FILE", None)
                resolved = engine_runtime_common._resolve_known_hosts_file()

            self.assertEqual(resolved, str(expected))
            self.assertTrue(expected.is_file())

    def test_falls_back_to_temp_when_data_dir_unset(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop("DEPLOYDASH_SSH_KNOWN_HOSTS_FILE", None)
                os.environ.pop("DEPLOYDASH_DATA_DIR", None)
                with mock.patch.object(
                    engine_runtime_common.tempfile,
                    "gettempdir",
                    return_value=temp_dir,
                ):
                    resolved = engine_runtime_common._resolve_known_hosts_file()

            expected = Path(temp_dir) / "deploydash-known_hosts"
            self.assertEqual(resolved, str(expected))
            self.assertTrue(expected.is_file())
            self.assertNotIn(".deploydash", resolved)

    def test_does_not_use_home_dot_deploydash(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            legacy = Path(temp_dir) / "home" / ".deploydash" / "known_hosts"
            legacy.parent.mkdir(parents=True)
            legacy.write_text("legacy\n", encoding="utf-8")
            data_dir = Path(temp_dir) / "app-support"
            with mock.patch.dict(
                os.environ,
                {"DEPLOYDASH_DATA_DIR": str(data_dir)},
                clear=False,
            ):
                os.environ.pop("DEPLOYDASH_SSH_KNOWN_HOSTS_FILE", None)
                resolved = engine_runtime_common._resolve_known_hosts_file()

            self.assertEqual(resolved, str(data_dir / "ssh" / "known_hosts"))
            self.assertNotEqual(resolved, str(legacy))
            self.assertEqual(legacy.read_text(encoding="utf-8"), "legacy\n")


if __name__ == "__main__":
    unittest.main()
