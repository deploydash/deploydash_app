#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${APP_DIR}"

TARGET_TESTS=(
  tests.backup_error_details_test
  tests.postgres_backup_test
  tests.postgres_plugin_test
  tests.postgres_supply_chain_test
)

INCLUDE_FILES=(
  "src/orchestrator/backup_error_details.py"
  "src/orchestrator/postgres_backup.py"
  "src/orchestrator/postgres_supply_chain.py"
  "src/orchestrator/plugins/postgres_plugin.py"
)

INCLUDE_CSV="$(IFS=,; echo "${INCLUDE_FILES[*]}")"

rm -rf coverage/backup
mkdir -p coverage/backup

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TARGET_TESTS[@]}"
uv run --with coverage coverage json \
  --include="${INCLUDE_CSV}" \
  -o coverage/backup/coverage.json

python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

report_path = Path("coverage/backup/coverage.json")
if not report_path.exists():
    print("coverage/backup/coverage.json was not generated", file=sys.stderr)
    sys.exit(1)

threshold = float(os.environ.get("BACKUP_COVERAGE_THRESHOLD", "100"))
report = json.loads(report_path.read_text())
files = report.get("files", {})
if not files:
    print("No backup coverage files were reported", file=sys.stderr)
    sys.exit(1)

covered = total = 0
branches_covered = branches_total = 0
for file_path, payload in files.items():
    summary = payload.get("summary", {})
    file_covered = int(summary.get("covered_lines", 0))
    file_total = int(summary.get("num_statements", 0))
    covered += file_covered
    total += file_total
    percent = (file_covered / file_total * 100.0) if file_total else 0.0
    print(f"{file_path}: {percent:.2f}% ({file_covered}/{file_total})")
    file_branches_covered = int(summary.get("covered_branches", 0))
    file_branches_total = int(summary.get("num_branches", 0))
    branches_covered += file_branches_covered
    branches_total += file_branches_total
    branch_percent = (
        (file_branches_covered / file_branches_total * 100.0) if file_branches_total else 0.0
    )
    print(
        f"{file_path} branches: {branch_percent:.2f}% "
        f"({file_branches_covered}/{file_branches_total})"
    )

overall = (covered / total * 100.0) if total else 0.0
print(
    "Backup backend coverage: "
    f"{overall:.2f}% ({covered}/{total}) "
    f"(threshold {threshold:.2f}%)"
)
branch_overall = (branches_covered / branches_total * 100.0) if branches_total else 0.0
print(
    "Backup backend branch coverage: "
    f"{branch_overall:.2f}% ({branches_covered}/{branches_total}) "
    f"(threshold {threshold:.2f}%)"
)

if overall < threshold:
    print(
        f"Backup backend coverage {overall:.2f}% is below {threshold:.2f}%",
        file=sys.stderr,
    )
    sys.exit(1)
if branch_overall < threshold:
    print(
        f"Backup backend branch coverage {branch_overall:.2f}% is below {threshold:.2f}%",
        file=sys.stderr,
    )
    sys.exit(1)
PY
