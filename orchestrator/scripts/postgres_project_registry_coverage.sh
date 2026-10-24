#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/postgres_project_registry"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

TEST_MODULES=(
  tests.postgres_backup_helpers_test
  tests.postgres_flow_failures_test
  tests.postgres_registry_test
  tests.postgres_config_test
  tests.postgres_agent_query_test
  tests.postgres_parsers_test
  tests.postgres_workflow_test
  tests.postgres_project_ops_test
  tests.postgres_service_storage_test
  tests.postgres_backup_helpers_test
)

INCLUDE_FILES=(
  "src/orchestrator/postgres_runtime_parts/users_and_grants.py"
  "src/orchestrator/postgres_runtime_parts/backup_operations.py"
  "src/orchestrator/postgres_runtime_parts/local_sql_import.py"
  "src/orchestrator/postgres_runtime_parts/project_registry.py"
  "src/orchestrator/postgres_parts/__init__.py"
  "src/orchestrator/postgres_parts/postgres_config.py"
  "src/orchestrator/postgres_runtime_parts/agent_access.py"
  "src/orchestrator/postgres_runtime_parts/service_configuration.py"
  "src/orchestrator/postgres_runtime_parts/database_lifecycle.py"
  "src/orchestrator/postgres_runtime_parts/project_inventory.py"
  "src/orchestrator/postgres_runtime_parts/backup_operations.py"
)

# Whole-symbol 100% line-and-branch targets per file: the registry module in
# full, plus the small #80-touched helpers whose entirety changed meaning.
# The shared flow handlers below are pinned by anchors instead, so the gate
# holds the #80 regions without absorbing their older debt.
FILE_SYMBOL_TARGETS_JSON='{
  "src/orchestrator/postgres_runtime_parts/project_registry.py": [
    "_postgres_registry_database_roles_sql",
    "_postgres_registry_bootstrap_sql",
    "_postgres_registry_register_database_sql",
    "_postgres_registry_unregister_database_sql",
    "_postgres_registry_register_role_sql",
    "_postgres_registry_unregister_role_sql",
    "_postgres_registry_lookup_sql",
    "_postgres_registry_owner_slug",
    "_postgres_registry_list_roles_sql",
    "_postgres_registry_list_databases_sql",
    "_postgres_registry_unregistered_databases_sql",
    "_postgres_registry_role_comment_rows_sql",
    "_postgres_backfill_parse_role_row",
    "_postgres_backfill_classify",
    "_load_postgres_backfill_input",
    "_backfill_postgres_project_registry",
    "_describe_postgres_registry_leftovers",
    "_ensure_postgres_project_registry"
  ],
  "src/orchestrator/postgres_parts/__init__.py": ["_params_schema", ""],
  "src/orchestrator/postgres_parts/postgres_config.py": [
    "parse_postgres_service_config",
    "_optional_string_list"
  ],
  "src/orchestrator/postgres_runtime_parts/agent_access.py": [
    "_parse_postgres_role_comment",
    "_postgres_implicit_connect_roles_sql",
    "_postgres_ensure_owner_role_sql",
    "_postgres_owner_membership_sql",
    "_postgres_revoke_public_connect_sql",
    "_postgres_owner_default_privileges_sql",
    "_postgres_reassign_owned_if_exists_sql",
    "_postgres_existing_roles_sql",
    "_postgres_ensure_agent_reader_role_sql",
    "_postgres_agent_reader_grants_sql",
    "_run_postgres_psql_query_impl"
  ],
  "src/orchestrator/postgres_runtime_parts/service_configuration.py": [
    "_postgres_prefixed_name"
  ],
  "src/orchestrator/postgres_runtime_parts/database_lifecycle.py": [
    "_postgres_force_drop_database",
    "_postgres_drop_database_failure_details"
  ],
  "src/orchestrator/postgres_runtime_parts/project_inventory.py": [
    "_project_list_not_ready_result"
  ],
  "src/orchestrator/postgres_runtime_parts/backup_operations.py": [
    "_postgres_restore_failure_with_cleanup"
  ]
}'

# Anchor-pinned 100% line-and-branch regions inside the shared flow handlers.
# The empty-string symbol target above is coverage.py's module-level entry:
# the new settings keys execute at import and carry no branches.
FILE_ANCHOR_TARGETS_JSON='{
  "src/orchestrator/postgres_runtime_parts/database_lifecycle.py": [
    "create_ownership_registration",
    "create_owner_provisioning",
    "create_reader_provisioning",
    "create_public_revoke",
    "delete_database_derived_roles_cleanup",
    "normalize_database_flow",
    "project_delete_registry_ensure",
    "project_delete_ownership_unregister",
    "project_delete_backup_cleanup",
    "create_rollback_unregister_role"
  ],
  "src/orchestrator/postgres_runtime_parts/project_inventory.py": [
    "project_list_registry_flow",
    "project_list_base_readiness",
    "project_list_storage_enrichment",
    "agent_reader_lazy_ensure"
  ],
  "src/orchestrator/postgres_runtime_parts/backup_operations.py": [
    "restore_run_now_atomic_flow",
    "backup_policy_delete_cleanup"
  ]
}'

INCLUDE_CSV="$(IFS=,; echo "${INCLUDE_FILES[*]}")"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TEST_MODULES[@]}"
uv run --with coverage coverage json --include="${INCLUDE_CSV}" -o "${REPORT_JSON}"

# Whole-file 100% line-and-branch targets: every file the #127 ownership
# gate touches is measured in full, so older debt in a touched file can
# never hide behind symbol or anchor targets again.
WHOLE_FILE_TARGETS_JSON='[
  "src/orchestrator/postgres_runtime_parts/backup_operations.py",
  "src/orchestrator/postgres_runtime_parts/database_lifecycle.py",
  "src/orchestrator/postgres_runtime_parts/local_sql_import.py",
  "src/orchestrator/postgres_runtime_parts/project_inventory.py",
  "src/orchestrator/postgres_runtime_parts/project_registry.py",
  "src/orchestrator/postgres_runtime_parts/users_and_grants.py"
]'

export FILE_SYMBOL_TARGETS_JSON FILE_ANCHOR_TARGETS_JSON WHOLE_FILE_TARGETS_JSON

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

report_path = Path("coverage/postgres_project_registry/coverage.json")
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

whole_file_targets = json.loads(os.environ["WHOLE_FILE_TARGETS_JSON"])
for file_path in whole_file_targets:
    payload = by_file.get(file_path)
    if payload is None:
        print(f"{file_path}: no coverage payload", file=sys.stderr)
        failures.append(f"{file_path} (missing)")
        continue
    summary = payload["summary"]
    print(
        f"{file_path} (whole file): "
        f"lines {summary['covered_lines']}/{summary['num_statements']}, "
        f"branches {summary['covered_branches']}/{summary['num_branches']}",
    )
    if payload.get("missing_lines"):
        print(f"  missing lines: {payload['missing_lines']}")
    if payload.get("missing_branches"):
        print(f"  missing arcs: {payload['missing_branches']}")
    if payload.get("missing_lines") or payload.get("missing_branches"):
        failures.append(f"{file_path} (whole file)")

if failures:
    print("\nPostgres project registry coverage gate failed:")
    for failure in failures:
        print(f"- {failure}")
    sys.exit(1)

print("\nPostgres project registry coverage gate passed.")
PY
