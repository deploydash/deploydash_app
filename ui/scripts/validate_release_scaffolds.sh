#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"
GIT_ROOT="${REPO_ROOT}"
source "${APP_DIR}/scripts/lib/backend_paths.sh"
BACKEND_ROOT="$(resolve_backend_root)"

for shell_script in \
  "${APP_DIR}/scripts/lib/backend_paths.sh" \
  "${APP_DIR}/scripts/build_deb.sh" \
  "${APP_DIR}/scripts/build_flatpak.sh" \
  "${APP_DIR}/scripts/build_macos_app_store.sh" \
  "${APP_DIR}/scripts/build_macos_dmg.sh" \
  "${APP_DIR}/scripts/build_snap.sh" \
  "${APP_DIR}/scripts/desktop_updates_coverage.sh" \
  "${APP_DIR}/scripts/notarize_macos_dmg.sh" \
  "${APP_DIR}/scripts/native_process_security_coverage.sh" \
  "${APP_DIR}/scripts/process_security_diagnostics_coverage.sh" \
  "${APP_DIR}/scripts/windows_store_accessibility_coverage.sh" \
  "${APP_DIR}/scripts/rebuild_macos_dmg.sh" \
  "${APP_DIR}/scripts/reinstall_deb.sh" \
  "${APP_DIR}/scripts/sign_macos_app_bundle.sh" \
  "${APP_DIR}/scripts/stage_macos_runtime.sh" \
  "${APP_DIR}/scripts/verify_macos_hardened_runtime.sh"; do
  bash -n "${shell_script}"
done
test -x "${APP_DIR}/scripts/verify_macos_hardened_runtime.sh"
test -x "${APP_DIR}/scripts/native_process_security_coverage.sh"
test -x "${APP_DIR}/scripts/process_security_diagnostics_coverage.sh"
test -x "${APP_DIR}/scripts/desktop_updates_coverage.sh"
test -x "${APP_DIR}/scripts/windows_store_accessibility_coverage.sh"
test -x "${APP_DIR}/scripts/sign_macos_app_bundle.sh"
grep -q 'ENABLE_HARDENED_RUNTIME = YES' "${APP_DIR}/macos/Runner.xcodeproj/project.pbxproj"
grep -q 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO' "${APP_DIR}/macos/Runner.xcodeproj/project.pbxproj"
# macOS 13 Ventura is the oldest supported release on both architectures:
# Flutter builds the sqlite native asset with -mmacos-version-min=13 and
# nothing in the app can lower that. The deployment target must state it
# in all three build configurations — never 10.15 again (Flutter's own
# migrator rewrites 10.15 to 12.0, which would admit machines the native
# asset refuses to load on).
deployment_target_count="$(
  grep -c 'MACOSX_DEPLOYMENT_TARGET = 13.0;' \
    "${APP_DIR}/macos/Runner.xcodeproj/project.pbxproj" || true
)"
if [[ "${deployment_target_count}" -ne 3 ]]; then
  echo "Expected MACOSX_DEPLOYMENT_TARGET = 13.0 in 3 build configurations, found ${deployment_target_count}." >&2
  exit 1
fi
if grep -q 'MACOSX_DEPLOYMENT_TARGET = 10\.15' \
  "${APP_DIR}/macos/Runner.xcodeproj/project.pbxproj"; then
  echo "The 10.15 deployment target is retired; the floor is macOS 13." >&2
  exit 1
fi
grep -q 'mmacosx-version-min=13.0' "${APP_DIR}/scripts/stage_macos_runtime.sh"
grep -Fxq 'ARCHS = $(DEPLOYDASH_MACOS_ARCHS)' "${APP_DIR}/macos/Runner/Configs/Debug.xcconfig"
grep -Fxq 'ARCHS = $(DEPLOYDASH_MACOS_ARCHS)' "${APP_DIR}/macos/Runner/Configs/Release.xcconfig"
if grep -q '^ARCHS = arm64' "${APP_DIR}/macos/Runner/Configs/Release.xcconfig"; then
  echo "Release ARCHS must stay parameterized; arm64 is the script default, not the config." >&2
  exit 1
fi
grep -q 'DEPLOYDASH_MACOS_ARCH:-arm64' "${APP_DIR}/scripts/build_macos_dmg.sh"
grep -q 'macos-dmg-name' "${APP_DIR}/scripts/build_macos_dmg.sh"
grep -q 'macos-dmg-name' "${APP_DIR}/scripts/rebuild_macos_dmg.sh"
grep -q 'macos-dmg-name' "${APP_DIR}/scripts/notarize_macos_dmg.sh"
for macos_dmg_stage in \
  "${APP_DIR}/scripts/build_macos_dmg.sh" \
  "${APP_DIR}/scripts/rebuild_macos_dmg.sh" \
  "${APP_DIR}/scripts/notarize_macos_dmg.sh"; do
  if ! grep -Fq 'BUILD_NAME="${DEPLOYDASH_BUILD_NAME:-}"' "${macos_dmg_stage}"; then
    echo "macOS DMG stage must derive BUILD_NAME from DEPLOYDASH_BUILD_NAME: ${macos_dmg_stage}" >&2
    exit 1
  fi
done
if grep -q 'DeployDash\.dmg' "${APP_DIR}/scripts/build_macos_dmg.sh" \
  "${APP_DIR}/scripts/rebuild_macos_dmg.sh" \
  "${APP_DIR}/scripts/notarize_macos_dmg.sh"; then
  echo "DMG filename must come from the macos-dmg-name contract, never a literal." >&2
  exit 1
