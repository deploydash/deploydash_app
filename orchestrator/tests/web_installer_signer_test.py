"""The web-installer signer check accepts Microsoft in any DN spelling.

v1.1.1 proved the check was format-locked: it expected osslsigncode
to print ``CN=Microsoft Corporation,...`` but the runner's
osslsigncode printed openssl-oneline form
(``/C=US/.../O=Microsoft Corporation/CN=Microsoft Corporation``),
so a genuine Microsoft stub was rejected, the installer never
attached, and the publish tick failed after flipping the draft.
osslsigncode is apt-installed unpinned, so its rendering is not a
contract — the check canonicalizes both spellings instead.

Rule (deliberate, documented here so a future tightener knows):
a full DN component exactly ``O=Microsoft Corporation`` or
``CN=Microsoft Corporation`` accepts. Exact components only:
the old prefix match would have accepted
``CN=Microsoft Corporation Evil``; the new check must not.
"""

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "ui" / "scripts" / "store_fetch_web_installer.sh"

# The exact signer line osslsigncode printed for the genuine stub in
# the failed v1.1.1 publish tick (run 41267731300).
ONELINE_MS = "/C=US/ST=Washington/L=Redmond/O=Microsoft Corporation/CN=Microsoft Corporation"
# The same DN the way the script used to expect it (v1.1.0 shape).
RFC2253_MS = "CN=Microsoft Corporation,O=Microsoft Corporation,L=Redmond,ST=Washington,C=US"

DRIVER = r"""
source "$FETCH_SCRIPT"
result() { printf '%s=%s\n' "$1" "$2"; }
if signer_is_microsoft "$FIX_ONELINE"; then result oneline accept; else result oneline reject; fi
if signer_is_microsoft "$FIX_RFC2253"; then result rfc2253 accept; else result rfc2253 reject; fi
if signer_is_microsoft "$FIX_CN_ONLY_EVIL_O"; then result cn_only accept; else result cn_only reject; fi
if signer_is_microsoft "$FIX_PREFIX_ATTACK"; then result prefix_attack accept; else result prefix_attack reject; fi
if signer_is_microsoft "$FIX_SUFFIX_ATTACK"; then result suffix_attack accept; else result suffix_attack reject; fi
if signer_is_microsoft "$FIX_OU_ONLY"; then result ou_only accept; else result ou_only reject; fi
if signer_is_microsoft "$FIX_EVIL"; then result evil accept; else result evil reject; fi
if signer_is_microsoft ""; then result empty accept; else result empty reject; fi
if [[ "$(canon_dn "$FIX_ONELINE")" == "$(canon_dn "$FIX_RFC2253")" ]]; then result canon_equal yes; else result canon_equal no; fi
"""

EXPECTED = {
    "oneline": "accept",
    "rfc2253": "accept",
    # Either anchor component suffices (documented OR rule).
    "cn_only": "accept",
    # Prefix/suffix lookalikes must not pass (old code passed prefix).
    "prefix_attack": "reject",
    "suffix_attack": "reject",
    "ou_only": "reject",
    "evil": "reject",
    "empty": "reject",
    # Leaf matching compares canonical forms, so either spelling
    # finds the embedded signer cert.
    "canon_equal": "yes",
}


class WebInstallerSignerTest(unittest.TestCase):
    def test_signer_check_accepts_microsoft_in_either_dn_spelling(self) -> None:
        env = {
            "FETCH_SCRIPT": str(SCRIPT),
            "FIX_ONELINE": ONELINE_MS,
            "FIX_RFC2253": RFC2253_MS,
            "FIX_CN_ONLY_EVIL_O": "CN=Microsoft Corporation,O=Evil Corp,C=US",
            "FIX_PREFIX_ATTACK": "CN=Microsoft Corporation Evil,O=Evil Corp,C=US",
            "FIX_SUFFIX_ATTACK": "/C=US/O=Microsoft CorporationX/CN=Evil",
            "FIX_OU_ONLY": "CN=Evil,OU=Microsoft Corporation,O=Evil,C=US",
            "FIX_EVIL": "CN=Evil Corp,O=Evil Corp,C=US",
        }
        completed = subprocess.run(
            ["bash", "-c", DRIVER],
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        self.assertEqual(
            completed.returncode,
            0,
            f"sourcing the fetch script must define working helpers: {completed.stderr}",
        )
        observed = dict(line.split("=", 1) for line in completed.stdout.splitlines() if "=" in line)
        self.assertEqual(observed, EXPECTED)


if __name__ == "__main__":
    unittest.main()
