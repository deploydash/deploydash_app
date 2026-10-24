import os
import re
import shlex

from .. import platform_versions, server_identifiers, server_paths
from ..container_status import (
    container_process_running_check_shell,
    container_status_kv_shell,
    postgres_service_readiness_check_shell,
)

# backup_env_assignments, normalize_backup_artifact_path, and
# normalize_backup_hhmm are not referenced by name below -- tests call them
# through this module's own aliased attributes (e.g.
# engine_postgres_ops._backup_env_assignments(...)), which is why the
# `as _name` aliasing exists at all.
from ..postgres_backup import (
    backup_env_assignments as _backup_env_assignments,  # noqa: F401
)
from ..postgres_backup import (
    normalize_backup_artifact_path as _normalize_backup_artifact_path,  # noqa: F401
)
from ..postgres_backup import (
    normalize_backup_hhmm as _normalize_backup_hhmm,  # noqa: F401
)
from ..postgres_parts import (
    SUPPORTED_POSTGRES_EXTENSIONS,
    UNSUPPORTED_POSTGRES_EXTENSIONS,
    PostgresConfigValidationError,
)
from ..postgres_supply_chain import postgres_extension_image_dockerfile
from ..runtime_security import (
    ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING,
    docker_compose_security_lines,
)
from .tls_policy import postgres_tls_key_pair_check_shell

_PG_IDENTIFIER_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,62}$")
_BACKUP_POLICY_TOKEN_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")
_BACKUP_HHMM_PATTERN = re.compile(r"^(?:[01]?\d|2[0-3]):[0-5]\d$")
_PARADEDB_PG_SEARCH_VERSION = platform_versions.PG_SEARCH_VERSION
_POSTGRES_IMAGE_TAGS_BY_MAJOR = platform_versions.POSTGRES_IMAGE_TAGS_BY_MAJOR
_LOCAL_SQL_UPLOAD_CHUNK_SIZE = 4 * 1024 * 1024
_LOCAL_SQL_UPLOAD_PROGRESS_STEP = 64 * 1024 * 1024
_LOCAL_SQL_IMPORT_SUCCESS_MARKER = "__DEPLOYDASH_LOCAL_SQL_IMPORT_SUCCEEDED__"
_POSTGRES_AGENT_QUERY_SQL_MAX_LENGTH = 20000
_POSTGRES_AGENT_QUERY_DEFAULT_MAX_ROWS = 200
_POSTGRES_AGENT_QUERY_MAX_ROWS = 1000
_POSTGRES_AGENT_QUERY_TIMEOUT_MS = 10000
_POSTGRES_AGENT_QUERY_RESULT_MAX_BYTES = 1024 * 1024
_POSTGRES_TLS_CONTAINER_ROOT = "/run/deploydash-postgres-tls"


class _PostgresLocalImportCancelled(RuntimeError):
    pass


class _PostgresLocalImportUploadError(RuntimeError):
    pass


def _normalize_postgres_identifier(raw_value, field_name):
    if not isinstance(raw_value, str) or not raw_value.strip():
        raise PostgresConfigValidationError(
            f"{field_name} must be a non-empty string.",
        )
    normalized = raw_value.strip().lower()
    normalized = re.sub(r"[^a-z0-9_]+", "_", normalized)
    normalized = re.sub(r"_+", "_", normalized).strip("_")
    if not normalized:
        raise PostgresConfigValidationError(
            f"{field_name} must contain at least one letter or number.",
        )
    if normalized[0].isdigit():
        normalized = f"n_{normalized}"
    if len(normalized) > 63:
        normalized = normalized[:63].rstrip("_")
    if not _PG_IDENTIFIER_PATTERN.match(normalized):
        raise PostgresConfigValidationError(
            f"{field_name} is invalid after normalization.",
        )
    return normalized


