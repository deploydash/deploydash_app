import contextlib
import hashlib
import secrets
from datetime import UTC, datetime, timedelta

import paramiko

from ..engine_runtime_common import _build_connector_data

# ruff: noqa: F403, F405
from .service_configuration import *

_THROWAWAY_CLIENT_SUFFIX = (
    '< "${IMPORT_FILE}" && ' + "printf '%s\\n' " + shlex.quote(_LOCAL_SQL_IMPORT_SUCCESS_MARKER)
)
_STAGED_FILE_CHECK = (
    '[ -f "${IMPORT_FILE}" ] || '
    + "(echo 'Uploaded import file is missing on the server.' >&2; exit 1); "
)
_CUSTOM_DUMP_MAGIC = b"PGDMP"


def _run_postgres_host_command(ctx, session, command, *, emit=None, timeout=120):
    status, output = session.host.run_shell_command(
        command,
        _timeout=timeout,
        _sudo=True,
    )
    ctx.emit_shell_output_lines(emit, output)
    return status, output


def _normalize_local_import_file_path(raw_value, field_name):
    if not isinstance(raw_value, str) or not raw_value.strip():
        raise PostgresConfigValidationError(
            f"{field_name} must be a non-empty string.",
        )
    return os.path.abspath(raw_value.strip())


def _resolve_local_sql_import_payload(
    config,
    project_prefix,
    *,
    validate_local_file,
):
    if config.database_name is None:
        raise PostgresConfigValidationError("settings.database_name is required.")
    database_name = _postgres_prefixed_name(
        project_prefix,
        config.database_name,
        "settings.database_name",
    )
    local_file_path = _normalize_local_import_file_path(
        config.import_local_file_path,
        "settings.import_local_file_path",
    )
    lowered_path = local_file_path.lower()
    # coverage-gate: upload_dump_format
    size_bytes = None
    if validate_local_file:
        if not os.path.isfile(local_file_path):
            raise PostgresConfigValidationError(
                "settings.import_local_file_path does not exist on this workstation.",
            )
        size_bytes = os.path.getsize(local_file_path)
        if _dump_file_is_custom_format(local_file_path):
            dump_format = "custom"
        elif lowered_path.endswith(".sql"):
            dump_format = "plain"
        else:
            raise PostgresConfigValidationError(
                "settings.import_local_file_path must point to a .sql file "
                "or a custom-format PostgreSQL dump.",
            )
    elif lowered_path.endswith(".sql"):
        dump_format = "plain"
    else:
        dump_format = "custom"
    # end coverage-gate

    basename = os.path.basename(local_file_path)
    # Custom dumps keep any workstation filename, so unlike the old
    # .sql-only path the sanitized stem can come out empty ("...").
    sanitized_basename = re.sub(r"[^a-zA-Z0-9._-]+", "-", basename).strip("-.") or "import"
    # coverage-gate: upload_staging_paths
    remote_dir = f"/tmp/deploydash-postgres-import-{secrets.token_hex(8)}.d"
    remote_path = f"{remote_dir}/{sanitized_basename}"

    return {
        "database_name": database_name,
        "local_file_path": local_file_path,
        "remote_dir": remote_dir,
        "remote_path": remote_path,
        "size_bytes": size_bytes,
        "dump_format": dump_format,
    }
    # end coverage-gate


def _dump_file_is_custom_format(path):
    """Detect a pg_dump custom-format archive by its magic bytes.

    Magic wins over the suffix: a misnamed dump still restores through
    pg_restore, while a text file renamed to .dump fails closed with a
    suffix error instead of feeding binary to the SQL scanner (#84).
    """
    with open(path, "rb") as handle:
        return handle.read(5) == _CUSTOM_DUMP_MAGIC


