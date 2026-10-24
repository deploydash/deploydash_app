#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/backend_paths.sh"
CONTRACTS_SCRIPT="$(resolve_backend_script_path release_contracts.py)"
OUTPUT_DIR="${APP_DIR}/build/macos/distribution"
SKIP_BUILD=0
PACKAGE_ONLY=0
APP_SIGN_IDENTITY="${DEPLOYDASH_MACOS_APP_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${DEPLOYDASH_MACOS_NOTARY_PROFILE:-${MACOS_NOTARY_PROFILE:-}}"
DART_DEFINES_FILE="${DEPLOYDASH_DART_DEFINES_FILE:-config/dart-defines.local.json}"
BUILD_NAME="${DEPLOYDASH_BUILD_NAME:-}"
BUILD_NUMBER="${DEPLOYDASH_BUILD_NUMBER:-}"
PYTHON_EXE="${ORCHESTRATOR_VENV_PYTHON:-${DEPLOYDASH_ENGINE_VENV_PYTHON:-}}"
DIRECT_ENTITLEMENTS="${APP_DIR}/macos/Runner/Release.direct.entitlements"
SPARKLE_FEED_URL="${DEPLOYDASH_SPARKLE_FEED_URL:-https://updates.deploydash.com/feeds/macos/stable/appcast.xml}"
SPARKLE_PUBLIC_KEY="${DEPLOYDASH_SPARKLE_PUBLIC_KEY:-xRAtjhwXD7TBdm1nxwl0srQnXNTFgaQWZ8VaKXf2LGg=}"
# Target Apple architecture for this DMG: arm64 or x64 (x86_64 accepted and
# normalized by the naming helper). Defaults to arm64; the CI matrix sets
# x64 on the Intel leg.
MACOS_ARCH="${DEPLOYDASH_MACOS_ARCH:-arm64}"
# Xcode architecture(s) derived from the target: xcconfigs read
# DEPLOYDASH_MACOS_ARCHS, defaulting to arm64 there as well.
case "${MACOS_ARCH}" in
  arm64) MACOS_ARCHS="arm64" ;;
  x64|x86_64) MACOS_ARCHS="x86_64" ;;
  *)
    echo "DEPLOYDASH_MACOS_ARCH must be arm64 or x64, got: ${MACOS_ARCH}" >&2
    exit 1
    ;;
esac
export DEPLOYDASH_MACOS_ARCHS="${DEPLOYDASH_MACOS_ARCHS:-${MACOS_ARCHS}}"

usage() {
  cat <<'EOF'
Usage: build_macos_dmg.sh [--skip-build] [--package-only]

Build, Developer ID sign, notarize, staple, and validate the production macOS
DMG. The default signing identity is configured by rebuild_macos_dmg.sh. The
default notarytool Keychain profile is deploydash-notary.

Options:
  --skip-build    Repackage and notarize the existing release app bundle.
  --package-only  Build and package without signing the DMG or notarizing it.
                  This lower-level mode is used by rebuild_macos_dmg.sh and
                  unsigned CI artifact builds.
  -h, --help      Show this help message.

Optional environment overrides:
  DEPLOYDASH_DART_DEFINES_FILE
    Dart-defines JSON passed to Flutter. Defaults to the local-only
    config/dart-defines.local.json file.
  DEPLOYDASH_MACOS_NOTARY_PROFILE or MACOS_NOTARY_PROFILE
    Name of the notarytool Keychain profile. Defaults to deploydash-notary
    unless direct Apple notarization credentials are supplied.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --package-only)
      PACKAGE_ONLY=1
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

