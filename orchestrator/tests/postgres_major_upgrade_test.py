"""PostgreSQL major-version upgrade operation (#86).

Swapping the image over a live data directory breaks the cluster, so
service_configure refuses it (see the guard tests) and this operation
moves versions by dump and restore instead: preflight, dump with the
target binaries, switch to a fresh volume, restore, verify, and keep
the old volume for rollback. These tests pin every phase and every
refusal through a scripted host.
"""

from __future__ import annotations

import inspect
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from engine import run_postgres_runtime_operation
from orchestrator.plugins.postgres_plugin import build_plugin as build_postgres_plugin
from orchestrator.postgres_parts import OPERATIONS, parse_postgres_service_config
from orchestrator.postgres_runtime_parts import (
    service_configuration,
    service_storage,
    service_upgrade,
)
from tests.engine_context_fixtures import build_test_context

_PGDATA = "/var/lib/postgresql/data/pgdata"
_LIVE_VOLUME = "postgres_postgres_data"
_NEW_VOLUME_PREFIX = "postgres_postgres_data_pg17_"


def _mounts_json(volume_name):
    """Why: mounts are the only live-to-physical volume mapping."""
    return json.dumps(
        [
            {
                "Type": "volume",
                "Name": volume_name,
                "Source": volume_name,
                "Destination": "/var/lib/postgresql/data",
                "Mode": "",
                "RW": True,
            }
        ]
    )


class _FakeOutput:
    """Why: carries canned remote command output without a server."""

    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


class _FakeSession:
    """Why: a session whose host answers from the script."""

    def __init__(self, host):
        self.host = host

    def close(self):
        return {"disconnect_error": None}