def _postgres_throwaway_client_prefix(
    config,
    *,
    import_role,
    import_password,
    owner_role,
    mount_import_list=False,
):
    """Build the shell prelude that launches a disposable import client.

    One concept, one prelude: psql and pg_restore both run in a removed
    afterwards same-image container over TCP, as the temporary import
    role with the owner session pinned, so client-side commands in the
    dump can never reach the database container or the superuser (#84).
    """
    quoted_user = shlex.quote(import_role)
    quoted_password = shlex.quote(import_password)
    quoted_pgoptions = shlex.quote(f"-c role={owner_role}")
    quoted_image = shlex.quote(_postgres_runtime_image_name(config))
    quoted_port = shlex.quote(str(config.host_port))
    list_mount = (
        '--mount "type=bind,src=${IMPORT_LIST},dst=/tmp/deploydash-import.list,readonly" '
        if mount_import_list
        else ""
    )
    return (
        f"IMPORT_USER={quoted_user}; "
        + f"IMPORT_PASSWORD={quoted_password}; "
        + f"IMPORT_PGOPTIONS={quoted_pgoptions}; "
        + f"IMPORT_IMAGE={quoted_image}; "
        + f"IMPORT_PORT={quoted_port}; "
        + "docker run --rm -i --read-only --cap-drop ALL "
        + "--security-opt no-new-privileges "
        + "--add-host host.docker.internal:host-gateway "
        + list_mount
        + '-e PGPASSWORD="${IMPORT_PASSWORD}" '
        + '-e PGOPTIONS="${IMPORT_PGOPTIONS}" '
        + '"${IMPORT_IMAGE}" '
    )


def _postgres_local_sql_import_command(
    config,
    *,
    database_name,
    remote_path,
    import_role,
    import_password,
    owner_role,
):
    quoted_database_name = shlex.quote(database_name)
    quoted_remote_path = shlex.quote(remote_path)
    return (
        _postgres_base_env_prefix(config)
        + f"TARGET_DB={quoted_database_name}; "
        + f"IMPORT_FILE={quoted_remote_path}; "
        + _STAGED_FILE_CHECK
        + _postgres_throwaway_client_prefix(
            config,
            import_role=import_role,
            import_password=import_password,
            owner_role=owner_role,
        )
        + "psql -v ON_ERROR_STOP=1 --single-transaction "
        + '-h host.docker.internal -p "${IMPORT_PORT}" '
        + '-U "${IMPORT_USER}" -d "${TARGET_DB}" '
        + _THROWAWAY_CLIENT_SUFFIX
    )


def _postgres_local_pg_restore_command(
    config,
    *,
    database_name,
    remote_path,
    import_role,
    import_password,
    owner_role,
):
    quoted_database_name = shlex.quote(database_name)
    quoted_remote_path = shlex.quote(remote_path)
    quoted_restore_role = shlex.quote(owner_role)
    extension_metadata_filter = (
        r"/^[0-9]+; [0-9]+ [0-9]+ "
        r"(COMMENT - EXTENSION|SECURITY LABEL - EXTENSION|ACL - EXTENSION) /s/^/;/"
    )
    return (
        _postgres_base_env_prefix(config)
        + f"TARGET_DB={quoted_database_name}; "
        + f"IMPORT_FILE={quoted_remote_path}; "
        + 'IMPORT_LIST="${IMPORT_FILE}.list"; '
        + 'IMPORT_LIST_FILTERED="${IMPORT_LIST}.filtered"; '
        + 'trap \'rm -f -- "${IMPORT_LIST}" "${IMPORT_LIST_FILTERED}"\' EXIT; '
        + _STAGED_FILE_CHECK
        + _postgres_throwaway_client_prefix(
            config,
            import_role=import_role,
            import_password=import_password,
            owner_role=owner_role,
        )
        + 'pg_restore --list < "${IMPORT_FILE}" > "${IMPORT_LIST}"; '
        + f"sed -E {shlex.quote(extension_metadata_filter)} "
        + '"${IMPORT_LIST}" > "${IMPORT_LIST_FILTERED}"; '
        + 'mv -f -- "${IMPORT_LIST_FILTERED}" "${IMPORT_LIST}"; '
        + _postgres_throwaway_client_prefix(
            config,
            import_role=import_role,
            import_password=import_password,
            owner_role=owner_role,
            mount_import_list=True,
        )
        + "pg_restore --no-owner --no-privileges --single-transaction --exit-on-error "
        + "--use-list=/tmp/deploydash-import.list "
        + f"--role={quoted_restore_role} "
        + '-h host.docker.internal -p "${IMPORT_PORT}" '
        + '-U "${IMPORT_USER}" -d "${TARGET_DB}" '
        + _THROWAWAY_CLIENT_SUFFIX
    )


