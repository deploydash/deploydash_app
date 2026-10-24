"""The single owner of the `KEY=value` shell-output protocol.

Managed servers answer in one shape: a remote command emits
`printf "KEY=%s\n"` lines and the backend reads them back. Before T-3.8.6
that read was written fifteen times across nine modules -- four named
helpers, each named differently, and eleven anonymous inline loops. Three
separate automated duplication censuses reported the layer clean, because no
similarity check can find a reimplemented protocol when every copy is spelled
differently and most have no name at all. It was found by reading.

The reason one owner matters here is not tidiness. The parse has real edge
cases -- a value containing `=`, a line with no separator, a `None` output
object, `stdout_lines` absent, a non-string line -- and fifteen
implementations meant fifteen chances to handle them differently. They did:
three sites raised `AttributeError` when the output object had no
`stdout_lines`, eleven raised `ValueError` on a line with no `=`, and one
coerced non-string lines with `str()`, which turns `b"X=1"` into the key
`b'X`. Every one of those is now decided once, here, and pinned by
`tests/shell_output_test.py`.

`as_int` lives here for the same reason: it existed twice, once public and
once private, in the same feature area.
"""

from collections.abc import Callable
from typing import Any

__all__ = ["as_int", "parse_bool_token", "parse_key_values", "split_key_value"]

_SEPARATOR = "="


def split_key_value(line: Any) -> tuple[str, str] | None:
    """Return the `(key, value)` a protocol line carries, or `None`.

    `None` means the line is not part of the protocol -- blank, malformed, or
    not a string. Returning it rather than raising is what lets a caller loop
    over mixed output without guarding every line itself.

    An empty key is **kept**, not dropped. It only arises from a malformed
    line like `"=value"`, and no caller looks one up, but
    `firewall_status_test` pins it and T-3.8.6 is a characterization task:
    the parse this replaces produced it, so this one does too.
    """
    if not isinstance(line, str):
        return None
    if _SEPARATOR not in line:
        return None
    key, value = line.split(_SEPARATOR, 1)
    return key.strip(), value.strip()


def parse_key_values(output: Any, *, prefix: str | None = None) -> dict[str, str]:
    """Return every protocol line in `output` as a dictionary.

    A repeated key takes its last value, matching the shell's own semantics:
    a command that reports progress emits the same key more than once and the
    final line is the outcome.

    `prefix` keeps only the keys that start with it, and keeps the prefix on
    them, because callers match on the full key afterwards.
    """
    values: dict[str, str] = {}
    if output is None:
        return values
    for line in getattr(output, "stdout_lines", None) or []:
        parsed = split_key_value(line)
        if parsed is None:
            continue
        key, value = parsed
        if prefix is not None and not key.startswith(prefix):
            continue
        values[key] = value
    return values


def as_int(value: Any, fallback: int) -> int:
    """Return `value` as an integer, or `fallback` when it is not one.

    `bool` is rejected even though Python treats it as an `int`: a flag
    reaching an integer field means the caller confused it for a count, and
    silently returning 1 would hide that.
    """
    if isinstance(value, bool):
        return fallback
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value.strip())
        except ValueError:
            return fallback
    return fallback


def parse_bool_token(
    value: Any,
    default: bool = False,
    *,
    true_tokens: tuple[str, ...] = ("1", "true", "yes", "on"),
    false_tokens: tuple[str, ...] = ("0", "false", "no", "off"),
    coerce_non_string: bool = False,
    unknown_error: Callable[[], Exception] | None = None,
) -> bool:
    """Coerce a bool-ish token, returning `default` when it is not one.

    The six-way bool-from-string sprawl (T-128 audit, #197) collapses
    here; the token sets diverge both ways, so they stay parameters:

    - engine `dry_run` reads y/n but not on/off;
    - firewall, scheduler, system_settings, postgres, container_status
      read on/off but not y/n;
    - container_status str-coerces non-strings (`coerce_non_string`);
    - postgres treats "" as false (extended `false_tokens`) and raises
      on unknown tokens (`unknown_error`) instead of defaulting.
    """
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    candidate = value
    if coerce_non_string and not isinstance(candidate, str):
        candidate = str(candidate)
    if isinstance(candidate, str):
        text = candidate.strip().lower()
        if text in true_tokens:
            return True
        if text in false_tokens:
            return False
    if unknown_error is not None:
        raise unknown_error()
    return default
