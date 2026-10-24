import re
import shlex
from urllib.parse import urlparse

from . import server_identifiers, server_paths, shell_output
from .postgres_parts import PostgresConfigValidationError
from .postgres_supply_chain import (
    postgres_walg_install_command as postgres_walg_install_command,
)

POSTGRES_BACKUP_MANIFEST_FORMAT_VERSION = 1

_BACKUP_POLICY_TOKEN_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")
_BACKUP_HHMM_PATTERN = re.compile(r"^(?:[01]?\d|2[0-3]):[0-5]\d$")
_S3_BUCKET_PATTERN = re.compile(r"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$")


def normalize_backup_policy_token(raw_value, field_name):
    if not isinstance(raw_value, str) or not raw_value.strip():
        raise PostgresConfigValidationError(
            f"{field_name} must be a non-empty string.",
        )
    token = raw_value.strip().lower()
    token = re.sub(r"[^a-z0-9._-]+", "-", token)
    token = re.sub(r"-+", "-", token).strip("-.")
    if not token:
        raise PostgresConfigValidationError(
            f"{field_name} must include letters or numbers.",
        )
    if token[0] in "._-":
        token = f"p-{token.lstrip('._-')}"
    if len(token) > 80:
        token = token[:80].rstrip("._-")
    if not _BACKUP_POLICY_TOKEN_PATTERN.match(token) or token == "p-":
        raise PostgresConfigValidationError(f"{field_name} is invalid.")
    return token


def normalize_backup_hhmm(raw_value, field_name, default):
    candidate = default
    if isinstance(raw_value, str) and raw_value.strip():
        candidate = raw_value.strip()
    if not _BACKUP_HHMM_PATTERN.match(candidate):
        raise PostgresConfigValidationError(
            f"{field_name} must match HH:MM in 24-hour time.",
        )
    hour = int(candidate.split(":", 1)[0])
    minute = int(candidate.split(":", 1)[1])
    return f"{hour:02d}:{minute:02d}"


def normalize_backup_artifact_path(raw_value, field_name):
    if not isinstance(raw_value, str) or not raw_value.strip():
        raise PostgresConfigValidationError(
            f"{field_name} must be a non-empty string.",
        )
    path = raw_value.strip().replace("\\", "/")
    if path.startswith("/"):
        path = path[1:]
    if not path or ".." in path.split("/"):
        raise PostgresConfigValidationError(
            f"{field_name} contains an invalid path.",
        )
    if not re.match(r"^[A-Za-z0-9._/@:+-]+$", path):
        raise PostgresConfigValidationError(
            f"{field_name} contains unsupported characters.",
        )
    return path


def backup_remote_base_path(project_slug, policy_token):
    return server_identifiers.postgres_backup_object_prefix(project_slug, policy_token)


def backup_artifact_key(remote_base_path, name):
    """Build the full storage key for one artifact listing entry.

    `wal-g st ls` prints names relative to the listed folder on both S3 and
    filesystem destinations, while `wal-g st rm` (and `st get`) resolve
    their argument from the storage root. Listing and pruning must therefore
    agree on one key shape: this helper is that single owner. The prune
    phase of the generated backup script cannot import Python, so it
    expands the same rule in shell; an end-to-end test pins that expansion
    to this shape so the two cannot drift apart again (#95).
    """
    candidate = str(name).strip().lstrip("/")
    normalized_base_path = (
        str(remote_base_path).strip().strip("/")
        if isinstance(remote_base_path, str) and remote_base_path.strip()
        else None
    )
    if normalized_base_path and not candidate.startswith(f"{normalized_base_path}/"):
        return f"{normalized_base_path}/{candidate}"
    return candidate


def normalize_backup_s3_prefix(raw_value, field_name):
    if not isinstance(raw_value, str) or not raw_value.strip():
        raise PostgresConfigValidationError(
            f"{field_name} must be a non-empty string.",
        )
    candidate = raw_value.strip()
    if candidate.startswith("s3://"):
        candidate = candidate[5:]
    candidate = candidate.strip("/")
    if not candidate:
        raise PostgresConfigValidationError(f"{field_name} is invalid.")
    if "/" in candidate:
        bucket_name, path = candidate.split("/", 1)
    else:
        bucket_name, path = candidate, ""
    bucket_name = bucket_name.strip().lower()
    if not _S3_BUCKET_PATTERN.match(bucket_name):
        raise PostgresConfigValidationError(
            f"{field_name} must include a valid bucket name.",
        )
    normalized = f"s3://{bucket_name}"
    path = re.sub(r"/+", "/", path.replace("\\", "/")).strip("/")
    if path:
        if ".." in path.split("/"):
            raise PostgresConfigValidationError(
                f"{field_name} contains an invalid path.",
            )
        normalized = f"{normalized}/{path}"
    return normalized


