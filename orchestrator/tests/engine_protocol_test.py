"""T-1.5.1: the request envelope carries a `protocol` field.

Written before the validation existed (discipline D1). Every recorded
envelope predates this field (T-0.5's corpus, when it exists, was captured
before section 1.4), so an absent `protocol` must still work for this
release -- the four branches below are the whole contract.
"""

import json
import unittest

from engine import handle_request


def _describe_postgres_payload(protocol=None):
    payload = {
        "action": "run_workflow",
        "workflow_id": "postgres",
        "operation_id": "describe",
    }
    if protocol is not None:
        payload["protocol"] = protocol
    return json.dumps(payload)


class TestRequestProtocolField(unittest.TestCase):
    def test_absent_protocol_is_accepted_as_version_1(self):
        result = json.loads(handle_request(_describe_postgres_payload()))
        self.assertEqual(result["status"], "success")

    def test_protocol_equal_to_known_version_is_accepted(self):
        result = json.loads(handle_request(_describe_postgres_payload(1)))
        self.assertEqual(result["status"], "success")

    def test_protocol_greater_than_known_is_rejected(self):
        result = json.loads(handle_request(_describe_postgres_payload(2)))
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_PROTOCOL_TOO_NEW")

    def test_protocol_wrong_type_is_rejected(self):
        for bad_value in ("1", 1.5, True, [1], {"version": 1}):
            with self.subTest(value=bad_value):
                result = json.loads(handle_request(_describe_postgres_payload(bad_value)))
                self.assertEqual(result["status"], "error")
                self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")


if __name__ == "__main__":
    unittest.main()
