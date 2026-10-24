"""Which settings the wire is allowed to carry.

The rule, stated once: **the wire carries intent, not infrastructure.**

A settings key belongs to one of four owners. This module names the keys the
*server* owns -- the ones a desktop client or an external agent must never be
able to supply, because supplying them means the layout is defined in two
codebases at once and an old client can point a new server at a stale path.

`stack_root` is the first entry and the reason this module exists. It was
hardcoded in six Dart call sites and sent to the backend as a parameter, so
the client was telling the server where the server's own managed root lives.

Section 1.4 of the pre-1.0 plan generalises this to every class A and class B
key -- container names, helper binary paths, pinned image references, and the
remaining roots. This module is where those land; the set is expected to grow
and the enforcement shape should not need to change when it does.

Rejection, not silent ignoring, is deliberate. Ignoring an unexpected key
lets a stale client keep working while believing it is in control, which is
the worst failure mode because it is invisible. Rejecting makes version skew
loud, immediate, and attributable to the caller that caused it.
"""

from collections.abc import Mapping
from typing import Any

__all__ = [
    "SERVER_OWNED_SETTING_KEYS",
    "reject_server_owned_keys",
    "resolved_config_snapshot",
    "wire_defaults",
]


# Keys the server resolves for itself. Never accepted from the wire.
#
# Generalised from `stack_root` alone (T-1.1.4) to every class A
# (backend-owned) key (T-1.4.4).
# `host_port` is deliberately absent: it already has exactly one legal
# value, so rejecting it as server-owned would make its own "must be 5432"
# validation permanently unreachable rather than fixing the actual defect
# (the key itself should not exist) -- see T-1.4.1's Discovered work entry.
# `server_identifiers.py` does not exist until T-3.4.1 (Phase 3), so the
# identifier-shaped values below (container_name, caddy_container_name,
# superuser_name, bind_service_name) are literals in each config module's
# `RESOLVED_*_DEFAULTS` rather than resolved from a dedicated module -- see
# T-1.4.3's note in the plan.
SERVER_OWNED_SETTING_KEYS = frozenset(
    {
        # The managed stack root for a service. Resolved from server_paths.
        "stack_root",
        # HTTP gateway (http_config.RESOLVED_HTTP_DEFAULTS).
        "container_name",
        "caddy_image",
        # DNS service (dns_config.RESOLVED_DNS_DEFAULTS).
        "bind_image",
        "bind_service_name",
        # PostgreSQL service (postgres_config.RESOLVED_POSTGRES_DEFAULTS).
        "superuser_name",
        # Web app deploys (app_config.RESOLVED_APP_DEFAULTS).
        "apps_root",
        "railpack_build_helper",
        "railpack_env_file",
        "caddy_stack_root",
        "caddy_container_name",
        "caddy_apply_helper",
        # Setup/onboarding (setup_config.CANONICAL_SETUP_SETTINGS). Only
        # admin_user -- ssh_banner_text was reclassified C in T-1.4.8: the
        # desktop client sends a different value on every onboarding, so
        # the backend's SSH_BANNER_TEXT is a fallback default, not the
        # actual owner of what ships.
        "admin_user",
    }
)


def reject_server_owned_keys(raw_settings: object, error_class: type[Exception]) -> None:
    """Raise `error_class` if `raw_settings` carries a server-owned key.

    Must be called on the settings **as received from the caller**, before
    the canonical defaults are merged in. After the merge every server-owned
    key is present by definition, and a check at that point cannot tell a
    stale caller apart from a default -- which would make the guard vacuous.
    """
    if not isinstance(raw_settings, dict):
        return

    offending = sorted(key for key in raw_settings if key in SERVER_OWNED_SETTING_KEYS)
    if not offending:
        return

    names = ", ".join(offending)
    subject = "These settings are" if len(offending) > 1 else "This setting is"
    raise error_class(
        f"Rejected server-owned settings keys: {names}. {subject} "
        "server-owned: Deploy Dash resolves the value on the server, so a "
        "value sent from here would be ignored or, worse, wrong. Update "
        "Deploy Dash and retry."
    )


def wire_defaults(canonical_settings: Mapping[str, Any]) -> dict[str, Any]:
    """Return `canonical_settings` without the keys the server owns.

    This is the subset a caller is actually entitled to send. Section 1.4
    turns this into a first-class `*_INTENT_DEFAULTS` per config module; until
    then it derives the same set from the existing canonical dictionaries, so
    callers and tests have one definition of "what may go on the wire"
    instead of each maintaining its own copy.
    """
    return {
        key: value
        for key, value in canonical_settings.items()
        if key not in SERVER_OWNED_SETTING_KEYS
    }


def resolved_config_snapshot(
    config: object, resolved_defaults: Mapping[str, object]
) -> dict[str, object]:
    """The class A/B values a parsed config object actually resolved to.

    T-1.4.6: the server now tells the client what it resolved instead of
    the client guessing (or, before T-1.4.4/T-1.4.5, supplying it). Reads
    straight off `resolved_defaults` (each module's `RESOLVED_*_DEFAULTS`)
    so the response can never drift from the classification that decided
    these keys are server-owned in the first place -- add a key there and
    it appears here automatically, with no second list to maintain.
    """
    return {key: getattr(config, key) for key in resolved_defaults}
