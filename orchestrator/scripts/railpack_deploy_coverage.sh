#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${APP_DIR}"

TARGET_TESTS=(
  tests.server_tooling_test
  tests.architecture.engine_contract_guardrails_test
  tests.architecture.railpack_contract_test
  tests.setup_part5_railpack_test
  tests.app_part1_deploy_test
  tests.workflow_executor_test
  tests.pyinfra_runtime_test
)

INCLUDE_FILES=(
  "src/orchestrator/railpack_contract.py"
  "src/orchestrator/setup_parts/part5_railpack_builds.py"
  "src/orchestrator/app_parts/part1_deploy.py"
  "src/orchestrator/workflow_executor.py"
  "src/orchestrator/pyinfra_runtime.py"
  "src/orchestrator/infra_parts/tooling.py"
  "src/orchestrator/plugins/server_plugin.py"
  "src/orchestrator/engine.py"
  "src/orchestrator/engine_bootstrap.py"
)

INCLUDE_CSV="$(IFS=,; echo "${INCLUDE_FILES[*]}")"
COVERAGE_DIR="coverage/railpack_deploy"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TARGET_TESTS[@]}"
uv run --with coverage coverage json --include="${INCLUDE_CSV}" -o "${REPORT_JSON}"

uv run python - <<'PY'
import json
import sys
from pathlib import Path

report_path = Path("coverage/railpack_deploy/coverage.json")
if not report_path.exists():
    print("coverage/railpack_deploy/coverage.json was not generated", file=sys.stderr)
    sys.exit(1)

whole_files = (
    "src/orchestrator/railpack_contract.py",
    "src/orchestrator/setup_parts/part5_railpack_builds.py",
)

function_targets = {
    "src/orchestrator/app_parts/part1_deploy.py": (
        "render_selected_branch_fetch_command",
        "build_steps",
        "build_steps.register_step1",
        "build_steps.register_step2",
        "build_steps.register_step3",
    ),
    "src/orchestrator/workflow_executor.py": (
        "_failed_action_payload",
        "run_plan_execute",
    ),
    "src/orchestrator/pyinfra_runtime.py": (
        "PyinfraRuntimeSession.add_operation",
        "PyinfraRuntimeSession._collect_operation_results",
        "PyinfraRuntimeSession.execute",
    ),
    "src/orchestrator/infra_parts/tooling.py": (
        "_tooling_component",
        "_capability_detail",
        "_capability",
        "_details_status",
        "_package_detail",
        "_stack_image_detail",
        "_build_server_tooling_status_command",
        "_tooling_status_from_payload",
        "_server_capabilities_from_payload",
        "_capability_update_available",
        "_tooling_update_available",
        "_stdout_text",
        "_read_remote_software_ledger",
        "_write_remote_software_ledger",
        "_backup_dir",
        "_managed_railpack_update_command",
        "_read_server_tooling_status",
        "run_server_tooling_status_operation",
        "run_server_tooling_update_operation",
        "run_server_tooling_update_operation._emit_from_executor",
    ),
    "src/orchestrator/plugins/server_plugin.py": (
        "build_plugin.handle_tooling_status",
        "build_plugin.handle_tooling_update",
        "build_plugin.handle_tooling_rollback",
    ),
    "src/orchestrator/engine.py": (
        "run_server_tooling_status_operation",
        "run_server_tooling_update_operation",
        "run_server_tooling_rollback_operation",
    ),
    "src/orchestrator/engine_bootstrap.py": (
        "build_engine_bootstrap",
    ),
}

report = json.loads(report_path.read_text())
files = report.get("files", {})
failures = []
total_statements = 0
total_covered = 0
total_branches = 0
total_covered_branches = 0


def check_payload(label, payload):
    global total_statements, total_covered, total_branches, total_covered_branches
    summary = payload.get("summary", {})
    statements = int(summary.get("num_statements", 0))
    covered = int(summary.get("covered_lines", 0))
    missing = sorted(payload.get("missing_lines", []))
    branches = int(summary.get("num_branches", 0))
    covered_branches = int(summary.get("covered_branches", 0))
    missing_branches = sorted(payload.get("missing_branches", []))
    total_statements += statements
    total_covered += covered
    total_branches += branches
    total_covered_branches += covered_branches
    percent = (covered / statements * 100.0) if statements else 0.0
    branch_percent = (covered_branches / branches * 100.0) if branches else 100.0
    print(f"{label}: executable lines {covered}/{statements} ({percent:.2f}%)")
    print(
        f"{label}: branches {covered_branches}/{branches} "
        f"({branch_percent:.2f}%)"
    )
    if not statements:
        failures.append(f"{label}: no executable lines")
    elif missing or covered != statements:
        failures.append(f"{label}: missing lines {missing}")
    if missing_branches or covered_branches != branches:
        failures.append(f"{label}: missing branches {missing_branches}")


for path in whole_files:
    payload = files.get(path)
    if payload is None:
        failures.append(f"{path}: no coverage payload")
        continue
    check_payload(path, payload)

for path, function_names in function_targets.items():
    file_payload = files.get(path)
    if file_payload is None:
        failures.append(f"{path}: no coverage payload")
        continue
    functions = file_payload.get("functions", {})
    for function_name in function_names:
        payload = functions.get(function_name)
        label = f"{path}::{function_name}"
        if payload is None:
            failures.append(f"{label}: no coverage payload")
            continue
        check_payload(label, payload)

if failures:
    print("\nRailpack deploy coverage gate failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)

line_percent = (
    total_covered / total_statements * 100.0
    if total_statements
    else 0.0
)
branch_percent = (
    total_covered_branches / total_branches * 100.0
    if total_branches
    else 100.0
)
print(
    "\nRailpack deploy coverage gate passed: "
    f"lines {total_covered}/{total_statements} ({line_percent:.2f}%); "
    f"branches {total_covered_branches}/{total_branches} "
    f"({branch_percent:.2f}%)."
)
PY
