import html
from io import StringIO
from pathlib import Path

from pyinfra.operations import files

from .. import server_identifiers, server_paths
from ..addressing import format_url_host
from ..container_status import caddy_service_readiness_check_shell
from ..runtime_security import caddy_default_header_lines, docker_compose_security_lines
from .common import HttpAction, HttpStep
from .http_config import HttpConfig

_DEFAULT_PAGE_TEMPLATE_PATH = Path(__file__).with_name("index.html")
_CUSTOM_CADDY_IMAGE = server_identifiers.caddy_custom_image()

_DNS_PROVIDER_MODULES = (
    ("cloudflare", "github.com/caddy-dns/cloudflare@v0.2.4"),
    ("porkbun", "github.com/caddy-dns/porkbun@v0.3.1"),
    ("namecheap", "github.com/caddy-dns/namecheap@v1.0.0"),
    ("cloudns", "github.com/caddy-dns/cloudns@v1.1.0"),
    ("easydns", "github.com/caddy-dns/easydns@v1.1.1"),
)


def _render_default_site_body(config: HttpConfig, *, include_hsts: bool):
    lines = ["    root * /srv/default-site"]
    if config.enable_response_compression:
        lines.append("    encode zstd gzip")
    if config.enable_access_logs:
        lines.append("    log")
    lines.extend(f"    {line}" for line in caddy_default_header_lines(include_hsts=include_hsts))
    lines.append("    file_server")
    return "\n".join(lines) + "\n"


def _render_root_caddyfile(config: HttpConfig):
    global_options = []
    if config.enable_on_demand_tls:
        global_options.extend(
            [
                "    # Restrict On-Demand TLS issuance with an approval endpoint.",
                "    on_demand_tls {",
                f"        ask {config.on_demand_tls_ask_endpoint}",
                "    }",
            ]
        )

    lines = []
    if global_options:
        lines.extend(["{", *global_options, "}", ""])

    lines.extend(
        [
            "# Site blocks are loaded from modular snippets.",
            "import /etc/caddy/conf.d/*.caddy",
            "",
        ]
    )
    return "\n".join(lines)


def _render_default_site_config(config: HttpConfig):
    formatted_server_address = format_url_host(config.server_address)
    blocks = [
        (
            config.default_hostname,
            _render_default_site_body(config, include_hsts=True),
        ),
        (
            f"http://{formatted_server_address}",
            _render_default_site_body(config, include_hsts=False),
        ),
    ]
    if config.serve_ip_over_https:
        blocks.append(
            (
                f"https://{formatted_server_address}",
                f"    tls internal\n{_render_default_site_body(config, include_hsts=True)}",
            ),
        )
    blocks.append(
        (
            "http://",
            _render_default_site_body(config, include_hsts=False),
        ),
    )
    if config.enable_on_demand_tls:
        blocks.append(
            (
                "https://",
                "    tls {\n"
                "        on_demand\n"
                "    }\n"
                f"{_render_default_site_body(config, include_hsts=True)}",
            ),
        )

    rendered = []
    for site_label, body in blocks:
        rendered.append(f"{site_label} {{\n{body}}}\n")
    return "\n".join(rendered)


def _render_default_page(_config: HttpConfig):
    try:
        template = _DEFAULT_PAGE_TEMPLATE_PATH.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise RuntimeError(
            f"Missing default page template: {_DEFAULT_PAGE_TEMPLATE_PATH}",
        ) from exc
    return template.replace(
        "{{DEFAULT_PAGE_TITLE}}", html.escape(_config.default_page_title)
    ).replace(
        "{{DEFAULT_PAGE_MESSAGE}}",
        html.escape(_config.default_page_message),
    )


def _enabled_dns_provider_modules(config: HttpConfig):
    enabled_providers = {
        "cloudflare": config.enable_dns_plugin_cloudflare,
        "porkbun": config.enable_dns_plugin_porkbun,
        "namecheap": config.enable_dns_plugin_namecheap,
        "cloudns": config.enable_dns_plugin_cloudns,
        "easydns": config.enable_dns_plugin_easydns,
    }
    return [
        (provider, module)
        for provider, module in _DNS_PROVIDER_MODULES
        if enabled_providers.get(provider) is True
    ]


