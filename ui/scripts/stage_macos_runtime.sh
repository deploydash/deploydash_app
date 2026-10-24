#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"
BRIDGE_SOURCE="${APP_DIR}/shared_native/bridge_exports.cc"
PROCESS_SECURITY_SOURCE="${APP_DIR}/shared_native/process_security.cc"
source "${SCRIPT_DIR}/lib/backend_paths.sh"
BACKEND_ROOT="$(resolve_backend_root)"
RUNTIME_PREP="$(resolve_backend_script_path prepare_desktop_runtime_bundle.sh)"
RUNTIME_BUNDLE_DIR="${BACKEND_ROOT}/runtime_bundle/py"
SPARKLE_VERSION="2.9.2"
SPARKLE_ARCHIVE_SHA256="1cb340cbbef04c6c0d162078610c25e2221031d794a3449d89f2f56f4df77c95"
SPARKLE_ARCHIVE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
SPARKLE_BUILD_ROOT="${APP_DIR}/build/macos/sparkle/${SPARKLE_VERSION}"

if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" || -z "${FRAMEWORKS_FOLDER_PATH:-}" ]]; then
  echo "stage_macos_runtime.sh must run from an Xcode build phase." >&2
  exit 1
fi

PYTHON_EXE="$(uv python find 3.13.14)"
if [[ -z "${PYTHON_EXE}" ]]; then
  echo "Unable to locate Python 3.13.14 via uv." >&2
  exit 1
fi

export ORCHESTRATOR_VENV_PYTHON="${PYTHON_EXE}"
"${RUNTIME_PREP}"

PYTHON_BASE_PREFIX="$("${PYTHON_EXE}" -c 'import sys; print(sys.base_prefix)')"
if [[ -z "${PYTHON_BASE_PREFIX}" ]]; then
  echo "Unable to determine Python base prefix." >&2
  exit 1
fi

APP_CONTENTS_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH:-${WRAPPER_NAME}/Contents}"
RESOURCES_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
FRAMEWORKS_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "${RESOURCES_DIR}" "${FRAMEWORKS_DIR}"

stage_sparkle_framework() {
  local framework_source="${DEPLOYDASH_SPARKLE_FRAMEWORK_PATH:-}"
  local license_source=""

  if [[ -z "${framework_source}" ]]; then
    local archive_path="${SPARKLE_BUILD_ROOT}/Sparkle-${SPARKLE_VERSION}.tar.xz"
    local extracted_dir="${SPARKLE_BUILD_ROOT}/extracted"
    mkdir -p "${SPARKLE_BUILD_ROOT}"
    if [[ ! -f "${archive_path}" ]]; then
      command -v curl >/dev/null 2>&1 || {
        echo "curl is required to download the pinned Sparkle framework." >&2
        exit 1
      }
      curl --fail --location --silent --show-error \
        "${SPARKLE_ARCHIVE_URL}" \
        --output "${archive_path}"
    fi
    local actual_sha256
    actual_sha256="$(shasum -a 256 "${archive_path}" | awk '{print $1}')"
    if [[ "${actual_sha256}" != "${SPARKLE_ARCHIVE_SHA256}" ]]; then
      echo "Pinned Sparkle archive checksum verification failed." >&2
      exit 1
    fi
    if [[ ! -d "${extracted_dir}/Sparkle.framework" ]]; then
      rm -rf "${extracted_dir}"
      mkdir -p "${extracted_dir}"
      tar -xJf "${archive_path}" -C "${extracted_dir}"
    fi
    framework_source="${extracted_dir}/Sparkle.framework"
    license_source="${extracted_dir}/LICENSE"
  else
    license_source="$(dirname "${framework_source}")/LICENSE"
  fi

  if [[ ! -d "${framework_source}" ]]; then
    echo "Sparkle framework not found: ${framework_source}" >&2
    exit 1
  fi
  rm -rf "${FRAMEWORKS_DIR}/Sparkle.framework"
  cp -R "${framework_source}" "${FRAMEWORKS_DIR}/Sparkle.framework"
  if [[ -f "${license_source}" ]]; then
    mkdir -p "${RESOURCES_DIR}/licenses"
    cp "${license_source}" "${RESOURCES_DIR}/licenses/Sparkle-LICENSE.txt"
  fi
}

