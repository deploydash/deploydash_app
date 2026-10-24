"""Ownership registry for managed PostgreSQL databases and roles (#80).

Project scoping must come from these tables -- never from ``LIKE`` name
matching, which crosses project boundaries two ways (``_`` wildcards and
nesting prefixes). The registry lives in the ``postgres`` database under a
superuser-owned schema with ``REVOKE ALL ... FROM PUBLIC``, so a read-write
user that owns its database still cannot rewrite ownership. ``pg_dumpall``
carries the schema along with everything else it already dumps.
"""

from ..postgres_parts import PostgresConfigValidationError
from .agent_access import (
    _parse_postgres_role_comment,
    _postgres_output_has_one,
    _run_postgres_psql_query_impl,
)
from .service_configuration import (
    _normalize_postgres_identifier,
    _postgres_project_prefix,
    _postgres_sql_identifier,
    _postgres_sql_literal,
)

_REGISTRY_SCHEMA = "deploydash"
_REGISTRY_DATABASES_TABLE = f"{_REGISTRY_SCHEMA}.managed_databases"
_REGISTRY_ROLES_TABLE = f"{_REGISTRY_SCHEMA}.managed_roles"

# Role kinds the registry accepts. #80 writes ``app``; the S2/S4/S5 flows
# register ``owner``, ``agent_reader``, and ``import`` when they land.
_PROJECT_ROLE_KINDS = frozenset({"app", "readonly", "owner", "agent_reader", "import"})
# Ordinary user surfaces omit product-owned and transient infrastructure roles.
_PROJECT_USER_ROLE_KINDS = ("app", "readonly")


def _postgres_registry_bootstrap_sql(superuser_name):
    """Build the idempotent DDL that creates the ownership registry.

    Rerunnable by construction (``IF NOT EXISTS`` plus unconditional
    ``REVOKE``), so every project flow can ensure it without coordinating.
    """
    owner = _postgres_sql_identifier(
        _normalize_postgres_identifier(superuser_name, "settings.superuser_name"),
    )
    return (
        f"CREATE SCHEMA IF NOT EXISTS {_REGISTRY_SCHEMA} AUTHORIZATION {owner}; "
        f"REVOKE ALL ON SCHEMA {_REGISTRY_SCHEMA} FROM PUBLIC; "
        f"CREATE TABLE IF NOT EXISTS {_REGISTRY_DATABASES_TABLE} ("
        "datname text PRIMARY KEY, "
        "project_slug text NOT NULL, "
        "created_at timestamptz NOT NULL DEFAULT now()"
        "); "
        f"REVOKE ALL ON TABLE {_REGISTRY_DATABASES_TABLE} FROM PUBLIC; "
        f"CREATE TABLE IF NOT EXISTS {_REGISTRY_ROLES_TABLE} ("
        "rolname text PRIMARY KEY, "
        "project_slug text NOT NULL, "
        "datname text, "
        "access_mode text, "
        "role_kind text"
        "); "
        f"REVOKE ALL ON TABLE {_REGISTRY_ROLES_TABLE} FROM PUBLIC;"
    )


def _postgres_registry_register_database_sql(datname, project_slug):
    """Build the upsert that records a database's owning project."""
    return (
        f"INSERT INTO {_REGISTRY_DATABASES_TABLE} (datname, project_slug) "
        f"VALUES ({_postgres_sql_literal(datname)}, "
        f"{_postgres_sql_literal(project_slug)}) "
        "ON CONFLICT (datname) DO UPDATE "
        "SET project_slug = EXCLUDED.project_slug;"
    )


def _postgres_registry_unregister_database_sql(datname):
    """Build the delete that forgets a dropped database."""
    return (
        f"DELETE FROM {_REGISTRY_DATABASES_TABLE} WHERE datname = {_postgres_sql_literal(datname)};"
    )


