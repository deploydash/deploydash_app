#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCHESTRATOR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${ORCHESTRATOR_DIR}"

COVERAGE_DIR="coverage/dns_runtime"
COVERAGE_DATA="${COVERAGE_DIR}/.coverage"
COVERAGE_JSON="${COVERAGE_DIR}/coverage.json"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

COVERAGE_FILE="${COVERAGE_DATA}" uv run --with coverage coverage erase
COVERAGE_FILE="${COVERAGE_DATA}" uv run --with coverage coverage run --branch \
  -m unittest tests.dns_part2_runtime_test
uv run --with coverage coverage json \
  --data-file="${COVERAGE_DATA}" \
  --include="src/orchestrator/dns_parts/part2_runtime.py" \
  -o "${COVERAGE_JSON}"

uv run python - <<'PY'
import json
import sys
from pathlib import Path

report_path = Path("coverage/dns_runtime/coverage.json")
source_path = "src/orchestrator/dns_parts/part2_runtime.py"

report = json.loads(report_path.read_text())
summary = report["files"][source_path]["summary"]
covered_lines = summary["covered_lines"]
total_lines = summary["num_statements"]
covered_branches = summary["covered_branches"]
total_branches = summary["num_branches"]

print(
    f"{source_path}: lines {covered_lines}/{total_lines}; "
    f"branches {covered_branches}/{total_branches}",
)
if covered_lines != total_lines or covered_branches != total_branches:
    print("DNS runtime coverage gate failed.", file=sys.stderr)
    sys.exit(1)

print("DNS runtime coverage gate passed.")
PY
