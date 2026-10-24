#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/postgres_major_upgrade"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

TEST_MODULES=(
  tests.postgres_major_upgrade_test
  tests.postgres_workflow_test
)

INCLUDE_FILES=(
  "src/orchestrator/postgres_runtime_parts/service_runtime.py"
  "src/orchestrator/postgres_runtime_parts/service_storage.py"
  "src/orchestrator/postgres_runtime_parts/service_upgrade.py"
)

# Whole-symbol 100% line-and-branch targets for the #86 major-version
# guard and upgrade operation: the container-image probe, its tag
# parser, the refusal that keeps service_configure from swapping the
# image under live data, and every upgrade builder, snapshotter and
# runner below it.
FILE_SYMBOL_TARGETS_JSON='{
  "src/orchestrator/postgres_runtime_parts/service_storage.py": [
    "_postgres_upgrade_empty_ledger",
    "_postgres_upgrade_parse_ledger",
    "_postgres_upgrade_encode_ledger",
    "_postgres_upgrade_read_ledger_command",
    "_postgres_upgrade_write_ledger_command"
  ],
  "src/orchestrator/postgres_runtime_parts/service_upgrade.py": [
    "_postgres_container_image_probe_command",
    "_postgres_parse_container_image_major",
    "refuse_postgres_major_version_change",
    "_postgres_upgrade_timestamp",
    "_postgres_upgrade_dump_dir",
    "_postgres_upgrade_makedir_command",
    "_postgres_upgrade_target_volume_name",
    "_postgres_upgrade_throwaway_prefix",
    "_postgres_upgrade_dump_globals_command",
    "_postgres_upgrade_dump_database_command",
    "_postgres_upgrade_create_volume_command",
    "_postgres_upgrade_restore_globals_command",
    "_postgres_upgrade_restore_database_command",
    "_postgres_upgrade_relations_snapshot_sql",
    "_postgres_upgrade_user_tables_sql",
    "_postgres_upgrade_row_counts_sql",
    "_postgres_upgrade_extensions_snapshot_sql",
    "_postgres_upgrade_database_metadata_snapshot_sql",
    "_postgres_upgrade_globals_tolerable",
    "_postgres_upgrade_output_line",
    "_postgres_upgrade_snapshot_database",
    "run_postgres_major_upgrade"
  ]
}'

FILE_ANCHOR_TARGETS_JSON='{
  "src/orchestrator/postgres_runtime_parts/service_runtime.py": [
    "major_version_guard",
    "major_upgrade_dispatch"
  ]
}'

INCLUDE_CSV="$(IFS=,; echo "${INCLUDE_FILES[*]}")"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TEST_MODULES[@]}"
uv run --with coverage coverage json --include="${INCLUDE_CSV}" -o "${REPORT_JSON}"

export FILE_SYMBOL_TARGETS_JSON FILE_ANCHOR_TARGETS_JSON

uv run python - <<'PY'
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import (
    CoverageGateDefinitionError,
    resolve_python_anchor_spans,
    uncovered_arcs_touching_spans,
)

report_path = Path("coverage/postgres_major_upgrade/coverage.json")
data = json.loads(report_path.read_text())
files = data["files"]
by_file = {}
for path, payload in files.items():
    normalized = path[path.find("src/") :] if "src/" in path else path
    by_file[normalized] = payload

failures = []


def check_symbol(file_path, payload, target):
    functions = payload.get("functions", {})
    if target not in functions:
        print(f"{file_path}:{target or '<module>'}: MISSING FUNCTION ENTRY")
        failures.append(f"{file_path}:{target} (missing)")
        return
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
        f"{file_path}:{target or '<module>'}: "
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
        failures.append(f"{file_path}:{target}")


def check_anchors(file_path, payload, anchors):
    try:
        spans = resolve_python_anchor_spans(Path(file_path), anchors)
    except CoverageGateDefinitionError as error:
        print(error, file=sys.stderr)
        failures.append(f"{file_path} (anchor definition)")
        return
    executable = set(payload.get("executed_lines", [])) | set(
        payload.get("missing_lines", [])
    )
    uncovered_lines = sorted(
        line
        for line in set(payload.get("missing_lines", []))
        if any(start <= line <= end for start, end in spans.values())
    )
    touching_arcs = uncovered_arcs_touching_spans(
        spans,
        payload.get("missing_branches", []),
    )
    anchored = sorted(
        line
        for line in executable
        if any(start <= line <= end for start, end in spans.values())
    )
    print(
        f"{file_path}::{','.join(anchors)}: "
        f"lines {len(anchored) - len(uncovered_lines)}/{len(anchored)}, "
        f"touching arcs uncovered: {len(touching_arcs)}",
    )
    if uncovered_lines:
        print(f"  missing lines: {uncovered_lines}")
    if touching_arcs:
        print(f"  touching arcs: {touching_arcs}")
    if uncovered_lines or touching_arcs:
        failures.append(f"{file_path}::{','.join(anchors)}")


symbol_targets = json.loads(os.environ["FILE_SYMBOL_TARGETS_JSON"])
for file_path, targets in sorted(symbol_targets.items()):
    payload = by_file.get(file_path)
    if payload is None:
        print(f"{file_path}: no coverage payload", file=sys.stderr)
        failures.append(f"{file_path} (missing)")
        continue
    for target in targets:
        check_symbol(file_path, payload, target)

anchor_targets = json.loads(os.environ["FILE_ANCHOR_TARGETS_JSON"])
for file_path, anchors in sorted(anchor_targets.items()):
    payload = by_file.get(file_path)
    if payload is None:
        print(f"{file_path}: no coverage payload", file=sys.stderr)
        failures.append(f"{file_path} (missing)")
        continue
    check_anchors(file_path, payload, anchors)

if failures:
    print("\nPostgres major upgrade coverage gate failed:")
    for failure in failures:
        print(f"- {failure}")
    sys.exit(1)

print("\nPostgres major upgrade coverage gate passed.")
PY
