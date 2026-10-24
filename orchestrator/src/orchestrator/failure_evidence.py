"""Select and serialize bounded version-one deployment failure evidence.

This module is the sole evidence and structured-error-normalization owner so a
failed operation cannot accidentally grow into a second transcript or bypass
the engine's standard ``msg`` and ``details`` fallback.
"""

import json
import re
import xml.etree.ElementTree as ET
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import cast

from .log_sanitizer import normalize_log_text, sanitize_text

_SANITIZE_TEXT = cast(Callable[[object], str], sanitize_text)

FAILURE_EVIDENCE_FIELD = "failure_evidence"
FAILURE_EVIDENCE_SCHEMA_VERSION = 1
FAILURE_EVIDENCE_MAX_LINES = 12
FAILURE_EVIDENCE_MAX_ENCODED_LINE_BYTES = 6 * 1024

FAILURE_EVIDENCE_PHASES = frozenset(
    {
        "prepare",
        "repository_sync",
        "build",
        "candidate_start",
        "candidate_readiness",
        "traffic_switch",
        "post_cutover_stabilization",
        "rollback",
        "engine",
        "unknown",
    }
)
FAILURE_EVIDENCE_SOURCES = frozenset(
    {
        "failed_operation",
        "candidate_runtime",
        "candidate_probe",
        "routed_probe",
        "exception",
        "none",
        "unknown",
    }
)
FAILURE_EVIDENCE_COMPLETENESS = frozenset(
    {
        "diagnostic",
        "boundary_only",
        "unavailable",
    }
)

_EVIDENCE_FIELDS = frozenset(
    {
        "schema_version",
        "phase",
        "source",
        "completeness",
        "lines",
        "failed_step_id",
        "failed_action_id",
        "probe",
    }
)
_PROBE_FIELDS = frozenset({"path", "curl_exit", "http_status"})
_DIAGNOSTIC_SHAPE_RE = re.compile(
    r"(?:\b(?:error|failed|failure|fatal|exception|traceback|denied|"
    r"unauthori[sz]ed|not\s+found|missing|invalid|timed?\s*out|timeout|"
    r"refused|unhealthy|exited)\b|\bHTTP(?:/\d(?:\.\d)?)?\s+[45]\d\d\b)",
    re.IGNORECASE,
)
_COMPILER_LOCATION_RE = re.compile(
    r"(?:^|\s)[^\s:]+\.[A-Za-z0-9]+:\d+(?::\d+)?(?:\s|:|$)",
)
_DIAGNOSTIC_CONTEXT_BEFORE = 4


@dataclass(frozen=True, slots=True)
class FailureEvidenceProbe:
    """Represent only the safe probe facts permitted across the engine boundary."""

    path: str | None = None
    curl_exit: int | None = None
    http_status: int | None = None


@dataclass(frozen=True, slots=True)
class FailureEvidenceInput:
    """Capture one failed operation without granting access to a global transcript."""

    phase: str
    source: str
    stderr_lines: tuple[object, ...] = ()
    stdout_lines: tuple[object, ...] = ()
    wrapper_lines: tuple[object, ...] = ()
    failed_step_id: str | None = None
    failed_action_id: str | None = None
    probe: FailureEvidenceProbe | None = None
    boundary_reached: bool = True


@dataclass(frozen=True, slots=True)
class FailureEvidence:
    """Hold canonical immutable evidence until the sole serializer builds the wire shape."""

    phase: str
    source: str
    completeness: str
    lines: tuple[str, ...]
    failed_step_id: str | None
    failed_action_id: str | None
    probe: FailureEvidenceProbe | None


def select_failure_evidence(value: FailureEvidenceInput) -> FailureEvidence:
    """Select evidence for one failure boundary without consulting ambient task state."""
    wrappers = frozenset(_normalized_output_lines(value.wrapper_lines))
    stderr = tuple(
        line for line in _normalized_output_lines(value.stderr_lines) if line not in wrappers
    )
    stdout = tuple(
        line for line in _normalized_output_lines(value.stdout_lines) if line not in wrappers
    )

    stderr_window = _select_contiguous_window(stderr, FAILURE_EVIDENCE_MAX_LINES)
    remaining = FAILURE_EVIDENCE_MAX_LINES - len(stderr_window)
    stdout_window = _select_contiguous_window(stdout, remaining) if remaining else ()
    lines = _bounded_sanitized_lines((*stderr_window, *stdout_window))
    probe = _validated_probe(value.probe)
    if lines or probe is not None:
        completeness = "diagnostic"
    elif value.boundary_reached:
        completeness = "boundary_only"
    else:
        completeness = "unavailable"
    return FailureEvidence(
        phase=value.phase,
        source=value.source,
        completeness=completeness,
        lines=lines,
        failed_step_id=value.failed_step_id,
        failed_action_id=value.failed_action_id,
        probe=probe,
    )


