import json
import unittest
from unittest.mock import patch

import engine
from engine import handle_request


class TestEngineEntryPoint(unittest.TestCase):
    def test_registry_and_handlers_do_not_expose_removed_milvus_workflow(self):
        self.assertNotIn("milvus", engine.WORKFLOW_REGISTRY)
        self.assertNotIn(("milvus", "describe"), engine.WORKFLOW_OPERATION_HANDLERS)
        self.assertNotIn("milvus", engine.WORKFLOW_PLUGIN_COVERAGE_GAPS)

    def test_handle_request_echo(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "core",
                "operation_id": "echo",
                "data": "hello",
            }
        )
        result_str = handle_request(payload)
        result = json.loads(result_str)
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["action"], "echo")
        self.assertEqual(result["data"], "hello")

    def test_handle_request_invalid_json(self):
        result_str = handle_request("invalid json")
        result = json.loads(result_str)
        self.assertEqual(result["status"], "error")
        self.assertIn("JSON", result["msg"])

    def test_handle_request_run_workflow_echo(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "core",
                "operation_id": "echo",
                "data": "hello-workflow",
            }
        )
        result_str = handle_request(payload)
        result = json.loads(result_str)
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["workflow_id"], "core")
        self.assertEqual(result["operation_id"], "echo")
        self.assertEqual(result["data"], "hello-workflow")

    def test_handle_request_run_workflow_missing_ids(self):
        payload = json.dumps({"action": "run_workflow"})
        result_str = handle_request(payload)
        result = json.loads(result_str)
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")

    def test_handle_request_run_workflow_unknown_operation(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "setup",
                "operation_id": "unknown",
            }
        )
        result_str = handle_request(payload)
        result = json.loads(result_str)
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")

    def test_handle_request_run_workflow_placeholder_describe(self):
        payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "postgres",
                "operation_id": "describe",
            }
        )
        result_str = handle_request(payload)
        result = json.loads(result_str)
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["workflow_id"], "postgres")
        self.assertEqual(result["operation_id"], "describe")

    def test_handle_request_returns_structured_error_on_handler_exception(self):
        def _raise_handler(*_args, **_kwargs):
            raise RuntimeError("forced engine failure")

        with patch.dict(
            "engine.WORKFLOW_OPERATION_HANDLERS",
            {("core", "echo"): _raise_handler},
        ):
            payload = json.dumps(
                {
                    "action": "run_workflow",
                    "workflow_id": "core",
                    "operation_id": "echo",
                }
            )
            result_str = handle_request(payload)
            result = json.loads(result_str)

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["stage"], "dispatch")
        self.assertIn("forced engine failure", result["msg"])


if __name__ == "__main__":
    unittest.main()
