#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COVERAGE_DIR="${APP_DIR}/coverage/database"

cd "${APP_DIR}"
rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

run_coverage() {
  local output_path="$1"
  shift
  flutter test --coverage --branch-coverage --coverage-path "${output_path}" "$@"
}

run_coverage \
  "${COVERAGE_DIR}/repositories.lcov" \
  test/data/local/app_environment_variable_repository_test.dart \
  test/data/local/project_repository_test.dart \
  test/data/local/project_database_access_repository_test.dart \
  test/data/local/app_database/ \
  test/data/local/app_release_repository_test.dart \
  test/data/local/server_credential_repository_test.dart \
  test/data/local/server_config_json_codecs_test.dart \
  test/data/local/terminal_log_repository_test.dart \
  test/data/local/worker_instance_repository_test.dart \
  test/data/local/project_sqlite_snapshot_repository_test.dart \
  test/data/local/project_sqlite_database_repository_test.dart \
  test/data/local/sqlite_validation_test.dart \
  test/providers/project_provider_test.dart

run_coverage \
  "${COVERAGE_DIR}/runtime_env.lcov" \
  test/postgres_runtime_env_test.dart

run_coverage \
  "${COVERAGE_DIR}/workspace.lcov" \
  test/ui/project/workspace/

python3 - <<'PY'
from collections import defaultdict
from pathlib import Path
import os
import sys

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import CoverageGateDefinitionError, covered_lines_in_spans

coverage_dir = Path("coverage/database")
coverage_files = sorted(coverage_dir.glob("*.lcov"))
if not coverage_files:
    print("Database coverage runs did not generate any LCOV output.", file=sys.stderr)
    sys.exit(1)

merged = defaultdict(lambda: defaultdict(int))
merged_branches = defaultdict(lambda: defaultdict(int))
for lcov_path in coverage_files:
    current_file = None
    for line in lcov_path.read_text().splitlines():
        if line.startswith("SF:"):
            current_file = line[3:]
            continue
        if line == "end_of_record":
            current_file = None
            continue
        if current_file is None:
            continue
        if line.startswith("DA:"):
            line_number_text, count_text = line[3:].split(",", 1)
            merged[current_file][int(line_number_text)] += int(count_text)
        elif line.startswith("BRDA:"):
            branch_key, taken_text = line[5:].rsplit(",", 1)
            merged_branches[current_file][branch_key] += int(taken_text)

merged_lcov_path = coverage_dir / "lcov.info"
with merged_lcov_path.open("w", encoding="utf-8") as handle:
    for file_path in sorted(set(merged) | set(merged_branches)):
        handle.write(f"SF:{file_path}\n")
        for line_number in sorted(merged.get(file_path, {})):
            handle.write(f"DA:{line_number},{merged[file_path][line_number]}\n")
        for branch_key in sorted(merged_branches.get(file_path, {})):
            handle.write(f"BRDA:{branch_key},{merged_branches[file_path][branch_key]}\n")
        handle.write("end_of_record\n")

include_files = {
    "lib/data/local/app_environment_variable_repository.dart",
    "lib/data/local/project_repository.dart",
    "lib/data/local/project_database_access_repository.dart",
    "lib/data/local/project_sqlite_snapshot_repository.dart",
    "lib/data/local/project_sqlite_database_repository.dart",
    "lib/data/local/sqlite_validation.dart",
    "lib/data/local/worker_instance_repository.dart",
    "lib/data/local/server_credential_repository.dart",
    "lib/data/local/server_config_json_codecs.dart",
    "lib/providers/project_provider.dart",
    "lib/postgres_runtime_env.dart",
}
anchor_targets = {
    "lib/data/local/app_release_repository.dart": (
        "diagnostic_journal_request",
        "diagnostic_journal_result",
        "journal_status_lists",
    ),
    "lib/data/local/app_database.dart": (
        "app_database_passphrase_failure",
        "app_database_passphrase_creation_handle",
        "app_database_passphrase_proof",
        "app_database_sidecar_paths",
        "debug_repair_missing_app_database_user_version",
    ),
    "lib/data/local/project_managed_database_repository.dart": (
        "journal_credential_uri",
        "journal_credential_password",
        "journal_credential_marker",
    ),
    "lib/data/local/terminal_log_repository.dart": (
        "terminal_persistence_sanitization",
    ),
    "lib/ui/project/workspace/database/database_tab.dart": (
        "database_selection_bind",
        "database_error_state",
        "database_tab_build",
        "detached_storage_local_catalog",
        "detached_storage_readiness",
        "detached_storage_card",
    ),
    "lib/ui/project/workspace/database/database_create_sqlite_dialog.dart": (
        "create_sqlite_database_dialog",
    ),
    "lib/ui/project/workspace/database/database_tab_postgres_operations.dart": (
        "database_mutation",
        "normalize_database_isolation",
        "detached_storage_expectations",
        "detached_storage_project_request",
        "detached_storage_error_mapping",
        "detached_storage_error_state",
        "detached_storage_success_mapping",
        "detached_storage_success_state",
        "detached_storage_failure_reset",
    ),
    "lib/ui/project/workspace/database/database_restore_sql_dialog.dart": (
        "restore_local_postgres_sql",
    ),
    "lib/ui/project/workspace/database/database_project_sharing_card.dart": (
        "refresh_linked_projects",
    ),
    "lib/ui/project/workspace/database/database_sqlite_card.dart": (
        "sqlite_card",
    ),
}
threshold = float(os.environ.get("DATABASE_COVERAGE_THRESHOLD", "100"))