def normalize_backup_s3_endpoint(raw_value, field_name):
    if raw_value is None:
        return ""
    if not isinstance(raw_value, str):
        raise PostgresConfigValidationError(f"{field_name} must be a string.")
    endpoint = raw_value.strip()
    if not endpoint:
        return ""
    if "://" not in endpoint:
        endpoint = f"https://{endpoint}"
    parsed = urlparse(endpoint)
    if not parsed.hostname:
        raise PostgresConfigValidationError(f"{field_name} is invalid.")
    scheme = (parsed.scheme or "https").lower()
    port = f":{parsed.port}" if parsed.port is not None else ""
    return f"{scheme}://{parsed.hostname}{port}"


def resolve_backup_destination(config):
    destination_type = (config.backup_destination_type or "").strip().lower()
    if destination_type not in ("s3", "filesystem"):
        raise PostgresConfigValidationError(
            "settings.backup_destination_type must be one of: s3, filesystem.",
        )

    if destination_type == "s3":
        if not isinstance(config.backup_s3_prefix, str) or not config.backup_s3_prefix.strip():
            raise PostgresConfigValidationError(
                "settings.backup_s3_prefix must be set for S3 backups.",
            )
        if (
            not isinstance(config.backup_aws_access_key_id, str)
            or not config.backup_aws_access_key_id.strip()
        ):
            raise PostgresConfigValidationError(
                "settings.backup_aws_access_key_id must be set for S3 backups.",
            )
        if (
            not isinstance(config.backup_aws_secret_access_key, str)
            or not config.backup_aws_secret_access_key.strip()
        ):
            raise PostgresConfigValidationError(
                "settings.backup_aws_secret_access_key must be set for S3 backups.",
            )
        if not isinstance(config.backup_aws_region, str) or not config.backup_aws_region.strip():
            raise PostgresConfigValidationError(
                "settings.backup_aws_region must be set for S3 backups.",
            )
        return {
            "type": "s3",
            "prefix": normalize_backup_s3_prefix(
                config.backup_s3_prefix,
                "settings.backup_s3_prefix",
            ),
            "aws_access_key_id": config.backup_aws_access_key_id.strip(),
            "aws_secret_access_key": config.backup_aws_secret_access_key.strip(),
            "aws_region": config.backup_aws_region.strip(),
            "aws_endpoint": normalize_backup_s3_endpoint(
                config.backup_aws_endpoint,
                "settings.backup_aws_endpoint",
            ),
            "aws_force_path_style": bool(config.backup_aws_force_path_style),
        }

    if not isinstance(config.backup_file_prefix, str) or not config.backup_file_prefix.strip():
        raise PostgresConfigValidationError(
            "settings.backup_file_prefix must be set for filesystem backups.",
        )
    return {
        "type": "filesystem",
        "prefix": config.backup_file_prefix.strip(),
    }


def backup_env_assignments(destination):
    lines = []
    if destination["type"] == "s3":
        lines.append(f"export WALG_S3_PREFIX={shlex.quote(destination['prefix'])}")
        lines.append(
            "export AWS_ACCESS_KEY_ID=" + shlex.quote(destination["aws_access_key_id"]),
        )
        lines.append(
            "export AWS_SECRET_ACCESS_KEY=" + shlex.quote(destination["aws_secret_access_key"]),
        )
        lines.append(f"export AWS_REGION={shlex.quote(destination['aws_region'])}")
        if destination["aws_endpoint"]:
            lines.append(
                f"export AWS_ENDPOINT={shlex.quote(destination['aws_endpoint'])}",
            )
        lines.append(
            "export AWS_S3_FORCE_PATH_STYLE="
            + ("true" if destination["aws_force_path_style"] else "false"),
        )
    else:
        lines.append(f"export WALG_FILE_PREFIX={shlex.quote(destination['prefix'])}")
    lines.append("export WALG_UPLOAD_CONCURRENCY=4")
    lines.append("export WALG_DOWNLOAD_CONCURRENCY=4")
    return lines


def backup_env_export_block(destination):
    return "; ".join(backup_env_assignments(destination)) + "; "


