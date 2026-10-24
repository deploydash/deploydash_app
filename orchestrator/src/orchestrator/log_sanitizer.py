import re

# The %-formatting below builds regex *patterns* (not log output) by
# splicing one raw pattern string into another. Several of the resulting
# patterns contain literal `{`/`}` regex metacharacters (e.g. the `}` in
# `[^"'\s,\)\]}]` below), which an f-string would require escaping as `}}`
# -- a subtle, easy-to-get-wrong conversion for code that redacts
# credentials from logs. Left as %-formatting rather than risk silently
# weakening the redaction patterns for a style-only change.
_ANSI_ESCAPE_RE = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")
_UNSAFE_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_SENSITIVE_KEY_RE = re.compile(
    r"(password|passphrase|token|secret|credential|api[_-]?key|access[_-]?key|private[_-]?key|key_path|_sudo_password|ssh_password|pgpassword)",
    re.IGNORECASE,
)
_SENSITIVE_IDENTIFIER_RE = (
    r"[A-Za-z0-9_-]*"
    r"(?:password|passphrase|token|secret|api[_-]?key|access[_-]?key|private[_-]?key|key_path|pgpassword)"
    r"[A-Za-z0-9_-]*"
)
_SENSITIVE_FIELD_RE = re.compile(
    r"""((?:(?<=\W)|^)(?:["']?(?:%s)["']?)\s*[:=]\s*)(["']?)([^"'\s,\)\]}]+)\2"""  # noqa: UP031
    % _SENSITIVE_IDENTIFIER_RE,
    re.IGNORECASE,
)
_URI_CREDENTIAL_RE = re.compile(
    r"([a-z][a-z0-9+\-.]*://[^/\s:@]+:)([^@/\s]+)(@)",
    re.IGNORECASE,
)
_ENV_KEY_NAME_RE = r"[A-Z][A-Z0-9_]{1,}"
_ENV_ASSIGNMENT_RE = re.compile(
    r"(?<![A-Za-z0-9_])(%s)=(\"[^\"]*\"|'[^']*'|[^\s;,\)\]}]+)" % _ENV_KEY_NAME_RE  # noqa: UP031
)
_ENV_MAPPING_RE = re.compile(
    r"""((?:(?<=\W)|^)(?:["']?(?:%s)["']?)\s*[:=]\s*)(["'])([^"']*)\2"""  # noqa: UP031
    % _ENV_KEY_NAME_RE
)
_ENV_TAB_VALUE_RE = re.compile(r"(?m)^(%s)\t.+$" % _ENV_KEY_NAME_RE)  # noqa: UP031
_ENV_CONTAINER_KEYS = frozenset({"env", "env_vars", "environment", "runtime_env"})
_PRIVATE_KEY_BLOCK_RE = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
    re.IGNORECASE | re.DOTALL,
)
_AUTHORIZATION_HEADER_RE = re.compile(
    r"((?:(?<=\W)|^)authorization\s*[:=]\s*)((?:bearer|basic)\s+)?([^\s,;]+)",
    re.IGNORECASE,
)


def _mask_sensitive_field(match):
    prefix, quote, _ = match.groups()
    if quote:
        return f"{prefix}{quote}***{quote}"
    return f"{prefix}***"


def _mask_authorization_header(match):
    """Retain the authentication scheme while removing its credential."""
    prefix, scheme, _ = match.groups()
    return f"{prefix}{scheme or ''}***"


def _redact_descendants(value):
    """Preserve environment-container shape while redacting every leaf value."""
    if isinstance(value, dict):
        return {key: _redact_descendants(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_redact_descendants(item) for item in value]
    if isinstance(value, tuple):
        return tuple(_redact_descendants(item) for item in value)
    return "***"


def normalize_log_text(message):
    """Remove terminal decoration and unsafe controls before log text is ranked or shown."""
    if not isinstance(message, str):
        message = str(message)
    without_ansi = _ANSI_ESCAPE_RE.sub("", message)
    return _UNSAFE_CONTROL_RE.sub("", without_ansi)


def sanitize_text(message):
    cleaned = normalize_log_text(message)
    cleaned = _PRIVATE_KEY_BLOCK_RE.sub("***", cleaned)
    cleaned = _AUTHORIZATION_HEADER_RE.sub(_mask_authorization_header, cleaned)
    cleaned = _SENSITIVE_FIELD_RE.sub(_mask_sensitive_field, cleaned)
    cleaned = _ENV_TAB_VALUE_RE.sub(r"\1\t***", cleaned)
    cleaned = _ENV_MAPPING_RE.sub(
        lambda match: f"{match.group(1)}{match.group(2)}***{match.group(2)}", cleaned
    )
    cleaned = _ENV_ASSIGNMENT_RE.sub(lambda match: f"{match.group(1)}=***", cleaned)
    cleaned = _URI_CREDENTIAL_RE.sub(r"\1***\3", cleaned)
    return cleaned.strip()


def sanitize_data(value):
    if isinstance(value, dict):
        sanitized = {}
        for key, item in value.items():
            if str(key).strip().lower() in _ENV_CONTAINER_KEYS:
                sanitized[key] = _redact_descendants(item)
                continue
            if _SENSITIVE_KEY_RE.search(str(key)):
                sanitized[key] = "***"
                continue
            sanitized[key] = sanitize_data(item)
        return sanitized

    if isinstance(value, list):
        return [sanitize_data(item) for item in value]

    if isinstance(value, tuple):
        return tuple(sanitize_data(item) for item in value)

    if isinstance(value, str):
        return sanitize_text(value)

    return value
