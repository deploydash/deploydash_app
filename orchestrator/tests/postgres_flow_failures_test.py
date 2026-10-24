"""Failure paths of the ownership-gated PostgreSQL project flows (#127).

Each test drives one operation through ``_run_operation_with_host`` with a
fake server whose answers force one specific validation, runtime or
cancellation path, and asserts the exact error that path returns. These are
product behavior: a flow that stops half way must say where and why.
"""

import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from orchestrator import engine_postgres_ops
from orchestrator.postgres_runtime_parts import (
    backup_operations,
    database_lifecycle,
    local_sql_import,
    project_inventory,
    users_and_grants,
)
from tests.engine_context_fixtures import build_test_context
from tests.postgres_registry_test import (
    _FILESYSTEM_BACKUP,
    _OWNED_BY_SHOP,
    _error_result,
    _FakeSession,
    _RoutingHost,
    _run_operation_with_host,
    _shop_settings,
)


def _cancel_after(allowed_checks):
    """Return an ``is_cancelled`` callback that trips after ``allowed_checks`` calls.

    The router checks cancellation once before it starts, so a flow reaches
    its own in-loop cancellation checks only when the first answers are False.
    """
    calls = {"count": 0}

    def is_cancelled():
        """Report cancellation once the allowed number of checks has passed."""
        calls["count"] += 1
        return calls["count"] > allowed_checks

    return is_cancelled


def _run_operation_with_details(
    operation_id,
    settings,
    host,
    *,
    details="remote failed",
    dry_run=False,
    is_cancelled=None,
):
    """Run one operation while controlling error text and recording emitted events."""
    events = []
    ctx = build_test_context(
        error_result=_error_result,
        emit_event=lambda *args, **kwargs: events.append((args, kwargs)),
        emit_shell_output_lines=lambda *_args, **_kwargs: None,
        command_error_details=lambda _output: details,
        open_runtime_session=lambda **_kwargs: {
            "ok": True,
            "session": _FakeSession(host=host),
        },
    )
    result = engine_postgres_ops.run_postgres_project_operation(
        ctx,
        operation_id,
        ip="198.51.100.8",
        username="ubuntu",
        password="secret",
        dry_run=dry_run,
        raw_data={"settings": settings},
        is_cancelled=is_cancelled,
    )
    return result, host.commands, events


def _foreign_handler_request(operation_id):
    """Build a session-free request proving a handler ignores foreign operations."""
    return SimpleNamespace(
        ctx=None,
        operation_id=operation_id,
        ip="198.51.100.8",
        username="ubuntu",
        password="secret",
        key_filename=None,
        port=22,
        postgres_config=None,
        project_prefix="dd_shop_",
        session=None,
        emit=None,
        is_cancelled=None,
        dry_run=False,
    )


def _filesystem_backup_settings(**extra):
    """Build valid filesystem backup settings while allowing one test override."""
    return _shop_settings(backup_database_name="main", **_FILESYSTEM_BACKUP, **extra)


def _s3_destination_settings():
    """Build a valid S3 destination so tests can reach its wal-g install step."""
    return _shop_settings(
        backup_destination_type="s3",
        backup_s3_prefix="s3://bucket/path",
        backup_aws_access_key_id="key",
        backup_aws_secret_access_key="secret",
        backup_aws_region="us-east-1",
        backup_aws_endpoint="https://s3.us-east-1.amazonaws.com",
        backup_aws_force_path_style=True,
    )


