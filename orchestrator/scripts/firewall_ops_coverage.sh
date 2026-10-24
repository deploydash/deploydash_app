#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/firewall_ops"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

TEST_MODULES=(
  tests.firewall_workflow_test
  tests.firewall_status_test
  tests.ssh_test
  tests.setup_postflight_test
  tests.setup_security_test
  tests.golden_artifacts_test
)

INCLUDE_FILES=(
  "src/orchestrator/engine_firewall_ops.py"
  "src/orchestrator/firewall_status.py"
  "src/orchestrator/firewall_ufw.py"
)

INCLUDE_CSV="$(IFS=,; echo "${INCLUDE_FILES[*]}")"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TEST_MODULES[@]}"
uv run --with coverage coverage json --include="${INCLUDE_CSV}" -o "${REPORT_JSON}"

uv run python - <<'PY'
import json
import sys
from pathlib import Path

report_path = Path("coverage/firewall_ops/coverage.json")
data = json.loads(report_path.read_text())
files = data["files"]

bad = []
for path in sorted(files):
    summary = files[path]["summary"]
    lines = summary["percent_statements_covered"]
    branches = summary["percent_branches_covered"]
    print(
        f"{path}: "
        f"lines {summary['covered_lines']}/{summary['num_statements']} "
        f"({lines:.2f}%), "
        f"branches {summary['covered_branches']}/{summary['num_branches']} "
        f"({branches:.2f}%)",
    )
    if abs(lines - 100.0) > 1e-9 or abs(branches - 100.0) > 1e-9:
        bad.append(path)

if bad:
    print("\nFirewall ops backend coverage gate failed:")
    for path in bad:
        print(f"- {path}")
    sys.exit(1)

print("\nFirewall ops backend coverage gate passed.")
PY
