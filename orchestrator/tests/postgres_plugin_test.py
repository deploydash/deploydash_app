import unittest

from orchestrator.plugins.postgres_plugin import build_plugin
from tests.engine_context_fixtures import build_test_context


class TestPostgresPlugin(unittest.TestCase):
    def _build_plugin(
        self,
        *,
        describe_response=None,
        connection_error=None,
    ):
        runtime_calls = []
        project_calls = []
        emitted_events = []

        def emit_event(emit, event_type, message, level="info", data=None):
            payload = {
                "type": event_type,
                "level": level,
                "message": message,
                "data": data or {},
            }
            emitted_events.append(payload)
            if emit is not None:
                emit(payload)

        def run_postgres_runtime_operation(**kwargs):
            runtime_calls.append(kwargs)
            return {"status": "success", "operation_id": kwargs["operation_id"]}

        def run_postgres_project_operation(**kwargs):
            project_calls.append(kwargs)
            return {"status": "success", "operation_id": kwargs["operation_id"]}

        operations = {
            operation_id: {"id": operation_id}
            for operation_id in [
                "describe",
                "run",
                "service_enable",
                "service_start",
                "service_stop",
                "service_restart",
                "service_configure",
                "service_status",
                "service_delete",
                "project_list",
                "project_list_schemas",
                "project_list_tables",
                "project_describe_table",
                "project_explain_readonly_query",
                "project_execute_readonly_query",
                "project_create_database",
                "project_create_user",
                "project_delete_database",
                "project_rotate_password",
                "project_delete_user",
                "project_delete",
                "project_normalize_database",
                "backup_destination_test",
                "backup_policy_apply",
                "backup_policy_delete",
                "backup_run_now",
                "backup_artifact_list",
                "backup_backlog_report",
                "backup_backlog_cleanup",
                "restore_run_now",
                "import_local_sql",
            ]
        }

        ctx = build_test_context(
            describe_postgres=lambda **_: (
                describe_response
                or {
                    "status": "success",
                    "selected_version": "17",
                    "supported_versions": ["17", "16"],
                }
            ),
            extract_postgres_settings_payload=lambda data: {"settings": data.get("settings", {})},
            emit_event=emit_event,
            extract_connection_payload=lambda _data: {
                "ip": "127.0.0.1",
                "username": "ubuntu",
                "password": "secret",
                "key_path": "/tmp/id_ed25519",
                "port": 22,
            },
            connection_validation_error=lambda _payload: connection_error,
            run_postgres_runtime_operation=run_postgres_runtime_operation,
            run_postgres_project_operation=run_postgres_project_operation,
            resolve_dry_run=lambda data, default: data.get("dry_run", default),
        )
        plugin = build_plugin(
            operations=operations,
            ctx=ctx,
        )
        return plugin, runtime_calls, project_calls, emitted_events

    def test_describe_success_emits_plan_ready_event(self):
        plugin, _runtime_calls, _project_calls, emitted_events = self._build_plugin()

        events = []
        result = plugin.handlers["describe"](
            {"settings": {"postgres_version": "17"}},
            emit=events.append,
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(plugin.workflow_id, "postgres")
        self.assertEqual(plugin.operations["describe"]["id"], "describe")
        self.assertEqual(events[0]["type"], "postgres_plan_ready")
        self.assertEqual(events[0]["data"]["selected_version"], "17")
        self.assertEqual(emitted_events[0]["type"], "postgres_plan_ready")

    def test_describe_error_emits_validation_error(self):
        plugin, _runtime_calls, _project_calls, _emitted_events = self._build_plugin(
            describe_response={"status": "error", "msg": "bad postgres"},
        )

        events = []
        result = plugin.handlers["describe"]({}, emit=events.append)

        self.assertEqual(result["status"], "error")
        self.assertEqual(events[0]["type"], "validation_error")
        self.assertEqual(events[0]["message"], "bad postgres")
        self.assertEqual(events[0]["level"], "error")

    def test_runtime_handlers_delegate_expected_operation_ids(self):
        plugin, runtime_calls, _project_calls, _emitted_events = self._build_plugin()

        expected = {
            "run": "service_enable",
            "service_enable": "service_enable",
            "service_start": "service_start",
            "service_stop": "service_stop",
            "service_restart": "service_restart",
            "service_configure": "service_configure",
            "service_status": "service_status",
            "service_delete": "service_delete",
        }

        for handler_name, operation_id in expected.items():
            with self.subTest(handler_name=handler_name):
                result = plugin.handlers[handler_name](
                    {"dry_run": True, "settings": {"scope": handler_name}},
                    emit=lambda _event: None,
                    is_cancelled=lambda: False,
                )
                self.assertEqual(result["operation_id"], operation_id)

        self.assertEqual(
            [call["operation_id"] for call in runtime_calls],
            list(expected.values()),
        )
        for call in runtime_calls:
            self.assertEqual(call["ip"], "127.0.0.1")
            self.assertEqual(call["username"], "ubuntu")
            self.assertEqual(call["password"], "secret")
            self.assertEqual(call["key_filename"], "/tmp/id_ed25519")
            self.assertEqual(call["port"], 22)
            self.assertTrue(call["dry_run"])

    def test_project_handlers_delegate_expected_operation_ids(self):
        plugin, _runtime_calls, project_calls, _emitted_events = self._build_plugin()

        expected = {
            "project_list": "project_list",
            "project_list_schemas": "project_list_schemas",
            "project_list_tables": "project_list_tables",
            "project_describe_table": "project_describe_table",
            "project_explain_readonly_query": "project_explain_readonly_query",
            "project_execute_readonly_query": "project_execute_readonly_query",
            "project_create_database": "project_create_database",
            "project_create_user": "project_create_user",
            "project_delete_database": "project_delete_database",
            "project_rotate_password": "project_rotate_password",
            "project_delete_user": "project_delete_user",
            "project_delete": "project_delete",
            "project_normalize_database": "project_normalize_database",
            "backup_destination_test": "backup_destination_test",
            "backup_policy_apply": "backup_policy_apply",
            "backup_policy_delete": "backup_policy_delete",
            "backup_run_now": "backup_run_now",
            "backup_artifact_list": "backup_artifact_list",
            "backup_backlog_report": "backup_backlog_report",
            "backup_backlog_cleanup": "backup_backlog_cleanup",
            "restore_run_now": "restore_run_now",
            "import_local_sql": "import_local_sql",
        }

        for handler_name, operation_id in expected.items():
            with self.subTest(handler_name=handler_name):
                result = plugin.handlers[handler_name](
                    {"dry_run": False, "settings": {"scope": handler_name}},
                    emit=lambda _event: None,
                    is_cancelled=lambda: False,
                )
                self.assertEqual(result["operation_id"], operation_id)

        self.assertEqual(
            [call["operation_id"] for call in project_calls],
            list(expected.values()),
        )
        self.assertTrue(all(call["dry_run"] is False for call in project_calls))

    def test_connection_validation_error_short_circuits_runtime_and_project_handlers(
        self,
    ):
        error = {"status": "error", "msg": "missing connection"}
        plugin, runtime_calls, project_calls, _emitted_events = self._build_plugin(
            connection_error=error
        )

        runtime_result = plugin.handlers["service_start"]({})
        project_result = plugin.handlers["project_create_user"]({})

        self.assertEqual(runtime_result, error)
        self.assertEqual(project_result, error)
        self.assertEqual(runtime_calls, [])
        self.assertEqual(project_calls, [])


if __name__ == "__main__":
    unittest.main()
