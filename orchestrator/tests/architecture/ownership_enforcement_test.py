"""Architecture invariant: ownership values have one source owner.

Measurement: first-party source literals are scanned below for duplicated
pinned image references and managed identifier literals.

Ownership classification prose lives in the owner's private tracking docs
and is deliberately not machine-checked here: a test must never depend on
a document that does not ship with the repository under test. What is
enforced here is the single-owner rule over values the code itself owns:

1. No image-reference literal (platform_versions.py's own pinned values)
   exists outside `platform_versions.py` and `railpack_contract.py`.
2. No fixed managed identifier literal (the values in each module's
   `RESOLVED_*_DEFAULTS` that are container/service names, not paths or
   pins) exists outside that module's own config file.
"""

import pathlib
import re
import unittest

from orchestrator import platform_versions
from orchestrator.dns_parts.dns_config import RESOLVED_DNS_DEFAULTS
from orchestrator.http_parts.http_config import RESOLVED_HTTP_DEFAULTS
from orchestrator.postgres_parts.postgres_config import RESOLVED_POSTGRES_DEFAULTS

_BACKEND_ROOT = pathlib.Path(__file__).resolve().parents[2]
_SRC_ROOT = _BACKEND_ROOT / "src" / "orchestrator"

# The ownership scanner has five deliberately narrow boundaries. Keep their
# rationale in machine-checked data: an unreasoned exception is a silent
# hole in the one-owner rule, not a passing test. The set can shrink as
# the named consolidation work lands, never grow.
_OWNERSHIP_EXEMPTION_REASONS = {
    "host_port": (
        "PostgreSQL accepts only its sole legal port today; removing the obsolete wire "
        "field is the real fix."
    ),
    "platform pin re-export": (
        "railpack_contract.py renders the shared pin owned by platform_versions.py."
    ),
    "app Caddy identifier": (
        "app_config.py deliberately addresses the same physical Caddy container pending "
        "the dedicated identifier owner."
    ),
    "short generic identifiers": (
        "bind9 and deploydash have legitimate unrelated textual occurrences that a literal "
        "scan cannot distinguish."
    ),
    "provisioning helper identifiers": (
        "The existing duplicates need their own owner-consolidation task; a substring scan "
        "cannot prove them clean."
    ),
}
_OWNERSHIP_EXEMPTION_BASELINE_COUNT = 5


# Identifier-shaped values (container/service names) in each RESOLVED_*_
# DEFAULTS, together with the one file each is allowed to declare a literal
# in. Deliberately excludes the pinned image references (platform_versions.py
# already owns those, checked separately) and the managed roots (they are
# full paths built from server_paths.py function calls, not bare literals,
# so there is nothing here to duplicate).
#
# Also deliberately excludes app_parts.app_config.RESOLVED_APP_DEFAULTS'
# `railpack_build_helper`/`caddy_apply_helper` -- checked and found
# duplicated across infra_parts/tooling.py, setup_parts/part5_railpack_builds.py,
# and http_parts/part1_foundation.py (10+ sites), entrenched in the
# provisioning pipeline that installs those helper binaries in the first
# place. Fixing that is a materially bigger task than the mechanical
# quote-and-pass substitution `container_name` got -- recorded as future
# work rather than silently expanded into here.
#
# Also excludes `bind_service_name` ("bind9") and `superuser_name`
# ("deploydash") entirely: both are short, generic values with genuine,
# legitimate unrelated matches elsewhere in the tree (the Debian package/
# systemd-unit name "bind9" checked when detecting a pre-existing unmanaged
# install; "deploydash" as a substring of dozens of other identifiers and
# the product name itself in comments/docstrings) that a substring scan
# cannot tell apart from a real duplicate.
# `caddy_container_name` (app_config.py) is excluded from the "must
# not appear outside its own file" direction: it deliberately holds the
# same value as HTTP's `container_name` because both refer to the one
# physical Caddy container from two modules' perspectives.
_IDENTIFIER_SOURCES = (
    (RESOLVED_HTTP_DEFAULTS, ("container_name",), "http_parts/http_config.py"),
    (RESOLVED_DNS_DEFAULTS, ("container_name",), "dns_parts/dns_config.py"),
    (
        RESOLVED_POSTGRES_DEFAULTS,
        ("container_name",),
        "postgres_parts/postgres_config.py",
    ),
)

