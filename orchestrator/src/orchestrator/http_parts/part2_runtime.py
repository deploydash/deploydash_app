import shlex

from pyinfra.operations import docker, server

from ..container_status import caddy_service_readiness_check_shell
from .common import HttpAction, HttpStep
from .http_config import HttpConfig


def build_steps(config: HttpConfig):
    compose_file = f"{config.stack_root}/docker-compose.yml"
    quoted_compose_file = shlex.quote(compose_file)
    quoted_container_name = shlex.quote(config.container_name)
    health_status_command = (
        "docker inspect -f "
        "'{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "
        f"{quoted_container_name}"
    )

    def register_step(runtime):
        runtime.add_operation(
            server.shell,
            commands=[
                "docker --version",
                "docker compose version",
            ],
        )
        runtime.add_operation(
            server.shell,
            commands=[
                f"docker compose -f {quoted_compose_file} config -q",
            ],
        )
        runtime.add_operation(
            docker.compose,
            project_directory=config.stack_root,
            files=[compose_file],
            build=True,
        )
        runtime.add_operation(
            docker.container_exec,
            container=config.container_name,
            command=["caddy", "validate", "--config", "/etc/caddy/Caddyfile"],
        )
        runtime.add_operation(
            docker.container_exec,
            container=config.container_name,
            command=["caddy", "reload", "--config", "/etc/caddy/Caddyfile"],
        )
        runtime.add_operation(
            server.shell,
            commands=[
                f"docker update --restart unless-stopped {quoted_container_name}",
            ],
        )
        runtime.add_operation(
            server.shell,
            commands=[
                caddy_service_readiness_check_shell(quoted_container_name),
            ],
        )
        runtime.add_operation(
            server.shell,
            commands=[
                f"{health_status_command} | grep -q healthy",
            ],
            _retries=10,
            _retry_delay=3,
        )

    return [
        HttpStep(
            id="http_part2_step1_start_caddy_gateway",
            title="Start Caddy gateway and enforce resilience",
            part="part2",
            commands=[
                "Verify Docker engine and compose plugin availability",
                "Validate docker compose stack file",
                "Bring up caddy container with docker compose",
                "Validate and reload active Caddy configuration",
                "Enforce restart policy and verify Caddy readiness",
                "Verify container healthcheck reaches healthy status",
            ],
            actions=[
                HttpAction(
                    id="http_part2_step1_action_verify_docker",
                    label="Verify Docker runtime",
                    description="Confirm Docker engine and compose availability",
                ),
                HttpAction(
                    id="http_part2_step1_action_validate_compose",
                    label="Validate compose file",
                    description="Ensure docker-compose.yml parses correctly",
                ),
                HttpAction(
                    id="http_part2_step1_action_up_stack",
                    label="Start Caddy stack",
                    description="Launch Caddy container on ports 80/443",
                ),
                HttpAction(
                    id="http_part2_step1_action_validate_config",
                    label="Validate Caddy configuration",
                    description="Check merged Caddyfile before reload",
                ),
                HttpAction(
                    id="http_part2_step1_action_reload_config",
                    label="Reload Caddy configuration",
                    description="Apply latest modular routing snippets",
                ),
                HttpAction(
                    id="http_part2_step1_action_restart_policy",
                    label="Enforce restart policy",
                    description="Keep Caddy alive after crash or reboot",
                ),
                HttpAction(
                    id="http_part2_step1_action_verify_running",
                    label="Verify Caddy readiness",
                    description="Confirm Caddy is running and its configuration validates",
                ),
                HttpAction(
                    id="http_part2_step1_action_verify_health",
                    label="Verify container health",
                    description="Confirm healthcheck reports healthy status",
                ),
            ],
            register=register_step,
        ),
    ]
