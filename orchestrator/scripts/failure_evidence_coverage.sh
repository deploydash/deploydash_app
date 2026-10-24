#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COVERAGE_DIR="${APP_DIR}/coverage/failure_evidence"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

cd "${APP_DIR}"
rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest \
  tests.failure_evidence_test \
  tests.backup_error_details_test \
  tests.architecture.engine_contract_guardrails_test \
  tests.architecture.house_protocol_test \
  tests.log_sanitizer_test \
  tests.workflow_executor_test \
  tests.pyinfra_runtime_test \
  tests.app_workflow_test
uv run --with coverage coverage json \
  --include="src/orchestrator/failure_evidence.py,src/orchestrator/log_sanitizer.py,src/orchestrator/backup_error_details.py,src/orchestrator/workflow_executor.py,src/orchestrator/pyinfra_runtime.py,src/orchestrator/setup_parts/common.py,src/orchestrator/app_parts/common.py" \
  -o "${REPORT_JSON}"

python3 - "${REPORT_JSON}" <<'PY'
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import (
    covered_lines_in_spans,
    resolve_python_symbol_spans,
    uncovered_arcs_touching_spans,
)

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for path in (
    "src/orchestrator/failure_evidence.py",
    "src/orchestrator/log_sanitizer.py",
    "src/orchestrator/backup_error_details.py",
):
    payload = report.get("files", {}).get(path)
    if payload is None:
        raise SystemExit(f"{path}: no coverage payload")

    summary = payload["summary"]
    covered_lines = int(summary["covered_lines"])
    lines = int(summary["num_statements"])
    covered_branches = int(summary["covered_branches"])
    branches = int(summary["num_branches"])
    print(
        f"{path}: lines {covered_lines}/{lines}, "
        f"branches {covered_branches}/{branches}"
    )
    if payload.get("missing_lines") or payload.get("missing_branches"):
        print(f"Missing lines: {payload.get('missing_lines', [])}", file=sys.stderr)
        print(
            f"Missing branches: {payload.get('missing_branches', [])}",
            file=sys.stderr,
        )
        raise SystemExit(1)

symbols_by_path = {
    "src/orchestrator/workflow_executor.py": (
        "step_action_payloads",
        "_failed_action_payload",
        "_operation_details",
        "_operation_failure_evidence",
        "_unavailable_engine_evidence",
        "run_plan_execute",
    ),
    "src/orchestrator/pyinfra_runtime.py": (
        "_bounded_failure_lines",
        "PyinfraRuntimeSession._collect_operation_results",
    ),
    "src/orchestrator/setup_parts/common.py": ("StepAction.to_dict",),
    "src/orchestrator/app_parts/common.py": ("AppAction",),
}
for path, symbols in symbols_by_path.items():
    payload = report.get("files", {}).get(path)
    if payload is None:
        raise SystemExit(f"{path}: no coverage payload")
    source_path = Path(path)
    spans = resolve_python_symbol_spans(source_path, symbols)
    executed_lines = set(payload.get("executed_lines", []))
    missing_lines = set(payload.get("missing_lines", []))
    checked_lines = covered_lines_in_spans(
        source_path,
        symbols,
        executed_lines | missing_lines,
        language="python",
    )
    scoped_missing_lines = sorted(checked_lines & missing_lines)
    executed_branches = {
        tuple(arc)
        for arc in uncovered_arcs_touching_spans(
            spans,
            payload.get("executed_branches", []),
        )
    }
    missing_branches = {
        tuple(arc)
        for arc in uncovered_arcs_touching_spans(
            spans,
            payload.get("missing_branches", []),
        )
    }
    checked_branches = executed_branches | missing_branches
    print(
        f"{path}: scoped lines {len(checked_lines) - len(scoped_missing_lines)}/"
        f"{len(checked_lines)}, branches "
        f"{len(checked_branches) - len(missing_branches)}/{len(checked_branches)}"
    )
    if scoped_missing_lines or missing_branches:
        print(f"Missing scoped lines: {scoped_missing_lines}", file=sys.stderr)
        print(f"Missing scoped branches: {sorted(missing_branches)}", file=sys.stderr)
        raise SystemExit(1)
print("Failure-evidence coverage: 100.00% line, 100.00% branch")
PY