def _postgres_registry_register_role_sql(
    rolname,
    project_slug,
    datname,
    access_mode,
    role_kind,
):
    """Build the upsert that records a role's owning project and purpose."""
    if role_kind not in _PROJECT_ROLE_KINDS:
        raise ValueError(f"Unknown postgres role kind: {role_kind!r}.")
    return (
        f"INSERT INTO {_REGISTRY_ROLES_TABLE} "
        "(rolname, project_slug, datname, access_mode, role_kind) "
        f"VALUES ({_postgres_sql_literal(rolname)}, "
        f"{_postgres_sql_literal(project_slug)}, "
        f"{_postgres_sql_literal(datname)}, "
        f"{_postgres_sql_literal(access_mode)}, "
        f"{_postgres_sql_literal(role_kind)}) "
        "ON CONFLICT (rolname) DO UPDATE SET "
        "project_slug = EXCLUDED.project_slug, "
        "datname = EXCLUDED.datname, "
        "access_mode = EXCLUDED.access_mode, "
        "role_kind = EXCLUDED.role_kind;"
    )


def _postgres_registry_unregister_role_sql(rolname):
    """Build the delete that forgets a dropped role."""
    return f"DELETE FROM {_REGISTRY_ROLES_TABLE} WHERE rolname = {_postgres_sql_literal(rolname)};"


def _postgres_registry_lookup_sql(table, select_column, where_column, where_value):
    """Build an exact single-column registry lookup ordered by that column.

    The one owner for every ``SELECT <column> ... WHERE <column> = ...``
    registry read. ``table`` and the column names must be module constants
    or fixed literals at the call site -- only ``where_value`` is a quoted
    runtime value.
    """
    return (
        f"SELECT {select_column} FROM "
        f"{table} "
        f"WHERE {where_column} = {_postgres_sql_literal(where_value)} "
        f"ORDER BY {select_column};"
    )


def _postgres_registry_owner_slug(query_output):
    """Return the owning project slug from an ownership lookup, or None.

    Ownership lookups select a single ``project_slug`` value; an empty
    result means the name is unregistered and free for this project.
    """
    for raw_line in getattr(query_output, "stdout_lines", None) or []:
        line = str(raw_line).strip()
        if line:
            return line
    return None


def _postgres_registry_list_databases_sql():
    """Build the lookup of every registered database name in order.

    The storage migration guard and the detached-volume detector compare
    this expectation against live pg_database: names Deploy Dash manages
    that the cluster lacks mean the data volume is detached (#85).
    """
    return f"SELECT datname FROM {_REGISTRY_DATABASES_TABLE} ORDER BY datname;"


def _postgres_registry_list_roles_sql(project_slug):
    """Build the exact lookup of a project's registered roles and users."""
    user_role_kinds = ", ".join(
        _postgres_sql_literal(role_kind) for role_kind in _PROJECT_USER_ROLE_KINDS
    )
    return (
        "SELECT COALESCE(json_agg("
        "json_build_object("
        "'username', rolname, "
        "'database', datname, "
        "'access_mode', access_mode, "
        "'role_kind', role_kind"
        ") ORDER BY rolname"
        "), '[]'::json)::text "
        f"FROM {_REGISTRY_ROLES_TABLE} "
        f"WHERE project_slug = {_postgres_sql_literal(project_slug)} "
        f"AND role_kind IN ({user_role_kinds});"
    )


def _postgres_registry_database_roles_sql(datname):
    """Build the lookup of one database's registered roles with their kinds.

    Normalization reads who belongs to a database through this: login users
    by access mode, and the owner row so it is never reassigned to itself.
    """
    return (
        "SELECT COALESCE(json_agg("
        "json_build_object("
        "'username', rolname, "
        "'access_mode', access_mode, "
        "'role_kind', role_kind"
        ") ORDER BY rolname"
        "), '[]'::json)::text "
        f"FROM {_REGISTRY_ROLES_TABLE} "
        f"WHERE datname = {_postgres_sql_literal(datname)};"
    )


