#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COVERAGE_DIR="${APP_DIR}/coverage/models"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

cd "${APP_DIR}"
flutter test --coverage --branch-coverage \
  test/models/result_test.dart \
  test/models/engine_failure_mapper_test.dart \
  test/models/deploy_failure_evidence_test.dart \
  test/models/storage_failure_mapper_test.dart \
  test/models/app_user_attribute_test.dart \
  test/models/postgres_storage_status_test.dart \
  test/ui/layout/home_telemetry_nag_test.dart \
  --coverage-path "${LCOV_PATH}"

python3 - "${LCOV_PATH}" <<'PY'
from pathlib import Path
import sys

lcov_path = Path(sys.argv[1])
targets = {
    "lib/models/result.dart",
    "lib/models/engine_failure_mapper.dart",
    "lib/models/deploy_failure_evidence.dart",
    "lib/models/storage_failure_mapper.dart",
    "lib/models/app_user_attribute.dart",
    "lib/models/telemetry_prompt.dart",
    "lib/models/postgres_storage_status.dart",
}
# New models pin branches too; pre-existing targets keep their line-only
# enforcement rather than failing on untouched historical branches.
branch_targets = {
    "lib/models/deploy_failure_evidence.dart",
    "lib/models/engine_failure_mapper.dart",
    "lib/models/postgres_storage_status.dart",
    "lib/models/result.dart",
    "lib/models/storage_failure_mapper.dart",
}
records = {}
branch_records = {}

for raw_record in lcov_path.read_text(encoding="utf-8").split("end_of_record"):
    lines = raw_record.splitlines()
    source = next((line[3:] for line in lines if line.startswith("SF:")), None)
    if source is None:
        continue
    relative = source.split("/ui/")[-1]
    if relative not in targets:
        continue
    found = int(next(line[3:] for line in lines if line.startswith("LF:")))
    hit = int(next(line[3:] for line in lines if line.startswith("LH:")))
    records[relative] = (hit, found)
    if relative in branch_targets:
        taken = [
            int(line[5:].rsplit(",", 1)[1])
            for line in lines
            if line.startswith("BRDA:")
        ]
        branch_records[relative] = (
            sum(1 for count in taken if count > 0),
            len(taken),
        )

missing = targets.difference(records)
if missing:
    raise SystemExit(f"Model coverage records missing: {sorted(missing)}")

failed = False
for target in sorted(targets):
    hit, found = records[target]
    percent = 100.0 if found == 0 else hit * 100.0 / found
    print(f"{target}: {hit}/{found} ({percent:.2f}%)")
    if hit != found:
        failed = True
for target in sorted(branch_targets):
    hit, found = branch_records[target]
    percent = 100.0 if found == 0 else hit * 100.0 / found
    print(f"{target} (branch): {hit}/{found} ({percent:.2f}%)")
    if hit != found:
        failed = True
if failed:
    raise SystemExit("Desktop model coverage must remain 100.00%.")
print("Desktop model coverage: 100.00%")
PY
