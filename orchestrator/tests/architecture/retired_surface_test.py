"""Architecture invariant: a deleted surface stays deleted.

T-1.5.2 removed five wire actions. Two callers survived — one inside a string
constant in `runtime_bundle.py`, one inside a CI workflow — and stayed
invisible for weeks, because nothing enumerated the callers of a removed
surface. T-1.5.8 found them by hand. A census finds that once; this check is
what makes it standing, and it is why the registry is a file a deleting task
appends to rather than a list inside this module.

**Where the misses hid is where this scans.** Both survivors were inside
string literals, so a check that only looked at code would have found
neither. This reads the raw text of every tracked source, YAML and shell file,
which is the only way to see inside a heredoc or a workflow `run:` block.

**Tests that prove a removal are not violations.** `assertNotIn("milvus", ...)`
names the retired id on purpose. Recognising negative assertions rather than
exempting those files one by one keeps the exemption list for real survivors —
an exemption list that fills up with false positives is one nobody reads.
"""

from __future__ import annotations

import json
import pathlib
import re
import subprocess
import unittest

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_REGISTRY = pathlib.Path(__file__).with_name("retired-surfaces.json")

_SCANNED_SUFFIXES = {".py", ".dart", ".yml", ".yaml", ".sh", ".json", ".ts", ".js"}

# Generated or vendored trees. `runtime_bundle` is build output; the registry
# itself names every retired identifier by definition.
_SKIPPED_PARTS = {"runtime_bundle", "published_repo", "node_modules"}
_SKIPPED_FILES = {
    # The registry names every retired identifier by definition.
    "orchestrator/tests/architecture/retired-surfaces.json",
    # This module's own vacuity fixtures spell the patterns it searches for.
    # They are the definition of a violation, not one -- and they only become
    # visible after commit because `git ls-files` is deliberately the scope.
    "orchestrator/tests/architecture/retired_surface_test.py",
}

# A line asserting the surface is absent, in either language's idiom.
_NEGATIVE_ASSERTION = re.compile(
    r"assertNotIn|assertFalse|assertIsNone|assertNotEqual"
    r"|isNot\b|isNull\b|isFalse\b|isEmpty\b|findsNothing"
    r"|not\s+in\b|!=|\bno\b|\bnever\b|\bremoved\b|\bretired\b",
    re.IGNORECASE,
)


