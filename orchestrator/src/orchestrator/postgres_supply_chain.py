"""Verified PostgreSQL download and extension-image rendering.

This module is the one implementation owner for commands that download
PostgreSQL support artifacts. Pin values remain in ``platform_versions``;
provisioning, backup setup, and managed updates consume the renderers here.
"""

import shlex
from collections.abc import Mapping

from . import platform_versions

POSTGRES_EXTENSION_IMAGE_VARIANTS = (
    "base",
    "vector",
    "pg-search",
    "postgis",
    "vector-pg-search",
    "vector-postgis",
    "pg-search-postgis",
    "vector-pg-search-postgis",
)


def _shell_architecture_cases(
    records: Mapping[str, Mapping[str, str]],
    *,
    prefix: str = "",
) -> str:
    """Render an exhaustive architecture selector from reviewed pin records."""
    return " ".join(
        f"{architecture}) {prefix}ASSET={shlex.quote(record['asset'])}; "
        f"{prefix}SHA256={shlex.quote(record['sha256'])} ;;"
        for architecture, record in records.items()
    )


def _docker_architecture_cases(
    records: Mapping[str, Mapping[str, str]],
    *,
    asset_name: str,
    checksum_name: str,
) -> str:
    """Keep Dockerfile architecture selection derived from the same pin records."""
    return " \\\n".join(
        f"      {architecture}) {asset_name}={shlex.quote(record['asset'])}; "
        f"{checksum_name}={shlex.quote(record['sha256'])} ;;"
        for architecture, record in records.items()
    )


def _pg_search_docker_cases() -> str:
    """Bind each supported PostgreSQL-major/architecture pair to one package."""
    cases = []
    for major, architecture_records in platform_versions.PG_SEARCH_ASSETS_BY_MAJOR_AND_ARCH.items():
        for architecture, record in architecture_records.items():
            cases.append(
                f"      {major}:{architecture}) "
                f"PG_SEARCH_ASSET={shlex.quote(record['asset'])}; "
                f"PG_SEARCH_SHA256={shlex.quote(record['sha256'])} ;;"
            )
    return " \\\n".join(cases)


def postgres_walg_install_command(*, reinstall_existing: bool = False) -> str:
    """Install one architecture-pinned WAL-G tarball only after SHA-256 verification."""
    existing_binary_guard = ""
    if not reinstall_existing:
        existing_binary_guard = (
            "if command -v wal-g >/dev/null 2>&1; then "
            "wal-g --version >/dev/null 2>&1 || true; "
            "exit 0; "
            "fi; "
        )
    architecture_cases = _shell_architecture_cases(
        platform_versions.WALG_HOST_ASSETS_BY_ARCH,
    )
    release_root = (
        f"https://github.com/wal-g/wal-g/releases/download/{platform_versions.WALG_VERSION}"
    )
    return (
        "set -eu; "
        f"{existing_binary_guard}"
        "DL_TOOL=''; "
        "if command -v curl >/dev/null 2>&1; then DL_TOOL='curl'; "
        "elif command -v wget >/dev/null 2>&1; then DL_TOOL='wget'; "
        "else echo 'Neither curl nor wget is installed; cannot install wal-g.' >&2; "
        "exit 1; fi; "
        'ARCH="$(dpkg --print-architecture)"; '
        f'case "${{ARCH}}" in {architecture_cases} *) '
        'echo "Unsupported architecture for WAL-G: ${ARCH}" >&2; exit 1 ;; esac; '
        f'URL={shlex.quote(release_root)}/"${{ASSET}}"; '
        "INSTALL_PATH=/usr/local/bin/wal-g; "
        'TMP_DIR="$(mktemp -d)"; '
        'cleanup(){ rm -rf "${TMP_DIR}" >/dev/null 2>&1 || true; }; '
        "trap cleanup EXIT INT TERM; "
        "if [ \"${DL_TOOL}\" = 'curl' ]; then "
        'curl -fsSL "${URL}" -o "${TMP_DIR}/wal-g.tar.gz" || '
        "{ echo 'Could not download the pinned WAL-G asset.' >&2; exit 1; }; "
        "else "
        'wget -qO "${TMP_DIR}/wal-g.tar.gz" "${URL}" || '
        "{ echo 'Could not download the pinned WAL-G asset.' >&2; exit 1; }; "
        "fi; "
        'if ! printf \'%s  %s\\n\' "${SHA256}" "${TMP_DIR}/wal-g.tar.gz" '
        "| sha256sum -c -; then "
        "echo 'WAL-G checksum verification failed.' >&2; exit 1; fi; "
        'tar -xzf "${TMP_DIR}/wal-g.tar.gz" -C "${TMP_DIR}"; '
        'BIN_PATH="$(find "${TMP_DIR}" -maxdepth 1 -type f '
        "\\( -name 'wal-g-pg-*' -o -name 'wal-g' -o -name 'wal-g-*' \\) "
        '| head -n1)"; '
        '[ -n "${BIN_PATH}" ] || '
        "{ echo 'Pinned WAL-G archive did not contain a binary.' >&2; exit 1; }; "
        'install -m 0755 "${BIN_PATH}" "${INSTALL_PATH}"; '
        '"${INSTALL_PATH}" --version >/dev/null 2>&1'
    )


