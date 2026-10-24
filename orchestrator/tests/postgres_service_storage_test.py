"""Named-volume storage layout and migration for PostgreSQL (#85).

The 16/17 images nest the real data in an anonymous volume under the old
parent mount; these tests pin the inspection, safety and migration builders
that move every major onto the unified layout, plus the migration handler.
"""

from __future__ import annotations

import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from orchestrator import engine_postgres_ops
from orchestrator.plugins.postgres_plugin import build_plugin as build_postgres_plugin
from orchestrator.postgres_parts import OPERATIONS, parse_postgres_service_config
from orchestrator.postgres_runtime_parts import project_registry, service_storage
from tests.engine_context_fixtures import build_test_context
from tests.postgres_helpers_support import _error_result


def _config(**settings):
    """Why: builds the minimal service config each builder needs."""
    base = {
        "postgres_version": "17",
        "superuser_password": "secret",
    }
    base.update(settings)
    return parse_postgres_service_config({"settings": base})


class _FakeOutput:
    """Why: carries canned remote command output without a server."""

    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


_ANON_NAME = "a" * 64
_OLD_LAYOUT_MOUNTS = [
    {
        "Type": "volume",
        "Name": "postgres_postgres_data",
        "Source": "postgres_postgres_data",
        "Destination": "/var/lib/postgresql",
        "Driver": "local",
        "Mode": "z",
        "RW": True,
        "Propagation": "",
    },
    {
        "Type": "volume",
        "Name": _ANON_NAME,
        "Source": "/var/lib/docker/volumes/" + _ANON_NAME + "/_data",
        "Destination": "/var/lib/postgresql/data",
        "Driver": "local",
        "Mode": "z",
        "RW": True,
        "Propagation": "",
    },
]
_NEW_LAYOUT_MOUNTS = [
    {
        "Type": "volume",
        "Name": "postgres_postgres_data",
        "Source": "postgres_postgres_data",
        "Destination": "/var/lib/postgresql/data",
        "Driver": "local",
        "Mode": "z",
        "RW": True,
        "Propagation": "",
    },
]


class TestServiceStorageInspection(unittest.TestCase):
    def test_inspect_mounts_command_reads_container_mounts_as_json(self):
        command = engine_postgres_ops._postgres_storage_inspect_mounts_command(_config())
        self.assertIn("set -eu;", command)
        self.assertIn("docker inspect -f '{{json .Mounts}}'", command)
        self.assertIn("deploydash_postgres", command)

    def test_parse_storage_mounts_reads_docker_inspect_json(self):
        output = _FakeOutput(stdout_lines=[json.dumps(_OLD_LAYOUT_MOUNTS)])
        mounts = engine_postgres_ops._postgres_parse_storage_mounts(output)
        self.assertEqual(len(mounts), 2)
        self.assertEqual(mounts[0]["Name"], "postgres_postgres_data")
        self.assertEqual(mounts[0]["Destination"], "/var/lib/postgresql")
        self.assertEqual(mounts[1]["Name"], _ANON_NAME)
        self.assertEqual(mounts[1]["Destination"], "/var/lib/postgresql/data")

    def test_parse_storage_mounts_rejects_non_json(self):
        output = _FakeOutput(stdout_lines=["not json{{{"])
        with self.assertRaisesRegex(ValueError, "not valid JSON"):
            engine_postgres_ops._postgres_parse_storage_mounts(output)

    def test_parse_storage_mounts_rejects_empty_output(self):
        with self.assertRaisesRegex(ValueError, "empty"):
            engine_postgres_ops._postgres_parse_storage_mounts(_FakeOutput())

    def test_parse_storage_mounts_rejects_non_list_payload(self):
        output = _FakeOutput(stdout_lines=['{"Mounts": []}'])
        with self.assertRaisesRegex(ValueError, "must be a JSON array"):
            engine_postgres_ops._postgres_parse_storage_mounts(output)

    def test_parse_storage_mounts_accepts_an_empty_list(self):
        output = _FakeOutput(stdout_lines=["[]"])
        self.assertEqual(
            engine_postgres_ops._postgres_parse_storage_mounts(output),
            [],
        )

    def test_parse_storage_mounts_rejects_non_object_entries(self):
        # Fail closed: silently skipping a malformed entry could identify
        # the wrong volume as the PGDATA source and copy the wrong bytes.
        output = _FakeOutput(stdout_lines=[json.dumps([{"Name": "x"}, 42])])
        with self.assertRaisesRegex(ValueError, "must be objects"):
            engine_postgres_ops._postgres_parse_storage_mounts(output)

    def test_find_pgdata_source_volume_prefers_the_deepest_mount(self):
        # Old layout: PGDATA sits under the anonymous nested mount, not the
        # named parent mount.
        mount = engine_postgres_ops._postgres_find_pgdata_source_volume(
            _OLD_LAYOUT_MOUNTS,
            "/var/lib/postgresql/data",
        )
        self.assertEqual(mount["Name"], _ANON_NAME)

    def test_find_pgdata_source_volume_matches_new_layout(self):
        mount = engine_postgres_ops._postgres_find_pgdata_source_volume(
            _NEW_LAYOUT_MOUNTS,
            "/var/lib/postgresql/data/pgdata",
        )
        self.assertEqual(mount["Name"], "postgres_postgres_data")

    def test_find_pgdata_source_volume_requires_a_path_boundary(self):
        # /var/lib/postgresql/data2 must not match a PGDATA of
        # /var/lib/postgresql/data: a string prefix is not a directory.
        mounts = [
            {
                "Name": "other",
                "Destination": "/var/lib/postgresql/data2",
            },
        ]
        self.assertIsNone(
            engine_postgres_ops._postgres_find_pgdata_source_volume(
                mounts,
                "/var/lib/postgresql/data",
            )
        )

    def test_find_pgdata_source_volume_returns_none_without_a_match(self):
        self.assertIsNone(
            engine_postgres_ops._postgres_find_pgdata_source_volume(
                _NEW_LAYOUT_MOUNTS,
                "/var/lib/elsewhere",
            )
        )

    def test_storage_volume_is_anonymous_matches_docker_generated_ids(self):
        self.assertTrue(engine_postgres_ops._postgres_storage_volume_is_anonymous(_ANON_NAME))
        self.assertTrue(engine_postgres_ops._postgres_storage_volume_is_anonymous("f" * 64))

    def test_storage_volume_is_anonymous_rejects_named_volumes(self):
        self.assertFalse(
            engine_postgres_ops._postgres_storage_volume_is_anonymous("postgres_postgres_data")
        )
        self.assertFalse(engine_postgres_ops._postgres_storage_volume_is_anonymous(""))
        self.assertFalse(engine_postgres_ops._postgres_storage_volume_is_anonymous("a" * 63))
        self.assertFalse(engine_postgres_ops._postgres_storage_volume_is_anonymous("g" * 64))

    def test_disk_space_command_reports_data_and_avail_bytes(self):
        command = engine_postgres_ops._postgres_storage_disk_space_command(
            _config(),
            _ANON_NAME,
        )
        self.assertIn("set -eu;", command)
        self.assertIn(_ANON_NAME, command)
        self.assertIn("docker volume inspect -f '{{.Mountpoint}}'", command)
        self.assertIn("du -sb", command)
        self.assertIn("df -B1 --output=avail", command)
        self.assertIn("data_bytes=", command)
        self.assertIn("avail_bytes=", command)

    def test_safety_dump_command_dumps_all_databases_with_restricted_mode(self):
        command = engine_postgres_ops._postgres_storage_safety_dump_command(
            _config(),
            "/opt/deploydash/stack/postgres/storage-migration-safety.sql",
        )
        self.assertIn("set -eu;", command)
        self.assertIn("umask 077", command)
        self.assertIn("pg_dumpall", command)
        self.assertIn('-U "${POSTGRES_USER}"', command)
        self.assertIn('"${CONTAINER_NAME}"', command)
        self.assertIn("storage-migration-safety.sql", command)

    def test_stop_command_stops_without_detaching_volumes(self):
        # `stop` keeps containers and volumes; `down` would detach the very
        # anonymous volume the migration is about to rescue. The generous
        # grace period lets PostgreSQL checkpoint cleanly instead of being
        # killed mid-write and recovering on the next start.
        command = engine_postgres_ops._postgres_storage_stop_command(_config())
        self.assertIn("docker compose", command)
        self.assertIn("stop -t 120", command)
        self.assertNotIn("down", command)
        self.assertIn("docker-compose", command)