copy_python_stdlib() {
  local destination_root="$1"
  local stdlib_source="${PYTHON_BASE_PREFIX}/lib/python3.13"

  if [[ ! -d "${stdlib_source}" ]]; then
    echo "Unable to locate Python 3.13.14 stdlib at ${stdlib_source}" >&2
    exit 1
  fi

  mkdir -p "${destination_root}/lib/python3.13"
  rsync -a \
    --delete \
    --exclude '__pycache__/' \
    --exclude 'site-packages/' \
    --exclude 'test/' \
    --exclude 'tkinter/' \
    --exclude 'turtledemo/' \
    --exclude 'idlelib/' \
    --exclude 'ensurepip/' \
    --exclude 'venv/' \
    --exclude 'lib2to3/' \
    "${stdlib_source}/" \
    "${destination_root}/lib/python3.13/"
}

stage_slim_python_framework() {
  local framework_dest="${FRAMEWORKS_DIR}/Python.framework"
  local version_name
  version_name="$(basename "${PYTHON_BASE_PREFIX}")"
  local version_dest="${framework_dest}/Versions/${version_name}"

  rm -rf "${framework_dest}"
  mkdir -p "${version_dest}"

  if [[ ! -f "${PYTHON_BASE_PREFIX}/Python" ]]; then
    echo "Unable to locate framework Python binary at ${PYTHON_BASE_PREFIX}/Python" >&2
    exit 1
  fi

  cp "${PYTHON_BASE_PREFIX}/Python" "${version_dest}/Python"
  copy_python_stdlib "${version_dest}"

  if [[ -f "${PYTHON_BASE_PREFIX}/Resources/Info.plist" ]]; then
    mkdir -p "${version_dest}/Resources"
    cp "${PYTHON_BASE_PREFIX}/Resources/Info.plist" "${version_dest}/Resources/Info.plist"
  fi

  mkdir -p "${framework_dest}/Versions"
  ln -sfn "${version_name}" "${framework_dest}/Versions/Current"
  ln -sfn "Versions/Current/Python" "${framework_dest}/Python"
  if [[ -d "${version_dest}/Resources" ]]; then
    ln -sfn "Versions/Current/Resources" "${framework_dest}/Resources"
  fi
}

codesign_runtime_item() {
  local binary_path="$1"
  local sign_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  local -a sign_args=(--force --sign "${sign_identity}")

  if [[ ! -e "${binary_path}" ]]; then
    return 0
  fi
  if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "YES" ]]; then
    return 0
  fi
  if ! command -v codesign >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${CONFIGURATION:-Debug}" == "Release" || "${CONFIGURATION:-Debug}" == "Profile" ]]; then
    sign_args+=(--options runtime)
    if [[ "${sign_identity}" == "-" ]]; then
      sign_args+=(--timestamp=none)
    else
      sign_args+=(--timestamp)
    fi
  else
    sign_args+=(--timestamp=none)
  fi

  codesign "${sign_args[@]}" "${binary_path}"
}

