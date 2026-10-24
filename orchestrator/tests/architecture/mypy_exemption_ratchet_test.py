"""Architecture invariant: mypy exemptions are a shrinking, justified debt list.

Measurement: the configured exemption set may contain only modules that were
already exempt when this ratchet was established, and every remaining module
must still emit a strict-mypy diagnostic when checked without the exemption.
"""

from __future__ import annotations

import subprocess
import tempfile
import tomllib
import unittest
from collections import Counter
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parents[2]
PYPROJECT = BACKEND_ROOT / "pyproject.toml"

# T-2.1.6 baseline, recorded after removing the two plan-authored modules
# `server_layout` and `settings_ownership`. This is a ratchet fixture rather
# than a second runtime configuration: pyproject.toml remains the one owner of
# the exemptions mypy actually consumes. Every configured module maps to this
# reason; deleting the configuration entry is the only permitted direction.
_MYPY_EXEMPTION_REASON = (
    "Pre-existing strict-mypy debt: the module still emits a diagnostic when "
    "checked without ignore_errors, so its typing must be repaired before the "
    "exemption can be removed."
)
MYPY_EXEMPTION_REASONS = dict.fromkeys(
    {
        "orchestrator.app_parts",
        "orchestrator.app_parts.app_config",
        "orchestrator.app_parts.app_plan",
        "orchestrator.app_parts.common",
        "orchestrator.app_parts.part0_prepare_key",
        "orchestrator.app_parts.part1_deploy",
        "orchestrator.app_parts.repository_host_key",
        "orchestrator.app_parts.worker_runtime",
        "orchestrator.app_release_runtime",
        "orchestrator.backup_error_details",
        "orchestrator.container_status",
        "orchestrator.dns_parts",
        "orchestrator.dns_parts.common",
        "orchestrator.dns_parts.dns_config",
        "orchestrator.dns_parts.dns_plan",
        "orchestrator.dns_parts.part1_foundation",
        "orchestrator.dns_parts.part2_runtime",
        "orchestrator.embedded_runtime",
        "orchestrator.engine",
        "orchestrator.app_runtime_parts.*",
        "orchestrator.engine_bootstrap",
        "orchestrator.engine_firewall_ops",
        "orchestrator.infra_parts.*",
        "orchestrator.engine_metrics_parsers",
        "orchestrator.postgres_runtime_parts.*",
        "orchestrator.engine_runtime_common",
        "orchestrator.engine_scheduler_ops",
        "orchestrator.firewall_parts",
        "orchestrator.firewall_status",
        "orchestrator.http_parts",
        "orchestrator.http_parts.common",
        "orchestrator.http_parts.http_config",
        "orchestrator.http_parts.http_plan",
        "orchestrator.http_parts.part1_foundation",
        "orchestrator.http_parts.part2_runtime",
        "orchestrator.log_sanitizer",
        "orchestrator.managed_software",
        "orchestrator.postgres_backup",
        "orchestrator.postgres_parts",
        "orchestrator.postgres_parts.postgres_config",
        "orchestrator.pyinfra_runtime",
        "orchestrator.railpack_contract",
        "orchestrator.release_helpers",
        "orchestrator.runner",
        "orchestrator.scheduler_parts",
        "orchestrator.setup_parts.common",
        "orchestrator.setup_parts.part1_system_foundation",
        "orchestrator.setup_parts.part2_stability",
        "orchestrator.setup_parts.part3_docker_prep",
        "orchestrator.setup_parts.part4_passive_security",
        "orchestrator.setup_parts.part5_railpack_builds",
        "orchestrator.setup_parts.setup_config",
        "orchestrator.setup_parts.setup_plan",
        "orchestrator.setup_postflight",
        "orchestrator.setup_security",
        "orchestrator.ssh_hostkey",
        "orchestrator.task_runtime",
        "orchestrator.workflow_executor",
        "orchestrator.workflow_registry",
    },
    _MYPY_EXEMPTION_REASON,
)
BASELINE_EXEMPT_MODULES = frozenset(MYPY_EXEMPTION_REASONS)
MYPY_EXEMPTION_BASELINE_COUNT = 59

