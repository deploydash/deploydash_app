"""Resolve durable source spans for scoped coverage gates.

Coverage reports identify executed source by line number, but a numeric range
is not a stable identity.  Python gates name definitions and resolve them from
the AST; Dart gates use explicit, checked source anchors because the standard
library offers no Dart parser.
"""

from __future__ import annotations

import argparse
import ast
import re
import sys
from collections.abc import Iterable
from pathlib import Path


class CoverageGateDefinitionError(ValueError):
    """A coverage gate points at source that no longer has its named anchor."""


_DART_START = re.compile(r"^\s*//\s*coverage-gate:\s*([^\s]+)\s*$")
_DART_END = re.compile(r"^\s*//\s*end coverage-gate\s*$")
_PY_START = re.compile(r"^\s*#\s*coverage-gate:\s*([^\s]+)\s*$")
_PY_END = re.compile(r"^\s*#\s*end coverage-gate\s*$")


def _read_gate_source(source_path: Path) -> str:
    """Read [source_path], reporting an absent file as a gate definition error.

    A gate outliving the file it names is an ordinary event: a rename, a split
    into `part` files, a move between directories.  Letting the resulting
    `FileNotFoundError` escape makes that arrive as a raw traceback rather than
    as the gate failure it is, and every caller here catches
    `CoverageGateDefinitionError` only -- so the gate reads as *crashed*, not
    as *failed*, and a crashed gate is easy to leave broken.  That is exactly
    how `project_server_scope_coverage.sh` stayed red from T-3.1.5 without
    anyone reading it as a coverage regression.
    """

    try:
        return source_path.read_text(encoding="utf-8")
    except FileNotFoundError as error:
        raise CoverageGateDefinitionError(
            f"coverage-gate source file does not exist: {source_path}"
        ) from error


def resolve_python_symbol_spans(
    source_path: Path,
    symbols: Iterable[str],
) -> dict[str, tuple[int, int]]:
    """Return inclusive line spans for fully-qualified Python definitions."""

    tree = ast.parse(_read_gate_source(source_path), filename=str(source_path))
    available: dict[str, tuple[int, int]] = {}

    def visit(body: list[ast.stmt], prefix: str = "") -> None:
        for node in body:
            if not isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            name = f"{prefix}{node.name}"
            available[name] = (node.lineno, node.end_lineno or node.lineno)
            visit(node.body, f"{name}.")

    visit(tree.body)
    return _select_named_spans(source_path, tuple(symbols), available)


def resolve_dart_anchor_spans(
    source_path: Path,
    anchors: Iterable[str],
) -> dict[str, tuple[int, int]]:
    """Return inclusive spans delimited by named Dart coverage-gate comments."""

    return _resolve_anchor_spans(source_path, anchors, _DART_START, _DART_END)


def resolve_python_anchor_spans(
    source_path: Path,
    anchors: Iterable[str],
) -> dict[str, tuple[int, int]]:
    """Return inclusive spans delimited by named Python coverage-gate comments.

    Symbol spans cover whole definitions; anchors pin a changed region inside
    a shared handler so a gate can hold new lines and branches without
    absorbing the handler's older debt.
    """

    return _resolve_anchor_spans(source_path, anchors, _PY_START, _PY_END)


def uncovered_arcs_touching_spans(
    spans: dict[str, tuple[int, int]],
    missing_branches: Iterable[Iterable[int]],
) -> list[tuple[int, int]]:
    """Return the missing arcs that start or land inside any span.

    A branch whose condition sits inside an anchored region but whose jump
    lands outside it (or the reverse) still exercises anchored behavior, so
    either endpoint qualifies. Coverage.py marks function exits with
    negative targets, which never match a span alone.
    """

    touching: list[tuple[int, int]] = []
    for arc in missing_branches:
        endpoints = tuple(arc)
        if len(endpoints) != 2:
            continue
        start, end = endpoints
        for span_start, span_end in spans.values():
            if span_start <= start <= span_end or span_start <= end <= span_end:
                touching.append((start, end))
                break
    return touching


def _resolve_anchor_spans(
    source_path: Path,
    anchors: Iterable[str],
    start_pattern: re.Pattern[str],
    end_pattern: re.Pattern[str],
) -> dict[str, tuple[int, int]]:
    """Collect named comment-delimited spans; Dart and Python share it."""

    available: dict[str, tuple[int, int]] = {}
    active: list[tuple[str, int]] = []
    for line_number, line in enumerate(
        _read_gate_source(source_path).splitlines(),
        start=1,
    ):
        start_match = start_pattern.match(line)
        if start_match:
            name = start_match.group(1)
            if name in available or any(active_name == name for active_name, _ in active):
                raise CoverageGateDefinitionError(
                    f"duplicate coverage-gate anchor: {name} in {source_path}"
                )
            active.append((name, line_number + 1))
            continue
        if not end_pattern.match(line):
            continue
        if not active:
            raise CoverageGateDefinitionError(
                f"end coverage-gate without a start marker in {source_path}"
            )
        active_name, active_start = active.pop()
        if active_start > line_number - 1:
            raise CoverageGateDefinitionError(
                f"empty coverage-gate anchor: {active_name} in {source_path}"
            )
        available[active_name] = (active_start, line_number - 1)
    if active:
        active_name, _ = active[-1]
        raise CoverageGateDefinitionError(
            f"missing end coverage-gate marker: {active_name} in {source_path}"
        )
    return _select_named_spans(source_path, tuple(anchors), available)


def covered_lines_in_spans(
    source_path: Path,
    names: Iterable[str],
    executable_lines: Iterable[int],
    *,
    language: str,
) -> set[int]:
    """Select the reported executable lines within named source spans."""

    if language == "python":
        spans = resolve_python_symbol_spans(source_path, names)
    elif language == "dart":
        spans = resolve_dart_anchor_spans(source_path, names)
    else:
        raise ValueError(f"Unsupported coverage-gate language: {language}")
    return {
        line
        for line in executable_lines
        if any(start <= line <= end for start, end in spans.values())
    }


def _select_named_spans(
    source_path: Path,
    names: tuple[str, ...],
    available: dict[str, tuple[int, int]],
) -> dict[str, tuple[int, int]]:
    selected: dict[str, tuple[int, int]] = {}
    for name in names:
        span = available.get(name)
        if span is None:
            raise CoverageGateDefinitionError(
                f"missing coverage-gate symbol: {name} in {source_path}"
            )
        selected[name] = span
    return selected


def main(argv: list[str] | None = None) -> int:
    """Resolve named gate spans for the missing-symbol guard verification."""

    parser = argparse.ArgumentParser()
    parser.add_argument("language", choices=("python", "dart"))
    parser.add_argument("source_path", type=Path)
    parser.add_argument("names", nargs="+")
    args = parser.parse_args(argv)
    try:
        if args.language == "python":
            spans = resolve_python_symbol_spans(args.source_path, args.names)
        else:
            spans = resolve_dart_anchor_spans(args.source_path, args.names)
    except CoverageGateDefinitionError as error:
        print(error, file=sys.stderr)
        return 1
    for name, (start, end) in spans.items():
        print(f"{args.source_path}::{name} {start}-{end}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
