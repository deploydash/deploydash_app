"""Architecture invariant: engine dispatch keeps its documented wire contract.

Measurement: malformed input, workflow descriptions, dispatch failures, and
the registered-but-unimplemented mail workflow must all preserve the published
response and event envelope shapes.
"""

import json
import re
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

from engine import _error_result, handle_request
from orchestrator.workflow_registry import workflow_operation_exists
from workflow_registry import WORKFLOW_REGISTRY

_REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
_ANALYTICS_SERVICE = _REPOSITORY_ROOT / "ui" / "lib" / "services" / "app_analytics_service.dart"


def _parse_iso8601(timestamp):
    candidate = timestamp.strip()
    if candidate.endswith("Z"):
        candidate = candidate[:-1] + "+00:00"
    return datetime.fromisoformat(candidate)


def _dart_analytics_workflow_operations():
    """Read the closed Dart snapshot so the Python registry remains its owner."""
    source = _ANALYTICS_SERVICE.read_text(encoding="utf-8")
    start = source.index("const Map<String, Set<String>> knownEngineWorkflowOperations = {")
    end = source.index("\n};", start)
    snapshot = source[start:end]
    operations = set()
    current_workflow = None
    for line in snapshot.splitlines()[1:]:
        entry = re.fullmatch(r"  '([^']+)': \{(.*)", line)
        if entry is not None:
            current_workflow = entry.group(1)
            tail = entry.group(2)
            for operation in re.findall(r"'([^']+)'", tail):
                operations.add(f"{current_workflow}/{operation}")
            if tail.endswith("},"):
                current_workflow = None
            continue
        if current_workflow is None:
            continue
        if line == "  },":
            current_workflow = None
            continue
        for operation in re.findall(r"'([^']+)'", line):
            operations.add(f"{current_workflow}/{operation}")
    return frozenset(operations)


