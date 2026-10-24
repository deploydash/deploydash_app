#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COVERAGE_DIR="${APP_DIR}/coverage/managed_software"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

cd "${APP_DIR}"
rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest \
  tests.container_status_test \
  tests.dns_part1_foundation_test \
  tests.dns_part2_runtime_test \
  tests.postgres_backup_test \
  tests.postgres_supply_chain_test \
  tests.server_tooling_test
uv run --with coverage coverage json \
  --include="src/orchestrator/container_status.py,src/orchestrator/dns_parts/part1_foundation.py,src/orchestrator/dns_parts/part2_runtime.py,src/orchestrator/infra_parts/tooling.py,src/orchestrator/managed_software.py,src/orchestrator/postgres_backup.py,src/orchestrator/postgres_supply_chain.py" \
  -o "${REPORT_JSON}"

python3 - "${REPORT_JSON}" <<'PY'
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

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
files = report.get("files", {})
symbols_by_path = {
    "src/orchestrator/container_status.py": (
        "postgres_service_readiness_check_shell",
        "postgres_service_readiness_wait_shell",
    ),
    "src/orchestrator/dns_parts/part1_foundation.py": ("_render_compose",),
    "src/orchestrator/dns_parts/part2_runtime.py": (
        "build_steps",
        "build_steps.register_step",
    ),
    "src/orchestrator/postgres_backup.py": (
        "backup_env_export_block",
    ),
    "src/orchestrator/postgres_supply_chain.py": (
        "_shell_architecture_cases",
        "_docker_architecture_cases",
        "_pg_search_docker_cases",
        "postgres_walg_install_command",
        "postgres_extension_image_dockerfile",
        "postgres_extension_image_dockerfiles_by_variant",
    ),
    "src/orchestrator/infra_parts/tooling.py": (
        "_software_ledger_write_error",
        "_private_backup_dir_command",
        "_managed_backup_hygiene_command",
        "_managed_backup_service_dirs",
        "_managed_backup_retention_command",
        "_parse_managed_backup_retention_output",
        "_docker_patch_probe_shell",
        "_build_server_tooling_status_command",
        "_postgres_compose_image_rewriter_script",
        "_postgres_managed_update_target",
        "_managed_caddy_rebuild_command",
        "_managed_postgres_update_command",
        "_docker_patch_install_command",
        "_managed_update_command",
        "_managed_rollback_command",
        "run_server_tooling_update_operation",
        "run_server_tooling_rollback_operation",
    ),
    "src/orchestrator/managed_software.py": (
        "docker_package_patch_series",
        "docker_package_series_version",
        "caddy_image_is_current",
        "_retained_backup_records",
        "build_managed_software_status",
        "record_component_action",
    ),
}

failures = []
covered_lines_total = 0
executable_lines_total = 0
covered_branches_total = 0
branches_total = 0
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
        checked = covered_lines_in_spans(
            Path(path),
            symbols,
            executable,
            language="python",
        )
    except CoverageGateDefinitionError as error:
        failures.append(str(error))
        continue
    missed = sorted(checked & missing)
    executed_branches = set(
        uncovered_arcs_touching_spans(
            spans,
            payload.get("executed_branches", []),
        )
    )
    missing_branches = set(
        uncovered_arcs_touching_spans(
            spans,
            payload.get("missing_branches", []),
        )
    )
    covered = len(checked) - len(missed)
    covered_lines_total += covered
    executable_lines_total += len(checked)
    percent = 100.0 * covered / len(checked) if checked else 0.0
    branch_total = len(executed_branches) + len(missing_branches)
    covered_branches_total += len(executed_branches)
    branches_total += branch_total
    branch_percent = (
        100.0 * len(executed_branches) / branch_total if branch_total else 100.0
    )
    print(
        f"{path}: lines {percent:.2f}% ({covered}/{len(checked)}), "
        f"branches {branch_percent:.2f}% "
        f"({len(executed_branches)}/{branch_total})"
    )
    if not checked:
        failures.append(f"{path}: no executable lines in managed symbols")
    elif missed:
        failures.append(f"{path}: missing managed lines {missed}")
    if missing_branches:
        failures.append(f"{path}: missing managed branches {sorted(missing_branches)}")

if failures:
    print("Managed software coverage gate failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    raise SystemExit(1)

print(
    "Managed software coverage: "
    f"lines {covered_lines_total}/{executable_lines_total} (100.00%), "
    f"branches {covered_branches_total}/{branches_total} (100.00%)"
)
PY
