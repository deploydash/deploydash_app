#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${APP_DIR}"

TARGET_TESTS=(
  tests.embedded_runtime_test
  tests.task_runtime_test
  tests.runtime_bundle_test
  tests.release_helpers_test
  tests.windows_store_release_test
)

INCLUDE_FILES=(
  "src/orchestrator/embedded_runtime.py"
  "src/orchestrator/task_runtime.py"
  "src/orchestrator/runtime_bundle.py"
  "src/orchestrator/release_helpers.py"
)

INCLUDE_CSV="$(IFS=,; echo "${INCLUDE_FILES[*]}")"

rm -rf coverage/desktop_runtime
mkdir -p coverage/desktop_runtime

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TARGET_TESTS[@]}"
uv run --with coverage coverage json \
  --include="${INCLUDE_CSV}" \
  -o coverage/desktop_runtime/coverage.json

python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

report_path = Path("coverage/desktop_runtime/coverage.json")
if not report_path.exists():
    print(
        "coverage/desktop_runtime/coverage.json was not generated",
        file=sys.stderr,
    )
    sys.exit(1)

threshold = float(os.environ.get("DESKTOP_RUNTIME_COVERAGE_THRESHOLD", "100"))
report = json.loads(report_path.read_text())
files = report.get("files", {})
if not files:
    print("No desktop runtime coverage files were reported", file=sys.stderr)
    sys.exit(1)

covered = total = 0
covered_branches = total_branches = 0
for file_path, payload in files.items():
    summary = payload.get("summary", {})
    file_covered = int(summary.get("covered_lines", 0))
    file_total = int(summary.get("num_statements", 0))
    file_covered_branches = int(summary.get("covered_branches", 0))
    file_total_branches = int(summary.get("num_branches", 0))
    covered += file_covered
    total += file_total
    covered_branches += file_covered_branches
    total_branches += file_total_branches
    denominator = file_total + file_total_branches
    numerator = file_covered + file_covered_branches
    percent = (numerator / denominator * 100.0) if denominator else 0.0
    print(
        f"{file_path}: {percent:.2f}% "
        f"({file_covered}/{file_total} lines, "
        f"{file_covered_branches}/{file_total_branches} branches)"
    )

denominator = total + total_branches
numerator = covered + covered_branches
overall = (numerator / denominator * 100.0) if denominator else 0.0
print(
    "Desktop runtime backend coverage: "
    f"{overall:.2f}% "
    f"({covered}/{total} lines, "
    f"{covered_branches}/{total_branches} branches) "
    f"(threshold {threshold:.2f}%)"
)

if overall < threshold:
    print(
        f"Desktop runtime backend coverage {overall:.2f}% "
        f"is below {threshold:.2f}%",
        file=sys.stderr,
    )
    sys.exit(1)
PY