def postgres_extension_image_dockerfile(variant: str) -> str:
    """Render the sole verified Dockerfile body for one supported extension set."""
    if variant not in POSTGRES_EXTENSION_IMAGE_VARIANTS:
        raise ValueError(f"Unsupported PostgreSQL extension image variant: {variant}")

    requires_vector = variant in {
        "vector",
        "vector-pg-search",
        "vector-postgis",
        "vector-pg-search-postgis",
    }
    requires_pg_search = variant in {
        "pg-search",
        "vector-pg-search",
        "pg-search-postgis",
        "vector-pg-search-postgis",
    }
    requires_postgis = variant in {
        "postgis",
        "vector-postgis",
        "pg-search-postgis",
        "vector-pg-search-postgis",
    }

    install_packages = ["ca-certificates", "curl"]
    steps = []
    if requires_vector:
        install_packages.extend(["build-essential", "git", "postgresql-server-dev-${PG_MAJOR}"])
        steps.extend(
            [
                "    git init /tmp/pgvector; \\",
                "    git -C /tmp/pgvector remote add origin https://github.com/pgvector/pgvector.git; \\",
                "    git -C /tmp/pgvector fetch --depth 1 origin "
                f"{platform_versions.PGVECTOR_COMMIT}; \\",
                "    git -C /tmp/pgvector checkout --detach FETCH_HEAD; \\",
                '    test "$(git -C /tmp/pgvector rev-parse HEAD)" = '
                f"{platform_versions.PGVECTOR_COMMIT}; \\",
                "    make -C /tmp/pgvector; \\",
                "    make -C /tmp/pgvector install; \\",
                "    rm -rf /tmp/pgvector; \\",
            ]
        )
    if requires_postgis:
        install_packages.extend(
            [
                "postgresql-${PG_MAJOR}-postgis-3",
                "postgresql-${PG_MAJOR}-postgis-3-scripts",
            ]
        )
    if requires_pg_search:
        pg_search_cases = _pg_search_docker_cases()
        steps.extend(
            [
                '    PARADEDB_ARCH="$(dpkg --print-architecture)"; \\',
                '    case "${PG_MAJOR}:${PARADEDB_ARCH}" in \\',
                f"{pg_search_cases} \\",
                '      *) echo "Unsupported pg_search target: '
                '${PG_MAJOR}/${PARADEDB_ARCH}" >&2; exit 1 ;; \\',
                "    esac; \\",
                '    curl -fsSL "https://github.com/paradedb/paradedb/releases/download/'
                f'v{platform_versions.PG_SEARCH_VERSION}/${{PG_SEARCH_ASSET}}" '
                "-o /tmp/pg_search.deb; \\",
                "    if ! printf '%s  %s\\n' \"${PG_SEARCH_SHA256}\" "
                "/tmp/pg_search.deb | sha256sum -c -; then "
                "echo 'pg_search checksum verification failed.' >&2; exit 1; fi; \\",
                "    apt-get install -y --no-install-recommends /tmp/pg_search.deb; \\",
                "    rm -f /tmp/pg_search.deb; \\",
            ]
        )

    walg_cases = _docker_architecture_cases(
        platform_versions.WALG_IMAGE_ASSETS_BY_ARCH,
        asset_name="WALG_ASSET",
        checksum_name="WALG_SHA256",
    )
    install_lines = " \\\n      ".join(install_packages)
    extension_steps = "\n".join(steps)
    if extension_steps:
        extension_steps += "\n"
    return (
        "ARG BASE_IMAGE\n"
        "FROM ${BASE_IMAGE}\n"
        "ARG PG_MAJOR\n"
        "RUN set -eux; \\\n"
        "    apt-get update; \\\n"
        "    apt-get install -y --no-install-recommends \\\n"
        f"      {install_lines}; \\\n"
        f"{extension_steps}"
        '    WALG_ARCH="$(dpkg --print-architecture)"; \\\n'
        '    case "${WALG_ARCH}" in \\\n'
        f"{walg_cases} \\\n"
        '      *) echo "Unsupported WAL-G image architecture: ${WALG_ARCH}" >&2; exit 1 ;; \\\n'
        "    esac; \\\n"
        '    WALG_TMP="$(mktemp -d)"; \\\n'
        '    curl -fsSL "https://github.com/wal-g/wal-g/releases/download/'
        f'{platform_versions.WALG_VERSION}/${{WALG_ASSET}}" '
        '-o "${WALG_TMP}/wal-g.tar.gz"; \\\n'
        "    if ! printf '%s  %s\\n' \"${WALG_SHA256}\" "
        '"${WALG_TMP}/wal-g.tar.gz" | sha256sum -c -; then '
        "echo 'WAL-G checksum verification failed.' >&2; exit 1; fi; \\\n"
        '    tar -xzf "${WALG_TMP}/wal-g.tar.gz" -C "${WALG_TMP}"; \\\n'
        '    BIN_PATH="$(find "${WALG_TMP}" -maxdepth 1 -type f '
        "\\( -name 'wal-g-pg-*' -o -name 'wal-g' -o -name 'wal-g-*' \\) "
        '| head -n1)"; \\\n'
        '    test -n "${BIN_PATH}"; \\\n'
        '    install -m 0755 "${BIN_PATH}" /usr/local/bin/wal-g; \\\n'
        '    rm -rf "${WALG_TMP}"; \\\n'
        "    wal-g --version >/dev/null 2>&1; \\\n"
        "    rm -rf /var/lib/apt/lists/*\n"
    )


def postgres_extension_image_dockerfiles_by_variant() -> dict[str, str]:
    """Publish every supported body for runtime selection without re-rendering it remotely."""
    return {
        variant: postgres_extension_image_dockerfile(variant)
        for variant in POSTGRES_EXTENSION_IMAGE_VARIANTS
    }
