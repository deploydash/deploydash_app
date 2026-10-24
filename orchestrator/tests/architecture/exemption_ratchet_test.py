"""Architecture invariant: exemption lists are finite, reasoned debt.

Measurement: the Flutter coverage gate's held-out first-party files are read
from its executable Python block.  Each entry must carry a human-readable
reason and the committed total may decrease but never increase.
"""

from __future__ import annotations

import ast
import unittest
from dataclasses import dataclass
from pathlib import Path

_REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
_FLUTTER_COVERAGE_GATE = _REPOSITORY_ROOT / "ui" / "scripts" / "flutter_coverage.sh"
_FLUTTER_COVERAGE_DEBT_BASELINE = 4
_SCOPED_COVERAGE_OWNERS = (
    (
        _REPOSITORY_ROOT / "ui" / "scripts",
        _REPOSITORY_ROOT / ".github" / "workflows" / "desktop-dart.yml",
    ),
    (
        _REPOSITORY_ROOT / "orchestrator" / "scripts",
        _REPOSITORY_ROOT / ".github" / "workflows" / "backend-engine.yml",
    ),
)


@dataclass(frozen=True)
class _RetiredCoverageGate:
    """Metadata required before a scoped coverage gate may be retired."""

    reason: str
    replacement: str
    retired_scope: frozenset[str]
    retired_threshold: float
    replacement_scope: frozenset[str]
    replacement_threshold: float


# No scoped coverage gate has been retired as of the T-2.6.5 baseline.  The
# tuple is intentionally explicit: a future retirement must add metadata here
# and pass the same scope/threshold validation below.
_RETIRED_SCOPED_COVERAGE_GATES: tuple[_RetiredCoverageGate, ...] = ()
_RETIRED_SCOPED_COVERAGE_GATE_BASELINE_COUNT = 0


def _flutter_coverage_debt() -> object:
    source = _FLUTTER_COVERAGE_GATE.read_text(encoding="utf-8")
    start = source.index("COVERAGE_DEBT = {")
    end = source.index("\n\nrecords, current", start)
    assignment = ast.parse(source[start:end]).body[0]
    assert isinstance(assignment, ast.Assign)
    return ast.literal_eval(assignment.value)


def _validate_retired_coverage_gate(gate: _RetiredCoverageGate) -> None:
    if not gate.reason.strip():
        raise AssertionError("a retired scoped coverage gate must have a reason")
    if not gate.replacement.strip():
        raise AssertionError("a retired scoped coverage gate must name its replacement")
    if not gate.retired_scope <= gate.replacement_scope:
        raise AssertionError(
            "a retired scoped coverage gate replacement must cover every retired target"
        )
    if gate.replacement_threshold < gate.retired_threshold:
        raise AssertionError(
            "a retired scoped coverage gate replacement must retain or raise its threshold"
        )


class TestExemptionRatchets(unittest.TestCase):
    def test_every_scoped_coverage_gate_is_registered_once(self) -> None:
        """Rule: every coverage promise has exactly one CI workflow owner."""
        for scripts_dir, workflow_path in _SCOPED_COVERAGE_OWNERS:
            workflow = workflow_path.read_text(encoding="utf-8")
            for gate_path in sorted(scripts_dir.glob("*_coverage.sh")):
                self.assertEqual(
                    workflow.count(gate_path.name),
                    1,
                    f"{gate_path.relative_to(_REPOSITORY_ROOT)} must appear exactly "
                    f"once in {workflow_path.relative_to(_REPOSITORY_ROOT)}",
                )

    def test_flutter_coverage_debt_is_reasoned_and_can_only_shrink(self) -> None:
        """Rule: coverage debt is explicit, justified debt rather than exclusion."""
        debt = _flutter_coverage_debt()
        self.assertIsInstance(
            debt,
            dict,
            "flutter_coverage.sh COVERAGE_DEBT must map each held-out file to its reason",
        )
        assert isinstance(debt, dict)
        for path, reason in debt.items():
            self.assertIsInstance(path, str)
            self.assertIsInstance(reason, str)
            self.assertTrue(reason.strip(), f"Flutter coverage debt {path!r} has no reason")
        self.assertLessEqual(
            len(debt),
            _FLUTTER_COVERAGE_DEBT_BASELINE,
            "Flutter coverage-debt list grew; cover the file instead of excluding it",
        )

    def test_retired_scoped_coverage_gates_have_equivalent_or_stronger_replacements(self) -> None:
        """Rule: retiring a gate cannot quietly lower its coverage promise."""
        self.assertLessEqual(
            len(_RETIRED_SCOPED_COVERAGE_GATES),
            _RETIRED_SCOPED_COVERAGE_GATE_BASELINE_COUNT,
            "retired scoped coverage-gate list grew; retain the gate instead",
        )
        for gate in _RETIRED_SCOPED_COVERAGE_GATES:
            _validate_retired_coverage_gate(gate)

    def test_retired_gate_validator_rejects_weaker_replacements(self) -> None:
        """D2 proof: a weaker replacement is rejected before a list entry can hide it."""
        with self.assertRaisesRegex(AssertionError, "cover every retired target"):
            _validate_retired_coverage_gate(
                _RetiredCoverageGate(
                    reason="Regression fixture.",
                    replacement="replacement_coverage.sh",
                    retired_scope=frozenset({"module_a.py", "module_b.py"}),
                    retired_threshold=100.0,
                    replacement_scope=frozenset({"module_a.py"}),
                    replacement_threshold=100.0,
                )
            )


if __name__ == "__main__":
    unittest.main()
