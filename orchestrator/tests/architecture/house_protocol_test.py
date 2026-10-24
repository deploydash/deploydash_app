"""Architecture invariant: each House protocol row has exactly one owner.

`AGENTS.md`'s House protocols section names the shapes that recur across the
whole backend and the single implementation each one is supposed to have.
Until T-2.6.3 not one of those rows was measured, which is the condition the
section exists to end: **a row added to that table without a check here is a
row that will be reimplemented.**

Two rows are checked here; the other two already have owners elsewhere
(`managed_identifier_ownership_test.py` for managed paths and identifiers,
`ownership_enforcement_test.py` for pinned image and tool versions).

**The network seam.** `runtime_ops.run_shell_command(host, ...)` is meant to
be the only way a remote call leaves this process, because a single injectable
`host` is what makes the Tier 0 fault injection in `tests/fault_injection.py`
possible at all. Two different things can break that, and they are not equally
bad:

- Opening a *connection* outside the session owner is a genuine second path to
  the network. A fake host cannot intercept it, so whatever it does is
  invisible to every fault-injection test. `test_only_the_session_owner_opens_
  a_connection` is the check that matters.
- Calling `host.run_shell_command` directly rather than through the
  `runtime_ops` wrapper still uses the injected host, so it stays
  interceptable; what it loses is the uniform `{ok, output, details}` result.
  That is a real but lesser divergence, and there are 42 of them across 15
  modules, so it is a shrink-only ratchet rather than a hard failure.

**The `KEY=value` output protocol.** `shell_output.parse_key_values` is the
one parser. This row is why the check exists: the 2026-08-31 audit found
**fifteen** hand-rolled copies, and they were found by reading rather than by
any tool, because differently-named duplicates are invisible to search by
construction. They have since been collapsed, so this check passes today and
its whole job is to keep it that way.
"""

from __future__ import annotations

import pathlib
import re
import unittest

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SOURCE_ROOT = _REPO_ROOT / "orchestrator" / "src" / "orchestrator"
_DART_SOURCE_ROOT = _REPO_ROOT / "ui" / "lib"

# --- the network seam ----------------------------------------------------

# Modules permitted to construct a connection. `engine_runtime_common.py` owns
# the runtime session every workflow opens.
_CONNECTION_OWNERS = ("engine_runtime_common.py",)

# A second network path that exists and is not yet closed.
#
# `local_import_support.py` opens its own `paramiko.SSHClient` to stream a
# local .sql file over SFTP with progress reporting, which the command seam
# cannot express -- `run_shell_command` sends a command and reads its output,
# it does not upload a file. The consequence is concrete rather than
# theoretical: **the local SQL import path cannot be fault-injected**, because
# a fake host never sees this connection.
#
# Reasoned and shrink-only. Closing it needs an upload seam beside the command
# seam, which is a design change and therefore its own task -- see the
# Discovered work row dated 2026-09-04. Do not add an entry here without one.
_CONNECTION_EXEMPTIONS = {
    "postgres_runtime_parts/local_import_support.py": (
        "Streams a .sql upload over SFTP with progress; not expressible "
        "through the command seam. Needs an upload seam - see Discovered work."
    ),
}

_CONNECTION_MARKERS = (
    re.compile(r"\bparamiko\.SSHClient\s*\("),
    re.compile(r"\bparamiko\.Transport\s*\("),
    re.compile(r"\bsocket\.create_connection\s*\("),
)

# Direct `host.run_shell_command` calls, by module, as measured 2026-09-04.
# These bypass the `runtime_ops` wrapper but keep the injected host, so they
# remain interceptable. The list and every count may only shrink.
_DIRECT_HOST_CALL_BASELINE = {
    "engine_firewall_ops.py": 8,
    "postgres_runtime_parts/database_lifecycle.py": 3,
    "infra_parts/overview.py": 5,
    "firewall_status.py": 4,
    "infra_parts/system_settings.py": 3,
    "engine_runtime_common.py": 3,
    "app_runtime_parts/release_lifecycle.py": 3,
    "postgres_runtime_parts/backup_support.py": 2,
    "postgres_runtime_parts/agent_access.py": 2,
    "infra_parts/docker_storage.py": 2,
    "postgres_runtime_parts/service_runtime.py": 1,
    "postgres_runtime_parts/local_import_support.py": 1,
    "infra_parts/provisioning.py": 1,
    "app_runtime_parts/runtime_operations.py": 1,
    "app_runtime_parts/deployment.py": 1,
}

_DIRECT_HOST_CALL = re.compile(r"\.run_shell_command\s*\(")

# --- the KEY=value output protocol ---------------------------------------

_KEY_VALUE_OWNER = "shell_output.py"

# Splitting a line on the first `=` while reading command output is the shape
# `parse_key_values` owns. Matching the split alone would flag unrelated code,
# so a module only counts when it also reads `stdout_lines` -- which is what
# makes it a *protocol* parser rather than an ordinary string split.
_KEY_VALUE_SPLIT = re.compile(r"\.split\(\s*[\"']=[\"']\s*,\s*1\s*\)")
_READS_STDOUT_LINES = re.compile(r"\bstdout_lines\b")


