"""Connect-time compatibility check for the on-disk server layout.

`server_paths` defines where things live; this module decides whether a
particular server's layout is one this release may operate on at all.

The rule it exists to enforce: **never operate on a layout written by a
newer client.** A newer Deploy Dash may have moved, split, or renamed
directories whose meaning this release does not know. Writing into that
layout with old assumptions is how a working customer server becomes a
half-migrated one, and there is no undo.

Classification is deliberately split from probing. `classify_layout` is a
pure function over two facts, so all of its branches are testable without a
server; `read_layout_state` is the only part that needs a host.
"""

import shlex
from collections.abc import Callable
from dataclasses import dataclass

from . import server_paths
from .runtime_ops import Host, ShellCommandOutput, run_shell_command

__all__ = [
    "LayoutOutcome",
    "LayoutState",
    "classify_layout",
    "classify_state",
    "migrate_layout",
    "read_layout_state",
    "verify_layout_after_setup",
]

# The pre-layout-1 root. Present only on servers provisioned before the
# marker existed, and the only reason this literal survives outside
# server_paths: it is history, not a path this release ever writes to.
_LEGACY_STACK_ROOT = "/opt/docker-stack"


@dataclass(frozen=True)
class LayoutState:
    """What a single probe observed on the server."""

    marker_text: str | None
    legacy_root_present: bool
    readable: bool = True


@dataclass(frozen=True)
class LayoutOutcome:
    """Whether this release may proceed against the observed layout."""

    ok: bool
    code: str | None = None
    message: str = ""
    version: int | None = None
    unprovisioned: bool = False


def _parse_version(marker_text: str | None) -> int | None:
    """Return the integer version in `marker_text`, or None if it is not one."""
    if marker_text is None:
        return None
    text = marker_text.strip()
    # Explicitly not int(text): that accepts "+1", " 1 ", and unicode digits,
    # and rejecting a malformed marker is safer than guessing at it.
    if not text.isdigit():
        return None
    return int(text)


def classify_layout(marker_text: str | None, legacy_root_present: bool) -> LayoutOutcome:
    """Decide whether to proceed, given the marker and the legacy root."""
    version = _parse_version(marker_text)

    if version is None:
        if marker_text is None:
            if not legacy_root_present:
                # Nothing of ours on the machine. A normal first onboarding.
                return LayoutOutcome(ok=True, unprovisioned=True)
            return LayoutOutcome(
                ok=False,
                code="ENGINE_LAYOUT_UNVERSIONED",
                message=(
                    "This server was set up by an older version of Deploy "
                    "Dash, before Deploy Dash recorded which layout it used. "
                    "It cannot be managed by this version yet."
                ),
            )
        # A marker that exists but cannot be read as a version is NOT an
        # unprovisioned server, whether or not the legacy root is present.
        # Something wrote that file; proceeding would mean provisioning over
        # a machine whose state we demonstrably do not understand.
        return LayoutOutcome(
            ok=False,
            code="ENGINE_LAYOUT_UNVERSIONED",
            message=(
                "This server's layout marker could not be understood, so "
                "Deploy Dash cannot tell how it is set up. Stopping rather "
                "than guessing."
            ),
        )

    if version > server_paths.LAYOUT_VERSION:
        return LayoutOutcome(
            ok=False,
            code="ENGINE_LAYOUT_TOO_NEW",
            message=(
                "This server was set up by a newer version of Deploy Dash. "
                "Update Deploy Dash to manage it."
            ),
            version=version,
        )

    if version < server_paths.LAYOUT_VERSION:
        return LayoutOutcome(
            ok=False,
            code="ENGINE_LAYOUT_MIGRATION_REQUIRED",
            message=(
                "This server uses an earlier Deploy Dash layout and needs to "
                "be upgraded before it can be managed."
            ),
            version=version,
        )

    return LayoutOutcome(ok=True, version=version)


def classify_state(state: LayoutState) -> LayoutOutcome:
    """Classify a `LayoutState`, including the unreadable case."""
    if not state.readable:
        return LayoutOutcome(
            ok=False,
            code="ENGINE_LAYOUT_UNREADABLE",
            message=(
                "Deploy Dash could not check how this server is set up. "
                "Check the connection and try again."
            ),
        )
    return classify_layout(
        marker_text=state.marker_text,
        legacy_root_present=state.legacy_root_present,
    )