def caddy_builder_image(caddy_image):
    """Derive the xcaddy builder tag for a Caddy base image.

    Shared by the Dockerfile renderer and the gateway update path, which
    rewrites the builder stage when it rebuilds a custom stack.
    """
    image = caddy_image.strip()
    if ":" in image:
        _, tag = image.rsplit(":", 1)
        version = tag.split("-", 1)[0].strip()
        if version and version != "latest":
            return f"caddy:{version}-builder"
    return "caddy:builder"


def _builder_image_for(config: HttpConfig):
    return caddy_builder_image(config.caddy_image)


def _render_caddy_plugin_dockerfile(config: HttpConfig):
    enabled_modules = _enabled_dns_provider_modules(config)
    if not enabled_modules:
        return None
    plugin_flags = " \\\n    ".join(f"--with {module}" for _, module in enabled_modules)
    # A Dockerfile LABEL lands in the image config exactly like
    # docker build --label, and survives whichever frontend (compose
    # build, plain build) produces the image -- compose build has no
    # --label flag of its own.
    return (
        f"FROM {_builder_image_for(config)} AS builder\n"
        "RUN xcaddy build \\\n"
        f"    {plugin_flags}\n\n"
        f"FROM {config.caddy_image}\n"
        f'LABEL {server_identifiers.LABEL_CADDY_BASE}="{config.caddy_image}"\n'
        "COPY --from=builder /usr/bin/caddy /usr/bin/caddy\n"
    )


def _render_compose(config: HttpConfig):
    use_custom_caddy = bool(_enabled_dns_provider_modules(config))
    image_line = (
        f"    image: {_CUSTOM_CADDY_IMAGE}\n"
        if use_custom_caddy
        else f"    image: {config.caddy_image}\n"
    )
    build_block = (
        f"    build:\n      context: {config.stack_root}/caddy\n      dockerfile: Dockerfile\n"
        if use_custom_caddy
        else ""
    )
    return (
        "services:\n"
        "  caddy:\n"
        f"    container_name: {config.container_name}\n"
        f"{image_line}"
        f"{build_block}"
        "    restart: unless-stopped\n"
        f"{docker_compose_security_lines(cap_add=('NET_BIND_SERVICE',))}"
        "    ports:\n"
        '      - "80:80"\n'
        '      - "443:443"\n'
        '      - "443:443/udp"\n'
        "    volumes:\n"
        f"      - {config.stack_root}/caddy/Caddyfile:/etc/caddy/Caddyfile:ro\n"
        f"      - {config.stack_root}/caddy/conf.d:/etc/caddy/conf.d:ro\n"
        f"      - {config.stack_root}/site/default:/srv/default-site:ro\n"
        f"      - {config.stack_root}/data:/data\n"
        f"      - {config.stack_root}/config:/config\n"
        "    env_file:\n"
        f"      - {config.stack_root}/caddy/.env\n"
        "    healthcheck:\n"
        '      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:80/ || exit 1"]\n'
        "      interval: 30s\n"
        "      timeout: 5s\n"
        "      retries: 5\n"
        "      start_period: 15s\n"
        "    networks:\n"
        f"      - {server_identifiers.HTTP_NETWORK}\n"
        "\n"
        "networks:\n"
        f"  {server_identifiers.HTTP_NETWORK}:\n"
        "    driver: bridge\n"
    )


def _render_conf_readme(config: HttpConfig):
    return (
        "# Caddy snippet directory\n\n"
        "Create one file per domain/app route. Keep each app isolated in its own\n"
        "snippet so a single change does not require rewriting all config.\n\n"
        "Example snippet (`10-app.example.com.caddy`):\n\n"
        "```\n"
        "app.example.com {\n"
        "    reverse_proxy app_web:8000\n"
        "}\n"
        "```\n\n"
        "Default fallback model:\n\n"
        "- `http://` catch-all serves the default landing page.\n"
        f"- `{config.default_hostname}` uses normal automatic HTTPS.\n"
        "- HTTPS catch-all is only enabled when On-Demand TLS is explicitly\n"
        "  enabled with a valid `on_demand_tls` ask endpoint.\n\n"
        "After adding/updating a snippet, apply safely:\n\n"
        f"`{server_paths.caddy_apply_helper()} {config.stack_root}`\n"
    )


