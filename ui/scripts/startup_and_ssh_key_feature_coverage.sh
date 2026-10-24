#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/startup_and_ssh_key_feature"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

flutter test --coverage --branch-coverage \
  test/data/local/app_database_passphrase_logic_test.dart \
  test/ui/startup/database_unlock_gate_test.dart \
  test/ui/server/system_ssh_key_import_test.dart \
  test/ui/server/system_ssh_key_replacement_logic_test.dart \
  test/data/local/server_repository_test.dart \
  test/providers/server_list_provider_test.dart \
  --coverage-path "${LCOV_PATH}"

python3 - <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import CoverageGateDefinitionError, covered_lines_in_spans

file_targets = {
    "lib/data/local/app_database_passphrase_logic.dart",
    "lib/ui/startup/database_unlock_gate.dart",
    "lib/ui/server/management/system_ssh_key_import.dart",
    "lib/ui/server/management/system_ssh_key_replacement_logic.dart",
}

anchor_targets = {
    "lib/data/local/server_repository.dart": (
        "server_repository_key_storage",
        "server_repository_managed_password_create",
        "server_repository_managed_password_key_import",
        "server_repository_managed_password_failure",
        "server_column_writers",
        "server_draft_copy_with",
        "server_onboarding_writers",
    ),
    "lib/providers/server_list_provider.dart": (
        "update_selected_server_imported_ssh_key",
        "server_count_bucket_save",
        "server_count_bucket_remove",
    ),
}

lcov_path = Path("coverage/startup_and_ssh_key_feature/lcov.info")
if not lcov_path.exists():
    print(
        "coverage/startup_and_ssh_key_feature/lcov.info was not generated",
        file=sys.stderr,
    )
    sys.exit(1)

coverage = {}
branch_coverage = {}
current = None
for line in lcov_path.read_text().splitlines():
    if line.startswith("SF:"):
        source = line[3:]
        current = source[source.find("lib/"):] if "lib/" in source else source
        coverage.setdefault(current, {})
        branch_coverage.setdefault(current, {})
        continue
    if current is None:
        continue
    if line.startswith("BRDA:"):
        branch_key, taken_text = line[5:].rsplit(",", 1)
        branch_coverage[current][branch_key] = int(taken_text)
        continue
    if not line.startswith("DA:"):
        continue
    line_number_text, hit_count_text = line[3:].split(",", 1)
    coverage[current][int(line_number_text)] = int(hit_count_text)

failures = []

for target in sorted(file_targets):
    data = coverage.get(target, {})
    total = len(data)
    hit = sum(1 for count in data.values() if count > 0)
    pct = (hit / total) * 100 if total else 0.0
    print(f"{target}: {pct:.2f}% ({hit}/{total})")
    if abs(pct - 100.0) > 1e-9:
        failures.append(target)

for target, anchors in sorted(anchor_targets.items()):
    try:
        selected_lines = covered_lines_in_spans(
            Path(target),
            anchors,
            coverage.get(target, {}),
            language="dart",
        )
    except CoverageGateDefinitionError as error:
        failures.append(str(error))
        continue
    data = {
        line_number: count
        for line_number, count in coverage.get(target, {}).items()
        if line_number in selected_lines
    }
    total = len(data)
    hit = sum(1 for count in data.values() if count > 0)
    pct = (hit / total) * 100 if total else 0.0
    label = f"{target}::{', '.join(anchors)}"
    print(f"{label}: {pct:.2f}% ({hit}/{total})")
    if abs(pct - 100.0) > 1e-9:
        failures.append(label)

# Branch enforcement, scoped to the #62-touched anchors. A span with no BRDA
# records is straight-line code, fully held by the line gate above; the check
# then passes vacuously but still prints its count, so a later conditional
# inside the span cannot slip in unmeasured.
branch_anchor_targets = {
    "lib/data/local/server_repository.dart": (
        "server_repository_managed_password_create",
        "server_repository_managed_password_key_import",
        "server_repository_managed_password_failure",
    ),
}

for target, anchors in sorted(branch_anchor_targets.items()):
    try:
        selected_lines = covered_lines_in_spans(
            Path(target),
            anchors,
            coverage.get(target, {}),
            language="dart",
        )
    except CoverageGateDefinitionError as error:
        failures.append(str(error))
        continue
    branches = [
        taken
        for branch_key, taken in branch_coverage.get(target, {}).items()
        if int(branch_key.split(",", 1)[0]) in selected_lines
    ]
    total = len(branches)
    hit = sum(1 for taken in branches if taken > 0)
    pct = (hit / total) * 100 if total else 100.0
    label = f"{target}::{', '.join(anchors)}"
    print(f"{label} (branch): {pct:.2f}% ({hit}/{total})")
    if abs(pct - 100.0) > 1e-9:
        failures.append(f"{label} (branch)")

if failures:
    print("\nStartup and SSH key coverage gate failed:")
    for failure in failures:
        print(f"- {failure}")
    sys.exit(1)

print("\nStartup and SSH key coverage gate passed.")
PY
