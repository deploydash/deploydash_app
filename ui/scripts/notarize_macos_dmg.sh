#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/backend_paths.sh"
CONTRACTS_SCRIPT="$(resolve_backend_script_path release_contracts.py)"

PYTHON_EXE="${ORCHESTRATOR_VENV_PYTHON:-${DEPLOYDASH_ENGINE_VENV_PYTHON:-}}"
MACOS_ARCH="${DEPLOYDASH_MACOS_ARCH:-arm64}"
BUILD_NAME="${DEPLOYDASH_BUILD_NAME:-}"
NOTARY_PROFILE="${DEPLOYDASH_MACOS_NOTARY_PROFILE:-${MACOS_NOTARY_PROFILE:-}}"
APPLE_ID_VALUE="${DEPLOYDASH_APPLE_ID:-${APPLE_ID:-}}"
APPLE_TEAM_ID_VALUE="${DEPLOYDASH_APPLE_TEAM_ID:-${APPLE_TEAM_ID:-}}"
APPLE_APP_PASSWORD_VALUE="${DEPLOYDASH_APPLE_APP_PASSWORD:-${APPLE_APP_PASSWORD:-}}"
REBUILD_FIRST=0

usage() {
  cat <<'EOF'
Usage: notarize_macos_dmg.sh [--rebuild]

Submit the signed Deploy Dash DMG to Apple notarization, wait for the result,
staple the approved ticket to the DMG, and validate the stapled artifact.

Options:
  --rebuild    Run rebuild_macos_dmg.sh before notarization.
  -h, --help   Show this help message.

Preferred authentication:
  DEPLOYDASH_MACOS_NOTARY_PROFILE
    or MACOS_NOTARY_PROFILE
    Name of an xcrun notarytool keychain profile.

Direct credential fallback:
  DEPLOYDASH_APPLE_ID or APPLE_ID
  DEPLOYDASH_APPLE_TEAM_ID or APPLE_TEAM_ID
  DEPLOYDASH_APPLE_APP_PASSWORD or APPLE_APP_PASSWORD

Example profile setup:
  xcrun notarytool store-credentials deploydash-notary \
    --apple-id you@example.com \
    --team-id ABC1234567 \
    --password app-specific-password

  export DEPLOYDASH_MACOS_NOTARY_PROFILE=deploydash-notary
  bash scripts/notarize_macos_dmg.sh --rebuild
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild)
      REBUILD_FIRST=1
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

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "notarize_macos_dmg.sh must run on macOS." >&2
  exit 1
fi

if [[ -z "${PYTHON_EXE}" ]] && command -v uv >/dev/null 2>&1; then
  PYTHON_EXE="$(uv python find 3.13.14 2>/dev/null || true)"
fi

if [[ -z "${PYTHON_EXE}" ]]; then
  echo "Unable to locate Python 3.13.14 via uv for backend release helpers." >&2
  exit 1
fi

require_command bash
require_command xcrun

if [[ "${REBUILD_FIRST}" -eq 1 ]]; then
  bash "${SCRIPT_DIR}/rebuild_macos_dmg.sh"
fi

DMG_NAME="$(
  "${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" macos-dmg-name \
    --build-name "${BUILD_NAME:-}" \
    --arch "${MACOS_ARCH}"
)"
DMG_PATH="${APP_DIR}/build/macos/distribution/${DMG_NAME}"
"${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" assert-artifact \
  --path "${DMG_PATH}" \
  --label "DMG"

if [[ -n "${NOTARY_PROFILE}" ]]; then
  submit_args=(
    submit
    "${DMG_PATH}"
    --keychain-profile "${NOTARY_PROFILE}"
    --wait
  )
elif [[ -n "${APPLE_ID_VALUE}" && -n "${APPLE_TEAM_ID_VALUE}" && -n "${APPLE_APP_PASSWORD_VALUE}" ]]; then
  submit_args=(
    submit
    "${DMG_PATH}"
    --apple-id "${APPLE_ID_VALUE}"
    --team-id "${APPLE_TEAM_ID_VALUE}"
    --password "${APPLE_APP_PASSWORD_VALUE}"
    --wait
  )
else
  echo "Provide DEPLOYDASH_MACOS_NOTARY_PROFILE or the Apple ID/team ID/app password credentials." >&2
  exit 1
fi

echo "Submitting DMG for notarization: ${DMG_PATH}"
xcrun notarytool "${submit_args[@]}"

echo "Stapling notarization ticket to DMG"
xcrun stapler staple "${DMG_PATH}"

echo "Validating stapled DMG"
xcrun stapler validate "${DMG_PATH}"

if command -v spctl >/dev/null 2>&1; then
  echo "Assessing stapled DMG with Gatekeeper"
  spctl \
    --assess \
    --type open \
    --context context:primary-signature \
    --verbose=4 \
    "${DMG_PATH}"
fi

echo "Notarized and stapled DMG at ${DMG_PATH}"