def postgres_backup_destination_test_command(destination):
    test_remote_path = server_identifiers.BACKUP_CONNECTION_TEST_PREFIX
    if destination["type"] == "s3":
        env_export_block = backup_env_export_block(destination)
        return {
            "command": (
                "set -eu; " + env_export_block + 'TMP_DIR="$(mktemp -d)"; '
                'cleanup(){ rm -rf "${TMP_DIR}" >/dev/null 2>&1 || true; }; '
                "trap cleanup EXIT INT TERM; "
                'TEST_FILE="${TMP_DIR}/backup-destination-test.txt"; '
                'READ_FILE="${TMP_DIR}/backup-destination-read.txt"; '
                "printf 'deploydash backup destination test %s\\n' "
                '"$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${TEST_FILE}"; '
                f"TEST_REMOTE_BASE_PATH={shlex.quote(test_remote_path)}; "
                'TEST_REMOTE_PATH="${TEST_REMOTE_BASE_PATH}/$(date -u +%Y%m%dT%H%M%SZ)-$$-backup-test.txt"; '
                "wal-g st put --no-compress --no-encrypt "
                '"${TEST_FILE}" "${TEST_REMOTE_PATH}"; '
                "ATTEMPT=0; "
                "until wal-g st get --no-decompress --no-decrypt "
                '"${TEST_REMOTE_PATH}" "${READ_FILE}"; do '
                "ATTEMPT=$((ATTEMPT+1)); "
                'if [ "${ATTEMPT}" -ge 5 ]; then '
                "echo 'Timed out waiting for S3 object visibility.' >&2; "
                "exit 1; "
                "fi; "
                "sleep 2; "
                "done; "
                'cmp -s "${TEST_FILE}" "${READ_FILE}"; '
                'wal-g st rm "${TEST_REMOTE_PATH}"; '
                'echo "tested_remote_path=${TEST_REMOTE_PATH}"; '
                "echo 'test_destination_type=s3'; "
                "echo 'test_result=ok'"
            ),
            "tested_remote_path": f"{test_remote_path}/<timestamp>-<pid>-backup-test.txt",
        }

    test_file_path = (
        destination["prefix"].rstrip("/")
        + f"/{server_identifiers.BACKUP_CONNECTION_TEST_PREFIX}/"
        + "$(date -u +%Y%m%dT%H%M%SZ)-$$-backup-test.txt"
    )
    return {
        "command": (
            "set -eu; "
            'TMP_DIR="$(mktemp -d)"; '
            'cleanup(){ rm -rf "${TMP_DIR}" >/dev/null 2>&1 || true; }; '
            "trap cleanup EXIT INT TERM; "
            'TEST_FILE="${TMP_DIR}/backup-destination-test.txt"; '
            'READ_FILE="${TMP_DIR}/backup-destination-read.txt"; '
            "printf 'deploydash backup destination test %s\\n' "
            '"$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${TEST_FILE}"; '
            f"TEST_FILE_PATH={shlex.quote(test_file_path)}; "
            'mkdir -p "$(dirname "${TEST_FILE_PATH}")"; '
            'cp "${TEST_FILE}" "${TEST_FILE_PATH}"; '
            'cat "${TEST_FILE_PATH}" > "${READ_FILE}"; '
            'cmp -s "${TEST_FILE}" "${READ_FILE}"; '
            'rm -f "${TEST_FILE_PATH}"; '
            'echo "tested_remote_path=${TEST_FILE_PATH}"; '
            "echo 'test_destination_type=filesystem'; "
            "echo 'test_result=ok'"
        ),
        "tested_remote_path": test_file_path,
    }


def _backup_policy_environment_body(
    config,
    *,
    database_name,
    policy_name,
    policy_token,
    task_token,
    remote_base_path,
    retention_keep_last,
    destination,
):
    policy_environment = {
        "POSTGRES_USER": config.superuser_name,
        "POSTGRES_PASSWORD": config.superuser_password or "",
        "CONTAINER_NAME": config.container_name,
        "BACKUP_DATABASE_NAME": database_name,
        "BACKUP_POLICY_NAME": policy_name,
        "BACKUP_POLICY_ID": policy_token,
        "BACKUP_TASK_ID": task_token,
        "BACKUP_REMOTE_BASE_PATH": remote_base_path,
        "BACKUP_RETENTION_KEEP_LAST": retention_keep_last,
    }
    return (
        "\n".join(f"{name}={shlex.quote(str(value))}" for name, value in policy_environment.items())
        + "\n"
        + "\n".join(backup_env_assignments(destination))
        + "\n"
    )


def postgres_backup_manifest_write_command():
    """Shell snippet writing and uploading the manifest for the dump just
    uploaded to REMOTE_PATH. Assumes TMP_DIR, BACKUP_DATABASE_NAME,
    TIMESTAMP, SIZE_BYTES, and REMOTE_PATH are already set by the caller
    (all already established variable names at the one call site)."""
    return (
        'LOCAL_MANIFEST="${TMP_DIR}/manifest.json"\n'
        + "python3 -c \"import json, sys; json.dump({'format_version': "
        + f"{POSTGRES_BACKUP_MANIFEST_FORMAT_VERSION}, 'database_name': "
        + "sys.argv[1], 'created_at': sys.argv[2], 'size_bytes': "
        + "int(sys.argv[3])}, open(sys.argv[4], 'w'))\" "
        + '"${BACKUP_DATABASE_NAME}" "${TIMESTAMP}" "${SIZE_BYTES}" '
        '"${LOCAL_MANIFEST}"\n'
        "wal-g st put --no-compress --no-encrypt "
        '"${LOCAL_MANIFEST}" "${REMOTE_PATH}.manifest.json"\n'
    )