fi
grep -Fq 'path = "Deploy Dash.app"' \
  "${APP_DIR}/macos/Runner.xcodeproj/project.pbxproj"
grep -Fq 'BuildableName = "Deploy Dash.app"' \
  "${APP_DIR}/macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme"
grep -q -- '--options runtime' "${APP_DIR}/scripts/stage_macos_runtime.sh"
grep -q 'process_security.cc' "${APP_DIR}/scripts/stage_macos_runtime.sh"
grep -q 'macos-signing-paths' "${APP_DIR}/scripts/sign_macos_app_bundle.sh"
grep -q 'REPO_ROOT=.*APP_DIR' "${APP_DIR}/scripts/sign_macos_app_bundle.sh"
grep -q 'REPO_ROOT=.*APP_DIR' "${APP_DIR}/scripts/verify_macos_hardened_runtime.sh"
grep -q 'REPO_ROOT=.*APP_DIR' "${APP_DIR}/scripts/reinstall_deb.sh"
grep -q 'DEPLOYDASH_MACOS_APP_SIGN_IDENTITY' "${APP_DIR}/scripts/build_macos_dmg.sh"
grep -q 'production DMG chain requires DEPLOYDASH_BUILD_NAME' "${APP_DIR}/scripts/build_macos_dmg.sh"
grep -Fq \
  'DEPLOYDASH_DART_DEFINES_FILE:-config/dart-defines.local.json' \
  "${APP_DIR}/scripts/build_macos_dmg.sh"
grep -q 'DEPLOYDASH_MACOS_APP_SIGN_IDENTITY' "${APP_DIR}/scripts/rebuild_macos_dmg.sh"
grep -q -- '--package-only' "${APP_DIR}/scripts/rebuild_macos_dmg.sh"
grep -q 'DEPLOYDASH_MACOS_NOTARY_PROFILE=deploydash-notary' "${APP_DIR}/scripts/build_macos_dmg.sh"
grep -Fq -- '--context context:primary-signature' \
  "${APP_DIR}/scripts/notarize_macos_dmg.sh"
if grep -Fq 'spctl --assess' "${APP_DIR}/scripts/rebuild_macos_dmg.sh"; then
  echo "A DMG cannot pass Gatekeeper assessment before notarization." >&2
  exit 1
fi
grep -Fq \
  'Developer ID Application: Tidy Technology Ltd (CAZ3ADRS95)' \
  "${APP_DIR}/scripts/rebuild_macos_dmg.sh"

python3 - "${APP_DIR}/macos/Runner.xcodeproj/project.pbxproj" <<'PY'
import sys
from pathlib import Path

project = Path(sys.argv[1]).read_text(encoding="utf-8")

for marker, diagnostic_name in (
    ("33CC111E2044C6BF0003C045 /* ShellScript */ = {", "Flutter Assemble"),
    (
        "D601A0032CC1000000000001 /* Stage Python Runtime */ = {",
        "Stage Python Runtime",
    ),
):
    start = project.index(marker)
    end = project.index("\n\t\t};", start)
    phase = project[start:end]
    if "alwaysOutOfDate = 1;" not in phase:
        raise SystemExit(f"The {diagnostic_name} phase must explicitly run every build.")
    if f'name = "{diagnostic_name}";' not in phase:
        raise SystemExit(f"The {diagnostic_name} phase must keep its diagnostic name.")
PY
grep -q 'APPLE_TEAM_ID:-CAZ3ADRS95' "${APP_DIR}/scripts/build_macos_app_store.sh"
grep -q -- '--default-to-pubspec' "${APP_DIR}/scripts/build_macos_app_store.sh"
grep -q 'select-macos-signing-identity' "${APP_DIR}/scripts/build_macos_dmg.sh"
grep -q 'does not have an Apple Team ID' "${APP_DIR}/scripts/verify_macos_hardened_runtime.sh"
grep -q \
  'nested_team_id.*outer_team_id' \
  "${APP_DIR}/scripts/verify_macos_hardened_runtime.sh"

macos_sign_line="$(
  grep -n 'sign_macos_app_bundle.sh' \
    "${APP_DIR}/scripts/build_macos_dmg.sh" | head -n1 | cut -d: -f1
)"
macos_dmg_line="$(
  grep -n 'hdiutil create' \
    "${APP_DIR}/scripts/build_macos_dmg.sh" | head -n1 | cut -d: -f1
)"
if [[ \
  -z "${macos_sign_line}" || \
  -z "${macos_dmg_line}" || \
  "${macos_sign_line}" -ge "${macos_dmg_line}" \
]]; then
  echo "macOS app signing must complete before DMG creation." >&2
  exit 1
fi

macos_rebuild_line="$(
  grep -n 'rebuild_macos_dmg.sh' \
    "${APP_DIR}/scripts/build_macos_dmg.sh" | tail -n1 | cut -d: -f1
)"
macos_notarize_line="$(
  grep -n 'notarize_macos_dmg.sh' \
    "${APP_DIR}/scripts/build_macos_dmg.sh" | tail -n1 | cut -d: -f1
)"
if [[ \
  -z "${macos_rebuild_line}" || \
  -z "${macos_notarize_line}" || \
  "${macos_rebuild_line}" -ge "${macos_notarize_line}" \
]]; then
  echo "Production macOS build must rebuild before notarization." >&2
  exit 1
