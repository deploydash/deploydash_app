#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/services"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

rm -rf "${COVERAGE_DIR}"

flutter test --coverage --branch-coverage \
  test/ui/server/services_logic_test.dart \
  test/ui/server/server_management/ \
  test/services/sensitive_data_sanitizer_test.dart \
  test/ssh_service_test.dart \
  --coverage-path "${LCOV_PATH}"

python3 - <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import (
    CoverageGateDefinitionError,
    covered_lines_in_spans,
)

targets = {
    "lib/ui/server/management/services_tab_logic.dart",
    "lib/services/ssh_service.dart",
    "lib/utils/sensitive_data_sanitizer.dart",
    "lib/ui/server/management/services_postgres_storage_footer.dart",
    "lib/ui/server/management/services_postgres_storage_migrate_dialog.dart",
    "lib/ui/server/management/services_postgres_upgrade_dialog.dart",
    "lib/ui/server/management/services_postgres_remote_access_footer.dart",
}
# Whole-file branch scope for the logic file and the new storage widgets;
# ssh_service keeps its line-only enforcement as an untouched file.
branch_file_targets = {
    "lib/ui/server/management/services_tab_logic.dart",
    "lib/ui/server/management/services_postgres_storage_footer.dart",
    "lib/ui/server/management/services_postgres_storage_migrate_dialog.dart",
    "lib/ui/server/management/services_postgres_upgrade_dialog.dart",
    "lib/ui/server/management/services_postgres_remote_access_footer.dart",
}
anchor_targets = {
    "lib/data/local/backup_repository.dart": (
        "backup_service_policy_catalog_cleanup",
    ),
    "lib/providers/backup_provider.dart": (
        "backup_service_policy_cache_cleanup",
    ),
    "lib/ui/server/management/services_tab_actions.dart": (
        "postgres_remote_access_source_settings",
        "postgres_expected_databases",
        "postgres_major_upgrade_action",
        "postgres_service_delete_policy_catalog",
        "postgres_storage_migrate_action",
        "postgres_storage_remove_action",
        "postgres_storage_status_revalidate",
    ),
    "lib/ui/server/management/services_tab_status_operations.dart": (
        "postgres_remote_access_tls_status",
        "postgres_storage_status_refresh",
    ),
    "lib/ui/server/management/services_tab.dart": (
        "postgres_remote_access_security_fields",
        "postgres_remote_access_security_reset",
    ),
}

coverage = {}
branch_coverage = {}
current = None

for line in Path("coverage/services/lcov.info").read_text().splitlines():
    if line.startswith("SF:"):
        sf = line[3:]
        current = sf[sf.index("lib/"):] if "lib/" in sf else None
        continue
    if current is None:
        continue
    if line.startswith("DA:"):
        _, rest = line.split(":", 1)
        line_no, hits = rest.split(",")
        coverage.setdefault(current, {})[int(line_no)] = int(hits)
    elif line.startswith("BRDA:"):
        branch_key, taken_text = line[5:].rsplit(",", 1)
        branch_coverage.setdefault(current, {})[branch_key] = int(taken_text)

bad = []
for target in sorted(targets):
    counts = coverage.get(target, {})
    found = len(counts)
    hit = sum(1 for count in counts.values() if count > 0)
    pct = (100.0 * hit / found) if found else 0.0
    print(f"{target}: {hit}/{found} lines ({pct:.2f}%)")
    if found == 0 or abs(pct - 100.0) > 1e-9:
        bad.append(target)

for target in sorted(branch_file_targets):
    branches = list(branch_coverage.get(target, {}).values())
    file_total = len(branches)
    file_hit = sum(1 for taken in branches if taken > 0)
    pct = (file_hit / file_total * 100.0) if file_total else 0.0
    print(f"{target} (branch): {file_hit}/{file_total} ({pct:.2f}%)")
    if file_total == 0 or file_hit < file_total:
        bad.append(f"{target} (branch)")

for target, anchors in sorted(anchor_targets.items()):
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
        bad.append(f"{target}::{','.join(anchors)} (anchor definition)")
        continue
    file_lines = coverage.get(target, {})
    uncovered_lines = sorted(
        line_no for line_no in selected if file_lines.get(line_no, 0) == 0
    )
    uncovered_branches = sorted(
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
        f"{target}::{','.join(anchors)}: "
        f"lines {len(selected) - len(uncovered_lines)}/{len(selected)}, "
        f"branches {branch_total - len(uncovered_branches)}/{branch_total}"
    )
    if uncovered_lines:
        print(f"  uncovered lines: {uncovered_lines}")
    if uncovered_branches:
        print(f"  uncovered branches: {uncovered_branches}")
    if uncovered_lines or uncovered_branches:
        bad.append(f"{target}::{','.join(anchors)}")

if bad:
    print("\nServices coverage gate failed:")
    for target in bad:
        print(f"- {target}")
    sys.exit(1)

print("\nServices coverage gate passed.")
PY
