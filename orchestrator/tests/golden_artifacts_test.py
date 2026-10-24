"""Golden files for every artifact this backend writes to a customer's machine.

A Caddyfile, a compose file, an sshd drop-in, `jail.local`, a systemd unit, a
firewall rule set: these are the actual output of the product. A silent change
to any of them is a production incident with **no local symptom** -- the tests
around them assert behaviour, and behaviour tests pass happily while the bytes
that reach the server drift.

Each generator below renders into `tests/golden/`, and the test compares the
rendered text with the committed file byte for byte.

**Updating a golden.**

    DEPLOYDASH_UPDATE_GOLDENS=1 uv run python -m unittest tests.golden_artifacts_test

That rewrites the files and **fails the run**, deliberately, so an update can
never be the thing that makes a red build green. Then read the diff. Every
line of it is a line that will land on a customer's server; if you cannot say
why a line changed, the change is not ready. `AGENTS.md` names accepting a
golden without reading it as a forbidden pattern, because a golden captured
from current output freezes current bugs and turns the eventual fix into what
looks like a regression.
"""

from __future__ import annotations

import json
import os
import pathlib
import typing
import unittest
from types import SimpleNamespace

from orchestrator import (
    engine_firewall_ops,
    engine_scheduler_ops,
    runtime_security,
    server_paths,
    setup_postflight,
)
from orchestrator.app_parts import parse_app_config
from orchestrator.app_parts.part1_deploy import _render_caddy_snippet
from orchestrator.dns_parts.dns_config import parse_dns_config
from orchestrator.dns_parts.part1_foundation import _render_compose as _render_dns_compose
from orchestrator.postgres_parts.postgres_config import parse_postgres_service_config
from orchestrator.postgres_runtime_parts.agent_access import (
    _parse_postgres_service_status_output,
)
from orchestrator.postgres_runtime_parts.service_configuration import (
    _postgres_base_env_bootstrap_command,
    _postgres_service_compose_text,
)
from orchestrator.setup_parts.part2_stability import _render_fail2ban_jail_local
from orchestrator.setup_security import build_onboarding_firewall_config

_GOLDEN_DIR = pathlib.Path(__file__).resolve().parent / "golden"
_UPDATING = os.environ.get("DEPLOYDASH_UPDATE_GOLDENS") == "1"


def _app_config(**settings):
    base = {
        "project_slug": "demo-app",
        "repository_full_name": "acme/demo-app",
        "branch": "main",
        "primary_domain": "demo.example.com",
        "app_port": 3000,
    }
    base.update(settings)
    return parse_app_config({"settings": base})


