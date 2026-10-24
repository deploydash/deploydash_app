import json
import tempfile
import unittest
from unittest.mock import patch

import engine
from engine import handle_request, run_postgres_runtime_operation
from orchestrator.postgres_parts import (
    PostgresConfigValidationError,
    parse_postgres_service_config,
)
from orchestrator.postgres_runtime_parts import database_lifecycle, users_and_grants
from orchestrator.postgres_runtime_parts.service_upgrade import (
    _postgres_container_image_probe_command,
    _postgres_parse_container_image_major,
)


class _RaisingHost:
    def run_shell_command(self, *_args, **_kwargs):
        raise RuntimeError("simulated remote command failure")


class _FakeOutput:
    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


class _ReadinessFailHost:
    def __init__(self):
        self._calls = 0

    def run_shell_command(self, *_args, **_kwargs):
        self._calls += 1
        if self._calls <= 45:
            return False, _FakeOutput()
        return True, _FakeOutput(
            stderr_lines=[
                "PostgreSQL readiness diagnostics: running=false, health=unknown",
                "docker logs: FATAL data directory permissions are invalid",
            ],
        )


class _ProjectListHost:
    def __init__(
        self,
        service_status_line=None,
        roles_stdout_lines=None,
        fail_markers=(),
        live_database_lines=None,
    ):
        self.commands = []
        self.service_status_line = service_status_line or (
            '{"running":true,"health":"healthy","version":"17.8","configured":true}'
        )
        self.roles_stdout_lines = (
            list(roles_stdout_lines) if roles_stdout_lines is not None else ["[]"]
        )
        self.fail_markers = tuple(fail_markers)
        self.live_database_lines = (
            list(live_database_lines) if live_database_lines is not None else ["dd_test_app"]
        )

    def run_shell_command(self, command, *_args, **_kwargs):
        self.commands.append(command)
        if any(marker in command for marker in self.fail_markers):
            return False, _FakeOutput(stderr_lines=["injected list failure"])
        if "CONFIGURED='false'" in command and "SHOW server_version" in command:
            return True, _FakeOutput(
                stdout_lines=[self.service_status_line],
            )
        if "SELECT project_slug FROM deploydash.managed_" in command:
            # Every name these tests use is registered to their project,
            # "test", so flows pass the ownership gate (#127).
            return True, _FakeOutput(stdout_lines=["test"])
        if "FROM pg_database WHERE NOT datistemplate" in command:
            return True, _FakeOutput(stdout_lines=self.live_database_lines)
        if "FROM deploydash.managed_databases" in command:
            return True, _FakeOutput(stdout_lines=["dd_test_app"])
        if "FROM deploydash.managed_roles" in command:
            return True, _FakeOutput(stdout_lines=list(self.roles_stdout_lines))
        if "current_setting('server_version')" in command:
            return True, _FakeOutput(stdout_lines=["17.8"])
        return True, _FakeOutput(stdout_lines=[])


class _CapturingHost:
    def __init__(self, fail_markers=(), stdout_by_marker=None):
        self.commands = []
        self.fail_markers = tuple(fail_markers)
        self.stdout_by_marker = dict(stdout_by_marker or {})

    def run_shell_command(self, command, *_args, **_kwargs):
        self.commands.append(command)
        if "SELECT project_slug FROM deploydash.managed_" in command:
            # Every name these tests use is registered to their project,
            # "test", so flows pass the ownership gate (#127).
            return True, _FakeOutput(stdout_lines=["test"])
        if any(marker in command for marker in self.fail_markers):
            return False, _FakeOutput(
                stderr_lines=["database is being accessed by other users"],
            )
        for marker, lines in self.stdout_by_marker.items():
            if marker in command:
                return True, _FakeOutput(stdout_lines=list(lines))
        return True, _FakeOutput(stdout_lines=[])


class _MajorGuardHost:
    """Scripts the container-image probe for the #86 configure guard."""

    def __init__(self, image_line=None, mounts_line="[]"):
        self.commands = []
        self.image_line = image_line
        self.mounts_line = mounts_line

    def run_shell_command(self, command, *_args, **_kwargs):
        self.commands.append(command)
        if ".Config.Image" in command:
            if self.image_line is None:
                return False, _FakeOutput(
                    stderr_lines=["Error: No such container"],
                )
            return True, _FakeOutput(stdout_lines=[self.image_line])
        if "{{json .Mounts}}" in command:
            if self.image_line is None:
                return False, _FakeOutput(
                    stderr_lines=["Error: No such container"],
                )
            return True, _FakeOutput(stdout_lines=[self.mounts_line])
        return True, _FakeOutput(stdout_lines=[])


class _ReaderReadyHost(_ProjectListHost):
    def run_shell_command(self, command, *_args, **_kwargs):
        if "SELECT 1 FROM pg_database WHERE datname =" in command:
            self.commands.append(command)
            return True, _FakeOutput(stdout_lines=["1"])
        return super().run_shell_command(command, *_args, **_kwargs)


class _FakeSession:
    def __init__(self, host):
        self.host = host

    def close(self):
        return {"disconnect_error": None}


