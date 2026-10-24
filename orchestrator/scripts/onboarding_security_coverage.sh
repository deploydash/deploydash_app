#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

COVERAGE_DIR="coverage/onboarding_security"
REPORT_JSON="${COVERAGE_DIR}/coverage.json"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

TEST_MODULES=(
  tests.setup_config_test
  tests.setup_part1_system_foundation_test
  tests.setup_part2_stability_test
  tests.swap_management_test
  tests.setup_part3_docker_test
  tests.setup_part4_security_test
  tests.setup_part5_railpack_test
  tests.ssh_test
  tests.setup_security_test
  tests.ssh_hostkey_test
  tests.setup_postflight_test
  tests.setup_additive_admin_access_test
  tests.setup_server_test
  tests.app_config_test
  tests.dns_config_test
  tests.http_config_test
  tests.postgres_config_test
  tests.server_tooling_test
)

INCLUDE_FILES=(
  "src/orchestrator/setup_parts/setup_config.py"
  "src/orchestrator/setup_parts/part1_system_foundation.py"
  "src/orchestrator/setup_parts/part2_stability.py"
  "src/orchestrator/swap_management.py"
  "src/orchestrator/setup_parts/part3_docker_prep.py"
  "src/orchestrator/setup_parts/part4_passive_security.py"
  "src/orchestrator/setup_parts/part5_railpack_builds.py"
  "src/orchestrator/setup_security.py"
  "src/orchestrator/ssh_hostkey.py"
  "src/orchestrator/setup_postflight.py"
  "src/orchestrator/config_validation.py"
  "src/orchestrator/infra_parts/tooling.py"
)

INCLUDE_CSV="$(IFS=,; echo "${INCLUDE_FILES[*]}")"

# I-12 absence check: no code path may delete admin keys or ask to. The
# retired takeover surface must never quietly regain a foothold.
if grep -rn --include="*.py" -E "confirm_existing_admin_takeover|requires_admin_takeover_confirmation|delete_keys.*True" src/ | grep -v __pycache__; then
  echo "Takeover surface still present; see I-12." >&2
  exit 1
fi

uv run --with coverage coverage erase
uv run --with coverage coverage run --branch -m unittest "${TEST_MODULES[@]}"
uv run --with coverage coverage json --include="${INCLUDE_CSV}" -o "${REPORT_JSON}"

uv run python - <<'PY'
import json
import sys
from pathlib import Path

report_path = Path("coverage/onboarding_security/coverage.json")
data = json.loads(report_path.read_text())
files = data["files"]

bad = []
for path in sorted(files):
    summary = files[path]["summary"]
    lines = summary["percent_statements_covered"]
    branches = summary["percent_branches_covered"]
    print(
        f"{path}: "
        f"lines {summary['covered_lines']}/{summary['num_statements']} "
        f"({lines:.2f}%), "
        f"branches {summary['covered_branches']}/{summary['num_branches']} "
        f"({branches:.2f}%)",
    )
    if abs(lines - 100.0) > 1e-9 or abs(branches - 100.0) > 1e-9:
        bad.append(path)

if bad:
    print("\nOnboarding security coverage gate failed:")
    for path in bad:
        print(f"- {path}")
    sys.exit(1)

print("\nOnboarding security coverage gate passed.")
PY