def postgres_backup_policy_apply_command(
    config,
    *,
    policy_token,
    task_token,
    policy_name,
    project_slug,
    database_name,
    schedule_mode,
    time1,
    time2,
    retention_keep_last,
    enabled,
    destination,
):
    policy_dir = f"{config.stack_root}/backups/policies/{policy_token}"
    env_path = f"{policy_dir}/walg.env"
    script_path = f"{policy_dir}/run_backup.sh"
    cron_path = server_paths.postgres_backup_cron_file(policy_token)
    log_path = server_paths.postgres_backup_log(policy_token)
    remote_base_path = backup_remote_base_path(project_slug, policy_token)
    cron_times = [time1]
    if schedule_mode == "daily_twice" and time2 is not None:
        cron_times.append(time2)

    env_body = _backup_policy_environment_body(
        config,
        database_name=database_name,
        policy_name=policy_name,
        policy_token=policy_token,
        task_token=task_token,
        remote_base_path=remote_base_path,
        retention_keep_last=retention_keep_last,
        destination=destination,
    )

    script_body = (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
        '. "${SCRIPT_DIR}/walg.env"\n'
        'TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"\n'
        'TMP_DIR="$(mktemp -d)"\n'
        'cleanup(){ rm -rf "${TMP_DIR}" >/dev/null 2>&1 || true; }\n'
        "trap cleanup EXIT INT TERM\n"
        'LOCAL_DUMP="${TMP_DIR}/${BACKUP_DATABASE_NAME}_${TIMESTAMP}.dump"\n'
        'REMOTE_PATH="${BACKUP_REMOTE_BASE_PATH}/${TIMESTAMP}__${BACKUP_DATABASE_NAME}.dump"\n'
        'docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${CONTAINER_NAME}" '
        'pg_dump -U "${POSTGRES_USER}" -d "${BACKUP_DATABASE_NAME}" '
        '-Fc --no-owner --no-privileges > "${LOCAL_DUMP}"\n'
        'SIZE_BYTES="$(wc -c < "${LOCAL_DUMP}" | tr -d \'[:space:]\')"\n'
        "wal-g st put --no-compress --no-encrypt "
        '"${LOCAL_DUMP}" "${REMOTE_PATH}"\n'
        + postgres_backup_manifest_write_command()
        + 'echo "backup_artifact_path=${REMOTE_PATH}"\n'
        'echo "backup_created_at=${TIMESTAMP}"\n'
        'echo "backup_size_bytes=${SIZE_BYTES}"\n'
        # The prune phase below expands backup_artifact_key() in shell: the
        # listing prints folder-relative names but `wal-g st rm` resolves
        # from the storage root, so the full key is rebuilt before deleting
        # (#95). A failed prune fails the run (backup_run_now surfaces the
        # task result in the app); only a missing manifest stays a warning.
        "PRUNE_FAILURES=0\n"
        'if [ "${BACKUP_RETENTION_KEEP_LAST}" -gt 0 ]; then\n'
        '  mapfile -t OBJECTS < <(wal-g st ls -r "${BACKUP_REMOTE_BASE_PATH}" '
        "| awk '{print $NF}' | grep '\\.dump$' | sort)\n"
        '  COUNT="${#OBJECTS[@]}"\n'
        '  if [ "${COUNT}" -gt "${BACKUP_RETENTION_KEEP_LAST}" ]; then\n'
        "    DELETE_COUNT=$((COUNT-BACKUP_RETENTION_KEEP_LAST))\n"
        "    for ((i=0; i<DELETE_COUNT; i++)); do\n"
        '      OBJECT_NAME="${OBJECTS[$i]}"\n'
        '      case "${OBJECT_NAME}" in\n'
        '        "${BACKUP_REMOTE_BASE_PATH}/"*) ARTIFACT_KEY="${OBJECT_NAME}" ;;\n'
        '        *) ARTIFACT_KEY="${BACKUP_REMOTE_BASE_PATH}/${OBJECT_NAME}" ;;\n'
        "      esac\n"
        '      if ! wal-g st rm "${ARTIFACT_KEY}"; then\n'
        '        echo "prune_failed=${ARTIFACT_KEY}" >&2\n'
        "        PRUNE_FAILURES=$((PRUNE_FAILURES+1))\n"
        "        continue\n"
        "      fi\n"
        '      wal-g st rm "${ARTIFACT_KEY}.manifest.json" || '
        'echo "prune_manifest_missing=${ARTIFACT_KEY}" >&2\n'
        '      echo "pruned_artifact=${ARTIFACT_KEY}"\n'
        "    done\n"
        "  fi\n"
        "fi\n"
        'if [ "${PRUNE_FAILURES}" -gt 0 ]; then\n'
        '  echo "prune_failures=${PRUNE_FAILURES}" >&2\n'
        "  exit 1\n"
        "fi\n"
    )

    cron_lines = [
        "SHELL=/bin/bash",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    ]
    for hhmm in cron_times:
        hour = hhmm.split(":", 1)[0].zfill(2)
        minute = hhmm.split(":", 1)[1].zfill(2)
        cron_lines.append(
            f"{minute} {hour} * * * root /bin/bash {script_path} >> {log_path} 2>&1",
        )
    cron_body = "\n".join(cron_lines) + "\n"

    quoted_policy_dir = shlex.quote(policy_dir)
    quoted_env_path = shlex.quote(env_path)
    quoted_script_path = shlex.quote(script_path)
    quoted_cron_path = shlex.quote(cron_path)
    quoted_log_dir = shlex.quote(server_paths.LOG_ROOT)
    quoted_env_body = shlex.quote(env_body)
    quoted_script_body = shlex.quote(script_body)
    quoted_cron_body = shlex.quote(cron_body)

    command = (
        "set -eu; "
        f"POLICY_DIR={quoted_policy_dir}; "
        f"ENV_PATH={quoted_env_path}; "
        f"SCRIPT_PATH={quoted_script_path}; "
        f"CRON_PATH={quoted_cron_path}; "
        'mkdir -p "${POLICY_DIR}"; '
        f"mkdir -p {quoted_log_dir}; "
        f'printf %s {quoted_env_body} > "${{ENV_PATH}}"; '
        'chmod 600 "${ENV_PATH}"; '
        f'printf %s {quoted_script_body} > "${{SCRIPT_PATH}}"; '
        'chmod 750 "${SCRIPT_PATH}"; '
    )
    if enabled:
        command += f'printf %s {quoted_cron_body} > "${{CRON_PATH}}"; chmod 644 "${{CRON_PATH}}"; '
    else:
        command += 'rm -f "${CRON_PATH}"; '

    return {
        "command": command,
        "policy_dir": policy_dir,
        "cron_path": cron_path,
        "script_path": script_path,
        "remote_base_path": remote_base_path,
    }


