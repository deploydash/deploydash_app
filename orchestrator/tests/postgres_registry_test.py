"""Ownership registry for managed PostgreSQL resources (#80).

Project scoping must come from these tables -- never from ``LIKE`` name
matching, which crosses project boundaries two ways (``_`` wildcards and
nesting prefixes). Slice 1 covers the registry DDL, the register/unregister
statements, and the idempotent bootstrap that runs before project flows.
"""

import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from orchestrator import engine_postgres_ops
from orchestrator.postgres_runtime_parts import local_sql_import
from tests.engine_context_fixtures import build_test_context


class _FakeOutput:
    """Minimal shell-output double carrying stdout lines."""

    def __init__(self, stdout_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = []


class _CapturingHost:
    """Answers status probes and records every command for SQL assertions."""

    def __init__(self):
        self.commands = []

    def run_shell_command(self, command, *_args, **_kwargs):
        self.commands.append(command)
        if "CONFIGURED='false'" in command and "SHOW server_version" in command:
            return True, _FakeOutput(
                stdout_lines=[
                    '{"running":true,"health":"healthy","version":"17.8","configured":true}',
                ],
            )
        return True, _FakeOutput(stdout_lines=[])


class _FakeSession:
    """Session double that never reports a disconnect error."""

    def __init__(self, host):
        self.host = host

    def close(self):
        return {"disconnect_error": None}


def _error_result(code, msg, stage=None, details=None, extra=None):
    """Structured error shaped like the engine context's own."""
    return {
        "status": "error",
        "code": code,
        "msg": msg,
        "stage": stage,
        "details": details,
        "extra": extra or {},
    }


class _RoutingHost(_CapturingHost):
    """Capturing host that answers psql probes from canned result sets.

    Each rule pairs a command needle with either a fixed ``(status, lines)``
    answer or a callable taking the per-rule match count, so repeated probes
    (a roles listing, then its post-delete verification) can answer
    differently per call.
    """

    def __init__(self, rules=()):
        super().__init__()
        self._rules = list(rules)
        self._match_counts = [0] * len(self._rules)

    def run_shell_command(self, command, *_args, **_kwargs):
        self.commands.append(command)
        if "CONFIGURED='false'" in command and "SHOW server_version" in command:
            return True, _FakeOutput(
                stdout_lines=[
                    '{"running":true,"health":"healthy","version":"17.8","configured":true}',
                ],
            )
        for index, (needle, answer) in enumerate(self._rules):
            if needle not in command:
                continue
            self._match_counts[index] += 1
            if callable(answer):
                status, lines = answer(self._match_counts[index])
            else:
                status, lines = answer
            return status, _FakeOutput(stdout_lines=list(lines))
        return True, _FakeOutput(stdout_lines=[])


# Registry answer recording every looked-up name as project shop's own, so a
# flow gets past the ownership gate to the behavior under test (#127).
_OWNED_BY_SHOP = ("SELECT project_slug FROM deploydash.managed_", (True, ["shop"]))


def _run_operation_with_host(operation_id, settings, host, dry_run=False, is_cancelled=None):
    """Run one project operation against a scripted host, capturing SQL."""
    ctx = build_test_context(
        error_result=_error_result,
        emit_event=lambda *_args, **_kwargs: None,
        emit_shell_output_lines=lambda *_args, **_kwargs: None,
        command_error_details=lambda _output: "remote failed",
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
    return result, host.commands


class TestProjectRegistryFlows(unittest.TestCase):
    def test_create_database_registers_database_and_role(self):
        """A created database and its user land in the registry together."""
        host = _RoutingHost()
        result, commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        statements = "\n".join(commands)
        self.assertIn("INSERT INTO deploydash.managed_databases", statements)
        self.assertIn("'dd_shop_main'", statements)
        self.assertIn("INSERT INTO deploydash.managed_roles", statements)
        self.assertIn("'dd_shop_main_user'", statements)
        self.assertIn("'app'", statements)

    def test_create_failure_unregisters_what_it_rolled_back(self):
        """A failed create leaves no registry row for its rolled-back database."""
        host = _RoutingHost(
            rules=[
                ("GRANT USAGE, CREATE ON SCHEMA public", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["status"], "error")
        statements = "\n".join(commands)
        self.assertIn(
            "DELETE FROM deploydash.managed_databases",
            statements,
        )
        self.assertIn(
            "DELETE FROM deploydash.managed_roles",
            statements,
        )

    def test_registration_failure_rolls_back_the_created_resources(self):
        """A failed registration drops what the flow just created."""
        host = _RoutingHost(
            rules=[
                ("INSERT INTO deploydash.managed_databases", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("register", result["msg"].lower())
        statements = "\n".join(commands)
        self.assertIn("dropdb", statements)
        self.assertIn('DROP ROLE IF EXISTS "dd_shop_main_user"', statements)

    def test_cleanup_reports_unregister_failures(self):
        """Rollback names the registration it could not remove."""
        host = _RoutingHost(
            rules=[
                ("GRANT USAGE, CREATE ON SCHEMA public", (False, [])),
                ("DELETE FROM deploydash.managed_databases", (False, [])),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["status"], "error")
        self.assertIn("remove database registration", result["details"])

    def test_create_aborts_when_the_registry_cannot_be_ensured(self):
        """No database is created when bootstrap itself fails."""
        host = _RoutingHost(
            rules=[
                ("CREATE SCHEMA IF NOT EXISTS deploydash", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertNotIn("createdb", "\n".join(commands))

    def test_delete_database_unregisters_database_and_roles(self):
        """Dropping a database forgets it and its users in the registry."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    # First the pre-delete listing finds the user; the
                    # post-delete verification finds nobody left.
                    lambda call: (True, ["dd_shop_main_user"]) if call == 1 else (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        statements = "\n".join(commands)
        self.assertIn(
            "DELETE FROM deploydash.managed_databases",
            statements,
        )
        self.assertIn(
            "DELETE FROM deploydash.managed_roles",
            statements,
        )

    def test_delete_reports_unregister_failures(self):
        """A dropped database with a stale row fails loudly, not silently."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "FROM pg_roles WHERE rolname LIKE",
                    (True, ["[]"]),
                ),
                ("DELETE FROM deploydash.managed_databases", (False, [])),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_delete_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["status"], "error")
        self.assertIn("registration", result["msg"].lower())

    def test_delete_aborts_when_the_registry_cannot_be_ensured(self):
        """No drop runs when bootstrap itself fails."""
        host = _RoutingHost(
            rules=[
                ("CREATE SCHEMA IF NOT EXISTS deploydash", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertNotIn("dropdb", "\n".join(commands))

    def test_list_aborts_when_the_registry_cannot_be_ensured(self):
        """Listing fails loudly instead of enumerating without the registry."""
        host = _RoutingHost(
            rules=[
                ("CREATE SCHEMA IF NOT EXISTS deploydash", (False, [])),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_list",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")


def _shell_quoted_blob(value):
    """Quote one SQL literal the way the shared psql runner shell-quotes it."""
    return "'\"'\"'" + value + "'\"'\"'"


def _backfill_insert_command(commands, table):
    """Return the backfill command registering into ``table``."""
    matches = [command for command in commands if f"INSERT INTO {table}" in command]
    if len(matches) != 1:
        raise AssertionError(
            f"expected one INSERT INTO {table}, found {len(matches)}",
        )
    return matches[0]


class TestProjectRegistryBackfill(unittest.TestCase):
    def test_backfill_assigns_an_unregistered_database_from_its_role_comment(self):
        """A legacy database with a Deploy Dash role comment joins its project."""
        host = _RoutingHost(
            rules=[
                (
                    "left(datname, 3)",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "shobj_description",
                    (
                        True,
                        [
                            "dd_shop_main_user||deploydash:project=shop;"
                            "db=dd_shop_main;access=read_write",
                        ],
                    ),
                ),
                (
                    "FROM deploydash.managed_databases WHERE project_slug",
                    (True, ["dd_shop_main"]),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_list",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "known_project_slugs": ["shop"],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["databases"], ["dd_shop_main"])
        insert_command = _backfill_insert_command(
            commands,
            "deploydash.managed_databases",
        )
        self.assertLess(
            insert_command.index(_shell_quoted_blob("dd_shop_main")),
            insert_command.index(_shell_quoted_blob("shop")),
        )

    def test_backfill_prefers_the_longest_matching_project_prefix(self):
        """dd_shop_api_main belongs to shop-api, not shop."""
        host = _RoutingHost(
            rules=[
                (
                    "left(datname, 3)",
                    (True, ["dd_shop_api_main"]),
                ),
                (
                    "shobj_description",
                    (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_list",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "known_project_slugs": ["shop", "shop-api"],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        insert_command = _backfill_insert_command(
            commands,
            "deploydash.managed_databases",
        )
        self.assertLess(
            insert_command.index(_shell_quoted_blob("dd_shop_api_main")),
            insert_command.index(_shell_quoted_blob("shop-api")),
        )

    def test_backfill_leaves_unknown_databases_unassigned_and_lists_them(self):
        """A name matching nothing stays out of the registry but visible."""
        host = _RoutingHost(
            rules=[
                (
                    "left(datname, 3)",
                    (True, ["", "dd_mystery_main", "  "]),
                ),
                (
                    "shobj_description",
                    (True, ["", "  "]),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_list",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "known_project_slugs": ["shop"],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result.get("unassigned_databases"), ["dd_mystery_main"])
        self.assertEqual(result.get("ownership_conflicts"), [])
        self.assertNotIn("dd_mystery_main", "\n".join(commands))

    def test_backfill_reports_conflicting_role_comments_instead_of_guessing(self):
        """Two projects claiming one database is a conflict, not an assignment."""
        host = _RoutingHost(
            rules=[
                (
                    "left(datname, 3)",
                    (True, ["dd_contested_main"]),
                ),
                (
                    "shobj_description",
                    (
                        True,
                        [
                            "dd_contested_a||deploydash:project=shop-a;"
                            "db=dd_contested_main;access=read_write",
                            "dd_contested_b||deploydash:project=shop-b;"
                            "db=dd_contested_main;access=read_write",
                        ],
                    ),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_list",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop-a",
                "known_project_slugs": ["shop-a", "shop-b"],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(
            result.get("ownership_conflicts"),
            [{"datname": "dd_contested_main", "projects": ["shop-a", "shop-b"]}],
        )
        self.assertNotIn("dd_contested_main", "\n".join(commands))

    def test_backfill_registers_commented_roles_alongside_their_database(self):
        """A backfilled database brings its commented roles into the registry."""
        host = _RoutingHost(
            rules=[
                (
                    "left(datname, 3)",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "shobj_description",
                    (
                        True,
                        [
                            "dd_shop_main_user||deploydash:project=shop;"
                            "db=dd_shop_main;access=read_write",
                        ],
                    ),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_list",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "known_project_slugs": ["shop"],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        insert_command = _backfill_insert_command(
            commands,
            "deploydash.managed_roles",
        )
        role_insert = insert_command[insert_command.index("INSERT INTO deploydash.managed_roles") :]
        self.assertLess(
            role_insert.index(_shell_quoted_blob("dd_shop_main_user")),
            role_insert.index(_shell_quoted_blob("shop")),
        )
        self.assertLess(
            role_insert.index(_shell_quoted_blob("shop")),
            role_insert.index(_shell_quoted_blob("dd_shop_main")),
        )

    def test_backfill_skips_roles_that_are_already_registered(self):
        """A registered role is left alone while its database is backfilled."""
        host = _RoutingHost(
            rules=[
                (
                    "left(datname, 3)",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "shobj_description",
                    (
                        True,
                        [
                            "dd_shop_main_user|registered|deploydash:project=shop;"
                            "db=dd_shop_main;access=read_write",
                        ],
                    ),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_list",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "known_project_slugs": ["shop"],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        joined = "\n".join(commands)
        insert_command = _backfill_insert_command(
            commands,
            "deploydash.managed_databases",
        )
        self.assertLess(
            insert_command.index(_shell_quoted_blob("dd_shop_main")),
            insert_command.index(_shell_quoted_blob("shop")),
        )
        self.assertNotIn("INSERT INTO deploydash.managed_roles", joined)

    def test_backfill_aborts_the_operation_when_classification_fails(self):
        """A failed ownership scan aborts instead of proceeding half-scoped."""
        host = _RoutingHost(
            rules=[
                (
                    "left(datname, 3)",
                    (False, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "known_project_slugs": ["shop"],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertNotIn("createdb", "\n".join(commands))

    def test_backfill_aborts_when_role_comments_cannot_be_read(self):
        """A failed comment scan aborts instead of assigning blindly."""
        host = _RoutingHost(
            rules=[
                (
                    "left(datname, 3)",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "shobj_description",
                    (False, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "known_project_slugs": ["shop"],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertNotIn("createdb", "\n".join(commands))

    def test_backfill_aborts_when_assignment_registration_fails(self):
        """A failed backfill write aborts instead of half-registering."""
        host = _RoutingHost(
            rules=[
                (
                    "left(datname, 3)",
                    (True, ["dd_shop_api_main"]),
                ),
                (
                    "shobj_description",
                    (True, []),
                ),
                (
                    "INSERT INTO deploydash.managed_databases",
                    (False, []),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_list",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "known_project_slugs": ["shop", "shop-api"],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("backfill", result["msg"].lower())

    def test_project_list_aborts_when_leftover_scan_fails(self):
        """A failed unassigned scan fails the list instead of hiding names."""
        host = _RoutingHost(
            rules=[
                (
                    "left(datname, 3)",
                    lambda call: (True, []) if call == 1 else (False, []),
                ),
                (
                    "shobj_description",
                    (True, []),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_list",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "known_project_slugs": ["shop"],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")

    def test_backfill_leaves_unassigned_databases_out_of_project_delete(self):
        """Deletes drop registered resources only, never unassigned names."""
        host = _RoutingHost(
            rules=[
                (
                    "left(datname, 3)",
                    (True, ["dd_mystery_main"]),
                ),
                (
                    "shobj_description",
                    (True, []),
                ),
                (
                    "FROM deploydash.managed_databases WHERE project_slug",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "FROM deploydash.managed_roles WHERE datname",
                    (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "confirmed_databases": ["dd_shop_main"],
                "confirmed_users": [],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["dropped_databases"], ["dd_shop_main"])
        self.assertNotIn("dd_mystery_main", "\n".join(commands))

    def test_known_project_slugs_must_be_an_array(self):
        """A misshapen slug list is a validation error, not a silent skip."""
        host = _RoutingHost()
        result, _commands = _run_operation_with_host(
            "project_list",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "known_project_slugs": "shop",
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("must be an array", result["msg"])


class TestProjectRegistryBackfillClassification(unittest.TestCase):
    def test_parse_role_row_rejects_blank_and_mangled_rows(self):
        from orchestrator.postgres_runtime_parts import project_registry

        parse = project_registry._postgres_backfill_parse_role_row
        self.assertIsNone(parse(""))
        self.assertIsNone(parse("   "))
        self.assertIsNone(parse("just-a-rolname"))
        self.assertIsNone(parse("rolname|only-one-separator"))
        self.assertIsNone(parse("|empty-rolname|comment"))
        self.assertIsNone(parse("!!!|registered|deploydash:project=s;db=d"))

    def test_parse_role_row_keeps_pipes_inside_the_comment(self):
        from orchestrator.postgres_runtime_parts import project_registry

        row = project_registry._postgres_backfill_parse_role_row(
            "app_user||deploydash:project=s;db=d;access=read_write|tail",
        )
        self.assertEqual(
            row,
            {
                "rolname": "app_user",
                "registered": False,
                "comment": "deploydash:project=s;db=d;access=read_write|tail",
            },
        )

    def test_classify_reports_a_prefix_tie_instead_of_guessing(self):
        from orchestrator.postgres_runtime_parts import project_registry

        report = project_registry._postgres_backfill_classify(
            ["dd_shop_main"],
            [],
            ["shop", "SHOP"],
        )
        self.assertEqual(report["assigned"], {})
        self.assertEqual(report["unassigned"], [])
        self.assertEqual(
            report["conflicts"],
            [{"datname": "dd_shop_main", "projects": ["SHOP", "shop"]}],
        )

    def test_classify_skips_slugs_that_cannot_form_a_prefix(self):
        from orchestrator.postgres_runtime_parts import project_registry

        report = project_registry._postgres_backfill_classify(
            ["dd_shop_main"],
            [],
            ["!!!", "shop"],
        )
        self.assertEqual(report["assigned"], {"dd_shop_main": "shop"})
        self.assertEqual(report["conflicts"], [])

    def test_classify_marks_read_only_roles_for_backfill(self):
        from orchestrator.postgres_runtime_parts import project_registry

        report = project_registry._postgres_backfill_classify(
            ["dd_shop_main"],
            [
                {
                    "rolname": "dd_shop_reader",
                    "registered": False,
                    "comment": ("deploydash:project=shop;db=dd_shop_main;access=read_only"),
                },
            ],
            ["shop"],
        )
        self.assertEqual(
            report["roles"],
            [
                {
                    "rolname": "dd_shop_reader",
                    "project_slug": "shop",
                    "datname": "dd_shop_main",
                    "access_mode": "read_only",
                    "role_kind": "readonly",
                },
            ],
        )

    def test_classify_ignores_comments_without_an_owner(self):
        from orchestrator.postgres_runtime_parts import project_registry

        report = project_registry._postgres_backfill_classify(
            ["dd_shop_main"],
            [
                {
                    "rolname": "dd_shop_main_user",
                    "registered": False,
                    "comment": "deploydash:db=dd_shop_main",
                },
            ],
            [],
        )
        self.assertEqual(report["assigned"], {})
        self.assertEqual(report["roles"], [])
        self.assertEqual(report["unassigned"], ["dd_shop_main"])

    def test_classify_prefers_a_comment_over_a_prefix_match(self):
        from orchestrator.postgres_runtime_parts import project_registry

        report = project_registry._postgres_backfill_classify(
            ["dd_shop_main"],
            [
                {
                    "rolname": "dd_shop_main_user",
                    "registered": False,
                    "comment": ("deploydash:project=shop-api;db=dd_shop_main;access=read_write"),
                },
            ],
            ["shop"],
        )
        self.assertEqual(report["assigned"], {"dd_shop_main": "shop-api"})
        self.assertEqual(report["conflicts"], [])


class TestProjectDeleteConfirmation(unittest.TestCase):
    def test_delete_dry_run_lists_the_exact_databases_and_roles(self):
        """The confirm screen shows registry truth, not a static plan."""
        host = _RoutingHost(
            rules=[
                (
                    "FROM deploydash.managed_databases WHERE project_slug",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "FROM deploydash.managed_roles WHERE project_slug",
                    (True, ["dd_shop_main_user"]),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result.get("databases"), ["dd_shop_main"])
        self.assertEqual(result.get("users"), ["dd_shop_main_user"])
        joined = "\n".join(commands)
        self.assertNotIn("dropdb", joined)
        self.assertNotIn("DROP ROLE", joined)
        self.assertNotIn("DELETE FROM deploydash", joined)

    def test_delete_dry_run_requires_credentials(self):
        """A delete plan reads the live registry, so it needs a session."""
        host = _RoutingHost()
        result, commands = _run_operation_with_host(
            "project_delete",
            {
                "postgres_version": "17",
                "project_slug": "shop",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("credentials are missing", result["msg"])
        self.assertEqual(commands, [])

    def test_delete_execute_refuses_when_databases_drifted(self):
        """A database added after confirmation refuses the whole delete."""
        host = _RoutingHost(
            rules=[
                (
                    "FROM deploydash.managed_databases WHERE project_slug",
                    (True, ["dd_shop_main", "dd_shop_new"]),
                ),
                (
                    "FROM deploydash.managed_roles WHERE project_slug",
                    (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "confirmed_databases": ["dd_shop_main"],
                "confirmed_users": [],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("no longer matches", result["msg"])
        self.assertNotIn("dropdb", "\n".join(commands))

    def test_delete_execute_refuses_when_users_drifted(self):
        """A user added after confirmation refuses the whole delete."""
        host = _RoutingHost(
            rules=[
                (
                    "FROM deploydash.managed_databases WHERE project_slug",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "FROM deploydash.managed_roles WHERE project_slug",
                    (True, ["dd_shop_main_user", "dd_shop_extra_user"]),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "confirmed_databases": ["dd_shop_main"],
                "confirmed_users": ["dd_shop_main_user"],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("no longer matches", result["msg"])
        self.assertNotIn("dropdb", "\n".join(commands))

    def test_delete_execute_aborts_when_users_cannot_be_listed(self):
        """A failed user listing aborts before anything is dropped."""
        host = _RoutingHost(
            rules=[
                (
                    "FROM deploydash.managed_databases WHERE project_slug",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "FROM deploydash.managed_roles WHERE project_slug",
                    (False, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "confirmed_databases": ["dd_shop_main"],
                "confirmed_users": [],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertNotIn("dropdb", "\n".join(commands))

    def test_delete_execute_requires_confirmed_lists(self):
        """An unconfirmed project delete is refused without touching data."""
        host = _RoutingHost(
            rules=[
                (
                    "FROM deploydash.managed_databases WHERE project_slug",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "FROM deploydash.managed_roles WHERE project_slug",
                    (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertNotIn("dropdb", "\n".join(commands))

    def test_delete_execute_proceeds_when_confirmed_lists_match(self):
        """A matching confirmation deletes exactly the confirmed resources."""
        host = _RoutingHost(
            rules=[
                (
                    "FROM deploydash.managed_databases WHERE project_slug",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "FROM deploydash.managed_roles WHERE project_slug",
                    (True, ["dd_shop_main_user"]),
                ),
                (
                    "FROM deploydash.managed_roles WHERE datname",
                    (True, ["dd_shop_main_user"]),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_delete",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "confirmed_databases": ["dd_shop_main"],
                "confirmed_users": ["dd_shop_main_user"],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["dropped_databases"], ["dd_shop_main"])
        self.assertEqual(result["dropped_users"], ["dd_shop_main_user"])


class TestProjectRegistryCollisionRejection(unittest.TestCase):
    def test_create_rejects_an_already_prefixed_database_name(self):
        """A payload carrying a remote database name is refused outright."""
        host = _RoutingHost()
        result, commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "dd_shop_main",
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertNotIn("createdb", "\n".join(commands))

    def test_create_rejects_a_nested_foreign_prefix(self):
        """shop-api's remote name is not a logical name for shop."""
        host = _RoutingHost()
        result, commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "dd_shop_api_main",
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertNotIn("createdb", "\n".join(commands))

    def test_create_refuses_a_database_registered_to_another_project(self):
        """A collided remote name fails, naming the owning project."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop-api"]),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("shop-api", result["msg"])
        self.assertNotIn("createdb", "\n".join(commands))

    def test_create_refuses_a_username_registered_to_another_project(self):
        """A collided role name fails even when the database is unregistered."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, []),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_roles",
                    (True, ["shop-api"]),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("shop-api", result["msg"])
        self.assertNotIn("createdb", "\n".join(commands))

    def test_create_fails_when_ownership_cannot_be_inspected(self):
        """A failed ownership lookup aborts instead of creating blindly."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (False, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertNotIn("createdb", "\n".join(commands))

    def test_create_proceeds_when_names_are_registered_to_the_same_project(self):
        """Re-creating over your own registration is still allowed."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_roles",
                    (True, ["shop"]),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["status"], "success")

    def test_create_ignores_blank_lines_in_ownership_output(self):
        """Blank lookup lines mean unregistered, not owned by nobody."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["", "  "]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_roles",
                    (True, ["", "shop"]),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_create_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["status"], "success")

    def test_create_user_rejects_an_already_prefixed_username(self):
        """User creation takes a logical username, never a remote rolname."""
        host = _RoutingHost()
        result, _commands = _run_operation_with_host(
            "project_create_user",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "username": "dd_shop_main_user",
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")


class TestProjectRegistryLookups(unittest.TestCase):
    def test_project_list_reads_from_the_registry(self):
        """project_list returns exactly the project's registered resources."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT datname FROM pg_database WHERE NOT datistemplate",
                    (True, ["postgres", "dd_shop_main"]),
                ),
                (
                    "FROM deploydash.managed_databases",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"database": "dd_shop_main", '
                            '"access_mode": "read_write", "role_kind": "app"}, '
                            '{"username": "deploydash_owner_dd_shop_main_af424ac203f7", '
                            '"database": "dd_shop_main", '
                            '"access_mode": "owner", "role_kind": "owner"}, '
                            '{"username": "deploydash_agent_reader_dd_shop_main_af424ac203f7", '
                            '"database": "dd_shop_main", '
                            '"access_mode": "read_only", "role_kind": "agent_reader"}]',
                        ],
                    ),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_list",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["databases"], ["dd_shop_main"])
        self.assertEqual(
            result["users"],
            [
                {
                    "username": "dd_shop_main_user",
                    "database": "dd_shop_main",
                    "access_mode": "read_write",
                },
            ],
        )
        statements = "\n".join(commands)
        self.assertIn("FROM deploydash.managed_databases WHERE project_slug", statements)
        self.assertIn("FROM deploydash.managed_roles WHERE project_slug", statements)
        self.assertNotIn("LIKE", statements)

    def test_project_delete_drops_only_the_deleted_projects_resources(self):
        """Three slugs sharing a prefix: deleting one leaves two untouched."""
        host = _RoutingHost(
            rules=[
                # What the catalog holds: three projects sharing a prefix.
                # Prefix matching drops all three (the red run proves the
                # data loss); the registry holds only shop's rows.
                (
                    "SELECT datname FROM pg_database",
                    (
                        True,
                        ["dd_shop_main", "dd_shop_api_main", "dd_shops_main"],
                    ),
                ),
                (
                    "SELECT rolname FROM pg_roles",
                    (
                        True,
                        [
                            "dd_shop_main_user",
                            "dd_shop_api_main_user",
                            "dd_shops_main_user",
                        ],
                    ),
                ),
                (
                    "FROM deploydash.managed_databases",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (True, ["dd_shop_main_user"]),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "confirmed_databases": ["dd_shop_main"],
                "confirmed_users": ["dd_shop_main_user"],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["dropped_databases"], ["dd_shop_main"])
        self.assertEqual(result["dropped_users"], ["dd_shop_main_user"])
        statements = "\n".join(commands)
        self.assertNotIn("dd_shop_api_main", statements)
        self.assertNotIn("dd_shops_main", statements)

    def test_project_delete_unregisters_dropped_resources(self):
        """Whole-project delete forgets every dropped database and role."""
        host = _RoutingHost(
            rules=[
                (
                    "FROM deploydash.managed_databases",
                    (True, ["dd_shop_main"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (True, ["dd_shop_main_user"]),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "confirmed_databases": ["dd_shop_main"],
                "confirmed_users": ["dd_shop_main_user"],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["dropped_databases"], ["dd_shop_main"])
        self.assertEqual(result["dropped_users"], ["dd_shop_main_user"])
        statements = "\n".join(commands)
        self.assertIn("DELETE FROM deploydash.managed_databases", statements)
        self.assertIn("DELETE FROM deploydash.managed_roles", statements)

    def test_delete_user_sweep_reads_datnames_from_the_registry(self):
        """User cleanup without a database sweeps registry rows, not LIKE."""
        host = _RoutingHost(rules=[_OWNED_BY_SHOP])
        result, commands = _run_operation_with_host(
            "project_delete_user",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "username": "main_user",
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        statements = "\n".join(commands)
        self.assertIn("FROM deploydash.managed_databases", statements)
        self.assertNotIn("LIKE", statements)

    def test_delete_database_finds_users_in_the_registry(self):
        """Database delete resolves its users by exact registry match.

        #81 also drops the derived owner role: deleting a database drops
        its owner role and its registry rows. #83 drops the derived agent
        reader with it.
        """
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    lambda call: (True, ["dd_shop_main_user"]) if call == 1 else (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(
            result["dropped_users"],
            [
                "dd_shop_main_user",
                "deploydash_owner_dd_shop_main_af424ac203f7",
                "deploydash_agent_reader_dd_shop_main_af424ac203f7",
            ],
        )
        statements = "\n".join(commands)
        self.assertIn("FROM deploydash.managed_roles WHERE datname", statements)
        self.assertNotIn("LIKE", statements)

    def test_project_delete_of_an_empty_project_skips_unregister(self):
        """Deleting a project with no resources issues no registry writes."""
        host = _RoutingHost(
            rules=[
                (
                    "FROM deploydash.managed_databases",
                    (True, []),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "confirmed_databases": [],
                "confirmed_users": [],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["dropped_databases"], [])
        self.assertEqual(result["dropped_users"], [])
        self.assertNotIn("DELETE FROM deploydash", "\n".join(commands))

    def test_delete_user_unregisters_the_dropped_role(self):
        """Removing a user forgets its registry row."""
        host = _RoutingHost(rules=[_OWNED_BY_SHOP])
        result, commands = _run_operation_with_host(
            "project_delete_user",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "username": "main_user",
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        statements = "\n".join(commands)
        self.assertIn("DELETE FROM deploydash.managed_roles", statements)
        self.assertIn("dd_shop_main_user", statements)

    def test_delete_user_reports_unregister_failures(self):
        """A dropped role with a stale row fails loudly, not silently."""
        host = _RoutingHost(
            rules=[
                _OWNED_BY_SHOP,
                ("DELETE FROM deploydash.managed_roles", (False, [])),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_delete_user",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "username": "main_user",
            },
            host,
        )
        self.assertEqual(result["status"], "error")
        self.assertIn("registration", result["msg"].lower())

    def test_delete_user_aborts_when_the_registry_cannot_be_ensured(self):
        """No role is dropped when bootstrap itself fails."""
        host = _RoutingHost(
            rules=[
                ("CREATE SCHEMA IF NOT EXISTS deploydash", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete_user",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "username": "main_user",
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertNotIn("DROP ROLE", "\n".join(commands))


class TestProjectNormalizeDatabase(unittest.TestCase):
    def test_dry_run_reports_the_normalization_plan(self):
        """The confirm screen shows who is normalized and who loses CONNECT."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}, '
                            '{"username": "dd_shop_reader", '
                            '"access_mode": "read_only", "role_kind": "readonly"}, '
                            '{"username": '
                            '"deploydash_owner_dd_shop_main_af424ac203f7", '
                            '"access_mode": "owner", "role_kind": "owner"}]',
                        ],
                    ),
                ),
                (
                    "aclexplode",
                    (True, ["dd_shop_main_user", "dd_stray_role"]),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["database_name"], "main")
        self.assertEqual(result["remote_database_name"], "dd_shop_main")
        self.assertEqual(
            result["owner_name"],
            "deploydash_owner_dd_shop_main_af424ac203f7",
        )
        self.assertEqual(result["read_write_users"], ["dd_shop_main_user"])
        self.assertEqual(result["read_only_users"], ["dd_shop_reader"])
        self.assertEqual(
            result["roles_losing_connect"],
            ["dd_stray_role"],
        )

    def test_dry_run_requires_credentials(self):
        """A normalize plan reads live state, so it needs a session."""
        host = _RoutingHost()
        result, commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("credentials are missing", result["msg"])
        self.assertEqual(commands, [])

    def test_dry_run_requires_a_database_name(self):
        """Normalization without a target database is refused outright."""
        host = _RoutingHost()
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("database_name", result["msg"])

    def test_dry_run_refuses_a_database_that_does_not_exist(self):
        """A dropped database cannot be normalized."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, []),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("does not exist", result["msg"])

    def test_dry_run_refuses_an_unregistered_database(self):
        """Only registry-managed databases are normalized, never strangers."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, []),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("not registered as a managed database", result["msg"])

    def test_dry_run_refuses_a_database_registered_to_another_project(self):
        """Normalizing another project's database is refused outright."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop-api"]),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("shop-api", result["msg"])

    def test_dry_run_reports_role_listing_failure(self):
        """A failed role listing aborts the plan instead of planning blind."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (False, []),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("database users", result["msg"])

    def test_dry_run_reports_connect_scan_failure(self):
        """A failed implicit-CONNECT scan aborts instead of hiding losers."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (True, ["[]"]),
                ),
                (
                    "aclexplode",
                    (False, []),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("CONNECT", result["msg"])

    def test_dry_run_skips_rows_it_cannot_act_on(self):
        """Junk rows, unknown modes, and future kinds stay out of the plan."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '["junk-string", 42, {"username": 42}, '
                            '{"username": "u1", "access_mode": "bogus", '
                            '"role_kind": "app"}, '
                            '{"username": "agentx", "access_mode": "read_write", '
                            '"role_kind": "agent_reader"}, '
                            '{"username": '
                            '"deploydash_owner_dd_shop_main_af424ac203f7", '
                            '"access_mode": "read_write", "role_kind": "app"}, '
                            '{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}]',
                        ],
                    ),
                ),
                (
                    "aclexplode",
                    (True, []),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["read_write_users"], ["dd_shop_main_user"])
        self.assertEqual(result["read_only_users"], [])

    def test_dry_run_fails_when_roles_cannot_be_parsed(self):
        """An unreadable role listing fails loudly instead of planning empty."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (True, ["not json{{{"]),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("database users", result["msg"])

    def test_dry_run_reports_existence_probe_failure(self):
        """A failed existence probe aborts instead of planning blind."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (False, []),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("inspect target database", result["msg"])

    def test_dry_run_reports_ownership_probe_failure(self):
        """A failed managed check aborts instead of normalizing blindly."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (False, []),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("ownership", result["msg"])

    def test_dry_run_fails_when_roles_are_not_a_list(self):
        """A valid-JSON-but-not-a-list role payload fails loudly."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (True, ['{"oops": 1}']),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("database users", result["msg"])

    def test_dry_run_aborts_when_the_registry_cannot_be_ensured(self):
        """No plan is built when bootstrap itself fails."""
        host = _RoutingHost(
            rules=[
                ("CREATE SCHEMA IF NOT EXISTS deploydash", (False, [])),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
            dry_run=True,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")

    def test_apply_normalizes_ownership_and_access(self):
        """A confirmed apply reassigns, grants, revokes PUBLIC, and registers."""
        owner = "deploydash_owner_dd_shop_main_af424ac203f7"
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}, '
                            '{"username": "dd_shop_reader", '
                            '"access_mode": "read_only", "role_kind": "readonly"}]',
                        ],
                    ),
                ),
                (
                    "SELECT rolname FROM pg_roles WHERE rolname IN",
                    (True, ["dd_shop_main_user", "dd_shop_reader"]),
                ),
                (
                    "aclexplode",
                    lambda call: (
                        (True, ["dd_shop_main_user", "dd_stray_role"]) if call == 1 else (True, [])
                    ),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": [
                    "dd_shop_main_user",
                    "dd_shop_reader",
                ],
                "confirmed_lost_connect_roles": ["dd_stray_role"],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["msg"], "Database isolation normalized.")
        self.assertEqual(
            result["normalized_users"],
            ["dd_shop_main_user", "dd_shop_reader"],
        )
        self.assertEqual(result["roles_losing_connect"], ["dd_stray_role"])
        self.assertEqual(result["roles_lost_connect"], ["dd_stray_role"])
        statements = "\n".join(commands)
        self.assertIn(
            f'REASSIGN OWNED BY "dd_shop_main_user", "dd_shop_reader" TO "{owner}";',
            statements,
        )
        self.assertIn(
            f'ALTER DATABASE "dd_shop_main" OWNER TO "{owner}";',
            statements,
        )
        self.assertIn(
            f'ALTER SCHEMA public OWNER TO "{owner}";',
            statements,
        )
        self.assertIn(
            f'GRANT "{owner}" TO "dd_shop_main_user";',
            statements,
        )
        self.assertIn(
            f'ALTER ROLE "dd_shop_main_user" IN DATABASE "dd_shop_main" SET role = "{owner}";',
            statements,
        )
        self.assertNotIn(f'GRANT "{owner}" TO "dd_shop_reader"', statements)
        self.assertIn(
            f'ALTER DEFAULT PRIVILEGES FOR ROLE "{owner}" '
            'IN SCHEMA public GRANT SELECT ON TABLES TO "dd_shop_reader";',
            statements,
        )
        self.assertIn(
            'GRANT SELECT ON ALL TABLES IN SCHEMA public TO "dd_shop_reader";',
            statements,
        )
        self.assertIn(
            'GRANT CONNECT, TEMP ON DATABASE "dd_shop_main" TO "dd_shop_main_user";',
            statements,
        )
        self.assertIn(
            'GRANT CONNECT, TEMP ON DATABASE "dd_shop_main" TO "dd_shop_reader";',
            statements,
        )
        self.assertIn(
            'REVOKE CONNECT, TEMP ON DATABASE "dd_shop_main" FROM PUBLIC;',
            statements,
        )
        self.assertLess(
            statements.index(
                'GRANT CONNECT, TEMP ON DATABASE "dd_shop_main" TO "dd_shop_main_user";'
            ),
            statements.index('REVOKE CONNECT, TEMP ON DATABASE "dd_shop_main" FROM PUBLIC;'),
        )
        insert_command = _backfill_insert_command(
            commands,
            "deploydash.managed_roles",
        )
        self.assertIn(_shell_quoted_blob(owner), insert_command)
        self.assertIn(_shell_quoted_blob("owner"), insert_command)

    def test_apply_refuses_missing_registry_roles_before_mutation(self):
        """Out-of-band role deletion must stop normalization before any write."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}, '
                            '{"username": "dd_shop_reader", '
                            '"access_mode": "read_only", "role_kind": "readonly"}]',
                        ],
                    ),
                ),
                (
                    "aclexplode",
                    (True, []),
                ),
                (
                    "SELECT rolname FROM pg_roles WHERE rolname IN",
                    (True, ["dd_shop_main_user"]),
                ),
                (
                    "REASSIGN OWNED BY",
                    (False, []),
                ),
            ],
        )

        result, commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": [
                    "dd_shop_main_user",
                    "dd_shop_reader",
                ],
                "confirmed_lost_connect_roles": [],
            },
            host,
        )

        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(
            result["msg"],
            "One or more registered database users no longer exist in PostgreSQL. "
            "Remove the stale user from Deploy Dash, review the normalize plan, "
            "then try again.",
        )
        self.assertEqual(result["details"], "Missing PostgreSQL roles: dd_shop_reader")
        statements = "\n".join(commands)
        self.assertNotIn("NOLOGIN", statements)
        self.assertNotIn("REASSIGN OWNED BY", statements)
        self.assertNotIn("REVOKE CONNECT, TEMP", statements)
        self.assertNotIn("INSERT INTO deploydash.managed_roles", statements)

    def test_apply_reports_live_role_preflight_failure_before_mutation(self):
        """An unreadable live-role catalog must not permit a partial normalize."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}]',
                        ],
                    ),
                ),
                (
                    "aclexplode",
                    (True, []),
                ),
                (
                    "SELECT rolname FROM pg_roles WHERE rolname IN",
                    (False, []),
                ),
            ],
        )

        result, commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": ["dd_shop_main_user"],
                "confirmed_lost_connect_roles": [],
            },
            host,
        )

        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not inspect live database users.")
        self.assertEqual(result["details"], "remote failed")
        statements = "\n".join(commands)
        self.assertNotIn("NOLOGIN", statements)
        self.assertNotIn("REASSIGN OWNED BY", statements)
        self.assertNotIn("REVOKE CONNECT, TEMP", statements)
        self.assertNotIn("INSERT INTO deploydash.managed_roles", statements)

    def test_apply_refuses_when_users_drifted(self):
        """A user added after confirmation refuses the whole apply."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}, '
                            '{"username": "dd_shop_newbie", '
                            '"access_mode": "read_write", "role_kind": "app"}]',
                        ],
                    ),
                ),
                (
                    "aclexplode",
                    (True, ["dd_shop_main_user"]),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": ["dd_shop_main_user"],
                "confirmed_lost_connect_roles": ["dd_shop_main_user"],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("no longer matches", result["msg"])
        joined = "\n".join(commands)
        self.assertNotIn("REASSIGN OWNED BY", joined)
        self.assertNotIn("REVOKE CONNECT, TEMP", joined)

    def test_apply_refuses_when_losing_roles_drifted(self):
        """A new implicit role after confirmation refuses the whole apply."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}]',
                        ],
                    ),
                ),
                (
                    "aclexplode",
                    (True, ["dd_shop_main_user", "dd_newcomer"]),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": ["dd_shop_main_user"],
                "confirmed_lost_connect_roles": ["dd_shop_main_user"],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("no longer matches", result["msg"])
        joined = "\n".join(commands)
        self.assertNotIn("REASSIGN OWNED BY", joined)
        self.assertNotIn("REVOKE CONNECT, TEMP", joined)

    def test_apply_reports_owner_provisioning_failure(self):
        """A failed owner ensure aborts before anything is reassigned."""
        host = _RoutingHost(
            rules=[
                ("NOLOGIN", (False, [])),
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}]',
                        ],
                    ),
                ),
                (
                    "SELECT rolname FROM pg_roles WHERE rolname IN",
                    (True, ["dd_shop_main_user"]),
                ),
                (
                    "aclexplode",
                    (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": ["dd_shop_main_user"],
                "confirmed_lost_connect_roles": [],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not provision the database owner role.", result["msg"])
        self.assertNotIn("REASSIGN OWNED BY", "\n".join(commands))

    def test_apply_reports_ownership_transfer_failure(self):
        """A failed reassignment aborts before access changes."""
        host = _RoutingHost(
            rules=[
                ("REASSIGN OWNED BY", (False, [])),
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}]',
                        ],
                    ),
                ),
                (
                    "SELECT rolname FROM pg_roles WHERE rolname IN",
                    (True, ["dd_shop_main_user"]),
                ),
                (
                    "aclexplode",
                    (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": ["dd_shop_main_user"],
                "confirmed_lost_connect_roles": [],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn(
            "Could not transfer object ownership to the owner role.",
            result["msg"],
        )
        self.assertNotIn("REVOKE CONNECT, TEMP", "\n".join(commands))

    def test_apply_reports_access_change_failure(self):
        """A failed access transaction aborts before registration."""
        host = _RoutingHost(
            rules=[
                ("REVOKE CONNECT, TEMP", (False, [])),
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}]',
                        ],
                    ),
                ),
                (
                    "SELECT rolname FROM pg_roles WHERE rolname IN",
                    (True, ["dd_shop_main_user"]),
                ),
                (
                    "aclexplode",
                    (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": ["dd_shop_main_user"],
                "confirmed_lost_connect_roles": [],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not apply database access changes.", result["msg"])
        self.assertNotIn("INSERT INTO deploydash.managed_roles", "\n".join(commands))

    def test_apply_reports_owner_registration_failure(self):
        """A failed owner registration fails loudly after access changes."""
        host = _RoutingHost(
            rules=[
                ("INSERT INTO deploydash.managed_roles", (False, [])),
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}]',
                        ],
                    ),
                ),
                (
                    "SELECT rolname FROM pg_roles WHERE rolname IN",
                    (True, ["dd_shop_main_user"]),
                ),
                (
                    "aclexplode",
                    (True, []),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": ["dd_shop_main_user"],
                "confirmed_lost_connect_roles": [],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not register the database owner role.", result["msg"])

    def test_apply_reports_verification_failure(self):
        """A failed post-apply scan fails loudly instead of assuming success."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}]',
                        ],
                    ),
                ),
                (
                    "SELECT rolname FROM pg_roles WHERE rolname IN",
                    (True, ["dd_shop_main_user"]),
                ),
                (
                    "aclexplode",
                    lambda call: (True, []) if call == 1 else (False, []),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": ["dd_shop_main_user"],
                "confirmed_lost_connect_roles": [],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not verify database normalization.", result["msg"])

    def test_apply_refuses_when_roles_still_connect_implicitly(self):
        """A revoke that did not land is reported, not claimed as success."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}]',
                        ],
                    ),
                ),
                (
                    "SELECT rolname FROM pg_roles WHERE rolname IN",
                    (True, ["dd_shop_main_user"]),
                ),
                (
                    "aclexplode",
                    (True, ["dd_stray_role"]),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": ["dd_shop_main_user"],
                "confirmed_lost_connect_roles": ["dd_stray_role"],
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("could not be verified", result["msg"])
        self.assertIn("dd_stray_role", result["details"])

    def test_apply_honours_cancellation_before_mutating(self):
        """A cancelled apply changes nothing."""
        calls = []

        def cancel_after_preflight():
            calls.append(1)
            return len(calls) > 1

        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}]',
                        ],
                    ),
                ),
                (
                    "aclexplode",
                    (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": ["dd_shop_main_user"],
                "confirmed_lost_connect_roles": [],
            },
            host,
            is_cancelled=cancel_after_preflight,
        )
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertIn("during PostgreSQL operation", result["msg"])
        joined = "\n".join(commands)
        self.assertNotIn("REASSIGN OWNED BY", joined)
        self.assertNotIn("REVOKE CONNECT, TEMP", joined)
        self.assertNotIn("NOLOGIN", joined)

    def test_apply_with_no_users_revokes_public_only(self):
        """A userless database still gets an owner and a PUBLIC revoke."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (True, ["[]"]),
                ),
                (
                    "aclexplode",
                    (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": [],
                "confirmed_lost_connect_roles": [],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["normalized_users"], [])
        self.assertEqual(result["roles_lost_connect"], [])
        statements = "\n".join(commands)
        self.assertNotIn("REASSIGN OWNED BY", statements)
        self.assertIn(
            'REVOKE CONNECT, TEMP ON DATABASE "dd_shop_main" FROM PUBLIC;',
            statements,
        )

    def test_apply_is_idempotent_for_an_already_normalized_database(self):
        """Re-running over normalized state succeeds and changes nothing."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (
                        True,
                        [
                            '[{"username": "dd_shop_main_user", '
                            '"access_mode": "read_write", "role_kind": "app"}]',
                        ],
                    ),
                ),
                (
                    "SELECT rolname FROM pg_roles WHERE rolname IN",
                    (True, ["dd_shop_main_user"]),
                ),
                (
                    "aclexplode",
                    (True, []),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
                "confirmed_normalize_users": ["dd_shop_main_user"],
                "confirmed_lost_connect_roles": [],
            },
            host,
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["roles_lost_connect"], [])
        self.assertIn(
            'REVOKE CONNECT, TEMP ON DATABASE "dd_shop_main" FROM PUBLIC;',
            "\n".join(commands),
        )

    def test_apply_requires_the_confirmed_plan_from_its_dry_run(self):
        """Applying without the dry-run confirmation is refused outright."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT 1 FROM pg_database WHERE datname",
                    (True, ["1"]),
                ),
                (
                    "SELECT project_slug FROM deploydash.managed_databases",
                    (True, ["shop"]),
                ),
                (
                    "FROM deploydash.managed_roles",
                    (True, ["[]"]),
                ),
                (
                    "aclexplode",
                    (True, []),
                ),
            ],
        )
        result, _commands = _run_operation_with_host(
            "project_normalize_database",
            {
                "postgres_version": "17",
                "superuser_password": "secret",
                "project_slug": "shop",
                "database_name": "main",
            },
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("dry run", result["msg"])


class TestProjectRegistryBootstrap(unittest.TestCase):
    def _run_list_with_capturing_host(self):
        """Run project_list against a host that records every command."""
        host = _CapturingHost()
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=host),
            },
        )
        result = engine_postgres_ops.run_postgres_project_operation(
            ctx,
            "project_list",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            raw_data={
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "secret",
                    "project_slug": "shop",
                },
            },
        )
        return result, host.commands

    def test_project_list_bootstraps_the_registry_first(self):
        """Listing a project ensures the ownership tables exist beforehand."""
        result, commands = self._run_list_with_capturing_host()
        self.assertEqual(result["status"], "success")
        bootstrap = [
            command for command in commands if "CREATE SCHEMA IF NOT EXISTS deploydash" in command
        ]
        self.assertEqual(
            len(bootstrap),
            1,
            "project_list must bootstrap the registry exactly once.",
        )
        list_queries = [
            command
            for command in commands
            if "FROM deploydash.managed_databases" in command
            or "FROM deploydash.managed_roles" in command
        ]
        self.assertTrue(
            list_queries,
            "project_list must still enumerate databases and roles.",
        )
        self.assertLess(
            commands.index(bootstrap[0]),
            commands.index(list_queries[0]),
            "Bootstrap must precede any project enumeration.",
        )

    def test_bootstrap_is_idempotent_and_superuser_owned(self):
        """Bootstrap DDL is rerunnable and locked away from PUBLIC."""
        from orchestrator.postgres_runtime_parts import project_registry

        sql = project_registry._postgres_registry_bootstrap_sql("deploydash_su")
        self.assertIn(
            'CREATE SCHEMA IF NOT EXISTS deploydash AUTHORIZATION "deploydash_su"',
            sql,
        )
        self.assertIn("CREATE TABLE IF NOT EXISTS deploydash.managed_databases", sql)
        self.assertIn("CREATE TABLE IF NOT EXISTS deploydash.managed_roles", sql)
        self.assertIn("datname text PRIMARY KEY", sql)
        self.assertIn("rolname text PRIMARY KEY", sql)
        self.assertIn("project_slug text NOT NULL", sql)
        self.assertEqual(sql.count("REVOKE ALL"), 3)
        self.assertIn("REVOKE ALL ON SCHEMA deploydash FROM PUBLIC", sql)

    def test_register_and_unregister_cover_databases_and_roles(self):
        """Registration statements upsert; removal deletes by exact name."""
        from orchestrator.postgres_runtime_parts import project_registry

        register_db = project_registry._postgres_registry_register_database_sql(
            "dd_shop_main",
            "shop",
        )
        self.assertIn("INSERT INTO deploydash.managed_databases", register_db)
        self.assertIn("ON CONFLICT (datname) DO UPDATE", register_db)
        self.assertIn("'dd_shop_main'", register_db)
        self.assertIn("'shop'", register_db)

        unregister_db = project_registry._postgres_registry_unregister_database_sql(
            "dd_shop_main",
        )
        self.assertIn("DELETE FROM deploydash.managed_databases", unregister_db)
        self.assertIn("WHERE datname = 'dd_shop_main'", unregister_db)

        register_role = project_registry._postgres_registry_register_role_sql(
            "dd_shop_main_user",
            "shop",
            datname="dd_shop_main",
            access_mode="read_write",
            role_kind="app",
        )
        self.assertIn("INSERT INTO deploydash.managed_roles", register_role)
        self.assertIn("ON CONFLICT (rolname) DO UPDATE", register_role)
        self.assertIn("'dd_shop_main_user'", register_role)

        unregister_role = project_registry._postgres_registry_unregister_role_sql(
            "dd_shop_main_user",
        )
        self.assertIn("DELETE FROM deploydash.managed_roles", unregister_role)
        self.assertIn("WHERE rolname = 'dd_shop_main_user'", unregister_role)

    def test_database_roles_sql_lists_one_databases_roles_with_kinds(self):
        """Normalization reads who belongs to a database from the registry."""
        from orchestrator.postgres_runtime_parts import project_registry

        sql = project_registry._postgres_registry_database_roles_sql("dd_shop_main")
        self.assertIn("FROM deploydash.managed_roles", sql)
        self.assertIn("WHERE datname = 'dd_shop_main'", sql)
        self.assertIn("'username', rolname", sql)
        self.assertIn("'access_mode', access_mode", sql)
        self.assertIn("'role_kind', role_kind", sql)
        self.assertIn("ORDER BY rolname", sql)

    def test_list_roles_sql_exposes_only_login_user_kinds(self):
        """The ordinary user inventory must hide product-owned infrastructure roles."""
        from orchestrator.postgres_runtime_parts import project_registry

        sql = project_registry._postgres_registry_list_roles_sql("shop")

        self.assertIn("'role_kind', role_kind", sql)
        self.assertIn("role_kind IN ('app', 'readonly')", sql)
        self.assertNotIn("'owner'", sql)
        self.assertNotIn("'agent_reader'", sql)

    def test_register_role_rejects_unknown_role_kinds(self):
        """Only the five known role kinds may be registered."""
        from orchestrator.postgres_runtime_parts import project_registry

        with self.assertRaises(ValueError) as raised:
            project_registry._postgres_registry_register_role_sql(
                "dd_shop_main_user",
                "shop",
                datname="dd_shop_main",
                access_mode="read_write",
                role_kind="superadmin",
            )
        self.assertIn("superadmin", str(raised.exception))

    def test_bootstrap_failure_aborts_with_a_registry_error(self):
        """A registry that cannot be ensured fails the operation loudly."""
        from orchestrator.postgres_runtime_parts import project_registry

        host = _CapturingHost()
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "remote failed",
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(host=host),
            },
        )
        with patch.object(
            project_registry,
            "_run_postgres_psql_query_impl",
            return_value=(False, _FakeOutput()),
        ):
            error = project_registry._ensure_postgres_project_registry(
                ctx,
                _FakeSession(host=host),
                SimpleNamespace(superuser_name="deploydash_su"),
                emit=None,
            )
        self.assertIsNotNone(error)
        self.assertEqual(error["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("registry", error["msg"].lower())


def _shop_settings(**extra):
    """Settings for a request made by project "shop", plus ``extra``."""
    settings = {
        "postgres_version": "17",
        "superuser_password": "secret",
        "project_slug": "shop",
    }
    settings.update(extra)
    return settings


# A filesystem backup destination that passes settings validation.
_FILESYSTEM_BACKUP = {
    "backup_destination_type": "filesystem",
    "backup_file_prefix": "/var/backups/deploydash",
    "backup_policy_id": "daily",
}


class TestNamedResourceOwnership(unittest.TestCase):
    """Operations that name a database or user refuse another project's (#127).

    Project "shop" names shop-api's resources by logical name: ``dd_shop_``
    plus ``api_main`` is shop-api's ``main``. The fake registry records those
    names as shop-api's, so every call must fail before it touches them.
    """

    def _run_refused(self, operation_id, settings, rules):
        """Run one shop request against ``rules``; assert a validation refusal."""
        host = _RoutingHost(rules=rules)
        result, commands = _run_operation_with_host(operation_id, settings, host)
        self.assertEqual(result["status"], "error", result)
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR", result)
        return result, commands

    def _foreign_rules(self):
        """Registry answers naming shop-api as the owner of every lookup."""
        return [
            ("SELECT project_slug FROM deploydash.managed_", (True, ["shop-api"])),
            ("SELECT 1 FROM pg_database WHERE datname", (True, ["1"])),
        ]

    def test_delete_database_refuses_another_projects_database(self):
        """shop cannot drop shop-api's main by calling it api_main."""
        result, commands = self._run_refused(
            "project_delete_database",
            _shop_settings(database_name="api_main"),
            self._foreign_rules(),
        )
        self.assertEqual(result["msg"], "This database is registered to project 'shop-api'.")
        self.assertEqual(result["details"], "dd_shop_api_main")
        self.assertNotIn("dropdb", "\n".join(commands))

    def test_rotate_password_refuses_another_projects_user(self):
        """shop cannot take over shop-api's login by resetting its password."""
        result, commands = self._run_refused(
            "project_rotate_password",
            _shop_settings(username="api_main_user"),
            self._foreign_rules(),
        )
        self.assertEqual(result["msg"], "This user is registered to project 'shop-api'.")
        self.assertNotIn("ALTER ROLE", "\n".join(commands))
        self.assertNotIn("password", result)

    def test_delete_user_refuses_another_projects_user(self):
        """shop cannot drop shop-api's user."""
        _result, commands = self._run_refused(
            "project_delete_user",
            _shop_settings(username="api_main_user"),
            self._foreign_rules(),
        )
        statements = "\n".join(commands)
        self.assertNotIn("DROP ROLE", statements)
        self.assertNotIn("REASSIGN OWNED", statements)

    def test_delete_user_refuses_another_projects_database(self):
        """A user of shop still cannot be swept out of shop-api's database."""
        rules = [
            ("SELECT project_slug FROM deploydash.managed_roles", (True, ["shop"])),
            ("SELECT project_slug FROM deploydash.managed_databases", (True, ["shop-api"])),
        ]
        result, commands = self._run_refused(
            "project_delete_user",
            _shop_settings(username="main_user", database_name="api_main"),
            rules,
        )
        self.assertEqual(result["msg"], "This database is registered to project 'shop-api'.")
        self.assertNotIn("REASSIGN OWNED", "\n".join(commands))

    def test_create_user_requires_the_callers_own_database(self):
        """A new user is never added to a database the caller does not own."""
        result, commands = self._run_refused(
            "project_create_user",
            _shop_settings(database_name="api_main", username="intruder"),
            [
                ("SELECT project_slug FROM deploydash.managed_databases", (True, [])),
                ("SELECT 1 FROM pg_database WHERE datname", (True, ["1"])),
            ],
        )
        self.assertEqual(result["msg"], "This database is not registered as a managed database.")
        statements = "\n".join(commands)
        self.assertNotIn("CREATE ROLE", statements)
        self.assertNotIn("ALTER ROLE", statements)

    def test_read_operations_refuse_another_projects_database(self):
        """shop cannot read shop-api's catalog or rows."""
        for operation_id in (
            "project_list_schemas",
            "project_list_tables",
            "project_describe_table",
            "project_explain_readonly_query",
            "project_execute_readonly_query",
        ):
            with self.subTest(operation_id=operation_id):
                _result, commands = self._run_refused(
                    operation_id,
                    _shop_settings(database_name="api_main", table_name="t", sql="SELECT 1"),
                    self._foreign_rules(),
                )
                self.assertNotIn("-d dd_shop_api_main", "\n".join(commands))

    def test_backup_operations_refuse_another_projects_database(self):
        """shop cannot schedule or run a backup of shop-api's database."""
        for operation_id in ("backup_policy_apply", "backup_run_now"):
            with self.subTest(operation_id=operation_id):
                _result, commands = self._run_refused(
                    operation_id,
                    _shop_settings(backup_database_name="api_main", **_FILESYSTEM_BACKUP),
                    self._foreign_rules(),
                )
                self.assertNotIn("wal-g", "\n".join(commands))

    def test_restore_refuses_a_target_registered_to_another_project(self):
        """A restore cannot land in a name that shop-api owns."""
        _result, commands = self._run_refused(
            "restore_run_now",
            _shop_settings(
                backup_target_database_name="api_main",
                backup_artifact_path="sample.dump",
                **_FILESYSTEM_BACKUP,
            ),
            self._foreign_rules(),
        )
        statements = "\n".join(commands)
        self.assertNotIn("wal-g", statements)
        self.assertNotIn("createdb", statements)

    def test_import_refuses_another_projects_database(self):
        """shop cannot import SQL into shop-api's database."""
        with (
            tempfile.NamedTemporaryFile(suffix=".sql") as handle,
            patch.object(
                local_sql_import,
                "_upload_local_sql_import_file",
                side_effect=AssertionError("the upload must not start"),
            ),
        ):
            self._run_refused(
                "import_local_sql",
                _shop_settings(database_name="api_main", import_local_file_path=handle.name),
                self._foreign_rules(),
            )

    def test_normalize_refuses_another_projects_database(self):
        """The normalize flow uses the same gate and wording as every other flow."""
        result, _commands = self._run_refused(
            "project_normalize_database",
            _shop_settings(database_name="api_main"),
            self._foreign_rules(),
        )
        self.assertEqual(result["msg"], "This database is registered to project 'shop-api'.")

    def test_owned_names_must_be_registered_to_the_caller(self):
        """A name nobody registered is refused, naming the calling project."""
        result, commands = self._run_refused(
            "project_rotate_password",
            _shop_settings(username="main_user"),
            [("SELECT project_slug FROM deploydash.managed_", (True, []))],
        )
        self.assertEqual(result["msg"], "This user is not registered as a managed user.")
        self.assertNotIn("ALTER ROLE", "\n".join(commands))

    def test_ownership_lookup_failure_is_an_error(self):
        """A failed ownership lookup stops the operation."""
        host = _RoutingHost(
            rules=[("SELECT project_slug FROM deploydash.managed_", (False, []))],
        )
        result, commands = _run_operation_with_host(
            "project_rotate_password",
            _shop_settings(username="main_user"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not inspect user ownership.")
        self.assertNotIn("ALTER ROLE", "\n".join(commands))

    def test_ownership_gate_stops_when_the_registry_cannot_be_ensured(self):
        """A failed registry bootstrap stops the operation before any lookup."""
        host = _RoutingHost(rules=[("CREATE SCHEMA IF NOT EXISTS deploydash", (False, []))])
        result, commands = _run_operation_with_host(
            "project_rotate_password",
            _shop_settings(username="main_user"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not ensure the PostgreSQL ownership registry.")
        self.assertNotIn("ALTER ROLE", "\n".join(commands))


class TestCreateNeverAdoptsExistingNames(unittest.TestCase):
    """Creating never takes over a database or user nobody registered (#127).

    An unregistered name that already exists in the cluster may belong to a
    project the desktop does not know about, so create and restore refuse it
    instead of registering it to the caller.
    """

    def test_create_database_refuses_an_existing_unregistered_database(self):
        """An existing database with no registry row is not adopted."""
        host = _RoutingHost(
            rules=[
                ("SELECT project_slug FROM deploydash.managed_", (True, [])),
                ("SELECT 1 FROM pg_database WHERE datname", (True, ["1"])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_create_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR", result)
        self.assertEqual(
            result["msg"],
            "This database already exists but is not registered to any project.",
        )
        self.assertEqual(result["details"], "dd_shop_main")
        statements = "\n".join(commands)
        self.assertNotIn("CREATE ROLE", statements)
        self.assertNotIn("INSERT INTO deploydash.managed_databases", statements)

    def test_create_refuses_an_existing_unregistered_user(self):
        """An existing login with no registry row is not taken over."""
        host = _RoutingHost(
            rules=[
                ("SELECT project_slug FROM deploydash.managed_", (True, [])),
                ("SELECT 1 FROM pg_roles WHERE rolname", (True, ["1"])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_create_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR", result)
        self.assertEqual(
            result["msg"],
            "This user already exists but is not registered to any project.",
        )
        self.assertEqual(result["details"], "dd_shop_main_user")
        statements = "\n".join(commands)
        self.assertNotIn("ALTER ROLE", statements)
        self.assertNotIn("createdb", statements)

    def test_restore_refuses_an_existing_unregistered_target(self):
        """A restore target that exists unregistered is refused before any work."""
        host = _RoutingHost(
            rules=[
                ("SELECT project_slug FROM deploydash.managed_", (True, [])),
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
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR", result)
        self.assertEqual(
            result["msg"],
            "This database already exists but is not registered to any project.",
        )
        self.assertNotIn("wal-g", "\n".join(commands))

    def test_existence_check_failure_is_an_error(self):
        """A failed catalog check stops the create before anything is made."""
        host = _RoutingHost(
            rules=[
                ("SELECT project_slug FROM deploydash.managed_", (True, [])),
                ("SELECT 1 FROM pg_database WHERE datname", (False, [])),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_create_database",
            _shop_settings(database_name="main"),
            host,
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR", result)
        self.assertEqual(result["msg"], "Could not inspect database ownership.")
        self.assertNotIn("createdb", "\n".join(commands))


class TestBackfillNeverGuessesNestedNames(unittest.TestCase):
    """The backfill assigns by prefix only when no nested project can own the name (#127).

    ``dd_shop_api_main`` is shop's ``api_main`` or shop-api's ``main``. When
    the caller's slug list lacks "shop-api", a longest-prefix match picks
    "shop" and the registry row is permanent, so an underscore after the
    matched prefix leaves the name unassigned and reported instead.
    """

    def test_classify_leaves_a_nested_remainder_unassigned(self):
        """Without shop-api in the list, dd_shop_api_main is not given to shop."""
        from orchestrator.postgres_runtime_parts import project_registry

        report = project_registry._postgres_backfill_classify(["dd_shop_api_main"], [], ["shop"])
        self.assertEqual(report["assigned"], {})
        self.assertEqual(report["unassigned"], ["dd_shop_api_main"])

    def test_classify_still_assigns_a_plain_remainder(self):
        """dd_shop_main can only be shop's, so it is still assigned."""
        from orchestrator.postgres_runtime_parts import project_registry

        report = project_registry._postgres_backfill_classify(["dd_shop_main"], [], ["shop"])
        self.assertEqual(report["assigned"], {"dd_shop_main": "shop"})
        self.assertEqual(report["unassigned"], [])

    def test_classify_assigns_the_nested_project_when_it_is_known(self):
        """With shop-api in the list, the longest prefix leaves a plain remainder."""
        from orchestrator.postgres_runtime_parts import project_registry

        report = project_registry._postgres_backfill_classify(
            ["dd_shop_api_main"],
            [],
            ["shop", "shop-api"],
        )
        self.assertEqual(report["assigned"], {"dd_shop_api_main": "shop-api"})

    def test_delete_dry_run_does_not_register_a_nested_legacy_database(self):
        """A dry run with an incomplete slug list writes nothing for the nested name."""
        host = _RoutingHost(
            rules=[
                (
                    "SELECT datname FROM pg_database WHERE left(datname, 3)",
                    (True, ["dd_shop_api_main"]),
                ),
            ],
        )
        result, commands = _run_operation_with_host(
            "project_delete",
            _shop_settings(known_project_slugs=["shop"]),
            host,
            dry_run=True,
        )
        self.assertEqual(result["status"], "success", result)
        self.assertNotIn("INSERT INTO deploydash.managed_databases", "\n".join(commands))


class TestRestoreRegistersItsDatabase(unittest.TestCase):
    """A restore registers the database it creates to the calling project (#127).

    Without the row, ``project_list`` shows the restored copy only as
    unassigned and a project delete leaves it, and its data, on the server.
    """

    def _restore(self, rules=()):
        """Run a filesystem restore for shop into a new database named restored."""
        host = _RoutingHost(
            rules=[
                ("-d dd_shop_restored -tA -c 'SELECT 1;'", (True, ["1"])),
                *rules,
            ],
        )
        return _run_operation_with_host(
            "restore_run_now",
            _shop_settings(
                backup_target_database_name="restored",
                backup_artifact_path="sample.dump",
                **_FILESYSTEM_BACKUP,
            ),
            host,
        )

    def test_restore_registers_the_new_database(self):
        """The restored database is registered to shop after pg_restore succeeds."""
        result, commands = self._restore()
        self.assertEqual(result["status"], "success", result)
        inserts = [c for c in commands if "INSERT INTO deploydash.managed_databases" in c]
        self.assertEqual(len(inserts), 1)
        self.assertIn(_shell_quoted_blob("dd_shop_restored"), inserts[0])
        self.assertIn(_shell_quoted_blob("shop"), inserts[0])
        restore_at = next(i for i, c in enumerate(commands) if "pg_restore" in c)
        self.assertLess(restore_at, commands.index(inserts[0]))

    def test_restore_revokes_public_database_access_before_loading_data(self):
        """Keep a restored managed database isolated from every cluster login."""
        result, commands = self._restore()

        self.assertEqual(result["status"], "success", result)
        restore_command = next(command for command in commands if "pg_restore" in command)
        revoke = 'REVOKE CONNECT, TEMP ON DATABASE "dd_shop_restored" FROM PUBLIC;'
        self.assertIn(revoke, restore_command)
        self.assertLess(restore_command.index(revoke), restore_command.index("pg_restore"))

    def test_restore_reports_a_failed_registration(self):
        """A restore whose registration fails is an error, not a silent orphan."""
        result, _commands = self._restore(
            rules=[("INSERT INTO deploydash.managed_databases", (False, []))],
        )
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR", result)
        self.assertEqual(
            result["msg"],
            "Could not register restored PostgreSQL database.",
        )