# The one deliberate, recorded cross-reference: app_config.py's own
# `caddy_container_name` holds the same value as HTTP's `container_name`
# on purpose, so it is not a leak.
_IDENTIFIER_LEAK_EXCEPTIONS = frozenset({"app_parts/app_config.py"})


def _iter_source_files(*, exclude):
    excluded = {(_SRC_ROOT / rel).resolve() for rel in exclude}
    for path in sorted(_SRC_ROOT.rglob("*.py")):
        if path.resolve() in excluded:
            continue
        yield path


class TestOwnershipExemptionMetadata(unittest.TestCase):
    def test_every_scanner_boundary_is_reasoned_and_the_list_only_shrinks(self):
        """Rule: a narrow ownership-scan boundary is debt, never an unnamed bypass."""
        self.assertLessEqual(len(_OWNERSHIP_EXEMPTION_REASONS), _OWNERSHIP_EXEMPTION_BASELINE_COUNT)
        for name, reason in _OWNERSHIP_EXEMPTION_REASONS.items():
            self.assertTrue(reason.strip(), f"ownership exemption {name!r} has no reason")


class TestNoImageReferenceLeaksOutsidePlatformVersions(unittest.TestCase):
    def test_pinned_image_values_appear_only_in_their_owner_modules(self):
        allowed = {
            _SRC_ROOT / "platform_versions.py",
            _SRC_ROOT / "railpack_contract.py",
        }
        pins = (
            platform_versions.CADDY_IMAGE,
            platform_versions.BIND_IMAGE,
            platform_versions.WALG_VERSION,
            *platform_versions.POSTGRES_IMAGE_TAGS_BY_MAJOR.values(),
            *platform_versions.DOCKER_PACKAGE_VERSION_PREFIXES.values(),
        )
        offending = []
        for path in _iter_source_files(exclude=()):
            if path in allowed:
                continue
            text = path.read_text(encoding="utf-8")
            for pin in pins:
                if pin in text:
                    offending.append(f"{path.relative_to(_SRC_ROOT)}: {pin!r}")
        self.assertEqual(offending, [])


class TestPostgresSupplyChainRendererOwnership(unittest.TestCase):
    def test_download_installer_rendering_has_one_source_owner(self):
        """Why: provisioning and managed updates must consume one verified renderer."""
        owner = _SRC_ROOT / "postgres_supply_chain.py"
        markers = (
            "WALG_INSTALLED=",
            "WALG_ASSETS_JSON",
            "_WALG_PG_TARBALL_CANDIDATES",
            "github.com/wal-g/wal-g/releases/download/",
            "github.com/paradedb/paradedb/releases/download/",
            "git -C /tmp/pgvector fetch",
            "/tmp/pg_search.deb",
        )
        offending = []
        for path in _iter_source_files(exclude=()):
            if path == owner:
                continue
            text = path.read_text(encoding="utf-8")
            for marker in markers:
                if marker in text:
                    offending.append(f"{path.relative_to(_SRC_ROOT)}: {marker}")
        self.assertEqual(
            offending,
            [],
            f"PostgreSQL download/install rendering belongs only in {owner.name}: {offending}",
        )


class TestNoIdentifierLeaksOutsideTheirOwnerModule(unittest.TestCase):
    def test_fixed_identifier_values_appear_only_in_their_owner_module(self):
        # Quote-bounded, not a bare substring search: "deploydash_caddy" is
        # also a prefix of the unrelated "deploydash_caddy_custom" image tag
        # in http_parts/part1_foundation.py, which a plain substring check
        # flagged as a false positive while building this guard.
        offending = []
        for resolved_defaults, identifier_keys, owner_relpath in _IDENTIFIER_SOURCES:
            for path in _iter_source_files(exclude=(owner_relpath,)):
                relpath = str(path.relative_to(_SRC_ROOT))
                if relpath in _IDENTIFIER_LEAK_EXCEPTIONS:
                    continue
                text = path.read_text(encoding="utf-8")
                for key in identifier_keys:
                    value = resolved_defaults[key]
                    pattern = re.compile(r"['\"]" + re.escape(value) + r"['\"]")
                    if pattern.search(text):
                        offending.append(
                            f"{path.relative_to(_SRC_ROOT)}: {key}={value!r} "
                            f"(owned by {owner_relpath})"
                        )
        self.assertEqual(
            offending,
            [],
            "These identifier literals duplicate a value RESOLVED_*_DEFAULTS "
            f"already owns -- read the value instead of retyping it: {offending}",
        )


if __name__ == "__main__":
    unittest.main()
