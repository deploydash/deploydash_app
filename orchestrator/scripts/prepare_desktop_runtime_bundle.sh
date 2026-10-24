#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXE="${ORCHESTRATOR_VENV_PYTHON:-${DEPLOYDASH_ENGINE_VENV_PYTHON:-}}"

if [[ -z "${PYTHON_EXE}" ]]; then
  if command -v uv >/dev/null 2>&1; then
    PYTHON_EXE="$(uv python find 3.13.14 2>/dev/null || true)"
  fi
fi

if [[ -z "${PYTHON_EXE}" ]]; then
  PYTHON_EXE="python3"
fi

exec "${PYTHON_EXE}" "${SCRIPT_DIR}/prepare_desktop_runtime_bundle.py" "$@"
