"""Live PostgreSQL proof for project isolation through the ownership registry (#127).

Drives the real engine flows (``run_postgres_project_operation``) against a
throwaway PostgreSQL container. The only substitution is the server's
env-file and readiness prefix, swapped for local variables that point at the
container, so every psql, createdb and dropdb command the engine builds runs
for real. Commands that do not carry that prefix are recorded, not executed.

Skipped unless ``DEPLOYDASH_LIVE_POSTGRES_CONTAINER`` names a running
container whose superuser is ``deploydash``. Run it through
``scripts/postgres_registry_live_check.sh``, which starts and removes one.
"""

import os
import subprocess
import unittest

from orchestrator import engine_postgres_ops
from orchestrator.postgres_parts import parse_postgres_service_config
from orchestrator.postgres_runtime_parts.service_configuration import _postgres_base_env_prefix
from tests.engine_context_fixtures import build_test_context

_CONTAINER = os.environ.get("DEPLOYDASH_LIVE_POSTGRES_CONTAINER", "")
_SUPERUSER = "deploydash"
_PASSWORD = os.environ.get("DEPLOYDASH_LIVE_POSTGRES_PASSWORD", "secret")
_STATUS_JSON = '{"running":true,"health":"healthy","version":"18","configured":true}'


class _LiveOutput:
    """Shell-output double carrying the real stdout and stderr lines."""

    def __init__(self, stdout="", stderr=""):
        self.stdout_lines = stdout.splitlines()
        self.stderr_lines = stderr.splitlines()


