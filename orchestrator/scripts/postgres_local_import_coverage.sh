#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/postgres_local_import"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

TEST_MODULES=(
  tests.postgres_local_import_scan_test
  tests.postgres_local_import_upload_test
  tests.postgres_backup_helpers_test
  tests.postgres_parsers_test
)

INCLUDE_FILES=(
  "src/orchestrator/postgres_runtime_parts/local_import_scan.py"
  "src/orchestrator/postgres_runtime_parts/local_import_support.py"
  "src/orchestrator/postgres_runtime_parts/local_sql_import.py"
)

# Whole-symbol 100% line-and-branch targets per file. The scanner module
# ships in full here (#84 slice A); slice B adds the staging checksum
# symbols. Later slices extend both lists with the role, container and
# pg_restore symbols they add.
FILE_SYMBOL_TARGETS_JSON='{
  "src/orchestrator/postgres_runtime_parts/local_import_scan.py": [
    "",
    "_scan_local_sql_dump",
    "_write_filtered_sql_dump",
    "_iter_sql_dump_segments",
    "_classify_dump_statement",
    "_classify_dump_meta_command",
    "_extension_statement_name"
  ],
  "src/orchestrator/postgres_runtime_parts/local_import_support.py": [
    "_postgres_local_sql_cleanup_command",
    "_verify_uploaded_file_sha256",
    "_postgres_throwaway_client_prefix",
    "_postgres_local_sql_import_command",
    "_postgres_temp_import_role_sql",
    "_postgres_drop_temp_import_role_sql",
    "_dump_file_is_custom_format",
    "_postgres_local_pg_restore_command"
  ],
  "src/orchestrator/postgres_runtime_parts/local_sql_import.py": [
    "_drop_temp_import_role_best_effort"
  ]
}'

# Anchor-pinned 100% line-and-branch regions inside the shared upload and
# import handlers, so the gate holds the #84 regions without absorbing
# their older debt.
FILE_ANCHOR_TARGETS_JSON='{
  "src/orchestrator/postgres_runtime_parts/local_import_support.py": [
    "upload_staging_paths",
    "upload_staging_mkdir",
    "upload_stream_digest_init",
    "upload_stream_digest_update",
    "upload_sha256_verify",
    "upload_dump_format"
  ],
  "src/orchestrator/postgres_runtime_parts/local_sql_import.py": [
    "import_staging_dir_local",
    "import_upload_staging_arg",
    "import_cancel_cleanup",
    "import_upload_error_cleanup",
    "import_finally_cleanup",
    "import_preflight_scan",
    "import_filtered_temp_cleanup",
    "import_temp_role_provision",
    "import_temp_role_drop",
    "import_command_by_format",
    "import_owner_role_preflight"
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

report_path = Path("coverage/postgres_local_import/coverage.json")
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
    print("\nPostgres local import coverage gate failed:")
    for failure in failures:
        print(f"- {failure}")
    sys.exit(1)

print("\nPostgres local import coverage gate passed.")
PY