# --- the plugin dispatch protocols ---------------------------------------

_PLUGIN_ROOT_NAME = "plugins"
_PLUGIN_BASE = "base.py"

# `plugins/base.py` owns connection validation and operation binding. Before
# T-3.8.5 each plugin carried its own copy of both, which is why the contract
# lists them as protocol rows rather than as ordinary helpers.
_PLUGIN_LOCAL_DISPATCH = re.compile(
    r"^\s*def\s+_?(?:runtime_operation|bind_operation|validated_connection)\b",
    re.MULTILINE,
)
_EXTRACTS_CONNECTION = re.compile(r"\bextract_connection_payload\s*\(")
_VALIDATES_CONNECTION = re.compile(r"\bconnection_validation_error\s*\(")

# --- the cross-language failure-evidence protocol ------------------------

_FAILURE_EVIDENCE_FIELD = re.compile(r"[\"']failure_evidence[\"']")
_FAILURE_EVIDENCE_PYTHON_OWNER = "failure_evidence.py"
_FAILURE_EVIDENCE_DART_OWNER = "models/deploy_failure_evidence.dart"
_STRUCTURED_ERROR_NORMALIZER_DEFINITION = re.compile(
    r"^def (?:normalize_diagnostic_line|_structured_(?:json|xml)_error_message)\(",
    re.MULTILINE,
)


def _python_sources() -> list[pathlib.Path]:
    return sorted(path for path in _SOURCE_ROOT.rglob("*.py") if "__pycache__" not in path.parts)


def _relative(path: pathlib.Path) -> str:
    return path.relative_to(_SOURCE_ROOT).as_posix()


