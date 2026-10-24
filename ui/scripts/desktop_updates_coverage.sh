#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COVERAGE_DIR="${APP_DIR}/coverage/desktop_updates"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"

mkdir -p "${COVERAGE_DIR}"

cd "${APP_DIR}"
flutter test \
  --coverage \
  --coverage-path="${LCOV_PATH}" \
  test/services/device_identity_service_test.dart \
  test/data/local/device_installation_repository_test.dart \
  test/services/desktop_update_service_test.dart \
  test/services/desktop_update_http_test.dart \
  test/ui/settings/desktop_updates_view_test.dart

python3 - "${LCOV_PATH}" <<'PY'
from pathlib import Path
import sys

lcov_path = Path(sys.argv[1])
targets = {
    "lib/services/device_identity_service.dart",
    "lib/data/local/device_installation_repository.dart",
    "lib/services/desktop_update_service.dart",
    "lib/ui/settings/desktop_updates_view.dart",
}
records = {}
for raw_record in lcov_path.read_text(encoding="utf-8").split("end_of_record"):
    lines = raw_record.splitlines()
    source = next((line[3:] for line in lines if line.startswith("SF:")), None)
    if source is None:
        continue
    # SF lines are already repo-relative (lib/...); an absolute checkout path
    # would end in the same suffix, so strip up to lib/ instead of splitting
    # on "/ui/" (which mangles lib/ui/... into a bare tail).
    relative = "lib/" + source.split("lib/")[-1]
    if relative not in targets:
        continue
    found = int(next(line[3:] for line in lines if line.startswith("LF:")))
    hit = int(next(line[3:] for line in lines if line.startswith("LH:")))
    records[relative] = (hit, found)

missing = targets.difference(records)
if missing:
    raise SystemExit(f"Desktop update coverage records missing: {sorted(missing)}")

failed = False
for target in sorted(targets):
    hit, found = records[target]
    percent = 100.0 if found == 0 else hit * 100.0 / found
    print(f"{target}: {hit}/{found} ({percent:.2f}%)")
    if hit != found:
        failed = True
if failed:
    raise SystemExit("Desktop identity/update coverage must remain 100.00%.")
print("Desktop identity/update coverage: 100.00%")
PY
