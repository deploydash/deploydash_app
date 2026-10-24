#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/backend_paths.sh"
CONTRACTS_SCRIPT="$(resolve_backend_script_path release_contracts.py)"

PACKAGE_NAME="${DEB_PACKAGE_NAME:-deploydash}"
BINARY_NAME="${DEB_BINARY_NAME:-deploydash}"
APP_DISPLAY_NAME="${DEB_APP_DISPLAY_NAME:-Deploy Dash}"
APP_ID="${DEB_APP_ID:-com.deploydash.desktop}"
MAINTAINER="${DEB_MAINTAINER:-Deploy Dash <info@deploydash.com>}"
DESCRIPTION="${DEB_DESCRIPTION:-A desktop application for web app deployment and server management}"
DESCRIPTION_LONG="${DEB_DESCRIPTION_LONG:-Deploy Dash is a desktop application for deploying web apps based on Node.js, PHP, Python and Ruby on your own servers.}"
HOMEPAGE="${DEB_HOMEPAGE:-https://www.deploydash.com}"
SECTION="${DEB_SECTION:-devel}"
PRIORITY="${DEB_PRIORITY:-optional}"
PACKAGE_ROOT="${APP_DIR}/build/deb"
TEMPLATE_PATH="${APP_DIR}/packaging/linux/deploydash.desktop"
ICON_SOURCE="${APP_DIR}/assets/icons/app_icon.png"
LAUNCHER_PATH="/usr/bin/${PACKAGE_NAME}"
INSTALL_LIB_DIR="/usr/lib/${PACKAGE_NAME}"
CANONICAL_DESKTOP_FILE_NAME="${APP_ID}.desktop"
# Flutter dynamically loads the EGL/OpenGL stack at runtime, so dpkg-shlibdeps
# cannot discover these libraries from the launcher ELF dependency graph.
REQUIRED_RUNTIME_DEPENDS="libegl1, libgl1, libgles2"
PACKAGE_MANAGER_DEPENDS="apturl, ca-certificates"
DEFAULT_DEPENDS="libgtk-3-0, libstdc++6, ${REQUIRED_RUNTIME_DEPENDS}, ${PACKAGE_MANAGER_DEPENDS}"
APT_KEY_SOURCE="${APP_DIR}/packaging/linux/deploydash-archive-keyring.asc"
APT_SOURCE_LIST="${APP_DIR}/packaging/linux/deploydash.sources"
SKIP_BUILD=0
DART_DEFINES_FILE="${DEPLOYDASH_DART_DEFINES_FILE:-config/dart-defines.local.json}"
BUILD_NAME="${DEPLOYDASH_BUILD_NAME:-}"
BUILD_NUMBER="${DEPLOYDASH_BUILD_NUMBER:-}"