fi

for release_entitlements in \
  "${APP_DIR}/macos/Runner/Release.entitlements" \
  "${APP_DIR}/macos/Runner/Release.direct.entitlements"; do
  for forbidden_entitlement in \
    com.apple.security.cs.allow-jit \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.cs.disable-executable-page-protection \
    com.apple.security.cs.disable-library-validation \
    com.apple.security.cs.allow-dyld-environment-variables \
    com.apple.security.get-task-allow; do
    if grep -q "${forbidden_entitlement}" "${release_entitlements}"; then
      echo "Forbidden release entitlement in ${release_entitlements}: ${forbidden_entitlement}" >&2
      exit 1
    fi
  done
done

python3 -m py_compile \
  "${BACKEND_ROOT}/scripts/prepare_desktop_runtime_bundle.py" \
  "${BACKEND_ROOT}/scripts/release_contracts.py" \
  "${BACKEND_ROOT}/scripts/resolve_build_metadata.py"

REPO_ROOT="${REPO_ROOT}" python3 - <<'PY'
from pathlib import Path
import os
import plistlib
import xml.etree.ElementTree as ET

repo_root = Path(os.environ["REPO_ROOT"])

for plist_path in [
    repo_root / "ui/macos/Runner/Info.plist",
    repo_root / "ui/macos/Runner/DebugProfile.entitlements",
    repo_root / "ui/macos/Runner/Release.entitlements",
    repo_root / "ui/macos/Runner/Release.direct.entitlements",
]:
    with plist_path.open("rb") as handle:
        plistlib.load(handle)

for xml_path in [
    repo_root / "ui/packaging/flatpak/com.deploydash.desktop.metainfo.xml",
    repo_root / "ui/packaging/windows/msix/Package.appxmanifest",
    repo_root / "ui/packaging/windows/wix/DeployDash.wxs",
]:
    ET.parse(xml_path)
PY

grep -q "name: deploydash" "${APP_DIR}/packaging/snap/snapcraft.yaml"
grep -q "base: core24" "${APP_DIR}/packaging/snap/snapcraft.yaml"
grep -q "confinement: strict" "${APP_DIR}/packaging/snap/snapcraft.yaml"
grep -q "interface: dbus" "${APP_DIR}/packaging/snap/snapcraft.yaml"
grep -q "name: com.deploydash.desktop" "${APP_DIR}/packaging/snap/snapcraft.yaml"
# Private shared memory for Python multiprocessing workers: strict
# confinement denies sem_open() on the host /dev/shm, so Event/Lock fail
# with EPERM for fork AND spawn alike without this interface.
grep -q "interface: shared-memory" "${APP_DIR}/packaging/snap/snapcraft.yaml"
grep -q "private: true" "${APP_DIR}/packaging/snap/snapcraft.yaml"
grep -q "^\s*- shared-memory$" "${APP_DIR}/packaging/snap/snapcraft.yaml"
grep -q 'DEPLOYDASH_SNAPCRAFT_BUILD_MODE' "${APP_DIR}/scripts/build_snap.sh"
grep -q -- '--destructive-mode' "${APP_DIR}/scripts/build_snap.sh"
grep -q -- '--use-lxd' "${APP_DIR}/scripts/build_snap.sh"
grep -q 'DEPLOYDASH_SNAPCRAFT_BUILD_MODE=destructive' \
  "${GIT_ROOT}/.github/workflows/desktop-snap-build.yml"
if grep -q 'snap install lxd' "${GIT_ROOT}/.github/workflows/desktop-snap-build.yml"; then
  echo "Desktop Snap Build must use the hosted runner directly, not LXD." >&2
  exit 1