def postgres_backup_restore_format_check_command():
    """Shell snippet to insert into a restore command, before downloading
    and restoring the dump itself. Assumes ARTIFACT_PATH and TMP_DIR are
    already set by the caller (both are already established variable names
    at every restore call site).

    Backups from before this manifest concept existed have no
    "<artifact>.manifest.json" companion object at all; `wal-g st get`
    fails and the `if` simply does not run -- that absence is treated as
    the oldest supported format, per the "support every older format
    forever" policy, not refused. A manifest that does exist and names a
    format_version this build does not recognize aborts the whole command
    (`set -eu` is already in force at every call site) before pg_restore
    -- which is destructive to whatever "createdb" just made -- ever runs.
    """
    return (
        'MANIFEST_PATH="${ARTIFACT_PATH}.manifest.json"; '
        'LOCAL_MANIFEST="${TMP_DIR}/manifest.json"; '
        "if wal-g st get --no-decompress --no-decrypt "
        '"${MANIFEST_PATH}" "${LOCAL_MANIFEST}" 2>/dev/null; then '
        'python3 - "${LOCAL_MANIFEST}" '
        f"{POSTGRES_BACKUP_MANIFEST_FORMAT_VERSION} <<'PY'\n"
        "import json, sys\n"
        "path, known = sys.argv[1], int(sys.argv[2])\n"
        "data = json.load(open(path))\n"
        "version = data.get('format_version')\n"
        "if version is None or version > known:\n"
        "    print(\n"
        "        f'Backup manifest format_version {version!r} is not '\n"
        "        f'supported by this build (expected <= {known}).',\n"
        "        file=sys.stderr,\n"
        "    )\n"
        "    sys.exit(1)\n"
        "PY\n"
        "fi; "
    )


