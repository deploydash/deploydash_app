import base64
import unittest
from types import SimpleNamespace

from pyinfra.operations import docker, server

from orchestrator.app_parts.app_config import parse_app_config
from orchestrator.app_parts.part1_deploy import (
    build_steps,
    render_selected_branch_fetch_command,
)


class _RuntimeRecorder:
    def __init__(self):
        self.operations = []
        self.events = []

    def add_operation(self, operation, **kwargs):
        self.operations.append((operation, kwargs))
        self.events.append(("operation", operation, kwargs))

    def ensure_service_enabled(self, service_name):
        """Capture the shared service-owner call in registration order."""
        self.events.append(("service", service_name))


class TestAppPart1Deploy(unittest.TestCase):
    @staticmethod
    def _shell_commands(runtime):
        commands = []
        for _, kwargs in runtime.operations:
            op_commands = kwargs.get("commands")
            if isinstance(op_commands, list):
                commands.extend(op_commands)
        return commands

    def test_selected_branch_fetch_uses_explicit_remote_tracking_ref(self):
        command = render_selected_branch_fetch_command(
            source_root="/opt/deploydash/stack/apps/sample-app/src",
            branch="experiment/agentic-grounded-eval",
            git_ssh_command="ssh -o StrictHostKeyChecking=yes",
        )

        self.assertIn("GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=yes'", command)
        self.assertIn(
            "git -C /opt/deploydash/stack/apps/sample-app/src "
            "fetch --depth 1 --no-tags origin "
            "+refs/heads/experiment/agentic-grounded-eval:"
            "refs/remotes/origin/experiment/agentic-grounded-eval;",
            command,
        )
        self.assertNotIn("fetch --prune origin", command)

    def test_preflight_uses_caddy_apply_fallback_when_helper_missing(self):
        config = parse_app_config({}, require_domain=True)
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[0].register(runtime)

        self.assertEqual(len(runtime.operations), 2)
        self.assertEqual(
            [event[0] for event in runtime.events],
            ["operation", "service", "operation"],
        )
        self.assertEqual(runtime.events[1], ("service", "docker"))
        preflight_commands = runtime.operations[0][1]["commands"]
        caddy_commands = runtime.operations[1][1]["commands"]
        commands = preflight_commands + caddy_commands
        self.assertTrue(preflight_commands)
        self.assertTrue(caddy_commands)
        self.assertFalse(any("systemctl enable --now docker" in cmd for cmd in commands))

        self.assertFalse(
            any("test -x /usr/local/bin/deploydash-caddy-apply" in cmd for cmd in commands)
        )

        fallback_cmds = [
            cmd for cmd in commands if "if [ -x /usr/local/bin/deploydash-caddy-apply ]" in cmd
        ]
        self.assertEqual(len(fallback_cmds), 1)
        self.assertIn(fallback_cmds[0], caddy_commands)
        self.assertIn("docker compose version", fallback_cmds[0])
        self.assertIn("docker-compose -f", fallback_cmds[0])
        self.assertIn("caddy validate --config /etc/caddy/Caddyfile", fallback_cmds[0])
        self.assertIn("caddy reload --config /etc/caddy/Caddyfile", fallback_cmds[0])

        disk_check_cmds = [
            cmd for cmd in commands if "Insufficient free disk in ${DOCKER_ROOT}" in cmd
        ]
        self.assertEqual(len(disk_check_cmds), 1)

        railpack_version_cmds = [
            cmd for cmd in commands if "Deploy Dash requires Railpack 0.29.0" in cmd
        ]
        self.assertEqual(len(railpack_version_cmds), 1)

        helper_contract_cmds = [
            cmd for cmd in commands if "Railpack build helper is out of date" in cmd
        ]
        self.assertEqual(len(helper_contract_cmds), 1)
        self.assertIn(
            "ghcr.io/railwayapp/railpack-frontend:v0.29.0",
            helper_contract_cmds[0],
        )

    def test_sync_step_does_not_prune_buildkit_cache(self):
        config = parse_app_config({}, require_domain=True)
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[1].register(runtime)

        self.assertEqual(len(runtime.operations), 3)
        commands = self._shell_commands(runtime)
        self.assertNotIn("docker buildx prune -af >/dev/null 2>&1 || true", commands)

    def test_sync_step_tags_operations_with_failed_action_ids(self):
        config = parse_app_config({}, require_domain=True)
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[1].register(runtime)

        action_ids = [kwargs.get("deploydash_action_id") for _, kwargs in runtime.operations]
        self.assertEqual(
            action_ids,
            [
                "app_part1_step2_action_sync_repository",
                "app_part1_step2_action_build_image",
                "app_part1_step2_action_run_container",
            ],
        )

    def test_runtime_mode_disables_railpack_spa_detection(self):
        config = parse_app_config(
            {
                "settings": {
                    "railpack_node_mode": "runtime",
                    "railpack_build_cmd": "npm run build",
                    "railpack_start_cmd": "npm run start",
                }
            },
            require_domain=True,
        )
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[1].register(runtime)

        commands = self._shell_commands(runtime)
        build_cmds = [cmd for cmd in commands if "/usr/local/bin/deploydash-railpack-build" in cmd]
        self.assertEqual(len(build_cmds), 1)
        self.assertIn("RAILPACK_NO_SPA=1", build_cmds[0])
        self.assertIn("NIXPACKS_BUILD_CMD='npm run build'", build_cmds[0])
        self.assertIn("NIXPACKS_START_CMD='npm run start'", build_cmds[0])

    def test_custom_build_and_run_commands_are_forwarded_to_railpack(self):
        config = parse_app_config(
            {
                "settings": {
                    "railpack_build_cmd": "pnpm build",
                    "railpack_start_cmd": "pnpm start",
                }
            },
            require_domain=True,
        )
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[1].register(runtime)

        commands = self._shell_commands(runtime)
        build_cmds = [cmd for cmd in commands if "/usr/local/bin/deploydash-railpack-build" in cmd]
        self.assertEqual(len(build_cmds), 1)
        self.assertIn("RAILPACK_BUILD_CMD='pnpm build'", build_cmds[0])
        self.assertIn("RAILPACK_START_CMD='pnpm start'", build_cmds[0])

    def test_explicit_provider_is_forwarded_without_forcing_commands(self):
        config = parse_app_config(
            {
                "settings": {
                    "railpack_provider": "python",
                }
            },
            require_domain=True,
        )
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[1].register(runtime)

        commands = self._shell_commands(runtime)
        build_cmds = [cmd for cmd in commands if "/usr/local/bin/deploydash-railpack-build" in cmd]
        self.assertEqual(len(build_cmds), 1)
        self.assertIn("RAILPACK_PROVIDER=python", build_cmds[0])
        self.assertNotIn("RAILPACK_BUILD_CMD=", build_cmds[0])
        self.assertNotIn("RAILPACK_START_CMD=", build_cmds[0])

    def test_build_uses_configured_app_subdirectory(self):
        config = parse_app_config(
            {
                "settings": {
                    "app_subdirectory": "website",
                }
            },
            require_domain=True,
        )
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[1].register(runtime)

        commands = self._shell_commands(runtime)
        guard_cmds = [cmd for cmd in commands if "Configured app subdirectory was not found" in cmd]
        self.assertEqual(len(guard_cmds), 1)
        build_cmds = [cmd for cmd in commands if "/usr/local/bin/deploydash-railpack-build" in cmd]
        self.assertEqual(len(build_cmds), 1)
        self.assertIn("/opt/deploydash/stack/apps/sample-app/src/website", build_cmds[0])

    def test_inline_private_key_uses_runtime_injected_git_key(self):
        config = parse_app_config(
            {
                "settings": {
                    "branch": "experiment/agentic-grounded-eval",
                    "deploy_private_key": (
                        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
                        "abc123\n"
                        "-----END OPENSSH PRIVATE KEY-----\n"
                    ),
                }
            },
            require_domain=True,
        )
        steps = build_steps(config)

        runtime_preflight = _RuntimeRecorder()
        steps[0].register(runtime_preflight)
        self.assertEqual(
            [event[0] for event in runtime_preflight.events],
            ["operation", "service", "operation"],
        )
        self.assertEqual(runtime_preflight.events[1], ("service", "docker"))
        self.assertEqual(len(runtime_preflight.operations), 2)
        preflight_commands = runtime_preflight.operations[0][1]["commands"]
        caddy_commands = runtime_preflight.operations[1][1]["commands"]
        self.assertIn("command -v ssh-agent >/dev/null", preflight_commands)
        self.assertIn("command -v ssh-add >/dev/null", preflight_commands)
        self.assertFalse(any("systemctl enable --now docker" in cmd for cmd in preflight_commands))
        self.assertTrue(
            any("if [ -x /usr/local/bin/deploydash-caddy-apply ]" in cmd for cmd in caddy_commands)
        )
        self.assertFalse(
            any(
                "test -f /opt/deploydash/stack/apps/.deploydash/keys/" in cmd
                for cmd in preflight_commands
            )
        )

        runtime_sync = _RuntimeRecorder()
        steps[1].register(runtime_sync)
        self.assertEqual(len(runtime_sync.operations), 3)
        self.assertIn("_stdin", runtime_sync.operations[0][1])
        self.assertIn("BEGIN OPENSSH PRIVATE KEY", runtime_sync.operations[0][1]["_stdin"])

        sync_commands = runtime_sync.operations[0][1]["commands"]
        clone_cmds = [cmd for cmd in sync_commands if "ssh-add - >/dev/null" in cmd]
        self.assertEqual(len(clone_cmds), 1)
        self.assertIn("StrictHostKeyChecking=yes", clone_cmds[0])
        self.assertIn(
            "UserKnownHostsFile=/opt/deploydash/stack/apps/.deploydash/repository-known-hosts/sample-app/known_hosts",
            clone_cmds[0],
        )
        self.assertIn("ssh-keyscan", clone_cmds[0])
        self.assertIn(
            "__DEPLOYDASH_REPOSITORY_HOST_KEY_CONFIRMATION__=",
            clone_cmds[0],
        )
        self.assertNotIn("StrictHostKeyChecking=accept-new", clone_cmds[0])
        self.assertNotIn("UserKnownHostsFile=/dev/null", clone_cmds[0])
        self.assertNotIn("KnownHostsCommand=", clone_cmds[0])
        self.assertIn(
            "fetch --depth 1 --no-tags origin "
            "+refs/heads/experiment/agentic-grounded-eval:"
            "refs/remotes/origin/experiment/agentic-grounded-eval",
            clone_cmds[0],
        )
        self.assertNotIn("fetch --prune origin", clone_cmds[0])

    def test_file_deploy_key_fetches_the_selected_branch_explicitly(self):
        config = parse_app_config(
            {
                "settings": {
                    "branch": "experiment/agentic-grounded-eval",
                }
            },
            require_domain=True,
        )
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[1].register(runtime)
        commands = self._shell_commands(runtime)
        clone_commands = [
            command for command in commands if "git clone --depth 1 --branch" in command
        ]

        self.assertEqual(len(clone_commands), 1)
        self.assertIn(
            "fetch --depth 1 --no-tags origin "
            "+refs/heads/experiment/agentic-grounded-eval:"
            "refs/remotes/origin/experiment/agentic-grounded-eval",
            clone_commands[0],
        )
        self.assertNotIn("fetch --prune origin", clone_commands[0])

    def test_sync_step_injects_runtime_env_via_stdin(self):
        config = parse_app_config(
            {
                "settings": {
                    "project_slug": "demo-app",
                    "runtime_env": {
                        "NODE_ENV": "production",
                        "STRIPE_SECRET_KEY": "sk_live",
                    },
                }
            },
            require_domain=True,
        )
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[1].register(runtime)

        self.assertEqual(len(runtime.operations), 3)
        self.assertFalse(any(op.__name__ == "put" for op, _ in runtime.operations))

        commands = self._shell_commands(runtime)
        run_cmds = [cmd for cmd in commands if "docker run -d" in cmd]
        self.assertEqual(len(run_cmds), 1)
        self.assertNotIn("--env-file", run_cmds[0])
        self.assertIn("rm -f /opt/deploydash/stack/apps/demo-app/runtime.env", run_cmds[0])
        self.assertIn("-e NODE_ENV", run_cmds[0])
        self.assertIn("-e STRIPE_SECRET_KEY", run_cmds[0])
        self.assertNotIn("--security-opt no-new-privileges", run_cmds[0])
        self.assertNotIn("--cap-drop ALL", run_cmds[0])
        self.assertIn("--pids-limit 512", run_cmds[0])
        run_kwargs = runtime.operations[2][1]
        self.assertIn("_stdin", run_kwargs)
        self.assertIn(
            f"NODE_ENV\t{base64.b64encode(b'production').decode('ascii')}",
            run_kwargs["_stdin"],
        )
        self.assertIn(
            f"STRIPE_SECRET_KEY\t{base64.b64encode(b'sk_live').decode('ascii')}",
            run_kwargs["_stdin"],
        )

    def test_sqlite_volumes_use_docker_volume_before_run_in_both_key_modes(self):
        """Keep volume ownership declarative without changing failure attribution."""
        for key_mode in ("file", "inline"):
            with self.subTest(key_mode=key_mode):
                settings = {
                    "sqlite_storage": {
                        "enabled": True,
                        "volume_name": "deploydash_sqlite_primary",
                        "mount_path": "/var/lib/deploydash/sqlite",
                        "file_name": "main.db",
                    },
                    "sqlite_snapshot_mounts": [
                        {
                            "volume_name": "deploydash_sqlite_snapshot_catalog",
                            "mount_path": "/var/lib/deploydash/sqlite-snapshots/catalog",
                            "file_name": "catalog.db",
                        },
                        {
                            "volume_name": "deploydash_sqlite_snapshot_archive",
                            "mount_path": "/var/lib/deploydash/sqlite-snapshots/archive",
                            "file_name": "archive.db",
                        },
                    ],
                }
                if key_mode == "inline":
                    settings["deploy_private_key"] = "inline-private-key"
                config = parse_app_config(
                    {"settings": settings},
                    require_domain=True,
                )
                runtime = _RuntimeRecorder()

                build_steps(config)[1].register(runtime)

                run_index, run_kwargs = next(
                    (index, kwargs)
                    for index, (operation, kwargs) in enumerate(runtime.operations)
                    if operation == server.shell
                    and kwargs.get("deploydash_action_id") == "app_part1_step2_action_run_container"
                )
                volume_operations = [
                    (index, kwargs)
                    for index, (operation, kwargs) in enumerate(runtime.operations)
                    if operation == docker.volume
                ]
                self.assertEqual(
                    [
                        (kwargs["volume"], kwargs["deploydash_action_id"])
                        for _, kwargs in volume_operations
                    ],
                    [
                        (
                            "deploydash_sqlite_primary",
                            "app_part1_step2_action_run_container",
                        ),
                        (
                            "deploydash_sqlite_snapshot_catalog",
                            "app_part1_step2_action_run_container",
                        ),
                        (
                            "deploydash_sqlite_snapshot_archive",
                            "app_part1_step2_action_run_container",
                        ),
                    ],
                )
                self.assertTrue(
                    all(index < run_index for index, _ in volume_operations),
                )
                run_command_blob = "\n".join(run_kwargs["commands"])
                self.assertNotIn("docker volume inspect", run_command_blob)
                self.assertNotIn("docker volume create", run_command_blob)

    def test_sync_step_mounts_sqlite_volume_and_injects_sqlite_env_contract(self):
        config = parse_app_config(
            {
                "settings": {
                    "project_slug": "sqlite-app",
                    "sqlite_storage": {
                        "enabled": True,
                        "volume_name": "deploydash_sqlite_sqlite-app",
                        "mount_path": "/var/lib/deploydash/sqlite",
                        "file_name": "main.db",
                    },
                }
            },
            require_domain=True,
        )
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[1].register(runtime)

        commands = self._shell_commands(runtime)
        run_cmds = [cmd for cmd in commands if "docker run -d" in cmd]
        self.assertEqual(len(run_cmds), 1)
        self.assertNotIn("docker volume inspect", run_cmds[0])
        self.assertNotIn("docker volume create", run_cmds[0])
        self.assertIn(
            "-v deploydash_sqlite_sqlite-app:/var/lib/deploydash/sqlite",
            run_cmds[0],
        )
        run_kwargs = next(
            kwargs
            for operation, kwargs in runtime.operations
            if operation == server.shell
            and kwargs.get("deploydash_action_id") == "app_part1_step2_action_run_container"
        )
        self.assertIn("_stdin", run_kwargs)
        self.assertIn(
            "SQLITE_PATH\t"
            + base64.b64encode(b"/var/lib/deploydash/sqlite/main.db").decode("ascii"),
            run_kwargs["_stdin"],
        )
        self.assertIn(
            "DATABASE_URL\t"
            + base64.b64encode(b"sqlite:////var/lib/deploydash/sqlite/main.db").decode("ascii"),
            run_kwargs["_stdin"],
        )

    def test_sync_step_mounts_sqlite_snapshots_read_only(self):
        config = parse_app_config(
            {
                "settings": {
                    "sqlite_snapshot_mounts": [
                        {
                            "volume_name": "deploydash_sqlite_snapshot_catalog",
                            "mount_path": "/var/lib/deploydash/sqlite-snapshots/catalog",
                            "file_name": "catalog.db",
                            "path_env_key": "CATALOG_SQLITE_PATH",
                            "database_url_env_key": "CATALOG_DATABASE_URL",
                        },
                        {
                            "volume_name": "deploydash_sqlite_snapshot_archive",
                            "mount_path": "/var/lib/deploydash/sqlite-snapshots/archive",
                            "file_name": "archive.db",
                        },
                    ],
                    "workers": [
                        {
                            "id": "queue-worker",
                            "start_cmd": "npm run worker",
                            "cpu_limit": 1,
                            "memory_mb": 512,
                            "disk_mb": 1024,
                        }
                    ],
                }
            },
            require_domain=True,
        )
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[1].register(runtime)

        commands = self._shell_commands(runtime)
        run_cmds = [cmd for cmd in commands if "docker run -d" in cmd]
        self.assertGreaterEqual(len(run_cmds), 2)
        self.assertTrue(
            all(
                "-v deploydash_sqlite_snapshot_catalog:"
                "/var/lib/deploydash/sqlite-snapshots/catalog:ro" in command
                for command in run_cmds
            )
        )
        app_run_cmd = next(
            command for command in run_cmds if "deploydash_app_sample-app" in command
        )
        self.assertNotIn("docker volume inspect", app_run_cmd)
        self.assertNotIn("docker volume create", app_run_cmd)
        run_kwargs = next(
            kwargs
            for operation, kwargs in runtime.operations
            if operation == server.shell
            and kwargs.get("deploydash_action_id") == "app_part1_step2_action_run_container"
        )
        self.assertIn(
            "CATALOG_SQLITE_PATH\t"
            + base64.b64encode(b"/var/lib/deploydash/sqlite-snapshots/catalog/catalog.db").decode(
                "ascii"
            ),
            run_kwargs["_stdin"],
        )
        self.assertIn(
            "CATALOG_DATABASE_URL\t"
            + base64.b64encode(
                b"sqlite:////var/lib/deploydash/sqlite-snapshots/catalog/catalog.db"
            ).decode("ascii"),
            run_kwargs["_stdin"],
        )

    def test_sync_step_connects_app_and_workers_to_trust_networks(self):
        config = parse_app_config(
            {
                "settings": {
                    "trust_network_names": ["deploydash_trust_alpha"],
                    "workers": [
                        {
                            "id": "queue-worker",
                            "start_cmd": "npm run worker",
                            "cpu_limit": 1,
                            "memory_mb": 512,
                            "disk_mb": 1024,
                        }
                    ],
                }
            },
            require_domain=True,
        )
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[1].register(runtime)
        commands = self._shell_commands(runtime)
        run_commands = [cmd for cmd in commands if "docker run -d " in cmd]
        self.assertTrue(
            any(
                "for TRUST_NETWORK in deploydash_trust_alpha" in command
                and "deploydash_app_sample-app" in command
                for command in run_commands
            )
        )
        self.assertTrue(
            any(
                "for TRUST_NETWORK in deploydash_trust_alpha" in command
                and "deploydash_worker_sample-app_queue-worker" in command
                for command in run_commands
            )
        )

    def test_publish_snippet_contains_single_domain_block(self):
        config = parse_app_config({}, require_domain=True)
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[2].register(runtime)

        self.assertEqual(len(runtime.operations), 3)
        validate_kwargs = runtime.operations[0][1]
        put_kwargs = runtime.operations[1][1]
        snippet_text = put_kwargs["src"].getvalue()
        self.assertIn("app.example.com {", snippet_text)
        self.assertNotIn("http://app.example.com", snippet_text)
        self.assertIn("header_down -Server", snippet_text)
        self.assertIn("header_down -Via", snippet_text)
        self.assertIn("header_down -X-Powered-By", snippet_text)
        self.assertIn("header {", snippet_text)
        self.assertIn("-Server", snippet_text)
        self.assertIn("-Via", snippet_text)
        self.assertIn("-X-Powered-By", snippet_text)
        self.assertIn("?X-Content-Type-Options nosniff", snippet_text)
        self.assertIn("?Referrer-Policy strict-origin-when-cross-origin", snippet_text)
        self.assertIn("?Permissions-Policy", snippet_text)
        self.assertIn("?X-Frame-Options SAMEORIGIN", snippet_text)
        self.assertIn("@deploydash_https protocol https", snippet_text)
        self.assertIn("?Strict-Transport-Security max-age=31536000;includeSubDomains", snippet_text)
        validate_cmd = validate_kwargs["commands"][0]
        self.assertIn(".deploydash-domain-owners.tsv", validate_cmd)
        self.assertIn("Domain ownership conflict:", validate_cmd)

        shell_kwargs = runtime.operations[2][1]

        http_probe_cmds = [
            cmd
            for cmd in shell_kwargs["commands"]
            if "HTTP_CODE=" in cmd and "http://127.0.0.1/" in cmd
        ]
        self.assertEqual(len(http_probe_cmds), 1)
        self.assertIn('[ "${HTTP_CODE}" -lt 500 ]', http_probe_cmds[0])

        https_probe_cmds = [cmd for cmd in shell_kwargs["commands"] if "HTTPS_CODE=" in cmd]
        self.assertEqual(len(https_probe_cmds), 1)
        self.assertIn("--resolve app.example.com:443:127.0.0.1", https_probe_cmds[0])

        caddy_env_sync_cmds = [
            cmd
            for cmd in shell_kwargs["commands"]
            if "ENV_FILE=/opt/deploydash/stack/http/caddy/.env" in cmd
        ]
        self.assertEqual(len(caddy_env_sync_cmds), 1)
        self.assertIn('grep -v "^${PREFIX}"', caddy_env_sync_cmds[0])

    def test_publish_snippet_redirects_www_to_apex(self):
        config = parse_app_config(
            {
                "settings": {
                    "primary_domain": "www.example.com",
                    "domain_routing_mode": "redirect_www_to_apex",
                }
            },
            require_domain=True,
        )
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[2].register(runtime)

        put_kwargs = runtime.operations[1][1]
        snippet_text = put_kwargs["src"].getvalue()
        self.assertIn("www.example.com {", snippet_text)
        self.assertIn("redir https://example.com{uri} permanent", snippet_text)
        self.assertIn("example.com {", snippet_text)
        self.assertIn("reverse_proxy deploydash_app_sample-app:3000", snippet_text)
        self.assertIn("header_down -Server", snippet_text)
        self.assertIn("header_down -Via", snippet_text)
        self.assertIn("header_down -X-Powered-By", snippet_text)
        self.assertIn("header {", snippet_text)
        self.assertIn("-Server", snippet_text)
        self.assertIn("-Via", snippet_text)
        self.assertIn("-X-Powered-By", snippet_text)
        self.assertIn("?X-Content-Type-Options nosniff", snippet_text)

        shell_kwargs = runtime.operations[2][1]
        self.assertTrue(
            any(
                "DESIRED_DOMAINS='example.com www.example.com'" in cmd
                for cmd in shell_kwargs["commands"]
            )
        )

        redirect_probe_cmd = next(
            cmd
            for cmd in shell_kwargs["commands"]
            if "REDIRECT_CODE=" in cmd and "Host: www.example.com" in cmd
        )
        self.assertIn("https://example.com", redirect_probe_cmd)
        self.assertIn("https://www.example.com", redirect_probe_cmd)
        self.assertIn("HTTPS_REDIRECT_CODE=", redirect_probe_cmd)
        self.assertIn(
            "--resolve www.example.com:443:127.0.0.1",
            redirect_probe_cmd,
        )

        https_probe_cmds = [cmd for cmd in shell_kwargs["commands"] if "HTTPS_CODE=" in cmd]
        self.assertEqual(len(https_probe_cmds), 1)
        self.assertIn("--resolve example.com:443:127.0.0.1", https_probe_cmds[0])

    def test_publish_snippet_redirects_apex_to_www(self):
        config = parse_app_config(
            {
                "settings": {
                    "primary_domain": "example.com",
                    "domain_routing_mode": "redirect_apex_to_www",
                }
            },
            require_domain=True,
        )
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[2].register(runtime)

        put_kwargs = runtime.operations[1][1]
        snippet_text = put_kwargs["src"].getvalue()
        self.assertIn("example.com {", snippet_text)
        self.assertIn("redir https://www.example.com{uri} permanent", snippet_text)
        self.assertIn("www.example.com {", snippet_text)

        shell_kwargs = runtime.operations[2][1]
        redirect_probe_cmd = next(
            cmd
            for cmd in shell_kwargs["commands"]
            if "REDIRECT_CODE=" in cmd and "Host: example.com" in cmd
        )
        self.assertIn("https://www.example.com", redirect_probe_cmd)
        self.assertIn("https://example.com", redirect_probe_cmd)
        self.assertIn("HTTPS_REDIRECT_CODE=", redirect_probe_cmd)
        self.assertIn("--resolve example.com:443:127.0.0.1", redirect_probe_cmd)

    def test_publish_snippet_uses_dns_tls_for_cloudflare(self):
        config = parse_app_config(
            {
                "settings": {
                    "project_slug": "demo-app",
                    "tls_challenge_mode": "dns",
                    "tls_dns_provider": "cloudflare",
                    "tls_dns_credentials": {
                        "api_token": "cloudflare-token",
                    },
                }
            },
            require_domain=True,
        )
        steps = build_steps(config)

        runtime = _RuntimeRecorder()
        steps[2].register(runtime)
        put_kwargs = runtime.operations[1][1]
        snippet_text = put_kwargs["src"].getvalue()
        self.assertIn("dns cloudflare {env.DEPLOYDASH_DEMO_APP_CLOUDFLARE_API_TOKEN}", snippet_text)

        shell_kwargs = runtime.operations[2][1]
        sync_cmd = next(
            cmd
            for cmd in shell_kwargs["commands"]
            if "ENV_FILE=/opt/deploydash/stack/http/caddy/.env" in cmd
        )
        self.assertIn("PREFIX=DEPLOYDASH_DEMO_APP_", sync_cmd)
        self.assertIn("DEPLOYDASH_DEMO_APP_CLOUDFLARE_API_TOKEN", sync_cmd)

    def test_publish_snippet_uses_dns_tls_for_supported_providers(self):
        cases = [
            (
                "porkbun",
                {"api_key": "porkbun-key", "api_secret_key": "porkbun-secret"},
                [
                    "dns porkbun {",
                    "api_key {env.DEPLOYDASH_DEMO_APP_PORKBUN_API_KEY}",
                    "api_secret_key {env.DEPLOYDASH_DEMO_APP_PORKBUN_API_SECRET_KEY}",
                ],
                [
                    "DEPLOYDASH_DEMO_APP_PORKBUN_API_KEY",
                    "DEPLOYDASH_DEMO_APP_PORKBUN_API_SECRET_KEY",
                ],
            ),
            (
                "namecheap",
                {
                    "api_user": "namecheap-user",
                    "api_key": "namecheap-key",
                    "client_ip": "203.0.113.20",
                    "api_endpoint": "https://api.namecheap.com/xml.response",
                },
                [
                    "dns namecheap {",
                    "api_user {env.DEPLOYDASH_DEMO_APP_NAMECHEAP_API_USER}",
                    "api_key {env.DEPLOYDASH_DEMO_APP_NAMECHEAP_API_KEY}",
                    "client_ip {env.DEPLOYDASH_DEMO_APP_NAMECHEAP_CLIENT_IP}",
                    "endpoint {env.DEPLOYDASH_DEMO_APP_NAMECHEAP_API_ENDPOINT}",
                ],
                [
                    "DEPLOYDASH_DEMO_APP_NAMECHEAP_API_USER",
                    "DEPLOYDASH_DEMO_APP_NAMECHEAP_API_KEY",
                    "DEPLOYDASH_DEMO_APP_NAMECHEAP_CLIENT_IP",
                    "DEPLOYDASH_DEMO_APP_NAMECHEAP_API_ENDPOINT",
                ],
            ),
            (
                "cloudns",
                {
                    "auth_password": "cloudns-password",
                    "auth_id": "123",
                    "sub_auth_id": "456",
                },
                [
                    "dns cloudns {",
                    "auth_password {env.DEPLOYDASH_DEMO_APP_CLOUDNS_AUTH_PASSWORD}",
                    "auth_id {env.DEPLOYDASH_DEMO_APP_CLOUDNS_AUTH_ID}",
                    "sub_auth_id {env.DEPLOYDASH_DEMO_APP_CLOUDNS_SUB_AUTH_ID}",
                ],
                [
                    "DEPLOYDASH_DEMO_APP_CLOUDNS_AUTH_PASSWORD",
                    "DEPLOYDASH_DEMO_APP_CLOUDNS_AUTH_ID",
                    "DEPLOYDASH_DEMO_APP_CLOUDNS_SUB_AUTH_ID",
                ],
            ),
            (
                "easydns",
                {
                    "api_token": "easydns-token",
                    "api_key": "easydns-key",
                    "api_url": "https://rest.easydns.net",
                },
                [
                    "dns easydns {",
                    "api_token {env.DEPLOYDASH_DEMO_APP_EASYDNS_API_TOKEN}",
                    "api_key {env.DEPLOYDASH_DEMO_APP_EASYDNS_API_KEY}",
                    "api_url {env.DEPLOYDASH_DEMO_APP_EASYDNS_API_URL}",
                ],
                [
                    "DEPLOYDASH_DEMO_APP_EASYDNS_API_TOKEN",
                    "DEPLOYDASH_DEMO_APP_EASYDNS_API_KEY",
                    "DEPLOYDASH_DEMO_APP_EASYDNS_API_URL",
                ],
            ),
        ]

        for provider, credentials, snippet_fragments, env_keys in cases:
            with self.subTest(provider=provider):
                config = parse_app_config(
                    {
                        "settings": {
                            "project_slug": "demo-app",
                            "tls_challenge_mode": "dns",
                            "tls_dns_provider": provider,
                            "tls_dns_credentials": credentials,
                        }
                    },
                    require_domain=True,
                )
                steps = build_steps(config)
                runtime = _RuntimeRecorder()
                steps[2].register(runtime)
                snippet_text = runtime.operations[1][1]["src"].getvalue()

                for fragment in snippet_fragments:
                    self.assertIn(fragment, snippet_text)

                sync_cmd = next(
                    cmd
                    for cmd in runtime.operations[2][1]["commands"]
                    if "ENV_FILE=/opt/deploydash/stack/http/caddy/.env" in cmd
                )
                for env_key in env_keys:
                    self.assertIn(env_key, sync_cmd)

    def test_build_steps_rejects_single_host_with_redirect_domain(self):
        invalid = SimpleNamespace(
            domain_routing_mode="single_host",
            redirect_domain="www.app.example.com",
            canonical_domain="app.example.com",
        )
        with self.assertRaisesRegex(
            ValueError,
            "single_host routing cannot set a redirect domain",
        ):
            build_steps(invalid)

    def test_build_steps_rejects_redirect_mode_without_redirect_domain(self):
        invalid = SimpleNamespace(
            domain_routing_mode="redirect_apex_to_www",
            redirect_domain=None,
            canonical_domain="www.example.com",
        )
        with self.assertRaisesRegex(
            ValueError,
            "redirect routing mode requires a redirect domain",
        ):
            build_steps(invalid)

    def test_build_steps_rejects_redirect_domain_equal_to_canonical_domain(self):
        invalid = SimpleNamespace(
            domain_routing_mode="redirect_apex_to_www",
            redirect_domain="www.example.com",
            canonical_domain="www.example.com",
        )
        with self.assertRaisesRegex(
            ValueError,
            "redirect domain and canonical domain must be distinct",
        ):
            build_steps(invalid)


if __name__ == "__main__":
    unittest.main()
