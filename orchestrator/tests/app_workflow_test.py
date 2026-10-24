import json
import unittest
from unittest.mock import patch

from engine import _read_remote_file_text, handle_request
from orchestrator.app_parts.repository_host_key import (
    CONFIRMATION_CODE,
    CONFIRMATION_MARKER,
)
from orchestrator.plugins.app_plugin import build_plugin as build_app_plugin
from tests.engine_context_fixtures import build_test_context


class _FakeSession:
    def __init__(
        self,
        fail_step_id=None,
        public_key="ssh-ed25519 AAAATESTKEY",
        private_key="-----BEGIN OPENSSH PRIVATE KEY-----\nTEST\n-----END OPENSSH PRIVATE KEY-----",
    ):
        self._step_records = []
        self._fail_step_id = fail_step_id
        self.host = _FakeHost(public_key, private_key)

    def register_steps_deploy(self, steps):
        self._step_records = [(step.id, step.part, step.title) for step in steps]

    def execute(self):
        operations = []
        for step_id, part, title in self._step_records:
            failed = step_id == self._fail_step_id
            operations.append(
                {
                    "step_id": step_id,
                    "part": part,
                    "title": title,
                    "complete": True,
                    "success": not failed,
                    "changed": True,
                    "stdout": ["ok"] if not failed else [],
                    "stderr": ["failed"] if failed else [],
                }
            )
        return {
            "ops": len(operations),
            "success_ops": len([op for op in operations if op["success"]]),
            "error_ops": len([op for op in operations if not op["success"]]),
            "ignored_error_ops": 0,
            "partial_ops": 0,
            "run_error": None,
            "operations": operations,
        }

    def close(self):
        return {"disconnect_error": None}


class _FakeOutput:
    def __init__(self, lines, stderr_lines=None):
        self.stdout_lines = lines
        self.stderr_lines = stderr_lines or []


class _FakeHost:
    def __init__(self, public_key, private_key):
        self._public_key = public_key
        self._private_key = private_key
        self.cleanup_commands = []
        self.commands = []

    def run_shell_command(self, command, _timeout=10, _sudo=False, **kwargs):
        self.commands.append(command)
        if "__DEPLOYDASH_APP_EXEC_EXIT_CODE__=" in command:
            if "npm run fail:migrate" in command:
                return (
                    True,
                    _FakeOutput(
                        [
                            "Applying migrations",
                            "__DEPLOYDASH_APP_EXEC_EXIT_CODE__=1",
                        ],
                        stderr_lines=["Migration failed"],
                    ),
                )
            if "npm run missing-container" in command:
                return (
                    True,
                    _FakeOutput(
                        ["__DEPLOYDASH_APP_EXEC_EXIT_CODE__=126"],
                        stderr_lines=["App container is not running on server."],
                    ),
                )
            if "npm run timeout:migrate" in command:
                return (
                    False,
                    _FakeOutput(
                        [],
                        stderr_lines=["Command timed out after 900 seconds."],
                    ),
                )
            if "npm run db:migrate" in command:
                return (
                    True,
                    _FakeOutput(
                        [
                            "Applying migrations",
                            "Done",
                            "__DEPLOYDASH_APP_EXEC_EXIT_CODE__=0",
                        ]
                    ),
                )
            return True, _FakeOutput(["ok", "__DEPLOYDASH_APP_EXEC_EXIT_CODE__=0"])
        if command.startswith("cat ") and command.endswith(".pub"):
            return True, _FakeOutput([self._public_key])
        if command.startswith("cat "):
            return True, _FakeOutput([self._private_key])
        if "WORKER_PRECHECK_IMAGE_EXISTS" in command:
            return (
                True,
                _FakeOutput(
                    [
                        "IGNORED_PRECHECK_LINE",
                        "WORKER_PRECHECK_IMAGE_EXISTS=true",
                        "WORKER_PRECHECK_APP_CONTAINER_EXISTS=true",
                        "WORKER_PRECHECK_APP_CONTAINER_RUNNING=true",
                        "WORKER_PRECHECK_WORKER_NETWORK=deploydash_default",
                    ]
                ),
            )
        if "META|{{.Names}}" in command and "deploydash.role=worker" in command:
            return (
                True,
                _FakeOutput(
                    [
                        "META|deploydash_worker_remix-blog_queue-worker|running|Up 5s|abc001",
                        "STAT|deploydash_worker_remix-blog_queue-worker|1.20%|62MiB / 512MiB|12.11%|7",
                    ]
                ),
            )
        if "docker stats --no-stream" in command:
            return (
                True,
                _FakeOutput(
                    [
                        "container_present=1",
                        "container_docker_state=running",
                        "container_running=true",
                        "container_health=healthy",
                        "container_exit_code=0",
                        "container_image=deploydash_app_remix-blog:live",
                        "container_started_at=2026-07-01T12:00:00Z",
                        '{"BlockIO":"0B / 0B","CPUPerc":"0.03%","Container":"abc123","ID":"abc123","MemPerc":"0.24%","MemUsage":"2.352MiB / 982.5MiB","Name":"deploydash_app_remix-blog","NetIO":"539kB / 606kB","PIDs":"2"}',
                    ]
                ),
            )
        if "SQLITE_META_ENABLED" in command:
            return (
                True,
                _FakeOutput(
                    [
                        "SQLITE_META_ENABLED=true",
                        "SQLITE_META_VOLUME_NAME=deploydash_sqlite_remix-blog",
                        "SQLITE_META_MOUNT_PATH=/var/lib/deploydash/sqlite",
                        "SQLITE_META_FILE_NAME=main.db",
                        "SQLITE_META_DATABASE_PATH=/var/lib/deploydash/sqlite/main.db",
                        "SQLITE_META_DATABASE_URL=sqlite:////var/lib/deploydash/sqlite/main.db",
                        "SQLITE_META_VOLUME_EXISTS=true",
                        "SQLITE_META_VOLUME_MOUNTPOINT=/var/lib/docker/volumes/deploydash_sqlite_remix-blog/_data",
                        "SQLITE_META_VOLUME_SIZE_KB=128",
                    ]
                ),
            )
        if "DEPLOYDASH_PUBLIC_HEALTH|" in command:
            return (
                True,
                _FakeOutput(["DEPLOYDASH_PUBLIC_HEALTH|0|500"]),
            )
        if "docker logs --tail" in command:
            return (
                True,
                _FakeOutput(
                    [
                        "2026-02-19T22:47:00.123456789Z booting app",
                        "2026-02-19T22:47:01.123456789Z Missing required env var STRIPE_SECRET_KEY",
                    ]
                ),
            )
        if command.startswith("rm -rf "):
            self.cleanup_commands.append(command)
            return True, _FakeOutput(["ok"])
        return True, _FakeOutput(["ok"])


