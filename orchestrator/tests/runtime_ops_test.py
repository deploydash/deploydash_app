import unittest

from orchestrator.runtime_ops import (
    _join_nonempty_lines,
    remove_remote_files,
    run_shell_command,
    systemd_daemon_reload,
    systemd_disable_now,
    systemd_enable_now,
    systemd_reset_failed,
    systemd_service_action,
    write_remote_text_file,
)


class _FakeOutput:
    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


class _FakeHost:
    def __init__(self, ok=True, output=None):
        self.ok = ok
        self.output = output if output is not None else _FakeOutput()
        self.calls = []

    def run_shell_command(self, command, _timeout=0, _sudo=False):
        self.calls.append(
            {
                "command": command,
                "timeout": _timeout,
                "sudo": _sudo,
            }
        )
        return self.ok, self.output


class TestRuntimeOps(unittest.TestCase):
    def test_run_shell_command_extracts_error_details(self):
        host = _FakeHost(
            ok=False,
            output=_FakeOutput(stderr_lines=["first error", "second error"]),
        )

        result = run_shell_command(host, "echo test", timeout=12, sudo=True)

        self.assertFalse(result["ok"])
        self.assertEqual(result["details"], "first error; second error")
        self.assertEqual(host.calls[0]["timeout"], 12)
        self.assertTrue(host.calls[0]["sudo"])

    def test_write_remote_text_file_writes_content_and_mode(self):
        host = _FakeHost(ok=True, output=_FakeOutput())

        result = write_remote_text_file(
            host,
            path="/tmp/example.conf",
            content="A=1\nB=2",
            mode="640",
            timeout=30,
        )

        self.assertTrue(result["ok"])
        command = host.calls[0]["command"]
        self.assertIn("cat > /tmp/example.conf <<", command)
        self.assertIn("A=1\nB=2\n", command)
        self.assertIn("chmod 640 /tmp/example.conf", command)

    def test_systemd_helpers_build_expected_commands(self):
        host = _FakeHost(ok=True, output=_FakeOutput())

        systemd_daemon_reload(host)
        systemd_enable_now(host, unit="example.timer")
        systemd_disable_now(host, unit="example.timer", ignore_failure=True)
        systemd_service_action(host, unit="example.service", action="restart")
        systemd_reset_failed(host, units=["example.timer", "example.service"])
        remove_remote_files(host, paths=["/tmp/a", "/tmp/b"])

        commands = [item["command"] for item in host.calls]
        self.assertEqual(commands[0], "systemctl daemon-reload")
        self.assertEqual(commands[1], "systemctl enable --now example.timer")
        self.assertEqual(commands[2], "systemctl disable --now example.timer || true")
        self.assertEqual(commands[3], "systemctl restart example.service")
        self.assertEqual(
            commands[4],
            "systemctl reset-failed example.timer example.service || true",
        )
        self.assertEqual(commands[5], "rm -f /tmp/a /tmp/b")


class TestJoinNonemptyLines(unittest.TestCase):
    def test_skips_blank_lines_and_strips_the_rest(self):
        self.assertEqual(
            _join_nonempty_lines(["  first  ", "", "   ", "second"]),
            "first; second",
        )

    def test_honors_an_explicit_separator(self):
        self.assertEqual(
            _join_nonempty_lines(["a", "b"], separator=" | "),
            "a | b",
        )

    def test_empty_input_yields_empty_string(self):
        self.assertEqual(_join_nonempty_lines([]), "")
        self.assertEqual(_join_nonempty_lines(["", "   "]), "")

    def test_stringifies_non_string_lines(self):
        self.assertEqual(_join_nonempty_lines(["rc=", 2]), "rc=; 2")


if __name__ == "__main__":
    unittest.main()
