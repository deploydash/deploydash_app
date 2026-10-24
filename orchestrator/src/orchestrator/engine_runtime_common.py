import contextlib
import io
import os
import re
import shlex
import subprocess
import tempfile

from paramiko import DSSKey, ECDSAKey, Ed25519Key, RSAKey
from pyinfra.api.exceptions import ConnectError

from .addressing import format_host_port, normalize_host
from .backup_error_details import format_command_error_details
from .container_status import caddy_service_readiness_check_shell
from .engine_context import SupportsRuntimeCommon
from .engine_metrics_parsers import _parse_positive_int
from .ssh_hostkey import (
    build_host_key_mismatch_payload,
    host_key_mismatch_message,
    is_host_key_mismatch_error,
)


def _normalized_optional_string(value):
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    return trimmed if trimmed else None


def _normalized_port(value):
    if value is None:
        return 22
    try:
        port = int(value)
    except (TypeError, ValueError):
        return None
    return port if 1 <= port <= 65535 else None


def _int_from_env(name, default):
    raw_value = os.getenv(name, "").strip()
    if not raw_value:
        return default
    try:
        parsed = int(raw_value)
        if parsed > 0:
            return parsed
    except ValueError:
        return default
    return default


def _friendly_connect_error_message(ctx: SupportsRuntimeCommon, error_message):
    error_message = ctx.sanitize_message(error_message)
    lowered = error_message.lower()

    if "authentication error" in lowered or "authentication failed" in lowered:
        return (
            "Authentication failed. Verify the SSH username and credentials "
            "(password/key), then try again."
        )
    if "could not resolve hostname" in lowered:
        return "Could not resolve hostname. Check the server host/address and DNS."
    if "could not connect" in lowered or "connection refused" in lowered:
        return (
            "Could not connect to the server. Verify host/port, firewall rules, "
            "and SSH service availability."
        )
    if (
        ("host key" in lowered and "does not match" in lowered)
        or ("remote host identification has changed" in lowered)
        or "ssh host key error" in lowered
    ):
        return host_key_mismatch_message(
            known_hosts_file=_resolve_known_hosts_file(),
        )
    if "no hosts remaining" in lowered:
        return (
            "Could not establish SSH connection. Verify host, port, username, "
            "and authentication details."
        )

    return error_message