class TestServiceStorageCopy(unittest.TestCase):
    def test_copy_command_moves_pgdata_through_a_helper_container(self):
        command = engine_postgres_ops._postgres_storage_copy_command(
            _config(),
            _ANON_NAME,
            "postgres_postgres_data",
        )
        self.assertIn("set -eu;", command)
        self.assertIn("docker run --rm", command)
        self.assertIn(f"-v {_ANON_NAME}:/from:ro", command)
        self.assertIn("-v postgres_postgres_data:/to", command)
        self.assertIn("deploydash/postgres-ext:17.10-bookworm-base", command)
        # A re-run after a partial copy wipes the target first; the
        # read-only source is untouched, so resume is a fresh full copy.
        self.assertIn("rm -rf /to/pgdata", command)
        self.assertIn("cp -a /from/. /to/pgdata/", command)
        self.assertIn("chown -R postgres:postgres /to/pgdata", command)
        self.assertIn("chmod 0700 /to/pgdata", command)

    def test_copy_command_copies_from_a_subpath_for_versioned_layouts(self):
        # Old-layout 18 keeps PGDATA at 18/docker inside the named volume.
        command = engine_postgres_ops._postgres_storage_copy_command(
            _config(postgres_version="18"),
            "postgres_postgres_data",
            "postgres_postgres_data",
            "18/docker",
        )
        self.assertIn("cp -a /from/18/docker/. /to/pgdata/", command)

    def test_copy_command_rejects_unsafe_subpaths(self):
        for subpath in ("../escape", "/absolute", "a;b", "a`b`", "", "ok"):
            with self.subTest(subpath=subpath):
                if subpath in ("", "ok"):
                    continue
                with self.assertRaisesRegex(ValueError, "unsafe"):
                    engine_postgres_ops._postgres_storage_copy_command(
                        _config(),
                        _ANON_NAME,
                        "postgres_postgres_data",
                        subpath,
                    )

    def test_backup_compose_command_keeps_the_first_backup(self):
        # First backup wins across re-runs: after a failed migration the
        # current compose may already be the new one, and overwriting the
        # backup would lose the original rollback target.
        command = engine_postgres_ops._postgres_storage_backup_compose_command(
            _config(),
            "/opt/deploydash/stack/postgres/docker-compose.yml.pre-storage-migration",
        )
        self.assertIn("cp -n", command)
        self.assertIn("docker-compose.yml", command)
        self.assertIn(".pre-storage-migration", command)

    def test_restore_compose_command_restores_the_backup(self):
        command = engine_postgres_ops._postgres_storage_restore_compose_command(
            _config(),
            "/opt/deploydash/stack/postgres/docker-compose.yml.pre-storage-migration",
        )
        self.assertIn('cp "${BACKUP_FILE}" "${COMPOSE_FILE}"', command)

    def test_cleanup_compose_backup_command_removes_the_backup(self):
        command = engine_postgres_ops._postgres_storage_cleanup_compose_backup_command(
            _config(),
            "/opt/deploydash/stack/postgres/docker-compose.yml.pre-storage-migration",
        )
        self.assertIn("rm -f", command)
        self.assertIn(".pre-storage-migration", command)

    def test_inventory_queries_list_databases_and_roles_in_order(self):
        queries = engine_postgres_ops._postgres_storage_inventory_queries()
        self.assertEqual(
            queries["databases"],
            "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname;",
        )
        # #86: predefined pg_* roles are version-dependent (17 adds
        # pg_maintain), so only user roles compare across a move.
        self.assertEqual(
            queries["roles"],
            "SELECT rolname FROM pg_roles WHERE rolname NOT LIKE 'pg\\_%' ORDER BY rolname;",
        )

    def test_remove_volume_command_refuses_volumes_still_in_use(self):
        command = engine_postgres_ops._postgres_storage_remove_volume_command(
            _config(),
            _ANON_NAME,
        )
        self.assertIn("set -eu;", command)
        self.assertIn(_ANON_NAME, command)
        self.assertIn('docker ps -q --filter "volume=', command)
        self.assertIn("docker volume rm", command)

    def test_remove_legacy_subdir_command_clears_a_versioned_leftover(self):
        command = engine_postgres_ops._postgres_storage_remove_legacy_subdir_command(
            _config(),
            "postgres_postgres_data",
            "18/docker",
        )
        self.assertIn("docker run --rm", command)
        self.assertIn("-v postgres_postgres_data:/data", command)
        self.assertIn("rm -rf /data/18/docker", command)

    def test_remove_legacy_subdir_command_rejects_unsafe_subpaths(self):
        with self.assertRaisesRegex(ValueError, "unsafe"):
            engine_postgres_ops._postgres_storage_remove_legacy_subdir_command(
                _config(),
                "postgres_postgres_data",
                "../escape",
            )

    def test_remove_legacy_subdir_command_rejects_an_empty_subpath(self):
        # Empty would resolve to the volume root: refusing keeps the
        # whole-volume removal on the dedicated guarded command.
        with self.assertRaisesRegex(ValueError, "unsafe"):
            engine_postgres_ops._postgres_storage_remove_legacy_subdir_command(
                _config(),
                "postgres_postgres_data",
                "",
            )


class _ScriptedHost:
    """Why: answers shell commands from ordered needle scripts per case."""

    def __init__(self, scripts):
        self._scripts = [
            {"needle": needle, "ok": ok, "result": result, "used": False}
            for needle, ok, result in scripts
        ]
        self.commands = []

    def run_shell_command(self, command, **kwargs):
        """Why: consumes the first unused script matching the command."""
        self.commands.append(command)
        for script in self._scripts:
            if not script["used"] and script["needle"] in command:
                script["used"] = True
                result = script["result"]
                if isinstance(result, Exception):
                    raise result
                return script["ok"], result
        return True, _FakeOutput()


class _FakeSession:
    """Why: hands the handler a scripted host without SSH."""

    def __init__(self, host):
        self.host = host

    def close(self):
        """Why: the handler never closes the session it was given."""
        return {"disconnect_error": None}


class _ScriptedPsql:
    """Why: answers psql calls from ordered needle scripts per case."""

    def __init__(self, scripts):
        self._scripts = [
            {"needle": needle, "ok": ok, "result": result, "used": False}
            for needle, ok, result in scripts
        ]
        self.calls = []

    def __call__(self, _ctx, _session, _config, sql, database="postgres", **kwargs):
        """Why: consumes the first unused script matching the SQL."""
        self.calls.append(sql)
        for script in self._scripts:
            if not script["used"] and script["needle"] in sql:
                script["used"] = True
                result = script["result"]
                if isinstance(result, Exception):
                    raise result
                return script["ok"], result
        return True, _FakeOutput()


def _storage_ctx(events=None, command_error_details=None):
    """Why: builds the handler context with recorded events per case."""
    collected = events if events is not None else []
    kwargs = {
        "error_result": _error_result,
        "emit_event": lambda *args, **kwargs: collected.append((args, kwargs)),
        "emit_shell_output_lines": lambda *_args, **_kwargs: None,
    }
    if command_error_details is not None:
        kwargs["command_error_details"] = command_error_details
    return build_test_context(**kwargs)


def _cancel_on_call(fire_at):
    """Why: cancels on the Nth check so each cancel window is targeted."""
    calls = []

    def check():
        calls.append(1)
        return len(calls) >= fire_at

    return check


_NEW_PGDATA = "/var/lib/postgresql/data/pgdata"
_OLD_DATADIR = "/var/lib/postgresql/data"


def _old_mounts_output():
    """Why: canned pre-migration inspect output with the nested volume."""
    return _FakeOutput(stdout_lines=[json.dumps(_OLD_LAYOUT_MOUNTS)])


def _new_mounts_output():
    """Why: canned post-migration inspect output on the named volume."""
    return _FakeOutput(stdout_lines=[json.dumps(_NEW_LAYOUT_MOUNTS)])


class TestServiceStorageDetection(unittest.TestCase):
    def test_registry_list_databases_sql_selects_every_managed_database(self):
        # Tested beside its storage consumer: the migration guard and the
        # status detector both compare this expectation against pg_database.
        self.assertEqual(
            project_registry._postgres_registry_list_databases_sql(),
            "SELECT datname FROM deploydash.managed_databases ORDER BY datname;",
        )

    def test_missing_expected_databases_is_empty_when_all_are_live(self):
        self.assertEqual(
            engine_postgres_ops._postgres_storage_missing_expected_databases(
                ["dd_test_app", "dd_test_jobs"],
                ["postgres", "dd_test_jobs", "dd_test_app"],
            ),
            [],
        )

    def test_missing_expected_databases_reports_the_absent_sorted(self):
        self.assertEqual(
            engine_postgres_ops._postgres_storage_missing_expected_databases(
                ["dd_test_jobs", "dd_test_app", "dd_test_live"],
                ["postgres", "dd_test_live"],
            ),
            ["dd_test_app", "dd_test_jobs"],
        )

    def test_missing_expected_databases_is_empty_without_expectations(self):
        # Never cry wolf: a fresh service expects nothing, so nothing can
        # be missing.
        self.assertEqual(
            engine_postgres_ops._postgres_storage_missing_expected_databases(
                [],
                ["postgres"],
            ),
            [],
        )

    def test_missing_expected_databases_reports_all_when_none_are_live(self):
        self.assertEqual(
            engine_postgres_ops._postgres_storage_missing_expected_databases(
                ["dd_test_app"],
                [],
            ),
            ["dd_test_app"],
        )

    def test_clean_name_lines_strips_and_drops_blanks(self):
        output = _FakeOutput(stdout_lines=["  dd_test_app  ", "", "   ", "dd_test_jobs"])
        self.assertEqual(
            engine_postgres_ops._postgres_storage_clean_name_lines(output),
            ["dd_test_app", "dd_test_jobs"],
        )

    def test_clean_name_lines_tolerates_missing_output(self):
        self.assertEqual(
            engine_postgres_ops._postgres_storage_clean_name_lines(_FakeOutput()),
            [],
        )
        self.assertEqual(
            engine_postgres_ops._postgres_storage_clean_name_lines(None),
            [],
        )

    def test_first_output_line_returns_the_first_non_blank_line(self):
        output = _FakeOutput(stdout_lines=["", "  /var/lib/postgresql/data  ", "x"])
        self.assertEqual(
            engine_postgres_ops._postgres_storage_first_output_line(output),
            "/var/lib/postgresql/data",
        )

    def test_first_output_line_returns_none_without_content(self):
        self.assertIsNone(engine_postgres_ops._postgres_storage_first_output_line(_FakeOutput()))
        self.assertIsNone(
            engine_postgres_ops._postgres_storage_first_output_line(
                _FakeOutput(stdout_lines=["", "   "])
            )
        )


class TestServiceStorageStepHelpers(unittest.TestCase):
    def test_cancelled_returns_none_without_a_cancel_callback(self):
        self.assertIsNone(service_storage._storage_migration_cancelled(_storage_ctx(), None))

    def test_cancelled_returns_none_while_running(self):
        self.assertIsNone(
            service_storage._storage_migration_cancelled(_storage_ctx(), lambda: False)
        )

    def test_cancelled_returns_a_cancellation_error(self):
        error = service_storage._storage_migration_cancelled(_storage_ctx(), lambda: True)
        self.assertEqual(error["code"], "ENGINE_TASK_CANCELLED")

    def test_host_command_returns_output_on_success(self):
        host = _ScriptedHost([("true", True, _FakeOutput(stdout_lines=["ok"]))])
        ok, output, details = service_storage._run_storage_host_command(
            _storage_ctx(),
            _FakeSession(host),
            "true",
            emit=None,
            timeout=60,
            operation_id="service_migrate_storage",
        )
        self.assertTrue(ok)
        self.assertEqual(output.stdout_lines, ["ok"])
        self.assertEqual(details, "")

    def test_host_command_reports_remote_failure_details(self):
        # Details come from the shared helper's stderr join, not the
        # context hook: the stderr text must win over the hook's value.
        host = _ScriptedHost([("false", False, _FakeOutput(stderr_lines=["boom-remote"]))])
        ok, _output, details = service_storage._run_storage_host_command(
            _storage_ctx(command_error_details=lambda _output: "boom-ctx"),
            _FakeSession(host),
            "false",
            emit=None,
            timeout=60,
            operation_id="service_migrate_storage",
        )
        self.assertFalse(ok)
        self.assertEqual(details, "boom-remote")

    def test_host_command_falls_back_without_remote_details(self):
        host = _ScriptedHost([("false", False, _FakeOutput())])
        ok, _output, details = service_storage._run_storage_host_command(
            _storage_ctx(),
            _FakeSession(host),
            "false",
            emit=None,
            timeout=60,
            operation_id="service_migrate_storage",
        )
        self.assertFalse(ok)
        self.assertEqual(details, "remote command failed")

    def test_host_command_converts_exceptions_to_failures(self):
        host = _ScriptedHost([("bang", True, RuntimeError("ssh broke"))])
        ok, output, details = service_storage._run_storage_host_command(
            _storage_ctx(),
            _FakeSession(host),
            "bang",
            emit=None,
            timeout=60,
            operation_id="service_migrate_storage",
        )
        self.assertFalse(ok)
        self.assertIsNone(output)
        self.assertEqual(details, "ssh broke")

    def test_psql_query_returns_output_on_success(self):
        with patch.object(
            service_storage,
            "_run_postgres_psql_query_impl",
            return_value=(True, _FakeOutput(stdout_lines=["1"])),
        ):
            ok, output, details = service_storage._run_storage_psql_query(
                _storage_ctx(),
                _FakeSession(_ScriptedHost([])),
                _config(),
                "SELECT 1;",
                emit=None,
                operation_id="service_migrate_storage",
            )
        self.assertTrue(ok)
        self.assertEqual(output.stdout_lines, ["1"])
        self.assertEqual(details, "")

    def test_psql_query_reports_remote_failure_details(self):
        with patch.object(
            service_storage,
            "_run_postgres_psql_query_impl",
            return_value=(False, _FakeOutput(stderr_lines=["bad sql"])),
        ):
            ok, _output, details = service_storage._run_storage_psql_query(
                _storage_ctx(command_error_details=lambda _output: "bad sql"),
                _FakeSession(_ScriptedHost([])),
                _config(),
                "SELECT 1;",
                emit=None,
                operation_id="service_migrate_storage",
            )
        self.assertFalse(ok)
        self.assertEqual(details, "bad sql")

    def test_psql_query_falls_back_without_remote_details(self):
        with patch.object(
            service_storage,
            "_run_postgres_psql_query_impl",
            return_value=(False, _FakeOutput()),
        ):
            ok, _output, details = service_storage._run_storage_psql_query(
                _storage_ctx(),
                _FakeSession(_ScriptedHost([])),
                _config(),
                "SELECT 1;",
                emit=None,
                operation_id="service_migrate_storage",
            )
        self.assertFalse(ok)
        self.assertEqual(details, "remote command failed")

    def test_psql_query_converts_exceptions_to_failures(self):
        def _raise(*_args, **_kwargs):
            raise RuntimeError("ssh broke")

        with patch.object(service_storage, "_run_postgres_psql_query_impl", _raise):
            ok, output, details = service_storage._run_storage_psql_query(
                _storage_ctx(),
                _FakeSession(_ScriptedHost([])),
                _config(),
                "SELECT 1;",
                emit=None,
                operation_id="service_migrate_storage",
            )
        self.assertFalse(ok)
        self.assertIsNone(output)
        self.assertEqual(details, "ssh broke")


