#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/setup_server"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

TEST_MODULES=(
  tests.setup_server_test
  tests.setup_additive_admin_access_test
  tests.setup_postflight_test
  tests.setup_config_test
)

INCLUDE_FILES=(
  "src/orchestrator/infra_parts/provisioning.py"
)

# Symbol-owned 100% line-and-branch coverage for the setup_server flow: the
# hosting module also owns the HTTP, DNS, and layout runtime flows, which are
# separate functional areas with their own suites and are not billed here.
SYMBOL_TARGETS=(
  "setup_server"
  "setup_server._emit_from_executor"
)

INCLUDE_CSV="$(IFS=,; echo "${INCLUDE_FILES[*]}")"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TEST_MODULES[@]}"
uv run --with coverage coverage json --include="${INCLUDE_CSV}" -o "${REPORT_JSON}"

TARGETS_JSON="$(printf '%s\n' "${SYMBOL_TARGETS[@]}")"
export TARGETS_JSON

uv run python - <<'PY'
import json
import os
import sys
from pathlib import Path

report_path = Path("coverage/setup_server/coverage.json")
data = json.loads(report_path.read_text())
files = data["files"]
targets = [line for line in os.environ["TARGETS_JSON"].splitlines() if line]

failures = []
for path in sorted(files):
    functions = files[path].get("functions", {})
    for target in targets:
        if target not in functions:
            print(f"{path}:{target}: MISSING FUNCTION ENTRY")
            failures.append(f"{path}:{target} (missing)")
            continue
        summary = functions[target]["summary"]
        line_pct = summary["percent_covered"]
        branch_total = summary.get("num_branches", 0)
        branch_done = summary.get("covered_branches", 0)
        branch_pct = (
            summary.get("percent_branches_covered", 100.0)
            if branch_total
            else 100.0
        )
        missing = functions[target].get("missing_lines", [])
        missing_arcs = functions[target].get("missing_branches", [])
        print(
            f"{path}:{target}: "
            f"lines {summary['covered_lines']}/{summary['num_statements']} "
            f"({line_pct:.2f}%), "
            f"branches {branch_done}/{branch_total} ({branch_pct:.2f}%)",
        )
        if missing:
            print(f"  missing lines: {missing}")
        if missing_arcs:
            print(f"  missing arcs: {missing_arcs}")
        if (
            abs(line_pct - 100.0) > 1e-9
            or abs(branch_pct - 100.0) > 1e-9
        ):
            failures.append(f"{path}:{target}")

unmatched = [
    target
    for target in targets
    if all(target not in files[path].get("functions", {}) for path in files)
]
if unmatched:
    print("\nSymbol coverage targets without any function entry:")
    for target in unmatched:
        print(f"- {target}")
    sys.exit(1)

if failures:
    print("\nSetup server coverage gate failed:")
    for failure in failures:
        print(f"- {failure}")
    sys.exit(1)

print("\nSetup server coverage gate passed.")
PY