def _postgres_temp_import_role_expiry():
    """Stamp the temporary login's expiry as a UTC timestamp literal.

    VALID UNTIL takes a timestamp string, never an expression, so the
    orchestrator computes now-plus-three-hours itself. The explicit +00
    keeps the bound identical whatever the server TimeZone is (#84).
    """
    return (datetime.now(UTC) + timedelta(hours=3)).strftime("%Y-%m-%d %H:%M:%S+00")


def _postgres_temp_import_role_sql(temp_role_name, password, database_name, owner_name):
    """Build the statements that provision the temporary import login.

    The throwaway client connects over TCP as this role, so unlike the
    socket-only agent reader it carries a password. Membership plus the
    pinned session role makes it act as the database owner, and VALID
    UNTIL bounds the role if its drop is ever skipped (#84).
    """
    return (
        f"CREATE ROLE {_postgres_sql_identifier(temp_role_name)} "
        f"LOGIN PASSWORD {_postgres_sql_literal(password)} "
        f"VALID UNTIL {_postgres_sql_literal(_postgres_temp_import_role_expiry())} "
        "CONNECTION LIMIT 1; "
        f"GRANT CONNECT ON DATABASE {_postgres_sql_identifier(database_name)} "
        f"TO {_postgres_sql_identifier(temp_role_name)}; "
        f"GRANT {_postgres_sql_identifier(owner_name)} "
        f"TO {_postgres_sql_identifier(temp_role_name)};"
    )


def _postgres_drop_temp_import_role_sql(temp_role_name, owner_name):
    """Build the idempotent statements that remove the temporary login.

    A dump that resets the pinned session role could leave objects
    behind under the temp login, so the drop reassigns to the owner
    first. Existence-guarded like the #81 cleanup: the create may have
    failed halfway, yet the drop still runs on every path (#84).
    """
    return (
        "DO $$ "
        "BEGIN "
        "IF EXISTS ("
        f"SELECT 1 FROM pg_roles WHERE rolname = {_postgres_sql_literal(temp_role_name)}"
        ") THEN "
        f"REASSIGN OWNED BY {_postgres_sql_identifier(temp_role_name)} "
        f"TO {_postgres_sql_identifier(owner_name)}; "
        f"DROP OWNED BY {_postgres_sql_identifier(temp_role_name)}; "
        "END IF; "
        "END "
        "$$; "
        f"DROP ROLE IF EXISTS {_postgres_sql_identifier(temp_role_name)};"
    )


def _postgres_local_sql_cleanup_command(remote_dir):
    return "set -eu; rm -rf " + shlex.quote(remote_dir)


def _verify_uploaded_file_sha256(client, remote_path, expected_hex):
    """Compare the staged file's server-side SHA-256 against the upload.

    Runs sha256sum over the upload connection after the bytes land, so a
    truncated or corrupted transfer fails here instead of importing a
    mangled dump. Raises on mismatch or on unreadable checksum output (#84).
    """
    stdout = client.exec_command("sha256sum " + shlex.quote(remote_path))[1]
    tokens = stdout.read().decode("ascii", errors="replace").split()
    actual = tokens[0] if tokens else ""
    if actual != expected_hex:
        raise _PostgresLocalImportUploadError(
            "Uploaded file failed SHA-256 verification: "
            f"expected {expected_hex}, server has {actual or 'no checksum'}.",
        )


