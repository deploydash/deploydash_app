#!/usr/bin/env bash
# Scoped coverage gate for the single-owner modules: layout, identifiers,
# and the KEY=value shell-output protocol.
#
# server_paths.py is the single owner of every managed path on a server
# (T-1.1.1), server_identifiers.py of every managed name (T-3.4.1), and
# shell_output.py of the KEY=value protocol servers answer in (T-3.8.6). A gap
# here is not an ordinary coverage gap: an unexercised builder is a path or a
# name nothing has ever constructed, and the first time it is constructed will
# be against a customer's machine. The gate therefore demands whole-file 100%
# line AND branch coverage rather than a range list.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COVERAGE_DIR="${APP_DIR}/coverage/server_layout"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

cd "${APP_DIR}"
rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest \
  tests.server_paths_test \
  tests.server_identifiers_test \
  tests.shell_output_test \
  tests.server_layout_test \
  tests.server_layout_compat_test
uv run --with coverage coverage json \
  --include="src/orchestrator/server_paths.py,src/orchestrator/server_identifiers.py,src/orchestrator/shell_output.py,src/orchestrator/server_layout.py" \
  -o "${REPORT_JSON}"

python3 - "${REPORT_JSON}" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
files = report.get("files", {})

required = [
    "src/orchestrator/server_paths.py",
    "src/orchestrator/server_identifiers.py",
    "src/orchestrator/shell_output.py",
    "src/orchestrator/server_layout.py",
]

failures = []
for path in required:
    payload = files.get(path)
    if payload is None:
        failures.append(f"{path}: no coverage payload")
        continue
    summary = payload.get("summary", {})
    missing_lines = sorted(payload.get("missing_lines", []))
    missing_branches = payload.get("missing_branches", [])
    percent = summary.get("percent_covered", 0.0)
    print(
        f"{path}: {percent:.2f}% "
        f"({summary.get('covered_lines', 0)}/"
        f"{summary.get('num_statements', 0)} statements, "
        f"{summary.get('covered_branches', 0)}/"
        f"{summary.get('num_branches', 0)} branches)"
    )
    if missing_lines:
        failures.append(f"{path}: uncovered lines {missing_lines}")
    if missing_branches:
        failures.append(f"{path}: uncovered branches {missing_branches}")

if failures:
    print("Server layout coverage gate failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    raise SystemExit(1)

print("Single-owner module coverage: 100% lines and branches.")
PY
