#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${APP_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/backend_paths.sh"
CONTRACTS_SCRIPT="$(resolve_backend_script_path release_contracts.py)"
PYTHON_EXE="${ORCHESTRATOR_VENV_PYTHON:-${DEPLOYDASH_ENGINE_VENV_PYTHON:-}}"

APP_BUNDLE="${1:-}"
if [[ -z "${APP_BUNDLE}" || ! -d "${APP_BUNDLE}" ]]; then
  echo "Usage: verify_macos_hardened_runtime.sh <Deploy Dash.app>" >&2
  exit 1
fi

command -v codesign >/dev/null 2>&1 || {
  echo "Missing required command: codesign" >&2
  exit 1
}

if [[ -z "${PYTHON_EXE}" ]] && command -v uv >/dev/null 2>&1; then
  PYTHON_EXE="$(uv python find 3.13.14 2>/dev/null || true)"
fi
if [[ -z "${PYTHON_EXE}" ]] && command -v python3 >/dev/null 2>&1; then
  PYTHON_EXE="$(command -v python3)"
fi
if [[ -z "${PYTHON_EXE}" ]]; then
  echo "Unable to locate Python for macOS release verification." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

signature_details="$(codesign -dv --verbose=4 "${APP_BUNDLE}" 2>&1)"
if ! grep -Eq 'flags=.*runtime' <<<"${signature_details}"; then
  echo "The macOS app signature does not enable Hardened Runtime." >&2
  exit 1
fi

outer_team_id="$(sed -n 's/^TeamIdentifier=//p' <<<"${signature_details}" | head -n1)"
if [[ -z "${outer_team_id}" || "${outer_team_id}" == "not set" ]]; then
  echo "The macOS app signature does not have an Apple Team ID." >&2
  echo "Ad-hoc signing is incompatible with Hardened Runtime library validation." >&2
  exit 1
fi
entitlements_file="$(mktemp)"
trap 'rm -f "${entitlements_file}"' EXIT
codesign -d --entitlements :- "${APP_BUNDLE}" >"${entitlements_file}" 2>/dev/null

"${PYTHON_EXE}" - "${entitlements_file}" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    entitlements = plistlib.load(handle)

required = (
    "com.apple.security.app-sandbox",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.network.client",
    "com.apple.security.network.server",
)
for entitlement in required:
    if entitlements.get(entitlement) is not True:
        raise SystemExit(f"Required macOS entitlement is missing: {entitlement}")

forbidden = (
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.disable-executable-page-protection",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.get-task-allow",
)
for entitlement in forbidden:
    if entitlement in entitlements:
        raise SystemExit(f"Forbidden macOS release entitlement is present: {entitlement}")
PY

signing_paths_file="$(mktemp)"
trap 'rm -f "${entitlements_file}" "${signing_paths_file}"' EXIT
"${PYTHON_EXE}" "${CONTRACTS_SCRIPT}" macos-signing-paths \
  --app-bundle "${APP_BUNDLE}" >"${signing_paths_file}"

while IFS= read -r nested_binary; do
  [[ -n "${nested_binary}" ]] || continue
  nested_details="$(codesign -dv --verbose=4 "${nested_binary}" 2>&1)" || {
    echo "Unsigned nested macOS runtime code: ${nested_binary}" >&2
    exit 1
  }
  if ! grep -Eq 'flags=.*runtime' <<<"${nested_details}"; then
    echo "Nested runtime code lacks Hardened Runtime: ${nested_binary}" >&2
    exit 1
  fi
  nested_team_id="$(sed -n 's/^TeamIdentifier=//p' <<<"${nested_details}" | head -n1)"
  if [[ "${nested_team_id}" != "${outer_team_id}" ]]; then
    echo "Nested runtime code has a different Team ID: ${nested_binary}" >&2
    echo "Outer Team ID: ${outer_team_id:-<none>}" >&2
    echo "Nested Team ID: ${nested_team_id:-<none>}" >&2
    exit 1
  fi
done <"${signing_paths_file}"

echo "Verified macOS Hardened Runtime for ${APP_BUNDLE}"
