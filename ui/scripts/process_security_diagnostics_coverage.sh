#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COVERAGE_DIR="${APP_DIR}/coverage/process-security-diagnostics"
LCOV_PATH="${COVERAGE_DIR}/lcov.info"
TARGET="lib/services/process_security_diagnostics.dart"

cd "${APP_DIR}"
rm -rf "${COVERAGE_DIR}"
mkdir -p "${COVERAGE_DIR}"

flutter test \
  --coverage \
  --coverage-path "${LCOV_PATH}" \
  test/services/native_bridge_test.dart

python3 - "${LCOV_PATH}" "${TARGET}" <<'PY'
from pathlib import Path
import sys

lcov_path = Path(sys.argv[1])
target = sys.argv[2]
current = None
covered = 0
total = 0
for line in lcov_path.read_text(encoding="utf-8").splitlines():
    if line.startswith("SF:"):
        source = line[3:].replace("\\", "/")
        current = source[source.find("lib/"):] if "lib/" in source else source
        continue
    if current != target or not line.startswith("DA:"):
        continue
    total += 1
    if int(line[3:].split(",", 1)[1]) > 0:
        covered += 1

percent = covered * 100.0 / total if total else 0.0
print(f"Process security diagnostics coverage: {percent:.2f}% ({covered}/{total})")
if total == 0 or covered != total:
    raise SystemExit("Process security diagnostics coverage must remain 100.00%.")
PY
