#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/backend_paths.sh"
CONTRACTS_SCRIPT="$(resolve_backend_script_path release_contracts.py)"

APP_BUNDLE="${1:-}"
SIGN_IDENTITY="${2:-}"
ENTITLEMENTS_PATH="${3:-${APP_DIR}/macos/Runner/Release.entitlements}"
PYTHON_EXE="${ORCHESTRATOR_VENV_PYTHON:-${DEPLOYDASH_ENGINE_VENV_PYTHON:-}}"

if [[ -z "${APP_BUNDLE}" || ! -d "${APP_BUNDLE}" ]]; then
  echo "Usage: sign_macos_app_bundle.sh <Deploy Dash.app> [identity] [entitlements]" >&2
  exit 1
fi
if [[ ! -f "${ENTITLEMENTS_PATH}" ]]; then
  echo "macOS release entitlements not found: ${ENTITLEMENTS_PATH}" >&2
  exit 1
fi
if [[ -z "${SIGN_IDENTITY}" || "${SIGN_IDENTITY}" == "-" ]]; then
  echo "A real Apple code-signing identity is required for library validation." >&2
  exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "sign_macos_app_bundle.sh must run on macOS." >&2
  exit 1
fi
command -v codesign >/dev/null 2>&1 || {
  echo "codesign is required." >&2
  exit 1
}

if [[ -z "${PYTHON_EXE}" ]] && command -v uv >/dev/null 2>&1; then
  PYTHON_EXE="$(uv python find 3.13.14 2>/dev/null || true)"
fi
if [[ -z "${PYTHON_EXE}" ]]; then
  echo "Unable to locate Python 3.13.14 via uv for release helpers." >&2
  exit 1
fi

SIGN_ARGS=(--force --sign "${SIGN_IDENTITY}" --options runtime)
if [[ "${SIGN_IDENTITY}" == Developer\ ID\ Application:* ]]; then
  SIGN_ARGS+=(--timestamp)
else
  SIGN_ARGS+=(--timestamp=none)
fi

SIGNING_PATHS_FILE="$(mktemp)"
trap 'rm -f "${SIGNING_PATHS_FILE}"' EXIT
"${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" macos-signing-paths \
  --app-bundle "${APP_BUNDLE}" >"${SIGNING_PATHS_FILE}"

echo "Signing nested macOS code with identity: ${SIGN_IDENTITY}"
while IFS= read -r nested_code; do
  [[ -n "${nested_code}" ]] || continue
  if [[ "${nested_code}" == *.xpc ]]; then
    codesign \
      "${SIGN_ARGS[@]}" \
      --preserve-metadata=entitlements \
      "${nested_code}"
  else
    codesign "${SIGN_ARGS[@]}" "${nested_code}"
  fi
done <"${SIGNING_PATHS_FILE}"

echo "Signing macOS app bundle with identity: ${SIGN_IDENTITY}"
codesign \
  "${SIGN_ARGS[@]}" \
  --entitlements "${ENTITLEMENTS_PATH}" \
  "${APP_BUNDLE}"

bash "${SCRIPT_DIR}/verify_macos_hardened_runtime.sh" "${APP_BUNDLE}"
