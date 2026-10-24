"""Architecture invariant: module-global rebindings stay finite and runtime-owned.

Measurement: every ``global`` statement in first-party backend source is
reported with its module and variable name.  This catches the dependency-slot
pattern removed by T-2.2 before it can be reintroduced under a new spelling.
"""

from __future__ import annotations

import ast
import pathlib
import tempfile
import unittest
from dataclasses import dataclass

_BACKEND_ROOT = pathlib.Path(__file__).resolve().parents[2]
_SOURCE_ROOT = _BACKEND_ROOT / "src" / "orchestrator"


@dataclass(frozen=True)
class _GlobalRebindingExemption:
    reason: str


_GLOBAL_REBINDING_EXEMPTIONS = {
    ("api.py", "_DEFAULT_RUNTIME"): _GlobalRebindingExemption(
        "The compatibility ingress owns the one process-default EngineRuntime."
    ),
    ("embedded_runtime.py", "_process_hardening_configured"): _GlobalRebindingExemption(
        "The embedded host needs an idempotency guard for process-wide hardening."
    ),
    ("embedded_runtime.py", "_windows_dll_directory_handles"): _GlobalRebindingExemption(
        "Windows DLL-directory handles must remain live for the process lifetime."
    ),
    ("task_runtime.py", "_next_task_id"): _GlobalRebindingExemption(
        "The process-local task runtime owns its monotonic task identifier sequence."
    ),
}


def _global_rebindings(source_root: pathlib.Path) -> set[tuple[str, str]]:
    rebindings: set[tuple[str, str]] = set()
    for source_path in source_root.rglob("*.py"):
        module = source_path.relative_to(source_root).as_posix()
        tree = ast.parse(source_path.read_text(encoding="utf-8"), filename=str(source_path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Global):
                rebindings.update((module, name) for name in node.names)
    return rebindings


class TestGlobalMutableState(unittest.TestCase):
    def test_module_global_rebindings_are_runtime_owned(self) -> None:
        """Rule: no new mutable module-global state appears in backend source."""
        observed = _global_rebindings(_SOURCE_ROOT)
        self.assertEqual(set(_GLOBAL_REBINDING_EXEMPTIONS), observed)
        for exemption in _GLOBAL_REBINDING_EXEMPTIONS.values():
            self.assertTrue(exemption.reason.strip())

    def test_scanner_detects_a_new_global_rebinding(self) -> None:
        """D2 proof: a new module global has a concrete, observable failure shape."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            source_root = pathlib.Path(temporary_directory)
            (source_root / "new_global.py").write_text(
                "_runtime = None\n\ndef replace_runtime():\n    global _runtime\n    _runtime = object()\n",
                encoding="utf-8",
            )
            self.assertEqual(_global_rebindings(source_root), {("new_global.py", "_runtime")})


if __name__ == "__main__":
    unittest.main()
