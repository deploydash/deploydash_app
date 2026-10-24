import shlex

from .engine_firewall_ops import _normalize_locked_ports
from .engine_runtime_common import _normalized_optional_string


def resolve_managed_connection(raw_data, ip, default_port):
    if not isinstance(raw_data, dict):
        return None

    managed = None
    params = raw_data.get("params")
    if isinstance(params, dict):
        managed = params.get("managed_connection")
    if managed is None:
        managed = raw_data.get("managed_connection")
    if not isinstance(managed, dict):
        return None

    username = _normalized_optional_string(
        managed.get("username") or managed.get("ssh_user"),
    )
    private_key = _normalized_optional_string(managed.get("private_key"))
    key_path = _normalized_optional_string(managed.get("key_path"))
    if not username or (not private_key and not key_path):
        return None

    raw_port = managed.get("port")
    managed_port = raw_port if isinstance(raw_port, int) else default_port
    return {
        "ip": ip,
        "username": username,
        "password": None,
        "key_path": key_path,
        "private_key": private_key,
        "port": managed_port,
    }


def build_onboarding_firewall_config(ssh_port):
    # locked_ports runs through the single normalizer, so the always-on
    # web ports travel with the SSH port instead of being silently dropped
    # the way a literal [ssh_port] was: fresh servers came up web-dark.
    # The rollback deadline must exceed the post-stage verify budget
    # (attempts plus backoff in setup_postflight) plus commit time, or a slow
    # verify would outlast the safety timer and the commit would find nothing
    # to commit. Three minutes still bounds the lockout if the client dies.
    return {
        "strict_mode": True,
        "allow_postgres": False,
        "postgres_source_cidrs": [],
        "allow_dns": False,
        "allow_smtp": False,
        "allow_mail_receive": False,
        "rollback_timeout_seconds": 180,
        "locked_ports": _normalize_locked_ports([ssh_port]),
        "custom_rules": [],
        "stage_token": None,
    }


def build_managed_connection_result(connection):
    return {
        "username": connection["username"],
        "port": connection["port"],
    }


# --- Existing admin account: display infrastructure, not a gate -------------
#
# Setup is additive-only (I-9): pre-existing `ubuntu` SSH keys are left
# untouched, so nothing here refuses or confirms anything. The probe below
# reports what access already exists so the review screen can show it, and
# the parser gives that answer a shape. Both are pure so the branches can be
# enumerated without a server. Owner decision, 2026-09-10: the G-4 refusal,
# its resolver, and its confirmation check were removed together with the
# wipe they guarded.


def existing_admin_account_probe_command(admin_user):
    """A read-only command reporting the SSH access [admin_user] already has.

    Runs before the user has consented to anything, so it must not be able to
    change the server: no `rm`, no `adduser`, no ownership change. Speaks the
    `KEY=value` house protocol, so `shell_output.parse_key_values` reads it.
    """

    quoted_admin_user = shlex.quote(admin_user)
    return (
        "set -eu; "
        f"ADMIN_USER={quoted_admin_user}; "
        "EXISTS=0; KEY_COUNT=0; HAS_HOME=0; FINGERPRINTS=''; "
        'if id -u "$ADMIN_USER" >/dev/null 2>&1; then '
        "EXISTS=1; "
        'TARGET_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"; '
        'if [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ]; then HAS_HOME=1; fi; '
        'AUTHORIZED="${TARGET_HOME}/.ssh/authorized_keys"; '
        'if [ -f "$AUTHORIZED" ]; then '
        "KEY_COUNT=\"$(grep -c -E '^[[:space:]]*[^#[:space:]]' "
        '"$AUTHORIZED" || true)"; '
        # Fingerprints, not the keys: the same thing the host-key modal shows,
        # and a fixed format that cannot smuggle anything into the payload.
        'FINGERPRINTS="$(ssh-keygen -lf "$AUTHORIZED" -E sha256 2>/dev/null '
        '| awk \'{printf "%s|", $2}\' || true)"; '
        "fi; "
        "fi; "
        "printf 'exists=%s\\n' \"$EXISTS\"; "
        "printf 'authorized_key_count=%s\\n' \"$KEY_COUNT\"; "
        "printf 'has_home=%s\\n' \"$HAS_HOME\"; "
        "printf 'authorized_key_fingerprints=%s\\n' \"$FINGERPRINTS\""
    )


def unknown_admin_account():
    """The account state to assume when the probe could not be read.

    One owner for "we do not know", because there are two ways to arrive at
    it -- the command failing, and its answer not parsing -- and they must
    reach the same shape. `exists` is true and the count is `None`, so the
    review screen says "unknown" instead of "none": defaulting the other way
    would report no keys because a command did not return.
    """

    return {
        "exists": True,
        "authorized_key_count": None,
        "has_home": False,
        "authorized_key_fingerprints": [],
    }


def parse_existing_admin_account(values):
    """Read the probe's `KEY=value` answer into the shape the review needs.

    A missing count parses as `None`, never `0`. Absent keys and an answer
    that did not arrive are different facts, and only one of them means
    "no keys" on the review screen.
    """

    if not isinstance(values, dict):
        return unknown_admin_account()
    exists = str(values.get("exists", "")).strip() == "1"
    raw_count = values.get("authorized_key_count")
    try:
        key_count = int(str(raw_count).strip())
    except (TypeError, ValueError):
        key_count = None
    fingerprints = [
        fingerprint
        for fingerprint in str(
            values.get("authorized_key_fingerprints") or "",
        ).split("|")
        if fingerprint.strip()
    ]
    return {
        "exists": exists,
        "authorized_key_count": 0 if not exists and key_count is None else key_count,
        "has_home": str(values.get("has_home", "")).strip() == "1",
        "authorized_key_fingerprints": fingerprints,
    }
