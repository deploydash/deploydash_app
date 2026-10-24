"""Architecture invariant: source shape must not grow unchecked.

Measurement: the largest first-party Python and Dart files by
formatting-insensitive token count, plus the counts of private Widget helpers,
bare Dart catches, and tab files without a paired logic file, may not exceed
the committed baseline. The test prints the current largest files on every run
so the ratchet does not hide the shape it measures.
"""

from __future__ import annotations

import io
import json
import pathlib
import re
import tempfile
import tokenize
import unittest
from dataclasses import dataclass

_REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[3]
_BASELINE_PATH = pathlib.Path(__file__).with_name("size_shape_baseline.json")
_WIDGET_HELPER_RE = re.compile(r"\bWidget(?:\s*\?)?\s+_[A-Za-z0-9_]+\s*\(")
_BARE_CATCH_RE = re.compile(r"\bcatch\s*\(\s*_\s*\)")


@dataclass(frozen=True)
class ShapeMetrics:
    """Measured source shape, including enough detail for an actionable error."""

    top_python_files: tuple[tuple[int, str], ...]
    top_dart_files: tuple[tuple[int, str], ...]
    widget_helper_paths: tuple[str, ...]
    bare_catch_paths: tuple[str, ...]
    tabs_without_logic: tuple[str, ...]

    @property
    def top_python_tokens(self) -> int:
        return self.top_python_files[0][0] if self.top_python_files else 0

    @property
    def top_dart_tokens(self) -> int:
        return self.top_dart_files[0][0] if self.top_dart_files else 0


_IGNORED_PYTHON_TOKENS = {
    tokenize.COMMENT,
    tokenize.DEDENT,
    tokenize.ENCODING,
    tokenize.ENDMARKER,
    tokenize.INDENT,
    tokenize.NEWLINE,
    tokenize.NL,
}
_DART_OPERATOR_CHARS = frozenset("~!%^&*+=|?:<>/-")


def _python_token_count(source: str) -> int:
    """Count formatting-insensitive Python tokens, excluding comments and commas."""
    return sum(
        token.type not in _IGNORED_PYTHON_TOKENS and token.string != ","
        for token in tokenize.generate_tokens(io.StringIO(source).readline)
    )


def _consume_dart_string(source: str, start: int) -> int:
    """Return the first offset after one valid Dart string literal."""
    raw = source[start] in "rR" and start + 1 < len(source) and source[start + 1] in "'\""
    quote_start = start + 1 if raw else start
    quote = source[quote_start]
    delimiter = quote * 3 if source.startswith(quote * 3, quote_start) else quote
    offset = quote_start + len(delimiter)
    while offset < len(source):
        if source.startswith(delimiter, offset):
            return offset + len(delimiter)
        if not raw and source[offset] == "\\":
            offset += 2
        else:
            offset += 1
    return offset


def _dart_token_count(source: str) -> int:
    """Count Dart lexical units without formatting, comments, or separator commas."""
    count = 0
    offset = 0
    while offset < len(source):
        char = source[offset]
        if char.isspace() or char == ",":
            offset += 1
            continue
        if source.startswith("//", offset):
            newline = source.find("\n", offset + 2)
            offset = len(source) if newline == -1 else newline + 1
            continue
        if source.startswith("/*", offset):
            depth = 1
            offset += 2
            while offset < len(source) and depth:
                if source.startswith("/*", offset):
                    depth += 1
                    offset += 2
                elif source.startswith("*/", offset):
                    depth -= 1
                    offset += 2
                else:
                    offset += 1
            continue
        if char in "'\"" or (
            char in "rR" and offset + 1 < len(source) and source[offset + 1] in "'\""
        ):
            offset = _consume_dart_string(source, offset)
            count += 1
            continue
        if char.isalpha() or char in "_$":
            offset += 1
            while offset < len(source) and (source[offset].isalnum() or source[offset] in "_$"):
                offset += 1
            count += 1
            continue
        if char.isdigit():
            offset += 1
            while offset < len(source) and (source[offset].isalnum() or source[offset] in "._"):
                offset += 1
            count += 1
            continue
        if char in _DART_OPERATOR_CHARS:
            offset += 1
            while offset < len(source) and source[offset] in _DART_OPERATOR_CHARS:
                offset += 1
            count += 1
            continue
        count += 1
        offset += 1
    return count


