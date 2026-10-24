import unittest
from pathlib import Path
from unittest.mock import patch

from orchestrator.http_parts.http_config import HttpConfig
from orchestrator.http_parts.part1_foundation import (
    _builder_image_for,
    _render_apply_script,
    _render_caddy_plugin_dockerfile,
    _render_compose,
    _render_conf_readme,
    _render_default_page,
    _render_default_site_config,
    _render_root_caddyfile,
    build_steps,
)


def _base_config(**overrides):
    # Constructs the frozen HttpConfig directly, not a wire payload, so
    # stack_root belongs here: it is a resolved field of the config object.
    values = {
        "stack_root": "/opt/deploydash/stack/http",
        "container_name": "deploydash_caddy",
        "caddy_image": "caddy:2.11.2-alpine",
        "default_hostname": "edge.example.com",
        "server_address": "198.51.100.8",
        "default_page_title": "Deploy Dash HTTP gateway is online",
        "default_page_message": "Caddy gateway ready.",
        "serve_ip_over_https": True,
        "enable_https_redirect": True,
        "enable_response_compression": True,
        "enable_access_logs": False,
        "enable_on_demand_tls": False,
        "on_demand_tls_ask_endpoint": None,
        "enable_dns_plugin_cloudflare": False,
        "enable_dns_plugin_porkbun": False,
        "enable_dns_plugin_namecheap": False,
        "enable_dns_plugin_cloudns": False,
        "enable_dns_plugin_easydns": False,
    }
    values.update(overrides)
    return HttpConfig(**values)