class HouseProtocolTest(unittest.TestCase):
    def test_only_the_session_owner_opens_a_connection(self) -> None:
        offenders = []
        for path in _python_sources():
            relative = _relative(path)
            if path.name in _CONNECTION_OWNERS:
                continue
            text = path.read_text(encoding="utf-8")
            for marker in _CONNECTION_MARKERS:
                match = marker.search(text)
                if match is None:
                    continue
                if relative in _CONNECTION_EXEMPTIONS:
                    continue
                line = text[: match.start()].count("\n") + 1
                offenders.append(f"{relative}:{line} opens {match.group(0)}")
        self.assertEqual(
            offenders,
            [],
            "A second path to the network makes everything it does invisible "
            "to fault injection. Route it through runtime_ops, or add a "
            "reasoned exemption naming the task that will:\n" + "\n".join(offenders),
        )

    def test_every_connection_exemption_is_reasoned_and_still_real(self) -> None:
        """An exemption list that outlives its reason is a rule abandoned."""
        for relative, reason in _CONNECTION_EXEMPTIONS.items():
            with self.subTest(module=relative):
                self.assertGreater(
                    len(reason),
                    60,
                    "an exemption needs a reason, not a label",
                )
                path = _SOURCE_ROOT / relative
                self.assertTrue(path.exists(), f"{relative} no longer exists")
                text = path.read_text(encoding="utf-8")
                self.assertTrue(
                    any(marker.search(text) for marker in _CONNECTION_MARKERS),
                    f"{relative} no longer opens a connection; drop the entry",
                )

    def test_direct_host_shell_calls_only_shrink(self) -> None:
        counts: dict[str, int] = {}
        for path in _python_sources():
            relative = _relative(path)
            if relative == "runtime_ops.py":
                continue
            found = len(_DIRECT_HOST_CALL.findall(path.read_text(encoding="utf-8")))
            if found:
                counts[relative] = found

        grown = sorted(
            f"{module}: {count} (baseline {_DIRECT_HOST_CALL_BASELINE.get(module, 0)})"
            for module, count in counts.items()
            if count > _DIRECT_HOST_CALL_BASELINE.get(module, 0)
        )
        self.assertEqual(
            grown,
            [],
            "Direct host.run_shell_command calls may only shrink. Use "
            "runtime_ops.run_shell_command(host, ...) so the result shape is "
            "the same everywhere:\n" + "\n".join(grown),
        )

        stale = sorted(
            module
            for module, baseline in _DIRECT_HOST_CALL_BASELINE.items()
            if counts.get(module, 0) < baseline
        )
        self.assertEqual(
            stale,
            [],
            "These modules now have fewer direct calls than the baseline "
            "claims. Lower the baseline in the same commit, or the ratchet "
            "stops ratcheting:\n" + "\n".join(stale),
        )

    def test_only_shell_output_parses_the_key_value_protocol(self) -> None:
        offenders = []
        for path in _python_sources():
            relative = _relative(path)
            if path.name == _KEY_VALUE_OWNER:
                continue
            text = path.read_text(encoding="utf-8")
            if not _READS_STDOUT_LINES.search(text):
                continue
            match = _KEY_VALUE_SPLIT.search(text)
            if match is None:
                continue
            line = text[: match.start()].count("\n") + 1
            offenders.append(f"{relative}:{line}")
        self.assertEqual(
            offenders,
            [],
            "shell_output.parse_key_values owns the KEY=value protocol. The "
            "2026-08-31 audit found fifteen hand-rolled copies; this is what "
            "stops the sixteenth:\n" + "\n".join(offenders),
        )

    def test_only_plugins_base_owns_connection_validation(self) -> None:
        """A plugin that extracts and validates itself is the sixth copy."""
        offenders = []
        for path in _python_sources():
            relative = _relative(path)
            if _PLUGIN_ROOT_NAME not in path.parts or path.name == _PLUGIN_BASE:
                continue
            text = path.read_text(encoding="utf-8")
            if _EXTRACTS_CONNECTION.search(text) and _VALIDATES_CONNECTION.search(text):
                offenders.append(relative)
        self.assertEqual(
            offenders,
            [],
            "plugins/base.validated_connection(data, ctx) is the one owner. "
            "T-3.8.5 collapsed a copy of this pair out of every plugin:\n" + "\n".join(offenders),
        )

    def test_only_plugins_base_owns_operation_binding(self) -> None:
        """A per-plugin dispatch helper is the shape T-3.8.5 removed."""
        offenders = []
        for path in _python_sources():
            relative = _relative(path)
            if _PLUGIN_ROOT_NAME not in path.parts or path.name == _PLUGIN_BASE:
                continue
            text = path.read_text(encoding="utf-8")
            for match in _PLUGIN_LOCAL_DISPATCH.finditer(text):
                line = text[: match.start()].count("\n") + 1
                offenders.append(f"{relative}:{line}{match.group(0).rstrip()}")
        self.assertEqual(
            offenders,
            [],
            "plugins/base.runtime_operation and .bind_operation are the one "
            "owner of workflow dispatch; bind through them rather than "
            "redefining the shape per plugin:\n" + "\n".join(offenders),
        )

    def test_failure_evidence_has_one_python_and_one_dart_owner(self) -> None:
        """A cross-language diagnostic shape must not gain an ad hoc parser."""
        python_owners = sorted(
            _relative(path)
            for path in _python_sources()
            if _FAILURE_EVIDENCE_FIELD.search(path.read_text(encoding="utf-8"))
        )
        dart_owners = sorted(
            path.relative_to(_DART_SOURCE_ROOT).as_posix()
            for path in _DART_SOURCE_ROOT.rglob("*.dart")
            if _FAILURE_EVIDENCE_FIELD.search(path.read_text(encoding="utf-8"))
        )

        self.assertEqual(python_owners, [_FAILURE_EVIDENCE_PYTHON_OWNER])
        self.assertEqual(dart_owners, [_FAILURE_EVIDENCE_DART_OWNER])

    def test_failure_evidence_owns_structured_error_normalization(self) -> None:
        """A second JSON/XML diagnostic parser would make evidence selection diverge."""
        owners = sorted(
            _relative(path)
            for path in _python_sources()
            if _STRUCTURED_ERROR_NORMALIZER_DEFINITION.search(path.read_text(encoding="utf-8"))
        )

        self.assertEqual(owners, [_FAILURE_EVIDENCE_PYTHON_OWNER])

    def test_the_checks_can_see_a_violation(self) -> None:
        """Each pattern matches a known-bad line, so a green run means something."""
        self.assertIsNotNone(_CONNECTION_MARKERS[0].search("c = paramiko.SSHClient()"))
        self.assertIsNone(_CONNECTION_MARKERS[0].search("# paramiko.SSHClient is owned"))
        self.assertIsNotNone(_DIRECT_HOST_CALL.search("ok, out = host.run_shell_command("))
        self.assertIsNone(_DIRECT_HOST_CALL.search("run_shell_command_wrapper("))
        self.assertIsNotNone(_KEY_VALUE_SPLIT.search('key, value = line.split("=", 1)'))
        self.assertIsNone(_KEY_VALUE_SPLIT.search('parts = line.split("=")'))
        self.assertIsNotNone(_PLUGIN_LOCAL_DISPATCH.search("    def _runtime_operation(x):"))
        self.assertIsNone(_PLUGIN_LOCAL_DISPATCH.search("    def handle_run(data):"))
        self.assertIsNotNone(
            _FAILURE_EVIDENCE_FIELD.search("payload['failure_evidence']"),
        )
        self.assertIsNone(
            _FAILURE_EVIDENCE_FIELD.search("payload['failure-details']"),
        )
        self.assertIsNotNone(
            _STRUCTURED_ERROR_NORMALIZER_DEFINITION.search(
                "def normalize_diagnostic_line(value, sanitizer):"
            ),
        )
        self.assertIsNone(
            _STRUCTURED_ERROR_NORMALIZER_DEFINITION.search("def normalize_unrelated_line(value):"),
        )
        self.assertIsNotNone(
            _EXTRACTS_CONNECTION.search("d = ctx.extract_connection_payload(data)")
        )


if __name__ == "__main__":
    unittest.main()
