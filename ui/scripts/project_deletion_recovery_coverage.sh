#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COVERAGE_DIR="${APP_DIR}/coverage/project_deletion_recovery"
CORE_COVERAGE_PATH="${COVERAGE_DIR}/core.lcov.info"
UI_COVERAGE_PATH="${COVERAGE_DIR}/ui.lcov.info"

cd "${APP_DIR}"
rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

flutter test \
  --coverage \
  --branch-coverage \
  --coverage-path "${CORE_COVERAGE_PATH}" \
  test/data/local/project_deletion_recovery_repository_test.dart \
  test/services/project_deletion_coordinator_test.dart

flutter test \
  --coverage \
  --branch-coverage \
  --coverage-path "${UI_COVERAGE_PATH}" \
  --name 'displayBucketTypeLabel|Home dashboard|Settings tab' \
  test/ui/layout/home_dashboard_view_test.dart \
  test/ui/project/workspace/

python3 - "${CORE_COVERAGE_PATH}" "${UI_COVERAGE_PATH}" <<'PY'
from pathlib import Path
import sys

coverage_paths = [Path(value) for value in sys.argv[1:]]
core_targets = {
    "lib/data/local/project_deletion_recovery_repository.dart",
    "lib/services/project_deletion_coordinator.dart",
}
ui_targets = {
    "lib/ui/layout/home_dashboard_view.dart",
    "lib/ui/project/workspace/settings/settings_tab.dart",
}
targets = core_targets | ui_targets
stats = {target: {"hit": 0, "total": 0, "missed": []} for target in targets}
branch_stats = {}

for coverage_path, allowed_targets in zip(
    coverage_paths,
    (core_targets, ui_targets),
    strict=True,
):
    current = None
    for line in coverage_path.read_text().splitlines():
        if line.startswith("SF:"):
            source = line[3:]
            current = source[source.find("lib/"):] if "lib/" in source else source
            continue
        if current not in allowed_targets:
            continue
        if line.startswith("BRDA:"):
            branch_key, taken_text = line[5:].rsplit(",", 1)
            branch_stats.setdefault(current, {})[branch_key] = int(taken_text)
            continue
        if not line.startswith("DA:"):
            continue
        line_number, count_text = line[3:].split(",", 1)
        count = int(count_text)
        stats[current]["total"] += 1
        if count > 0:
            stats[current]["hit"] += 1
        else:
            stats[current]["missed"].append(int(line_number))

bad = []
covered = 0
executable = 0
for target in sorted(targets):
    item = stats[target]
    hit = item["hit"]
    total = item["total"]
    covered += hit
    executable += total
    percent = 100.0 * hit / total if total else 0.0
    print(f"{target}: {percent:.2f}% ({hit}/{total})")
    if total == 0 or hit != total:
        print(f"  missing: {item['missed']}")
        bad.append(target)

if bad:
    print("Project deletion recovery coverage gate failed.", file=sys.stderr)
    raise SystemExit(1)

print(
    "Project deletion recovery coverage: "
    f"{100.0 * covered / executable:.2f}% ({covered}/{executable})"
)

# Branch enforcement, scoped to the #80-touched whole-file target: the
# deletion coordinator, whose line scope this gate already owns. Other
# targets stay line-gated as before.
branch_file_targets = {
    "lib/services/project_deletion_coordinator.dart",
}
branch_failures = []
for file_path in sorted(branch_file_targets):
    branches = list(branch_stats.get(file_path, {}).values())
    file_total = len(branches)
    file_hit = sum(1 for taken in branches if taken > 0)
    percent = 100.0 * file_hit / file_total if file_total else 0.0
    print(f"{file_path} (branch): {percent:.2f}% ({file_hit}/{file_total})")
    if file_total == 0 or file_hit < file_total:
        branch_failures.append(file_path)

if branch_failures:
    print(
        "Project deletion recovery branch coverage failed: "
        + ", ".join(branch_failures),
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
