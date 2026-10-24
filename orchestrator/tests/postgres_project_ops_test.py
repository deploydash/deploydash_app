"""The project-database operations a workflow dispatches.

One of four files T-3.6.2 split `postgres_helpers_test.py` into. Fixtures and
the base case are in `tests/postgres_helpers_support.py`.
"""

from __future__ import annotations

import unittest

from tests.postgres_helpers_support import (
    PostgresHelpersTestCase,
    _error_result,
    _FakeHost,
    _FakeOutput,
    _FakeSession,
    agent_access,
    build_test_context,
    engine_postgres_ops,
    patch,
    project_inventory,
    users_and_grants,
)


class TestPostgresProjectOperations(PostgresHelpersTestCase):
    def test_run_project_operation_list_schemas(self):
        captured = []

        def fake_query(_session, _config, sql, database="postgres", emit=None, run_as_user=None):
            del emit, run_as_user
            captured.append((sql, database))
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "json_agg(schema_name ORDER BY sort_order, schema_name)" in sql:
                return True, _FakeOutput(stdout_lines=['["public","audit"]'])
            raise AssertionError(sql)

        result = self._run_project_operation(
            "project_list_schemas",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=fake_query,
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["database_name"], "app")
        self.assertEqual(result["remote_database_name"], "dd_test_app")
        self.assertEqual(result["schemas"], ["public", "audit"])
        self.assertTrue(
            any(database == "dd_test_app" for _sql, database in captured),
        )

    def test_run_project_operation_list_schemas_provisions_the_agent_reader_first(self):
        # #83: the reader is ensured lazily on the first agent query, so
        # adopted databases that never ran creation gain it too. The owner
        # role is ensured bare first: the reader's FOR ROLE default
        # privileges need it to exist, without moving any ownership.
        captured = []

        def lazy_query(_session, _config, sql, database="postgres", emit=None, run_as_user=None):
            del emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "json_agg(schema_name ORDER BY sort_order, schema_name)" in sql:
                return True, _FakeOutput(stdout_lines=['["public","audit"]'])
            raise AssertionError(sql)

        result = self._run_project_operation(
            "project_list_schemas",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=lazy_query,
            captured_sql=captured,
        )

        self.assertEqual(result["status"], "success")
        reader_steps = [index for index, sql in enumerate(captured) if "CONNECTION LIMIT" in sql]
        schemas_steps = [
            index
            for index, sql in enumerate(captured)
            if "json_agg(schema_name ORDER BY sort_order, schema_name)" in sql
        ]
        self.assertTrue(reader_steps)
        self.assertTrue(schemas_steps)
        self.assertLess(reader_steps[0], schemas_steps[0])
        reader_sql = captured[reader_steps[0]]
        self.assertIn(
            'CREATE ROLE "deploydash_owner_dd_test_app_770b1081f7ad" NOLOGIN;', reader_sql
        )
        self.assertIn(
            'CREATE ROLE "deploydash_agent_reader_dd_test_app_770b1081f7ad" LOGIN',
            reader_sql,
        )
        self.assertTrue(
            any(
                "'deploydash_agent_reader_dd_test_app_770b1081f7ad'" in sql
                and "'agent_reader'" in sql
                for sql in captured
                if "INSERT INTO deploydash.managed_roles" in sql
            )
        )

    def test_run_project_operation_agent_query_reports_registry_ensure_failure(self):
        # The registry bootstrap runs through project_registry's own import
        # of the query runner, which this harness does not patch, so the
        # failure is injected at the ensure boundary itself.
        def registry_failure_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            raise AssertionError(sql)

        with patch.object(
            project_inventory,
            "_ensure_postgres_project_registry",
            return_value=_error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not ensure the PostgreSQL ownership registry.",
            ),
        ):
            result = self._run_project_operation(
                "project_list_schemas",
                settings={
                    "project_slug": "test",
                    "database_name": "app",
                    "postgres_version": "17",
                    "superuser_password": "secret",
                },
                query_handler=registry_failure_query,
                serve_lazy_ensure=False,
            )

        self.assertEqual(result["status"], "error")
        self.assertIn("Could not ensure the PostgreSQL ownership registry.", result["msg"])

    def test_run_project_operation_agent_query_reports_reader_provisioning_failure(self):
        def reader_failure_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "CONNECTION LIMIT" in sql:
                return False, _FakeOutput(stderr_lines=["reader ensure failure"])
            raise AssertionError(sql)

        result = self._run_project_operation(
            "project_list_schemas",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=reader_failure_query,
            serve_lazy_ensure=False,
        )

        self.assertEqual(result["status"], "error")
        self.assertIn("Could not provision agent reader role.", result["msg"])

    def test_run_project_operation_agent_query_reports_reader_registration_failure(self):
        def register_failure_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "CONNECTION LIMIT" in sql:
                return True, _FakeOutput(stdout_lines=["DO"])
            if "INSERT INTO deploydash.managed_roles" in sql:
                return False, _FakeOutput(stderr_lines=["register failure"])
            raise AssertionError(sql)

        result = self._run_project_operation(
            "project_list_schemas",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=register_failure_query,
            serve_lazy_ensure=False,
        )

        self.assertEqual(result["status"], "error")
        self.assertIn("Could not provision agent reader role.", result["msg"])

    def test_run_project_operation_list_schemas_validates_missing_database_name(self):
        result = self._run_project_operation(
            "project_list_schemas",
            settings={
                "project_slug": "test",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=lambda *_args, **_kwargs: (True, _FakeOutput()),
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("settings.database_name is required", result["msg"])

    def test_run_project_operation_list_schemas_surfaces_status_and_database_errors(self):
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
            project_inventory,
            _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (True, _FakeOutput()),
            _postgres_collect_service_status=lambda *_args, **_kwargs: (
                None,
                _error_result(
                    "ENGINE_RUNTIME_ERROR",
                    "Could not collect PostgreSQL service status.",
                ),
            ),
        ):
            status_result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "project_list_schemas",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "database_name": "app",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                    },
                },
            )

        self.assertEqual(status_result["status"], "error")
        self.assertIn("Could not collect PostgreSQL service status", status_result["msg"])

        stopped_result = self._run_project_operation(
            "project_list_schemas",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=lambda *_args, **_kwargs: (True, _FakeOutput()),
            status_output=_FakeOutput(
                stdout_lines=[
                    '{"running":false,"health":"down","version":"17.8","configured":true}',
                ],
            ),
        )
        self.assertEqual(stopped_result["status"], "error")
        self.assertEqual(stopped_result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Database service is not ready", stopped_result["msg"])

        def database_error_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return False, _FakeOutput(stderr_lines=["db lookup failed"])
            raise AssertionError(sql)

        database_error_result = self._run_project_operation(
            "project_list_schemas",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=database_error_query,
        )
        self.assertEqual(database_error_result["status"], "error")
        self.assertIn("Could not inspect target database", database_error_result["msg"])

        def missing_database_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["0"])
            raise AssertionError(sql)

        missing_database_result = self._run_project_operation(
            "project_list_schemas",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=missing_database_query,
        )
        self.assertEqual(missing_database_result["status"], "error")
        self.assertIn(
            "The selected project database does not exist",
            missing_database_result["msg"],
        )

    def test_run_project_operation_list_queries_handle_failures_and_invalid_json(self):
        def schema_failure_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "json_agg(schema_name ORDER BY sort_order, schema_name)" in sql:
                return False, _FakeOutput(stderr_lines=["schema query failed"])
            raise AssertionError(sql)

        schema_failure = self._run_project_operation(
            "project_list_schemas",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=schema_failure_query,
        )
        self.assertEqual(schema_failure["status"], "error")
        self.assertIn("Could not list project database schemas", schema_failure["msg"])

        def schema_invalid_json_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "json_agg(schema_name ORDER BY sort_order, schema_name)" in sql:
                return True, _FakeOutput(stdout_lines=["not-json"])
            raise AssertionError(sql)

        schema_invalid_json = self._run_project_operation(
            "project_list_schemas",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=schema_invalid_json_query,
        )
        self.assertEqual(schema_invalid_json["status"], "success")
        self.assertEqual(schema_invalid_json["schemas"], [])

        def tables_failure_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "'object_type', CASE c.relkind" in sql:
                return False, _FakeOutput(stderr_lines=["table query failed"])
            raise AssertionError(sql)

        tables_failure = self._run_project_operation(
            "project_list_tables",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=tables_failure_query,
        )
        self.assertEqual(tables_failure["status"], "error")
        self.assertIn("Could not list project database tables", tables_failure["msg"])

        def tables_invalid_json_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "'object_type', CASE c.relkind" in sql:
                return True, _FakeOutput(stdout_lines=["not-json"])
            raise AssertionError(sql)

        tables_invalid_json = self._run_project_operation(
            "project_list_tables",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=tables_invalid_json_query,
        )
        self.assertEqual(tables_invalid_json["status"], "success")
        self.assertEqual(tables_invalid_json["tables"], [])

    def test_run_project_operation_list_tables(self):
        captured = []

        def fake_query(_session, _config, sql, database="postgres", emit=None, run_as_user=None):
            del emit, run_as_user
            captured.append((sql, database))
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "'object_type', CASE c.relkind" in sql:
                return True, _FakeOutput(
                    stdout_lines=[
                        '[{"schema_name":"public","table_name":"users","object_type":"table"}]',
                    ],
                )
            raise AssertionError(sql)

        result = self._run_project_operation(
            "project_list_tables",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "schema_name": "public",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=fake_query,
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["schema_name"], "public")
        self.assertEqual(
            result["tables"],
            [{"schema_name": "public", "table_name": "users", "object_type": "table"}],
        )
        table_sql = next(
            sql for sql, _database in captured if "'object_type', CASE c.relkind" in sql
        )
        self.assertIn("n.nspname = 'public'", table_sql)

    def test_run_project_operation_describe_table(self):
        def fake_query(_session, _config, sql, database="postgres", emit=None, run_as_user=None):
            del emit, database, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "SELECT c.relkind " in sql:
                return True, _FakeOutput(stdout_lines=["r"])
            if "FROM information_schema.columns " in sql:
                return True, _FakeOutput(
                    stdout_lines=[
                        '[{"name":"id","data_type":"uuid","is_nullable":false,"default_expression":"gen_random_uuid()"}]',
                    ],
                )
            if "tc.constraint_type = 'PRIMARY KEY'" in sql:
                return True, _FakeOutput(stdout_lines=['["id"]'])
            if "FROM pg_indexes " in sql:
                return True, _FakeOutput(
                    stdout_lines=[
                        '[{"name":"users_pkey","is_unique":true,"definition":"CREATE UNIQUE INDEX users_pkey ON public.users USING btree (id)"}]',
                    ],
                )
            if "tc.constraint_type = 'FOREIGN KEY'" in sql:
                return True, _FakeOutput(
                    stdout_lines=[
                        '[{"name":"users_org_id_fkey","column_names":["org_id"],"referenced_schema_name":"public","referenced_table_name":"orgs","referenced_column_names":["id"]}]',
                    ],
                )
            raise AssertionError(sql)

        result = self._run_project_operation(
            "project_describe_table",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "schema_name": "public",
                "table_name": "users",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=fake_query,
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["table_name"], "users")
        self.assertEqual(result["primary_key_columns"], ["id"])
        self.assertEqual(result["columns"][0]["name"], "id")
        self.assertEqual(result["indexes"][0]["name"], "users_pkey")
        self.assertEqual(result["foreign_keys"][0]["name"], "users_org_id_fkey")

    def test_run_project_operation_describe_table_validates_missing_and_invalid_relations(self):
        def missing_table_name_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            raise AssertionError(sql)

        missing_table_name = self._run_project_operation(
            "project_describe_table",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=missing_table_name_query,
        )
        self.assertEqual(missing_table_name["status"], "error")
        self.assertIn("settings.table_name is required", missing_table_name["msg"])

        def relation_failure_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "SELECT c.relkind " in sql:
                return False, _FakeOutput(stderr_lines=["relation failed"])
            raise AssertionError(sql)

        relation_failure = self._run_project_operation(
            "project_describe_table",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "table_name": "users",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=relation_failure_query,
        )
        self.assertEqual(relation_failure["status"], "error")
        self.assertIn("Could not inspect project database table", relation_failure["msg"])

        def relation_missing_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "SELECT c.relkind " in sql:
                return True, _FakeOutput(stdout_lines=[])
            raise AssertionError(sql)

        relation_missing = self._run_project_operation(
            "project_describe_table",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "table_name": "users",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=relation_missing_query,
        )
        self.assertEqual(relation_missing["status"], "error")
        self.assertIn("does not exist", relation_missing["msg"])

        def relation_unsupported_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "SELECT c.relkind " in sql:
                return True, _FakeOutput(stdout_lines=["i"])
            raise AssertionError(sql)

        relation_unsupported = self._run_project_operation(
            "project_describe_table",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "table_name": "users",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=relation_unsupported_query,
        )
        self.assertEqual(relation_unsupported["status"], "error")
        self.assertIn("relation type is not supported", relation_unsupported["msg"])

    def test_run_project_operation_describe_table_handles_metadata_failure_and_invalid_json(self):
        def metadata_failure_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "SELECT c.relkind " in sql:
                return True, _FakeOutput(stdout_lines=["r"])
            if "FROM information_schema.columns " in sql:
                return False, _FakeOutput(stderr_lines=["columns failed"])
            raise AssertionError(sql)

        metadata_failure = self._run_project_operation(
            "project_describe_table",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "table_name": "users",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=metadata_failure_query,
        )
        self.assertEqual(metadata_failure["status"], "error")
        self.assertIn("Could not describe project database table", metadata_failure["msg"])

        def metadata_invalid_json_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "SELECT c.relkind " in sql:
                return True, _FakeOutput(stdout_lines=["r"])
            if "FROM information_schema.columns " in sql:
                return True, _FakeOutput(stdout_lines=["not-json"])
            if "tc.constraint_type = 'PRIMARY KEY'" in sql:
                return True, _FakeOutput(stdout_lines=["not-json"])
            if "FROM pg_indexes " in sql:
                return True, _FakeOutput(stdout_lines=["not-json"])
            if "tc.constraint_type = 'FOREIGN KEY'" in sql:
                return True, _FakeOutput(stdout_lines=["not-json"])
            raise AssertionError(sql)

        metadata_invalid_json = self._run_project_operation(
            "project_describe_table",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "table_name": "users",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=metadata_invalid_json_query,
        )
        self.assertEqual(metadata_invalid_json["status"], "success")
        self.assertEqual(metadata_invalid_json["columns"], [])
        self.assertEqual(metadata_invalid_json["primary_key_columns"], [])

    def test_run_project_operation_explain_readonly_query(self):
        captured = []

        def fake_query(_session, _config, sql, database="postgres", emit=None, run_as_user=None):
            del emit, run_as_user
            captured.append((sql, database))
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "EXPLAIN (FORMAT JSON, VERBOSE TRUE, COSTS TRUE)" in sql:
                return True, _FakeOutput(
                    stdout_lines=[
                        "BEGIN",
                        '[{"Plan":{"Node Type":"Limit"}}]',
                        "ROLLBACK",
                    ],
                )
            raise AssertionError(sql)

        result = self._run_project_operation(
            "project_explain_readonly_query",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "sql": "SELECT * FROM users",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=fake_query,
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["plan"], [{"Plan": {"Node Type": "Limit"}}])
        self.assertEqual(result["plan"][0]["Plan"]["Node Type"], "Limit")
        explain_sql = next(
            sql
            for sql, _database in captured
            if "EXPLAIN (FORMAT JSON, VERBOSE TRUE, COSTS TRUE)" in sql
        )
        self.assertIn("BEGIN READ ONLY;", explain_sql)
        self.assertIn("SET LOCAL default_transaction_read_only = on;", explain_sql)
        self.assertIn("SELECT * FROM users; ROLLBACK;", explain_sql)

    def test_run_project_operation_explain_handles_failure_and_invalid_json(self):
        def explain_failure_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "EXPLAIN (FORMAT JSON, VERBOSE TRUE, COSTS TRUE)" in sql:
                return False, _FakeOutput(stderr_lines=["explain failed"])
            raise AssertionError(sql)

        explain_failure = self._run_project_operation(
            "project_explain_readonly_query",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "sql": "SELECT * FROM users",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=explain_failure_query,
        )
        self.assertEqual(explain_failure["status"], "error")
        self.assertIn("Could not explain project database query", explain_failure["msg"])

        def explain_invalid_json_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "EXPLAIN (FORMAT JSON, VERBOSE TRUE, COSTS TRUE)" in sql:
                return True, _FakeOutput(stdout_lines=["not-json"])
            raise AssertionError(sql)

        explain_invalid_json = self._run_project_operation(
            "project_explain_readonly_query",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "sql": "SELECT * FROM users",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=explain_invalid_json_query,
        )
        self.assertEqual(explain_invalid_json["status"], "success")
        self.assertEqual(explain_invalid_json["plan"], [])

    def test_run_project_operation_execute_readonly_query_truncates_rows(self):
        captured = []

        def fake_query(_session, _config, sql, database="postgres", emit=None, run_as_user=None):
            del emit, run_as_user
            captured.append((sql, database))
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if (
                "COPY (SELECT * FROM (SELECT id, email FROM users) AS deploydash_query LIMIT 0)"
                in sql
            ):
                return True, _FakeOutput(stdout_lines=["id,email"])
            if "json_agg(row_to_json(t))" in sql:
                return True, _FakeOutput(
                    stdout_lines=[
                        '[{"id":"u_1","email":"a@example.com"},{"id":"u_2","email":"b@example.com"}]',
                        "ROLLBACK",
                    ],
                )
            raise AssertionError(sql)

        result = self._run_project_operation(
            "project_execute_readonly_query",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "sql": "SELECT id, email FROM users",
                "max_rows": 1,
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=fake_query,
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["columns"], ["id", "email"])
        self.assertEqual(result["row_count_returned"], 1)
        self.assertTrue(result["truncated"])
        self.assertEqual(result["rows"][0]["id"], "u_1")
        data_sql = next(sql for sql, _database in captured if "json_agg(row_to_json(t))" in sql)
        self.assertIn("LIMIT 2", data_sql)
        self.assertIn(") AS t; ROLLBACK;", data_sql)

    def test_run_project_operation_execute_readonly_query_rejects_large_result(self):
        def fake_query(_session, _config, sql, database="postgres", emit=None, run_as_user=None):
            del emit, database, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "COPY (" in sql:
                return True, _FakeOutput(stdout_lines=["id,payload"])
            if "json_agg(row_to_json(t))" in sql:
                return True, _FakeOutput(
                    stdout_lines=[
                        '[{"id":"u_1","payload":"' + ("x" * 300) + '"}]',
                    ],
                )
            raise AssertionError(sql)

        with patch.object(
            agent_access,
            "_POSTGRES_AGENT_QUERY_RESULT_MAX_BYTES",
            64,
        ):
            result = self._run_project_operation(
                "project_execute_readonly_query",
                settings={
                    "project_slug": "test",
                    "database_name": "app",
                    "sql": "SELECT id, payload FROM users",
                    "postgres_version": "17",
                    "superuser_password": "secret",
                },
                query_handler=fake_query,
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["details"], "result_too_large")

    def test_run_project_operation_execute_readonly_query_handles_runtime_failures(self):
        def header_failure_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "COPY (" in sql:
                return False, _FakeOutput(stderr_lines=["header failed"])
            raise AssertionError(sql)

        header_failure = self._run_project_operation(
            "project_execute_readonly_query",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "sql": "SELECT id FROM users",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=header_failure_query,
        )
        self.assertEqual(header_failure["status"], "error")
        self.assertIn("Could not inspect query columns", header_failure["msg"])

        def data_failure_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "COPY (" in sql:
                return True, _FakeOutput(stdout_lines=["id"])
            if "json_agg(row_to_json(t))" in sql:
                return False, _FakeOutput(stderr_lines=["data failed"])
            raise AssertionError(sql)

        data_failure = self._run_project_operation(
            "project_execute_readonly_query",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "sql": "SELECT id FROM users",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=data_failure_query,
        )
        self.assertEqual(data_failure["status"], "error")
        self.assertIn("Could not execute project database query", data_failure["msg"])

        def parse_failure_query(
            _session, _config, sql, database="postgres", emit=None, run_as_user=None
        ):
            del database, emit, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            if "COPY (" in sql:
                return True, _FakeOutput(stdout_lines=["id"])
            if "json_agg(row_to_json(t))" in sql:
                return True, _FakeOutput(stdout_lines=['{"id":"u_1"}'])
            raise AssertionError(sql)

        parse_failure = self._run_project_operation(
            "project_execute_readonly_query",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "sql": "SELECT id FROM users",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=parse_failure_query,
        )
        self.assertEqual(parse_failure["status"], "error")
        self.assertIn(
            "Could not parse project database query results",
            parse_failure["msg"],
        )

    def test_run_project_operation_execute_readonly_query_rejects_invalid_sql(self):
        def fake_query(_session, _config, sql, database="postgres", emit=None, run_as_user=None):
            del emit, database, run_as_user
            if "SELECT 1 FROM pg_database WHERE datname =" in sql:
                return True, _FakeOutput(stdout_lines=["1"])
            if "current_setting('server_version')" in sql:
                return True, _FakeOutput(stdout_lines=["17.8"])
            raise AssertionError(sql)

        result = self._run_project_operation(
            "project_execute_readonly_query",
            settings={
                "project_slug": "test",
                "database_name": "app",
                "sql": "DELETE FROM users",
                "postgres_version": "17",
                "superuser_password": "secret",
            },
            query_handler=fake_query,
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("SELECT or WITH", result["msg"])

    def test_run_runtime_operation_service_status_success(self):
        host = _FakeHost(
            status_output=_FakeOutput(
                stdout_lines=[
                    '{"running":true,"health":"healthy","version":"17.8","configured":true}',
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
                "session": _FakeSession(host=host),
            },
        )
        result = engine_postgres_ops.run_postgres_runtime_operation(
            ctx,
            "service_status",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            raw_data={"settings": {"postgres_version": "17", "superuser_password": "secret"}},
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["service_status"]["health"], "healthy")
        self.assertEqual(
            result["service_status"]["container_status"]["effective_status"],
            "ready",
        )

    def test_run_runtime_operation_unknown_operation(self):
        ctx = build_test_context(error_result=_error_result)
        result = engine_postgres_ops.run_postgres_runtime_operation(
            ctx,
            "invalid-op",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            dry_run=True,
            raw_data={"settings": {"postgres_version": "17", "superuser_password": "secret"}},
        )
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")

    def test_run_project_operation_list_when_service_stopped(self):
        host = _FakeHost(
            status_output=_FakeOutput(
                stdout_lines=[
                    '{"running":false,"health":"down","version":"17.8","configured":false}',
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
                    "project_slug": "test",
                    "postgres_version": "17",
                    "superuser_password": "secret",
                },
            },
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["databases"], [])
        self.assertEqual(result["users"], [])

    def test_run_project_operation_preflight_cancelled(self):
        ctx = build_test_context(error_result=_error_result)
        result = engine_postgres_ops.run_postgres_project_operation(
            ctx,
            "project_list",
            ip="198.51.100.8",
            username="ubuntu",
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "postgres_version": "17",
                    "superuser_password": "secret",
                },
            },
            is_cancelled=lambda: True,
        )
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")

    def test_run_runtime_operation_preflight_cancelled(self):
        ctx = build_test_context(error_result=_error_result)
        result = engine_postgres_ops.run_postgres_runtime_operation(
            ctx,
            "service_status",
            ip="198.51.100.8",
            username="ubuntu",
            raw_data={"settings": {"postgres_version": "17", "superuser_password": "secret"}},
            is_cancelled=lambda: True,
        )
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")

    def test_run_runtime_operation_open_session_error(self):
        ctx = build_test_context(
            error_result=_error_result,
            open_runtime_session=lambda **_kwargs: {
                "ok": False,
                "error": _error_result("ENGINE_RUNTIME_ERROR", "cannot connect"),
            },
        )
        result = engine_postgres_ops.run_postgres_runtime_operation(
            ctx,
            "service_status",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            raw_data={"settings": {"postgres_version": "17", "superuser_password": "secret"}},
        )
        self.assertEqual(result["msg"], "cannot connect")

    def test_run_project_operation_rotate_password_success(self):
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
            users_and_grants,
            _run_postgres_psql_query_impl=lambda *_args, **_kwargs: (
                True,
                _FakeOutput(stdout_lines=[]),
            ),
            _postgres_generated_password=lambda: "generated-pass",
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "project_rotate_password",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                        "username": "reader",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["password"], "generated-pass")
        self.assertEqual(result["username"], "reader")
        self.assertEqual(result["remote_username"], "dd_test_reader")

    def test_run_project_operation_open_session_error(self):
        ctx = build_test_context(
            error_result=_error_result,
            open_runtime_session=lambda **_kwargs: {
                "ok": False,
                "error": _error_result("ENGINE_RUNTIME_ERROR", "cannot connect"),
            },
        )
        result = engine_postgres_ops.run_postgres_project_operation(
            ctx,
            "project_rotate_password",
            ip="198.51.100.8",
            username="ubuntu",
            password="secret",
            raw_data={
                "settings": {
                    "project_slug": "test",
                    "postgres_version": "17",
                    "superuser_password": "secret",
                    "username": "reader",
                },
            },
        )
        self.assertEqual(result["msg"], "cannot connect")

    def test_run_project_operation_delete_user_scopes_cleanup_to_database(self):
        query_calls = []
        query_databases = []

        def _query_side_effect(_ctx, _session, _config, sql, **kwargs):
            query_calls.append(sql)
            query_databases.append(kwargs.get("database"))
            return True, _FakeOutput(stdout_lines=[])

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
        with patch.object(
            users_and_grants,
            "_run_postgres_psql_query_impl",
            side_effect=_query_side_effect,
        ):
            result = engine_postgres_ops.run_postgres_project_operation(
                ctx,
                "project_delete_user",
                ip="198.51.100.8",
                username="ubuntu",
                password="secret",
                raw_data={
                    "settings": {
                        "project_slug": "test",
                        "postgres_version": "17",
                        "superuser_password": "secret",
                        "database_name": "app",
                        "username": "reader",
                    },
                },
            )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "project_delete_user")
        self.assertEqual(result["database_name"], "app")
        self.assertEqual(result["deleted_database_name"], "app")
        self.assertEqual(result["remote_database_name"], "dd_test_app")
        self.assertEqual(result["username"], "reader")
        self.assertEqual(result["deleted_username"], "reader")
        self.assertEqual(result["remote_username"], "dd_test_reader")
        self.assertFalse(any("SELECT datname FROM pg_database" in sql for sql in query_calls))
        self.assertIn("dd_test_app", query_databases)


if __name__ == "__main__":
    unittest.main()
