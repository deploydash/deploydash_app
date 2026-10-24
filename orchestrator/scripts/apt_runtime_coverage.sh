#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/apt_runtime"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"
TARGET="src/orchestrator/apt_runtime.py"
INCLUDE="${TARGET},src/orchestrator/pyinfra_runtime.py,src/orchestrator/setup_parts/part3_docker_prep.py"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest tests.apt_lock_timeout_test
uv run --with coverage coverage json --include="${INCLUDE}" -o "${REPORT_JSON}"

python3 - "${REPORT_JSON}" "${TARGET}" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
target = sys.argv[2]
data = report.get("files", {}).get(target)
if data is None:
    raise SystemExit(f"{target}: no coverage payload")

targets = {
    target: (None, data),
    "src/orchestrator/pyinfra_runtime.py": (
        "PyinfraRuntimeSession.ensure_apt_updated",
        None,
    ),
    "src/orchestrator/setup_parts/part3_docker_prep.py": (
        "_docker_pinned_install_command",
        None,
    ),
}

failures = []
for path, (symbol, payload) in targets.items():
    file_payload = report.get("files", {}).get(path)
    if file_payload is None:
        failures.append(f"{path}: no coverage payload")
        continue
    if payload is None:
        payload = file_payload.get("functions", {}).get(symbol)
    label = path if symbol is None else f"{path}:{symbol}"
    if payload is None:
        failures.append(f"{label}: no function coverage payload")
        continue
    summary = payload["summary"]
    covered_lines = summary["covered_lines"]
    total_lines = summary["num_statements"]
    covered_branches = summary["covered_branches"]
    total_branches = summary["num_branches"]
    print(
        f"{label}: lines {covered_lines}/{total_lines}; "
        f"branches {covered_branches}/{total_branches}",
    )
    if covered_lines != total_lines or covered_branches != total_branches:
        failures.append(
            f"{label}: missing lines {payload.get('missing_lines', [])}; "
            f"missing branches {payload.get('missing_branches', [])}",
        )

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    raise SystemExit("APT runtime coverage must remain 100% line and branch.")

print("APT runtime coverage gate passed.")
PY
