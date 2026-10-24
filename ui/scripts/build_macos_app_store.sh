#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/backend_paths.sh"
CONTRACTS_SCRIPT="$(resolve_backend_script_path release_contracts.py)"
TEMPLATE_PATH="${APP_DIR}/packaging/macos/ExportOptions.appstore.plist.template"
OUTPUT_DIR="${APP_DIR}/build/macos/app_store"
ARCHIVE_PATH="${OUTPUT_DIR}/DeployDash.xcarchive"
EXPORT_OPTIONS_PATH="${OUTPUT_DIR}/ExportOptions.plist"
EXPORT_PATH="${OUTPUT_DIR}/export"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-CAZ3ADRS95}"
DART_DEFINES_FILE="${DEPLOYDASH_DART_DEFINES_FILE:-}"
BUILD_NAME="${DEPLOYDASH_BUILD_NAME:-}"
BUILD_NUMBER="${DEPLOYDASH_BUILD_NUMBER:-}"
PYTHON_EXE="${ORCHESTRATOR_VENV_PYTHON:-${DEPLOYDASH_ENGINE_VENV_PYTHON:-}}"

if [[ -z "${APPLE_TEAM_ID}" ]]; then
  echo "Set APPLE_TEAM_ID before building the Mac App Store artifact." >&2
  exit 1
fi

command -v xcodebuild >/dev/null 2>&1 || {
  echo "xcodebuild is required and is only available on macOS." >&2
  exit 1
}

if [[ -z "${PYTHON_EXE}" ]] && command -v uv >/dev/null 2>&1; then
  PYTHON_EXE="$(uv python find 3.13.14 2>/dev/null || true)"
fi

if [[ -z "${PYTHON_EXE}" ]]; then
  echo "Unable to locate Python 3.13.14 via uv for backend release helpers." >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}" "${EXPORT_PATH}"
sed "s/__APPLE_TEAM_ID__/${APPLE_TEAM_ID}/g" \
  "${TEMPLATE_PATH}" > "${EXPORT_OPTIONS_PATH}"

FLUTTER_BUILD_ARGS=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && FLUTTER_BUILD_ARGS+=("${line}")
done < <(
  "${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" flutter-build-args \
    --app-dir "${APP_DIR}" \
    --dart-defines-file "${DART_DEFINES_FILE}" \
    --build-name "${BUILD_NAME}" \
    --build-number "${BUILD_NUMBER}" \
    --default-to-pubspec
)
FLUTTER_BUILD_ARGS+=(
  --dart-define=DEPLOYDASH_DISTRIBUTION=mac_app_store
  --dart-define=DEPLOYDASH_RELEASE_CHANNEL=stable
)

(
  cd "${APP_DIR}"
  if [[ ${#FLUTTER_BUILD_ARGS[@]} -gt 0 ]]; then
    DEPLOYDASH_MACOS_INCLUDE_SPARKLE=0 \
      flutter build macos --release "${FLUTTER_BUILD_ARGS[@]}"
  else
    DEPLOYDASH_MACOS_INCLUDE_SPARKLE=0 flutter build macos --release
  fi
)

DEPLOYDASH_MACOS_INCLUDE_SPARKLE=0 xcodebuild archive \
  -workspace "${APP_DIR}/macos/Runner.xcworkspace" \
  -scheme Runner \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  DEVELOPMENT_TEAM="${APPLE_TEAM_ID}"

ARCHIVED_APP="$("${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" locate-macos-app-bundle \
  --release-dir "${ARCHIVE_PATH}/Products/Applications")"
if [[ -d "${ARCHIVED_APP}/Contents/Frameworks/Sparkle.framework" ]]; then
  echo "Mac App Store archive must not include Sparkle.framework." >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' \
  "${ARCHIVED_APP}/Contents/Info.plist" >/dev/null 2>&1; then
  echo "Mac App Store archive must not include Sparkle update settings." >&2
  exit 1
fi
bash "${SCRIPT_DIR}/verify_macos_hardened_runtime.sh" "${ARCHIVED_APP}"

xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS_PATH}" \
  -exportPath "${EXPORT_PATH}"

"${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" assert-artifact \
  --path "${EXPORT_PATH}" \
  --label "Mac App Store export"

echo "Built Mac App Store export at ${EXPORT_PATH}"
