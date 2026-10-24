#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/security_workspace"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

flutter test --coverage --branch-coverage \
  test/ui/server/firewall_tab_logic_test.dart \
  test/ui/server/server_management/ \
  --coverage-path "${LCOV_PATH}"

python3 - <<'PY'
import sys
from pathlib import Path

targets = {
    "lib/ui/server/management/firewall_tab_logic.dart",
}

lcov_path = Path("coverage/security_workspace/lcov.info")
if not lcov_path.exists():
    print("coverage/security_workspace/lcov.info was not generated", file=sys.stderr)
    sys.exit(1)

stats = {
    target: {"line_hit": 0, "line_total": 0, "branch_hit": 0, "branch_total": 0}
    for target in targets
}
current = None

for line in lcov_path.read_text().splitlines():
    if line.startswith("SF:"):
        source = line[3:]
        current = source[source.find("lib/"):] if "lib/" in source else source
        continue
    if current not in stats:
        continue
    if line.startswith("DA:"):
        _, count_text = line.split(",", 1)
        stats[current]["line_total"] += 1
        if int(count_text) > 0:
            stats[current]["line_hit"] += 1
    elif line.startswith("BRDA:"):
        taken_text = line.rsplit(",", 1)[-1]
        stats[current]["branch_total"] += 1
        if taken_text != "-" and int(taken_text) > 0:
            stats[current]["branch_hit"] += 1

bad = []
for target, item in stats.items():
    line_total = item["line_total"]
    line_hit = item["line_hit"]
    line_pct = (line_hit / line_total) * 100 if line_total else 0.0
    branch_total = item["branch_total"]
    branch_hit = item["branch_hit"]
    branch_pct = (branch_hit / branch_total) * 100 if branch_total else 0.0
    print(
        f"{target}: lines {line_hit}/{line_total} ({line_pct:.2f}%), "
        f"branches {branch_hit}/{branch_total} ({branch_pct:.2f}%)"
    )
    if (
        abs(line_pct - 100.0) > 1e-9
        or branch_total == 0
        or abs(branch_pct - 100.0) > 1e-9
    ):
        bad.append(target)

if bad:
    print("\nSecurity workspace desktop coverage gate failed:")
    for target in bad:
        print(f"- {target}")
    sys.exit(1)

print("\nSecurity workspace desktop coverage gate passed.")
PY