def _migration_psql(*, datadir_before=None, datadir_after=None, registry=None):
    """Why: scripts the eight psql answers of the migration flow."""
    return _ScriptedPsql(
        [
            (
                "SHOW data_directory",
                True,
                _FakeOutput(stdout_lines=[datadir_before or _OLD_DATADIR]),
            ),
            ("SHOW server_version", True, _FakeOutput(stdout_lines=["17.8"])),
            (
                "FROM pg_database WHERE NOT datistemplate",
                True,
                _FakeOutput(stdout_lines=["dd_test_app"]),
            ),
            (
                "FROM pg_roles",
                True,
                _FakeOutput(stdout_lines=["dd_test_app_user"]),
            ),
            (
                "FROM deploydash.managed_databases",
                True,
                _FakeOutput(stdout_lines=list(registry or ["dd_test_app"])),
            ),
            (
                "SHOW data_directory",
                True,
                _FakeOutput(stdout_lines=[datadir_after or _NEW_PGDATA]),
            ),
            (
                "FROM pg_database WHERE NOT datistemplate",
                True,
                _FakeOutput(stdout_lines=["dd_test_app"]),
            ),
            (
                "FROM pg_roles",
                True,
                _FakeOutput(stdout_lines=["dd_test_app_user"]),
            ),
        ]
    )


def _migration_host(*scripts):
    """Why: scripts shell answers with old-then-new mounts by default."""
    return _ScriptedHost(
        [
            ("json .Mounts", True, _old_mounts_output()),
            (
                "du -sb",
                True,
                _FakeOutput(stdout_lines=["data_bytes=1000", "avail_bytes=2000"]),
            ),
            ("pg_dumpall", True, _FakeOutput()),
            ("cp -n", True, _FakeOutput()),
            ("stop -t 120", True, _FakeOutput()),
            ("cp -a", True, _FakeOutput()),
            ('cat > "${COMPOSE_FILE}"', True, _FakeOutput()),
            ("up -d", True, _FakeOutput()),
            ("json .Mounts", True, _new_mounts_output()),
            ("rm -f", True, _FakeOutput()),
            *scripts,
        ]
    )


def _run_migration(host, psql, expected=(), **kwargs):
    """Why: runs the migrate handler with patched psql and readiness."""
    kwargs.setdefault("is_cancelled", None)
    with (
        patch.object(service_storage, "_run_postgres_psql_query_impl", psql),
        patch.object(service_storage, "_wait_for_postgres_readiness", return_value=None),
    ):
        return service_storage.run_postgres_storage_migration(
            _storage_ctx(command_error_details=lambda _output: "remote failed"),
            _FakeSession(host),
            _config(expected_databases=list(expected)),
            emit=None,
            operation_id="service_migrate_storage",
            **kwargs,
        )