def _postgres_project_prefix(project_slug):
    project = _normalize_postgres_identifier(project_slug, "settings.project_slug")
    prefix = f"dd_{project}_"
    if len(prefix) <= 63:
        return prefix

    allowed_project_len = max(1, 63 - len("dd__"))
    project = project[:allowed_project_len].rstrip("_")
    return f"dd_{project}_"


def _postgres_prefixed_name(prefix, raw_value, field_name):
    base = _normalize_postgres_identifier(raw_value, field_name)
    # Logical names only (#80): passing an already-prefixed value straight
    # through lets a client address another project's remote name directly,
    # including nested prefixes such as dd_shop_api_* under dd_shop_.
    if base.startswith(prefix):
        raise PostgresConfigValidationError(
            f"{field_name} must be a logical name without the project prefix.",
        )
    candidate = f"{prefix}{base}"
    if len(candidate) > 63:
        remaining = max(1, 63 - len(prefix))
        candidate = f"{prefix}{base[:remaining].rstrip('_')}"
    if not _PG_IDENTIFIER_PATTERN.match(candidate):
        raise PostgresConfigValidationError(f"{field_name} produced invalid identifier.")
    return candidate


def _postgres_sql_identifier(identifier):
    return '"' + identifier.replace('"', '""') + '"'


def _postgres_sql_literal(value):
    return "'" + value.replace("'", "''") + "'"


def _postgres_generated_password():
    return os.urandom(24).hex()


def _postgres_enabled_supported_extensions(config):
    return tuple(ext for ext in config.enabled_extensions if ext in SUPPORTED_POSTGRES_EXTENSIONS)


def _postgres_enabled_unsupported_extensions(config):
    return tuple(ext for ext in config.enabled_extensions if ext in UNSUPPORTED_POSTGRES_EXTENSIONS)


def _postgres_shared_preload_libraries(config):
    libraries = []
    enabled = set(_postgres_enabled_supported_extensions(config))
    if "pg_stat_statements" in enabled:
        libraries.append("pg_stat_statements")
    if "pg_search" in enabled:
        libraries.append("pg_search")
    return tuple(libraries)


def _postgres_extensions_requiring_custom_image():
    return {"vector", "pg_search", "postgis"}


def _postgres_custom_image_variant(config):
    enabled = set(_postgres_enabled_supported_extensions(config))
    variants = []
    if "vector" in enabled:
        variants.append("vector")
    if "pg_search" in enabled:
        variants.append("pg-search")
    if "postgis" in enabled:
        variants.append("postgis")
    if not variants:
        return "base"
    return "-".join(variants)


def _postgres_requires_vector_extension(config):
    enabled = set(_postgres_enabled_supported_extensions(config))
    return "vector" in enabled


def _postgres_requires_pg_search_extension(config):
    enabled = set(_postgres_enabled_supported_extensions(config))
    return "pg_search" in enabled


def _postgres_requires_postgis_extension(config):
    enabled = set(_postgres_enabled_supported_extensions(config))
    return "postgis" in enabled


def _postgres_data_volume_target(config):
    # The 16 and 17 images declare VOLUME /var/lib/postgresql/data, so a
    # parent mount nests a second anonymous volume holding the real data,
    # which a plain `down` detaches. Mounting the named volume at the data
    # path itself defeats that on every major, including 18 (#85).
    return "/var/lib/postgresql/data"


def _postgres_pgdata_path(config):
    """Return the data directory inside the named volume, for every major.

    PGDATA sits in a pgdata subdirectory of the mount rather than at the
    mount root, so the entrypoint's ownership fixups and the migration
    copy target never fight the volume root itself (#85).
    """
    return f"{_postgres_data_volume_target(config)}/pgdata"


def _postgres_runtime_image_name(config):
    variant = _postgres_custom_image_variant(config)
    return server_identifiers.postgres_extension_image(_postgres_image_tag(config), variant)


def _postgres_image_tag(config):
    return _POSTGRES_IMAGE_TAGS_BY_MAJOR[config.postgres_version]


