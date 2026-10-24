import unittest

from orchestrator.http_parts.http_config import parse_http_config
from orchestrator.http_parts.part2_runtime import build_steps


class _RuntimeRecorder:
    def __init__(self):
        self.operations = []

    def add_operation(self, operation, **kwargs):
        name = getattr(operation, "__name__", str(operation))
        self.operations.append((name, kwargs))


class TestHttpPart2Runtime(unittest.TestCase):
    def test_runtime_step_registers_typed_docker_operations(self) -> None:
        """Keep Compose and standalone container commands typed with exact argv."""
        config = parse_http_config({}, connection_ip="198.51.100.25")
        step = build_steps(config)[0]
        runtime = _RuntimeRecorder()

        step.register(runtime)

        self.assertEqual(len(runtime.operations), 8)
        self.assertEqual(
            [name for name, _ in runtime.operations],
            [
                "shell",
                "shell",
                "compose",
                "container_exec",
                "container_exec",
                "shell",
                "shell",
                "shell",
            ],
        )

        compose_kwargs = runtime.operations[2][1]
        self.assertEqual(
            compose_kwargs,
            {
                "project_directory": "/opt/deploydash/stack/http",
                "files": ["/opt/deploydash/stack/http/docker-compose.yml"],
                "build": True,
            },
        )
        self.assertEqual(
            runtime.operations[3][1],
            {
                "container": "deploydash_caddy",
                "command": ["caddy", "validate", "--config", "/etc/caddy/Caddyfile"],
            },
        )
        self.assertEqual(
            runtime.operations[4][1],
            {
                "container": "deploydash_caddy",
                "command": ["caddy", "reload", "--config", "/etc/caddy/Caddyfile"],
            },
        )

        all_commands = []
        for _name, kwargs in runtime.operations:
            all_commands.extend(kwargs.get("commands", []))
        joined = "\n".join(all_commands)

        self.assertIn("docker --version", joined)
        self.assertIn("docker compose version", joined)
        self.assertIn(
            "docker compose -f /opt/deploydash/stack/http/docker-compose.yml config -q", joined
        )
        self.assertNotIn(" up -d ", joined)
        self.assertIn("docker update --restart unless-stopped deploydash_caddy", joined)
        self.assertIn("{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}", joined)

        health_kwargs = runtime.operations[-1][1]
        self.assertEqual(health_kwargs.get("_retries"), 10)
        self.assertEqual(health_kwargs.get("_retry_delay"), 3)


if __name__ == "__main__":
    unittest.main()
