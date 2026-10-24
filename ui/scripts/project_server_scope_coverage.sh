#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/project_server_scope"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

flutter test --coverage \
  test/data/local/project_repository_test.dart \
  test/providers/project_provider_test.dart \
  test/data/local/app_database/ \
  test/ui/layout/shell_page_test.dart \
  test/ui/layout/navigation_rail_test.dart \
  test/ui/layout/app_navigation_rail_test.dart \
  test/services/agent_access/ \
  --coverage-path "${LCOV_PATH}"

python3 - <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import CoverageGateDefinitionError, covered_lines_in_spans

anchor_targets = {
    "lib/data/local/app_database.dart": ("workspace_scope_indexes",),
    "lib/data/local/project_repository.dart": (
        "list_projects",
        "read_active_project_id",
        "read_project",
        "update_deployment_config",
        "update_last_deploy_state",
        "set_active_project",
        "update_runtime_state",
        "update_database_wiring",
        "delete_project_records",
    ),
    "lib/providers/project_provider.dart": (
        "add_project",
        "selected_project_id_notifier",
        "selected_project_provider",
    ),
    # These five anchors named lib/main.dart, and none of them had existed
    # there for some time: the navigation actions moved to the shell rail and
    # the password generator to its own service. The gate had therefore been
    # failing on missing symbols rather than measuring anything -- the same
    # shape as the agent_access_service.dart entry below, and the reason
    # `_read_gate_source` now reports an absent file as a gate error instead
    # of a bare traceback.
    "lib/ui/shell/shell_navigation_rail.dart": (
        "open_home_mode",
        "open_add_server_mode",
        "open_project",
        "select_server_from_home",
    ),
    "lib/services/postgres_service_password.dart": (
        "generate_postgres_service_password",
    ),
    # T-3.5.3 split the Agent Access service by concern, so each anchor now
    # lives with the handler it guards. The previous entry named
    # lib/services/agent_access_service.dart -- a path that has not existed
    # since T-3.1.5 moved the file into providers/, which left this gate red
    # and unnoticed. See the T-3.5.3 rows under Discovered work.
    "lib/providers/agent_access/tools/servers.dart": ("reply_list_servers",),
    "lib/providers/agent_access/tools/web_apps.dart": ("reply_deploy_logs",),
    "lib/providers/agent_access/tools/github.dart": (
        "reply_list_github_repositories",
    ),
    "lib/providers/agent_access/tools/redeploy.dart": ("reply_redeploy",),
    "lib/providers/agent_access/tools/postgres.dart": (
        "resolve_project_postgres_context_reply",
    ),
}

lcov_path = Path("coverage/project_server_scope/lcov.info")
if not lcov_path.exists():
    print("coverage/project_server_scope/lcov.info was not generated", file=sys.stderr)
    sys.exit(1)

coverage = {}
current = None
for line in lcov_path.read_text().splitlines():
    if line.startswith("SF:"):
        source = line[3:]
        current = source[source.find("lib/"):] if "lib/" in source else source
        coverage.setdefault(current, {})
        continue
    if current is None or not line.startswith("DA:"):
        continue
    line_number_text, hit_count_text = line[3:].split(",", 1)
    coverage[current][int(line_number_text)] = int(hit_count_text)

failures = []
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

if failures:
    print("\nProject/server scope coverage gate failed:")
    for failure in failures:
        print(f"- {failure}")
    sys.exit(1)

print("\nProject/server scope coverage gate passed.")
PY
