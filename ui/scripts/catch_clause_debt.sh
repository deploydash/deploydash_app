#!/usr/bin/env bash
set -euo pipefail

# T-2.1.1: the "equivalent guard for T-2.3" its own task text allows in
# place of enabling avoid_catches_without_on_clauses as a blocking lint.
# That rule found 162 sites -- a strict superset of the ~26 T-2.3.4 names
# by file, since most of the rest already handle the caught exception
# reasonably (e.g. `catch (e) { ...e.toString()... }`) and just lack an
# `on SomeType` filter. Fixing that properly needs the typed
# Result/AppFailure model T-2.3 introduces; this script just stops the
# count from growing until then. T-2.3.5 turns the real lint on for good
# once T-2.3.4 has driven this to zero.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${APP_DIR}"

# Baseline recorded at T-2.1.1 as 162, re-pinned to the measured 114 on
# 2026-09-04 after T-2.3.4 cleared every `catch (_)`. Lower it as sites are
# fixed; never raise it without a stated reason -- this is a debt register,
# not a suppression, and a baseline carrying 48 lines of slack does not
# ratchet.
BASELINE=114

CONFIG="analysis_options.yaml"
BACKUP="$(mktemp)"
cp "${CONFIG}" "${BACKUP}"
restore_config() {
  mv "${BACKUP}" "${CONFIG}"
}
trap restore_config EXIT

# Temporarily enable the rule this file otherwise deliberately omits (see
# the comment in analysis_options.yaml), count its findings, then restore
# the checked-in config unconditionally via the trap above.
python3 - "${CONFIG}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "    avoid_dynamic_calls: true\n"
if marker not in text:
    raise SystemExit("Expected marker line not found in analysis_options.yaml")
text = text.replace(marker, marker + "    avoid_catches_without_on_clauses: true\n", 1)
path.write_text(text, encoding="utf-8")
PY

set +e
ANALYZE_OUTPUT="$(flutter analyze 2>&1)"
set -e

COUNT="$(grep -c 'avoid_catches_without_on_clauses' <<<"${ANALYZE_OUTPUT}" || true)"

echo "avoid_catches_without_on_clauses: ${COUNT} site(s) (baseline ${BASELINE})"

if [ "${COUNT}" -gt "${BASELINE}" ]; then
  echo "New catch-without-on-clause sites were added (${COUNT} > baseline ${BASELINE})." >&2
  echo "Fix them (preferred), or if this is expected mid-migration work for" >&2
  echo "T-2.3, lower BASELINE in this script with a stated reason -- never" >&2
  echo "raise it to make a number look better." >&2
  exit 1
fi
