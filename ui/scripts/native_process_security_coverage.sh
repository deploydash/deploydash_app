#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${APP_DIR}/build/native-process-security-coverage"
SOURCE="${APP_DIR}/shared_native/process_security.cc"
TEST_SOURCE="${APP_DIR}/shared_native/process_security_test.cc"
BINARY="${BUILD_DIR}/process_security_test"
PROFILE="${BUILD_DIR}/process_security.profraw"
PROFILE_DATA="${BUILD_DIR}/process_security.profdata"
REPORT="${BUILD_DIR}/coverage.json"

CLANGXX="$(command -v clang++ || true)"
for command in python3; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "Missing required native coverage command: ${command}" >&2
    exit 1
  }
done

if [[ -z "${CLANGXX}" ]]; then
  echo "Missing required native coverage command: clang++" >&2
  exit 1
fi

# LLVM instrumentation profiles are versioned. Mixing the compiler that wrote
# a profile with the first llvm-profdata on PATH can make a valid profile
# unreadable, so obtain the tools from that compiler's toolchain first.
LLVM_PROFDATA="$("${CLANGXX}" -print-prog-name=llvm-profdata)"
LLVM_COV="$("${CLANGXX}" -print-prog-name=llvm-cov)"

if [[ ! -x "${LLVM_PROFDATA}" || ! -x "${LLVM_COV}" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    LLVM_PROFDATA="$(xcrun --find llvm-profdata 2>/dev/null || true)"
    LLVM_COV="$(xcrun --find llvm-cov 2>/dev/null || true)"
  fi
fi

if [[ ! -x "${LLVM_PROFDATA}" || ! -x "${LLVM_COV}" ]]; then
  for llvm_bin_dir in /usr/lib/llvm-*/bin /usr/local/opt/llvm/bin /opt/homebrew/opt/llvm/bin; do
    if [[ -x "${llvm_bin_dir}/clang++" && -x "${llvm_bin_dir}/llvm-profdata" && -x "${llvm_bin_dir}/llvm-cov" ]]; then
      CLANGXX="${llvm_bin_dir}/clang++"
      LLVM_PROFDATA="${llvm_bin_dir}/llvm-profdata"
      LLVM_COV="${llvm_bin_dir}/llvm-cov"
      break
    fi
  done
fi

if [[ ! -x "${LLVM_PROFDATA}" || ! -x "${LLVM_COV}" ]]; then
  echo "Missing required native coverage commands: llvm-profdata and llvm-cov" >&2
  exit 1
fi

echo "Native coverage compiler: ${CLANGXX}"
echo "Native coverage LLVM tools: ${LLVM_PROFDATA}, ${LLVM_COV}"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

"${CLANGXX}" \
  -std=c++17 \
  -Wall \
  -Wextra \
  -Werror \
  -DDEPLOYDASH_PROCESS_SECURITY_TESTING=1 \
  -fprofile-instr-generate \
  -fcoverage-mapping \
  -I "${APP_DIR}/shared_native" \
  "${SOURCE}" \
  "${TEST_SOURCE}" \
  -o "${BINARY}"

LLVM_PROFILE_FILE="${PROFILE}" "${BINARY}"
"${LLVM_PROFDATA}" merge -sparse "${PROFILE}" -o "${PROFILE_DATA}"
"${LLVM_COV}" export "${BINARY}" \
  -instr-profile="${PROFILE_DATA}" \
  -ignore-filename-regex='process_security_test\.cc$' \
  > "${REPORT}"

python3 - "${REPORT}" "${SOURCE}" <<'PY'
import json
import pathlib
import sys

report_path = pathlib.Path(sys.argv[1])
source_path = pathlib.Path(sys.argv[2]).resolve()
report = json.loads(report_path.read_text(encoding="utf-8"))

matches = [
    entry
    for unit in report["data"]
    for entry in unit["files"]
    if pathlib.Path(entry["filename"]).resolve() == source_path
]
if len(matches) != 1:
    raise SystemExit(
        f"Expected one coverage entry for {source_path}, got {len(matches)}"
    )

summary = matches[0]["summary"]
for metric in ("lines", "branches"):
    covered = summary[metric]["covered"]
    count = summary[metric]["count"]
    percent = 100.0 if count == 0 else covered * 100.0 / count
    print(f"Native process security {metric}: {percent:.2f}% ({covered}/{count})")
    if covered != count:
        raise SystemExit(
            f"Native process security {metric} coverage must remain 100.00%."
        )
PY
