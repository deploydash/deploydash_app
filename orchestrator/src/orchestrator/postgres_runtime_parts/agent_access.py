import csv
import json
import time
from io import StringIO

from .. import server_identifiers, shell_output
from ..container_status import (
    container_status_from_payload,
    normalize_container_status,
)
from ..server_identifiers import POSTGRES_QUERY_ALIAS, POSTGRES_ROLE_COMMENT_PREFIX

# ruff: noqa: F403, F405
from .service_configuration import *


def _run_postgres_psql_query_impl(
    ctx, session, config, sql, database="postgres", emit=None, run_as_user=None
):
    quoted_database = shlex.quote(database)
    quoted_sql = shlex.quote(sql)
    if run_as_user is None:
        user_flag = '-U "${POSTGRES_USER}"'
        password_flag = '-e PGPASSWORD="${POSTGRES_PASSWORD}" '
    else:
        # Agent tools log in as the per-database reader over the trusted
        # container socket, with no password sent (#83).
        user_flag = f"-U {shlex.quote(run_as_user)}"
        password_flag = ""
    command = (
        _postgres_base_env_prefix(config) + f"docker exec {password_flag}"
        '"${CONTAINER_NAME}" '
        f"psql -v ON_ERROR_STOP=1 {user_flag} "
        f"-d {quoted_database} -tA -c {quoted_sql}"
    )
    status, output = session.host.run_shell_command(
        command,
        _timeout=60,
        _sudo=True,
    )
    ctx.emit_shell_output_lines(emit, output)
    return status, output


def _postgres_collect_service_status(ctx, session, postgres_config, emit, operation_id):
    status_command = _postgres_service_status_command(postgres_config)
    try:
        status_ok, status_output = session.host.run_shell_command(
            status_command,
            _timeout=120,
            _sudo=True,
        )
    except Exception as exc:
        return None, ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not collect PostgreSQL service status.",
            stage="execute_runtime_operation",
            details=str(exc),
            extra={"operation_id": operation_id},
        )
    ctx.emit_shell_output_lines(emit, status_output)
    if not status_ok:
        return None, ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not collect PostgreSQL service status.",
            stage="execute_runtime_operation",
            details=ctx.command_error_details(status_output) or "remote command failed",
            extra={"operation_id": operation_id},
        )
    return _parse_postgres_service_status_output(status_output), None


def _postgres_collect_engine_version(ctx, session, postgres_config, emit):
    version_sql = "SELECT current_setting('server_version');"
    version_status, version_output = _run_postgres_psql_query_impl(
        ctx,
        session,
        postgres_config,
        version_sql,
        emit=emit,
    )
    if not version_status or version_output is None:
        return None
    version_lines = getattr(version_output, "stdout_lines", None) or []
    for raw_line in version_lines:
        line = str(raw_line).strip()
        if line:
            return line
    return None


def _postgres_database_exists(ctx, session, postgres_config, database_name, emit):
    db_exists_sql = (
        f"SELECT 1 FROM pg_database WHERE datname = {_postgres_sql_literal(database_name)};"
    )
    db_exists_status, db_exists_output = _run_postgres_psql_query_impl(
        ctx,
        session,
        postgres_config,
        db_exists_sql,
        emit=emit,
    )
    if not db_exists_status:
        return None, ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not inspect target database.",
            stage="execute_runtime_operation",
            details=ctx.command_error_details(db_exists_output) or "remote command failed",
        )
    return _postgres_output_has_one(db_exists_output), None


