import json
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from orchestrator import postgres_backup as postgres_backup_module
from orchestrator.postgres_backup import (
    POSTGRES_BACKUP_MANIFEST_FORMAT_VERSION,
    _backup_policy_environment_body,
    backup_artifact_key,
    backup_env_assignments,
    backup_env_export_block,
    backup_remote_base_path,
    normalize_backup_artifact_path,
    normalize_backup_hhmm,
    normalize_backup_policy_token,
    normalize_backup_s3_endpoint,
    normalize_backup_s3_prefix,
    postgres_backlog_beyond_retention,
    postgres_backup_backlog_cleanup_command,
    postgres_backup_destination_test_command,
    postgres_backup_manifest_write_command,
    postgres_backup_policy_apply_command,
    postgres_backup_policy_delete_command,
    postgres_backup_restore_format_check_command,
    postgres_parse_backup_artifacts_output,
    postgres_parse_backup_cleanup_output,
    postgres_parse_backup_policy_cleanup_output,
    postgres_parse_backup_run_output,
    postgres_project_backup_policies_delete_command,
    postgres_service_backup_policies_delete_command,
    postgres_walg_install_command,
    resolve_backup_destination,
    resolve_backup_policy_payload,
    resolve_backup_restore_payload,
)
from orchestrator.postgres_parts import (
    PostgresConfigValidationError,
    parse_postgres_service_config,
)


class _FakeOutput:
    def __init__(self, stdout_lines=None):
        self.stdout_lines = stdout_lines or []


def _config(**settings):
    payload = {"settings": {"postgres_version": "17", "superuser_password": "secret"}}
    payload["settings"].update(settings)
    return parse_postgres_service_config(payload)


def _normalize_postgres_identifier(raw_value, _field_name):
    return str(raw_value).strip().lower().replace("-", "_")


def _postgres_prefixed_name(prefix, raw_value, _field_name):
    base = _normalize_postgres_identifier(raw_value, "field")
    return base if base.startswith(prefix) else f"{prefix}{base}"


# A minimal stand-in for the real `wal-g` CLI, understanding only the `st
# put`/`st get`/`st rm` subset the backup/restore shell snippets use, backed
# by a plain directory instead of real object storage. This is deliberately
# a real subprocess-executed shell script, not a Python mock -- the thing
# under test is bash string generation, and a mock would only prove the
# Python that builds the string is self-consistent, not that the resulting
# shell actually does the right thing when bash parses and runs it.
_FAKE_WALG_SCRIPT = """#!/usr/bin/env bash
set -eu
STORE="$FAKE_WALG_STORE"
sub="$1"; shift
verb="$1"; shift
args=()
for a in "$@"; do
  case "$a" in
    --no-compress|--no-encrypt|--no-decompress|--no-decrypt|-r) ;;
    *) args+=("$a") ;;
  esac
done
case "$sub $verb" in
  "st put")
    mkdir -p "$(dirname "$STORE/${args[1]}")"
    cp "${args[0]}" "$STORE/${args[1]}"
    ;;
  "st get")
    [ -f "$STORE/${args[0]}" ] || exit 1
    cp "$STORE/${args[0]}" "${args[1]}"
    ;;
  "st rm")
    rm -f "$STORE/${args[0]}"
    ;;
  *)
    echo "unhandled fake wal-g invocation: $sub $verb ${args[*]}" >&2
    exit 1
    ;;
esac
"""


def _fake_walg_environment(bin_dir, store_dir):
    walg_path = Path(bin_dir) / "wal-g"
    walg_path.write_text(_FAKE_WALG_SCRIPT, encoding="utf-8")
    walg_path.chmod(0o755)
    environment = dict(os.environ)
    environment["PATH"] = f"{bin_dir}:{environment.get('PATH', '')}"
    environment["FAKE_WALG_STORE"] = str(store_dir)
    return environment


# A fake `wal-g` for the prune phase: `st ls` replays a canned listing (so
# the test controls relative vs full key shape exactly as the real CLI
# prints it) and `st rm` records its argument, then really deletes --
# failing when the key is missing, like `wal-g st rm` does (#95).
_PRUNE_FAKE_WALG_SCRIPT = """#!/usr/bin/env bash
set -eu
STORE="$FAKE_WALG_STORE"
sub="$1"; shift
verb="$1"; shift
args=()
for a in "$@"; do
  case "$a" in
    --no-compress|--no-encrypt|--no-decompress|--no-decrypt|-r) ;;
    *) args+=("$a") ;;
  esac
done
case "$sub $verb" in
  "st ls")
    cat "$FAKE_WALG_LISTING"
    ;;
  "st rm")
    echo "${args[0]}" >> "$FAKE_WALG_RM_ARGS"
    rm "$STORE/${args[0]}"
    ;;
  *)
    echo "unhandled fake wal-g invocation: $sub $verb ${args[*]}" >&2
    exit 1
    ;;
esac
"""


# Installs the prune-phase fake on PATH: the real prune block runs against
# it, so the tests prove the executed shell, not a Python reimplementation.
def _prune_fake_walg_environment(bin_dir, store_dir, listing_path, rm_args_path):
    walg_path = Path(bin_dir) / "wal-g"
    walg_path.write_text(_PRUNE_FAKE_WALG_SCRIPT, encoding="utf-8")
    walg_path.chmod(0o755)
    environment = dict(os.environ)
    environment["PATH"] = f"{bin_dir}:{environment.get('PATH', '')}"
    environment["FAKE_WALG_STORE"] = str(store_dir)
    environment["FAKE_WALG_LISTING"] = str(listing_path)
    environment["FAKE_WALG_RM_ARGS"] = str(rm_args_path)
    return environment


# Lifts the prune phase verbatim out of the generated apply command, so a
# test that only reworded the block could not pass while the shipped
# script still prunes nothing. The apply command embeds run_backup.sh via
# shlex.quote inside `printf %s ... > "${SCRIPT_PATH}"`; decoding
# reverses exactly that quoting, so the block below is byte-identical to
# what lands on the server.
def _prune_block_from_apply_command(command):
    terminator = ' > "${SCRIPT_PATH}"'
    term_index = command.index(terminator)
    printf_marker = "printf %s "
    blob_start = command.rindex(printf_marker, 0, term_index) + len(printf_marker)
    blob = command[blob_start:term_index]
    if not (blob.startswith("'") and blob.endswith("'")):
        raise AssertionError("embedded run_backup.sh is not single-quote wrapped")
    script_body = blob[1:-1].replace("'\"'\"'", "'")
    block_start = script_body.index("PRUNE_FAILURES=0\n")
    block = script_body[block_start:]
    if not block.rstrip().endswith("fi"):
        raise AssertionError("prune block no longer ends the generated script")
    return block


