#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/github_integration"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

flutter test --coverage --branch-coverage --concurrency=1 --reporter compact \
  test/models/app_public_health_test.dart \
  test/ui/project/app_deployment_tab_logic_test.dart \
  test/ui/project/app_deployment_settings_dialog_test.dart \
  test/providers/github_integration/ \
  test/providers/app_release_provider_test.dart \
  test/providers/project_provider_test.dart \
  test/providers/project_web_app_read_model_provider_test.dart \
  test/ui/project/workspace/ \
  test/data/local/app_database/ \
  test/data/local/app_release_repository_test.dart \
  test/data/local/app_deployment_history_repository_test.dart \
  test/data/local/project_repository_test.dart \
  test/data/local/terminal_log_repository_test.dart \
  test/services/agent_access/ \
  --coverage-path "${LCOV_PATH}"

python3 - <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import CoverageGateDefinitionError, covered_lines_in_spans

anchor_targets = {
    "lib/providers/github_deploy_diagnostics.dart": (
        "repository_access_hint",
        "repository_access_detection",
    ),
    "lib/providers/github_integration_provider.dart": (
        "deploy_selected_repository",
        "deploy_failure_analytics",
        "repository_key_rotation_retry",
        "deploy_failure_advice",
        "deploy_failure_result_decoding",
        "deploy_failure_restore",
        "deploy_failure_terminal_persistence",
        "github_oauth_connect",
    ),
    "lib/providers/github_integration_state.dart": (
        "project_deploy_failure_evidence_copy",
        "project_deploy_failure_evidence_scope",
        "integration_deploy_failure_evidence_copy",
    ),
    "lib/data/local/app_release_repository.dart": (
        "latest_failed_deploy_journal",
    ),
    "lib/data/local/terminal_log_repository.dart": (
        "terminal_evidence_batch",
    ),
    "lib/ui/project/workspace/app/app_deployment_state_sync_methods.dart": (
        "handle_github_transition",
        "load_local_release_inventory",
    ),
    "lib/ui/project/workspace/app/app_deployment_failure_card.dart": (
        "app_deploy_failure_card",
    ),
}

lcov_path = Path("coverage/github_integration/lcov.info")
if not lcov_path.exists():
    print(f"{lcov_path} was not generated", file=sys.stderr)
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
    "lib/providers/github_deploy_diagnostics.dart": (
        "repository_access_hint",
        "repository_access_detection",
    ),
    "lib/providers/github_integration_provider.dart": (
        "deploy_failure_analytics",
        "repository_key_rotation_retry",
        "deploy_failure_advice",
        "deploy_failure_result_decoding",
        "deploy_failure_restore",
        "deploy_failure_terminal_persistence",
    ),
    "lib/providers/github_integration_state.dart": (
        "project_deploy_failure_evidence_copy",
        "project_deploy_failure_evidence_scope",
        "integration_deploy_failure_evidence_copy",
    ),
    "lib/data/local/app_release_repository.dart": (
        "latest_failed_deploy_journal",
    ),
    "lib/data/local/terminal_log_repository.dart": (
        "terminal_evidence_batch",
    ),
    "lib/ui/project/workspace/app/app_deployment_failure_card.dart": (
        "app_deploy_failure_card",
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
    print("\nGitHub integration coverage gate failed:")
    for failure in failures:
        print(f"- {failure}")
    sys.exit(1)

print("\nGitHub integration coverage gate passed.")
PY
