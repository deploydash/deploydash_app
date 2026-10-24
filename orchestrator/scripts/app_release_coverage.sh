#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${APP_DIR}"

TARGET_TESTS=(
  tests.app_release_runtime_test
  tests.app_release_deploy_test
  tests.app_release_rollback_test
  tests.app_release_probes_test
  tests.app_release_helpers_test
  tests.app_release_fault_injection_test
  tests.app_config_test
  tests.app_part0_prepare_key_test
  tests.worker_runtime_builder_test
  tests.app_workflow_test
  tests.engine_params_schema_validation_test
  tests.workflow_registry_params_schema_test
  tests.architecture.engine_contract_guardrails_test
  tests.engine_test
  tests.runtime_ops_test
)

INCLUDE_FILES=(
  "src/orchestrator/app_release_runtime.py"
  "src/orchestrator/app_parts/__init__.py"
  "src/orchestrator/app_parts/app_config.py"
  "src/orchestrator/app_parts/part0_prepare_key.py"
  "src/orchestrator/app_parts/worker_runtime.py"
  "src/orchestrator/engine.py"
  "src/orchestrator/app_runtime_parts/release_lifecycle.py"
  "src/orchestrator/app_runtime_parts/release_failure_evidence.py"
  "src/orchestrator/app_runtime_parts/release_observability.py"
  "src/orchestrator/plugins/app_plugin.py"
  "src/orchestrator/plugins/base.py"
  "src/orchestrator/config_validation.py"
)

INCLUDE_CSV="$(IFS=,; echo "${INCLUDE_FILES[*]}")"
COVERAGE_DIR="coverage/app_release"
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

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import (
    CoverageGateDefinitionError,
    covered_lines_in_spans,
    resolve_python_symbol_spans,
    uncovered_arcs_touching_spans,
)

report_path = Path("coverage/app_release/coverage.json")
if not report_path.exists():
    print("coverage/app_release/coverage.json was not generated", file=sys.stderr)
    sys.exit(1)

