import unittest

from orchestrator.postgres_parts.postgres_config import (
    PostgresConfigValidationError,
    parse_postgres_service_config,
)


class TestPostgresConfig(unittest.TestCase):
    def test_defaults_are_valid(self):
        config = parse_postgres_service_config(None)
        self.assertEqual(config.postgres_version, "17")
        self.assertEqual(config.host_port, 5432)

    def test_accepts_supported_versions(self):
        for version in ("16", "17", "18"):
            config = parse_postgres_service_config({"settings": {"postgres_version": version}})
            self.assertEqual(config.postgres_version, version)

    def test_rejects_unsupported_version(self):
        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"postgres_version": "15"}},
            )

    def test_rejects_unknown_setting_keys(self):
        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"postgres_version": "17", "unexpected": True}},
            )

    def test_missing_settings_object_falls_back_to_defaults(self):
        config = parse_postgres_service_config({})
        self.assertEqual(config.access_mode, "read_write")
        self.assertEqual(config.backup_schedule_mode, "daily_once")

    def test_accepts_known_extension_list(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "enabled_extensions": [
                        "pgcrypto",
                        "pg_trgm",
                        "vector",
                        "pg_search",
                        "postgis",
                        "uuid-ossp",
                        "pg_stat_statements",
                    ],
                },
            }
        )
        self.assertEqual(
            config.enabled_extensions,
            (
                "pgcrypto",
                "pg_trgm",
                "vector",
                "pg_search",
                "postgis",
                "uuid-ossp",
                "pg_stat_statements",
            ),
        )

    def test_rejects_unknown_extension_name(self):
        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {
                    "settings": {
                        "enabled_extensions": [
                            "pgcrypto",
                            "not-a-real-extension",
                        ],
                    },
                },
            )

    def test_explicit_nulls_and_string_inputs_are_normalized(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "host_port": "5432",
                    "superuser_password": "   ",
                    "enabled_extensions": [
                        " pgcrypto ",
                        " ",
                        "vector",
                        "pg_search",
                        "vector",
                    ],
                    "project_slug": "   ",
                    "database_name": " app_db ",
                    "schema_name": " public ",
                    "table_name": " users ",
                    "sql": " SELECT * FROM users ",
                    "max_rows": "25",
                    "username": " app_user ",
                    "password": " secret ",
                    "access_mode": None,
                    "backup_schedule_mode": None,
                    "backup_time1": None,
                    "backup_retention_keep_last": "12",
                    "backup_artifact_path": " artifact.tar.zst ",
                    "backup_aws_force_path_style": "yes",
                    "enabled": "off",
                },
            }
        )

        self.assertIsNone(config.superuser_password)
        self.assertEqual(
            config.enabled_extensions,
            ("pgcrypto", "vector", "pg_search"),
        )
        self.assertIsNone(config.project_slug)
        self.assertEqual(config.database_name, "app_db")
        self.assertEqual(config.schema_name, "public")
        self.assertEqual(config.table_name, "users")
        self.assertEqual(config.sql, "SELECT * FROM users")
        self.assertEqual(config.max_rows, 25)
        self.assertEqual(config.username, "app_user")
        self.assertEqual(config.password, "secret")
        self.assertEqual(config.access_mode, "read_write")
        self.assertEqual(config.backup_schedule_mode, "daily_once")
        self.assertEqual(config.backup_time1, "02:00")
        self.assertEqual(config.backup_retention_keep_last, 12)
        self.assertEqual(config.backup_artifact_path, "artifact.tar.zst")
        self.assertTrue(config.backup_aws_force_path_style)
        self.assertFalse(config.enabled)

    def test_optional_extension_list_accepts_null(self):
        config = parse_postgres_service_config(
            {"settings": {"enabled_extensions": None}},
        )
        self.assertEqual(config.enabled_extensions, ())

    def test_rejects_invalid_settings_shapes(self):
        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config({"settings": "bad"})

        # postgres_version rather than stack_root/container_name: since
        # T-1.1.4/T-1.4.4 those raise for being server-owned before the
        # empty-string check is ever reached, so this would assert nothing
        # about invalid shapes.
        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"postgres_version": ""}},
            )

    def test_rejects_invalid_ports_and_integer_inputs(self):
        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"host_port": 5433}},
            )

        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"host_port": True}},
            )

        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"backup_retention_keep_last": "abc"}},
            )

        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"backup_retention_keep_last": "   "}},
            )

        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"backup_retention_keep_last": []}},
            )

    def test_rejects_invalid_optional_string_and_boolean_inputs(self):
        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"superuser_password": 123}},
            )

        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"backup_aws_force_path_style": "maybe"}},
            )

        config = parse_postgres_service_config(
            {"settings": {"backup_aws_force_path_style": None}},
        )
        self.assertFalse(config.backup_aws_force_path_style)

        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"backup_aws_force_path_style": 1}},
            )

    def test_rejects_invalid_access_and_backup_schedule_modes(self):
        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"access_mode": "admin"}},
            )

        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"backup_schedule_mode": "hourly"}},
            )

    def test_rejects_invalid_extension_payloads(self):
        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"enabled_extensions": "pgcrypto"}},
            )

        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"enabled_extensions": ["pgcrypto", 1]}},
            )

    def test_known_project_slugs_accepts_trims_and_rejects_shapes(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "known_project_slugs": [" shop ", " ", "shop-api", "shop"],
                },
            }
        )
        self.assertEqual(config.known_project_slugs, ("shop", "shop-api"))

        config = parse_postgres_service_config(
            {"settings": {"known_project_slugs": None}},
        )
        self.assertEqual(config.known_project_slugs, ())

        config = parse_postgres_service_config({"settings": {}})
        self.assertEqual(config.known_project_slugs, ())

        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"known_project_slugs": "shop"}},
            )

        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"known_project_slugs": ["shop", 1]}},
            )

    def test_expected_databases_accepts_trims_and_rejects_shapes(self):
        config = parse_postgres_service_config(
            {
                "settings": {
                    "expected_databases": [" dd_test_a ", " ", "dd_test_b"],
                },
            }
        )
        self.assertEqual(config.expected_databases, ("dd_test_a", "dd_test_b"))

        config = parse_postgres_service_config(
            {"settings": {"expected_databases": None}},
        )
        self.assertEqual(config.expected_databases, ())

        config = parse_postgres_service_config({"settings": {}})
        self.assertEqual(config.expected_databases, ())

        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"expected_databases": "dd_test_a"}},
            )

        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"expected_databases": ["dd_test_a", 1]}},
            )

    def test_normalize_confirmation_lists_default_to_none_and_trim(self):
        from orchestrator.postgres_parts import _SETTINGS_PROPERTIES

        config = parse_postgres_service_config({"settings": {}})
        self.assertIsNone(config.confirmed_normalize_users)
        self.assertIsNone(config.confirmed_lost_connect_roles)
        config = parse_postgres_service_config(
            {
                "settings": {
                    "confirmed_normalize_users": [" dd_shop_a ", " ", "dd_shop_b"],
                    "confirmed_lost_connect_roles": [],
                },
            }
        )
        self.assertEqual(
            config.confirmed_normalize_users,
            ("dd_shop_a", "dd_shop_b"),
        )
        self.assertEqual(config.confirmed_lost_connect_roles, ())
        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"confirmed_normalize_users": "dd_shop_a"}},
            )
        # The wire schema rejects unknown settings keys, so the new
        # confirmation lists must be declared there like confirmed_users.
        self.assertEqual(
            _SETTINGS_PROPERTIES["confirmed_normalize_users"],
            {"type": ["array", "null"], "items": {"type": "string"}},
        )
        self.assertEqual(
            _SETTINGS_PROPERTIES["confirmed_lost_connect_roles"],
            {"type": ["array", "null"], "items": {"type": "string"}},
        )

    def test_legacy_storage_settings_default_to_none_and_parse(self):
        from orchestrator.postgres_parts import _SETTINGS_PROPERTIES

        config = parse_postgres_service_config({"settings": {}})
        self.assertIsNone(config.legacy_storage_volume)
        self.assertIsNone(config.legacy_storage_subpath)
        config = parse_postgres_service_config(
            {
                "settings": {
                    "legacy_storage_volume": "  abc123  ",
                    "legacy_storage_subpath": " 18/docker ",
                },
            }
        )
        self.assertEqual(config.legacy_storage_volume, "abc123")
        self.assertEqual(config.legacy_storage_subpath, "18/docker")
        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"legacy_storage_volume": 123}},
            )
        self.assertEqual(
            _SETTINGS_PROPERTIES["legacy_storage_volume"],
            {"type": ["string", "null"]},
        )
        self.assertEqual(
            _SETTINGS_PROPERTIES["legacy_storage_subpath"],
            {"type": ["string", "null"]},
        )

    def test_import_ignore_ownership_defaults_to_false_and_parses(self):
        from orchestrator.postgres_parts import _SETTINGS_PROPERTIES

        config = parse_postgres_service_config({"settings": {}})
        self.assertFalse(config.import_ignore_ownership)
        config = parse_postgres_service_config(
            {"settings": {"import_ignore_ownership": True}},
        )
        self.assertTrue(config.import_ignore_ownership)
        config = parse_postgres_service_config(
            {"settings": {"import_ignore_ownership": "yes"}},
        )
        self.assertTrue(config.import_ignore_ownership)
        with self.assertRaises(PostgresConfigValidationError):
            parse_postgres_service_config(
                {"settings": {"import_ignore_ownership": "maybe"}},
            )
        self.assertEqual(
            _SETTINGS_PROPERTIES["import_ignore_ownership"],
            {"type": ["boolean", "null"]},
        )


if __name__ == "__main__":
    unittest.main()
