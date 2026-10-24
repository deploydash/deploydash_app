#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/server_overview"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

TARGET_TESTS=(
  tests.engine_metrics_parsers_test
  tests.server_overview_ops_test
  tests.server_overview_workflow_test
  tests.ssh_test
  tests.specs_test
)

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TARGET_TESTS[@]}"
uv run --with coverage coverage json -o "${REPORT_JSON}"

python3 - <<'PY'
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import (
    CoverageGateDefinitionError,
    covered_lines_in_spans,
    resolve_python_symbol_spans,
    uncovered_arcs_touching_spans,
)

report_path = Path("coverage/server_overview/coverage.json")
if not report_path.exists():
    print("coverage/server_overview/coverage.json was not generated", file=sys.stderr)
    sys.exit(1)

payload = json.loads(report_path.read_text())
files = payload.get("files", {})
targets = {
    "src/orchestrator/infra_parts/overview.py": (
        "_ufw_replacement_check",
        "collect_server_compatibility",
        "get_hardware_specs",
        "run_server_overview_operation",
    ),
    "src/orchestrator/engine_metrics_parsers.py": (
        "_parse_server_overview_metrics_output",
    ),
}
branch_targets = {"src/orchestrator/infra_parts/overview.py"}

failures = []
for target, symbols in targets.items():
    data = files.get(target)
    if not data:
        failures.append(f"{target}: no coverage payload")
        continue

    executed = set(data.get("executed_lines", []))
    missing = set(data.get("missing_lines", []))
    relevant = executed | missing
    try:
        spans = resolve_python_symbol_spans(Path(target), symbols)
        scoped_relevant = covered_lines_in_spans(
            Path(target),
            symbols,
            relevant,
            language="python",
        )
    except CoverageGateDefinitionError as error:
        failures.append(str(error))
        continue
    scoped_missing = sorted(missing & scoped_relevant)
    covered = len(scoped_relevant) - len(scoped_missing)
    total = len(scoped_relevant)
    pct = (covered / total) * 100 if total else 0.0
    if target in branch_targets:
        scoped_executed_branches = uncovered_arcs_touching_spans(
            spans,
            data.get("executed_branches", []),
        )
        scoped_missing_branches = uncovered_arcs_touching_spans(
            spans,
            data.get("missing_branches", []),
        )
        covered_branches = len(scoped_executed_branches)
        total_branches = covered_branches + len(scoped_missing_branches)
        branch_pct = (
            (covered_branches / total_branches) * 100 if total_branches else 100.0
        )
        print(
            f"{target}: lines {pct:.2f}% ({covered}/{total}), "
            f"branches {branch_pct:.2f}% ({covered_branches}/{total_branches})"
        )
    else:
        scoped_missing_branches = []
        print(f"{target}: lines {pct:.2f}% ({covered}/{total})")
    if scoped_missing:
        failures.append(f"{target}: missing lines {scoped_missing}")
    if scoped_missing_branches:
        failures.append(
            f"{target}: missing branches {scoped_missing_branches}"
        )

if failures:
    print("\nServer overview backend coverage gate failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)

print("\nServer overview backend coverage gate passed.")
PY
