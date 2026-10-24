"""Pure parsers, SQL builders and output helpers.

One of four files T-3.6.2 split `postgres_helpers_test.py` into. Fixtures and
the base case are in `tests/postgres_helpers_support.py`.
"""

from __future__ import annotations

import inspect
import re
import unittest
from datetime import UTC, datetime, timedelta

from tests.postgres_helpers_support import (
    PostgresHelpersTestCase,
    _config,
    _FakeOutput,
    agent_access,
    engine_postgres_ops,
    patch,
    tempfile,
)


class TestPostgresParsers(PostgresHelpersTestCase):
    def test_parse_postgres_role_comment(self):
        parsed = engine_postgres_ops._parse_postgres_role_comment(
            "deploydash:db=dd_demo_app;access=read_only",
        )
        self.assertEqual(parsed["database"], "dd_demo_app")
        self.assertEqual(parsed["access_mode"], "read_only")
        fallback = engine_postgres_ops._parse_postgres_role_comment("other")
        self.assertEqual(fallback["access_mode"], "read_write")

    def test_parse_postgres_role_comment_returns_the_owning_project(self):
        parsed = engine_postgres_ops._parse_postgres_role_comment(
            "deploydash:project=shop;db=dd_shop_main;access=read_only",
        )
        self.assertEqual(parsed["project"], "shop")
        self.assertEqual(parsed["database"], "dd_shop_main")
        self.assertEqual(parsed["access_mode"], "read_only")
        fallback = engine_postgres_ops._parse_postgres_role_comment("other")
        self.assertIsNone(fallback["project"])

    def test_assign_ddl_ownership_sql_hands_database_and_public_objects_to_the_owner(self):
        # #81: the builder used to transfer ownership to whichever user was
        # created last. It now ensures the stable owner role owns everything,
        # and runs at database creation and normalization only.
        sql = engine_postgres_ops._postgres_assign_ddl_ownership_sql(
            "dd_test_app",
            "deploydash_owner_dd_test_app_770b1081f7ad",
        )
        self.assertIn(
            'ALTER DATABASE "dd_test_app" OWNER TO "deploydash_owner_dd_test_app_770b1081f7ad";',
            sql,
        )
        self.assertIn(
            'ALTER SCHEMA public OWNER TO "deploydash_owner_dd_test_app_770b1081f7ad";',
            sql,
        )
        self.assertIn("ALTER TABLE %I.%I OWNER TO %I", sql)
        self.assertIn("ALTER SEQUENCE %I.%I OWNER TO %I", sql)
        self.assertIn("AND d.deptype IN ('a', 'i')", sql)
        self.assertIn("'deploydash_owner_dd_test_app_770b1081f7ad'", sql)

    def test_reclaim_ddl_ownership_sql_returns_owned_objects_to_current_user(self):
        sql = engine_postgres_ops._postgres_reclaim_ddl_ownership_sql(
            "dd_test_app",
            "dd_test_app_user",
        )
        self.assertIn('ALTER DATABASE "dd_test_app" OWNER TO CURRENT_USER;', sql)
        self.assertIn("ALTER SCHEMA public OWNER TO CURRENT_USER;", sql)
        self.assertIn("JOIN pg_roles r ON r.oid = d.datdba", sql)
        self.assertIn("JOIN pg_roles r ON r.oid = c.relowner", sql)
        self.assertIn("ALTER TABLE %I.%I OWNER TO %I", sql)
        self.assertIn("ALTER SEQUENCE %I.%I OWNER TO %I", sql)
        self.assertIn("AND d.deptype IN ('a', 'i')", sql)
        self.assertIn("current_user", sql)

    def test_ensure_owner_role_sql_creates_a_nologin_role_idempotently(self):
        sql = engine_postgres_ops._postgres_ensure_owner_role_sql(
            "deploydash_owner_dd_shop_db_67a59fc5ef19",
        )
        self.assertIn(
            "IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = "
            "'deploydash_owner_dd_shop_db_67a59fc5ef19') THEN "
            'CREATE ROLE "deploydash_owner_dd_shop_db_67a59fc5ef19" NOLOGIN;',
            sql,
        )
        self.assertNotIn("LOGIN PASSWORD", sql)

    def test_owner_membership_sql_pins_the_session_role_only_in_its_database(self):
        """Prevent one login's second database from changing its first database role."""
        parameters = inspect.signature(
            engine_postgres_ops._postgres_owner_membership_sql,
        ).parameters
        self.assertIn("database_name", parameters)
        sql = engine_postgres_ops._postgres_owner_membership_sql(
            "deploydash_owner_dd_shop_db_67a59fc5ef19",
            "dd_shop_db_user",
            database_name="dd_shop_db",
        )
        self.assertIn(
            'GRANT "deploydash_owner_dd_shop_db_67a59fc5ef19" TO "dd_shop_db_user";',
            sql,
        )
        self.assertIn(
            'ALTER ROLE "dd_shop_db_user" IN DATABASE "dd_shop_db" '
            'SET role = "deploydash_owner_dd_shop_db_67a59fc5ef19";',
            sql,
        )
        self.assertNotIn('ALTER ROLE "dd_shop_db_user" SET role', sql)

    def test_reassign_owned_if_exists_sql_skips_roles_that_do_not_exist(self):
        # #81: delete-database appends the derived owner to the cleanup
        # list even when it was never created. A bare REASSIGN OWNED BY
        # fails for a missing role, so the cleanup probes pg_roles first.
        sql = engine_postgres_ops._postgres_reassign_owned_if_exists_sql(
            "deploydash_owner_dd_shop_db_67a59fc5ef19",
        )
        self.assertIn(
            "IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = "
            "'deploydash_owner_dd_shop_db_67a59fc5ef19') THEN",
            sql,
        )
        self.assertIn(
            'REASSIGN OWNED BY "deploydash_owner_dd_shop_db_67a59fc5ef19" TO CURRENT_USER;',
            sql,
        )
        self.assertIn(
            'DROP OWNED BY "deploydash_owner_dd_shop_db_67a59fc5ef19";',
            sql,
        )

    def test_existing_roles_sql_lists_which_of_the_roles_still_exist(self):
        # #81: delete-database verifies the dropped users are actually
        # gone before it unregisters them, so the check reads live
        # pg_roles rather than the registry rows.
        sql = engine_postgres_ops._postgres_existing_roles_sql(
            [
                "dd_shop_db_user",
                "deploydash_owner_dd_shop_db_67a59fc5ef19",
            ],
        )
        self.assertEqual(
            sql,
            "SELECT rolname FROM pg_roles "
            "WHERE rolname IN ('dd_shop_db_user', "
            "'deploydash_owner_dd_shop_db_67a59fc5ef19') "
            "ORDER BY rolname;",
        )

    def test_ensure_agent_reader_role_sql_creates_a_passwordless_login_with_limits(self):
        # #83: the agent tools log in as this role instead of the
        # superuser. LOGIN with no password: reachable over the trusted
        # container socket, unreachable over TCP where SCRAM applies. The
        # limits converge on every run so an older role gets them too.
        sql = engine_postgres_ops._postgres_ensure_agent_reader_role_sql(
            "deploydash_agent_reader_dd_shop_db_67a59fc5ef19",
        )
        self.assertIn(
            "IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = "
            "'deploydash_agent_reader_dd_shop_db_67a59fc5ef19') THEN "
            'CREATE ROLE "deploydash_agent_reader_dd_shop_db_67a59fc5ef19" '
            "LOGIN CONNECTION LIMIT 2;",
            sql,
        )
        self.assertIn(
            'ALTER ROLE "deploydash_agent_reader_dd_shop_db_67a59fc5ef19" '
            "SET default_transaction_read_only = on;",
            sql,
        )
        self.assertIn("SET statement_timeout = '30s';", sql)
        self.assertIn("SET idle_in_transaction_session_timeout = '60s';", sql)
        self.assertIn("SET temp_file_limit = '512MB';", sql)
        self.assertNotIn("PASSWORD", sql)
        self.assertNotIn("SUPERUSER", sql)

    def test_agent_reader_grants_sql_connects_and_reads_one_database_only(self):
        # #83: explicit grants on its one database, never pg_read_all_data
        # (cluster-wide). Default privileges run FOR ROLE the owner, which
        # is the role that actually creates objects (#81).
        sql = engine_postgres_ops._postgres_agent_reader_grants_sql(
            "dd_shop_db",
            "deploydash_owner_dd_shop_db_67a59fc5ef19",
            "deploydash_agent_reader_dd_shop_db_67a59fc5ef19",
        )
        self.assertIn(
            'GRANT CONNECT ON DATABASE "dd_shop_db" '
            'TO "deploydash_agent_reader_dd_shop_db_67a59fc5ef19";',
            sql,
        )
        self.assertIn(
            'GRANT USAGE ON SCHEMA public TO "deploydash_agent_reader_dd_shop_db_67a59fc5ef19";',
            sql,
        )
        self.assertIn(
            'GRANT SELECT ON ALL TABLES IN SCHEMA public TO "deploydash_agent_reader_dd_shop_db_67a59fc5ef19";',
            sql,
        )
        self.assertIn(
            "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public "
            'TO "deploydash_agent_reader_dd_shop_db_67a59fc5ef19";',
            sql,
        )
        self.assertIn(
            'ALTER DEFAULT PRIVILEGES FOR ROLE "deploydash_owner_dd_shop_db_67a59fc5ef19" '
            'IN SCHEMA public GRANT SELECT ON TABLES TO "deploydash_agent_reader_dd_shop_db_67a59fc5ef19";',
            sql,
        )
        self.assertNotIn("pg_read_all_data", sql)

    def test_revoke_public_connect_sql_cuts_public_connect_and_temp(self):
        sql = engine_postgres_ops._postgres_revoke_public_connect_sql("dd_shop_db")
        self.assertEqual(
            sql,
            'REVOKE CONNECT, TEMP ON DATABASE "dd_shop_db" FROM PUBLIC;',
        )

    def test_owner_default_privileges_sql_grants_for_the_owner_role(self):
        sql = engine_postgres_ops._postgres_owner_default_privileges_sql(
            "deploydash_owner_dd_shop_db_67a59fc5ef19",
            "dd_shop_db_reader",
        )
        self.assertIn(
            'ALTER DEFAULT PRIVILEGES FOR ROLE "deploydash_owner_dd_shop_db_67a59fc5ef19" '
            'IN SCHEMA public GRANT SELECT ON TABLES TO "dd_shop_db_reader";',
            sql,
        )
        self.assertIn(
            'ALTER DEFAULT PRIVILEGES FOR ROLE "deploydash_owner_dd_shop_db_67a59fc5ef19" '
            "IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES "
            'TO "dd_shop_db_reader";',
            sql,
        )

    def test_implicit_connect_roles_sql_lists_login_roles_without_an_explicit_grant(self):
        sql = engine_postgres_ops._postgres_implicit_connect_roles_sql("dd_shop_db")
        self.assertIn("FROM pg_roles r", sql)
        self.assertIn("JOIN pg_database d ON d.datname = 'dd_shop_db'", sql)
        self.assertIn("r.rolcanlogin", sql)
        self.assertIn("NOT r.rolsuper", sql)
        self.assertIn("has_database_privilege(r.rolname, d.oid, 'CONNECT')", sql)
        self.assertIn("aclexplode(d.datacl)", sql)
        self.assertIn("ORDER BY r.rolname;", sql)

    def test_postgres_output_has_one(self):
        self.assertTrue(engine_postgres_ops._postgres_output_has_one(_FakeOutput(["0", "1"])))
        self.assertFalse(engine_postgres_ops._postgres_output_has_one(_FakeOutput(["0", "2"])))

    def test_temp_import_role_sql_creates_an_expiring_login_member_of_the_owner(self):
        # #84: the throwaway client logs in as this role over TCP, so it
        # carries a password where the socket-only reader (#83) has none.
        # Membership plus the pinned session role makes it act as the
        # owner; VALID UNTIL bounds a role whose drop is ever skipped.
        # PostgreSQL only accepts a timestamp literal here, never an
        # expression: the live proof rejected VALID UNTIL (now() + ...).
        before = datetime.now(UTC)
        sql = engine_postgres_ops._postgres_temp_import_role_sql(
            "deploydash_import_a1b2c3d4e5f60718",
            "secret-password",
            "dd_shop_db",
            "deploydash_owner_dd_shop_db_67a59fc5ef19",
        )
        after = datetime.now(UTC)
        self.assertIn(
            "CREATE ROLE \"deploydash_import_a1b2c3d4e5f60718\" LOGIN PASSWORD 'secret-password' ",
            sql,
        )
        match = re.search(
            r"VALID UNTIL '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\+00' "
            r"CONNECTION LIMIT 1;",
            sql,
        )
        self.assertIsNotNone(match, sql)
        expiry = datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=UTC)
        self.assertGreaterEqual(expiry, before + timedelta(hours=3) - timedelta(minutes=1))
        self.assertLessEqual(expiry, after + timedelta(hours=3) + timedelta(minutes=1))
        self.assertIn(
            'GRANT CONNECT ON DATABASE "dd_shop_db" TO "deploydash_import_a1b2c3d4e5f60718";',
            sql,
        )
        self.assertIn(
            'GRANT "deploydash_owner_dd_shop_db_67a59fc5ef19" '
            'TO "deploydash_import_a1b2c3d4e5f60718";',
            sql,
        )
        self.assertNotIn("SUPERUSER", sql)

    def test_drop_temp_import_role_sql_reassigns_guarded_and_drops(self):
        # #84: the import session pins the owner role, but a dump that
        # resets it could leave objects behind under the temp login, so
        # the drop reassigns first. Existence-guarded like #81: the create
        # may have failed halfway yet the drop still runs on every path.
        sql = engine_postgres_ops._postgres_drop_temp_import_role_sql(
            "deploydash_import_a1b2c3d4e5f60718",
            "deploydash_owner_dd_shop_db_67a59fc5ef19",
        )
        self.assertIn(
            "IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = "
            "'deploydash_import_a1b2c3d4e5f60718') THEN",
            sql,
        )
        self.assertIn(
            'REASSIGN OWNED BY "deploydash_import_a1b2c3d4e5f60718" '
            'TO "deploydash_owner_dd_shop_db_67a59fc5ef19";',
            sql,
        )
        self.assertIn(
            'DROP OWNED BY "deploydash_import_a1b2c3d4e5f60718";',
            sql,
        )
        self.assertIn(
            'DROP ROLE IF EXISTS "deploydash_import_a1b2c3d4e5f60718";',
            sql,
        )

    def test_local_sql_import_command_runs_psql_in_a_throwaway_client(self):
        # #84: psql runs in a disposable same-image container over TCP
        # with a single transaction, never as the superuser in the
        # database container. The pinned session role owns imported
        # objects correctly.
        cfg = _config(project_slug="test", superuser_password="secret")
        command = engine_postgres_ops._postgres_local_sql_import_command(
            cfg,
            database_name="dd_shop_db",
            remote_path="/tmp/staged.d/dump.sql",
            import_role="deploydash_import_a1b2c3d4e5f60718",
            import_password="secret-password",
            owner_role="deploydash_owner_dd_shop_db_67a59fc5ef19",
        )
        self.assertIn("docker run --rm -i --read-only --cap-drop ALL", command)
        self.assertIn("--security-opt no-new-privileges", command)
        self.assertIn("--add-host host.docker.internal:host-gateway", command)
        self.assertIn(
            engine_postgres_ops._postgres_runtime_image_name(cfg),
            command,
        )
        self.assertIn("--single-transaction", command)
        self.assertIn("-v ON_ERROR_STOP=1", command)
        self.assertIn("-h host.docker.internal", command)
        self.assertIn("role=deploydash_owner_dd_shop_db_67a59fc5ef19", command)
        self.assertIn("deploydash_import_a1b2c3d4e5f60718", command)
        self.assertIn(
            engine_postgres_ops._LOCAL_SQL_IMPORT_SUCCESS_MARKER,
            command,
        )
        # The readiness probe in the env prefix still uses docker exec;
        # the import itself must not run psql in the database container.
        self.assertNotIn('"${CONTAINER_NAME}" psql', command)
        client_part = command.split("docker run --rm", 1)[1]
        self.assertNotIn("docker exec", client_part)
        # The staged-file check must run on the server shell before the
        # client starts: placed after the image name it would execute
        # inside the throwaway container, where the path never exists.
        self.assertLess(
            command.index('[ -f "${IMPORT_FILE}" ]'),
            command.index("docker run --rm"),
        )

    def test_local_pg_restore_command_restores_custom_dumps_in_a_throwaway_client(self):
        # #84: custom-format dumps restore through pg_restore in the same
        # throwaway client, with ownership and privileges always dropped
        # and the owner session pinned, inside one transaction.
        cfg = _config(project_slug="test", superuser_password="secret")
        command = engine_postgres_ops._postgres_local_pg_restore_command(
            cfg,
            database_name="dd_shop_db",
            remote_path="/tmp/staged.d/backup.dump",
            import_role="deploydash_import_a1b2c3d4e5f60718",
            import_password="secret-password",
            owner_role="deploydash_owner_dd_shop_db_67a59fc5ef19",
        )
        self.assertIn("docker run --rm -i --read-only --cap-drop ALL", command)
        self.assertIn("--security-opt no-new-privileges", command)
        self.assertIn("--add-host host.docker.internal:host-gateway", command)
        self.assertIn(
            engine_postgres_ops._postgres_runtime_image_name(cfg),
            command,
        )
        self.assertIn("pg_restore", command)
        self.assertIn("pg_restore --list", command)
        self.assertIn("--use-list", command)
        self.assertIn("COMMENT - EXTENSION", command)
        self.assertIn("SECURITY LABEL - EXTENSION", command)
        self.assertNotIn("--no-comments", command)
        self.assertIn("--no-owner --no-privileges", command)
        self.assertIn("--single-transaction", command)
        self.assertIn("--exit-on-error", command)
        self.assertIn("--role=deploydash_owner_dd_shop_db_67a59fc5ef19", command)
        self.assertIn("-h host.docker.internal", command)
        self.assertIn("deploydash_import_a1b2c3d4e5f60718", command)
        self.assertIn(
            engine_postgres_ops._LOCAL_SQL_IMPORT_SUCCESS_MARKER,
            command,
        )
        self.assertNotIn('"${CONTAINER_NAME}"', command.split("docker run --rm", 1)[1])
        # Same server-shell-first ordering as the psql command: the check
        # after the image name would run inside the throwaway container.
        self.assertLess(
            command.index('[ -f "${IMPORT_FILE}" ]'),
            command.index("docker run --rm"),
        )

    def test_resolve_local_sql_import_payload(self):
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            cfg = _config(
                project_slug="test",
                database_name="restore_target",
                import_local_file_path=handle.name,
            )
            payload = engine_postgres_ops._resolve_local_sql_import_payload(
                cfg,
                "dd_test_",
                validate_local_file=True,
            )

        self.assertEqual(payload["database_name"], "dd_test_restore_target")
        self.assertEqual(payload["local_file_path"], handle.name)
        self.assertTrue(payload["remote_path"].startswith("/tmp/deploydash-postgres-import-"))
        self.assertEqual(payload["size_bytes"], 0)

    def test_helper_fallback_paths_cover_prefix_wrapping_and_empty_outputs(self):
        self.assertIsNone(
            engine_postgres_ops._postgres_strip_project_prefix("dd_test_", None),
        )
        self.assertEqual(
            engine_postgres_ops._postgres_strip_project_prefix(
                "dd_test_",
                "external_name",
            ),
            "external_name",
        )
        self.assertEqual(
            engine_postgres_ops._postgres_agent_wrapped_query("SELECT 1"),
            "SELECT * FROM (SELECT 1) AS deploydash_query",
        )
        self.assertEqual(
            engine_postgres_ops._postgres_collect_csv_columns(_FakeOutput()),
            [],
        )
        with patch.object(agent_access.csv, "reader", return_value=iter(())):
            self.assertEqual(
                engine_postgres_ops._postgres_collect_csv_columns(
                    _FakeOutput(stdout_lines=["header"]),
                ),
                [],
            )
        self.assertEqual(
            engine_postgres_ops._postgres_collect_json_rows(_FakeOutput()),
            [],
        )
        self.assertEqual(
            engine_postgres_ops._postgres_collect_json_rows(
                _FakeOutput(stdout_lines=["", "   "]),
            ),
            [],
        )


if __name__ == "__main__":
    unittest.main()
