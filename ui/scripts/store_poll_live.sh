#!/usr/bin/env bash
# Poll a committed Microsoft Store submission until it is live.
#
# Usage: store_poll_live.sh <submission-id>
# Exits 0 once the submission with the given id reports Published, exits 1
# on any failure status or when the submission slot no longer holds that
# id (superseded or deleted). Anything else sleeps and retries; the calling
# workflow's timeout-minutes bounds the total wait (certification runs on
# Microsoft time: hours typical, up to three business days).
#
# Required env: AZURE_AD_TENANT_ID, AZURE_AD_APPLICATION_CLIENT_ID,
# AZURE_AD_APPLICATION_SECRET, SELLER_ID.
set -euo pipefail

PRODUCT_ID="9P1GK6Z58B9T"
POLL_SECONDS=600

expected_id="${1:?usage: store_poll_live.sh <submission-id>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/store_cli.sh
source "${script_dir}/lib/store_cli.sh"

while true; do
  get_output="$(msstore_capture msstore submission get "${PRODUCT_ID}" || true)"
  if ! submission_json="$(printf '%s\n' "${get_output}" | msstore_submission_json_from_text)"; then
    echo "$(date -u +%FT%TZ) no submission payload; retrying..." >&2
    sleep "${POLL_SECONDS}"
    continue
  fi
  # msstore serializes PascalCase keys (UpperCaseNamingPolicy).
  actual_id="$(jq -r '.Id // empty' <<<"${submission_json}")"
  status="$(jq -r '.Status // empty' <<<"${submission_json}")"
  echo "$(date -u +%FT%TZ) submission ${actual_id} status: ${status}"
  if [[ "${actual_id}" != "${expected_id}" ]]; then
    echo "Submission slot no longer holds ${expected_id} (now ${actual_id}); refusing to wait on a stranger." >&2
    exit 1
  fi
  if [[ "${status}" == "Published" ]]; then
    echo "Submission ${expected_id} is live."
    exit 0
  fi
  if [[ "${status,,}" == *"fail"* ]]; then
    echo "Submission ${expected_id} failed with status ${status}." >&2
    jq '.StatusDetails // empty' <<<"${submission_json}"
    exit 1
  fi
  sleep "${POLL_SECONDS}"
done
