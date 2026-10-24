#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${APP_DIR}"

flutter test --coverage --concurrency=1 \
  test/ui/project/worker_runtime_contract_test.dart \
  test/ui/project/workers_tab_logic_test.dart

python3 - <<'PY'
from pathlib import Path
import os
import sys

lcov_path = Path("coverage/lcov.info")
if not lcov_path.exists():
    print("coverage/lcov.info was not generated", file=sys.stderr)
    sys.exit(1)

# T-3.3.6 extracted the worker tab's value types and id rule out of the
# workspace part file, so this gate covers both worker sources rather than one.
targets = {
    "lib/ui/project/workspace/workers/worker_runtime_contract.dart",
    "lib/ui/project/workspace/workers/workers_tab_logic.dart",
}
threshold = float(os.environ.get("WORKERS_COVERAGE_THRESHOLD", "100"))

current_file = None
covered = total = 0
missed = []

for line in lcov_path.read_text().splitlines():
    if line.startswith("SF:"):
        source = line[3:]
        current_file = source[source.find("lib/"):] if "lib/" in source else source
        continue

    if not line.startswith("DA:"):
        continue

    if current_file not in targets:
        continue
    line_number_text, count_text = line[3:].split(",", 1)
    total += 1
    if int(count_text) > 0:
        covered += 1
    else:
        missed.append(int(line_number_text))

overall = (covered / total * 100.0) if total else 0.0
print(
    "Workers desktop coverage: "
    f"{overall:.2f}% ({covered}/{total}) "
    f"(threshold {threshold:.2f}%)"
)
if missed:
    print(f"Missing lines: {missed}")

if total == 0 or overall < threshold:
    print(
        f"Workers desktop coverage {overall:.2f}% is below {threshold:.2f}%",
        file=sys.stderr,
    )
    sys.exit(1)
PY