class _UpgradeHost:
    """Why: routes upgrade commands to canned answers by marker.

    Stateful on the compose up count: the first up flips the server
    version and mounts to the target, a rollback up flips them back,
    so verify and rollback assertions see what a live server would show.
    """

    def __init__(
        self,
        *,
        version="16.4",
        target_version="17.5",
        ready=True,
        post_up_ready=True,
        disk_data=100,
        disk_avail=1000,
        fail_markers=(),
        fail_after_up_markers=(),
        fail_once_markers=(),
        databases=("dd_test_app", "postgres"),
        databases_post=None,
        roles=("dd_test_app_user", "deploydash"),
        roles_post=None,
        registry=("dd_test_app",),
        datadir=_PGDATA,
        datadir_post=None,
        datadir_empty=False,
        relations=("public.t:r",),
        relations_post=None,
        tables=('"public"."t"',),
        counts=("0|3",),
        counts_post=None,
        extensions=("pgcrypto",),
        extensions_post=None,
        database_metadata=("owner=deploydash", "acl=deploydash|deploydash|CREATE|true"),
        database_metadata_post=None,
        mounts_line=None,
        mounts_post_line=None,
        mounts_post_volume=None,
        ledger_line=None,
        globals_already_exists=False,
    ):
        self.commands = []
        self.version = version
        self.target_version = target_version
        self.ready = ready
        self.post_up_ready = post_up_ready
        self.disk_data = disk_data
        self.disk_avail = disk_avail
        self.fail_markers = tuple(fail_markers)
        self.fail_after_up_markers = tuple(fail_after_up_markers)
        self.fail_once_markers = list(fail_once_markers)
        self.databases = tuple(databases)
        self.databases_post = (
            tuple(databases_post) if databases_post is not None else tuple(databases)
        )
        self.roles = tuple(roles)
        self.roles_post = tuple(roles_post) if roles_post is not None else tuple(roles)
        self.registry = tuple(registry)
        self.datadir = datadir
        self.datadir_post = datadir_post if datadir_post is not None else datadir
        self.datadir_empty = datadir_empty
        self.mounts_line = mounts_line
        self.mounts_post_line = mounts_post_line
        self.mounts_post_volume = mounts_post_volume
        self.created_volume = None
        self.ledger_line = ledger_line
        self.relations = tuple(relations)
        self.relations_post = (
            tuple(relations_post) if relations_post is not None else tuple(relations)
        )
        self.tables = tuple(tables)
        self.counts = tuple(counts)
        self.counts_post = tuple(counts_post) if counts_post is not None else tuple(counts)
        self.extensions = tuple(extensions)
        self.extensions_post = (
            tuple(extensions_post) if extensions_post is not None else tuple(extensions)
        )
        self.database_metadata = tuple(database_metadata)
        self.database_metadata_post = (
            tuple(database_metadata_post)
            if database_metadata_post is not None
            else tuple(database_metadata)
        )
        self.globals_already_exists = globals_already_exists
        self.up_runs = 0
        self.rewrote = False
        self.restored = False
        self.serving_target = False

    def _upgraded(self):
        return self.serving_target

    def _post_lines(self, pre, post):
        return list(post) if self._upgraded() else list(pre)

    def run_shell_command(self, command, *_args, **_kwargs):
        self.commands.append(command)
        if any(marker in command for marker in self.fail_markers):
            return False, _FakeOutput(stderr_lines=["injected failure"])
        if self.up_runs >= 1 and any(marker in command for marker in self.fail_after_up_markers):
            return False, _FakeOutput(stderr_lines=["injected post-up failure"])
        for marker in list(self.fail_once_markers):
            if marker in command:
                self.fail_once_markers.remove(marker)
                return False, _FakeOutput(stderr_lines=["injected one-shot failure"])
        # Specific markers first: nearly every command carries the base
        # env prefix, so the readiness probe beneath it matches last.
        if 'cat > "${COMPOSE_FILE}"' in command:
            self.rewrote = True
            return True, _FakeOutput(stdout_lines=[])
        if 'cp "${BACKUP_FILE}" "${COMPOSE_FILE}"' in command:
            self.restored = True
            return True, _FakeOutput(stdout_lines=[])
        if "up -d" in command:
            self.up_runs += 1
            self.serving_target = self.rewrote and not self.restored
            return True, _FakeOutput(stdout_lines=[])
        if "{{json .Mounts}}" in command:
            if not self._upgraded() and self.mounts_line is not None:
                return True, _FakeOutput(stdout_lines=[self.mounts_line])
            if self._upgraded() and self.mounts_post_line is not None:
                return True, _FakeOutput(stdout_lines=[self.mounts_post_line])
            volume = (
                self.mounts_post_volume
                if self.mounts_post_volume is not None
                else self.created_volume
            )
            if not self._upgraded():
                volume = _LIVE_VOLUME
            return True, _FakeOutput(stdout_lines=[_mounts_json(volume)])
        if "SHOW server_version" in command:
            version = self.target_version if self._upgraded() else self.version
            return True, _FakeOutput(stdout_lines=[version])
        if "SHOW data_directory" in command:
            if self.datadir_empty:
                return True, _FakeOutput(stdout_lines=[])
            datadir = self.datadir_post if self._upgraded() else self.datadir
            return True, _FakeOutput(stdout_lines=[datadir])
        if "pg_dumpall" in command:
            return True, _FakeOutput(stdout_lines=[])
        if "pg_dump " in command:
            return True, _FakeOutput(stdout_lines=[])
        if "globals.sql" in command and "< " in command and self.globals_already_exists:
            return False, _FakeOutput(
                stderr_lines=['ERROR: role "deploydash" already exists'],
            )
        if "pg_restore" in command:
            return True, _FakeOutput(stdout_lines=[])
        if "CREATE EXTENSION" in command:
            return True, _FakeOutput(stdout_lines=[])
        if "CREATE DATABASE" in command:
            return True, _FakeOutput(stdout_lines=[])
        if "relkind IN (" in command:
            return True, _FakeOutput(
                stdout_lines=self._post_lines(self.relations, self.relations_post)
            )
        if "count(*)" in command:
            return True, _FakeOutput(stdout_lines=self._post_lines(self.counts, self.counts_post))
        if "relispartition" in command:
            return True, _FakeOutput(stdout_lines=list(self.tables))
        if "FROM pg_extension" in command:
            return True, _FakeOutput(
                stdout_lines=self._post_lines(self.extensions, self.extensions_post)
            )
        if "aclexplode" in command and "current_database()" in command:
            return True, _FakeOutput(
                stdout_lines=self._post_lines(
                    self.database_metadata,
                    self.database_metadata_post,
                )
            )
        if "FROM pg_database WHERE NOT datistemplate" in command:
            return True, _FakeOutput(
                stdout_lines=self._post_lines(self.databases, self.databases_post)
            )
        if "FROM pg_roles" in command:
            return True, _FakeOutput(stdout_lines=self._post_lines(self.roles, self.roles_post))
        if "FROM deploydash.managed_databases" in command:
            return True, _FakeOutput(stdout_lines=list(self.registry))
        if "data_bytes=" in command:
            return True, _FakeOutput(
                stdout_lines=[
                    f"data_bytes={self.disk_data}",
                    f"avail_bytes={self.disk_avail}",
                ]
            )
        if "docker build" in command:
            return True, _FakeOutput(stdout_lines=[])
        if "docker volume create" in command:
            self.created_volume = command.rsplit(" ", 1)[-1]
            return True, _FakeOutput(stdout_lines=[])
        if "postgres-major-upgrades.json" in command:
            if self.ledger_line is None:
                return True, _FakeOutput(stdout_lines=[])
            return True, _FakeOutput(stdout_lines=[self.ledger_line])
        if "{{if .State.Health}}" in command:
            ready = self.post_up_ready if self._upgraded() else self.ready
            if ready:
                return True, _FakeOutput(stdout_lines=[])
            return False, _FakeOutput(stderr_lines=["service not ready"])
        return True, _FakeOutput(stdout_lines=[])


def _config(**settings):
    """Why: builds the upgrade config with a 17 target by default."""
    base = {
        "postgres_version": "17",
        "superuser_password": "secret",
        "enabled_extensions": [],
    }
    base.update(settings)
    return parse_postgres_service_config({"settings": base})


def _context(**overrides):
    """Why: the handler context with listener overrides per test."""
    return build_test_context(**overrides)


def _run_upgrade(host, config=None, **kwargs):
    """Why: one call shape runs the handler against the scripted host."""
    params = {
        "ctx": _context(),
        "session": _FakeSession(host),
        "config": config if config is not None else _config(),
        "emit": None,
        "is_cancelled": None,
        "operation_id": "service_upgrade_major",
    }
    params.update(kwargs)
    return service_upgrade.run_postgres_major_upgrade(**params)


