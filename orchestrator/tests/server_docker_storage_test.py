import json
import unittest
from unittest.mock import patch

from engine import handle_request
from orchestrator.infra_parts import docker_storage as engine_infra_ops
from orchestrator.plugins.server_plugin import build_plugin
from orchestrator.workflow_registry import WORKFLOW_REGISTRY
from tests.engine_context_fixtures import build_test_context


class _FakeOutput:
    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


class _FakeDockerStorageHost:
    def __init__(self):
        self.commands = []
        self.status_call_count = 0

    def run_shell_command(self, command, _timeout=10, _sudo=False):
        self.commands.append((command, _timeout, _sudo))

        if "docker system df --format" in command:
            self.status_call_count += 1
            if self.status_call_count == 1:
                return True, _FakeOutput(
                    [
                        "",
                        '{"Type":"Images","TotalCount":"14","Active":"7","Size":"1.25GB","Reclaimable":"700MB (56%)"}',
                        '{"Type":"Build Cache","TotalCount":"28","Active":"0","Size":"450MB","Reclaimable":"450MB"}',
                    ]
                )
            return True, _FakeOutput(
                [
                    '{"Type":"Images","TotalCount":"0","Active":"0","Size":"0B","Reclaimable":"0B"}',
                    '{"Type":"Build Cache","TotalCount":"28","Active":"0","Size":"450MB","Reclaimable":"450MB"}',
                ]
            )

        if "docker image prune -af" in command:
            return True, _FakeOutput(["Deleted Images:"])

        if "docker builder prune -af" in command:
            return True, _FakeOutput(["Deleted build cache objects:"])

        return False, _FakeOutput(stderr_lines=["unexpected command"])


class _FakeSession:
    def __init__(self, host):
        self.host = host

    def close(self):
        return {"disconnect_error": None}


class _FakeSessionWithDisconnect(_FakeSession):
    def close(self):
        return {"disconnect_error": "disconnect failed"}


def _error_result(code, msg, stage=None, details=None, extra=None):
    return {
        "status": "error",
        "code": code,
        "msg": msg,
        "stage": stage,
        "details": details,
        "extra": extra or {},
    }