def _parse_postgres_service_status_output(output):
    parsed = shell_output.parse_key_values(output)
    if parsed and any(
        key in parsed
        for key in (
            "configured",
            "container_present",
            "version",
            "tls_enabled",
        )
    ):
        configured = parsed.get("configured") == "1"
        container_status = container_status_from_payload(parsed, "container")
        return {
            "running": container_status["running"],
            "health": container_status["health"],
            "version": parsed.get("version") or None,
            "configured": configured,
            "container_status": container_status,
            "tls_enabled": parsed.get("tls_enabled") == "1",
            "tls_ca_fingerprint": parsed.get("tls_ca_fingerprint") or None,
            "tls_ca_certificate_base64": parsed.get("tls_ca_certificate_base64") or None,
        }
    # Fallback: some builds answer with a single JSON line instead of the
    # KEY=value protocol, so the raw lines are still needed here.
    for raw_line in reversed(getattr(output, "stdout_lines", None) or []):
        line = str(raw_line).strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        container_status = payload.get("container_status")
        if not isinstance(container_status, dict):
            container_status = normalize_container_status(
                present=bool(payload.get("running")) or bool(payload.get("configured")),
                docker_state="running" if payload.get("running") else "exited",
                running=bool(payload.get("running")),
                health=str(payload.get("health") or "unknown"),
            )
        return {
            "running": bool(payload.get("running")),
            "health": str(payload.get("health") or "unknown"),
            "version": payload.get("version"),
            "configured": bool(payload.get("configured")),
            "container_status": container_status,
            "tls_enabled": bool(payload.get("tls_enabled")),
            "tls_ca_fingerprint": payload.get("tls_ca_fingerprint"),
            "tls_ca_certificate_base64": payload.get("tls_ca_certificate_base64"),
        }
    return {
        "running": False,
        "health": "down",
        "version": None,
        "configured": False,
        "container_status": normalize_container_status(),
        "tls_enabled": False,
        "tls_ca_fingerprint": None,
        "tls_ca_certificate_base64": None,
    }


def _postgres_service_is_ready(service_status):
    if not isinstance(service_status, dict):
        return False
    container_status = service_status.get("container_status")
    if isinstance(container_status, dict):
        return container_status.get("effective_status") == "ready"
    return service_status.get("running") is True


def _postgres_output_has_one(output):
    stdout_lines = getattr(output, "stdout_lines", None) or []
    return any(str(raw_line).strip() == "1" for raw_line in stdout_lines)


def _postgres_local_sql_import_confirmed(output):
    stdout_lines = getattr(output, "stdout_lines", None) or []
    return any(
        str(raw_line).strip() == _LOCAL_SQL_IMPORT_SUCCESS_MARKER for raw_line in stdout_lines
    )


def _postgres_connection_uri_host_for_managed_apps():
    return "host.docker.internal"


def _parse_postgres_role_comment(comment):
    if not isinstance(comment, str):
        return {"database": None, "access_mode": "read_write", "project": None}
    if not comment.startswith(POSTGRES_ROLE_COMMENT_PREFIX):
        return {"database": None, "access_mode": "read_write", "project": None}

    metadata = {"database": None, "access_mode": "read_write", "project": None}
    payload = comment[len(POSTGRES_ROLE_COMMENT_PREFIX) :]
    for chunk in payload.split(";"):
        key, _, value = chunk.partition("=")
        key = key.strip().lower()
        value = value.strip()
        if key == "db" and value:
            metadata["database"] = value
        if key == "access" and value in ("read_write", "read_only"):
            metadata["access_mode"] = value
        if key == "project" and value:
            metadata["project"] = value
    return metadata


def _postgres_strip_project_prefix(project_prefix, database_name):
    if not isinstance(database_name, str):
        return None
    if database_name.startswith(project_prefix):
        return database_name[len(project_prefix) :]
    return database_name


def _postgres_validate_agent_query_sql(sql):
    if not isinstance(sql, str):
        raise PostgresConfigValidationError("settings.sql must be a string.")
    normalized = sql.strip()
    if not normalized:
        raise PostgresConfigValidationError("settings.sql is required.")
    if "\x00" in normalized:
        raise PostgresConfigValidationError("settings.sql contains invalid null bytes.")
    if len(normalized) > _POSTGRES_AGENT_QUERY_SQL_MAX_LENGTH:
        raise PostgresConfigValidationError(
            "settings.sql must be 20000 characters or fewer.",
        )
    if ";" in normalized:
        raise PostgresConfigValidationError(
            "settings.sql must be a single statement without semicolons.",
        )
    if "--" in normalized or "/*" in normalized or "*/" in normalized:
        raise PostgresConfigValidationError(
            "settings.sql comments are not allowed.",
        )
    upper = normalized.lstrip().upper()
    if not (upper.startswith("SELECT ") or upper == "SELECT" or upper.startswith("WITH ")):
        raise PostgresConfigValidationError(
            "settings.sql must start with SELECT or WITH.",
        )
    return normalized