def _ensure_postgres_project_registry(ctx, session, postgres_config, emit):
    """Create the ownership registry if missing; return an error or None.

    Runs inside project flows, after readiness is confirmed, so a missing
    registry can never silently scope an operation by name matching.
    """
    bootstrap_sql = _postgres_registry_bootstrap_sql(postgres_config.superuser_name)
    status, output = _run_postgres_psql_query_impl(
        ctx,
        session,
        postgres_config,
        bootstrap_sql,
        emit=emit,
    )
    if not status:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not ensure the PostgreSQL ownership registry.",
            stage="execute_runtime_operation",
            details=ctx.command_error_details(output) or "remote command failed",
        )
    return _backfill_postgres_project_registry(ctx, session, postgres_config, emit)


def _postgres_registry_unregistered_databases_sql():
    """List managed-looking databases that the registry does not know yet.

    ``left()`` plus an anti-join: exact matching throughout, so legacy names
    with ``_`` wildcards or nesting prefixes cannot misroute.
    """
    return (
        "SELECT datname FROM pg_database "
        "WHERE left(datname, 3) = 'dd_' "
        "AND datistemplate = false "
        f"AND NOT EXISTS (SELECT 1 FROM {_REGISTRY_DATABASES_TABLE} "
        "WHERE datname = pg_database.datname) "
        "ORDER BY datname;"
    )


def _postgres_registry_role_comment_rows_sql():
    """List every role with its comment and registry membership.

    One row per role as ``rolname|registered-or-empty|comment``. The comment
    rides last because only it may contain the separator.
    """
    return (
        "SELECT r.rolname, "
        "CASE WHEN m.rolname IS NULL THEN '' ELSE 'registered' END, "
        "COALESCE(shobj_description(r.oid, 'pg_authid'), '') "
        "FROM pg_roles r "
        f"LEFT JOIN {_REGISTRY_ROLES_TABLE} m ON m.rolname = r.rolname "
        "ORDER BY r.rolname;"
    )


def _postgres_backfill_parse_role_row(line):
    """Split one role-comment row; return None when the row is unusable.

    A rolname that fails identifier validation is skipped rather than
    trusted: a mangled name must never steer an ownership decision.
    """
    text = str(line).strip()
    if not text:
        return None
    rolname, first_separator, rest = text.partition("|")
    if not first_separator:
        return None
    flag, second_separator, comment = rest.partition("|")
    if not second_separator:
        return None
    try:
        _normalize_postgres_identifier(rolname, "role row")
    except PostgresConfigValidationError:
        return None
    return {
        "rolname": rolname,
        "registered": flag == "registered",
        "comment": comment,
    }


def _postgres_backfill_classify(datnames, role_rows, known_project_slugs):
    """Assign unregistered databases to projects without guessing.

    Each name resolves by role comment first, then by the longest matching
    project prefix among the desktop's slugs, and stays unassigned when
    neither fires. Conflicting evidence is reported, never resolved by fiat.
    Returns assigned and role registrations plus the unassigned leftovers
    and ownership conflicts.
    """
    comments_by_database = {}
    for row in role_rows:
        parsed = _parse_postgres_role_comment(row["comment"])
        if parsed["database"] and parsed["project"]:
            comments_by_database.setdefault(parsed["database"], []).append(
                (parsed, row),
            )
    prefixes = []
    for slug in known_project_slugs or ():
        try:
            prefixes.append((slug, _postgres_project_prefix(slug)))
        except PostgresConfigValidationError:
            continue
    assigned = {}
    role_registrations = []
    unassigned = []
    conflicts = []
    for datname in datnames:
        claims = comments_by_database.get(datname, [])
        projects = sorted({parsed["project"] for parsed, _ in claims})
        if len(projects) > 1:
            conflicts.append({"datname": datname, "projects": projects})
            continue
        if projects:
            owner = projects[0]
        else:
            matches = [(slug, prefix) for slug, prefix in prefixes if datname.startswith(prefix)]
            if not matches:
                unassigned.append(datname)
                continue
            longest = max(len(prefix) for _, prefix in matches)
            winners = sorted(slug for slug, prefix in matches if len(prefix) == longest)
            if len(winners) > 1:
                conflicts.append({"datname": datname, "projects": winners})
                continue
            if "_" in datname[longest:]:
                # dd_shop_ + api_main is also dd_shop_api_ + main: a project
                # missing from the slug list may own it, and a registry row is
                # permanent, so report it instead of guessing (#127).
                unassigned.append(datname)
                continue
            owner = winners[0]
        assigned[datname] = owner
        for parsed, row in claims:
            if row["registered"]:
                continue
            role_registrations.append(
                {
                    "rolname": row["rolname"],
                    "project_slug": owner,
                    "datname": datname,
                    "access_mode": parsed["access_mode"],
                    "role_kind": ("readonly" if parsed["access_mode"] == "read_only" else "app"),
                }
            )
    return {
        "assigned": assigned,
        "roles": role_registrations,
        "unassigned": unassigned,
        "conflicts": conflicts,
    }


