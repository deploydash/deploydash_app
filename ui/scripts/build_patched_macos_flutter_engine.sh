#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <output FlutterMacOS binary>" >&2
  exit 1
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "The patched FlutterMacOS engine must be built on an Apple Silicon Mac." >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_dir="$(dirname "$1")"
mkdir -p "${output_dir}"
output="$(cd "${output_dir}" && pwd)/$(basename "$1")"
flutter_sdk="$(cd "$(dirname "$(command -v flutter)")/.." && pwd)"
host_ninja="$(command -v ninja)"
engine_revision="371f77202a73e8dff57a8b3bff75bca55c090aee"
if [[ "$(cat "${flutter_sdk}/bin/internal/engine.version")" != "${engine_revision}" ]]; then
  echo "Review Flutter PR #196583 before using this patch with a different engine revision." >&2
  exit 1
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/deploydash-flutter-engine.XXXXXX")"
trap 'rm -rf "${scratch}"' EXIT
mkdir "${scratch}/engine" "${scratch}/depot_tools"

git -C "${scratch}/depot_tools" init -q
git -C "${scratch}/depot_tools" fetch --depth=1 \
  https://chromium.googlesource.com/chromium/tools/depot_tools.git \
  1b0972d3d5e5b1e78055147cb3576361e274b9ed
git -C "${scratch}/depot_tools" checkout --detach FETCH_HEAD
export PATH="${scratch}/depot_tools:${PATH}"
export DEPOT_TOOLS_UPDATE=0

cd "${scratch}/engine"
git init -q
git remote add origin https://github.com/flutter/flutter.git
git fetch --depth=1 origin "${engine_revision}"
git checkout --detach FETCH_HEAD
cat > .gclient <<'EOF'
solutions = [{
    "name": ".",
    "url": "https://github.com/flutter/flutter.git",
    "deps_file": "DEPS",
    "managed": False,
    "custom_vars": {
        "download_android_deps": False,
        "setup_githooks": False,
    },
}]
EOF
xcodebuild -downloadComponent MetalToolchain
gclient sync --no-history
test "$(git rev-parse HEAD)" = "${engine_revision}"

# Flutter PR #196583 at c275d4f4738ee59e19d6b153b71fd6d3042de3f8.
git apply --check --whitespace=error "${script_dir}/patches/flutter-macos-ax-text-field.patch"
git apply --whitespace=error "${script_dir}/patches/flutter-macos-ax-text-field.patch"

# Use the arm64 release framework configuration from Flutter's
# engine/src/flutter/ci/builders/mac_host_engine.json.
cd engine/src
df -h .
python3 flutter/tools/gn --target-dir deploydash-release-arm64 \
  --mac --mac-cpu arm64 --runtime-mode release --no-lto --prebuilt-dart-sdk \
  --no-rbe --no-goma --use-glfw-swiftshader
# GN uses vpython3 from depot_tools. Invoke the host Ninja by its absolute
# path to avoid depot_tools' Chromium Ninja wrapper.
"${host_ninja}" -C out/deploydash-release-arm64 -j 3 \
  flutter/shell/platform/darwin/macos:zip_macos_flutter_framework

binary="out/deploydash-release-arm64/FlutterMacOS.framework/Versions/A/FlutterMacOS"
xcrun lipo "${binary}" -verify_arch arm64
xcrun strip -x -S "${binary}"
install -m 755 "${binary}" "${output}"
shasum -a 256 "${output}"
