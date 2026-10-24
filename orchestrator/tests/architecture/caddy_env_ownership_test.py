"""Architecture invariant: HTTP setup never writes caddy/.env content.

Measurement: every ``caddy/.env`` (or ``caddy_env_file_path``) mention in
first-party backend source whose preceding lines register a pyinfra
content-writing file operation (``files.put`` / ``files.template``).

App deploys merge each project's DNS-challenge credentials into that file
(``app_parts/part1_deploy.py::_build_caddy_env_sync_command``) and undeploy
strips them back out (``app_runtime_parts/runtime_operations.py``); both
work through shell variables, never a content-writing pyinfra operation, so
they are invisible to this scan by construction. HTTP part 1 used to
``files.put`` an empty file on every configure and setup re-run, wiping
every project's credentials and taking down every site on DNS-challenge
servers (#120). It may only ``files.file`` the path (ensure it exists,
enforce the mode).

Boundary, stated so the guard cannot be misread as wider than it is: the
scan sees pyinfra content writers near an env-file mention. It does not see
shell redirections through variables -- those are the two reviewed app-side
commands above, and a new one would need its own review, not this regex.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

_SRC_ROOT = Path(__file__).resolve().parents[2] / "src" / "orchestrator"

_ENV_MENTION = re.compile(r"caddy/\.env|caddy_env_file_path")
_CONTENT_WRITERS = ("files.put", "files.template")

# A pyinfra file operation registers as add_operation(files.<op>, ...) with
# the destination a couple of lines below the operation name, so a writer
# for the env file always sits within three lines above the mention.
_LOOKBACK_LINES = 3


def _env_content_write_sites(source_path):
    """Return 1-based line numbers writing caddy/.env content in a file."""
    lines = source_path.read_text(encoding="utf-8").splitlines()
    sites = []
    for index, line in enumerate(lines):
        if not _ENV_MENTION.search(line):
            continue
        window = "\n".join(lines[max(0, index - _LOOKBACK_LINES) : index + 1])
        if any(writer in window for writer in _CONTENT_WRITERS):
            sites.append(index + 1)
    return sites


class TestCaddyEnvOwnershipGuard(unittest.TestCase):
    def test_no_pyinfra_content_write_targets_caddy_env(self):
        """No files.put/template writes caddy/.env; the app sync owns it."""
        sites = {}
        for source_path in sorted(_SRC_ROOT.rglob("*.py")):
            found = _env_content_write_sites(source_path)
            if found:
                sites[str(source_path.relative_to(_SRC_ROOT))] = found
        self.assertEqual(
            sites,
            {},
            "caddy/.env content has a pyinfra writer again; only the app "
            "env-sync command may write it (#120).",
        )
