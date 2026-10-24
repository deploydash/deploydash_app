import subprocess

from .addressing import format_host_port, normalize_host


def host_key_mismatch_message(*, known_hosts_file):
    if known_hosts_file:
        return (
            "This server's identity looks different from what Deploy Dash "
            "saved before. Review the old and new fingerprints, then "
            "confirm the change if you expected it."
        )
    return (
        "This server's identity looks different from what Deploy Dash "
        "saved before. Review the fingerprint details, then confirm the "
        "change if you expected it."
    )


def is_host_key_mismatch_error(error_message):
    lowered = error_message.lower()
    return (
        ("host key" in lowered and "does not match" in lowered)
        or "remote host identification has changed" in lowered
        or "ssh host key error" in lowered
    )


def read_known_host_fingerprint(*, host, port, known_hosts_file):
    normalized_host = normalize_host(host)
    if not known_hosts_file or normalized_host is None:
        return None

    entries = [normalized_host]
    if port is not None:
        entries.append(format_host_port(normalized_host, port))

    for entry in entries:
        try:
            found = subprocess.run(
                ["ssh-keygen", "-F", entry, "-f", known_hosts_file],
                check=False,
                capture_output=True,
                text=True,
            )
        except Exception:
            continue
        if found.returncode != 0 or not found.stdout.strip():
            continue
        fingerprint = _fingerprint_for_key_material(found.stdout)
        if fingerprint:
            return fingerprint
    return None


def scan_remote_host_fingerprint(*, host, port):
    normalized_host = normalize_host(host)
    if normalized_host is None:
        return None
    try:
        keyscan = subprocess.run(
            [
                "ssh-keyscan",
                "-T",
                "5",
                "-p",
                str(port or 22),
                normalized_host,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except Exception:
        return None
    if keyscan.returncode != 0 or not (keyscan.stdout or "").strip():
        return None
    return _fingerprint_for_key_material(keyscan.stdout)


def build_host_key_mismatch_payload(*, host, port, known_hosts_file):
    return {
        "host": normalize_host(host) or host,
        "port": port,
        "known_hosts_file": known_hosts_file,
        "old_fingerprint": read_known_host_fingerprint(
            host=host,
            port=port,
            known_hosts_file=known_hosts_file,
        ),
        "new_fingerprint": scan_remote_host_fingerprint(host=host, port=port),
    }


def _fingerprint_for_key_material(key_material):
    try:
        fingerprint = subprocess.run(
            ["ssh-keygen", "-lf", "-", "-E", "sha256"],
            input=key_material,
            check=False,
            capture_output=True,
            text=True,
        )
    except Exception:
        return None
    if fingerprint.returncode != 0:
        return None
    line = (fingerprint.stdout or "").strip().splitlines()
    if not line:
        return None
    parts = line[0].split()
    if len(parts) < 2:
        return None
    return parts[1]
