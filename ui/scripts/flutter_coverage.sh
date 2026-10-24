#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${APP_DIR}"
flutter test --coverage "$@"

python3 - <<'PY'
from pathlib import Path
import os
import re
import sys

lcov_path = Path("coverage/lcov.info")
if not lcov_path.exists():
    print("coverage/lcov.info was not generated", file=sys.stderr)
    sys.exit(1)

# Generated code is not first-party source. It is stripped from lcov.info
# itself, not merely from the calculation below, so that every downstream
# consumer -- IDE gutters, CI reporters, humans reading the file -- agrees with
# the number this script prints.
GENERATED = re.compile(r"\.(g|freezed)\.dart$")

# Hand-written files deliberately held out of the threshold. This is COVERAGE
# DEBT, not exclusion: each one is first-party code that should be covered and
# currently is not. The script prints what this list hides so it cannot rot
# quietly. Removing an entry is the goal; adding one needs a concrete reason.
COVERAGE_DEBT = {
    "lib/data/local/app_database.dart": (
        "Schema/migration coverage still needs a hermetic encrypted-Drift integration harness."
    ),
    "lib/ui/project/project_workspace.dart": (
        "The composite workspace still needs focused tab-composition widget coverage."
    ),
    "lib/ui/server/server_management_view.dart": (
        "Server-management provider transitions still need focused widget coverage."
    ),
}
# 4 until T-3.2.5. `lib/main.dart` left the list when the shell moved to
# `ui/shell/`: what remained was 37 executable lines, 35 of them covered,
# and the two that are not are `windowManager.show()`/`focus()` inside the
# ready-to-show callback -- which needs a real window, not a harness. Two
# lines is not debt worth a register entry.
COVERAGE_DEBT_BASELINE = 3

if not isinstance(COVERAGE_DEBT, dict):
    print("COVERAGE_DEBT must map each held-out file to its reason", file=sys.stderr)
    sys.exit(1)
if len(COVERAGE_DEBT) > COVERAGE_DEBT_BASELINE:
    print(
        "Flutter coverage-debt list grew; cover the file instead of excluding it",
        file=sys.stderr,
    )
    sys.exit(1)
for debt_path, debt_reason in COVERAGE_DEBT.items():
    if not isinstance(debt_path, str) or not isinstance(debt_reason, str) or not debt_reason.strip():
        print(
            f"Flutter coverage debt {debt_path!r} must carry a non-empty reason",
            file=sys.stderr,
        )
        sys.exit(1)

records, current, keep = [], [], True
for line in lcov_path.read_text().splitlines():
    if line.startswith("SF:"):
        current = [line]
        keep = not GENERATED.search(line[3:])
        continue
    current.append(line)
    if line.strip() == "end_of_record":
        if keep:
            records.append(current)
        current = []

lcov_path.write_text("\n".join("\n".join(r) for r in records) + "\n")

def rel(source_line):
    source = source_line[3:]
    return source[source.find("lib/"):] if "lib/" in source else source

total_hit = total_all = 0
debt_hit = debt_all = 0
for record in records:
    name = rel(record[0])
    for line in record:
        if not line.startswith("DA:"):
            continue
        count = int(line.split(",", 1)[1])
        if name in COVERAGE_DEBT:
            debt_all += 1
            debt_hit += count > 0
            continue
        total_all += 1
        total_hit += count > 0

pct = (total_hit / total_all) * 100 if total_all else 0.0
threshold = float(os.environ.get("SCOPED_COVERAGE_THRESHOLD", "80"))

print(f"First-party coverage: {pct:.2f}% ({total_hit}/{total_all}) "
      f"(threshold {threshold:.2f}%)")
print("Generated files (*.g.dart, *.freezed.dart) stripped from lcov.info.")
if debt_all:
    print(f"Coverage debt held out of the threshold: "
          f"{debt_all - debt_hit} uncovered lines across "
          f"{len(COVERAGE_DEBT)} files -- {', '.join(sorted(COVERAGE_DEBT))}")
    for debt_path in sorted(COVERAGE_DEBT):
        print(f"  {debt_path}: {COVERAGE_DEBT[debt_path]}")

if pct < threshold:
    print(f"First-party coverage {pct:.2f}% is below {threshold:.2f}%",
          file=sys.stderr)
    sys.exit(1)
PY