usage() {
  cat <<'EOF'
Usage: build_deb.sh [--skip-build]

Builds a Debian package from the Flutter Linux release bundle.

Environment overrides:
  DEB_PACKAGE_NAME
  DEB_BINARY_NAME
  DEB_APP_DISPLAY_NAME
  DEB_APP_ID
  DEB_MAINTAINER
  DEB_DESCRIPTION
  DEB_DESCRIPTION_LONG
  DEB_HOMEPAGE
  DEB_SECTION
  DEB_PRIORITY
  DEB_ARCHITECTURE
  DEB_DEPENDS
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

compute_dependencies() {
  if [[ -n "${DEB_DEPENDS:-}" ]]; then
    printf '%s\n' "${DEB_DEPENDS}"
    return
  fi

  if ! command -v dpkg-shlibdeps >/dev/null 2>&1; then
    printf '%s\n' "${DEFAULT_DEPENDS}"
    return
  fi

  local bundle_install_dir="${PKG_DIR}${INSTALL_LIB_DIR}"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN

  mkdir -p "${tmpdir}/debian"
  cat > "${tmpdir}/debian/control" <<EOF
Source: ${PACKAGE_NAME}
Section: ${SECTION}
Priority: ${PRIORITY}
Maintainer: ${MAINTAINER}
Standards-Version: 4.6.0

Package: ${PACKAGE_NAME}
Architecture: ${ARCHITECTURE}
Description: ${DESCRIPTION}
EOF

  mapfile -t elf_files < <(
    {
      printf '%s\n' "${bundle_install_dir}/${BINARY_NAME}"
      find "${bundle_install_dir}/lib" -maxdepth 1 -type f \
        \( -name '*.so' -o -name '*.so.*' \)
      find "${bundle_install_dir}/data/py/site-packages" -type f \
        \( -name '*.so' -o -name '*.so.*' \) \
        ! -path '*/tests/*' \
        ! -path '*/test/*'
    } | sort -u
  )

  if [[ "${#elf_files[@]}" -eq 0 ]]; then
    printf '%s\n' "${DEFAULT_DEPENDS}"
    return
  fi

  local shlibs_output
  local shlibs_log="${tmpdir}/dpkg-shlibdeps.log"
  if ! shlibs_output="$(
    cd "${tmpdir}" && dpkg-shlibdeps \
      -O \
      -Tdebian/substvars \
      -l"${bundle_install_dir}/lib" \
      "${elf_files[@]}" 2>"${shlibs_log}"
  )"; then
    cat "${shlibs_log}" >&2 || true
    printf '%s\n' "${DEFAULT_DEPENDS}"
    return
  fi

  local depends
  depends="$(printf '%s\n' "${shlibs_output}" | sed -n 's/^shlibs:Depends=//p')"
  if [[ -n "${depends}" ]]; then
    printf '%s, %s, %s\n' \
      "${depends}" \
      "${REQUIRED_RUNTIME_DEPENDS}" \
      "${PACKAGE_MANAGER_DEPENDS}"
  else
    printf '%s\n' "${DEFAULT_DEPENDS}"
  fi
}

require_command flutter
require_command dpkg-deb

VERSION="$(
  python3 "${CONTRACTS_SCRIPT}" \
    debian-package-version \
    --app-dir "${APP_DIR}" \
    --build-name "${BUILD_NAME}" \
    --build-number "${BUILD_NUMBER}"
)"

ARCHITECTURE="$(resolve_architecture)"
case "${ARCHITECTURE}" in
  amd64) FLUTTER_ARCH="x64" ;;
  arm64) FLUTTER_ARCH="arm64" ;;
  *)
    echo "Unsupported Debian package architecture: ${ARCHITECTURE}" >&2
    exit 1
    ;;
esac
BUNDLE_DIR="${APP_DIR}/build/linux/${FLUTTER_ARCH}/release/bundle"
PKG_DIR="${PACKAGE_ROOT}/${PACKAGE_NAME}_${VERSION}_${ARCHITECTURE}"
DEB_PATH="${PKG_DIR}.deb"

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  (
    cd "${APP_DIR}"
    BUILD_ARGS=(build linux --release)
    mapfile -t RESOLVED_BUILD_ARGS < <(
      python3 "${CONTRACTS_SCRIPT}" \
        flutter-build-args \
        --app-dir "${APP_DIR}" \
        --dart-defines-file "${DART_DEFINES_FILE}" \
        --build-name "${BUILD_NAME}" \
        --build-number "${BUILD_NUMBER}" \
        --default-to-pubspec
    )
    BUILD_ARGS+=("${RESOLVED_BUILD_ARGS[@]}")
    BUILD_ARGS+=(
      --dart-define=DEPLOYDASH_DISTRIBUTION=deb
      --dart-define=DEPLOYDASH_RELEASE_CHANNEL=stable
    )
    flutter "${BUILD_ARGS[@]}"
  )
fi

if [[ ! -d "${BUNDLE_DIR}" ]]; then
  echo "Release bundle not found: ${BUNDLE_DIR}" >&2
  if [[ -n "${DART_DEFINES_FILE}" ]]; then
    echo "Run flutter build linux --release --dart-define-from-file=${DART_DEFINES_FILE} first." >&2
  else
    echo "Run flutter build linux --release first." >&2
  fi
  exit 1
