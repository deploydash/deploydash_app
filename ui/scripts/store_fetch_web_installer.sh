#!/usr/bin/env bash
# Attach Microsoft's web installer stub to a published GitHub release.
#
# Usage: store_fetch_web_installer.sh <tag>
# Downloads the Microsoft-signed stub that asks the Store to install the
# app, verifies it, and uploads it to the tag's release. The stub is
# version-independent (it always installs whatever the Store currently
# serves), so every release carries the same file under one fixed name;
# it is downloaded fresh each time rather than vendored, so a
# Microsoft-side rotation is picked up instead of frozen in.
#
# Verification (every check is loud; nothing fails silently):
#  1. TLS download from get.microsoft.com succeeds (curl --fail).
#  2. Integrity: osslsigncode's computed message digest equals the signed
#     digest. Its exit status is deliberately NOT trusted: short-lived
#     Marketplace leaves plus timestamp chains make exit-0 unachievable
#     (v1.1.0 proved this); the digest computation itself is sound.
#  3. Authenticity: the leaf signer is Microsoft Corporation, the
#     embedded chain links up to a self-signed Microsoft root fetched
#     from the intermediate's Microsoft AIA URL (key-pinned below, so a
#     network attacker cannot substitute it), and openssl verifies the
#     chain at the countersignature time.
#
# osslsigncode is apt-installed unpinned, so its Subject rendering is
# not a contract: v1.1.0 printed `CN=Microsoft Corporation,...` while
# v1.1.1 printed openssl-oneline `/C=US/.../CN=Microsoft Corporation`.
# Signer checks therefore canonicalize both spellings (canon_dn) and
# match full DN components, never prefixes.
#
# Required env: GH_TOKEN. Requires: curl, osslsigncode, openssl, gh.
set -euo pipefail

PRODUCT_ID="9P1GK6Z58B9T"
REPO="deploydash/deploydash_app"
INSTALLER_URL="https://get.microsoft.com/installer/download/${PRODUCT_ID}"
ASSET_NAME="DeployDash-Windows-x64.exe"
# SHA-256 over the DER SubjectPublicKeyInfo of Microsoft Root CA 2011.
# If Microsoft rotates the root, verification fails loudly here; update
# the pin from the new root at the intermediate's AIA CA-Issuers URL.
MS_ROOT_SPKI_SHA256="02376d0908ac23041cc7d666d9daf192554f7fc36317aa9cb800908616b28af8"

fail() {
  echo "store_fetch_web_installer: $*" >&2
  exit 1
}

# Canonical DN: split on either separator, trim, drop empties, sort.
# Order- and spelling-insensitive, so oneline and RFC2253 forms of one
# DN compare equal. Never fails: empty input yields empty output.
canon_dn() { # $1 = DN in oneline or RFC2253 form
  # The grep arm must not fail the pipeline on blank input: under
  # set -e/pipefail a bare grep -v would kill main() silently instead
  # of letting the caller fail loudly on the empty canonical form.
  tr ',/' '\n\n' <<<"$1" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | { grep -v '^$' || true; } \
    | LC_ALL=C sort \
    | tr '\n' ','
}

