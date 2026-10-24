#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/workspace_ux"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

flutter test --coverage --concurrency=1 \
  test/ui/system/app_design_system_test.dart \
  test/ui/system/app_search_test.dart \
  test/ui/layout/app_navigation_rail_test.dart \
  test/ui/layout/navigation_rail_test.dart \
  test/ui/layout/home_dashboard_view_test.dart \
  test/ui/layout/home_telemetry_nag_test.dart \
  test/ui/layout/shell_page_test.dart \
  test/ui/project/workspace/ \
  test/ui/project/create_project_view_test.dart \
  test/ui/server/server_management/ \
  test/ui/server/server_onboarding_view_test.dart \
  test/ui/settings/app_settings_view_test.dart \
  --coverage-path "${LCOV_PATH}"

python3 - <<'PY'
import sys
from pathlib import Path

targets = {
    "lib/ui/system/app_context_navigation.dart",
    "lib/ui/system/app_forms.dart",
    "lib/ui/system/app_sections.dart",
    "lib/ui/system/app_theme.dart",
    "lib/ui/system/app_workspace.dart",
    "lib/ui/system/app_search.dart",
    "lib/ui/layout/home_telemetry_nag_card.dart",
}

lcov_path = Path("coverage/workspace_ux/lcov.info")
if not lcov_path.exists():
    print(f"{lcov_path} was not generated", file=sys.stderr)
    sys.exit(1)

stats = {target: {"hit": 0, "total": 0, "missed": []} for target in targets}
current = None
for line in lcov_path.read_text().splitlines():
    if line.startswith("SF:"):
        source = line[3:]
        current = source[source.find("lib/"):] if "lib/" in source else source
        continue
    if current not in stats or not line.startswith("DA:"):
        continue
    line_number, count_text = line[3:].split(",", 1)
    count = int(count_text)
    stats[current]["total"] += 1
    if count > 0:
        stats[current]["hit"] += 1
    else:
        stats[current]["missed"].append(int(line_number))

bad = []
for target in sorted(targets):
    item = stats[target]
    total = item["total"]
    hit = item["hit"]
    percent = 100.0 * hit / total if total else 0.0
    print(f"{target}: {hit}/{total} workspace lines ({percent:.2f}%)")
    if total == 0 or abs(percent - 100.0) > 1e-9:
        print(f"  missing: {item['missed']}")
        bad.append(target)

if bad:
    print("\nDesktop workspace UX coverage gate failed:")
    for target in bad:
        print(f"- {target}")
    sys.exit(1)

print("\nDesktop workspace UX coverage gate passed.")
PY
