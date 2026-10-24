#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/backend_paths.sh"
CONTRACTS_SCRIPT="$(resolve_backend_script_path release_contracts.py)"

OUTPUT_DIR="${APP_DIR}/build/snap"
BUILD_NAME="${DEPLOYDASH_BUILD_NAME:-}"
BUILD_NUMBER="${DEPLOYDASH_BUILD_NUMBER:-}"
DART_DEFINES_FILE="${DEPLOYDASH_DART_DEFINES_FILE:-config/dart-defines.local.json}"
SNAPCRAFT_BUILD_MODE="${DEPLOYDASH_SNAPCRAFT_BUILD_MODE:-lxd}"

usage() {
  cat <<'EOF'
Usage: build_snap.sh

Build a production strict-confinement Snap inside a clean core24 Snapcraft
environment. The resulting artifact is written below build/snap/.

Environment overrides:
  DEPLOYDASH_BUILD_NAME
  DEPLOYDASH_BUILD_NUMBER
  DEPLOYDASH_DART_DEFINES_FILE
  DEPLOYDASH_SNAPCRAFT_BUILD_MODE (lxd [default] or destructive)
EOF
}

if [[ $# -gt 0 ]]; then
  case "$1" in
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
fi

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}" >&2
    exit 1
  fi
}

require_command git
require_command python3
require_command snapcraft
require_command unsquashfs

ARCHITECTURE="$({ dpkg --print-architecture 2>/dev/null || true; } | head -n1)"
if [[ "${ARCHITECTURE}" != "amd64" ]]; then
  echo "The initial Deploy Dash Snap release supports amd64 only." >&2
  exit 1
fi

SNAPCRAFT_COMMAND=(snapcraft)
SNAPCRAFT_PACK_OPTIONS=()
case "${SNAPCRAFT_BUILD_MODE}" in
  lxd)
    SNAPCRAFT_PACK_OPTIONS=(--use-lxd)
    ;;
  destructive)
    # CI uses a disposable Ubuntu 24.04 runner, which matches core24 and
    # avoids the hosted runner's LXD build-instance network restriction.
    if [[ "$(id -u)" -ne 0 ]]; then
      require_command sudo
      SNAPCRAFT_COMMAND=(sudo snapcraft)
    fi
    SNAPCRAFT_PACK_OPTIONS=(--destructive-mode "--build-for=${ARCHITECTURE}")
    ;;
  *)
    echo "DEPLOYDASH_SNAPCRAFT_BUILD_MODE must be lxd or destructive." >&2
    exit 1
    ;;
esac

VERSION="$(
  python3 "${CONTRACTS_SCRIPT}" snap-package-version \
    --app-dir "${APP_DIR}" \
    --build-name "${BUILD_NAME}" \
    --build-number "${BUILD_NUMBER}"
)"
RESOLVED_BUILD_NAME="${VERSION%+*}"
RESOLVED_BUILD_NUMBER="${VERSION##*+}"
SNAP_PATH="${OUTPUT_DIR}/deploydash_${VERSION}_${ARCHITECTURE}.snap"
WORK_ROOT="${OUTPUT_DIR}/work-${VERSION}-$$"
SOURCE_ROOT="${WORK_ROOT}/source"
SNAP_PROJECT_DIR="${SOURCE_ROOT}/ui/packaging/snap"

cleanup() {
  rm -rf "${WORK_ROOT}"
}
trap cleanup EXIT INT TERM

rm -rf "${WORK_ROOT}" "${SNAP_PATH}"
mkdir -p "${SOURCE_ROOT}" "${OUTPUT_DIR}"

# Build from the tracked application sources only. This includes tracked
# working-tree edits while keeping QA, credentials, and unrelated products out
# of the isolated Snapcraft build context. The repository holds the flat
# orchestrator/ui layout that snapcraft.yaml and the scripts below
# expect, so copy directly.
while IFS= read -r -d '' relative_path; do
  source_path="${REPO_ROOT}/${relative_path}"
  if [[ -f "${source_path}" || -L "${source_path}" ]]; then
    mkdir -p "${SOURCE_ROOT}/$(dirname "${relative_path}")"
    cp -a "${source_path}" "${SOURCE_ROOT}/${relative_path}"
  fi
done < <(git -C "${REPO_ROOT}" ls-files -z -- orchestrator ui)

