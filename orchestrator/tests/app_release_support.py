"""Shared fixtures and base case for the app release flow tests.

Extracted by T-3.6.2 from `app_release_flow_test.py` (3,497 lines, 50 tests in
one class). The four files that replace it split along the same seams as the
production code: the versioned deploy, the rollback, the readiness probes, and
the helpers each of those calls.

The name deliberately does not end in `_test.py`, so `unittest discover` does
not collect it as a test module -- a file that looked like a test but held no
tests would be the quiet way to lose coverage in a split like this.
"""

from __future__ import annotations

# Re-exported for the four test modules: they are used inside test bodies,
# which this module cannot see, so ruff would otherwise remove them.
import base64  # noqa: F401
import copy  # noqa: F401
import unittest
from dataclasses import replace  # noqa: F401
from types import SimpleNamespace

from orchestrator.app_parts import parse_app_config
from orchestrator.app_release_runtime import (
    append_or_replace_release,
    empty_release_manifest,
    release_entry_from_config,
)
from tests.engine_context_fixtures import build_test_context


class _FakeOutput:
    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


class _FakeHost:
    def __init__(self, status=True, output=None):
        self.status = status
        self.output = output or _FakeOutput()
        self.calls = []

    def run_shell_command(self, command, _timeout=0, _sudo=False, **kwargs):
        self.calls.append(
            {
                "command": command,
                "timeout": _timeout,
                "sudo": _sudo,
                "kwargs": kwargs,
            }
        )
        return self.status, self.output


def _app_config():
    return parse_app_config(
        {
            "settings": {
                "project_slug": "remix-blog",
                "repository_full_name": "acme/remix-blog",
                "primary_domain": "blog.example.com",
                "branch": "main",
                "app_port": 3000,
                "runtime_env": {
                    "NODE_ENV": "production",
                },
                "workers": [
                    {
                        "id": "queue",
                        "name": "Queue worker",
                        "start_cmd": "python worker.py",
                        "cpu_limit": 0.5,
                        "memory_mb": 256,
                        "disk_mb": 1024,
                        "enabled": True,
                    }
                ],
            }
        },
        require_domain=True,
    )


def _release_entry(
    app_config,
    *,
    release_id: str,
    commit_sha: str,
    status: str,
    deployment_kind: str = "deploy",
    image_name: str | None = None,
):
    entry = release_entry_from_config(
        app_config,
        release_id=release_id,
        commit_sha=commit_sha,
        status=status,
        deployment_kind=deployment_kind,
        image_name=image_name or app_config.release_image_name(release_id),
    )
    release_date = (
        f"{release_id[0:4]}-{release_id[4:6]}-{release_id[6:8]}"
        if len(release_id) >= 8
        else "2026-05-31"
    )
    entry["created_at"] = f"{release_date}T12:00:00Z"
    if status == "live":
        entry["live_at"] = "2026-05-31T12:01:00Z"
    return entry


def _error_result(code, msg, *, stage=None, details=None, extra=None):
    payload = {
        "status": "error",
        "code": code,
        "msg": msg,
        "stage": stage,
    }
    if details is not None:
        payload["details"] = details
    if extra is not None:
        payload["extra"] = extra
    return payload


class AppReleaseFlowTestCase(unittest.TestCase):
    """The context, config and manifest builders every release test needs."""

    def setUp(self):
        self.app_config = _app_config()
        self.session = SimpleNamespace(host=SimpleNamespace())
        self.ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *args, **kwargs: None,
            emit_shell_output_lines=lambda *args, **kwargs: None,
            command_error_details=lambda output: "remote command failed",
        )

    def _live_manifest(self):
        previous_live = _release_entry(
            self.app_config,
            release_id="20260531t120000z-abcdef123456",
            commit_sha="abcdef1234567890",
            status="live",
        )
        manifest = append_or_replace_release(
            empty_release_manifest(),
            previous_live,
        )
        return manifest, previous_live

    def _manifest_with_retained_release(self):
        manifest, previous_live = self._live_manifest()
        retained_release = _release_entry(
            self.app_config,
            release_id="20260530t113000z-fedcba987654",
            commit_sha="fedcba9876543210",
            status="retained",
        )
        manifest = append_or_replace_release(manifest, retained_release)
        return manifest, previous_live, retained_release
