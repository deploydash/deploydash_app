"""Architecture invariant: one concept has one implementation.

Measurement: first-party Python functions are parsed with :mod:`ast`.  The
checks distinguish byte-identical bodies, one name with divergent bodies, and
near-identical bodies whose identifiers have been normalised.  Each reported
exception must be a named, reasoned entry below; a broad pattern or size limit
would hide precisely the small helpers this rule protects.
"""

from __future__ import annotations

import ast
import copy
import difflib
import hashlib
import pathlib
import unittest
from collections import defaultdict
from dataclasses import dataclass

_BACKEND_ROOT = pathlib.Path(__file__).resolve().parents[2]
_SOURCE_ROOT = _BACKEND_ROOT / "src" / "orchestrator"


@dataclass(frozen=True)
class _Definition:
    name: str
    source: str
    body: ast.Module
    line_count: int = 0

    @property
    def body_signature(self) -> str:
        return ast.dump(self.body, include_attributes=False)

    @property
    def normalised_body_signature(self) -> str:
        body = copy.deepcopy(self.body)
        _IdentifierNormaliser().visit(body)
        return ast.dump(body, include_attributes=False)


@dataclass(frozen=True)
class _ExactBodyExemption:
    """A known exact-body group, pinned so a new copy is still a failure."""

    reason: str
    sources: frozenset[str]


@dataclass(frozen=True)
class _NameBodyExemption:
    """A collision which is scoped to the source-count observed by D2."""

    reason: str
    source_count: int


def _is_stub_body(definition: _Definition) -> bool:
    """True when the member has no implementation to compare.

    A ``Protocol`` method's body is a docstring and ``...`` by construction,
    so thirteen of them are trivially "near-identical" while saying nothing
    about duplication. The meaningful content of such a member is its
    signature, which no body-similarity check reads.
    """
    statements = [
        statement
        for statement in definition.body.body
        if not (
            isinstance(statement, ast.Expr)
            and isinstance(statement.value, ast.Constant)
            and isinstance(statement.value.value, str)
        )
    ]
    if not statements:
        return True
    if len(statements) > 1:
        return False
    only = statements[0]
    if isinstance(only, ast.Pass):
        return True
    return (
        isinstance(only, ast.Expr)
        and isinstance(only.value, ast.Constant)
        and only.value.value is Ellipsis
    )


class _IdentifierNormaliser(ast.NodeTransformer):
    """Replace each distinct identifier with its positional placeholder."""

    def __init__(self) -> None:
        self._names: dict[str, str] = {}
        self._attributes: dict[str, str] = {}

    @staticmethod
    def _placeholder(values: dict[str, str], value: str) -> str:
        return values.setdefault(value, f"identifier_{len(values)}")

    def visit_Name(self, node: ast.Name) -> ast.Name:
        node.id = self._placeholder(self._names, node.id)
        return self.generic_visit(node)

    def visit_arg(self, node: ast.arg) -> ast.arg:
        node.arg = self._placeholder(self._names, node.arg)
        return self.generic_visit(node)

    def visit_Attribute(self, node: ast.Attribute) -> ast.Attribute:
        node.value = self.visit(node.value)
        node.attr = self._placeholder(self._attributes, node.attr)
        return node

    def visit_keyword(self, node: ast.keyword) -> ast.keyword:
        if node.arg is not None:
            node.arg = self._placeholder(self._attributes, node.arg)
        return self.generic_visit(node)


def _definitions() -> list[_Definition]:
    definitions = []
    for source_path in sorted(_SOURCE_ROOT.rglob("*.py")):
        tree = ast.parse(source_path.read_text(encoding="utf-8"), filename=str(source_path))
        relative_path = source_path.relative_to(_SOURCE_ROOT).as_posix()
        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            lines = (getattr(node, "end_lineno", 0) or 0) - (getattr(node, "lineno", 0) or 0) + 1
            definitions.append(
                _Definition(
                    name=node.name,
                    source=relative_path,
                    body=ast.Module(body=node.body, type_ignores=[]),
                    line_count=lines,
                )
            )
    return definitions


def _format_group(definitions: list[_Definition]) -> str:
    sources = ", ".join(sorted({definition.source for definition in definitions}))
    return f"{definitions[0].name}: {sources}"


def _exact_key(definitions: list[_Definition]) -> tuple[str, frozenset[str], str]:
    body_signature = definitions[0].body_signature.encode("utf-8")
    return (
        definitions[0].name,
        frozenset(definition.source for definition in definitions),
        hashlib.sha256(body_signature).hexdigest(),
    )