def _upload_local_sql_import_file(
    ctx,
    *,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    local_path,
    remote_path,
    remote_dir,
    emit=None,
    is_cancelled=None,
):
    connector_data = _build_connector_data(
        username,
        password=password,
        key_filename=key_filename,
        port=port,
        needs_sudo=False,
    )
    known_hosts_file = connector_data.get("ssh_known_hosts_file")
    strict_host_key = str(connector_data.get("ssh_strict_host_key_checking") or "").strip().lower()
    connect_timeout = int(os.getenv("DEPLOYDASH_SSH_CONNECT_TIMEOUT", "4") or "4")
    connect_kwargs = {
        "hostname": ip,
        "port": int(connector_data.get("ssh_port") or port or 22),
        "username": connector_data["ssh_user"],
        "timeout": connect_timeout,
        "allow_agent": bool(connector_data.get("ssh_allow_agent", False)),
        "look_for_keys": bool(connector_data.get("ssh_look_for_keys", False)),
    }
    ssh_password = connector_data.get("ssh_password")
    if ssh_password:
        connect_kwargs["password"] = ssh_password
    ssh_key = connector_data.get("ssh_key")
    if ssh_key:
        connect_kwargs["key_filename"] = ssh_key
    paramiko_kwargs = connector_data.get("ssh_paramiko_connect_kwargs") or {}
    if isinstance(paramiko_kwargs, dict):
        connect_kwargs.update(paramiko_kwargs)

    client = paramiko.SSHClient()
    with contextlib.suppress(Exception):
        client.load_system_host_keys()
    if isinstance(known_hosts_file, str) and known_hosts_file:
        with contextlib.suppress(Exception):
            client.load_host_keys(known_hosts_file)
    if strict_host_key in {"yes", "true", "on"}:
        client.set_missing_host_key_policy(paramiko.RejectPolicy())
    else:
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    size_bytes = os.path.getsize(local_path)
    bytes_uploaded = 0
    last_progress_mark = 0
    ctx.emit_event(
        emit,
        "postgres_local_sql_upload_started",
        "Uploading local SQL file to the server.",
        data={
            "local_file_path": local_path,
            "remote_path": remote_path,
            "size_bytes": size_bytes,
        },
    )

    try:
        client.connect(**connect_kwargs)
        if (
            strict_host_key == "accept-new"
            and isinstance(known_hosts_file, str)
            and known_hosts_file
        ):
            with contextlib.suppress(Exception):
                client.save_host_keys(known_hosts_file)

        sftp = client.open_sftp()
        try:
            # coverage-gate: upload_staging_mkdir
            sftp.mkdir(remote_dir, 0o700)
            # end coverage-gate
            # coverage-gate: upload_stream_digest_init
            digest = hashlib.sha256()
            # end coverage-gate
            with open(local_path, "rb") as local_handle:
                remote_handle = sftp.file(remote_path, "wb")
                with contextlib.suppress(Exception):
                    sftp.chmod(remote_path, 0o600)
                try:
                    if hasattr(remote_handle, "set_pipelined"):
                        remote_handle.set_pipelined(True)
                    while True:
                        if callable(is_cancelled) and is_cancelled():
                            raise _PostgresLocalImportCancelled(
                                "Task cancelled during local SQL upload",
                            )
                        chunk = local_handle.read(_LOCAL_SQL_UPLOAD_CHUNK_SIZE)
                        if not chunk:
                            break
                        # coverage-gate: upload_stream_digest_update
                        digest.update(chunk)
                        # end coverage-gate
                        remote_handle.write(chunk)
                        bytes_uploaded += len(chunk)
                        if (
                            bytes_uploaded == size_bytes
                            or bytes_uploaded - last_progress_mark
                            >= _LOCAL_SQL_UPLOAD_PROGRESS_STEP
                        ):
                            last_progress_mark = bytes_uploaded
                            percent = (
                                int((bytes_uploaded * 100) / size_bytes) if size_bytes > 0 else 100
                            )
                            ctx.emit_event(
                                emit,
                                "postgres_local_sql_upload_progress",
                                f"Uploaded {bytes_uploaded} of {size_bytes} bytes.",
                                data={
                                    "local_file_path": local_path,
                                    "remote_path": remote_path,
                                    "bytes_uploaded": bytes_uploaded,
                                    "size_bytes": size_bytes,
                                    "progress_percent": percent,
                                },
                            )
                finally:
                    remote_handle.close()
            # coverage-gate: upload_sha256_verify
            _verify_uploaded_file_sha256(
                client,
                remote_path,
                digest.hexdigest(),
            )
            # end coverage-gate
        finally:
            sftp.close()
    finally:
        client.close()

    ctx.emit_event(
        emit,
        "postgres_local_sql_upload_completed",
        "Local SQL file upload completed.",
        data={
            "local_file_path": local_path,
            "remote_path": remote_path,
            "size_bytes": size_bytes,
        },
    )
    return {
        "local_file_path": local_path,
        "remote_path": remote_path,
        "size_bytes": size_bytes,
    }


__all__ = tuple(name for name in globals() if not name.startswith("__"))