DEFINES_SOURCE=""
if [[ -n "${DART_DEFINES_FILE}" ]]; then
  if [[ "${DART_DEFINES_FILE}" = /* ]]; then
    DEFINES_SOURCE="${DART_DEFINES_FILE}"
  else
    DEFINES_SOURCE="${APP_DIR}/${DART_DEFINES_FILE}"
  fi
  if [[ ! -f "${DEFINES_SOURCE}" ]]; then
    if [[ "${DART_DEFINES_FILE}" != "config/dart-defines.local.json" ]]; then
      echo "DEPLOYDASH_DART_DEFINES_FILE does not exist: ${DART_DEFINES_FILE}" >&2
      exit 1
    fi
    DEFINES_SOURCE=""
  fi
fi

BUILD_ARGS_PATH="${SNAP_PROJECT_DIR}/build-args.txt"
{
  printf '%s\n' "--build-name=${RESOLVED_BUILD_NAME}"
  printf '%s\n' "--dart-define=DEPLOYDASH_RELEASE_VERSION=${RESOLVED_BUILD_NAME}"
  printf '%s\n' "--build-number=${RESOLVED_BUILD_NUMBER}"
  printf '%s\n' "--dart-define=DEPLOYDASH_RELEASE_BUILD=${RESOLVED_BUILD_NUMBER}"
  printf '%s\n' "--dart-define=DEPLOYDASH_DISTRIBUTION=snap"
  printf '%s\n' "--dart-define=DEPLOYDASH_RELEASE_CHANNEL=stable"
  if [[ -n "${DEFINES_SOURCE}" ]]; then
    install -Dm600 \
      "${DEFINES_SOURCE}" \
      "${SOURCE_ROOT}/ui/config/dart-defines.snap.json"
    printf '%s\n' "--dart-define-from-file=config/dart-defines.snap.json"
  fi
} >"${BUILD_ARGS_PATH}"
chmod 600 "${BUILD_ARGS_PATH}"
printf '%s\n' "${VERSION}" >"${SNAP_PROJECT_DIR}/build-version.txt"
mkdir -p "${SOURCE_ROOT}/snap"
cp "${SNAP_PROJECT_DIR}/snapcraft.yaml" "${SOURCE_ROOT}/snap/snapcraft.yaml"
install -Dm644 \
  "${SOURCE_ROOT}/ui/assets/icons/app_icon.png" \
  "${SOURCE_ROOT}/snap/gui/icon.png"

(
  cd "${SOURCE_ROOT}"
  "${SNAPCRAFT_COMMAND[@]}" pack "${SNAPCRAFT_PACK_OPTIONS[@]}"
)

mapfile -t built_snaps < <(find "${SOURCE_ROOT}" -maxdepth 1 -type f -name '*.snap' -print)
if [[ ${#built_snaps[@]} -ne 1 ]]; then
  echo "Snapcraft must produce exactly one Snap artifact." >&2
  exit 1
fi
mv "${built_snaps[0]}" "${SNAP_PATH}"
test -f "${SNAP_PATH}"

SNAP_METADATA="$(unsquashfs -cat "${SNAP_PATH}" meta/snap.yaml)"
grep -Fxq "name: deploydash" <<<"${SNAP_METADATA}"
grep -Fxq "version: ${VERSION}" <<<"${SNAP_METADATA}"
grep -Fxq "base: core24" <<<"${SNAP_METADATA}"
grep -Fxq "confinement: strict" <<<"${SNAP_METADATA}"
grep -Fxq "grade: stable" <<<"${SNAP_METADATA}"
grep -Fq "deploydash-dbus:" <<<"${SNAP_METADATA}"
grep -Fxq "    interface: dbus" <<<"${SNAP_METADATA}"
grep -Fxq "    bus: session" <<<"${SNAP_METADATA}"
grep -Fxq "    name: com.deploydash.desktop" <<<"${SNAP_METADATA}"

SNAP_CONTENTS="$(unsquashfs -l "${SNAP_PATH}")"
for required_path in \
  squashfs-root/deploydash \
  squashfs-root/lib/libbridge.so \
  squashfs-root/data/flutter_assets \
  squashfs-root/data/py/site-packages/orchestrator \
  squashfs-root/meta/gui/deploydash.desktop \
  squashfs-root/meta/gui/icon.png \
  squashfs-root/usr/share/applications/com.deploydash.desktop.desktop; do
  grep -Fq "${required_path}" <<<"${SNAP_CONTENTS}"
done
SNAP_DESKTOP_ENTRY="$(
  unsquashfs -cat "${SNAP_PATH}" meta/gui/deploydash.desktop
)"
grep -Fxq 'Icon=${SNAP}/meta/gui/icon.png' <<<"${SNAP_DESKTOP_ENTRY}"
if grep -Fq "dart-defines.snap.json" <<<"${SNAP_CONTENTS}"; then
  echo "The Snap artifact contains the temporary Dart defines file." >&2
  exit 1
fi
if grep -Fq "/_tkinter." <<<"${SNAP_CONTENTS}"; then
  echo "The Snap artifact contains the unused Tkinter extension." >&2
  exit 1
fi
if grep -Eq 'squashfs-root/(qa|credentials)(/|$)' <<<"${SNAP_CONTENTS}"; then
  echo "The Snap artifact contains private build-context files." >&2
  exit 1
fi

echo "Built Snap package at ${SNAP_PATH}"
