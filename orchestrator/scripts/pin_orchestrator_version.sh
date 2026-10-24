#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <orchestrator-version>" >&2
  exit 1
fi

VERSION="$1"
BACKEND_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${BACKEND_ROOT}/.." && pwd)"

resolve_pinned_version_file() {
  local override="${DEPLOYDASH_ORCHESTRATOR_VERSION_FILE:-${DEPLOYDASH_BACKEND_VERSION_FILE:-${ORCHESTRATOR_VERSION_FILE:-}}}"
  if [[ -n "${override}" ]]; then
    if [[ "${override}" != /* ]]; then
      override="${REPO_ROOT}/${override}"
    fi
    printf '%s\n' "${override}"
    return
  fi

  if [[ -f "${BACKEND_ROOT}/orchestrator.version" ]]; then
    printf '%s\n' "${BACKEND_ROOT}/orchestrator.version"
    return
  fi

  if [[ -f "${REPO_ROOT}/ui/orchestrator.version" ]]; then
    printf '%s\n' "${REPO_ROOT}/ui/orchestrator.version"
    return
  fi

  printf '%s\n' "${REPO_ROOT}/orchestrator.version"
}

PINNED_VERSION_FILE="$(resolve_pinned_version_file)"

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]]; then
  echo "Invalid semantic version: ${VERSION}" >&2
  exit 1
fi

mkdir -p "$(dirname "${PINNED_VERSION_FILE}")"
printf '%s\n' "${VERSION}" > "${PINNED_VERSION_FILE}"
echo "Pinned orchestrator version to ${VERSION} in ${PINNED_VERSION_FILE}"
