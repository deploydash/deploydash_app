#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

rm -f dist/*.whl
uv build --wheel

echo "Built wheel(s):"
ls -1 dist/orchestrator-*.whl
