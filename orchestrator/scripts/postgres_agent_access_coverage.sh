#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${APP_DIR}"

TARGET_TESTS=(
  tests.postgres_config_test
  tests.postgres_plugin_test
  tests.postgres_agent_query_test
  tests.postgres_backup_helpers_test
  tests.postgres_project_ops_test
  tests.postgres_parsers_test
  tests.engine_params_schema_validation_test
  tests.workflow_registry_params_schema_test
)

rm -rf coverage/postgres_agent_access
mkdir -p coverage/postgres_agent_access

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TARGET_TESTS[@]}"
uv run --with coverage coverage json \
  -o coverage/postgres_agent_access/coverage.json

python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import CoverageGateDefinitionError, covered_lines_in_spans

report_path = Path("coverage/postgres_agent_access/coverage.json")
if not report_path.exists():
    print(
        "coverage/postgres_agent_access/coverage.json was not generated",
        file=sys.stderr,
    )
    sys.exit(1)

threshold = float(os.environ.get("POSTGRES_AGENT_ACCESS_COVERAGE_THRESHOLD", "100"))
report = json.loads(report_path.read_text())
files = report.get("files", {})
if not files:
    print("No coverage files were reported", file=sys.stderr)
    sys.exit(1)

file_targets = {
    "src/orchestrator/postgres_parts/postgres_config.py",
    "src/orchestrator/plugins/postgres_plugin.py",
}
symbol_targets = {
    "src/orchestrator/postgres_parts/__init__.py": (
        "_params_schema",
    ),
    "src/orchestrator/postgres_runtime_parts/agent_access.py": (
        "_parse_postgres_service_status_output",
        "_postgres_service_is_ready",
        "_postgres_output_has_one",
        "_postgres_local_sql_import_confirmed",
        "_postgres_connection_uri_host_for_managed_apps",
        "_parse_postgres_role_comment",
        "_postgres_strip_project_prefix",
        "_postgres_validate_agent_query_sql",
        "_postgres_agent_query_max_rows",
        "_run_postgres_agent_readonly_query",
    ),
}
branch_symbol_targets = {
    "src/orchestrator/postgres_runtime_parts/agent_access.py": (
        "_parse_postgres_service_status_output",
    ),
}

by_file = {path: {"hit": 0, "total": 0} for path in file_targets}
by_path = {}

for file_path, payload in files.items():
    normalized = file_path[file_path.find("src/") :] if "src/" in file_path else file_path
    by_path[normalized] = payload
    if normalized in by_file:
        data = payload.get("executed_lines", [])
        statements = set(payload.get("executed_lines", [])) | set(payload.get("missing_lines", []))
        by_file[normalized]["hit"] = len(data)
        by_file[normalized]["total"] = len(statements)

covered = total = 0
branch_failures = []
for file_path in sorted(file_targets):
    file_hit = by_file[file_path]["hit"]
    file_total = by_file[file_path]["total"]
    covered += file_hit
    total += file_total
    percent = (file_hit / file_total * 100.0) if file_total else 0.0
    print(f"{file_path}: {percent:.2f}% ({file_hit}/{file_total})")

for path, symbols in sorted(symbol_targets.items()):
    payload = by_path.get(path)
    if payload is None:
        print(f"{path}: no coverage payload", file=sys.stderr)
        sys.exit(1)
    executed = set(payload.get("executed_lines", []))
    statements = executed | set(payload.get("missing_lines", []))
    try:
        scoped = covered_lines_in_spans(
            Path(path),
            symbols,
            statements,
            language="python",
        )
    except CoverageGateDefinitionError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    symbol_hit = len(scoped & executed)
    symbol_total = len(scoped)
    covered += symbol_hit
    total += symbol_total
    percent = (symbol_hit / symbol_total * 100.0) if symbol_total else 0.0
    print(f"{path}::{', '.join(symbols)}: {percent:.2f}% ({symbol_hit}/{symbol_total})")

for path, symbols in sorted(branch_symbol_targets.items()):
    payload = by_path.get(path)
    if payload is None:
        print(f"{path}: no coverage payload", file=sys.stderr)
        sys.exit(1)
    functions = payload.get("functions", {})
    for symbol in symbols:
        function = functions.get(symbol)
        if function is None:
            branch_failures.append(f"{path}:{symbol} (missing function entry)")
            continue
        summary = function.get("summary", {})
        covered_branches = summary.get("covered_branches", 0)
        total_branches = summary.get("num_branches", 0)
        percent = (
            summary.get("percent_branches_covered", 100.0)
            if total_branches
            else 100.0
        )
        print(
            f"{path}:{symbol}: branches {covered_branches}/{total_branches} "
            f"({percent:.2f}%)"
        )
        if abs(percent - 100.0) > 1e-9:
            branch_failures.append(f"{path}:{symbol}")

overall = (covered / total * 100.0) if total else 0.0
print(
    "Postgres Agent Access backend coverage: "
    f"{overall:.2f}% ({covered}/{total}) "
    f"(threshold {threshold:.2f}%)"
)

if overall < threshold or branch_failures:
    print(
        "Postgres Agent Access backend coverage "
        f"{overall:.2f}% is below {threshold:.2f}%"
        if overall < threshold
        else "Postgres Agent Access branch coverage is below 100%",
        file=sys.stderr,
    )
    for failure in branch_failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)
PY