fi
grep -q "ls-files -z -- orchestrator ui" "${APP_DIR}/scripts/build_snap.sh"
grep -q "^lint:" "${APP_DIR}/packaging/snap/snapcraft.yaml"
grep -q "app-id: com.deploydash.desktop" "${APP_DIR}/packaging/flatpak/com.deploydash.desktop.yml"
grep -q "shared_native/bridge_exports.cc" "${APP_DIR}/scripts/stage_macos_runtime.sh"
grep -q 'PYTHON_BASE_PREFIX}/bin/python3.13' "${APP_DIR}/scripts/stage_macos_runtime.sh"
grep -q 'PYTHON_RESOURCE_ROOT}/bin/' "${APP_DIR}/scripts/stage_macos_runtime.sh"
grep -q 'codesign_runtime_item "${RESOURCES_DIR}/python/bin/python3.13"' "${APP_DIR}/scripts/stage_macos_runtime.sh"
grep -q "add_library(bridge SHARED" "${APP_DIR}/windows/runner/CMakeLists.txt"
grep -Fq '/Zi>' "${APP_DIR}/windows/runner/CMakeLists.txt"
grep -Fq '/DEBUG>' "${APP_DIR}/windows/runner/CMakeLists.txt"
grep -q "deliverProtocolUri" "${APP_DIR}/windows/runner/flutter_window.cpp"
grep -q "DEPLOYDASH_ORCHESTRATOR_ROOT" "${APP_DIR}/linux/CMakeLists.txt"
grep -q "DEPLOYDASH_ORCHESTRATOR_ROOT" "${APP_DIR}/windows/CMakeLists.txt"
# Spawn worker interpreter staging: task_runtime re-execs this binary, so
# the bundle must carry it. The symlinks reproduce its prefix layout.
# (Fixed-string match: the install(CODE) blocks escape inner quotes.)
grep -q 'SPAWN_PYTHON_BIN' "${APP_DIR}/linux/CMakeLists.txt"
grep -Fq 'CREATE_LINK \"../../lib/' "${APP_DIR}/linux/CMakeLists.txt"
grep -q 'file(TO_CMAKE_PATH "${PYTHON_ROOT_DIR}" PYTHON_ROOT_DIR)' "${APP_DIR}/windows/CMakeLists.txt"
grep -q 'file(TO_CMAKE_PATH "${ENGINE_BACKEND_ROOT}" ENGINE_BACKEND_ROOT)' "${APP_DIR}/windows/CMakeLists.txt"
grep -q 'ORCHESTRATOR_VENV_PYTHON=${PYTHON_INTERPRETER_PATH}' "${APP_DIR}/windows/CMakeLists.txt"
grep -q 'DIRECTORY "${PYTHON_ROOT_DIR}/DLLs"' "${APP_DIR}/windows/CMakeLists.txt"
grep -q 'PATTERN "_tkinter.pyd" EXCLUDE' "${APP_DIR}/windows/CMakeLists.txt"
grep -q 'PATTERN "tcl86t.dll" EXCLUDE' "${APP_DIR}/windows/CMakeLists.txt"
grep -q 'PATTERN "tk86t.dll" EXCLUDE' "${APP_DIR}/windows/CMakeLists.txt"
grep -q 'PATTERN "tkinter" EXCLUDE' "${APP_DIR}/windows/CMakeLists.txt"
grep -q '"${PYTHON_ROOT_DIR}/python.exe"' "${APP_DIR}/windows/CMakeLists.txt"
grep -q '"${PYTHON_ROOT_DIR}/pythonw.exe"' "${APP_DIR}/windows/CMakeLists.txt"
grep -q 'function Resolve-UvPython313' "${APP_DIR}/scripts/lib/backend_paths.ps1"
grep -q 'uv python find 3.13.14' "${APP_DIR}/scripts/lib/backend_paths.ps1"
test -f "${APP_DIR}/scripts/lib/windows_sdk.ps1"
grep -q 'function Resolve-WindowsSdkTool' \
  "${APP_DIR}/scripts/lib/windows_sdk.ps1"
grep -q 'Sort-Object Name -Descending' \
  "${APP_DIR}/scripts/lib/windows_sdk.ps1"
for windows_script in \
  "${APP_DIR}/scripts/build_windows_debug.ps1" \
  "${APP_DIR}/scripts/sign_windows_release.ps1" \
  "${APP_DIR}/scripts/build_windows_msi.ps1"; do
  grep -q 'Resolve-UvPython313' "${windows_script}"
  if grep -q '& python ' "${windows_script}"; then
    echo "Windows build scripts must use the uv-managed Python interpreter." >&2
    exit 1
  fi
done
test -f "${APP_DIR}/packaging/linux/deploydash-archive-keyring.asc"
test -f "${APP_DIR}/packaging/linux/deploydash.sources"
grep -q 'https://updates.deploydash.com/apt' "${APP_DIR}/packaging/linux/deploydash.sources"
grep -q 'Signed-By: /usr/share/keyrings/deploydash-archive-keyring.asc' \
  "${APP_DIR}/packaging/linux/deploydash.sources"
grep -q 'deploydash-archive-keyring.asc' "${APP_DIR}/scripts/build_deb.sh"
grep -q 'DEPLOYDASH_DISTRIBUTION=deb' "${APP_DIR}/scripts/build_deb.sh"
grep -q 'DEPLOYDASH_DISTRIBUTION=snap' "${APP_DIR}/scripts/build_snap.sh"
grep -q 'DEPLOYDASH_DISTRIBUTION=flatpak' "${APP_DIR}/scripts/build_flatpak.sh"
grep -q 'DEPLOYDASH_DISTRIBUTION=dmg' "${APP_DIR}/scripts/build_macos_dmg.sh"
grep -q 'DEPLOYDASH_DISTRIBUTION=mac_app_store' \
  "${APP_DIR}/scripts/build_macos_app_store.sh"
grep -q 'SPARKLE_VERSION="2.9.2"' "${APP_DIR}/scripts/stage_macos_runtime.sh"
grep -q 'SPARKLE_ARCHIVE_SHA256=' "${APP_DIR}/scripts/stage_macos_runtime.sh"
grep -q 'DEPLOYDASH_MACOS_INCLUDE_SPARKLE=1' "${APP_DIR}/scripts/build_macos_dmg.sh"
grep -q 'DEPLOYDASH_MACOS_INCLUDE_SPARKLE=0' \
  "${APP_DIR}/scripts/build_macos_app_store.sh"
grep -q 'SUFeedURL' "${APP_DIR}/scripts/build_macos_dmg.sh"
grep -q 'SUPublicEDKey' "${APP_DIR}/scripts/build_macos_dmg.sh"
grep -q 'checkForUpdates' "${APP_DIR}/macos/Runner/MainFlutterWindow.swift"
grep -q '__PACKAGE_VERSION__' \
  "${APP_DIR}/packaging/windows/msix/Package.appxmanifest"