def _load_postgres_backfill_input(ctx, session, postgres_config, emit):
    """Run the discovery queries; return (error_or_None, datnames, rows)."""
    unregistered_sql = _postgres_registry_unregistered_databases_sql()
    db_status, db_output = _run_postgres_psql_query_impl(
        ctx,
        session,
        postgres_config,
        unregistered_sql,
        emit=emit,
    )
    if not db_status:
        return (
            ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not inspect unregistered databases.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(db_output) or "remote command failed",
            ),
            [],
            [],
        )
    comments_sql = _postgres_registry_role_comment_rows_sql()
    comments_status, comments_output = _run_postgres_psql_query_impl(
        ctx,
        session,
        postgres_config,
        comments_sql,
        emit=emit,
    )
    if not comments_status:
        return (
            ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                "Could not inspect role comments.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(comments_output) or "remote command failed",
            ),
            [],
            [],
        )
    datnames = [
        line.strip() for line in getattr(db_output, "stdout_lines", None) or [] if str(line).strip()
    ]
    role_rows = []
    for line in getattr(comments_output, "stdout_lines", None) or []:
        parsed_row = _postgres_backfill_parse_role_row(line)
        if parsed_row is not None:
            role_rows.append(parsed_row)
    return (None, datnames, role_rows)


def _backfill_postgres_project_registry(ctx, session, postgres_config, emit):
    """Register legacy databases and roles; return an error or None.

    Runs inside every project flow after the bootstrap, so the first
    operation after an upgrade adopts the server's existing databases.
    Unassigned names and conflicts are left unregistered -- and therefore
    out of every delete -- for the project list to surface.
    """
    error, datnames, role_rows = _load_postgres_backfill_input(
        ctx,
        session,
        postgres_config,
        emit,
    )
    if error is not None:
        return error
    report = _postgres_backfill_classify(
        datnames,
        role_rows,
        postgres_config.known_project_slugs,
    )
    statements = []
    for datname, owner in report["assigned"].items():
        statements.append(
            _postgres_registry_register_database_sql(datname, owner),
        )
    for role in report["roles"]:
        statements.append(
            _postgres_registry_register_role_sql(
                role["rolname"],
                role["project_slug"],
                role["datname"],
                role["access_mode"],
                role["role_kind"],
            ),
        )
    if not statements:
        return None
    register_status, register_output = _run_postgres_psql_query_impl(
        ctx,
        session,
        postgres_config,
        " ".join(statements),
        emit=emit,
    )
    if not register_status:
        return ctx.error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not backfill database ownership.",
            stage="execute_runtime_operation",
            details=ctx.command_error_details(register_output) or "remote command failed",
        )
    return None


def _describe_postgres_registry_leftovers(ctx, session, postgres_config, emit):
    """Report unassigned databases and conflicts; (error_or_None, report)."""
    error, datnames, role_rows = _load_postgres_backfill_input(
        ctx,
        session,
        postgres_config,
        emit,
    )
    if error is not None:
        return (error, {})
    report = _postgres_backfill_classify(
        datnames,
        role_rows,
        postgres_config.known_project_slugs,
    )
    return (
        None,
        {
            "unassigned_databases": report["unassigned"],
            "ownership_conflicts": report["conflicts"],
        },
    )