def _render_apply_script(config: HttpConfig):
    container_ref = '"${CONTAINER_NAME}"'
    return (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n\n"
        f'STACK_ROOT="${{1:-{config.stack_root}}}"\n'
        f'CONTAINER_NAME="${{2:-{config.container_name}}}"\n'
        'COMPOSE_FILE="${STACK_ROOT}/docker-compose.yml"\n\n'
        'docker compose -f "${COMPOSE_FILE}" config -q\n'
        'docker compose -f "${COMPOSE_FILE}" up -d caddy\n'
        f"{caddy_service_readiness_check_shell(container_ref)}\n"
        'docker exec "${CONTAINER_NAME}" caddy reload --config /etc/caddy/Caddyfile >/dev/null\n'
        "if docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \"${CONTAINER_NAME}\" | grep -q none; then\n"
        "    exit 0\n"
        "fi\n"
        "for _ in $(seq 1 20); do\n"
        "    status=\"$(docker inspect -f '{{.State.Health.Status}}' "
        '"${CONTAINER_NAME}")"\n'
        '    if [ "${status}" = "healthy" ]; then\n'
        "        exit 0\n"
        "    fi\n"
        "    sleep 2\n"
        "done\n"
        'echo "Caddy container healthcheck did not reach healthy state." >&2\n'
        "exit 1\n"
    )


def build_steps(config: HttpConfig):
    stack_root = config.stack_root
    plugin_dockerfile = _render_caddy_plugin_dockerfile(config)

    def register_step(runtime):
        for path in (
            stack_root,
            f"{stack_root}/caddy",
            f"{stack_root}/caddy/conf.d",
            f"{stack_root}/site",
            f"{stack_root}/site/default",
            f"{stack_root}/data",
            f"{stack_root}/config",
        ):
            runtime.add_operation(
                files.directory,
                path=path,
                mode="755",
            )

        runtime.add_operation(
            files.put,
            src=StringIO(_render_root_caddyfile(config)),
            dest=f"{stack_root}/caddy/Caddyfile",
            mode="644",
        )
        # Ensure the file exists and lock its mode, but never write
        # content: app deploys own every line in it (each project's
        # DNS-challenge credentials), and an empty put here wiped them on
        # every configure and setup re-run (#120).
        runtime.add_operation(
            files.file,
            path=f"{stack_root}/caddy/.env",
            mode="600",
        )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_default_site_config(config)),
            dest=f"{stack_root}/caddy/conf.d/00-default.caddy",
            mode="644",
        )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_conf_readme(config)),
            dest=f"{stack_root}/caddy/conf.d/README.md",
            mode="644",
        )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_default_page(config)),
            dest=f"{stack_root}/site/default/index.html",
            mode="644",
        )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_compose(config)),
            dest=f"{stack_root}/docker-compose.yml",
            mode="644",
        )
        if plugin_dockerfile is None:
            runtime.add_operation(
                files.file,
                path=f"{stack_root}/caddy/Dockerfile",
                present=False,
            )
        else:
            runtime.add_operation(
                files.put,
                src=StringIO(plugin_dockerfile),
                dest=f"{stack_root}/caddy/Dockerfile",
                mode="644",
            )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_apply_script(config)),
            dest=server_paths.caddy_apply_helper(),
            mode="755",
        )

    return [
        HttpStep(
            id="http_part1_step1_scaffold_caddy_stack",
            title="Create modular Caddy stack files",
            part="part1",
            commands=[
                f"Create {server_paths.http_root()} directory layout",
                "Write base Caddyfile with conf.d import",
                "Write default hostname/IP/fallback site snippet",
                "Write default index page and docker-compose file",
                "Install safe apply helper for future domain updates",
            ],
            actions=[
                HttpAction(
                    id="http_part1_step1_action_create_directories",
                    label="Create HTTP stack directories",
                    description="Create persistent Caddy stack folder structure",
                ),
                HttpAction(
                    id="http_part1_step1_action_write_caddyfile",
                    label="Write base Caddyfile",
                    description="Enable modular conf.d snippet imports",
                ),
                HttpAction(
                    id="http_part1_step1_action_write_default_snippet",
                    label="Write default routing snippet",
                    description="Serve host defaults and safe fallback routes",
                ),
                HttpAction(
                    id="http_part1_step1_action_write_default_page",
                    label="Write default landing page",
                    description="Provide default HTTP response page content",
                ),
                HttpAction(
                    id="http_part1_step1_action_write_compose",
                    label="Write Docker Compose stack",
                    description="Define Caddy ports, volumes, and healthcheck",
                ),
                HttpAction(
                    id="http_part1_step1_action_write_apply_script",
                    label="Install apply helper script",
                    description="Validate compose/config, reload, and verify health",
                ),
            ],
            register=register_step,
        ),
    ]
