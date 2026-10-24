#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${APP_DIR}"

TARGET_TESTS=(
  tests.pyinfra_runtime_test
  tests.workflow_executor_test
  tests.app_workflow_test
  tests.http_workflow_test
  tests.dns_workflow_test
  tests.setup_server_test
)

INCLUDE_FILES=(
  "src/orchestrator/pyinfra_runtime.py"
)

INCLUDE_CSV="$(IFS=,; echo "${INCLUDE_FILES[*]}")"
COVERAGE_DIR="coverage/pyinfra_runtime_op_hash"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"
COVERAGE_DATA="${COVERAGE_DIR}/.coverage"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

COVERAGE_FILE="${COVERAGE_DATA}" uv run --with coverage coverage erase
COVERAGE_FILE="${COVERAGE_DATA}" uv run --with coverage coverage run --branch -m unittest "${TARGET_TESTS[@]}"
uv run --with coverage coverage json \
  --data-file="${COVERAGE_DATA}" \
  --include="${INCLUDE_CSV}" \
  -o "${REPORT_JSON}"

uv run python - <<'PY'
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

source_path = Path("src/orchestrator/pyinfra_runtime.py")
report_path = Path("coverage/pyinfra_runtime_op_hash/coverage.json")

if not report_path.exists():
    print(
        "coverage/pyinfra_runtime_op_hash/coverage.json was not generated",
        file=sys.stderr,
    )
    sys.exit(1)

source = source_path.read_text()
for forbidden in (
    'getattr(op_meta, "_hash"',
    "Operation metadata missing op hash",
    '"op_hash":',
    '"op_hashes"',
):
    if forbidden in source:
        print(f"Forbidden pyinfra op hash contract remains: {forbidden}", file=sys.stderr)
        sys.exit(1)

symbols_by_path = {
    "src/orchestrator/pyinfra_runtime.py": (
        "_StateEventCallback._operation_name",
        "_StateEventCallback._emit_operation_output",
        "_StateEventCallback.operation_start",
        "_StateEventCallback.operation_host_start",
        "_StateEventCallback.operation_host_success",
        "_StateEventCallback.operation_host_error",
        "_StateEventCallback.operation_host_retry",
        "_StateEventCallback.operation_end",
        "_OperationRecord",
        "PyinfraRuntimeSession.add_operation",
        "PyinfraRuntimeSession._collect_operation_results",
        "PyinfraRuntimeSession.execute",
        "PyinfraRuntimeSession.close",
    ),
}
branch_symbols_by_path = {
    "src/orchestrator/pyinfra_runtime.py": (
        "PyinfraRuntimeSession._collect_operation_results",
        "PyinfraRuntimeSession.execute",
        "PyinfraRuntimeSession.close",
    ),
}

report = json.loads(report_path.read_text())
files = report.get("files", {})
failures = []

for path, symbols in symbols_by_path.items():
    payload = files.get(path)
    if payload is None:
        failures.append(f"{path}: no coverage payload")
        continue

    executed = set(payload.get("executed_lines", []))
    missing = set(payload.get("missing_lines", []))
    executable = executed | missing
    try:
        branch_spans = resolve_python_symbol_spans(
            Path(path),
            branch_symbols_by_path[path],
        )
        lines = covered_lines_in_spans(
            Path(path),
            symbols,
            executable,
            language="python",
        )
    except CoverageGateDefinitionError as error:
        failures.append(str(error))
        continue
    checked = len(lines)
    missed_lines = sorted(lines & missing)
    covered = checked - len(missed_lines)
    covered_branches = uncovered_arcs_touching_spans(
        branch_spans,
        payload.get("executed_branches", []),
    )
    missing_branches = uncovered_arcs_touching_spans(
        branch_spans,
        payload.get("missing_branches", []),
    )

    percent = (covered / checked * 100.0) if checked else 100.0
    branch_total = len(covered_branches) + len(missing_branches)
    branch_percent = (
        len(covered_branches) / branch_total * 100.0 if branch_total else 100.0
    )
    print(
        f"{path}: op-hash refactor executable lines "
        f"{covered}/{checked} ({percent:.2f}%), branches "
        f"{len(covered_branches)}/{branch_total} ({branch_percent:.2f}%)"
    )
    if missed_lines:
        failures.append(f"{path}: missing op-hash refactor lines {missed_lines}")
    if missing_branches:
        failures.append(
            f"{path}: missing op-hash refactor branches {missing_branches}"
        )

if failures:
    print("\nPyinfra op-hash coverage gate failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)

print("\nPyinfra op-hash coverage gate passed.")
PY
