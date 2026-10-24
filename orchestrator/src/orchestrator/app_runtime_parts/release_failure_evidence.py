"""Own release-specific failure evidence, probe facts, and legacy projections."""

import shlex

from ..engine_context import SupportsAppReleaseLifecycle
from ..failure_evidence import (
    FailureEvidenceInput,
    FailureEvidenceProbe,
    select_failure_evidence,
)
from ._shared import _RELEASE_PROBE_PATHS

_RELEASE_PROBE_MARKER = "__DEPLOYDASH_RELEASE_PROBE__|"


def _candidate_probe_commands(app_config, *, container_name):
    """Render candidate probes that publish only allowlisted status facts."""
    quoted_container_name = shlex.quote(container_name)
    quoted_port = shlex.quote(str(app_config.app_port))
    commands = []
    for path in _RELEASE_PROBE_PATHS:
        quoted_path = shlex.quote(path)
        commands.append(
            'APP_IP="$(docker inspect -f '
            "'{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' "
            f"{quoted_container_name} | grep -m1 -v '^$' | tr -d '[:space:]')\"; "
            '[ -n "${APP_IP}" ] || exit 1; '
            "CURL_EXIT=0; CODE=000; "
            "CODE=\"$(curl -sS -o /dev/null -w '%{http_code}' "
            f'http://${{APP_IP}}:{quoted_port}{quoted_path} 2>/dev/null)" || CURL_EXIT=$?; '
            f"printf '{_RELEASE_PROBE_MARKER}%s|%s|%s\\n' "
            f'{quoted_path} "${{CURL_EXIT}}" "${{CODE}}"; '
            '[ "${CURL_EXIT}" -eq 0 ] && [ "${CODE}" -ge 200 ] && [ "${CODE}" -lt 400 ]'
        )
    return commands


def _routed_probe_commands(app_config):
    """Render routed probes without ever reading or returning a response body."""
    canonical_domain = app_config.canonical_domain
    if not canonical_domain:
        return []
    quoted_http_resolve = shlex.quote(f"{canonical_domain}:80:127.0.0.1")
    quoted_https_resolve = shlex.quote(f"{canonical_domain}:443:127.0.0.1")
    commands = []
    for path in _RELEASE_PROBE_PATHS:
        quoted_url = shlex.quote(f"http://{canonical_domain}{path}")
        commands.append(
            'CURL_EXIT=0; CODE=000; CODE="$(curl -ksS -L --max-redirs 5 --connect-timeout 5 '
            "--max-time 20 -o /dev/null -w '%{http_code}' "
            f"--resolve {quoted_http_resolve} --resolve {quoted_https_resolve} "
            f'{quoted_url} 2>/dev/null)" || CURL_EXIT=$?; '
            f"printf '{_RELEASE_PROBE_MARKER}%s|%s|%s\\n' "
            f'{shlex.quote(path)} "${{CURL_EXIT}}" "${{CODE}}"; '
            '[ "${CURL_EXIT}" -eq 0 ] && [ "${CODE}" -ge 200 ] && [ "${CODE}" -lt 400 ]'
        )
    return commands


def _result_output_lines(ctx: SupportsAppReleaseLifecycle, result, stream_name):
    """Read and sanitize one command stream without consulting any ambient transcript."""
    output = result.get("output") if isinstance(result, dict) else None
    sanitize = ctx.sanitize_message or (lambda value: value)
    lines = []
    for raw_line in getattr(output, stream_name, None) or ():
        line = str(sanitize(str(raw_line))).strip()
        if line:
            lines.append(line)
    return tuple(lines)


def _failure_evidence_from_result(
    ctx: SupportsAppReleaseLifecycle,
    *,
    phase,
    source,
    result=None,
    probe=None,
    probe_source=None,
    boundary_reached=True,
):
    """Select canonical evidence from exactly one release operation result."""
    result = result if isinstance(result, dict) else {}
    exception = result.get("exception")
    stderr_lines = _result_output_lines(ctx, result, "stderr_lines")
    stdout_lines = _result_output_lines(ctx, result, "stdout_lines")
    selected_source = source
    if isinstance(exception, str) and exception.strip():
        sanitize = ctx.sanitize_message or (lambda value: value)
        stderr_lines = (str(sanitize(exception)).strip(),)
        stdout_lines = ()
        selected_source = "exception"
    elif not stderr_lines and not stdout_lines and probe is None:
        selected_source = "none"
    elif not stderr_lines and not stdout_lines and probe_source is not None:
        selected_source = probe_source
    return select_failure_evidence(
        FailureEvidenceInput(
            phase=phase,
            source=selected_source,
            stderr_lines=stderr_lines,
            stdout_lines=stdout_lines,
            probe=probe,
            boundary_reached=boundary_reached,
        )
    )


def _release_probe_from_result(result, *, fallback_path):
    """Extract only allowlisted path, curl-exit, and HTTP-status probe facts."""
    output = result.get("output") if isinstance(result, dict) else None
    for stream_name in ("stdout_lines", "stderr_lines"):
        for raw_line in getattr(output, stream_name, None) or ():
            line = str(raw_line).strip()
            if not line.startswith(_RELEASE_PROBE_MARKER):
                continue
            fields = line.removeprefix(_RELEASE_PROBE_MARKER).split("|")
            if len(fields) != 3:
                continue
            path, raw_curl_exit, raw_http_status = fields
            try:
                curl_exit = int(raw_curl_exit)
                http_status = int(raw_http_status)
            except ValueError:
                continue
            if path not in _RELEASE_PROBE_PATHS:
                continue
            return FailureEvidenceProbe(
                path=path,
                curl_exit=curl_exit if 0 <= curl_exit <= 255 else None,
                http_status=http_status if 100 <= http_status <= 599 else None,
            )
    return FailureEvidenceProbe(
        path=fallback_path if fallback_path in _RELEASE_PROBE_PATHS else None,
    )


def _runtime_log_excerpt_from_evidence(evidence, *, max_lines=8):
    """Derive the legacy readiness excerpt from canonical evidence without reselection."""
    lines = tuple(getattr(evidence, "lines", ()) or ())
    if max_lines <= 0:
        return []
    return list(lines[-max_lines:])


def _stabilization_evidence_result(ctx, log_result, worker_verify_result):
    """Prefer runtime logs, falling back to the failed worker operation when empty."""
    if (
        _result_output_lines(ctx, log_result, "stderr_lines")
        or _result_output_lines(ctx, log_result, "stdout_lines")
        or worker_verify_result["ok"]
    ):
        return log_result, "candidate_runtime"
    return worker_verify_result.get("result"), "failed_operation"


def _readiness_failure_summary(log_excerpt):
    """Preserve the legacy one-line summary as a projection of selected evidence."""
    for line in reversed(log_excerpt):
        normalized = line.strip()
        if not normalized:
            continue
        return f"Readiness failed. Last runtime log: {normalized}"
    return "Readiness failed. The app container did not answer the health checks."


__all__ = (
    "_RELEASE_PROBE_MARKER",
    "FailureEvidenceProbe",
    "_candidate_probe_commands",
    "_failure_evidence_from_result",
    "_readiness_failure_summary",
    "_release_probe_from_result",
    "_result_output_lines",
    "_routed_probe_commands",
    "_runtime_log_excerpt_from_evidence",
    "_stabilization_evidence_result",
)
