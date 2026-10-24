#!/usr/bin/env bash
# Live PostgreSQL proof for project isolation (#127).
#
# Starts a throwaway PostgreSQL container, runs
# tests/postgres_registry_live_test.py against it, and removes the container
# on exit. Needs Docker. Nothing is published on a host port.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

IMAGE="${DEPLOYDASH_LIVE_POSTGRES_IMAGE:-postgres:18-alpine}"
CONTAINER="deploydash-live-pg-$$"
PASSWORD="live-check-$$"

cleanup() {
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker run -d --rm --name "${CONTAINER}" \
  -e POSTGRES_USER=deploydash \
  -e POSTGRES_PASSWORD="${PASSWORD}" \
  "${IMAGE}" >/dev/null

for _ in $(seq 1 90); do
  if docker exec "${CONTAINER}" psql -U deploydash -d postgres -tAc "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec "${CONTAINER}" psql -U deploydash -d postgres -tAc "SELECT version()"

DEPLOYDASH_LIVE_POSTGRES_CONTAINER="${CONTAINER}" \
DEPLOYDASH_LIVE_POSTGRES_PASSWORD="${PASSWORD}" \
  uv run python -m unittest -v tests.postgres_registry_live_test
