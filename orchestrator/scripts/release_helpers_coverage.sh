#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${APP_DIR}"

REPORT_DIR="coverage/release_helpers"
REPORT_JSON="${REPORT_DIR}/coverage.json"
TARGET="src/orchestrator/release_helpers.py"

rm -rf "${REPORT_DIR}"
mkdir -p "${REPORT_DIR}"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest \
  tests.release_helpers_test \
  tests.release_asset_contract_test
uv run --with coverage coverage json --include="${TARGET}" -o "${REPORT_JSON}"

python3 - <<'PY'
import json
import sys
from pathlib import Path

report_path = Path("coverage/release_helpers/coverage.json")
target = "src/orchestrator/release_helpers.py"
if not report_path.exists():
    print(f"{report_path} was not generated", file=sys.stderr)
    sys.exit(1)

payload = json.loads(report_path.read_text(encoding="utf-8"))
file_report = payload.get("files", {}).get(target)
if file_report is None:
    print(f"No coverage payload for {target}", file=sys.stderr)
    sys.exit(1)

summary = file_report.get("summary", {})
covered = int(summary.get("covered_lines", 0))
total = int(summary.get("num_statements", 0))
percent = 100.0 * covered / total if total else 0.0
print(f"Release helpers coverage: {percent:.2f}% ({covered}/{total})")
if covered != total:
    print("Release helpers coverage must remain 100.00%.", file=sys.stderr)
    sys.exit(1)

covered_branches = int(summary.get("covered_branches", 0))
total_branches = int(summary.get("num_branches", 0))
branch_percent = 100.0 * covered_branches / total_branches if total_branches else 0.0
print(
    "Release helpers branch coverage: "
    f"{branch_percent:.2f}% ({covered_branches}/{total_branches})"
)
if covered_branches != total_branches:
    print("Release helpers branch coverage must remain 100.00%.", file=sys.stderr)
    sys.exit(1)
PY