# These are bounded pre-existing implementations already present
# when the guard was introduced.  Sources and body hash are part of the key:
# adding a ninth `_validated_connection`, for example, fails rather than being
# hidden by an exemption for the original eight.  The three §3.8 removals are
# therefore able to delete their own entries instead of weakening the rule.
_EXACT_BODY_EXEMPTIONS = {
    (
        "_describe_schema",
        frozenset({"scheduler_parts/__init__.py", "workflow_registry.py"}),
        "11a43ac68c6df3c0b7afbe2af8740137b6acc3220b357526b73d527d8cdc4e83",
    ): _ExactBodyExemption(
        reason="The scheduler describes its own no-parameter operation explicitly.",
        sources=frozenset({"scheduler_parts/__init__.py", "workflow_registry.py"}),
    ),
    (
        "_emit_from_executor",
        frozenset(
            {
                "app_runtime_parts/deployment.py",
                "infra_parts/provisioning.py",
                "infra_parts/tooling.py",
            }
        ),
        "9017bfb53d108cd801d3f37c623b4a8b60b7fa637824c64ed6d8f683a36cd800",
    ): _ExactBodyExemption(
        reason="The two extracted engine-operation families retain local executor adapters.",
        sources=frozenset(
            {
                "app_runtime_parts/deployment.py",
                "infra_parts/provisioning.py",
                "infra_parts/tooling.py",
            }
        ),
    ),
    (
        "_sanitize_message",
        frozenset({"engine.py", "pyinfra_runtime.py"}),
        "587c932213d0096d84e79c2ee42785a2a2d1a20e1618cbb5a7f96f1bd9ad7e41",
    ): _ExactBodyExemption(
        reason="Engine and pyinfra have separate user-facing error boundaries.",
        sources=frozenset({"engine.py", "pyinfra_runtime.py"}),
    ),
    (
        "_settings_payload",
        frozenset({"engine_firewall_ops.py", "engine_scheduler_ops.py"}),
        "1abb2cc0ad8b719b0d86bfe8568dc420c57560d88a7d4df732039da9de4fa943",
    ): _ExactBodyExemption(
        reason="Firewall and scheduler preserve their own operation payload boundaries.",
        sources=frozenset({"engine_firewall_ops.py", "engine_scheduler_ops.py"}),
    ),
    (
        "normalize_parts",
        frozenset(
            {
                "app_parts/app_plan.py",
                "dns_parts/dns_plan.py",
                "http_parts/http_plan.py",
                "setup_parts/setup_plan.py",
            }
        ),
        "623b856996a5e16fdf8474d56287ba3ea3e789daeadaba3de9698f9e8c15ac46",
    ): _ExactBodyExemption(
        reason="Each workflow plan owns its own input-to-step normalisation boundary.",
        sources=frozenset(
            {
                "app_parts/app_plan.py",
                "dns_parts/dns_plan.py",
                "http_parts/http_plan.py",
                "setup_parts/setup_plan.py",
            }
        ),
    ),
    (
        "to_dict",
        frozenset(
            {
                "dns_parts/common.py",
                "http_parts/common.py",
                "setup_parts/common.py",
            }
        ),
        "8162731e76fbb87b8c58b4396861dd79aa9076f9bfa57009e175bf51705eb089",
    ): _ExactBodyExemption(
        reason="Setup, DNS, and HTTP serialize distinct public workflow action values.",
        sources=frozenset(
            {
                "dns_parts/common.py",
                "http_parts/common.py",
                "setup_parts/common.py",
            }
        ),
    ),
    (
        "to_dict",
        frozenset(
            {
                "app_parts/common.py",
                "dns_parts/common.py",
                "http_parts/common.py",
                "setup_parts/common.py",
            }
        ),
        "311181cb59bfa9faac0ce2ddd6f93f7267a976b76230566d200cbf0b404ee31c",
    ): _ExactBodyExemption(
        reason="Each serializes a distinct public workflow value object with different fields.",
        sources=frozenset(
            {
                "app_parts/common.py",
                "dns_parts/common.py",
                "http_parts/common.py",
                "setup_parts/common.py",
            }
        ),
    ),
    (
        "utc_now_iso",
        frozenset({"app_release_runtime.py", "task_runtime.py"}),
        "b64b2cffa3b1606cec2f21d7a38772fd025e452672c830c1cf9b39d7287b2c9b",
    ): _ExactBodyExemption(
        reason="Release and task persistence retain distinct timestamp module boundaries.",
        sources=frozenset({"app_release_runtime.py", "task_runtime.py"}),
    ),
}

