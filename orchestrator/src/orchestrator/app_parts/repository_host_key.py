import base64
import json
import shlex

CONFIRMATION_CODE = "APP_REPOSITORY_HOST_KEY_CONFIRMATION_REQUIRED"
CONFIRMATION_MARKER = "__DEPLOYDASH_REPOSITORY_HOST_KEY_CONFIRMATION__="
STRICT_POLICY = "strict"
ACCEPT_NEW_POLICY = "accept_new"
REPLACE_CONFIRMED_POLICY = "replace_confirmed"
ALLOWED_POLICIES = (
    STRICT_POLICY,
    ACCEPT_NEW_POLICY,
    REPLACE_CONFIRMED_POLICY,
)


def render_repository_host_key_preflight_command(config):
    args = [
        config.repo_host,
        "22",
        config.repository_known_hosts_path,
        config.repository_host_key_policy,
        config.accepted_repository_host_key_fingerprint or "",
    ]
    quoted_args = " ".join(shlex.quote(arg) for arg in args)
    return f"python3 - {quoted_args} <<'PY'\n{_REMOTE_PREFLIGHT_SCRIPT}\nPY"


def parse_repository_host_key_confirmation_lines(lines):
    for raw_line in lines or []:
        line = str(raw_line).strip()
        if not line.startswith(CONFIRMATION_MARKER):
            continue
        encoded = line[len(CONFIRMATION_MARKER) :].strip()
        try:
            decoded = base64.b64decode(encoded, validate=True).decode("utf-8")
            payload = json.loads(decoded)
        except Exception:
            continue
        if not isinstance(payload, dict):
            continue
        if payload.get("code") != CONFIRMATION_CODE:
            continue
        return payload
    return None


def parse_repository_host_key_confirmation_output(output):
    stdout_lines = list(getattr(output, "stdout_lines", None) or [])
    stderr_lines = list(getattr(output, "stderr_lines", None) or [])
    return parse_repository_host_key_confirmation_lines(
        [*stderr_lines, *stdout_lines],
    )


