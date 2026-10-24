#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/agent_access_postgres"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

flutter test --coverage --branch-coverage \
  test/services/agent_access_authorization_test.dart \
  test/services/agent_access/ \
  test/services/agent_access_surface_test.dart \
  test/services/project_database_settings_test.dart \
  --coverage-path "${LCOV_PATH}"

python3 - <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import CoverageGateDefinitionError, covered_lines_in_spans

file_targets = {
    # The Agent Access security boundary, whole-file rather than anchored:
    # every line of it is an allow/deny decision or the session state one
    # reads, so there is no region of it that may go unexercised (T-3.5.3).
    "lib/providers/agent_access/authorization.dart",
    # The MCP surface: catalogs, codec, and envelopes. Whole-file, because
    # every line of it is part of the frozen tool surface (T-3.5.3).
    "lib/providers/agent_access/protocol.dart",
    # Every module the T-3.5.3 split produced, whole-file. The anchors below
    # stay because project_server_scope_coverage.sh also names them; a
    # whole-file target is the stronger of the two, not a replacement.
    "lib/providers/agent_access_service.dart",
    "lib/providers/agent_access/tools/dispatch.dart",
    "lib/providers/agent_access/tools/github.dart",
    "lib/providers/agent_access/tools/postgres.dart",
    "lib/providers/agent_access/tools/redeploy.dart",
    "lib/providers/agent_access/tools/servers.dart",
    "lib/providers/agent_access/tools/tasks.dart",
    "lib/providers/agent_access/tools/web_apps.dart",
    # transport.dart is deliberately NOT here. It is at 98.64%: the
    # `on SocketException` body in the keepalive timer cannot run (the only
    # SocketException source is the un-awaited flush(), whose error surfaces
    # asynchronously and cannot reach a synchronous catch), and the finally
    # that cancels the timer did not run within an observed disconnect. Both
    # need a production change, which a D3 split may not make. See the T-3.5.3
    # rows under Discovered work.
    "lib/services/project_database_settings.dart",
}
anchor_targets = {
    # The shell keeps only lifecycle; T-3.5.3 moved the handlers, and each
    # anchor moved with the code it guards.
    "lib/providers/agent_access_service.dart": (
        "agent_access_endpoint_constants",
        "agent_session_lifecycle",
    ),
    "lib/providers/agent_access/tools/web_apps.dart": (
        "agent_web_app_read_replies",
    ),
    "lib/providers/agent_access/tools/dispatch.dart": (
        "agent_mcp_tool_dispatch",
    ),
}

lcov_path = Path("coverage/agent_access_postgres/lcov.info")
if not lcov_path.exists():
    print(
        "coverage/agent_access_postgres/lcov.info was not generated",
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
        branch_coverage[current][branch_key] = (
            0 if taken_text == "-" else int(taken_text)
        )
        continue
    if not line.startswith("DA:"):
        continue
    line_number_text, hit_count_text = line[3:].split(",", 1)
    coverage[current][int(line_number_text)] = int(hit_count_text)

failures = []
for file_path in sorted(file_targets):
    data = coverage.get(file_path, {})
    total = len(data)
    hit = sum(1 for count in data.values() if count > 0)
    pct = (hit / total) * 100 if total else 0.0
    print(f"{file_path}: {pct:.2f}% ({hit}/{total})")
    if total == 0 or abs(pct - 100.0) > 1e-9:
        failures.append(file_path)

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
    if total == 0 or abs(pct - 100.0) > 1e-9:
        failures.append(label)

branch_anchor_targets = {
    "lib/providers/agent_access/tools/redeploy.dart": (
        "deploy_failure_audit_metadata",
        "redeploy_failure_audit_selection",
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
    label = f"{target}::{', '.join(anchors)} (branch)"
    print(f"{label}: {pct:.2f}% ({hit}/{total})")
    if abs(pct - 100.0) > 1e-9:
        failures.append(label)

if failures:
    print("\nAgent Access Postgres coverage gate failed:")
    for failure in failures:
        print(f"- {failure}")
    sys.exit(1)

print("\nAgent Access Postgres coverage gate passed.")
PY