# Runs the extracted prune block under bash with the same shell options
# the generated script uses, so quoting and failure semantics match the
# server exactly.
def _run_prune_block(block, *, keep_last, base_path, environment):
    prelude = (
        "set -euo pipefail\n"
        f"BACKUP_RETENTION_KEEP_LAST={keep_last}\n"
        f"BACKUP_REMOTE_BASE_PATH={base_path}\n"
    )
    return subprocess.run(
        ["bash", "-c", prelude + block],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


# Builds the apply command the prune tests extract their block from: one
# call site, so the extraction markers stay honest by construction.
def _prune_apply_command():
    config = _config()
    plan = postgres_backup_policy_apply_command(
        config,
        policy_token="daily-main",
        task_token="backup-pg-daily-main",
        policy_name="Daily Main",
        project_slug="test",
        database_name="dd_test_app",
        schedule_mode="daily_once",
        time1="02:00",
        time2=None,
        retention_keep_last=7,
        enabled=True,
        destination={"type": "filesystem", "prefix": "/var/backups/deploydash"},
    )
    return plan["command"]


class TestPostgresBackup(unittest.TestCase):
    # Lifecycle reporting must ignore shell noise and repeated markers while
    # preserving first-removal order for the UI summary (#90).
    def test_backup_policy_cleanup_parser_is_unique_and_noise_tolerant(self):
        self.assertEqual(
            postgres_parse_backup_policy_cleanup_output(
                _FakeOutput(
                    [
                        "noise",
                        "other_key=value",
                        "removed_backup_policy=",
                        "removed_backup_policy=nightly",
                        "removed_backup_policy=daily",
                        "removed_backup_policy=nightly",
                    ],
                ),
            ),
            ["nightly", "daily"],
        )
        self.assertEqual(
            postgres_parse_backup_policy_cleanup_output(SimpleNamespace()),
            [],
        )

    # A project cleanup must use the policy's exact recorded project and leave
    # a similarly named project's scheduler untouched (#90).
    def test_project_backup_policy_cleanup_is_exact_and_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            policy_root = root / "stack" / "backups" / "policies"
            cron_root = root / "cron"
            log_root = root / "log"
            cron_root.mkdir()
            log_root.mkdir()
            for project_slug, token in (("shop", "daily"), ("shops", "nightly")):
                policy_dir = policy_root / token
                policy_dir.mkdir(parents=True)
                (policy_dir / "walg.env").write_text(
                    f"BACKUP_REMOTE_BASE_PATH={backup_remote_base_path(project_slug, token)}\n",
                    encoding="utf-8",
                )
                (cron_root / f"managed-{token}").write_text("cron", encoding="utf-8")
                (log_root / f"backup-{token}.log").write_text("log", encoding="utf-8")

            config = SimpleNamespace(stack_root=str(root / "stack"))
            with (
                patch.object(
                    postgres_backup_module.server_paths,
                    "postgres_backup_cron_file",
                    side_effect=lambda token: str(cron_root / f"managed-{token}"),
                ),
                patch.object(
                    postgres_backup_module.server_paths,
                    "postgres_backup_log",
                    side_effect=lambda token: str(log_root / f"backup-{token}.log"),
                ),
            ):
                command = postgres_project_backup_policies_delete_command(
                    config,
                    "shop",
                )

            first = subprocess.run(
                ["bash", "-c", command],
                check=False,
                capture_output=True,
                text=True,
            )
            second = subprocess.run(
                ["bash", "-c", command],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(
                postgres_parse_backup_policy_cleanup_output(
                    _FakeOutput(first.stdout.splitlines()),
                ),
                ["daily"],
            )
            self.assertEqual(
                postgres_parse_backup_policy_cleanup_output(
                    _FakeOutput(second.stdout.splitlines()),
                ),
                [],
            )
            self.assertFalse((policy_root / "daily").exists())
            self.assertFalse((cron_root / "managed-daily").exists())
            self.assertFalse((log_root / "backup-daily.log").exists())
            self.assertTrue((policy_root / "nightly").is_dir())
            self.assertTrue((cron_root / "managed-nightly").is_file())
            self.assertTrue((log_root / "backup-nightly.log").is_file())

    # Service cleanup must find partial remnants through all three managed
    # locations, report each policy once, and make a rerun a no-op (#90).
    def test_service_backup_policy_cleanup_removes_partial_remnants(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            policy_root = root / "stack" / "backups" / "policies"
            cron_root = root / "cron"
            log_root = root / "log"
            (policy_root / "complete").mkdir(parents=True)
            cron_root.mkdir()
            log_root.mkdir()
            (cron_root / "managed-complete").write_text("cron", encoding="utf-8")
            (cron_root / "managed-cron-only").write_text("cron", encoding="utf-8")
            (log_root / "backup-complete.log").write_text("log", encoding="utf-8")
            (log_root / "backup-log-only.log").write_text("log", encoding="utf-8")

            config = SimpleNamespace(stack_root=str(root / "stack"))
            with (
                patch.object(
                    postgres_backup_module.server_paths,
                    "postgres_backup_cron_file",
                    side_effect=lambda token: str(cron_root / f"managed-{token}"),
                ),
                patch.object(
                    postgres_backup_module.server_paths,
                    "postgres_backup_log",
                    side_effect=lambda token: str(log_root / f"backup-{token}.log"),
                ),
            ):
                command = postgres_service_backup_policies_delete_command(config)

            first = subprocess.run(
                ["bash", "-c", command],
                check=False,
                capture_output=True,
                text=True,
            )
            second = subprocess.run(
                ["bash", "-c", command],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(
                postgres_parse_backup_policy_cleanup_output(
                    _FakeOutput(first.stdout.splitlines()),
                ),
                ["complete", "cron-only", "log-only"],
            )
            self.assertEqual(
                postgres_parse_backup_policy_cleanup_output(
                    _FakeOutput(second.stdout.splitlines()),
                ),
                [],
            )
            self.assertEqual(list(policy_root.iterdir()), [])
            self.assertEqual(list(cron_root.iterdir()), [])
            self.assertEqual(list(log_root.iterdir()), [])

    def test_normalizers_and_paths(self):
        self.assertEqual(
            normalize_backup_policy_token("Daily Main Policy!!", "field"),
            "daily-main-policy",
        )
        self.assertEqual(
            normalize_backup_hhmm("2:05", "field", "02:00"),
            "02:05",
        )
        self.assertEqual(
            normalize_backup_artifact_path("/deploydash/postgres/app.dump", "field"),
            "deploydash/postgres/app.dump",
        )
        self.assertEqual(
            backup_remote_base_path("my-project", "daily-main"),
            "deploydash/postgres/my-project/daily-main",
        )
        self.assertEqual(
            normalize_backup_s3_prefix("DeployDash", "field"),
            "s3://deploydash",
        )
        self.assertEqual(
            normalize_backup_s3_prefix("DeployDash/backups/postgres", "field"),
            "s3://deploydash/backups/postgres",
        )
        self.assertEqual(
            normalize_backup_s3_endpoint("s3.eu-central-003.backblazeb2.com", "field"),
            "https://s3.eu-central-003.backblazeb2.com",
        )
        self.assertEqual(
            normalize_backup_s3_endpoint("http://localhost:9000", "field"),
            "http://localhost:9000",
        )
        self.assertEqual(normalize_backup_s3_endpoint(None, "field"), "")
        self.assertEqual(normalize_backup_s3_endpoint("   ", "field"), "")
        self.assertEqual(
            normalize_backup_policy_token("__leading", "field"),
            "p-leading",
        )
        self.assertEqual(
            normalize_backup_policy_token("a" * 90, "field"),
            "a" * 80,
        )
        with self.assertRaises(PostgresConfigValidationError):
            normalize_backup_s3_prefix(None, "field")
        with self.assertRaises(PostgresConfigValidationError):
            normalize_backup_policy_token(None, "field")
        with self.assertRaises(PostgresConfigValidationError):
            normalize_backup_policy_token("!!!", "field")
        with self.assertRaises(PostgresConfigValidationError):
            normalize_backup_policy_token("__", "field")
        with self.assertRaises(PostgresConfigValidationError):
            normalize_backup_hhmm("29:00", "field", "02:00")
        with self.assertRaises(PostgresConfigValidationError):
            normalize_backup_artifact_path(None, "field")
        with self.assertRaises(PostgresConfigValidationError):
            normalize_backup_artifact_path("bad path", "field")
        with self.assertRaises(PostgresConfigValidationError):
            normalize_backup_artifact_path("../secret.dump", "field")
        with self.assertRaises(PostgresConfigValidationError):
            normalize_backup_s3_prefix("s3://", "field")
        with self.assertRaises(PostgresConfigValidationError):
            normalize_backup_s3_prefix("bad_bucket", "field")
        with self.assertRaises(PostgresConfigValidationError):
            normalize_backup_s3_prefix("DeployDash/../secret", "field")
        with self.assertRaises(PostgresConfigValidationError):
            normalize_backup_s3_endpoint(3, "field")
        with self.assertRaises(PostgresConfigValidationError):
            normalize_backup_s3_endpoint("https://", "field")

    def test_destination_resolution_and_env_helpers(self):
        s3_destination = resolve_backup_destination(
            _config(
                backup_destination_type="s3",
                backup_s3_prefix="Bucket/Path",
                backup_aws_access_key_id="key",
                backup_aws_secret_access_key="secret",
                backup_aws_region="us-east-1",
                backup_aws_endpoint="s3.example.com",
                backup_aws_force_path_style=True,
            ),
        )
        self.assertEqual(s3_destination["type"], "s3")
        self.assertEqual(s3_destination["prefix"], "s3://bucket/Path")
        self.assertEqual(s3_destination["aws_endpoint"], "https://s3.example.com")
        self.assertIn(
            "export AWS_S3_FORCE_PATH_STYLE=true",
            backup_env_assignments(s3_destination),
        )
        self.assertIn(
            "export WALG_S3_PREFIX=s3://bucket/Path",
            backup_env_export_block(s3_destination),
        )
        self.assertTrue(backup_env_export_block(s3_destination).endswith("; "))

        fs_destination = resolve_backup_destination(
            _config(
                backup_destination_type="filesystem",
                backup_file_prefix="/var/backups/deploydash",
            ),
        )
        self.assertEqual(fs_destination["type"], "filesystem")
        self.assertIn(
            "export WALG_FILE_PREFIX=/var/backups/deploydash",
            backup_env_export_block(fs_destination),
        )

        with self.assertRaises(PostgresConfigValidationError):
            resolve_backup_destination(_config(backup_destination_type="s3"))
        with self.assertRaises(PostgresConfigValidationError):
            resolve_backup_destination(_config(backup_destination_type="ftp"))
        with self.assertRaises(PostgresConfigValidationError):
            resolve_backup_destination(
                _config(
                    backup_destination_type="s3",
                    backup_s3_prefix="s3://bucket/path",
                    backup_aws_secret_access_key="secret",
                    backup_aws_region="us-east-1",
                ),
            )
        with self.assertRaises(PostgresConfigValidationError):
            resolve_backup_destination(
                _config(
                    backup_destination_type="s3",
                    backup_s3_prefix="s3://bucket/path",
                    backup_aws_access_key_id="key",
                    backup_aws_region="us-east-1",
                ),
            )
        with self.assertRaises(PostgresConfigValidationError):
            resolve_backup_destination(
                _config(
                    backup_destination_type="s3",
                    backup_s3_prefix="s3://bucket/path",
                    backup_aws_access_key_id="key",
                    backup_aws_secret_access_key="secret",
                ),
            )
        with self.assertRaises(PostgresConfigValidationError):
            resolve_backup_destination(
                _config(
                    backup_destination_type="filesystem",
                    backup_file_prefix="",
                ),
            )

    def test_command_builders_and_output_parsers(self):
        # superuser_name is server-owned (T-1.4.4) and was set here to its
        # own default value anyway; omitted rather than sent.
        config = _config(
            project_slug="test",
            superuser_password="secret",
        )
        s3_command = postgres_backup_destination_test_command(
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
        self.assertIn("wal-g st put --no-compress --no-encrypt", s3_command["command"])
        self.assertIn("wal-g st get", s3_command["command"])
        self.assertIn("wal-g st rm", s3_command["command"])
        self.assertIn(
            "export WALG_S3_PREFIX=s3://bucket/path; export AWS_ACCESS_KEY_ID=key; ",
            s3_command["command"],
        )
        self.assertIn(
            'TEST_REMOTE_PATH="${TEST_REMOTE_BASE_PATH}/$(date -u +%Y%m%dT%H%M%SZ)-$$-backup-test.txt"',
            s3_command["command"],
        )
        self.assertIn("Timed out waiting for S3 object visibility.", s3_command["command"])
        self.assertEqual(
            s3_command["tested_remote_path"],
            "deploydash/connection-tests/<timestamp>-<pid>-backup-test.txt",
        )

        filesystem_command = postgres_backup_destination_test_command(
            {"type": "filesystem", "prefix": "/var/backups/deploydash"},
        )
        self.assertIn('cp "${TEST_FILE}"', filesystem_command["command"])
        self.assertIn('rm -f "${TEST_FILE_PATH}"', filesystem_command["command"])

        apply_plan = postgres_backup_policy_apply_command(
            config,
            policy_token="daily-main",
            task_token="backup-pg-daily-main",
            policy_name="Daily Main",
            project_slug="test",
            database_name="dd_test_app",
            schedule_mode="daily_twice",
            time1="02:00",
            time2="14:00",
            retention_keep_last=7,
            enabled=False,
            destination={"type": "filesystem", "prefix": "/var/backups/deploydash"},
        )
        self.assertIn('rm -f "${CRON_PATH}";', apply_plan["command"])
        self.assertEqual(
            apply_plan["remote_base_path"],
            "deploydash/postgres/test/daily-main",
        )
        self.assertIn(
            "export WALG_FILE_PREFIX=/var/backups/deploydash",
            apply_plan["command"],
        )
        enabled_plan = postgres_backup_policy_apply_command(
            config,
            policy_token="daily-main",
            task_token="backup-pg-daily-main",
            policy_name="Daily Main",
            project_slug="test",
            database_name="dd_test_app",
            schedule_mode="daily_once",
            time1="02:00",
            time2=None,
            retention_keep_last=7,
            enabled=True,
            destination={"type": "filesystem", "prefix": "/var/backups/deploydash"},
        )
        self.assertIn("chmod 644", enabled_plan["command"])
        self.assertIn(
            "wal-g st put --no-compress --no-encrypt",
            enabled_plan["command"],
        )

        quoted_environment = _backup_policy_environment_body(
            config,
            database_name="dd_test_app",
            policy_token="daily-main",
            task_token="backup-pg-daily-main",
            policy_name="Daily backup; do not execute",
            remote_base_path="deploydash/postgres/test/daily-main",
            retention_keep_last=7,
            destination={"type": "filesystem", "prefix": "/var/backups/deploydash"},
        )
        self.assertIn(
            "BACKUP_POLICY_NAME='Daily backup; do not execute'",
            quoted_environment,
        )

        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as handle:
            handle.write(quoted_environment)
            handle.flush()
            sourced = subprocess.run(
                [
                    "bash",
                    "-c",
                    'set -eu; . "$1"; '
                    '[ "$BACKUP_POLICY_NAME" = "Daily backup; do not execute" ]; '
                    '[ "$POSTGRES_PASSWORD" = "secret" ]',
                    "bash",
                    handle.name,
                ],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(sourced.returncode, 0, sourced.stderr)

        delete_command = postgres_backup_policy_delete_command(config, "daily-main")
        self.assertIn("deploydash-postgres-backup-daily-main", delete_command)
        self.assertIn("postgres-backup-daily-main.log", delete_command)
        self.assertIn("removed_backup_policy=daily-main", delete_command)

        install_command = postgres_walg_install_command()
        self.assertNotIn("api.github.com/repos/wal-g", install_command)
        self.assertIn(
            'github.com/wal-g/wal-g/releases/download/v3.0.8/"${ASSET}"',
            install_command,
        )
        self.assertIn("wal-g-pg-22.04-amd64.tar.gz", install_command)
        self.assertIn("wal-g-pg-22.04-aarch64.tar.gz", install_command)
        self.assertIn("sha256sum -c -", install_command)
        self.assertIn("WAL-G checksum verification failed", install_command)
        self.assertIn("if command -v wal-g", install_command)

        reinstall_command = postgres_walg_install_command(
            reinstall_existing=True,
        )
        self.assertNotIn("if command -v wal-g", reinstall_command)
        self.assertIn("install -m 0755", reinstall_command)

        self.assertEqual(
            postgres_parse_backup_run_output(
                _FakeOutput(
                    ["backup_artifact_path=a.dump", "backup_artifact_path=b.dump"],
                ),
            ),
            "b.dump",
        )
        artifacts = postgres_parse_backup_artifacts_output(
            _FakeOutput(
                [
                    "",
                    "name size",
                    "deploydash/postgres/test/a/",
                    "deploydash/postgres/test/a/readme.txt",
                    "20260101T010101Z__db.dump",
                    "20260102T010101Z__db.dump",
                ],
            ),
            remote_base_path="deploydash/postgres/test/a",
        )
        self.assertEqual(artifacts[0]["created_at"], "2026-01-02T01:01:01Z")
        self.assertEqual(
            artifacts[0]["remote_path"],
            "deploydash/postgres/test/a/20260102T010101Z__db.dump",
        )

    # `wal-g st ls` prints names relative to the listed folder on both S3
    # and filesystem destinations, while `wal-g st rm` resolves its
    # argument from the storage root -- deleting the relative name fails
    # with "does not exist" and prunes nothing (#95). One helper builds
    # the full key for both listing and pruning so they cannot disagree.
    def test_backup_artifact_key_prepends_base_path_for_relative_names(self):
        base = "deploydash/postgres/test/daily-main"
        self.assertEqual(
            backup_artifact_key(base, "20260101T010101Z__db.dump"),
            "deploydash/postgres/test/daily-main/20260101T010101Z__db.dump",
        )
        self.assertEqual(
            backup_artifact_key(
                base,
                "deploydash/postgres/test/daily-main/20260101T010101Z__db.dump",
            ),
            "deploydash/postgres/test/daily-main/20260101T010101Z__db.dump",
        )
        self.assertEqual(
            backup_artifact_key(None, "20260101T010101Z__db.dump"),
            "20260101T010101Z__db.dump",
        )
        self.assertEqual(
            backup_artifact_key("  deploydash/postgres/test/a/ ", "  x.dump  "),
            "deploydash/postgres/test/a/x.dump",
        )

    # An unset schedule time falls back to the policy default (#95
    # coverage of the unset-time branch).
    def test_normalize_backup_hhmm_uses_default_when_unset(self):
        self.assertEqual(
            normalize_backup_hhmm(None, "settings.backup_time1", "02:00"),
            "02:00",
        )
        self.assertEqual(
            normalize_backup_hhmm("  ", "settings.backup_time1", "14:00"),
            "14:00",
        )

    # S3 destinations without a custom endpoint export no AWS_ENDPOINT
    # (#95 coverage of the empty-endpoint branch).
    def test_backup_env_assignments_omits_empty_s3_endpoint(self):
        lines = backup_env_assignments(
            {
                "type": "s3",
                "prefix": "s3://backups95",
                "aws_access_key_id": "AKID",
                "aws_secret_access_key": "secret",
                "aws_region": "us-east-1",
                "aws_endpoint": "",
                "aws_force_path_style": True,
            }
        )
        self.assertNotIn("export AWS_ENDPOINT=", "\n".join(lines))
        self.assertIn("export AWS_S3_FORCE_PATH_STYLE=true", lines)

    # The size column of `wal-g st ls` feeds the backlog report ("~X GB");
    # lines without a parseable size keep size_bytes null rather than
    # guessed (#95).
    def test_backup_artifact_parser_captures_listing_sizes(self):
        artifacts = postgres_parse_backup_artifacts_output(
            _FakeOutput(
                [
                    "type size last modified                     name",
                    "obj  4194304    2026-09-28 21:23:17.279 +0000 UTC 20260101T010101Z__db.dump",
                    "obj  72         2026-09-28 21:23:17.279 +0000 UTC 20260101T010101Z__db.dump.manifest.json",
                    "obj  2097152    2026-09-28 22:23:39.389958092 +0100 BST 20260102T010101Z__db.dump",
                    "20260103T010101Z__db.dump",
                    "legacy-manual.dump",
                ],
            ),
            remote_base_path="deploydash/postgres/test/a",
        )

        by_name = {item["remote_path"].rsplit("/", 1)[-1]: item for item in artifacts}
        self.assertEqual(by_name["20260101T010101Z__db.dump"]["size_bytes"], 4194304)
        self.assertEqual(by_name["20260102T010101Z__db.dump"]["size_bytes"], 2097152)
        self.assertIsNone(by_name["20260103T010101Z__db.dump"]["size_bytes"])
        self.assertIsNone(by_name["legacy-manual.dump"]["created_at"])
        # Manifest sidecars contain ".dump" but are not dumps: counting them
        # as artifacts corrupts retention (the newest N must never be
        # doomed) and offers JSON sidecars as restorable backups (#95).
        self.assertNotIn("20260101T010101Z__db.dump.manifest.json", by_name)

    def test_payload_builders(self):
        policy_payload = resolve_backup_policy_payload(
            _config(
                project_slug="test",
                backup_policy_id="daily-main",
                backup_task_id="task-main",
                backup_policy_name="Daily Main",
                backup_database_name="app",
                backup_schedule_mode="daily_twice",
                backup_time1="01:15",
                backup_time2="13:45",
                backup_retention_keep_last=4000,
                backup_destination_type="filesystem",
                backup_file_prefix="/var/backups/deploydash",
                enabled=False,
            ),
            "dd_test_",
            postgres_prefixed_name=_postgres_prefixed_name,
            normalize_postgres_identifier=_normalize_postgres_identifier,
        )
        self.assertEqual(policy_payload["policy_token"], "daily-main")
        self.assertEqual(policy_payload["task_token"], "task-main")
        self.assertEqual(policy_payload["database_name"], "dd_test_app")
        self.assertEqual(policy_payload["time2"], "13:45")
        self.assertEqual(policy_payload["retention_keep_last"], 3650)
        self.assertFalse(policy_payload["enabled"])

        with self.assertRaises(PostgresConfigValidationError):
            resolve_backup_policy_payload(
                SimpleNamespace(
                    backup_policy_id="daily-main",
                    backup_task_id=None,
                    backup_policy_name=None,
                    backup_database_name="app",
                    backup_schedule_mode="hourly",
                    backup_time1=None,
                    backup_time2=None,
                    backup_retention_keep_last=7,
                    backup_destination_type="filesystem",
                    backup_file_prefix="/var/backups/deploydash",
                    backup_s3_prefix=None,
                    backup_aws_access_key_id=None,
                    backup_aws_secret_access_key=None,
                    backup_aws_region=None,
                    backup_aws_endpoint=None,
                    backup_aws_force_path_style=False,
                    project_slug="test",
                    enabled=True,
                ),
                "dd_test_",
                postgres_prefixed_name=_postgres_prefixed_name,
                normalize_postgres_identifier=_normalize_postgres_identifier,
            )

        low_retention_payload = resolve_backup_policy_payload(
            _config(
                project_slug="test",
                backup_policy_id="daily-main",
                backup_database_name="app",
                backup_schedule_mode="daily_once",
                backup_retention_keep_last=0,
                backup_destination_type="filesystem",
                backup_file_prefix="/var/backups/deploydash",
            ),
            "dd_test_",
            postgres_prefixed_name=_postgres_prefixed_name,
            normalize_postgres_identifier=_normalize_postgres_identifier,
        )
        self.assertEqual(low_retention_payload["retention_keep_last"], 1)

        restore_payload = resolve_backup_restore_payload(
            _config(
                project_slug="test",
                backup_policy_id="daily-main",
                backup_destination_type="filesystem",
                backup_file_prefix="/var/backups/deploydash",
                backup_target_database_name="restore_target",
                backup_artifact_path="deploydash/postgres/test/weekly/a.dump",
            ),
            "dd_test_",
            postgres_prefixed_name=_postgres_prefixed_name,
            normalize_postgres_identifier=_normalize_postgres_identifier,
        )
        self.assertEqual(
            restore_payload["target_database_name"],
            "dd_test_restore_target",
        )
        self.assertEqual(
            restore_payload["artifact_path"],
            "deploydash/postgres/test/weekly/a.dump",
        )

        relative_restore_payload = resolve_backup_restore_payload(
            _config(
                project_slug="test",
                backup_policy_id="daily-main",
                backup_destination_type="filesystem",
                backup_file_prefix="/var/backups/deploydash",
                backup_target_database_name="restore_target",
                backup_artifact_path="20260101T010101Z__db.dump",
            ),
            "dd_test_",
            postgres_prefixed_name=_postgres_prefixed_name,
            normalize_postgres_identifier=_normalize_postgres_identifier,
        )
        self.assertEqual(
            relative_restore_payload["artifact_path"],
            "deploydash/postgres/test/daily-main/20260101T010101Z__db.dump",
        )

    def test_restore_payload_refuses_artifacts_outside_current_project(self):
        """A restore cannot retrieve another project's backup object."""
        for artifact_path in (
            "deploydash/postgres/shop-api/daily-main/foreign.dump",
            "deploydash/postgres/shops/daily-main/foreign.dump",
            "deploydash/postgres/shopper/daily-main/foreign.dump",
        ):
            with (
                self.subTest(artifact_path=artifact_path),
                self.assertRaisesRegex(
                    PostgresConfigValidationError,
                    "selected project",
                ),
            ):
                resolve_backup_restore_payload(
                    _config(
                        project_slug="shop",
                        backup_policy_id="daily-main",
                        backup_destination_type="filesystem",
                        backup_file_prefix="/var/backups/deploydash",
                        backup_target_database_name="restore_target",
                        backup_artifact_path=artifact_path,
                    ),
                    "dd_shop_",
                    postgres_prefixed_name=_postgres_prefixed_name,
                    normalize_postgres_identifier=_normalize_postgres_identifier,
                )

    def test_backup_policy_apply_command_writes_and_prunes_manifest(self):
        config = _config()
        plan = postgres_backup_policy_apply_command(
            config,
            policy_token="daily-main",
            task_token="backup-pg-daily-main",
            policy_name="Daily Main",
            project_slug="test",
            database_name="dd_test_app",
            schedule_mode="daily_once",
            time1="02:00",
            time2=None,
            retention_keep_last=7,
            enabled=True,
            destination={"type": "filesystem", "prefix": "/var/backups/deploydash"},
        )
        self.assertIn(
            'LOCAL_MANIFEST="${TMP_DIR}/manifest.json"',
            plan["command"],
        )
        self.assertIn(
            'wal-g st put --no-compress --no-encrypt "${LOCAL_MANIFEST}" '
            '"${REMOTE_PATH}.manifest.json"',
            plan["command"],
        )
        self.assertIn(
            'wal-g st rm "${ARTIFACT_KEY}.manifest.json" || '
            'echo "prune_manifest_missing=${ARTIFACT_KEY}" >&2',
            plan["command"],
        )
        self.assertIn("prune_failed=", plan["command"])
        self.assertIn("PRUNE_FAILURES=0", plan["command"])
        self.assertIn("prune_failures=", plan["command"])
        self.assertNotIn('wal-g st rm "${OBJECTS[$i]}" || true', plan["command"])
        # Pruning deletes by the full storage key rebuilt from the relative
        # listing name, and a failed prune fails the run (#95).
        self.assertIn(
            'ARTIFACT_KEY="${BACKUP_REMOTE_BASE_PATH}/${OBJECT_NAME}"',
            plan["command"],
        )
        self.assertIn('echo "prune_failures=${PRUNE_FAILURES}" >&2', plan["command"])
        self.assertLess(
            plan["command"].index("prune_failures=${PRUNE_FAILURES}"),
            plan["command"].index("exit 1"),
        )

        # Validate emitted shell syntax
        proc_cmd = subprocess.run(
            ["bash", "-n"],
            input=plan["command"],
            text=True,
            capture_output=True,
        )
        self.assertEqual(proc_cmd.returncode, 0, proc_cmd.stderr)

        # The manifest write must come after SIZE_BYTES is computed (the
        # manifest needs it) and after the dump itself is uploaded (a
        # manifest naming a dump that was never actually written would be
        # worse than no manifest at all).
        self.assertLess(
            plan["command"].index('SIZE_BYTES="$(wc -c'),
            plan["command"].index("LOCAL_MANIFEST="),
        )
        self.assertLess(
            plan["command"].index('wal-g st put --no-compress --no-encrypt "${LOCAL_DUMP}"'),
            plan["command"].index("LOCAL_MANIFEST="),
        )

    def test_backup_manifest_write_command_produces_valid_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "bin"
            store_dir = tmp_path / "store"
            work_dir = tmp_path / "work"
            bin_dir.mkdir()
            store_dir.mkdir()
            work_dir.mkdir()

            script = (
                "set -eu\n"
                f'TMP_DIR="{work_dir}"\n'
                'BACKUP_DATABASE_NAME="dd_test_app"\n'
                'TIMESTAMP="20260830T080000Z"\n'
                'SIZE_BYTES="42"\n'
                'REMOTE_PATH="deploydash/postgres/test/daily-main/'
                '20260830T080000Z__dd_test_app.dump"\n'
            ) + postgres_backup_manifest_write_command()

            result = subprocess.run(
                ["bash", "-c", script],
                capture_output=True,
                text=True,
                env=_fake_walg_environment(bin_dir, store_dir),
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            uploaded_manifest = (
                store_dir
                / "deploydash/postgres/test/daily-main"
                / "20260830T080000Z__dd_test_app.dump.manifest.json"
            )
            self.assertTrue(uploaded_manifest.exists())
            manifest = json.loads(uploaded_manifest.read_text(encoding="utf-8"))
            self.assertEqual(
                manifest,
                {
                    "format_version": POSTGRES_BACKUP_MANIFEST_FORMAT_VERSION,
                    "database_name": "dd_test_app",
                    "created_at": "20260830T080000Z",
                    "size_bytes": 42,
                },
            )

    def _run_restore_format_check(self, *, store_dir, artifact_path):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "bin"
            work_dir = tmp_path / "work"
            bin_dir.mkdir()
            work_dir.mkdir()

            script = (
                (f'set -eu\nTMP_DIR="{work_dir}"\nARTIFACT_PATH="{artifact_path}"\n')
                + postgres_backup_restore_format_check_command()
                + "echo CHECK_PASSED\n"
            )

            return subprocess.run(
                ["bash", "-c", script],
                capture_output=True,
                text=True,
                env=_fake_walg_environment(bin_dir, store_dir),
            )

    def test_backup_restore_format_check_allows_a_backup_with_no_manifest(self):
        # Backups from before the manifest concept existed have no
        # "<artifact>.manifest.json" object at all -- the oldest possible
        # format, supported forever, not refused.
        with tempfile.TemporaryDirectory() as tmp:
            store_dir = Path(tmp)
            artifact_path = "deploydash/postgres/test/daily-main/old.dump"
            (store_dir / "deploydash/postgres/test/daily-main").mkdir(parents=True)
            (store_dir / artifact_path).write_text("dump bytes")

            result = self._run_restore_format_check(
                store_dir=store_dir, artifact_path=artifact_path
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("CHECK_PASSED", result.stdout)

    def test_backup_restore_format_check_allows_the_current_format(self):
        with tempfile.TemporaryDirectory() as tmp:
            store_dir = Path(tmp)
            artifact_path = "deploydash/postgres/test/daily-main/current.dump"
            manifest_dir = store_dir / "deploydash/postgres/test/daily-main"
            manifest_dir.mkdir(parents=True)
            (store_dir / artifact_path).write_text("dump bytes")
            (store_dir / f"{artifact_path}.manifest.json").write_text(
                json.dumps(
                    {
                        "format_version": POSTGRES_BACKUP_MANIFEST_FORMAT_VERSION,
                        "database_name": "dd_test_app",
                        "created_at": "20260830T080000Z",
                        "size_bytes": 11,
                    }
                )
            )

            result = self._run_restore_format_check(
                store_dir=store_dir, artifact_path=artifact_path
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("CHECK_PASSED", result.stdout)

    def test_backup_restore_format_check_refuses_a_newer_format(self):
        with tempfile.TemporaryDirectory() as tmp:
            store_dir = Path(tmp)
            artifact_path = "deploydash/postgres/test/daily-main/future.dump"
            manifest_dir = store_dir / "deploydash/postgres/test/daily-main"
            manifest_dir.mkdir(parents=True)
            (store_dir / artifact_path).write_text("dump bytes")
            future_version = POSTGRES_BACKUP_MANIFEST_FORMAT_VERSION + 98
            (store_dir / f"{artifact_path}.manifest.json").write_text(
                json.dumps(
                    {
                        "format_version": future_version,
                        "database_name": "dd_test_app",
                        "created_at": "20260830T080000Z",
                        "size_bytes": 11,
                    }
                )
            )

            result = self._run_restore_format_check(
                store_dir=store_dir, artifact_path=artifact_path
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("CHECK_PASSED", result.stdout)
            self.assertIn(str(future_version), result.stderr)
            self.assertIn("not supported", result.stderr)

    # The generated run_backup.sh prune phase must delete by the full
    # storage key: `wal-g st ls` prints folder-relative names but `st rm`
    # resolves from the storage root, so removing the relative name fails
    # and retention silently keeps everything (#95). The canned listing
    # below is the byte shape wal-g v3.0.8 prints on both S3 and
    # filesystem stores.
    def test_prune_block_deletes_expired_artifacts_by_full_key(self):
        base_path = "deploydash/postgres/test/daily-main"
        old_key = f"{base_path}/20260101T010101Z__dd_test_app.dump"
        new_key = f"{base_path}/20260201T010101Z__dd_test_app.dump"
        listing = (
            "type size last modified                           name\n"
            "obj  100  2026-09-28 22:31:25.567427428 +0100 BST "
            "20260101T010101Z__dd_test_app.dump \n"
            "obj  200  2026-09-28 22:31:25.585427176 +0100 BST "
            "20260201T010101Z__dd_test_app.dump \n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            store_dir = tmp_path / "store"
            (store_dir / base_path).mkdir(parents=True)
            (store_dir / old_key).write_text("old dump")
            (store_dir / f"{old_key}.manifest.json").write_text("{}")
            (store_dir / new_key).write_text("new dump")
            (store_dir / f"{new_key}.manifest.json").write_text("{}")
            listing_path = tmp_path / "listing.txt"
            listing_path.write_text(listing)
            rm_args_path = tmp_path / "rm_args.txt"
            rm_args_path.write_text("")
            (tmp_path / "bin").mkdir(parents=True, exist_ok=True)
            environment = _prune_fake_walg_environment(
                str(tmp_path / "bin"),
                str(store_dir),
                str(listing_path),
                str(rm_args_path),
            )
            block = _prune_block_from_apply_command(_prune_apply_command())

            result = _run_prune_block(
                block,
                keep_last=1,
                base_path=base_path,
                environment=environment,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("prune_failures=", result.stderr)
            self.assertIn(f"pruned_artifact={old_key}", result.stdout)
            self.assertEqual(
                rm_args_path.read_text().split(),
                [old_key, f"{old_key}.manifest.json"],
            )
            self.assertFalse((store_dir / old_key).exists())
            self.assertFalse((store_dir / f"{old_key}.manifest.json").exists())
            self.assertTrue((store_dir / new_key).exists())
            self.assertTrue((store_dir / f"{new_key}.manifest.json").exists())

    # A prune deletion that fails must fail the run loudly: exiting zero
    # while old artifacts pile up is the silent retention bug (#95).
    def test_prune_block_fails_loudly_when_deletion_fails(self):
        base_path = "deploydash/postgres/test/daily-main"
        old_key = f"{base_path}/20260101T010101Z__dd_test_app.dump"
        new_key = f"{base_path}/20260201T010101Z__dd_test_app.dump"
        listing = (
            "type size last modified                           name\n"
            "obj  100  2026-09-28 22:31:25.567427428 +0100 BST "
            "20260101T010101Z__dd_test_app.dump \n"
            "obj  200  2026-09-28 22:31:25.585427176 +0100 BST "
            "20260201T010101Z__dd_test_app.dump \n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            store_dir = tmp_path / "store"
            (store_dir / base_path).mkdir(parents=True)
            # The listing names the old dump but the object is gone, so the
            # deletion fails exactly like `wal-g st rm` on a missing key.
            (store_dir / new_key).write_text("new dump")
            listing_path = tmp_path / "listing.txt"
            listing_path.write_text(listing)
            rm_args_path = tmp_path / "rm_args.txt"
            rm_args_path.write_text("")
            (tmp_path / "bin").mkdir(parents=True, exist_ok=True)
            environment = _prune_fake_walg_environment(
                str(tmp_path / "bin"),
                str(store_dir),
                str(listing_path),
                str(rm_args_path),
            )
            block = _prune_block_from_apply_command(_prune_apply_command())

            result = _run_prune_block(
                block,
                keep_last=1,
                base_path=base_path,
                environment=environment,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(f"prune_failed={old_key}", result.stderr)
            self.assertIn("prune_failures=1", result.stderr)
            self.assertTrue((store_dir / new_key).exists())

    # Dumps from before manifests existed have no
    # "<artifact>.manifest.json" sidecar; pruning them warns but still
    # succeeds, since the dump itself was deleted (#95).
    def test_prune_block_warns_but_succeeds_without_a_manifest(self):
        base_path = "deploydash/postgres/test/daily-main"
        old_key = f"{base_path}/20260101T010101Z__dd_test_app.dump"
        new_key = f"{base_path}/20260201T010101Z__dd_test_app.dump"
        listing = (
            "type size last modified                           name\n"
            "obj  100  2026-09-28 22:31:25.567427428 +0100 BST "
            "20260101T010101Z__dd_test_app.dump \n"
            "obj  200  2026-09-28 22:31:25.585427176 +0100 BST "
            "20260201T010101Z__dd_test_app.dump \n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            store_dir = tmp_path / "store"
            (store_dir / base_path).mkdir(parents=True)
            (store_dir / old_key).write_text("old dump")
            (store_dir / new_key).write_text("new dump")
            listing_path = tmp_path / "listing.txt"
            listing_path.write_text(listing)
            rm_args_path = tmp_path / "rm_args.txt"
            rm_args_path.write_text("")
            (tmp_path / "bin").mkdir(parents=True, exist_ok=True)
            environment = _prune_fake_walg_environment(
                str(tmp_path / "bin"),
                str(store_dir),
                str(listing_path),
                str(rm_args_path),
            )
            block = _prune_block_from_apply_command(_prune_apply_command())

            result = _run_prune_block(
                block,
                keep_last=1,
                base_path=base_path,
                environment=environment,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("prune_failures=", result.stderr)
            self.assertIn(f"prune_manifest_missing={old_key}", result.stderr)
            self.assertFalse((store_dir / old_key).exists())
            self.assertTrue((store_dir / new_key).exists())

    # The backlog cleanup reports which artifacts sit beyond retention and
    # deletes exactly those after confirmation; the selector keeps the
    # newest N by key order no matter what order the listing arrived in,
    # and a non-positive keep-last still keeps one rather than dooming
    # everything (#95).
    def test_backlog_beyond_retention_keeps_newest_n(self):
        artifacts = [
            {
                "remote_path": "base/20260103T010101Z__db.dump",
                "created_at": "2026-01-03T01:01:01Z",
                "size_bytes": 30,
            },
            {
                "remote_path": "base/20260101T010101Z__db.dump",
                "created_at": "2026-01-01T01:01:01Z",
                "size_bytes": None,
            },
            {
                "remote_path": "base/20260104T010101Z__db.dump",
                "created_at": "2026-01-04T01:01:01Z",
                "size_bytes": None,
            },
            {
                "remote_path": "base/20260102T010101Z__db.dump",
                "created_at": "2026-01-02T01:01:01Z",
                "size_bytes": 20,
            },
        ]

        result = postgres_backlog_beyond_retention(artifacts, 2)

        self.assertEqual(
            [item["remote_path"] for item in result["retained"]],
            ["base/20260104T010101Z__db.dump", "base/20260103T010101Z__db.dump"],
        )
        self.assertEqual(
            [item["remote_path"] for item in result["beyond_retention"]],
            ["base/20260101T010101Z__db.dump", "base/20260102T010101Z__db.dump"],
        )
        self.assertEqual(result["beyond_retention_count"], 2)
        self.assertEqual(result["beyond_retention_bytes"], 20)
        self.assertEqual(result["beyond_retention_unknown_size_count"], 1)
        self.assertEqual(
            postgres_backlog_beyond_retention(artifacts, 9)["beyond_retention"],
            [],
        )
        self.assertEqual(
            postgres_backlog_beyond_retention(artifacts, 0)["beyond_retention_count"],
            3,
        )

    # The cleanup command deletes exactly the reported keys plus their
    # manifests, reporting each outcome as KEY=value lines (#95).
    def test_backlog_cleanup_command_deletes_keys_and_manifests(self):
        keys = [
            "deploydash/postgres/test/daily-main/20260101T010101Z__db.dump",
            "deploydash/postgres/test/daily-main/20260102T010101Z__db.dump",
        ]
        plan = postgres_backup_backlog_cleanup_command(
            {"type": "filesystem", "prefix": "/var/backups/deploydash"},
            keys,
        )

        self.assertEqual(plan["keys"], keys)
        self.assertIn("export WALG_FILE_PREFIX=/var/backups/deploydash", plan["command"])
        for key in keys:
            self.assertIn(f"wal-g st rm {shlex.quote(key)}", plan["command"])
            self.assertIn(
                f"wal-g st rm {shlex.quote(key)}.manifest.json",
                plan["command"],
            )
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            store_dir = tmp_path / "store"
            store_dir.mkdir()
            for key in keys:
                (store_dir / key).parent.mkdir(parents=True, exist_ok=True)
                (store_dir / key).write_text("dump")
                (store_dir / f"{key}.manifest.json").write_text("{}")
            keep_key = "deploydash/postgres/test/daily-main/20260103T010101Z__db.dump"
            (store_dir / keep_key).write_text("dump")

            result = subprocess.run(
                ["bash", "-c", plan["command"]],
                capture_output=True,
                text=True,
                env=_fake_walg_environment(bin_dir, store_dir),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            for key in keys:
                self.assertIn(f"deleted_artifact={key}", result.stdout)
                self.assertFalse((store_dir / key).exists())
                self.assertFalse((store_dir / f"{key}.manifest.json").exists())
            self.assertTrue((store_dir / keep_key).exists())

    # The cleanup output parser collects every deletion outcome; repeated
    # keys accumulate rather than collapsing to the last one (#95).
    def test_parse_backup_cleanup_output_collects_outcomes(self):
        result = postgres_parse_backup_cleanup_output(
            _FakeOutput(
                [
                    "deleted_artifact=base/a.dump",
                    "cleanup_manifest_missing=base/a.dump",
                    "deleted_artifact=base/b.dump",
                    "delete_failed=base/c.dump",
                    "backup_size_bytes=42",
                    "not a protocol line",
                    "",
                ],
            ),
        )

        self.assertEqual(
            result,
            {
                "deleted": ["base/a.dump", "base/b.dump"],
                "failed": ["base/c.dump"],
                "manifests_missing": ["base/a.dump"],
            },
        )


if __name__ == "__main__":
    unittest.main()
