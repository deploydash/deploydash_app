"""Architecture invariant: Railpack release assets remain pinned as one contract.

Measurement: the version, release assets, digest, installer, and server-side
version guard must agree on the same pinned Railpack release.
"""

import unittest

from orchestrator import railpack_contract


class TestRailpackContract(unittest.TestCase):
    def test_contract_exports_pinned_railpack_assets(self):
        self.assertEqual(railpack_contract.RAILPACK_VERSION, "v0.29.0")
        self.assertEqual(railpack_contract.RAILPACK_VERSION_NUMBER, "0.29.0")
        self.assertEqual(
            railpack_contract.RAILPACK_FRONTEND_IMAGE,
            "ghcr.io/railwayapp/railpack-frontend:v0.29.0",
        )
        self.assertEqual(
            railpack_contract.RAILPACK_FRONTEND_IMAGE_DIGEST,
            "sha256:683f0eba680f38d009290100ae3ceded667a1536687ce25696fe9f4e91abfd2b",
        )
        self.assertTrue(
            railpack_contract.RAILPACK_LINUX_AMD64_ASSET.startswith(
                "railpack-v0.29.0-",
            )
        )
        self.assertEqual(
            railpack_contract.RAILPACK_LINUX_AMD64_SHA256,
            "25cad96e4d2e9c9a3d47bf7abc46b0abb8e46360e8f13e0c24d5ea279933d247",
        )

    def test_install_command_replaces_missing_or_stale_railpack(self):
        command = railpack_contract.render_install_pinned_railpack_command()

        self.assertIn('DEPLOYDASH_RAILPACK_VERSION=""', command)
        self.assertIn("command -v railpack >/dev/null", command)
        self.assertIn(
            '[ "${DEPLOYDASH_RAILPACK_VERSION}" != "0.29.0" ]',
            command,
        )
        self.assertIn(
            "https://github.com/railwayapp/railpack/releases/download/v0.29.0",
            command,
        )
        self.assertIn("sha256sum -c -", command)
        self.assertIn("install -m 0755", command)

    def test_version_guard_explains_server_tooling_remediation(self):
        command = railpack_contract.render_railpack_version_guard_command()

        self.assertIn('[ "${DEPLOYDASH_RAILPACK_VERSION}" = "0.29.0" ]', command)
        self.assertIn("Deploy Dash requires Railpack 0.29.0", command)
        self.assertIn("Open Server Management and run setup again", command)
        self.assertIn("then redeploy", command)


if __name__ == "__main__":
    unittest.main()