def _postgres_extension_image_build_command(config):
    image_name = _postgres_runtime_image_name(config)
    base_image = f"postgres:{_postgres_image_tag(config)}"
    quoted_image_name = shlex.quote(image_name)
    quoted_base_image = shlex.quote(base_image)
    quoted_pg_major = shlex.quote(config.postgres_version)
    dockerfile_body = postgres_extension_image_dockerfile(
        _postgres_custom_image_variant(config),
    )
    quoted_dockerfile_body = shlex.quote(dockerfile_body)

    return (
        "set -eu; "
        f"IMAGE_NAME={quoted_image_name}; "
        f"BASE_IMAGE={quoted_base_image}; "
        f"PG_MAJOR={quoted_pg_major}; "
        'if docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then '
        'echo "Using cached PostgreSQL extension image ${IMAGE_NAME}."; '
        "exit 0; "
        "fi; "
        'BUILD_DIR="$(mktemp -d)"; '
        'cleanup(){ rm -rf "${BUILD_DIR}" >/dev/null 2>&1 || true; }; '
        "trap cleanup EXIT INT TERM; "
        f'printf %s {quoted_dockerfile_body} > "${{BUILD_DIR}}/Dockerfile"; '
        "docker build --pull "
        '--build-arg BASE_IMAGE="${BASE_IMAGE}" '
        '--build-arg PG_MAJOR="${PG_MAJOR}" '
        '-t "${IMAGE_NAME}" '
        '"${BUILD_DIR}"'
    )


def _postgres_hba_text():
    """Render the one access policy that rejects every plaintext TCP login."""
    return (
        "local all all trust\n"
        "hostssl all all 0.0.0.0/0 scram-sha-256\n"
        "hostssl all all ::/0 scram-sha-256\n"
        "hostnossl all all 0.0.0.0/0 reject\n"
        "hostnossl all all ::/0 reject\n"
    )


def _postgres_tls_bootstrap_command(config):
    """Create persistent trust material once and converge the TLS-only HBA."""
    tls_root = shlex.quote(server_paths.postgres_tls_root())
    certificate = shlex.quote(server_paths.postgres_tls_certificate())
    private_key = shlex.quote(server_paths.postgres_tls_private_key())
    hba_file = shlex.quote(server_paths.postgres_hba_file())
    image_name = shlex.quote(_postgres_runtime_image_name(config))
    certificate_script = shlex.quote(
        "umask 077; "
        "openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 "
        "-subj '/CN=Deploy Dash PostgreSQL' "
        "-addext 'basicConstraints=critical,CA:TRUE' "
        "-addext 'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign' "
        "-addext 'extendedKeyUsage=serverAuth' "
        "-keyout /tls/server.key -out /tls/server.crt; "
        "chown postgres:postgres /tls/server.key /tls/server.crt; "
        "chmod 600 /tls/server.key; chmod 644 /tls/server.crt",
    )
    hba_text = _postgres_hba_text()
    key_pair_check = postgres_tls_key_pair_check_shell(
        '"${TLS_CERTIFICATE}"',
        '"${TLS_PRIVATE_KEY}"',
    )
    return (
        "set -eu; "
        f"TLS_ROOT={tls_root}; "
        f"TLS_CERTIFICATE={certificate}; "
        f"TLS_PRIVATE_KEY={private_key}; "
        f"HBA_FILE={hba_file}; "
        'mkdir -p "${TLS_ROOT}"; '
        'if [ ! -s "${TLS_CERTIFICATE}" ] || [ ! -s "${TLS_PRIVATE_KEY}" ]; then '
        'TLS_TMP="$(mktemp -d "${TLS_ROOT}/.tls.XXXXXX")"; '
        'cleanup_tls(){ rm -rf "${TLS_TMP}" >/dev/null 2>&1 || true; }; '
        "trap cleanup_tls EXIT INT TERM; "
        f'docker run --rm -v "${{TLS_TMP}}:/tls" {image_name} sh -eu -c '
        f"{certificate_script}; "
        'mv -f "${TLS_TMP}/server.crt" "${TLS_CERTIFICATE}"; '
        'mv -f "${TLS_TMP}/server.key" "${TLS_PRIVATE_KEY}"; '
        "trap - EXIT INT TERM; "
        'rmdir "${TLS_TMP}"; '
        "fi; "
        "cat > \"${HBA_FILE}\" <<'EOF'\n"
        f"{hba_text}"
        "EOF\n"
        'chmod 644 "${HBA_FILE}"; '
        'openssl x509 -in "${TLS_CERTIFICATE}" -noout -fingerprint -sha256 >/dev/null; '
        f"{key_pair_check}"
    )