class _LiveHost:
    """Runs the engine's PostgreSQL commands inside the throwaway container.

    Exists so the test exercises the exact shell and SQL the engine sends,
    not a fake that could agree with a wrong implementation.
    """

    def __init__(self, settings):
        config = parse_postgres_service_config({"settings": settings})
        self._prefix = _postgres_base_env_prefix(config)
        self._local_prefix = (
            f"set -eu; POSTGRES_USER={_SUPERUSER}; POSTGRES_PASSWORD={_PASSWORD}; "
            f"CONTAINER_NAME={_CONTAINER}; "
        )
        self.skipped = []

    def run_shell_command(self, command, *_args, **_kwargs):
        """Answer the status probe; run prefixed commands; record the rest."""
        if "CONFIGURED='false'" in command and "SHOW server_version" in command:
            return True, _LiveOutput(_STATUS_JSON)
        if self._prefix not in command:
            self.skipped.append(command)
            return True, _LiveOutput()
        local_command = command.replace(self._prefix, self._local_prefix)
        completed = subprocess.run(
            ["bash", "-c", local_command],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        return completed.returncode == 0, _LiveOutput(completed.stdout, completed.stderr)


class _LiveSession:
    """Session double around the live host; it never fails to close."""

    def __init__(self, host):
        self.host = host

    def close(self):
        """Report a clean disconnect, as a healthy SSH session would."""
        return {"disconnect_error": None}


def _error_result(code, msg, stage=None, details=None, extra=None):
    """Structured error shaped like the engine context's own."""
    return {"status": "error", "code": code, "msg": msg, "stage": stage, "details": details}


def _run(operation_id, dry_run=False, **settings):
    """Run one project operation against the container; return its result."""
    merged = {"postgres_version": "17", "superuser_password": _PASSWORD, **settings}
    host = _LiveHost(merged)
    ctx = build_test_context(
        error_result=_error_result,
        emit_event=lambda *_args, **_kwargs: None,
        emit_shell_output_lines=lambda *_args, **_kwargs: None,
        command_error_details=lambda output: " | ".join(output.stderr_lines)[:300],
        open_runtime_session=lambda **_kwargs: {"ok": True, "session": _LiveSession(host)},
    )
    return engine_postgres_ops.run_postgres_project_operation(
        ctx,
        operation_id,
        ip="198.51.100.8",
        username="ubuntu",
        password="unused",
        dry_run=dry_run,
        raw_data={"settings": merged},
    )


def _psql(sql, database="postgres", user=_SUPERUSER, password=None, over_tcp=False):
    """Query the container directly, outside the engine; return (ok, stdout)."""
    command = ["docker", "exec"]
    if password is not None:
        command += ["-e", f"PGPASSWORD={password}"]
    command += [_CONTAINER, "psql", "-v", "ON_ERROR_STOP=1"]
    if over_tcp:
        # The container's own address, so pg_hba applies password auth;
        # loopback is trust in the official image.
        address = subprocess.run(
            ["docker", "exec", _CONTAINER, "hostname", "-i"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.split()[0]
        command += ["-h", address]
    command += ["-U", user, "-d", database, "-tAc", sql]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    return completed.returncode == 0, completed.stdout.strip()


def _names(sql):
    """Return the set of names a one-column catalog query lists."""
    _ok, output = _psql(sql)
    return {line for line in output.splitlines() if line}


def _databases():
    """Managed databases that exist in the cluster."""
    return _names("SELECT datname FROM pg_database WHERE datname LIKE 'dd\\_%'")


def _registered_databases():
    """Registry rows as datname->project strings."""
    return _names(
        "SELECT datname || '->' || project_slug FROM deploydash.managed_databases",
    )


def _reset_cluster():
    """Drop every managed database, managed role and the registry."""
    for database in _databases():
        _psql(f'DROP DATABASE IF EXISTS "{database}" WITH (FORCE)')
    roles = _names(
        "SELECT rolname FROM pg_roles WHERE rolname LIKE 'dd\\_%' "
        "OR rolname LIKE 'deploydash\\_owner\\_%' "
        "OR rolname LIKE 'deploydash\\_agent\\_reader\\_%'",
    )
    for role in roles:
        _psql(f'DROP ROLE IF EXISTS "{role}"')
    _psql("DROP SCHEMA IF EXISTS deploydash CASCADE")


def _seed(slug, database_name):
    """Create a project database through the engine and a row as its app user."""
    result = _run("project_create_database", project_slug=slug, database_name=database_name)
    if result.get("status") != "success":
        raise AssertionError(result)
    ok, output = _psql(
        f"CREATE TABLE t(secret text); INSERT INTO t VALUES ('{slug} data')",
        database=result["remote_database_name"],
        user=result["remote_username"],
        password=result["password"],
        over_tcp=True,
    )
    if not ok:
        raise AssertionError(output)
    return result


@unittest.skipUnless(_CONTAINER, "set DEPLOYDASH_LIVE_POSTGRES_CONTAINER to run live checks")
class TestLiveProjectIsolation(unittest.TestCase):
    """Project boundaries hold on a real PostgreSQL server (#80, #127)."""

    def setUp(self):
        """Start every scenario from an empty cluster."""
        _reset_cluster()

    def test_deleting_one_project_keeps_nested_neighbours(self):
        """Deleting shop leaves shops and shop-api, and their rows, intact."""
        for slug in ("shop", "shops", "shop-api"):
            _seed(slug, "main")
        plan = _run("project_delete", dry_run=True, project_slug="shop")
        self.assertEqual(plan["databases"], ["dd_shop_main"])
        result = _run(
            "project_delete",
            project_slug="shop",
            confirmed_databases=plan["databases"],
            confirmed_users=plan["users"],
        )
        self.assertEqual(result["status"], "success", result)
        self.assertEqual(_databases(), {"dd_shops_main", "dd_shop_api_main"})
        self.assertEqual(_psql("SELECT secret FROM t", database="dd_shops_main")[1], "shops data")
        self.assertEqual(
            _psql("SELECT secret FROM t", database="dd_shop_api_main")[1],
            "shop-api data",
        )

    def test_a_project_cannot_reach_another_projects_resources(self):
        """shop cannot delete, take over, or read shop-api's main as api_main."""
        _seed("shop", "main")
        shop_api = _seed("shop-api", "main")
        for operation_id, settings in (
            ("project_delete_database", {"database_name": "api_main"}),
            ("project_rotate_password", {"username": "api_main_user"}),
            ("project_delete_user", {"username": "api_main_user"}),
            ("project_list_tables", {"database_name": "api_main"}),
        ):
            with self.subTest(operation_id=operation_id):
                result = _run(operation_id, project_slug="shop", **settings)
                self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR", result)
                self.assertIn("shop-api", result["msg"])
        self.assertIn("dd_shop_api_main", _databases())
        ok, rows = _psql(
            "SELECT secret FROM t",
            database="dd_shop_api_main",
            user=shop_api["remote_username"],
            password=shop_api["password"],
            over_tcp=True,
        )
        self.assertTrue(ok, rows)
        self.assertEqual(rows, "shop-api data")

    def test_create_never_adopts_an_unregistered_database(self):
        """A legacy database nobody registered is refused, not taken over."""
        _psql('CREATE DATABASE "dd_shop_api_main"')
        _seed("shop", "main")
        for operation_id, settings in (
            ("project_create_user", {"database_name": "api_main", "username": "intruder"}),
            ("project_create_database", {"database_name": "api_main"}),
        ):
            with self.subTest(operation_id=operation_id):
                result = _run(operation_id, project_slug="shop", **settings)
                self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR", result)
        self.assertNotIn("dd_shop_api_main->shop", _registered_databases())
        self.assertEqual(
            _names("SELECT rolname FROM pg_roles WHERE rolname = 'dd_shop_intruder'"), set()
        )

    def test_a_dry_run_never_guesses_a_nested_legacy_database(self):
        """With only shop known, dd_shop_api_main stays unassigned."""
        _psql('CREATE DATABASE "dd_shop_main"')
        _psql('CREATE DATABASE "dd_shop_api_main"')
        plan = _run(
            "project_delete",
            dry_run=True,
            project_slug="shop",
            known_project_slugs=["shop"],
        )
        self.assertEqual(plan["databases"], ["dd_shop_main"])
        self.assertEqual(_registered_databases(), {"dd_shop_main->shop"})


if __name__ == "__main__":
    unittest.main()
