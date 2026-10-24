"""Backup policy, destination, artifact and restore *helpers*.

Named `postgres_backup_helpers_test.py` because `postgres_backup_test.py`
already exists and covers the manifest and format-version contract. Two
files, two subjects.

One of four files T-3.6.2 split `postgres_helpers_test.py` into. Fixtures and
the base case are in `tests/postgres_helpers_support.py`.
"""

from __future__ import annotations

import os
import unittest

from tests.postgres_helpers_support import (
    PostgresConfigValidationError,
    PostgresHelpersTestCase,
    _config,
    _error_result,
    _FakeHost,
    _FakeOutput,
    _FakeSession,
    backup_operations,
    build_test_context,
    engine_postgres_ops,
    local_sql_import,
    patch,
    tempfile,
)


class TestPostgresBackupHelpers(PostgresHelpersTestCase):
    def test_normalize_backup_policy_token_sanitizes(self):
        token = engine_postgres_ops._normalize_backup_policy_token(
            "Daily Main Policy!!",
            "settings.backup_policy_id",
        )
        self.assertEqual(token, "daily-main-policy")

    def test_normalize_backup_hhmm_validates(self):
        self.assertEqual(
            engine_postgres_ops._normalize_backup_hhmm(
                "2:05",
                "settings.backup_time1",
                "02:00",
            ),
            "02:05",
        )
        with self.assertRaises(PostgresConfigValidationError):
            engine_postgres_ops._normalize_backup_hhmm(
                "29:00",
                "settings.backup_time1",
                "02:00",
            )

    def test_normalize_backup_artifact_path_rejects_parent_traversal(self):
        with self.assertRaises(PostgresConfigValidationError):
            engine_postgres_ops._normalize_backup_artifact_path(
                "../secret.dump",
                "settings.backup_artifact_path",
            )

    def test_resolve_backup_destination_s3_and_filesystem(self):
        s3_config = _config(
            backup_destination_type="s3",
            backup_s3_prefix="s3://bucket/path",
            backup_aws_access_key_id="key",
            backup_aws_secret_access_key="secret",
            backup_aws_region="us-east-1",
            backup_aws_endpoint="https://s3.us-east-1.amazonaws.com",
            backup_aws_force_path_style=True,
        )
        s3 = engine_postgres_ops._resolve_backup_destination(s3_config)
        self.assertEqual(s3["type"], "s3")
        self.assertTrue(s3["aws_force_path_style"])

        fs_config = _config(
            backup_destination_type="filesystem",
            backup_file_prefix="/var/backups/deploydash",
        )
        fs = engine_postgres_ops._resolve_backup_destination(fs_config)
        self.assertEqual(fs["type"], "filesystem")
        self.assertEqual(fs["prefix"], "/var/backups/deploydash")

    def test_backup_env_assignments_for_s3(self):
        destination = {
            "type": "s3",
            "prefix": "s3://bucket/path",
            "aws_access_key_id": "key",
            "aws_secret_access_key": "secret",
            "aws_region": "us-east-1",
            "aws_endpoint": "https://s3.us-east-1.amazonaws.com",
            "aws_force_path_style": True,
        }
        lines = engine_postgres_ops._backup_env_assignments(destination)
        self.assertTrue(
            any(line.startswith("export WALG_S3_PREFIX=") for line in lines),
        )
        self.assertIn("export AWS_S3_FORCE_PATH_STYLE=true", lines)
        export_block = engine_postgres_ops._backup_env_export_block(destination)
        self.assertTrue(export_block.endswith("; "))

    def test_parse_backup_outputs(self):
        run_out = _FakeOutput(
            ["backup_artifact_path=a.dump", "backup_artifact_path=b.dump"],
        )
        self.assertEqual(
            engine_postgres_ops._postgres_parse_backup_run_output(run_out),
            "b.dump",
        )
        artifacts_out = _FakeOutput(
            [
                "name size",
                "deploydash/postgres/test/a/20260101T010101Z__db.dump",
                "deploydash/postgres/test/a/20260102T010101Z__db.dump",
            ]
        )
        artifacts = engine_postgres_ops._postgres_parse_backup_artifacts_output(
            artifacts_out,
            remote_base_path="deploydash/postgres/test/a",
        )
        self.assertEqual(len(artifacts), 2)
        self.assertEqual(
            artifacts[0]["created_at"],
            "2026-01-02T01:01:01Z",
        )
        self.assertEqual(
            artifacts[0]["remote_path"],
            "deploydash/postgres/test/a/20260102T010101Z__db.dump",
        )

    def test_resolve_backup_policy_payload(self):
        cfg = _config(
            project_slug="test",
            backup_policy_id="daily-main",
            backup_task_id="task-main",
            backup_policy_name="Daily Main",
            backup_database_name="app",
            backup_schedule_mode="daily_twice",
            backup_time1="01:15",
            backup_time2="13:45",
            backup_retention_keep_last=10,
            backup_destination_type="filesystem",
            backup_file_prefix="/var/backups/deploydash",
            enabled=False,
        )
        payload = engine_postgres_ops._resolve_backup_policy_payload(
            cfg,
            "dd_test_",
        )
        self.assertEqual(payload["policy_token"], "daily-main")
        self.assertEqual(payload["schedule_mode"], "daily_twice")
        self.assertEqual(payload["time2"], "13:45")
        self.assertFalse(payload["enabled"])

    def test_resolve_backup_restore_payload(self):
        cfg = _config(
            project_slug="test",
            backup_policy_id="daily-main",
            backup_destination_type="filesystem",
            backup_file_prefix="/var/backups/deploydash",
            backup_target_database_name="restore_target",
            backup_artifact_path="deploydash/postgres/test/a/20260101T010101Z__db.dump",
        )
        payload = engine_postgres_ops._resolve_backup_restore_payload(
            cfg,
            "dd_test_",
        )
        self.assertEqual(payload["target_database_name"], "dd_test_restore_target")
        self.assertIn("20260101T010101Z__db.dump", payload["artifact_path"])

        relative_cfg = _config(
            project_slug="test",
            backup_policy_id="daily-main",
            backup_destination_type="filesystem",
            backup_file_prefix="/var/backups/deploydash",
            backup_target_database_name="restore_target",
            backup_artifact_path="20260101T010101Z__db.dump",
        )
        relative_payload = engine_postgres_ops._resolve_backup_restore_payload(
            relative_cfg,
            "dd_test_",
        )
        self.assertEqual(
            relative_payload["artifact_path"],
            "deploydash/postgres/test/daily-main/20260101T010101Z__db.dump",
        )

    def test_backup_policy_apply_command_disables_cron_when_not_enabled(self):
        # superuser_name is server-owned (T-1.4.4) and was set here to its
        # own default value anyway; omitted rather than sent.
        cfg = _config(
            project_slug="test",
            superuser_password="secret",
        )
        destination = {"type": "filesystem", "prefix": "/var/backups/deploydash"}
        rendered = engine_postgres_ops._postgres_backup_policy_apply_command(
            cfg,
            policy_token="daily-main",
            task_token="task-main",
            policy_name="Daily Main",
            project_slug="test",
            database_name="dd_test_app",
            schedule_mode="daily_once",
            time1="02:00",
            time2=None,
            retention_keep_last=7,
            enabled=False,
            destination=destination,
        )
        self.assertIn('rm -f "${CRON_PATH}";', rendered["command"])
        self.assertIn("deploydash/postgres/test/daily-main", rendered["remote_base_path"])

    def test_postgres_walg_install_command_has_release_url(self):
        command = engine_postgres_ops._postgres_walg_install_command()
        self.assertNotIn("api.github.com/repos/wal-g", command)
        self.assertIn(
            'github.com/wal-g/wal-g/releases/download/v3.0.8/"${ASSET}"',
            command,
        )
        self.assertIn("wal-g-pg-22.04-amd64.tar.gz", command)
        self.assertIn("wal-g-pg-22.04-aarch64.tar.gz", command)
        self.assertIn("sha256sum -c -", command)
        self.assertIn("WAL-G checksum verification failed", command)

    def test_postgres_backup_destination_test_commands_cover_s3_and_filesystem(self):
        s3_command = engine_postgres_ops._postgres_backup_destination_test_command(
            {
                "type": "s3",
                "prefix": "s3://bucket/path",
                "aws_access_key_id": "key",
                "aws_secret_access_key": "secret",
                "aws_region": "us-east-1",
                "aws_endpoint": "https://s3.example.com",
                "aws_force_path_style": True,
            },
        )
        self.assertIn(
            "wal-g st put --no-compress --no-encrypt",
            s3_command["command"],
        )
        self.assertIn("wal-g st get", s3_command["command"])
        self.assertIn("wal-g st rm", s3_command["command"])
        self.assertIn("test_destination_type=s3", s3_command["command"])

        filesystem_command = engine_postgres_ops._postgres_backup_destination_test_command(
            {
                "type": "filesystem",
                "prefix": "/var/backups/deploydash",
            },
        )
        self.assertIn('cp "${TEST_FILE}"', filesystem_command["command"])
        self.assertIn('cat "${TEST_FILE_PATH}"', filesystem_command["command"])
        self.assertIn('rm -f "${TEST_FILE_PATH}"', filesystem_command["command"])
        self.assertIn(
            "test_destination_type=filesystem",
            filesystem_command["command"],
        )

    def test_run_project_operation_backup_policy_apply_success(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 7,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        apply_plan = {
            "command": "apply backup policy",
            "remote_base_path": "/var/backups/deploydash/postgres/test/daily-main",
            "script_path": "/tmp/backup.sh",
        }
        host_outputs = [
            (True, _FakeOutput()),
            (True, _FakeOutput()),
        ]

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_backup_policy_apply_command=lambda *_args, **_kwargs: apply_plan,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_policy_apply",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["backup_policy_id"], "daily-main")

    def test_run_project_operation_backup_destination_test_success(self):
        destination = {
            "type": "s3",
            "prefix": "s3://bucket/path",
            "aws_access_key_id": "key",
            "aws_secret_access_key": "secret",
            "aws_region": "us-east-1",
            "aws_endpoint": "https://s3.example.com",
            "aws_force_path_style": True,
        }
        host_outputs = [
            (True, _FakeOutput()),
            (True, _FakeOutput(stdout_lines=["test_result=ok"])),
        ]
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_destination=lambda *_args, **_kwargs: destination,
            _postgres_walg_install_command=lambda: "install wal-g",
            _postgres_backup_destination_test_command=lambda *_args, **_kwargs: {
                "command": "test destination",
                "tested_remote_path": "deploydash/connection-tests/sample.txt",
            },
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_destination_test",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["backup_destination_type"], "s3")
        self.assertEqual(
            result["tested_remote_path"],
            "deploydash/connection-tests/sample.txt",
        )

    def test_run_project_operation_backup_destination_test_failure(self):
        destination = {
            "type": "filesystem",
            "prefix": "/var/backups/deploydash",
        }
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_destination=lambda *_args, **_kwargs: destination,
            _postgres_backup_destination_test_command=lambda *_args, **_kwargs: {
                "command": "test destination",
                "tested_remote_path": "/var/backups/deploydash/test.txt",
            },
            _run_postgres_host_command=lambda *_args, **_kwargs: (
                False,
                _FakeOutput(stdout_lines=["boom"]),
            ),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_destination_test",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "PostgreSQL backup destination test failed.")

    def test_run_project_operation_backup_run_now_success(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 7,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        apply_plan = {
            "command": "apply backup policy",
            "remote_base_path": "/var/backups/deploydash/postgres/test/daily-main",
            "script_path": "/tmp/backup.sh",
        }
        host_outputs = [
            (True, _FakeOutput()),
            (True, _FakeOutput()),
            (True, _FakeOutput(stdout_lines=["backup_artifact_path=test.dump"])),
        ]

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_backup_policy_apply_command=lambda *_args, **_kwargs: apply_plan,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
            _postgres_parse_backup_run_output=lambda _output: "test.dump",
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_run_now",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["backup_artifact_path"], "test.dump")

    def test_run_project_operation_backup_artifact_list_success(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 7,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        host_outputs = [
            (True, _FakeOutput()),
            (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "type size last modified name",
                        "obj 10 2026-01-01 00:00:00 +0000 UTC 20260101T010101Z__db.dump",
                    ],
                ),
            ),
        ]

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_artifact_list",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(
            result["artifacts"],
            [
                {
                    "remote_path": "deploydash/postgres/test/daily-main/20260101T010101Z__db.dump",
                    "created_at": "2026-01-01T01:01:01Z",
                    "size_bytes": 10,
                },
            ],
        )
        self.assertEqual(
            result["backup_remote_base_path"],
            "deploydash/postgres/test/daily-main",
        )

    # The backlog report names every artifact beyond retention with its
    # size, so the cleanup dialog can show "N artifacts (~X GB)" before
    # anything is deleted (#95).
    def test_run_project_operation_backup_backlog_report_success(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 1,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        host_outputs = [
            (True, _FakeOutput()),
            (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "type size last modified name",
                        "obj 100 2026-01-01 00:00:00 +0000 UTC 20260101T010101Z__db.dump",
                        "obj 200 2026-01-02 00:00:00 +0000 UTC 20260102T010101Z__db.dump",
                    ],
                ),
            ),
        ]

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_report",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["msg"], "Backup backlog reported.")
        self.assertEqual(result["backup_policy_id"], "daily-main")
        self.assertEqual(
            result["backup_remote_base_path"],
            "deploydash/postgres/test/daily-main",
        )
        self.assertEqual(result["retention_keep_last"], 1)
        self.assertEqual(result["retained_count"], 1)
        self.assertEqual(result["beyond_retention_count"], 1)
        self.assertEqual(result["beyond_retention_bytes"], 100)
        self.assertEqual(result["beyond_retention_unknown_size_count"], 0)
        self.assertEqual(
            result["beyond_retention"],
            [
                {
                    "remote_path": (
                        "deploydash/postgres/test/daily-main/20260101T010101Z__db.dump"
                    ),
                    "created_at": "2026-01-01T01:01:01Z",
                    "size_bytes": 100,
                },
            ],
        )

    # A policy within retention reports an empty backlog rather than an
    # error (#95).
    def test_run_project_operation_backup_backlog_report_empty(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 7,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        host_outputs = [
            (True, _FakeOutput()),
            (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "type size last modified name",
                        "obj 100 2026-01-01 00:00:00 +0000 UTC 20260101T010101Z__db.dump",
                    ],
                ),
            ),
        ]

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_report",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["beyond_retention"], [])
        self.assertEqual(result["beyond_retention_count"], 0)
        self.assertEqual(result["beyond_retention_bytes"], 0)
        self.assertEqual(result["retained_count"], 1)

    # A destination prefix that does not exist yet holds no backlog, so the
    # report succeeds empty like the artifact listing does (#95).
    def test_run_project_operation_backup_backlog_report_missing_prefix(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 1,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        host_outputs = [
            (True, _FakeOutput()),
            (False, _FakeOutput(stderr_lines=["key does not exist"])),
        ]

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "key does not exist",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_report",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["beyond_retention_count"], 0)
        self.assertEqual(result["retained_count"], 0)

    # A listing that fails for a real reason fails the report loudly (#95).
    def test_run_project_operation_backup_backlog_report_list_failure(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 1,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        host_outputs = [
            (True, _FakeOutput()),
            (False, _FakeOutput(stderr_lines=["boom"])),
        ]

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_report",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not list backup artifacts.")
        self.assertEqual(result["details"], "remote failed")

    def test_run_project_operation_backup_backlog_report_install_failure(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 1,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: (
                False,
                _FakeOutput(stderr_lines=["boom"]),
            ),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_report",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Could not install wal-g.")

    def test_run_project_operation_backup_backlog_report_payload_error(self):
        def raise_payload_error(*_args, **_kwargs):
            """Why: fails resolution exactly like invalid policy settings."""
            raise PostgresConfigValidationError("policy id missing")

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=raise_payload_error,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: (True, _FakeOutput()),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_report",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")

    # The confirmed cleanup deletes exactly the beyond-retention keys from a
    # fresh listing -- never the newest N -- plus their manifests (#95).
    def test_run_project_operation_backup_backlog_cleanup_success(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 1,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        old_key = "deploydash/postgres/test/daily-main/20260101T010101Z__db.dump"
        new_key = "deploydash/postgres/test/daily-main/20260102T010101Z__db.dump"
        host_outputs = [
            (True, _FakeOutput()),
            (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "type size last modified name",
                        "obj 100 2026-01-01 00:00:00 +0000 UTC 20260101T010101Z__db.dump",
                        "obj 200 2026-01-02 00:00:00 +0000 UTC 20260102T010101Z__db.dump",
                    ],
                ),
            ),
            (
                True,
                _FakeOutput(
                    stdout_lines=[
                        f"deleted_artifact={old_key}",
                        f"cleanup_manifest_missing={old_key}",
                    ],
                ),
            ),
        ]
        host_commands = []

        def run_host_command(_ctx, _session, command, **_kwargs):
            """Why: captures the cleanup command for the key-shape proof."""
            host_commands.append(command)
            return host_outputs.pop(0)

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=run_host_command,
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_cleanup",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["msg"], "Backup backlog cleaned up.")
        self.assertEqual(result["deleted"], [old_key])
        self.assertEqual(result["deleted_count"], 1)
        self.assertEqual(result["deleted_bytes"], 100)
        self.assertEqual(result["manifests_missing"], [old_key])
        self.assertEqual(len(host_commands), 3)
        cleanup_command = host_commands[2]
        self.assertIn(f"wal-g st rm {old_key}", cleanup_command)
        self.assertIn(f"wal-g st rm {old_key}.manifest.json", cleanup_command)
        self.assertNotIn(new_key, cleanup_command)

    # An empty backlog is a successful no-op that issues no delete command
    # (#95).
    def test_run_project_operation_backup_backlog_cleanup_empty(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 7,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        host_outputs = [
            (True, _FakeOutput()),
            (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "type size last modified name",
                        "obj 100 2026-01-01 00:00:00 +0000 UTC 20260101T010101Z__db.dump",
                    ],
                ),
            ),
        ]
        host_commands = []

        def run_host_command(_ctx, _session, command, **_kwargs):
            """Why: proves no delete command runs for an empty backlog."""
            host_commands.append(command)
            return host_outputs.pop(0)

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=run_host_command,
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_cleanup",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["msg"], "No backup backlog beyond retention.")
        self.assertEqual(result["deleted"], [])
        self.assertEqual(result["deleted_count"], 0)
        self.assertEqual(len(host_commands), 2)

    # A cleanup that deletes some artifacts and then fails reports the
    # partial state honestly: what was deleted and what failed (#95).
    def test_run_project_operation_backup_backlog_cleanup_partial_failure(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 1,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        first_key = "deploydash/postgres/test/daily-main/20260101T010101Z__db.dump"
        second_key = "deploydash/postgres/test/daily-main/20260102T010101Z__db.dump"
        host_outputs = [
            (True, _FakeOutput()),
            (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "type size last modified name",
                        "obj 100 2026-01-01 00:00:00 +0000 UTC 20260101T010101Z__db.dump",
                        "obj 200 2026-01-02 00:00:00 +0000 UTC 20260102T010101Z__db.dump",
                        "obj 300 2026-01-03 00:00:00 +0000 UTC 20260103T010101Z__db.dump",
                    ],
                ),
            ),
            (
                True,
                _FakeOutput(
                    stdout_lines=[
                        f"deleted_artifact={first_key}",
                        f"delete_failed={second_key}",
                    ],
                ),
            ),
        ]

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_cleanup",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "PostgreSQL backup backlog cleanup failed.")
        self.assertEqual(
            result["details"],
            f"Deleted 1 artifact(s) before failing on: {second_key}",
        )

    # A cleanup that deletes nothing names only the failures (#95).
    def test_run_project_operation_backup_backlog_cleanup_all_failed(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 1,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        old_key = "deploydash/postgres/test/daily-main/20260101T010101Z__db.dump"
        host_outputs = [
            (True, _FakeOutput()),
            (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "type size last modified name",
                        "obj 100 2026-01-01 00:00:00 +0000 UTC 20260101T010101Z__db.dump",
                        "obj 200 2026-01-02 00:00:00 +0000 UTC 20260102T010101Z__db.dump",
                    ],
                ),
            ),
            (True, _FakeOutput(stdout_lines=[f"delete_failed={old_key}"])),
        ]

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_cleanup",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "PostgreSQL backup backlog cleanup failed.")
        self.assertEqual(result["details"], f"Failed to delete: {old_key}")

    # A cleanup command that fails at the transport layer -- no outcome
    # markers at all -- reports the command failure, never a phantom
    # success (#95).
    def test_run_project_operation_backup_backlog_cleanup_command_failure(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 1,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        host_outputs = [
            (True, _FakeOutput()),
            (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "type size last modified name",
                        "obj 100 2026-01-01 00:00:00 +0000 UTC 20260101T010101Z__db.dump",
                        "obj 200 2026-01-02 00:00:00 +0000 UTC 20260102T010101Z__db.dump",
                    ],
                ),
            ),
            (False, _FakeOutput(stderr_lines=["ssh broke"])),
        ]

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "ssh broke",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_cleanup",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "PostgreSQL backup backlog cleanup failed.")
        self.assertEqual(result["details"], "ssh broke")

    def test_run_project_operation_backup_backlog_cleanup_install_failure(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 1,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: (
                False,
                _FakeOutput(stderr_lines=["boom"]),
            ),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_cleanup",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Could not install wal-g.")

    def test_run_project_operation_backup_backlog_cleanup_payload_error(self):
        def raise_payload_error(*_args, **_kwargs):
            """Why: fails resolution exactly like invalid policy settings."""
            raise PostgresConfigValidationError("policy id missing")

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=raise_payload_error,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: (True, _FakeOutput()),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_cleanup",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")

    def test_run_project_operation_backup_backlog_cleanup_list_failure(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 1,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        host_outputs = [
            (True, _FakeOutput()),
            (False, _FakeOutput(stderr_lines=["boom"])),
        ]

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_backlog_cleanup",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not list backup artifacts.")

    # The shared listing helper preserves the artifact-list behavior for a
    # missing prefix: success with no artifacts (#95).
    def test_run_project_operation_backup_artifact_list_missing_prefix(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 7,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        host_outputs = [
            (True, _FakeOutput()),
            (False, _FakeOutput(stderr_lines=["key does not exist"])),
        ]

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "key does not exist",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_artifact_list",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["artifacts"], [])

    # A listing that fails for a real reason fails the artifact list loudly
    # (#95).
    def test_run_project_operation_backup_artifact_list_failure(self):
        backup_payload = {
            "policy_token": "daily-main",
            "task_token": "backup-task",
            "policy_name": "Daily",
            "project_slug": "test",
            "database_name": "dd_test_app",
            "schedule_mode": "daily_once",
            "time1": "02:00",
            "time2": None,
            "retention_keep_last": 7,
            "enabled": True,
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        host_outputs = [
            (True, _FakeOutput()),
            (False, _FakeOutput(stderr_lines=["boom"])),
        ]

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_policy_payload=lambda *_args, **_kwargs: backup_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_artifact_list",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not list backup artifacts.")

    def test_run_project_operation_restore_run_now_success(self):
        restore_payload = {
            "target_database_name": "dd_test_restore_target",
            "artifact_path": "deploydash/postgres/test/daily-main/sample.dump",
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        host_outputs = [
            (True, _FakeOutput()),
            (
                True,
                _FakeOutput(
                    stdout_lines=[
                        "restore_target_created=1",
                        "restore_verified=1",
                    ],
                ),
            ),
        ]
        host_commands = []
        psql_calls = []

        def run_host_command(_ctx, _session, command, **_kwargs):
            """Why: captures the atomic restore command for its contract assertions."""
            host_commands.append(command)
            return host_outputs.pop(0)

        def run_psql_query(_ctx, _session, _config, sql, **_kwargs):
            """Why: distinguishes the existence check from ownership registration."""
            psql_calls.append(sql)
            if "FROM pg_database" in sql:
                return True, _FakeOutput(stdout_lines=["0"])
            if sql == "SELECT 1;":
                return True, _FakeOutput(stdout_lines=["1"])
            return True, _FakeOutput()

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_restore_payload=lambda *_args, **_kwargs: restore_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=run_host_command,
            _run_postgres_psql_query_impl=run_psql_query,
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "restore_run_now",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["database_name"], "restore_target")
        self.assertEqual(result["target_database_name"], "dd_test_restore_target")

        # The install-wal-g command runs first, so the actual restore
        # command (built inline in run_postgres_project_operation, not
        # through a mocked helper) is the second captured command. Confirms
        # the format-version check is actually wired into the real restore
        # command this operation sends, not just independently correct in
        # isolation, and that it runs before the destructive createdb/
        # pg_restore sequence rather than after.
        self.assertEqual(len(host_commands), 2)
        restore_command = host_commands[1]
        self.assertIn(
            'MANIFEST_PATH="${ARTIFACT_PATH}.manifest.json"',
            restore_command,
        )
        self.assertLess(
            restore_command.index("MANIFEST_PATH="),
            restore_command.index("createdb -U"),
        )
        self.assertIn("--single-transaction", restore_command)
        self.assertIn("--exit-on-error", restore_command)
        self.assertIn("docker run --rm -i --read-only --cap-drop ALL", restore_command)
        self.assertEqual(len(psql_calls), 3)
        self.assertEqual(psql_calls[1], "SELECT 1;")
        self.assertIn(
            "INSERT INTO deploydash.managed_databases",
            psql_calls[2],
        )
        self.assertIn("'dd_test_restore_target'", psql_calls[2])
        self.assertIn("'test'", psql_calls[2])

    def test_run_project_operation_restore_failure_drops_target_and_surfaces_pg_restore_error(self):
        restore_payload = {
            "target_database_name": "dd_test_restore_target",
            "artifact_path": "deploydash/postgres/test/daily-main/sample.dump",
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        host_outputs = [
            (True, _FakeOutput()),
            (
                False,
                _FakeOutput(
                    stdout_lines=["restore_target_created=1"],
                    stderr_lines=["pg_restore: duplicate key value violates unique constraint"],
                ),
            ),
        ]
        force_drop_commands = []
        fake_host = _FakeHost()

        def run_direct_command(command, *_args, **_kwargs):
            """Record only the cleanup command while allowing ownership preflights."""
            if "dropdb -U" in command:
                force_drop_commands.append(command)
            return True, _FakeOutput()

        fake_host.run_shell_command = run_direct_command

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda output: "; ".join(output.stderr_lines) or None,
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=fake_host),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_restore_payload=lambda *_args, **_kwargs: restore_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
            _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                True,
                _FakeOutput(stdout_lines=["0"]),
            ),
            _postgres_output_has_one=lambda _output: False,
            _ensure_postgres_project_registry=lambda *_args, **_kwargs: None,
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "restore_run_now",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "PostgreSQL restore failed.")
        self.assertIn("pg_restore: duplicate key", result["details"])
        self.assertEqual(len(force_drop_commands), 1)
        self.assertIn(
            'dropdb -U "${POSTGRES_USER}" --force --if-exists dd_test_restore_target',
            force_drop_commands[0],
        )

    def _run_restore_failure_case(
        self,
        *,
        host_outputs,
        psql_outputs=(),
        resolver_error=None,
        registry_error=None,
        cleanup_status=True,
        cleanup_stderr=(),
    ):
        """Why: keeps the restore failure matrix focused on distinct boundaries."""
        restore_payload = {
            "target_database_name": "dd_test_restore_target",
            "artifact_path": "deploydash/postgres/test/daily-main/sample.dump",
            "destination": {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        }
        remaining_host_outputs = list(host_outputs)
        remaining_psql_outputs = list(psql_outputs)
        force_drop_commands = []
        fake_host = _FakeHost()

        def run_direct_command(command, *_args, **_kwargs):
            """Apply injected cleanup results only to the forced-drop boundary."""
            if "dropdb -U" in command:
                force_drop_commands.append(command)
                return (
                    cleanup_status,
                    _FakeOutput(stderr_lines=list(cleanup_stderr)),
                )
            return True, _FakeOutput()

        fake_host.run_shell_command = run_direct_command

        def resolve_restore_payload(*_args, **_kwargs):
            """Why: injects either valid restore intent or its validation failure."""
            if resolver_error is not None:
                raise PostgresConfigValidationError(resolver_error)
            return restore_payload

        def command_details(output):
            """Why: surfaces the same stderr the runtime would show to the user."""
            return "; ".join(output.stderr_lines) or None

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=command_details,
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=fake_host),
            },
        )
        with patch.multiple(
            backup_operations,
            _resolve_backup_restore_payload=resolve_restore_payload,
            _postgres_walg_install_command=lambda: "install wal-g",
            _run_postgres_host_command=lambda *_args, **_kwargs: remaining_host_outputs.pop(0),
            _run_postgres_psql_query_impl=lambda *_args, **_kwargs: remaining_psql_outputs.pop(0),
            _ensure_postgres_project_registry=lambda *_args, **_kwargs: registry_error,
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "restore_run_now",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )
        return result, force_drop_commands

    def test_restore_preflight_failures_never_drop_an_uncreated_target(self):
        cases = (
            (
                "invalid payload",
                {
                    "host_outputs": (),
                    "resolver_error": "restore target missing",
                    "expected_code": "ENGINE_VALIDATION_ERROR",
                    "expected_message": "restore target missing",
                },
            ),
            (
                "wal-g install",
                {
                    "host_outputs": ((False, _FakeOutput(stderr_lines=["apt unavailable"])),),
                    "expected_code": "ENGINE_RUNTIME_ERROR",
                    "expected_message": "Could not install wal-g.",
                },
            ),
            (
                "existence query",
                {
                    "host_outputs": ((True, _FakeOutput()),),
                    "psql_outputs": ((False, _FakeOutput(stderr_lines=["query failed"])),),
                    "expected_code": "ENGINE_RUNTIME_ERROR",
                    "expected_message": "Could not validate restore target database.",
                },
            ),
            (
                "target exists",
                {
                    "host_outputs": ((True, _FakeOutput()),),
                    "psql_outputs": ((True, _FakeOutput(stdout_lines=["1"])),),
                    "expected_code": "ENGINE_VALIDATION_ERROR",
                    "expected_message": "Target database already exists.",
                },
            ),
            (
                "registry preflight",
                {
                    "host_outputs": ((True, _FakeOutput()),),
                    "psql_outputs": ((True, _FakeOutput(stdout_lines=["0"])),),
                    "registry_error": _error_result(
                        "ENGINE_RUNTIME_ERROR",
                        "Could not ensure the PostgreSQL ownership registry.",
                        stage="execute_runtime_operation",
                        details="registry unavailable",
                    ),
                    "expected_code": "ENGINE_RUNTIME_ERROR",
                    "expected_message": "Could not ensure the PostgreSQL ownership registry.",
                },
            ),
            (
                "artifact check",
                {
                    "host_outputs": (
                        (True, _FakeOutput()),
                        (False, _FakeOutput(stderr_lines=["unsupported manifest"])),
                    ),
                    "psql_outputs": ((True, _FakeOutput(stdout_lines=["0"])),),
                    "expected_code": "ENGINE_RUNTIME_ERROR",
                    "expected_message": "PostgreSQL restore failed.",
                },
            ),
        )
        for label, case in cases:
            with self.subTest(boundary=label):
                expected_code = case.pop("expected_code")
                expected_message = case.pop("expected_message")
                result, drops = self._run_restore_failure_case(**case)
                self.assertEqual(result["status"], "error")
                self.assertEqual(result["code"], expected_code)
                self.assertIn(expected_message, result["msg"])
                self.assertEqual(drops, [])

    def test_restore_verification_and_registry_failures_drop_the_target(self):
        created = _FakeOutput(stdout_lines=["restore_target_created=1"])
        cases = (
            (
                "verification command",
                {
                    "psql_outputs": (
                        (True, _FakeOutput(stdout_lines=["0"])),
                        (False, _FakeOutput(stderr_lines=["connection lost"])),
                    ),
                    "expected_message": "Could not verify PostgreSQL restore.",
                    "expected_details": "connection lost",
                },
            ),
            (
                "verification result",
                {
                    "psql_outputs": (
                        (True, _FakeOutput(stdout_lines=["0"])),
                        (True, _FakeOutput(stdout_lines=["0"])),
                    ),
                    "expected_message": "Could not verify PostgreSQL restore.",
                    "expected_details": "did not confirm",
                },
            ),
            (
                "registration query",
                {
                    "psql_outputs": (
                        (True, _FakeOutput(stdout_lines=["0"])),
                        (True, _FakeOutput(stdout_lines=["1"])),
                        (False, _FakeOutput(stderr_lines=["insert denied"])),
                    ),
                    "expected_message": "Could not register restored PostgreSQL database.",
                    "expected_details": "insert denied",
                },
            ),
            (
                "registration fallback",
                {
                    "psql_outputs": (
                        (True, _FakeOutput(stdout_lines=["0"])),
                        (True, _FakeOutput(stdout_lines=["1"])),
                        (False, _FakeOutput()),
                    ),
                    "expected_message": "Could not register restored PostgreSQL database.",
                    "expected_details": "remote command failed",
                },
            ),
        )
        for label, case in cases:
            with self.subTest(boundary=label):
                expected_message = case.pop("expected_message")
                expected_details = case.pop("expected_details")
                result, drops = self._run_restore_failure_case(
                    host_outputs=((True, _FakeOutput()), (True, created)),
                    **case,
                )
                self.assertEqual(result["status"], "error")
                self.assertEqual(result["msg"], expected_message)
                self.assertIn(expected_details, result["details"])
                self.assertEqual(len(drops), 1)

    def test_restore_reports_when_failed_target_cleanup_also_fails(self):
        result, drops = self._run_restore_failure_case(
            host_outputs=(
                (True, _FakeOutput()),
                (
                    False,
                    _FakeOutput(
                        stdout_lines=["restore_target_created=1"],
                        stderr_lines=["pg_restore: corrupt archive"],
                    ),
                ),
            ),
            psql_outputs=((True, _FakeOutput(stdout_lines=["0"])),),
            cleanup_status=False,
            cleanup_stderr=("database is being accessed",),
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(len(drops), 1)
        self.assertIn("pg_restore: corrupt archive", result["details"])
        self.assertIn("Cleanup also failed", result["details"])
        self.assertIn("Stop the app or worker", result["details"])

    def test_run_project_operation_import_local_sql_success(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"CREATE TABLE demo(id integer);")
            handle.flush()

            host_outputs = [
                (
                    True,
                    _FakeOutput(
                        stdout_lines=[
                            engine_postgres_ops._LOCAL_SQL_IMPORT_SUCCESS_MARKER,
                        ],
                    ),
                ),
                (True, _FakeOutput()),
            ]
            uploaded = []
            host_commands = []

            def run_host_command(_ctx, _session, command, **_kwargs):
                host_commands.append(command)
                return host_outputs.pop(0)

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=run_host_command,
                _upload_local_sql_import_file=lambda _ctx, **kwargs: (
                    uploaded.append(kwargs)
                    or {
                        "local_file_path": kwargs["local_path"],
                        "remote_path": kwargs["remote_path"],
                        "size_bytes": 30,
                    }
                ),
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["database_name"], "restore_target")
        self.assertEqual(result["remote_database_name"], "dd_test_restore_target")
        self.assertEqual(result["target_database_name"], "dd_test_restore_target")
        self.assertEqual(uploaded[0]["local_path"], handle.name)
        self.assertIn(
            engine_postgres_ops._LOCAL_SQL_IMPORT_SUCCESS_MARKER,
            host_commands[0],
        )

    def test_run_project_operation_import_local_sql_rejects_failed_command(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"THIS IS NOT VALID SQL;")
            handle.flush()

            host_outputs = [
                (False, _FakeOutput(stderr_lines=["psql: syntax error"])),
                (True, _FakeOutput()),
            ]

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "psql: syntax error",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
                _upload_local_sql_import_file=lambda _ctx, **_kwargs: {},
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "PostgreSQL local SQL restore failed.")
        self.assertEqual(result["details"], "psql: syntax error")

    def test_run_project_operation_import_local_sql_requires_completion_marker(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"THIS IS NOT VALID SQL;")
            handle.flush()

            host_outputs = [
                (True, _FakeOutput(stderr_lines=["psql: syntax error"])),
                (True, _FakeOutput()),
            ]

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: None,
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
                _upload_local_sql_import_file=lambda _ctx, **_kwargs: {},
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "PostgreSQL local SQL restore failed.")
        self.assertEqual(
            result["details"],
            "PostgreSQL did not confirm SQL import completion.",
        )

    def test_run_project_operation_import_local_sql_cancel_during_upload_cleans_up(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"SELECT 1;")
            handle.flush()

            host_commands = []

            def run_host_command(_ctx, _session, command, **_kwargs):
                """Why: captures the staging-dir cleanup for the assertion."""
                host_commands.append(command)
                return (True, _FakeOutput())

            def raise_cancelled(_ctx, **_kwargs):
                """Why: fails the upload exactly like a mid-stream cancel."""
                raise local_sql_import._PostgresLocalImportCancelled(
                    "Task cancelled during local SQL upload",
                )

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=run_host_command,
                _upload_local_sql_import_file=raise_cancelled,
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(len(host_commands), 1)
        self.assertIn("rm -rf", host_commands[0])

    def test_run_project_operation_import_local_sql_upload_failure_cleans_up(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"SELECT 1;")
            handle.flush()

            host_commands = []

            def run_host_command(_ctx, _session, command, **_kwargs):
                """Why: captures the staging-dir cleanup for the assertion."""
                host_commands.append(command)
                return (True, _FakeOutput())

            def raise_failed(_ctx, **_kwargs):
                """Why: fails the upload exactly like a broken SSH stream."""
                raise RuntimeError("ssh broke")

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=run_host_command,
                _upload_local_sql_import_file=raise_failed,
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not upload local SQL file.")
        self.assertEqual(result["details"], "ssh broke")
        self.assertEqual(len(host_commands), 1)
        self.assertIn("rm -rf", host_commands[0])

    def test_run_project_operation_import_local_sql_rejects_blocked_dump(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"CREATE TABLE demo(id integer);\nCREATE DATABASE otherdb;\n")
            handle.flush()

            uploaded = []
            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(
                        stdout_lines=[
                            engine_postgres_ops._LOCAL_SQL_IMPORT_SUCCESS_MARKER,
                        ],
                    ),
                ),
                _upload_local_sql_import_file=lambda _ctx, **kwargs: uploaded.append(kwargs) or {},
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("without pg_dump -C", result["msg"])
        self.assertEqual(result["details"], "create_database at line 2")
        self.assertEqual(uploaded, [])

    def test_run_project_operation_import_local_sql_reports_further_findings(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"CREATE DATABASE otherdb;\nCREATE ROLE otherrole;\n")
            handle.flush()

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(),
                ),
                _upload_local_sql_import_file=lambda _ctx, **_kwargs: {},
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("(1 more)", result["details"])

    def test_run_project_operation_import_local_sql_rejects_ownership_without_opt_in(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(
                b"CREATE TABLE demo(id integer);\n"
                b"ALTER TABLE demo OWNER TO otherrole;\n"
                b"GRANT SELECT ON demo TO otherrole;\n"
            )
            handle.flush()

            uploaded = []
            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(),
                ),
                _upload_local_sql_import_file=lambda _ctx, **kwargs: uploaded.append(kwargs) or {},
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("(2 found)", result["msg"])
        self.assertIn("--no-owner", result["msg"])
        self.assertEqual(uploaded, [])

    def test_run_project_operation_import_local_sql_filters_ownership_when_opted_in(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(
                b"CREATE TABLE demo(id integer);\n"
                b"ALTER TABLE demo OWNER TO otherrole;\n"
                b"GRANT SELECT ON demo TO otherrole;\n"
            )
            handle.flush()

            uploaded_paths = []
            uploaded_bytes = []
            events = []

            def capture_upload(_ctx, **kwargs):
                """Why: reads the staged bytes before the temp file is gone."""
                uploaded_paths.append(kwargs["local_path"])
                with open(kwargs["local_path"], "rb") as staged:
                    uploaded_bytes.append(staged.read())
                return {
                    "local_file_path": kwargs["local_path"],
                    "remote_path": kwargs["remote_path"],
                    "size_bytes": len(uploaded_bytes[-1]),
                }

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: events.append((args, kwargs)),
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(
                        stdout_lines=[
                            engine_postgres_ops._LOCAL_SQL_IMPORT_SUCCESS_MARKER,
                        ],
                    ),
                ),
                _upload_local_sql_import_file=capture_upload,
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                            "import_ignore_ownership": True,
                        },
                    },
                )

        self.assertEqual(result["status"], "success")
        self.assertNotEqual(uploaded_paths[0], handle.name)
        self.assertNotIn(b"OWNER TO", uploaded_bytes[0])
        self.assertNotIn(b"GRANT SELECT", uploaded_bytes[0])
        self.assertIn(b"CREATE TABLE demo", uploaded_bytes[0])
        self.assertEqual(result["imported_size_bytes"], len(uploaded_bytes[0]))
        self.assertFalse(os.path.exists(uploaded_paths[0]))
        names = [args[1] for args, _kwargs in events]
        self.assertIn("postgres_local_sql_ownership_filtered", names)

    def test_run_project_operation_import_local_sql_filters_enabled_extensions(self):
        """Upload no managed extension DDL while preserving application comments."""
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(
                b"CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA public;\n"
                b"COMMENT ON EXTENSION hstore IS 'key value store';\n"
                b"CREATE TABLE demo(id integer);\n"
                b"COMMENT ON TABLE demo IS 'application table';\n"
            )
            handle.flush()
            uploaded_bytes = []
            events = []

            def capture_upload(_ctx, **kwargs):
                """Why: captures the filtered file before its guaranteed cleanup."""
                with open(kwargs["local_path"], "rb") as staged:
                    uploaded_bytes.append(staged.read())
                return {}

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: events.append((args, kwargs)),
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(
                        stdout_lines=[engine_postgres_ops._LOCAL_SQL_IMPORT_SUCCESS_MARKER],
                    ),
                ),
                _upload_local_sql_import_file=capture_upload,
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                            "enabled_extensions": ["hstore"],
                        },
                    },
                )

        self.assertEqual(result["status"], "success")
        self.assertNotIn(b"EXTENSION hstore", uploaded_bytes[0])
        self.assertIn(b"COMMENT ON TABLE demo", uploaded_bytes[0])
        names = [args[1] for args, _kwargs in events]
        self.assertIn("postgres_local_sql_extensions_filtered", names)

    def test_run_project_operation_import_local_sql_requires_owner_normalization(self):
        """Guide legacy databases to Normalize instead of failing role setup."""
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"CREATE TABLE demo(id integer);\n")
            handle.flush()
            psql_outputs = [
                (True, _FakeOutput(stdout_lines=["1"])),
                (True, _FakeOutput(stdout_lines=["0"])),
            ]
            uploaded = []
            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: psql_outputs.pop(0),
                _run_postgres_host_command=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(
                        stdout_lines=[engine_postgres_ops._LOCAL_SQL_IMPORT_SUCCESS_MARKER],
                    ),
                ),
                _upload_local_sql_import_file=lambda _ctx, **kwargs: uploaded.append(kwargs),
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("Normalize", result["msg"])
        self.assertEqual(uploaded, [])

    def test_run_project_operation_import_local_sql_reports_owner_probe_failure(self):
        """Surface an owner-role catalog failure before uploading any dump."""
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"CREATE TABLE demo(id integer);\n")
            handle.flush()
            psql_outputs = [
                (True, _FakeOutput(stdout_lines=["1"])),
                (False, _FakeOutput(stderr_lines=["catalog unavailable"])),
            ]
            uploaded = []
            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "catalog unavailable",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: psql_outputs.pop(0),
                _upload_local_sql_import_file=lambda _ctx, **kwargs: uploaded.append(kwargs),
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not validate the database owner role.")
        self.assertEqual(result["details"], "catalog unavailable")
        self.assertEqual(uploaded, [])

    def test_run_project_operation_import_local_sql_reports_unreadable_dump(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"SELECT 1;")
            handle.flush()

            def raise_unreadable(_path, **_kwargs):
                """Why: fails the scan exactly like an unreadable file."""
                raise OSError("disk gone")

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _scan_local_sql_dump=raise_unreadable,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(),
                ),
                _upload_local_sql_import_file=lambda _ctx, **_kwargs: {},
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("pre-flight scan", result["msg"])
        self.assertEqual(result["details"], "disk gone")

    def test_run_project_operation_import_local_sql_shell_notice_is_a_warning(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"SELECT 1;\n\\! id\n")
            handle.flush()

            events = []
            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: events.append((args, kwargs)),
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(
                        stdout_lines=[
                            engine_postgres_ops._LOCAL_SQL_IMPORT_SUCCESS_MARKER,
                        ],
                    ),
                ),
                _upload_local_sql_import_file=lambda _ctx, **_kwargs: {},
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "success")
        notices = [
            (args, kwargs)
            for args, kwargs in events
            if args[1] == "postgres_local_sql_import_notice"
        ]
        self.assertEqual(len(notices), 1)
        self.assertIn("throwaway", notices[0][0][2])
        self.assertEqual(notices[0][1].get("level"), "warning")

    def test_run_project_operation_import_local_sql_reports_filter_write_failure(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"ALTER TABLE demo OWNER TO otherrole;\n")
            handle.flush()

            def raise_unwritable(_source, _dest, **_kwargs):
                """Why: fails staging exactly like a full workstation disk."""
                raise OSError("disk full")

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _write_filtered_sql_dump=raise_unwritable,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(),
                ),
                _upload_local_sql_import_file=lambda _ctx, **_kwargs: {},
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                            "import_ignore_ownership": True,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("stage the filtered", result["msg"])
        self.assertEqual(result["details"], "disk full")

    def test_run_project_operation_import_local_sql_reports_filter_temp_failure(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"ALTER TABLE demo OWNER TO otherrole;\n")
            handle.flush()

            def raise_no_temp(**_kwargs):
                """Why: fails staging before any temp file exists to drop."""
                raise OSError("no temp space")

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with (
                patch.multiple(
                    local_sql_import,
                    _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                        True,
                        _FakeOutput(stdout_lines=["1"]),
                    ),
                    _run_postgres_host_command=lambda *_args, **_kwargs: (
                        True,
                        _FakeOutput(),
                    ),
                    _upload_local_sql_import_file=lambda _ctx, **_kwargs: {},
                ),
                patch.object(
                    local_sql_import.tempfile,
                    "NamedTemporaryFile",
                    raise_no_temp,
                ),
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                            "import_ignore_ownership": True,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("stage the filtered", result["msg"])
        self.assertEqual(result["details"], "no temp space")

    def test_run_project_operation_import_local_sql_uses_temp_role_and_throwaway_client(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"CREATE TABLE demo(id integer);")
            handle.flush()

            psql_calls = []
            host_commands = []

            def record_psql(_ctx, _session, _config, sql, database="postgres", **_kwargs):
                """Why: records every server-side statement for the wiring proof."""
                psql_calls.append((sql, database))
                return (True, _FakeOutput(stdout_lines=["1"]))

            def run_host_command(_ctx, _session, command, **_kwargs):
                """Why: captures the throwaway-client command for the proof."""
                host_commands.append(command)
                return (
                    True,
                    _FakeOutput(
                        stdout_lines=[
                            engine_postgres_ops._LOCAL_SQL_IMPORT_SUCCESS_MARKER,
                        ],
                    ),
                )

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            owner_name = local_sql_import.server_identifiers.postgres_owner_role_name(
                "dd_test_restore_target",
            )
            with (
                patch.multiple(
                    local_sql_import,
                    _run_postgres_psql_query_impl=record_psql,
                    _run_postgres_host_command=run_host_command,
                    _upload_local_sql_import_file=lambda _ctx, **_kwargs: {},
                    _postgres_generated_password=lambda: "fixed-temp-password",
                ),
                patch.object(
                    local_sql_import.secrets,
                    "token_hex",
                    lambda _size=16: "a1b2c3d4e5f60718",
                ),
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "success")
        self.assertEqual(len(psql_calls), 4)
        create_sql = psql_calls[2][0]
        self.assertIn(
            'CREATE ROLE "deploydash_import_a1b2c3d4e5f60718" LOGIN '
            "PASSWORD 'fixed-temp-password' ",
            create_sql,
        )
        # VALID UNTIL takes a timestamp literal, never an expression.
        self.assertRegex(
            create_sql,
            r"VALID UNTIL '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\+00'",
        )
        self.assertNotIn("now()", create_sql)
        self.assertIn(
            'GRANT CONNECT ON DATABASE "dd_test_restore_target" '
            'TO "deploydash_import_a1b2c3d4e5f60718";',
            create_sql,
        )
        self.assertIn(
            f'GRANT "{owner_name}" TO "deploydash_import_a1b2c3d4e5f60718";',
            create_sql,
        )
        drop_sql, drop_database = psql_calls[3]
        self.assertEqual(drop_database, "dd_test_restore_target")
        self.assertIn(
            'REASSIGN OWNED BY "deploydash_import_a1b2c3d4e5f60718"',
            drop_sql,
        )
        self.assertIn(
            'DROP ROLE IF EXISTS "deploydash_import_a1b2c3d4e5f60718";',
            drop_sql,
        )
        import_command = host_commands[0]
        self.assertIn("docker run --rm", import_command)
        self.assertIn("--single-transaction", import_command)
        self.assertIn("-h host.docker.internal", import_command)
        self.assertIn("deploydash_import_a1b2c3d4e5f60718", import_command)
        self.assertIn("fixed-temp-password", import_command)
        self.assertIn(f"role={owner_name}", import_command)
        self.assertNotIn('"${CONTAINER_NAME}" psql', import_command)
        client_part = import_command.split("docker run --rm", 1)[1]
        self.assertNotIn("docker exec", client_part)

    def test_run_project_operation_import_local_sql_create_role_failure_drops_and_reports(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"CREATE TABLE demo(id integer);")
            handle.flush()

            psql_calls = []
            psql_outputs = [
                (True, _FakeOutput(stdout_lines=["1"])),
                (True, _FakeOutput(stdout_lines=["1"])),
                (False, _FakeOutput(stderr_lines=["create failed"])),
                (True, _FakeOutput()),
            ]
            host_commands = []

            def record_psql(_ctx, _session, _config, sql, database="postgres", **_kwargs):
                """Why: fails the create call so the drop path is exercised."""
                psql_calls.append((sql, database))
                return psql_outputs.pop(0)

            def run_host_command(_ctx, _session, command, **_kwargs):
                """Why: captures the staging-dir cleanup for the assertion."""
                host_commands.append(command)
                return (True, _FakeOutput())

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "create failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=record_psql,
                _run_postgres_host_command=run_host_command,
                _upload_local_sql_import_file=lambda _ctx, **_kwargs: {},
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not prepare the temporary import role.")
        self.assertEqual(len(psql_calls), 4)
        self.assertIn("DROP ROLE IF EXISTS", psql_calls[3][0])
        self.assertEqual(len(host_commands), 1)
        self.assertIn("rm -rf", host_commands[0])

    def test_run_project_operation_import_local_sql_import_failure_drops_role_and_cleans_up(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"CREATE TABLE demo(id integer);")
            handle.flush()

            psql_calls = []
            host_outputs = [
                (False, _FakeOutput(stderr_lines=["psql: restore failed"])),
                (True, _FakeOutput()),
            ]

            def record_psql(_ctx, _session, _config, sql, database="postgres", **_kwargs):
                """Why: records create and drop around the failed import."""
                psql_calls.append((sql, database))
                return (True, _FakeOutput(stdout_lines=["1"]))

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "psql: restore failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=record_psql,
                _run_postgres_host_command=lambda *_args, **_kwargs: host_outputs.pop(0),
                _upload_local_sql_import_file=lambda _ctx, **_kwargs: {},
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "PostgreSQL local SQL restore failed.")
        self.assertEqual(len(psql_calls), 4)
        self.assertIn("REASSIGN OWNED BY", psql_calls[3][0])

    def test_run_project_operation_import_local_sql_role_drop_failure_warns_but_succeeds(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"CREATE TABLE demo(id integer);")
            handle.flush()

            psql_calls = []
            psql_outputs = [
                (True, _FakeOutput(stdout_lines=["1"])),
                (True, _FakeOutput(stdout_lines=["1"])),
                (True, _FakeOutput()),
                (False, _FakeOutput(stderr_lines=["drop failed"])),
            ]
            events = []

            def record_psql(_ctx, _session, _config, sql, database="postgres", **_kwargs):
                """Why: fails the drop call so the warning path is exercised."""
                psql_calls.append((sql, database))
                return psql_outputs.pop(0)

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *args, **kwargs: events.append((args, kwargs)),
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "drop failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=record_psql,
                _run_postgres_host_command=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(
                        stdout_lines=[
                            engine_postgres_ops._LOCAL_SQL_IMPORT_SUCCESS_MARKER,
                        ],
                    ),
                ),
                _upload_local_sql_import_file=lambda _ctx, **_kwargs: {},
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "success")
        self.assertEqual(len(psql_calls), 4)
        warnings = [
            (args, kwargs)
            for args, kwargs in events
            if args[1] == "postgres_local_sql_role_cleanup_warning"
        ]
        self.assertEqual(len(warnings), 1)
        self.assertEqual(warnings[0][1].get("level"), "warning")
        self.assertIn("expires", warnings[0][0][2])

    def test_run_project_operation_import_local_sql_restores_custom_dumps(self):
        with tempfile.NamedTemporaryFile(suffix=".dump") as handle:
            # The scanner would reject this content as a plain dump, so a
            # success proves custom-format files skip the pre-flight scan
            # and restore through pg_restore instead.
            handle.write(b"PGDMP\x00CREATE DATABASE otherdb;")
            handle.flush()

            uploaded_paths = []
            host_commands = []

            def capture_upload(_ctx, **kwargs):
                """Why: proves the original bytes upload without filtering."""
                uploaded_paths.append(kwargs["local_path"])
                return {
                    "local_file_path": kwargs["local_path"],
                    "remote_path": kwargs["remote_path"],
                    "size_bytes": 999,
                }

            def run_host_command(_ctx, _session, command, **_kwargs):
                """Why: captures the pg_restore command for the assertion."""
                host_commands.append(command)
                return (
                    True,
                    _FakeOutput(
                        stdout_lines=[
                            engine_postgres_ops._LOCAL_SQL_IMPORT_SUCCESS_MARKER,
                        ],
                    ),
                )

            ctx = build_test_context(
                error_result=_error_result,
                emit_event=lambda *_args, **_kwargs: None,
                emit_shell_output_lines=lambda *_args, **_kwargs: None,
                command_error_details=lambda _output: "remote failed",
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": _FakeSession(host=_FakeHost()),
                },
            )
            owner_name = local_sql_import.server_identifiers.postgres_owner_role_name(
                "dd_test_restore_target",
            )
            with patch.multiple(
                local_sql_import,
                _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                    True,
                    _FakeOutput(stdout_lines=["1"]),
                ),
                _run_postgres_host_command=run_host_command,
                _upload_local_sql_import_file=capture_upload,
            ):
                result = engine_postgres_ops.run_postgres_project_operation(
                    ctx,
                    "import_local_sql",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "postgres_version": "17",
                            "superuser_password": "secret",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                )

        self.assertEqual(result["status"], "success")
        self.assertEqual(uploaded_paths, [handle.name])
        restore_command = host_commands[0]
        self.assertIn("pg_restore", restore_command)
        self.assertIn("--no-owner --no-privileges", restore_command)
        self.assertIn("--single-transaction", restore_command)
        self.assertIn("--exit-on-error", restore_command)
        self.assertIn(f"--role={owner_name}", restore_command)
        self.assertNotIn("psql -v ON_ERROR_STOP", restore_command)

    def test_run_project_operation_backup_policy_delete_success(self):
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=_FakeHost()),
            },
        )
        with patch.multiple(
            backup_operations,
            _postgres_backup_policy_delete_command=lambda *_args, **_kwargs: "delete policy",
            _run_postgres_host_command=lambda *_args, **_kwargs: (
                True,
                _FakeOutput(stdout_lines=["removed_backup_policy=daily-main"]),
            ),
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "backup_policy_delete",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                        "backup_policy_id": "daily-main",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["backup_policy_id"], "daily-main")
        self.assertEqual(result["removed_backup_policies"], ["daily-main"])
        self.assertEqual(result["removed_backup_policy_count"], 1)
        self.assertTrue(result["backup_logs_removed"])


if __name__ == "__main__":
    unittest.main()