def read_layout_state(
    host: Host, *, emit_output: Callable[[ShellCommandOutput], None] | None = None
) -> LayoutState:
    """Probe `host` once for the layout marker and the legacy root.

    One round trip rather than two: separate probes could observe the machine
    in two different states if provisioning is running concurrently, and the
    pair of facts is only meaningful taken together.
    """
    marker = server_paths.LAYOUT_VERSION_FILE
    command = (
        "set -eu; "
        f"if [ -f {marker} ]; then "
        f"printf 'marker=%s\\n' \"$(cat {marker} 2>/dev/null | head -n 1)\"; "
        "else printf 'marker=\\n'; fi; "
        f"if [ -d {_LEGACY_STACK_ROOT} ]; then printf 'legacy=1\\n'; "
        "else printf 'legacy=0\\n'; fi"
    )
    result = run_shell_command(host, command, timeout=20, sudo=True, emit_output=emit_output)
    if not result["ok"]:
        # Deliberately NOT reported as "no marker": treating an unreachable
        # or permission-denied probe as an unprovisioned server would let the
        # caller provision straight over a live one.
        return LayoutState(marker_text=None, legacy_root_present=False, readable=False)

    marker_text = None
    legacy_root_present = False
    for line in getattr(result["output"], "stdout_lines", None) or []:
        text = str(line).strip()
        if text.startswith("marker="):
            value = text[len("marker=") :].strip()
            marker_text = value or None
        elif text.startswith("legacy="):
            legacy_root_present = text[len("legacy=") :].strip() == "1"

    return LayoutState(marker_text=marker_text, legacy_root_present=legacy_root_present)


def migrate_layout(
    host: Host,
    state: LayoutState,
    *,
    emit_output: Callable[[ShellCommandOutput], None] | None = None,
) -> LayoutOutcome:
    """Advance the one reviewed layout transition and fail closed otherwise.

    Layout 2 only declares the additive PostgreSQL retained-volume ledger.
    An absent ledger already means an empty ledger, so migration has no data
    to move; it atomically advances the marker after comparing the live value.
    The comparison makes concurrent clients idempotent while refusing to
    overwrite an unexpected marker.
    """
    outcome = classify_state(state)
    if outcome.code != "ENGINE_LAYOUT_MIGRATION_REQUIRED":
        return outcome
    if outcome.version != 1 or server_paths.LAYOUT_VERSION != 2:
        return outcome

    marker = shlex.quote(server_paths.LAYOUT_VERSION_FILE)
    source_version = f"'{outcome.version}'"
    target_version = f"'{server_paths.LAYOUT_VERSION}'"
    command = (
        "set -eu; "
        f"marker={marker}; "
        'current="$(cat "$marker" 2>/dev/null || true)"; '
        f'if [ "$current" = {target_version} ]; then :; '
        f'elif [ "$current" = {source_version} ]; then '
        'tmp="${marker}.migrate.$$"; '
        "trap 'rm -f \"$tmp\"' EXIT HUP INT TERM; "
        f"printf '%s\\n' {target_version} > \"$tmp\"; "
        'chmod 0644 "$tmp"; chown root:root "$tmp"; '
        'mv -f "$tmp" "$marker"; '
        "trap - EXIT HUP INT TERM; "
        "else printf 'Unexpected layout marker: %s\\n' \"$current\" >&2; exit 1; fi"
    )
    result = run_shell_command(
        host,
        command,
        timeout=20,
        sudo=True,
        emit_output=emit_output,
    )
    if not result["ok"]:
        return LayoutOutcome(
            ok=False,
            code="ENGINE_LAYOUT_MIGRATION_REQUIRED",
            message=(
                "This server uses an earlier Deploy Dash layout, and its "
                "layout marker could not be upgraded automatically. No "
                "server data was moved."
            ),
            version=outcome.version,
        )

    return classify_state(read_layout_state(host, emit_output=emit_output))


def verify_layout_after_setup(
    host: Host, *, emit_output: Callable[[ShellCommandOutput], None] | None = None
) -> LayoutOutcome:
    """Confirm provisioning actually left a readable, current marker.

    Setup *writing* the marker and the server *having* it are different
    claims, and only the second one matters to every later connect. A run
    that silently failed to write it would look like a success now and like
    an unversioned pre-layout-1 server forever afterwards -- the one state
    T-1.1.6 refuses to operate on. Checking here converts that into an
    immediate, fixable setup failure.
    """
    state = read_layout_state(host, emit_output=emit_output)
    outcome = classify_state(state)
    if outcome.ok and outcome.unprovisioned:
        return LayoutOutcome(
            ok=False,
            code="ENGINE_LAYOUT_UNVERSIONED",
            message=(
                "Server setup finished but did not record how the server is "
                "set up, so Deploy Dash would not be able to manage it "
                "later. Run setup again."
            ),
        )
    return outcome