symbols_by_path = {
    "src/orchestrator/app_parts/part0_prepare_key.py": (
        "build_steps",
        "build_steps.register_step",
    ),
    "src/orchestrator/app_release_runtime.py": (
        "utc_now_iso",
        "normalize_commit_sha",
        "build_release_id",
        "empty_release_manifest",
        "normalize_release_manifest",
        "normalize_release_entry",
        "normalize_worker_spec",
        "release_entry_from_config",
        "live_release_entry",
        "successful_release_entries",
        "find_release_entry",
        "sort_releases_newest_first",
        "previous_successful_release",
        "set_live_release",
        "mark_release_failed",
        "append_or_replace_release",
        "release_prune_candidates",
        "prune_release_entries",
        "render_manifest_write_command",
        "render_manifest_write_payload",
        "load_manifest_from_text",
        "worker_specs_to_configs",
    ),
    "src/orchestrator/app_parts/app_config.py": (
        "AppConfig.repository_ssh_url",
        "AppConfig.project_root",
        "AppConfig.source_root",
        "AppConfig.source_app_root",
        "AppConfig.deploy_data_root",
        "AppConfig.release_data_root",
        "AppConfig.release_manifest_path",
        "AppConfig.key_dir",
        "AppConfig.key_private_path",
        "AppConfig.key_public_path",
    ),
    # `_validate_unknown_setting_keys` used to be named here. T-3.8.1
    # collapsed it, and the four other config helpers, into one owner; the
    # gate follows the code rather than keeping a symbol that no longer
    # exists. The shared implementation is measured below.
    # Only the part the app-release path exercises. `select_settings`'s
    # other branches belong to the workflows that take them -- see
    # onboarding_security_coverage.sh, which measures the whole file.
    "src/orchestrator/config_validation.py": (
        "validate_unknown_setting_keys",
    ),
    "src/orchestrator/app_parts/__init__.py": (
        "_params_schema",
    ),
    "src/orchestrator/app_parts/worker_runtime.py": (
        "render_runtime_env_stdin",
        "build_runtime_env_docker_flags",
        "WorkerRuntimeCommandSpec",
        "_worker_env_flags",
        "build_worker_runtime_command_spec",
    ),
    "src/orchestrator/engine.py": (
        "prepare_app_deploy_key",
        "deploy_application",
        "run_app_runtime_operation",
    ),
    # `_validated_connection` used to be nested in `build_plugin` here. It was
    # hoisted into `plugins/base.py` as the shared `validated_connection` --
    # the "parameterise the original" collapse -- and this gate kept naming
    # the old path, so it was failing on a missing symbol rather than
    # measuring anything.
    "src/orchestrator/plugins/base.py": (
        "validated_connection",
        "bind_operation",
    ),
    # The seven per-operation handlers this used to name -- `_runtime_operation`,
    # `handle_runtime_logs`, `handle_exec`, `_worker_id_from_params`,
    # `_release_id_from_params`, `_worker_runtime_action`, `handle_worker_logs`
    # -- were collapsed into one `bind_operation` factory parameterised per
    # operation, which is the duplication collapse this plan drives. The gate
    # kept naming the deleted symbols and so had been failing on a missing
    # symbol rather than measuring anything. These five are what `build_plugin`
    # still defines; the shared factory is measured in `base.py` above.
    "src/orchestrator/plugins/app_plugin.py": (
        "build_plugin.handle_describe",
        "build_plugin.handle_prepare_key",
        "build_plugin.handle_run",
        "build_plugin._tail_from_params",
        "build_plugin._string_param",
    ),
    "src/orchestrator/app_runtime_parts/release_lifecycle.py": (
        "_run_remote_command",
        "_load_release_manifest",
        "_write_release_manifest",
        "_release_inventory_response",
        "_release_failure_inventory_extra",
        "_release_runtime_targets",
        "_legacy_container_is_running",
        "_build_clone_or_update_command",
        "_build_release_run_command",
        "_release_route_target",
        "_public_health_probe_command",
        "_public_health_error",
        "_public_health_from_output",
        "_probe_public_health",
        "_release_worker_container_names",
        "_legacy_worker_container_names",
        "_write_caddy_route",
        "_restore_or_remove_caddy_route",
        "_cleanup_failed_release_after_route_cutover",
        "_route_cleanup_extra",
        "_stop_release_runtime",
        "_probe_candidate_release",
        "_probe_routed_release",
        "_collect_release_runtime_logs",
        "_verify_release_workers_running",
        "_prune_release_artifacts",
        "_execute_versioned_release_deploy",
        "_execute_release_rollback",
    ),
    "src/orchestrator/app_runtime_parts/release_failure_evidence.py": (
        "_candidate_probe_commands",
        "_routed_probe_commands",
        "_result_output_lines",
        "_failure_evidence_from_result",
        "_release_probe_from_result",
        "_runtime_log_excerpt_from_evidence",
        "_stabilization_evidence_result",
        "_readiness_failure_summary",
    ),
    "src/orchestrator/app_runtime_parts/release_observability.py": (
        "_parse_worker_status_lines",
        "_parse_container_status_output",
        "_build_worker_runtime_snapshot",
        "_parse_sqlite_meta_output",
    ),
}

report = json.loads(report_path.read_text())
files = report.get("files", {})
failures = []

for path, symbols in symbols_by_path.items():
    payload = files.get(path)
    if payload is None:
        failures.append(f"{path}: no coverage payload")
        continue

    executed = set(payload.get("executed_lines", []))
    missing = set(payload.get("missing_lines", []))
    executable = executed | missing
    try:
        spans = resolve_python_symbol_spans(Path(path), symbols)
        lines = covered_lines_in_spans(
            Path(path),
            symbols,
            executable,
            language="python",
        )
    except CoverageGateDefinitionError as error:
        failures.append(str(error))
        continue
    checked = len(lines)
    missed_lines = sorted(lines & missing)
    covered = checked - len(missed_lines)

    percent = (covered / checked * 100.0) if checked else 100.0
    executed_branches = {
        tuple(arc)
        for arc in uncovered_arcs_touching_spans(
            spans,
            payload.get("executed_branches", []),
        )
    }
    missing_branches = {
        tuple(arc)
        for arc in uncovered_arcs_touching_spans(
            spans,
            payload.get("missing_branches", []),
        )
    }
    checked_branches = len(executed_branches | missing_branches)
    covered_branches = checked_branches - len(missing_branches)
    branch_percent = (
        covered_branches / checked_branches * 100.0
        if checked_branches
        else 100.0
    )
    print(
        f"{path}: touched executable lines {covered}/{checked} ({percent:.2f}%); "
        f"branches {covered_branches}/{checked_branches} ({branch_percent:.2f}%)"
    )
    if missed_lines:
        failures.append(f"{path}: missing touched lines {missed_lines}")
    if missing_branches:
        failures.append(
            f"{path}: missing touched branches {sorted(missing_branches)}"
        )

if failures:
    print("\nApp release coverage gate failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)

print("\nApp release coverage gate passed.")
PY
