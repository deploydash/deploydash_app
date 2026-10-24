import importlib.util
import io
import runpy
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

_REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
_HELPER_PATH = _REPOSITORY_ROOT / "scripts" / "coverage_gate_symbols.py"


def _load_helper():
    spec = importlib.util.spec_from_file_location("coverage_gate_symbols", _HELPER_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CoverageGateSymbolsTest(unittest.TestCase):
    def test_resolves_nested_python_symbols_and_filters_coverage_lines(self):
        helper = _load_helper()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "sample.py"
            source.write_text(
                "class Outer:\n"
                "    async def inner(self):\n"
                "        return 1\n\n"
                "def outer():\n"
                "    return 2\n",
                encoding="utf-8",
            )

            spans = helper.resolve_python_symbol_spans(
                source,
                ("Outer.inner", "outer"),
            )
            selected = helper.covered_lines_in_spans(
                source,
                ("Outer.inner",),
                range(1, 10),
                language="python",
            )

        self.assertLess(spans["Outer.inner"][0], spans["outer"][0])
        self.assertIn(spans["Outer.inner"][0], selected)
        self.assertNotIn(spans["outer"][0], selected)

    def test_missing_python_symbol_fails_loudly(self):
        helper = _load_helper()

        with self.assertRaisesRegex(
            helper.CoverageGateDefinitionError,
            "missing coverage-gate symbol: does_not_exist",
        ):
            helper.resolve_python_symbol_spans(
                _REPOSITORY_ROOT / "orchestrator/src/orchestrator/engine.py",
                ("does_not_exist",),
            )

    def test_resolves_nested_dart_anchors_and_filters_coverage_lines(self):
        helper = _load_helper()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "sample.dart"
            source.write_text(
                "// coverage-gate: outer\n"
                "void outer() {\n"
                "  // coverage-gate: inner\n"
                "  void inner() {}\n"
                "  // end coverage-gate\n"
                "}\n"
                "// end coverage-gate\n",
                encoding="utf-8",
            )

            spans = helper.resolve_dart_anchor_spans(source, ("outer", "inner"))
            selected = helper.covered_lines_in_spans(
                source,
                ("inner",),
                range(1, 10),
                language="dart",
            )

        self.assertLessEqual(spans["outer"][0], spans["inner"][0])
        self.assertIn(spans["inner"][0], selected)
        self.assertNotIn(spans["outer"][0], selected)

    def test_resolves_python_anchors_and_filters_coverage_lines(self):
        helper = _load_helper()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "sample.py"
            source.write_text(
                "# coverage-gate: outer\n"
                "def outer():\n"
                "    # coverage-gate: inner\n"
                "    def inner():\n"
                "        pass\n"
                "    # end coverage-gate\n"
                "    return inner\n"
                "# end coverage-gate\n",
                encoding="utf-8",
            )

            spans = helper.resolve_python_anchor_spans(source, ("outer", "inner"))

        self.assertLessEqual(spans["outer"][0], spans["inner"][0])
        self.assertEqual(spans["inner"], (4, 5))
        self.assertEqual(spans["outer"], (2, 7))

    def test_missing_python_anchor_fails_loudly(self):
        helper = _load_helper()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "sample.py"
            source.write_text(
                "# coverage-gate: present\ndef present():\n    pass\n# end coverage-gate\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                helper.CoverageGateDefinitionError,
                "missing coverage-gate symbol: does_not_exist",
            ):
                helper.resolve_python_anchor_spans(source, ("does_not_exist",))

    def test_rejects_malformed_python_anchors(self):
        helper = _load_helper()
        cases = (
            ("# end coverage-gate\n", "end coverage-gate without a start"),
            (
                "# coverage-gate: empty\n# end coverage-gate\n",
                "empty coverage-gate anchor: empty",
            ),
            ("# coverage-gate: unclosed\ndef f():\n    pass\n", "missing end coverage-gate"),
            (
                "# coverage-gate: repeated\n"
                "FIRST = 1\n"
                "# end coverage-gate\n"
                "# coverage-gate: repeated\n"
                "SECOND = 2\n"
                "# end coverage-gate\n",
                "duplicate coverage-gate anchor: repeated",
            ),
        )
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "sample.py"
            for content, error_message in cases:
                source.write_text(content, encoding="utf-8")
                with self.assertRaisesRegex(
                    helper.CoverageGateDefinitionError,
                    error_message,
                ):
                    helper.resolve_python_anchor_spans(source, ())

    def test_python_anchor_gate_naming_a_file_that_moved_fails_as_a_gate_error(self):
        helper = _load_helper()
        missing = _REPOSITORY_ROOT / "orchestrator/src/orchestrator/does_not_exist.py"

        with self.assertRaisesRegex(
            helper.CoverageGateDefinitionError,
            "coverage-gate source file does not exist",
        ):
            helper.resolve_python_anchor_spans(missing, ("anything",))

    def test_uncovered_arcs_touching_spans_reports_boundary_arcs(self):
        helper = _load_helper()
        spans = {"region": (10, 20)}

        touching = helper.uncovered_arcs_touching_spans(
            spans,
            [(5, 12), (10, 11), (15, 25), (30, 40), (18, -1)],
        )

        # Arcs entering, inside, leaving, or exiting the span all touch it.
        # (18, -1) qualifies through its in-span source; the -1 exit marker
        # alone never matches, and (30, 40) is fully outside.
        self.assertEqual(touching, [(5, 12), (10, 11), (15, 25), (18, -1)])

    def test_uncovered_arcs_touching_spans_ignores_outside_arcs(self):
        helper = _load_helper()

        self.assertEqual(
            helper.uncovered_arcs_touching_spans({"region": (10, 20)}, [(1, 2), (30, 40)]),
            [],
        )

    def test_missing_dart_anchor_fails_loudly(self):
        helper = _load_helper()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "sample.dart"
            source.write_text(
                "// coverage-gate: present\nvoid present() {}\n// end coverage-gate\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                helper.CoverageGateDefinitionError,
                "missing coverage-gate symbol: does_not_exist",
            ):
                helper.resolve_dart_anchor_spans(source, ("does_not_exist",))

    def test_rejects_malformed_dart_anchors(self):
        helper = _load_helper()
        cases = (
            ("// end coverage-gate\n", "end coverage-gate without a start"),
            (
                "// coverage-gate: empty\n// end coverage-gate\n",
                "empty coverage-gate anchor: empty",
            ),
            ("// coverage-gate: unclosed\nvoid f() {}\n", "missing end coverage-gate"),
            (
                "// coverage-gate: repeated\n"
                "void first() {}\n"
                "// end coverage-gate\n"
                "// coverage-gate: repeated\n"
                "void second() {}\n"
                "// end coverage-gate\n",
                "duplicate coverage-gate anchor: repeated",
            ),
        )
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "sample.dart"
            for content, error_message in cases:
                source.write_text(content, encoding="utf-8")
                with self.assertRaisesRegex(
                    helper.CoverageGateDefinitionError,
                    error_message,
                ):
                    helper.resolve_dart_anchor_spans(source, ())

    def test_a_gate_naming_a_file_that_moved_fails_as_a_gate_error(self):
        # The failure this actually produces: a gate keeps naming a source
        # file after a rename or a split, and the resolver raises
        # FileNotFoundError -- which is not a CoverageGateDefinitionError, so
        # every caller that catches the gate error lets it out as a raw
        # traceback. `project_server_scope_coverage.sh` was red that way from
        # T-3.1.5 until it was noticed, because the traceback did not look
        # like a gate failure.
        helper = _load_helper()
        missing = _REPOSITORY_ROOT / "ui/lib/does_not_exist.dart"

        for language, resolve in (
            ("dart", helper.resolve_dart_anchor_spans),
            ("python", helper.resolve_python_symbol_spans),
        ):
            with (
                self.subTest(language=language),
                self.assertRaisesRegex(
                    helper.CoverageGateDefinitionError,
                    "coverage-gate source file does not exist",
                ),
            ):
                resolve(missing, ("anything",))

    def test_main_reports_a_missing_source_file_rather_than_crashing(self):
        helper = _load_helper()
        missing = _REPOSITORY_ROOT / "ui/lib/does_not_exist.dart"
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            status = helper.main(["dart", str(missing), "anything"])

        self.assertEqual(1, status)
        self.assertIn("coverage-gate source file does not exist", stderr.getvalue())

    def test_rejects_unknown_coverage_gate_language(self):
        helper = _load_helper()
        with self.assertRaisesRegex(ValueError, "Unsupported coverage-gate language"):
            helper.covered_lines_in_spans(
                _HELPER_PATH,
                (),
                (),
                language="rust",
            )

    def test_main_reports_spans_and_missing_symbols(self):
        helper = _load_helper()
        source = _REPOSITORY_ROOT / "orchestrator/src/orchestrator/infra_parts/tooling.py"
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            status = helper.main(["python", str(source), "_tooling_component"])
        self.assertEqual(0, status)
        self.assertIn("::_tooling_component", stdout.getvalue())

        stderr = io.StringIO()
        with redirect_stderr(stderr):
            status = helper.main(["dart", str(source), "does_not_exist"])
        self.assertEqual(1, status)
        self.assertIn("missing coverage-gate symbol: does_not_exist", stderr.getvalue())

    def test_module_entrypoint_exits_with_main_result(self):
        source = _REPOSITORY_ROOT / "orchestrator/src/orchestrator/infra_parts/tooling.py"
        stdout = io.StringIO()
        with (
            mock.patch.object(
                sys,
                "argv",
                [str(_HELPER_PATH), "python", str(source), "_tooling_component"],
            ),
            redirect_stdout(stdout),
            self.assertRaises(SystemExit) as raised,
        ):
            runpy.run_path(str(_HELPER_PATH), run_name="__main__")
        self.assertEqual(0, raised.exception.code)
        self.assertIn("::_tooling_component", stdout.getvalue())
