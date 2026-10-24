#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/server_docker_storage"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

TARGET_TESTS=(
  tests.server_docker_storage_test
  tests.server_tooling_test
  tests.server_system_workflow_test
)

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TARGET_TESTS[@]}"
uv run --with coverage coverage json -o "${REPORT_JSON}"

python3 - <<'PY'
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd().parent / "scripts"))
from coverage_gate_symbols import CoverageGateDefinitionError, covered_lines_in_spans

report_path = Path("coverage/server_docker_storage/coverage.json")
if not report_path.exists():
    print(
        "coverage/server_docker_storage/coverage.json was not generated",
        file=sys.stderr,
    )
    sys.exit(1)

payload = json.loads(report_path.read_text())
files = payload.get("files", {})
targets = {
    "src/orchestrator/infra_parts/docker_storage.py": (
        "_parse_docker_size_bytes",
        "_parse_docker_storage_status_output",
        "_build_server_docker_storage_status_command",
        "_read_server_docker_storage_status",
        "run_server_docker_storage_status_operation",
        "run_server_docker_storage_prune_operation",
    ),
    "src/orchestrator/plugins/server_plugin.py": (
        "build_plugin.handle_docker_storage_status",
        "build_plugin.handle_docker_storage_prune",
    ),
    "src/orchestrator/engine.py": (
        "run_server_docker_storage_prune_operation",
    ),
    "src/orchestrator/engine_bootstrap.py": ("build_engine_bootstrap",),
}

failures = []
for target, symbols in targets.items():
    data = files.get(target)
    if not data:
        failures.append(f"{target}: no coverage payload")
        continue

    executed = set(data.get("executed_lines", []))
    missing = set(data.get("missing_lines", []))
    relevant = executed | missing
    try:
        scoped_relevant = covered_lines_in_spans(
            Path(target),
            symbols,
            relevant,
            language="python",
        )
    except CoverageGateDefinitionError as error:
        failures.append(str(error))
        continue
    scoped_missing = sorted(missing & scoped_relevant)
    covered = len(scoped_relevant) - len(scoped_missing)
    total = len(scoped_relevant)
    if total:
        pct = (covered / total) * 100
        print(f"{target}: {pct:.2f}% ({covered}/{total})")
    else:
        print(f"{target}: n/a (0/0)")
    if scoped_missing:
        failures.append(f"{target}: missing lines {scoped_missing}")

if failures:
    print("\nServer Docker storage backend coverage gate failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)

print("\nServer Docker storage backend coverage gate passed.")
PY