STRICT_MYPY_CONFIG = """[mypy]
python_version = 3.13
mypy_path = src
packages = orchestrator
strict = True
warn_unused_ignores = True
"""


def _configured_exempt_modules() -> set[str]:
    config = tomllib.loads(PYPROJECT.read_text(encoding="utf-8"))
    overrides = config["tool"]["mypy"].get("overrides", [])
    return {
        module
        for override in overrides
        if override.get("ignore_errors") is True
        for module in override["module"]
    }


def _module_for_source_path(source_path: str) -> str | None:
    source = Path(source_path)
    if not source.is_absolute():
        if source.parts and source.parts[0] == "orchestrator":
            module_parts = source.with_suffix("").parts
            if module_parts[-1] == "__init__":
                module_parts = module_parts[:-1]
            return ".".join(module_parts)
        source = BACKEND_ROOT / source
    try:
        relative = source.relative_to(BACKEND_ROOT / "src")
    except ValueError:
        return None
    module_parts = relative.with_suffix("").parts
    if module_parts[-1] == "__init__":
        module_parts = module_parts[:-1]
    return ".".join(module_parts)


def _strict_mypy_error_counts() -> Counter[str]:
    with tempfile.NamedTemporaryFile(
        mode="w", dir=BACKEND_ROOT, suffix=".ini", encoding="utf-8"
    ) as config_file:
        config_file.write(STRICT_MYPY_CONFIG)
        config_file.flush()
        completed = subprocess.run(
            [
                "uv",
                "run",
                "mypy",
                "--config-file",
                config_file.name,
                "-p",
                "orchestrator",
            ],
            cwd=BACKEND_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    if completed.returncode == 0:
        return Counter()

    error_counts: Counter[str] = Counter()
    for line in f"{completed.stdout}\n{completed.stderr}".splitlines():
        if ": error:" not in line:
            continue
        source_path, separator, _ = line.partition(":")
        if not separator:
            continue
        module = _module_for_source_path(source_path)
        if module is not None:
            error_counts[module] += 1
    if not error_counts:
        raise AssertionError(
            "stripped-config mypy run failed without source diagnostics:\\n"
            f"{completed.stdout}{completed.stderr}"
        )
    return error_counts


def _exemption_matches_module(exemption: str, module: str) -> bool:
    """Return whether a configured exact or package-glob exemption covers a module."""
    if exemption.endswith(".*"):
        return module.startswith(exemption.removesuffix("*"))
    return exemption == module


class TestMypyExemptionRatchet(unittest.TestCase):
    def test_exemptions_only_shrink_and_all_remaining_entries_still_need_them(self) -> None:
        """Rule: an exemption is temporary debt, never a permanent bypass."""
        configured_modules = _configured_exempt_modules()
        self.assertEqual(len(MYPY_EXEMPTION_REASONS), MYPY_EXEMPTION_BASELINE_COUNT)
        self.assertTrue(
            all(reason.strip() for reason in MYPY_EXEMPTION_REASONS.values()),
            "every mypy ignore_errors entry must carry a non-empty reason",
        )
        self.assertLessEqual(
            len(configured_modules),
            MYPY_EXEMPTION_BASELINE_COUNT,
            "mypy exemption count grew; type the module instead of adding debt",
        )
        additions = configured_modules - BASELINE_EXEMPT_MODULES
        self.assertFalse(
            additions,
            "mypy exemption list grew; type the module instead of adding a "
            f"new ignore_errors entry: {sorted(additions)}",
        )

        error_counts = _strict_mypy_error_counts()
        exemptions_that_now_pass = {
            exemption
            for exemption in configured_modules
            if not any(_exemption_matches_module(exemption, module) for module in error_counts)
        }
        self.assertFalse(
            exemptions_that_now_pass,
            "mypy exemptions that now pass strict checking must be removed: "
            f"{sorted(exemptions_that_now_pass)}",
        )


if __name__ == "__main__":
    unittest.main()