def _postgres_agent_query_max_rows(raw_value):
    if raw_value is None:
        return _POSTGRES_AGENT_QUERY_DEFAULT_MAX_ROWS
    try:
        value = int(raw_value)
    except (TypeError, ValueError):
        raise PostgresConfigValidationError("settings.max_rows must be an integer.") from None
    if value < 1 or value > _POSTGRES_AGENT_QUERY_MAX_ROWS:
        raise PostgresConfigValidationError(
            f"settings.max_rows must be between 1 and {_POSTGRES_AGENT_QUERY_MAX_ROWS}.",
        )
    return value


def _postgres_agent_wrapped_query(sql, *, limit=None):
    base = f"SELECT * FROM ({sql}) AS {POSTGRES_QUERY_ALIAS}"
    if limit is None:
        return base
    return f"{base} LIMIT {int(limit)}"


def _postgres_agent_readonly_block(sql):
    return (
        "BEGIN READ ONLY; "
        f"SET LOCAL statement_timeout = '{_POSTGRES_AGENT_QUERY_TIMEOUT_MS}'; "
        "SET LOCAL default_transaction_read_only = on; "
        f"{sql}; "
        "ROLLBACK;"
    )


def _postgres_agent_result_too_large(payload):
    encoded = json.dumps(payload).encode("utf-8")
    return len(encoded) > _POSTGRES_AGENT_QUERY_RESULT_MAX_BYTES


def _run_postgres_agent_readonly_query(
    ctx,
    session,
    postgres_config,
    *,
    operation_id,
    database_name,
    base_response,
    service_status,
    ip,
    emit=None,
):
    try:
        validated_sql = _postgres_validate_agent_query_sql(
            postgres_config.sql,
        )
        max_rows = _postgres_agent_query_max_rows(
            postgres_config.max_rows,
        )
    except PostgresConfigValidationError as exc:
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            str(exc),
            stage="validate_request",
            extra={
                "service_status": service_status,
                "host": ip,
                "port": postgres_config.host_port,
            },
        )
    reader_name = server_identifiers.postgres_agent_reader_role_name(database_name)
    if operation_id == "project_explain_readonly_query":
        explain_sql = _postgres_agent_readonly_block(
            f"EXPLAIN (FORMAT JSON, VERBOSE TRUE, COSTS TRUE) {validated_sql}"
        )
        started = time.perf_counter()
        explain_status, explain_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            explain_sql,
            database=database_name,
            emit=emit,
            run_as_user=reader_name,
        )
        duration_ms = int((time.perf_counter() - started) * 1000)
        if not explain_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not explain project database query.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(explain_output) or "remote command failed",
            )
        try:
            plan = _postgres_collect_json_rows(explain_output)
        except (json.JSONDecodeError, ValueError):
            plan = []
        return {
            **base_response,
            "msg": "Project database query plan collected.",
            "duration_ms": duration_ms,
            "plan": plan if isinstance(plan, list) else [],
        }

    header_sql = _postgres_agent_readonly_block(
        "COPY ("
        + _postgres_agent_wrapped_query(validated_sql, limit=0)
        + ") TO STDOUT WITH CSV HEADER"
    )
    header_status, header_output = _run_postgres_psql_query_impl(
        ctx,
        session,
        postgres_config,
        header_sql,
        database=database_name,
        emit=emit,
        run_as_user=reader_name,
    )
    if not header_status:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not inspect query columns.",
            stage="execute_runtime_operation",
            details=ctx.command_error_details(header_output) or "remote command failed",
        )
    columns = _postgres_collect_csv_columns(header_output)
    row_limit = max_rows + 1
    data_sql = _postgres_agent_readonly_block(
        "SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)::text FROM ("
        + _postgres_agent_wrapped_query(validated_sql, limit=row_limit)
        + ") AS t"
    )
    started = time.perf_counter()
    data_status, data_output = _run_postgres_psql_query_impl(
        ctx,
        session,
        postgres_config,
        data_sql,
        database=database_name,
        emit=emit,
        run_as_user=reader_name,
    )
    duration_ms = int((time.perf_counter() - started) * 1000)
    if not data_status:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not execute project database query.",
            stage="execute_runtime_operation",
            details=ctx.command_error_details(data_output) or "remote command failed",
        )
    try:
        rows = _postgres_collect_json_rows(data_output)
    except ValueError as exc:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not parse project database query results.",
            stage="execute_runtime_operation",
            details=str(exc),
        )
    truncated = len(rows) > max_rows
    if truncated:
        rows = rows[:max_rows]
    result_payload = {
        **base_response,
        "msg": "Project database query completed.",
        "max_rows": max_rows,
        "columns": columns,
        "rows": rows,
        "row_count_returned": len(rows),
        "truncated": truncated,
        "duration_ms": duration_ms,
    }
    if _postgres_agent_result_too_large(result_payload):
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Project database query results are too large to return.",
            stage="execute_runtime_operation",
            details="result_too_large",
        )
    return result_payload


