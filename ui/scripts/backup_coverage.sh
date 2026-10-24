#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COVERAGE_DIR="${APP_DIR}/coverage/backup"

cd "${APP_DIR}"
rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

run_coverage() {
  local output_path="$1"
  shift
  flutter test --branch-coverage --coverage-path "${output_path}" "$@"
}

run_coverage \
  "${COVERAGE_DIR}/logic.lcov" \
  test/ui/project/backup_logic_test.dart

run_coverage \
  "${COVERAGE_DIR}/workspace.lcov" \
  test/ui/project/workspace/

run_coverage \
  "${COVERAGE_DIR}/sqlite_service.lcov" \
  test/services/sqlite_backup_service_test.dart \
  test/services/sqlite_backup_retention_test.dart \
  test/services/sqlite_backup_d4_collapse_test.dart

run_coverage \
  "${COVERAGE_DIR}/repository.lcov" \
  test/data/local/backup_repository_test.dart

python3 - <<'PY'
from collections import defaultdict
from pathlib import Path
import os
import sys

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import CoverageGateDefinitionError, covered_lines_in_spans

coverage_dir = Path("coverage/backup")
coverage_files = sorted(coverage_dir.glob("*.lcov"))
if not coverage_files:
    print("Backup coverage runs did not generate any LCOV output.", file=sys.stderr)
    sys.exit(1)

merged = defaultdict(lambda: defaultdict(int))
merged_branches = defaultdict(lambda: defaultdict(int))
for lcov_path in coverage_files:
    current_file = None
    for line in lcov_path.read_text().splitlines():
        if line.startswith("SF:"):
            current_file = line[3:]
            continue
        if line == "end_of_record":
            current_file = None
            continue
        if current_file is None or not line.startswith("DA:"):
            if current_file is None or not line.startswith("BRDA:"):
                continue
            line_number, block, branch, count_text = line[5:].split(",", 3)
            count = 0 if count_text == "-" else int(count_text)
            merged_branches[current_file][
                (int(line_number), block, branch)
            ] += count
            continue
        line_number_text, count_text = line[3:].split(",", 1)
        merged[current_file][int(line_number_text)] += int(count_text)

merged_lcov_path = coverage_dir / "lcov.info"
with merged_lcov_path.open("w", encoding="utf-8") as handle:
    for file_path in sorted(merged):
        handle.write(f"SF:{file_path}\n")
        for line_number in sorted(merged[file_path]):
            handle.write(f"DA:{line_number},{merged[file_path][line_number]}\n")
        for (line_number, block, branch), count in sorted(
            merged_branches[file_path].items()
        ):
            handle.write(f"BRDA:{line_number},{block},{branch},{count}\n")
        handle.write("end_of_record\n")

anchor_targets = {
    "lib/services/backup_logic.dart": (
        "backup_workspace_logic",
    ),
    "lib/ui/project/workspace/backup/backup_state_methods.dart": (
        "backup_selection",
        "backup_journaled_workflow",
    ),
    "lib/ui/project/workspace/backup/backup_dialog_methods.dart": (
        "backup_destination_dialog",
    ),
    "lib/ui/project/workspace/backup/backup_tab.dart": (
        "backup_tab_build",
    ),
}
whole_file_targets = (
    "lib/services/sqlite_backup_service.dart",
    "lib/data/local/backup_repository.dart",
)
threshold = float(os.environ.get("BACKUP_COVERAGE_THRESHOLD", "100"))

current_file = None
coverage = defaultdict(dict)
branch_coverage = defaultdict(dict)

for line in merged_lcov_path.read_text().splitlines():
    if line.startswith("SF:"):
        source = line[3:]
        current_file = source[source.find("lib/"):] if "lib/" in source else source
        continue

    if line.startswith("BRDA:"):
        line_number, block, branch, count_text = line[5:].split(",", 3)
        branch_coverage[current_file][
            (int(line_number), block, branch)
        ] = int(count_text)
        continue

    if not line.startswith("DA:"):
        continue

    line_number_text, count_text = line[3:].split(",", 1)
    line_number = int(line_number_text)
    count = int(count_text)
    coverage[current_file][line_number] = count

covered = total = branch_covered = branch_total = 0
for target, anchors in sorted(anchor_targets.items()):
    try:
        selected = covered_lines_in_spans(
            Path(target),
            anchors,
            coverage.get(target, {}),
            language="dart",
        )
    except CoverageGateDefinitionError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    anchor_total = len(selected)
    anchor_hit = sum(1 for line_number in selected if coverage[target][line_number] > 0)
    covered += anchor_hit
    total += anchor_total
    selected_branches = [
        count
        for (line_number, _block, _branch), count in branch_coverage[target].items()
        if line_number in selected
    ]
    branch_hit = sum(count > 0 for count in selected_branches)
    branch_covered += branch_hit
    branch_total += len(selected_branches)
    percent = (anchor_hit / anchor_total * 100.0) if anchor_total else 0.0
    branch_percent = (
        branch_hit / len(selected_branches) * 100.0
        if selected_branches
        else 100.0
    )
    print(
        f"{target}::{', '.join(anchors)}: "
        f"lines {percent:.2f}% ({anchor_hit}/{anchor_total}), "
        f"branches {branch_percent:.2f}% ({branch_hit}/{len(selected_branches)})"
    )

for target in whole_file_targets:
    selected = coverage.get(target, {})
    if not selected:
        print(f"Missing whole-file coverage for {target}", file=sys.stderr)
        sys.exit(1)
    file_hit = sum(count > 0 for count in selected.values())
    file_total = len(selected)
    selected_branches = list(branch_coverage[target].values())
    if not selected_branches:
        print(f"Missing branch coverage for {target}", file=sys.stderr)
        sys.exit(1)
    branch_hit = sum(count > 0 for count in selected_branches)
    covered += file_hit
    total += file_total
    branch_covered += branch_hit
    branch_total += len(selected_branches)
    print(
        f"{target}: lines {file_hit / file_total * 100.0:.2f}% "
        f"({file_hit}/{file_total}), branches "
        f"{branch_hit / len(selected_branches) * 100.0:.2f}% "
        f"({branch_hit}/{len(selected_branches)})"
    )

overall = (covered / total * 100.0) if total else 0.0
branch_overall = (
    branch_covered / branch_total * 100.0 if branch_total else 0.0
)
print(
    "Backup desktop coverage: "
    f"lines {overall:.2f}% ({covered}/{total}), "
    f"branches {branch_overall:.2f}% ({branch_covered}/{branch_total}) "
    f"(threshold {threshold:.2f}%)"
)

if overall < threshold or branch_overall < threshold:
    print(
        "Backup desktop coverage is below the required threshold: "
        f"lines {overall:.2f}%, branches {branch_overall:.2f}%, "
        f"required {threshold:.2f}%",
        file=sys.stderr,
    )
    sys.exit(1)
PY
