"""Upload hygiene for local `.sql` imports (#84).

The dump travels over SFTP into a fresh 0700 staging directory and is
SHA-256-verified before the import runs, so its bytes are never
group- or world-readable on the server at any point.
"""

from __future__ import annotations

import hashlib
import os
import tempfile
import unittest
from contextlib import ExitStack

from orchestrator.postgres_runtime_parts import local_import_support
from tests.postgres_helpers_support import (
    _config,
    _error_result,
    build_test_context,
    patch,
)

_REMOTE_DIR = "/tmp/deploydash-postgres-import-abc123.d"
_REMOTE_PATH = f"{_REMOTE_DIR}/dump.sql"


class _FakeChannelFile:
    """Why: stands in for paramiko's stdout so sha256sum needs no server."""

    def __init__(self, payload):
        self._payload = payload

    def read(self):
        """Why: the verifier consumes the checksum line in a single read."""
        return self._payload


class _FakeRemoteFile:
    """Why: captures uploaded bytes so tests assert exact file content."""

    def __init__(self):
        self.written = bytearray()
        self.pipelined = False
        self.closed = False
        self.events = None

    def set_pipelined(self, value):
        """Why: the uploader enables pipelining when the handle offers it."""
        self.pipelined = value

    def write(self, chunk):
        """Why: records each uploaded chunk in arrival order."""
        self.written += chunk
        if self.events is not None:
            self.events.append("write")

    def close(self):
        """Why: the uploader always closes the remote file handle."""
        self.closed = True


class _FakeSftpClient:
    """Why: stands in for the SFTP session: directory, file and modes."""

    def __init__(self):
        self.mkdir_calls = []
        self.files = {}
        self.chmod_calls = []
        self.events = []
        self.closed = False

    def mkdir(self, path, mode):
        """Why: the uploader creates the 0700 staging directory first."""
        self.mkdir_calls.append((path, mode))

    def file(self, path, mode):
        """Why: hands the uploader a fresh capture handle per upload."""
        handle = _FakeRemoteFile()
        handle.events = self.events
        self.files[path] = handle
        return handle

    def chmod(self, path, mode):
        """Why: records the defense-in-depth 0600 on the staged file."""
        self.chmod_calls.append((path, mode))
        self.events.append("chmod")

    def close(self):
        """Why: the uploader always closes the SFTP session."""
        self.closed = True


class _FakeSshClient:
    """Why: stands in for paramiko.SSHClient without touching a network."""

    def __init__(self, checksum_output):
        self.checksum_output = checksum_output
        self.connect_kwargs = None
        self.exec_commands = []
        self.sftp = _FakeSftpClient()
        self.closed = False
        self.host_key_policy = None
        self.saved_host_keys = None

    def load_system_host_keys(self):
        """Why: the uploader loads system host keys before its own file."""

    def load_host_keys(self, path):
        """Why: the uploader loads the known-hosts file when configured."""

    def set_missing_host_key_policy(self, policy):
        """Why: records which host-key policy the uploader selected."""
        self.host_key_policy = policy

    def connect(self, **kwargs):
        """Why: records the SSH credentials instead of dialing out."""
        self.connect_kwargs = kwargs

    def open_sftp(self):
        """Why: hands the uploader the fake SFTP session."""
        return self.sftp

    def exec_command(self, command):
        """Why: answers sha256sum with the canned checksum output."""
        self.exec_commands.append(command)
        return (None, _FakeChannelFile(self.checksum_output), None)

    def save_host_keys(self, path):
        """Why: accept-new persists the host key instead of writing it."""
        self.saved_host_keys = path

    def close(self):
        """Why: the uploader always closes the SSH connection."""
        self.closed = True


