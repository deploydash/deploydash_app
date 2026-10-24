"""Architecture invariant: project scoping never matches names by prefix.

Measurement: every ``LIKE`` in ``postgres_runtime_parts`` whose statement
also references ``project_prefix``. ``LIKE 'dd_<project>_%'`` matches other
projects two ways -- ``_`` is a single-character wildcard, and prefixes nest
(``dd_shop_`` is a prefix of ``dd_shop_api_``) -- so deleting one project can
drop another project's databases and roles (#80). All enumeration must join
the ownership registry on ``project_slug`` instead.

Fixed-literal ``LIKE`` filters (``pg_temp_%``) carry no project prefix
and are not flagged; everything else fails the build.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

_RUNTIME_PARTS = (
    Path(__file__).resolve().parents[2] / "src" / "orchestrator" / "postgres_runtime_parts"
)

_LIKE_RE = re.compile(r"\bLIKE\b", re.IGNORECASE)


def _prefix_like_sites(source_path):
    """Return the 1-based line numbers whose LIKE matches a project prefix."""
    lines = source_path.read_text(encoding="utf-8").splitlines()
    sites = []
    for index, line in enumerate(lines):
        if not _LIKE_RE.search(line):
            continue
        window = "\n".join(lines[index : index + 3])
        if "project_prefix" in window:
            sites.append(index + 1)
    return sites


class TestPostgresPrefixLikeGuard(unittest.TestCase):
    def test_no_project_prefix_like_matching(self):
        """No project-prefix LIKE survives; the registry owns scoping."""
        sites = {}
        for source_path in sorted(_RUNTIME_PARTS.glob("*.py")):
            found = _prefix_like_sites(source_path)
            if found:
                sites[source_path.name] = found
        self.assertEqual(
            sites,
            {},
            "Project-prefix LIKE matching is back; join the registry instead (#80).",
        )