def _token_count(path: pathlib.Path) -> int:
    source = path.read_text(encoding="utf-8")
    return _python_token_count(source) if path.suffix == ".py" else _dart_token_count(source)


def _rank_files(
    root: pathlib.Path, suffix: str, *, excluded_suffixes: tuple[str, ...]
) -> tuple[tuple[int, str], ...]:
    ranked = [
        (_token_count(path), path.relative_to(root.parent).as_posix())
        for path in root.rglob(f"*{suffix}")
        if not path.name.endswith(excluded_suffixes)
    ]
    return tuple(sorted(ranked, reverse=True)[:5])


def collect_shape_metrics(python_root: pathlib.Path, dart_root: pathlib.Path) -> ShapeMetrics:
    """Collect the language-neutral shape measurements for the supplied roots."""
    widget_helper_paths: list[str] = []
    bare_catch_paths: list[str] = []
    tabs_without_logic: list[str] = []
    for path in sorted(dart_root.rglob("*.dart")):
        text = path.read_text(encoding="utf-8")
        relative = path.relative_to(dart_root.parent).as_posix()
        widget_helper_paths.extend(relative for _ in _WIDGET_HELPER_RE.finditer(text))
        bare_catch_paths.extend(relative for _ in _BARE_CATCH_RE.finditer(text))
        if path.name.endswith("_tab.dart"):
            # Both spellings count. The repository writes `<name>_tab_logic.dart`
            # far more often than `<name>_logic.dart`, and recognising only the
            # latter made this metric measure a naming mismatch rather than
            # debt: T-3.3.6's services split renamed `services_logic.dart` to
            # `services_tab_logic.dart` and the tab flipped to "debt" by
            # becoming *more* decomposed. See the 2026-09-02 Discovered work
            # entry in the pre-1.0 plan.
            stem = path.name.removesuffix("_tab.dart")
            logic_candidates = [
                path.with_name(f"{stem}_tab_logic.dart"),
                path.with_name(f"{stem}_logic.dart"),
                # Extraction to `services/` also counts, and is the outcome the
                # desktop layering rule prefers when the logic is needed by a
                # provider: `backup_logic.dart` moved there so
                # `projectBackupProvider` could use it without importing
                # `lib/ui`. Recognising only siblings would score that move as
                # new debt. See the 2026-09-02 Discovered work entries.
                dart_root / "services" / f"{stem}_logic.dart",
            ]
            if not any(candidate.exists() for candidate in logic_candidates):
                tabs_without_logic.append(relative)
    return ShapeMetrics(
        top_python_files=_rank_files(python_root, ".py", excluded_suffixes=()),
        top_dart_files=_rank_files(
            dart_root,
            ".dart",
            excluded_suffixes=(".g.dart", ".freezed.dart"),
        ),
        widget_helper_paths=tuple(widget_helper_paths),
        bare_catch_paths=tuple(bare_catch_paths),
        tabs_without_logic=tuple(tabs_without_logic),
    )


def ratchet_failures(metrics: ShapeMetrics, baseline: dict[str, int]) -> list[str]:
    """Return every metric that exceeded its committed baseline."""
    measurements = {
        "top_python_tokens": metrics.top_python_tokens,
        "top_dart_tokens": metrics.top_dart_tokens,
        "widget_helper_count": len(metrics.widget_helper_paths),
        "bare_catch_count": len(metrics.bare_catch_paths),
        "tabs_without_logic_count": len(metrics.tabs_without_logic),
    }
    return [
        f"{key}: {value} exceeds baseline {baseline[key]}"
        for key, value in measurements.items()
        if value > baseline[key]
    ]