grep -q '__ARCHITECTURE__' \
  "${APP_DIR}/packaging/windows/msix/Package.appxmanifest"
grep -q 'Name="TidyTechnology.DeployDash"' \
  "${APP_DIR}/packaging/windows/msix/Package.appxmanifest"
grep -q 'Publisher="CN=4DF691A0-E545-4698-A115-C49614B329C6"' \
  "${APP_DIR}/packaging/windows/msix/Package.appxmanifest"
if grep -q 'ProcessorArchitecture="x64"' \
  "${APP_DIR}/packaging/windows/msix/Package.appxmanifest"; then
  echo "The manifest architecture must stay parameterized; per-arch values render at build time." >&2
  exit 1
fi
grep -q 'MinVersion="10.0.17763.0"' \
  "${APP_DIR}/packaging/windows/msix/Package.appxmanifest"
if grep -q 'MinVersion="10.0.22000.0"' \
  "${APP_DIR}/packaging/windows/msix/Package.appxmanifest"; then
  echo "The Windows 11-only floor is retired; the floor is Windows 10 (17763)." >&2
  exit 1
fi
grep -Fq '[ValidateSet("x64", "arm64")]' \
  "${APP_DIR}/scripts/lib/windows_store_packaging.psm1"
grep -q '\-Arch \$Arch' \
  "${APP_DIR}/scripts/build_windows_store.ps1"
grep -q 'windows-store-package-version' \
  "${APP_DIR}/scripts/lib/windows_store_packaging.psm1"
grep -q 'function Invoke-DeployDashNativeCommand' \
  "${APP_DIR}/scripts/lib/windows_store_packaging.psm1"
grep -q 'Resolve-WindowsSdkTool -Name "makeappx.exe"' \
  "${APP_DIR}/scripts/lib/windows_store_packaging.psm1"
grep -q 'returned no output' \
  "${APP_DIR}/scripts/lib/windows_store_packaging.psm1"
grep -q '\[switch\]\$SkipClean' \
  "${APP_DIR}/scripts/build_windows_store.ps1"
grep -q 'windows-store-artifact-names' \
  "${APP_DIR}/scripts/lib/windows_store_packaging.psm1"
grep -Fq 'Include "*.pdb", "*.lib", "*.exp"' \
  "${APP_DIR}/scripts/lib/windows_store_packaging.psm1"
grep -q 'write-windows-store-build-manifest' \
  "${APP_DIR}/scripts/lib/windows_store_packaging.psm1"
grep -q 'DEPLOYDASH_DISTRIBUTION=windows_store' \
  "${APP_DIR}/scripts/lib/windows_store_packaging.psm1"
grep -q 'Invoke-DeployDashWindowsStoreBuild' \
  "${APP_DIR}/scripts/build_windows_store.ps1"
test -f "${APP_DIR}/scripts/build_windows_store_e2e_pair.ps1"
grep -q 'candidate version must be newer' \
  "${APP_DIR}/scripts/lib/windows_store_e2e.psm1"
grep -q 'function New-DeployDashE2ESigningCertificate' \
  "${APP_DIR}/scripts/lib/windows_store_e2e.psm1"
grep -q 'throw "\$Description failed with exit code \$exitCode\. \$(\$detail\.Trim()) \[\$diag\]"' \
  "${APP_DIR}/scripts/lib/windows_store_e2e.psm1"
grep -q 'New-SelfSignedCertificate' \
  "${APP_DIR}/scripts/lib/windows_store_e2e.psm1"
grep -q -- '-KeyExportPolicy NonExportable' \
  "${APP_DIR}/scripts/lib/windows_store_e2e.psm1"
grep -q '\[IO\.File\]::WriteAllBytes' \
  "${APP_DIR}/scripts/lib/windows_store_e2e.psm1"
grep -q 'if (\$index -eq 1)' \
  "${APP_DIR}/scripts/lib/windows_store_e2e.psm1"
grep -q 'Invoke-DeployDashSignTool' \
  "${APP_DIR}/scripts/lib/windows_store_e2e.psm1"
grep -q 'legacyPrivateCertificatePath =.*DeployDash-E2E\.pfx' \
  "${APP_DIR}/scripts/lib/windows_store_e2e.psm1"
if grep -q 'Export-PfxCertificate' \
  "${APP_DIR}/scripts/lib/windows_store_e2e.psm1"; then
  echo "windows_store_e2e.psm1 must not export a PFX certificate." >&2
  exit 1
fi
grep -Fq 'Cert:\CurrentUser\My\$certificateThumbprint' \
  "${APP_DIR}/scripts/lib/windows_store_e2e.psm1"
grep -q 'Invoke-DeployDashWindowsStoreE2EPairBuild' \
  "${APP_DIR}/scripts/build_windows_store_e2e_pair.ps1"
if grep -rqE 'msix_appinstaller|ms-appinstaller|DeployDash\.appinstaller' \
  "${APP_DIR}/lib" \
  "${APP_DIR}/scripts" \
  "${APP_DIR}/packaging/windows" \
  --exclude='validate_release_scaffolds.sh'; then
  echo "The retired direct App Installer channel is still referenced." >&2
  exit 1
