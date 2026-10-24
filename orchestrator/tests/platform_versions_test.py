"""Guard tests for `orchestrator.platform_versions` (T-1.4.2, discipline D2).

Written before the module existed. Two things are guarded:

1. The module exposes the pinned values with the literal, real-world value
   each pin actually is -- stated here directly, not derived from the module
   under test, per the plan's anti-vacuity rule.
2. None of those literal values appear anywhere else in `orchestrator/src`
   except this module and `railpack_contract.py` -- the actual defect this
   task exists to close. Before this task, `WALG_VERSION` and
   `POSTGRES_IMAGE_TAGS_BY_MAJOR` each had three independent copies
   (`managed_software.py`, `postgres_backup.py`, `engine_postgres_ops.py`),
   and `caddy_image`/`bind_image`/the Docker package version prefixes each
   had one copy outside any of the "five places" the plan's own intro named.
"""

import pathlib
import unittest

from orchestrator import platform_versions

_SRC_ROOT = pathlib.Path(__file__).resolve().parents[1] / "src" / "orchestrator"
_ALLOWED_FILES = {
    _SRC_ROOT / "platform_versions.py",
    _SRC_ROOT / "railpack_contract.py",
}


def _iter_source_files():
    for path in sorted(_SRC_ROOT.rglob("*.py")):
        if path in _ALLOWED_FILES:
            continue
        yield path


class TestPinnedValues(unittest.TestCase):
    def test_caddy_image_is_the_pinned_release_tag(self):
        self.assertEqual(platform_versions.CADDY_IMAGE, "caddy:2.11.2-alpine")

    def test_bind_image_is_the_pinned_release_tag(self):
        self.assertEqual(
            platform_versions.BIND_IMAGE,
            "internetsystemsconsortium/bind9:9.20",
        )

    def test_postgres_image_tags_cover_every_supported_major(self):
        self.assertEqual(
            platform_versions.POSTGRES_IMAGE_TAGS_BY_MAJOR,
            {
                "16": "16.14-bookworm",
                "17": "17.10-bookworm",
                "18": "18.4-bookworm",
            },
        )

    def test_walg_version_is_the_pinned_release_tag(self):
        self.assertEqual(platform_versions.WALG_VERSION, "v3.0.8")

    def test_docker_package_version_prefixes_cover_every_pinned_package(self):
        self.assertEqual(
            platform_versions.DOCKER_PACKAGE_VERSION_PREFIXES,
            {
                "docker-ce": "5:29.6.0-1",
                "docker-ce-cli": "5:29.6.0-1",
                "containerd.io": "2.2.5-1",
                "docker-compose-plugin": "5.1.4-1",
            },
        )

    def test_railpack_pins_are_reexported_not_duplicated(self):
        from orchestrator.railpack_contract import (
            RAILPACK_FRONTEND_IMAGE,
            RAILPACK_VERSION,
        )

        self.assertIs(platform_versions.RAILPACK_VERSION, RAILPACK_VERSION)
        self.assertIs(
            platform_versions.RAILPACK_FRONTEND_IMAGE,
            RAILPACK_FRONTEND_IMAGE,
        )


class TestNoPinLeaksOutsidePlatformVersions(unittest.TestCase):
    """The actual guard: every pinned literal, only in the two allowed files."""

    def _assert_literal_confined(self, literal, source_description):
        offending = []
        for path in _iter_source_files():
            text = path.read_text(encoding="utf-8")
            if literal in text:
                offending.append(str(path.relative_to(_SRC_ROOT)))
        self.assertEqual(
            offending,
            [],
            f"{source_description} ({literal!r}) must live only in "
            "platform_versions.py (or railpack_contract.py for Railpack's "
            f"own pins), but also appears in: {offending}",
        )

    def test_caddy_image_confined(self):
        self._assert_literal_confined(platform_versions.CADDY_IMAGE, "CADDY_IMAGE")

    def test_bind_image_confined(self):
        self._assert_literal_confined(platform_versions.BIND_IMAGE, "BIND_IMAGE")

    def test_walg_version_confined(self):
        self._assert_literal_confined(platform_versions.WALG_VERSION, "WALG_VERSION")

    def test_postgres_image_tags_confined(self):
        for major, tag in platform_versions.POSTGRES_IMAGE_TAGS_BY_MAJOR.items():
            self._assert_literal_confined(tag, f"POSTGRES_IMAGE_TAGS_BY_MAJOR[{major!r}]")

    def test_docker_package_version_prefixes_confined(self):
        for name, version in platform_versions.DOCKER_PACKAGE_VERSION_PREFIXES.items():
            self._assert_literal_confined(version, f"DOCKER_PACKAGE_VERSION_PREFIXES[{name!r}]")


if __name__ == "__main__":
    unittest.main()
