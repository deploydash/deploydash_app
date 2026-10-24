import inspect
import unittest
from unittest.mock import patch

import orchestrator.failure_evidence as failure_evidence


class TestFailureEvidenceSelection(unittest.TestCase):
    def _select_payload(self, **overrides):
        """Exercise the public selector through the same serializer used at the wire boundary."""
        input_type = getattr(failure_evidence, "FailureEvidenceInput", None)
        selector = getattr(failure_evidence, "select_failure_evidence", None)
        self.assertIsNotNone(input_type, "the immutable selector input is missing")
        self.assertTrue(callable(selector), "the generic evidence selector is missing")
        defaults = {
            "phase": "build",
            "source": "failed_operation",
            "stderr_lines": (),
            "stdout_lines": (),
            "wrapper_lines": (),
            "failed_step_id": "app_release",
            "failed_action_id": "build_release_image",
            "boundary_reached": True,
        }
        defaults.update(overrides)
        evidence = selector(input_type(**defaults))
        payload = failure_evidence.serialize_failure_evidence(evidence)
        self.assertIsNotNone(payload)
        return payload

    def test_prefers_stderr_and_uses_stdout_only_as_fallback_capacity(self):
        """Stderr must win selection while stdout remains available when stderr is absent."""
        stderr = tuple(f"stderr diagnostic {index}" for index in range(14))
        selected = self._select_payload(
            stderr_lines=stderr,
            stdout_lines=("FATAL stdout must not displace stderr",),
        )

        self.assertEqual(len(selected["lines"]), 12)
        self.assertTrue(all(line.startswith("stderr") for line in selected["lines"]))

        fallback = self._select_payload(
            stderr_lines=(),
            stdout_lines=("stdout-only frobnicator became purple",),
        )
        self.assertEqual(fallback["lines"], ["stdout-only frobnicator became purple"])

    def test_retains_unfamiliar_stderr_without_requiring_a_marker(self):
        """Marker-free operation output is still evidence rather than an unavailable failure."""
        selected = self._select_payload(
            stderr_lines=("frobnicator became purple",),
            stdout_lines=("ordinary stdout context",),
        )

        self.assertEqual(selected["completeness"], "diagnostic")
        self.assertEqual(selected["lines"][0], "frobnicator became purple")

    def test_splits_multiline_compiler_context_and_keeps_exception_tail(self):
        """A useful contiguous window must retain context before and detail after markers."""
        compiler = self._select_payload(
            stderr_lines=(
                "resolving package\nlib/main.dart:41:7: error: undefined name\n"
                "  deployRelease();\n  ^^^^^^^^^^^^^",
            ),
        )
        self.assertIn("resolving package", compiler["lines"])
        self.assertIn("lib/main.dart:41:7: error: undefined name", compiler["lines"])

        traceback = self._select_payload(
            stderr_lines=(
                "Traceback (most recent call last):\n"
                '  File "runner.py", line 9, in deploy\n'
                "RuntimeError: candidate never became ready",
            ),
        )
        self.assertEqual(
            traceback["lines"][-1],
            "RuntimeError: candidate never became ready",
        )

    def test_collapses_only_adjacent_duplicate_retry_blocks(self):
        """Repeated retries must not crowd out context or erase a later recurrence."""
        selected = self._select_payload(
            stderr_lines=(
                "retrying probe",
                "retrying probe",
                "frobnicator became purple",
                "retrying probe",
                "frobnicator became purple",
                "new context",
                "frobnicator became purple",
            ),
        )

        self.assertEqual(selected["lines"].count("retrying probe"), 1)
        self.assertEqual(selected["lines"].count("frobnicator became purple"), 2)
        self.assertLess(
            selected["lines"].index("retrying probe"),
            selected["lines"].index("new context"),
        )

    def test_wrapper_only_is_boundary_only_and_abrupt_empty_failure_is_unavailable(self):
        """Completeness must describe known boundaries without promoting wrapper prose."""
        wrapper = "Failed action: Build release image"
        boundary = self._select_payload(
            stderr_lines=(wrapper,),
            wrapper_lines=(wrapper,),
        )
        self.assertEqual(boundary["completeness"], "boundary_only")
        self.assertEqual(boundary["lines"], [])

        unavailable = self._select_payload(
            phase="engine",
            source="exception",
            failed_step_id=None,
            failed_action_id=None,
            boundary_reached=False,
        )
        self.assertEqual(unavailable["completeness"], "unavailable")
        self.assertEqual(unavailable["lines"], [])

    def test_enforces_line_byte_ansi_control_and_late_sanitization_bounds(self):
        """Selected evidence must be bounded and sanitized after ranking raw diagnostics."""
        oversized = "\x1b[31mERROR TOKEN=selected-canary\x00 " + ("é" * 7000)
        selected = self._select_payload(
            stderr_lines=(*(f"context {index}" for index in range(20)), oversized),
        )

        lines = selected["lines"]
        self.assertLessEqual(len(lines), failure_evidence.FAILURE_EVIDENCE_MAX_LINES)
        self.assertLessEqual(
            len("\n".join(lines).encode("utf-8")),
            failure_evidence.FAILURE_EVIDENCE_MAX_ENCODED_LINE_BYTES,
        )
        self.assertIn("TOKEN=***", "\n".join(lines))
        self.assertNotIn("selected-canary", repr(selected))
        self.assertNotIn("\x1b", repr(selected))
        self.assertNotIn("\x00", repr(selected))

    def test_handles_empty_final_sanitization_and_exhausted_multibyte_budgets(self):
        """Final sanitation and UTF-8 budgeting must not emit blanks or overrun separators."""
        with patch.object(failure_evidence, "_SANITIZE_TEXT", return_value=""):
            emptied = self._select_payload(stderr_lines=("diagnostic before sanitation",))
        self.assertEqual(emptied["completeness"], "boundary_only")

        exhausted = self._select_payload(
            stderr_lines=("x" * 7000, "later line cannot fit"),
        )
        self.assertEqual(len(exhausted["lines"]), 1)
        self.assertEqual(
            len("\n".join(exhausted["lines"]).encode("utf-8")),
            failure_evidence.FAILURE_EVIDENCE_MAX_ENCODED_LINE_BYTES,
        )

        split_character = self._select_payload(
            stderr_lines=("x" * 6142, "é"),
        )
        self.assertEqual(split_character["lines"], ["x" * 6142])

    def test_normalizes_structured_json_xml_and_embedded_newlines_once(self):
        """The selector and backup formatter must share one structured-error normalizer."""
        selected = self._select_payload(
            stderr_lines=(
                '{"error":{"code":"ServiceUnavailable","message":"Try again later."}}',
                "wal-g failed <Error><Code>AccessDenied</Code>"
                "<Message>Access Denied.</Message></Error>",
            ),
        )

        self.assertEqual(
            selected["lines"],
            [
                "ServiceUnavailable: Try again later.",
                "wal-g failed: AccessDenied: Access Denied.",
            ],
        )

    def test_redacts_selected_canary_and_never_serializes_discarded_canary(self):
        """Secrets must be absent whether a bounded window selects or discards their line."""
        selected = self._select_payload(
            stderr_lines=(
                "TOKEN=discarded-canary",
                *(f"neutral context {index}" for index in range(20)),
                "FATAL API_KEY=selected-canary",
            ),
        )

        rendered = repr(selected)
        self.assertNotIn("discarded-canary", rendered)
        self.assertNotIn("selected-canary", rendered)
        self.assertIn("API_KEY=***", rendered)

        multiline = self._select_payload(
            stderr_lines=(
                "ERROR while loading key\n"
                "-----BEGIN PRIVATE KEY-----\n"
                "multiline-private-key-canary\n"
                "-----END PRIVATE KEY-----",
            ),
        )
        self.assertNotIn("multiline-private-key-canary", repr(multiline))
        self.assertNotIn("BEGIN PRIVATE KEY", repr(multiline))

        direct_producer = failure_evidence.serialize_failure_evidence(
            {
                "schema_version": 1,
                "phase": "build",
                "source": "failed_operation",
                "completeness": "diagnostic",
                "lines": [
                    "ERROR while loading key",
                    "-----BEGIN PRIVATE KEY-----",
                    "direct-producer-private-key-canary",
                    "-----END PRIVATE KEY-----",
                ],
                "failed_step_id": "app_release",
                "failed_action_id": "build_release_image",
                "probe": None,
            }
        )
        self.assertIsNotNone(direct_producer)
        self.assertNotIn("direct-producer-private-key-canary", repr(direct_producer))
        self.assertNotIn("BEGIN PRIVATE KEY", repr(direct_producer))

    def test_selector_is_pure_and_cannot_read_an_earlier_success_transcript(self):
        """Calling the selector for a later failed operation must not retain prior output."""
        self._select_payload(stderr_lines=("FATAL earlier successful operation marker",))
        selected = self._select_payload(stderr_lines=("actual unfamiliar failure output",))

        self.assertEqual(selected["lines"], ["actual unfamiliar failure output"])
        input_type = failure_evidence.FailureEvidenceInput
        self.assertNotIn("transcript", inspect.signature(input_type).parameters)

    def test_serializes_safe_probe_facts_and_rejects_response_body_fields(self):
        """Probe evidence may carry status facts but never an HTTP response body."""
        probe_type = getattr(failure_evidence, "FailureEvidenceProbe", None)
        self.assertIsNotNone(probe_type, "the immutable safe-probe type is missing")
        selected = self._select_payload(
            phase="candidate_readiness",
            source="candidate_probe",
            probe=probe_type(path="/up", curl_exit=22, http_status=503),
        )
        self.assertEqual(
            selected["probe"],
            {"path": "/up", "curl_exit": 22, "http_status": 503},
        )

        empty_probe = self._select_payload(probe=probe_type())
        self.assertEqual(empty_probe["completeness"], "boundary_only")

        invalid_probe = self._select_payload(
            probe=probe_type(path="relative", curl_exit=256, http_status=600),
        )
        self.assertEqual(invalid_probe["completeness"], "boundary_only")

        forbidden = {
            **selected,
            "probe": {**selected["probe"], "response_body": "private-canary"},
        }
        self.assertIsNone(failure_evidence.serialize_failure_evidence(forbidden))


if __name__ == "__main__":
    unittest.main()
