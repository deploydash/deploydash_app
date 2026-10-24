import unittest
from types import SimpleNamespace
from unittest.mock import patch

from orchestrator import ssh_hostkey


class TestSshHostkey(unittest.TestCase):
    def test_host_key_mismatch_message_variants(self):
        self.assertIn(
            "saved before",
            ssh_hostkey.host_key_mismatch_message(
                known_hosts_file="/tmp/known_hosts",
            ),
        )
        self.assertIn(
            "fingerprint details",
            ssh_hostkey.host_key_mismatch_message(known_hosts_file=None),
        )

    def test_is_host_key_mismatch_error_matches_supported_messages(self):
        self.assertTrue(
            ssh_hostkey.is_host_key_mismatch_error(
                "Host key does not match saved entry",
            ),
        )
        self.assertTrue(
            ssh_hostkey.is_host_key_mismatch_error(
                "REMOTE HOST IDENTIFICATION HAS CHANGED",
            ),
        )
        self.assertTrue(
            ssh_hostkey.is_host_key_mismatch_error("SSH host key error"),
        )
        self.assertFalse(
            ssh_hostkey.is_host_key_mismatch_error("Permission denied"),
        )

    @patch("orchestrator.ssh_hostkey.subprocess.run")
    def test_read_known_host_fingerprint_prefers_found_entries(self, run_mock):
        run_mock.side_effect = [
            SimpleNamespace(returncode=0, stdout="host ssh-ed25519 AAAA\n"),
            SimpleNamespace(returncode=0, stdout="123 SHA256:abc comment"),
        ]

        result = ssh_hostkey.read_known_host_fingerprint(
            host="example.com",
            port=22,
            known_hosts_file="/tmp/known_hosts",
        )

        self.assertEqual(result, "SHA256:abc")

    @patch("orchestrator.ssh_hostkey.subprocess.run")
    def test_read_known_host_fingerprint_returns_none_on_failures(self, run_mock):
        run_mock.side_effect = RuntimeError("boom")
        self.assertIsNone(
            ssh_hostkey.read_known_host_fingerprint(
                host="example.com",
                port=22,
                known_hosts_file="/tmp/known_hosts",
            ),
        )
        self.assertIsNone(
            ssh_hostkey.read_known_host_fingerprint(
                host="example.com",
                port=22,
                known_hosts_file=None,
            ),
        )

    @patch("orchestrator.ssh_hostkey.subprocess.run")
    def test_read_known_host_fingerprint_tries_port_entry_and_handles_none_fingerprint(
        self,
        run_mock,
    ):
        run_mock.side_effect = [
            SimpleNamespace(returncode=0, stdout="first ssh-ed25519 AAAA\n"),
            SimpleNamespace(returncode=0, stdout="singlepart"),
            SimpleNamespace(returncode=0, stdout="second ssh-ed25519 BBBB\n"),
            SimpleNamespace(returncode=0, stdout="123 SHA256:port comment"),
        ]

        result = ssh_hostkey.read_known_host_fingerprint(
            host="example.com",
            port=22,
            known_hosts_file="/tmp/known_hosts",
        )

        self.assertEqual(result, "SHA256:port")

        with patch("orchestrator.ssh_hostkey.subprocess.run") as no_port_mock:
            no_port_mock.side_effect = [
                SimpleNamespace(returncode=0, stdout="first ssh-ed25519 AAAA\n"),
                SimpleNamespace(returncode=0, stdout="123 SHA256:host comment"),
            ]
            self.assertEqual(
                ssh_hostkey.read_known_host_fingerprint(
                    host="example.com",
                    port=None,
                    known_hosts_file="/tmp/known_hosts",
                ),
                "SHA256:host",
            )

    @patch("orchestrator.ssh_hostkey.subprocess.run")
    def test_scan_remote_host_fingerprint_and_parser(self, run_mock):
        run_mock.side_effect = [
            SimpleNamespace(returncode=0, stdout="host ssh-ed25519 AAAA\n"),
            SimpleNamespace(returncode=0, stdout="123 SHA256:def comment"),
            SimpleNamespace(returncode=1, stdout=""),
            RuntimeError("boom"),
            SimpleNamespace(returncode=0, stdout="123 SHA256:def comment"),
            SimpleNamespace(returncode=1, stdout=""),
            SimpleNamespace(returncode=0, stdout="no-fingerprint-here"),
        ]

        self.assertEqual(
            ssh_hostkey.scan_remote_host_fingerprint(host="example.com", port=22),
            "SHA256:def",
        )
        self.assertIsNone(
            ssh_hostkey.scan_remote_host_fingerprint(host="example.com", port=22),
        )
        self.assertIsNone(
            ssh_hostkey.scan_remote_host_fingerprint(host="example.com", port=22),
        )
        self.assertIsNone(
            ssh_hostkey.scan_remote_host_fingerprint(host="", port=22),
        )

    @patch("orchestrator.ssh_hostkey.subprocess.run")
    def test_fingerprint_parser_handles_exceptions_and_empty_output(self, run_mock):
        run_mock.side_effect = [
            RuntimeError("boom"),
            SimpleNamespace(returncode=1, stdout=""),
            SimpleNamespace(returncode=0, stdout=""),
            SimpleNamespace(returncode=0, stdout="singlepart"),
        ]

        self.assertIsNone(ssh_hostkey._fingerprint_for_key_material("key"))
        self.assertIsNone(ssh_hostkey._fingerprint_for_key_material("key"))
        self.assertIsNone(ssh_hostkey._fingerprint_for_key_material("key"))
        self.assertIsNone(ssh_hostkey._fingerprint_for_key_material("key"))

    @patch("orchestrator.ssh_hostkey.scan_remote_host_fingerprint")
    @patch("orchestrator.ssh_hostkey.read_known_host_fingerprint")
    def test_build_host_key_mismatch_payload(self, read_mock, scan_mock):
        read_mock.return_value = "SHA256:old"
        scan_mock.return_value = "SHA256:new"

        result = ssh_hostkey.build_host_key_mismatch_payload(
            host="example.com",
            port=2022,
            known_hosts_file="/tmp/known_hosts",
        )

        self.assertEqual(
            result,
            {
                "host": "example.com",
                "port": 2022,
                "known_hosts_file": "/tmp/known_hosts",
                "old_fingerprint": "SHA256:old",
                "new_fingerprint": "SHA256:new",
            },
        )


if __name__ == "__main__":
    unittest.main()