def postgres_backup_policy_delete_command(config, policy_token):
    """Remove one policy's scheduler, private config, and operational log.

    The existence check makes the command report only real removals while
    keeping a second invocation harmless. Logs leave with their policy: they
    can contain database names and failure detail and have no useful owner
    after the schedule is gone (#90).
    """
    policy_dir = f"{config.stack_root}/backups/policies/{policy_token}"
    cron_path = server_paths.postgres_backup_cron_file(policy_token)
    log_path = server_paths.postgres_backup_log(policy_token)
    return (
        "set -eu; REMOVED=false; "
        f"if [ -e {shlex.quote(cron_path)} ] || "
        f"[ -d {shlex.quote(policy_dir)} ] || "
        f"[ -e {shlex.quote(log_path)} ]; then REMOVED=true; fi; "
        f"rm -f {shlex.quote(cron_path)} {shlex.quote(log_path)}; "
        f"rm -rf {shlex.quote(policy_dir)}; "
        f'if [ "$REMOVED" = true ]; then echo '
        f"removed_backup_policy={shlex.quote(policy_token)}; fi"
    )


def postgres_project_backup_policies_delete_command(config, project_slug):
    """Remove exactly the policies whose private config names one project.

    The generated environment file is the surviving server-side ownership
    record for policies created before a database registry could describe
    them. Matching its complete object prefix avoids the unsafe project-name
    prefix inference that the PostgreSQL ownership registry replaced (#90).
    """
    policy_root = f"{config.stack_root}/backups/policies"
    sentinel = "POLICYTOKEN"
    remote_prefix = backup_remote_base_path(project_slug, sentinel).removesuffix(sentinel)
    cron_prefix = server_paths.postgres_backup_cron_file(sentinel).removesuffix(sentinel)
    log_prefix, _, log_suffix = server_paths.postgres_backup_log(sentinel).partition(
        sentinel,
    )
    return (
        "set -eu; "
        f"POLICY_ROOT={shlex.quote(policy_root)}; "
        f"CRON_PREFIX={shlex.quote(cron_prefix)}; "
        f"LOG_PREFIX={shlex.quote(log_prefix)}; "
        f"LOG_SUFFIX={shlex.quote(log_suffix)}; "
        f"REMOTE_PREFIX={shlex.quote(remote_prefix)}; "
        'if [ -d "$POLICY_ROOT" ]; then '
        'for ENV_FILE in "$POLICY_ROOT"/*/walg.env; do '
        '[ -f "$ENV_FILE" ] || continue; '
        'POLICY_DIR="${ENV_FILE%/walg.env}"; '
        'POLICY_TOKEN="${POLICY_DIR##*/}"; '
        'case "$POLICY_TOKEN" in ""|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) continue;; esac; '
        'if grep -Fqx -- "BACKUP_REMOTE_BASE_PATH=${REMOTE_PREFIX}${POLICY_TOKEN}" '
        '"$ENV_FILE"; then '
        'rm -f "${CRON_PREFIX}${POLICY_TOKEN}" '
        '"${LOG_PREFIX}${POLICY_TOKEN}${LOG_SUFFIX}"; '
        'rm -rf "$POLICY_DIR"; '
        'echo "removed_backup_policy=${POLICY_TOKEN}"; '
        "fi; done; fi"
    )


def postgres_service_backup_policies_delete_command(config):
    """Remove every managed policy remnant before PostgreSQL service teardown.

    Tokens are enumerated from policy directories, cron files, and logs so a
    partially deleted legacy policy is still cleaned. The generated token set
    is de-duplicated before removal and reporting, making retries safe (#90).
    """
    policy_root = f"{config.stack_root}/backups/policies"
    sentinel = "POLICYTOKEN"
    cron_prefix = server_paths.postgres_backup_cron_file(sentinel).removesuffix(sentinel)
    log_prefix, _, log_suffix = server_paths.postgres_backup_log(sentinel).partition(
        sentinel,
    )
    return (
        "set -eu; "
        f"POLICY_ROOT={shlex.quote(policy_root)}; "
        f"CRON_PREFIX={shlex.quote(cron_prefix)}; "
        f"LOG_PREFIX={shlex.quote(log_prefix)}; "
        f"LOG_SUFFIX={shlex.quote(log_suffix)}; "
        'TOKENS_FILE="$(mktemp)"; '
        "trap 'rm -f \"$TOKENS_FILE\"' EXIT; "
        'for POLICY_DIR in "$POLICY_ROOT"/*; do '
        '[ -d "$POLICY_DIR" ] || continue; basename "$POLICY_DIR" >> "$TOKENS_FILE"; done; '
        'for CRON_FILE in "${CRON_PREFIX}"*; do '
        '[ -e "$CRON_FILE" ] || continue; '
        'printf \'%s\\n\' "${CRON_FILE#"$CRON_PREFIX"}" >> "$TOKENS_FILE"; done; '
        'for LOG_FILE in "${LOG_PREFIX}"*"${LOG_SUFFIX}"; do '
        '[ -e "$LOG_FILE" ] || continue; '
        'POLICY_TOKEN="${LOG_FILE#"$LOG_PREFIX"}"; '
        'printf \'%s\\n\' "${POLICY_TOKEN%"$LOG_SUFFIX"}" >> "$TOKENS_FILE"; done; '
        'sort -u "$TOKENS_FILE" | while IFS= read -r POLICY_TOKEN; do '
        'case "$POLICY_TOKEN" in ""|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) continue;; esac; '
        'rm -f "${CRON_PREFIX}${POLICY_TOKEN}" '
        '"${LOG_PREFIX}${POLICY_TOKEN}${LOG_SUFFIX}"; '
        'rm -rf "$POLICY_ROOT/$POLICY_TOKEN"; '
        'echo "removed_backup_policy=${POLICY_TOKEN}"; done; '
        'rm -f "$TOKENS_FILE"; trap - EXIT'
    )