fi

python3 "${CONTRACTS_SCRIPT}" \
  validate-linux-release-bundle \
  --build-dir "${BUNDLE_DIR}"

if [[ ! -f "${TEMPLATE_PATH}" ]]; then
  echo "Desktop file template not found: ${TEMPLATE_PATH}" >&2
  exit 1
fi

if [[ ! -f "${ICON_SOURCE}" ]]; then
  echo "Icon source not found: ${ICON_SOURCE}" >&2
  exit 1
fi

if [[ ! -f "${APT_KEY_SOURCE}" || ! -f "${APT_SOURCE_LIST}" ]]; then
  echo "Deploy Dash APT trust files are missing from packaging/linux." >&2
  exit 1
fi

rm -rf "${PKG_DIR}" "${DEB_PATH}"
mkdir -p "${PKG_DIR}/DEBIAN"
mkdir -p "${PKG_DIR}${INSTALL_LIB_DIR}"
mkdir -p "${PKG_DIR}/usr/bin"
mkdir -p "${PKG_DIR}/usr/share/applications"
mkdir -p "${PKG_DIR}/usr/share/icons/hicolor/256x256/apps"
mkdir -p "${PKG_DIR}/usr/share/icons/hicolor/512x512/apps"
mkdir -p "${PKG_DIR}/usr/share/keyrings"
mkdir -p "${PKG_DIR}/etc/apt/sources.list.d"

cp -a "${BUNDLE_DIR}/." "${PKG_DIR}${INSTALL_LIB_DIR}/"

cat > "${PKG_DIR}${LAUNCHER_PATH}" <<EOF
#!/usr/bin/env bash
exec ${INSTALL_LIB_DIR}/${BINARY_NAME} "\$@"
EOF
chmod 755 "${PKG_DIR}${LAUNCHER_PATH}"

cp "${TEMPLATE_PATH}" \
  "${PKG_DIR}/usr/share/applications/${CANONICAL_DESKTOP_FILE_NAME}"

for icon_name in "${APP_ID}" "${PACKAGE_NAME}"; do
  cp "${ICON_SOURCE}" \
    "${PKG_DIR}/usr/share/icons/hicolor/256x256/apps/${icon_name}.png"
  cp "${ICON_SOURCE}" \
    "${PKG_DIR}/usr/share/icons/hicolor/512x512/apps/${icon_name}.png"
done

install -m 0644 \
  "${APT_KEY_SOURCE}" \
  "${PKG_DIR}/usr/share/keyrings/deploydash-archive-keyring.asc"
install -m 0644 \
  "${APT_SOURCE_LIST}" \
  "${PKG_DIR}/etc/apt/sources.list.d/deploydash.sources"

INSTALLED_SIZE="$(du -sk "${PKG_DIR}" | awk '{print $1}')"
DEPENDS="$(compute_dependencies)"

cat > "${PKG_DIR}/DEBIAN/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Section: ${SECTION}
Priority: ${PRIORITY}
Architecture: ${ARCHITECTURE}
Maintainer: ${MAINTAINER}
Homepage: ${HOMEPAGE}
Installed-Size: ${INSTALLED_SIZE}
Depends: ${DEPENDS}
Description: ${DESCRIPTION}
 ${DESCRIPTION_LONG}
EOF

cat > "${PKG_DIR}/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -e

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
EOF
chmod 755 "${PKG_DIR}/DEBIAN/postinst"

cat > "${PKG_DIR}/DEBIAN/postrm" <<'EOF'
#!/usr/bin/env bash
set -e

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
EOF
chmod 755 "${PKG_DIR}/DEBIAN/postrm"

dpkg-deb --build --root-owner-group "${PKG_DIR}" "${DEB_PATH}" >/dev/null
python3 "${CONTRACTS_SCRIPT}" assert-artifact --path "${DEB_PATH}" --label DEB

echo "Built Debian package:"
echo "${DEB_PATH}"