class TestServerDockerStorageHelpers(unittest.TestCase):
    def test_parse_docker_size_bytes_handles_supported_units(self):
        self.assertEqual(engine_infra_ops._parse_docker_size_bytes("0B"), 0)
        self.assertEqual(engine_infra_ops._parse_docker_size_bytes("450MB"), 450000000)
        self.assertEqual(
            engine_infra_ops._parse_docker_size_bytes("1.25GB"),
            1250000000,
        )
        self.assertEqual(
            engine_infra_ops._parse_docker_size_bytes("700MB (56%)"),
            700000000,
        )
        self.assertIsNone(engine_infra_ops._parse_docker_size_bytes("n/a"))

    def test_parse_docker_size_bytes_handles_empty_values(self):
        self.assertIsNone(engine_infra_ops._parse_docker_size_bytes(None))
        self.assertIsNone(engine_infra_ops._parse_docker_size_bytes("   "))

    def test_parse_docker_storage_status_output_reads_images_and_cache(self):
        output = _FakeOutput(
            [
                "noise",
                '{"Type":"Images","TotalCount":"14","Active":"7","Size":"1.25GB","Reclaimable":"700MB (56%)"}',
                '{"Type":"Build Cache","TotalCount":"28","Active":"0","Size":"450MB","Reclaimable":"450MB"}',
            ]
        )

        parsed = engine_infra_ops._parse_docker_storage_status_output(output)

        self.assertEqual(parsed["images"]["size_bytes"], 1250000000)
        self.assertEqual(parsed["images"]["reclaimable_bytes"], 700000000)
        self.assertEqual(parsed["images"]["total_count"], 14)
        self.assertEqual(parsed["build_cache"]["size_bytes"], 450000000)
        self.assertEqual(parsed["build_cache"]["total_count"], 28)

    def test_parse_docker_storage_status_output_skips_non_dict_json_rows(self):
        output = _FakeOutput(
            [
                "[]",
                '{"Type":"Images","TotalCount":"1","Active":"1","Size":"5MB","Reclaimable":"0B"}',
            ]
        )

        parsed = engine_infra_ops._parse_docker_storage_status_output(output)

        self.assertEqual(parsed["images"]["size_bytes"], 5000000)

    def test_read_server_docker_storage_status_returns_runtime_error(self):
        class _ErrorHost:
            def run_shell_command(self, *_args, **_kwargs):
                return False, _FakeOutput(stderr_lines=["docker missing"])

        session = _FakeSession(_ErrorHost())
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "docker missing",
        )

        result = engine_infra_ops._read_server_docker_storage_status(ctx, session)

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "ENGINE_RUNTIME_ERROR")

    def test_docker_storage_operations_honor_validation_and_cancellation(self):
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "failed",
        )

        cancelled_status = engine_infra_ops.run_server_docker_storage_status_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            is_cancelled=lambda: True,
        )
        cancelled_prune = engine_infra_ops.run_server_docker_storage_prune_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            target="unused_images",
            is_cancelled=lambda: True,
        )
        invalid_target = engine_infra_ops.run_server_docker_storage_prune_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            target="everything",
        )

        self.assertEqual(cancelled_status["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(cancelled_prune["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(invalid_target["code"], "ENGINE_VALIDATION_ERROR")

    def test_status_operation_returns_open_session_error(self):
        expected = _error_result("ENGINE_RUNTIME_ERROR", "open failed")
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            open_runtime_session=lambda **_kwargs: {"ok": False, "error": expected},
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "failed",
        )

        result = engine_infra_ops.run_server_docker_storage_status_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
        )

        self.assertEqual(result, expected)

    def test_status_operation_returns_runtime_error_and_emits_disconnect_warning(self):
        class _ErrorHost:
            def run_shell_command(self, *_args, **_kwargs):
                return False, _FakeOutput(stderr_lines=["docker missing"])

        emitted = []
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda emit, event_type, message, level="info", data=None: emit(
                {
                    "type": event_type,
                    "message": message,
                    "level": level,
                    "data": data or {},
                }
            ),
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSessionWithDisconnect(_ErrorHost()),
            },
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "docker missing",
        )

        result = engine_infra_ops.run_server_docker_storage_status_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            emit=emitted.append,
        )

        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(emitted[-1]["type"], "connection_disconnect_error")
        self.assertEqual(emitted[-1]["level"], "warning")

    def test_prune_operation_returns_open_session_error(self):
        expected = _error_result("ENGINE_RUNTIME_ERROR", "open failed")
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            open_runtime_session=lambda **_kwargs: {"ok": False, "error": expected},
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "failed",
        )

        result = engine_infra_ops.run_server_docker_storage_prune_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            target="unused_images",
        )

        self.assertEqual(result, expected)

    def test_prune_operation_returns_before_status_error(self):
        class _ErrorHost:
            def run_shell_command(self, *_args, **_kwargs):
                return False, _FakeOutput(stderr_lines=["docker missing"])

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(_ErrorHost()),
            },
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "docker missing",
        )

        result = engine_infra_ops.run_server_docker_storage_prune_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            target="unused_images",
        )

        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Couldn't read Docker storage usage.")

    def test_prune_operation_returns_prune_command_error(self):
        class _PruneErrorHost:
            def __init__(self):
                self.status_calls = 0

            def run_shell_command(self, command, _timeout=10, _sudo=False):
                del _timeout, _sudo
                if "docker system df --format" in command:
                    self.status_calls += 1
                    return True, _FakeOutput(
                        [
                            '{"Type":"Images","TotalCount":"1","Active":"0","Size":"5MB","Reclaimable":"5MB"}'
                        ]
                    )
                if "docker image prune -af" in command:
                    return False, _FakeOutput(stderr_lines=["prune failed"])
                return False, _FakeOutput(stderr_lines=["unexpected"])

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(_PruneErrorHost()),
            },
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "prune failed",
        )

        result = engine_infra_ops.run_server_docker_storage_prune_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            target="unused_images",
        )

        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Couldn't remove unused Docker images.")

    def test_prune_operation_returns_after_status_error(self):
        class _AfterStatusErrorHost:
            def __init__(self):
                self.status_calls = 0

            def run_shell_command(self, command, _timeout=10, _sudo=False):
                del _timeout, _sudo
                if "docker system df --format" in command:
                    self.status_calls += 1
                    if self.status_calls == 1:
                        return True, _FakeOutput(
                            [
                                '{"Type":"Images","TotalCount":"1","Active":"0","Size":"5MB","Reclaimable":"5MB"}'
                            ]
                        )
                    return False, _FakeOutput(stderr_lines=["docker missing"])
                if "docker image prune -af" in command:
                    return True, _FakeOutput(["Deleted Images:"])
                return False, _FakeOutput(stderr_lines=["unexpected"])

        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda *_args, **_kwargs: None,
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSession(_AfterStatusErrorHost()),
            },
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "docker missing",
        )

        result = engine_infra_ops.run_server_docker_storage_prune_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            target="unused_images",
        )

        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["msg"], "Couldn't read Docker storage usage.")

    def test_prune_operation_reports_disconnect_error_after_success(self):
        emitted = []
        ctx = build_test_context(
            error_result=_error_result,
            emit_event=lambda emit, event_type, message, level="info", data=None: emit(
                {
                    "type": event_type,
                    "message": message,
                    "level": level,
                    "data": data or {},
                }
            ),
            open_runtime_session=lambda **_kwargs: {
                "ok": True,
                "session": _FakeSessionWithDisconnect(_FakeDockerStorageHost()),
            },
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "docker missing",
        )

        result = engine_infra_ops.run_server_docker_storage_prune_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            target="unused_images",
            emit=emitted.append,
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(emitted[-1]["type"], "connection_disconnect_error")
        self.assertEqual(emitted[-1]["level"], "warning")


