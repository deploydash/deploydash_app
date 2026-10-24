#!/usr/bin/env python3
"""T-3.7.3: stop the postfix `!` count growing while the audit works it down.

The Flutter rule is "avoid `!` unless the value is guaranteed to be
non-null". There is no analyzer lint for it -- `unnecessary_non_null_assertion`
only flags an `!` on an already-non-nullable expression -- so this counts the
sites directly and fails when the total rises.

It is a debt register, not a suppression. Lower BASELINE as sites are fixed;
never raise it to make a number look better.

Counting rules, and why each is needed:

* Comments and string literals are stripped, so a `!` inside either is not a
  site. Code inside a `${...}` interpolation is kept, because it is real Dart
  and can carry a real assertion.
* `a != b` is excluded, obviously.
* `x is! Foo` is excluded: that `!` belongs to the negated type test. Counting
  it inflated the first measurement of this task by 72 sites.
* A prefix `!` after a keyword -- `return !ready`, `case !x` -- is excluded for
  the same reason. That accounted for another 2.
* Generated Dart (`*.g.dart`, `*.freezed.dart`) is excluded: it is not
  hand-written, so it is not anybody's to fix.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Measured 2026-09-05 against HEAD as 249 across 63 files, then worked down.
# The pre-existing plan figure of "~300 across 69 files" counted `is!` and
# prefix `!` as assertions; this is the same tree measured correctly.
#
# The eight that remain are all deliberate, and each carries a comment saying
# which invariant it is asserting:
#
#   data/local/project_deletion_recovery_repository.dart  x2  read-after-write
#   ui/navigation/desktop_route.dart                      x2  route `location`
#   ui/server/management/updates_tab.dart                 x2  server is loaded
#   providers/agent_access/tools/redeploy.dart            x1  preview resolved
#   ui/server/management/system_tab.dart                  x1  result is failure
#
# Each is a type that cannot express the invariant, not a promotion failure.
# Fixing the last of them means changing those types -- making
# `SshKeyReplacementResult` a sealed hierarchy, for instance -- which is
# recorded under Discovered work rather than done inside this task.
BASELINE = 8

IDENT_END = set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$)]"
)
# `is` is the negated type test; the rest are keywords a *prefix* `!` follows.
KEYWORDS_BEFORE_PREFIX_BANG = re.compile(
    r"(?:^|[^A-Za-z0-9_$])"
    r"(?:is|return|case|in|else|await|yield|throw|when|do)\s*$"
)


def strip_comments_and_strings(source: str) -> str:
    """Blank out comments and string bodies, keeping interpolated code."""
    out: list[str] = []
    i = 0
    n = len(source)
    while i < n:
        ch = source[i]
        if ch == "/" and source.startswith("//", i):
            while i < n and source[i] != "\n":
                i += 1
            continue
        if ch == "/" and source.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth:
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            out.append(" ")
            continue
        raw = ch == "r" and i + 1 < n and source[i + 1] in "\"'"
        if raw:
            i += 1
            ch = source[i]
        if ch in "\"'":
            quote = ch
            triple = source.startswith(quote * 3, i)
            delim = quote * 3 if triple else quote
            i += len(delim)
            out.append("''")
            while i < n:
                if not raw and source[i] == "\\":
                    i += 2
                    continue
                if source.startswith(delim, i):
                    i += len(delim)
                    break
                if not raw and source.startswith("${", i):
                    i += 2
                    depth = 1
                    start = i
                    while i < n and depth:
                        if source[i] == "{":
                            depth += 1
                        elif source[i] == "}":
                            depth -= 1
                            if depth == 0:
                                break
                        i += 1
                    out.append(
                        " " + strip_comments_and_strings(source[start:i]) + " "
                    )
                    i += 1
                    continue
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def assertion_lines(source: str) -> list[int]:
    """1-based line numbers of every postfix `!` in [source]."""
    code = strip_comments_and_strings(source)
    lines: list[int] = []
    for match in re.finditer(r"!", code):
        i = match.start()
        if i + 1 < len(code) and code[i + 1] == "=":
            continue
        if KEYWORDS_BEFORE_PREFIX_BANG.search(code[:i]):
            continue
        j = i - 1
        while j >= 0 and code[j] in " \t\n":
            j -= 1
        if j >= 0 and code[j] in IDENT_END:
            lines.append(code[:i].count("\n") + 1)
    return lines


def main() -> int:
    app_dir = Path(__file__).resolve().parent.parent
    root = app_dir / "lib"
    rows: list[tuple[int, str, list[int]]] = []
    for path in sorted(root.rglob("*.dart")):
        if path.name.endswith((".g.dart", ".freezed.dart")):
            continue
        lines = assertion_lines(path.read_text(encoding="utf-8"))
        if lines:
            rows.append((len(lines), str(path.relative_to(app_dir)), lines))
    rows.sort(key=lambda row: (-row[0], row[1]))
    total = sum(count for count, _, _ in rows)

    if "--list" in sys.argv:
        for count, name, lines in rows:
            joined = ", ".join(str(line) for line in lines)
            print(f"{count:5d}  {name}  (lines {joined})")
        print()

    print(
        f"postfix null assertions: {total} site(s) across {len(rows)} file(s) "
        f"(baseline {BASELINE})"
    )
    if total > BASELINE:
        print(
            f"New null assertions were added ({total} > baseline {BASELINE}).",
            file=sys.stderr,
        )
        print(
            "Remove them (preferred: hoist the value into a local so flow "
            "analysis promotes it), or if the value really is guaranteed, "
            "state the invariant in a comment and lower BASELINE in this "
            "script -- never raise it.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