def postgres_backup_backlog_cleanup_command(destination, keys):
    """Shell command deleting exactly `keys` plus their manifests.

    One SSH command for the whole backlog: a round trip per artifact would
    take minutes on the accumulations this exists to clear. Each deletion
    reports `deleted_artifact=`/`delete_failed=`, and a missing manifest
    reports `cleanup_manifest_missing=` without failing -- pre-manifest
    dumps have no sidecar. Failures never abort the loop, so one bad key
    cannot strand the rest; the caller fails loudly when any failed (#95).

    Keys are shell-quoted at every use, including inside the report echoes:
    they arrive from a storage listing, not from validated input, so a name
    carrying substitution syntax must stay inert.
    """
    steps = []
    for key in keys:
        quoted = shlex.quote(key)
        steps.append(
            f"if wal-g st rm {quoted}; then "
            f"echo deleted_artifact={quoted}; "
            f"wal-g st rm {quoted}.manifest.json "
            f"|| echo cleanup_manifest_missing={quoted}; "
            f"else echo delete_failed={quoted}; fi; "
        )
    return {
        "command": "set -eu; " + backup_env_export_block(destination) + "".join(steps),
        "keys": list(keys),
    }


def postgres_parse_backup_run_output(output):
    return shell_output.parse_key_values(output).get("backup_artifact_path")


def postgres_parse_backup_artifacts_output(output, remote_base_path=None):
    artifacts = []
    for raw_line in getattr(output, "stdout_lines", None) or []:
        line = str(raw_line).strip()
        if not line:
            continue
        if line.lower().startswith("name") and "size" in line.lower():
            continue
        fields = line.split()
        candidate = fields[-1]
        if candidate.endswith("/"):
            continue
        # Anchored like the prune phase's `grep '\.dump$'`: a substring
        # match would count "<dump>.manifest.json" sidecars as restorable
        # artifacts and corrupt retention counting (#95).
        if not candidate.lower().endswith(".dump"):
            continue
        path = backup_artifact_key(remote_base_path, candidate)
        size_bytes = None
        if len(fields) > 1 and fields[1].isdigit():
            size_bytes = int(fields[1])
        created_at = None
        match = re.search(r"(\d{8}T\d{6}Z)__", path)
        if match:
            stamp = match.group(1)
            created_at = (
                f"{stamp[0:4]}-{stamp[4:6]}-{stamp[6:8]}T"
                f"{stamp[9:11]}:{stamp[11:13]}:{stamp[13:15]}Z"
            )
        artifacts.append(
            {
                "remote_path": path,
                "created_at": created_at,
                "size_bytes": size_bytes,
            }
        )

    artifacts.sort(key=lambda item: item.get("remote_path") or "", reverse=True)
    return artifacts


def postgres_backlog_beyond_retention(artifacts, retention_keep_last):
    """Split parsed artifacts into retained and beyond-retention sets.

    The backlog report shows the beyond set ("N artifacts (~X GB)") and
    the confirmed cleanup deletes exactly it, so this selector is where
    "never removes the newest N" is enforced: newest-first by remote path
    (timestamp-prefixed names order chronologically), keep the first N,
    doom the rest oldest-first. A non-positive keep-last still keeps one --
    deleting everything must stay unrepresentable (#95).
    """
    keep = retention_keep_last if retention_keep_last >= 1 else 1
    ordered = sorted(
        artifacts or [],
        key=lambda item: item.get("remote_path") or "",
        reverse=True,
    )
    retained = ordered[:keep]
    beyond = list(reversed(ordered[keep:]))
    beyond_bytes = 0
    unknown_sizes = 0
    for item in beyond:
        size = item.get("size_bytes")
        if isinstance(size, int):
            beyond_bytes += size
        else:
            unknown_sizes += 1
    return {
        "retained": retained,
        "beyond_retention": beyond,
        "beyond_retention_count": len(beyond),
        "beyond_retention_bytes": beyond_bytes,
        "beyond_retention_unknown_size_count": unknown_sizes,
    }