fi
grep -q 'DEPLOYDASH_DISTRIBUTION=msi' "${APP_DIR}/scripts/build_windows_msi.ps1"
grep -q "protocolIngressReady" "${APP_DIR}/macos/Runner/MainFlutterWindow.swift"
grep -q "ProtocolRelayCoordinator.shared.handle" "${APP_DIR}/macos/Runner/AppDelegate.swift"
grep -q "get_bridge_runtime_diagnostics" "${APP_DIR}/shared_native/bridge_exports.cc"
grep -q "LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR" "${APP_DIR}/shared_native/bridge_exports.cc"
grep -q "PR_SET_DUMPABLE" "${APP_DIR}/shared_native/process_security.cc"
grep -q "SetDefaultDllDirectories" "${APP_DIR}/shared_native/process_security.cc"
grep -q "NativeBridgeRuntimeDiagnostics" "${APP_DIR}/lib/native_bridge.dart"
test -f "${APP_DIR}/scripts/build_windows_debug.ps1"
test -f "${APP_DIR}/scripts/run_windows_pester_coverage.ps1"
grep -q 'flutter config --enable-windows-desktop' "${APP_DIR}/scripts/build_windows_debug.ps1"
grep -q '@("build", "windows", "--debug")' "${APP_DIR}/scripts/build_windows_debug.ps1"
grep -q 'validate-windows-release-bundle' "${APP_DIR}/scripts/build_windows_debug.ps1"
grep -q 'validate-windows-binary-hardening' "${APP_DIR}/scripts/build_windows_msi.ps1"
grep -q 'validate-windows-binary-hardening' \
  "${APP_DIR}/scripts/lib/windows_store_packaging.psm1"
grep -q 'DEPLOYDASH_WINDOWS_SIGNING_REQUIRED' "${APP_DIR}/scripts/sign_windows_release.ps1"
grep -q 'signtool.exe' "${APP_DIR}/scripts/sign_windows_release.ps1"
grep -q 'windows-signing-paths' "${APP_DIR}/scripts/sign_windows_release.ps1"
test -f "${APP_DIR}/integration_test/platform_runtime_security_test.dart"
test -f "${APP_DIR}/test_driver/integration_test.dart"
grep -q 'source: sqlite3mc' "${APP_DIR}/pubspec.yaml"
if grep -q 'sqlcipher_flutter_libs' "${APP_DIR}/pubspec.yaml"; then
  echo "pubspec.yaml must not depend on sqlcipher_flutter_libs." >&2
  exit 1
fi
test -f "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
test -f "${GIT_ROOT}/.github/workflows/desktop-snap-build.yml"
grep -q "actions/upload-artifact@v6" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
if grep -rq "softprops/\|subosito/" "${GIT_ROOT}/.github/workflows/" --include='*.yml'; then
  echo "Workflows must use only official, vendor-official, or in-repo actions (see Track G)." >&2
  exit 1
fi
grep -q 'gh release upload' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q 'gh release upload' "${GIT_ROOT}/.github/workflows/desktop-snap-build.yml"
grep -q "DEPLOYDASH_ORCHESTRATOR_ROOT" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q 'bash scripts/build_macos_dmg.sh' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "runs-on: ubuntu-24.04" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "ui/build/deb/\\*.deb" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "arch: arm64" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "arch: x64" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "runs-on: \${{ matrix.runner }}" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "runs-on: macos-15" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "AppleWWDRCA" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "STAPLE-RETRY" "${APP_DIR}/scripts/notarize_macos_dmg.sh"
grep -q "macos_only" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "macos-26-intel" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "DEPLOYDASH_MACOS_ARCH" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "deploydash-macos-\${{ matrix.arch }}" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "DeployDash-\\*.dmg" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q 'uv python install 3.13.14' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q 'deploydash-keychains-before.txt' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q 'macos_only' "${GIT_ROOT}/.github/workflows/release.yml"
grep -q "macos_only: \${{ needs.version.outputs.macos_only" "${GIT_ROOT}/.github/workflows/release.yml"
grep -q "macos_only != 'true'" "${GIT_ROOT}/.github/workflows/release.yml"
grep -q '^[[:space:]]*winmac_only:' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q '^[[:space:]]*winmac_only:' "${GIT_ROOT}/.github/workflows/release.yml"
grep -q "^[[:space:]]*winmac_only: \${{ needs\.version\.outputs\.winmac_only" "${GIT_ROOT}/.github/workflows/release.yml"
grep -q "^[[:space:]]*if:[^#]*winmac_only != 'true'" "${GIT_ROOT}/.github/workflows/release.yml"
grep -q "^[[:space:]]*if:[^#]*needs\.ubuntu-deb\.result == 'success' || inputs\.winmac_only" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q 'has_msix' "${GIT_ROOT}/.github/workflows/release.yml"
if grep -q 'list-keychains -d user -s "${KEYCHAIN_PATH}"$' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"; then
  echo "macos-dmg must append its keychain to the existing search list, not replace it (replacing hides the login-keychain Developer ID intermediate and breaks codesign)." >&2
  exit 1
fi
macos_selfhosted="$(
  awk '
    /^  macos-dmg:/ { in_macos=1; next }
    /^  [a-zA-Z0-9_-]+:/ { in_macos=0 }
    in_macos && /self-hosted/ && !/^ *#/ { print; exit }
  ' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
)"
if [[ -n "${macos_selfhosted}" ]]; then
  echo "macos-dmg must run on hosted macos-15, not a self-hosted runner (the desk Mac is fallback-only; see the job comment)." >&2
  exit 1