_REMOTE_PREFLIGHT_SCRIPT = r"""
import base64
import json
import os
import pathlib
import subprocess
import sys

CONFIRMATION_CODE = "APP_REPOSITORY_HOST_KEY_CONFIRMATION_REQUIRED"
CONFIRMATION_MARKER = "__DEPLOYDASH_REPOSITORY_HOST_KEY_CONFIRMATION__="
ALLOWED_POLICIES = {"strict", "accept_new", "replace_confirmed"}


def run(args, *, input_text=None):
    return subprocess.run(
        args,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def fingerprints_for_lines(lines):
    fingerprints = []
    for line in lines:
        candidate = line.strip()
        if not candidate or candidate.startswith("#"):
            continue
        result = run(["ssh-keygen", "-lf", "-", "-E", "sha256"], input_text=candidate + "\n")
        if result.returncode != 0:
            continue
        parts = result.stdout.strip().split()
        if len(parts) >= 2 and parts[1].startswith("SHA256:"):
            fingerprints.append(parts[1])
    return sorted(set(fingerprints))


def stored_key_lines(host, known_hosts_path):
    if not known_hosts_path.exists() or known_hosts_path.stat().st_size == 0:
        return []
    result = run(["ssh-keygen", "-F", host, "-f", str(known_hosts_path)])
    if result.returncode != 0:
        return []
    return [
        line
        for line in result.stdout.splitlines()
        if line.strip() and not line.startswith("#")
    ]


def scan_key_lines(host):
    result = run(["ssh-keyscan", "-T", "5", "-t", "ed25519,ecdsa,rsa", host])
    lines = [
        line
        for line in result.stdout.splitlines()
        if line.strip() and not line.startswith("#")
    ]
    if result.returncode != 0 and not lines:
        print(
            f"Could not scan SSH host key for repository host {host}.",
            file=sys.stderr,
        )
        sys.exit(1)
    if not lines:
        print(
            f"No SSH host key was returned for repository host {host}.",
            file=sys.stderr,
        )
        sys.exit(1)
    return lines


def emit_confirmation(*, host, port, reason, previous_fingerprint, scanned_fingerprint, known_hosts_path):
    payload = {
        "code": CONFIRMATION_CODE,
        "repository_host_key_confirmation_required": True,
        "host": host,
        "port": port,
        "reason": reason,
        "previous_fingerprint": previous_fingerprint or "",
        "scanned_fingerprint": scanned_fingerprint or "",
        "known_hosts_path": str(known_hosts_path),
    }
    encoded = base64.b64encode(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8"),
    ).decode("ascii")
    print(f"{CONFIRMATION_MARKER}{encoded}", file=sys.stderr)
    sys.exit(42)


def write_scanned_keys(host, known_hosts_path, *, replace):
    known_hosts_path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(known_hosts_path.parent, 0o700)
    known_hosts_path.touch(mode=0o600, exist_ok=True)
    if replace:
        run(["ssh-keygen", "-R", host, "-f", str(known_hosts_path)])
    result = run(["ssh-keyscan", "-H", "-T", "5", "-t", "ed25519,ecdsa,rsa", host])
    lines = [
        line
        for line in result.stdout.splitlines()
        if line.strip() and not line.startswith("#")
    ]
    if not lines:
        print(
            f"Could not write SSH host key for repository host {host}.",
            file=sys.stderr,
        )
        sys.exit(1)
    with known_hosts_path.open("a", encoding="utf-8") as handle:
        for line in lines:
            handle.write(line + "\n")
    os.chmod(known_hosts_path, 0o600)


host, port, known_hosts, policy, accepted_fingerprint = sys.argv[1:6]
if policy not in ALLOWED_POLICIES:
    print(f"Unsupported repository host-key policy: {policy}", file=sys.stderr)
    sys.exit(1)

known_hosts_path = pathlib.Path(known_hosts)
scan_lines = scan_key_lines(host)
scan_fingerprints = fingerprints_for_lines(scan_lines)
if not scan_fingerprints:
    print(
        f"Could not derive SSH host-key fingerprint for repository host {host}.",
        file=sys.stderr,
    )
    sys.exit(1)

stored_lines = stored_key_lines(host, known_hosts_path)
stored_fingerprints = fingerprints_for_lines(stored_lines)
has_match = bool(set(scan_fingerprints).intersection(stored_fingerprints))

if has_match:
    sys.exit(0)

reason = "missing" if not stored_fingerprints else "changed"
previous_fingerprint = stored_fingerprints[0] if stored_fingerprints else ""
scanned_fingerprint = scan_fingerprints[0]

if policy == "strict":
    emit_confirmation(
        host=host,
        port=port,
        reason=reason,
        previous_fingerprint=previous_fingerprint,
        scanned_fingerprint=scanned_fingerprint,
        known_hosts_path=known_hosts_path,
    )

if accepted_fingerprint not in scan_fingerprints:
    print(
        "Accepted repository SSH fingerprint does not match the current scan.",
        file=sys.stderr,
    )
    sys.exit(1)

if policy == "accept_new" and reason != "missing":
    emit_confirmation(
        host=host,
        port=port,
        reason=reason,
        previous_fingerprint=previous_fingerprint,
        scanned_fingerprint=scanned_fingerprint,
        known_hosts_path=known_hosts_path,
    )

if policy == "replace_confirmed" and reason != "changed":
    emit_confirmation(
        host=host,
        port=port,
        reason=reason,
        previous_fingerprint=previous_fingerprint,
        scanned_fingerprint=scanned_fingerprint,
        known_hosts_path=known_hosts_path,
    )

write_scanned_keys(host, known_hosts_path, replace=policy == "replace_confirmed")
sys.exit(0)
""".strip()