# Registry table and name column for each kind of name a request can carry.
_REGISTRY_TABLE_BY_KIND = {
    "database": (_REGISTRY_DATABASES_TABLE, "datname"),
    "user": (_REGISTRY_ROLES_TABLE, "rolname"),
}

# Catalog query proving a name already exists in the cluster, per kind.
_CLUSTER_NAME_EXISTS_SQL = {
    "database": "SELECT 1 FROM pg_database WHERE datname = {name};",
    "user": "SELECT 1 FROM pg_roles WHERE rolname = {name};",
}


def _require_postgres_resource_owners(
    ctx,
    session,
    postgres_config,
    emit,
    owned=(),
    creating=(),
    ensure_registry=True,
):
    """Refuse a request that names a database or user of another project.

    The one ownership gate for every operation that acts on a named database
    or user (#127). A logical name resolves under the caller's prefix, and
    prefixes nest (``dd_shop_`` + ``api_main`` is shop-api's ``main``), so a
    remote name never proves ownership on its own; the registry does.
    ``owned`` and ``creating`` are sequences of ``(kind, remote_name)`` pairs
    whose ``kind`` is a key of ``_REGISTRY_TABLE_BY_KIND``. An ``owned`` name
    must be registered to the calling project. A ``creating`` name may also
    be unregistered, because the operation is about to create it, but only
    while nothing by that name exists in the cluster: an existing name with
    no registry row may belong to a project this desktop does not know, so
    it is refused rather than adopted. Ensures the
    registry first unless ``ensure_registry`` is False, which a caller passes
    only when it has just ensured the registry itself. Returns an error
    result, or None when every name passes.
    """
    if ensure_registry:
        registry_error = _ensure_postgres_project_registry(
            ctx,
            session,
            postgres_config,
            emit,
        )
        if registry_error is not None:
            return registry_error
    checks = [(kind, remote_name, False) for kind, remote_name in owned]
    checks.extend((kind, remote_name, True) for kind, remote_name in creating)
    for kind, remote_name, is_creating in checks:
        table, name_column = _REGISTRY_TABLE_BY_KIND[kind]
        owner_sql = _postgres_registry_lookup_sql(
            table,
            "project_slug",
            name_column,
            remote_name,
        )
        owner_status, owner_output = _run_postgres_psql_query_impl(
            ctx,
            session,
            postgres_config,
            owner_sql,
            emit=emit,
        )
        if not owner_status:
            return ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                f"Could not inspect {kind} ownership.",
                stage="execute_runtime_operation",
                details=ctx.command_error_details(owner_output) or "remote command failed",
            )
        owner_slug = _postgres_registry_owner_slug(owner_output)
        if owner_slug == postgres_config.project_slug:
            continue
        if owner_slug is None and is_creating:
            exists_status, exists_output = _run_postgres_psql_query_impl(
                ctx,
                session,
                postgres_config,
                _CLUSTER_NAME_EXISTS_SQL[kind].format(
                    name=_postgres_sql_literal(remote_name),
                ),
                emit=emit,
            )
            if not exists_status:
                return ctx.error_result(
                    "ENGINE_RUNTIME_ERROR",
                    f"Could not inspect {kind} ownership.",
                    stage="execute_runtime_operation",
                    details=ctx.command_error_details(exists_output) or "remote command failed",
                )
            if not _postgres_output_has_one(exists_output):
                continue
            return ctx.error_result(
                "ENGINE_VALIDATION_ERROR",
                f"This {kind} already exists but is not registered to any project.",
                stage="validate_request",
                details=remote_name,
            )
        if owner_slug is None:
            message = f"This {kind} is not registered as a managed {kind}."
        else:
            message = f"This {kind} is registered to project '{owner_slug}'."
        return ctx.error_result(
            "ENGINE_VALIDATION_ERROR",
            message,
            stage="validate_request",
            details=remote_name,
        )
    return None


__all__ = tuple(name for name in globals() if not name.startswith("__"))
