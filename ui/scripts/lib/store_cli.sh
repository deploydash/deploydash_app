# Shared Microsoft Store CLI session handling for release automation.
#
# msstore persists the client secret via libsecret, so reconfigure and every
# msstore invocation must share one live D-Bus session with a keyring.
# Also works around microsoft/msstore-cli#181 by pre-creating XDG_DATA_HOME
# (0700: it holds tenant/client/seller ids) so reconfigure and later reads
# agree on the config location.
#
# Required env: AZURE_AD_TENANT_ID, AZURE_AD_APPLICATION_CLIENT_ID,
# AZURE_AD_APPLICATION_SECRET, SELLER_ID. Requires: msstore,
# dbus-run-session, gnome-keyring-daemon (installed by the calling workflow).

# Run one msstore command inside a fresh authenticated session.
# Usage: store_cli_session msstore <args>...
# Stdout/stderr pass through; exit status is the command's.
store_cli_session() {
  if [[ -z "${AZURE_AD_TENANT_ID}${AZURE_AD_APPLICATION_CLIENT_ID}${AZURE_AD_APPLICATION_SECRET}${SELLER_ID}" ]]; then
    echo "Store submission secrets are not configured." >&2
    return 1
  fi
  export XDG_DATA_HOME="${HOME}/.local/share"
  mkdir -p "${XDG_DATA_HOME}" && chmod 0700 "${XDG_DATA_HOME}"
  # The payload crosses a dbus-run-session boundary, so re-quote it into a
  # temp script instead of trusting nested shell quoting.
  local payload
  payload="$(mktemp)"
  printf '%q ' "$@" >"${payload}"
  dbus-run-session -- bash -c '
    set -euo pipefail
    eval "$(printf "%s\n" "ci" | gnome-keyring-daemon --unlock --daemonize --login)"
    msstore reconfigure \
      --tenantId "${AZURE_AD_TENANT_ID}" \
      --sellerId "${SELLER_ID}" \
      --clientId "${AZURE_AD_APPLICATION_CLIENT_ID}" \
      --clientSecret "${AZURE_AD_APPLICATION_SECRET}"
    bash "$1"
  ' _ "${payload}"
  local status=$?
  rm -f "${payload}"
  return "${status}"
}

# Strip ANSI color codes from msstore output for reliable parsing.
store_cli_plain() {
  sed 's/\x1b\[[0-9;]*m//g'
}

# Capture msstore session output without pipefail/sed EPIPE races.
# Piping `store_cli_session | store_cli_plain` under `set -o pipefail` can
# kill the tick with `sed: couldn't flush stdout: Broken pipe` when the
# session tears down mid-stream. Capture first, then strip ANSI.
# Usage: out="$(msstore_capture msstore ...)"; status=$?
msstore_capture() {
  local out status
  set +e
  out="$(store_cli_session "$@" 2>&1)"
  status=$?
  set -e
  printf '%s\n' "${out}" | store_cli_plain
  return "${status}"
}

# Extract the pretty-printed submission JSON object from msstore stdout.
# Prints the JSON document or exits 1 when none is present. Prefer this
# over `grep -m1 '^{'`, which truncates multiline payloads and breaks jq.
msstore_submission_json_from_text() {
  python3 -c '
import json, re, sys
text = sys.stdin.read()
match = re.search(r"\{[\s\S]*\n\}", text)
if match is None:
    match = re.search(r"\{[\s\S]*\}", text)
if match is None:
    raise SystemExit("no submission json in msstore output")
payload = json.loads(match.group(0))
json.dump(payload, sys.stdout)
'
}
