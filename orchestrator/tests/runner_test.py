import json
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

import runner


class TestRunnerPayloads(unittest.TestCase):
    def test_parse_args_for_echo_command(self):
        with patch.object(sys, "argv", ["runner.py", "echo", "--data", "abc", "--pretty"]):
            args = runner._parse_args()
        self.assertEqual(args.command, "echo")
        self.assertEqual(args.data, "abc")
        self.assertTrue(args.pretty)

    def test_parse_args_for_check_server_command(self):
        with patch.object(
            sys,
            "argv",
            [
                "runner.py",
                "check-server",
                "--ip",
                "198.51.100.8",
                "--username",
                "ubuntu",
                "--password",
                "secret",
                "--port",
                "2222",
            ],
        ):
            args = runner._parse_args()
        self.assertEqual(args.command, "check-server")
        self.assertEqual(args.host, "198.51.100.8")
        self.assertEqual(args.port, 2222)

    def test_parse_args_for_setup_server_command(self):
        with patch.object(
            sys,
            "argv",
            [
                "runner.py",
                "setup-server",
                "--ip",
                "198.51.100.8",
                "--username",
                "ubuntu",
                "--password",
                "secret",
                "--parts",
                "part1,part2",
                "--execute",
            ],
        ):
            args = runner._parse_args()
        self.assertEqual(args.command, "setup-server")
        self.assertEqual(args.parts, "part1,part2")
        self.assertTrue(args.execute)

    def test_parse_args_for_run_payload_command(self):
        with patch.object(
            sys,
            "argv",
            ["runner.py", "run-payload", "--payload", '{"action":"echo"}'],
        ):
            args = runner._parse_args()
        self.assertEqual(args.command, "run-payload")
        self.assertEqual(args.payload, '{"action":"echo"}')

    @staticmethod
    def _setup_args(**overrides):
        defaults = {
            "command": "setup-server",
            "host": "203.0.113.10",
            "port": 22,
            "username": "root",
            "password": "secret",
            "key_path": None,
            "parts": None,
            "hostname": None,
            "timezone": None,
            "ssh_public_key": None,
            "ssh_public_key_file": None,
            "disable_password_auth": False,
            "disable_root_login": False,
            "ssh_banner_text": None,
            "settings_json": None,
            "settings_file": None,
            "execute": False,
        }
        defaults.update(overrides)
        return Namespace(**defaults)

    def test_build_check_server_payload_from_args(self):
        args = Namespace(
            command="check-server",
            host="203.0.113.10",
            port=2222,
            username="root",
            password="secret",
            key_path=None,
        )

        payload = runner._build_payload(args, target={})
        self.assertEqual(payload["action"], "run_workflow")
        self.assertEqual(payload["workflow_id"], "server")
        self.assertEqual(payload["operation_id"], "check")
        self.assertEqual(payload["host"], "203.0.113.10")
        self.assertEqual(payload["port"], 2222)
        self.assertEqual(payload["username"], "root")
        self.assertEqual(payload["password"], "secret")
        self.assertIsNone(payload["key_path"])

    def test_build_check_server_payload_from_target_config(self):
        args = Namespace(
            command="check-server",
            host=None,
            port=None,
            username=None,
            password=None,
            key_path=None,
        )
        target = {
            "ip": "198.51.100.8",
            "port": 22,
            "username": "ubuntu",
            "password": "topsecret",
        }

        payload = runner._build_payload(args, target)
        self.assertEqual(payload["host"], "198.51.100.8")
        self.assertEqual(payload["port"], 22)
        self.assertEqual(payload["username"], "ubuntu")
        self.assertEqual(payload["password"], "topsecret")

    def test_build_check_server_requires_ip_and_username(self):
        args = Namespace(
            command="check-server",
            host=None,
            port=None,
            username=None,
            password=None,
            key_path=None,
        )

        with self.assertRaises(ValueError):
            runner._build_payload(args, target={})

    def test_build_payload_from_json_file(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            payload_path = Path(tmp_dir) / "payload.json"
            payload_path.write_text(json.dumps({"action": "echo", "data": "hi"}))

            args = Namespace(
                command="run-payload",
                payload=None,
                payload_file=payload_path,
            )
            payload = runner._build_payload(args, target={})
            self.assertEqual(payload["action"], "echo")
            self.assertEqual(payload["data"], "hi")

    def test_build_setup_server_payload_defaults_to_dry_run(self):
        args = self._setup_args()

        payload = runner._build_payload(args, target={})
        self.assertEqual(payload["action"], "run_workflow")
        self.assertEqual(payload["workflow_id"], "setup")
        self.assertEqual(payload["operation_id"], "run")
        self.assertTrue(payload["dry_run"])
        self.assertEqual(payload["host"], "203.0.113.10")
        self.assertEqual(payload["username"], "root")
        self.assertNotIn("parts", payload)
        self.assertEqual(payload["settings"]["timezone"], "UTC")
        self.assertIsNone(payload["settings"]["ssh_public_key"])

    def test_build_setup_server_payload_execute_with_parts_and_settings(self):
        args = self._setup_args(
            host=None,
            port=None,
            username=None,
            password=None,
            parts="part1,part3",
            disable_password_auth=True,
            execute=True,
        )
        target = {
            "ip": "198.51.100.8",
            "port": 22,
            "username": "ubuntu",
            "password": "pw",
            "parts": ["part2"],
            "settings": {"timezone": "UTC"},
        }

        payload = runner._build_payload(args, target=target)
        self.assertFalse(payload["dry_run"])
        self.assertEqual(payload["parts"], ["part1", "part3"])
        self.assertEqual(payload["settings"]["timezone"], "UTC")
        self.assertTrue(payload["settings"]["disable_password_auth"])

    def test_build_setup_server_payload_rejects_invalid_part(self):
        args = self._setup_args(parts="part1,unknown")

        with self.assertRaises(ValueError):
            runner._build_payload(args, target={})

    def test_build_setup_server_payload_loads_ssh_key_file(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            key_path = Path(tmp_dir) / "id_ed25519.pub"
            key_path.write_text("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...")
            args = self._setup_args(
                ssh_public_key_file=key_path,
                disable_root_login=True,
            )

            payload = runner._build_payload(args, target={})
            self.assertIn("ssh_public_key", payload["settings"])
            self.assertTrue(payload["settings"]["disable_root_login"])

    def test_parse_parts_returns_none_for_empty(self):
        self.assertIsNone(runner._parse_parts(None))
        self.assertIsNone(runner._parse_parts(""))

    def test_parse_json_object_requires_object(self):
        with self.assertRaises(ValueError):
            runner._parse_json_object("[]", "settings-json")

    def test_load_config_missing_file_raises(self):
        with self.assertRaises(ValueError):
            runner._load_config(Path("/definitely/missing/config.json"))

    def test_load_config_invalid_json_raises(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            config_path = Path(tmp_dir) / "config.json"
            config_path.write_text("{invalid")
            with self.assertRaises(ValueError):
                runner._load_config(config_path)

    def test_resolve_target_uses_default_target(self):
        config = {
            "default_target": "prod",
            "targets": {
                "prod": {
                    "ip": "203.0.113.15",
                    "username": "ubuntu",
                },
            },
        }
        resolved = runner._resolve_target(config, None)
        self.assertEqual(resolved["ip"], "203.0.113.15")

    def test_resolve_target_invalid_type_raises(self):
        with self.assertRaises(ValueError):
            runner._resolve_target(
                {"targets": {"prod": "not-an-object"}},
                "prod",
            )

    def test_resolve_target_missing_named_target_raises(self):
        with self.assertRaises(ValueError):
            runner._resolve_target({"targets": {"dev": {}}}, "prod")

    def test_resolve_target_returns_empty_when_targets_not_object(self):
        self.assertEqual(runner._resolve_target({"targets": []}, None), {})

    def test_load_json_object_missing_raises(self):
        with self.assertRaises(ValueError):
            runner._load_json_object(Path("/tmp/missing-settings.json"), "settings-file")

    def test_build_setup_settings_merges_file_and_json(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            settings_path = Path(tmp_dir) / "settings.json"
            settings_path.write_text(json.dumps({"timezone": "Asia/Kolkata"}))
            args = self._setup_args(
                settings_file=settings_path,
                settings_json=json.dumps({"hostname": "srv.example.com"}),
            )
            settings = runner._build_setup_settings(
                args,
                {"settings": {"disable_root_login": False}},
            )
            self.assertEqual(settings["timezone"], "Asia/Kolkata")
            self.assertEqual(settings["hostname"], "srv.example.com")
            self.assertFalse(settings["disable_root_login"])

    def test_build_setup_settings_overrides_all_supported_flags(self):
        args = self._setup_args(
            hostname="node-01",
            timezone="UTC",
            ssh_public_key="ssh-ed25519 AAAATEST",
            disable_password_auth=True,
            disable_root_login=True,
            ssh_banner_text="Authorized use only",
        )
        settings = runner._build_setup_settings(args, target={})
        self.assertEqual(settings["hostname"], "node-01")
        self.assertEqual(settings["timezone"], "UTC")
        self.assertEqual(settings["ssh_public_key"], "ssh-ed25519 AAAATEST")
        self.assertTrue(settings["disable_password_auth"])
        self.assertTrue(settings["disable_root_login"])
        self.assertEqual(settings["ssh_banner_text"], "Authorized use only")

    def test_build_setup_settings_missing_ssh_key_file_raises(self):
        args = self._setup_args(ssh_public_key_file=Path("/tmp/does-not-exist-key.pub"))
        with self.assertRaises(ValueError):
            runner._build_setup_settings(args, target={})

    def test_build_payload_run_payload_string(self):
        args = Namespace(
            command="run-payload",
            payload='{"action":"echo","data":"abc"}',
            payload_file=None,
        )
        payload = runner._build_payload(args, target={})
        self.assertEqual(payload["action"], "echo")
        self.assertEqual(payload["data"], "abc")

    def test_build_payload_unknown_command_raises(self):
        args = Namespace(command="unknown")
        with self.assertRaises(ValueError):
            runner._build_payload(args, target={})


class TestRunnerDispatch(unittest.TestCase):
    """T-1.5.11: CLI payloads must reach registered engine operations."""

    def _assert_engine_accepts_addressing(self, payload):
        response = json.loads(runner.handle_request(json.dumps(payload)))
        self.assertNotIn(
            response.get("code"),
            {"ENGINE_UNKNOWN_ACTION", "ENGINE_VALIDATION_ERROR"},
            response,
        )

    def test_echo_payload_dispatches(self):
        payload = runner._build_payload(
            Namespace(command="echo", data="hello"),
            target={},
        )

        self._assert_engine_accepts_addressing(payload)

    def test_check_server_payload_dispatches(self):
        payload = runner._build_payload(
            Namespace(
                command="check-server",
                host="127.0.0.1",
                port=22,
                username="deploydash",
                password="invalid",
                key_path=None,
            ),
            target={},
        )

        self._assert_engine_accepts_addressing(payload)

    def test_setup_server_payload_dispatches(self):
        args = TestRunnerPayloads._setup_args(
            ssh_public_key="ssh-ed25519 AAAATEST",
        )
        payload = runner._build_payload(args, target={})
        # The CLI has no managed-connection flag (recorded as T-1.5.9
        # discovered work), so provide the backend's separate onboarding
        # prerequisite here. The assertion is about the builder's addressing,
        # not a live SSH setup.
        payload["params"] = {
            "managed_connection": {
                "username": "ubuntu",
                "private_key": "test-private-key",
                "port": 22,
            },
        }

        self._assert_engine_accepts_addressing(payload)

    def test_run_payload_dispatches(self):
        payload = runner._build_payload(
            Namespace(
                command="run-payload",
                payload=(
                    '{"action":"run_workflow","workflow_id":"core",'
                    '"operation_id":"echo","data":"hello"}'
                ),
                payload_file=None,
            ),
            target={},
        )

        self._assert_engine_accepts_addressing(payload)


class TestRunnerMain(unittest.TestCase):
    @patch("runner._print_json")
    @patch("runner.handle_request")
    @patch("runner._parse_args")
    def test_main_success_exit_code(self, mock_parse_args, mock_handle_request, mock_print_json):
        mock_parse_args.return_value = Namespace(
            command="echo",
            data="hello",
            config=None,
            target=None,
            pretty=False,
        )
        mock_handle_request.return_value = json.dumps({"status": "success"})

        exit_code = runner.main()
        self.assertEqual(exit_code, 0)
        mock_print_json.assert_called_once()

    @patch("runner._print_json")
    @patch("runner._parse_args")
    def test_main_handles_value_error(self, mock_parse_args, mock_print_json):
        mock_parse_args.return_value = Namespace(
            command="check-server",
            host=None,
            port=None,
            username=None,
            password=None,
            key_path=None,
            config=None,
            target=None,
            pretty=False,
        )
        exit_code = runner.main()
        self.assertEqual(exit_code, 2)
        rendered = mock_print_json.call_args.args[0]
        self.assertEqual(rendered["status"], "error")

    @patch("runner._print_json")
    @patch("runner.handle_request", side_effect=json.JSONDecodeError("bad", "", 0))
    @patch("runner._parse_args")
    def test_main_handles_json_decode_error(
        self,
        mock_parse_args,
        _mock_handle_request,
        mock_print_json,
    ):
        mock_parse_args.return_value = Namespace(
            command="echo",
            data="hello",
            config=None,
            target=None,
            pretty=False,
        )
        exit_code = runner.main()
        self.assertEqual(exit_code, 2)
        rendered = mock_print_json.call_args.args[0]
        self.assertIn("Invalid JSON", rendered["msg"])

    @patch("runner._print_json")
    @patch("runner.handle_request", side_effect=RuntimeError("boom"))
    @patch("runner._parse_args")
    def test_main_handles_unexpected_exception(
        self,
        mock_parse_args,
        _mock_handle_request,
        mock_print_json,
    ):
        mock_parse_args.return_value = Namespace(
            command="echo",
            data="hello",
            config=None,
            target=None,
            pretty=False,
        )
        exit_code = runner.main()
        self.assertEqual(exit_code, 3)
        rendered = mock_print_json.call_args.args[0]
        self.assertEqual(rendered["msg"], "boom")


if __name__ == "__main__":
    unittest.main()