class TestServiceStorageMigration(unittest.TestCase):
    def test_migrate_moves_data_and_verifies_everything(self):
        host = _migration_host()
        psql = _migration_psql()
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "service_migrate_storage")
        self.assertFalse(result["already_migrated"])
        self.assertEqual(result["data_directory"], _NEW_PGDATA)
        self.assertEqual(result["storage_volume"], "postgres_postgres_data")
        self.assertEqual(result["legacy_volume"], _ANON_NAME)
        self.assertEqual(result["legacy_subpath"], "")
        self.assertEqual(result["migrated_databases"], ["dd_test_app"])
        self.assertEqual(result["migrated_roles"], ["dd_test_app_user"])
        self.assertTrue(result["safety_dump_path"].endswith("storage-migration-safety.sql"))
        self.assertTrue(result["compose_backup_removed"])
        commands = "\n".join(host.commands)
        self.assertIn("pg_dumpall", commands)
        self.assertIn("cp -a", commands)
        self.assertIn("up -d", commands)
        self.assertNotIn('cp "${BACKUP_FILE}" "${COMPOSE_FILE}"', commands)
        sql = "\n".join(psql.calls)
        self.assertIn("SHOW data_directory", sql)
        self.assertIn("SHOW server_version", sql)
        self.assertIn("FROM deploydash.managed_databases", sql)

    def test_migrate_records_the_only_removable_legacy_copy(self):
        """Persist provenance so status never guesses from global Docker state."""
        host = _migration_host()
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "success")
        self.assertTrue(result["ledger_recorded"])
        ledger_command = next(
            command
            for command in host.commands
            if "retained_volumes" in command and "cat >" in command
        )
        self.assertIn(_ANON_NAME, ledger_command)
        self.assertIn('"kind":"storage_migration"', ledger_command)

    def test_migrate_warns_when_retained_copy_provenance_cannot_be_saved(self):
        """Keep a successful migration honest when its cleanup ledger fails."""
        cases = (
            (
                "read failure",
                (("postgres-major-upgrades.json", False, _FakeOutput(stderr_lines=["down"])),),
            ),
            (
                "unknown version",
                (
                    (
                        "postgres-major-upgrades.json",
                        True,
                        _FakeOutput(stdout_lines=['{"format_version":2}']),
                    ),
                ),
            ),
            (
                "write failure",
                (
                    ("postgres-major-upgrades.json", True, _FakeOutput()),
                    (
                        "__DEPLOYDASH_POSTGRES_UPGRADE_EOF__",
                        False,
                        _FakeOutput(stderr_lines=["read only"]),
                    ),
                ),
            ),
        )
        for label, scripts in cases:
            with self.subTest(label=label):
                host = _migration_host(*scripts)
                result = _run_migration(host, _migration_psql())

                self.assertEqual(result["status"], "success")
                self.assertFalse(result["ledger_recorded"])

    def test_migrate_replaces_a_duplicate_retained_copy_record(self):
        """Retrying bookkeeping keeps one provenance record per retained copy."""
        existing = json.dumps(
            {
                "format_version": 1,
                "retained_volumes": [
                    {
                        "volume": _ANON_NAME,
                        "kind": "storage_migration",
                        "subpath": "",
                    }
                ],
            }
        )
        host = _migration_host(
            ("postgres-major-upgrades.json", True, _FakeOutput(stdout_lines=[existing]))
        )

        result = _run_migration(host, _migration_psql())

        self.assertTrue(result["ledger_recorded"])
        ledger_command = next(
            command
            for command in host.commands
            if "retained_volumes" in command and "cat >" in command
        )
        self.assertEqual(ledger_command.count(_ANON_NAME), 1)

    def test_migrate_short_circuits_when_already_on_the_layout(self):
        host = _ScriptedHost([("json .Mounts", True, _new_mounts_output())])
        psql = _ScriptedPsql(
            [("SHOW data_directory", True, _FakeOutput(stdout_lines=[_NEW_PGDATA]))]
        )
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "success")
        self.assertTrue(result["already_migrated"])
        self.assertEqual(result["data_directory"], _NEW_PGDATA)
        self.assertEqual(result["storage_volume"], "postgres_postgres_data")
        self.assertIsNone(result["legacy_volume"])
        self.assertIsNone(result["legacy_subpath"])
        commands = "\n".join(host.commands)
        self.assertNotIn("pg_dumpall", commands)
        self.assertNotIn("cp -a", commands)
        self.assertNotIn("up -d", commands)

    def test_migrate_refuses_a_major_change(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[1] = {
            "needle": "SHOW server_version",
            "ok": True,
            "result": _FakeOutput(stdout_lines=["18.1"]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("17", result["msg"])
        self.assertIn("18", result["msg"])
        self.assertNotIn("stop -t 120", "\n".join(host.commands))

    def test_migrate_refuses_an_unreadable_server_version(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[1] = {
            "needle": "SHOW server_version",
            "ok": True,
            "result": _FakeOutput(stdout_lines=["not-a-version"]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("major version", result["msg"])

    def test_migrate_refuses_a_partially_detached_cluster(self):
        host = _migration_host()
        psql = _migration_psql(registry=["dd_test_app", "dd_test_gone"])
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("dd_test_gone", result["msg"])
        self.assertIn("may be detached", result["msg"])
        self.assertIn("dangling=true", result["msg"])
        self.assertNotIn("stop -t 120", "\n".join(host.commands))

    def test_migrate_refuses_a_fully_detached_cluster(self):
        host = _migration_host()
        psql = _ScriptedPsql(
            [
                ("SHOW data_directory", True, _FakeOutput(stdout_lines=[_OLD_DATADIR])),
                ("SHOW server_version", True, _FakeOutput(stdout_lines=["17.8"])),
                ("FROM pg_database WHERE NOT datistemplate", True, _FakeOutput()),
                ("FROM pg_roles", True, _FakeOutput()),
                (
                    "FROM deploydash.managed_databases",
                    True,
                    _FakeOutput(stdout_lines=["dd_test_app", "dd_test_jobs"]),
                ),
            ]
        )
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("none of the 2", result["msg"])

    def test_migrate_treats_a_missing_registry_as_no_expectations(self):
        # A fresh service never ran a project flow, so the registry schema
        # does not exist yet: that means nothing is expected, not failure.
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[4] = {
            "needle": "FROM deploydash.managed_databases",
            "ok": False,
            "result": _FakeOutput(
                stderr_lines=['relation "deploydash.managed_databases" does not exist']
            ),
            "used": False,
        }
        with (
            patch.object(service_storage, "_run_postgres_psql_query_impl", psql),
            patch.object(service_storage, "_wait_for_postgres_readiness", return_value=None),
        ):
            result = service_storage.run_postgres_storage_migration(
                _storage_ctx(command_error_details=lambda output: "\n".join(output.stderr_lines)),
                _FakeSession(host),
                _config(),
                emit=None,
                operation_id="service_migrate_storage",
                is_cancelled=None,
            )
        self.assertEqual(result["status"], "success")
        self.assertFalse(result["already_migrated"])

    def test_migrate_refuses_a_detached_cluster_via_desktop_expectations(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[2] = {
            "needle": "FROM pg_database WHERE NOT datistemplate",
            "ok": True,
            "result": _FakeOutput(),
            "used": False,
        }
        psql._scripts[4] = {
            "needle": "FROM deploydash.managed_databases",
            "ok": False,
            "result": _FakeOutput(
                stderr_lines=['relation "deploydash.managed_databases" does not exist']
            ),
            "used": False,
        }
        with (
            patch.object(service_storage, "_run_postgres_psql_query_impl", psql),
            patch.object(service_storage, "_wait_for_postgres_readiness", return_value=None),
        ):
            result = service_storage.run_postgres_storage_migration(
                _storage_ctx(command_error_details=lambda output: "\n".join(output.stderr_lines)),
                _FakeSession(host),
                _config(expected_databases=["dd_test_app", "dd_test_jobs"]),
                emit=None,
                operation_id="service_migrate_storage",
                is_cancelled=None,
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("none of the 2", result["msg"])

    def test_migrate_reports_registry_read_failures(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[4] = {
            "needle": "FROM deploydash.managed_databases",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["connection reset"]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("registry", result["msg"])

    def test_migrate_reports_inspect_failures(self):
        host = _ScriptedHost(
            [("json .Mounts", False, _FakeOutput(stderr_lines=["no such container"]))]
        )
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("inspect", result["msg"])

    def test_migrate_reports_unparsable_mounts(self):
        host = _ScriptedHost([("json .Mounts", True, _FakeOutput(stdout_lines=["not json"]))])
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("inspect", result["msg"])

    def test_migrate_reports_datadir_read_failures(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[0] = {
            "needle": "SHOW data_directory",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["down"]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("Start the Database service", result["msg"])

    def test_migrate_reports_empty_datadir_output(self):
        host = _migration_host()
        psql = _migration_psql(datadir_before=None)
        psql._scripts[0] = {
            "needle": "SHOW data_directory",
            "ok": True,
            "result": _FakeOutput(stdout_lines=["", "  "]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("data directory", result["msg"])

    def test_migrate_reports_inventory_read_failures(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[2] = {
            "needle": "FROM pg_database WHERE NOT datistemplate",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["down"]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("inventory", result["msg"])

    def test_migrate_reports_roles_read_failures(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[3] = {
            "needle": "FROM pg_roles",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["down"]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("inventory", result["msg"])

    def test_migrate_reports_a_version_read_failure(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[1] = {
            "needle": "SHOW server_version",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["down"]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("server version", result["msg"])

    def test_migrate_reports_a_missing_source_mount(self):
        host = _migration_host()
        psql = _migration_psql(datadir_before="/var/lib/elsewhere")
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("No mounted volume", result["msg"])

    def test_migrate_reports_an_unnamed_source_mount(self):
        mounts = [{"Type": "volume", "Destination": "/var/lib/postgresql/data"}]
        host = _migration_host()
        host._scripts[0] = {
            "needle": "json .Mounts",
            "ok": True,
            "result": _FakeOutput(stdout_lines=[json.dumps(mounts)]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("identify the volume", result["msg"])

    def test_migrate_reports_a_missing_named_volume(self):
        host = _migration_host()
        host._scripts[0] = {
            "needle": "json .Mounts",
            "ok": True,
            "result": _FakeOutput(stdout_lines=[json.dumps([_OLD_LAYOUT_MOUNTS[1]])]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("named data volume", result["msg"])

    def test_migrate_refuses_an_anonymous_parent_mount(self):
        mounts = [
            {
                "Type": "volume",
                "Name": "b" * 64,
                "Destination": "/var/lib/postgresql",
            },
            _OLD_LAYOUT_MOUNTS[1],
        ]
        host = _migration_host()
        host._scripts[0] = {
            "needle": "json .Mounts",
            "ok": True,
            "result": _FakeOutput(stdout_lines=[json.dumps(mounts)]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("Unexpected storage layout", result["msg"])

    def test_migrate_refuses_an_unsafe_copy_source(self):
        host = _migration_host()
        psql = _migration_psql(datadir_before="/var/lib/postgresql/data/x;evil")
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("unexpected layout", result["msg"])

    def test_migrate_reports_disk_check_failures(self):
        host = _migration_host()
        host._scripts[1] = {
            "needle": "du -sb",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["no docker"]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("free disk", result["msg"])

    def test_migrate_reports_unparsable_disk_output(self):
        host = _migration_host()
        host._scripts[1] = {
            "needle": "du -sb",
            "ok": True,
            "result": _FakeOutput(stdout_lines=["data_bytes=lots"]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("free disk", result["msg"])

    def test_migrate_refuses_without_room_for_the_safety_dump(self):
        host = _migration_host()
        host._scripts[1] = {
            "needle": "du -sb",
            "ok": True,
            "result": _FakeOutput(stdout_lines=["data_bytes=2000", "avail_bytes=1000"]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("2000", result["msg"])
        self.assertIn("1000", result["msg"])

    def test_migrate_reports_safety_dump_failures_without_changes(self):
        host = _migration_host()
        host._scripts[2] = {
            "needle": "pg_dumpall",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["dump failed"]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("safety dump", result["msg"])
        self.assertIn("untouched", result["msg"])
        self.assertNotIn("stop -t 120", "\n".join(host.commands))

    def test_migrate_reports_compose_backup_failures(self):
        host = _migration_host()
        host._scripts[3] = {
            "needle": "cp -n",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["read-only fs"]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("back up the compose", result["msg"])

    def test_migrate_reports_stop_failures(self):
        host = _migration_host()
        host._scripts[4] = {
            "needle": "stop -t 120",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["stuck"]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("stop the PostgreSQL container", result["msg"])
        self.assertNotIn("cp -a", "\n".join(host.commands))

    def test_migrate_rolls_back_after_a_copy_failure(self):
        host = _migration_host()
        host._scripts[5] = {
            "needle": "cp -a",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["disk full"]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("data copy failed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])
        commands = "\n".join(host.commands)
        self.assertIn('cp "${BACKUP_FILE}" "${COMPOSE_FILE}"', commands)
        self.assertIn("up -d", commands)

    def test_migrate_rolls_back_after_a_rewrite_failure(self):
        host = _migration_host()
        host._scripts[6] = {
            "needle": 'cat > "${COMPOSE_FILE}"',
            "ok": False,
            "result": _FakeOutput(stderr_lines=["disk full"]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("migrated compose file", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_migrate_rolls_back_after_a_start_failure(self):
        host = _migration_host()
        host._scripts[7] = {
            "needle": "up -d",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["bad image"]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("start PostgreSQL", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_migrate_rolls_back_when_readiness_fails(self):
        host = _migration_host()
        with (
            patch.object(service_storage, "_run_postgres_psql_query_impl", _migration_psql()),
            patch.object(
                service_storage,
                "_wait_for_postgres_readiness",
                side_effect=[
                    _error_result(
                        "ENGINE_RUNTIME_ERROR",
                        "Verify PostgreSQL readiness failed.",
                        stage="execute_runtime_operation",
                        details="still starting",
                    ),
                    None,
                ],
            ),
        ):
            result = service_storage.run_postgres_storage_migration(
                _storage_ctx(command_error_details=lambda _output: "remote failed"),
                _FakeSession(host),
                _config(),
                emit=None,
                operation_id="service_migrate_storage",
                is_cancelled=None,
            )

        self.assertEqual(result["status"], "error")
        self.assertIn("become ready", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_migrate_rolls_back_on_a_datadir_mismatch(self):
        host = _migration_host()
        psql = _migration_psql(datadir_after=_OLD_DATADIR)
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("data_directory", result["details"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_migrate_rolls_back_on_a_database_mismatch(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[6] = {
            "needle": "FROM pg_database WHERE NOT datistemplate",
            "ok": True,
            "result": _FakeOutput(stdout_lines=["dd_test_app", "dd_test_extra"]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("inventory changed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_migrate_rolls_back_on_a_role_mismatch(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[7] = {
            "needle": "FROM pg_roles",
            "ok": True,
            "result": _FakeOutput(stdout_lines=[]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("inventory changed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_migrate_rolls_back_when_verify_cannot_read_back(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[5] = {
            "needle": "SHOW data_directory",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["down"]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("verification", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_migrate_rolls_back_when_verify_mounts_are_wrong(self):
        host = _migration_host()
        host._scripts[8] = {
            "needle": "json .Mounts",
            "ok": True,
            "result": _old_mounts_output(),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("storage mounts", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_migrate_reports_a_failed_rollback(self):
        host = _migration_host()
        host._scripts[5] = {
            "needle": "cp -a",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["disk full"]),
            "used": False,
        }
        host._scripts.append(
            {
                "needle": 'cp "${BACKUP_FILE}"',
                "ok": False,
                "result": _FakeOutput(stderr_lines=["backup gone"]),
                "used": False,
            }
        )
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("data copy failed", result["msg"])
        self.assertIn("Rollback failed", result["details"])

    def test_migrate_succeeds_despite_a_cleanup_failure(self):
        events = []
        host = _migration_host()
        host._scripts[9] = {
            "needle": "rm -f",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["busy"]),
            "used": False,
        }
        with (
            patch.object(service_storage, "_run_postgres_psql_query_impl", _migration_psql()),
            patch.object(service_storage, "_wait_for_postgres_readiness", return_value=None),
        ):
            result = service_storage.run_postgres_storage_migration(
                _storage_ctx(
                    events,
                    command_error_details=lambda _output: "remote failed",
                ),
                _FakeSession(host),
                _config(),
                emit=None,
                operation_id="service_migrate_storage",
                is_cancelled=None,
            )

        self.assertEqual(result["status"], "success")
        self.assertFalse(result["compose_backup_removed"])
        warnings = [(args, kwargs) for args, kwargs in events if kwargs.get("level") == "warning"]
        self.assertEqual(len(warnings), 1)

    def test_migrate_honours_cancellation_before_starting(self):
        host = _migration_host()
        result = _run_migration(host, _migration_psql(), is_cancelled=_cancel_on_call(1))

        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(host.commands, [])

    def test_migrate_honours_cancellation_before_stopping(self):
        host = _migration_host()
        result = _run_migration(host, _migration_psql(), is_cancelled=_cancel_on_call(2))

        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertNotIn("stop -t 120", "\n".join(host.commands))

    def test_migrate_honours_cancellation_before_copying(self):
        host = _migration_host()
        result = _run_migration(host, _migration_psql(), is_cancelled=_cancel_on_call(3))

        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertNotIn("cp -a", "\n".join(host.commands))

    def test_migrate_honours_cancellation_before_starting_up(self):
        host = _migration_host()
        result = _run_migration(host, _migration_psql(), is_cancelled=_cancel_on_call(4))

        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertNotIn("up -d", "\n".join(host.commands))

    def test_migrate_converts_shell_exceptions_to_errors(self):
        host = _ScriptedHost([("json .Mounts", True, RuntimeError("ssh broke"))])
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["details"], "ssh broke")

    def test_migrate_finds_the_named_volume_in_any_mount_order(self):
        mounts = list(reversed(_OLD_LAYOUT_MOUNTS))
        host = _migration_host()
        host._scripts[0] = {
            "needle": "json .Mounts",
            "ok": True,
            "result": _FakeOutput(stdout_lines=[json.dumps(mounts)]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "success")
        self.assertFalse(result["already_migrated"])
        self.assertEqual(result["legacy_volume"], _ANON_NAME)

    def test_migrate_refuses_an_unnamed_parent_mount(self):
        mounts = [
            {"Type": "volume", "Destination": "/var/lib/postgresql"},
            _OLD_LAYOUT_MOUNTS[1],
        ]
        host = _migration_host()
        host._scripts[0] = {
            "needle": "json .Mounts",
            "ok": True,
            "result": _FakeOutput(stdout_lines=[json.dumps(mounts)]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("Unexpected storage layout", result["msg"])

    def test_migrate_refuses_an_empty_server_version(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[1] = {
            "needle": "SHOW server_version",
            "ok": True,
            "result": _FakeOutput(stdout_lines=["", "  "]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("major version", result["msg"])

    def test_migrate_rolls_back_when_verify_database_read_fails(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[6] = {
            "needle": "FROM pg_database WHERE NOT datistemplate",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["down"]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("re-read", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_migrate_rolls_back_when_verify_role_read_fails(self):
        host = _migration_host()
        psql = _migration_psql()
        psql._scripts[7] = {
            "needle": "FROM pg_roles",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["down"]),
            "used": False,
        }
        result = _run_migration(host, psql)

        self.assertEqual(result["status"], "error")
        self.assertIn("re-read", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_migrate_rolls_back_when_verify_inspect_fails(self):
        host = _migration_host()
        host._scripts[8] = {
            "needle": "json .Mounts",
            "ok": False,
            "result": _FakeOutput(stderr_lines=["no docker"]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("storage mounts", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_migrate_rolls_back_when_verify_mounts_are_unparsable(self):
        host = _migration_host()
        host._scripts[8] = {
            "needle": "json .Mounts",
            "ok": True,
            "result": _FakeOutput(stdout_lines=["not json"]),
            "used": False,
        }
        result = _run_migration(host, _migration_psql())

        self.assertEqual(result["status"], "error")
        self.assertIn("storage mounts", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])


class TestServiceStorageLayoutChecks(unittest.TestCase):
    def test_is_migrated_layout_accepts_the_named_pgdata_mount(self):
        self.assertTrue(
            engine_postgres_ops._postgres_storage_is_migrated_layout(
                _NEW_LAYOUT_MOUNTS[0],
                _NEW_PGDATA,
                _config(),
            )
        )

    def test_is_migrated_layout_rejects_a_stale_datadir(self):
        self.assertFalse(
            engine_postgres_ops._postgres_storage_is_migrated_layout(
                _NEW_LAYOUT_MOUNTS[0],
                _OLD_DATADIR,
                _config(),
            )
        )

    def test_is_migrated_layout_rejects_the_parent_mount(self):
        self.assertFalse(
            engine_postgres_ops._postgres_storage_is_migrated_layout(
                _OLD_LAYOUT_MOUNTS[0],
                _NEW_PGDATA,
                _config(),
            )
        )

    def test_is_migrated_layout_rejects_an_unnamed_mount(self):
        self.assertFalse(
            engine_postgres_ops._postgres_storage_is_migrated_layout(
                {"Destination": "/var/lib/postgresql/data"},
                _NEW_PGDATA,
                _config(),
            )
        )

    def test_is_migrated_layout_rejects_an_anonymous_mount(self):
        self.assertFalse(
            engine_postgres_ops._postgres_storage_is_migrated_layout(
                _OLD_LAYOUT_MOUNTS[1],
                _NEW_PGDATA,
                _config(),
            )
        )

    def test_verify_final_mount_accepts_the_named_pgdata_mount(self):
        ok, detail, mount = engine_postgres_ops._postgres_storage_verify_final_mount(
            _NEW_LAYOUT_MOUNTS,
            _NEW_PGDATA,
            "/var/lib/postgresql/data",
        )
        self.assertTrue(ok)
        self.assertEqual(detail, "")
        self.assertEqual(mount["Name"], "postgres_postgres_data")

    def test_verify_final_mount_rejects_missing_mounts(self):
        ok, detail, mount = engine_postgres_ops._postgres_storage_verify_final_mount(
            [],
            _NEW_PGDATA,
            "/var/lib/postgresql/data",
        )
        self.assertFalse(ok)
        self.assertIn("No mounted volume", detail)
        self.assertIsNone(mount)

    def test_verify_final_mount_rejects_an_unnamed_mount(self):
        ok, _detail, mount = engine_postgres_ops._postgres_storage_verify_final_mount(
            [{"Destination": "/var/lib/postgresql/data"}],
            _NEW_PGDATA,
            "/var/lib/postgresql/data",
        )
        self.assertFalse(ok)
        self.assertIsNone(mount)

    def test_verify_final_mount_rejects_an_anonymous_mount(self):
        ok, _detail, mount = engine_postgres_ops._postgres_storage_verify_final_mount(
            _OLD_LAYOUT_MOUNTS,
            _NEW_PGDATA,
            "/var/lib/postgresql/data",
        )
        self.assertFalse(ok)
        self.assertIsNone(mount)

    def test_verify_final_mount_rejects_the_parent_mount(self):
        ok, _detail, mount = engine_postgres_ops._postgres_storage_verify_final_mount(
            [_OLD_LAYOUT_MOUNTS[0]],
            _NEW_PGDATA,
            "/var/lib/postgresql/data",
        )
        self.assertFalse(ok)
        self.assertIsNone(mount)


def _removal_config(volume=None, subpath=None):
    """Why: builds the remove-action config with legacy settings."""
    settings = {}
    if volume is not None:
        settings["legacy_storage_volume"] = volume
    if subpath is not None:
        settings["legacy_storage_subpath"] = subpath
    return parse_postgres_service_config({"settings": settings})


def _run_removal(host, psql, config, **kwargs):
    """Why: runs the remove handler with patched psql per case."""
    kwargs.setdefault("is_cancelled", None)
    with patch.object(service_storage, "_run_postgres_psql_query_impl", psql):
        return service_storage.run_postgres_legacy_storage_removal(
            _storage_ctx(command_error_details=lambda _output: "remote failed"),
            _FakeSession(host),
            config,
            emit=None,
            operation_id="service_remove_legacy_storage",
            **kwargs,
        )


def _removal_psql(datadir=None):
    """Why: scripts the data-directory read of the remove flow."""
    return _ScriptedPsql(
        [
            (
                "SHOW data_directory",
                True,
                _FakeOutput(stdout_lines=[datadir or _NEW_PGDATA]),
            )
        ]
    )


def _retained_storage_output(volume, *, subpath="", kind="storage_migration"):
    """Why: removal tests need explicit Deploy Dash provenance to delete."""
    return _FakeOutput(
        stdout_lines=[
            json.dumps(
                {
                    "format_version": 1,
                    "retained_volumes": [
                        {
                            "volume": volume,
                            "kind": kind,
                            "subpath": subpath,
                        }
                    ],
                }
            )
        ]
    )


class TestServiceStorageRemoval(unittest.TestCase):
    def test_remove_deletes_a_detached_anonymous_volume(self):
        host = _ScriptedHost(
            [
                ("json .Mounts", True, _new_mounts_output()),
                (
                    "cat ",
                    True,
                    _FakeOutput(
                        stdout_lines=[
                            json.dumps(
                                {
                                    "format_version": 1,
                                    "retained_volumes": [
                                        {
                                            "volume": _ANON_NAME,
                                            "kind": "storage_migration",
                                        }
                                    ],
                                }
                            )
                        ]
                    ),
                ),
                ("docker volume rm", True, _FakeOutput()),
            ]
        )
        result = _run_removal(host, _removal_psql(), _removal_config(volume=_ANON_NAME))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["removed_volume"], _ANON_NAME)
        self.assertIn(_ANON_NAME, "\n".join(host.commands))

    def test_remove_refuses_an_unledgered_anonymous_volume(self):
        """Never turn an unrelated dangling Docker volume into a delete target."""
        host = _ScriptedHost(
            [
                ("json .Mounts", True, _new_mounts_output()),
                ("cat ", True, _FakeOutput()),
            ]
        )

        result = _run_removal(host, _removal_psql(), _removal_config(volume=_ANON_NAME))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("not recorded", result["msg"])
        self.assertNotIn("docker volume rm", "\n".join(host.commands))

    def test_remove_clears_a_legacy_subdir_in_the_live_volume(self):
        host = _ScriptedHost(
            [
                ("json .Mounts", True, _new_mounts_output()),
                (
                    "cat ",
                    True,
                    _retained_storage_output(
                        "postgres_postgres_data",
                        subpath="18/docker",
                    ),
                ),
                ("rm -rf /data/18/docker", True, _FakeOutput()),
            ]
        )
        result = _run_removal(
            host,
            _removal_psql(),
            _removal_config(volume="postgres_postgres_data", subpath="18/docker"),
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["removed_subpath"], "18/docker")
        self.assertEqual(result["volume"], "postgres_postgres_data")

    def test_remove_requires_the_legacy_volume_setting(self):
        host = _ScriptedHost([])
        result = _run_removal(host, _removal_psql(), _removal_config())

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("legacy_storage_volume", result["msg"])
        self.assertEqual(host.commands, [])

    def test_remove_rejects_an_unsafe_subpath(self):
        host = _ScriptedHost([])
        result = _run_removal(
            host,
            _removal_psql(),
            _removal_config(volume="postgres_postgres_data", subpath="../escape"),
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("unsafe", result["msg"])

    def test_remove_refuses_the_live_pgdata_subdir(self):
        for subpath in ("pgdata", "pgdata/base"):
            with self.subTest(subpath=subpath):
                host = _ScriptedHost([])
                result = _run_removal(
                    host,
                    _removal_psql(),
                    _removal_config(volume="postgres_postgres_data", subpath=subpath),
                )

                self.assertEqual(result["status"], "error")
                self.assertIn("live data", result["msg"])
                self.assertEqual(host.commands, [])

    def test_remove_refuses_before_migration(self):
        host = _ScriptedHost([("json .Mounts", True, _old_mounts_output())])
        psql = _ScriptedPsql(
            [("SHOW data_directory", True, _FakeOutput(stdout_lines=[_OLD_DATADIR]))]
        )
        result = _run_removal(host, psql, _removal_config(volume=_ANON_NAME))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("Migrate storage", result["msg"])
        self.assertNotIn("docker volume rm", "\n".join(host.commands))

    def test_remove_refuses_a_datadir_mismatch(self):
        host = _ScriptedHost([("json .Mounts", True, _new_mounts_output())])
        psql = _ScriptedPsql(
            [("SHOW data_directory", True, _FakeOutput(stdout_lines=[_OLD_DATADIR]))]
        )
        result = _run_removal(host, psql, _removal_config(volume=_ANON_NAME))

        self.assertEqual(result["status"], "error")
        self.assertIn("migrated storage layout", result["msg"])

    def test_remove_reports_an_empty_datadir_reading(self):
        host = _ScriptedHost([("json .Mounts", True, _new_mounts_output())])
        psql = _ScriptedPsql([("SHOW data_directory", True, _FakeOutput(stdout_lines=["", "  "]))])
        result = _run_removal(host, psql, _removal_config(volume=_ANON_NAME))

        self.assertEqual(result["status"], "error")
        self.assertIn("data directory", result["msg"])

    def test_remove_refuses_without_matching_mounts(self):
        host = _ScriptedHost([("json .Mounts", True, _FakeOutput(stdout_lines=["[]"]))])
        result = _run_removal(host, _removal_psql(), _removal_config(volume=_ANON_NAME))

        self.assertEqual(result["status"], "error")
        self.assertIn("migrated storage layout", result["msg"])

    def test_remove_refuses_a_named_volume(self):
        host = _ScriptedHost([("json .Mounts", True, _new_mounts_output())])
        result = _run_removal(
            host,
            _removal_psql(),
            _removal_config(volume="postgres_postgres_data"),
        )

        self.assertEqual(result["status"], "error")
        self.assertIn("named volume", result["msg"])
        self.assertNotIn("docker volume rm", "\n".join(host.commands))

    def test_remove_refuses_a_volume_that_is_still_attached(self):
        mounts = [
            *_NEW_LAYOUT_MOUNTS,
            {
                "Type": "volume",
                "Name": _ANON_NAME,
                "Source": _ANON_NAME,
                "Destination": "/var/lib/postgresql/data-old",
            },
        ]
        host = _ScriptedHost(
            [
                ("json .Mounts", True, _FakeOutput(stdout_lines=[json.dumps(mounts)])),
                ("cat ", True, _retained_storage_output(_ANON_NAME)),
            ]
        )
        result = _run_removal(host, _removal_psql(), _removal_config(volume=_ANON_NAME))

        self.assertEqual(result["status"], "error")
        self.assertIn("still attached", result["msg"])

    def test_remove_reports_volume_removal_failures(self):
        host = _ScriptedHost(
            [
                ("json .Mounts", True, _new_mounts_output()),
                ("cat ", True, _retained_storage_output(_ANON_NAME)),
                ("docker volume rm", False, _FakeOutput(stderr_lines=["busy"])),
            ]
        )
        result = _run_removal(host, _removal_psql(), _removal_config(volume=_ANON_NAME))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")

    def test_remove_refuses_a_subpath_in_a_foreign_volume(self):
        host = _ScriptedHost([("json .Mounts", True, _new_mounts_output())])
        result = _run_removal(
            host,
            _removal_psql(),
            _removal_config(volume="some_other_volume", subpath="18/docker"),
        )

        self.assertEqual(result["status"], "error")
        self.assertIn("does not match", result["msg"])

    def test_remove_reports_subdir_removal_failures(self):
        host = _ScriptedHost(
            [
                ("json .Mounts", True, _new_mounts_output()),
                (
                    "cat ",
                    True,
                    _retained_storage_output(
                        "postgres_postgres_data",
                        subpath="18/docker",
                    ),
                ),
                ("rm -rf /data/18/docker", False, _FakeOutput(stderr_lines=["busy"])),
            ]
        )
        result = _run_removal(
            host,
            _removal_psql(),
            _removal_config(volume="postgres_postgres_data", subpath="18/docker"),
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")

    def test_remove_honours_cancellation(self):
        host = _ScriptedHost([])
        result = _run_removal(
            host,
            _removal_psql(),
            _removal_config(volume=_ANON_NAME),
            is_cancelled=lambda: True,
        )

        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(host.commands, [])

    def test_remove_reports_inspect_failures(self):
        host = _ScriptedHost([("json .Mounts", False, _FakeOutput(stderr_lines=["no docker"]))])
        result = _run_removal(host, _removal_psql(), _removal_config(volume=_ANON_NAME))

        self.assertEqual(result["status"], "error")
        self.assertIn("inspect", result["msg"])

    def test_remove_reports_unparsable_mounts(self):
        host = _ScriptedHost([("json .Mounts", True, _FakeOutput(stdout_lines=["not json"]))])
        result = _run_removal(host, _removal_psql(), _removal_config(volume=_ANON_NAME))

        self.assertEqual(result["status"], "error")
        self.assertIn("inspect", result["msg"])

    def test_remove_reports_datadir_read_failures(self):
        host = _ScriptedHost([("json .Mounts", True, _new_mounts_output())])
        psql = _ScriptedPsql([("SHOW data_directory", False, _FakeOutput(stderr_lines=["down"]))])
        result = _run_removal(host, psql, _removal_config(volume=_ANON_NAME))

        self.assertEqual(result["status"], "error")
        self.assertIn("data directory", result["msg"])


def _dispatch_ctx(host, **overrides):
    """Why: runs runtime operations against a scripted session."""
    kwargs = {
        "error_result": _error_result,
        "emit_event": lambda *args, **kwargs: None,
        "emit_shell_output_lines": lambda *args, **kwargs: None,
        "command_error_details": lambda _output: "remote failed",
        "open_runtime_session": lambda **kwargs: {
            "ok": True,
            "session": _FakeSession(host),
        },
    }
    kwargs.update(overrides)
    return build_test_context(**kwargs)


class TestServiceStorageDispatch(unittest.TestCase):
    def test_migrate_dry_run_lists_the_migration_action(self):
        result = engine_postgres_ops.run_postgres_runtime_operation(
            _dispatch_ctx(_ScriptedHost([])),
            "service_migrate_storage",
            ip="203.0.113.10",
            username="deploy",
            password="secret",
            port=22,
            dry_run=True,
            raw_data={"settings": {"superuser_password": "secret"}},
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["actions"], ["Migrate PostgreSQL storage layout"])

    def test_remove_dry_run_lists_the_removal_action(self):
        result = engine_postgres_ops.run_postgres_runtime_operation(
            _dispatch_ctx(_ScriptedHost([])),
            "service_remove_legacy_storage",
            ip="203.0.113.10",
            username="deploy",
            password="secret",
            port=22,
            dry_run=True,
            raw_data={"settings": {"superuser_password": "secret"}},
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["actions"], ["Remove legacy PostgreSQL storage"])

    def test_migrate_dispatches_to_the_migration_handler(self):
        host = _ScriptedHost([("json .Mounts", True, _new_mounts_output())])
        psql = _ScriptedPsql(
            [("SHOW data_directory", True, _FakeOutput(stdout_lines=[_NEW_PGDATA]))]
        )
        with patch.object(service_storage, "_run_postgres_psql_query_impl", psql):
            result = engine_postgres_ops.run_postgres_runtime_operation(
                _dispatch_ctx(host),
                "service_migrate_storage",
                ip="203.0.113.10",
                username="deploy",
                password="secret",
                port=22,
                raw_data={"settings": {"superuser_password": "secret"}},
            )

        self.assertEqual(result["status"], "success")
        self.assertTrue(result["already_migrated"])

    def test_remove_dispatches_to_the_removal_handler(self):
        host = _ScriptedHost([("json .Mounts", True, _old_mounts_output())])
        psql = _ScriptedPsql(
            [("SHOW data_directory", True, _FakeOutput(stdout_lines=[_OLD_DATADIR]))]
        )
        with patch.object(service_storage, "_run_postgres_psql_query_impl", psql):
            result = engine_postgres_ops.run_postgres_runtime_operation(
                _dispatch_ctx(host),
                "service_remove_legacy_storage",
                ip="203.0.113.10",
                username="deploy",
                password="secret",
                port=22,
                raw_data={
                    "settings": {
                        "superuser_password": "secret",
                        "legacy_storage_volume": _ANON_NAME,
                    }
                },
            )

        self.assertEqual(result["status"], "error")
        self.assertIn("Migrate storage", result["msg"])

    def test_storage_operations_are_registered(self):
        for operation_id in (
            "service_migrate_storage",
            "service_remove_legacy_storage",
        ):
            with self.subTest(operation_id=operation_id):
                self.assertEqual(OPERATIONS[operation_id]["id"], operation_id)
        self.assertIn(
            "legacy_storage_volume",
            OPERATIONS["service_remove_legacy_storage"]["params_schema"]["properties"]["settings"][
                "required"
            ],
        )

    def test_status_dispatch_merges_storage_shape(self):
        host = _ScriptedHost(
            [
                (
                    "kv container_readiness_status",
                    True,
                    _FakeOutput(
                        stdout_lines=[
                            "configured=1",
                            "container_readiness_status=ready",
                            "server_version=17.8",
                        ]
                    ),
                ),
                ("json .Mounts", True, _new_mounts_output()),
                ("docker volume ls", True, _FakeOutput()),
            ]
        )
        with patch.object(service_storage, "_run_postgres_psql_query_impl", _enrich_psql()):
            result = engine_postgres_ops.run_postgres_runtime_operation(
                _dispatch_ctx(host),
                "service_status",
                ip="203.0.113.10",
                username="deploy",
                password="secret",
                port=22,
                raw_data={"settings": {"superuser_password": "secret"}},
            )

        self.assertEqual(result["status"], "success")
        service_status = result["service_status"]
        self.assertEqual(service_status["configured"], True)
        self.assertEqual(service_status["data_directory"], _NEW_PGDATA)
        self.assertEqual(service_status["storage_volume"], "postgres_postgres_data")
        self.assertTrue(service_status["storage_layout_current"])

    def test_storage_plugin_handlers_bind_the_operation_ids(self):
        calls = []
        fake_ctx = SimpleNamespace(
            describe_postgres=lambda **kwargs: {"status": "success"},
            emit_event=lambda *args, **kwargs: None,
            extract_connection_payload=lambda data: {
                "ip": "203.0.113.10",
                "username": "deploy",
                "password": "secret",
                "port": 22,
            },
            connection_validation_error=lambda connection: None,
            resolve_dry_run=lambda data, default: False,
            extract_postgres_settings_payload=lambda data: {"settings": {}},
            run_postgres_runtime_operation=lambda **kwargs: (
                calls.append(kwargs) or {"status": "success"}
            ),
            run_postgres_project_operation=lambda **kwargs: {"status": "success"},
        )
        plugin = build_postgres_plugin(operations=OPERATIONS, ctx=fake_ctx)
        for operation_id in (
            "service_migrate_storage",
            "service_remove_legacy_storage",
        ):
            with self.subTest(operation_id=operation_id):
                calls.clear()
                plugin.handlers[operation_id]({})
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0]["operation_id"], operation_id)


class TestServiceStorageStatusBuilders(unittest.TestCase):
    def test_data_size_sql_sums_live_database_sizes(self):
        self.assertEqual(
            engine_postgres_ops._postgres_storage_data_size_sql(),
            "SELECT COALESCE(sum(pg_database_size(datname)), 0) FROM pg_database;",
        )

    def test_dangling_volumes_command_lists_detached_volumes(self):
        command = engine_postgres_ops._postgres_storage_dangling_volumes_command(_config())
        self.assertIn("set -eu;", command)
        self.assertIn("docker volume ls -q -f dangling=true", command)

    def test_detached_description_names_a_total_loss(self):
        self.assertEqual(
            engine_postgres_ops._postgres_storage_detached_description(
                ["dd_test_app", "dd_test_jobs"], 2
            ),
            "this cluster has none of the 2 databases Deploy Dash expects; "
            "the data volume may be detached. List candidates with "
            "`docker volume ls -f dangling=true`, and do not run "
            "`docker volume prune` until it is resolved.",
        )

    def test_detached_description_names_a_partial_loss(self):
        self.assertEqual(
            engine_postgres_ops._postgres_storage_detached_description(["dd_test_gone"], 2),
            "this cluster has 1 of the 2 databases Deploy Dash expects "
            "(dd_test_gone); the data volume may be detached. List "
            "candidates with `docker volume ls -f dangling=true`, and do "
            "not run `docker volume prune` until it is resolved.",
        )


def _enrich(host, psql, base=None, expected=()):
    """Why: runs status enrichment with patched psql per case."""
    with patch.object(service_storage, "_run_postgres_psql_query_impl", psql):
        return service_storage.enrich_postgres_service_status(
            _storage_ctx(command_error_details=lambda output: "\n".join(output.stderr_lines)),
            _FakeSession(host),
            _config(expected_databases=list(expected)),
            emit=None,
            operation_id="service_status",
            base_status=dict(base or {"status": "running"}),
        )


def _enrich_psql(**overrides):
    """Why: scripts the four enrichment reads with healthy defaults."""
    scripts = {
        "SHOW data_directory": _FakeOutput(stdout_lines=[_NEW_PGDATA]),
        "pg_database_size": _FakeOutput(stdout_lines=["12345"]),
        "FROM deploydash.managed_databases": _FakeOutput(stdout_lines=["dd_test_app"]),
        "FROM pg_database WHERE NOT datistemplate": _FakeOutput(stdout_lines=["dd_test_app"]),
    }
    scripts.update(overrides)
    return _ScriptedPsql([(needle, True, output) for needle, output in scripts.items()])


def _enrich_host():
    """Why: scripts mounts plus an empty dangling list by default."""
    return _ScriptedHost(
        [
            ("json .Mounts", True, _new_mounts_output()),
            ("docker volume ls", True, _FakeOutput()),
        ]
    )


def _ready_base_status():
    """Why: carries a ready container map so tests can watch it change."""
    return {
        "status": "running",
        "container_status": {
            "present": True,
            "docker_state": "running",
            "running": True,
            "health": "healthy",
            "exit_code": None,
            "image": "postgres:17",
            "started_at": "2026-09-01T00:00:00Z",
            "effective_status": "ready",
            "readiness": {"status": "ready", "detail": ""},
        },
    }


class TestServiceStorageStatusEnrichment(unittest.TestCase):
    def test_enrich_reports_the_named_layout(self):
        result = _enrich(_enrich_host(), _enrich_psql())

        self.assertEqual(result.get("status"), "running")
        self.assertEqual(result.get("data_directory"), _NEW_PGDATA)
        self.assertEqual(result.get("storage_volume"), "postgres_postgres_data")
        self.assertFalse(result.get("storage_volume_anonymous"))
        self.assertEqual(result.get("data_size_bytes"), 12345)
        self.assertTrue(result.get("storage_layout_current"))
        self.assertEqual(result.get("missing_expected_databases"), [])
        self.assertIsNone(result.get("storage_error"))
        self.assertEqual(result.get("detached_storage_volumes"), [])

    def test_enrich_reports_the_legacy_layout(self):
        host = _ScriptedHost(
            [
                ("json .Mounts", True, _old_mounts_output()),
                ("docker volume ls", True, _FakeOutput()),
            ]
        )
        psql = _enrich_psql(**{"SHOW data_directory": _FakeOutput(stdout_lines=[_OLD_DATADIR])})
        result = _enrich(host, psql)

        self.assertEqual(result.get("data_directory"), _OLD_DATADIR)
        self.assertEqual(result.get("storage_volume"), _ANON_NAME)
        self.assertTrue(result.get("storage_volume_anonymous"))
        self.assertFalse(result.get("storage_layout_current"))
        self.assertIsNone(result.get("storage_error"))

    def test_enrich_reports_a_detached_cluster(self):
        psql = _enrich_psql(
            **{
                "FROM deploydash.managed_databases": _FakeOutput(
                    stdout_lines=["dd_test_app", "dd_test_jobs"]
                ),
                "FROM pg_database WHERE NOT datistemplate": _FakeOutput(),
            }
        )
        result = _enrich(_enrich_host(), psql)

        self.assertEqual(
            result.get("missing_expected_databases"),
            ["dd_test_app", "dd_test_jobs"],
        )
        self.assertIn("none of the 2", result.get("storage_error"))
        self.assertIn("dangling=true", result.get("storage_error"))

    def test_enrich_marks_a_detached_cluster_unhealthy_instead_of_ready(self):
        psql = _enrich_psql(
            **{
                "FROM deploydash.managed_databases": _FakeOutput(
                    stdout_lines=["dd_test_app", "dd_test_jobs"]
                ),
                "FROM pg_database WHERE NOT datistemplate": _FakeOutput(),
            }
        )
        result = _enrich(_enrich_host(), psql, base=_ready_base_status())

        container = result.get("container_status")
        self.assertIsNotNone(result.get("storage_error"))
        self.assertEqual(container.get("effective_status"), "unhealthy")
        self.assertEqual(container.get("readiness", {}).get("status"), "unhealthy")
        self.assertEqual(
            container.get("readiness", {}).get("detail"),
            result.get("storage_error"),
        )
        self.assertTrue(container.get("running"))
        self.assertEqual(container.get("image"), "postgres:17")

    def test_enrich_leaves_container_status_alone_when_nothing_is_missing(self):
        base = _ready_base_status()
        result = _enrich(_enrich_host(), _enrich_psql(), base=base)

        self.assertIsNone(result.get("storage_error"))
        self.assertEqual(result.get("container_status"), base["container_status"])

    def test_enrich_reports_detachment_without_a_container_status_map(self):
        psql = _enrich_psql(
            **{
                "FROM deploydash.managed_databases": _FakeOutput(
                    stdout_lines=["dd_test_app", "dd_test_jobs"]
                ),
                "FROM pg_database WHERE NOT datistemplate": _FakeOutput(),
            }
        )
        result = _enrich(_enrich_host(), psql)

        self.assertIn("none of the 2", result.get("storage_error"))
        self.assertNotIn("container_status", result)

    def test_enrich_lists_detached_volumes(self):
        host = _ScriptedHost(
            [
                ("json .Mounts", True, _new_mounts_output()),
                (
                    "docker volume ls",
                    True,
                    _FakeOutput(stdout_lines=[_ANON_NAME, "  ", "b" * 64]),
                ),
                (
                    "cat ",
                    True,
                    _FakeOutput(
                        stdout_lines=[
                            json.dumps(
                                {
                                    "format_version": 1,
                                    "retained_volumes": [
                                        {
                                            "volume": _ANON_NAME,
                                            "kind": "storage_migration",
                                        }
                                    ],
                                }
                            )
                        ]
                    ),
                ),
            ]
        )
        result = _enrich(host, _enrich_psql())

        self.assertEqual(result.get("detached_storage_volumes"), [_ANON_NAME])

    def test_enrich_leaves_unknowns_when_inspect_fails(self):
        host = _ScriptedHost(
            [
                ("json .Mounts", False, _FakeOutput(stderr_lines=["no docker"])),
                ("docker volume ls", True, _FakeOutput()),
            ]
        )
        result = _enrich(host, _enrich_psql())

        self.assertEqual(result.get("status"), "running")
        self.assertIsNone(result.get("storage_volume"))
        self.assertIsNone(result.get("storage_layout_current"))
        self.assertEqual(result.get("data_directory"), _NEW_PGDATA)
        self.assertEqual(result.get("data_size_bytes"), 12345)

    def test_enrich_leaves_unknowns_when_mounts_are_unparsable(self):
        host = _ScriptedHost(
            [
                ("json .Mounts", True, _FakeOutput(stdout_lines=["not json"])),
                ("docker volume ls", True, _FakeOutput()),
            ]
        )
        result = _enrich(host, _enrich_psql())

        self.assertIsNone(result.get("storage_volume"))
        self.assertIsNone(result.get("storage_layout_current"))

    def test_enrich_leaves_unknowns_when_datadir_read_fails(self):
        psql = _ScriptedPsql(
            [
                ("SHOW data_directory", False, _FakeOutput(stderr_lines=["down"])),
                ("pg_database_size", True, _FakeOutput(stdout_lines=["12345"])),
                (
                    "FROM deploydash.managed_databases",
                    True,
                    _FakeOutput(stdout_lines=["dd_test_app"]),
                ),
                (
                    "FROM pg_database WHERE NOT datistemplate",
                    True,
                    _FakeOutput(stdout_lines=["dd_test_app"]),
                ),
            ]
        )
        result = _enrich(_enrich_host(), psql)

        self.assertIsNone(result.get("data_directory"))
        self.assertIsNone(result.get("storage_volume"))
        self.assertEqual(result.get("data_size_bytes"), 12345)

    def test_enrich_leaves_unknowns_when_datadir_is_empty(self):
        psql = _enrich_psql(**{"SHOW data_directory": _FakeOutput(stdout_lines=["", "  "])})
        result = _enrich(_enrich_host(), psql)

        self.assertIsNone(result.get("data_directory"))
        self.assertIsNone(result.get("storage_volume"))

    def test_enrich_leaves_unknowns_without_a_source_mount(self):
        host = _ScriptedHost(
            [
                ("json .Mounts", True, _FakeOutput(stdout_lines=["[]"])),
                ("docker volume ls", True, _FakeOutput()),
            ]
        )
        result = _enrich(host, _enrich_psql())

        self.assertIsNone(result.get("storage_volume"))
        self.assertIsNone(result.get("storage_layout_current"))
        self.assertEqual(result.get("data_directory"), _NEW_PGDATA)

    def test_enrich_leaves_volume_unknown_for_an_unnamed_mount(self):
        host = _ScriptedHost(
            [
                (
                    "json .Mounts",
                    True,
                    _FakeOutput(
                        stdout_lines=[json.dumps([{"Destination": "/var/lib/postgresql/data"}])]
                    ),
                ),
                ("docker volume ls", True, _FakeOutput()),
            ]
        )
        result = _enrich(host, _enrich_psql())

        self.assertIsNone(result.get("storage_volume"))
        self.assertFalse(result.get("storage_layout_current"))

    def test_enrich_leaves_size_unknown_when_the_read_fails(self):
        psql = _ScriptedPsql(
            [
                ("SHOW data_directory", True, _FakeOutput(stdout_lines=[_NEW_PGDATA])),
                ("pg_database_size", False, _FakeOutput(stderr_lines=["down"])),
                (
                    "FROM deploydash.managed_databases",
                    True,
                    _FakeOutput(stdout_lines=["dd_test_app"]),
                ),
                (
                    "FROM pg_database WHERE NOT datistemplate",
                    True,
                    _FakeOutput(stdout_lines=["dd_test_app"]),
                ),
            ]
        )
        result = _enrich(_enrich_host(), psql)

        self.assertIsNone(result.get("data_size_bytes"))
        self.assertEqual(result.get("storage_volume"), "postgres_postgres_data")

    def test_enrich_leaves_size_unknown_when_the_read_is_empty(self):
        psql = _enrich_psql(**{"pg_database_size": _FakeOutput(stdout_lines=["", "  "])})
        result = _enrich(_enrich_host(), psql)

        self.assertIsNone(result.get("data_size_bytes"))

    def test_enrich_leaves_size_unknown_when_the_read_is_garbage(self):
        psql = _enrich_psql(**{"pg_database_size": _FakeOutput(stdout_lines=["lots"])})
        result = _enrich(_enrich_host(), psql)

        self.assertIsNone(result.get("data_size_bytes"))

    def test_enrich_stays_silent_when_the_registry_read_fails(self):
        psql = _ScriptedPsql(
            [
                ("SHOW data_directory", True, _FakeOutput(stdout_lines=[_NEW_PGDATA])),
                ("pg_database_size", True, _FakeOutput(stdout_lines=["12345"])),
                (
                    "FROM deploydash.managed_databases",
                    False,
                    _FakeOutput(stderr_lines=["reset"]),
                ),
                (
                    "FROM pg_database WHERE NOT datistemplate",
                    True,
                    _FakeOutput(stdout_lines=["dd_test_app"]),
                ),
            ]
        )
        result = _enrich(_enrich_host(), psql)

        self.assertEqual(result.get("missing_expected_databases"), [])
        self.assertIsNone(result.get("storage_error"))

    def test_enrich_stays_silent_when_the_live_read_fails(self):
        psql = _ScriptedPsql(
            [
                ("SHOW data_directory", True, _FakeOutput(stdout_lines=[_NEW_PGDATA])),
                ("pg_database_size", True, _FakeOutput(stdout_lines=["12345"])),
                (
                    "FROM deploydash.managed_databases",
                    True,
                    _FakeOutput(stdout_lines=["dd_test_app"]),
                ),
                ("FROM pg_database WHERE NOT datistemplate", False, _FakeOutput()),
            ]
        )
        result = _enrich(_enrich_host(), psql)

        self.assertEqual(result.get("missing_expected_databases"), [])
        self.assertIsNone(result.get("storage_error"))

    def test_enrich_falls_back_to_desktop_expectations_without_a_registry(self):
        psql = _ScriptedPsql(
            [
                ("SHOW data_directory", True, _FakeOutput(stdout_lines=[_NEW_PGDATA])),
                ("pg_database_size", True, _FakeOutput(stdout_lines=["12345"])),
                (
                    "FROM deploydash.managed_databases",
                    False,
                    _FakeOutput(
                        stderr_lines=['relation "deploydash.managed_databases" does not exist']
                    ),
                ),
                ("FROM pg_database WHERE NOT datistemplate", True, _FakeOutput()),
            ]
        )
        result = _enrich(_enrich_host(), psql, expected=("dd_test_app", "dd_test_jobs"))

        self.assertEqual(
            result.get("missing_expected_databases"),
            ["dd_test_app", "dd_test_jobs"],
        )
        self.assertIn("none of the 2", result.get("storage_error"))

    def test_enrich_stays_silent_for_a_fresh_service_without_expectations(self):
        psql = _ScriptedPsql(
            [
                ("SHOW data_directory", True, _FakeOutput(stdout_lines=[_NEW_PGDATA])),
                ("pg_database_size", True, _FakeOutput(stdout_lines=["12345"])),
                (
                    "FROM deploydash.managed_databases",
                    False,
                    _FakeOutput(
                        stderr_lines=['relation "deploydash.managed_databases" does not exist']
                    ),
                ),
                (
                    "FROM pg_database WHERE NOT datistemplate",
                    True,
                    _FakeOutput(stdout_lines=["dd_test_app"]),
                ),
            ]
        )
        result = _enrich(_enrich_host(), psql)

        self.assertEqual(result.get("missing_expected_databases"), [])
        self.assertIsNone(result.get("storage_error"))

    def test_enrich_prefers_a_readable_registry_over_desktop_expectations(self):
        psql = _enrich_psql(
            **{
                "FROM deploydash.managed_databases": _FakeOutput(stdout_lines=["dd_test_app"]),
                "FROM pg_database WHERE NOT datistemplate": _FakeOutput(
                    stdout_lines=["dd_test_app"]
                ),
            }
        )
        result = _enrich(_enrich_host(), psql, expected=("dd_test_app", "dd_stale"))

        self.assertEqual(result.get("missing_expected_databases"), [])
        self.assertIsNone(result.get("storage_error"))

    def test_enrich_leaves_detached_unknown_when_the_list_fails(self):
        host = _ScriptedHost(
            [
                ("json .Mounts", True, _new_mounts_output()),
                ("docker volume ls", False, _FakeOutput(stderr_lines=["no docker"])),
            ]
        )
        result = _enrich(host, _enrich_psql())

        self.assertEqual(result.get("detached_storage_volumes"), [])
        self.assertEqual(result.get("storage_volume"), "postgres_postgres_data")


class TestServiceStorageRollback(unittest.TestCase):
    def test_rollback_restores_and_restarts(self):
        host = _ScriptedHost(
            [
                ('cp "${BACKUP_FILE}"', True, _FakeOutput()),
                ("up -d", True, _FakeOutput()),
            ]
        )
        with patch.object(service_storage, "_wait_for_postgres_readiness", return_value=None):
            ok, detail = service_storage._rollback_storage_migration_to_backup(
                _storage_ctx(),
                _FakeSession(host),
                _config(),
                emit=None,
                backup_path="/opt/deploydash/stack/postgres/docker-compose.yml.bak",
                operation_id="service_migrate_storage",
            )
        self.assertTrue(ok)
        self.assertIn("restarted", detail)

    def test_rollback_reports_a_restore_failure(self):
        host = _ScriptedHost(
            [
                (
                    'cp "${BACKUP_FILE}"',
                    False,
                    _FakeOutput(stderr_lines=["backup gone"]),
                )
            ]
        )
        with patch.object(service_storage, "_wait_for_postgres_readiness", return_value=None):
            ok, detail = service_storage._rollback_storage_migration_to_backup(
                _storage_ctx(command_error_details=lambda _output: "backup gone"),
                _FakeSession(host),
                _config(),
                emit=None,
                backup_path="/opt/deploydash/stack/postgres/docker-compose.yml.bak",
                operation_id="service_migrate_storage",
            )
        self.assertFalse(ok)
        self.assertIn("restore", detail)
        self.assertNotIn("up -d", "\n".join(host.commands))

    def test_rollback_reports_a_restart_failure(self):
        host = _ScriptedHost(
            [
                ('cp "${BACKUP_FILE}"', True, _FakeOutput()),
                ("up -d", False, _FakeOutput(stderr_lines=["bad image"])),
            ]
        )
        with patch.object(service_storage, "_wait_for_postgres_readiness", return_value=None):
            ok, detail = service_storage._rollback_storage_migration_to_backup(
                _storage_ctx(command_error_details=lambda _output: "bad image"),
                _FakeSession(host),
                _config(),
                emit=None,
                backup_path="/opt/deploydash/stack/postgres/docker-compose.yml.bak",
                operation_id="service_migrate_storage",
            )
        self.assertFalse(ok)
        self.assertIn("start failed", detail)

    def test_rollback_reports_unreadiness_after_restart(self):
        host = _ScriptedHost(
            [
                ('cp "${BACKUP_FILE}"', True, _FakeOutput()),
                ("up -d", True, _FakeOutput()),
            ]
        )
        with patch.object(
            service_storage,
            "_wait_for_postgres_readiness",
            return_value=_error_result(
                "ENGINE_RUNTIME_ERROR",
                "Verify PostgreSQL readiness failed.",
                stage="execute_runtime_operation",
                details="still starting",
            ),
        ):
            ok, detail = service_storage._rollback_storage_migration_to_backup(
                _storage_ctx(),
                _FakeSession(host),
                _config(),
                emit=None,
                backup_path="/opt/deploydash/stack/postgres/docker-compose.yml.bak",
                operation_id="service_migrate_storage",
            )
        self.assertFalse(ok)
        self.assertIn("not ready", detail)


if __name__ == "__main__":
    unittest.main()
