import unittest

from orchestrator.dns_parts.dns_config import CANONICAL_DNS_SETTINGS, parse_dns_config
from orchestrator.dns_parts.part2_runtime import build_steps
from orchestrator.settings_ownership import wire_defaults


class _FakeRuntime:
    def __init__(self):
        self.operations = []
        self.enabled_services = []

    def add_operation(self, operation, **kwargs):
        self.operations.append(
            {
                "operation": operation,
                "kwargs": kwargs,
            }
        )

    def ensure_service_enabled(self, service_name):
        """Capture use of the session-owned service enablement boundary."""
        self.enabled_services.append(service_name)


def _config():
    settings = wire_defaults(CANONICAL_DNS_SETTINGS)
    settings["nameserver_ipv4"] = "203.0.113.10"
    return parse_dns_config({"settings": settings}, connection_ip="203.0.113.10")


class TestDnsPart2Runtime(unittest.TestCase):
    def test_register_step_uses_shared_docker_service_owner(self) -> None:
        """Require one service owner and an exact Docker active-state check."""
        step = build_steps(_config())[0]
        runtime = _FakeRuntime()

        step.register(runtime)

        command_lists = []
        for record in runtime.operations:
            commands = record["kwargs"].get("commands")
            if isinstance(commands, list):
                command_lists.append(commands)

        flattened = [command for commands in command_lists for command in commands]

        self.assertEqual(runtime.enabled_services, ["docker"])
        self.assertIn("systemctl is-active --quiet docker", flattened)
        self.assertNotIn("systemctl enable --now docker", flattened)
        self.assertFalse(any("systemctl is-enabled docker" in command for command in flattened))
        self.assertIn(
            "docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "
            "deploydash_bind9 | grep -q unless-stopped",
            flattened,
        )
        self.assertIn(
            "/usr/local/bin/deploydash-bind-apply /opt/deploydash/stack/dns deploydash_bind9",
            flattened,
        )
        self.assertIn(
            "docker port deploydash_bind9 53/udp | grep -q .",
            flattened,
        )
        self.assertIn(
            "docker port deploydash_bind9 53/tcp | grep -q .",
            flattened,
        )
        self.assertFalse(any("ss -lntup" in command for command in flattened))
        self.assertTrue(
            any("/bind/zones.conf" in command for command in flattened),
        )
        self.assertTrue(
            any(
                "docker run --rm --network host --entrypoint dig "
                "internetsystemsconsortium/bind9:9.20 "
                '@203.0.113.10 "${zone}" SOA +short' in command
                for command in flattened
            ),
        )
        self.assertTrue(
            any(
                "docker run --rm --network host --entrypoint dig "
                "internetsystemsconsortium/bind9:9.20 "
                '+tcp @203.0.113.10 "${zone}" SOA +short' in command
                for command in flattened
            ),
        )
        self.assertFalse(
            any(".deploydash-zones" in command for command in flattened),
        )

    def test_step_metadata_includes_enable_docker_action(self):
        step = build_steps(_config())[0]
        action_ids = [action.id for action in step.actions]

        self.assertIn("dns_part2_step1_action_enable_docker_service", action_ids)


if __name__ == "__main__":
    unittest.main()
