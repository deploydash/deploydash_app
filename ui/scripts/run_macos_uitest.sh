#!/usr/bin/env bash
# Local-desk runner for the macOS XCTest boundary shell (P2/P5).
#
# Runs RunnerUITests from a developer Terminal, where the process inherits
# the console GUI session (rendering, events, testmanagerd) that bare SSH
# sessions lack. CI runs the macOS slim gate from the private QA repo's
# release gate instead; this script is the ornament-free local equivalent
# for iterating on the boundary shell.
#
# One-time consents on a fresh Mac (all interactive, all persist):
# - macOS "enable UI Automation" password prompt on the first UI-test run.
# - Terminal "access data from other apps" Allow, for AX-driven tooling.
#
# Determinism comes from the world, not the app: the binary carries no
# profile-reset flag, so wipe the container (Finder delete) before a desk
# run and rely on virgin hosted runners in CI. Every journey asserts the
# onboarding intro first (and no passphrase gate), so a stale profile
# fails loud there; the CREATE gate appears only at enrollment.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

FLUTTER_ROOT="${FLUTTER_ROOT:-$HOME/flutter}"
if [[ ! -x "${FLUTTER_ROOT}/bin/flutter" ]]; then
  echo "Flutter not found at ${FLUTTER_ROOT}; set FLUTTER_ROOT." >&2
  exit 1
fi
export FLUTTER_ROOT

ARCH="$(uname -m)"
if [[ "${ARCH}" == "arm64" ]]; then
  export DEPLOYDASH_MACOS_ARCHS="${DEPLOYDASH_MACOS_ARCHS:-arm64}"
  DEST_ARCH="arm64"
else
  export DEPLOYDASH_MACOS_ARCHS="${DEPLOYDASH_MACOS_ARCHS:-x64}"
  DEST_ARCH="x86_64"
fi

ONLY_TESTING="${1:-RunnerUITests}"
RESULT_BUNDLE="${RUNNER_TEMP:-/tmp}/RunnerUITests.xcresult"

# xcodebuild strips plain shell env for test processes (verified live: an
# exported FULLFLOW arrived empty), but forwards TEST_RUNNER_-prefixed
# variables with the prefix stripped (Xcode 13+ behavior). Translate the
# documented names so callers keep using them.
for e2e_name in DEPLOYDASH_XCUITEST_FULLFLOW DEPLOYDASH_XCUITEST_REUSE_PROFILE DEPLOYDASH_XCUITEST_ITERATE_LEG DEPLOYDASH_E2E_VM_HOST DEPLOYDASH_E2E_VM_PORT DEPLOYDASH_E2E_VM_USER DEPLOYDASH_E2E_VM_PASSWORD E2E_GITHUB_USERNAME E2E_GITHUB_PASSWORD E2E_GITHUB_TOTP_SECRET E2E_GITHUB_REPOSITORY DEPLOYDASH_GITHUB_CLIENT_ID; do
  if [[ -n "${!e2e_name:-}" ]]; then
    export "TEST_RUNNER_${e2e_name}=${!e2e_name}"
  fi
done

# The AX gate must reach the Dart bundle xcodebuild assembles, not just the
# `flutter build` above it: the Assemble phase recompiles from
# xcodebuild's own DART_DEFINES setting (base64 KEY=VALUE per flutter's
# encodeDartDefines), and an empty one silently builds the gate off even
# though pixels render. Verified live: identical empty AX tree with and
# without the flutter-build define until this was passed explicitly.
# (BSD base64 has no -w flag; strip newlines explicitly.)
# OAuth client secret for the code exchange (E2E only): the app reads
# DEPLOYDASH_GITHUB_CLIENT_SECRET with an empty compiled default, so
# without this the OAuth leg dies at code exchange. Sourced from
# DEPLOYDASH_OAUTH_APP_CLIENT_SECRET in the environment (mapped to the
# define name the app reads). It rides both the flutter build (never
# echoed) and xcodebuild DART_DEFINES (echoed into the LOCAL xcodebuild
# log only — acceptable on a private desk Mac; CI must mask the exact
# blob before use). Absent secret leaves every other leg unaffected.
E2E_AX_DEFINES="$(printf '%s' 'DEPLOYDASH_E2E_AX_IDENTIFIERS=true' | base64 | tr -d '\n')"
OAUTH_SECRET_DEFINE=""
OAUTH_SECRET_DEFINES_SUFFIX=""
if [[ -n "${DEPLOYDASH_OAUTH_APP_CLIENT_SECRET:-}" ]]; then
  OAUTH_SECRET_DEFINE="--dart-define=DEPLOYDASH_GITHUB_CLIENT_SECRET=${DEPLOYDASH_OAUTH_APP_CLIENT_SECRET}"
  OAUTH_SECRET_B64="$(printf '%s' "DEPLOYDASH_GITHUB_CLIENT_SECRET=${DEPLOYDASH_OAUTH_APP_CLIENT_SECRET}" | base64 | tr -d '\n')"
  OAUTH_SECRET_DEFINES_SUFFIX=",${OAUTH_SECRET_B64}"
fi
# SKIP_FLUTTER_BUILD=1 skips the app rebuild for harness-only changes
# (Swift test file, this script): the app binary is untouched by those,
# so xcodebuild recompiles only the test bundle. Correct only when no Dart,
# asset, plugin, or define change is pending — a stale app binary under
# new test code fails loudly at runtime, never silently. Default off.
if [[ "${SKIP_FLUTTER_BUILD:-0}" == "1" ]]; then
  echo "SKIP_FLUTTER_BUILD=1: reusing the existing app binary." >&2
else
  flutter build macos --debug \
    --dart-define=DEPLOYDASH_E2E_AX_IDENTIFIERS=true \
    ${OAUTH_SECRET_DEFINE}
fi
rm -rf "${RESULT_BUNDLE}"
# Long allowance: server setup alone runs ~45min; mirrors the WidgetTester
# 90-minute test timeout rather than xcodebuild's much shorter default.
xcodebuild test \
  -project macos/Runner.xcodeproj \
  -scheme Runner \
  -destination "platform=macOS,arch=${DEST_ARCH}" \
  -only-testing:"${ONLY_TESTING}" \
  -resultBundlePath "${RESULT_BUNDLE}" \
  -default-test-execution-time-allowance 5400 \
  CODE_SIGN_IDENTITY="-" \
  DART_DEFINES="${E2E_AX_DEFINES}${OAUTH_SECRET_DEFINES_SUFFIX}"