if [[ "${PACKAGE_ONLY}" -eq 0 ]]; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "build_macos_dmg.sh must run on macOS." >&2
    exit 1
  fi

  if [[ -z "${BUILD_NAME}" ]]; then
    echo "The production DMG chain requires DEPLOYDASH_BUILD_NAME (from the release tag)." >&2
    echo "Use --package-only for local dev builds, which keep the unversioned name." >&2
    exit 1
  fi

  REBUILD_ARGS=()
  if [[ "${SKIP_BUILD}" -eq 1 ]]; then
    REBUILD_ARGS+=(--skip-build)
  fi

  echo "Building the production signed macOS DMG..."
  if [[ ${#REBUILD_ARGS[@]} -gt 0 ]]; then
    bash "${SCRIPT_DIR}/rebuild_macos_dmg.sh" "${REBUILD_ARGS[@]}"
  else
    bash "${SCRIPT_DIR}/rebuild_macos_dmg.sh"
  fi

  if [[ -n "${NOTARY_PROFILE}" ]]; then
    DEPLOYDASH_MACOS_NOTARY_PROFILE="${NOTARY_PROFILE}" \
      bash "${SCRIPT_DIR}/notarize_macos_dmg.sh"
  elif [[ \
    -n "${DEPLOYDASH_APPLE_ID:-${APPLE_ID:-}}" && \
    -n "${DEPLOYDASH_APPLE_TEAM_ID:-${APPLE_TEAM_ID:-}}" && \
    -n "${DEPLOYDASH_APPLE_APP_PASSWORD:-${APPLE_APP_PASSWORD:-}}" \
  ]]; then
    bash "${SCRIPT_DIR}/notarize_macos_dmg.sh"
  else
    DEPLOYDASH_MACOS_NOTARY_PROFILE=deploydash-notary \
      bash "${SCRIPT_DIR}/notarize_macos_dmg.sh"
  fi

  echo "Production macOS DMG is signed, notarized, stapled, and validated."
  exit 0
fi

command -v hdiutil >/dev/null 2>&1 || {
  echo "hdiutil is required and is only available on macOS." >&2
  exit 1
}

if [[ -z "${PYTHON_EXE}" ]] && command -v uv >/dev/null 2>&1; then
  PYTHON_EXE="$(uv python find 3.13.14 2>/dev/null || true)"
fi

if [[ -z "${PYTHON_EXE}" ]]; then
  echo "Unable to locate Python 3.13.14 via uv for backend release helpers." >&2
  exit 1
fi

if [[ -z "${APP_SIGN_IDENTITY}" ]]; then
  command -v security >/dev/null 2>&1 || {
    echo "security is required to select a macOS signing identity." >&2
    exit 1
  }
  APP_SIGN_IDENTITY="$(
    security find-identity -v -p codesigning | \
      "${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" select-macos-signing-identity
  )"
fi
echo "Using macOS app signing identity: ${APP_SIGN_IDENTITY}"

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  FLUTTER_BUILD_ARGS=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && FLUTTER_BUILD_ARGS+=("${line}")
  done < <(
    "${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" flutter-build-args \
      --app-dir "${APP_DIR}" \
      --dart-defines-file "${DART_DEFINES_FILE}" \
      --build-name "${BUILD_NAME}" \
      --build-number "${BUILD_NUMBER}"
  )
  FLUTTER_BUILD_ARGS+=(
    --dart-define=DEPLOYDASH_DISTRIBUTION=dmg
    --dart-define=DEPLOYDASH_RELEASE_CHANNEL=stable
  )
  (
    cd "${APP_DIR}"
    if [[ ${#FLUTTER_BUILD_ARGS[@]} -gt 0 ]]; then
      DEPLOYDASH_MACOS_INCLUDE_SPARKLE=1 \
        flutter build macos --release "${FLUTTER_BUILD_ARGS[@]}"
    else
      DEPLOYDASH_MACOS_INCLUDE_SPARKLE=1 flutter build macos --release
    fi
  )
fi

APP_BUNDLE="$(
  "${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" locate-macos-app-bundle \
    --release-dir "${APP_DIR}/build/macos/Build/Products/Release"
)"

SPARKLE_FRAMEWORK="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "${SPARKLE_FRAMEWORK}" ]]; then
  echo "Direct macOS build is missing the pinned Sparkle framework." >&2
  exit 1
fi
INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"
set_plist_value() {
  local key="$1"
  local type="$2"
  local value="$3"
  if ! /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${INFO_PLIST}" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :${key} ${type} ${value}" "${INFO_PLIST}"
  fi
}
set_plist_value SUFeedURL string "${SPARKLE_FEED_URL}"
set_plist_value SUPublicEDKey string "${SPARKLE_PUBLIC_KEY}"
set_plist_value SUEnableInstallerLauncherService bool true

bash "${SCRIPT_DIR}/sign_macos_app_bundle.sh" \
  "${APP_BUNDLE}" \
  "${APP_SIGN_IDENTITY}" \
  "${DIRECT_ENTITLEMENTS}"

    mkdir -p "${OUTPUT_DIR}"
    DMG_NAME="$(
      "${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" macos-dmg-name \
        --build-name "${BUILD_NAME}" \
        --arch "${MACOS_ARCH}"
    )"
    DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"
    rm -f "${DMG_PATH}"

TMP_STAGE="$(mktemp -d)"
trap 'rm -rf "${TMP_STAGE}"' EXIT
cp -R "${APP_BUNDLE}" "${TMP_STAGE}/"
ln -s /Applications "${TMP_STAGE}/Applications"

hdiutil create \
  -volname "Deploy Dash" \
  -srcfolder "${TMP_STAGE}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

"${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" assert-artifact \
  --path "${DMG_PATH}" \
  --label "DMG"

echo "Built DMG at ${DMG_PATH}"