class TestLocalSqlImportUpload(unittest.TestCase):
    def _run_upload(self, payload, *, checksum=None, is_cancelled=None, chunk_size=None):
        """Why: builds the fakes, temp dump and clean SSH env per case."""
        expected = hashlib.sha256(payload).hexdigest()
        if checksum is None:
            checksum = f"{expected}  {_REMOTE_PATH}\n".encode("ascii")
        clients = []

        def fake_client_factory():
            """Why: hands paramiko's slot a recording client for the case."""
            client = _FakeSshClient(checksum)
            clients.append(client)
            return client

        events = []
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *args, **kwargs: events.append((args, kwargs)),
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
        )
        clean_env = {
            "DEPLOYDASH_SSH_CONNECT_TIMEOUT": "",
            "DEPLOYDASH_SSH_STRICT_HOST_KEY_CHECKING": "",
            "DEPLOYDASH_SSH_KNOWN_HOSTS_FILE": "",
            "DEPLOYDASH_DATA_DIR": "",
        }
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(payload)
            handle.flush()
            with ExitStack() as stack:
                stack.enter_context(
                    patch.object(
                        local_import_support.paramiko,
                        "SSHClient",
                        fake_client_factory,
                    )
                )
                stack.enter_context(patch.dict(os.environ, clean_env))
                if chunk_size is not None:
                    stack.enter_context(
                        patch.object(
                            local_import_support,
                            "_LOCAL_SQL_UPLOAD_CHUNK_SIZE",
                            chunk_size,
                        )
                    )
                result = local_import_support._upload_local_sql_import_file(
                    ctx,
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    local_path=handle.name,
                    remote_path=_REMOTE_PATH,
                    remote_dir=_REMOTE_DIR,
                    emit=None,
                    is_cancelled=is_cancelled,
                )
        return result, clients[0], events

    def test_upload_stages_0600_file_in_0700_dir_and_verifies_sha256(self):
        payload = b"CREATE TABLE demo(id integer);\n"
        result, client, events = self._run_upload(payload)
        self.assertEqual(client.sftp.mkdir_calls, [(_REMOTE_DIR, 0o700)])
        handle = client.sftp.files[_REMOTE_PATH]
        self.assertEqual(bytes(handle.written), payload)
        self.assertTrue(handle.pipelined)
        self.assertTrue(handle.closed)
        self.assertEqual(client.sftp.chmod_calls, [(_REMOTE_PATH, 0o600)])
        self.assertEqual(len(client.exec_commands), 1)
        self.assertIn("sha256sum", client.exec_commands[0])
        self.assertIn("dump.sql", client.exec_commands[0])
        self.assertEqual(result["size_bytes"], len(payload))
        self.assertEqual(result["remote_path"], _REMOTE_PATH)
        self.assertTrue(client.closed)
        self.assertTrue(client.sftp.closed)
        names = [args[1] for args, _kwargs in events]
        self.assertIn("postgres_local_sql_upload_started", names)
        self.assertIn("postgres_local_sql_upload_completed", names)
        self.assertEqual(client.connect_kwargs["username"], "ubuntu")
        self.assertEqual(client.connect_kwargs["hostname"], "198.51.100.8")
        self.assertEqual(client.connect_kwargs["password"], "secret")

    def test_upload_restricts_staged_file_before_the_first_byte(self):
        # The 0600 must land before any dump bytes stream: a chmod after
        # the transfer leaves the file at the SFTP default (0644) for the
        # whole upload, against this file's never-readable promise.
        _result, client, _events = self._run_upload(b"CREATE TABLE demo(id integer);\n")
        order = client.sftp.events
        self.assertIn("chmod", order)
        self.assertIn("write", order)
        self.assertLess(order.index("chmod"), order.index("write"))

    def test_upload_rejects_sha256_mismatch(self):
        payload = b"CREATE TABLE demo(id integer);\n"
        bad = "0" * 64
        with self.assertRaisesRegex(
            local_import_support._PostgresLocalImportUploadError,
            f"SHA-256.*{bad}",
        ):
            self._run_upload(
                payload,
                checksum=f"{bad}  {_REMOTE_PATH}\n".encode("ascii"),
            )

    def test_upload_rejects_empty_checksum_output(self):
        with self.assertRaisesRegex(
            local_import_support._PostgresLocalImportUploadError,
            "no checksum",
        ):
            self._run_upload(b"SELECT 1;\n", checksum=b"")

    def test_upload_cancelled_mid_stream_aborts(self):
        calls = []

        def cancel_after_two_chunks():
            """Why: lets two chunks land so the abort hits mid-stream."""
            calls.append(1)
            return len(calls) > 2

        with self.assertRaises(
            local_import_support._PostgresLocalImportCancelled,
        ):
            self._run_upload(
                b"01234567890123456789",
                chunk_size=6,
                is_cancelled=cancel_after_two_chunks,
            )

    def test_resolve_payload_nests_remote_file_in_fresh_staging_dir(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            local_path = os.path.join(tmpdir, "my dump.sql")
            with open(local_path, "wb") as handle:
                handle.write(b"SELECT 1;\n")
            cfg = _config(
                project_slug="test",
                database_name="app",
                import_local_file_path=local_path,
            )
            payload = local_import_support._resolve_local_sql_import_payload(
                cfg,
                "dd_test_",
                validate_local_file=True,
            )
        self.assertTrue(
            payload["remote_dir"].startswith("/tmp/deploydash-postgres-import-"),
        )
        self.assertTrue(payload["remote_dir"].endswith(".d"))
        self.assertEqual(payload["remote_path"], payload["remote_dir"] + "/my-dump.sql")
        self.assertEqual(payload["size_bytes"], 10)

    def test_cleanup_command_removes_staging_dir(self):
        command = local_import_support._postgres_local_sql_cleanup_command(_REMOTE_DIR)
        self.assertIn("rm -rf", command)
        self.assertIn(_REMOTE_DIR, command)

    def test_resolve_payload_detects_custom_format_by_magic(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            dump_path = os.path.join(tmpdir, "backup.dump")
            with open(dump_path, "wb") as handle:
                handle.write(b"PGDMPfake-custom-bytes")
            cfg = _config(
                project_slug="test",
                database_name="app",
                import_local_file_path=dump_path,
            )
            payload = local_import_support._resolve_local_sql_import_payload(
                cfg,
                "dd_test_",
                validate_local_file=True,
            )
        self.assertEqual(payload["dump_format"], "custom")
        self.assertEqual(payload["size_bytes"], 22)

    def test_resolve_payload_prefers_magic_over_sql_suffix(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            dump_path = os.path.join(tmpdir, "misnamed.sql")
            with open(dump_path, "wb") as handle:
                handle.write(b"PGDMPfake-custom-bytes")
            cfg = _config(
                project_slug="test",
                database_name="app",
                import_local_file_path=dump_path,
            )
            payload = local_import_support._resolve_local_sql_import_payload(
                cfg,
                "dd_test_",
                validate_local_file=True,
            )
        self.assertEqual(payload["dump_format"], "custom")

    def test_resolve_payload_rejects_plain_non_sql_files(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            text_path = os.path.join(tmpdir, "notes.txt")
            with open(text_path, "wb") as handle:
                handle.write(b"SELECT 1;\n")
            cfg = _config(
                project_slug="test",
                database_name="app",
                import_local_file_path=text_path,
            )
            with self.assertRaisesRegex(
                local_import_support.PostgresConfigValidationError,
                "custom-format",
            ):
                local_import_support._resolve_local_sql_import_payload(
                    cfg,
                    "dd_test_",
                    validate_local_file=True,
                )

    def test_resolve_payload_rejects_missing_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = _config(
                project_slug="test",
                database_name="app",
                import_local_file_path=os.path.join(tmpdir, "gone.sql"),
            )
            with self.assertRaises(
                local_import_support.PostgresConfigValidationError,
            ):
                local_import_support._resolve_local_sql_import_payload(
                    cfg,
                    "dd_test_",
                    validate_local_file=True,
                )

    def test_resolve_payload_falls_back_for_empty_sanitized_stem(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            dump_path = os.path.join(tmpdir, "...")
            with open(dump_path, "wb") as handle:
                handle.write(b"PGDMPfake-custom-bytes")
            cfg = _config(
                project_slug="test",
                database_name="app",
                import_local_file_path=dump_path,
            )
            payload = local_import_support._resolve_local_sql_import_payload(
                cfg,
                "dd_test_",
                validate_local_file=True,
            )
        self.assertEqual(payload["dump_format"], "custom")
        self.assertTrue(payload["remote_path"].endswith("/import"))

    def test_resolve_payload_dry_run_infers_format_from_suffix(self):
        cfg = _config(
            project_slug="test",
            database_name="app",
            import_local_file_path="/tmp/planned.sql",
        )
        payload = local_import_support._resolve_local_sql_import_payload(
            cfg,
            "dd_test_",
            validate_local_file=False,
        )
        self.assertEqual(payload["dump_format"], "plain")
        self.assertIsNone(payload["size_bytes"])
        cfg = _config(
            project_slug="test",
            database_name="app",
            import_local_file_path="/tmp/planned.dump",
        )
        payload = local_import_support._resolve_local_sql_import_payload(
            cfg,
            "dd_test_",
            validate_local_file=False,
        )
        self.assertEqual(payload["dump_format"], "custom")


if __name__ == "__main__":
    unittest.main()