class _FakeSudoFallbackHost:
    def __init__(self, public_key):
        self._public_key = public_key
        self.calls = []

    def run_shell_command(self, command, _timeout=10, _sudo=False, **kwargs):
        self.calls.append(_sudo)
        if command.startswith("cat ") and _sudo:
            return True, _FakeOutput([self._public_key])
        if command.startswith("cat "):
            return False, _FakeOutput([])
        return True, _FakeOutput(["ok"])


class _FakeSudoDeniedHost:
    def __init__(self, public_key):
        self._public_key = public_key
        self.calls = []

    def run_shell_command(self, command, _timeout=10, _sudo=False, **kwargs):
        self.calls.append(_sudo)
        if command.startswith("cat ") and _sudo:
            return False, _FakeOutput([])
        if command.startswith("cat "):
            return True, _FakeOutput([self._public_key])
        return True, _FakeOutput(["ok"])


class _FakeImageMissingHost(_FakeHost):
    def run_shell_command(self, command, _timeout=10, _sudo=False, **kwargs):
        if "docker image inspect" in command:
            return (
                False,
                _FakeOutput(
                    [],
                    stderr_lines=["Web app image is missing. Deploy web app first to build image."],
                ),
            )
        return super().run_shell_command(command, _timeout=_timeout, _sudo=_sudo)


class _FakeImageMissingSession(_FakeSession):
    def __init__(
        self,
        public_key="ssh-ed25519 AAAATESTKEY",
        private_key="-----BEGIN OPENSSH PRIVATE KEY-----\nTEST\n-----END OPENSSH PRIVATE KEY-----",
    ):
        super().__init__(public_key=public_key, private_key=private_key)
        self.host = _FakeImageMissingHost(public_key, private_key)


class _FakeRepositoryHostKeyConfirmationHost(_FakeHost):
    def run_shell_command(self, command, _timeout=10, _sudo=False, **kwargs):
        if "__DEPLOYDASH_REPOSITORY_HOST_KEY_CONFIRMATION__=" in command:
            payload = {
                "code": CONFIRMATION_CODE,
                "repository_host_key_confirmation_required": True,
                "host": "github.com",
                "port": "22",
                "reason": "missing",
                "previous_fingerprint": "",
                "scanned_fingerprint": "SHA256:newfingerprint",
                "known_hosts_path": "/opt/deploydash/stack/apps/.deploydash/repository-known-hosts/remix-blog/known_hosts",
            }
            import base64

            encoded = base64.b64encode(
                json.dumps(payload, separators=(",", ":")).encode("utf-8")
            ).decode("ascii")
            return (
                False,
                _FakeOutput(
                    [],
                    stderr_lines=[f"{CONFIRMATION_MARKER}{encoded}"],
                ),
            )
        return super().run_shell_command(command, _timeout=_timeout, _sudo=_sudo)


class _FakeRepositoryHostKeyConfirmationSession(_FakeSession):
    def __init__(self):
        super().__init__()
        self.host = _FakeRepositoryHostKeyConfirmationHost(
            self.host._public_key,
            self.host._private_key,
        )


