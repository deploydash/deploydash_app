"""Pre-flight scanner for local `.sql` imports (#84).

The scanner reads the workstation dump before anything is uploaded and
reports the statements the hardened import cannot run, so failures surface
as guidance instead of opaque psql errors. The filter drops ownership and
privilege statements when the caller opts into ignoring them.
"""

from __future__ import annotations

import tempfile
import unittest

from orchestrator.postgres_runtime_parts import local_import_scan


class TestLocalSqlImportScan(unittest.TestCase):
    def _scan(self, payload, **kwargs):
        # Why: every scan case needs the same bytes-on-disk fixture without
        # repeating the temp-file dance.
        with tempfile.NamedTemporaryFile(suffix=".sql") as handle:
            handle.write(payload)
            handle.flush()
            return local_import_scan._scan_local_sql_dump(handle.name, **kwargs)

    def _filter(self, payload, **kwargs):
        # Why: filter cases assert on both the drop count and the exact
        # surviving bytes, which needs two temp files per case.
        with tempfile.NamedTemporaryFile(suffix=".sql") as source:
            source.write(payload)
            source.flush()
            with tempfile.NamedTemporaryFile(suffix=".sql") as dest:
                result = local_import_scan._write_filtered_sql_dump(
                    source.name,
                    dest.name,
                    **kwargs,
                )
                with open(dest.name, "rb") as handle:
                    return result, handle.read()

    def test_clean_dump_scans_without_findings(self):
        report = self._scan(
            b"-- plain dump\n"
            b";\n"
            b"CREATE TABLE public.demo(id integer);\n"
            b"CREATE TABLE public.split(\n"
            b"id integer\n"
            b");\n"
            b"INSERT INTO public.demo VALUES (1), (2);\n"
            b"SELECT $1;\n"
            b"SELECT 1-2;\n"
            b"SELECT 4/2;\n"
        )
        self.assertEqual(report["blocking"], [])
        self.assertEqual(report["ownership_statement_count"], 0)
        self.assertEqual(report["notices"], [])

    def test_create_database_is_blocked_with_reexport_guidance(self):
        report = self._scan(b"CREATE TABLE public.demo(id integer);\nCREATE DATABASE otherdb;\n")
        self.assertEqual(len(report["blocking"]), 1)
        finding = report["blocking"][0]
        self.assertEqual(finding["code"], "create_database")
        self.assertEqual(finding["line"], 2)
        self.assertIn("without pg_dump -C", finding["message"])

    def test_connect_commands_are_blocked(self):
        for meta in (b"\\connect otherdb\n", b"\\c otherdb\n"):
            with self.subTest(meta=meta):
                report = self._scan(b"SELECT 1;\n" + meta)
                self.assertEqual(len(report["blocking"]), 1)
                finding = report["blocking"][0]
                self.assertEqual(finding["code"], "connect_command")
                self.assertEqual(finding["line"], 2)
                self.assertIn("without pg_dump -C", finding["message"])

    def test_missing_extension_is_blocked_with_enable_guidance(self):
        report = self._scan(
            b'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";\n',
            enabled_extensions=(),
        )
        self.assertEqual(len(report["blocking"]), 1)
        finding = report["blocking"][0]
        self.assertEqual(finding["code"], "missing_extension")
        self.assertEqual(finding["line"], 1)
        self.assertIn("uuid-ossp", finding["message"])
        self.assertIn("Database settings", finding["message"])

    def test_enabled_and_builtin_extensions_scan_clean(self):
        report = self._scan(
            b"CREATE EXTENSION IF NOT EXISTS plpgsql;\n"
            b"COMMENT ON EXTENSION plpgsql IS 'PL/pgSQL';\n"
            b"CREATE EXTENSION hstore SCHEMA public;\n"
            b"COMMENT ON EXTENSION hstore IS 'key value store';\n",
            enabled_extensions=("hstore",),
        )
        self.assertEqual(report["blocking"], [])
        self.assertEqual(report["extension_statement_count"], 4)

    def test_enabled_extension_statements_are_filtered_without_losing_other_comments(self):
        """Keep application comments while Deploy Dash owns extension metadata."""
        payload = (
            b"CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA public;\n"
            b"COMMENT ON EXTENSION hstore IS 'key value store';\n"
            b"CREATE TABLE public.demo(id integer);\n"
            b"COMMENT ON TABLE public.demo IS 'application table';\n"
        )

        result, filtered = self._filter(
            payload,
            enabled_extensions=("hstore",),
            drop_extensions=True,
        )

        self.assertEqual(result["dropped_extension_statements"], 2)
        self.assertNotIn(b"EXTENSION hstore", filtered)
        self.assertIn(b"CREATE TABLE public.demo", filtered)
        self.assertIn(b"COMMENT ON TABLE public.demo", filtered)

    def test_unparseable_create_extension_is_blocked(self):
        report = self._scan(b"CREATE EXTENSION;\n")
        self.assertEqual(len(report["blocking"]), 1)
        self.assertEqual(report["blocking"][0]["code"], "missing_extension")

    def test_ownership_statements_are_counted_not_blocked(self):
        report = self._scan(
            b"ALTER TABLE public.demo OWNER TO oldrole;\n"
            b"GRANT SELECT ON public.demo TO oldrole;\n"
            b"REVOKE ALL ON public.demo FROM oldrole;\n"
            b"ALTER DEFAULT PRIVILEGES FOR ROLE oldrole GRANT SELECT ON TABLES TO reader;\n"
        )
        self.assertEqual(report["blocking"], [])
        self.assertEqual(report["ownership_statement_count"], 4)

    def test_concurrently_is_blocked(self):
        report = self._scan(
            b"create index concurrently demo_idx on public.demo(id);\n",
        )
        self.assertEqual(len(report["blocking"]), 1)
        finding = report["blocking"][0]
        self.assertEqual(finding["code"], "concurrent_statement")
        self.assertIn("single transaction", finding["message"])

    def test_role_statements_are_blocked(self):
        for statement in (
            b"CREATE ROLE otherrole LOGIN;\n",
            b"ALTER ROLE otherrole SET search_path TO public;\n",
            b"DROP ROLE otherrole;\n",
        ):
            with self.subTest(statement=statement):
                report = self._scan(statement)
                self.assertEqual(len(report["blocking"]), 1)
                self.assertEqual(report["blocking"][0]["code"], "role_statement")

    def test_alter_system_is_blocked(self):
        report = self._scan(b"ALTER SYSTEM SET shared_buffers TO '256MB';\n")
        self.assertEqual(len(report["blocking"]), 1)
        self.assertEqual(report["blocking"][0]["code"], "alter_system")

    def test_session_authorization_is_blocked(self):
        report = self._scan(b"SET SESSION AUTHORIZATION 'otherrole';\n")
        self.assertEqual(len(report["blocking"]), 1)
        self.assertEqual(report["blocking"][0]["code"], "session_authorization")

    def test_copy_data_is_opaque_to_the_scanner(self):
        report = self._scan(
            b"COPY public.demo (id, note) FROM stdin;\n"
            b"1\tCREATE DATABASE sneaky;\n"
            b"2\t\\connect sneaky\n"
            b"3\tALTER TABLE x OWNER TO sneaky;\n"
            b"\\.\n"
            b"SELECT 1;\n",
        )
        self.assertEqual(report["blocking"], [])
        self.assertEqual(report["ownership_statement_count"], 0)

    def test_dollar_quoted_bodies_do_not_split_or_match(self):
        report = self._scan(
            b"CREATE FUNCTION public.noop() RETURNS void LANGUAGE plpgsql AS $$\n"
            b"BEGIN\n"
            b"  GRANT SELECT ON t TO r; -- not a statement\n"
            b"\\connect nope\n"
            b"  RAISE NOTICE 'done;';\n"
            b"END;\n"
            b"$$;\n"
            b"CREATE TABLE public.afterfn(id integer);\n",
        )
        self.assertEqual(report["blocking"], [])
        self.assertEqual(report["ownership_statement_count"], 0)

    def test_quoted_strings_and_comments_do_not_split_or_match(self):
        report = self._scan(
            b"-- CREATE DATABASE commented;\n"
            b"/* CREATE ROLE commented;\n"
            b"   \\connect commented\n"
            b"   /* nested; still a comment */\n"
            b"*/\n"
            b"INSERT INTO public.demo VALUES ('it''; CREATE DATABASE sneaky; s');\n"
            b"INSERT INTO public.demo VALUES (E'a\\'b; CREATE DATABASE sneaky; c');\n"
            b'CREATE TABLE "we;ird" (id integer);\n'
            b"SELECT weedE'x';\n",
        )
        self.assertEqual(report["blocking"], [])
        self.assertEqual(report["ownership_statement_count"], 0)

    def test_shell_escape_is_a_notice_not_a_blocker(self):
        report = self._scan(b"SELECT 1;\n\\! id\n")
        self.assertEqual(report["blocking"], [])
        self.assertEqual(len(report["notices"]), 1)
        notice = report["notices"][0]
        self.assertEqual(notice["code"], "shell_escape")
        self.assertEqual(notice["line"], 2)
        self.assertIn("throwaway", notice["message"])

    def test_file_inclusion_metas_are_blocked(self):
        for meta, code in (
            (b"\\include '/tmp/other.sql'\n", "include_command"),
            (b"\\ir other.sql\n", "include_command"),
            (b"\\copy public.demo FROM '/tmp/data.csv'\n", "copy_command"),
        ):
            with self.subTest(meta=meta):
                report = self._scan(meta)
                self.assertEqual(len(report["blocking"]), 1)
                self.assertEqual(report["blocking"][0]["code"], code)

    def test_truncated_file_is_blocked(self):
        report = self._scan(b"CREATE TABLE public.demo(id integer")
        self.assertEqual(len(report["blocking"]), 1)
        finding = report["blocking"][0]
        self.assertEqual(finding["code"], "unterminated_statement")
        self.assertEqual(finding["line"], 1)

    def test_backslash_lines_inside_strings_are_not_meta(self):
        report = self._scan(
            b"INSERT INTO public.demo VALUES ('first\n\\! id\nlast');\n",
        )
        self.assertEqual(report["blocking"], [])
        self.assertEqual(report["notices"], [])

    def test_meta_between_statement_lines_does_not_break_the_statement(self):
        # psql keeps the query buffer across a meta-command line, so CREATE
        # above the \echo and DATABASE below it are one statement. The scan
        # must see the same statement psql would run.
        report = self._scan(
            b"CREATE\n\\echo still one statement\nDATABASE sneaky;\n",
        )
        self.assertEqual(len(report["blocking"]), 1)
        self.assertEqual(report["blocking"][0]["code"], "create_database")
        self.assertEqual(report["blocking"][0]["line"], 1)
        self.assertEqual(report["notices"], [])

    def test_unknown_meta_and_empty_file_scan_clean(self):
        report = self._scan(b"\\\\\\\\\n")
        self.assertEqual(report["blocking"], [])
        self.assertEqual(report["notices"], [])
        report = self._scan(b"")
        self.assertEqual(report["blocking"], [])
        self.assertEqual(report["ownership_statement_count"], 0)

    def test_eof_quote_without_newline_closes_cleanly(self):
        report = self._scan(b"SELECT 'a'")
        self.assertEqual(len(report["blocking"]), 1)
        self.assertEqual(report["blocking"][0]["code"], "unterminated_statement")

    def test_filter_drops_only_ownership_statements(self):
        payload = (
            b"CREATE TABLE public.demo(id integer);\n"
            b"ALTER TABLE public.demo OWNER TO oldrole;\n"
            b"ALTER TABLE public.demo ADD COLUMN note text;\n"
            b"GRANT SELECT ON public.demo TO oldrole;\n"
            b"INSERT INTO public.demo VALUES ('GRANT is just text');\n"
            b"REVOKE ALL ON public.demo FROM oldrole;\n"
            b"ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO reader;\n"
            b"COPY public.demo (id) FROM stdin;\n"
            b"1\n"
            b"\\.\n"
        )
        result, filtered = self._filter(payload)
        self.assertEqual(result["dropped_statements"], 4)
        self.assertEqual(
            filtered,
            b"CREATE TABLE public.demo(id integer);\n"
            b"ALTER TABLE public.demo ADD COLUMN note text;\n"
            b"INSERT INTO public.demo VALUES ('GRANT is just text');\n"
            b"COPY public.demo (id) FROM stdin;\n"
            b"1\n"
            b"\\.\n",
        )

    def test_filter_preserves_rename_of_column_named_owner(self):
        """Keep schema changes whose identifiers happen to contain `owner`."""
        payload = (
            b"ALTER TABLE public.demo RENAME COLUMN owner TO account_owner;\n"
            b"ALTER TABLE public.demo OWNER TO app_owner;\n"
        )

        result, filtered = self._filter(payload)

        self.assertEqual(result["dropped_statements"], 1)
        self.assertEqual(
            filtered,
            b"ALTER TABLE public.demo RENAME COLUMN owner TO account_owner;\n",
        )

    def test_filter_preserves_non_utf8_bytes(self):
        payload = b"CREATE TABLE public.demo(id integer);\nINSERT INTO t VALUES ('caf\xe9');\n"
        result, filtered = self._filter(payload)
        self.assertEqual(result["dropped_statements"], 0)
        self.assertEqual(filtered, payload)
        report = self._scan(payload)
        self.assertEqual(report["blocking"], [])


if __name__ == "__main__":
    unittest.main()
