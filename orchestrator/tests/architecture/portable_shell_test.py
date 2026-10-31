"""Architecture invariant: scripts a non-Linux runner executes stay portable.

Measurement: every shell script under the repository, **and every inline
`run:` block in a workflow that has a macOS or Windows job**, is scanned for
GNU-only constructs. `grep -P`/`-oP` is the one that has actually bitten: it
is a GNU extension, macOS ships BSD grep, and `desktop-release-scaffolds.yml`
runs `validate_release_scaffolds.sh` on a macOS runner.

The workflow half was added by T-2.5.10. Scanning only `*.sh` left the gap
that matters just as much: a `run: |` block is a script a runner executes,
it simply does not live in a file with that extension, and the three
workflows with non-Linux jobs contain 79 such blocks between them.

Failure: the offending file, line number, and construct are named. This check
exists because T-1.6.2 introduced three `grep -oP` calls on 2026-08-30 and
nothing noticed until a macOS runner failed with `grep: invalid option -- P`
two days later -- and it stayed invisible locally because this workstation's
grep is `ugrep`, which supports `-P`.
"""

from __future__ import annotations

import pathlib
import re
import unittest

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
# Workflows live at the repository root alongside the orchestrator/ui trees.
_WORKFLOWS_DIR = _REPO_ROOT / ".github" / "workflows"

# Constructs that work on GNU userland and fail on BSD (macOS).
#
# Quoted spans are stripped before matching. Without that, a line such as
#   grep -q 'Out-File -FilePath $BuildLog' file
# reports a false positive on the -FilePath inside the *search pattern*, and a
# guard that cries wolf is a guard somebody disables.
_QUOTED = re.compile(r"'[^']*'|\"[^\"]*\"")

_GNU_ONLY = (
    (
        re.compile(r"\bgrep\s+(?:-[a-zA-Z]*\s+)*-[a-zA-Z]*P"),
        "grep -P is a GNU extension; BSD grep rejects it",
    ),
    (
        re.compile(r"\bsed\s+(?:-[a-zA-Z]+\s+)*-i(?:\s+-|\s*$)"),
        "sed -i without a backup suffix differs on BSD",
    ),
    (re.compile(r"(?:^|[\s|;&(])rg\s"), "rg (ripgrep) is not guaranteed on a runner; use grep"),
)

_SKIP_DIRS = {".git", "node_modules", "build", "local", "site-packages"}

# A workflow only matters here if it actually schedules a non-Linux job.
# Three forms all count: a literal `runs-on: macos-latest`, a build matrix
# whose `os:` list names one, and a matrix whose `runner:` entries name
# one (`desktop-direct-builds.yml` routes macOS/Windows legs through
# `${{ matrix.runner }}`). `desktop-release-scaffolds.yml` uses the matrix
# form for the very job that runs validate_release_scaffolds.sh on macOS, so
# matching only `runs-on:` would miss the case this check exists for.
_NON_LINUX_RUNNER = re.compile(
    r"runs-on:[^\n]*(?:macos|windows)|os:\s*\[[^\]]*(?:macos|windows)|runner:\s*\S*(?:macos|windows)",
    re.IGNORECASE,
)

# Named, not counted. A rename or a runner change should fail loudly here
# rather than quietly shrinking the set this check scans.
_EXPECTED_NON_LINUX_WORKFLOWS = frozenset(
    {
        "desktop-direct-builds.yml",
        "desktop-release-scaffolds.yml",
        # Dispatch-only hosted-Windows slim-QA probe (permanent diagnostic).
        "probe-public-windows-slim.yml",
        # Public caller for the private Windows slim suite.
        "qa-public-windows-slim.yml",
        # Dispatch-only hosted-macOS AX/self-SSH probe (permanent diagnostic).
        "probe-public-macos-ax.yml",
        # Dispatch-only Swift-over-SSH launch proof (permanent diagnostic).
        "probe-mac-swift-launch.yml",
    }
)


def _shell_scripts() -> list[pathlib.Path]:
    found = []
    for path in _REPO_ROOT.rglob("*.sh"):
        if any(part in _SKIP_DIRS for part in path.parts):
            continue
        found.append(path)
    return sorted(found)


def _non_linux_workflows() -> list[pathlib.Path]:
    """Return workflows that schedule at least one macOS or Windows job."""
    found = []
    for path in sorted(_WORKFLOWS_DIR.glob("*.yml")):
        if _NON_LINUX_RUNNER.search(path.read_text(errors="ignore")):
            found.append(path)
    return found


def _scan(path: pathlib.Path, base: pathlib.Path | None = None) -> list[str]:
    """Return `file:line: reason` for every GNU-only construct in `path`."""
    offenders = []
    display_base = base if base is not None else _REPO_ROOT
    for number, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        scannable = _QUOTED.sub("''", line)
        for pattern, why in _GNU_ONLY:
            if pattern.search(scannable):
                offenders.append(f"{path.relative_to(display_base)}:{number}: {why}")
    return offenders


class PortableShellTest(unittest.TestCase):
    def test_no_gnu_only_constructs_in_shell_scripts(self) -> None:
        offenders = []
        for script in _shell_scripts():
            offenders.extend(_scan(script))
        self.assertEqual(
            offenders,
            [],
            "GNU-only shell constructs found in scripts that may run on macOS:\n"
            + "\n".join(offenders),
        )

    def test_no_gnu_only_constructs_in_non_linux_workflow_steps(self) -> None:
        """Rule: an inline `run:` block is a script a runner executes too."""
        workflows = _non_linux_workflows()
        self.assertEqual(
            {path.name for path in workflows},
            set(_EXPECTED_NON_LINUX_WORKFLOWS),
            "the set of workflows with a macOS or Windows job changed; update "
            "_EXPECTED_NON_LINUX_WORKFLOWS deliberately rather than letting "
            "this check silently scan fewer files",
        )
        offenders = []
        for workflow in workflows:
            offenders.extend(_scan(workflow, _WORKFLOWS_DIR.parent.parent))
        self.assertEqual(
            offenders,
            [],
            "GNU-only constructs found in a workflow with a macOS or Windows "
            "job:\n" + "\n".join(offenders),
        )

    def test_the_check_can_see_a_violation(self) -> None:
        """The scan matches a known-bad line, so a green run means something."""
        pattern, _ = _GNU_ONLY[0]

        def strip(line: str) -> str:
            return _QUOTED.sub("''", line)

        self.assertIsNotNone(pattern.search(strip("  value=$(grep -oP 'x\\K[0-9]+' file)")))
        self.assertIsNone(pattern.search(strip("  value=$(grep -o 'x[0-9]*' file)")))
        # The false positive this guard was corrected for: an option-looking
        # token inside the search pattern is not a grep option.
        self.assertIsNone(pattern.search(strip("grep -q 'Out-File -FilePath $Log' file")))
        rg_pattern = _GNU_ONLY[2][0]
        self.assertIsNotNone(rg_pattern.search("if rg -q 'x' file; then"))
        self.assertIsNone(rg_pattern.search("echo merging file"))


if __name__ == "__main__":
    unittest.main()
