#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${APP_DIR}"

TARGET_TESTS=(
  tests.runtime_security_test
  tests.worker_runtime_builder_test
  tests.http_part1_foundation_test
  tests.setup_part5_railpack_test
)

INCLUDE_FILES=(
  "src/orchestrator/runtime_security.py"
  "src/orchestrator/app_parts/worker_runtime.py"
  "src/orchestrator/http_parts/part1_foundation.py"
  "src/orchestrator/setup_parts/part5_railpack_builds.py"
)

INCLUDE_CSV="$(IFS=,; echo "${INCLUDE_FILES[*]}")"

rm -rf coverage/runtime_security
mkdir -p coverage/runtime_security

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TARGET_TESTS[@]}"
uv run --with coverage coverage json \
  --include="${INCLUDE_CSV}" \
  -o coverage/runtime_security/coverage.json

python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

report_path = Path("coverage/runtime_security/coverage.json")
if not report_path.exists():
    print("coverage/runtime_security/coverage.json was not generated", file=sys.stderr)
    sys.exit(1)

threshold = float(os.environ.get("RUNTIME_SECURITY_COVERAGE_THRESHOLD", "100"))
report = json.loads(report_path.read_text())
files = report.get("files", {})
if not files:
    print("No runtime security coverage files were reported", file=sys.stderr)
    sys.exit(1)

covered = total = 0
for file_path, payload in files.items():
    summary = payload.get("summary", {})
    file_covered = int(summary.get("covered_lines", 0))
    file_total = int(summary.get("num_statements", 0))
    covered += file_covered
    total += file_total
    percent = (file_covered / file_total * 100.0) if file_total else 0.0
    print(f"{file_path}: {percent:.2f}% ({file_covered}/{file_total})")

overall = (covered / total * 100.0) if total else 0.0
print(
    "Runtime security backend coverage: "
    f"{overall:.2f}% ({covered}/{total}) "
    f"(threshold {threshold:.2f}%)"
)

if overall < threshold:
    print(
        f"Runtime security backend coverage {overall:.2f}% is below {threshold:.2f}%",
        file=sys.stderr,
    )
    sys.exit(1)
PY
