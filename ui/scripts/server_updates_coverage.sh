#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/server_updates"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

flutter test --coverage --branch-coverage \
  test/ui/server/server_management/ \
  test/ui/server/updates_tab_logic_test.dart \
  --coverage-path "${LCOV_PATH}"

python3 - <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import (
    CoverageGateDefinitionError,
    resolve_dart_anchor_spans,
)

lcov_path = Path("coverage/server_updates/lcov.info")
# T-3.3.6 gave the tab a logic file; the gate follows both halves.
targets = [
    "lib/ui/server/management/updates_tab.dart",
    "lib/ui/server/management/updates_tab_logic.dart",
]
# Branch scope stays on anchored spans: the files carry pre-existing
# defensive arcs (unreachable !mounted early-returns) that whole-file
# branch enforcement would absorb as new debt.
branch_anchors = {
    "lib/ui/server/management/updates_tab.dart": (
        "postgres_rollback_action",
        "postgres_rollback_dialogs",
    ),
    "lib/ui/server/management/updates_tab_logic.dart": (
        "postgres_rollback_choice_fields",
        "postgres_rollback_choice_offer",
    ),
}

if not lcov_path.exists():
    print("coverage/server_updates/lcov.info was not generated", file=sys.stderr)
    sys.exit(1)

current_file = None
hit = 0
total = 0
branches = {}

for line in lcov_path.read_text().splitlines():
    if line.startswith("SF:"):
        source = line[3:]
        current_file = source[source.find("lib/"):] if "lib/" in source else source
        continue
    if current_file not in targets:
        continue
    if line.startswith("DA:"):
        total += 1
        _, count_text = line.split(",", 1)
        if int(count_text) > 0:
            hit += 1
    elif line.startswith("BRDA:"):
        line_no_text, _, _, taken_text = line[5:].split(",")
        taken = int(taken_text) if taken_text != "-" else 0
        branches.setdefault(current_file, []).append((int(line_no_text), taken))

percent = (hit / total * 100.0) if total else 0.0
print(f"{', '.join(targets)}: {percent:.2f}% ({hit}/{total})")

if total == 0 or abs(percent - 100.0) > 1e-9:
    print("Server updates coverage gate failed", file=sys.stderr)
    sys.exit(1)

try:
    anchor_spans = {
        target: resolve_dart_anchor_spans(Path(target), anchors)
        for target, anchors in branch_anchors.items()
    }
except CoverageGateDefinitionError as error:
    print(f"Server updates coverage gate failed: {error}", file=sys.stderr)
    sys.exit(1)

uncovered_branches = []
anchored_total = 0
for target, spans in anchor_spans.items():
    for line_no, taken in branches.get(target, []):
        if not any(start <= line_no <= end for start, end in spans.values()):
            continue
        anchored_total += 1
        if taken <= 0:
            uncovered_branches.append(f"{target}:{line_no}")

print(f"anchored branches: {anchored_total - len(uncovered_branches)}/{anchored_total}")
if uncovered_branches:
    print("Server updates branch gate failed:", file=sys.stderr)
    for branch in sorted(uncovered_branches):
        print(f"- uncovered anchored branch {branch}", file=sys.stderr)
    sys.exit(1)

print("Server updates coverage gate passed.")
PY
