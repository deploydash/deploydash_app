"""Setup proceeds past existing admin keys without any confirmation.

Additive onboarding (I-9): pre-existing `ubuntu` SSH keys are left
untouched, so the old G-4 refusal has no function. With admin keys present
and no confirm flag, the bootstrap steps run exactly as they do for a fresh
server. Later phases fail under this fake host for unrelated reasons (it
cannot complete the managed login phase 5 verifies); what this test is
about is the gate, and the gate's whole observable effect is whether the
bootstrap steps ran.
"""

import json
import unittest
from unittest.mock import patch

from pyinfra import facts

from engine import handle_request

# Absolute, matching `tests.fault_injection`'s precedent: `unittest discover`
# imports these modules flat rather than as a package, so a relative import
# fails there while passing under `-m unittest tests.<module>`.
from tests.pyinfra_fact_fixtures import ubuntu_linux_distribution
from tests.setup_server_test import (
    _FakeHost,
    _FakeSession,
    _with_setup_contract,
)

_KEY_FINGERPRINTS = (
    "SHA256:5qvHvsoZNZdm99pixlAHtvmVym4FAb0w6q9bWMzmE8A",
    "SHA256:ytrvh7mG8pq+VZFyF2MLCsW4sKgYk2uODzFFtGb9AXI",
)


def _host(existing_admin_keys, *, admin_probe_fails=False):
    return _FakeHost(
        {
            facts.server.Kernel: "Linux",
            facts.server.LinuxDistribution: ubuntu_linux_distribution("22.04"),
            facts.server.Arch: "x86_64",
            facts.hardware.Memory: 2048,
            facts.hardware.BlockDevices: {
                "/dev/vda1": {"blocks": "41943040", "mount": "/"},
            },
        },
        existing_admin_keys=existing_admin_keys,
        admin_probe_fails=admin_probe_fails,
    )


def _setup_payload(**overrides):
    payload = {
        "action": "run_workflow",
        "workflow_id": "setup",
        "operation_id": "run",
        "ip": "1.2.3.4",
        "username": "root",
        "password": "secret",
        "parts": ["part1"],
        "dry_run": False,
    }
    payload.update(overrides)
    return json.dumps(_with_setup_contract(payload))


class AdditiveAdminAccessTest(unittest.TestCase):
    @patch("engine.create_runtime_session")
    def test_existing_admin_keys_do_not_stop_setup(
        self,
        mock_create_runtime_session,
    ):
        session = _FakeSession(_host(list(_KEY_FINGERPRINTS)))
        mock_create_runtime_session.return_value = session

        result = json.loads(handle_request(_setup_payload()))

        self.assertNotEqual(
            result.get("code"),
            "ENGINE_ADMIN_TAKEOVER_CONFIRMATION_REQUIRED",
        )
        self.assertNotEqual(session.step_records, [])


if __name__ == "__main__":
    unittest.main()
