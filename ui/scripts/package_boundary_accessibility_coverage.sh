#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COVERAGE_DIR="${APP_DIR}/coverage/package_boundary_accessibility"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

mkdir -p "${COVERAGE_DIR}"

cd "${APP_DIR}"
flutter test \
  --coverage \
  --branch-coverage \
  --coverage-path="${LCOV_PATH}" \
  test/e2e_ax_identifier_guard_test.dart \
  test/ui/system/app_accessibility_identifier_test.dart \
  test/ui/startup/database_unlock_gate_test.dart \
  test/ui/server/server_onboarding_view_test.dart \
  test/ui/settings/desktop_updates_view_test.dart \
  test/ui/system/icon_control_semantics_test.dart

python3 - "${LCOV_PATH}" <<'PY'
from pathlib import Path
import sys

lcov_path = Path(sys.argv[1])
target = "lib/ui/system/app_accessibility_identifier.dart"
line_hits = []
branch_hits = []
current = None

for line in lcov_path.read_text(encoding="utf-8").splitlines():
    if line.startswith("SF:"):
        source = line[3:]
        current = "lib/" + source.split("lib/")[-1]
        continue
    if current != target:
        continue
    if line.startswith("DA:"):
        line_hits.append(int(line.split(",", 1)[1]))
    elif line.startswith("BRDA:"):
        branch_hits.append(int(line.rsplit(",", 1)[1]))

if not line_hits:
    raise SystemExit(f"No line coverage record found for {target}.")
if not branch_hits:
    raise SystemExit(f"No branch coverage record found for {target}.")

line_hit_count = sum(hit > 0 for hit in line_hits)
branch_hit_count = sum(hit > 0 for hit in branch_hits)
line_percent = 100.0 * line_hit_count / len(line_hits)
branch_percent = 100.0 * branch_hit_count / len(branch_hits)
print(
    f"{target}: lines {line_hit_count}/{len(line_hits)} "
    f"({line_percent:.2f}%), branches {branch_hit_count}/{len(branch_hits)} "
    f"({branch_percent:.2f}%)"
)

if line_hit_count != len(line_hits) or branch_hit_count != len(branch_hits):
    raise SystemExit(
        "Package-boundary accessibility coverage must remain at "
        "100.00% line and branch coverage."
    )

print("Package-boundary accessibility: 100.00% line and branch coverage.")
PY
