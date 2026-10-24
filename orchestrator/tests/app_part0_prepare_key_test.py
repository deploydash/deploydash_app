import unittest

from orchestrator.app_parts.app_config import parse_app_config
from orchestrator.app_parts.part0_prepare_key import build_steps


class _RuntimeRecorder:
    def __init__(self):
        self.operations = []

    def add_operation(self, operation, **kwargs):
        name = getattr(operation, "__name__", str(operation))
        self.operations.append((name, kwargs))


class TestAppPart0PrepareKey(unittest.TestCase):
    def test_prepare_key_step_registers_expected_operations(self):
        config = parse_app_config({}, require_domain=False)
        steps = build_steps(config)
        self.assertEqual(len(steps), 1)

        runtime = _RuntimeRecorder()
        steps[0].register(runtime)

        self.assertEqual(
            [name for name, _ in runtime.operations],
            [
                "directory",
                "directory",
                "directory",
                "shell",
                "file",
                "file",
                "file",
                "shell",
            ],
        )
        directory_calls = [kwargs for name, kwargs in runtime.operations if name == "directory"]
        self.assertEqual(
            directory_calls,
            [
                {"path": config.project_root, "mode": "755"},
                {"path": config.key_dir, "mode": "700"},
                {"path": config.source_root},
            ],
        )
        file_calls = [kwargs for name, kwargs in runtime.operations if name == "file"]
        self.assertEqual(
            file_calls,
            [
                {"path": config.key_private_path, "present": True, "mode": "600"},
                {"path": config.key_public_path, "present": True, "mode": "644"},
                {"path": config.key_known_hosts_path, "present": True, "mode": "600"},
            ],
        )
        shell_calls = [kwargs["commands"] for name, kwargs in runtime.operations if name == "shell"]
        self.assertEqual(len(shell_calls), 2)
        self.assertIn("command -v ssh-keygen >/dev/null", shell_calls[0])
        self.assertIn("command -v ssh-keyscan >/dev/null", shell_calls[0])
        self.assertTrue(any("ssh-keygen -t ed25519 -N ''" in item for item in shell_calls[0]))
        self.assertTrue(any("ssh-keyscan -H" in item for item in shell_calls[1]))
        self.assertTrue(
            any("test -s" in item and "id_ed25519.pub" in item for item in shell_calls[1])
        )
        all_shell_commands = [command for commands in shell_calls for command in commands]
        self.assertFalse(any("mkdir -p" in command for command in all_shell_commands))
        self.assertFalse(any("chmod 700" in command for command in all_shell_commands))

    def test_prepare_key_step_metadata_is_expected(self):
        config = parse_app_config({}, require_domain=False)
        step = build_steps(config)[0]

        self.assertEqual(step.id, "app_prepare_step1_deploy_key")
        self.assertEqual(step.part, "part0")
        self.assertEqual(len(step.actions), 3)
        self.assertEqual(
            [action.id for action in step.actions],
            [
                "app_prepare_step1_action_create_directories",
                "app_prepare_step1_action_generate_deploy_key",
                "app_prepare_step1_action_seed_known_hosts",
            ],
        )


if __name__ == "__main__":
    unittest.main()
