"""Release-pipeline token scopes stay sufficient for the APIs each job calls.

Two rules GitHub enforces that YAML alone never checks:

1. A ``GITHUB_TOKEN`` with only ``contents: read`` cannot see draft
   releases: ``gh release download``/``view`` answers ``release not
   found`` even when every asset is present. Any job that touches a
   possibly-draft release (every ``gh release`` verb except ``list``,
   which is draft-blind by design) must grant ``contents: write``.
   Proven by v1.1.1 attempt 3: the macOS slim gate failed its draft
   DMG download in one second while the published-tag proof stayed
   green.
2. Reading workflow runs/jobs through ``gh api .../actions/...``
   needs ``actions: read``; ``contents: read`` alone answers 403.

For reusable callees both halves are checked: the callee must declare
top-level ``contents: write`` (a callee may not exceed its caller's
grant, so the caller job must grant it too).
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"

# The tag pipeline and nothing else. probe-*.yml workflows are manual,
# pinned to published tags (drafts never involved), and stay out.
PIPELINE = (
    "release.yml",
    "desktop-direct-builds.yml",
    "desktop-snap-build.yml",
    "qa-public-windows-slim.yml",
    "qa-public-macos-slim.yml",
)

_JOB = re.compile(r"^  ([A-Za-z0-9_./-]+):\s*$", re.MULTILINE)
_PERMISSIONS = re.compile(r"^(\s*)permissions:\s*(?:\{\})?\s*$")
_SCOPE = re.compile(r"^\s+(contents|actions):\s*(\S+)\s*$")
_USES_LOCAL = re.compile(r"uses:\s*\./\.github/workflows/(\S+\.yml)")
_GH_RELEASE = re.compile(r"\bgh\s+release\s+(\S+)")
_GH_ACTIONS_API = re.compile(r"\bgh\s+api\s+[\"']?[^\"'\s]*/actions/")
_CHAIN_SPLIT = re.compile(r"&&|\|\||;")

# Verbs that resolve a release object (draft or published). ``list`` is
# deliberately absent: it only ever sees published releases, which is
# exactly what the version job wants from its unprivileged token.
DRAFT_VERBS = {"download", "view", "upload", "create", "edit", "delete"}


def _scopes(block: str) -> dict[str, str]:
    """Parse the first permissions mapping inside a text block."""
    scopes: dict[str, str] = {}
    in_permissions = False
    base_indent = 0
    for line in block.splitlines():
        match = _PERMISSIONS.match(line)
        if match:
            in_permissions = "{}" not in line
            base_indent = len(match.group(1))
            continue
        if in_permissions:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            scope = _SCOPE.match(line)
            if scope and len(line) - len(line.lstrip()) > base_indent:
                scopes[scope.group(1)] = scope.group(2)
            else:
                in_permissions = False
    return scopes


def _top_level_scopes(text: str) -> dict[str, str]:
    head, _, _ = text.partition("\njobs:")
    return _scopes(head)


def _job_blocks(text: str) -> list[tuple[str, str]]:
    names: list[str] = []
    starts: list[int] = []
    for match in _JOB.finditer(text):
        # Only top-level job keys sit exactly two spaces deep and only
        # mean jobs after the `jobs:` mapping starts.
        if match.start() < text.find("\njobs:"):
            continue
        names.append(match.group(1))
        starts.append(match.start())
    starts.append(len(text))
    return [
        (name, text[start : starts[index + 1]])
        for index, (name, start) in enumerate(zip(names, starts[:-1], strict=True))
    ]


def _draft_verbs(block: str) -> set[str]:
    verbs: set[str] = set()
    for line in block.splitlines():
        stripped = line.split("#", 1)[0]
        for segment in _CHAIN_SPLIT.split(stripped):
            for verb in _GH_RELEASE.findall(segment):
                if verb in DRAFT_VERBS:
                    verbs.add(verb)
    return verbs


def _needs_actions_api(block: str) -> bool:
    return any(
        _GH_ACTIONS_API.search(segment)
        for line in block.splitlines()
        for segment in _CHAIN_SPLIT.split(line.split("#", 1)[0])
    )


def _effective(job_scopes: dict[str, str], top_scopes: dict[str, str], scope: str) -> str:
    return job_scopes.get(scope, top_scopes.get(scope, "none"))


class ReleaseTokenScopeTest(unittest.TestCase):
    def test_draft_release_readers_grant_contents_write(self) -> None:
        offenders: list[str] = []
        for name in PIPELINE:
            text = (WORKFLOWS / name).read_text()
            top = _top_level_scopes(text)
            for job, block in _job_blocks(text):
                verbs = _draft_verbs(block)
                if not verbs:
                    continue
                if _effective(_scopes(block), top, "contents") != "write":
                    offenders.append(
                        f"{name} :: {job} runs gh release {sorted(verbs)} without contents: write"
                    )
        self.assertEqual(offenders, [])

    def test_reusable_callees_touching_drafts_declare_write(self) -> None:
        offenders: list[str] = []
        for name in PIPELINE:
            if name == "release.yml":
                continue
            text = (WORKFLOWS / name).read_text()
            if "workflow_call" not in text:
                continue
            verbs = _draft_verbs(text)
            if not verbs:
                continue
            if _top_level_scopes(text).get("contents") != "write":
                offenders.append(
                    f"{name} runs gh release {sorted(verbs)} without top-level contents: write"
                )
        self.assertEqual(offenders, [])

    def test_callers_grant_what_their_callee_needs(self) -> None:
        needs_write = {
            name
            for name in PIPELINE
            if name != "release.yml" and _draft_verbs((WORKFLOWS / name).read_text())
        }
        text = (WORKFLOWS / "release.yml").read_text()
        top = _top_level_scopes(text)
        offenders: list[str] = []
        for job, block in _job_blocks(text):
            for callee in _USES_LOCAL.findall(block):
                if callee in needs_write and _effective(_scopes(block), top, "contents") != "write":
                    offenders.append(
                        f"release.yml :: {job} calls {callee} (draft"
                        " release access) without contents: write"
                    )
        self.assertEqual(offenders, [])

    def test_actions_api_readers_grant_actions_read(self) -> None:
        offenders: list[str] = []
        for name in PIPELINE:
            text = (WORKFLOWS / name).read_text()
            top = _top_level_scopes(text)
            for job, block in _job_blocks(text):
                if not _needs_actions_api(block):
                    continue
                if _effective(_scopes(block), top, "actions") != "read":
                    offenders.append(f"{name} :: {job} calls the actions API without actions: read")
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