def _normalized_output_lines(values: tuple[object, ...]) -> tuple[str, ...]:
    """Turn bounded operation values into ordered comparable diagnostic lines."""
    lines: list[str] = []
    for value in values:
        normalized = normalize_diagnostic_line(value, normalize_log_text)
        normalized = normalized.replace("\r\n", "\n").replace("\r", "\n")
        lines.extend(line.strip() for line in normalized.split("\n") if line.strip())
    return _collapse_repeated_blocks(tuple(lines))


def _collapse_repeated_blocks(lines: tuple[str, ...]) -> tuple[str, ...]:
    """Collapse only adjacent exact repeats so separated recurrence keeps its meaning."""
    collapsed: list[str] = []
    for line in lines:
        if collapsed and collapsed[-1] == line:
            continue
        collapsed.append(line)
        while True:
            repeated_size = next(
                (
                    size
                    for size in range(1, (len(collapsed) // 2) + 1)
                    if collapsed[-(size * 2) : -size] == collapsed[-size:]
                ),
                None,
            )
            if repeated_size is None:
                break
            del collapsed[-repeated_size:]
    return tuple(collapsed)


def _diagnostic_rank(line: str) -> int:
    """Score broad failure shapes solely to position a useful contiguous window."""
    return int(bool(_DIAGNOSTIC_SHAPE_RE.search(line))) + int(
        bool(_COMPILER_LOCATION_RE.search(line))
    )


def _select_contiguous_window(lines: tuple[str, ...], limit: int) -> tuple[str, ...]:
    """Keep one ordered window with context around the latest strongest diagnostic."""
    if limit <= 0 or not lines:
        return ()
    if len(lines) <= limit:
        return lines

    ranked = tuple(_diagnostic_rank(line) for line in lines)
    strongest = max(ranked)
    if strongest:
        focus = max(index for index, rank in enumerate(ranked) if rank == strongest)
        start = max(0, focus - _DIAGNOSTIC_CONTEXT_BEFORE)
        end = min(len(lines), start + limit)
        start = max(0, end - limit)
        return lines[start:end]
    return lines[-limit:]


def _truncate_utf8(value: str, byte_limit: int) -> str:
    """Cut a diagnostic at a valid UTF-8 boundary without exceeding its remaining budget."""
    encoded = value.encode("utf-8")
    if len(encoded) <= byte_limit:
        return value
    return encoded[:byte_limit].decode("utf-8", errors="ignore")


def _bounded_sanitized_lines(lines: tuple[str, ...]) -> tuple[str, ...]:
    """Apply the final secret boundary and both hard wire limits after selection."""
    bounded: list[str] = []
    used_bytes = 0
    selected_text = "\n".join(lines[:FAILURE_EVIDENCE_MAX_LINES])
    sanitized_text = _SANITIZE_TEXT(selected_text)
    sanitized_lines = tuple(line.strip() for line in sanitized_text.split("\n") if line.strip())
    for clean in sanitized_lines:
        separator_bytes = 1 if bounded else 0
        remaining = FAILURE_EVIDENCE_MAX_ENCODED_LINE_BYTES - used_bytes - separator_bytes
        if remaining <= 0:
            break
        clean = _truncate_utf8(clean, remaining)
        if not clean:
            break
        bounded.append(clean)
        used_bytes += separator_bytes + len(clean.encode("utf-8"))
    return tuple(bounded)


def _validated_probe(value: FailureEvidenceProbe | None) -> FailureEvidenceProbe | None:
    """Reject invalid or empty probe values before they can become diagnostic evidence."""
    if value is None:
        return None
    probe_mapping = _probe_mapping(value)
    if not probe_mapping:
        return None
    try:
        serialized = cast(dict[str, object], _serialized_probe(probe_mapping))
    except (TypeError, ValueError):
        return None
    return FailureEvidenceProbe(
        path=cast(str | None, serialized.get("path")),
        curl_exit=cast(int | None, serialized.get("curl_exit")),
        http_status=cast(int | None, serialized.get("http_status")),
    )


def _probe_mapping(value: FailureEvidenceProbe) -> dict[str, object]:
    """Expose exactly the three safe facts from the immutable probe value."""
    return {
        key: fact
        for key, fact in {
            "path": value.path,
            "curl_exit": value.curl_exit,
            "http_status": value.http_status,
        }.items()
        if fact is not None
    }


def _evidence_mapping(value: object) -> object:
    """Translate immutable producer values into the existing closed mapping validator."""
    if not isinstance(value, FailureEvidence):
        return value
    probe = value.probe
    return {
        "schema_version": FAILURE_EVIDENCE_SCHEMA_VERSION,
        "phase": value.phase,
        "source": value.source,
        "completeness": value.completeness,
        "lines": list(value.lines),
        "failed_step_id": value.failed_step_id,
        "failed_action_id": value.failed_action_id,
        "probe": (
            None if probe is None else {key: fact for key, fact in _probe_mapping(probe).items()}
        ),
    }


def normalize_diagnostic_line(raw_line: object, sanitize_message: Callable[[object], str]) -> str:
    """Share structured JSON/XML extraction between evidence and legacy error details."""
    normalized = sanitize_message(raw_line).strip()
    if not normalized:
        return ""

    parsed = _structured_json_error_message(normalized) or _structured_xml_error_message(normalized)
    return parsed or normalized


def _structured_json_error_message(text: str) -> str | None:
    """Extract common error code and message fields without depending on one framework."""
    stripped = text.strip()
    if not stripped.startswith("{"):
        return None
    try:
        payload = json.loads(stripped)
    except Exception:
        return None
    candidate_dicts = [payload]
    for key in ("error", "Error", "errors", "Errors"):
        nested = payload.get(key)
        if isinstance(nested, Mapping):
            candidate_dicts.append(nested)

    for item in candidate_dicts:
        message = _first_nonempty_value(
            item,
            "Message",
            "message",
            "msg",
            "detail",
            "details",
            "error_description",
            "description",
        )
        code = _first_nonempty_value(
            item,
            "Code",
            "code",
            "errorCode",
            "error_code",
            "type",
        )
        combined = _combine_error_code_and_message(code, message)
        if combined:
            return combined
    return None


def _structured_xml_error_message(text: str) -> str | None:
    """Extract namespace-tolerant XML errors while preserving a useful command prefix."""
    marker = text.find("<")
    if marker < 0:
        return None
    xml_text = text[marker:].strip()
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return None

    code = _xml_error_field(root, "Code")
    message = _xml_error_field(root, "Message")
    combined = _combine_error_code_and_message(code, message)
    if not combined:
        return None

    prefix = text[:marker].strip(" :-")
    if prefix and prefix.lower() not in combined.lower():
        return f"{prefix}: {combined}"
    return combined


def _xml_error_field(root: ET.Element, field_name: str) -> str | None:
    """Find the first non-blank XML field regardless of an enclosing namespace."""
    target = field_name.lower()
    for element in root.iter():
        local_name = element.tag.rsplit("}", 1)[-1].lower()
        if local_name != target:
            continue
        value = (element.text or "").strip()
        if value:
            return value
    return None


def _first_nonempty_value(payload: Mapping[object, object], *keys: str) -> str | None:
    """Select the first meaningful structured value across common provider field names."""
    for key in keys:
        value = payload.get(key)
        if value is None:
            continue
        if isinstance(value, str):
            trimmed = value.strip()
            if trimmed:
                return trimmed
        else:
            return str(value)
    return None


def _combine_error_code_and_message(code: str | None, message: str | None) -> str | None:
    """Preserve both structured facts without repeating an already-prefixed code."""
    if code and message:
        if message.startswith(f"{code}:"):
            return message
        return f"{code}: {message}"
    if message:
        return message
    if code:
        return code
    return None


def _sanitized_serialized_lines(raw_lines: list[str]) -> list[str]:
    """Redact the whole selected block so multiline secret formats cannot cross the wire."""
    if not raw_lines:
        return []
    joined = "\n".join(raw_lines).replace("\r\n", "\n").replace("\r", "\n")
    sanitized = _SANITIZE_TEXT(joined)
    return [line.strip() for line in sanitized.split("\n")]


def _optional_identifier(value: object) -> str | None:
    """Accept only absent or non-blank workflow identifiers from producers."""
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise ValueError("failure evidence identifier must be a non-blank string")
    return value.strip()


def _serialized_probe(value: object) -> dict[str, object] | None:
    """Keep only complete, body-free probe facts with bounded numeric values."""
    if value is None:
        return None
    if not isinstance(value, Mapping) or not value or not set(value).issubset(_PROBE_FIELDS):
        raise ValueError("failure evidence probe contains unsupported fields")

    probe: dict[str, object] = {}
    if "path" in value:
        path = value["path"]
        if not isinstance(path, str) or not path.strip().startswith("/"):
            raise ValueError("failure evidence probe path must be absolute")
        probe["path"] = path.strip()
    if "curl_exit" in value:
        curl_exit = value["curl_exit"]
        if type(curl_exit) is not int or not 0 <= curl_exit <= 255:
            raise ValueError("failure evidence curl exit is out of range")
        probe["curl_exit"] = curl_exit
    if "http_status" in value:
        http_status = value["http_status"]
        if type(http_status) is not int or not 100 <= http_status <= 599:
            raise ValueError("failure evidence HTTP status is out of range")
        probe["http_status"] = http_status
    return probe


def serialize_failure_evidence(value: object) -> dict[str, object] | None:
    """Return one canonical safe v1 object, or ``None`` for producer defects."""
    value = _evidence_mapping(value)
    try:
        if not isinstance(value, Mapping) or set(value) != _EVIDENCE_FIELDS:
            raise ValueError("failure evidence must have the closed v1 shape")
        schema_version = value["schema_version"]
        if type(schema_version) is not int or schema_version != FAILURE_EVIDENCE_SCHEMA_VERSION:
            raise ValueError("failure evidence schema version is unsupported")

        phase = value["phase"]
        source = value["source"]
        completeness = value["completeness"]
        if phase not in FAILURE_EVIDENCE_PHASES:
            raise ValueError("failure evidence phase is unsupported")
        if source not in FAILURE_EVIDENCE_SOURCES:
            raise ValueError("failure evidence source is unsupported")
        if completeness not in FAILURE_EVIDENCE_COMPLETENESS:
            raise ValueError("failure evidence completeness is unsupported")

        raw_lines = value["lines"]
        if not isinstance(raw_lines, list) or len(raw_lines) > FAILURE_EVIDENCE_MAX_LINES:
            raise ValueError("failure evidence line count is invalid")
        if any(not isinstance(line, str) for line in raw_lines):
            raise ValueError("failure evidence lines must be strings")
        if any(not line.strip() for line in raw_lines):
            raise ValueError("failure evidence lines must be non-blank")
        lines = _sanitized_serialized_lines(cast(list[str], raw_lines))
        if len(lines) > FAILURE_EVIDENCE_MAX_LINES or any(not line for line in lines):
            raise ValueError("failure evidence normalized lines are invalid")
        encoded_size = len("\n".join(lines).encode("utf-8"))
        if encoded_size > FAILURE_EVIDENCE_MAX_ENCODED_LINE_BYTES:
            raise ValueError("failure evidence lines exceed the byte limit")

        failed_step_id = _optional_identifier(value["failed_step_id"])
        failed_action_id = _optional_identifier(value["failed_action_id"])
        probe = _serialized_probe(value["probe"])
        if completeness == "diagnostic":
            if not lines and probe is None:
                raise ValueError("diagnostic failure evidence needs a line or probe")
        elif lines or probe is not None:
            raise ValueError("non-diagnostic failure evidence cannot carry details")
    except (KeyError, TypeError, ValueError):
        return None

    return {
        "schema_version": FAILURE_EVIDENCE_SCHEMA_VERSION,
        "phase": phase,
        "source": source,
        "completeness": completeness,
        "lines": lines,
        "failed_step_id": failed_step_id,
        "failed_action_id": failed_action_id,
        "probe": probe,
    }


def prepare_error_extra(extra: Mapping[str, object] | None) -> dict[str, object]:
    """Validate the optional evidence member while preserving other context."""
    prepared = dict(extra or {})
    if FAILURE_EVIDENCE_FIELD not in prepared:
        return prepared
    raw_evidence = prepared.pop(FAILURE_EVIDENCE_FIELD)
    evidence = serialize_failure_evidence(raw_evidence)
    if evidence is not None:
        prepared[FAILURE_EVIDENCE_FIELD] = evidence
    return prepared
