import json
import unittest
from pathlib import Path

from orchestrator.managed_software import parse_software_ledger
from orchestrator.postgres_backup import POSTGRES_BACKUP_MANIFEST_FORMAT_VERSION

# NEVER DELETE THIS TEST FILE, and never modify the assertions below against
# an *existing* fixture file. T-1.3.3: the frozen corpus under
# orchestrator/tests/fixtures/artifact-compat/v1/ is the only evidence this
# build can ever open format-version-1 artifacts, because those artifacts
# cannot be reconstructed later -- the build that could produce a "fresh" v1
# sample will not exist forever. When format 2 ships, add a new
# orchestrator/tests/fixtures/artifact-compat/v2/ directory and new test
# methods; do not touch the v1 fixtures or their assertions.
#
# The corpus lives beside the suites that consume it so every checkout of
# this repository can run these tests with no other checkout present.

_FIXTURE_ROOT = Path(__file__).resolve().parent / "fixtures" / "artifact-compat" / "v1"


class TestArtifactFormatCompatV1(unittest.TestCase):
    def test_postgres_backup_manifest_v1_parses_with_expected_values(self):
        manifest_path = _FIXTURE_ROOT / "postgres-backup-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

        self.assertEqual(
            manifest,
            {
                "format_version": 1,
                "database_name": "dd_fixture_app",
                "created_at": "2026-01-01T00:00:00Z",
                "size_bytes": 2048,
            },
        )
        # The corpus exists to prove *this build* can still read format 1,
        # not just that the frozen file happens to look right -- assert the
        # live constant still equals what the fixture was frozen at.
        self.assertEqual(manifest["format_version"], POSTGRES_BACKUP_MANIFEST_FORMAT_VERSION)

    def test_managed_software_ledger_v1_parses_with_expected_values(self):
        ledger_path = _FIXTURE_ROOT / "managed-software-ledger.json"
        raw = ledger_path.read_text(encoding="utf-8")

        parsed = parse_software_ledger(raw)

        self.assertEqual(parsed["format_version"], 1)
        self.assertEqual(
            parsed["components"]["walg_backup_tool"],
            {
                "component_id": "walg_backup_tool",
                "last_action": "update",
                "status": "success",
                "installed_version": "v3.0.7",
                "previous_version": "v3.0.6",
                "target_version": "v3.0.7",
                "backup_path": "/opt/deploydash/backups/walg/v3.0.6",
                "backup_dir": "",
                "changed_at": "2026-01-01T00:00:00Z",
            },
        )


if __name__ == "__main__":
    unittest.main()
