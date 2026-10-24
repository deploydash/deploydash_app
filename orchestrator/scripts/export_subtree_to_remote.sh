#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <remote-url> [branch]" >&2
  exit 1
fi

REMOTE_URL="$1"
TARGET_BRANCH="${2:-main}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUBTREE_PREFIX="orchestrator"
TEMP_BRANCH="orchestrator-export-$(date +%s)"

cd "${REPO_ROOT}"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Must run from a git repository." >&2
  exit 1
fi

echo "Creating subtree split branch ${TEMP_BRANCH} from ${SUBTREE_PREFIX}..."
git subtree split --prefix="${SUBTREE_PREFIX}" -b "${TEMP_BRANCH}"

cleanup() {
  git branch -D "${TEMP_BRANCH}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Pushing ${TEMP_BRANCH} to ${REMOTE_URL}:${TARGET_BRANCH}..."
git push "${REMOTE_URL}" "${TEMP_BRANCH}:${TARGET_BRANCH}"

echo "Export complete."
