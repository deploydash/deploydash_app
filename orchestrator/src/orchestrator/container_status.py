import re
import shlex

from .shell_output import parse_bool_token

_VALID_PREFIX_PATTERN = re.compile(r"^[a-z][a-z0-9_]*$")


def _normalize_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _normalized_text(value, default=""):
    if value is None:
        return default
    return str(value).strip()


_READINESS_KNOWN_STATUSES = frozenset({"ready", "starting", "unhealthy", "not_checked"})

_READINESS_STATUS_ALIASES = {
    "ok": "ready",
    "healthy": "ready",
    "true": "ready",
    "1": "ready",
    "failed": "unhealthy",
    "down": "unhealthy",
    "false": "unhealthy",
    "0": "unhealthy",
}


def normalize_readiness_status(value):
    normalized = _normalized_text(value, "not_checked").lower()
    if normalized in _READINESS_KNOWN_STATUSES:
        return normalized
    return _READINESS_STATUS_ALIASES.get(normalized, "not_checked")


def normalize_container_status(
    *,
    present=False,
    docker_state="",
    running=False,
    health="unknown",
    exit_code=None,
    image="",
    started_at="",
    readiness_status="not_checked",
    readiness_detail="",
):
    present = parse_bool_token(present, coerce_non_string=True)
    running = parse_bool_token(running, coerce_non_string=True)
    docker_state = _normalized_text(docker_state, "unknown").lower()
    health = _normalized_text(health, "unknown").lower()
    readiness_status = normalize_readiness_status(readiness_status)
    exit_code = _normalize_int(exit_code)

    if not present:
        effective_status = "missing"
    elif docker_state == "restarting":
        effective_status = "restarting"
    elif not running or docker_state in {"created", "exited", "dead", "removing"}:
        effective_status = "stopped"
    elif health == "starting" or readiness_status == "starting":
        effective_status = "starting"
    elif health == "unhealthy" or readiness_status == "unhealthy":
        effective_status = "unhealthy"
    else:
        effective_status = "ready"

    return {
        "present": present,
        "docker_state": docker_state,
        "running": running,
        "health": health,
        "exit_code": exit_code,
        "image": _normalized_text(image),
        "started_at": _normalized_text(started_at),
        "effective_status": effective_status,
        "readiness": {
            "status": readiness_status,
            "detail": _normalized_text(readiness_detail),
        },
    }


_CONTAINER_STATUS_PAYLOAD_FIELDS = (
    "present",
    "docker_state",
    "running",
    "health",
    "exit_code",
    "image",
    "started_at",
)


def container_status_from_payload(
    payload,
    prefix,
    *,
    readiness_status=None,
    readiness_detail=None,
):
    key_prefix = f"{prefix}_"
    readiness_status = (
        payload.get(f"{key_prefix}readiness_status")
        if readiness_status is None
        else readiness_status
    )
    readiness_detail = (
        payload.get(f"{key_prefix}readiness_detail")
        if readiness_detail is None
        else readiness_detail
    )
    fields = {name: payload.get(f"{key_prefix}{name}") for name in _CONTAINER_STATUS_PAYLOAD_FIELDS}
    return normalize_container_status(
        **fields,
        readiness_status=readiness_status or "not_checked",
        readiness_detail=readiness_detail or "",
    )


def container_status_from_worker_row(row):
    state = _normalized_text(row.get("state"), "unknown").lower()
    status_text = _normalized_text(row.get("status"), "").lower()
    health = "none"
    if "(healthy)" in status_text:
        health = "healthy"
    elif "(health: starting)" in status_text or "(starting)" in status_text:
        health = "starting"
    elif "(unhealthy)" in status_text:
        health = "unhealthy"
    return normalize_container_status(
        present=True,
        docker_state=state,
        running=state == "running",
        health=health,
        image=row.get("image", ""),
    )


# (key, docker inspect -f template, failure fallback). Templates render
# inside the -f single quotes with their Go braces intact; each row keeps
# its own fallback -- parameterized per row, never unified.
_STATUS_INSPECT_ROWS = (
    ("docker_state", "{{.State.Status}}", "true"),
    ("running", "{{.State.Running}}", "echo false"),
    (
        "health",
        "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}",
        "echo unknown",
    ),
    ("exit_code", "{{.State.ExitCode}}", "true"),
    ("image", "{{.Config.Image}}", "true"),
    ("started_at", "{{.State.StartedAt}}", "true"),
)