def _tracked_files() -> list[pathlib.Path]:
    """Scan the owning repository's tracked sources so new files cannot evade the guard."""
    listing = subprocess.run(
        ["git", "ls-files"],
        cwd=_REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()
    files = []
    for entry in listing:
        if not entry or entry in _SKIPPED_FILES:
            continue
        path = pathlib.Path(entry)
        if path.suffix not in _SCANNED_SUFFIXES:
            continue
        if _SKIPPED_PARTS.intersection(path.parts):
            continue
        files.append(path)
    return files


def _load_registry() -> dict:
    """Load the application-owned retired names that every tracked source must respect."""
    return json.loads(_REGISTRY.read_text(encoding="utf-8"))


def _value_patterns(key: str, name: str) -> list[re.Pattern[str]]:
    """Match a retired value in the serialization shapes shipped by the application."""
    quoted = re.escape(name)
    return [
        # "action": "echo" / 'action': 'echo' / "action" = "echo"
        re.compile(r"""["']""" + re.escape(key) + r"""["']\s*[:=]\s*["']""" + quoted + r"""["']"""),
        # action: echo (YAML, unquoted)
        re.compile(r"(?<![\w-])" + re.escape(key) + r"\s*:\s*" + quoted + r"(?![\w-])"),
    ]


class RetiredSurfaceTest(unittest.TestCase):
    """Keep every retired public wire identifier absent from the tracked app tree."""

    def setUp(self) -> None:
        """Use the same tracked source census and registry for every invariant assertion."""
        self.registry = _load_registry()
        self.files = _tracked_files()

    def test_the_scan_reaches_the_whole_tracked_tree(self) -> None:
        """A scan that quietly stops seeing files reports clean for the wrong reason."""
        self.assertGreater(
            len(self.files),
            500,
            "the retired-surface scan is seeing far fewer files than the "
            "repository contains; check _SCANNED_SUFFIXES and _SKIPPED_PARTS",
        )
        suffixes = {path.suffix for path in self.files}
        for required in (".py", ".dart", ".yml"):
            self.assertIn(required, suffixes, f"nothing with {required} was scanned")

    def test_no_retired_surface_is_used_anywhere(self) -> None:
        """A raw-text census catches retired values even inside strings and workflows."""
        violations: list[str] = []
        for key, entries in (
            ("action", self.registry["wire_actions"]),
            ("workflow_id", self.registry["workflow_ids"]),
        ):
            for entry in entries:
                name = entry["name"]
                exemptions = entry.get("exemptions", {})
                patterns = _value_patterns(key, name)
                for path in self.files:
                    relative = path.as_posix()
                    if relative in exemptions:
                        continue
                    try:
                        text = (_REPO_ROOT / path).read_text(
                            encoding="utf-8",
                            errors="ignore",
                        )
                    except OSError:  # pragma: no cover - unreadable file
                        continue
                    if name not in text:
                        continue
                    for line_number, line in enumerate(text.splitlines(), start=1):
                        if not any(pattern.search(line) for pattern in patterns):
                            continue
                        if _NEGATIVE_ASSERTION.search(line):
                            continue
                        violations.append(
                            f"{relative}:{line_number} uses retired "
                            f"{key}={name!r} (retired by {entry['retired_by']}; "
                            f"use {entry['replacement']})"
                        )
        self.assertEqual(
            violations,
            [],
            "A retired surface is back. Replace it, or -- if it genuinely "
            "cannot go yet -- add a reasoned exemption to "
            "orchestrator/tests/architecture/retired-surfaces.json naming "
            "the task that will remove it:\n" + "\n".join(sorted(violations)),
        )

    def test_every_exemption_is_reasoned_and_still_needed(self) -> None:
        """An exemption outliving its reason is a rule quietly abandoned."""
        for entries in self.registry["wire_actions"], self.registry["workflow_ids"]:
            for entry in entries:
                for relative, reason in entry.get("exemptions", {}).items():
                    with self.subTest(surface=entry["name"], file=relative):
                        self.assertGreater(
                            len(reason),
                            60,
                            "an exemption needs a reason, not a label",
                        )
                        path = _REPO_ROOT / relative
                        self.assertTrue(path.exists(), f"{relative} no longer exists")
                        self.assertIn(
                            entry["name"],
                            path.read_text(encoding="utf-8", errors="ignore"),
                            f"{relative} no longer mentions {entry['name']!r}; "
                            "drop the exemption in the same commit",
                        )

    def test_every_registry_entry_states_what_replaced_it(self) -> None:
        """A retired name with no replacement sends the reader nowhere."""
        for entries in self.registry["wire_actions"], self.registry["workflow_ids"]:
            for entry in entries:
                with self.subTest(surface=entry["name"]):
                    self.assertTrue(entry["name"])
                    self.assertTrue(entry["retired_by"])
                    self.assertTrue(entry["replacement"])

    def test_the_check_can_see_a_violation(self) -> None:
        """A green run means something only if a known-bad line is matched."""
        patterns = _value_patterns("action", "setup_server")
        for bad in (
            '{"action": "setup_server"}',
            "payload = {'action': 'setup_server'}",
            "  action: setup_server",
        ):
            self.assertTrue(
                any(pattern.search(bad) for pattern in patterns),
                f"the scan missed {bad!r}",
            )
        for good in (
            '{"action": "run_workflow", "workflow_id": "setup"}',
            "def setup_server(ctx):",
            "result = setup_server(ip=ip)",
        ):
            self.assertFalse(
                any(pattern.search(good) for pattern in patterns),
                f"the scan false-positived on {good!r}",
            )
        self.assertIsNotNone(_NEGATIVE_ASSERTION.search('assertNotIn("milvus", registry)'))
        self.assertIsNone(_NEGATIVE_ASSERTION.search('payload = {"workflow_id": "milvus"}'))


if __name__ == "__main__":
    unittest.main()
