"""Pinned platform versions and image references.

Class A in `docs/contracts/settings-ownership.md`: owned by the backend
package, never accepted from the wire. This is the one module allowed to
contain a Caddy/BIND/PostgreSQL image tag, a WAL-G release, or a pinned
Docker apt package version as a literal.

Before this module existed, `WALG_VERSION` and `POSTGRES_IMAGE_TAGS_BY_MAJOR`
each had three independent copies (`managed_software.py`, `postgres_backup.py`,
`engine_postgres_ops.py`), which is exactly the "the deploy path and the
update path can disagree" defect described in the pre-1.0 plan's section 1.4.
Every caller now imports from here instead.

Railpack already had one correct home for its own pin
(`railpack_contract.py`), so its values are re-exported rather than
duplicated.
"""

from .railpack_contract import RAILPACK_FRONTEND_IMAGE, RAILPACK_VERSION

__all__ = [
    "BIND_IMAGE",
    "CADDY_IMAGE",
    "DOCKER_PACKAGE_VERSION_PREFIXES",
    "PGVECTOR_COMMIT",
    "PG_SEARCH_ASSETS_BY_MAJOR_AND_ARCH",
    "PG_SEARCH_VERSION",
    "POSTGRES_IMAGE_TAGS_BY_MAJOR",
    "RAILPACK_FRONTEND_IMAGE",
    "RAILPACK_VERSION",
    "WALG_HOST_ASSETS_BY_ARCH",
    "WALG_IMAGE_ASSETS_BY_ARCH",
    "WALG_VERSION",
]

# https://hub.docker.com/_/caddy/tags -- alpine variant, pinned patch release.
CADDY_IMAGE = "caddy:2.11.2-alpine"

# https://hub.docker.com/r/internetsystemsconsortium/bind9/tags
BIND_IMAGE = "internetsystemsconsortium/bind9:9.20"

# deploydash/postgres-ext build tags, one per supported PostgreSQL major.
POSTGRES_IMAGE_TAGS_BY_MAJOR = {
    "16": "16.14-bookworm",
    "17": "17.10-bookworm",
    "18": "18.4-bookworm",
}

# https://github.com/wal-g/wal-g/releases
WALG_VERSION = "v3.0.8"

# GitHub release-API `digest` values for the Ubuntu 22.04 PostgreSQL
# tarballs. Host and image contexts are separate pins even while they select
# the same compatible assets, so either context can move independently when
# its supported platform baseline changes.
WALG_HOST_ASSETS_BY_ARCH = {
    "amd64": {
        "asset": "wal-g-pg-22.04-amd64.tar.gz",
        "sha256": "b0df1b484035eb5f131db7bbd303d1a460391848fdcce34ba1e0a564cca493e9",
    },
    "arm64": {
        "asset": "wal-g-pg-22.04-aarch64.tar.gz",
        "sha256": "048b5033c34c1487dc1fccc0572db030e323230984ccc093e80e4e4081c797d1",
    },
}
WALG_IMAGE_ASSETS_BY_ARCH = {
    "amd64": {
        "asset": "wal-g-pg-22.04-amd64.tar.gz",
        "sha256": "b0df1b484035eb5f131db7bbd303d1a460391848fdcce34ba1e0a564cca493e9",
    },
    "arm64": {
        "asset": "wal-g-pg-22.04-aarch64.tar.gz",
        "sha256": "048b5033c34c1487dc1fccc0572db030e323230984ccc093e80e4e4081c797d1",
    },
}

# ParadeDB v0.22.6 release assets and GitHub release-API `digest` values.
# Asset names are pinned with their hashes because PostgreSQL major and
# Debian architecture are both part of the package identity.
PG_SEARCH_VERSION = "0.22.6"
PG_SEARCH_ASSETS_BY_MAJOR_AND_ARCH = {
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
}

# Immutable commit behind pgvector v0.8.1.
PGVECTOR_COMMIT = "778dacf20c07caf904557a88705142631818d8cb"

# apt package versions pinned and held after Docker engine install.
DOCKER_PACKAGE_VERSION_PREFIXES = {
    "docker-ce": "5:29.6.0-1",
    "docker-ce-cli": "5:29.6.0-1",
    "containerd.io": "2.2.5-1",
    "docker-compose-plugin": "5.1.4-1",
}
