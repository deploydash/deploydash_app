import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from orchestrator.app_parts.app_config import parse_app_config
from orchestrator.app_parts.repository_host_key import (
    CONFIRMATION_CODE,
    CONFIRMATION_MARKER,
    parse_repository_host_key_confirmation_lines,
    render_repository_host_key_preflight_command,
)


class TestRepositoryHostKeyPreflight(unittest.TestCase):
    def test_strict_missing_key_emits_confirmation(self):
        with _fake_ssh_tools(scan_fingerprint="SHA256:newfingerprint") as fixture:
            result = fixture.run_policy("strict")

            self.assertEqual(result.returncode, 42)
            payload = parse_repository_host_key_confirmation_lines(result.stderr.splitlines())
            self.assertIsNotNone(payload)
            self.assertEqual(payload["code"], CONFIRMATION_CODE)
            self.assertEqual(payload["reason"], "missing")
            self.assertEqual(payload["scanned_fingerprint"], "SHA256:newfingerprint")
            self.assertFalse(fixture.known_hosts_path.exists())

    def test_accept_new_writes_only_when_no_previous_key_exists(self):
        with _fake_ssh_tools(scan_fingerprint="SHA256:newfingerprint") as fixture:
            result = fixture.run_policy(
                "accept_new",
                accepted_fingerprint="SHA256:newfingerprint",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            known_hosts_text = fixture.known_hosts_path.read_text()
            self.assertIn("|hashed github.com ssh-ed25519 AAAAnew", known_hosts_text)
            self.assertNotIn("-R github.com", fixture.calls_path.read_text())

    def test_accept_new_refuses_existing_changed_key(self):
        with _fake_ssh_tools(
            scan_fingerprint="SHA256:newfingerprint",
            stored_fingerprint="SHA256:oldfingerprint",
        ) as fixture:
            fixture.known_hosts_path.parent.mkdir(parents=True)
            fixture.known_hosts_path.write_text("|old github.com ssh-ed25519 AAAAold\n")

            result = fixture.run_policy(
                "accept_new",
                accepted_fingerprint="SHA256:newfingerprint",
            )

            self.assertEqual(result.returncode, 42)
            payload = parse_repository_host_key_confirmation_lines(result.stderr.splitlines())
            self.assertEqual(payload["reason"], "changed")
            self.assertEqual(payload["previous_fingerprint"], "SHA256:oldfingerprint")
            self.assertIn("AAAAold", fixture.known_hosts_path.read_text())

    def test_replace_confirmed_replaces_existing_changed_key(self):
        with _fake_ssh_tools(
            scan_fingerprint="SHA256:newfingerprint",
            stored_fingerprint="SHA256:oldfingerprint",
        ) as fixture:
            fixture.known_hosts_path.parent.mkdir(parents=True)
            fixture.known_hosts_path.write_text("|old github.com ssh-ed25519 AAAAold\n")

            result = fixture.run_policy(
                "replace_confirmed",
                accepted_fingerprint="SHA256:newfingerprint",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            known_hosts_text = fixture.known_hosts_path.read_text()
            self.assertNotIn("AAAAold", known_hosts_text)
            self.assertIn("AAAAnew", known_hosts_text)
            self.assertIn("ssh-keygen -R github.com", fixture.calls_path.read_text())

    def test_fingerprint_mismatch_does_not_write_known_hosts(self):
        with _fake_ssh_tools(scan_fingerprint="SHA256:newfingerprint") as fixture:
            result = fixture.run_policy(
                "accept_new",
                accepted_fingerprint="SHA256:otherfingerprint",
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("does not match", result.stderr)
            self.assertFalse(fixture.known_hosts_path.exists())

    def test_existing_matching_key_passes_in_strict_mode(self):
        with _fake_ssh_tools(
            scan_fingerprint="SHA256:samefingerprint",
            stored_fingerprint="SHA256:samefingerprint",
        ) as fixture:
            fixture.known_hosts_path.parent.mkdir(parents=True)
            fixture.known_hosts_path.write_text("|old github.com ssh-ed25519 AAAAold\n")

            result = fixture.run_policy("strict")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(CONFIRMATION_MARKER, result.stderr)


class _FakeSshToolsFixture:
    def __init__(self, temp_dir, *, scan_fingerprint, stored_fingerprint=None):
        self.temp_dir = Path(temp_dir)
        self.bin_dir = self.temp_dir / "bin"
        self.calls_path = self.temp_dir / "calls.log"
        self.apps_root = self.temp_dir / "apps"
        self.known_hosts_path = (
            self.apps_root / ".deploydash" / "repository-known-hosts" / "demo-app" / "known_hosts"
        )
        self.scan_fingerprint = scan_fingerprint
        self.stored_fingerprint = stored_fingerprint

    def install(self):
        self.bin_dir.mkdir()
        (self.bin_dir / "ssh-keyscan").write_text(
            textwrap.dedent(
                f"""\
                #!/bin/sh
                echo "ssh-keyscan $@" >> {self.calls_path}
                case "$1" in
                  -H) echo "|hashed github.com ssh-ed25519 AAAAnew" ;;
                  *) echo "github.com ssh-ed25519 AAAAnew" ;;
                esac
                """
            )
        )
        (self.bin_dir / "ssh-keygen").write_text(
            textwrap.dedent(
                f"""\
                #!/bin/sh
                echo "ssh-keygen $@" >> {self.calls_path}
                if [ "$1" = "-F" ]; then
                  if [ -s "$4" ]; then cat "$4"; exit 0; fi
                  exit 1
                fi
                if [ "$1" = "-R" ]; then
                  : > "$4"
                  exit 0
                fi
                input="$(cat)"
                case "$input" in
                  *AAAAold*) echo "256 {self.stored_fingerprint or self.scan_fingerprint} old (ED25519)" ;;
                  *) echo "256 {self.scan_fingerprint} new (ED25519)" ;;
                esac
                """
            )
        )
        os.chmod(self.bin_dir / "ssh-keyscan", 0o755)
        os.chmod(self.bin_dir / "ssh-keygen", 0o755)
        return self

    def run_policy(self, policy, *, accepted_fingerprint=""):
        config = parse_app_config(
            {
                "settings": {
                    "project_slug": "demo-app",
                    "repository_full_name": "acme/demo-app",
                    "repository_host_key_policy": policy,
                    "accepted_repository_host_key_fingerprint": (accepted_fingerprint or None),
                }
            },
            require_domain=True,
        )
        config = config.__class__(
            **{
                **config.__dict__,
                "apps_root": str(self.apps_root),
            }
        )
        command = render_repository_host_key_preflight_command(config)
        env = {
            **os.environ,
            "PATH": f"{self.bin_dir}:{os.environ.get('PATH', '')}",
        }
        return subprocess.run(
            ["sh", "-c", command],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )


class _fake_ssh_tools:
    def __init__(self, *, scan_fingerprint, stored_fingerprint=None):
        self.scan_fingerprint = scan_fingerprint
        self.stored_fingerprint = stored_fingerprint
        self._temp_dir = None
        self.fixture = None

    def __enter__(self):
        self._temp_dir = tempfile.TemporaryDirectory()
        self.fixture = _FakeSshToolsFixture(
            self._temp_dir.name,
            scan_fingerprint=self.scan_fingerprint,
            stored_fingerprint=self.stored_fingerprint,
        ).install()
        return self.fixture

    def __exit__(self, exc_type, exc, tb):
        self._temp_dir.cleanup()


if __name__ == "__main__":
    unittest.main()