def _postgres_collect_csv_columns(output):
    stdout_lines = getattr(output, "stdout_lines", None) or []
    text = "\n".join(str(line) for line in stdout_lines if str(line).strip())
    if not text:
        return []
    reader = csv.reader(StringIO(text))
    try:
        header = next(reader)
    except StopIteration:
        return []
    return [str(item) for item in header]


def _postgres_collect_json_rows(output):
    stdout_lines = getattr(output, "stdout_lines", None) or []
    last_decode_error = None
    # Fallback: some builds answer with a single JSON line instead of the
    # KEY=value protocol, so the raw lines are still needed here.
    for raw_line in reversed(getattr(output, "stdout_lines", None) or []):
        line = str(raw_line).strip()
        if not line:
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError as exc:
            last_decode_error = exc
            continue
        if not isinstance(parsed, list):
            raise ValueError("query result payload must be a JSON array")
        rows = []
        for item in parsed:
            if isinstance(item, dict):
                rows.append({str(key): value for key, value in item.items()})
        return rows
    if not stdout_lines:
        return []
    if last_decode_error is not None:
        raise last_decode_error
    return []


def _postgres_assign_ddl_ownership_sql(database_name, owner_name):
    """Build the statements that hand a database and its objects to its owner.

    The owner role owns everything: the database, the public schema and all
    tables and sequences in it. Runs at database creation and during
    normalization only -- creating a user never moves ownership (#81).
    """
    database_identifier = _postgres_sql_identifier(database_name)
    owner_identifier = _postgres_sql_identifier(owner_name)
    owner_literal = _postgres_sql_literal(owner_name)
    return (
        f"ALTER DATABASE {database_identifier} OWNER TO {owner_identifier}; "
        f"ALTER SCHEMA public OWNER TO {owner_identifier}; "
        "DO $$ "
        "DECLARE obj record; "
        "BEGIN "
        "FOR obj IN "
        "SELECT n.nspname AS schema_name, c.relname AS object_name "
        "FROM pg_class c "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') "
        "LOOP "
        f"EXECUTE format('ALTER TABLE %I.%I OWNER TO %I', obj.schema_name, obj.object_name, {owner_literal}); "
        "END LOOP; "
        "FOR obj IN "
        "SELECT n.nspname AS schema_name, c.relname AS object_name "
        "FROM pg_class c "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = 'public' AND c.relkind = 'S' "
        "AND NOT EXISTS ("
        "SELECT 1 FROM pg_depend d "
        "WHERE d.classid = 'pg_class'::regclass "
        "AND d.objid = c.oid "
        "AND d.deptype IN ('a', 'i')"
        ") "
        "LOOP "
        f"EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO %I', obj.schema_name, obj.object_name, {owner_literal}); "
        "END LOOP; "
        "END "
        "$$;"
    )


def _postgres_reclaim_ddl_ownership_sql(database_name, username_name):
    database_identifier = _postgres_sql_identifier(database_name)
    username_literal = _postgres_sql_literal(username_name)
    return (
        "DO $$ "
        "BEGIN "
        "IF EXISTS ("
        "SELECT 1 FROM pg_database d "
        "JOIN pg_roles r ON r.oid = d.datdba "
        f"WHERE d.datname = {_postgres_sql_literal(database_name)} "
        f"AND r.rolname = {username_literal}"
        ") THEN "
        f"ALTER DATABASE {database_identifier} OWNER TO CURRENT_USER; "
        "END IF; "
        "END "
        "$$; "
        "DO $$ "
        "BEGIN "
        "IF EXISTS ("
        "SELECT 1 FROM pg_namespace n "
        "JOIN pg_roles r ON r.oid = n.nspowner "
        f"WHERE n.nspname = 'public' AND r.rolname = {username_literal}"
        ") THEN "
        "ALTER SCHEMA public OWNER TO CURRENT_USER; "
        "END IF; "
        "END "
        "$$; "
        "DO $$ "
        "DECLARE obj record; "
        "BEGIN "
        "FOR obj IN "
        "SELECT n.nspname AS schema_name, c.relname AS object_name "
        "FROM pg_class c "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "JOIN pg_roles r ON r.oid = c.relowner "
        "WHERE n.nspname = 'public' "
        "AND c.relkind IN ('r', 'p') "
        f"AND r.rolname = {username_literal} "
        "LOOP "
        "EXECUTE format('ALTER TABLE %I.%I OWNER TO %I', obj.schema_name, obj.object_name, current_user); "
        "END LOOP; "
        "FOR obj IN "
        "SELECT n.nspname AS schema_name, c.relname AS object_name "
        "FROM pg_class c "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "JOIN pg_roles r ON r.oid = c.relowner "
        "WHERE n.nspname = 'public' "
        "AND c.relkind = 'S' "
        f"AND r.rolname = {username_literal} "
        "AND NOT EXISTS ("
        "SELECT 1 FROM pg_depend d "
        "WHERE d.classid = 'pg_class'::regclass "
        "AND d.objid = c.oid "
        "AND d.deptype IN ('a', 'i')"
        ") "
        "LOOP "
        "EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO %I', obj.schema_name, obj.object_name, current_user); "
        "END LOOP; "
        "END "
        "$$;"
    )