class TestServerDockerStoragePlugin(unittest.TestCase):
    def _build_plugin(self, *, connection_error=None):
        status_calls = []
        prune_calls = []

        ctx = build_test_context(
            check_ssh_and_specs=lambda **_kwargs: None,
            emit_event=lambda *_args, **_kwargs: None,
            error_result=_error_result,
            extract_connection_payload=lambda _data: {
                "ip": "127.0.0.1",
                "username": "ubuntu",
                "password": "secret",
                "key_path": "/tmp/id_ed25519",
                "port": 22,
            },
            connection_validation_error=lambda _payload: connection_error,
            resolve_dry_run=lambda data, default: data.get("dry_run", default),
            resolve_known_hosts_file=lambda: "/tmp/known_hosts",
            refresh_known_host_entry=lambda *_args, **_kwargs: True,
            run_server_overview_operation=lambda **_kwargs: None,
            run_server_docker_storage_status_operation=(
                lambda **kwargs: (
                    status_calls.append(kwargs)
                    or {"status": "success", "operation_id": "docker_storage_status"}
                )
            ),
            run_server_docker_storage_prune_operation=(
                lambda **kwargs: (
                    prune_calls.append(kwargs)
                    or {"status": "success", "operation_id": "docker_storage_prune"}
                )
            ),
            run_server_tooling_status_operation=lambda **_kwargs: None,
            run_server_tooling_update_operation=lambda **_kwargs: None,
            run_server_tooling_rollback_operation=lambda **_kwargs: None,
        )
        plugin = build_plugin(
            operations={
                "docker_storage_status": {"id": "docker_storage_status"},
                "docker_storage_prune": {"id": "docker_storage_prune"},
            },
            ctx=ctx,
        )
        return plugin, status_calls, prune_calls

    def test_plugin_returns_connection_errors_for_docker_storage_handlers(self):
        error = _error_result("ENGINE_VALIDATION_ERROR", "bad connection")
        plugin, status_calls, prune_calls = self._build_plugin(connection_error=error)

        self.assertEqual(plugin.handlers["docker_storage_status"]({}), error)
        self.assertEqual(plugin.handlers["docker_storage_prune"]({}), error)
        self.assertEqual(status_calls, [])
        self.assertEqual(prune_calls, [])

    def test_plugin_prune_handler_accepts_missing_params_dict(self):
        plugin, _status_calls, prune_calls = self._build_plugin()

        result = plugin.handlers["docker_storage_prune"]({"params": None})

        self.assertEqual(result["operation_id"], "docker_storage_prune")
        self.assertIsNone(prune_calls[0]["target"])


class TestServerDockerStorageRegistry(unittest.TestCase):
    def test_workflow_registry_exposes_docker_storage_operations(self):
        server_operations = WORKFLOW_REGISTRY["server"]

        self.assertIn("docker_storage_status", server_operations)
        self.assertIn("docker_storage_prune", server_operations)


class TestServerDockerStorageWorkflow(unittest.TestCase):
    def test_status_dry_run_returns_plan(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "docker_storage_status",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {"dry_run": True},
            }
        )

        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "docker_storage_status")
        self.assertIn("Read Docker image and build cache disk usage", result["actions"])

    @patch("engine.create_runtime_session")
    def test_status_reads_storage(self, mock_create_runtime_session):
        host = _FakeDockerStorageHost()
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "docker_storage_status",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {"dry_run": False},
            }
        )

        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["storage"]["images"]["size_bytes"], 1250000000)
        self.assertEqual(result["storage"]["build_cache"]["size_bytes"], 450000000)

    def test_prune_dry_run_returns_plan(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "docker_storage_prune",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": True,
                    "target": "unused_images",
                },
            }
        )

        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["target"], "unused_images")
        self.assertIn("Remove unused Docker images", result["actions"])

    @patch("engine.create_runtime_session")
    def test_prune_removes_unused_images_and_reports_reclaimed_bytes(
        self,
        mock_create_runtime_session,
    ):
        host = _FakeDockerStorageHost()
        mock_create_runtime_session.return_value = _FakeSession(host)

        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "server",
                "operation_id": "docker_storage_prune",
                "connection": {
                    "ip": "203.0.113.44",
                    "port": 22,
                    "username": "ubuntu",
                    "password": "secret",
                },
                "params": {
                    "dry_run": False,
                    "target": "unused_images",
                },
            }
        )

        result = json.loads(handle_request(payload))

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["target"], "unused_images")
        self.assertEqual(result["reclaimed_bytes"], 1250000000)
        self.assertEqual(result["storage"]["images"]["size_bytes"], 0)
        self.assertTrue(any("docker image prune -af" in command for command, _, _ in host.commands))


if __name__ == "__main__":
    unittest.main()
