"""Architecture invariant: one owner for every managed server identifier.

`server_identifiers.py` owns what a managed resource is called and
`server_paths.py` owns where it lives (T-3.4.1). This module is what makes
that ownership real rather than aspirational: without it the two modules are
files nobody is required to use, which is how `platform_versions.py` would
have gone had T-1.4.7 not repointed its callers in the same pass.

Two properties are checked, and the second matters as much as the first:

1. No module outside the two owners contains a `deploydash[_.]` string
   literal.
2. Every public name the identifier module declares has a caller. A declared
   name with no callers is a literal that was never actually routed.
"""

import ast
import pathlib
import re
import unittest

_REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SOURCE_ROOT = _REPOSITORY_ROOT / "orchestrator" / "src" / "orchestrator"

_OWNER_MODULES = ("server_identifiers.py", "server_paths.py")

# Underscore or dot only. A hyphen or slash after the brand names a helper
# binary, an image repository, or an object-storage prefix, which the owner
# module also declares but which appear inside generated shell and are
# checked by their own tests rather than by a literal scan.
_MANAGED_IDENTIFIER = re.compile(r"deploydash[_.]")


class _Exemption:
    def __init__(self, reason: str) -> None:
        self.reason = reason


# Each entry is (module, literal). Both are pinned, so a new literal in an
# already-listed module still fails.
_LITERAL_EXEMPTIONS: dict[tuple[str, str], _Exemption] = {
    ("pyinfra_runtime.py", "deploydash_action_id"): _Exemption(
        reason=(
            "A pyinfra operation keyword argument name, read back with "
            "kwargs.pop. It is consumed inside this process and never "
            "reaches a server, so it names nothing a server can own."
        ),
    ),
    ("pyinfra_runtime.py", "deploydash_setup"): _Exemption(
        reason=(
            "The name pyinfra's @deploy decorator registers this deploy "
            "under. Same reason: a process-local pyinfra identifier, not a "
            "managed resource on the server."
        ),
    ),
    ("release_helpers.py", "deploydash.exe"): _Exemption(
        reason=(
            "The Windows desktop executable produced by packaging. It is a "
            "build artifact on the developer's machine, not a resource "
            "Deploy Dash creates on a customer server."
        ),
    ),
    ("release_helpers.py", "deploydash.pdb"): _Exemption(
        reason=(
            "The debug symbol file paired with deploydash.exe, required by "
            "the Windows Store symbol upload. Same build-artifact reason."
        ),
    ),
}

_EXEMPTION_BASELINE_COUNT = 4

_STATUS_QUO_PHRASES = ("intentionally local", "workflow-specific", "for now")


def _docstring_nodes(tree: ast.Module) -> set[int]:
    """Return ids of string constants that are docstrings.

    A docstring naming an identifier is documentation, not construction --
    `server_identifiers.py`'s own docstring explains three of these values.
    """
    found = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Module | ast.ClassDef | ast.FunctionDef | ast.AsyncFunctionDef):
            continue
        body = getattr(node, "body", None)
        if not body:
            continue
        first = body[0]
        if (
            isinstance(first, ast.Expr)
            and isinstance(first.value, ast.Constant)
            and isinstance(first.value.value, str)
        ):
            found.add(id(first.value))
    return found


def collect_managed_identifier_literals(source_root: pathlib.Path) -> list[tuple[str, str, int]]:
    """Return every (module, literal, line) that constructs a managed name."""
    findings = []
    for path in sorted(source_root.rglob("*.py")):
        relative = str(path.relative_to(source_root))
        if relative in _OWNER_MODULES:
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"))
        docstrings = _docstring_nodes(tree)
        for node in ast.walk(tree):
            if not isinstance(node, ast.Constant) or not isinstance(node.value, str):
                continue
            if id(node) in docstrings:
                continue
            if _MANAGED_IDENTIFIER.search(node.value):
                findings.append((relative, node.value, node.lineno))
    return findings


class TestManagedIdentifierOwnership(unittest.TestCase):
    def test_no_module_outside_the_owners_constructs_a_managed_identifier(self) -> None:
        """Rule: a managed identifier literal has exactly one owner module."""
        violations = []
        for relative, value, line in collect_managed_identifier_literals(_SOURCE_ROOT):
            matched = None
            for (module, literal), exemption in _LITERAL_EXEMPTIONS.items():
                if module == relative and literal in value:
                    matched = exemption
                    break
            if matched is None:
                violations.append(f"{relative}:{line}: {value[:80]!r}")
        self.assertEqual(
            violations,
            [],
            "Managed identifiers must come from server_identifiers.py (names) "
            "or server_paths.py (paths): " + "; ".join(violations),
        )

    def test_every_exemption_states_why_and_the_list_only_shrinks(self) -> None:
        """Rule: an exemption names a real difference, not the status quo."""
        for (module, literal), exemption in _LITERAL_EXEMPTIONS.items():
            with self.subTest(module=module, literal=literal):
                self.assertTrue(exemption.reason.strip())
                lowered = exemption.reason.lower()
                for phrase in _STATUS_QUO_PHRASES:
                    self.assertNotIn(
                        phrase,
                        lowered,
                        "an exemption must state why the literal is not a managed "
                        "server identifier, not that it is currently written here",
                    )
        self.assertLessEqual(
            len(_LITERAL_EXEMPTIONS),
            _EXEMPTION_BASELINE_COUNT,
            "managed-identifier exemption count grew; route the literal instead",
        )

    def test_every_exemption_still_matches_a_real_literal(self) -> None:
        """Rule: an exemption for a literal that no longer exists is stale."""
        observed = {
            (relative, value)
            for relative, value, _ in collect_managed_identifier_literals(_SOURCE_ROOT)
        }
        for module, literal in _LITERAL_EXEMPTIONS:
            with self.subTest(module=module, literal=literal):
                self.assertTrue(
                    any(source == module and literal in value for source, value in observed),
                    f"{module} no longer contains {literal!r}; remove the exemption",
                )

    def test_every_declared_identifier_has_a_caller(self) -> None:
        """Rule: the owner module is used, not merely available.

        This is the failure T-3.4.2 exists to prevent. A declared name with
        no caller means the literal it was written for is still inline
        somewhere, and the module is decoration.
        """
        owner = _SOURCE_ROOT / "server_identifiers.py"
        declared = ast.literal_eval(
            next(
                node.value
                for node in ast.parse(owner.read_text(encoding="utf-8")).body
                if isinstance(node, ast.Assign)
                and any(
                    isinstance(target, ast.Name) and target.id == "__all__"
                    for target in node.targets
                )
            )
        )
        self.assertGreater(len(declared), 30)

        sources = [
            path.read_text(encoding="utf-8")
            for path in sorted(_SOURCE_ROOT.rglob("*.py"))
            if path.name != "server_identifiers.py"
        ]
        uncalled = []
        for name in declared:
            if name == "safe_segment":
                # Called through server_paths._segment, which is itself the
                # only caller; covered by the server_paths tests instead.
                continue
            pattern = re.compile(rf"\b{re.escape(name)}\b")
            if not any(pattern.search(text) for text in sources):
                uncalled.append(name)
        self.assertEqual(
            uncalled,
            [],
            "server_identifiers declares names nothing calls, so the literals "
            f"they replace are still inline: {uncalled}",
        )


if __name__ == "__main__":
    unittest.main()