def _postgres_service_compose_text(config, data_volume_name=None):
    image_name = _postgres_runtime_image_name(config)
    data_volume_target = _postgres_data_volume_target(config)
    pgdata_path = _postgres_pgdata_path(config)
    preload_libraries = _postgres_shared_preload_libraries(config)
    command_settings = [
        "ssl=on",
        f"ssl_cert_file={_POSTGRES_TLS_CONTAINER_ROOT}/server.crt",
        f"ssl_key_file={_POSTGRES_TLS_CONTAINER_ROOT}/server.key",
        f"hba_file={_POSTGRES_TLS_CONTAINER_ROOT}/pg_hba.conf",
    ]
    if preload_libraries:
        command_settings.append(
            f"shared_preload_libraries={','.join(preload_libraries)}",
        )
    command_block = "    command:\n      - postgres\n" + "".join(
        f"      - -c\n      - {setting}\n" for setting in command_settings
    )
    # A major upgrade retargets the logical postgres_data volume at a fresh
    # physical volume while the service mount line stays identical (#86).
    if data_volume_name is not None:
        volumes_block = f"volumes:\n  postgres_data:\n    name: {data_volume_name}\n\n"
    else:
        volumes_block = "volumes:\n  postgres_data:\n\n"
    return (
        volumes_block + "services:\n"
        "  postgres:\n"
        f"    image: {image_name}\n"
        f"    container_name: {config.container_name}\n"
        "    restart: unless-stopped\n"
        f"{docker_compose_security_lines(profile=ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING)}"
        "    env_file:\n"
        "      - .env\n"
        "    environment:\n"
        f"      PGDATA: {pgdata_path}\n"
        f"{command_block}"
        "    ports:\n"
        f'      - "{config.host_port}:5432"\n'
        "    volumes:\n"
        f"      - postgres_data:{data_volume_target}\n"
        f"      - {server_paths.postgres_tls_certificate()}:{_POSTGRES_TLS_CONTAINER_ROOT}/server.crt:ro\n"
        f"      - {server_paths.postgres_tls_private_key()}:{_POSTGRES_TLS_CONTAINER_ROOT}/server.key:ro\n"
        f"      - {server_paths.postgres_hba_file()}:{_POSTGRES_TLS_CONTAINER_ROOT}/pg_hba.conf:ro\n"
        "    healthcheck:\n"
        '      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d postgres"]\n'
        "      interval: 10s\n"
        "      timeout: 5s\n"
        "      retries: 10\n"
        "      start_period: 20s\n"
    )


