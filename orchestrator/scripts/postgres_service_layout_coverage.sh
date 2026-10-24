#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/postgres_service_layout"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

TEST_MODULES=(
  tests.postgres_major_upgrade_test
  tests.postgres_workflow_test
  tests.golden_artifacts_test
  tests.postgres_service_storage_test
)

INCLUDE_FILES=(
  "src/orchestrator/postgres_runtime_parts/service_configuration.py"
  "src/orchestrator/postgres_runtime_parts/service_storage.py"
  "src/orchestrator/postgres_runtime_parts/service_runtime.py"
  "src/orchestrator/postgres_runtime_parts/tls_policy.py"
)

# Whole-symbol 100% line-and-branch targets for the #85 storage layout:
# the unified named-volume mount, the PGDATA path derived from it, the
# compose text that carries both to the server, and every inspection,
# migration, removal and verification helper in service_storage.
FILE_SYMBOL_TARGETS_JSON='{
  "src/orchestrator/postgres_runtime_parts/service_configuration.py": [
    "_postgres_data_volume_target",
    "_postgres_pgdata_path",
    "_postgres_hba_text",
    "_postgres_tls_bootstrap_command",
    "_postgres_service_compose_text",
    "_postgres_base_env_bootstrap_command",
    "_postgres_service_status_command"
  ],
  "src/orchestrator/postgres_runtime_parts/service_storage.py": [
    "_postgres_storage_inspect_mounts_command",
    "_postgres_parse_storage_mounts",
    "_postgres_find_pgdata_source_volume",
    "_postgres_storage_volume_is_anonymous",
    "_postgres_storage_disk_space_command",
    "_postgres_storage_safety_dump_command",
    "_postgres_storage_stop_command",
    "_postgres_checked_storage_subpath",
    "_postgres_storage_copy_command",
    "_postgres_storage_backup_compose_command",
    "_postgres_storage_restore_compose_command",
    "_postgres_storage_cleanup_compose_backup_command",
    "_postgres_storage_inventory_queries",
    "_postgres_storage_remove_volume_command",
    "_postgres_storage_remove_legacy_subdir_command",
    "_postgres_storage_missing_expected_databases",
    "_postgres_storage_clean_name_lines",
    "_postgres_storage_first_output_line",
    "_storage_migration_cancelled",
    "_run_storage_host_command",
    "_run_storage_psql_query",
    "_rollback_storage_migration_to_backup",
    "_fail_storage_migration_with_rollback",
    "_postgres_storage_is_migrated_layout",
    "_postgres_storage_verify_final_mount",
    "run_postgres_storage_migration",
    "run_postgres_legacy_storage_removal",
    "_postgres_storage_data_size_sql",
    "_postgres_storage_dangling_volumes_command",
    "_postgres_storage_detached_description",
    "_postgres_storage_detached_container_status",
    "_postgres_storage_expected_databases",
    "enrich_postgres_service_status"
  ],
  "src/orchestrator/postgres_runtime_parts/tls_policy.py": [
    "postgres_tls_key_pair_check_shell"
  ]
}'

FILE_ANCHOR_TARGETS_JSON='{
  "src/orchestrator/postgres_runtime_parts/service_runtime.py": [
    "preserve_live_data_volume",
    "storage_status_enrich",
    "postgres_service_delete_cleanup_plan",
    "postgres_service_delete_cleanup_state",
    "postgres_service_delete_cleanup_parse",
    "postgres_service_delete_cleanup_response"
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

report_path = Path("coverage/postgres_service_layout/coverage.json")
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
    print("\nPostgres service layout coverage gate failed:")
    for failure in failures:
        print(f"- {failure}")
    sys.exit(1)

print("\nPostgres service layout coverage gate passed.")
PY
