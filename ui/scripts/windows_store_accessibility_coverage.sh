#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/windows_store_accessibility"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"
rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

flutter test --coverage \
  test/ui/system/app_window_title_test.dart \
  test/ui/startup/database_unlock_gate_test.dart \
  test/ui/server/server_onboarding_view_test.dart \
  test/ui/server/server_management/ \
  test/ui/layout/home_dashboard_view_test.dart \
  test/ui/layout/shell_page_test.dart \
  --coverage-path "${LCOV_PATH}"

python3 - <<'PY'
import sys
from pathlib import Path

markers = {
    "lib/ui/startup/database_unlock_gate.dart": (
        "database-passphrase-field",
        "database-confirm-passphrase-field",
        "identifier: isRestoreMode",
    ),
    "lib/ui/server/server_onboarding_view.dart": (
        "server-name-field",
        "server-host-field",
        "server-user-field",
        "server-password-field",
        "identifier: 'server-check-button',",
    ),
    "lib/ui/layout/home_dashboard_view.dart": (
        "key: const Key('home-add-server-button'),",
    ),
    "lib/ui/system/app_window_title.dart": (
        "setter('Deploy Dash - $expectedScreen')",
    ),
    "lib/ui/server/server_management_view.dart": (
        "'Server management - ${_destinations[controller.index].label}'",
    ),
}

exact_runtime_markers = {
    "lib/ui/system/app_forms.dart": (
        "focusNode: focusNode,",
        "autofocus: autofocus,",
        "focusNode: widget.focusNode,",
        "autofocus: widget.autofocus,",
        "textInputAction: widget.textInputAction,",
        "onFieldSubmitted: widget.onFieldSubmitted,",
    ),
    "lib/ui/startup/database_unlock_gate.dart": (
        "_passphraseFocusNode.dispose();",
        "_confirmPassphraseFocusNode.dispose();",
        "focusNode: _passphraseFocusNode,",
        "_confirmPassphraseFocusNode.requestFocus();",
        "focusNode: _confirmPassphraseFocusNode,",
        "return AppWindowTitle(",
    ),
    # The credential-step focus nodes live in `_CredentialFields` under
    # non-underscored names (serverNameFocus, hostFocus, ...); the previous
    # markers named state fields that no longer exist. Each marker below is
    # one unique executable line the gate's widget tests hit, so the check
    # still proves disposal, focus wiring, submit traversal, and the final
    # connection-check submit all run.
    "lib/ui/server/server_onboarding_view.dart": (
        "serverNameFocus.dispose();",
        "hostFocus.dispose();",
        "portFocus.dispose();",
        "userFocus.dispose();",
        "passwordFocus.dispose();",
        "screen: switch (_step) {",
        "focusNode: fields.serverNameFocus,",
        "fields.hostFocus.requestFocus()",
        "focusNode: fields.hostFocus,",
        "fields.portFocus.requestFocus()",
        "focusNode: fields.portFocus,",
        "fields.userFocus.requestFocus()",
        "focusNode: fields.userFocus,",
        "fields.passwordFocus.requestFocus()",
        "focusNode: fields.passwordFocus,",
        "onFieldSubmitted: (_) => onCheckConnection(),",
    ),
    "lib/ui/layout/home_dashboard_view.dart": (
        "screen: selectedServer == null",
        "autofocus: selectedServer == null,",
    ),
}

coverage = {}
current = None
for line in Path("coverage/windows_store_accessibility/lcov.info").read_text().splitlines():
    if line.startswith("SF:"):
        source = line[3:]
        current = source[source.find("lib/") :] if "lib/" in source else None
        continue
    if current is not None and line.startswith("DA:"):
        number, count = line[3:].split(",", 1)
        coverage.setdefault(current, {})[int(number)] = int(count)

failures = []
for source, source_markers in markers.items():
    lines = Path(source).read_text().splitlines()
    for marker in source_markers:
        matches = [
            index
            for index, content in enumerate(lines, start=1)
            if marker in content
        ]
        if len(matches) != 1:
            failures.append(f"{source}: marker {marker!r} is not unique")
            continue
        line_number = matches[0]
        hits = sum(
            count
            for covered_line, count in coverage.get(source, {}).items()
            if line_number - 5 <= covered_line <= line_number + 5
        )
        print(
            f"{source}:{line_number} {marker}: "
            f"{hits} nearby construction hit(s)"
        )
        if hits <= 0:
            failures.append(f"{source}:{line_number} {marker}")

if failures:
    print("\nWindows Store accessibility coverage gate failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)

for source, source_markers in exact_runtime_markers.items():
    source_lines = Path(source).read_text().splitlines()
    source_coverage = coverage.get(source, {})
    for marker in source_markers:
        executable_matches = [
            index
            for index, content in enumerate(source_lines, start=1)
            if marker in content and index in source_coverage
        ]
        if not executable_matches:
            failures.append(f"{source}: executable marker {marker!r} not found")
            continue
        uncovered_matches = [
            line_number
            for line_number in executable_matches
            if source_coverage[line_number] == 0
        ]
        if uncovered_matches:
            failures.append(
                f"{source}: executable marker {marker!r} is uncovered at "
                f"{uncovered_matches}"
            )

if failures:
    print(
        "\nWindows Store executable accessibility coverage failed:",
        file=sys.stderr,
    )
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)

for source in ("lib/ui/system/app_window_title.dart",):
    uncovered = [
        line_number
        for line_number, count in coverage.get(source, {}).items()
        if count == 0
    ]
    if uncovered:
        print(
            f"{source} is below 100% line coverage: {uncovered}",
            file=sys.stderr,
        )
        sys.exit(1)

print(
    "\nWindows Store accessibility coverage: "
    "100% of baseline executable automation lines."
)
PY