def _postgres_base_env_bootstrap_command(config, data_volume_name=None):
    quoted_stack_root = shlex.quote(config.stack_root)
    quoted_superuser = shlex.quote(
        _normalize_postgres_identifier(
            config.superuser_name,
            "settings.superuser_name",
        ),
    )
    quoted_superuser_password = shlex.quote(config.superuser_password or "")
    compose_text = _postgres_service_compose_text(config, data_volume_name=data_volume_name)
    tls_bootstrap = _postgres_tls_bootstrap_command(config)
    compose_write_command = f"cat > \"${{COMPOSE_FILE}}\" <<'EOF'\n{compose_text}EOF\n"

    return (
        "set -eu; "
        f"STACK_ROOT={quoted_stack_root}; "
        'ENV_FILE="${STACK_ROOT}/.env"; '
        'COMPOSE_FILE="${STACK_ROOT}/docker-compose.yml"; '
        'mkdir -p "${STACK_ROOT}"; '
        f"{tls_bootstrap}"
        f"POSTGRES_USER={quoted_superuser}; "
        f'if [ -z "${{POSTGRES_USER}}" ]; then '
        f"POSTGRES_USER='{server_identifiers.POSTGRES_SUPERUSER}'; fi; "
        f"POSTGRES_PASSWORD={quoted_superuser_password}; "
        '[ -n "${POSTGRES_PASSWORD}" ] || '
        "(echo 'settings.superuser_password must be set in Deploy Dash.' >&2; exit 1); "
        'cat > "${ENV_FILE}" <<EOF\n'
        "POSTGRES_USER=${POSTGRES_USER}\n"
        "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}\n"
        "POSTGRES_DB=postgres\n"
        "EOF\n"
        'chmod 600 "${ENV_FILE}"; '
        f"{compose_write_command}"
    )


def _postgres_compose_apply_command(config):
    quoted_compose_file = shlex.quote(f"{config.stack_root}/docker-compose.yml")
    return (
        f"COMPOSE_FILE={quoted_compose_file}; "
        "if docker compose version >/dev/null 2>&1; then "
        'docker compose -f "${COMPOSE_FILE}" config >/dev/null; '
        'docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans; '
        "elif command -v docker-compose >/dev/null 2>&1; then "
        'docker-compose -f "${COMPOSE_FILE}" config >/dev/null; '
        'docker-compose -f "${COMPOSE_FILE}" up -d --remove-orphans; '
        "else "
        "echo 'docker compose is unavailable.' >&2; "
        "exit 1; "
        "fi"
    )


def _postgres_readiness_command(config):
    quoted_container_name = shlex.quote(config.container_name)
    quoted_superuser = shlex.quote(
        _normalize_postgres_identifier(
            config.superuser_name,
            "settings.superuser_name",
        ),
    )
    return (
        "set -eu; "
        "ATTEMPT=1; "
        "MAX_ATTEMPTS=45; "
        'while [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; do '
        "RUNNING=\"$(docker inspect -f '{{.State.Running}}' "
        f'{quoted_container_name} 2>/dev/null || echo false)"; '
        "HEALTH=\"$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "
        f'{quoted_container_name} 2>/dev/null || echo unknown)"; '
        'if [ "${RUNNING}" = true ] && [ "${HEALTH}" = healthy ]; then '
        "exit 0; "
        "fi; "
        'if [ "${RUNNING}" = true ] && [ "${HEALTH}" = none ] && '
        "docker exec "
        f"{quoted_container_name} "
        "pg_isready -U "
        f"{quoted_superuser} "
        "-d postgres >/dev/null 2>&1; then "
        "exit 0; "
        "fi; "
        "sleep 2; "
        "ATTEMPT=$((ATTEMPT+1)); "
        "done; "
        "RUNNING=\"$(docker inspect -f '{{.State.Running}}' "
        f'{quoted_container_name} 2>/dev/null || echo false)"; '
        "HEALTH=\"$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "
        f'{quoted_container_name} 2>/dev/null || echo unknown)"; '
        'echo "PostgreSQL readiness probe failed after ${MAX_ATTEMPTS} attempts '
        '(running=${RUNNING}, health=${HEALTH})." >&2; '
        f"docker logs --tail 40 {quoted_container_name} >&2 || true; "
        "exit 1"
    )


