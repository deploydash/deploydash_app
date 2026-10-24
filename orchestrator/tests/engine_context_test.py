import unittest

from orchestrator.engine_context import build_partial_context


class TestBuildPartialContext(unittest.TestCase):
    def test_unset_field_raises_with_field_name_when_called(self):
        ctx = build_partial_context(error_result=lambda *a, **kw: {"status": "error"})

        with self.assertRaises(NotImplementedError) as raised:
            ctx.emit_event(None, "some_event", "message")

        self.assertIn("emit_event", str(raised.exception))
        self.assertIn("not provided", str(raised.exception))

    def test_override_is_used_instead_of_the_stub(self):
        calls = []
        ctx = build_partial_context(
            emit_event=lambda *args, **kwargs: calls.append((args, kwargs)),
        )

        ctx.emit_event(None, "some_event", "message")

        self.assertEqual(calls, [((None, "some_event", "message"), {})])

    def test_every_unset_field_is_independently_stubbed(self):
        ctx = build_partial_context()

        for field_name in (
            "create_runtime_session",
            "open_runtime_session",
            "error_result",
            "emit_event",
            "sanitize_message",
            "emit_shell_output_lines",
            "command_error_details",
            "read_remote_file_text",
            "probe_http_gateway_fast_path",
            "setup_http_gateway",
            "normalize_runtime_log_tail",
        ):
            with self.assertRaises(NotImplementedError):
                getattr(ctx, field_name)()


if __name__ == "__main__":
    unittest.main()
