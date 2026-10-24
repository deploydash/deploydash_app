#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${APP_DIR}"

TARGET_TESTS=(
  tests.engine_test
  tests.architecture.engine_contract_guardrails_test
)

INCLUDE_FILES=(
  "src/orchestrator/workflow_registry.py"
  "src/orchestrator/engine_bootstrap.py"
)

INCLUDE_CSV="$(IFS=,; echo "${INCLUDE_FILES[*]}")"
COVERAGE_DIR="coverage/post_milvus_removal"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TARGET_TESTS[@]}"
uv run --with coverage coverage json --include="${INCLUDE_CSV}" -o "${REPORT_JSON}"

uv run python - <<'PY'
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import CoverageGateDefinitionError, covered_lines_in_spans

report_path = Path("coverage/post_milvus_removal/coverage.json")
if not report_path.exists():
    print("coverage/post_milvus_removal/coverage.json was not generated", file=sys.stderr)
    sys.exit(1)

symbols_by_path = {
    "src/orchestrator/workflow_registry.py": ("_no_extra_params_schema",),
    "src/orchestrator/engine_bootstrap.py": ("build_engine_bootstrap",),
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

    percent = (covered / checked * 100.0) if checked else 100.0
    print(f"{path}: touched executable lines {covered}/{checked} ({percent:.2f}%)")
    if missed_lines:
        failures.append(f"{path}: missing touched lines {missed_lines}")

if failures:
    print("\nPost-Milvus removal coverage gate failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)

print("\nPost-Milvus removal coverage gate passed.")
PY