def _postgres_readiness_probe_command(config):
    quoted_container_name = shlex.quote(config.container_name)
    quoted_superuser = shlex.quote(
        _normalize_postgres_identifier(
            config.superuser_name,
            "settings.superuser_name",
        ),
    )
    return (
        "set -eu; "
        "RUNNING=\"$(docker inspect -f '{{.State.Running}}' "
        f'{quoted_container_name} 2>/dev/null || echo false)"; '
        '[ "${RUNNING}" = true ] || exit 1; '
        "HEALTH=\"$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "
        f'{quoted_container_name} 2>/dev/null || echo unknown)"; '
        'if [ "${HEALTH}" = healthy ]; then '
        "exit 0; "
        "fi; "
        'if [ "${HEALTH}" = none ] && docker exec '
        f"{quoted_container_name} "
        "pg_isready -U "
        f"{quoted_superuser} "
        "-d postgres >/dev/null 2>&1; then "
        "exit 0; "
        "fi; "
        "exit 1"
    )


def _postgres_readiness_diagnostics_command(config):
    quoted_container_name = shlex.quote(config.container_name)
    quoted_compose_file = shlex.quote(f"{config.stack_root}/docker-compose.yml")
    return (
        "set -eu; "
        "RUNNING=\"$(docker inspect -f '{{.State.Running}}' "
        f'{quoted_container_name} 2>/dev/null || echo false)"; '
        "HEALTH=\"$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "
        f'{quoted_container_name} 2>/dev/null || echo unknown)"; '
        'echo "PostgreSQL readiness diagnostics: running=${RUNNING}, health=${HEALTH}" >&2; '
        "if docker inspect "
        f"{quoted_container_name} >/dev/null 2>&1; then "
        "docker inspect -f "
        "'PostgreSQL container state: status={{.State.Status}} exit={{.State.ExitCode}} "
        "error={{.State.Error}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' "
        f"{quoted_container_name} >&2 || true; "
        "fi; "
        "if [ -f "
        f"{quoted_compose_file}"
        " ]; then "
        f"COMPOSE_FILE={quoted_compose_file}; "
        "echo 'PostgreSQL compose file (line numbered):' >&2; "
        'nl -ba "${COMPOSE_FILE}" >&2 || cat "${COMPOSE_FILE}" >&2 || true; '
        "if docker compose version >/dev/null 2>&1; then "
        'docker compose -f "${COMPOSE_FILE}" ps >&2 || true; '
        "elif command -v docker-compose >/dev/null 2>&1; then "
        'docker-compose -f "${COMPOSE_FILE}" ps >&2 || true; '
        "fi; "
        "fi; "
        f"docker ps -a --filter name={quoted_container_name} >&2 || true; "
        f"docker logs --tail 60 {quoted_container_name} >&2 || true"
    )


def _postgres_sync_superuser_command(config):
    quoted_container_name = shlex.quote(config.container_name)
    superuser = _normalize_postgres_identifier(
        config.superuser_name,
        "settings.superuser_name",
    )
    password = config.superuser_password or ""
    quoted_password = shlex.quote(password)
    quoted_superuser = shlex.quote(superuser)
    sql = (
        "DO $$ BEGIN "
        f"IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = {_postgres_sql_literal(superuser)}) THEN "
        f"CREATE ROLE {_postgres_sql_identifier(superuser)} LOGIN SUPERUSER PASSWORD {_postgres_sql_literal(password)}; "
        "ELSE "
        f"ALTER ROLE {_postgres_sql_identifier(superuser)} LOGIN SUPERUSER PASSWORD {_postgres_sql_literal(password)}; "
        "END IF; "
        "END $$;"
    )
    quoted_sql = shlex.quote(sql)
    return (
        "set -eu; "
        f"SUPERUSER_NAME={quoted_superuser}; "
        f"SUPERUSER_PASSWORD={quoted_password}; "
        '[ -n "${SUPERUSER_NAME}" ] || '
        "(echo 'settings.superuser_name must be set in Deploy Dash.' >&2; exit 1); "
        '[ -n "${SUPERUSER_PASSWORD}" ] || '
        "(echo 'settings.superuser_password must be set in Deploy Dash.' >&2; exit 1); "
        'docker exec -e PGPASSWORD="${SUPERUSER_PASSWORD}" '
        f"{quoted_container_name} "
        'psql -v ON_ERROR_STOP=1 -U "${SUPERUSER_NAME}" -d postgres -c '
        f"{quoted_sql}"
    )