class TestPostgresWorkflow(unittest.TestCase):
    def test_readiness_probe_uses_container_health(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                },
            }
        )
        command = engine._postgres_readiness_probe_command(config)
        self.assertIn(".State.Health", command)
        self.assertNotIn("pg_isready -d postgres", command)

    def test_service_compose_mounts_named_volume_at_data_dir_on_every_major(self):
        # #85: the 16/17 images declare VOLUME /var/lib/postgresql/data, so
        # the old parent mount hid the real data in an anonymous volume that
        # a plain `down` detaches. Every major now mounts postgres_data at
        # /var/lib/postgresql/data with PGDATA in a pgdata subdirectory.
        for version in ("16", "17", "18"):
            with self.subTest(postgres_version=version):
                config = parse_postgres_service_config(
                    {
                        "settings": {
                            "postgres_version": version,
                            "superuser_password": "test-superuser-password",
                        },
                    }
                )
                compose_text = engine._postgres_service_compose_text(config)
                self.assertIn("volumes:\n  postgres_data:\n", compose_text)
                self.assertIn(
                    "postgres_data:/var/lib/postgresql/data\n",
                    compose_text,
                )
                self.assertNotIn(
                    "postgres_data:/var/lib/postgresql\n",
                    compose_text,
                )
                self.assertIn(
                    "PGDATA: /var/lib/postgresql/data/pgdata",
                    compose_text,
                )

    def test_service_compose_uses_entrypoint_compatible_runtime_guard(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                },
            }
        )
        compose_text = engine._postgres_service_compose_text(config)
        self.assertNotIn("security_opt:", compose_text)
        self.assertNotIn("cap_drop:", compose_text)
        self.assertIn("pids_limit: 512", compose_text)
        self.assertNotIn("cap_add:", compose_text)

    def test_service_compose_enables_shared_preload_for_pg_stat_statements(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["pg_stat_statements", "pg_search"],
                },
            }
        )
        compose_text = engine._postgres_service_compose_text(config)
        self.assertIn("command:", compose_text)
        self.assertIn(
            "shared_preload_libraries=pg_stat_statements,pg_search",
            compose_text,
        )

    def test_service_compose_uses_custom_image_when_vector_selected(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["vector"],
                },
            }
        )
        compose_text = engine._postgres_service_compose_text(config)
        self.assertIn(
            "image: deploydash/postgres-ext:17.10-bookworm-vector",
            compose_text,
        )

    def test_extension_image_build_command_builds_base_image_without_extensions(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["pgcrypto"],
                },
            }
        )
        command = engine._postgres_extension_image_build_command(config)
        self.assertIn("deploydash/postgres-ext:17.10-bookworm-base", command)
        self.assertIn("ARG BASE_IMAGE", command)
        self.assertIn('--build-arg BASE_IMAGE="${BASE_IMAGE}"', command)
        self.assertNotIn("api.github.com/repos/wal-g", command)
        self.assertIn(
            "github.com/wal-g/wal-g/releases/download/v3.0.8/${WALG_ASSET}",
            command,
        )
        self.assertIn("wal-g-pg-22.04-amd64.tar.gz", command)
        self.assertIn("wal-g-pg-22.04-aarch64.tar.gz", command)
        self.assertIn("sha256sum -c -", command)
        self.assertNotIn("wal-g-pg-20.04", command)
        self.assertNotIn("wal-g-pg-24.04", command)
        self.assertNotIn("postgresql-${PG_MAJOR}-postgis-3", command)
        self.assertNotIn("postgresql-server-dev-${PG_MAJOR}", command)
        self.assertNotIn("pgvector", command)

    def test_extension_image_build_command_builds_for_postgis_or_vector(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "18",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["vector", "postgis"],
                },
            }
        )
        command = engine._postgres_extension_image_build_command(config)
        self.assertIn("deploydash/postgres-ext:18.4-bookworm-vector-postgis", command)
        self.assertIn("postgres:18.4-bookworm", command)
        self.assertIn("docker build --pull", command)
        self.assertIn("ARG BASE_IMAGE", command)
        self.assertIn("ARG PG_MAJOR", command)
        self.assertIn('--build-arg BASE_IMAGE="${BASE_IMAGE}"', command)
        self.assertIn('--build-arg PG_MAJOR="${PG_MAJOR}"', command)
        self.assertIn("pgvector", command)
        self.assertIn("778dacf20c07caf904557a88705142631818d8cb", command)
        self.assertIn("rev-parse HEAD", command)
        self.assertIn("postgis-3", command)

    def test_custom_image_tag_uses_extension_variant(self):
        base = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "18",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["pgcrypto"],
                },
            }
        )
        vector_only = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "18",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["vector"],
                },
            }
        )
        pg_search_only = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "18",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["pg_search"],
                },
            }
        )
        postgis_only = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "18",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["postgis"],
                },
            }
        )
        both = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "18",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["vector", "postgis"],
                },
            }
        )
        vector_and_pg_search = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "18",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["vector", "pg_search"],
                },
            }
        )
        postgres_16 = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "16",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["pgcrypto"],
                },
            }
        )
        self.assertEqual(
            engine._postgres_runtime_image_name(postgres_16),
            "deploydash/postgres-ext:16.14-bookworm-base",
        )
        self.assertEqual(
            engine._postgres_runtime_image_name(base),
            "deploydash/postgres-ext:18.4-bookworm-base",
        )
        self.assertEqual(
            engine._postgres_runtime_image_name(vector_only),
            "deploydash/postgres-ext:18.4-bookworm-vector",
        )
        self.assertEqual(
            engine._postgres_runtime_image_name(pg_search_only),
            "deploydash/postgres-ext:18.4-bookworm-pg-search",
        )
        self.assertEqual(
            engine._postgres_runtime_image_name(postgis_only),
            "deploydash/postgres-ext:18.4-bookworm-postgis",
        )
        self.assertEqual(
            engine._postgres_runtime_image_name(both),
            "deploydash/postgres-ext:18.4-bookworm-vector-postgis",
        )
        self.assertEqual(
            engine._postgres_runtime_image_name(vector_and_pg_search),
            "deploydash/postgres-ext:18.4-bookworm-vector-pg-search",
        )

    def test_extension_image_build_command_pg_search_installs_paradedb_package(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["pg_search"],
                },
            }
        )
        command = engine._postgres_extension_image_build_command(config)
        self.assertIn("deploydash/postgres-ext:17.10-bookworm-pg-search", command)
        self.assertIn(
            "https://github.com/paradedb/paradedb/releases/download/v0.22.6/",
            command,
        )
        self.assertIn("postgresql-17-pg-search_0.22.6-1PARADEDB-bookworm_amd64.deb", command)
        self.assertIn("postgresql-17-pg-search_0.22.6-1PARADEDB-bookworm_arm64.deb", command)
        self.assertIn("9852f3fdee9e387d5da47c6d745bc8d6b6dd4cd3ea9dac9858c6a5f9c18eea93", command)
        self.assertIn("12528247efdd62b0365bebf1469de90c15a1a87da93f920559a270f255740fc4", command)
        self.assertIn("pg_search checksum verification failed", command)
        self.assertIn("apt-get install -y --no-install-recommends", command)
        self.assertIn("pg_search.deb", command)

    def test_extension_image_build_command_vector_only_skips_postgis_packages(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "18",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["vector"],
                },
            }
        )
        command = engine._postgres_extension_image_build_command(config)
        self.assertIn("postgresql-server-dev-${PG_MAJOR}", command)
        self.assertIn("pgvector", command)
        self.assertNotIn("postgresql-${PG_MAJOR}-postgis-3", command)

    def test_extension_image_build_command_postgis_only_skips_pgvector_build(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "18",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["postgis"],
                },
            }
        )
        command = engine._postgres_extension_image_build_command(config)
        self.assertIn("postgresql-${PG_MAJOR}-postgis-3", command)
        self.assertNotIn("pgvector", command)
        self.assertNotIn("postgresql-server-dev-${PG_MAJOR}", command)

    def test_apply_extensions_command_discovers_databases_without_escaped_quotes(self):
        # superuser_name is server-owned (T-1.4.4) and was set here to its
        # own default value anyway; omitted rather than sent.
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": ["vector", "pg_search"],
                },
            }
        )
        command = engine._postgres_apply_extensions_command(config)
        self.assertIn(
            'ADDITIONAL_DATABASES="$(docker exec -e '
            'PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}"',
            command,
        )
        self.assertIn('DATABASES="template1 postgres ${ADDITIONAL_DATABASES}"', command)
        self.assertIn('docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1', command)
        self.assertNotIn('\\"${CONTAINER_NAME}\\"', command)

    def test_bootstrap_command_terminates_compose_heredoc_on_own_line(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                },
            }
        )
        command = engine._postgres_base_env_bootstrap_command(config)
        self.assertIn('cat > "${COMPOSE_FILE}" <<', command)
        self.assertIn("\nEOF\n", command)
        self.assertNotIn("EOF;", command)

    def test_sync_superuser_command_uses_configured_superuser_login(self):
        # superuser_name is server-owned (T-1.4.4) and was set here to its
        # own default value anyway; omitted rather than sent.
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                },
            }
        )
        command = engine._postgres_sync_superuser_command(config)
        self.assertIn("SUPERUSER_NAME=deploydash;", command)
        self.assertIn('-U "${SUPERUSER_NAME}" -d postgres', command)
        self.assertNotIn("-U postgres -d postgres", command)

    def test_readiness_failure_returns_diagnostics_details(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                },
            }
        )
        with patch("engine.time.sleep", return_value=None):
            error = engine._wait_for_postgres_readiness(
                _FakeSession(_ReadinessFailHost()),
                config,
                operation_id="service_enable",
            )

        self.assertIsNotNone(error)
        self.assertEqual(error["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("readiness diagnostics", error["details"])
        self.assertIn("permissions are invalid", error["details"])

    def test_describe_postgres_plan(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "postgres",
                "operation_id": "describe",
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["workflow_id"], "postgres")
        self.assertEqual(result["operation_id"], "describe")
        self.assertEqual(result["supported_versions"], ["16", "17", "18"])
        self.assertIn("pgcrypto", result["supported_extensions"])
        self.assertIn("pg_trgm", result["supported_extensions"])
        self.assertIn("vector", result["supported_extensions"])
        self.assertIn("pg_search", result["supported_extensions"])
        self.assertIn("postgis", result["supported_extensions"])
        self.assertIn("pg_session_jwt", result["unsupported_extensions"])
        self.assertEqual(
            result["resolved_config"],
            {
                "stack_root": "/opt/deploydash/stack/postgres",
                "container_name": "deploydash_postgres",
                "host_port": 5432,
                "superuser_name": "deploydash",
            },
        )

    def test_service_enable_dry_run(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "postgres",
                "operation_id": "service_enable",
                "connection": {
                    "ip": "198.51.100.8",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {
                        "postgres_version": "18",
                        "superuser_password": "secret",
                        "enabled_extensions": [],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "service_enable")
        self.assertEqual(result["selected_version"], "18")
        self.assertEqual(
            result["resolved_config"],
            {
                "stack_root": "/opt/deploydash/stack/postgres",
                "container_name": "deploydash_postgres",
                "host_port": 5432,
                "superuser_name": "deploydash",
            },
        )

    def test_service_delete_dry_run(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "postgres",
                "operation_id": "service_delete",
                "connection": {
                    "ip": "198.51.100.8",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {
                        "postgres_version": "17",
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "service_delete")

    # Service deletion must own every managed scheduler remnant, not only the
    # stack directory whose scripts those schedulers invoke (#90).
    @patch("engine._open_runtime_session")
    def test_service_delete_removes_and_reports_all_backup_policies(
        self,
        mock_open_runtime_session,
    ):
        host = _CapturingHost(
            stdout_by_marker={
                "TOKENS_FILE": ["removed_backup_policy=daily-main"],
            },
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        result = run_postgres_runtime_operation(
            operation_id="service_delete",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={"settings": {"postgres_version": "17"}},
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["removed_backup_policies"], ["daily-main"])
        self.assertEqual(result["removed_backup_policy_count"], 1)
        self.assertTrue(result["backup_logs_removed"])
        cleanup_command = next(command for command in host.commands if "TOKENS_FILE" in command)
        self.assertIn("/etc/cron.d/deploydash-postgres-backup-", cleanup_command)
        self.assertIn('"${CRON_PREFIX}"*', cleanup_command)
        self.assertIn("/var/log/deploydash/postgres-backup-", cleanup_command)
        self.assertIn('"${LOG_PREFIX}"*"${LOG_SUFFIX}"', cleanup_command)

    # A failed scheduler cleanup must stop service deletion before the stack
    # disappears and preserve the remote diagnostic (#90).
    @patch("engine._open_runtime_session")
    def test_service_delete_reports_backup_policy_cleanup_failure(
        self,
        mock_open_runtime_session,
    ):
        host = _CapturingHost(fail_markers=("TOKENS_FILE",))
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        result = run_postgres_runtime_operation(
            operation_id="service_delete",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={"settings": {"postgres_version": "17"}},
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["action"], "Delete PostgreSQL backup policies")
        self.assertIn("database is being accessed", result["details"])
        self.assertFalse(any("docker rm -f" in command for command in host.commands))

    def test_service_enable_rejects_unsupported_extension(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "postgres",
                "operation_id": "service_enable",
                "connection": {
                    "ip": "198.51.100.8",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {
                        "postgres_version": "17",
                        "superuser_password": "secret",
                        "enabled_extensions": ["pg_session_jwt"],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("not currently supported", result["msg"])
        self.assertIn("pg_session_jwt", result["msg"])

    def test_project_list_requires_project_slug(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "postgres",
                "operation_id": "project_list",
                "connection": {
                    "ip": "198.51.100.8",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {},
                },
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("project_slug", result["msg"])

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_dry_run(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            if "FROM deploydash.managed_databases" in sql_text:
                return True, _FakeOutput(stdout_lines=["dd_test_app"])
            if "FROM deploydash.managed_roles" in sql_text:
                return True, _FakeOutput(stdout_lines=["dd_test_app_user"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=True,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "project_delete")
        self.assertEqual(result["project_slug"], "test")
        self.assertEqual(result["databases"], ["dd_test_app"])
        self.assertEqual(result["users"], ["dd_test_app_user"])

    def test_backup_policy_apply_dry_run(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "postgres",
                "operation_id": "backup_policy_apply",
                "connection": {
                    "ip": "198.51.100.8",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {
                        "project_slug": "test",
                        "backup_policy_id": "daily-main",
                        "backup_task_id": "backup-pg-daily-main",
                        "backup_policy_name": "Daily Main",
                        "backup_database_name": "app",
                        "backup_destination_type": "filesystem",
                        "backup_file_prefix": "/var/backups/deploydash",
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "backup_policy_apply")
        self.assertEqual(result["backup_policy_id"], "daily-main")
        self.assertEqual(result["backup_task_id"], "backup-pg-daily-main")
        self.assertEqual(result["backup_destination_type"], "filesystem")

    def test_backup_policy_delete_dry_run_requires_only_policy_id(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "postgres",
                "operation_id": "backup_policy_delete",
                "connection": {
                    "ip": "198.51.100.8",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {
                        "project_slug": "test",
                        "backup_policy_id": "daily-main",
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "backup_policy_delete")
        self.assertEqual(result["backup_policy_id"], "daily-main")

    # Policy cleanup must reject a missing identity before running any remote
    # command, so an empty request can never broaden into service cleanup.
    @patch("engine._open_runtime_session")
    def test_backup_policy_delete_rejects_missing_policy_id(
        self,
        mock_open_runtime_session,
    ):
        host = _CapturingHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        result = engine.run_postgres_project_operation(
            operation_id="backup_policy_delete",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
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
        self.assertEqual(host.commands, [])

    # A host-side policy cleanup failure must preserve its diagnostic and
    # return an error instead of claiming the schedule disappeared (#90).
    @patch("engine._open_runtime_session")
    def test_backup_policy_delete_reports_cleanup_failure(
        self,
        mock_open_runtime_session,
    ):
        host = _CapturingHost(
            fail_markers=("deploydash-postgres-backup-daily-main",),
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        result = engine.run_postgres_project_operation(
            operation_id="backup_policy_delete",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "postgres_version": "17",
                    "superuser_password": "secret",
                    "backup_policy_id": "daily-main",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not delete backup policy.")
        self.assertIn("database is being accessed", result["details"])

    def test_restore_run_now_dry_run(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "postgres",
                "operation_id": "restore_run_now",
                "connection": {
                    "ip": "198.51.100.8",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {
                        "project_slug": "test",
                        "backup_destination_type": "filesystem",
                        "backup_file_prefix": "/var/backups/deploydash",
                        "backup_artifact_path": "deploydash/postgres/test/daily-main/sample.dump",
                        "backup_target_database_name": "restore_target",
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "restore_run_now")
        self.assertEqual(result["backup_destination_type"], "filesystem")
        self.assertEqual(result["database_name"], "restore_target")
        self.assertEqual(
            result["restore_target_database_name"],
            "dd_test_restore_target",
        )

    def test_import_local_sql_dry_run(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            payload = json.dumps(
                {
                    "action": "run_workflow",
                    "workflow_id": "postgres",
                    "operation_id": "import_local_sql",
                    "connection": {
                        "ip": "198.51.100.8",
                        "port": 22,
                        "username": "ubuntu",
                        "password": "secret",
                    },
                    "params": {
                        "dry_run": True,
                        "settings": {
                            "project_slug": "test",
                            "database_name": "restore_target",
                            "import_local_file_path": handle.name,
                        },
                    },
                }
            )
            result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "import_local_sql")
        self.assertEqual(result["database_name"], "restore_target")
        self.assertEqual(result["remote_database_name"], "dd_test_restore_target")
        self.assertEqual(result["target_database_name"], "dd_test_restore_target")
        self.assertEqual(result["import_local_file_path"], handle.name)

    @patch("engine._open_runtime_session")
    def test_runtime_operation_returns_error_when_command_raises(
        self,
        mock_open_runtime_session,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_RaisingHost()),
        }
        result = run_postgres_runtime_operation(
            operation_id="service_enable",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                },
            },
        )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertTrue(
            "Build PostgreSQL extension image" in result["msg"]
            or "Prepare PostgreSQL service" in result["msg"],
        )
        self.assertIn("simulated remote command failure", result["details"])

    @patch(
        "engine.run_postgres_runtime_operation",
        side_effect=AssertionError("nested runtime status call should not run"),
    )
    @patch("engine._open_runtime_session")
    def test_project_list_uses_same_session_for_service_status(
        self,
        mock_open_runtime_session,
        _mock_runtime_status,
    ):
        host = _ProjectListHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }
        result = engine.run_postgres_project_operation(
            operation_id="project_list",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                },
            },
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "project_list")
        self.assertEqual(result["service_status"]["running"], True)
        self.assertTrue(
            any(
                "CONFIGURED='false'" in command and "SHOW server_version" in command
                for command in host.commands
            ),
        )

    @patch("engine._open_runtime_session")
    def test_project_list_does_not_query_databases_until_service_is_ready(
        self,
        mock_open_runtime_session,
    ):
        host = _ProjectListHost(
            service_status_line=(
                '{"running":true,"health":"unhealthy","version":"17.8","configured":true}'
            ),
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }
        result = engine.run_postgres_project_operation(
            operation_id="project_list",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["msg"], "Database service is not ready.")
        self.assertEqual(result["databases"], [])
        self.assertEqual(result["users"], [])
        self.assertEqual(
            result["service_status"]["container_status"]["effective_status"],
            "unhealthy",
        )
        self.assertFalse(
            any("deploydash.managed_databases" in command for command in host.commands)
        )
        self.assertFalse(any("deploydash.managed_roles" in command for command in host.commands))

    @patch("engine._open_runtime_session")
    def test_project_list_surfaces_detached_storage_before_listing_resources(
        self,
        mock_open_runtime_session,
    ):
        """Project inventory must not report ready when expected data vanished."""
        host = _ProjectListHost(live_database_lines=[])
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        result = engine.run_postgres_project_operation(
            operation_id="project_list",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                    "expected_databases": ["dd_test_app"],
                },
            },
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["msg"], "Database service is not ready.")
        self.assertEqual(result["databases"], [])
        self.assertEqual(result["users"], [])
        self.assertEqual(
            result["service_status"]["missing_expected_databases"],
            ["dd_test_app"],
        )
        self.assertIn("data volume may be detached", result["service_status"]["storage_error"])
        self.assertEqual(
            result["service_status"]["container_status"]["effective_status"],
            "unhealthy",
        )
        self.assertFalse(
            any("WHERE project_slug" in command for command in host.commands),
            "detached storage must stop the project-scoped resource listing",
        )

    @patch("engine._open_runtime_session")
    def test_project_create_user_wraps_role_and_grants_in_transactions(
        self,
        mock_open_runtime_session,
    ):
        host = _CapturingHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }
        result = engine.run_postgres_project_operation(
            operation_id="project_create_user",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "superuser_password": "test-superuser-password",
                },
            },
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["database_name"], "app")
        self.assertEqual(result["remote_database_name"], "dd_test_app")
        self.assertEqual(result["username"], "app_user")
        self.assertEqual(result["remote_username"], "dd_test_app_user")
        self.assertTrue(result["connection_uri"].startswith("postgresql://dd_test_app_user:"))
        self.assertTrue(result["connection_uri"].endswith("@host.docker.internal:5432/dd_test_app"))
        all_commands = "\n".join(host.commands)
        self.assertIn("BEGIN;", all_commands)
        self.assertIn("COMMIT;", all_commands)

    @patch("engine._open_runtime_session")
    def test_agent_tools_connect_as_the_reader_role_not_the_superuser(
        self,
        mock_open_runtime_session,
    ):
        # #83: every agent-reachable Postgres tool logs in as the
        # per-database reader role over the trusted socket, with no
        # password sent. The superuser never sees agent SQL. The fake host
        # answers empty result sets, so describe-table reports its table
        # missing; its probe command is still generated and asserted.
        host = _ReaderReadyHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }
        reader_name = "deploydash_agent_reader_dd_test_app_770b1081f7ad"
        cases = (
            ("project_list_schemas", {"database_name": "app"}, "sort_order"),
            ("project_list_tables", {"database_name": "app"}, "c.relname"),
            (
                "project_describe_table",
                {"database_name": "app", "table_name": "widgets"},
                "SELECT c.relkind",
            ),
            (
                "project_explain_readonly_query",
                {"database_name": "app", "sql": "SELECT 1"},
                "EXPLAIN (FORMAT JSON",
            ),
            (
                "project_execute_readonly_query",
                {"database_name": "app", "sql": "SELECT 1"},
                "deploydash_query",
            ),
        )
        for operation_id, extra_settings, needle in cases:
            with self.subTest(operation_id=operation_id):
                host.commands.clear()
                settings = {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                }
                settings.update(extra_settings)
                engine.run_postgres_project_operation(
                    operation_id=operation_id,
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    dry_run=False,
                    raw_data={"settings": settings},
                )
                tool_commands = [command for command in host.commands if needle in command]
                self.assertTrue(tool_commands)
                for command in tool_commands:
                    # The readiness probe in the shared prefix still uses the
                    # superuser; the requirement is the psql query login.
                    self.assertIn(f"psql -v ON_ERROR_STOP=1 -U {reader_name}", command)
                    self.assertNotIn('psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}"', command)
                    self.assertNotIn("-e PGPASSWORD", command)

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_user_read_write_grants_membership_without_ownership_transfer(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        # #81: this test used to assert the ownership theft (the new user
        # becoming owner of the database, schema, tables and sequences),
        # which broke the earlier app's migrations. Creating a user now
        # grants membership in the stable owner role and moves no ownership.
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        executed_sql = []

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            executed_sql.append(str(sql))
            if "SELECT project_slug FROM" in str(sql):
                # Ownership probe: the names under test are unregistered.
                return True, _FakeOutput(stdout_lines=[])
            return True, _FakeOutput(stdout_lines=["1"])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_user",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "access_mode": "read_write",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        owner_name = "deploydash_owner_dd_test_app_770b1081f7ad"
        self.assertEqual(result["status"], "success")
        grant_sql = "\n".join(executed_sql)
        self.assertNotIn('OWNER TO "dd_test_app_user"', grant_sql)
        self.assertNotIn("OWNER TO %I', obj.schema_name", grant_sql)
        self.assertIn(
            f'GRANT "{owner_name}" TO "dd_test_app_user";',
            grant_sql,
        )
        self.assertIn(
            f'ALTER ROLE "dd_test_app_user" IN DATABASE "dd_test_app" SET role = "{owner_name}";',
            grant_sql,
        )
        self.assertIn(
            f'GRANT USAGE, CREATE ON SCHEMA public TO "{owner_name}";',
            grant_sql,
        )
        self.assertIn(
            "GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER "
            'ON ALL TABLES IN SCHEMA public TO "dd_test_app_user";',
            grant_sql,
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_user_read_only_reclaims_ddl_ownership(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        executed_sql = []

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            executed_sql.append(str(sql))
            if "SELECT project_slug FROM" in str(sql):
                # Ownership probe: the names under test are unregistered.
                return True, _FakeOutput(stdout_lines=[])
            return True, _FakeOutput(stdout_lines=["1"])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_user",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "reporting_user",
                    "access_mode": "read_only",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        owner_name = "deploydash_owner_dd_test_app_770b1081f7ad"
        self.assertEqual(result["status"], "success")
        grant_sql = "\n".join(executed_sql)
        self.assertIn('ALTER DATABASE "dd_test_app" OWNER TO CURRENT_USER;', grant_sql)
        self.assertIn("ALTER SCHEMA public OWNER TO CURRENT_USER;", grant_sql)
        self.assertIn("JOIN pg_roles r ON r.oid = c.relowner", grant_sql)
        self.assertIn("AND d.deptype IN ('a', 'i')", grant_sql)
        self.assertIn("REVOKE CREATE ON SCHEMA public", grant_sql)
        # #81: future-object grants are scoped FOR ROLE to the owner, which
        # is the role that creates objects. A bare ALTER DEFAULT PRIVILEGES
        # would only cover objects the superuser creates.
        self.assertIn(
            f'ALTER DEFAULT PRIVILEGES FOR ROLE "{owner_name}" '
            "IN SCHEMA public GRANT SELECT ON TABLES "
            'TO "dd_test_reporting_user";',
            grant_sql,
        )
        self.assertIn(
            f'ALTER DEFAULT PRIVILEGES FOR ROLE "{owner_name}" '
            "IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES "
            'TO "dd_test_reporting_user";',
            grant_sql,
        )
        self.assertNotIn(
            "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES "
            'TO "dd_test_reporting_user";',
            grant_sql,
        )
        self.assertIn(
            "VALUES ('dd_test_reporting_user', 'test', 'dd_test_app', 'read_only', 'readonly')",
            grant_sql,
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_provisions_owner_before_granting_membership(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        # #81: the membership GRANT names the owner role, so PostgreSQL
        # rejects it when the owner does not exist yet. The ensure must
        # execute before the user-creation statement that carries the GRANT.
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        executed_sql = []

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            executed_sql.append(str(sql))
            sql_text = str(sql)
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "access_mode": "read_write",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        owner_name = "deploydash_owner_dd_test_app_770b1081f7ad"
        self.assertEqual(result["status"], "success")
        ensure_step = next(
            index
            for index, sql in enumerate(executed_sql)
            if f'CREATE ROLE "{owner_name}" NOLOGIN;' in sql
        )
        membership_step = next(
            index
            for index, sql in enumerate(executed_sql)
            if f'GRANT "{owner_name}" TO "dd_test_app_user";' in sql
        )
        self.assertLess(ensure_step, membership_step)

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_provisions_owner_role_and_membership(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        executed_sql = []

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            executed_sql.append(str(sql))
            sql_text = str(sql)
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "access_mode": "read_write",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        owner_name = "deploydash_owner_dd_test_app_770b1081f7ad"
        self.assertEqual(result["status"], "success")
        all_sql = "\n".join(executed_sql)
        self.assertIn(f'CREATE ROLE "{owner_name}" NOLOGIN;', all_sql)
        self.assertIn(
            f'ALTER DATABASE "dd_test_app" OWNER TO "{owner_name}";',
            all_sql,
        )
        self.assertIn(
            f'ALTER SCHEMA public OWNER TO "{owner_name}";',
            all_sql,
        )
        self.assertIn(
            f'GRANT "{owner_name}" TO "dd_test_app_user";',
            all_sql,
        )
        self.assertIn(
            f'ALTER ROLE "dd_test_app_user" IN DATABASE "dd_test_app" SET role = "{owner_name}";',
            all_sql,
        )
        self.assertIn(
            f"VALUES ('{owner_name}', 'test', 'dd_test_app', 'owner', 'owner')",
            all_sql,
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_provisions_agent_reader_with_limits_and_grants(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        executed_sql = []

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            executed_sql.append(str(sql))
            sql_text = str(sql)
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "access_mode": "read_write",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        owner_name = "deploydash_owner_dd_test_app_770b1081f7ad"
        reader_name = "deploydash_agent_reader_dd_test_app_770b1081f7ad"
        self.assertEqual(result["status"], "success")
        all_sql = "\n".join(executed_sql)
        self.assertIn(f'CREATE ROLE "{reader_name}" LOGIN CONNECTION LIMIT 2;', all_sql)
        self.assertIn("SET default_transaction_read_only = on;", all_sql)
        self.assertIn(
            f'GRANT CONNECT ON DATABASE "dd_test_app" TO "{reader_name}";',
            all_sql,
        )
        self.assertIn(
            f'ALTER DEFAULT PRIVILEGES FOR ROLE "{owner_name}" '
            f'IN SCHEMA public GRANT SELECT ON TABLES TO "{reader_name}";',
            all_sql,
        )
        self.assertIn(
            f"VALUES ('{reader_name}', 'test', 'dd_test_app', 'read_only', 'agent_reader')",
            all_sql,
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_reports_agent_reader_provisioning_failure(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        host = _CapturingHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            # The CONNECTION LIMIT match comes first: the ensure statement
            # embeds the same role-existence probe the checks below match on.
            if "CONNECTION LIMIT" in sql_text:
                return False, _FakeOutput(stderr_lines=["reader ensure failure"])
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not provision agent reader role.", result["msg"])
        all_commands = "\n".join(host.commands)
        self.assertIn("createdb -U", all_commands)
        self.assertIn("dropdb -U", all_commands)
        self.assertIn('dropdb -U "${POSTGRES_USER}" --force --if-exists', all_commands)
        self.assertTrue(
            any(
                "DROP ROLE IF EXISTS" in str(call.args[3])
                for call in mock_run_postgres_psql_query.call_args_list
            )
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_reports_agent_reader_rollback_failure(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            if "CONNECTION LIMIT" in sql_text:
                return False, _FakeOutput(stderr_lines=["reader ensure failure"])
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "DELETE FROM deploydash.managed_roles" in sql_text:
                return False, _FakeOutput(stderr_lines=["unregister failure"])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not provision agent reader role.", result["msg"])
        self.assertIn("reader ensure failure", result["details"])
        self.assertIn("rollback could not remove role registration", result["details"])

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_user_does_not_provision_the_agent_reader(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        # #83: the reader is per-database, provisioned at database creation
        # and lazily on the first agent query -- never when adding a user.
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        executed_sql = []

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            executed_sql.append(str(sql))
            sql_text = str(sql)
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=["1"])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_user",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "extra_user",
                    "access_mode": "read_write",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "success")
        self.assertNotIn("CONNECTION LIMIT", "\n".join(executed_sql))

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_with_read_only_user_assigns_owner_without_membership(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        executed_sql = []

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            executed_sql.append(str(sql))
            sql_text = str(sql)
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "reporting_user",
                    "access_mode": "read_only",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        owner_name = "deploydash_owner_dd_test_app_770b1081f7ad"
        self.assertEqual(result["status"], "success")
        all_sql = "\n".join(executed_sql)
        self.assertIn(f'CREATE ROLE "{owner_name}" NOLOGIN;', all_sql)
        self.assertIn(
            f'ALTER DATABASE "dd_test_app" OWNER TO "{owner_name}";',
            all_sql,
        )
        self.assertNotIn(f'GRANT "{owner_name}" TO ', all_sql)

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_reports_owner_provisioning_failure(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        host = _CapturingHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            # The NOLOGIN match comes first: the ensure statement embeds the
            # same role-existence probe the checks below match on.
            if "NOLOGIN" in sql_text:
                return False, _FakeOutput(stderr_lines=["ensure failure"])
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not provision database owner role.", result["msg"])
        all_commands = "\n".join(host.commands)
        self.assertIn("createdb -U", all_commands)
        self.assertIn("dropdb -U", all_commands)
        self.assertTrue(
            any(
                "DROP ROLE IF EXISTS" in str(call.args[3])
                for call in mock_run_postgres_psql_query.call_args_list
            )
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_reports_owner_rollback_failure(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            if "NOLOGIN" in sql_text:
                return False, _FakeOutput(stderr_lines=["ensure failure"])
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "DELETE FROM deploydash.managed_roles" in sql_text:
                return False, _FakeOutput(stderr_lines=["unregister failure"])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not provision database owner role.", result["msg"])
        self.assertIn("ensure failure", result["details"])
        self.assertIn("rollback could not remove role registration", result["details"])

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_revokes_public_connect_and_temp(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        executed_sql = []

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            executed_sql.append(str(sql))
            sql_text = str(sql)
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "success")
        all_sql = "\n".join(executed_sql)
        self.assertIn(
            'REVOKE CONNECT, TEMP ON DATABASE "dd_test_app" FROM PUBLIC;',
            all_sql,
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_leaves_adopted_database_public_rights_alone(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        # #82: only databases created in the flow are revoked. A pre-existing
        # database adopted by create-database keeps its PUBLIC rights until
        # the normalization dry-run report covers it.
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        executed_sql = []

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            executed_sql.append(str(sql))
            sql_text = str(sql)
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=["1"])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "success")
        self.assertNotIn("FROM PUBLIC", "\n".join(executed_sql))

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_reports_public_revoke_failure(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        host = _CapturingHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            if "FROM PUBLIC" in sql_text:
                return False, _FakeOutput(stderr_lines=["revoke failure"])
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not revoke public database access.", result["msg"])
        all_commands = "\n".join(host.commands)
        self.assertIn("createdb -U", all_commands)
        self.assertIn("dropdb -U", all_commands)

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_reports_public_revoke_rollback_failure(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        host = _CapturingHost(fail_markers=("dropdb -U",))
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            if "FROM PUBLIC" in sql_text:
                return False, _FakeOutput(stderr_lines=["revoke failure"])
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "DELETE FROM deploydash.managed_databases" in sql_text:
                return False, _FakeOutput(stderr_lines=["unregister failure"])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not revoke public database access.", result["msg"])
        self.assertIn("revoke failure", result["details"])
        self.assertIn(
            "rollback could not remove database registration",
            result["details"],
        )
        self.assertIn("dd_test_app", result["details"])
        self.assertIn("reconnecting", result["details"])
        self.assertIn("--force --if-exists", "\n".join(host.commands))

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_rolls_back_new_resources_on_grant_failure(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        host = _CapturingHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if (
                'ALTER DATABASE "dd_test_app" OWNER TO "dd_test_app_user";' in sql_text
                or "GRANT USAGE ON SCHEMA public TO" in sql_text
                or "GRANT SELECT, INSERT, UPDATE, DELETE" in sql_text
            ):
                return False, _FakeOutput(stderr_lines=["grant failure"])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not grant database access.", result["msg"])
        all_commands = "\n".join(host.commands)
        self.assertIn("createdb -U", all_commands)
        self.assertIn("dropdb -U", all_commands)
        self.assertTrue(
            any(
                "DROP ROLE IF EXISTS" in str(call.args[3])
                for call in mock_run_postgres_psql_query.call_args_list
            )
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_database_drops_target_database_and_users(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        host = _CapturingHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        app_role_deleted = False

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            nonlocal app_role_deleted
            sql_text = str(sql)
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=["1"])
            if "FROM deploydash.managed_roles" in sql_text:
                if app_role_deleted:
                    return True, _FakeOutput(stdout_lines=[])
                return True, _FakeOutput(stdout_lines=["dd_test_app_user"])
            if "REASSIGN OWNED BY" in sql_text or "DROP OWNED BY" in sql_text:
                return True, _FakeOutput(stdout_lines=["COMMIT"])
            if "SELECT pg_terminate_backend(pid)" in sql_text:
                return True, _FakeOutput(stdout_lines=["t"])
            if "DROP ROLE IF EXISTS" in sql_text:
                if "dd_test_app_user" in sql_text:
                    app_role_deleted = True
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "project_delete_database")
        self.assertEqual(result["database_name"], "app")
        self.assertEqual(result["deleted_database_name"], "app")
        self.assertEqual(result["remote_database_name"], "dd_test_app")
        self.assertEqual(result["deleted_remote_database_name"], "dd_test_app")
        # #81: deleting a database drops its derived owner role alongside
        # the registered users, even when the owner row itself is missing.
        # #83: the derived agent reader goes with it.
        self.assertEqual(
            result["dropped_users"],
            [
                "dd_test_app_user",
                "deploydash_owner_dd_test_app_770b1081f7ad",
                "deploydash_agent_reader_dd_test_app_770b1081f7ad",
            ],
        )
        self.assertTrue(result["database_existed"])
        dropdb_commands = [command for command in host.commands if "dropdb -U" in command]
        self.assertEqual(len(dropdb_commands), 1)
        self.assertIn("--force --if-exists", dropdb_commands[0])
        self.assertIn("dd_test_app", dropdb_commands[0])

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_database_drop_failure_names_database_and_reconnecting_client(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        """Actionable drop failures must identify the resource and likely race."""
        host = _CapturingHost(fail_markers=("dropdb -U",))
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            """Reach the direct drop while isolating its injected host failure."""
            sql_text = str(sql)
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=["1"])
            if "FROM deploydash.managed_roles" in sql_text:
                return True, _FakeOutput(stdout_lines=[])
            if "SELECT pg_terminate_backend(pid)" in sql_text:
                return True, _FakeOutput(stdout_lines=["t"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("dd_test_app", result["details"])
        self.assertIn("reconnecting", result["details"])
        self.assertIn("Stop the app", result["details"])

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_database_drops_unregistered_owner_role(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        # #81: the owner role is derived from the database name, so the
        # delete drops it even when its registry row is missing (for example
        # after a create that rolled back past registration).
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        executed_sql = []
        app_role_deleted = False

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            nonlocal app_role_deleted
            executed_sql.append(str(sql))
            sql_text = str(sql)
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=["1"])
            if "FROM deploydash.managed_roles" in sql_text:
                if app_role_deleted:
                    return True, _FakeOutput(stdout_lines=[])
                return True, _FakeOutput(stdout_lines=["dd_test_app_user"])
            if "REASSIGN OWNED BY" in sql_text or "DROP OWNED BY" in sql_text:
                return True, _FakeOutput(stdout_lines=["COMMIT"])
            if "SELECT pg_terminate_backend(pid)" in sql_text:
                return True, _FakeOutput(stdout_lines=["t"])
            if "DROP ROLE IF EXISTS" in sql_text:
                if "dd_test_app_user" in sql_text:
                    app_role_deleted = True
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        owner_name = "deploydash_owner_dd_test_app_770b1081f7ad"
        reader_name = "deploydash_agent_reader_dd_test_app_770b1081f7ad"
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["dropped_users"], ["dd_test_app_user", owner_name, reader_name])
        all_sql = "\n".join(executed_sql)
        self.assertIn(f'DROP ROLE IF EXISTS "{owner_name}";', all_sql)
        self.assertIn(
            f"DELETE FROM deploydash.managed_roles WHERE rolname = '{owner_name}';",
            all_sql,
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_database_drops_registered_owner_role_once(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        roles_deleted = False

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            nonlocal roles_deleted
            sql_text = str(sql)
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=["1"])
            if "FROM deploydash.managed_roles" in sql_text:
                if roles_deleted:
                    return True, _FakeOutput(stdout_lines=[])
                return True, _FakeOutput(
                    stdout_lines=[
                        "dd_test_app_user",
                        "deploydash_owner_dd_test_app_770b1081f7ad",
                    ]
                )
            if "REASSIGN OWNED BY" in sql_text or "DROP OWNED BY" in sql_text:
                return True, _FakeOutput(stdout_lines=["COMMIT"])
            if "SELECT pg_terminate_backend(pid)" in sql_text:
                return True, _FakeOutput(stdout_lines=["t"])
            if "DROP ROLE IF EXISTS" in sql_text:
                roles_deleted = True
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(
            result["dropped_users"],
            [
                "dd_test_app_user",
                "deploydash_owner_dd_test_app_770b1081f7ad",
                "deploydash_agent_reader_dd_test_app_770b1081f7ad",
            ],
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_database_tolerates_owner_role_that_was_never_created(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        # #81: the derived owner is appended to the cleanup list even when
        # it was never created (pre-#81 databases, rolled-back creates).
        # PostgreSQL rejects a bare REASSIGN OWNED BY for a missing role,
        # so the cleanup must skip roles that do not exist instead of
        # failing the whole delete.
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        owner_name = "deploydash_owner_dd_test_app_770b1081f7ad"
        existing_roles = {"dd_test_app_user"}
        app_role_deleted = False
        executed_sql = []

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            nonlocal app_role_deleted
            executed_sql.append(str(sql))
            sql_text = str(sql)
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=["1"])
            if "FROM deploydash.managed_roles" in sql_text:
                if app_role_deleted:
                    return True, _FakeOutput(stdout_lines=[])
                return True, _FakeOutput(stdout_lines=["dd_test_app_user"])
            if "REASSIGN OWNED BY" in sql_text:
                if "IF EXISTS" in sql_text:
                    return True, _FakeOutput(stdout_lines=["DO"])
                if f'"{owner_name}"' in sql_text and owner_name not in existing_roles:
                    return False, _FakeOutput(
                        stderr_lines=[f'ERROR: role "{owner_name}" does not exist']
                    )
                return True, _FakeOutput(stdout_lines=["COMMIT"])
            if "SELECT pg_terminate_backend(pid)" in sql_text:
                return True, _FakeOutput(stdout_lines=["t"])
            if "DROP ROLE IF EXISTS" in sql_text:
                if "dd_test_app_user" in sql_text:
                    app_role_deleted = True
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        reader_name = "deploydash_agent_reader_dd_test_app_770b1081f7ad"
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["dropped_users"], ["dd_test_app_user", owner_name, reader_name])
        self.assertTrue(
            any("REASSIGN OWNED BY" in sql and "IF EXISTS" in sql for sql in executed_sql)
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_database_verifies_live_roles_not_registry_rows(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        # #81: the verify step runs before the unregister step, so the
        # registry rows still exist when it runs. It must check live
        # pg_roles instead: re-reading the registry fails every delete
        # whose roles were registered.
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        owner_name = "deploydash_owner_dd_test_app_770b1081f7ad"
        executed_sql = []

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            executed_sql.append(str(sql))
            sql_text = str(sql)
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=["1"])
            if "FROM deploydash.managed_roles" in sql_text:
                return True, _FakeOutput(stdout_lines=["dd_test_app_user"])
            if "REASSIGN OWNED BY" in sql_text:
                return True, _FakeOutput(stdout_lines=["COMMIT"])
            if "SELECT pg_terminate_backend(pid)" in sql_text:
                return True, _FakeOutput(stdout_lines=["t"])
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            if "FROM pg_roles WHERE rolname IN" in sql_text:
                return True, _FakeOutput(stdout_lines=[])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        reader_name = "deploydash_agent_reader_dd_test_app_770b1081f7ad"
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["dropped_users"], ["dd_test_app_user", owner_name, reader_name])
        self.assertTrue(any("FROM pg_roles WHERE rolname IN" in sql for sql in executed_sql))
        self.assertIn(
            f"DELETE FROM deploydash.managed_roles WHERE rolname = '{owner_name}';",
            "\n".join(executed_sql),
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_database_verify_failure_names_remaining_live_roles(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        # #81: when a dropped role is still present afterwards, the
        # verify error names the live remainder, not the registry rows.
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        owner_name = "deploydash_owner_dd_test_app_770b1081f7ad"

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=["1"])
            if "FROM deploydash.managed_roles" in sql_text:
                return True, _FakeOutput(stdout_lines=["dd_test_app_user"])
            if "REASSIGN OWNED BY" in sql_text:
                return True, _FakeOutput(stdout_lines=["COMMIT"])
            if "SELECT pg_terminate_backend(pid)" in sql_text:
                return True, _FakeOutput(stdout_lines=["t"])
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            if "FROM pg_roles WHERE rolname IN" in sql_text:
                return True, _FakeOutput(stdout_lines=[owner_name])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertIn("Could not verify database user cleanup.", result["msg"])
        self.assertIn(owner_name, result["details"])

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_database_drops_unregistered_reader_role(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        # #83: the reader role is derived from the database name, so the
        # delete drops it even when its registry row is missing (for example
        # after a create that rolled back past registration).
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        executed_sql = []
        roles_deleted = False

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            nonlocal roles_deleted
            executed_sql.append(str(sql))
            sql_text = str(sql)
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=["1"])
            if "FROM deploydash.managed_roles" in sql_text:
                if roles_deleted:
                    return True, _FakeOutput(stdout_lines=[])
                return True, _FakeOutput(
                    stdout_lines=[
                        "dd_test_app_user",
                        "deploydash_owner_dd_test_app_770b1081f7ad",
                    ]
                )
            if "REASSIGN OWNED BY" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            if "SELECT pg_terminate_backend(pid)" in sql_text:
                return True, _FakeOutput(stdout_lines=["t"])
            if "DROP ROLE IF EXISTS" in sql_text:
                roles_deleted = True
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            if "FROM pg_roles WHERE rolname IN" in sql_text:
                return True, _FakeOutput(stdout_lines=[])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        owner_name = "deploydash_owner_dd_test_app_770b1081f7ad"
        reader_name = "deploydash_agent_reader_dd_test_app_770b1081f7ad"
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["dropped_users"], ["dd_test_app_user", owner_name, reader_name])
        all_sql = "\n".join(executed_sql)
        self.assertIn(f'DROP ROLE IF EXISTS "{reader_name}";', all_sql)
        self.assertIn(
            f"DELETE FROM deploydash.managed_roles WHERE rolname = '{reader_name}';",
            all_sql,
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_database_drops_registered_reader_role_once(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        roles_deleted = False

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            nonlocal roles_deleted
            sql_text = str(sql)
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=["1"])
            if "FROM deploydash.managed_roles" in sql_text:
                if roles_deleted:
                    return True, _FakeOutput(stdout_lines=[])
                return True, _FakeOutput(
                    stdout_lines=[
                        "dd_test_app_user",
                        "deploydash_owner_dd_test_app_770b1081f7ad",
                        "deploydash_agent_reader_dd_test_app_770b1081f7ad",
                    ]
                )
            if "REASSIGN OWNED BY" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            if "SELECT pg_terminate_backend(pid)" in sql_text:
                return True, _FakeOutput(stdout_lines=["t"])
            if "DROP ROLE IF EXISTS" in sql_text:
                roles_deleted = True
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            if "FROM pg_roles WHERE rolname IN" in sql_text:
                return True, _FakeOutput(stdout_lines=[])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(
            result["dropped_users"],
            [
                "dd_test_app_user",
                "deploydash_owner_dd_test_app_770b1081f7ad",
                "deploydash_agent_reader_dd_test_app_770b1081f7ad",
            ],
        )

    @patch.object(users_and_grants, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_user_drops_role_when_database_is_already_gone(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        host = _CapturingHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            if "REASSIGN OWNED BY" in sql_text or "DROP OWNED BY" in sql_text:
                return False, _FakeOutput(
                    stderr_lines=['database "dd_test_app" does not exist'],
                )
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete_user",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "reader",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["database_name"], "app")
        self.assertEqual(result["deleted_database_name"], "app")
        self.assertEqual(result["remote_database_name"], "dd_test_app")
        self.assertEqual(result["username"], "reader")
        self.assertEqual(result["deleted_username"], "reader")
        self.assertEqual(result["remote_username"], "dd_test_reader")
        self.assertTrue(
            any(
                "DROP ROLE IF EXISTS" in str(call.args[3])
                for call in mock_run_postgres_psql_query.call_args_list
            )
        )

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_drops_project_databases_and_users(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        host = _CapturingHost(
            stdout_by_marker={
                "REMOTE_PREFIX=deploydash/postgres/test/": [
                    "removed_backup_policy=daily-main",
                ],
            },
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            if "FROM deploydash.managed_databases" in sql_text:
                return True, _FakeOutput(stdout_lines=["dd_test_app", "dd_test_jobs"])
            if "SELECT pg_terminate_backend(pid)" in sql_text:
                return True, _FakeOutput(stdout_lines=["t"])
            if "FROM deploydash.managed_roles" in sql_text:
                return True, _FakeOutput(stdout_lines=["dd_test_app_user", "dd_test_jobs_user"])
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                    "confirmed_databases": ["dd_test_app", "dd_test_jobs"],
                    "confirmed_users": [
                        "dd_test_app_user",
                        "dd_test_jobs_user",
                    ],
                },
            },
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "project_delete")
        self.assertEqual(result["dropped_databases"], ["dd_test_app", "dd_test_jobs"])
        self.assertEqual(
            result["dropped_users"],
            ["dd_test_app_user", "dd_test_jobs_user"],
        )
        dropdb_commands = [command for command in host.commands if "dropdb -U" in command]
        self.assertEqual(len(dropdb_commands), 2)
        self.assertTrue(
            all("--force --if-exists" in command for command in dropdb_commands),
        )
        self.assertTrue(
            any(
                "REMOTE_PREFIX=deploydash/postgres/test/" in command
                and "BACKUP_REMOTE_BASE_PATH=${REMOTE_PREFIX}${POLICY_TOKEN}" in command
                for command in host.commands
            ),
        )
        self.assertEqual(result["removed_backup_policies"], ["daily-main"])
        self.assertEqual(result["removed_backup_policy_count"], 1)
        self.assertTrue(result["backup_logs_removed"])

    # A policy cleanup fault is surfaced even though the already-confirmed
    # database resources were removed, allowing a safe retry to finish (#90).
    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_reports_backup_policy_cleanup_failure(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        host = _CapturingHost(
            fail_markers=("REMOTE_PREFIX=deploydash/postgres/test/",),
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }
        mock_run_postgres_psql_query.return_value = True, _FakeOutput()

        result = engine.run_postgres_project_operation(
            operation_id="project_delete",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                    "confirmed_databases": [],
                    "confirmed_users": [],
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Could not remove project backup policies.")
        self.assertIn("database is being accessed", result["details"])

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_drop_failure_names_database_and_reconnecting_client(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        """Whole-project cleanup must preserve actionable force-drop failures."""
        host = _CapturingHost(fail_markers=("dropdb -U",))
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            """Reach whole-project drop without introducing unrelated failures."""
            sql_text = str(sql)
            if "FROM deploydash.managed_databases" in sql_text:
                return True, _FakeOutput(stdout_lines=["dd_test_app"])
            if "FROM deploydash.managed_roles" in sql_text:
                return True, _FakeOutput(stdout_lines=[])
            if "SELECT pg_terminate_backend(pid)" in sql_text:
                return True, _FakeOutput(stdout_lines=["t"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                    "confirmed_databases": ["dd_test_app"],
                    "confirmed_users": [],
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("dd_test_app", result["details"])
        self.assertIn("reconnecting", result["details"])
        self.assertIn("Stop the app", result["details"])

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_drops_the_agent_reader_with_its_database(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        # #83: project delete drops every registered project role, which
        # includes the agent reader row, and unregisters it.
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }
        executed_sql = []

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            executed_sql.append(str(sql))
            sql_text = str(sql)
            if "FROM deploydash.managed_databases" in sql_text:
                return True, _FakeOutput(stdout_lines=["dd_test_app"])
            if "SELECT pg_terminate_backend(pid)" in sql_text:
                return True, _FakeOutput(stdout_lines=["t"])
            if "FROM deploydash.managed_roles" in sql_text:
                return True, _FakeOutput(
                    stdout_lines=[
                        "dd_test_app_user",
                        "deploydash_owner_dd_test_app_770b1081f7ad",
                        "deploydash_agent_reader_dd_test_app_770b1081f7ad",
                    ]
                )
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                    "confirmed_databases": ["dd_test_app"],
                    "confirmed_users": [
                        "dd_test_app_user",
                        "deploydash_owner_dd_test_app_770b1081f7ad",
                        "deploydash_agent_reader_dd_test_app_770b1081f7ad",
                    ],
                },
            },
        )

        reader_name = "deploydash_agent_reader_dd_test_app_770b1081f7ad"
        self.assertEqual(result["status"], "success")
        self.assertIn(reader_name, result["dropped_users"])
        all_sql = "\n".join(executed_sql)
        self.assertIn(f'DROP ROLE IF EXISTS "{reader_name}";', all_sql)
        self.assertIn(
            f"DELETE FROM deploydash.managed_roles WHERE rolname = '{reader_name}';",
            all_sql,
        )

    def test_prefixed_name_truncates_overlong_candidates_to_identifier_limit(self):
        self.assertEqual(
            engine._postgres_prefixed_name("dd_test_", "b" * 60, "settings.database_name"),
            "dd_test_" + "b" * 55,
        )
        # Truncation strips a trailing separator left behind by the cut so the
        # stored name never ends in a bare underscore.
        self.assertEqual(
            engine._postgres_prefixed_name(
                "dd_test_",
                "b" * 54 + "_bbbbbb",
                "settings.database_name",
            ),
            "dd_test_" + "b" * 54,
        )

    def test_prefixed_name_rejects_unusable_identifier_when_prefix_consumes_limit(self):
        prefix = "dd_" + "a" * 59 + "_"
        self.assertEqual(len(prefix), 63)

        with self.assertRaisesRegex(
            PostgresConfigValidationError,
            "produced invalid identifier",
        ):
            engine._postgres_prefixed_name(prefix, "app", "settings.database_name")

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_reports_ownership_registration_failure(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        host = _CapturingHost()
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=["1"])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "INSERT INTO deploydash.managed" in sql_text:
                return False, _FakeOutput(stderr_lines=["register failure"])
            if "DELETE FROM deploydash.managed_databases" in sql_text:
                return False, _FakeOutput(stderr_lines=["unregister failure"])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not register database ownership.", result["msg"])
        self.assertIn("register failure", result["details"])
        self.assertIn(
            "rollback could not remove database registration",
            result["details"],
        )

    @patch.object(
        database_lifecycle,
        "_ensure_postgres_project_registry",
        return_value={
            "status": "error",
            "code": "ENGINE_RUNTIME_ERROR",
            "msg": "ensure boom",
        },
    )
    @patch("engine._open_runtime_session")
    def test_project_delete_reports_registry_ensure_failure(
        self,
        mock_open_runtime_session,
        _mock_ensure_registry,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }

        result = engine.run_postgres_project_operation(
            operation_id="project_delete",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                    "confirmed_databases": [],
                    "confirmed_users": [],
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "ensure boom")

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_delete_reports_ownership_unregistration_failure(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            # The unregister DELETEs also mention the registry tables, so they
            # must match before the listing SELECTs below.
            if "DELETE FROM deploydash.managed" in sql_text:
                return False, _FakeOutput(stderr_lines=["unregister failure"])
            if "FROM deploydash.managed_databases" in sql_text:
                return True, _FakeOutput(stdout_lines=["dd_test_app"])
            if "FROM deploydash.managed_roles" in sql_text:
                return True, _FakeOutput(stdout_lines=["dd_test_app_user"])
            if "SELECT pg_terminate_backend(pid)" in sql_text:
                return True, _FakeOutput(stdout_lines=["t"])
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_delete",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                    "confirmed_databases": ["dd_test_app"],
                    "confirmed_users": ["dd_test_app_user"],
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not remove project ownership registrations.", result["msg"])
        self.assertIn("unregister failure", result["details"])

    @patch.object(database_lifecycle, "_run_postgres_psql_query_impl")
    @patch("engine._open_runtime_session")
    def test_project_create_database_reports_role_registration_rollback_failure(
        self,
        mock_open_runtime_session,
        mock_run_postgres_psql_query,
    ):
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_CapturingHost()),
        }

        def _query_side_effect(_ctx, _session, _config, sql, **_kwargs):
            sql_text = str(sql)
            if "SELECT 1 FROM pg_roles WHERE rolname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if "SELECT 1 FROM pg_database WHERE datname =" in sql_text:
                return True, _FakeOutput(stdout_lines=[""])
            if (
                'ALTER DATABASE "dd_test_app" OWNER TO "dd_test_app_user";' in sql_text
                or "GRANT USAGE ON SCHEMA public TO" in sql_text
                or "GRANT SELECT, INSERT, UPDATE, DELETE" in sql_text
            ):
                return False, _FakeOutput(stderr_lines=["grant failure"])
            if "DELETE FROM deploydash.managed_roles" in sql_text:
                return False, _FakeOutput(stderr_lines=["unregister failure"])
            if "DO $$" in sql_text:
                return True, _FakeOutput(stdout_lines=["DO"])
            if "DROP ROLE IF EXISTS" in sql_text:
                return True, _FakeOutput(stdout_lines=["DROP ROLE"])
            return True, _FakeOutput(stdout_lines=[])

        mock_run_postgres_psql_query.side_effect = _query_side_effect

        result = engine.run_postgres_project_operation(
            operation_id="project_create_database",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "database_name": "app",
                    "username": "app_user",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not grant database access.", result["msg"])
        self.assertIn("grant failure", result["details"])
        self.assertIn("rollback could not remove role registration", result["details"])

    @patch("engine._open_runtime_session")
    def test_project_list_reports_database_listing_failure(
        self,
        mock_open_runtime_session,
    ):
        host = _ProjectListHost(
            fail_markers=("FROM deploydash.managed_databases WHERE project_slug",),
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        result = engine.run_postgres_project_operation(
            operation_id="project_list",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not list project databases.", result["msg"])
        self.assertIn("injected list failure", result["details"])

    @patch("engine._open_runtime_session")
    def test_project_list_reports_user_listing_failure(
        self,
        mock_open_runtime_session,
    ):
        host = _ProjectListHost(
            fail_markers=("FROM deploydash.managed_roles WHERE project_slug",),
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        result = engine.run_postgres_project_operation(
            operation_id="project_list",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Could not list project database users.", result["msg"])
        self.assertIn("injected list failure", result["details"])

    @patch("engine._open_runtime_session")
    def test_project_list_skips_malformed_role_entries(
        self,
        mock_open_runtime_session,
    ):
        host = _ProjectListHost(
            roles_stdout_lines=[
                json.dumps(
                    [
                        "junk-string",
                        42,
                        {"username": 42},
                        {"username": "u1", "database": 7, "access_mode": "bogus"},
                    ]
                ),
            ],
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        result = engine.run_postgres_project_operation(
            operation_id="project_list",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "superuser_password": "test-superuser-password",
                },
            },
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(
            result["users"],
            [{"username": "u1", "database": None, "access_mode": "read_write"}],
        )

    @patch("engine._open_runtime_session")
    def test_project_list_tolerates_non_list_and_broken_role_payloads(
        self,
        mock_open_runtime_session,
    ):
        for roles_stdout_lines in (['{"oops": 1}'], ["not json{{{"]):
            with self.subTest(roles_stdout_lines=roles_stdout_lines):
                host = _ProjectListHost(roles_stdout_lines=roles_stdout_lines)
                mock_open_runtime_session.return_value = {
                    "ok": True,
                    "session": _FakeSession(host),
                }

                result = engine.run_postgres_project_operation(
                    operation_id="project_list",
                    ip="198.51.100.8",
                    username="ubuntu",
                    password="secret",
                    dry_run=False,
                    raw_data={
                        "settings": {
                            "project_slug": "test",
                            "superuser_password": "test-superuser-password",
                        },
                    },
                )

                self.assertEqual(result["status"], "success")
                self.assertEqual(result["users"], [])
                self.assertEqual(result["databases"], ["dd_test_app"])

    @patch("engine._open_runtime_session")
    def test_service_configure_refuses_major_version_change(
        self,
        mock_open_runtime_session,
    ):
        # #86: swapping the image over a live data directory breaks the
        # cluster, so configure refuses a different major with a dedicated
        # code pointing at the upgrade flow, before touching anything.
        host = _MajorGuardHost(
            image_line="deploydash/postgres-ext:17.10-bookworm-base",
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }
        result = run_postgres_runtime_operation(
            operation_id="service_configure",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "postgres_version": "16",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": [],
                },
            },
        )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "POSTGRES_MAJOR_VERSION_CHANGE_BLOCKED")
        self.assertIn("17", result["msg"])
        self.assertIn("16", result["msg"])
        self.assertIn("service_upgrade_major", result["msg"])
        self.assertFalse(
            any("up -d" in command for command in host.commands),
            "refused configure must not bring the container up",
        )

    @patch("engine._open_runtime_session")
    def test_service_configure_allows_same_major_version(
        self,
        mock_open_runtime_session,
    ):
        # #86: the guard only fires on a change; same-major reconfigures
        # (extensions, credentials) proceed untouched.
        host = _MajorGuardHost(
            image_line="deploydash/postgres-ext:17.10-bookworm-base",
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }
        result = run_postgres_runtime_operation(
            operation_id="service_configure",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": [],
                },
            },
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "service_configure")

    @patch("engine._open_runtime_session")
    def test_service_configure_preserves_the_live_physical_volume(
        self,
        mock_open_runtime_session,
    ):
        """Keep a post-upgrade volume attached when rewriting compose."""
        upgraded_volume = "postgres_postgres_data_pg17"
        host = _MajorGuardHost(
            image_line="deploydash/postgres-ext:17.10-bookworm-base",
            mounts_line=json.dumps(
                [
                    {
                        "Type": "volume",
                        "Name": upgraded_volume,
                        "Source": upgraded_volume,
                        "Destination": "/var/lib/postgresql/data",
                    },
                ],
            ),
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        result = run_postgres_runtime_operation(
            operation_id="service_configure",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": [],
                },
            },
        )

        self.assertEqual(result["status"], "success")
        compose_command = next(
            command for command in host.commands if 'cat > "${COMPOSE_FILE}"' in command
        )
        self.assertIn(f"name: {upgraded_volume}", compose_command)

    @patch("engine._open_runtime_session")
    def test_service_enable_refuses_a_live_major_version_change(
        self,
        mock_open_runtime_session,
    ):
        """Apply the destructive major-version guard to every enabling rewrite."""
        host = _MajorGuardHost(
            image_line="deploydash/postgres-ext:17.10-bookworm-base",
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        result = run_postgres_runtime_operation(
            operation_id="service_enable",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "postgres_version": "16",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": [],
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "POSTGRES_MAJOR_VERSION_CHANGE_BLOCKED")
        self.assertFalse(any('cat > "${COMPOSE_FILE}"' in command for command in host.commands))

    @patch("engine._open_runtime_session")
    def test_service_configure_refuses_unparseable_live_mounts(
        self,
        mock_open_runtime_session,
    ):
        """Fail closed when compose cannot safely retain the live data volume."""
        host = _MajorGuardHost(
            image_line="deploydash/postgres-ext:17.10-bookworm-base",
            mounts_line="not-json",
        )
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }

        result = run_postgres_runtime_operation(
            operation_id="service_configure",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": [],
                },
            },
        )

        self.assertEqual(result["status"], "error")
        self.assertIn("preserve", result["msg"])
        self.assertFalse(any('cat > "${COMPOSE_FILE}"' in command for command in host.commands))

    @patch("engine._open_runtime_session")
    def test_service_configure_allows_missing_container(
        self,
        mock_open_runtime_session,
    ):
        # #86: with no container there is no live data to protect, so a
        # first configure proceeds.
        host = _MajorGuardHost(image_line=None)
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }
        result = run_postgres_runtime_operation(
            operation_id="service_configure",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "postgres_version": "16",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": [],
                },
            },
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "service_configure")

    @patch("engine._open_runtime_session")
    def test_service_configure_refuses_unparseable_container_image(
        self,
        mock_open_runtime_session,
    ):
        # #86: a container whose image tag names no major cannot be proven
        # safe, so the guard fails closed.
        host = _MajorGuardHost(image_line="registry.example.com/custom/db:latest")
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(host),
        }
        result = run_postgres_runtime_operation(
            operation_id="service_configure",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "postgres_version": "16",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": [],
                },
            },
        )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "POSTGRES_MAJOR_VERSION_CHANGE_BLOCKED")

    @patch("engine._open_runtime_session")
    def test_service_configure_defers_probe_transport_failure_to_later_steps(
        self,
        mock_open_runtime_session,
    ):
        # #86: when the probe itself cannot run, the guard gets out of the
        # way and the first real step reports the transport fault.
        mock_open_runtime_session.return_value = {
            "ok": True,
            "session": _FakeSession(_RaisingHost()),
        }
        result = run_postgres_runtime_operation(
            operation_id="service_configure",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=False,
            raw_data={
                "settings": {
                    "postgres_version": "16",
                    "superuser_password": "test-superuser-password",
                    "enabled_extensions": [],
                },
            },
        )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Build PostgreSQL extension image", result["msg"])

    def test_container_image_major_parses_supported_tags(self):
        cases = {
            "deploydash/postgres-ext:16.14-bookworm-base": "16",
            "deploydash/postgres-ext:17.10-bookworm-vector-postgis": "17",
            "postgres:18.4-bookworm": "18",
            "  deploydash/postgres-ext:17.10-bookworm-base\n": "17",
        }
        for image, expected in cases.items():
            with self.subTest(image=image):
                self.assertEqual(
                    _postgres_parse_container_image_major(image),
                    expected,
                )

    def test_container_image_major_rejects_unknown_shapes(self):
        for image in (
            "",
            "   ",
            "registry.example.com/custom/db:latest",
            "deploydash/postgres-ext:nightly",
            "postgres:15.8-bookworm",
            None,
            42,
        ):
            with self.subTest(image=image):
                self.assertIsNone(
                    _postgres_parse_container_image_major(image),
                )

    def test_container_image_probe_renders_a_valid_go_template(self):
        # #86: single braces make docker print the template literally with
        # rc=0, so a probe built that way always reads "unparseable" and the
        # fail-closed guard refuses every configure. The rendered command
        # must carry the doubled template braces.
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "test-superuser-password",
                },
            }
        )
        command = _postgres_container_image_probe_command(config)
        self.assertIn("{{.Config.Image}}", command)
        self.assertNotIn("{.Config.Image}}", command.replace("{{.Config.Image}}", ""))
        self.assertIn("deploydash_postgres", command)


if __name__ == "__main__":
    unittest.main()