class TestAppWorkflow(unittest.TestCase):
    def _build_app_plugin(
        self,
        *,
        connection_error=None,
        describe_response=None,
        deploy_calls=None,
        prepare_key_calls=None,
    ):
        runtime_calls = []
        self.emitted_events: list[tuple] = []
        ctx = build_test_context(
            emit_event=lambda _emit, event_type, message, **kwargs: self.emitted_events.append(
                (event_type, message, kwargs.get("level", "info")),
            ),
            connection_validation_error=lambda _connection: connection_error,
            resolve_parts=lambda _data: [],
            describe_app=lambda **_kwargs: (
                describe_response or {"status": "success", "parts": [], "steps": []}
            ),
            prepare_app_deploy_key=lambda **kwargs: (
                (prepare_key_calls if prepare_key_calls is not None else []).append(
                    kwargs,
                )
                or {"status": "success"}
            ),
            deploy_application=lambda **kwargs: (
                (deploy_calls if deploy_calls is not None else []).append(kwargs)
                or {"status": "success"}
            ),
            extract_app_settings_payload=lambda data: data.get("params", {}),
            extract_connection_payload=lambda _data: {
                "ip": "203.0.113.10",
                "username": "ubuntu",
                "password": "secret",
                "key_path": "/tmp/id_ed25519",
                "port": 22,
            },
            normalize_runtime_log_tail=lambda _value: 200,
            payload_params=lambda data: data.get("params") or {},
            resolve_dry_run=lambda data, default: data.get("dry_run", default),
            run_app_runtime_operation=lambda **kwargs: (
                runtime_calls.append(kwargs)
                or {"status": "success", "operation_id": kwargs["operation_id"]}
            ),
        )
        return build_app_plugin(operations={}, ctx=ctx), runtime_calls

    def test_app_plugin_runtime_handlers_return_connection_errors(self):
        error = {"status": "error", "msg": "missing connection"}
        plugin, runtime_calls = self._build_app_plugin(connection_error=error)

        result = plugin.handlers["runtime_logs"]({"params": {}})

        self.assertEqual(result, error)
        self.assertEqual(runtime_calls, [])

    def test_prepare_key_refuses_before_touching_the_server(self):
        # The connection did not validate, so nothing may reach the server:
        # `prepare_key` writes a deploy key to a customer's machine.
        error = {"status": "error", "msg": "missing connection"}
        prepare_key_calls: list[dict] = []
        plugin, _ = self._build_app_plugin(
            connection_error=error,
            prepare_key_calls=prepare_key_calls,
        )

        result = plugin.handlers["prepare_key"]({"params": {}})

        self.assertEqual(result, error)
        self.assertEqual(prepare_key_calls, [])

    def test_a_deploy_refuses_before_touching_the_server(self):
        # Same rule for the operation that actually deploys.
        error = {"status": "error", "msg": "missing connection"}
        deploy_calls: list[dict] = []
        plugin, _ = self._build_app_plugin(
            connection_error=error,
            deploy_calls=deploy_calls,
        )

        result = plugin.handlers["run"]({"params": {}})

        self.assertEqual(result, error)
        self.assertEqual(deploy_calls, [])

    def test_a_rejected_describe_is_emitted_as_a_validation_error(self):
        # The describe half: a plan that cannot be built has to say so as an
        # error-level event, not merely return a payload the caller may not
        # read. Asserting the emitted event rather than the returned status,
        # because the return is the same either way -- only the event tells
        # the desktop to stop and show something.
        plugin, _ = self._build_app_plugin(
            describe_response={"status": "error", "msg": "Unknown parts: nope"},
        )

        result = plugin.handlers["describe"]({"params": {}})

        self.assertEqual(result["status"], "error")
        self.assertEqual(
            self.emitted_events,
            [("validation_error", "Unknown parts: nope", "error")],
        )

    def test_an_accepted_describe_announces_the_plan_instead(self):
        # The other branch, so neither is satisfied by the same emit.
        plugin, _ = self._build_app_plugin(
            describe_response={
                "status": "success",
                "parts": ["part1"],
                "steps": [{"id": "step1"}],
            },
        )

        plugin.handlers["describe"]({"params": {}})

        self.assertEqual(
            [event[0] for event in self.emitted_events],
            ["app_plan_ready"],
        )

    def test_app_plugin_normalizes_non_string_worker_and_release_ids(self):
        plugin, runtime_calls = self._build_app_plugin()

        worker_result = plugin.handlers["worker_logs"]({"params": {"worker_id": 17}})
        rollback_result = plugin.handlers["rollback"]({"params": {"release_id": 20260831}})

        self.assertEqual(worker_result["operation_id"], "worker_logs")
        self.assertEqual(rollback_result["operation_id"], "rollback")
        self.assertIsNone(runtime_calls[0]["worker_id"])
        self.assertIsNone(runtime_calls[1]["release_id"])

    def test_describe_app_returns_steps(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "describe",
                "params": {
                    "settings": {
                        "project_slug": "sample-app",
                        "repository_full_name": "example-org/example-repo",
                        "branch": "main",
                        "primary_domain": "app.example.com",
                    }
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertGreaterEqual(len(result["steps"]), 1)
        self.assertIn("actions", result["steps"][0])
        self.assertEqual(
            result["resolved_config"],
            {
                "apps_root": "/opt/deploydash/stack/apps",
                "railpack_build_helper": "/usr/local/bin/deploydash-railpack-build",
                "railpack_env_file": "/opt/deploydash/stack/railpack/railpack.env",
                "caddy_stack_root": "/opt/deploydash/stack/http",
                "caddy_container_name": "deploydash_caddy",
                "caddy_apply_helper": "/usr/local/bin/deploydash-caddy-apply",
            },
        )

    @patch("engine.create_runtime_session")
    def test_prepare_key_returns_public_and_private_key(self, mock_create_runtime_session):
        fake_session = _FakeSession(
            public_key="ssh-ed25519 AAAAB3NzaC1prepared",
        )
        mock_create_runtime_session.return_value = fake_session

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "prepare_key",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "sqlite_storage": {
                            "enabled": True,
                            "volume_name": "deploydash_sqlite_remix-blog",
                            "mount_path": "/var/lib/deploydash/sqlite",
                            "file_name": "main.db",
                        },
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertIn("deploy_public_key", result)
        self.assertIn("deploy_private_key", result)
        self.assertTrue(result["deploy_public_key"].startswith("ssh-ed25519"))
        self.assertIn("BEGIN OPENSSH PRIVATE KEY", result["deploy_private_key"])
        self.assertTrue(fake_session.host.cleanup_commands)

    def test_prepare_key_operation_returns_cancelled_result(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "prepare_key",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "sqlite_storage": {
                            "enabled": True,
                            "volume_name": "deploydash_sqlite_remix-blog",
                            "mount_path": "/var/lib/deploydash/sqlite",
                            "file_name": "main.db",
                        },
                    },
                },
            }
        )
        result = json.loads(handle_request(payload, is_cancelled=lambda: True))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertIn("cancelled", result["msg"].lower())

    @patch("engine.create_runtime_session")
    def test_run_app_deploy_dry_run(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "run",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": "blog.example.com",
                        "branch": "main",
                        "app_port": 3000,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["project_slug"], "remix-blog")
        self.assertEqual(result["https_url"], "https://blog.example.com")
        self.assertEqual(
            result["resolved_config"],
            {
                "apps_root": "/opt/deploydash/stack/apps",
                "railpack_build_helper": "/usr/local/bin/deploydash-railpack-build",
                "railpack_env_file": "/opt/deploydash/stack/railpack/railpack.env",
                "caddy_stack_root": "/opt/deploydash/stack/http",
                "caddy_container_name": "deploydash_caddy",
                "caddy_apply_helper": "/usr/local/bin/deploydash-caddy-apply",
            },
        )

    @patch("engine._read_remote_file_text")
    @patch("engine.create_runtime_session")
    def test_list_releases_returns_live_release_inventory(
        self,
        mock_create_runtime_session,
        mock_read_remote_file_text,
    ):
        mock_create_runtime_session.return_value = _FakeSession()
        mock_read_remote_file_text.return_value = json.dumps(
            {
                "schema_version": 1,
                "retention_success_limit": 5,
                "releases": [
                    {
                        "release_id": "20260531t120000z-abcdef12",
                        "commit_sha": "abcdef1234567890",
                        "branch": "main",
                        "created_at": "2026-05-31T12:00:00Z",
                        "status": "live",
                        "deployment_kind": "deploy",
                        "web_container_name": "deploydash_app_remix-blog_20260531t120000z-abcdef12",
                        "worker_container_names": [],
                        "image_name": "deploydash_remix-blog:release-20260531t120000z-abcdef12",
                        "runtime_env": {},
                        "app_port": 3000,
                        "workers": [],
                        "sqlite_storage": None,
                        "sqlite_snapshot_mounts": [],
                        "trust_network_names": [],
                        "rollback_from_release_id": None,
                        "rollback_reason": None,
                        "live_at": "2026-05-31T12:01:00Z",
                    }
                ],
            }
        )

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "list_releases",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["live_release_id"], "20260531t120000z-abcdef12")
        self.assertEqual(len(result["releases"]), 1)
        self.assertEqual(
            result["releases"][0]["release_id"],
            "20260531t120000z-abcdef12",
        )
        self.assertEqual(
            result["release_inventory"]["live_release_id"],
            "20260531t120000z-abcdef12",
        )
        self.assertEqual(result["release_inventory"]["releases"], result["releases"])

    @patch("engine._read_remote_file_text")
    @patch("engine.create_runtime_session")
    def test_list_releases_returns_empty_inventory_when_manifest_is_missing(
        self,
        mock_create_runtime_session,
        mock_read_remote_file_text,
    ):
        mock_create_runtime_session.return_value = _FakeSession()
        mock_read_remote_file_text.side_effect = RuntimeError(
            "Unable to read remote file: "
            "/opt/deploydash/stack/apps/.deploydash/apps/remix-blog/release.json "
            "(cat:/opt/deploydash/stack/apps/.deploydash/apps/remix-blog/release.json : "
            "No such file or directory)"
        )

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "list_releases",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertIsNone(result["live_release_id"])
        self.assertEqual(result["releases"], [])
        self.assertIsNone(result["release_inventory"]["live_release_id"])
        self.assertEqual(result["release_inventory"]["releases"], [])

    def test_rollback_dry_run_returns_actions(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "rollback",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "release_id": "20260530t110000z-fedcba98",
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "rollback")
        self.assertEqual(result["project_slug"], "remix-blog")
        self.assertIn("Switch traffic", result["actions"][1])

    @patch("engine.create_runtime_session")
    def test_run_app_deploy_dry_run_uses_canonical_www_url(
        self,
        mock_create_runtime_session,
    ):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "run",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": "example.com",
                        "domain_routing_mode": "redirect_apex_to_www",
                        "branch": "main",
                        "app_port": 3000,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["https_url"], "https://www.example.com")

    @patch("engine.setup_http_gateway")
    @patch("engine._probe_http_gateway_fast_path")
    def test_run_app_deploy_fails_when_http_dependency_fails(
        self,
        mock_probe_http_gateway_fast_path,
        mock_setup_http_gateway,
    ):
        mock_probe_http_gateway_fast_path.return_value = {
            "ready": False,
            "failed_check": "caddy_running",
            "reason": "Caddy container is not running",
            "details": "",
        }
        mock_setup_http_gateway.return_value = {
            "status": "error",
            "code": "ENGINE_RUNTIME_ERROR",
            "msg": "Caddy bootstrap failed",
        }

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "run",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": "blog.example.com",
                        "branch": "main",
                        "app_port": 3000,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_DEPENDENCY_ERROR")
        self.assertEqual(result["stage"], "ensure_http_gateway")

    @patch("engine.create_runtime_session")
    @patch("engine.setup_http_gateway")
    @patch("engine._probe_http_gateway_fast_path")
    def test_run_app_deploy_fails_when_dns_module_is_missing(
        self,
        mock_probe_http_gateway_fast_path,
        mock_setup_http_gateway,
        mock_create_runtime_session,
    ):
        mock_create_runtime_session.return_value = _FakeSession()
        mock_setup_http_gateway.return_value = {
            "status": "success",
            "code": "OK",
            "msg": "unexpected setup invocation",
        }
        mock_probe_http_gateway_fast_path.return_value = {
            "ready": False,
            "failed_check": "caddy_dns_module",
            "reason": "Caddy DNS module 'cloudflare' is missing",
            "details": "",
        }

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "run",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": "blog.example.com",
                        "branch": "main",
                        "app_port": 3000,
                        "tls_challenge_mode": "dns",
                        "tls_dns_provider": "cloudflare",
                        "tls_dns_credentials": {
                            "api_token": "test-token",
                        },
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_DEPENDENCY_ERROR")
        self.assertEqual(result["stage"], "ensure_http_gateway")
        self.assertIn("module", result["msg"].lower())
        mock_setup_http_gateway.assert_not_called()

    @patch("engine.setup_http_gateway")
    @patch("engine.create_runtime_session")
    def test_run_app_deploy_returns_repository_host_key_confirmation(
        self,
        mock_create_runtime_session,
        mock_setup_http_gateway,
    ):
        mock_create_runtime_session.return_value = _FakeRepositoryHostKeyConfirmationSession()
        mock_setup_http_gateway.return_value = {
            "status": "success",
            "code": "OK",
        }

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "run",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": "blog.example.com",
                        "branch": "main",
                        "app_port": 3000,
                        "deploy_private_key": "-----BEGIN PRIVATE KEY-----test",
                    },
                },
            }
        )

        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], CONFIRMATION_CODE)
        self.assertNotIn("failure_evidence", result)
        self.assertTrue(result["repository_host_key_confirmation_required"])
        confirmation = result["repository_host_key_confirmation"]
        self.assertEqual(confirmation["host"], "github.com")
        self.assertEqual(confirmation["reason"], "missing")
        self.assertEqual(confirmation["scanned_fingerprint"], "SHA256:newfingerprint")

    @patch("engine.setup_http_gateway")
    @patch("engine.create_runtime_session")
    def test_run_app_deploy_skips_http_foundation_when_probe_is_ready(
        self,
        mock_create_runtime_session,
        mock_setup_http_gateway,
    ):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "run",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": "blog.example.com",
                        "branch": "main",
                        "app_port": 3000,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        mock_setup_http_gateway.assert_not_called()

    def test_read_remote_file_text_prefers_sudo(self):
        host = _FakeSudoFallbackHost("ssh-ed25519 AAAAB3NzaC1fallback")
        text = _read_remote_file_text(host, "/opt/deploydash/stack/apps/key.pub")

        self.assertEqual(text, "ssh-ed25519 AAAAB3NzaC1fallback")
        self.assertEqual(host.calls, [True])

    def test_read_remote_file_text_falls_back_without_sudo(self):
        host = _FakeSudoDeniedHost("ssh-ed25519 AAAAB3NzaC1nosudo")
        text = _read_remote_file_text(host, "/opt/deploydash/stack/apps/key.pub")

        self.assertEqual(text, "ssh-ed25519 AAAAB3NzaC1nosudo")
        self.assertEqual(host.calls, [True, False])

    @patch("engine.create_runtime_session")
    def test_app_resource_usage_operation_returns_stats_payload(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "resource_usage",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": "blog.example.com",
                        "public_health_check_path": "/status",
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "resource_usage")
        self.assertIsInstance(result.get("resource_usage"), dict)
        self.assertEqual(result["resource_usage"]["Name"], "deploydash_app_remix-blog")
        self.assertEqual(result["container_status"]["effective_status"], "ready")
        self.assertEqual(result["container_status"]["image"], "deploydash_app_remix-blog:live")
        self.assertIsInstance(result.get("sqlite_storage"), dict)
        self.assertTrue(result["sqlite_storage"]["enabled"])
        self.assertEqual(
            result["sqlite_storage"]["volume_name"],
            "deploydash_sqlite_remix-blog",
        )
        self.assertEqual(
            result["sqlite_storage"]["database_path"],
            "/var/lib/deploydash/sqlite/main.db",
        )
        self.assertEqual(
            result["public_health"],
            {
                "enabled": True,
                "status": "unhealthy",
                "path": "/status",
                "http_status": 500,
                "checked_at": result["public_health"]["checked_at"],
                "error": "http_error",
            },
        )

    @patch("engine.create_runtime_session")
    def test_app_sqlite_volume_ensure_operation_returns_storage_payload(
        self, mock_create_runtime_session
    ):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "sqlite_volume_ensure",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "sqlite_storage": {
                            "enabled": True,
                            "volume_name": "deploydash_sqlite_remix-blog",
                            "mount_path": "/var/lib/deploydash/sqlite",
                            "file_name": "main.db",
                        },
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "sqlite_volume_ensure")
        self.assertIsInstance(result.get("sqlite_storage"), dict)
        self.assertTrue(result["sqlite_storage"]["enabled"])
        self.assertEqual(
            result["sqlite_storage"]["volume_name"],
            "deploydash_sqlite_remix-blog",
        )

    def test_app_sqlite_volume_status_requires_sqlite_settings(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "sqlite_volume_status",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["stage"], "validate_request")
        self.assertIn("SQLite storage is not configured", result["msg"])

    @patch("engine.create_runtime_session")
    def test_app_runtime_logs_operation_returns_success(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "runtime_logs",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "log_tail_lines": 120,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "runtime_logs")
        self.assertEqual(result["log_tail_lines"], 120)
        self.assertEqual(
            result["runtime_log_lines"],
            [
                "2026-02-19T22:47:00.123456789Z booting app",
                "2026-02-19T22:47:01.123456789Z Missing required env var STRIPE_SECRET_KEY",
            ],
        )

    @patch("engine.create_runtime_session")
    def test_app_exec_operation_returns_success(self, mock_create_runtime_session):
        session = _FakeSession()
        mock_create_runtime_session.return_value = session

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "exec",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "command": "npm run db:migrate",
                    "timeout_seconds": 900,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "exec")
        self.assertEqual(result["command"], "npm run db:migrate")
        self.assertEqual(result["timeout_seconds"], 900)
        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(result["stdout_lines"], ["Applying migrations", "Done"])
        self.assertEqual(result["stderr_lines"], [])
        exec_command = next(
            command
            for command in session.host.commands
            if "__DEPLOYDASH_APP_EXEC_EXIT_CODE__=" in command
        )
        self.assertIn("/proc/1/environ", exec_command)
        self.assertIn("APP_EXEC_RUNTIME_PATH", exec_command)
        self.assertIn('export PATH="${APP_EXEC_RUNTIME_PATH}"', exec_command)

    @patch("engine.create_runtime_session")
    def test_app_exec_operation_returns_non_zero_exit_code(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "exec",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "command": "npm run fail:migrate",
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["exit_code"], 1)
        self.assertIn("exit code 1", result["msg"])
        self.assertIn("Migration failed", result["details"])

    @patch("engine.create_runtime_session")
    def test_app_exec_operation_returns_missing_container_error(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "exec",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "command": "npm run missing-container",
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["exit_code"], 126)
        self.assertIn("requires the app container to be running", result["msg"])
        self.assertIn("App container is not running on server.", result["details"])

    @patch("engine.create_runtime_session")
    def test_app_exec_operation_returns_timeout_error(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "exec",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "command": "npm run timeout:migrate",
                    "timeout_seconds": 900,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Run one-off app command failed", result["msg"])
        self.assertIn("timed out", result["details"].lower())
        self.assertEqual(result["timeout_seconds"], 900)

    @patch("engine.create_runtime_session")
    def test_app_exec_operation_emits_terminal_result_event(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()
        events = []

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "exec",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "command": "npm run db:migrate",
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload, emit=events.append))

        self.assertEqual(result["status"], "success")
        terminal_events = [event for event in events if event["type"] == "app_exec_result"]
        self.assertEqual(len(terminal_events), 1)
        self.assertEqual(terminal_events[0]["data"]["terminal_status"], "success")
        self.assertEqual(terminal_events[0]["data"]["exit_code"], 0)

    @patch("engine.create_runtime_session")
    def test_app_exec_operation_returns_cancelled_result(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "exec",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "command": "npm run db:migrate",
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload, is_cancelled=lambda: True))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertIn("cancelled", result["msg"].lower())

    def test_app_exec_operation_rejects_blank_command(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "exec",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "command": "   ",
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("params.command", result["msg"])

    def test_app_exec_operation_rejects_staticfile_runtime(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "exec",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "command": "npm run db:migrate",
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "railpack_provider": "staticfile",
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("staticfile", result["msg"])

    def test_app_exec_operation_rejects_invalid_timeout(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "exec",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "command": "npm run db:migrate",
                    "timeout_seconds": 0,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("timeout_seconds", result["msg"])

    @patch("engine.create_runtime_session")
    def test_app_workers_apply_operation_returns_worker_snapshot(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "workers_apply",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "workers": [
                            {
                                "id": "queue-worker",
                                "name": "Queue worker",
                                "start_cmd": "npm run worker:queue",
                                "cpu_limit": 1.5,
                                "memory_mb": 512,
                                "disk_mb": 2048,
                                "database_user": "app_rw",
                                "database_name": "app_db",
                                "database_password": "pw-123",
                            }
                        ],
                        "runtime_env": {"WORKER_MODE": "queue"},
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "workers_apply")
        self.assertIn("workers", result)
        configured = result["workers"]["configured"]
        self.assertEqual(len(configured), 1)
        self.assertEqual(configured[0]["id"], "queue-worker")
        self.assertEqual(configured[0]["runtime"]["state"], "running")
        run_commands = [
            command
            for command in mock_create_runtime_session.return_value.host.commands
            if "docker run -d " in command
            and "deploydash_worker_remix-blog_queue-worker" in command
        ]
        self.assertEqual(len(run_commands), 1)
        self.assertIn("-e DATABASE_ENGINE=postgres", run_commands[0])
        self.assertIn("-e DATABASE_HOST=host.docker.internal", run_commands[0])
        self.assertIn("WORKER_MODE=queue", run_commands[0])
        self.assertIn('WORKER_NETWORK="$(docker inspect -f ', run_commands[0])
        self.assertIn('--network "${WORKER_NETWORK}"', run_commands[0])
        self.assertNotIn("--security-opt no-new-privileges", run_commands[0])
        self.assertNotIn("--cap-drop ALL", run_commands[0])
        self.assertIn("--pids-limit 512", run_commands[0])
        self.assertIn("--entrypoint /bin/sh", run_commands[0])
        self.assertIn(" -lc 'npm run worker:queue'", run_commands[0])
        self.assertNotIn(" sh -lc 'npm run worker:queue'", run_commands[0])

    @patch("engine.create_runtime_session")
    def test_app_workers_apply_requires_existing_image(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeImageMissingSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "workers_apply",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "workers": [
                            {
                                "id": "queue-worker",
                                "name": "Queue worker",
                                "start_cmd": "npm run worker:queue",
                                "cpu_limit": 1.5,
                                "memory_mb": 512,
                                "disk_mb": 2048,
                            }
                        ],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("Verify web app image exists failed.", result["msg"])
        self.assertIn("Deploy web app first to build image", result["details"])

    @patch("engine.create_runtime_session")
    def test_app_workers_status_operation_returns_worker_snapshot(
        self, mock_create_runtime_session
    ):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "workers_status",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "workers": [
                            {
                                "id": "queue-worker",
                                "name": "Queue worker",
                                "start_cmd": "npm run worker:queue",
                                "cpu_limit": 1.5,
                                "memory_mb": 512,
                                "disk_mb": 2048,
                            }
                        ],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "workers_status")
        self.assertIn("workers", result)
        configured = result["workers"]["configured"]
        self.assertEqual(configured[0]["runtime"]["state"], "running")
        self.assertEqual(configured[0]["runtime"]["stats"]["cpu_perc"], "1.20%")

    @patch("engine.create_runtime_session")
    def test_app_workers_precheck_operation_returns_readiness_payload(
        self, mock_create_runtime_session
    ):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "workers_precheck",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "workers_precheck")
        self.assertIn("workers_precheck", result)
        self.assertEqual(result["workers_precheck"]["image_exists"], True)
        self.assertEqual(result["workers_precheck"]["app_container_running"], True)

    @patch("engine.create_runtime_session")
    def test_app_worker_logs_operation_returns_lines(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "worker_logs",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "worker_id": "queue-worker",
                    "log_tail_lines": 120,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "workers": [
                            {
                                "id": "queue-worker",
                                "name": "Queue worker",
                                "start_cmd": "npm run worker:queue",
                                "cpu_limit": 1.5,
                                "memory_mb": 512,
                                "disk_mb": 2048,
                            }
                        ],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "worker_logs")
        self.assertEqual(result["worker_id"], "queue-worker")
        self.assertEqual(result["log_tail_lines"], 120)
        self.assertIsInstance(result.get("logs"), list)

    @patch("engine.create_runtime_session")
    def test_app_worker_start_operation_resolves_network_in_run_command(
        self, mock_create_runtime_session
    ):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "worker_start",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "worker_id": "queue-worker",
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "workers": [
                            {
                                "id": "queue-worker",
                                "name": "Queue worker",
                                "start_cmd": "npm run worker:queue",
                                "cpu_limit": 1.5,
                                "memory_mb": 512,
                                "disk_mb": 2048,
                            }
                        ],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "worker_start")
        run_commands = [
            command
            for command in mock_create_runtime_session.return_value.host.commands
            if "docker run -d " in command
            and "deploydash_worker_remix-blog_queue-worker" in command
        ]
        self.assertEqual(len(run_commands), 1)
        self.assertIn('WORKER_NETWORK="$(docker inspect -f ', run_commands[0])
        self.assertIn('--network "${WORKER_NETWORK}"', run_commands[0])
        self.assertNotIn("--security-opt no-new-privileges", run_commands[0])
        self.assertNotIn("--cap-drop ALL", run_commands[0])
        self.assertIn("--pids-limit 512", run_commands[0])

    @patch("engine.create_runtime_session")
    def test_app_worker_start_requires_worker_id(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "worker_start",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "workers": [
                            {
                                "id": "queue-worker",
                                "name": "Queue worker",
                                "start_cmd": "npm run worker:queue",
                                "cpu_limit": 1.5,
                                "memory_mb": 512,
                                "disk_mb": 2048,
                            }
                        ],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("worker_id", result["msg"])

    @patch("engine.create_runtime_session")
    def test_app_worker_start_rejects_unknown_worker_id(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "worker_start",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "worker_id": "missing-worker",
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "workers": [
                            {
                                "id": "queue-worker",
                                "name": "Queue worker",
                                "start_cmd": "npm run worker:queue",
                                "cpu_limit": 1.5,
                                "memory_mb": 512,
                                "disk_mb": 2048,
                            }
                        ],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("is not configured", result["msg"])

    @patch("engine.create_runtime_session")
    def test_app_worker_start_rejects_disabled_worker(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "worker_start",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "worker_id": "queue-worker",
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "workers": [
                            {
                                "id": "queue-worker",
                                "name": "Queue worker",
                                "start_cmd": "npm run worker:queue",
                                "cpu_limit": 1.5,
                                "memory_mb": 512,
                                "disk_mb": 2048,
                                "enabled": False,
                            }
                        ],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("is disabled", result["msg"])

    @patch("engine.create_runtime_session")
    def test_app_worker_restart_operation_resolves_network_in_run_command(
        self, mock_create_runtime_session
    ):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "worker_restart",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "worker_id": "queue-worker",
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "workers": [
                            {
                                "id": "queue-worker",
                                "name": "Queue worker",
                                "start_cmd": "npm run worker:queue",
                                "cpu_limit": 1.5,
                                "memory_mb": 512,
                                "disk_mb": 2048,
                            }
                        ],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "worker_restart")
        run_commands = [
            command
            for command in mock_create_runtime_session.return_value.host.commands
            if "docker run -d " in command
            and "deploydash_worker_remix-blog_queue-worker" in command
        ]
        self.assertEqual(len(run_commands), 1)
        self.assertIn('WORKER_NETWORK="$(docker inspect -f ', run_commands[0])
        self.assertIn('--network "${WORKER_NETWORK}"', run_commands[0])
        self.assertNotIn("--security-opt no-new-privileges", run_commands[0])
        self.assertNotIn("--cap-drop ALL", run_commands[0])
        self.assertIn("--pids-limit 512", run_commands[0])

    @patch("engine.create_runtime_session")
    def test_app_worker_stop_operation_succeeds(self, mock_create_runtime_session):
        mock_create_runtime_session.return_value = _FakeSession()

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "app",
                "operation_id": "worker_stop",
                "connection": {
                    "ip": "203.0.113.10",
                    "port": 22,
                    "username": "root",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "worker_id": "queue-worker",
                    "settings": {
                        "project_slug": "remix-blog",
                        "repository_full_name": "acme/remix-blog",
                        "primary_domain": None,
                        "workers": [
                            {
                                "id": "queue-worker",
                                "name": "Queue worker",
                                "start_cmd": "npm run worker:queue",
                                "cpu_limit": 1.5,
                                "memory_mb": 512,
                                "disk_mb": 2048,
                            }
                        ],
                    },
                },
            }
        )
        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "worker_stop")
        self.assertEqual(result["worker_id"], "queue-worker")


if __name__ == "__main__":
    unittest.main()