def _postgres_ensure_owner_role_sql(owner_name):
    """Build the idempotent statement that provisions a database owner role.

    The owner is NOLOGIN with no password: it exists only to own the
    database and its objects, and every read-write user reaches it through
    membership plus a pinned session role, so ownership never moves when a
    user is added or removed (#81).
    """
    return (
        "DO $$ "
        "BEGIN "
        "IF NOT EXISTS ("
        f"SELECT 1 FROM pg_roles WHERE rolname = {_postgres_sql_literal(owner_name)}"
        ") THEN "
        f"CREATE ROLE {_postgres_sql_identifier(owner_name)} NOLOGIN; "
        "END IF; "
        "END "
        "$$;"
    )


def _postgres_owner_membership_sql(owner_name, username_name, *, database_name):
    """Build the membership that lets a user act as the database owner.

    The grant gives the user the owner's rights and the database-scoped pinned
    role makes sessions create objects as the right owner without changing the
    same login's behavior in its other managed databases (#81).
    """
    return (
        f"GRANT {_postgres_sql_identifier(owner_name)} "
        f"TO {_postgres_sql_identifier(username_name)}; "
        f"ALTER ROLE {_postgres_sql_identifier(username_name)} "
        f"IN DATABASE {_postgres_sql_identifier(database_name)} "
        f"SET role = {_postgres_sql_identifier(owner_name)};"
    )


def _postgres_reassign_owned_if_exists_sql(username_name):
    """Build the per-user cleanup that skips roles that were never created.

    Delete-database appends the derived owner to the cleanup list even when
    it was never provisioned (pre-#81 databases, rolled-back creates), and
    registry rows can outlive their roles. PostgreSQL rejects a bare
    REASSIGN OWNED BY for a missing role, so the cleanup probes pg_roles
    first and skips the role instead of failing the whole delete (#81).
    """
    return (
        "DO $$ "
        "BEGIN "
        "IF EXISTS ("
        f"SELECT 1 FROM pg_roles WHERE rolname = {_postgres_sql_literal(username_name)}"
        ") THEN "
        f"REASSIGN OWNED BY {_postgres_sql_identifier(username_name)} TO CURRENT_USER; "
        f"DROP OWNED BY {_postgres_sql_identifier(username_name)}; "
        "END IF; "
        "END "
        "$$;"
    )


def _postgres_existing_roles_sql(username_names):
    """Build the query listing which of the given roles still exist.

    Delete-database verifies the dropped users are actually gone before it
    unregisters them: the check reads live pg_roles, because the registry
    rows still exist until the unregister step that follows (#80, #81).
    """
    names = ", ".join(_postgres_sql_literal(name) for name in username_names)
    return f"SELECT rolname FROM pg_roles WHERE rolname IN ({names}) ORDER BY rolname;"