# Same-name collisions with concrete contract differences or explicit pending
# consolidation work. This starts empty for the D2 baseline; the
# populated, reasoned list is added only after that baseline is captured.
_SAME_NAME_BODY_EXEMPTIONS = {
    ("_build_connector_data", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_command_error_details", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_emit", 2): _NameBodyExemption("Separate runtime event-delivery boundaries.", 2),
    ("_emit_shell_output_lines", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_error_result", 2): _NameBodyExemption(
        "Engine and executor own distinct error boundaries.", 2
    ),
    ("_extract_connection_payload", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_friendly_connect_error_message", 2): _NameBodyExemption(
        "T-3.3 engine facade extraction.", 2
    ),
    ("_get_hardware_specs_fast", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_get_primary_disk_gb", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_int_from_env", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_normalize_runtime_log_tail", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_normalized_optional_string", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_normalized_port", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_open_runtime_session", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_optional_string", 2): _NameBodyExemption(
        "B-62-tail collapses the setup/postgres `_optional_string` pair T-3.8.1 left behind.",
        2,
    ),
    ("_params_schema", 5): _NameBodyExemption(
        "Each workflow publishes a distinct JSON schema for its operation parameters.", 5
    ),
    ("_parse_docker_stats_output", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_parse_float", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_parse_http_service_status_output", 2): _NameBodyExemption(
        "T-3.3 engine facade extraction.", 2
    ),
    ("_parse_percent", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_parse_positive_int", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_parse_server_overview_metrics_output", 2): _NameBodyExemption(
        "T-3.3 engine facade extraction.", 2
    ),
    ("_probe_http_gateway_fast_path", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_read_remote_file_text", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_refresh_known_host_entry", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_render_apply_script", 2): _NameBodyExemption(
        "DNS and HTTP render different deployment artifacts.", 2
    ),
    ("_render_compose", 2): _NameBodyExemption(
        "DNS and HTTP render different deployment artifacts.", 2
    ),
    ("_render_stack_readme", 2): _NameBodyExemption(
        "Deployment documentation is workflow specific.", 2
    ),
    ("_required_container_name", 2): _NameBodyExemption(
        "B-3 collapses the app/dns `_required_container_name` Docker-name "
        "twins T-3.8.1 left behind.",
        2,
    ),
    ("_resolve_known_hosts_file", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_runtime_event_emitter", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
    ("_wait_for_postgres_readiness", 2): _NameBodyExemption("T-3.3 engine facade extraction.", 2),
}
_NEAR_BODY_EXEMPTIONS = {
    ("_required_container_name", 2): _NameBodyExemption(
        "B-3 collapses the app/dns `_required_container_name` Docker-name "
        "twins T-3.8.1 left behind.",
        2,
    ),
}

# T-2.6.5 records the full exception total after T-2.6.2. Each individual
# collision is already source-count-pinned below; this extra aggregate ratchet
# prevents several apparently small additions from becoming normal over time.
_ONE_OWNER_EXEMPTION_BASELINE_COUNT = 50
_STATUS_QUO_EXEMPTION_PHRASES = ("intentionally local", "workflow-specific")


class TestOneOwnerPerConcept(unittest.TestCase):
    def test_exemptions_are_reasoned_and_match_the_observed_collision_set(self):
        """Rule: an exemption is narrow, reasoned, and never silently stale."""
        definitions = _definitions()

        exact_groups: dict[str, list[_Definition]] = defaultdict(list)
        for definition in definitions:
            exact_groups[definition.body_signature].append(definition)
        observed_exact = {
            _exact_key(group)
            for group in exact_groups.values()
            if len({definition.source for definition in group}) >= 2
        }

        same_name_groups: dict[str, list[_Definition]] = defaultdict(list)
        for definition in definitions:
            if definition.name.startswith("_") and not definition.name.startswith("__"):
                same_name_groups[definition.name].append(definition)
        observed_same_name = {
            (name, len({definition.source for definition in group}))
            for name, group in same_name_groups.items()
            if len({definition.source for definition in group}) >= 2
            and len({definition.body_signature for definition in group}) >= 2
        }

        near_groups: dict[tuple[str, str], list[_Definition]] = defaultdict(list)
        for definition in definitions:
            if definition.name.startswith("_") and not definition.name.startswith("__"):
                near_groups[(definition.name, definition.normalised_body_signature)].append(
                    definition
                )
        observed_near = {
            (name, len({definition.source for definition in group}))
            for (name, _), group in near_groups.items()
            if len({definition.source for definition in group}) >= 2
            and len({definition.body_signature for definition in group}) >= 2
        }

        self.assertEqual(set(_EXACT_BODY_EXEMPTIONS), observed_exact)
        self.assertEqual(set(_SAME_NAME_BODY_EXEMPTIONS), observed_same_name)
        self.assertEqual(set(_NEAR_BODY_EXEMPTIONS), observed_near)
        for exemptions in (
            _EXACT_BODY_EXEMPTIONS.values(),
            _SAME_NAME_BODY_EXEMPTIONS.values(),
            _NEAR_BODY_EXEMPTIONS.values(),
        ):
            for exemption in exemptions:
                self.assertTrue(exemption.reason.strip())
                self.assertFalse(
                    any(
                        phrase in exemption.reason.lower()
                        for phrase in _STATUS_QUO_EXEMPTION_PHRASES
                    ),
                    "one-owner exemptions must name a consolidation task or "
                    "state the concrete contract difference; status-quo labels "
                    "are not reasons",
                )
        self.assertLessEqual(
            len(_EXACT_BODY_EXEMPTIONS)
            + len(_SAME_NAME_BODY_EXEMPTIONS)
            + len(_NEAR_BODY_EXEMPTIONS),
            _ONE_OWNER_EXEMPTION_BASELINE_COUNT,
            "backend one-owner exemption count grew; consolidate instead of "
            "normalising another duplicate",
        )
        for exemption in _IN_FILE_NEAR_DUPLICATE_EXEMPTIONS.values():
            self.assertTrue(exemption.reason.strip())
            self.assertFalse(
                any(phrase in exemption.reason.lower() for phrase in _STATUS_QUO_EXEMPTION_PHRASES),
                "in-file near-duplicate exemptions must name a consolidation "
                "task or state the concrete contract difference",
            )
        self.assertLessEqual(
            len(_IN_FILE_NEAR_DUPLICATE_EXEMPTIONS),
            _IN_FILE_NEAR_DUPLICATE_BASELINE_COUNT,
            "in-file near-duplicate exemption count grew; collapse the family "
            "instead of pinning another file",
        )

    def test_no_identical_function_body_has_multiple_source_owners(self):
        """Rule: an exact implementation body has one owner across source files."""
        grouped: dict[str, list[_Definition]] = defaultdict(list)
        for definition in _definitions():
            grouped[definition.body_signature].append(definition)

        violations = []
        for definitions in grouped.values():
            if len({definition.source for definition in definitions}) < 2:
                continue
            key = _exact_key(definitions)
            if key not in _EXACT_BODY_EXEMPTIONS:
                violations.append(_format_group(definitions))
        self.assertEqual(
            violations,
            [],
            "One-owner rule (identical bodies across files) failed: "
            + "; ".join(sorted(violations)),
        )

    def test_one_private_helper_name_does_not_hide_divergent_contracts(self):
        """Rule: one private helper name has one body contract across files."""
        grouped: dict[str, list[_Definition]] = defaultdict(list)
        for definition in _definitions():
            if definition.name.startswith("_") and not definition.name.startswith("__"):
                grouped[definition.name].append(definition)

        violations = []
        for name, definitions in grouped.items():
            if len({definition.source for definition in definitions}) < 2:
                continue
            if len({definition.body_signature for definition in definitions}) < 2:
                continue
            if (
                name,
                len({definition.source for definition in definitions}),
            ) not in _SAME_NAME_BODY_EXEMPTIONS:
                violations.append(_format_group(definitions))
        self.assertEqual(
            violations,
            [],
            "One-owner rule (same private helper name, different bodies) failed: "
            + "; ".join(sorted(violations)),
        )

    def test_no_private_helpers_are_near_duplicates_after_identifier_normalisation(self):
        """Rule: private helpers must not differ only by identifier spelling."""
        grouped: dict[tuple[str, str], list[_Definition]] = defaultdict(list)
        for definition in _definitions():
            if definition.name.startswith("_") and not definition.name.startswith("__"):
                grouped[(definition.name, definition.normalised_body_signature)].append(definition)

        violations = []
        for (name, _), definitions in grouped.items():
            if len({definition.source for definition in definitions}) < 2:
                continue
            if len({definition.body_signature for definition in definitions}) < 2:
                # The exact-body check owns this shape, so do not report it twice.
                continue
            if (
                name,
                len({definition.source for definition in definitions}),
            ) not in _NEAR_BODY_EXEMPTIONS:
                violations.append(_format_group(definitions))
        self.assertEqual(
            violations,
            [],
            "One-owner rule (near-identical private helper bodies) failed: "
            + "; ".join(sorted(violations)),
        )

    def test_no_differently_named_near_duplicates_in_one_file(self):
        """Rule: a single file must not contain three or more near-duplicate member bodies."""
        by_file: dict[str, list[_Definition]] = defaultdict(list)
        for definition in _definitions():
            if definition.line_count >= 8 and not _is_stub_body(definition):
                by_file[definition.source].append(definition)

        violations = []
        for source, defs in by_file.items():
            if len(defs) < 3:
                continue
            adj: dict[int, set[int]] = defaultdict(set)
            sigs = [d.normalised_body_signature for d in defs]
            for i in range(len(defs)):
                for j in range(i + 1, len(defs)):
                    sim = difflib.SequenceMatcher(None, sigs[i], sigs[j]).ratio()
                    if sim >= 0.9:
                        adj[i].add(j)
                        adj[j].add(i)

            visited = set()
            clusters = []
            for i in range(len(defs)):
                if i not in visited and len(adj[i]) >= 2:
                    comp = []
                    q = [i]
                    visited.add(i)
                    while q:
                        curr = q.pop(0)
                        comp.append(defs[curr].name)
                        for neighbor in adj[curr]:
                            if neighbor not in visited:
                                visited.add(neighbor)
                                q.append(neighbor)
                    if len(comp) >= 3:
                        clusters.append(comp)

            if not clusters:
                continue

            total_members = sum(len(c) for c in clusters)
            exemption = _IN_FILE_NEAR_DUPLICATE_EXEMPTIONS.get(source)
            if exemption is None or exemption.source_count != total_members:
                cluster_desc = "; ".join(f"[{', '.join(sorted(set(c)))}]" for c in clusters)
                violations.append(f"{source} ({total_members} members): {cluster_desc}")

        self.assertEqual(
            violations,
            [],
            "One-owner rule (near-duplicate member bodies inside one file) failed: "
            + " | ".join(sorted(violations)),
        )


# T-2.6.8's first red run, 2026-09-03. Every entry names the task that
# removes it and is pinned to the member count observed then, so a new copy
# in an already-listed file still fails. The list may only shrink.
_IN_FILE_NEAR_DUPLICATE_EXEMPTIONS: dict[str, _NameBodyExemption] = {
    # Was `app_parts/app_config.py` until T-3.3.4 split the validators out.
    # The family moved with them; the count fell 5 -> 4 because one of the
    # five stayed behind with the resolved values.
    "app_parts/app_config_fields.py": _NameBodyExemption(
        reason=(
            "B-3 collapses the _optional_<thing> regex validators into one "
            "parameterised helper. Not covered by T-3.8.1, which owns the "
            "cross-module _required_*/_optional_string family instead."
        ),
        source_count=4,
    ),
    "engine.py": _NameBodyExemption(
        reason=(
            "B-2 collapses the twenty facade forwarders that inject "
            "_ENGINE_CONTEXT and pass every argument through by keyword."
        ),
        source_count=20,
    ),
    "infra_parts/provisioning.py": _NameBodyExemption(
        reason=(
            "B-4 hoists the three byte-identical _emit_from_executor "
            "closures into one shared emitter factory."
        ),
        source_count=3,
    ),
    "plugins/server_plugin.py": _NameBodyExemption(
        reason=(
            "B-1 collapses nine of the ten handlers onto one connection "
            "handler factory. T-3.8.5's plugin read did not name this file."
        ),
        source_count=8,
    ),
}

# Pinned separately from _ONE_OWNER_EXEMPTION_BASELINE_COUNT: this map keys on
# file rather than on a name/source-count pair, so a shared total would let a
# collapse here pay for a new exemption there.
_IN_FILE_NEAR_DUPLICATE_BASELINE_COUNT = 4


if __name__ == "__main__":
    unittest.main()