class TestEngineContractGuardrails(unittest.TestCase):
    def test_analytics_workflow_snapshot_matches_live_registry(self):
        """Rule: analytics cannot silently omit or retain a workflow operation."""
        expected = frozenset(
            f"{workflow_id}/{operation_id}"
            for workflow_id, workflow in WORKFLOW_REGISTRY.items()
            for operation_id in workflow
        )
        self.assertEqual(_dart_analytics_workflow_operations(), expected)

    def _assert_error_envelope(self, payload):
        result = json.loads(handle_request(payload))
        self.assertEqual(result["status"], "error")
        self.assertIsInstance(result.get("code"), str)
        self.assertTrue(result["code"])
        self.assertIsInstance(result.get("msg"), str)
        self.assertTrue(result["msg"])
        self.assertIsInstance(result.get("stage"), str)
        self.assertTrue(result["stage"])
        return result

    def _assert_event_shape(self, event):
        self.assertIsInstance(event, dict)
        self.assertIn("type", event)
        self.assertIn("level", event)
        self.assertIn("message", event)
        self.assertIn("data", event)
        self.assertIn("ts", event)
        self.assertIsInstance(event["type"], str)
        self.assertTrue(event["type"])
        self.assertIsInstance(event["level"], str)
        self.assertTrue(event["level"])
        self.assertIsInstance(event["message"], str)
        self.assertIsInstance(event["data"], dict)
        self.assertIsInstance(event["ts"], str)
        _parse_iso8601(event["ts"])

    def test_error_envelope_contract_for_invalid_inputs(self):
        invalid_payloads = [
            "invalid json",
            json.dumps(["not-an-object"]),
            json.dumps({"action": "run_workflow"}),
            json.dumps(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                }
            ),
            json.dumps(
                {
                    "action": "run_workflow",
                    "workflow_id": "setup",
                    "operation_id": "unknown_operation",
                }
            ),
            json.dumps({"action": "unknown_action"}),
        ]
        for payload in invalid_payloads:
            with self.subTest(payload=payload):
                self._assert_error_envelope(payload)

    def test_failure_evidence_survives_sanitization_and_serialization(self):
        """Rule: valid additive evidence crosses the v1 envelope intact and clean."""
        result = json.loads(
            json.dumps(
                _error_result(
                    "ENGINE_OPERATION_FAILED",
                    "Build failed.",
                    stage="execute_operations",
                    details="The normal fallback remains available.",
                    extra={
                        "failure_evidence": {
                            "schema_version": 1,
                            "phase": "build",
                            "source": "failed_operation",
                            "completeness": "diagnostic",
                            "lines": ["npm failed with TOKEN=synthetic-canary"],
                            "failed_step_id": "app_release",
                            "failed_action_id": "build_release_image",
                            "probe": {
                                "path": "/up",
                                "curl_exit": 22,
                                "http_status": 503,
                            },
                        }
                    },
                )
            )
        )

        self.assertEqual(result["msg"], "Build failed.")
        self.assertEqual(
            result["details"],
            "The normal fallback remains available.",
        )
        self.assertEqual(
            result["failure_evidence"],
            {
                "schema_version": 1,
                "phase": "build",
                "source": "failed_operation",
                "completeness": "diagnostic",
                "lines": ["npm failed with TOKEN=***"],
                "failed_step_id": "app_release",
                "failed_action_id": "build_release_image",
                "probe": {
                    "path": "/up",
                    "curl_exit": 22,
                    "http_status": 503,
                },
            },
        )

    def test_malformed_failure_evidence_is_omitted_without_losing_fallback(self):
        """Rule: producer defects cannot replace the standard error message."""
        valid = {
            "schema_version": 1,
            "phase": "build",
            "source": "failed_operation",
            "completeness": "diagnostic",
            "lines": ["compiler error"],
            "failed_step_id": "app_release",
            "failed_action_id": "build_release_image",
            "probe": None,
        }
        malformed = {
            "not an object": "invalid",
            "missing field": {key: value for key, value in valid.items() if key != "probe"},
            "future schema": {**valid, "schema_version": 2},
            "unknown producer phase": {**valid, "phase": "future_phase"},
            "unhashable phase": {**valid, "phase": []},
            "unknown producer source": {**valid, "source": "future_source"},
            "unknown producer completeness": {
                **valid,
                "completeness": "future_completeness",
            },
            "line collection is not a list": {**valid, "lines": "compiler error"},
            "non-string line": {**valid, "lines": [123]},
            "blank line": {**valid, "lines": ["  "]},
            "too many lines": {**valid, "lines": ["error"] * 13},
            "embedded too many lines": {
                **valid,
                "lines": ["\n".join(["error"] * 13)],
            },
            "oversized lines": {**valid, "lines": ["x" * 6145]},
            "blank step id": {**valid, "failed_step_id": " "},
            "non-string action id": {**valid, "failed_action_id": 3},
            "environment data": {**valid, "environment": {"FLAG": "canary"}},
            "probe is not an object": {**valid, "probe": "/up"},
            "empty probe": {**valid, "probe": {}},
            "response body": {
                **valid,
                "probe": {"path": "/up", "response_body": "canary"},
            },
            "non-string probe path": {**valid, "probe": {"path": 3}},
            "relative probe path": {**valid, "probe": {"path": "health"}},
            "boolean curl exit": {**valid, "probe": {"curl_exit": True}},
            "negative curl exit": {**valid, "probe": {"curl_exit": -1}},
            "large curl exit": {**valid, "probe": {"curl_exit": 256}},
            "boolean HTTP status": {**valid, "probe": {"http_status": True}},
            "small HTTP status": {**valid, "probe": {"http_status": 99}},
            "large HTTP status": {**valid, "probe": {"http_status": 600}},
            "empty diagnostic": {
                **valid,
                "lines": [],
                "failed_step_id": None,
                "failed_action_id": None,
            },
            "boundary with lines": {
                **valid,
                "completeness": "boundary_only",
            },
            "unavailable with probe": {
                **valid,
                "completeness": "unavailable",
                "lines": [],
                "probe": {"path": "/up"},
            },
        }

        for label, evidence in malformed.items():
            with self.subTest(label=label):
                result = _error_result(
                    "ENGINE_OPERATION_FAILED",
                    "Build failed.",
                    stage="execute_operations",
                    details="Use the complete sanitized log.",
                    extra={"failure_evidence": evidence},
                )
                self.assertNotIn("failure_evidence", result)
                self.assertEqual(result["msg"], "Build failed.")
                self.assertEqual(
                    result["details"],
                    "Use the complete sanitized log.",
                )

    def test_failure_evidence_accepts_each_safe_detail_shape(self):
        """Rule: null metadata and partial safe probes remain valid v1 evidence."""
        cases = [
            {
                "schema_version": 1,
                "phase": "engine",
                "source": "exception",
                "completeness": "diagnostic",
                "lines": ["unexpected exception"],
                "failed_step_id": None,
                "failed_action_id": None,
                "probe": None,
            },
            {
                "schema_version": 1,
                "phase": "candidate_readiness",
                "source": "candidate_probe",
                "completeness": "diagnostic",
                "lines": [],
                "failed_step_id": None,
                "failed_action_id": None,
                "probe": {"path": " /up "},
            },
            {
                "schema_version": 1,
                "phase": "post_cutover_stabilization",
                "source": "routed_probe",
                "completeness": "diagnostic",
                "lines": [],
                "failed_step_id": None,
                "failed_action_id": None,
                "probe": {"curl_exit": 7},
            },
            {
                "schema_version": 1,
                "phase": "traffic_switch",
                "source": "failed_operation",
                "completeness": "diagnostic",
                "lines": [],
                "failed_step_id": None,
                "failed_action_id": None,
                "probe": {"http_status": 502},
            },
            {
                "schema_version": 1,
                "phase": "rollback",
                "source": "none",
                "completeness": "boundary_only",
                "lines": [],
                "failed_step_id": None,
                "failed_action_id": None,
                "probe": None,
            },
            {
                "schema_version": 1,
                "phase": "unknown",
                "source": "unknown",
                "completeness": "unavailable",
                "lines": [],
                "failed_step_id": None,
                "failed_action_id": None,
                "probe": None,
            },
        ]

        serialized = []
        for evidence in cases:
            with self.subTest(evidence=evidence):
                result = _error_result(
                    "ENGINE_OPERATION_FAILED",
                    "Deployment failed.",
                    stage="execute_operations",
                    extra={"failure_evidence": evidence},
                )
                self.assertIn("failure_evidence", result)
                serialized.append(result["failure_evidence"])
        self.assertEqual(serialized[1]["probe"]["path"], "/up")

    def test_describe_workflow_event_schema_contract(self):
        describe_operations = [
            ("setup", "setup_plan_ready"),
            ("http", "http_plan_ready"),
            ("dns", "dns_plan_ready"),
            ("app", "app_plan_ready"),
            ("postgres", "postgres_plan_ready"),
            ("firewall", "firewall_plan_ready"),
            ("scheduler", "scheduler_plan_ready"),
        ]

        for workflow_id, expected_type in describe_operations:
            emitted = []
            request = {
                "action": "run_workflow",
                "workflow_id": workflow_id,
                "operation_id": "describe",
            }
            if workflow_id == "app":
                request["params"] = {
                    "settings": {
                        "project_slug": "sample-app",
                        "repository_full_name": "example-org/example-repo",
                        "branch": "main",
                        "primary_domain": "app.example.com",
                    }
                }
            payload = json.dumps(request)
            result = json.loads(handle_request(payload, emit=emitted.append))

            with self.subTest(workflow_id=workflow_id):
                self.assertEqual(result["status"], "success")
                self.assertGreaterEqual(len(emitted), 1)
                matching = [event for event in emitted if event.get("type") == expected_type]
                self.assertGreaterEqual(len(matching), 1)
                for event in emitted:
                    self._assert_event_shape(event)

    def test_dispatch_exception_contract_emits_structured_error_event(self):
        emitted = []

        def _raise_handler(*_args, **_kwargs):
            raise RuntimeError("forced contract failure")

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
            result = json.loads(handle_request(payload, emit=emitted.append))

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["stage"], "dispatch")
        self.assertIn("forced contract failure", result["msg"])
        self.assertIsInstance(result.get("details"), str)
        self.assertIn("Traceback", result["details"])

        unhandled_events = [
            event for event in emitted if event.get("type") == "engine_unhandled_exception"
        ]
        self.assertEqual(len(unhandled_events), 1)
        event = unhandled_events[0]
        self._assert_event_shape(event)
        self.assertEqual(event["level"], "error")
        self.assertEqual(event["data"].get("workflow_id"), "core")
        self.assertEqual(event["data"].get("operation_id"), "echo")

    def test_unimplemented_workflow_contract_for_mail(self):
        describe_payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "mail",
                "operation_id": "describe",
            }
        )
        describe_result = json.loads(handle_request(describe_payload))
        self.assertEqual(describe_result["status"], "success")
        self.assertEqual(describe_result["code"], "OK")
        self.assertEqual(describe_result["workflow_id"], "mail")
        self.assertEqual(describe_result["operation_id"], "describe")

        run_payload = json.dumps(
            {
                "action": "run_workflow",
                "workflow_id": "mail",
                "operation_id": "run",
            }
        )
        run_result = json.loads(handle_request(run_payload))
        self.assertEqual(run_result["status"], "error")
        self.assertEqual(run_result["code"], "ENGINE_NOT_IMPLEMENTED")
        self.assertEqual(run_result["stage"], "dispatch")
        self.assertEqual(run_result.get("workflow_id"), "mail")
        self.assertEqual(run_result.get("operation_id"), "run")

    def test_registry_contract_excludes_removed_milvus_workflow(self):
        self.assertNotIn("milvus", WORKFLOW_REGISTRY)
        self.assertFalse(workflow_operation_exists("milvus", "describe"))
        self.assertFalse(workflow_operation_exists("milvus", "run"))


if __name__ == "__main__":
    unittest.main()
