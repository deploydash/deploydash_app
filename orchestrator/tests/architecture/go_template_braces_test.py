"""Architecture invariant: docker Go templates in f-strings stay doubled.

Measurement: every first-party Python file under ``orchestrator/src`` is
scanned for f-string lines that render a single-brace Go template
(``{.Field}``). Docker prints such a template literally with rc=0 instead
of failing, so the bug hides behind a successful probe: #86's
container-image probe read back its own template text, the major parse
failed, and the fail-closed guard refused every configure. The scripted
unit tests never saw it because the fake host matched the command by
substring and returned a canned image line.

Failure: the offending file and line number are named. Write ``{{{{`` in
the f-string source so the rendered command carries ``{{``, matching the
container-status builders.
"""

from __future__ import annotations

import pathlib
import unittest

_SRC_ROOT = pathlib.Path(__file__).resolve().parents[2] / "src"
_SELF = pathlib.Path(__file__).resolve().name


def _line_renders_single_brace_template(line: str) -> bool:
    """Why: the detector, shared by the scan and its self-check."""
    if "f'" not in line and 'f"' not in line and "F'" not in line and 'F"' not in line:
        return False
    scrubbed = line.replace("{{{{", "").replace("}}}}", "")
    return "{{." in scrubbed


def _single_brace_violations(root: pathlib.Path) -> list[str]:
    """Why: the scan, so the self-check can run it against fixtures."""
    violations = []
    for path in sorted(root.rglob("*.py")):
        if path.name == _SELF:
            # This file's docstring and fixtures quote the broken shape on
            # purpose; scanning them would flag the guard itself.
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if _line_renders_single_brace_template(line):
                violations.append(f"{path}:{lineno}: {line.strip()}")
    return violations


class GoTemplateBracesTest(unittest.TestCase):
    def test_no_single_brace_go_template_in_f_strings(self):
        violations = _single_brace_violations(_SRC_ROOT)
        self.assertEqual(violations, [])

    def test_the_check_can_see_a_violation(self):
        self.assertTrue(
            _line_renders_single_brace_template(
                "return f\"docker inspect -f '{{.Config.Image}}' {name}\"",
            )
        )
        self.assertFalse(
            _line_renders_single_brace_template(
                "return f\"docker inspect -f '{{{{.Config.Image}}}}' {name}\"",
            )
        )
        self.assertFalse(
            _line_renders_single_brace_template(
                '"RUNNING=\\"$(docker inspect -f \'{{.State.Running}}\' "',
            )
        )


if __name__ == "__main__":
    unittest.main()