# True when a full O or CN component is exactly Microsoft Corporation.
# Exact components only: `CN=Microsoft Corporation Evil` (which a
# prefix match would accept) and bare OU membership both reject.
signer_is_microsoft() { # $1 = signer subject in either DN form
  local component
  while IFS= read -r component; do
    if [[ "${component}" == "O=Microsoft Corporation" || "${component}" == "CN=Microsoft Corporation" ]]; then
      return 0
    fi
  done < <(tr ',/' '\n\n' <<<"$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  return 1
}

main() {
  tag="${1:?usage: store_fetch_web_installer.sh <tag>}"
  work_dir="$(mktemp -d)"
  trap 'rm -rf "${work_dir}"' EXIT

curl --fail --silent --show-error --location \
  --output "${work_dir}/${ASSET_NAME}" "${INSTALLER_URL}"
ls -la "${work_dir}/${ASSET_NAME}"

# osslsigncode exits non-zero on this stub shape (see header); capture
# the output and judge it ourselves instead of dying silently in $().
verify_out="$(osslsigncode verify "${work_dir}/${ASSET_NAME}" 2>&1 || true)"
[[ -n "${verify_out}" ]] || fail "osslsigncode produced no output"

current_digest="$(grep -m1 'Current message digest' <<<"${verify_out}" | sed 's/.*:[[:space:]]*//' | tr -d ' \t\r\n')"
calculated_digest="$(grep -m1 'Calculated message digest' <<<"${verify_out}" | sed 's/.*:[[:space:]]*//' | tr -d ' \t\r\n')"
[[ -n "${current_digest}" && -n "${calculated_digest}" ]] \
  || fail "could not read message digests from osslsigncode output"
[[ "${current_digest}" == "${calculated_digest}" ]] \
  || fail "message digest mismatch: file differs from what was signed"
echo "Message digest matches signed digest."

signer_subject="$(awk '/Signer #0:/{found=1} found && /^[ \t]*Subject:/{sub(/^[ \t]*Subject:[ \t]*/, ""); print; exit}' <<<"${verify_out}")"
[[ -n "${signer_subject}" ]] || fail "could not read Signer #0 subject"
signer_is_microsoft "${signer_subject}" \
  || fail "signer is not Microsoft Corporation: ${signer_subject}"
echo "Signer: ${signer_subject}"

timestamp_time="$(grep -m1 'Timestamp time:' <<<"${verify_out}" | sed 's/.*Timestamp time:[[:space:]]*//')"
[[ -n "${timestamp_time}" ]] || fail "no countersignature timestamp found"
attime="$(date -u -d "${timestamp_time}" +%s)" \
  || fail "could not parse timestamp: ${timestamp_time}"
echo "Countersignature time: ${timestamp_time}"

osslsigncode extract-signature -pem \
  -out "${work_dir}/sig.pem" "${work_dir}/${ASSET_NAME}" >/dev/null \
  || fail "could not extract PKCS#7 signature"
openssl pkcs7 -in "${work_dir}/sig.pem" -print_certs \
  -out "${work_dir}/certs.pem" \
  || fail "could not list embedded certificates"

# Split the bundle and locate the leaf by the signer subject above.
# Canonical comparison: openssl prints RFC2253 here while osslsigncode
# may print oneline above; both spellings canonicalize identically.
rm -f "${work_dir}"/cert-*.pem
awk "/BEGIN CERT/{n++} n > 0 {print > (\"${work_dir}/cert-\" n \".pem\")}" \
  "${work_dir}/certs.pem"
leaf=""
intermediates=()
signer_canon="$(canon_dn "${signer_subject}")"
for cert in "${work_dir}"/cert-*.pem; do
  subject="$(openssl x509 -in "${cert}" -noout -subject -nameopt RFC2253 \
    | sed 's/^subject=//')"
  if [[ "$(canon_dn "${subject}")" == "${signer_canon}" ]]; then
    [[ -z "${leaf}" ]] || fail "signer subject matches two embedded certs"
    leaf="${cert}"
  else
    intermediates+=("${cert}")
  fi
done
[[ -n "${leaf}" ]] || fail "signer cert not found among embedded certs"

# Walk issuer linkage from the leaf to the topmost intermediate; the
# walk staying inside embedded certs proves the chain links are intact.
dn_of() { # $1 = cert path, $2 = subject|issuer (RFC2253, no prefix)
  openssl x509 -in "$1" -noout "-$2" -nameopt RFC2253 | sed "s/^$2=//"
}
current_issuer="$(dn_of "${leaf}" issuer)"
topmost=""
while [[ -n "${current_issuer}" ]]; do
  next=""
  for cert in "${intermediates[@]}"; do
    if [[ "$(dn_of "${cert}" subject)" == "${current_issuer}" ]]; then
      next="${cert}"
      break
    fi
  done
  [[ -z "${next}" ]] && break
  topmost="${next}"
  current_issuer="$(dn_of "${next}" issuer)"
done
[[ -n "${topmost}" ]] || fail "no embedded issuer chain above the leaf"

aia_url="$(openssl x509 -in "${topmost}" -noout -text \
  | sed -n 's/.*CA Issuers - URI:\(.*\)/\1/p' | head -1 | tr -d '\r')"
[[ -n "${aia_url}" ]] || fail "topmost intermediate carries no AIA CA-Issuers URL"
echo "Fetching root CA from ${aia_url}"
curl --fail --silent --show-error --location \
  --output "${work_dir}/root.cer" "${aia_url}"
openssl x509 -inform DER -in "${work_dir}/root.cer" \
  -out "${work_dir}/root.pem" -outform PEM \
  || fail "downloaded root is not a DER certificate"

root_subject="$(dn_of "${work_dir}/root.pem" subject)"
root_issuer="$(dn_of "${work_dir}/root.pem" issuer)"
[[ "${root_subject}" == "${root_issuer}" ]] \
  || fail "downloaded root is not self-signed: ${root_subject}"
[[ "${root_subject}" == *"Microsoft Root Certificate Authority"* ]] \
  || fail "downloaded root is not a Microsoft root: ${root_subject}"
[[ "${current_issuer}" == "${root_subject}" ]] \
  || fail "chain top does not link to the downloaded root"
root_spki="$(openssl x509 -in "${work_dir}/root.pem" -pubkey -noout \
  | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 | sed 's/^.*= //')"
[[ "${root_spki}" == "${MS_ROOT_SPKI_SHA256}" ]] \
  || fail "downloaded root key does not match the pinned key"
echo "Root: ${root_subject}"

# Never let bare `cat` read stdin: an empty array must yield an empty
# bundle, not a hung pipeline.
if [[ "${#intermediates[@]}" -gt 0 ]]; then
  cat "${intermediates[@]}" >"${work_dir}/untrusted.pem"
else
  touch "${work_dir}/untrusted.pem"
fi
chain_out="$(openssl verify -attime "${attime}" -ignore_critical \
  -CAfile "${work_dir}/root.pem" -untrusted "${work_dir}/untrusted.pem" \
  "${leaf}" 2>&1)" || true
grep -q ': OK$' <<<"${chain_out}" \
  || fail "certificate chain did not verify: ${chain_out}"
echo "Certificate chain verifies to the Microsoft root."

gh release upload "${tag}" \
  --repo "${REPO}" \
  "${work_dir}/${ASSET_NAME}" \
  --clobber
}

# Sourcing the file defines the helpers without running the release
# mutation, so contract tests can execute the real checks.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