class TestPart1Foundation(unittest.TestCase):
    def test_root_caddyfile_import_outside_global_block(self):
        rendered = _render_root_caddyfile(_base_config())

        self.assertIn("import /etc/caddy/conf.d/*.caddy", rendered)
        self.assertFalse(rendered.lstrip().startswith("{"))

    def test_default_site_config_has_http_fallback_and_no_fake_443(self):
        rendered = _render_default_site_config(_base_config())

        self.assertIn("http:// {", rendered)
        self.assertNotIn(":443 {", rendered)
        self.assertNotIn("https:// {\n    tls {\n        on_demand", rendered)

    def test_default_site_config_brackets_ipv6_addresses(self):
        rendered = _render_default_site_config(
            _base_config(server_address="2001:db8::8"),
        )
        self.assertIn("http://[2001:db8::8] {", rendered)
        self.assertIn("https://[2001:db8::8] {", rendered)

    def test_on_demand_tls_mode_is_gated_and_ask_protected(self):
        config = _base_config(
            enable_on_demand_tls=True,
            on_demand_tls_ask_endpoint="http://127.0.0.1:9123/ask",
        )

        root_rendered = _render_root_caddyfile(config)
        site_rendered = _render_default_site_config(config)

        self.assertIn("on_demand_tls {", root_rendered)
        self.assertIn("ask http://127.0.0.1:9123/ask", root_rendered)
        self.assertIn("https:// {", site_rendered)
        self.assertIn("on_demand", site_rendered)

    def test_compose_uses_stock_image_when_dns_plugins_disabled(self):
        rendered = _render_compose(_base_config())

        self.assertIn("image: caddy:2.11.2-alpine", rendered)
        self.assertIn("security_opt:\n      - no-new-privileges:true", rendered)
        self.assertIn("cap_drop:\n      - ALL", rendered)
        self.assertIn("cap_add:\n      - NET_BIND_SERVICE", rendered)
        self.assertIn("pids_limit: 512", rendered)
        self.assertIn("env_file:", rendered)
        self.assertIn("/opt/deploydash/stack/http/caddy/.env", rendered)
        self.assertNotIn("build:", rendered)

    def test_compose_uses_custom_build_when_dns_plugins_enabled(self):
        rendered = _render_compose(
            _base_config(
                enable_dns_plugin_cloudflare=True,
                enable_dns_plugin_easydns=True,
            )
        )

        self.assertIn("image: deploydash_caddy_custom:local", rendered)
        self.assertIn("build:", rendered)
        self.assertIn("dockerfile: Dockerfile", rendered)

    def test_plugin_dockerfile_contains_selected_modules_only(self):
        rendered = _render_caddy_plugin_dockerfile(
            _base_config(
                enable_dns_plugin_cloudflare=True,
                enable_dns_plugin_namecheap=True,
            )
        )

        self.assertIsNotNone(rendered)
        self.assertIn("--with github.com/caddy-dns/cloudflare@v0.2.4", rendered)
        self.assertIn("--with github.com/caddy-dns/namecheap@v1.0.0", rendered)
        self.assertNotIn("--with github.com/caddy-dns/dnsimple", rendered)

    # The custom build stamps the stock base image as a label, so a
    # later status read can tell a current custom build from a stale one
    # without parsing tags (#91). A Dockerfile LABEL lands in the image
    # config exactly like docker build --label, and survives whichever
    # frontend (compose build, plain build) produces the image.
    def test_plugin_dockerfile_labels_the_stock_base_image(self):
        rendered = _render_caddy_plugin_dockerfile(
            _base_config(enable_dns_plugin_cloudflare=True),
        )

        self.assertIsNotNone(rendered)
        self.assertIn(
            'LABEL deploydash.caddy_base="caddy:2.11.2-alpine"',
            rendered,
        )

    # The gateway update path reuses the builder-tag derivation to rewrite
    # the Dockerfile's builder stage, so it lives behind one public name.
    def test_builder_image_derivation_is_shared_with_gateway_update(self):
        from orchestrator.http_parts.part1_foundation import caddy_builder_image

        self.assertEqual(
            caddy_builder_image("caddy:2.11.2-alpine"),
            "caddy:2.11.2-builder",
        )
        self.assertEqual(caddy_builder_image("caddy"), "caddy:builder")

    def test_plugin_dockerfile_pins_all_supported_dns_modules(self):
        rendered = _render_caddy_plugin_dockerfile(
            _base_config(
                enable_dns_plugin_cloudflare=True,
                enable_dns_plugin_porkbun=True,
                enable_dns_plugin_namecheap=True,
                enable_dns_plugin_cloudns=True,
                enable_dns_plugin_easydns=True,
            )
        )

        self.assertIsNotNone(rendered)
        self.assertIn("--with github.com/caddy-dns/cloudflare@v0.2.4", rendered)
        self.assertIn("--with github.com/caddy-dns/porkbun@v0.3.1", rendered)
        self.assertIn("--with github.com/caddy-dns/namecheap@v1.0.0", rendered)
        self.assertIn("--with github.com/caddy-dns/cloudns@v1.1.0", rendered)
        self.assertIn("--with github.com/caddy-dns/easydns@v1.1.1", rendered)
        self.assertNotIn("dnsimple", rendered)

    def test_default_site_body_enables_access_log_when_requested(self):
        rendered = _render_default_site_config(
            _base_config(enable_access_logs=True),
        )
        self.assertIn("log", rendered)

    # Gap-fill: the compression-disabled branch renders no encode line.
    def test_default_site_body_omits_encode_without_compression(self):
        rendered = _render_default_site_config(
            _base_config(enable_response_compression=False),
        )
        self.assertNotIn("encode zstd gzip", rendered)

    # Gap-fill: with serve_ip_over_https off there is no https://ip block.
    def test_default_site_config_omits_ip_https_block_when_disabled(self):
        rendered = _render_default_site_config(
            _base_config(serve_ip_over_https=False),
        )
        self.assertNotIn("https://198.51.100.8 {", rendered)
        self.assertIn("http://198.51.100.8 {", rendered)

    # Gap-fill: a bare image name with no tag uses the default builder.
    def test_builder_image_defaults_when_no_tag_present(self):
        config = _base_config(caddy_image="caddy")
        self.assertEqual(_builder_image_for(config), "caddy:builder")

    def test_default_site_body_strips_sensitive_response_headers(self):
        rendered = _render_default_site_config(_base_config())
        self.assertIn("header {", rendered)
        self.assertIn("-Server", rendered)
        self.assertIn("-Via", rendered)
        self.assertIn("-X-Powered-By", rendered)
        self.assertIn("?X-Content-Type-Options nosniff", rendered)
        self.assertIn("?Referrer-Policy strict-origin-when-cross-origin", rendered)
        self.assertIn("?Permissions-Policy", rendered)
        self.assertIn("?X-Frame-Options SAMEORIGIN", rendered)
        self.assertIn("@deploydash_https protocol https", rendered)
        self.assertIn("?Strict-Transport-Security max-age=31536000;includeSubDomains", rendered)

    def test_root_caddyfile_always_keeps_auto_https_redirects_enabled(self):
        rendered = _render_root_caddyfile(
            _base_config(enable_https_redirect=False),
        )
        self.assertNotIn("auto_https disable_redirects", rendered)

    def test_builder_image_defaults_when_latest_tag(self):
        config = _base_config(caddy_image="caddy:latest")
        self.assertEqual(_builder_image_for(config), "caddy:builder")

    def test_render_default_page_replaces_template_tokens(self):
        rendered = _render_default_page(
            _base_config(
                default_page_title="Hello <World>",
                default_page_message="Ready & waiting",
            ),
        )
        self.assertIn("Hello &lt;World&gt;", rendered)
        self.assertIn("Ready &amp; waiting", rendered)

    def test_render_default_page_raises_when_template_missing(self):
        config = _base_config()
        missing = Path("/tmp/not-a-real-template-file.html")
        with (
            patch("orchestrator.http_parts.part1_foundation._DEFAULT_PAGE_TEMPLATE_PATH", missing),
            self.assertRaises(RuntimeError),
        ):
            _render_default_page(config)

    def test_render_conf_readme_and_apply_script_include_stack_details(self):
        config = _base_config()
        readme = _render_conf_readme(config)
        script = _render_apply_script(config)
        self.assertIn("/usr/local/bin/deploydash-caddy-apply /opt/deploydash/stack/http", readme)
        self.assertIn('STACK_ROOT="${1:-/opt/deploydash/stack/http}"', script)
        self.assertIn('CONTAINER_NAME="${2:-deploydash_caddy}"', script)

    def test_build_steps_registers_scaffold_operations_without_plugins(self):
        class RuntimeRecorder:
            def __init__(self):
                self.calls = []

            def add_operation(self, op, **kwargs):
                self.calls.append((getattr(op, "__name__", str(op)), kwargs))

        config = _base_config(enable_dns_plugin_cloudflare=False)
        step = build_steps(config)[0]
        runtime = RuntimeRecorder()
        step.register(runtime)

        names = [name for name, _kwargs in runtime.calls]
        self.assertGreaterEqual(names.count("directory"), 7)
        self.assertIn("file", names)
        self.assertTrue(
            any(
                kwargs.get("path") == "/opt/deploydash/stack/http/caddy/Dockerfile"
                and kwargs.get("present") is False
                for name, kwargs in runtime.calls
                if name == "file"
            )
        )

    def test_build_steps_registers_custom_dockerfile_when_plugins_enabled(self):
        class RuntimeRecorder:
            def __init__(self):
                self.calls = []

            def add_operation(self, op, **kwargs):
                self.calls.append((getattr(op, "__name__", str(op)), kwargs))

        config = _base_config(enable_dns_plugin_cloudflare=True)
        step = build_steps(config)[0]
        runtime = RuntimeRecorder()
        step.register(runtime)

        self.assertTrue(
            any(
                name == "put"
                and kwargs.get("dest") == "/opt/deploydash/stack/http/caddy/Dockerfile"
                for name, kwargs in runtime.calls
            )
        )

    # App deploys merge each project's DNS-challenge credentials into
    # caddy/.env, so part 1 must only ensure the file exists with mode 600
    # and never write content to it (#120: the empty files.put wiped every
    # project's credentials on each configure and setup re-run).
    def test_build_steps_preserves_caddy_env_file_content(self):
        class RuntimeRecorder:
            def __init__(self):
                self.calls = []

            def add_operation(self, op, **kwargs):
                self.calls.append((getattr(op, "__name__", str(op)), kwargs))

        config = _base_config()
        step = build_steps(config)[0]
        runtime = RuntimeRecorder()
        step.register(runtime)

        env_file = "/opt/deploydash/stack/http/caddy/.env"
        self.assertTrue(
            any(
                name == "file" and kwargs.get("path") == env_file and kwargs.get("mode") == "600"
                for name, kwargs in runtime.calls
            )
        )
        self.assertFalse(
            any(name == "put" and kwargs.get("dest") == env_file for name, kwargs in runtime.calls)
        )


if __name__ == "__main__":
    unittest.main()
