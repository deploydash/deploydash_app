#!/usr/bin/env bash
# One tick of the Store-live watcher.
#
# Finds draft releases carrying a `deploydash:store-submission=<id>` marker
# (written by store_submit_release.sh) and checks the Microsoft Store
# submission with that id:
#   - Published: flip the draft to published, link the Store and the web
#     installer in the notes, attach Microsoft's web installer stub, and
#     strip the marker.
#   - Failed: annotate the draft, strip the marker, and fail the tick so
#     the failure is visible exactly once instead of on every tick.
#   - Anything else (or a different submission in the slot): leave for a
#     later tick. No marked drafts is the normal, quiet state.
#
# Required env: GH_TOKEN, AZURE_AD_TENANT_ID,
# AZURE_AD_APPLICATION_CLIENT_ID, AZURE_AD_APPLICATION_SECRET, SELLER_ID.
set -euo pipefail

PRODUCT_ID="9P1GK6Z58B9T"
REPO="deploydash/deploydash_app"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/store_cli.sh
source "${script_dir}/lib/store_cli.sh"

drafts_json="$(gh api "repos/${REPO}/releases?per_page=100" --paginate \
  | jq -s 'add | map(select(.draft == true))')"
draft_count="$(jq 'length' <<<"${drafts_json}")"
if [[ "${draft_count}" == "0" ]]; then
  echo "No draft releases; nothing to do."
  exit 0
fi

# Keep full release rows (id + tag + body). Draft get-by-tag via
# `gh release view` 404s; list + PATCH by release id is durable.
marked_rows=()
while IFS= read -r row; do
  body="$(jq -r '.body // ""' <<<"${row}")"
  if grep -q 'deploydash:store-submission=' <<<"${body}"; then
    marked_rows+=("${row}")
  fi
done < <(jq -c '.[]' <<<"${drafts_json}")

if [[ "${#marked_rows[@]}" == "0" ]]; then
  echo "No drafts awaiting a Store submission; nothing to do."
  exit 0
fi

echo "Resolving current Store submission..."
get_output="$(msstore_capture msstore submission get "${PRODUCT_ID}" || true)"
if ! submission_json="$(printf '%s\n' "${get_output}" | msstore_submission_json_from_text)"; then
  echo "Store returned no submission payload; retrying next tick." >&2
  exit 1
fi
# msstore serializes PascalCase keys (UpperCaseNamingPolicy).
current_id="$(jq -r '.Id // empty' <<<"${submission_json}")"
current_status="$(jq -r '.Status // empty' <<<"${submission_json}")"
echo "Store submission ${current_id} status: ${current_status}"

tick_failed=0
for row in "${marked_rows[@]}"; do
  release_id="$(jq -r '.id' <<<"${row}")"
  tag="$(jq -r '.tag_name' <<<"${row}")"
  body_file="$(mktemp)"
  jq -r '.body // ""' <<<"${row}" >"${body_file}"
  marker_id="$(grep -oE 'deploydash:store-submission=[0-9]+' "${body_file}" | head -1 | cut -d= -f2)"
  sed -i '/deploydash:store-submission=/d' "${body_file}"

  if [[ "${marker_id}" != "${current_id}" ]]; then
    echo "${tag}: submission ${marker_id} is not in the Store slot (currently ${current_id}); waiting."
    rm -f "${body_file}"
    continue
  fi

  if [[ "${current_status}" == "Published" ]]; then
    echo "${tag}: submission is live; publishing."
    store_url="https://apps.microsoft.com/detail/${PRODUCT_ID}"
    installer_url="https://get.microsoft.com/installer/download/${PRODUCT_ID}"
    if ! grep -Fq "${store_url}" "${body_file}"; then
      printf '\nMicrosoft Store: %s\n' "${store_url}" >>"${body_file}"
      printf 'Web installer: %s\n' "${installer_url}" >>"${body_file}"
    fi
    # Restate tag_name so a prior notes-only PATCH cannot leave the draft
    # untagged; draft=false makes the release downloadable.
    gh api --method PATCH "repos/${REPO}/releases/${release_id}" \
      -f tag_name="${tag}" \
      -F draft=false \
      --raw-field body="$(cat "${body_file}")" >/dev/null
    bash "${script_dir}/store_fetch_web_installer.sh" "${tag}"
    # Published releases carry only user-facing artifacts. The pipeline
    # handoff files (.msixupload for Store submit, .build-manifest.json
    # for QA audit) stay on the draft while the pipeline needs them and
    # leave here. Allowlist, so future pipeline files never leak either.
    # Command substitution, not process substitution: set -e/pipefail
    # cannot see a `< <(...)` failure, so a gh/jq error would strip
    # nothing and still report success.
    assets_to_delete="$(gh api "repos/${REPO}/releases/${release_id}/assets?per_page=100" \
      --paginate \
      | jq -s 'add | .[] | select(.name | test("\\.dmg$|^DeployDash-Windows-x64\\.exe$") | not) | .id')"
    while IFS= read -r asset_id; do
      [[ -n "${asset_id}" ]] || continue
      echo "${tag}: removing internal asset ${asset_id}."
      gh api --method DELETE \
        "repos/${REPO}/releases/assets/${asset_id}" >/dev/null
    done <<<"${assets_to_delete}"
  elif [[ "${current_status,,}" == *"fail"* ]]; then
    echo "${tag}: submission failed (${current_status}); annotating draft." >&2
    printf '\n**Store submission failed** (status %s, %s). Fix the submission and re-run the Store Submit workflow for this tag.\n' \
      "${current_status}" "$(date -u +%FT%TZ)" >>"${body_file}"
    gh api --method PATCH "repos/${REPO}/releases/${release_id}" \
      -f tag_name="${tag}" \
      --raw-field body="$(cat "${body_file}")" >/dev/null
    tick_failed=1
  else
    echo "${tag}: submission still in flight (${current_status})."
  fi
  rm -f "${body_file}"
done

exit "${tick_failed}"
