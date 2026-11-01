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
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS_DIR = REPOSITORY_ROOT / ".github" / "workflows"

_JOB_HEADER = re.compile(r"^  [A-Za-z0-9_-]+:\s*(?:#.*)?$")
_GH_RELEASE = re.compile(r"\bgh\s+release\b")
_CHAIN_SPLIT = re.compile(r"&&|\|\||;")
_REPO_FLAG = re.compile(r"(?:^|\s)(?:--repo|-R)(?:\s|=)")


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
        elif current is not None and re.match(r"^[A-Za-z]", line):
            jobs.append((name, "\n".join(current)))
            current = None
    if current is not None:
        jobs.append((name, "\n".join(current)))
    return jobs


def bare_gh_release_uses(job_body: str) -> list[str]:
    """Return joined command lines where `gh release` lacks --repo."""
    offenders: list[str] = []
    for line in _join_continuations(job_body).splitlines():
        if not _GH_RELEASE.search(line):
            continue
        for segment in _CHAIN_SPLIT.split(line):
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


class GhReleaseRepoFlagTest(unittest.TestCase):
    def test_tree_workflows_have_no_bare_gh_release(self) -> None:
        offenders: list[str] = []
        for path in sorted(WORKFLOWS_DIR.glob("*.yml")):
            offenders.extend(scan_workflow(path))
        self.assertEqual(offenders, [])

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


if __name__ == "__main__":
    unittest.main()
