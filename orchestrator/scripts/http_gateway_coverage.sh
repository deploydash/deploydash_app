#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${APP_DIR}"

COVERAGE_DIR="coverage/http_gateway"
COVERAGE_DATA="${COVERAGE_DIR}/.coverage"
COVERAGE_JSON="${COVERAGE_DIR}/coverage.json"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

COVERAGE_FILE="${COVERAGE_DATA}" uv run --with coverage coverage erase
COVERAGE_FILE="${COVERAGE_DATA}" uv run --with coverage coverage run --branch -m unittest \
  tests.http_part1_foundation_test \
  tests.http_part2_runtime_test \
  tests.http_workflow_test
uv run --with coverage coverage json \
  --data-file="${COVERAGE_DATA}" \
  --include="src/orchestrator/http_parts/part2_runtime.py" \
  -o "${COVERAGE_JSON}"

uv run python - <<'PY'
import json
import sys
from pathlib import Path

report_path = Path("coverage/http_gateway/coverage.json")
source_path = "src/orchestrator/http_parts/part2_runtime.py"

report = json.loads(report_path.read_text())
summary = report["files"][source_path]["summary"]
covered_lines = summary["covered_lines"]
total_lines = summary["num_statements"]
covered_branches = summary["covered_branches"]
total_branches = summary["num_branches"]

print(f"{source_path}: lines {covered_lines}/{total_lines}; branches {covered_branches}/{total_branches}")
if covered_lines != total_lines or covered_branches != total_branches:
    print("HTTP gateway coverage gate failed.", file=sys.stderr)
    sys.exit(1)

print("HTTP gateway coverage gate passed.")
PY
