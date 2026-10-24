#!/usr/bin/env bash
# Submit a release's MSIX packages to the Microsoft Store and commit the
# submission for certification.
#
# Usage: store_submit_release.sh <tag>
# Reads .msixupload assets from the tag's GitHub release (draft or
# published) via the releases list + asset API — not get-by-tag, which
# 404s for drafts. Uploads each architecture. Current msstore CLI
# (`publish <package>`) creates, uploads, and commits in one step and
# waits for commit acceptance; this script then records the submission
# id on the draft for store_publish_watch.sh. Writes submission_id to
# GITHUB_OUTPUT.
#
# Fail-closed: refuses when a submission is already pending before
# upload, when the release carries no packages, or when the submission
# id cannot be resolved after publish.
#
# Required env: GH_TOKEN, AZURE_AD_TENANT_ID,
# AZURE_AD_APPLICATION_CLIENT_ID, AZURE_AD_APPLICATION_SECRET, SELLER_ID.
set -euo pipefail

PRODUCT_ID="9P1GK6Z58B9T"
REPO="deploydash/deploydash_app"

tag="${1:?usage: store_submit_release.sh <tag>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/store_cli.sh
source "${script_dir}/lib/store_cli.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

echo "Checking for an already-pending submission..."
status_output="$(msstore_capture msstore submission status "${PRODUCT_ID}" || true)"
# "Found Pending Submission" also appears while Status is Certification for
# the in-flight package; only refuse when Status is still Pending (not yet
# committed). A stuck Pending blocks a new upload.
if grep -q "Found Pending Submission" <<<"${status_output}"; then
  if grep -Eq '"Status"[[:space:]]*:[[:space:]]*"Pending"' <<<"${status_output}"; then
    echo "A submission is already pending; refusing to submit ${tag} on top of it." >&2
    exit 1
  fi
fi

echo "Downloading .msixupload packages from release ${tag}..."
# `/releases/tags/{tag}` 404s for drafts. List releases (includes drafts in
# this private repo) and download assets by id so GITHUB_TOKEN + older `gh`
# both work without relying on CLI get-by-tag fallbacks.
release_id="$(
  gh api "repos/${REPO}/releases?per_page=100" --paginate \
    | jq -s --arg tag "${tag}" '
        add
        | map(select(.tag_name == $tag))
        | first
        | .id // empty
      '
)"
if [[ -z "${release_id}" ]]; then
  echo "No GitHub release found for tag ${tag}; refusing submission." >&2
  exit 1
fi
while IFS=$'\t' read -r asset_id asset_name; do
  [[ -z "${asset_id}" ]] && continue
  echo "Fetching ${asset_name} (asset ${asset_id})..."
  gh api \
    -H "Accept: application/octet-stream" \
    "repos/${REPO}/releases/assets/${asset_id}" \
    >"${work_dir}/${asset_name}"
done < <(
  gh api "repos/${REPO}/releases/${release_id}/assets" \
    --jq '.[] | select(.name | endswith(".msixupload")) | [.id, .name] | @tsv'
)
if [[ -z "$(ls -A "${work_dir}" 2>/dev/null || true)" ]]; then
  echo "No .msixupload assets on release ${tag}; refusing submission." >&2
  exit 1
fi
ls -la "${work_dir}"

for package in "${work_dir}"/*.msixupload; do
  echo "Submitting ${package} ..."
  # Current msstore: create + upload + commit + poll to PreProcessing.
  store_cli_session msstore publish "${package}" -id "${PRODUCT_ID}"
done

echo "Resolving submission id after publish..."
get_output="$(msstore_capture msstore submission get "${PRODUCT_ID}" || true)"
submission_json="$(printf '%s\n' "${get_output}" | msstore_submission_json_from_text)"
submission_id="$(jq -r '.Id // empty' <<<"${submission_json}")"
if [[ -z "${submission_id}" ]]; then
  echo "submission json has no Id; refusing to mark draft." >&2
  exit 1
fi
echo "Submission id: ${submission_id}"

# Record the in-flight submission on the draft so the scheduled watcher
# (store_publish_watch.sh) knows which release this submission unlocks.
# Published releases are already done and never get a marker. Use the
# release id (not get-by-tag) so drafts stay addressable. Always restate
# tag_name on PATCH so the draft cannot lose its tag association.
release_json="$(gh api "repos/${REPO}/releases/${release_id}")"
is_draft="$(jq -r '.draft' <<<"${release_json}")"
if [[ "${is_draft}" == "true" ]]; then
  body_file="$(mktemp)"
  jq -r '.body // ""' <<<"${release_json}" >"${body_file}"
  if ! grep -q 'deploydash:store-submission=' "${body_file}"; then
    printf '\n<!-- deploydash:store-submission=%s -->\n' "${submission_id}" >>"${body_file}"
    gh api --method PATCH "repos/${REPO}/releases/${release_id}" \
      -f tag_name="${tag}" \
      --raw-field body="$(cat "${body_file}")" >/dev/null
    echo "Marker recorded on draft ${tag}."
  else
    echo "Draft ${tag} already carries a submission marker; leaving it."
  fi
  rm -f "${body_file}"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "submission_id=${submission_id}" >>"${GITHUB_OUTPUT}"
else
  echo "submission_id=${submission_id}"
fi
