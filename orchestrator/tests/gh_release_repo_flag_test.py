"""Contract: every `gh release` in a checkout-less job passes --repo.

`gh` resolves the repository from git remotes when --repo is absent. A job
with no actions/checkout step has no git checkout, so a bare `gh release`
dies with `fatal: not a git repository`. This exact failure killed two tag
runs: the version job's upgrade-lane lookup (v1.1.1 attempt 1) and the
release-checksums SHA256SUMS upload (v1.1.1 attempt 2).

Scope is deliberately narrow: only `gh release` (the subcommand that has
bitten), only jobs without actions/checkout. `gh api repos/...` calls are
absolute by construction and out of scope.
"""

from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS_DIR = REPOSITORY_ROOT / ".github" / "workflows"

_JOB_HEADER = re.compile(r"^  [A-Za-z0-9_-]+:\s*(?:#.*)?$")
_GH_RELEASE = re.compile(r"\bgh\s+release\b")
_CHAIN_SPLIT = re.compile(r"&&|\|\||;")
_REPO_FLAG = re.compile(r"(?:^|\s)(?:--repo|-R)(?:\s|=)")
# A '#' starting a comment: at line start or after whitespace. Never
# matches ${#var} or a '#' inside a word, so parameter expansion and
# quoted literals survive stripping.
_COMMENT_START = re.compile(r"(?:^|\s)#")


def _join_continuations(text: str) -> str:
    return re.sub(r"\\\n\s*", " ", text)


def _job_blocks(workflow_text: str) -> list[tuple[str, str]]:
    """Split workflow text into (job_name, job_body) pairs.

    Job headers are the two-space-indented keys under `jobs:`. Step names
    also sit at deeper indentation, so the header pattern is unambiguous.
    """
    jobs: list[tuple[str, str]] = []
    current: list[str] | None = None
    name = ""
    in_jobs = False
    for line in workflow_text.splitlines():
        if re.match(r"^jobs:\s*(?:#.*)?$", line):
            in_jobs = True
            continue
        if not in_jobs:
            continue
        header = _JOB_HEADER.match(line)
        if header:
            if current is not None:
                jobs.append((name, "\n".join(current)))
            name = line.strip().rstrip(":")
            current = []
        elif current is not None and (line.startswith("    ") or line.strip() == ""):
            current.append(line)
        elif re.match(r"^[A-Za-z]", line):
            if current is not None:
                jobs.append((name, "\n".join(current)))
                current = None
            # The jobs block is over: without this, two-space keys
            # under a later top-level block (e.g. `env:`) would parse
            # as jobs. A comment-only stretch after `jobs:` leaves
            # current as None, so the guard must live inside, not on
            # the branch.
            in_jobs = False
    if current is not None:
        jobs.append((name, "\n".join(current)))
    return jobs


def bare_gh_release_uses(job_body: str) -> list[str]:
    """Return joined command lines where `gh release` lacks --repo."""
    offenders: list[str] = []
    for line in _join_continuations(job_body).splitlines():
        code = _COMMENT_START.split(line, maxsplit=1)[0]
        if not _GH_RELEASE.search(code):
            continue
        for segment in _CHAIN_SPLIT.split(code):
            if _GH_RELEASE.search(segment) and not _REPO_FLAG.search(segment):
                offenders.append(segment.strip())
    return offenders


def scan_workflow(path: Path) -> list[str]:
    """Return human-readable violations for one workflow file."""
    findings: list[str] = []
    for job_name, body in _job_blocks(path.read_text(encoding="utf-8")):
        if "actions/checkout" in body:
            continue
        for use in bare_gh_release_uses(body):
            findings.append(f"{path.name} :: {job_name} :: {use}")
    return findings


def scan_tree(workflows_dir: Path) -> list[str]:
    """Scan every workflow file regardless of YAML extension."""
    offenders: list[str] = []
    for extension in ("*.yml", "*.yaml"):
        for path in sorted(workflows_dir.glob(extension)):
            offenders.extend(scan_workflow(path))
    return offenders


class GhReleaseRepoFlagTest(unittest.TestCase):
    def test_tree_workflows_have_no_bare_gh_release(self) -> None:
        self.assertEqual(scan_tree(WORKFLOWS_DIR), [])

    def test_flags_bare_gh_release_in_checkout_less_job(self) -> None:
        body = 'run: |\n  gh release upload "v1" SHA256SUMS --clobber\n'
        self.assertEqual(len(bare_gh_release_uses(body)), 1)

    def test_accepts_repo_flag_across_continuations(self) -> None:
        body = (
            "run: |\n"
            '  gh release download "v1" \\\n'
            "    --repo deploydash/deploydash_app \\\n"
            "    --dir out\n"
        )
        self.assertEqual(bare_gh_release_uses(body), [])

    def test_checkout_jobs_are_out_of_scope(self) -> None:
        text = (
            "jobs:\n"
            "  build:\n"
            "    steps:\n"
            "      - uses: actions/checkout@v5\n"
            "      - run: gh release view v1\n"
        )
        jobs = _job_blocks(text)
        self.assertEqual(len(jobs), 1)
        self.assertIn("actions/checkout", jobs[0][1])

    def test_top_level_keys_after_jobs_are_not_jobs(self) -> None:
        text = "jobs:\n  build:\n    steps:\n      - run: echo hi\nenv:\n  OUTER:\n    INNER: 1\n"
        self.assertEqual([name for name, _ in _job_blocks(text)], ["build"])

    def test_comment_only_jobs_opener_does_not_swallow_later_blocks(
        self,
    ) -> None:
        text = (
            "jobs:\n"
            "  # no jobs defined yet\n"
            "\n"
            "env:\n"
            "  OUTER:\n"
            "    INNER: 1\n"
        )
        self.assertEqual(_job_blocks(text), [])

    def test_commented_gh_release_is_not_flagged(self) -> None:
        body = (
            "run: |\n"
            "  # gh release view v1\n"
            "  echo done # gh release view v1\n"
            '  echo "length ${#x}"\n'
        )
        self.assertEqual(bare_gh_release_uses(body), [])

    def test_scan_tree_covers_both_yaml_extensions(self) -> None:
        workflow = "jobs:\n  build:\n    steps:\n      - run: gh release view v1\n"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "a.yml").write_text(workflow, encoding="utf-8")
            (root / "b.yaml").write_text(workflow, encoding="utf-8")
            offenders = scan_tree(root)
        self.assertEqual(len(offenders), 2)
        self.assertTrue(any("a.yml" in hit for hit in offenders))
        self.assertTrue(any("b.yaml" in hit for hit in offenders))


if __name__ == "__main__":
    unittest.main()