def _postgres_apply_extensions_command(config, database_name=None):
    enabled_extensions = _postgres_enabled_supported_extensions(config)
    if not enabled_extensions:
        return "echo 'No PostgreSQL extensions selected; skipping extension setup.'"

    quoted_container_name = shlex.quote(config.container_name)
    quoted_superuser = shlex.quote(
        _normalize_postgres_identifier(
            config.superuser_name,
            "settings.superuser_name",
        ),
    )
    quoted_superuser_password = shlex.quote(config.superuser_password or "")
    extension_sql_parts = []
    for extension in enabled_extensions:
        extension_sql_parts.append(
            f'CREATE EXTENSION IF NOT EXISTS "{extension}";',
        )
    extension_sql = " ".join(extension_sql_parts)
    quoted_extension_sql = shlex.quote(extension_sql)

    if database_name is None:
        discover_sql = shlex.quote(
            "SELECT datname FROM pg_database "
            "WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' "
            "ORDER BY datname;",
        )
        database_list_command = (
            'ADDITIONAL_DATABASES="$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" '
            '"${CONTAINER_NAME}" psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" '
            f'-d postgres -tA -c {discover_sql})" || '
            "(echo 'Unable to list existing PostgreSQL databases.' >&2; exit 1); "
            'DATABASES="template1 postgres ${ADDITIONAL_DATABASES}"; '
        )
    else:
        quoted_database_name = shlex.quote(database_name)
        database_list_command = f"DATABASES={quoted_database_name}; "
    database_loop = (
        "for DB in ${DATABASES}; do "
        '[ -n "${DB}" ] || continue; '
        'docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" '
        '"${CONTAINER_NAME}" '
        'psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${DB}" -c '
        f"{quoted_extension_sql}; "
        "done"
    )

    return (
        "set -eu; "
        f"CONTAINER_NAME={quoted_container_name}; "
        f"POSTGRES_USER={quoted_superuser}; "
        f"POSTGRES_PASSWORD={quoted_superuser_password}; "
        'docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1 || '
        '(echo "PostgreSQL container ${CONTAINER_NAME} does not exist." >&2; exit 1); '
        '[ -n "${POSTGRES_USER}" ] || '
        "(echo 'settings.superuser_name must be set in Deploy Dash.' >&2; exit 1); "
        '[ -n "${POSTGRES_PASSWORD}" ] || '
        "(echo 'settings.superuser_password must be set in Deploy Dash.' >&2; exit 1); "
        f"{database_list_command}"
        f"{database_loop}"
    )


def _postgres_base_env_prefix(config):
    quoted_env_file = shlex.quote(f"{config.stack_root}/.env")
    quoted_container_name = shlex.quote(config.container_name)
    quoted_superuser = shlex.quote(
        _normalize_postgres_identifier(
            config.superuser_name,
            "settings.superuser_name",
        ),
    )
    quoted_superuser_password = shlex.quote(config.superuser_password or "")
    container_ref = '"${CONTAINER_NAME}"'
    postgres_user_ref = '"${POSTGRES_USER}"'
    return (
        "set -eu; "
        f"ENV_FILE={quoted_env_file}; "
        '[ -f "${ENV_FILE}" ] || '
        "(echo 'PostgreSQL service is not configured yet. Enable Database service first.' >&2; exit 1); "
        f"POSTGRES_USER={quoted_superuser}; "
        f"POSTGRES_PASSWORD={quoted_superuser_password}; "
        '[ -n "${POSTGRES_USER}" ] || '
        "(echo 'settings.superuser_name must be set in Deploy Dash.' >&2; exit 1); "
        '[ -n "${POSTGRES_PASSWORD}" ] || '
        "(echo 'settings.superuser_password must be set in Deploy Dash.' >&2; exit 1); "
        f"CONTAINER_NAME={quoted_container_name}; "
        f"{postgres_service_readiness_check_shell(container_ref, postgres_user_ref)} || "
        "(echo 'PostgreSQL service is not ready.' >&2; exit 1); "
    )