class TestPostgresFlowFailurePaths(unittest.TestCase):
    """Every stop in the gated flows returns its own exact error."""

    def test_rotate_password_requires_a_username(self):
        """Rotation without a username is refused before touching the server."""
        host = _RoutingHost()
        result, commands = _run_operation_with_host(
            "project_rotate_password",
            _shop_settings(),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["msg"], "settings.username is required.")
        self.assertEqual(commands, [])

    def test_rotate_password_reports_a_failed_alter_role(self):
        """A failing ALTER ROLE is reported, and no password is returned."""
        host = _RoutingHost(rules=[_OWNED_BY_SHOP, ("ALTER ROLE", (False, []))])
        result, _commands = _run_operation_with_host(
            "project_rotate_password",
            _shop_settings(username="main_user"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not rotate user password.")
        self.assertNotIn("password", result)

    def test_delete_user_stops_when_cancelled_between_databases(self):
        """Cancelling during the per-database sweep stops before any DROP ROLE."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT datname FROM deploydash.managed_databases", (True, ["dd_shop_main"])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_user",
            _shop_settings(username="main_user"),
            host,
            is_cancelled=_cancel_after(1),
        )
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(result["msg"], "Task cancelled during PostgreSQL operation")
        self.assertNotIn("DROP ROLE", "\n".join(commands))

    def test_delete_user_requires_a_username(self):
        """Deletion without a username is refused before touching the server."""
        result, commands = _run_operation_with_host(
            "project_delete_user",
            _shop_settings(),
            _RoutingHost(),
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["msg"], "settings.username is required.")
        self.assertEqual(commands, [])

    def test_delete_user_reports_a_failed_database_listing(self):
        """A failed registry read stops the user sweep before grants change."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT datname FROM deploydash.managed_databases", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_user",
            _shop_settings(username="main_user"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not inspect project databases.")
        self.assertNotIn("DROP ROLE", "\n".join(commands))

    def test_delete_user_reports_a_failed_grant_cleanup(self):
        """A real grant-cleanup failure stops deletion instead of being ignored."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT datname FROM deploydash.managed_databases", (True, ["dd_shop_main"])),
                ("REASSIGN OWNED BY", (False, [])),
            ],
        )
        result, commands, _events = _run_operation_with_details(
            "project_delete_user",
            _shop_settings(username="main_user"),
            host,
            details="permission denied",
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not remove user grants from project database.")
        self.assertNotIn("DROP ROLE", "\n".join(commands))

    def test_delete_user_ignores_a_database_that_disappeared_during_cleanup(self):
        """A concurrently removed database does not prevent the role deletion."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT datname FROM deploydash.managed_databases", (True, ["dd_shop_main"])),
                ("REASSIGN OWNED BY", (False, [])),
            ],
        )
        result, commands, _events = _run_operation_with_details(
            "project_delete_user",
            _shop_settings(username="main_user"),
            host,
            details="database does not exist",
        )
        self.assertEqual(result["status"], "success", result)
        self.assertIn("DROP ROLE", "\n".join(commands))

    def test_delete_user_reports_a_failed_drop_role(self):
        """A failed DROP ROLE is reported before registry removal."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("DROP ROLE IF EXISTS", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_user",
            _shop_settings(username="main_user", database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not remove database user.")
        self.assertNotIn("DELETE FROM deploydash.managed_roles", "\n".join(commands))

    def test_user_operation_ignores_an_operation_it_does_not_own(self):
        """A handler never acts on an operation it does not own."""
        request = _foreign_handler_request("project_list")
        self.assertIsNone(users_and_grants.handle_user_operation(request))

    def test_database_lifecycle_ignores_an_operation_it_does_not_own(self):
        """A handler never acts on an operation it does not own."""
        request = _foreign_handler_request("project_list")
        self.assertIsNone(database_lifecycle.handle_database_lifecycle(request))

    def test_project_inventory_ignores_an_operation_it_does_not_own(self):
        """A handler never acts on an operation it does not own."""
        request = _foreign_handler_request("project_rotate_password")
        self.assertIsNone(project_inventory.handle_project_inventory(request))

    def test_backup_operation_ignores_an_operation_it_does_not_own(self):
        """A handler never acts on an operation it does not own."""
        request = _foreign_handler_request("project_list")
        self.assertIsNone(backup_operations.handle_backup_operation(request))

    def test_local_sql_import_ignores_an_operation_it_does_not_own(self):
        """A handler never acts on an operation it does not own."""
        request = _foreign_handler_request("project_list")
        self.assertIsNone(local_sql_import.handle_local_sql_import(request))

    def test_backup_policy_apply_reports_invalid_settings(self):
        """An incomplete policy is refused before ownership or installation."""
        result, commands = _run_operation_with_host(
            "backup_policy_apply",
            _shop_settings(),
            _RoutingHost(),
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["msg"], "settings.backup_policy_id must be a non-empty string.")
        self.assertEqual(commands, [])

    def test_backup_policy_apply_reports_a_failed_wal_g_install(self):
        """A missing wal-g stops policy application before cron is written."""
        host = _RoutingHost(
            rules=[_OWNED_BY_SHOP, ("if command -v wal-g", (False, []))],
        )
        result, commands = _run_operation_with_host(
            "backup_policy_apply",
            _filesystem_backup_settings(),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not install wal-g.")
        self.assertNotIn("POLICY_DIR=", "\n".join(commands))

    def test_backup_policy_apply_reports_a_failed_policy_write(self):
        """A failed cron write is returned as the policy-apply error."""
        host = _RoutingHost(
            rules=[_OWNED_BY_SHOP, ("POLICY_DIR=", (False, []))],
        )
        result, _commands = _run_operation_with_host(
            "backup_policy_apply",
            _filesystem_backup_settings(),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not apply backup policy.")

    def test_backup_policy_delete_reports_invalid_settings(self):
        """Deletion without a policy identifier is refused without a command."""
        result, commands = _run_operation_with_host(
            "backup_policy_delete",
            _shop_settings(),
            _RoutingHost(),
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["msg"], "settings.backup_policy_id must be a non-empty string.")
        self.assertEqual(commands, [])

    def test_backup_policy_delete_reports_a_failed_delete(self):
        """A failed policy cleanup is surfaced instead of claiming deletion."""
        host = _RoutingHost(rules=[("rm -f /etc/cron.d", (False, []))])
        result, _commands = _run_operation_with_host(
            "backup_policy_delete",
            _shop_settings(backup_policy_id="daily"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not delete backup policy.")

    def test_backup_destination_test_reports_invalid_settings(self):
        """A missing destination type is refused before any remote command."""
        result, commands = _run_operation_with_host(
            "backup_destination_test",
            _shop_settings(),
            _RoutingHost(),
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(
            result["msg"],
            "settings.backup_destination_type must be one of: s3, filesystem.",
        )
        self.assertEqual(commands, [])

    def test_s3_destination_test_reports_a_failed_wal_g_install(self):
        """An S3 check cannot proceed when wal-g installation fails."""
        host = _RoutingHost(rules=[("if command -v wal-g", (False, []))])
        result, commands = _run_operation_with_host(
            "backup_destination_test",
            _s3_destination_settings(),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not install wal-g.")
        self.assertNotIn("wal-g st ls", "\n".join(commands))

    def test_backup_run_now_reports_invalid_settings(self):
        """A run without a policy identifier is refused before ownership checks."""
        result, commands = _run_operation_with_host(
            "backup_run_now",
            _shop_settings(),
            _RoutingHost(),
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["msg"], "settings.backup_policy_id must be a non-empty string.")
        self.assertEqual(commands, [])

    def test_backup_run_now_reports_a_failed_wal_g_install(self):
        """A missing wal-g stops the backup before its runner is prepared."""
        host = _RoutingHost(
            rules=[_OWNED_BY_SHOP, ("if command -v wal-g", (False, []))],
        )
        result, commands = _run_operation_with_host(
            "backup_run_now",
            _filesystem_backup_settings(),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not install wal-g.")
        self.assertNotIn("POLICY_DIR=", "\n".join(commands))

    def test_backup_run_now_reports_a_failed_runner_prepare(self):
        """A failed runner write stops the backup before the script executes."""
        host = _RoutingHost(
            rules=[_OWNED_BY_SHOP, ("POLICY_DIR=", (False, []))],
        )
        result, commands = _run_operation_with_host(
            "backup_run_now",
            _filesystem_backup_settings(),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not prepare backup runner.")
        self.assertNotIn("set -eu; /bin/bash", "\n".join(commands))

    def test_backup_run_now_reports_a_failed_runner(self):
        """A failing backup script is returned as the backup-run error."""
        host = _RoutingHost(
            rules=[_OWNED_BY_SHOP, ("set -eu; /bin/bash", (False, []))],
        )
        result, _commands = _run_operation_with_host(
            "backup_run_now",
            _filesystem_backup_settings(),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "PostgreSQL backup run failed.")

    def test_backup_artifact_list_reports_invalid_settings(self):
        """Artifact listing without a policy identifier is refused locally."""
        result, commands = _run_operation_with_host(
            "backup_artifact_list",
            _shop_settings(),
            _RoutingHost(),
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["msg"], "settings.backup_policy_id must be a non-empty string.")
        self.assertEqual(commands, [])

    def test_backup_artifact_list_reports_a_failed_wal_g_install(self):
        """Artifacts are not listed when wal-g installation fails."""
        host = _RoutingHost(rules=[("if command -v wal-g", (False, []))])
        result, commands = _run_operation_with_host(
            "backup_artifact_list",
            _filesystem_backup_settings(),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not install wal-g.")
        self.assertNotIn("wal-g st ls", "\n".join(commands))

    def test_restore_reports_invalid_settings(self):
        """Restore without a target name is refused before installation."""
        result, commands = _run_operation_with_host(
            "restore_run_now",
            _shop_settings(**_FILESYSTEM_BACKUP),
            _RoutingHost(),
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(
            result["msg"],
            "settings.backup_target_database_name must be a non-empty string.",
        )
        self.assertEqual(commands, [])

    def test_restore_reports_a_failed_wal_g_install(self):
        """A missing wal-g stops restore before target validation."""
        host = _RoutingHost(
            rules=[
                ("SELECT project_slug FROM deploydash.managed_", (True, [])),
                ("SELECT 1 FROM pg_database WHERE datname", (True, [])),
                ("if command -v wal-g", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "restore_run_now",
            _shop_settings(
                backup_target_database_name="restored",
                backup_artifact_path="sample.dump",
                **_FILESYSTEM_BACKUP,
            ),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not install wal-g.")
        self.assertNotIn("pg_restore", "\n".join(commands))

    def test_restore_reports_a_failed_target_probe(self):
        """A failed catalog read stops restore before download or creation."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "restore_run_now",
            _shop_settings(
                backup_target_database_name="restored",
                backup_artifact_path="sample.dump",
                **_FILESYSTEM_BACKUP,
            ),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not validate restore target database.")
        self.assertNotIn("pg_restore", "\n".join(commands))

    def test_restore_refuses_a_registered_target_that_still_exists(self):
        """A registered live target is never overwritten by restore."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (True, ["1"])),
            ],
        )
        result, commands = _run_operation_with_host(
            "restore_run_now",
            _shop_settings(
                backup_target_database_name="restored",
                backup_artifact_path="sample.dump",
                **_FILESYSTEM_BACKUP,
            ),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(
            result["msg"], "Target database already exists. Choose a new database name."
        )
        self.assertNotIn("pg_restore", "\n".join(commands))

    def test_restore_reports_a_failed_pg_restore(self):
        """A failed restore command never proceeds to registry insertion."""
        host = _RoutingHost(
            rules=[
                ("SELECT project_slug FROM deploydash.managed_", (True, [])),
                ("SELECT 1 FROM pg_database WHERE datname", (True, [])),
                ("pg_restore", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "restore_run_now",
            _shop_settings(
                backup_target_database_name="restored",
                backup_artifact_path="sample.dump",
                **_FILESYSTEM_BACKUP,
            ),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "PostgreSQL restore failed.")
        self.assertNotIn("INSERT INTO deploydash.managed_databases", "\n".join(commands))

    def test_create_database_requires_a_database_name(self):
        """Database creation without a logical name is refused locally."""
        result, commands = _run_operation_with_host(
            "project_create_database",
            _shop_settings(),
            _RoutingHost(),
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["msg"], "settings.database_name is required.")
        self.assertEqual(commands, [])

    def test_create_user_requires_a_database_name(self):
        """User creation without a database cannot choose an ownership boundary."""
        result, commands = _run_operation_with_host(
            "project_create_user",
            _shop_settings(username="reader"),
            _RoutingHost(),
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["msg"], "settings.database_name is required.")
        self.assertEqual(commands, [])

    def test_create_user_requires_a_username(self):
        """User creation without a logical username is refused locally."""
        result, commands = _run_operation_with_host(
            "project_create_user",
            _shop_settings(database_name="main"),
            _RoutingHost(),
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["msg"], "settings.username is required.")
        self.assertEqual(commands, [])

    def test_create_reports_a_failed_role_existence_probe(self):
        """A failed role catalog read stops creation before any database mutation."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_roles WHERE rolname", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_create_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not inspect existing database users.")
        self.assertNotIn("createdb", "\n".join(commands))

    def test_create_reports_a_failed_database_existence_probe(self):
        """A failed database catalog read stops creation before createdb."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_create_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not inspect existing databases.")
        self.assertNotIn("createdb", "\n".join(commands))

    def test_create_reports_a_failed_createdb(self):
        """A failed createdb stops before PUBLIC access or extensions change."""
        host = _RoutingHost(rules=[_OWNED_BY_SHOP, ("createdb -U", (False, []))])
        result, commands = _run_operation_with_host(
            "project_create_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not create database.")
        self.assertNotIn("REVOKE CONNECT, TEMP", "\n".join(commands))

    def test_create_reports_revoke_failure_and_failed_database_rollback(self):
        """A failed safety revoke reports a rollback that could not drop the database."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("REVOKE CONNECT, TEMP ON DATABASE", (False, [])),
                ("dropdb -U", (False, [])),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_create_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not revoke public database access.")
        self.assertIn(
            "could not be dropped because a client may still be reconnecting",
            result["details"],
        )

    def test_create_reports_extension_failure_after_clean_rollback(self):
        """An extension failure remains the primary error when rollback succeeds."""
        host = _RoutingHost(
            rules=[_OWNED_BY_SHOP, ("CREATE EXTENSION", (False, []))],
        )
        result, _commands = _run_operation_with_host(
            "project_create_database",
            _shop_settings(database_name="main", enabled_extensions=["pgcrypto"]),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not enable database extensions.")
        self.assertEqual(result["details"], "remote failed")

    def test_create_reports_extension_failure_and_failed_rollback(self):
        """An extension failure also reports any database rollback failure."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("CREATE EXTENSION", (False, [])),
                ("dropdb -U", (False, [])),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_create_database",
            _shop_settings(database_name="main", enabled_extensions=["pgcrypto"]),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not enable database extensions.")
        self.assertIn(
            "could not be dropped because a client may still be reconnecting",
            result["details"],
        )

    def test_create_reports_role_failure_after_clean_rollback(self):
        """A role-creation failure remains primary when all rollback steps succeed."""
        host = _RoutingHost(rules=[_OWNED_BY_SHOP, ("COMMENT ON ROLE", (False, []))])
        result, _commands = _run_operation_with_host(
            "project_create_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not create database user.")
        self.assertEqual(result["details"], "remote failed")

    def test_create_reports_role_failure_and_failed_role_rollback(self):
        """A role-creation failure reports a temporary role that could not be dropped."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("COMMENT ON ROLE", (False, [])),
                ("DROP ROLE IF EXISTS", (False, [])),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_create_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not create database user.")
        self.assertIn("rollback could not drop role", result["details"])

    def test_delete_database_requires_a_database_name(self):
        """Database deletion without a logical name is refused locally."""
        result, commands = _run_operation_with_host(
            "project_delete_database",
            _shop_settings(),
            _RoutingHost(),
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["msg"], "settings.database_name is required.")
        self.assertEqual(commands, [])

    def test_delete_database_reports_a_failed_existence_probe(self):
        """A failed catalog probe stops deletion before role discovery."""
        host = _RoutingHost(
            rules=[_OWNED_BY_SHOP, ("SELECT 1 FROM pg_database WHERE datname", (False, []))],
        )
        result, commands = _run_operation_with_host(
            "project_delete_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not inspect target database.")
        self.assertNotIn("DROP ROLE", "\n".join(commands))

    def test_delete_database_reports_a_failed_role_listing(self):
        """A failed registry role read stops deletion before grants are removed."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (True, ["1"])),
                ("FROM deploydash.managed_roles WHERE datname", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not inspect project database users.")
        self.assertNotIn("REASSIGN OWNED", "\n".join(commands))

    def test_delete_database_stops_when_cancelled_during_grant_cleanup(self):
        """Cancellation before the first cleanup leaves the database untouched."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (True, ["1"])),
                ("FROM deploydash.managed_roles WHERE datname", (True, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_database",
            _shop_settings(database_name="main"),
            host,
            is_cancelled=_cancel_after(1),
        )
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertNotIn("REASSIGN OWNED", "\n".join(commands))

    def test_delete_database_reports_a_failed_grant_cleanup(self):
        """A failed role cleanup stops before active sessions are terminated."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (True, ["1"])),
                ("FROM deploydash.managed_roles WHERE datname", (True, [])),
                ("REASSIGN OWNED BY", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not remove user grants from database.")
        self.assertNotIn("SELECT pg_terminate_backend", "\n".join(commands))

    def test_delete_database_reports_a_failed_session_termination(self):
        """A failed session termination stops before dropdb."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (True, ["1"])),
                ("FROM deploydash.managed_roles WHERE datname", (True, [])),
                ("SELECT pg_terminate_backend", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not terminate active database sessions.")
        self.assertNotIn("dropdb -U", "\n".join(commands))

    def test_delete_database_reports_a_failed_dropdb(self):
        """A failed dropdb is surfaced before any role is dropped."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (True, ["1"])),
                ("FROM deploydash.managed_roles WHERE datname", (True, [])),
                ("dropdb -U", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not drop database.")
        self.assertNotIn("DROP ROLE IF EXISTS", "\n".join(commands))

    def test_delete_database_skips_dropdb_when_the_database_is_already_gone(self):
        """A missing database still allows its derived roles to be removed."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (True, [])),
                ("FROM deploydash.managed_roles WHERE datname", (True, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["status"], "success", result)
        self.assertNotIn("dropdb -U", "\n".join(commands))
        self.assertIn("DROP ROLE IF EXISTS", "\n".join(commands))

    def test_delete_database_stops_when_cancelled_before_role_drop(self):
        """Cancellation after a vanished database leaves its roles intact."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (True, [])),
                ("FROM deploydash.managed_roles WHERE datname", (True, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_database",
            _shop_settings(database_name="main"),
            host,
            is_cancelled=_cancel_after(1),
        )
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertNotIn("DROP ROLE IF EXISTS", "\n".join(commands))

    def test_delete_database_reports_a_failed_role_drop(self):
        """A failed derived-role drop stops before cleanup verification."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (True, [])),
                ("FROM deploydash.managed_roles WHERE datname", (True, [])),
                ("DROP ROLE IF EXISTS", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not drop database user.")
        self.assertNotIn("SELECT rolname FROM pg_roles", "\n".join(commands))

    def test_delete_database_reports_a_failed_role_cleanup_verification(self):
        """A failed catalog verification prevents registry cleanup."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (True, [])),
                ("FROM deploydash.managed_roles WHERE datname", (True, [])),
                ("SELECT rolname FROM pg_roles", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not verify database user cleanup.")
        self.assertNotIn("DELETE FROM deploydash.managed_databases", "\n".join(commands))

    def test_project_delete_reports_a_failed_database_listing(self):
        """A failed database registry read stops a whole-project delete."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT datname FROM deploydash.managed_databases WHERE project_slug",
                    (False, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            _shop_settings(confirmed_databases=[], confirmed_users=[]),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not inspect project databases.")
        self.assertNotIn("dropdb -U", "\n".join(commands))

    def test_project_delete_stops_when_cancelled_before_database_drop(self):
        """Cancellation before the first database preserves all project resources."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT datname FROM deploydash.managed_databases WHERE project_slug",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "SELECT rolname FROM deploydash.managed_roles WHERE project_slug",
                    (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            _shop_settings(confirmed_databases=["dd_shop_main"], confirmed_users=[]),
            host,
            is_cancelled=_cancel_after(1),
        )
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertNotIn("SELECT pg_terminate_backend", "\n".join(commands))

    def test_project_delete_reports_a_failed_session_termination(self):
        """A failed session termination stops the whole-project drop."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT datname FROM deploydash.managed_databases WHERE project_slug",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "SELECT rolname FROM deploydash.managed_roles WHERE project_slug",
                    (True, []),
                ),
                ("SELECT pg_terminate_backend", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            _shop_settings(confirmed_databases=["dd_shop_main"], confirmed_users=[]),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not terminate active project DB sessions.")
        self.assertNotIn("dropdb -U", "\n".join(commands))

    def test_project_delete_reports_a_failed_database_drop(self):
        """A failed dropdb stops before any project role is removed."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT datname FROM deploydash.managed_databases WHERE project_slug",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "SELECT rolname FROM deploydash.managed_roles WHERE project_slug",
                    (True, []),
                ),
                ("dropdb -U", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            _shop_settings(confirmed_databases=["dd_shop_main"], confirmed_users=[]),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not drop project database.")
        self.assertNotIn("DROP ROLE IF EXISTS", "\n".join(commands))

    def test_project_delete_stops_when_cancelled_before_role_drop(self):
        """Cancellation after database planning preserves every project role."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT datname FROM deploydash.managed_databases WHERE project_slug",
                    (True, []),
                ),
                (
                    "SELECT rolname FROM deploydash.managed_roles WHERE project_slug",
                    (True, ["dd_shop_main_user"]),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            _shop_settings(confirmed_databases=[], confirmed_users=["dd_shop_main_user"]),
            host,
            is_cancelled=_cancel_after(1),
        )
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertNotIn("DROP ROLE IF EXISTS", "\n".join(commands))

    def test_project_delete_reports_a_failed_role_drop(self):
        """A failed project role drop stops before registry removal."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT datname FROM deploydash.managed_databases WHERE project_slug",
                    (True, []),
                ),
                (
                    "SELECT rolname FROM deploydash.managed_roles WHERE project_slug",
                    (True, ["dd_shop_main_user"]),
                ),
                ("DROP ROLE IF EXISTS", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            _shop_settings(confirmed_databases=[], confirmed_users=["dd_shop_main_user"]),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not drop project database user.")
        self.assertNotIn("DELETE FROM deploydash.managed_roles", "\n".join(commands))

    def test_create_user_rolls_back_only_the_new_role(self):
        """A standalone user failure removes its role without touching the database."""
        host = _RoutingHost(rules=[_OWNED_BY_SHOP, ("COMMENT ON ROLE", (False, []))])
        result, commands = _run_operation_with_host(
            "project_create_user",
            _shop_settings(database_name="main", username="reader"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not create database user.")
        statements = "\n".join(commands)
        self.assertIn("DROP ROLE IF EXISTS", statements)
        self.assertNotIn("dropdb -U", statements)

    def test_import_local_sql_requires_a_local_file_path(self):
        """An import without a source file is rejected before remote work starts."""
        result, commands = _run_operation_with_host(
            "import_local_sql",
            _shop_settings(database_name="main"),
            _RoutingHost(),
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(
            result["msg"],
            "settings.import_local_file_path must be a non-empty string.",
        )
        self.assertEqual(commands, [])

    def test_import_local_sql_reports_a_failed_target_probe(self):
        """A failed target lookup stops an import before ownership or upload work."""
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"SELECT 1;")
            handle.flush()
            result, commands = _run_operation_with_host(
                "import_local_sql",
                _shop_settings(database_name="main", import_local_file_path=handle.name),
                _RoutingHost(
                    rules=[("SELECT 1 FROM pg_database WHERE datname", (False, []))],
                ),
            )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not validate import target database.")
        self.assertNotIn("SELECT project_slug", "\n".join(commands))

    def test_import_local_sql_requires_an_existing_target(self):
        """A missing target database is rejected before upload work begins."""
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(b"SELECT 1;")
            handle.flush()
            result, commands = _run_operation_with_host(
                "import_local_sql",
                _shop_settings(database_name="main", import_local_file_path=handle.name),
                _RoutingHost(
                    rules=[("SELECT 1 FROM pg_database WHERE datname", (True, []))],
                ),
            )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(
            result["msg"],
            "Target database does not exist. Create it first, then retry the import.",
        )
        self.assertNotIn("SELECT project_slug", "\n".join(commands))

    def test_import_local_sql_warns_when_final_cleanup_fails(self):
        """A successful import remains successful while exposing cleanup failure."""
        host = _RoutingHost(
            rules=[
                ("SELECT 1 FROM pg_database WHERE datname", (True, ["1"])),
                _OWNED_BY_SHOP,
                (
                    "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_roles",
                    (True, ["1"]),
                ),
                (
                    "__DEPLOYDASH_LOCAL_SQL_IMPORT_SUCCEEDED__",
                    (True, ["__DEPLOYDASH_LOCAL_SQL_IMPORT_SUCCEEDED__"]),
                ),
                ("set -eu; rm -rf /tmp/deploydash-postgres-import-", (False, [])),
            ],
        )
        with (
            tempfile.NamedTemporaryFile(suffix=".sql") as handle,
            patch.object(local_sql_import, "_upload_local_sql_import_file", return_value={}),
        ):
            handle.write(b"SELECT 1;")
            handle.flush()
            result, _commands, events = _run_operation_with_details(
                "import_local_sql",
                _shop_settings(database_name="main", import_local_file_path=handle.name),
                host,
            )
        warnings = [
            (args, kwargs)
            for args, kwargs in events
            if len(args) > 1 and args[1] == "postgres_local_sql_cleanup_warning"
        ]
        self.assertEqual(result["status"], "success", result)
        self.assertEqual(len(warnings), 1)
        self.assertEqual(warnings[0][1]["level"], "warning")

    def test_project_list_returns_a_status_collection_error(self):
        """A status probe error is returned unchanged before registry work starts."""
        status_error = _error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not collect PostgreSQL status.",
        )
        with patch.object(
            project_inventory,
            "_postgres_collect_service_status",
            return_value=(None, status_error),
        ):
            result, commands = _run_operation_with_host(
                "project_list",
                _shop_settings(),
                _RoutingHost(),
            )
        self.assertEqual(result, status_error)
        self.assertNotIn("deploydash.managed_databases", "\n".join(commands))

    def test_project_list_stops_when_cancelled_after_readiness(self):
        """Cancellation after readiness prevents all registry inventory reads."""
        result, commands = _run_operation_with_host(
            "project_list",
            _shop_settings(),
            _RoutingHost(),
            is_cancelled=_cancel_after(1),
        )
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertNotIn("deploydash.managed_databases", "\n".join(commands))

    def test_project_list_schemas_ignores_a_non_list_json_value(self):
        """Catalog JSON with the wrong shape becomes an empty schema collection."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (True, ["1"])),
                ("FROM pg_namespace", (True, ['{"oops":1}'])),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_list_schemas",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["status"], "success", result)
        self.assertEqual(result["schemas"], [])

    def test_project_list_tables_ignores_a_non_list_json_value(self):
        """Catalog JSON with the wrong shape becomes an empty table collection."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (True, ["1"])),
                ("WHERE c.relkind IN", (True, ['{"oops":1}'])),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_list_tables",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["status"], "success", result)
        self.assertEqual(result["tables"], [])

    def test_project_describe_table_skips_blank_relation_and_metadata_lines(self):
        """Blank query lines do not become relation kinds or metadata entries."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("SELECT 1 FROM pg_database WHERE datname", (True, ["1"])),
                ("SELECT c.relkind", (True, ["", "r"])),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_describe_table",
            _shop_settings(database_name="main", table_name="widgets"),
            host,
        )
        self.assertEqual(result["status"], "success", result)
        self.assertEqual(result["columns"], [])
        self.assertEqual(result["primary_key_columns"], [])
        self.assertEqual(result["indexes"], [])
        self.assertEqual(result["foreign_keys"], [])


if __name__ == "__main__":
    unittest.main()
