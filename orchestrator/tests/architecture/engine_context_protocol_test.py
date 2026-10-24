"""T-3.3.5 guards for the narrow engine dependency interfaces."""

import ast
import unittest
from pathlib import Path

from orchestrator.engine_context import ENGINE_CONTEXT_PROTOCOLS
from tests.engine_context_fixtures import build_test_context

_BACKEND_ROOT = Path(__file__).resolve().parents[2] / "src" / "orchestrator"
_ENGINE_CONTEXT_ANNOTATION_EXCEPTIONS = {
    Path("engine.py"),
    Path("engine_bootstrap.py"),
}


def _engine_context_parameter_locations() -> set[tuple[Path, int]]:
    locations: set[tuple[Path, int]] = set()
    for source_path in _BACKEND_ROOT.rglob("*.py"):
        relative_path = source_path.relative_to(_BACKEND_ROOT)
        tree = ast.parse(source_path.read_text(encoding="utf-8"), filename=str(source_path))
        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            arguments = (*node.args.posonlyargs, *node.args.args, *node.args.kwonlyargs)
            if any(
                isinstance(argument.annotation, ast.Name)
                and argument.annotation.id == "EngineContext"
                for argument in arguments
            ):
                locations.add((relative_path, node.lineno))
    return locations


def _protocol_broad_callable_locations() -> set[tuple[str, int]]:
    engine_context_path = _BACKEND_ROOT / "engine_context.py"
    tree = ast.parse(
        engine_context_path.read_text(encoding="utf-8"), filename=str(engine_context_path)
    )
    protocol_names = {protocol.__name__ for protocol in ENGINE_CONTEXT_PROTOCOLS}
    locations: set[tuple[str, int]] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.ClassDef) or node.name not in protocol_names:
            continue
        for annotation in ast.walk(node):
            if not isinstance(annotation, ast.Subscript):
                continue
            if not isinstance(annotation.value, ast.Name) or annotation.value.id != "Callable":
                continue
            if not isinstance(annotation.slice, ast.Tuple) or not annotation.slice.elts:
                continue
            if (
                isinstance(annotation.slice.elts[0], ast.Constant)
                and annotation.slice.elts[0].value is Ellipsis
            ):
                locations.add((node.name, annotation.lineno))
    return locations


class TestEngineContextProtocols(unittest.TestCase):
    def test_concrete_context_satisfies_every_consumer_protocol(self):
        context = build_test_context()

        self.assertEqual(len(ENGINE_CONTEXT_PROTOCOLS), 14)
        for protocol in ENGINE_CONTEXT_PROTOCOLS:
            with self.subTest(protocol=protocol.__name__):
                self.assertIsInstance(context, protocol)

    def test_only_engine_bootstrap_boundaries_annotate_engine_context(self):
        locations = _engine_context_parameter_locations()

        annotated_modules = {relative_path for relative_path, _line in locations}
        self.assertFalse(
            annotated_modules - _ENGINE_CONTEXT_ANNOTATION_EXCEPTIONS,
            f"EngineContext escaped its construction boundaries: {sorted(annotated_modules)}",
        )
        self.assertIn(Path("engine_bootstrap.py"), annotated_modules)

    def test_protocols_do_not_reintroduce_broad_callable_annotations(self):
        self.assertEqual(_protocol_broad_callable_locations(), set())


if __name__ == "__main__":
    unittest.main()
