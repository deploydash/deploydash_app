"""Agent-access query validation and the read-only query surface.

One of four files T-3.6.2 split `postgres_helpers_test.py` into. Fixtures and
the base case are in `tests/postgres_helpers_support.py`.
"""

from __future__ import annotations

import unittest

from tests.postgres_helpers_support import (
    PostgresConfigValidationError,
    PostgresHelpersTestCase,
    _config,
    _FakeOutput,
    _FakeSession,
    build_test_context,
    engine_postgres_ops,
)


class _RecordingHost:
    def __init__(self):
        self.commands = []
        self.kwargs = []

    def run_shell_command(self, command, *_args, **kwargs):
        self.commands.append(command)
        self.kwargs.append(kwargs)
        return True, _FakeOutput(stdout_lines=["1"])


class TestPostgresAgentQuery(PostgresHelpersTestCase):
    def test_agent_access_status_helpers_normalize_legacy_and_invalid_payloads(self):
        key_value_status = engine_postgres_ops._parse_postgres_service_status_output(
            _FakeOutput(
                [
                    "configured=1",
                    "version=17.8",
                    "container_present=1",
                    "container_docker_state=running",
                    "container_running=true",
                    "container_health=healthy",
                ]
            )
        )
        invalid_status = engine_postgres_ops._parse_postgres_service_status_output(
            _FakeOutput(["", "not-json", "[]"])
        )
        json_status = engine_postgres_ops._parse_postgres_service_status_output(
            _FakeOutput(
                [
                    '{"running":true,"configured":true,'
                    '"container_status":{"effective_status":"ready"},'
                    '"tls_enabled":true,"tls_ca_fingerprint":"AA:BB",'
                    '"tls_ca_certificate_base64":"Q0E="}'
                ]
            )
        )

        self.assertTrue(key_value_status["configured"])
        self.assertEqual(key_value_status["version"], "17.8")
        self.assertFalse(key_value_status["tls_enabled"])
        self.assertTrue(engine_postgres_ops._postgres_service_is_ready(key_value_status))
        self.assertFalse(engine_postgres_ops._postgres_service_is_ready(None))
        self.assertTrue(engine_postgres_ops._postgres_service_is_ready({"running": True}))
        self.assertEqual(invalid_status["health"], "down")
        self.assertFalse(invalid_status["configured"])
        self.assertTrue(json_status["tls_enabled"])
        self.assertEqual(json_status["tls_ca_fingerprint"], "AA:BB")
        self.assertEqual(json_status["tls_ca_certificate_base64"], "Q0E=")

    def test_agent_access_role_and_connection_helpers_use_safe_defaults(self):
        self.assertEqual(
            engine_postgres_ops._parse_postgres_role_comment(None),
            {"database": None, "access_mode": "read_write", "project": None},
        )
        self.assertEqual(
            engine_postgres_ops._postgres_connection_uri_host_for_managed_apps(),
            "host.docker.internal",
        )

    def test_psql_query_impl_runs_as_the_superuser_with_a_password_by_default(self):
        host = _RecordingHost()
        session = _FakeSession(host=host)
        ctx = build_test_context()

        status, output = engine_postgres_ops._run_postgres_psql_query_impl(
            ctx,
            session,
            _config(),
            "SELECT 1",
            database="dd_test_app",
        )

        self.assertTrue(status)
        self.assertEqual(output.stdout_lines, ["1"])
        self.assertEqual(len(host.commands), 1)
        self.assertIn('psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}"', host.commands[0])
        self.assertIn('-e PGPASSWORD="${POSTGRES_PASSWORD}"', host.commands[0])
        self.assertIn("-d dd_test_app", host.commands[0])
        self.assertEqual(host.kwargs[0].get("_timeout"), 60)
        self.assertTrue(host.kwargs[0].get("_sudo"))

    def test_psql_query_impl_runs_as_the_reader_without_a_password_when_asked(self):
        # #83: agent tools log in as the per-database reader over the
        # trusted container socket, with no password sent.
        host = _RecordingHost()
        session = _FakeSession(host=host)
        ctx = build_test_context()

        status, _ = engine_postgres_ops._run_postgres_psql_query_impl(
            ctx,
            session,
            _config(),
            "SELECT 1",
            database="dd_test_app",
            run_as_user="deploydash_agent_reader_dd_test_app_770b1081f7ad",
        )

        self.assertTrue(status)
        self.assertEqual(len(host.commands), 1)
        self.assertIn(
            "psql -v ON_ERROR_STOP=1 -U deploydash_agent_reader_dd_test_app_770b1081f7ad",
            host.commands[0],
        )
        self.assertNotIn("-e PGPASSWORD", host.commands[0])

    def test_validate_agent_query_sql_accepts_select_and_with(self):
        self.assertEqual(
            engine_postgres_ops._postgres_validate_agent_query_sql(
                "SELECT * FROM users",
            ),
            "SELECT * FROM users",
        )
        self.assertEqual(
            engine_postgres_ops._postgres_validate_agent_query_sql(
                "WITH recent AS (SELECT 1) SELECT * FROM recent",
            ),
            "WITH recent AS (SELECT 1) SELECT * FROM recent",
        )

    def test_validate_agent_query_sql_rejects_invalid_forms(self):
        cases = (
            (None, "must be a string"),
            ("", "is required"),
            ("SELECT 1;", "without semicolons"),
            ("SELECT 1 -- note", "comments are not allowed"),
            ("DELETE FROM users", "must start with SELECT or WITH"),
            ("x" * 20001, "20000 characters or fewer"),
            ("SELECT \x00 1", "invalid null bytes"),
        )
        for sql, expected in cases:
            with self.subTest(sql=sql):
                with self.assertRaises(PostgresConfigValidationError) as ctx:
                    engine_postgres_ops._postgres_validate_agent_query_sql(sql)
                self.assertIn(expected, str(ctx.exception))

    def test_agent_query_max_rows_defaults_and_validates(self):
        self.assertEqual(engine_postgres_ops._postgres_agent_query_max_rows(None), 200)
        self.assertEqual(engine_postgres_ops._postgres_agent_query_max_rows("25"), 25)
        for value in (0, 1001, "bad"):
            with self.subTest(value=value), self.assertRaises(PostgresConfigValidationError):
                engine_postgres_ops._postgres_agent_query_max_rows(value)

    def test_collect_csv_columns_and_json_rows(self):
        self.assertEqual(
            engine_postgres_ops._postgres_collect_csv_columns(
                _FakeOutput(stdout_lines=["id,email", "1,a@example.com"]),
            ),
            ["id", "email"],
        )
        self.assertEqual(
            engine_postgres_ops._postgres_collect_json_rows(
                _FakeOutput(stdout_lines=['[{"id":"u_1"},{"id":"u_2"}]']),
            ),
            [{"id": "u_1"}, {"id": "u_2"}],
        )
        self.assertEqual(
            engine_postgres_ops._postgres_collect_json_rows(
                _FakeOutput(
                    stdout_lines=[
                        "BEGIN",
                        '[{"id":"u_1"},{"id":"u_2"}]',
                        "ROLLBACK",
                    ],
                ),
            ),
            [{"id": "u_1"}, {"id": "u_2"}],
        )
        with self.assertRaises(ValueError):
            engine_postgres_ops._postgres_collect_json_rows(
                _FakeOutput(stdout_lines=['{"id":"u_1"}']),
            )


if __name__ == "__main__":
    unittest.main()
