import json
import unittest

import engine
from orchestrator.registry import (
    build_handler_map,
    build_plugins_from_handlers,
    validate_plugin_coverage,
)
from orchestrator.runtime import EngineRuntime


def _error_result(code, msg, stage, details=None, extra=None):
    payload = {
        "status": "error",
        "code": code,
        "msg": msg,
        "stage": stage,
        "details": details,
    }
    if extra:
        payload.update(extra)
    return payload


def _emit_event(emit, event_type, message, level="info", data=None):
    if emit is None:
        return
    emit(
        {
            "type": event_type,
            "level": level,
            "message": message,
            "data": data or {},
        },
    )


class TestEngineRuntime(unittest.TestCase):
    def test_run_workflow_dispatches_to_registered_handler(self):
        registry = {
            "core": {
                "echo": {"id": "echo"},
            },
        }
        handlers = {
            ("core", "echo"): lambda data, **_: {
                "status": "success",
                "workflow_id": "core",
                "operation_id": "echo",
                "data": data.get("data"),
            },
        }
        runtime = EngineRuntime(
            workflow_registry_getter=lambda: registry,
            workflow_handlers_getter=lambda: handlers,
            error_result=_error_result,
            emit_event=_emit_event,
            unimplemented_handler=lambda _wf, _op: {"status": "success"},
        )

        result = json.loads(
            runtime.handle_request_json(
                json.dumps(
                    {
                        "action": "run_workflow",
                        "workflow_id": "core",
                        "operation_id": "echo",
                        "data": "hello",
                    },
                )
            )
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["workflow_id"], "core")
        self.assertEqual(result["operation_id"], "echo")
        self.assertEqual(result["data"], "hello")

    def test_runtime_wraps_handler_exceptions(self):
        registry = {"core": {"echo": {"id": "echo"}}}
        handlers = {
            ("core", "echo"): lambda _data, **_: (_ for _ in ()).throw(RuntimeError("boom")),
        }
        runtime = EngineRuntime(
            workflow_registry_getter=lambda: registry,
            workflow_handlers_getter=lambda: handlers,
            error_result=_error_result,
            emit_event=_emit_event,
            unimplemented_handler=lambda _wf, _op: {"status": "success"},
        )

        events = []
        result = json.loads(
            runtime.handle_request_json(
                json.dumps(
                    {
                        "action": "run_workflow",
                        "workflow_id": "core",
                        "operation_id": "echo",
                    }
                ),
                emit=events.append,
            )
        )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["stage"], "dispatch")
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["type"], "engine_unhandled_exception")


class TestEngineRegistry(unittest.TestCase):
    def test_plugin_builder_and_coverage(self):
        workflow_registry = {
            "core": {"echo": {"id": "echo"}},
            "mail": {"describe": {"id": "describe"}},
        }
        workflow_handlers = {
            ("core", "echo"): lambda _data, **_: {"status": "success"},
        }
        plugins = build_plugins_from_handlers(workflow_registry, workflow_handlers)
        handler_map = build_handler_map(plugins)
        coverage = validate_plugin_coverage(workflow_registry, plugins)

        self.assertIn(("core", "echo"), handler_map)
        self.assertIn("mail", coverage)
        self.assertEqual(coverage["mail"], ["describe"])


class TestEnginePluginWiring(unittest.TestCase):
    def test_runtime_plugins_exclude_removed_milvus_workflow(self):
        plugin_ids = {plugin.workflow_id for plugin in engine.EXTRACTED_WORKFLOW_PLUGINS}

        self.assertNotIn("milvus", plugin_ids)
        self.assertNotIn("milvus", engine.WORKFLOW_REGISTRY)
        self.assertNotIn("milvus", engine.WORKFLOW_PLUGIN_COVERAGE_GAPS)

    def test_extracted_workflow_handlers_override_engine_dispatch(self):
        extracted_workflow_ids = {
            "core",
            "server",
            "setup",
            "http",
            "dns",
            "postgres",
            "app",
            "firewall",
            "scheduler",
        }
        extracted_keys = {
            (workflow_id, operation_id)
            for workflow_id in extracted_workflow_ids
            for operation_id in engine.WORKFLOW_REGISTRY[workflow_id]
        }

        for key in extracted_keys:
            with self.subTest(key=key):
                self.assertIn(key, engine.EXTRACTED_WORKFLOW_HANDLER_MAP)
                self.assertIn(key, engine.WORKFLOW_OPERATION_HANDLERS)
                self.assertIs(
                    engine.WORKFLOW_OPERATION_HANDLERS[key],
                    engine.EXTRACTED_WORKFLOW_HANDLER_MAP[key],
                )
                self.assertTrue(
                    engine.WORKFLOW_OPERATION_HANDLERS[key].__module__.startswith(
                        "orchestrator.plugins."
                    )
                )


if __name__ == "__main__":
    unittest.main()