codesign_runtime_tree() {
  local root="$1"
  local -a binaries=()

  if [[ ! -d "${root}" ]]; then
    return 0
  fi

  while IFS= read -r -d '' binary; do
    binaries+=("${binary}")
  done < <(
    find "${root}" \
      \( -name '*.so' -o -name '*.dylib' \) \
      -type f \
      -print0
  )

  if [[ -f "${FRAMEWORKS_DIR}/Python.framework/Versions/Current/Python" ]]; then
    binaries+=("${FRAMEWORKS_DIR}/Python.framework/Versions/Current/Python")
  fi

  for (( index=${#binaries[@]}-1; index>=0; index-- )); do
    codesign_runtime_item "${binaries[index]}"
  done
}

rm -rf "${RESOURCES_DIR}/data/py"
mkdir -p "${RESOURCES_DIR}/data"
cp -R "${RUNTIME_BUNDLE_DIR}" "${RESOURCES_DIR}/data/"

FRAMEWORK_ROOT=""
if [[ "${PYTHON_BASE_PREFIX}" == */Python.framework/Versions/* ]]; then
  FRAMEWORK_ROOT="$(cd "${PYTHON_BASE_PREFIX}/../.." && pwd)"
fi

rm -rf "${FRAMEWORKS_DIR}/Python.framework" "${RESOURCES_DIR}/python"

if [[ -n "${FRAMEWORK_ROOT}" && -d "${FRAMEWORK_ROOT}" ]]; then
  stage_slim_python_framework
else
  PYTHON_RESOURCE_ROOT="${RESOURCES_DIR}/python"
  copy_python_stdlib "${PYTHON_RESOURCE_ROOT}"
  if compgen -G "${PYTHON_BASE_PREFIX}/lib/libpython3.13*.dylib" >/dev/null; then
    cp "${PYTHON_BASE_PREFIX}"/lib/libpython3.13*.dylib "${PYTHON_RESOURCE_ROOT}/lib/"
  fi
  # Spawn worker interpreter (see T-S2): task_runtime re-execs this binary
  # for every engine task. uv/non-framework builder Pythons ship a ~50 KB
  # bin/python3.13 with @executable_path/../lib RPATH, so one copy into the
  # already prefix-shaped Resources/python tree completes a runnable
  # interpreter (prefix computation finds lib/python3.13/os.py where it
  # expects it). Framework-builder machines skip this: their interpreter is
  # the staged Versions/*/Python binary itself. Best-effort here — the
  # engine discovery fails closed at runtime if nothing resolves.
  if [[ -f "${PYTHON_BASE_PREFIX}/bin/python3.13" ]]; then
    mkdir -p "${PYTHON_RESOURCE_ROOT}/bin"
    cp "${PYTHON_BASE_PREFIX}/bin/python3.13" "${PYTHON_RESOURCE_ROOT}/bin/"
  fi
fi

BRIDGE_COMPILE_ARGS=()
if [[ "${CONFIGURATION:-Debug}" == "Release" || "${CONFIGURATION:-Debug}" == "Profile" ]]; then
  BRIDGE_COMPILE_ARGS+=(-DDEPLOYDASH_RELEASE_HARDENING=1)
fi

# The :+ form below is load-bearing, not style: Xcode build phases run this
# script under macOS /bin/bash 3.2, where expanding an empty array as
# "${BRIDGE_COMPILE_ARGS[@]}" under `set -u` is a fatal error. Debug builds
# leave the array empty (Release/Profile always add the hardening define, so
# they never hit it). ${arr[@]:+...} expands to nothing when empty without
# touching the array itself, which is safe on 3.2.
clang++ \
  -std=c++14 \
  -dynamiclib \
  -fvisibility=hidden \
  -mmacosx-version-min=13.0 \
  -stdlib=libc++ \
  -I "${APP_DIR}/shared_native" \
  ${BRIDGE_COMPILE_ARGS[@]:+"${BRIDGE_COMPILE_ARGS[@]}"} \
  "${BRIDGE_SOURCE}" \
  "${PROCESS_SECURITY_SOURCE}" \
  -o "${FRAMEWORKS_DIR}/libbridge.dylib"

codesign_runtime_item "${FRAMEWORKS_DIR}/libbridge.dylib"
codesign_runtime_tree "${FRAMEWORKS_DIR}"
codesign_runtime_tree "${RESOURCES_DIR}/python"
codesign_runtime_tree "${RESOURCES_DIR}/data/py"
# The spawn worker interpreter is a Mach-O executable, not a .so/.dylib, so
# the tree scan above does not cover it. Sign explicitly (same identity and
# hardening path as everything else); the release flow additionally picks it
# up through the macos_nested_signing_paths rglob with no contract change.
if [[ -f "${RESOURCES_DIR}/python/bin/python3.13" ]]; then
  codesign_runtime_item "${RESOURCES_DIR}/python/bin/python3.13"
fi
if [[ -d "${FRAMEWORKS_DIR}/Python.framework" ]]; then
  codesign_runtime_item "${FRAMEWORKS_DIR}/Python.framework"
fi

if [[ "${DEPLOYDASH_MACOS_INCLUDE_SPARKLE:-0}" == "1" ]]; then
  stage_sparkle_framework
else
  rm -rf "${FRAMEWORKS_DIR}/Sparkle.framework"
  rm -f "${RESOURCES_DIR}/licenses/Sparkle-LICENSE.txt"
fi

echo "Staged Deploy Dash embedded Python runtime into ${APP_CONTENTS_DIR}"
