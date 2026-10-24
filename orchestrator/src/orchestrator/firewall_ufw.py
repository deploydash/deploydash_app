"""Read-only UFW discovery shared by onboarding and firewall staging."""

from typing import Any, TypedDict

from . import shell_output
from .runtime_ops import run_shell_command


class UfwState(TypedDict):
    """Normalized UFW state carried across onboarding and runtime checks."""

    installed: bool
    active: bool
    enabled: bool
    allowed_rules: list[str]


def ufw_probe_command() -> str:
    """Build the single host probe that defines Deploy Dash's view of UFW."""
    return (
        "set +e; "
        'UFW_INSTALLED=0; UFW_ACTIVE=0; UFW_ENABLED=0; UFW_STATUS=""; '
        "if dpkg-query -W -f='${Status}' ufw 2>/dev/null | "
        'grep -q "install ok installed" || command -v ufw >/dev/null 2>&1; then '
        "UFW_INSTALLED=1; "
        'UFW_STATUS="$(ufw status 2>/dev/null || true)"; '
        'if printf "%s\n" "${UFW_STATUS}" | grep -Fqx "Status: active"; then '
        "UFW_ACTIVE=1; fi; "
        "if systemctl is-enabled --quiet ufw 2>/dev/null; then UFW_ENABLED=1; fi; "
        "fi; "
        "printf 'UFW_INSTALLED=%s\nUFW_ACTIVE=%s\nUFW_ENABLED=%s\n' "
        '"${UFW_INSTALLED}" "${UFW_ACTIVE}" "${UFW_ENABLED}"; '
        'if [ "${UFW_ACTIVE}" = 1 ]; then '
        'printf "%s\n" "${UFW_STATUS}" | '
        'awk \'index($0, "ALLOW") { line=$0; '
        'gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); '
        'print "UFW_RULE=" line }\'; '
        "fi"
    )


def parse_ufw_probe(output: Any) -> UfwState:
    """Normalize UFW output so every caller uses the same state semantics."""
    values = shell_output.parse_key_values(output)
    lines = getattr(output, "stdout_lines", None) or []
    rules = []
    for line in lines:
        if isinstance(line, str) and line.startswith("UFW_RULE="):
            rule = line.removeprefix("UFW_RULE=").strip()
            if rule:
                rules.append(rule)
    return {
        "installed": values.get("UFW_INSTALLED") == "1",
        "active": values.get("UFW_ACTIVE") == "1",
        "enabled": values.get("UFW_ENABLED") == "1",
        "allowed_rules": rules,
    }


def _probe_error_details(output: Any) -> str:
    """Keep probe failures useful without depending on an engine context."""
    if output is None:
        return "UFW probe returned no output."
    stderr = getattr(output, "stderr_lines", None) or []
    stdout = getattr(output, "stdout_lines", None) or []
    return "\n".join(stderr or stdout) or "UFW probe command failed."


def probe_ufw(host: Any) -> tuple[UfwState | None, str | None]:
    """Inspect UFW without mutating it, returning state plus any probe error."""
    if not hasattr(host, "run_shell_command"):
        return None, "Host connector does not support shell probes."
    try:
        result = run_shell_command(
            host,
            ufw_probe_command(),
            timeout=10,
            sudo=True,
        )
    except Exception as exc:
        return None, str(exc)
    output = result["output"]
    if not result["ok"] or output is None:
        return None, _probe_error_details(output)
    return parse_ufw_probe(output), None
