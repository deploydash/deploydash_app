#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/logs"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

rm -rf "${COVERAGE_DIR}"

flutter test --coverage --concurrency=1 \
  test/ui/project/log_tab_logic_test.dart \
  test/utils/terminal_output_filter_test.dart \
  --coverage-path "${LCOV_PATH}"

python3 - <<'PY'
import sys
from pathlib import Path

targets = {
    "lib/ui/project/workspace/logs/log_tab_logic.dart",
    "lib/utils/terminal_output_filter.dart",
}

records = {target: {} for target in targets}
current = None

for line in Path("coverage/logs/lcov.info").read_text().splitlines():
    if line.startswith("SF:"):
        sf = line[3:]
        current = sf[sf.index("lib/"):] if "lib/" in sf else None
    elif current in records and line.startswith("DA:"):
        _, rest = line.split(":", 1)
        line_no, hits = rest.split(",")
        records[current][int(line_no)] = int(hits)
    elif line == "end_of_record":
        current = None

bad = []
for target in sorted(targets):
    found = len(records[target])
    hit = sum(1 for count in records[target].values() if count > 0)
    pct = (100.0 * hit / found) if found else 0.0
    print(f"{target}: {hit}/{found} lines ({pct:.2f}%)")
    if found == 0 or abs(pct - 100.0) > 1e-9:
        bad.append(target)

if bad:
    print("\nLogs coverage gate failed:")
    for target in bad:
        print(f"- {target}")
    sys.exit(1)

print("\nLogs coverage gate passed.")
PY
