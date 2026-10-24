#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/ui_system"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

flutter test --coverage \
  test/ui/system/app_design_system_test.dart \
  test/ui/system/app_copy_test.dart \
  test/ui/system/app_search_test.dart \
  test/ui/layout/home_dashboard_view_test.dart \
  test/ui/layout/app_navigation_rail_test.dart \
  test/ui/server/server_onboarding_view_test.dart \
  test/ui/system/app_rows_test.dart \
  test/ui/system/app_cards_test.dart \
  test/providers/terminal_view_preferences_provider_test.dart \
  test/providers/theme_provider_test.dart \
  --coverage-path "${LCOV_PATH}"

python3 - <<'PY'
import sys
from pathlib import Path

targets = {
    "lib/ui/system/app_theme.dart",
    "lib/ui/system/app_sections.dart",
    "lib/ui/system/app_actions.dart",
    "lib/ui/system/app_context_navigation.dart",
    "lib/ui/system/app_workspace.dart",
    "lib/ui/system/app_dialogs.dart",
    "lib/ui/system/app_forms.dart",
    "lib/ui/system/app_state_views.dart",
    "lib/ui/system/app_copy.dart",
    "lib/ui/system/app_search.dart",
    "lib/ui/system/app_rows.dart",
    "lib/ui/system/app_cards.dart",
    "lib/providers/preference_notifier.dart",
    "lib/providers/terminal_view_preferences_provider.dart",
    "lib/providers/theme_provider.dart",
}

lcov_path = Path("coverage/ui_system/lcov.info")
if not lcov_path.exists():
    print("coverage/ui_system/lcov.info was not generated", file=sys.stderr)
    sys.exit(1)

stats = {target: {"hit": 0, "total": 0} for target in targets}
current = None

for line in lcov_path.read_text().splitlines():
    if line.startswith("SF:"):
        source = line[3:]
        current = source[source.find("lib/"):] if "lib/" in source else source
        continue
    if current not in stats or not line.startswith("DA:"):
        continue
    _, count_text = line.split(",", 1)
    stats[current]["total"] += 1
    if int(count_text) > 0:
        stats[current]["hit"] += 1

bad = []
for target, item in stats.items():
    total = item["total"]
    hit = item["hit"]
    pct = (hit / total) * 100 if total else 0.0
    print(f"{target}: {pct:.2f}% ({hit}/{total})")
    if abs(pct - 100.0) > 1e-9:
      bad.append(target)

if bad:
    print("\nDesktop UI system coverage gate failed:")
    for target in bad:
        print(f"- {target}")
    sys.exit(1)

print("\nDesktop UI system coverage gate passed.")
PY