def _postgres_service_status_command(config):
    quoted_env_file = shlex.quote(f"{config.stack_root}/.env")
    quoted_container_name = shlex.quote(config.container_name)
    quoted_superuser = shlex.quote(
        _normalize_postgres_identifier(
            config.superuser_name,
            "settings.superuser_name",
        ),
    )
    quoted_superuser_password = shlex.quote(config.superuser_password or "")
    container_ref = '"${CONTAINER_NAME}"'
    postgres_user_ref = '"${POSTGRES_USER}"'
    container_probe = container_status_kv_shell("container", container_ref)
    tls_certificate = shlex.quote(server_paths.postgres_tls_certificate())
    tls_private_key = shlex.quote(server_paths.postgres_tls_private_key())
    hba_file = shlex.quote(server_paths.postgres_hba_file())
    return (
        "set -eu; "
        'kv(){ printf "%s=%s\\n" "$1" "$2"; }; '
        f"ENV_FILE={quoted_env_file}; "
        f"CONTAINER_NAME={quoted_container_name}; "
        "CONFIGURED='false'; "
        "CONFIGURED_FLAG=0; "
        "if [ -f \"${ENV_FILE}\" ]; then CONFIGURED='true'; CONFIGURED_FLAG=1; fi; "
        'kv configured "${CONFIGURED_FLAG}"; '
        f"{container_probe}; "
        "READINESS_STATUS='not_checked'; "
        "READINESS_DETAIL=''; "
        "VERSION=''; "
        "TLS_ENABLED=0; "
        "TLS_CA_FINGERPRINT=''; "
        "TLS_CA_CERTIFICATE_BASE64=''; "
        f"TLS_CERTIFICATE={tls_certificate}; "
        f"TLS_PRIVATE_KEY={tls_private_key}; "
        f"HBA_FILE={hba_file}; "
        'if [ -s "${TLS_CERTIFICATE}" ] && [ -s "${TLS_PRIVATE_KEY}" ] && '
        '[ -s "${HBA_FILE}" ]; then '
        "TLS_ENABLED=1; "
        'TLS_CA_FINGERPRINT="$(openssl x509 -in "${TLS_CERTIFICATE}" '
        "-noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//')\"; "
        'TLS_CA_CERTIFICATE_BASE64="$(base64 -w 0 "${TLS_CERTIFICATE}")"; '
        "fi; "
        f"POSTGRES_USER={quoted_superuser}; "
        f"POSTGRES_PASSWORD={quoted_superuser_password}; "
        f"if {postgres_service_readiness_check_shell(container_ref, postgres_user_ref)}; then "
        "READINESS_STATUS='ready'; "
        "else "
        "READINESS_STATUS='unhealthy'; "
        "READINESS_DETAIL='pg_isready failed'; "
        "fi; "
        f"if {container_process_running_check_shell(container_ref)}; then "
        'if [ -n "${POSTGRES_USER}" ] && [ -n "${POSTGRES_PASSWORD}" ]; then '
        'VERSION="$(docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" '
        "psql -U \"${POSTGRES_USER}\" -d postgres -tA -c 'SHOW server_version;' 2>/dev/null | head -n1 | tr -d '[:space:]')\"; "
        "fi; "
        "fi; "
        'kv container_readiness_status "${READINESS_STATUS}"; '
        'kv container_readiness_detail "${READINESS_DETAIL}"; '
        'kv version "${VERSION}"; '
        'kv tls_enabled "${TLS_ENABLED}"; '
        'kv tls_ca_fingerprint "${TLS_CA_FINGERPRINT}"; '
        'kv tls_ca_certificate_base64 "${TLS_CA_CERTIFICATE_BASE64}"'
    )


__all__ = tuple(name for name in globals() if not name.startswith("__"))
