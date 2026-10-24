import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from orchestrator import platform_versions
from orchestrator.infra_parts import tooling
from orchestrator.postgres_backup import postgres_walg_install_command
from orchestrator.postgres_parts import parse_postgres_service_config
from orchestrator.postgres_runtime_parts.service_configuration import (
    _postgres_extension_image_build_command,
)
from orchestrator.postgres_supply_chain import postgres_extension_image_dockerfile


class TestPostgresSupplyChainPins(unittest.TestCase):
    def test_release_assets_have_exact_publisher_digests(self):
        """Why: every downloaded artifact must be pinned to reviewed release bytes."""
        self.assertEqual(
            getattr(platform_versions, "WALG_HOST_ASSETS_BY_ARCH", None),
            {
                "amd64": {
                    "asset": "wal-g-pg-22.04-amd64.tar.gz",
                    "sha256": "b0df1b484035eb5f131db7bbd303d1a460391848fdcce34ba1e0a564cca493e9",
                },
                "arm64": {
                    "asset": "wal-g-pg-22.04-aarch64.tar.gz",
                    "sha256": "048b5033c34c1487dc1fccc0572db030e323230984ccc093e80e4e4081c797d1",
                },
            },
        )
        self.assertEqual(
            getattr(platform_versions, "WALG_IMAGE_ASSETS_BY_ARCH", None),
            platform_versions.WALG_HOST_ASSETS_BY_ARCH,
        )
        self.assertEqual(
            getattr(platform_versions, "PGVECTOR_COMMIT", None),
            "778dacf20c07caf904557a88705142631818d8cb",
        )
        self.assertEqual(getattr(platform_versions, "PG_SEARCH_VERSION", None), "0.22.6")
        self.assertEqual(
            platform_versions.PG_SEARCH_ASSETS_BY_MAJOR_AND_ARCH,
            {
                "16": {
                    "amd64": {
                        "asset": "postgresql-16-pg-search_0.22.6-1PARADEDB-bookworm_amd64.deb",
                        "sha256": "8f516a29d35188bcb96f2131cf2473d467faf97e36810279898110ac87acbb84",
                    },
                    "arm64": {
                        "asset": "postgresql-16-pg-search_0.22.6-1PARADEDB-bookworm_arm64.deb",
                        "sha256": "58d5d652c8fc588da89aabd83ad1d6049533cf39ae103278e41504946e70bcc0",
                    },
                },
                "17": {
                    "amd64": {
                        "asset": "postgresql-17-pg-search_0.22.6-1PARADEDB-bookworm_amd64.deb",
                        "sha256": "9852f3fdee9e387d5da47c6d745bc8d6b6dd4cd3ea9dac9858c6a5f9c18eea93",
                    },
                    "arm64": {
                        "asset": "postgresql-17-pg-search_0.22.6-1PARADEDB-bookworm_arm64.deb",
                        "sha256": "12528247efdd62b0365bebf1469de90c15a1a87da93f920559a270f255740fc4",
                    },
                },
                "18": {
                    "amd64": {
                        "asset": "postgresql-18-pg-search_0.22.6-1PARADEDB-bookworm_amd64.deb",
                        "sha256": "e2417bcda87d65fd66386205b474148f1ee350ef4791e9f3e25f4082a27c8a2c",
                    },
                    "arm64": {
                        "asset": "postgresql-18-pg-search_0.22.6-1PARADEDB-bookworm_arm64.deb",
                        "sha256": "23a6845d223f495a059419cd147690ed309e8a12d5988a32a89ae2dbbdd82e97",
                    },
                },
            },
        )

    def test_host_installer_is_arch_pinned_and_verified(self):
        """Why: the root-run host installer must never execute unverified bytes."""
        command = postgres_walg_install_command(reinstall_existing=True)

        self.assertIn("dpkg --print-architecture", command)
        self.assertIn("wal-g-pg-22.04-amd64.tar.gz", command)
        self.assertIn("wal-g-pg-22.04-aarch64.tar.gz", command)
        self.assertIn("sha256sum -c -", command)
        self.assertIn("WAL-G checksum verification failed", command)
        self.assertNotIn("api.github.com/repos/wal-g", command)
        self.assertNotIn("for ASSET in", command)

    def test_tampered_host_download_fails_before_install(self):
        """Why: a corrupt download must leave the previously installed binary untouched."""
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            target = root / "wal-g"
            (bin_dir / "dpkg").write_text(
                "#!/usr/bin/env bash\necho amd64\n",
                encoding="utf-8",
            )
            (bin_dir / "curl").write_text(
                "#!/usr/bin/env bash\n"
                "set -eu\n"
                'while [ "$#" -gt 0 ]; do\n'
                '  if [ "$1" = -o ]; then printf tampered > "$2"; exit 0; fi\n'
                "  shift\n"
                "done\n"
                "exit 1\n",
                encoding="utf-8",
            )
            (bin_dir / "dpkg").chmod(0o755)
            (bin_dir / "curl").chmod(0o755)
            command = postgres_walg_install_command(reinstall_existing=True).replace(
                "/usr/local/bin/wal-g",
                str(target),
            )
            environment = dict(os.environ)
            environment["PATH"] = f"{bin_dir}:/usr/bin:/bin"

            completed = subprocess.run(
                ["bash", "-c", command],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("WAL-G checksum verification failed", completed.stderr)
        self.assertFalse(target.exists())


class TestPostgresExtensionImageSupplyChain(unittest.TestCase):
    @staticmethod
    def _build_command(*extensions):
        """Why: all image assertions need the same supported PostgreSQL configuration."""
        config = parse_postgres_service_config(
            {
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "secret",
                    "enabled_extensions": list(extensions),
                },
            }
        )
        return _postgres_extension_image_build_command(config)

    def test_image_downloads_are_pinned_and_verified(self):
        """Why: the image builder runs downloaded packages as root during build."""
        command = self._build_command("vector", "pg_search")

        self.assertIn(platform_versions.PGVECTOR_COMMIT, command)
        self.assertNotIn("--branch v0.8.1", command)
        self.assertIn("WAL-G checksum verification failed", command)
        self.assertIn("pg_search checksum verification failed", command)
        self.assertGreaterEqual(command.count("sha256sum -c -"), 2)
        self.assertLess(
            command.find("FROM ${BASE_IMAGE}"),
            command.find("ARG PG_MAJOR"),
        )
        self.assertNotIn("api.github.com/repos/wal-g", command)
        self.assertNotIn("for ASSET in", command)

    def test_managed_update_uses_the_same_verified_dockerfile_contract(self):
        """Why: managed updates must not retain a second, weaker installer."""
        initial = self._build_command("vector", "pg_search")
        managed = tooling._managed_update_command(
            "postgresql_database_service",
            backup_dir="/rollback/postgres",
        )

        for pin in (
            platform_versions.PGVECTOR_COMMIT,
            platform_versions.WALG_IMAGE_ASSETS_BY_ARCH["amd64"]["sha256"],
            platform_versions.WALG_IMAGE_ASSETS_BY_ARCH["arm64"]["sha256"],
            platform_versions.PG_SEARCH_ASSETS_BY_MAJOR_AND_ARCH["17"]["amd64"]["sha256"],
            platform_versions.PG_SEARCH_ASSETS_BY_MAJOR_AND_ARCH["17"]["arm64"]["sha256"],
        ):
            self.assertIn(pin, initial)
            self.assertIn(pin, managed)
        self.assertIn("POSTGRES_DOCKERFILES_JSON", managed)
        self.assertNotIn("WALG_ASSETS_JSON", managed)

    def test_unsupported_image_variant_fails_before_rendering(self):
        """Why: unknown extension sets must not bypass the reviewed renderer matrix."""
        with self.assertRaisesRegex(ValueError, "Unsupported PostgreSQL"):
            postgres_extension_image_dockerfile("unknown")


if __name__ == "__main__":
    unittest.main()
