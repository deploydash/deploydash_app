#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/backend_paths.sh"
CONTRACTS_SCRIPT="$(resolve_backend_script_path release_contracts.py)"
MANIFEST="${APP_DIR}/packaging/flatpak/com.deploydash.desktop.yml"
BUILD_ROOT="${APP_DIR}/build/flatpak"
WORK_DIR="${BUILD_ROOT}/workdir"
REPO_DIR="${BUILD_ROOT}/repo"
BUNDLE_PATH="${BUILD_ROOT}/com.deploydash.desktop.flatpak"
SKIP_BUILD=0

usage() {
  cat <<'EOF'
Usage: build_flatpak.sh [--skip-build]

Build a Flatpak bundle for Deploy Dash from the Linux release bundle.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
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

for command_name in flatpak-builder flatpak; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Missing required command: ${command_name}" >&2
    exit 1
  }
done

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  (
    cd "${APP_DIR}"
    mapfile -t RELEASE_ARGS < <(
      python3 "${CONTRACTS_SCRIPT}" flutter-build-args \
        --app-dir "${APP_DIR}" \
        --dart-defines-file "${DEPLOYDASH_DART_DEFINES_FILE:-config/dart-defines.local.json}" \
        --build-name "${DEPLOYDASH_BUILD_NAME:-}" \
        --build-number "${DEPLOYDASH_BUILD_NUMBER:-}" \
        --default-to-pubspec
    )
    flutter build linux --release \
      "${RELEASE_ARGS[@]}" \
      --dart-define=DEPLOYDASH_DISTRIBUTION=flatpak \
      --dart-define=DEPLOYDASH_RELEASE_CHANNEL=stable
  )
fi

rm -rf "${WORK_DIR}" "${REPO_DIR}" "${BUNDLE_PATH}"
mkdir -p "${BUILD_ROOT}"

flatpak-builder --force-clean "${WORK_DIR}" "${MANIFEST}" --repo="${REPO_DIR}"
flatpak build-bundle "${REPO_DIR}" "${BUNDLE_PATH}" com.deploydash.desktop

echo "Built Flatpak bundle at ${BUNDLE_PATH}"