def postgres_parse_backup_cleanup_output(output):
    """Collect every backlog-cleanup deletion outcome.

    Unlike parse_key_values (last value wins), repeated keys accumulate:
    each `deleted_artifact=` line is a distinct deleted object, and
    collapsing them would under-report the cleanup (#95).
    """
    deleted = []
    failed = []
    manifests_missing = []
    for raw_line in getattr(output, "stdout_lines", None) or []:
        parsed = shell_output.split_key_value(raw_line)
        if parsed is None:
            continue
        key, value = parsed
        if key == "deleted_artifact":
            deleted.append(value)
        elif key == "delete_failed":
            failed.append(value)
        elif key == "cleanup_manifest_missing":
            manifests_missing.append(value)
    return {
        "deleted": deleted,
        "failed": failed,
        "manifests_missing": manifests_missing,
    }


def postgres_parse_backup_policy_cleanup_output(output):
    """Collect ordered, unique policy tokens removed by lifecycle cleanup."""
    removed = []
    for raw_line in getattr(output, "stdout_lines", None) or []:
        parsed = shell_output.split_key_value(raw_line)
        if parsed is None or parsed[0] != "removed_backup_policy":
            continue
        token = parsed[1]
        if token and token not in removed:
            removed.append(token)
    return removed


def resolve_backup_policy_payload(
    config,
    project_prefix,
    *,
    postgres_prefixed_name,
    normalize_postgres_identifier,
):
    policy_token = normalize_backup_policy_token(
        config.backup_policy_id,
        "settings.backup_policy_id",
    )
    task_source = config.backup_task_id or f"backup-pg-{policy_token}"
    task_token = normalize_backup_policy_token(
        task_source,
        "settings.backup_task_id",
    )
    policy_name = (
        config.backup_policy_name.strip()
        if isinstance(config.backup_policy_name, str) and config.backup_policy_name.strip()
        else policy_token
    )
    database_name = postgres_prefixed_name(
        project_prefix,
        config.backup_database_name,
        "settings.backup_database_name",
    )
    schedule_mode = (config.backup_schedule_mode or "daily_once").strip().lower()
    if schedule_mode not in ("daily_once", "daily_twice"):
        raise PostgresConfigValidationError(
            "settings.backup_schedule_mode must be one of: daily_once, daily_twice.",
        )
    time1 = normalize_backup_hhmm(
        config.backup_time1,
        "settings.backup_time1",
        "02:00",
    )
    time2 = None
    if schedule_mode == "daily_twice":
        time2 = normalize_backup_hhmm(
            config.backup_time2,
            "settings.backup_time2",
            "14:00",
        )

    retention_keep_last = int(config.backup_retention_keep_last)
    if retention_keep_last < 1:
        retention_keep_last = 1
    if retention_keep_last > 3650:
        retention_keep_last = 3650

    destination = resolve_backup_destination(config)
    project_slug = normalize_postgres_identifier(
        config.project_slug,
        "settings.project_slug",
    )

    return {
        "policy_token": policy_token,
        "task_token": task_token,
        "policy_name": policy_name,
        "project_slug": project_slug,
        "database_name": database_name,
        "schedule_mode": schedule_mode,
        "time1": time1,
        "time2": time2,
        "retention_keep_last": retention_keep_last,
        "enabled": bool(config.enabled),
        "destination": destination,
    }


def resolve_backup_restore_payload(
    config,
    project_prefix,
    *,
    postgres_prefixed_name,
    normalize_postgres_identifier,
):
    target_database_name = postgres_prefixed_name(
        project_prefix,
        config.backup_target_database_name,
        "settings.backup_target_database_name",
    )
    artifact_path = normalize_backup_artifact_path(
        config.backup_artifact_path,
        "settings.backup_artifact_path",
    )
    project_slug = normalize_postgres_identifier(
        config.project_slug,
        "settings.project_slug",
    )
    project_base_path = f"{server_identifiers.BACKUP_OBJECT_ROOT}postgres/{project_slug}/"
    if not artifact_path.startswith(server_identifiers.BACKUP_OBJECT_ROOT):
        policy_token = normalize_backup_policy_token(
            config.backup_policy_id,
            "settings.backup_policy_id",
        )
        remote_base_path = backup_remote_base_path(project_slug, policy_token)
        artifact_path = f"{remote_base_path}/{artifact_path.lstrip('/')}"
    elif not artifact_path.startswith(project_base_path):
        raise PostgresConfigValidationError(
            "settings.backup_artifact_path must belong to the selected project.",
        )
    destination = resolve_backup_destination(config)
    return {
        "target_database_name": target_database_name,
        "artifact_path": artifact_path,
        "destination": destination,
    }