_STATUS_MISSING_ROWS = (
    ("present", "0"),
    ("docker_state", "missing"),
    ("running", "false"),
    ("health", "unknown"),
    ("exit_code", "''"),
    ("image", "''"),
    ("started_at", "''"),
)


def container_status_kv_shell(prefix, container_ref):
    if not _VALID_PREFIX_PATTERN.match(prefix):
        raise ValueError(f"invalid container status prefix: {prefix!r}")
    present_rows = "".join(
        f"kv {prefix}_{key} \"$(docker inspect -f '{template}' "
        f'{container_ref} 2>/dev/null || {fallback})"; '
        for key, template, fallback in _STATUS_INSPECT_ROWS
    )
    missing_rows = "".join(
        f"kv {prefix}_{key} {literal}; " for key, literal in _STATUS_MISSING_ROWS
    )
    head = (
        "if command -v docker >/dev/null 2>&1 && "
        f"docker inspect {container_ref} >/dev/null 2>&1; then "
        f"kv {prefix}_present 1; "
    )
    return f"{head}{present_rows}else {missing_rows}fi"


def container_process_running_check_shell(container_ref):
    return (
        "command -v docker >/dev/null 2>&1 && "
        f"docker inspect -f '{{{{.State.Running}}}}' "
        f"{container_ref} 2>/dev/null | grep -q true"
    )


def _service_readiness_check_shell(container_ref, probe_fragment):
    # Why: single owner of the gate && probe-fragment join; fragments stay
    # per-service because bind has two exec stages. Refs are caller-trusted
    # identifiers interpolated unquoted, matching current behavior.
    return f"{container_process_running_check_shell(container_ref)} && {probe_fragment}"


def caddy_service_readiness_check_shell(container_ref):
    return _service_readiness_check_shell(
        container_ref,
        f"docker exec {container_ref} caddy validate "
        "--config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1",
    )


def bind_service_readiness_check_shell(container_ref):
    named_probe = shlex.quote("pidof named >/dev/null 2>&1 || pgrep -x named >/dev/null 2>&1")
    return _service_readiness_check_shell(
        container_ref,
        f"docker exec {container_ref} sh -c {named_probe} >/dev/null 2>&1 && "
        f"docker exec {container_ref} "
        "named-checkconf /etc/bind/named.conf >/dev/null 2>&1",
    )


def postgres_service_readiness_check_shell(container_ref, postgres_user_ref):
    return _service_readiness_check_shell(
        container_ref,
        f"docker exec {container_ref} "
        f"pg_isready -U {postgres_user_ref} -d postgres >/dev/null 2>&1",
    )


def _require_int_at_least(value, minimum, message):
    # Strict-int validation: unlike the lenient _parse_positive_int
    # family, strings never coerce here, and bools are rejected even
    # though isinstance accepts them -- True/False would render into
    # shell integer contexts ([ -le ], sleep) that reject them.
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(message)
    return value


def postgres_service_readiness_wait_shell(
    container_ref,
    postgres_user_ref,
    *,
    max_attempts=45,
    delay_seconds=2,
):
    max_attempts = _require_int_at_least(max_attempts, 1, "max_attempts must be a positive integer")
    delay_seconds = _require_int_at_least(
        delay_seconds,
        0,
        "delay_seconds must be a non-negative integer",
    )
    readiness_check = postgres_service_readiness_check_shell(
        container_ref,
        postgres_user_ref,
    )
    return (
        "POSTGRES_READY=0; "
        "ATTEMPT=1; "
        f"MAX_ATTEMPTS={max_attempts}; "
        'while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do '
        f"if {readiness_check}; then POSTGRES_READY=1; break; fi; "
        f"sleep {delay_seconds}; "
        "ATTEMPT=$((ATTEMPT+1)); "
        "done; "
        '[ "$POSTGRES_READY" = 1 ] || '
        '(echo "PostgreSQL readiness probe failed after '
        '${MAX_ATTEMPTS} attempts." >&2; '
        f"docker logs --tail 80 {container_ref} >&2 || true; exit 1)"
    )


def worker_process_check_shell(container_ref):
    return container_process_running_check_shell(container_ref)
