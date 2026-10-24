from __future__ import annotations

from .server_identifiers import CADDY_HTTPS_MATCHER

DEFAULT_CONTAINER_PIDS_LIMIT = 512
STRICT_CONTAINER_HARDENING = "strict"
ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING = "entrypoint_compatible"
DEFAULT_PERMISSIONS_POLICY = (
    "accelerometer=(),autoplay=(),camera=(),display-capture=(),"
    "geolocation=(),gyroscope=(),hid=(),magnetometer=(),microphone=(),"
    "midi=(),payment=(),publickey-credentials-get=(),screen-wake-lock=(),"
    "serial=(),usb=(),xr-spatial-tracking=()"
)
DEFAULT_HSTS_VALUE = "max-age=31536000;includeSubDomains"


def _validate_hardening_profile(profile: str) -> str:
    if profile not in {
        STRICT_CONTAINER_HARDENING,
        ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING,
    }:
        raise ValueError("Unknown container hardening profile.")
    return profile


def docker_runtime_security_flags(
    *,
    pids_limit: int = DEFAULT_CONTAINER_PIDS_LIMIT,
    profile: str = STRICT_CONTAINER_HARDENING,
) -> str:
    if not isinstance(pids_limit, int) or pids_limit <= 0:
        raise ValueError("pids_limit must be a positive integer.")
    profile = _validate_hardening_profile(profile)
    if profile == ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING:
        return f"--pids-limit {pids_limit}"
    return f"--security-opt no-new-privileges --cap-drop ALL --pids-limit {pids_limit}"


def docker_compose_security_lines(
    *,
    indent: str = "    ",
    pids_limit: int = DEFAULT_CONTAINER_PIDS_LIMIT,
    cap_add: tuple[str, ...] = (),
    profile: str = STRICT_CONTAINER_HARDENING,
) -> str:
    if not isinstance(pids_limit, int) or pids_limit <= 0:
        raise ValueError("pids_limit must be a positive integer.")
    profile = _validate_hardening_profile(profile)
    rendered = []
    if profile == STRICT_CONTAINER_HARDENING:
        rendered.extend(
            [
                f"{indent}security_opt:",
                f"{indent}  - no-new-privileges:true",
                f"{indent}cap_drop:",
                f"{indent}  - ALL",
            ]
        )
    if cap_add:
        if profile != STRICT_CONTAINER_HARDENING:
            raise ValueError("cap_add requires strict container hardening.")
        rendered.append(f"{indent}cap_add:")
        for capability in cap_add:
            if not isinstance(capability, str) or not capability.strip():
                raise ValueError("cap_add values must be non-empty strings.")
            rendered.append(f"{indent}  - {capability.strip()}")
    rendered.append(f"{indent}pids_limit: {pids_limit}")
    return "\n".join(rendered) + "\n"


def caddy_default_header_lines(*, include_hsts: bool) -> list[str]:
    lines = [
        "header {",
        "    -Server",
        "    -Via",
        "    -X-Powered-By",
        "    ?X-Content-Type-Options nosniff",
        "    ?Referrer-Policy strict-origin-when-cross-origin",
        f"    ?Permissions-Policy {DEFAULT_PERMISSIONS_POLICY}",
        "    ?X-Frame-Options SAMEORIGIN",
        "}",
    ]
    if include_hsts:
        lines.extend(
            [
                f"{CADDY_HTTPS_MATCHER} protocol https",
                f"header {CADDY_HTTPS_MATCHER} {{",
                f"    ?Strict-Transport-Security {DEFAULT_HSTS_VALUE}",
                "}",
            ]
        )
    return lines