fi
macos_setup_python="$(
  awk '
    /^  macos-dmg:/ { in_macos=1; next }
    /^  [a-zA-Z0-9_-]+:/ { in_macos=0 }
    in_macos && /uses: actions\/setup-python/ { print; exit }
  ' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
)"
if [[ -n "${macos_setup_python}" ]]; then
  echo "macos-dmg must use uv-managed Python, not setup-python (setup-python requires admin-owned /Users/runner on the desk Mac)." >&2
  exit 1
fi
if grep -q "^  macos-qa-slim:" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"; then
  echo "macos-qa-slim belongs in deploydash_qa (desk-macos-slim), not the app build workflow." >&2
  exit 1
fi
macos_require_version="$(
  awk '
    /^  macos-dmg:/ { in_macos=1; next }
    /^  [a-zA-Z0-9_-]+:/ { in_macos=0 }
    in_macos && /^[[:space:]]+-[[:space:]]+name:[[:space:]]*Require resolved build version/ { print; exit }
  ' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
)"
if [[ -z "${macos_require_version}" ]]; then
  echo "macos-dmg must fail fast when the build version is unresolved (branch dispatch without inputs.build_name), before flutter pub get burns minutes." >&2
  exit 1
fi
if grep -qE '^\s+-\s+arch:\s+x64\s*$' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"; then
  # Active macOS x64 matrix entries are forbidden while x64 is suspended.
  # A commented restore block naming macos-26-intel is required (see above).
  macos_x64_active="$(
    awk '
      /^  macos-dmg:/ { in_macos=1; next }
      /^  [a-zA-Z0-9_-]+:/ { in_macos=0 }
      in_macos && /^[[:space:]]+-[[:space:]]+arch:[[:space:]]+x64[[:space:]]*$/ { print; exit }
    ' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
  )"
  if [[ -n "${macos_x64_active}" ]]; then
    echo "macos-dmg must not schedule an active x64 leg while x64 is suspended." >&2
    exit 1
  fi
fi
grep -q "ui/build/snap/\\*.snap" "${GIT_ROOT}/.github/workflows/desktop-snap-build.yml"
grep -q "build_windows_store.ps1" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q 'arch: x64' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q 'arch: arm64' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
if grep -q 'runner: windows-11-arm' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"; then
  echo "windows-11-arm stays out of the matrix while cryptography publishes no win_arm64 wheel; the Windows legs are x64-only (see desktop-direct-builds.yml)." >&2
  exit 1
fi
grep -q "DEPLOYDASH_WINDOWS_ARCH" "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q 'deploydash-windows-store-candidate-\${{ matrix.arch }}' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q 'windows-qa-slim' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q 'validate-windows-store-build-manifest' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q 'DeployDash_\*_\${{ matrix.arch }}.msixupload' \
  "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
if grep -q 'build_windows_msi.ps1' "${GIT_ROOT}/.github/workflows/"*.yml; then
  echo "MSI stays out of CI automation; MSIX is the only Windows vehicle." >&2
  exit 1