class TestSourceShapeRatchet(unittest.TestCase):
    def test_shape_does_not_exceed_the_committed_baseline(self) -> None:
        """Rule: source-shape debt may decrease, but must not increase."""
        baseline = json.loads(_BASELINE_PATH.read_text(encoding="utf-8"))
        self.assertEqual(baseline["schema_version"], 2)
        metrics = collect_shape_metrics(
            _REPOSITORY_ROOT / "orchestrator" / "src" / "orchestrator",
            _REPOSITORY_ROOT / "ui" / "lib",
        )
        print("Largest Python files by token count:", metrics.top_python_files)
        print("Largest Dart files by token count:", metrics.top_dart_files)
        self.assertEqual(
            ratchet_failures(metrics, baseline),
            [],
            "Source-shape ratchet failed; split or relocate the new debt: "
            f"helpers={metrics.widget_helper_paths}, "
            f"bare_catches={metrics.bare_catch_paths}, "
            f"tabs_without_logic={metrics.tabs_without_logic}",
        )

    def test_ratchet_rejects_a_deliberate_regression(self) -> None:
        """D2 proof: each measured debt class makes the ratchet fail."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = pathlib.Path(temporary_directory)
            python_root = temporary_root / "orchestrator"
            dart_root = temporary_root / "ui"
            python_root.mkdir()
            dart_root.mkdir()
            (python_root / "oversized.py").write_text("x = 1\n" * 3, encoding="utf-8")
            (dart_root / "oversized.dart").write_text("x\n" * 4, encoding="utf-8")
            (dart_root / "widget_helper.dart").write_text(
                "Widget _helper() => throw UnimplementedError();\n",
                encoding="utf-8",
            )
            (dart_root / "catcher.dart").write_text("try {} catch (_) {}\n", encoding="utf-8")
            (dart_root / "missing_logic_tab.dart").write_text("class Tab {}\n", encoding="utf-8")

            failures = ratchet_failures(
                collect_shape_metrics(python_root, dart_root),
                {
                    "top_python_tokens": 8,
                    "top_dart_tokens": 3,
                    "widget_helper_count": 0,
                    "bare_catch_count": 0,
                    "tabs_without_logic_count": 0,
                },
            )

        self.assertEqual(
            failures,
            [
                "top_python_tokens: 9 exceeds baseline 8",
                "top_dart_tokens: 10 exceeds baseline 3",
                "widget_helper_count: 1 exceeds baseline 0",
                "bare_catch_count: 1 exceeds baseline 0",
                "tabs_without_logic_count: 1 exceeds baseline 0",
            ],
        )

    def test_size_measurement_ignores_documentation_and_formatting(self) -> None:
        """D2 proof: documenting and formatting the same shape adds no debt."""
        compact_dart = "enum OperationMode { read, write }\n"
        documented_dart = """\
/// Lock mode for one operation.
enum OperationMode {
  /// Other operations may share this resource.
  read,

  /* Nested comments are legal in Dart. /* Keep ignoring them. */ */
  /// This operation needs exclusive access.
  write,
}
"""
        self.assertEqual(_dart_token_count(compact_dart), _dart_token_count(documented_dart))
        self.assertGreater(
            _dart_token_count("enum OperationMode { read, write, upgrade }\n"),
            _dart_token_count(compact_dart),
        )

        compact_python = "def run(value): return value\n"
        documented_python = """\
# Run one operation.
def run(
    value,
):
    # Preserve the caller's value.
    return value
"""
        self.assertEqual(
            _python_token_count(compact_python),
            _python_token_count(documented_python),
        )
        self.assertGreater(
            _python_token_count("def run(value): return transform(value)\n"),
            _python_token_count(compact_python),
        )


if __name__ == "__main__":
    unittest.main()