def _refresh_known_host_entry(host, port, known_hosts_file):
    if not known_hosts_file:
        return False

    normalized_host = normalize_host(host)
    if normalized_host is None:
        return False

    entries = [normalized_host]
    if port is not None:
        entries.append(format_host_port(normalized_host, port))

    changed = False
    for entry in entries:
        try:
            subprocess.run(
                ["ssh-keygen", "-R", entry, "-f", known_hosts_file],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            changed = True
        except Exception:
            continue
    return changed


def _build_connector_data(
    username,
    password=None,
    key_filename=None,
    private_key=None,
    port=22,
    needs_sudo=False,
):
    auth_timeout = _int_from_env("DEPLOYDASH_SSH_AUTH_TIMEOUT", 3)
    banner_timeout = _int_from_env("DEPLOYDASH_SSH_BANNER_TIMEOUT", 3)

    connector_data = {
        "ssh_user": username,
        "ssh_allow_agent": False,
        "ssh_look_for_keys": False,
        "ssh_connect_retries": 0,
        # GHSA-r374-rxx8-8654: paramiko accepts SHA-1 RSA signatures and
        # no fixed release fits pyinfra's paramiko<5 cap, so refuse the
        # SHA-1 key algorithms here. RSA keys keep working via SHA-2.
        "ssh_paramiko_connect_kwargs": {
            "auth_timeout": auth_timeout,
            "banner_timeout": banner_timeout,
            "disabled_algorithms": {
                "keys": ["ssh-rsa", "ssh-dss"],
                "pubkeys": ["ssh-rsa", "ssh-dss"],
            },
        },
    }

    strict_host_key = os.getenv(
        "DEPLOYDASH_SSH_STRICT_HOST_KEY_CHECKING",
        "accept-new",
    ).strip()
    if strict_host_key:
        connector_data["ssh_strict_host_key_checking"] = strict_host_key

    known_hosts_file = _resolve_known_hosts_file()
    if known_hosts_file:
        connector_data["ssh_known_hosts_file"] = known_hosts_file

    normalized_password = _normalized_optional_string(password)
    if normalized_password:
        connector_data["ssh_password"] = normalized_password

    normalized_private_key = _normalized_optional_string(private_key)
    normalized_key = _normalized_optional_string(key_filename)
    inline_private_key = normalized_private_key
    if inline_private_key is None and _looks_like_private_key_material(normalized_key):
        inline_private_key = normalized_key
        normalized_key = None

    if inline_private_key is not None:
        connector_data["ssh_paramiko_connect_kwargs"]["pkey"] = _parse_private_key_material(
            inline_private_key
        )
    elif normalized_key:
        connector_data["ssh_key"] = normalized_key

    if port is not None:
        connector_data["ssh_port"] = port

    if needs_sudo and isinstance(username, str) and username.strip() != "root":
        connector_data["_sudo"] = True
        if normalized_password:
            connector_data["_sudo_password"] = normalized_password

    return connector_data


def _resolve_known_hosts_file():
    configured = os.getenv("DEPLOYDASH_SSH_KNOWN_HOSTS_FILE", "").strip()
    candidate_paths = []
    if configured:
        candidate_paths.append(os.path.expanduser(configured))
    else:
        data_dir = os.getenv("DEPLOYDASH_DATA_DIR", "").strip()
        if data_dir:
            candidate_paths.append(
                os.path.join(
                    os.path.expanduser(data_dir),
                    "ssh",
                    "known_hosts",
                ),
            )
    candidate_paths.append(os.path.join(tempfile.gettempdir(), "deploydash-known_hosts"))

    for known_hosts_file in candidate_paths:
        parent = os.path.dirname(known_hosts_file)
        if parent:
            try:
                os.makedirs(parent, exist_ok=True)
            except OSError:
                continue
            with contextlib.suppress(OSError):
                os.chmod(parent, 0o700)

        try:
            if not os.path.exists(known_hosts_file):
                with open(known_hosts_file, "a", encoding="utf-8"):
                    pass
            os.chmod(known_hosts_file, 0o600)
            return known_hosts_file
        except OSError:
            continue

    return None


def _looks_like_private_key_material(value):
    if not isinstance(value, str):
        return False
    trimmed = value.strip()
    if not trimmed.startswith("-----BEGIN "):
        return False
    return "PRIVATE KEY-----" in trimmed


def _parse_private_key_material(private_key):
    normalized_key = _normalized_optional_string(private_key)
    if normalized_key is None:
        return None
    key_text = normalized_key if normalized_key.endswith("\n") else f"{normalized_key}\n"
    for key_type in (Ed25519Key, RSAKey, ECDSAKey, DSSKey):
        try:
            return key_type.from_private_key(io.StringIO(key_text))
        except Exception:
            continue
    raise ValueError("Unsupported SSH private key format.")


def _extract_connection_payload(data):
    if not isinstance(data, dict):
        return None

    connection_data = data.get("connection")
    if isinstance(connection_data, dict):
        auth_data = connection_data.get("auth")
        if not isinstance(auth_data, dict):
            auth_data = {}
        private_key = connection_data.get("private_key") or auth_data.get("private_key")
        return {
            "host": normalize_host(connection_data.get("host") or connection_data.get("ip")),
            "ip": normalize_host(connection_data.get("host") or connection_data.get("ip")),
            "username": connection_data.get("username") or connection_data.get("ssh_user"),
            "password": connection_data.get("password") or auth_data.get("password"),
            "key_path": None,
            "private_key": private_key,
            "port": _normalized_port(connection_data.get("port")),
        }

    server_data = data.get("server")
    if isinstance(server_data, dict):
        auth_data = server_data.get("auth")
        if not isinstance(auth_data, dict):
            auth_data = {}
        private_key = auth_data.get("private_key")
        return {
            "host": normalize_host(server_data.get("host") or server_data.get("ip")),
            "ip": normalize_host(server_data.get("host") or server_data.get("ip")),
            "username": server_data.get("ssh_user"),
            "password": auth_data.get("password"),
            "key_path": None,
            "private_key": private_key,
            "port": _normalized_port(server_data.get("port")),
        }

    private_key = data.get("private_key")
    return {
        "host": normalize_host(data.get("host") or data.get("ip")),
        "ip": normalize_host(data.get("host") or data.get("ip")),
        "username": data.get("username"),
        "password": data.get("password"),
        "key_path": None,
        "private_key": private_key,
        "port": _normalized_port(data.get("port")),
    }


def _normalize_runtime_log_tail(value, default=200, max_lines=2000):
    parsed = _parse_positive_int(value)
    if parsed is None or parsed <= 0:
        return default
    return min(parsed, max_lines)


def _runtime_event_emitter(ctx: SupportsRuntimeCommon, emit):
    def _emit_runtime_event(event_type, message, level="info", data=None):
        clean_message = ctx.sanitize_message(message)
        if not clean_message:
            return

        ctx.emit_event(
            emit,
            event_type,
            clean_message,
            level=level,
            data=data,
        )

    return _emit_runtime_event


def _open_runtime_session(
    ctx: SupportsRuntimeCommon,
    ip,
    username,
    password=None,
    key_filename=None,
    private_key=None,
    port=22,
    needs_sudo=False,
    emit=None,
):
    ctx.emit_event(
        emit,
        "connection_start",
        f"Connecting to {format_host_port(ip, port)} as {username}",
    )

    connector_data = _build_connector_data(
        username=username,
        password=password,
        key_filename=key_filename,
        private_key=private_key,
        port=port,
        needs_sudo=needs_sudo,
    )
    known_hosts_file = connector_data.get("ssh_known_hosts_file")
    strict_host_key = str(connector_data.get("ssh_strict_host_key_checking", "")).strip().lower()
    try:
        session = ctx.create_runtime_session(
            host_name=ip,
            connector_data=connector_data,
            emit_event=_runtime_event_emitter(ctx, emit),
        )
    except ConnectError as exc:
        raw_message = str(exc)
        if strict_host_key == "accept-new" and is_host_key_mismatch_error(
            ctx.sanitize_message(raw_message)
        ):
            host_key_mismatch = build_host_key_mismatch_payload(
                host=ip,
                port=port,
                known_hosts_file=known_hosts_file,
            )
            msg = _friendly_connect_error_message(ctx, raw_message)
            ctx.emit_event(emit, "connection_error", msg, level="error")
            return {
                "ok": False,
                "error": ctx.error_result(
                    "ENGINE_AUTH_FAILED",
                    msg,
                    stage="connect",
                    details=ctx.sanitize_message(raw_message),
                    extra={
                        "host_key_confirmation_required": True,
                        "host_key_mismatch": host_key_mismatch,
                    },
                ),
            }
        msg = _friendly_connect_error_message(ctx, raw_message)
        ctx.emit_event(emit, "connection_error", msg, level="error")
        return {
            "ok": False,
            "error": ctx.error_result(
                "ENGINE_AUTH_FAILED",
                msg,
                stage="connect",
                details=ctx.sanitize_message(raw_message),
            ),
        }
    except Exception as exc:
        msg = _friendly_connect_error_message(ctx, str(exc))
        ctx.emit_event(emit, "connection_error", msg, level="error")
        return {
            "ok": False,
            "error": ctx.error_result(
                "ENGINE_RUNTIME_ERROR",
                msg,
                stage="connect",
                details=ctx.sanitize_message(str(exc)),
            ),
        }

    ctx.emit_event(
        emit,
        "connection_ready",
        "Connection established.",
    )
    return {"ok": True, "session": session}


def _read_remote_file_text(host, path, timeout=10):
    command = f"cat {shlex.quote(path)}"

    # Read with sudo first: deploy key files are created in sudo-backed
    # workflows and can be unreadable by the SSH user.
    status, output = host.run_shell_command(
        command,
        _timeout=timeout,
        _sudo=True,
    )
    if status and output is not None:
        text = "\n".join(output.stdout_lines).strip()
        if text:
            return text

    # Fallback without sudo for environments where sudo is unavailable.
    status, output = host.run_shell_command(
        command,
        _timeout=timeout,
    )
    if status and output is not None:
        text = "\n".join(output.stdout_lines).strip()
        if text:
            return text

    if output is not None and getattr(output, "stderr_lines", None):
        details = "; ".join(output.stderr_lines).strip()
        raise RuntimeError(f"Unable to read remote file: {path} ({details})")

    raise RuntimeError(f"Unable to read remote file: {path}")


def _command_error_details(ctx: SupportsRuntimeCommon, output):
    return format_command_error_details(output, ctx.sanitize_message)


def _probe_http_gateway_fast_path(ctx: SupportsRuntimeCommon, host, app_config, timeout=8):
    quoted_apply_helper = shlex.quote(app_config.caddy_apply_helper)
    quoted_stack_root = shlex.quote(app_config.caddy_stack_root)
    quoted_container = shlex.quote(app_config.caddy_container_name)

    checks = [
        (
            "apply_helper",
            "Caddy apply helper is missing",
            f"test -x {quoted_apply_helper}",
        ),
        (
            "compose_file",
            "Caddy compose file is missing",
            f"test -f {quoted_stack_root}/docker-compose.yml",
        ),
        (
            "caddyfile",
            "Caddyfile is missing",
            f"test -f {quoted_stack_root}/caddy/Caddyfile",
        ),
        (
            "caddy_readiness",
            "Caddy is not ready",
            caddy_service_readiness_check_shell(quoted_container),
        ),
        (
            "caddy_health",
            "Caddy health is not healthy",
            'STATUS="$(docker inspect -f '
            f"'{{{{if .State.Health}}}}{{{{.State.Health.Status}}}}{{{{else}}}}none{{{{end}}}}' {quoted_container})\"; "
            '[ "${STATUS}" = healthy ] || [ "${STATUS}" = none ]',
        ),
    ]
    if (
        app_config.tls_challenge_mode == "dns"
        and isinstance(app_config.tls_dns_provider, str)
        and app_config.tls_dns_provider.strip() != ""
    ):
        provider = re.escape(app_config.tls_dns_provider.strip())
        checks.append(
            (
                "caddy_dns_module",
                f"Caddy DNS module '{app_config.tls_dns_provider}' is missing",
                "docker exec "
                f"{quoted_container} "
                "caddy list-modules 2>/dev/null | "
                f"grep -E '(dns\\.providers\\.{provider}|tls\\.dns\\.{provider})' >/dev/null",
            )
        )

    for check_id, summary, command in checks:
        status, output = host.run_shell_command(
            command,
            _timeout=timeout,
            _sudo=True,
        )
        if status:
            continue

        details = _command_error_details(ctx, output)
        return {
            "ready": False,
            "failed_check": check_id,
            "reason": summary,
            "details": details,
        }

    return {
        "ready": True,
        "failed_check": None,
        "reason": "",
        "details": "",
    }


def _emit_shell_output_lines(ctx: SupportsRuntimeCommon, emit, output):
    if output is None:
        return

    stdout_lines = getattr(output, "stdout_lines", None) or []
    for line in stdout_lines:
        normalized = ctx.sanitize_message(line)
        if normalized:
            ctx.emit_event(
                emit,
                "pyinfra_operation_stdout",
                normalized,
                level="info",
            )

    stderr_lines = getattr(output, "stderr_lines", None) or []
    for line in stderr_lines:
        normalized = ctx.sanitize_message(line)
        if normalized:
            ctx.emit_event(
                emit,
                "pyinfra_operation_stderr",
                normalized,
                level="warning",
            )
