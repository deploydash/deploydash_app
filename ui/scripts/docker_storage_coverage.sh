#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/docker_storage"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

flutter test --coverage \
  test/ui/server/server_docker_storage_logic_test.dart \
  test/ui/server/server_management/ \
  --coverage-path "${LCOV_PATH}"

python3 - <<'PY'
import sys
from pathlib import Path

targets = {
    "lib/ui/server/management/server_docker_storage_logic.dart",
    "lib/ui/server/management/docker_storage_section.dart",
}

lcov_path = Path("coverage/docker_storage/lcov.info")
if not lcov_path.exists():
    print("coverage/docker_storage/lcov.info was not generated", file=sys.stderr)
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
    print("\nDocker storage desktop coverage gate failed:")
    for target in bad:
        print(f"- {target}")
    sys.exit(1)

print("\nDocker storage desktop coverage gate passed.")
PY
