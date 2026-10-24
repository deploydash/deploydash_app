import unittest

from orchestrator.schema_validation import validate_against_schema
from orchestrator.workflow_registry import WORKFLOW_REGISTRY


def _iter_operations():
    for workflow_id, operations in WORKFLOW_REGISTRY.items():
        for operation_id, operation in operations.items():
            yield workflow_id, operation_id, operation


_OPEN_PARAMS_SCHEMA_ALLOWLIST = {
    ("core", "echo"): "Diagnostic arbitrary-JSON passthrough.",
}


class TestWorkflowRegistryParamsSchemaCompleteness(unittest.TestCase):
    """T-1.5.3/T-1.5.7 registry guards (D2).

    Written and observed failing before any operation declared a
    params_schema (every operation failed the "has key" check); now covers
    the completed registry so a future operation added without a schema, or
    with an unreasoned open schema, fails immediately rather than silently
    shipping unvalidated.
    """

    def test_every_operation_declares_a_params_schema(self):
        missing = [
            f"{workflow_id}/{operation_id}"
            for workflow_id, operation_id, operation in _iter_operations()
            if "params_schema" not in operation
        ]
        self.assertEqual(
            missing,
            [],
            f"Operations missing params_schema: {missing}",
        )

    def test_every_params_schema_is_a_draft_2020_12_object_schema(self):
        for workflow_id, operation_id, operation in _iter_operations():
            with self.subTest(workflow_id=workflow_id, operation_id=operation_id):
                schema = operation.get("params_schema")
                self.assertIsInstance(schema, dict)
                self.assertEqual(
                    schema.get("$schema"),
                    "https://json-schema.org/draft/2020-12/schema",
                )
                self.assertEqual(schema.get("type"), "object")
                self.assertIn("properties", schema)
                self.assertIsInstance(schema["properties"], dict)

    def test_only_reasoned_operations_leave_params_open(self):
        open_operations = {
            (workflow_id, operation_id)
            for workflow_id, operation_id, operation in _iter_operations()
            if operation["params_schema"].get("additionalProperties") is not False
        }
        self.assertEqual(open_operations, set(_OPEN_PARAMS_SCHEMA_ALLOWLIST))

    def test_non_passthrough_operations_reject_unknown_fields(self):
        for workflow_id, operation_id, operation in _iter_operations():
            if (workflow_id, operation_id) in _OPEN_PARAMS_SCHEMA_ALLOWLIST:
                continue
            with self.subTest(workflow_id=workflow_id, operation_id=operation_id):
                errors = validate_against_schema(
                    {"totally_bogus_key": 1},
                    operation["params_schema"],
                    path="payload",
                )
                self.assertNotEqual(errors, [])

    def test_required_settings_cannot_be_bypassed_by_omitting_settings(self):
        for workflow_id, operation_id, operation in _iter_operations():
            with self.subTest(workflow_id=workflow_id, operation_id=operation_id):
                if workflow_id not in {"app", "postgres"}:
                    continue
                schema = operation["params_schema"]
                properties = schema.get("properties", {})
                settings_schema = properties.get("settings")
                if not isinstance(settings_schema, dict):
                    continue
                required_settings = settings_schema.get("required", [])
                if not required_settings:
                    continue
                errors = validate_against_schema({}, schema, path="params")
                self.assertTrue(
                    any("settings is required" in error for error in errors),
                    "Operations with required settings must require the settings object "
                    "itself, so an empty params object cannot bypass their contract.",
                )


if __name__ == "__main__":
    unittest.main()