class GoldenArtifactTest(unittest.TestCase):
    """Every generated artifact, pinned to the byte."""

    maxDiff = None
    _written: typing.ClassVar[list[str]] = []

    def assertGolden(self, name: str, rendered: str) -> None:
        """Compare [rendered] with the committed golden [name]."""
        path = _GOLDEN_DIR / name
        if _UPDATING:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(rendered, encoding="utf-8")
            type(self)._written.append(name)
            return
        self.assertTrue(
            path.exists(),
            f"{name} has no golden file. Render it with "
            "DEPLOYDASH_UPDATE_GOLDENS=1, then read every line before "
            "committing it.",
        )
        self.assertEqual(
            path.read_text(encoding="utf-8"),
            rendered,
            f"{name} changed. This is text that lands on a customer's server: "
            "read the diff line by line before updating the golden.",
        )

    @classmethod
    def tearDownClass(cls) -> None:
        if _UPDATING:
            raise AssertionError(
                f"Rewrote {len(cls._written)} golden files. This run fails on "
                "purpose: updating a golden must never be what turns a red "
                "build green. Read the diff, then re-run without "
                "DEPLOYDASH_UPDATE_GOLDENS."
            )

    # --- fail2ban ---------------------------------------------------------

    def test_the_fail2ban_jail_local_written_during_onboarding(self) -> None:
        self.assertGolden("fail2ban/jail.local", _render_fail2ban_jail_local())

    # --- systemd ----------------------------------------------------------

    def test_the_scheduler_service_unit(self) -> None:
        self.assertGolden(
            "systemd/scheduler.service",
            engine_scheduler_ops._service_unit_text(
                "Nightly database backup",
                "/opt/deploydash/state/scheduler/demo-app/task-7/run.sh",
            ),
        )

    def test_the_scheduler_timer_unit_for_each_schedule_kind(self) -> None:
        for label, kind, interval, daily in (
            ("minutes", "every_minutes", 15, None),
            ("hours", "every_hours", 6, None),
            ("daily", "daily", None, "02:30"),
        ):
            with self.subTest(schedule=label):
                self.assertGolden(
                    f"systemd/scheduler-{label}.timer",
                    engine_scheduler_ops._timer_unit_text(
                        "deploydash-demo-app-task-7.service",
                        kind,
                        interval,
                        daily,
                    ),
                )

    # --- sshd -------------------------------------------------------------

    def test_the_sshd_hardening_command(self) -> None:
        self.assertGolden(
            "sshd/harden.command",
            setup_postflight.set_sshd_options_command(
                (("PermitRootLogin", "no"),),
            ),
        )

    def test_the_sshd_multi_option_command(self) -> None:
        self.assertGolden(
            "sshd/harden-multi.command",
            setup_postflight.set_sshd_options_command(
                (
                    ("PasswordAuthentication", "no"),
                    ("KbdInteractiveAuthentication", "no"),
                    ("Port", "2022"),
                ),
            ),
        )

    # --- compose ----------------------------------------------------------

    def test_the_bind9_compose_file(self) -> None:
        config = parse_dns_config(
            {
                "settings": {
                    "zone_name": "example.com",
                    "nameserver_ipv4": "203.0.113.10",
                },
            },
        )
        self.assertGolden("compose/bind9.yml", _render_dns_compose(config))

    def test_the_postgres_compose_file(self) -> None:
        config = parse_postgres_service_config({"settings": {}})
        self.assertGolden(
            "compose/postgres.yml",
            _postgres_service_compose_text(config),
        )

    def test_the_postgres_compose_file_with_preloaded_extensions(self) -> None:
        config = parse_postgres_service_config(
            {"settings": {"enabled_extensions": ["vector", "pg_search", "postgis"]}},
        )
        self.assertGolden(
            "compose/postgres-extensions.yml",
            _postgres_service_compose_text(config),
        )

    def test_postgres_compose_and_bootstrap_require_tls_for_tcp_clients(self) -> None:
        """The generated service must encrypt TCP and reject plaintext clients."""
        config = parse_postgres_service_config({"settings": {}})
        compose = _postgres_service_compose_text(config)
        bootstrap = _postgres_base_env_bootstrap_command(config)

        self.assertIn("ssl=on", compose)
        self.assertIn("ssl_cert_file=/run/deploydash-postgres-tls/server.crt", compose)
        self.assertIn("ssl_key_file=/run/deploydash-postgres-tls/server.key", compose)
        self.assertIn("hba_file=/run/deploydash-postgres-tls/pg_hba.conf", compose)
        self.assertIn("server.crt:/run/deploydash-postgres-tls/server.crt:ro", compose)
        self.assertIn("server.key:/run/deploydash-postgres-tls/server.key:ro", compose)
        self.assertIn("pg_hba.conf:/run/deploydash-postgres-tls/pg_hba.conf:ro", compose)
        self.assertIn("local all all trust", bootstrap)
        self.assertIn("hostssl all all 0.0.0.0/0 scram-sha-256", bootstrap)
        self.assertIn("hostssl all all ::/0 scram-sha-256", bootstrap)
        self.assertIn("hostnossl all all 0.0.0.0/0 reject", bootstrap)
        self.assertIn("hostnossl all all ::/0 reject", bootstrap)
        self.assertIn("openssl req -x509", bootstrap)
        self.assertIn("chmod 600", bootstrap)
        self.assertIn("TLS_CERTIFICATE_PUBLIC_KEY", bootstrap)
        self.assertIn("TLS_PRIVATE_KEY_PUBLIC_KEY", bootstrap)
        self.assertIn('test "${TLS_CERTIFICATE_PUBLIC_KEY}" =', bootstrap)

    def test_postgres_tls_paths_have_one_managed_owner(self) -> None:
        """Certificate and HBA files must remain inside the Postgres stack owner."""
        expected = {
            "postgres_tls_root": "/opt/deploydash/stack/postgres/tls",
            "postgres_tls_certificate": "/opt/deploydash/stack/postgres/tls/server.crt",
            "postgres_tls_private_key": "/opt/deploydash/stack/postgres/tls/server.key",
            "postgres_hba_file": "/opt/deploydash/stack/postgres/tls/pg_hba.conf",
        }
        for name, path in expected.items():
            with self.subTest(name=name):
                owner = getattr(server_paths, name, None)
                self.assertTrue(callable(owner))
                self.assertEqual(owner(), path)

    def test_postgres_status_exposes_public_tls_trust_material(self) -> None:
        """The desktop needs the public CA and fingerprint to guide remote clients."""
        output = SimpleNamespace(
            stdout_lines=[
                "configured=1",
                "container_present=1",
                "container_running=1",
                "container_health=healthy",
                "tls_enabled=1",
                "tls_ca_fingerprint=AA:BB:CC",
                "tls_ca_certificate_base64=Q0E=",
            ],
        )

        status = _parse_postgres_service_status_output(output)

        self.assertTrue(status["tls_enabled"])
        self.assertEqual(status["tls_ca_fingerprint"], "AA:BB:CC")
        self.assertEqual(status["tls_ca_certificate_base64"], "Q0E=")

    # --- Caddy ------------------------------------------------------------

    def test_the_caddy_route_for_each_routing_mode(self) -> None:
        for mode in (
            "single_host",
            "redirect_www_to_apex",
            "redirect_apex_to_www",
        ):
            with self.subTest(mode=mode):
                self.assertGolden(
                    f"caddy/{mode}.caddy",
                    _render_caddy_snippet(_app_config(domain_routing_mode=mode)),
                )

    def test_the_caddy_default_response_headers(self) -> None:
        for label, hsts in (("https", True), ("http", False)):
            with self.subTest(scheme=label):
                self.assertGolden(
                    f"caddy/headers-{label}.txt",
                    "\n".join(
                        runtime_security.caddy_default_header_lines(include_hsts=hsts),
                    )
                    + "\n",
                )

    # --- firewall ---------------------------------------------------------

    def test_the_effective_firewall_rules_for_onboarding_and_full_services(
        self,
    ) -> None:
        """What each configuration actually opens, resolved to a rule list.

        The applied `iptables` commands need a live host, but the decision
        does not: this is the function that turns "allow PostgreSQL" into a
        port, and a silent change to it changes a customer's exposure.
        """
        for label, config in (
            ("onboarding", build_onboarding_firewall_config(22)),
            (
                "all-services",
                {
                    **build_onboarding_firewall_config(2022),
                    "allow_postgres": True,
                    "postgres_source_cidrs": [],
                    "allow_dns": True,
                    "allow_smtp": True,
                    "allow_mail_receive": True,
                },
            ),
        ):
            with self.subTest(config=label):
                self.assertGolden(
                    f"firewall/{label}.json",
                    json.dumps(
                        engine_firewall_ops._effective_allow_rules(config),
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                )

    # --- container hardening ---------------------------------------------

    def test_the_container_hardening_lines_for_each_profile(self) -> None:
        for label, kwargs in (
            ("strict", {}),
            ("caddy", {"cap_add": ("NET_BIND_SERVICE",)}),
            # The profile managed app, worker and PostgreSQL containers use:
            # they keep the shared pids limit but not `no-new-privileges` or
            # `cap-drop ALL`, because a Railpack runtime or a database
            # entrypoint may need a privilege transition before dropping.
            (
                "entrypoint-compatible",
                {"profile": runtime_security.ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING},
            ),
        ):
            with self.subTest(profile=label):
                self.assertGolden(
                    f"hardening/{label}.yml",
                    runtime_security.docker_compose_security_lines(**kwargs),
                )


if __name__ == "__main__":
    unittest.main()
