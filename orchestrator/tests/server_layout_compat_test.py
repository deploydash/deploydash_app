"""Frozen compatibility fixtures for every managed-server layout version.

The v1 fixture is historical evidence and must never be edited or deleted.
Future layout versions add a sibling fixture and assertions while retaining
every earlier sample, matching the permanent compatibility promise.
"""

import json
import unittest
from pathlib import Path

from orchestrator import server_paths

_CORPUS = Path(__file__).resolve().parent / "fixtures" / "server-layout"


class TestServerLayoutCompatibilityCorpus(unittest.TestCase):
    def test_layout_one_fixture_remains_frozen(self):
        """The original tree must remain reviewable after later migrations ship."""
        payload = json.loads((_CORPUS / "v1" / "layout.json").read_text(encoding="utf-8"))

        self.assertEqual(
            payload,
            {
                "layout_version": 1,
                "marker": "/opt/deploydash/LAYOUT_VERSION",
                "required_directories": [
                    "/opt/deploydash",
                    "/opt/deploydash/firewall",
                    "/opt/deploydash/stack",
                    "/opt/deploydash/stack/apps",
                    "/opt/deploydash/stack/db",
                    "/opt/deploydash/stack/dns",
                    "/opt/deploydash/stack/http",
                    "/opt/deploydash/stack/mail",
                    "/opt/deploydash/stack/postgres",
                    "/opt/deploydash/stack/proxy",
                    "/opt/deploydash/stack/railpack",
                    "/opt/deploydash/state",
                    "/opt/deploydash/state/scheduler",
                    "/opt/deploydash/state/upgrade-backups",
                    "/var/log/deploydash",
                ],
                "optional_files": [
                    "/opt/deploydash/state/managed-software-ledger.json",
                ],
            },
        )

    def test_layout_two_fixture_adds_only_the_optional_postgres_upgrade_ledger(self):
        """The additive migration must not rename or remove a layout-one path."""
        version_one = json.loads((_CORPUS / "v1" / "layout.json").read_text(encoding="utf-8"))
        version_two = json.loads((_CORPUS / "v2" / "layout.json").read_text(encoding="utf-8"))

        self.assertEqual(version_two["layout_version"], server_paths.LAYOUT_VERSION)
        self.assertEqual(version_two["marker"], version_one["marker"])
        self.assertEqual(
            version_two["required_directories"],
            version_one["required_directories"],
        )
        self.assertEqual(
            version_two["optional_files"],
            [
                *version_one["optional_files"],
                "/opt/deploydash/state/postgres-major-upgrades.json",
            ],
        )

    def test_corpus_versions_are_contiguous_through_the_current_layout(self):
        """A version bump cannot ship without preserving every predecessor."""
        versions = sorted(
            int(path.name.removeprefix("v"))
            for path in _CORPUS.iterdir()
            if path.is_dir() and path.name.startswith("v")
        )

        self.assertEqual(versions, list(range(1, server_paths.LAYOUT_VERSION + 1)))


if __name__ == "__main__":
    unittest.main()