class TestPostgresMajorUpgrade(unittest.TestCase):
    def test_upgrade_moves_minor_old_cluster_to_target_volume(self):
        # #86: the full path — dump with the target binaries, switch to a
        # fresh volume, restore, verify — leaving the old volume behind.
        host = _UpgradeHost()
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "service_upgrade_major")
        self.assertEqual(result["previous_major"], "16")
        self.assertEqual(result["new_major"], "17")
        self.assertEqual(result["previous_volume"], _LIVE_VOLUME)
        self.assertEqual(result["new_volume"], host.created_volume)
        self.assertTrue(result["new_volume"].startswith(_NEW_VOLUME_PREFIX))
        self.assertEqual(result["upgraded_databases"], ["dd_test_app", "postgres"])
        self.assertEqual(result["upgraded_roles"], ["dd_test_app_user", "deploydash"])
        self.assertIn("/upgrade-backups/postgres/", result["dump_dir"])
        self.assertTrue(result["ledger_recorded"])
        commands = "\n".join(host.commands)
        self.assertIn("postgres-major-upgrades.json", commands)
        # Dumps run with the target binaries: the supported cross-version
        # direction is dumping with the newer client.
        self.assertIn("pg_dumpall --globals-only", commands)
        self.assertIn("pg_dump ", commands)
        self.assertIn("postgres:17.10-bookworm", commands)
        self.assertIn("docker volume create", commands)
        self.assertIn(_NEW_VOLUME_PREFIX, commands)
        self.assertIn(f"name: {host.created_volume}", commands)
        self.assertIn("pg_restore", commands)
        dump_index = commands.find("pg_dumpall")
        build_index = commands.find("docker build")
        stop_index = commands.find("stop -t 120")
        up_index = commands.find("up -d")
        restore_index = commands.find("pg_restore")
        self.assertLess(dump_index, build_index)
        self.assertLess(build_index, stop_index)
        self.assertLess(stop_index, up_index)
        self.assertLess(up_index, restore_index)

    @patch("engine._open_runtime_session")
    def test_upgrade_dispatches_through_the_runtime_operation(
        self,
        mock_open_runtime_session,
    ):
        # #86: the dispatcher routes the new id to the upgrade runner.
        host = _UpgradeHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }
        result = run_postgres_runtime_operation(
            operation_id="service_upgrade_major",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "secret",
                    "enabled_extensions": [],
                },
            },
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["previous_major"], "16")
        self.assertEqual(result["new_major"], "17")

    def test_upgrade_operation_is_registered_with_enable_settings(self):
        # #86: the upgrade needs the same intent as enable (target
        # version, credentials, extensions).
        operation = OPERATIONS["service_upgrade_major"]
        self.assertEqual(operation["id"], "service_upgrade_major")
        required = operation["params_schema"]["properties"]["settings"]["required"]
        self.assertEqual(
            sorted(required),
            ["enabled_extensions", "postgres_version", "superuser_password"],
        )

    def test_upgrade_plugin_handler_binds_the_operation_id(self):
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
        plugin.handlers["service_upgrade_major"]({})
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["operation_id"], "service_upgrade_major")

    def test_upgrade_dry_run_plans_the_single_action(self):
        result = run_postgres_runtime_operation(
            operation_id="service_upgrade_major",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=True,
            raw_data={
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "secret",
                    "enabled_extensions": [],
                },
            },
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(
            result["actions"],
            ["Upgrade PostgreSQL major version"],
        )
        self.assertEqual(result["selected_version"], "17")

    def test_upgrade_is_a_noop_when_already_on_target(self):
        # #86: same version in, nothing out — and nothing touched.
        host = _UpgradeHost(version="17.5")
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "success")
        self.assertTrue(result["already_on_version"])
        commands = "\n".join(host.commands)
        self.assertNotIn("pg_dump", commands)
        self.assertNotIn("stop -t 120", commands)
        self.assertNotIn("up -d", commands)

    def test_upgrade_refuses_when_version_is_unreadable(self):
        host = _UpgradeHost()
        host.fail_markers = ("SHOW server_version",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("server version", result["msg"])

    def test_upgrade_refuses_when_version_is_unparseable(self):
        host = _UpgradeHost(version="not-a-version")
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("major version", result["msg"])
        self.assertNotIn("pg_dump", "\n".join(host.commands))

    def test_upgrade_refuses_when_service_is_not_ready(self):
        host = _UpgradeHost(ready=False)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("not ready", result["msg"])
        self.assertNotIn("pg_dump", "\n".join(host.commands))

    def test_upgrade_refuses_detached_cluster(self):
        # #86: the registry names dd_test_app but the live cluster lacks
        # it, so the dump would capture the wrong data.
        host = _UpgradeHost(databases=("postgres",))
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("detached", result["msg"])
        self.assertNotIn("pg_dump", "\n".join(host.commands))

    def test_upgrade_refuses_when_disk_cannot_hold_two_copies(self):
        # #86: dumps plus a fresh data copy need twice the data size.
        host = _UpgradeHost(disk_data=1000, disk_avail=1999)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("free disk", result["msg"])
        self.assertNotIn("pg_dump", "\n".join(host.commands))

    def test_upgrade_reports_unmeasurable_disk(self):
        host = _UpgradeHost()
        host.fail_markers = ("data_bytes=",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("disk space", result["msg"])

    def test_upgrade_aborts_untouched_when_dump_fails(self):
        host = _UpgradeHost()
        host.fail_markers = ("pg_dumpall",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("dump", result["msg"])
        commands = "\n".join(host.commands)
        self.assertNotIn("stop -t 120", commands)
        self.assertNotIn("up -d", commands)

    def test_upgrade_aborts_untouched_when_database_dump_fails(self):
        host = _UpgradeHost()
        host.fail_markers = ("pg_dump -Fc",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("dump", result["msg"])
        self.assertNotIn("stop -t 120", "\n".join(host.commands))

    def test_upgrade_aborts_untouched_when_image_build_fails(self):
        host = _UpgradeHost()
        host.fail_markers = ("docker build",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("extension image", result["msg"])
        self.assertNotIn("stop -t 120", "\n".join(host.commands))

    def test_upgrade_aborts_untouched_when_compose_backup_fails(self):
        host = _UpgradeHost()
        host.fail_markers = ("cp -n",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("back up the compose", result["msg"])
        self.assertNotIn("stop -t 120", "\n".join(host.commands))

    def test_upgrade_aborts_when_stop_fails(self):
        host = _UpgradeHost()
        host.fail_markers = ("stop -t 120",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("stop the PostgreSQL", result["msg"])
        self.assertNotIn("up -d", "\n".join(host.commands))

    def test_upgrade_rolls_back_when_volume_create_fails(self):
        host = _UpgradeHost()
        host.fail_markers = ("docker volume create",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("volume", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])
        commands = "\n".join(host.commands)
        self.assertIn(".pre-major-upgrade", commands)
        self.assertIn("up -d", commands)

    def test_upgrade_rolls_back_when_rewrite_fails(self):
        host = _UpgradeHost()
        host.fail_markers = ('cat > "${COMPOSE_FILE}"',)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("compose", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_start_fails(self):
        host = _UpgradeHost()
        host.fail_once_markers = ["up -d"]
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("start PostgreSQL", result["msg"])
        # Only the upgrade's own start fails; the rollback's start is the
        # second up and succeeds.
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_target_is_not_ready(self):
        host = _UpgradeHost(post_up_ready=False)
        with patch("engine.time.sleep", return_value=None):
            result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("did not become ready", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_globals_restore_fails(self):
        host = _UpgradeHost()
        host.fail_markers = ('psql -U "${POSTGRES_USER}" -d postgres < ',)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("globals", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_database_restore_fails(self):
        host = _UpgradeHost()
        host.fail_markers = ("pg_restore",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("restore", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_extensions_fail(self):
        host = _UpgradeHost()
        host.fail_markers = ("CREATE EXTENSION",)
        config = _config(enabled_extensions=["pgcrypto"])
        result = _run_upgrade(host, config=config)
        self.assertEqual(result["status"], "error")
        self.assertIn("extension", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_target_major_mismatches(self):
        # #86: the new container came up but still reports the old major
        # (a stale image, a mis-tag); the data is fine but this is not an
        # upgrade, so roll back rather than declare success.
        host = _UpgradeHost(target_version="16.9")
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("verification failed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_database_inventory_changes(self):
        host = _UpgradeHost(databases_post=("postgres",))
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("verification failed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_row_counts_differ(self):
        host = _UpgradeHost(counts_post=("0|999",))
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("verification failed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_relations_differ(self):
        host = _UpgradeHost(relations_post=("public.t:r", "public.u:r"))
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("verification failed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_extensions_differ(self):
        host = _UpgradeHost(extensions_post=("pgcrypto", "vector"))
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("verification failed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_database_owner_or_acl_differs(self):
        """Reject a restore that reopens PUBLIC access or changes its owner."""
        host = _UpgradeHost(
            database_metadata_post=(
                "owner=deploydash",
                "acl=PUBLIC|deploydash|CONNECT|false",
            ),
        )

        result = _run_upgrade(host)

        self.assertEqual(result["status"], "error")
        self.assertIn("verification failed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_tolerates_existing_roles_in_globals_restore(self):
        # #86: the fresh cluster already has the superuser, so its CREATE
        # ROLE lines fail with "already exists" while every other line
        # applies; that specific noise is tolerated, nothing else.
        host = _UpgradeHost(globals_already_exists=True)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "service_upgrade_major")

    def test_upgrade_has_no_separate_database_create_failure_window(self):
        """Avoid a half-created database between manual create and restore."""
        host = _UpgradeHost()
        host.fail_markers = ("CREATE DATABASE",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "success")
        self.assertNotIn("CREATE DATABASE", "\n".join(host.commands))

    def test_upgrade_aborts_when_dump_dir_cannot_be_created(self):
        host = _UpgradeHost()
        host.fail_markers = ("mkdir -p",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("dump directory", result["msg"])
        self.assertNotIn("pg_dump", "\n".join(host.commands))

    def test_upgrade_aborts_when_database_inventory_fails(self):
        host = _UpgradeHost()
        host.fail_markers = ("FROM pg_database WHERE NOT datistemplate",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("inventory", result["msg"])

    def test_upgrade_aborts_when_role_inventory_fails(self):
        host = _UpgradeHost()
        host.fail_markers = ("FROM pg_roles",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("inventory", result["msg"])

    def test_upgrade_aborts_when_registry_read_fails(self):
        host = _UpgradeHost()
        host.fail_markers = ("FROM deploydash.managed_databases",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("registry", result["msg"])

    def test_upgrade_rolls_back_when_post_verify_queries_fail(self):
        for marker in (
            "SHOW server_version",
            "SHOW data_directory",
            "FROM pg_database WHERE NOT datistemplate",
            "FROM pg_roles",
            "relkind IN (",
            "count(*)",
            "FROM pg_extension",
            "aclexplode",
            "{{json .Mounts}}",
        ):
            with self.subTest(marker=marker):
                host = _UpgradeHost()
                host.fail_after_up_markers = (marker,)
                result = _run_upgrade(host)
                self.assertEqual(result["status"], "error")
                self.assertIn("verification failed", result["msg"])
                self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_aborts_when_mounts_cannot_be_read(self):
        host = _UpgradeHost()
        host.fail_markers = ("{{json .Mounts}}",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("storage layout", result["msg"])

    def test_upgrade_aborts_when_mounts_are_unparseable(self):
        host = _UpgradeHost(mounts_line="not json")
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("storage layout", result["msg"])

    def test_upgrade_aborts_when_data_directory_is_unreadable(self):
        host = _UpgradeHost()
        host.fail_markers = ("SHOW data_directory",)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("data directory", result["msg"])

    def test_upgrade_aborts_when_data_directory_is_empty(self):
        host = _UpgradeHost(datadir_empty=True)
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("data directory", result["msg"])

    def test_upgrade_aborts_when_no_volume_backs_the_data(self):
        host = _UpgradeHost(datadir="/elsewhere")
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("No mounted volume", result["msg"])

    def test_upgrade_rolls_back_when_target_version_is_unparseable(self):
        host = _UpgradeHost(target_version="bogus")
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("verification failed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_post_data_directory_moves(self):
        host = _UpgradeHost(datadir_post="/var/lib/postgresql/data/elsewhere")
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("verification failed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_roles_differ(self):
        host = _UpgradeHost(roles_post=("deploydash",))
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("verification failed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_final_mounts_are_unparseable(self):
        host = _UpgradeHost(mounts_post_line="junk")
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("verification failed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_final_mount_is_anonymous(self):
        host = _UpgradeHost(mounts_post_volume="")
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("verification failed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_rolls_back_when_final_mount_is_unexpected(self):
        host = _UpgradeHost(mounts_post_volume="some_other_volume")
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("verification failed", result["msg"])
        self.assertIn("Rollback succeeded", result["details"])

    def test_upgrade_honours_cancellation_between_phases(self):
        cases = (
            ("relkind IN (", "pg_dump"),
            ("pg_dump -Fc", "docker build"),
            ("docker build", ".pre-major-upgrade"),
            ("pg_restore", "CREATE EXTENSION"),
        )
        for seen_marker, absent_marker in cases:
            with self.subTest(seen_marker=seen_marker):
                host = _UpgradeHost()

                def _cancel_after_marker(
                    _host=host,
                    _marker=seen_marker,
                ):
                    """Cancel once the phase under test has run its marker."""
                    return any(_marker in command for command in _host.commands)

                result = _run_upgrade(host, is_cancelled=_cancel_after_marker)
                self.assertEqual(result["status"], "error")
                self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
                self.assertNotIn(absent_marker, "\n".join(host.commands))

    def test_upgrade_honours_cancellation_before_verify(self):
        host = _UpgradeHost()
        config = _config(enabled_extensions=["pgcrypto"])
        result = _run_upgrade(
            host,
            config=config,
            is_cancelled=lambda: any("CREATE EXTENSION" in command for command in host.commands),
        )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        # The pre-upgrade version probe ran once; the post-restore
        # verification never started.
        version_probes = [command for command in host.commands if "SHOW server_version" in command]
        self.assertEqual(len(version_probes), 1)

    def test_upgrade_moves_a_fresh_cluster_without_databases(self):
        host = _UpgradeHost(databases=(), registry=())
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["upgraded_databases"], [])

    def test_upgrade_succeeds_without_user_tables_to_count(self):
        # #86: a cluster with no user tables skips the row-count pass
        # rather than building an empty counts query.
        host = _UpgradeHost(tables=())
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "success")
        self.assertNotIn("count(*)", "\n".join(host.commands))

    def test_upgrade_aborts_when_snapshot_queries_fail(self):
        for marker in (
            "relkind IN (",
            "relispartition",
            "count(*)",
            "FROM pg_extension",
            "aclexplode",
        ):
            with self.subTest(marker=marker):
                host = _UpgradeHost()
                host.fail_markers = (marker,)
                result = _run_upgrade(host)
                self.assertEqual(result["status"], "error")
                self.assertIn("snapshot", result["msg"])
                self.assertNotIn("pg_dump", "\n".join(host.commands))

    def test_upgrade_compose_retargets_the_data_volume(self):
        # #86: the logical volume name stays postgres_data; only its
        # physical volume changes, so rollback is a compose restore.
        config = _config()
        text = service_configuration._postgres_service_compose_text(
            config, data_volume_name="mydata_pg17"
        )
        self.assertIn("postgres_data:\n    name: mydata_pg17\n", text)
        self.assertIn("postgres_data:/var/lib/postgresql/data\n", text)
        self.assertIn("PGDATA: /var/lib/postgresql/data/pgdata", text)
        self.assertIn("image: deploydash/postgres-ext:17.10-bookworm-base", text)
        default_text = service_configuration._postgres_service_compose_text(config)
        self.assertNotIn("name: mydata_pg17", default_text)

    def test_upgrade_target_volume_name_appends_the_major(self):
        parameters = inspect.signature(
            service_upgrade._postgres_upgrade_target_volume_name,
        ).parameters
        self.assertIn("upgrade_stamp", parameters)
        self.assertEqual(
            service_upgrade._postgres_upgrade_target_volume_name(
                "postgres_postgres_data",
                "17",
                upgrade_stamp="20261002T140000Z",
            ),
            "postgres_postgres_data_pg17_20261002t140000z",
        )

    def test_upgrade_dump_commands_use_the_target_binaries(self):
        config = _config()
        throwaway = service_upgrade._postgres_upgrade_throwaway_prefix(config)
        self.assertIn("postgres:17.10-bookworm", throwaway)
        self.assertIn("--add-host host.docker.internal:host-gateway", throwaway)
        self.assertIn("--cap-drop ALL", throwaway)
        self.assertIn("--security-opt no-new-privileges", throwaway)
        globals_command = service_upgrade._postgres_upgrade_dump_globals_command(
            config, dump_path="/dumps/globals.sql"
        )
        self.assertIn("pg_dumpall --globals-only", globals_command)
        self.assertIn("umask 077", globals_command)
        self.assertIn("/dumps/globals.sql", globals_command)
        database_command = service_upgrade._postgres_upgrade_dump_database_command(
            config, database="dd_test_app", dump_path="/dumps/dd_test_app.dump"
        )
        self.assertIn("pg_dump -Fc", database_command)
        self.assertIn("-d dd_test_app", database_command)
        self.assertIn("umask 077", database_command)

    def test_upgrade_restore_commands_cover_globals_and_databases(self):
        config = _config()
        globals_command = service_upgrade._postgres_upgrade_restore_globals_command(
            config, dump_path="/dumps/globals.sql"
        )
        self.assertIn("docker exec", globals_command)
        self.assertIn("/dumps/globals.sql", globals_command)
        self.assertNotIn("ON_ERROR_STOP", globals_command)
        database_command = service_upgrade._postgres_upgrade_restore_database_command(
            config, database="dd_test_app", dump_path="/dumps/dd_test_app.dump"
        )
        self.assertIn(
            "pg_restore --exit-on-error --clean --create --if-exists",
            database_command,
        )
        self.assertIn("-d template1", database_command)
        self.assertIn("/dumps/dd_test_app.dump", database_command)

    def test_upgrade_delegates_database_creation_to_pg_restore(self):
        """Use PostgreSQL's archive metadata as the owner and ACL authority."""
        host = _UpgradeHost()

        result = _run_upgrade(host)

        self.assertEqual(result["status"], "success")
        commands = "\n".join(host.commands)
        self.assertNotIn('CREATE DATABASE "dd_test_app"', commands)
        self.assertIn(
            "pg_restore --exit-on-error --clean --create --if-exists",
            commands,
        )

    def test_upgrade_verify_queries_cover_shape_and_counts(self):
        relations_sql = service_upgrade._postgres_upgrade_relations_snapshot_sql()
        self.assertIn("pg_class", relations_sql)
        self.assertIn("pg_catalog", relations_sql)
        # relkind is the single-byte "char" type, and text || "char" has no
        # unique operator, so the snapshot must cast before concatenating.
        self.assertIn("c.relkind::text", relations_sql)
        tables_sql = service_upgrade._postgres_upgrade_user_tables_sql()
        self.assertIn("relkind = 'r'", tables_sql)
        self.assertIn("LIMIT", tables_sql)
        self.assertIsNone(
            service_upgrade._postgres_upgrade_row_counts_sql([]),
        )
        counts_sql = service_upgrade._postgres_upgrade_row_counts_sql(
            ['"public"."t"', '"public"."u"']
        )
        self.assertIn("count(*)", counts_sql)
        self.assertIn('"public"."t"', counts_sql)
        self.assertIn("UNION ALL", counts_sql)
        extensions_sql = service_upgrade._postgres_upgrade_extensions_snapshot_sql()
        self.assertIn("FROM pg_extension", extensions_sql)
        database_metadata_sql = service_upgrade._postgres_upgrade_database_metadata_snapshot_sql()
        self.assertIn("pg_database", database_metadata_sql)
        self.assertIn("aclexplode", database_metadata_sql)
        self.assertIn("current_database()", database_metadata_sql)

    def test_upgrade_globals_tolerance_only_forgives_existing_roles(self):
        self.assertTrue(
            service_upgrade._postgres_upgrade_globals_tolerable(
                ['ERROR: role "deploydash" already exists', ""]
            )
        )
        self.assertFalse(
            service_upgrade._postgres_upgrade_globals_tolerable(
                ['ERROR: role "deploydash" already exists', "FATAL: boom"]
            )
        )
        self.assertFalse(service_upgrade._postgres_upgrade_globals_tolerable([]))
        self.assertFalse(service_upgrade._postgres_upgrade_globals_tolerable(None))

    def test_upgrade_ledger_parse_normalizes_entries(self):
        parsed = service_storage._postgres_upgrade_parse_ledger(
            json.dumps(
                {
                    "format_version": 1,
                    "retained_volumes": [
                        {
                            "volume": "old_data",
                            "from_major": "16",
                            "to_major": "17",
                            "upgraded_at": "20260926T084800Z",
                        },
                        "junk",
                        {"volume": ""},
                        {"volume": 42},
                    ],
                }
            )
        )
        self.assertEqual(parsed["format_version"], 1)
        self.assertEqual(
            parsed["retained_volumes"],
            [
                {
                    "volume": "old_data",
                    "from_major": "16",
                    "to_major": "17",
                    "upgraded_at": "20260926T084800Z",
                }
            ],
        )

    def test_upgrade_ledger_parse_defaults_missing_shapes(self):
        for raw in ("", None, "not json", "[1, 2]", '{"format_version": 1}'):
            with self.subTest(raw=raw):
                self.assertEqual(
                    service_storage._postgres_upgrade_parse_ledger(raw),
                    {"format_version": 1, "retained_volumes": []},
                )

    def test_upgrade_ledger_parse_rejects_unknown_versions(self):
        for raw in (
            json.dumps({"retained_volumes": []}),
            json.dumps({"format_version": 2, "retained_volumes": []}),
        ):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                service_storage._postgres_upgrade_parse_ledger(raw)

    def test_upgrade_ledger_encode_is_canonical(self):
        encoded = service_storage._postgres_upgrade_encode_ledger(
            {
                "format_version": 1,
                "retained_volumes": [
                    {"volume": "b_vol"},
                    {"volume": "a_vol"},
                ],
            }
        )
        self.assertEqual(
            encoded,
            '{"format_version":1,"retained_volumes":[{"volume":"b_vol"},{"volume":"a_vol"}]}',
        )

    def test_upgrade_ledger_commands_use_the_state_root(self):
        read_command = service_storage._postgres_upgrade_read_ledger_command()
        self.assertIn("/opt/deploydash/state/postgres-major-upgrades.json", read_command)
        write_command = service_storage._postgres_upgrade_write_ledger_command("{}")
        self.assertIn("/opt/deploydash/state/postgres-major-upgrades.json", write_command)
        self.assertIn("<<'", write_command)

    def test_upgrade_records_the_previous_volume_in_the_ledger(self):
        host = _UpgradeHost(
            ledger_line=json.dumps(
                {
                    "format_version": 1,
                    "retained_volumes": [
                        {"volume": "earlier_volume"},
                    ],
                }
            )
        )
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "success")
        self.assertTrue(result["ledger_recorded"])
        writes = [
            command for command in host.commands if "__DEPLOYDASH_POSTGRES_UPGRADE_EOF__" in command
        ]
        self.assertEqual(len(writes), 1)
        self.assertIn(_LIVE_VOLUME, writes[0])
        self.assertIn("earlier_volume", writes[0])

    def test_upgrade_warns_when_the_ledger_cannot_be_recorded(self):
        for ledger_line, fail_markers in (
            (
                json.dumps({"format_version": 2, "retained_volumes": []}),
                (),
            ),
            (None, ("postgres-major-upgrades.json",)),
            (None, ("__DEPLOYDASH_POSTGRES_UPGRADE_EOF__",)),
        ):
            with self.subTest(ledger_line=ledger_line, fail_markers=fail_markers):
                events = []
                host = _UpgradeHost(
                    ledger_line=ledger_line,
                )
                host.fail_markers = fail_markers
                ctx = _context(
                    emit_event=lambda emit, event, message, _events=events, **kwargs: (
                        _events.append(event)
                    ),
                )
                result = _run_upgrade(host, ctx=ctx)
                # The data moved and verified: bookkeeping trouble warns,
                # it never fails the upgrade.
                self.assertEqual(result["status"], "success")
                self.assertFalse(result["ledger_recorded"])
                self.assertIn("postgres_upgrade_ledger_warning", events)

    def test_removal_deletes_a_ledger_retained_volume(self):
        host = _UpgradeHost(
            ledger_line=json.dumps(
                {
                    "format_version": 1,
                    "retained_volumes": [
                        {"volume": "old_data_pg16"},
                        {"volume": "other_kept"},
                    ],
                }
            )
        )
        result = service_storage.run_postgres_legacy_storage_removal(
            _context(),
            _FakeSession(host),
            _config(legacy_storage_volume="old_data_pg16"),
            emit=None,
            is_cancelled=None,
            operation_id="service_remove_legacy_storage",
        )
        self.assertEqual(result["status"], "success")
        self.assertIn("pre-upgrade", result["msg"])
        self.assertEqual(result["removed_volume"], "old_data_pg16")
        self.assertTrue(result["ledger_updated"])
        writes = [
            command for command in host.commands if "__DEPLOYDASH_POSTGRES_UPGRADE_EOF__" in command
        ]
        self.assertEqual(len(writes), 1)
        self.assertNotIn("old_data_pg16", writes[0])
        self.assertIn("other_kept", writes[0])

    def test_removal_refuses_a_live_ledger_volume(self):
        host = _UpgradeHost(
            ledger_line=json.dumps(
                {
                    "format_version": 1,
                    "retained_volumes": [{"volume": _LIVE_VOLUME}],
                }
            )
        )
        result = service_storage.run_postgres_legacy_storage_removal(
            _context(),
            _FakeSession(host),
            _config(legacy_storage_volume=_LIVE_VOLUME),
            emit=None,
            is_cancelled=None,
            operation_id="service_remove_legacy_storage",
        )
        self.assertEqual(result["status"], "error")
        self.assertIn("still attached", result["msg"])

    def test_removal_fails_closed_on_an_unreadable_ledger(self):
        for ledger_line, fail_markers in (
            ("junk", ()),
            (None, ("postgres-major-upgrades.json",)),
            (json.dumps({"format_version": 2}), ()),
        ):
            with self.subTest(ledger_line=ledger_line, fail_markers=fail_markers):
                host = _UpgradeHost(ledger_line=ledger_line)
                host.fail_markers = fail_markers
                result = service_storage.run_postgres_legacy_storage_removal(
                    _context(),
                    _FakeSession(host),
                    _config(legacy_storage_volume="old_data_pg16"),
                    emit=None,
                    is_cancelled=None,
                    operation_id="service_remove_legacy_storage",
                )
                self.assertEqual(result["status"], "error")
                self.assertNotIn("docker volume rm", "\n".join(host.commands))
                self.assertTrue(
                    "not recorded" in result["msg"] or "Could not verify" in result["msg"]
                )

    def test_removal_warns_when_the_ledger_cannot_be_updated(self):
        events = []
        host = _UpgradeHost(
            ledger_line=json.dumps(
                {
                    "format_version": 1,
                    "retained_volumes": [{"volume": "old_data_pg16"}],
                }
            )
        )
        host.fail_markers = ("__DEPLOYDASH_POSTGRES_UPGRADE_EOF__",)
        ctx = _context(
            emit_event=lambda emit, event, message, **kwargs: events.append(event),
        )
        result = service_storage.run_postgres_legacy_storage_removal(
            ctx,
            _FakeSession(host),
            _config(legacy_storage_volume="old_data_pg16"),
            emit=None,
            is_cancelled=None,
            operation_id="service_remove_legacy_storage",
        )
        # The volume is gone; only the bookkeeping failed.
        self.assertEqual(result["status"], "success")
        self.assertFalse(result["ledger_updated"])
        self.assertIn("postgres_storage_ledger_warning", events)

    def test_status_reports_retained_upgrade_volumes(self):
        host = _UpgradeHost(
            ledger_line=json.dumps(
                {
                    "format_version": 1,
                    "retained_volumes": [
                        {
                            "volume": "old_data",
                            "from_major": "16",
                            "to_major": "17",
                            "upgraded_at": "20260926T084800Z",
                        }
                    ],
                }
            )
        )
        status = service_storage.enrich_postgres_service_status(
            _context(),
            _FakeSession(host),
            _config(),
            emit=None,
            operation_id="service_status",
            base_status={"status": "running"},
        )
        self.assertEqual(
            status["retained_upgrade_volumes"],
            [
                {
                    "volume": "old_data",
                    "from_major": "16",
                    "to_major": "17",
                    "upgraded_at": "20260926T084800Z",
                }
            ],
        )

    def test_status_reports_retained_storage_subpaths(self):
        """Keep the PG18 retained directory reachable by safe desktop cleanup."""
        host = _UpgradeHost(
            ledger_line=json.dumps(
                {
                    "format_version": 1,
                    "retained_volumes": [
                        {
                            "volume": "postgres_postgres_data",
                            "kind": "storage_migration",
                            "subpath": "18/docker",
                            "migrated_at": "20260926T084800Z",
                        }
                    ],
                }
            )
        )
        status = service_storage.enrich_postgres_service_status(
            _context(),
            _FakeSession(host),
            _config(),
            emit=None,
            operation_id="service_status",
            base_status={"status": "running"},
        )
        self.assertEqual(
            status["retained_storage_subpaths"],
            [
                {
                    "volume": "postgres_postgres_data",
                    "subpath": "18/docker",
                }
            ],
        )
        self.assertEqual(status["detached_storage_volumes"], [])
        self.assertEqual(status["retained_upgrade_volumes"], [])

    def test_status_omits_retained_volumes_when_the_ledger_is_unusable(self):
        for ledger_line, fail_markers in (
            (None, ()),
            ("junk", ()),
            (json.dumps({"format_version": 2}), ()),
            (None, ("postgres-major-upgrades.json",)),
        ):
            with self.subTest(ledger_line=ledger_line, fail_markers=fail_markers):
                host = _UpgradeHost(ledger_line=ledger_line)
                host.fail_markers = fail_markers
                status = service_storage.enrich_postgres_service_status(
                    _context(),
                    _FakeSession(host),
                    _config(),
                    emit=None,
                    operation_id="service_status",
                    base_status={"status": "running"},
                )
                self.assertEqual(status["retained_upgrade_volumes"], [])

    def test_upgrade_warns_when_compose_backup_cleanup_fails(self):
        events = []

        def _record_emit(emit, event, message, **kwargs):
            events.append(event)

        host = _UpgradeHost()
        host.fail_after_up_markers = ("rm -f",)
        ctx = _context(emit_event=_record_emit)
        result = _run_upgrade(host, ctx=ctx)
        self.assertEqual(result["status"], "success")
        self.assertFalse(result["compose_backup_removed"])
        self.assertIn("postgres_upgrade_compose_backup_warning", events)

    def test_upgrade_reports_rollback_failure(self):
        # #86: the volume create fails and the rollback's own compose
        # restore fails too; both outcomes are reported, nothing hidden.
        host = _UpgradeHost()
        host.fail_markers = (
            "docker volume create",
            'cp "${BACKUP_FILE}" "${COMPOSE_FILE}"',
        )
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("volume", result["msg"])
        self.assertIn("Rollback failed", result["details"])

    def test_upgrade_honours_cancellation_before_work_starts(self):
        host = _UpgradeHost()
        result = _run_upgrade(host, is_cancelled=lambda: True)
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(host.commands, [])

    def test_upgrade_reports_unparsable_disk_output(self):
        host = _UpgradeHost(disk_data=100, disk_avail="lots")
        result = _run_upgrade(host)
        self.assertEqual(result["status"], "error")
        self.assertIn("disk space", result["msg"])