current_file = None
by_file = {path: {"hit": 0, "total": 0} for path in include_files}
coverage = {}
branch_coverage = {}

for line in merged_lcov_path.read_text().splitlines():
    if line.startswith("SF:"):
        source = line[3:]
        current_file = source[source.find("lib/"):] if "lib/" in source else source
        continue
    if line.startswith("BRDA:"):
        branch_key, taken_text = line[5:].rsplit(",", 1)
        branch_coverage.setdefault(current_file, {})[branch_key] = int(taken_text)
        continue
    if not line.startswith("DA:"):
        continue

    line_number_text, count_text = line[3:].split(",", 1)
    line_number = int(line_number_text)
    count = int(count_text)
    if current_file in by_file:
        by_file[current_file]["total"] += 1
        if count > 0:
            by_file[current_file]["hit"] += 1
    coverage.setdefault(current_file, {})[line_number] = count

covered = total = 0
for file_path in sorted(include_files):
    file_hit = by_file[file_path]["hit"]
    file_total = by_file[file_path]["total"]
    covered += file_hit
    total += file_total
    percent = (file_hit / file_total * 100.0) if file_total else 0.0
    print(f"{file_path}: {percent:.2f}% ({file_hit}/{file_total})")

for target, anchors in sorted(anchor_targets.items()):
    try:
        selected = covered_lines_in_spans(
            Path(target),
            anchors,
            coverage.get(target, {}),
            language="dart",
        )
    except CoverageGateDefinitionError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    anchor_hit = sum(1 for line_number in selected if coverage[target][line_number] > 0)
    anchor_total = len(selected)
    covered += anchor_hit
    total += anchor_total
    percent = (anchor_hit / anchor_total * 100.0) if anchor_total else 0.0
    print(f"{target}::{', '.join(anchors)}: {percent:.2f}% ({anchor_hit}/{anchor_total})")

overall = (covered / total * 100.0) if total else 0.0
print(
    "Database desktop coverage: "
    f"{overall:.2f}% ({covered}/{total}) "
    f"(threshold {threshold:.2f}%)"
)

if overall < threshold:
    print(
        f"Database desktop coverage {overall:.2f}% is below {threshold:.2f}%",
        file=sys.stderr,
    )
    sys.exit(1)

# Branch enforcement, scoped to the #62-touched whole-file target: the
# credential repository, whose line scope this gate already owns. Other
# targets stay line-gated as before.
branch_file_targets = {
    "lib/data/local/server_credential_repository.dart",
}
branch_failures = []
for file_path in sorted(branch_file_targets):
    branches = list(branch_coverage.get(file_path, {}).values())
    file_total = len(branches)
    file_hit = sum(1 for taken in branches if taken > 0)
    percent = (file_hit / file_total * 100.0) if file_total else 0.0
    print(f"{file_path} (branch): {percent:.2f}% ({file_hit}/{file_total})")
    if file_total == 0 or file_hit < file_total:
        branch_failures.append(file_path)

if branch_failures:
    print(
        "Database branch coverage failed: "
        + ", ".join(branch_failures),
        file=sys.stderr,
    )
    sys.exit(1)

# Span-scoped branch enforcement for new anchors: whole-file branch scope
# would fail on pre-existing build branches, so each new anchor pins the
# BRDA records on its own lines instead.
branch_anchor_targets = {
    "lib/data/local/app_database.dart": (
        "app_database_passphrase_proof",
        "app_database_sidecar_paths",
    ),
    "lib/data/local/app_release_repository.dart": (
        "diagnostic_journal_request",
        "diagnostic_journal_result",
        "journal_status_lists",
    ),
    "lib/data/local/project_managed_database_repository.dart": (
        "journal_credential_uri",
        "journal_credential_password",
        "journal_credential_marker",
    ),
    "lib/data/local/terminal_log_repository.dart": (
        "terminal_persistence_sanitization",
    ),
    "lib/ui/project/workspace/database/database_tab.dart": (
        "normalize_database_button",
        "detached_storage_local_catalog",
        "detached_storage_readiness",
        "detached_storage_card",
    ),
    "lib/ui/project/workspace/database/database_tab_postgres_operations.dart": (
        "normalize_database_isolation",
        "detached_storage_expectations",
        "detached_storage_project_request",
        "detached_storage_error_mapping",
        "detached_storage_error_state",
        "detached_storage_success_mapping",
        "detached_storage_success_state",
        "detached_storage_failure_reset",
    ),
}

span_branch_failures = []
for target, anchors in sorted(branch_anchor_targets.items()):
    try:
        selected = set(
            covered_lines_in_spans(
                Path(target),
                anchors,
                coverage.get(target, {}),
                language="dart",
            )
        )
    except CoverageGateDefinitionError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    uncovered = sorted(
        key
        for key, taken in branch_coverage.get(target, {}).items()
        if int(key.split(",", 1)[0]) in selected and taken == 0
    )
    branch_total = sum(
        1
        for key in branch_coverage.get(target, {})
        if int(key.split(",", 1)[0]) in selected
    )
    print(
        f"{target}::{', '.join(anchors)} (branch): "
        f"{branch_total - len(uncovered)}/{branch_total}"
    )
    if uncovered:
        print(f"  uncovered branches: {uncovered}")
        span_branch_failures.append(target)

if span_branch_failures:
    print(
        "Database span branch coverage failed: "
        + ", ".join(span_branch_failures),
        file=sys.stderr,
    )
    sys.exit(1)
PY
