#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${APP_DIR}"

TARGET_TESTS=(
  tests.postgres_config_test
  tests.postgres_plugin_test
)

INCLUDE_FILES=(
  "src/orchestrator/postgres_parts/postgres_config.py"
  "src/orchestrator/plugins/postgres_plugin.py"
)

INCLUDE_CSV="$(IFS=,; echo "${INCLUDE_FILES[*]}")"

rm -rf coverage/database
mkdir -p coverage/database

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TARGET_TESTS[@]}"
uv run --with coverage coverage json \
  --include="${INCLUDE_CSV}" \
  -o coverage/database/coverage.json

python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

report_path = Path("coverage/database/coverage.json")
if not report_path.exists():
    print("coverage/database/coverage.json was not generated", file=sys.stderr)
    sys.exit(1)

threshold = float(os.environ.get("DATABASE_COVERAGE_THRESHOLD", "100"))
report = json.loads(report_path.read_text())
files = report.get("files", {})
if not files:
    print("No database coverage files were reported", file=sys.stderr)
    sys.exit(1)

covered = total = 0
for file_path, payload in files.items():
    summary = payload.get("summary", {})
    file_covered = int(summary.get("covered_lines", 0))
    file_total = int(summary.get("num_statements", 0))
    covered += file_covered
    total += file_total
    percent = (file_covered / file_total * 100.0) if file_total else 0.0
    print(
        f"{file_path}: {percent:.2f}% "
        f"({file_covered}/{file_total})"
    )

overall = (covered / total * 100.0) if total else 0.0
print(
    "Database backend coverage: "
    f"{overall:.2f}% ({covered}/{total}) "
    f"(threshold {threshold:.2f}%)"
)

if overall < threshold:
    print(
        f"Database backend coverage {overall:.2f}% is below {threshold:.2f}%",
        file=sys.stderr,
    )
    sys.exit(1)
PY
