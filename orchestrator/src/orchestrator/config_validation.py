"""One implementation of the checks every `*_config.py` parser performs.

Five workflow parsers -- app, DNS, HTTP, PostgreSQL and setup -- each grew its
own `_required_string`, `_required_bool`, `_select_settings` and settings-key
validator: **19 copies of four helpers**, differing only in which exception
class they raise. Adding a sixth workflow meant writing a fifth
`_required_string`. That is the shape `AGENTS.md` describes as hiding best,
because the copies were spelled identically and no similarity tool flagged
them as a problem worth acting on.

Every function here takes `error_class` as an argument, exactly as
`settings_ownership.reject_server_owned_keys(raw, error_class)` already does.
That is what lets one implementation serve five modules that must raise five
different error types, and it is the pattern to copy rather than re-deriving.

**Two things are deliberately not normalised away.**

`required_string`'s `strip` keyword exists because setup's SSH banner text is
the one field of the nineteen whose trailing whitespace is meaningful. It was
a real behavioural difference before this collapse and it stays one.

`validate_setting_keys` and `validate_unknown_setting_keys` remain **two
functions**, not one with an empty `required`. T-1.4.10 separated exactly
these two meanings -- parser-complete settings for DNS/HTTP/setup, versus
unknown-key rejection for app/PostgreSQL whose required intent is enforced
per operation by `params_schema` before a handler runs. `AGENTS.md` says it
directly: *`_validate_setting_keys` must never quietly regain the two
incompatible meanings it had before T-1.4.10*. Collapsing them here, however
tidy, is that regression.
"""

from __future__ import annotations

from collections.abc import Callable, Collection, Mapping
from typing import Any

from . import settings_ownership


def required_string(
    value: Any,
    field_name: str,
    error_class: type[Exception],
    *,
    strip: bool = True,
) -> str:
    """Return [value] as a non-empty string, raising [error_class] otherwise.

    `strip=False` keeps the value verbatim once it has been proven non-blank.
    Setup's SSH banner is the only caller that needs it: the banner is
    displayed as written, so its trailing newline is content.
    """
    if not isinstance(value, str) or not value.strip():
        raise error_class(f"{field_name} must be a non-empty string.")
    if strip:
        return value.strip()
    return value


def required_bool(
    value: Any,
    field_name: str,
    error_class: type[Exception],
) -> bool:
    """Return [value] when it is a real `bool`, raising [error_class] otherwise.

    `isinstance(value, bool)` rather than truthiness: `1` and `"yes"` are how
    a client that has not read the contract sends a boolean, and accepting
    them would mean the wire shape drifts silently.
    """
    if isinstance(value, bool):
        return value
    raise error_class(f"{field_name} must be a boolean.")


def validate_setting_keys(
    settings: Mapping[str, Any],
    *,
    allowed: Collection[str],
    required: Collection[str],
    error_class: type[Exception],
) -> None:
    """Require a complete settings object: every key present, no key unknown.

    For the three parsers whose contract is a complete settings shape. See
    [validate_unknown_setting_keys] for the other two, and this module's
    docstring for why they are not the same function.
    """
    missing = [key for key in required if key not in settings]
    if missing:
        raise error_class(f"Missing required settings keys: {', '.join(missing)}")

    extra = sorted(key for key in settings if key not in allowed)
    if extra:
        raise error_class(f"Unknown settings keys: {', '.join(extra)}")


def validate_unknown_setting_keys(
    settings: Mapping[str, Any],
    *,
    allowed: Collection[str],
    error_class: type[Exception],
) -> None:
    """Reject unknown keys without requiring any particular key to be present.

    For app and PostgreSQL, whose required intent is operation-specific and
    enforced by `params_schema` before the handler runs.
    """
    extra = sorted(key for key in settings if key not in allowed)
    if extra:
        raise error_class(f"Unknown settings keys: {', '.join(extra)}")


def select_settings(
    raw_data: Any,
    *,
    canonical: Mapping[str, Any],
    error_class: type[Exception],
    trusted: bool = False,
    merge: bool = True,
    normalize: Callable[[dict[str, Any]], dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Resolve the caller's settings, rejecting anything the server owns.

    The four steps every parser shares: absent or non-dict request means the
    canonical defaults; a non-dict `settings` is a client error; and the
    server-owned keys are rejected **against the caller's raw settings**,
    before any merge, because after the merge every server-owned key is
    present anyway and the check would pass vacuously.

    The differences that remain are named rather than hidden:

    - `normalize` runs before the rejection check. App uses it to accept two
      superseded key spellings, which must happen first or the rename would
      look like a server-owned key arriving from the wire.
    - `trusted` skips the rejection. HTTP alone re-parses settings it built
      itself, where "the caller may not set this" does not apply.
    - `merge=False` returns the caller's keys without the canonical defaults
      underneath. Setup needs it: merging would fill in every key and its
      contract is that a caller sends a complete object, so the missing-key
      check below would never fire again.
    """
    if not isinstance(raw_data, dict):
        return dict(canonical)

    candidate = raw_data.get("settings")
    if candidate is None:
        return dict(canonical)

    if not isinstance(candidate, dict):
        raise error_class("settings must be an object.")

    if normalize is not None:
        candidate = normalize(dict(candidate))

    if not trusted:
        settings_ownership.reject_server_owned_keys(candidate, error_class)

    if not merge:
        return dict(candidate)

    settings = dict(canonical)
    settings.update(candidate)
    return settings
