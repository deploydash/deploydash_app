#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COVERAGE_DIR="${APP_DIR}/coverage/analytics"

cd "${APP_DIR}"
rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

run_coverage() {
  local output_path="$1"
  shift
  flutter test --coverage --branch-coverage --coverage-path "${output_path}" "$@"
}

run_coverage \
  "${COVERAGE_DIR}/main_logic.lcov" \
  test/main_logic_test.dart

flutter test \
  --dart-define=DEPLOYDASH_DISTRIBUTION=apt \
  --coverage \
  --branch-coverage \
  --coverage-path "${COVERAGE_DIR}/release_shell.lcov" \
  test/ui/layout/shell_page_test.dart \
  --plain-name "Release shell initialization checks for desktop updates after the first frame"

run_coverage \
  "${COVERAGE_DIR}/service.lcov" \
  test/services/app_analytics_service_test.dart

run_coverage \
  "${COVERAGE_DIR}/layout.lcov" \
  test/ui/layout/main_layout_test.dart

shell_tests=(
  "Workspace navigation reports analytics events"
  "Home server actions open add server and server management"
  "Open server services action switches to the Services tab"
  "Home project list entries open the chosen project"
)

shell_index=0
for test_name in "${shell_tests[@]}"; do
  shell_index=$((shell_index + 1))
  run_coverage \
    "${COVERAGE_DIR}/shell_${shell_index}.lcov" \
    test/ui/layout/shell_page_test.dart \
    --plain-name "${test_name}"
done

python3 - <<'PY'
from collections import defaultdict
from pathlib import Path
import sys

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import CoverageGateDefinitionError, covered_lines_in_spans

coverage_dir = Path("coverage/analytics")
coverage_files = sorted(coverage_dir.glob("*.lcov"))
if not coverage_files:
    print("Analytics coverage runs did not generate any LCOV output.", file=sys.stderr)
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
            branch_key, count_text = line[5:].rsplit(",", 1)
            merged_branches[current_file][branch_key] += (
                0 if count_text == "-" else int(count_text)
            )
            continue
        line_number_text, count_text = line[3:].split(",", 1)
        merged[current_file][int(line_number_text)] += int(count_text)

merged_lcov_path = coverage_dir / "lcov.info"
with merged_lcov_path.open("w", encoding="utf-8") as handle:
    for file_path in sorted(merged):
        handle.write(f"SF:{file_path}\n")
        for line_number in sorted(merged[file_path]):
            handle.write(f"DA:{line_number},{merged[file_path][line_number]}\n")
        for branch_key in sorted(merged_branches[file_path]):
            handle.write(
                f"BRDA:{branch_key},{merged_branches[file_path][branch_key]}\n"
            )
        handle.write("end_of_record\n")

anchor_targets = {
    "lib/services/app_analytics_service.dart": (
        "analytics_service_contract",
        "aptabase_analytics_implementation",
        "amplitude_analytics_implementation",
        "analytics_fanout",
        "analytics_crash_marker",
    ),
    "lib/main.dart": ("deploydash_provider_scope",),
    "lib/ui/layout/main_layout.dart": ("main_layout_detach",),
    # `shell_state_initialization` moved with the shell when T-3.2.5 reduced
    # main.dart to bootstrap. The anchor follows the code, not the filename.
    "lib/ui/shell/shell_page.dart": ("shell_state_initialization",),
}

current_file = None
coverage = defaultdict(dict)
branch_coverage = defaultdict(dict)

for line in merged_lcov_path.read_text().splitlines():
    if line.startswith("SF:"):
        source = line[3:]
        current_file = source[source.find("lib/"):] if "lib/" in source else source
        continue
    if not line.startswith("DA:"):
        if not line.startswith("BRDA:"):
            continue
        branch_key, count_text = line[5:].rsplit(",", 1)
        branch_coverage[current_file][branch_key] = int(count_text)
        continue

    line_number_text, count_text = line[3:].split(",", 1)
    line_number = int(line_number_text)
    count = int(count_text)
    coverage[current_file][line_number] = count

bad = []
for target, anchors in sorted(anchor_targets.items()):
    try:
        selected = covered_lines_in_spans(
            Path(target),
            anchors,
            coverage.get(target, {}),
            language="dart",
        )
    except CoverageGateDefinitionError as error:
        bad.append(str(error))
        continue
    anchor_hit = sum(1 for line_number in selected if coverage[target][line_number] > 0)
    anchor_total = len(selected)
    percent = (anchor_hit / anchor_total * 100.0) if anchor_total else 0.0
    label = f"{target}::{', '.join(anchors)}"
    print(f"{label}: {percent:.2f}% ({anchor_hit}/{anchor_total})")
    if anchor_total == 0 or abs(percent - 100.0) > 1e-9:
        bad.append(label)

branch_anchor_targets = {
    "lib/services/app_analytics_service.dart": (
        "deploy_failure_analytics_metadata",
    ),
}
for target, anchors in sorted(branch_anchor_targets.items()):
    try:
        selected = covered_lines_in_spans(
            Path(target),
            anchors,
            coverage.get(target, {}),
            language="dart",
        )
    except CoverageGateDefinitionError as error:
        bad.append(str(error))
        continue
    branches = [
        count
        for branch_key, count in branch_coverage.get(target, {}).items()
        if int(branch_key.split(",", 1)[0]) in selected
    ]
    branch_hit = sum(1 for count in branches if count > 0)
    branch_total = len(branches)
    percent = branch_hit / branch_total * 100.0 if branch_total else 100.0
    label = f"{target}::{', '.join(anchors)} (branch)"
    print(f"{label}: {percent:.2f}% ({branch_hit}/{branch_total})")
    if abs(percent - 100.0) > 1e-9:
        bad.append(label)

if bad:
    print("\nAnalytics coverage gate failed:")
    for label in bad:
        print(f"- {label}")
    sys.exit(1)

print("\nAnalytics coverage gate passed.")
PY
