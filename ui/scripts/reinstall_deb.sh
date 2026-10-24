#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"
PACKAGE_NAME="${DEB_PACKAGE_NAME:-deploydash}"

usage() {
  cat <<'EOF'
Usage: reinstall_deb.sh [--skip-build]

Removes the currently installed Deploy Dash package if present, rebuilds the
Debian package, and installs the freshly built .deb.

Options:
  --skip-build   Repackage the existing release bundle instead of rebuilding it.
  -h, --help     Show this help message.

Environment overrides:
  DEB_PACKAGE_NAME
  DEB_ARCHITECTURE
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

resolve_architecture() {
  if [[ -n "${DEB_ARCHITECTURE:-}" ]]; then
    printf '%s\n' "${DEB_ARCHITECTURE}"
    return
  fi
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --print-architecture
    return
  fi
  case "$(uname -m)" in
    x86_64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *)
      echo "Unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

require_command sudo
require_command apt
require_command bash

source "${SCRIPT_DIR}/lib/backend_paths.sh"
CONTRACTS_SCRIPT="$(resolve_backend_script_path release_contracts.py)"
VERSION="$(
  python3 "${CONTRACTS_SCRIPT}" \
    debian-package-version \
    --app-dir "${APP_DIR}" \
    --build-name "${DEPLOYDASH_BUILD_NAME:-}" \
    --build-number "${DEPLOYDASH_BUILD_NUMBER:-}"
)"
ARCHITECTURE="$(resolve_architecture)"
DEB_PATH="${APP_DIR}/build/deb/${PACKAGE_NAME}_${VERSION}_${ARCHITECTURE}.deb"
TEMP_DEB="$(mktemp "/tmp/${PACKAGE_NAME}_${VERSION}_${ARCHITECTURE}_XXXXXX.deb")"
cleanup() {
  rm -f "${TEMP_DEB}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if dpkg-query -W -f='${Status}' "${PACKAGE_NAME}" 2>/dev/null | grep -q "install ok installed"; then
  echo "Removing installed package: ${PACKAGE_NAME}"
  sudo apt remove -y "${PACKAGE_NAME}"
else
  echo "Package ${PACKAGE_NAME} is not currently installed; skipping removal."
fi

echo "Building Debian package..."
bash "${SCRIPT_DIR}/build_deb.sh" "${BUILD_ARGS[@]}"

if [[ ! -f "${DEB_PATH}" ]]; then
  echo "Built package not found: ${DEB_PATH}" >&2
  exit 1
fi

cp "${DEB_PATH}" "${TEMP_DEB}"
chmod 0644 "${TEMP_DEB}"

echo "Installing package from ${DEB_PATH}"
sudo apt install -y "${TEMP_DEB}"