fi
if grep -A20 'Attach Windows Store candidate' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml" | grep -Eq "\\*\\.msix[ \"']"; then
  echo "The unsigned CI .msix must never attach to a release; only .msixupload travels." >&2
  exit 1
fi
# Published releases carry only the DMG and the fixed-name Windows web
# installer; the publish watch strips every other asset (pipeline
# handoff files stay on the draft while the pipeline needs them).
grep -q 'DeployDash-Windows-x64' \
  "${GIT_ROOT}/ui/scripts/store_publish_watch.sh"
grep -q 'releases/assets/${asset_id}' \
  "${GIT_ROOT}/ui/scripts/store_publish_watch.sh"
grep -q 'ASSET_NAME="DeployDash-Windows-x64.exe"' \
  "${GIT_ROOT}/ui/scripts/store_fetch_web_installer.sh"
if grep -q "DEPLOYDASH_WINDOWS_SIGN_CERT" \
  "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"; then
  echo "desktop-direct-builds.yml must not reference a Windows signing certificate." >&2
  exit 1
fi
grep -q "DEPLOYDASH_MACOS_SIGN_CERT_P12_BASE64" \
  "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "DEPLOYDASH_APPLE_APP_PASSWORD" \
  "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q "DEPLOYDASH_ORCHESTRATOR_VERSION_FILE" "${GIT_ROOT}/.github/workflows/backend-engine.yml"
test -f "${GIT_ROOT}/.github/actions/setup-flutter/action.yml"
grep -Eq '^[[:space:]]+default: "3.47.8"' "${GIT_ROOT}/.github/actions/setup-flutter/action.yml"
grep -Eq '^[[:space:]]+default: "737ba8f885dc774b53b442759999a312c9461e4e"' "${GIT_ROOT}/.github/actions/setup-flutter/action.yml"
grep -q './.github/actions/setup-flutter' "${GIT_ROOT}/.github/workflows/ci.yml"
test -f "${GIT_ROOT}/.github/actions/ci-dart-defines/action.yml"
grep -q './.github/actions/ci-dart-defines' "${GIT_ROOT}/.github/workflows/desktop-direct-builds.yml"
grep -q './.github/actions/ci-dart-defines' "${GIT_ROOT}/.github/workflows/desktop-snap-build.yml"
# The CI defines payload has exactly one owner: every producing job routes
# through the shared action, no workflow inlines the payload, and no
# workflow spells its own (relative) defines path. Four call sites: three
# in desktop-direct-builds, one in desktop-snap-build. (The macOS E2E legs
# moved to the private QA repo's release gate with the draft's deletion.)
ci_defines_call_sites="$(grep -rh 'uses: ./.github/actions/ci-dart-defines' "${GIT_ROOT}/.github/workflows/"*.yml | wc -l)"
if [[ "${ci_defines_call_sites}" -ne 4 ]]; then
  echo "Expected 4 ci-dart-defines call sites, found ${ci_defines_call_sites}." >&2
  exit 1
fi
if grep -q 'DART_DEFINES_FILE=config/' "${GIT_ROOT}/.github/workflows/"*.yml; then
  echo "Workflows must take the absolute defines path from ci-dart-defines, never a relative literal." >&2
  exit 1
fi
ci_defines_payloads="$(grep -rh 'os.environ.get("DEPLOYDASH_AMPLITUDE_API_KEY"' "${GIT_ROOT}/.github/" | wc -l)"
if [[ "${ci_defines_payloads}" -ne 1 ]]; then
  echo "The CI defines payload must live in ci-dart-defines exactly once, found ${ci_defines_payloads}." >&2
  exit 1
fi
test -f "${APP_DIR}/packaging/STORE_SUBMISSION_CHECKLIST.md"
test -f "${APP_DIR}/packaging/STORE_METADATA_TEMPLATE.md"
grep -q "imports SSH private key material into Deploy Dash" "${APP_DIR}/README.md"
grep -q "picker-based per action" "${APP_DIR}/RELEASING.md"
test -f "${APP_DIR}/scripts/lib/windows_store_packaging.psm1"
test -f "${APP_DIR}/scripts/lib/windows_store_e2e.psm1"
test -f "${APP_DIR}/test/scripts/windows_store_packaging.Tests.ps1"
test -f "${APP_DIR}/test/scripts/backend_paths.Tests.ps1"
grep -q "Ubuntu 24.04" "${APP_DIR}/RELEASING.md"
grep -q 'libegl1, libgl1, libgles2' "${APP_DIR}/scripts/build_deb.sh"

if grep -rnE \
  "payload\\[['\\\"]key_path['\\\"]\\][[:space:]]*=[[:space:]]*server\\.keyPath|['\\\"]key_path['\\\"][[:space:]]*:[[:space:]]*server\\.keyPath" \
  "${APP_DIR}/lib" \
  --include='*.dart' --exclude='*.g.dart'; then
  echo "Detected direct server.keyPath SSH payload wiring outside the app-managed key model." >&2
  exit 1
fi

# Identity literals duplicated across files with no shared import
# mechanism must not silently drift apart.

if grep -q 'com.example' "${APP_DIR}/macos/Runner.xcodeproj/project.pbxproj"; then
  echo "Runner.xcodeproj still carries a Flutter template com.example identifier." >&2
  exit 1
fi

# POSIX sed rather than grep -P: this script runs on the macOS leg of
# desktop-release-scaffolds.yml, and -P is a GNU extension BSD grep rejects.
agent_access_port="$(
  sed -n 's/.*deployDashAgentControlPort = \([0-9][0-9]*\).*/\1/p' \
    "${APP_DIR}/lib/providers/agent_access_service.dart"
)"
grep -q "127.0.0.1:${agent_access_port}/mcp" "${REPO_ROOT}/orchestrator/README.md"

windows_store_identity_name="$(
  sed -n 's/.*Name="\([^"]*\)" *$/\1/p' \
    "${APP_DIR}/packaging/windows/msix/Package.appxmanifest" | head -n1
)"
grep -q "${windows_store_identity_name}_" \
  "${APP_DIR}/scripts/lib/windows_store_packaging.psm1"

# desktop-release-scaffolds.yml is tag-only; keep its Flutter test paths
# from drifting onto deleted files (as with the old monolithic GitHub
# integration provider test).
DESKTOP_RELEASE_VALIDATION_WORKFLOW="${GIT_ROOT}/.github/workflows/desktop-release-scaffolds.yml"
if grep -q 'github_integration_provider_test\.dart' \
  "${DESKTOP_RELEASE_VALIDATION_WORKFLOW}"; then
  echo "desktop-release-scaffolds.yml still references the deleted monolithic GitHub integration test." >&2
  exit 1
fi
test -f "${APP_DIR}/test/services/native_bridge_test.dart"
test -f "${APP_DIR}/test/services/protocol_link_ingress_test.dart"
test -d "${APP_DIR}/test/providers/github_integration"
grep -q 'test/providers/github_integration/' \
  "${DESKTOP_RELEASE_VALIDATION_WORKFLOW}"
# The Pester coverage step must invoke pwsh, not Windows PowerShell 5.1.
if grep -qE 'powershell -ExecutionPolicy Bypass -File ui/scripts/run_windows_pester_coverage\.ps1' \
  "${DESKTOP_RELEASE_VALIDATION_WORKFLOW}"; then
  echo "desktop-release-scaffolds.yml must run Pester coverage under pwsh, not powershell.exe." >&2
  exit 1
fi
grep -q 'pwsh -ExecutionPolicy Bypass -File ui/scripts/run_windows_pester_coverage\.ps1' \
  "${DESKTOP_RELEASE_VALIDATION_WORKFLOW}"

echo "Release scaffolds validated."