def _postgres_ensure_agent_reader_role_sql(reader_name):
    """Build the idempotent statement that provisions an agent reader role.

    The agent tools log in as this role instead of the superuser, so a
    steered agent can only ever see what the reader can see. LOGIN with no
    password: reachable over the trusted container socket the engine
    queries through, unreachable over TCP where SCRAM applies. The role
    limits converge on every run, so a role provisioned earlier still gets
    them, and nothing ever grants the reader membership anywhere (#83).
    """
    reader_identifier = _postgres_sql_identifier(reader_name)
    reader_literal = _postgres_sql_literal(reader_name)
    return (
        "DO $$ "
        "BEGIN "
        "IF NOT EXISTS ("
        f"SELECT 1 FROM pg_roles WHERE rolname = {reader_literal}"
        ") THEN "
        f"CREATE ROLE {reader_identifier} LOGIN CONNECTION LIMIT 2; "
        "END IF; "
        "END "
        "$$; "
        f"ALTER ROLE {reader_identifier} WITH LOGIN CONNECTION LIMIT 2; "
        f"ALTER ROLE {reader_identifier} SET default_transaction_read_only = on; "
        f"ALTER ROLE {reader_identifier} SET statement_timeout = '30s'; "
        f"ALTER ROLE {reader_identifier} SET idle_in_transaction_session_timeout = '60s'; "
        f"ALTER ROLE {reader_identifier} SET temp_file_limit = '512MB';"
    )


def _postgres_agent_reader_grants_sql(database_name, owner_name, reader_name):
    """Build the explicit grants confining an agent reader to one database.

    CONNECT on its database plus SELECT on the app schema's tables (which
    covers views), sequences, and future objects through the owner's
    default privileges. Deliberately not pg_read_all_data, which is
    cluster-wide and broader than one database needs (#83).
    """
    return (
        f"GRANT CONNECT ON DATABASE {_postgres_sql_identifier(database_name)} "
        f"TO {_postgres_sql_identifier(reader_name)}; "
        f"GRANT USAGE ON SCHEMA public TO {_postgres_sql_identifier(reader_name)}; "
        f"GRANT SELECT ON ALL TABLES IN SCHEMA public TO {_postgres_sql_identifier(reader_name)}; "
        f"GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public "
        f"TO {_postgres_sql_identifier(reader_name)}; "
        + _postgres_owner_default_privileges_sql(owner_name, reader_name)
    )


def _postgres_revoke_public_connect_sql(database_name):
    """Build the statement that cuts PUBLIC off a managed database (#82).

    PostgreSQL grants CONNECT and TEMPORARY to PUBLIC by default, which lets
    any project's role reach any other project's database. Managed databases
    revoke it at creation and grant explicitly to the roles that need it.
    """
    return (
        f"REVOKE CONNECT, TEMP ON DATABASE {_postgres_sql_identifier(database_name)} FROM PUBLIC;"
    )


def _postgres_implicit_connect_roles_sql(database_name):
    """Build the query listing roles that connect without an explicit grant.

    These are the login roles that reach the database through PUBLIC's
    default CONNECT right: revoking it cuts them off, so the normalization
    dry-run report names them before anything changes (#82). Superusers and
    NOLOGIN roles can never lose access this way and are excluded.
    """
    return (
        "SELECT r.rolname "
        "FROM pg_roles r "
        f"JOIN pg_database d ON d.datname = {_postgres_sql_literal(database_name)} "
        "WHERE r.rolcanlogin "
        "AND NOT r.rolsuper "
        "AND has_database_privilege(r.rolname, d.oid, 'CONNECT') "
        "AND NOT EXISTS ("
        "SELECT 1 FROM aclexplode(d.datacl) AS acl "
        "WHERE acl.grantee = r.oid AND acl.privilege_type = 'CONNECT'"
        ") "
        "ORDER BY r.rolname;"
    )


def _postgres_owner_default_privileges_sql(owner_name, username_name):
    """Build the default privileges a read-only user gets on future objects.

    Scoped FOR ROLE to the database owner, which is the role that actually
    creates objects once read-write sessions pin it. A bare ALTER DEFAULT
    PRIVILEGES would only cover objects the superuser creates (#81).
    """
    return (
        f"ALTER DEFAULT PRIVILEGES FOR ROLE {_postgres_sql_identifier(owner_name)} "
        f"IN SCHEMA public GRANT SELECT ON TABLES TO {_postgres_sql_identifier(username_name)}; "
        f"ALTER DEFAULT PRIVILEGES FOR ROLE {_postgres_sql_identifier(owner_name)} "
        "IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES "
        f"TO {_postgres_sql_identifier(username_name)};"
    )


__all__ = tuple(name for name in globals() if not name.startswith("__"))
