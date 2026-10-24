#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/backend_paths.sh"
CONTRACTS_SCRIPT="$(resolve_backend_script_path release_contracts.py)"
DEPLOYDASH_MACOS_DMG_SIGN_IDENTITY="${DEPLOYDASH_MACOS_DMG_SIGN_IDENTITY:-${MACOS_DMG_SIGN_IDENTITY:-Developer ID Application: Tidy Technology Ltd (CAZ3ADRS95)}}"
DMG_SIGN_IDENTITY="${DEPLOYDASH_MACOS_DMG_SIGN_IDENTITY}"
PYTHON_EXE="${ORCHESTRATOR_VENV_PYTHON:-${DEPLOYDASH_ENGINE_VENV_PYTHON:-}}"
MACOS_ARCH="${DEPLOYDASH_MACOS_ARCH:-arm64}"
BUILD_NAME="${DEPLOYDASH_BUILD_NAME:-}"

usage() {
  cat <<'EOF'
Usage: rebuild_macos_dmg.sh [--skip-build]

Rebuilds the Deploy Dash macOS DMG through the supported packaging flow,
verifies the signed .app bundle, signs the DMG container itself, and verifies
the final DMG signature.

Options:
  --skip-build   Repackage the existing release app bundle instead of
                 rebuilding it.
  -h, --help     Show this help message.

Optional environment override:
  DEPLOYDASH_MACOS_DMG_SIGN_IDENTITY
    or MACOS_DMG_SIGN_IDENTITY
    Developer ID Application identity used to sign the app and DMG file.
    Defaults to Developer ID Application: Tidy Technology Ltd (CAZ3ADRS95).

Notes:
  - Every nested framework/runtime binary and the outer .app are signed with
    the supplied identity before the DMG is created.
  - This script signs the DMG container; it does not notarize or staple it.
EOF
}

BUILD_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      BUILD_ARGS+=("$1")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}" >&2
    exit 1
  fi
}

require_command bash
require_command codesign
require_command hdiutil

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "rebuild_macos_dmg.sh must run on macOS." >&2
  exit 1
fi

if [[ -z "${PYTHON_EXE}" ]] && command -v uv >/dev/null 2>&1; then
  PYTHON_EXE="$(uv python find 3.13.14 2>/dev/null || true)"
fi

if [[ -z "${PYTHON_EXE}" ]]; then
  echo "Unable to locate Python 3.13.14 via uv for backend release helpers." >&2
  exit 1
fi

echo "Building signed macOS app bundle and DMG..."
if [[ ${#BUILD_ARGS[@]} -gt 0 ]]; then
  DEPLOYDASH_MACOS_APP_SIGN_IDENTITY="${DMG_SIGN_IDENTITY}" \
    bash "${SCRIPT_DIR}/build_macos_dmg.sh" --package-only "${BUILD_ARGS[@]}"
else
  DEPLOYDASH_MACOS_APP_SIGN_IDENTITY="${DMG_SIGN_IDENTITY}" \
    bash "${SCRIPT_DIR}/build_macos_dmg.sh" --package-only
fi

APP_BUNDLE="$(
  "${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" locate-macos-app-bundle \
    --release-dir "${APP_DIR}/build/macos/Build/Products/Release"
)"
DMG_NAME="$(
  "${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" macos-dmg-name \
    --build-name "${BUILD_NAME:-}" \
    --arch "${MACOS_ARCH}"
)"
DMG_PATH="${APP_DIR}/build/macos/distribution/${DMG_NAME}"

"${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" assert-artifact \
  --path "${APP_BUNDLE}" \
  --label "macOS app bundle"
"${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" assert-artifact \
  --path "${DMG_PATH}" \
  --label "DMG"

echo "Verifying signed app bundle at ${APP_BUNDLE}"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
bash "${SCRIPT_DIR}/verify_macos_hardened_runtime.sh" "${APP_BUNDLE}"

echo "Signing DMG with identity: ${DMG_SIGN_IDENTITY}"
codesign \
  --force \
  --sign "${DMG_SIGN_IDENTITY}" \
  --timestamp \
  --verbose \
  "${DMG_PATH}"

echo "Verifying signed DMG at ${DMG_PATH}"
codesign --verify --strict --verbose=2 "${DMG_PATH}"

echo "Built and signed DMG at ${DMG_PATH}"
