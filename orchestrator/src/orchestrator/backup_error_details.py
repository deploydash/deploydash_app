from .failure_evidence import normalize_diagnostic_line


def format_command_error_details(output, sanitize_message):
    """Preserve concise backup errors while sharing the generic line normalizer."""
    if output is None:
        return ""
    stderr_lines = getattr(output, "stderr_lines", None)
    if not stderr_lines:
        return ""
    normalized_lines = []
    seen = set()
    for raw_line in stderr_lines:
        line = normalize_diagnostic_line(raw_line, sanitize_message)
        if not line or line in seen:
            continue
        normalized_lines.append(line)
        seen.add(line)
    return "; ".join(normalized_lines).strip()
