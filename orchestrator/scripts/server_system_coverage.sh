#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/server_system"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest \
  tests.server_system_workflow_test \
  tests.swap_management_test
uv run --with coverage coverage json -o "${REPORT_JSON}"

python3 - <<'PY'
import json
import sys
from pathlib import Path

report_path = Path("coverage/server_system/coverage.json")
targets = (
    "src/orchestrator/infra_parts/system_settings.py",
    "src/orchestrator/swap_management.py",
)
payload = json.loads(report_path.read_text(encoding="utf-8"))
for target in targets:
    data = payload.get("files", {}).get(target)
    if data is None:
        raise SystemExit(f"{target}: no coverage payload")

    summary = data["summary"]
    covered_lines = summary["covered_lines"]
    total_lines = summary["num_statements"]
    covered_branches = summary["covered_branches"]
    total_branches = summary["num_branches"]
    print(
        f"{target}: lines {covered_lines}/{total_lines}; "
        f"branches {covered_branches}/{total_branches}"
    )

    if covered_lines != total_lines or covered_branches != total_branches:
        print(f"missing lines: {data.get('missing_lines', [])}", file=sys.stderr)
        print(f"missing branches: {data.get('missing_branches', [])}", file=sys.stderr)
        raise SystemExit(
            "Server system settings coverage must remain 100% line and branch."
        )

print("Server system settings coverage gate passed.")
PY
