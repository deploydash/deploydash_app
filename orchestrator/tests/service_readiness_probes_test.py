import shlex
import unittest

from orchestrator.container_status import (
    bind_service_readiness_check_shell,
    caddy_service_readiness_check_shell,
    postgres_service_readiness_check_shell,
    postgres_service_readiness_wait_shell,
)

# Why: byte-exact pins of the three readiness probes so the B-27 collapse
# (T-154) can prove the emitted shell is unchanged. Expected strings are
# written literally from the code, not computed by the code under test.
_GATE = (
    "command -v docker >/dev/null 2>&1 && "
    "docker inspect -f '{{.State.Running}}' web 2>/dev/null | grep -q true"
)

_CADDY_EXPECTED = (
    _GATE
    + " && docker exec web caddy validate "
    + "--config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1"
)

_NAMED_PROBE = "'pidof named >/dev/null 2>&1 || pgrep -x named >/dev/null 2>&1'"

_BIND_EXPECTED = (
    _GATE
    + " && docker exec web sh -c "
    + _NAMED_PROBE
    + " >/dev/null 2>&1 && docker exec web "
    + "named-checkconf /etc/bind/named.conf >/dev/null 2>&1"
)

_POSTGRES_EXPECTED = (
    _GATE + " && docker exec web pg_isready -U deploy_owner -d postgres >/dev/null 2>&1"
)


class ServiceReadinessProbesTest(unittest.TestCase):
    def test_caddy_probe_emits_exact_shell(self):
        self.assertEqual(
            caddy_service_readiness_check_shell("web"),
            _CADDY_EXPECTED,
        )

    def test_bind_probe_emits_exact_shell_with_two_exec_stages(self):
        emitted = bind_service_readiness_check_shell("web")

        self.assertEqual(emitted, _BIND_EXPECTED)
        self.assertEqual(emitted.count("docker exec web"), 2)

    def test_bind_probe_quotes_pidof_pgrep_fragment(self):
        self.assertEqual(
            shlex.quote("pidof named >/dev/null 2>&1 || pgrep -x named >/dev/null 2>&1"),
            _NAMED_PROBE,
        )
        self.assertIn(_NAMED_PROBE, bind_service_readiness_check_shell("web"))

    def test_postgres_probe_emits_exact_shell(self):
        self.assertEqual(
            postgres_service_readiness_check_shell("web", "deploy_owner"),
            _POSTGRES_EXPECTED,
        )

    def test_container_refs_stay_unquoted(self):
        # Why: refs are interpolated unquoted today; adding quoting would
        # change shipped shell, so the collapse must preserve this.
        emitted = caddy_service_readiness_check_shell("my-app_2.test")
        self.assertIn("docker exec my-app_2.test ", emitted)
        self.assertNotIn("'my-app_2.test'", emitted)
        self.assertNotIn('"my-app_2.test"', emitted)

    def test_gate_and_fragment_join_with_single_and_and(self):
        for emitted in (
            caddy_service_readiness_check_shell("web"),
            postgres_service_readiness_check_shell("web", "deploy_owner"),
        ):
            self.assertTrue(emitted.startswith(_GATE + " && docker exec web "))

    def test_wait_shell_embeds_postgres_probe_verbatim(self):
        probe = postgres_service_readiness_check_shell("web", "deploy_owner")
        waited = postgres_service_readiness_wait_shell("web", "deploy_owner")

        self.assertIn(f"if {probe}; then POSTGRES_READY=1; break; fi;", waited)
        self.assertTrue(waited.startswith("POSTGRES_READY=0; ATTEMPT=1; "))


if __name__ == "__main__":
    unittest.main()
