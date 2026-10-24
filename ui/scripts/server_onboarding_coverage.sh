#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/server_onboarding"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

rm -rf "${COVERAGE_DIR}"

flutter test --coverage --branch-coverage \
  test/ui/server/server_onboarding_view_logic_test.dart \
  test/ui/server/server_onboarding_view_test.dart \
  test/ui/server/server_onboarding_security_test.dart \
  test/ui/server/server_system_settings_logic_test.dart \
  test/services/managed_ssh_key_service_test.dart \
  test/ui/server/server_management/ \
  test/providers/server_provider_test.dart \
  test/providers/server_list_provider_test.dart \
  test/domain/server_test.dart \
  --coverage-path "${LCOV_PATH}"

python3 - <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import CoverageGateDefinitionError, covered_lines_in_spans

targets = {
    "lib/services/managed_ssh_key_service.dart",
    "lib/ui/server/server_onboarding_view_logic.dart",
    "lib/ui/server/server_onboarding_security.dart",
    "lib/ui/server/management/server_system_settings_logic.dart",
}

# Analytics completion-reporting hook regions on the wizard view: the rest of
# the view has its own widget suite, so these anchors pin the gate on the new
# funnel-reporting lines instead of unrelated widget code.
anchor_targets = {
    "lib/ui/server/server_onboarding_view.dart": (
        "onboarding_completion_report",
        "onboarding_completion_dispose",
        "onboarding_services_completed",
        "onboarding_managed_password_threading",
    ),
    "lib/domain/server.dart": (
        "server_config_bool_decode",
        "server_root_login_mode",
        "server_system_root_login_constructor",
        "server_system_root_login_decode",
        "server_system_root_login_encode",
        "server_copy_with",
        "server_firewall_config_copy_with",
        "server_system_config_copy_with",
    ),
    "lib/ui/server/management/system_tab.dart": (
        "system_root_login_dirty",
        "system_root_login_control",
    ),
}

records = {target: {} for target in targets | set(anchor_targets)}
branch_records = {target: {} for target in targets | set(anchor_targets)}
current = None

for line in Path("coverage/server_onboarding/lcov.info").read_text().splitlines():
    if line.startswith("SF:"):
        sf = line[3:]
        current = sf[sf.index("lib/"):] if "lib/" in sf else None
    elif current in records and line.startswith("DA:"):
        _, rest = line.split(":", 1)
        line_no, hits = rest.split(",")
        records[current][int(line_no)] = int(hits)
    elif current in branch_records and line.startswith("BRDA:"):
        _, rest = line.split(":", 1)
        line_no, _, _, taken = rest.split(",")
        key = int(line_no)
        branch_records[current].setdefault(key, []).append(int(taken))
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

for target, anchors in sorted(anchor_targets.items()):
    try:
        selected_lines = covered_lines_in_spans(
            Path(target),
            anchors,
            records.get(target, {}),
            language="dart",
        )
    except CoverageGateDefinitionError as error:
        bad.append(str(error))
        continue
    data = {
        line_number: count
        for line_number, count in records.get(target, {}).items()
        if line_number in selected_lines
    }
    found = len(data)
    hit = sum(1 for count in data.values() if count > 0)
    pct = (100.0 * hit / found) if found else 0.0
    label = f"{target}::{', '.join(anchors)}"
    print(f"{label}: {hit}/{found} lines ({pct:.2f}%)")
    if found == 0 or abs(pct - 100.0) > 1e-9:
        bad.append(label)

# Branch enforcement, scoped to the #62-touched lines: the whole security
# helper file (whose scope this gate already owns) and the new view anchor.
# A span with no BRDA records is straight-line code, fully held by the line
# gate above; the check then passes vacuously but still prints its count, so
# a later conditional inside the span cannot slip in unmeasured.
branch_file_targets = {
    "lib/ui/server/server_onboarding_security.dart",
    "lib/ui/server/management/server_system_settings_logic.dart",
}
branch_anchor_targets = {
    "lib/ui/server/server_onboarding_view.dart": (
        "onboarding_managed_password_threading",
    ),
    "lib/domain/server.dart": (
        "server_config_bool_decode",
        "server_root_login_mode",
        "server_system_root_login_constructor",
        "server_system_root_login_decode",
        "server_system_root_login_encode",
        "server_copy_with",
        "server_firewall_config_copy_with",
        "server_system_config_copy_with",
    ),
    "lib/ui/server/management/system_tab.dart": (
        "system_root_login_dirty",
        "system_root_login_control",
    ),
}

for target in sorted(branch_file_targets):
    branches = [
        taken
        for takens in branch_records.get(target, {}).values()
        for taken in takens
    ]
    found = len(branches)
    hit = sum(1 for taken in branches if taken > 0)
    pct = (100.0 * hit / found) if found else 0.0
    print(f"{target}: {hit}/{found} branches ({pct:.2f}%)")
    if found == 0 or abs(pct - 100.0) > 1e-9:
        bad.append(f"{target} (branch)")

for target, anchors in sorted(branch_anchor_targets.items()):
    try:
        selected_lines = covered_lines_in_spans(
            Path(target),
            anchors,
            branch_records.get(target, {}),
            language="dart",
        )
    except CoverageGateDefinitionError as error:
        bad.append(str(error))
        continue
    branches = [
        taken
        for line_number, takens in branch_records.get(target, {}).items()
        if line_number in selected_lines
        for taken in takens
    ]
    found = len(branches)
    hit = sum(1 for taken in branches if taken > 0)
    pct = (100.0 * hit / found) if found else 100.0
    label = f"{target}::{', '.join(anchors)}"
    print(f"{label}: {hit}/{found} branches ({pct:.2f}%)")
    if abs(pct - 100.0) > 1e-9:
        bad.append(f"{label} (branch)")

if bad:
    print("\nServer onboarding coverage gate failed:")
    for target in bad:
        print(f"- {target}")
    sys.exit(1)

print("\nServer onboarding coverage gate passed.")
PY
