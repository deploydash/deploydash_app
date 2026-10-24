import unittest

from orchestrator.app_parts.app_config import (
    CANONICAL_APP_SETTINGS,
    AppConfigValidationError,
    parse_app_config,
)


class TestAppConfig(unittest.TestCase):
    def test_parse_uses_defaults(self):
        config = parse_app_config({}, require_domain=True)

        self.assertEqual(config.project_slug, CANONICAL_APP_SETTINGS["project_slug"])
        self.assertEqual(
            config.repository_full_name,
            CANONICAL_APP_SETTINGS["repository_full_name"],
        )
        self.assertEqual(config.branch, "main")
        self.assertEqual(config.primary_domain, "app.example.com")
        self.assertEqual(config.domain_routing_mode, "single_host")
        self.assertEqual(config.app_port, 3000)
        self.assertTrue(config.public_health_check_enabled)
        self.assertEqual(config.public_health_check_path, "/")
        self.assertEqual(config.railpack_node_mode, "auto")
        self.assertEqual(config.railpack_build_command, "")
        self.assertEqual(config.railpack_run_command, "")
        self.assertIsNone(config.railpack_provider)
        self.assertEqual(config.app_subdirectory, "")
        self.assertLessEqual(
            len(config.release_upstream_name("20260531t130000z-fedcba987654")),
            63,
        )

    def test_release_upstream_name_stays_short_and_unique_per_release(self):
        config = parse_app_config(
            {
                "settings": {
                    "project_slug": "buildingregs-website-with-a-very-long-slug",
                    "repository_full_name": "acme/buildingregs",
                    "primary_domain": "www.buildingregs.app",
                }
            },
            require_domain=True,
        )

        first = config.release_upstream_name("20260531t130000z-fedcba987654")
        second = config.release_upstream_name("20260531t140000z-fedcba987654")

        self.assertNotEqual(first, second)
        self.assertTrue(first.startswith("dd-app-"))
        self.assertTrue(second.startswith("dd-app-"))
        self.assertLessEqual(len(first), 63)
        self.assertLessEqual(len(second), 63)

    def test_parse_rejects_invalid_domain_when_required(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "primary_domain": "not a domain",
                    }
                },
                require_domain=True,
            )

    def test_parse_allows_missing_domain_for_prepare_key(self):
        config = parse_app_config(
            {
                "settings": {
                    "primary_domain": None,
                    "project_slug": "remix-app",
                    "repository_full_name": "acme/remix-app",
                }
            },
            require_domain=False,
        )

        self.assertIsNone(config.primary_domain)
        self.assertEqual(config.project_slug, "remix-app")

    def test_parse_accepts_public_health_check_override_and_opt_out(self):
        config = parse_app_config(
            {
                "settings": {
                    "public_health_check_enabled": False,
                    "public_health_check_path": "/status/ready?full=1",
                }
            },
            require_domain=True,
        )

        self.assertFalse(config.public_health_check_enabled)
        self.assertEqual(config.public_health_check_path, "/status/ready?full=1")

    def test_parse_rejects_invalid_public_health_check_settings(self):
        invalid_settings = (
            {"public_health_check_enabled": "yes"},
            {"public_health_check_path": "health"},
            {"public_health_check_path": "/health#details"},
            {"public_health_check_path": "/health\nnext"},
            {"public_health_check_path": "/" + ("a" * 512)},
        )

        for settings in invalid_settings:
            with self.subTest(settings=settings), self.assertRaises(AppConfigValidationError):
                parse_app_config({"settings": settings}, require_domain=True)

    def test_parse_accepts_www_redirect_modes(self):
        config = parse_app_config(
            {
                "settings": {
                    "primary_domain": "www.example.com",
                    "domain_routing_mode": "redirect_www_to_apex",
                }
            },
            require_domain=True,
        )

        self.assertEqual(config.primary_domain, "example.com")
        self.assertEqual(config.domain_routing_mode, "redirect_www_to_apex")
        self.assertEqual(config.canonical_domain, "example.com")
        self.assertEqual(config.redirect_domain, "www.example.com")
        self.assertEqual(
            config.managed_domains,
            ("example.com", "www.example.com"),
        )
        self.assertEqual(config.app_https_url, "https://example.com")

    def test_parse_uses_www_canonical_url_for_apex_redirect_mode(self):
        config = parse_app_config(
            {
                "settings": {
                    "primary_domain": "example.com",
                    "domain_routing_mode": "redirect_apex_to_www",
                }
            },
            require_domain=True,
        )

        self.assertEqual(config.canonical_domain, "www.example.com")
        self.assertEqual(config.redirect_domain, "example.com")
        self.assertEqual(config.app_http_url, "http://www.example.com")

    def test_parse_rejects_invalid_domain_routing_mode(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "domain_routing_mode": "redirect_everything",
                    }
                },
                require_domain=True,
            )

    def test_parse_rejects_bad_repo_format(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "repository_full_name": "invalid",
                    }
                },
                require_domain=True,
            )

    def test_parse_accepts_runtime_node_mode(self):
        config = parse_app_config(
            {
                "settings": {
                    "railpack_node_mode": "runtime",
                }
            },
            require_domain=True,
        )
        self.assertEqual(config.railpack_node_mode, "runtime")

    def test_parse_accepts_custom_build_and_run_commands(self):
        config = parse_app_config(
            {
                "settings": {
                    "railpack_build_cmd": "pnpm build",
                    "railpack_start_cmd": "pnpm start",
                }
            },
            require_domain=True,
        )
        self.assertEqual(config.railpack_build_command, "pnpm build")
        self.assertEqual(config.railpack_run_command, "pnpm start")

    def test_parse_accepts_explicit_railpack_provider(self):
        config = parse_app_config(
            {
                "settings": {
                    "railpack_provider": "python",
                }
            },
            require_domain=True,
        )
        self.assertEqual(config.railpack_provider, "python")
        self.assertEqual(config.railpack_build_command, "")
        self.assertEqual(config.railpack_run_command, "")

    def test_parse_accepts_legacy_build_and_run_command_keys(self):
        config = parse_app_config(
            {
                "settings": {
                    "railpack_build_command": "pnpm build",
                    "railpack_run_command": "pnpm start",
                }
            },
            require_domain=True,
        )
        self.assertEqual(config.railpack_build_command, "pnpm build")
        self.assertEqual(config.railpack_run_command, "pnpm start")

    def test_parse_accepts_optional_app_subdirectory(self):
        config = parse_app_config(
            {
                "settings": {
                    "app_subdirectory": " website/frontend ",
                }
            },
            require_domain=True,
        )
        self.assertEqual(config.app_subdirectory, "website/frontend")
        self.assertEqual(
            config.source_app_root,
            f"{config.source_root}/website/frontend",
        )

    def test_parse_rejects_invalid_app_subdirectory(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "app_subdirectory": "../website",
                    }
                },
                require_domain=True,
            )

    def test_parse_prefers_canonical_build_and_run_keys_when_both_present(self):
        config = parse_app_config(
            {
                "settings": {
                    "railpack_build_cmd": "npm run release",
                    "railpack_start_cmd": "npm run serve",
                    "railpack_build_command": "pnpm build",
                    "railpack_run_command": "pnpm start",
                }
            },
            require_domain=True,
        )
        self.assertEqual(config.railpack_build_command, "npm run release")
        self.assertEqual(config.railpack_run_command, "npm run serve")

    def test_parse_rejects_unknown_settings_keys(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "unexpected_key": "value",
                    }
                },
                require_domain=True,
            )

    def test_parse_accepts_optional_inline_deploy_key(self):
        config = parse_app_config(
            {
                "settings": {
                    "deploy_private_key": "  test-key-material  ",
                }
            },
            require_domain=True,
        )
        self.assertEqual(config.deploy_private_key, "test-key-material")
        self.assertEqual(config.repository_host_key_policy, "strict")
        self.assertIsNone(config.accepted_repository_host_key_fingerprint)
        self.assertEqual(
            config.repository_known_hosts_path,
            "/opt/deploydash/stack/apps/.deploydash/repository-known-hosts/sample-app/known_hosts",
        )

    def test_parse_accepts_repository_host_key_confirmation_policy(self):
        config = parse_app_config(
            {
                "settings": {
                    "repository_host_key_policy": "accept_new",
                    "accepted_repository_host_key_fingerprint": "SHA256:abcDEF123+/=",
                }
            },
            require_domain=True,
        )

        self.assertEqual(config.repository_host_key_policy, "accept_new")
        self.assertEqual(
            config.accepted_repository_host_key_fingerprint,
            "SHA256:abcDEF123+/=",
        )

    def test_parse_rejects_repository_host_key_policy_without_fingerprint(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "repository_host_key_policy": "replace_confirmed",
                    }
                },
                require_domain=True,
            )

    def test_parse_rejects_invalid_repository_host_key_fingerprint(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "repository_host_key_policy": "accept_new",
                        "accepted_repository_host_key_fingerprint": "MD5:bad",
                    }
                },
                require_domain=True,
            )

    def test_parse_accepts_runtime_env_map(self):
        config = parse_app_config(
            {
                "settings": {
                    "runtime_env": {
                        "STRIPE_SECRET_KEY": "sk_test_123",
                        "NODE_ENV": "production",
                    },
                }
            },
            require_domain=True,
        )
        self.assertEqual(
            config.runtime_env,
            {
                "STRIPE_SECRET_KEY": "sk_test_123",
                "NODE_ENV": "production",
            },
        )

    def test_parse_accepts_trust_network_names(self):
        config = parse_app_config(
            {
                "settings": {
                    "trust_network_names": [
                        "deploydash_trust_alpha",
                        "deploydash_trust_alpha",
                        "deploydash_trust_beta",
                    ],
                }
            },
            require_domain=True,
        )
        self.assertEqual(
            config.trust_network_names,
            ("deploydash_trust_alpha", "deploydash_trust_beta"),
        )

    def test_parse_rejects_invalid_trust_network_name(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "trust_network_names": ["bad network"],
                    }
                },
                require_domain=True,
            )

    def test_parse_accepts_sqlite_storage_settings(self):
        config = parse_app_config(
            {
                "settings": {
                    "sqlite_storage": {
                        "enabled": True,
                        "volume_name": "deploydash_sqlite_blog",
                        "mount_path": "/var/lib/deploydash/sqlite",
                        "file_name": "main.db",
                    },
                }
            },
            require_domain=True,
        )
        self.assertIsNotNone(config.sqlite_storage)
        self.assertEqual(config.sqlite_storage.volume_name, "deploydash_sqlite_blog")
        self.assertEqual(config.sqlite_storage.mount_path, "/var/lib/deploydash/sqlite")
        self.assertEqual(config.sqlite_storage.file_name, "main.db")
        self.assertEqual(
            config.sqlite_storage.database_path,
            "/var/lib/deploydash/sqlite/main.db",
        )
        self.assertEqual(
            config.sqlite_storage.database_url,
            "sqlite:////var/lib/deploydash/sqlite/main.db",
        )

    def test_parse_accepts_sqlite_snapshot_mounts(self):
        config = parse_app_config(
            {
                "settings": {
                    "sqlite_snapshot_mounts": [
                        {
                            "volume_name": "deploydash_sqlite_snapshot_catalog",
                            "mount_path": "/var/lib/deploydash/sqlite-snapshots/catalog",
                            "file_name": "catalog.db",
                            "path_env_key": "CATALOG_SQLITE_PATH",
                            "database_url_env_key": "CATALOG_DATABASE_URL",
                        },
                    ],
                }
            },
            require_domain=True,
        )

        mount = config.sqlite_snapshot_mounts[0]
        self.assertEqual(mount.volume_name, "deploydash_sqlite_snapshot_catalog")
        self.assertEqual(
            mount.database_path,
            "/var/lib/deploydash/sqlite-snapshots/catalog/catalog.db",
        )
        self.assertEqual(
            mount.database_url,
            "sqlite:////var/lib/deploydash/sqlite-snapshots/catalog/catalog.db",
        )
        self.assertEqual(mount.path_env_key, "CATALOG_SQLITE_PATH")
        self.assertEqual(mount.database_url_env_key, "CATALOG_DATABASE_URL")

    def test_parse_rejects_invalid_sqlite_snapshot_mount(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "sqlite_snapshot_mounts": [
                            {
                                "volume_name": "deploydash_sqlite_snapshot_catalog",
                                "mount_path": "/var/lib/deploydash/snapshots/catalog",
                                "file_name": "catalog.db",
                                "path_env_key": "BAD-KEY",
                            },
                        ],
                    }
                },
                require_domain=True,
            )

        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "sqlite_snapshot_mounts": [
                            {
                                "volume_name": "deploydash_sqlite_snapshot_a",
                                "mount_path": "/var/lib/deploydash/snapshots/catalog",
                                "file_name": "catalog.db",
                            },
                            {
                                "volume_name": "deploydash_sqlite_snapshot_b",
                                "mount_path": "/var/lib/deploydash/snapshots/catalog",
                                "file_name": "catalog.db",
                            },
                        ],
                    }
                },
                require_domain=True,
            )

    def test_parse_rejects_invalid_sqlite_storage_mount_path(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "sqlite_storage": {
                            "enabled": True,
                            "volume_name": "deploydash_sqlite_blog",
                            "mount_path": "var/lib/deploydash/sqlite",
                            "file_name": "main.db",
                        },
                    }
                },
                require_domain=True,
            )

    def test_parse_rejects_runtime_env_key_with_invalid_chars(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "runtime_env": {
                            "BAD-KEY": "value",
                        },
                    }
                },
                require_domain=True,
            )

    def test_parse_rejects_runtime_env_value_with_newline(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "runtime_env": {
                            "API_KEY": "first-line\nsecond-line",
                        },
                    }
                },
                require_domain=True,
            )

    def test_parse_accepts_optional_worker_start_command(self):
        config = parse_app_config(
            {
                "settings": {
                    "worker_start_cmd": "npm run worker",
                }
            },
            require_domain=True,
        )
        self.assertEqual(config.worker_run_command, "npm run worker")
        self.assertEqual(len(config.workers), 1)
        self.assertEqual(config.workers[0].id, "default")
        self.assertEqual(config.workers[0].start_command, "npm run worker")

    def test_parse_accepts_workers_array(self):
        config = parse_app_config(
            {
                "settings": {
                    "workers": [
                        {
                            "id": "queue-worker",
                            "name": "Queue worker",
                            "start_cmd": "npm run worker:queue",
                            "cpu_limit": 1.25,
                            "memory_mb": 512,
                            "disk_mb": 2048,
                            "enabled": True,
                            "database_user": "app_rw",
                            "database_name": "app_db",
                            "database_password": "pw-123",
                        },
                        {
                            "id": "email-worker",
                            "start_cmd": "npm run worker:email",
                            "cpu_limit": 0.5,
                            "memory_mb": 256,
                            "disk_mb": 1024,
                            "enabled": False,
                        },
                    ]
                }
            },
            require_domain=True,
        )
        self.assertEqual(len(config.workers), 2)
        queue = config.workers[0]
        self.assertEqual(queue.id, "queue-worker")
        self.assertEqual(queue.database_user, "app_rw")
        self.assertEqual(queue.database_name, "app_db")
        self.assertEqual(queue.database_host, "host.docker.internal")
        self.assertEqual(queue.database_port, 5432)
        email = config.workers[1]
        self.assertEqual(email.id, "email-worker")
        self.assertFalse(email.enabled)

    def test_parse_rejects_worker_without_required_database_user(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "workers": [
                            {
                                "id": "queue-worker",
                                "start_cmd": "npm run worker:queue",
                                "cpu_limit": 1,
                                "memory_mb": 512,
                                "disk_mb": 1024,
                                "database_name": "app_db",
                                "database_password": "pw-123",
                            }
                        ]
                    }
                },
                require_domain=True,
            )

    def test_parse_defaults_to_http_tls_challenge(self):
        config = parse_app_config({}, require_domain=True)
        self.assertEqual(config.tls_challenge_mode, "http")
        self.assertIsNone(config.tls_dns_provider)
        self.assertEqual(config.tls_dns_credentials, {})

    def test_parse_accepts_dns_tls_challenge_config(self):
        config = parse_app_config(
            {
                "settings": {
                    "tls_challenge_mode": "dns",
                    "tls_dns_provider": "cloudflare",
                    "tls_dns_credentials": {
                        "api_token": "cf-token",
                    },
                }
            },
            require_domain=True,
        )
        self.assertEqual(config.tls_challenge_mode, "dns")
        self.assertEqual(config.tls_dns_provider, "cloudflare")
        self.assertEqual(config.tls_dns_credentials, {"api_token": "cf-token"})

    def test_parse_dns_mode_requires_provider(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "tls_challenge_mode": "dns",
                    }
                },
                require_domain=True,
            )

    def test_parse_dns_mode_requires_provider_credentials(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "tls_challenge_mode": "dns",
                        "tls_dns_provider": "porkbun",
                        "tls_dns_credentials": {
                            "api_key": "only-one-value",
                        },
                    }
                },
                require_domain=True,
            )

    def test_parse_rejects_removed_dnsimple_tls_provider(self):
        with self.assertRaises(AppConfigValidationError):
            parse_app_config(
                {
                    "settings": {
                        "tls_challenge_mode": "dns",
                        "tls_dns_provider": "dnsimple",
                        "tls_dns_credentials": {
                            "api_token": "dnsimple-token",
                        },
                    }
                },
                require_domain=True,
            )


if __name__ == "__main__":
    unittest.main()
