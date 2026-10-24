import unittest

from pyinfra.operations import docker

from orchestrator.railpack_contract import (
    RAILPACK_FRONTEND_IMAGE,
    RAILPACK_FRONTEND_IMAGE_DIGEST,
)
from orchestrator.setup_parts.part5_railpack_builds import (
    _render_build_helper_script,
    _render_env_file,
    _render_stack_readme,
    build_steps,
)
from orchestrator.setup_parts.setup_config import parse_setup_config
from orchestrator.setup_parts.setup_plan import ALL_PARTS


class TestSetupPart5Railpack(unittest.TestCase):
    def test_all_parts_includes_part5(self):
        self.assertIn("part5", ALL_PARTS)

    def test_part5_step_metadata_is_exposed(self):
        config = parse_setup_config({})
        steps = build_steps(config)

        self.assertEqual([step.part for step in steps], ["part5", "part5", "part5"])
        self.assertEqual(
            [step.id for step in steps],
            [
                "part5_step25_install_railpack_cli",
                "part5_step26_bootstrap_buildkit_builder",
                "part5_step27_install_railpack_helpers",
            ],
        )

    def test_helper_script_uses_prepare_and_frontend_buildx(self):
        script = _render_build_helper_script()

        self.assertIn("railpack prepare", script)
        self.assertIn(
            'RAILPACK_ENV_FILE="${RAILPACK_ENV_FILE:-/opt/deploydash/stack/railpack/railpack.env}"',
            script,
        )
        self.assertIn('EPHEMERAL_BUILDER="${RAILPACK_EPHEMERAL_BUILDER:-0}"', script)
        self.assertIn("docker buildx rm -f", script)
        self.assertIn("docker buildx inspect --bootstrap", script)
        self.assertIn(
            'DEFAULT_FRONTEND_IMAGE="ghcr.io/railwayapp/railpack-frontend:v0.29.0"',
            script,
        )
        self.assertIn('DEFAULT_FRONTEND_DIGEST="sha256:', script)
        self.assertIn('FRONTEND_DIGEST="${RAILPACK_FRONTEND_IMAGE_DIGEST:-}"', script)
        self.assertIn('FRONTEND_DIGEST="${DEFAULT_FRONTEND_DIGEST}"', script)
        self.assertIn(
            'FRONTEND_SYNTAX="${FRONTEND_IMAGE}@${FRONTEND_DIGEST}"',
            script,
        )
        self.assertIn("BUILDKIT_SYNTAX=${FRONTEND_SYNTAX}", script)
        self.assertIn('--output "type=docker,name=${IMAGE_NAME}"', script)

    def test_helper_script_forwards_start_and_build_command_overrides(self):
        # railpack v0.29.0's `prepare` subcommand only accepts overrides as
        # --start-cmd/--build-cmd flags; it does not read RAILPACK_START_CMD,
        # NIXPACKS_START_CMD, or the *_BUILD_CMD equivalents as environment
        # variables. part1_deploy.py sets those env vars for the deploy-time
        # invocation of this helper, so the helper itself must translate them
        # into CLI flags or every custom run/build command is silently
        # ignored in favor of Railpack's auto-detected default.
        script = _render_build_helper_script()

        self.assertIn(
            'RAILPACK_START_CMD_VALUE="${RAILPACK_START_CMD:-${NIXPACKS_START_CMD:-}}"',
            script,
        )
        self.assertIn(
            'RAILPACK_BUILD_CMD_VALUE="${RAILPACK_BUILD_CMD:-${NIXPACKS_BUILD_CMD:-}}"',
            script,
        )
        self.assertIn('PREPARE_ARGS+=(--start-cmd "${RAILPACK_START_CMD_VALUE}")', script)
        self.assertIn('PREPARE_ARGS+=(--build-cmd "${RAILPACK_BUILD_CMD_VALUE}")', script)

        prepare_lines = [line for line in script.splitlines() if "railpack prepare" in line]
        self.assertEqual(len(prepare_lines), 2)
        for line in prepare_lines:
            self.assertIn('"${PREPARE_ARGS[@]}"', line)

    def test_step25_installer_uses_pinned_release_asset(self):
        config = parse_setup_config({})
        step = build_steps(config)[0]

        class _FakeRuntime:
            def __init__(self):
                self.commands = []

            def add_operation(self, _operation, **kwargs):
                self.commands.extend(kwargs.get("commands", []))
                return object()

        runtime = _FakeRuntime()
        step.register(runtime)

        command_blob = "\n".join(runtime.commands)
        self.assertIn(
            "https://github.com/railwayapp/railpack/releases/download/v0.29.0",
            command_blob,
        )
        self.assertIn('DEPLOYDASH_RAILPACK_VERSION=""', command_blob)
        self.assertIn('[ "${DEPLOYDASH_RAILPACK_VERSION}" != "0.29.0" ]', command_blob)
        self.assertIn("sha256sum -c -", command_blob)
        self.assertIn("install -m 0755", command_blob)

    def test_helper_metadata_files_include_pinned_frontend(self):
        self.assertIn("ghcr.io/railwayapp/railpack-frontend:v0.29.0", _render_stack_readme())
        env_file = _render_env_file()
        self.assertIn(
            "RAILPACK_FRONTEND_IMAGE=ghcr.io/railwayapp/railpack-frontend:v0.29.0", env_file
        )
        self.assertIn("RAILPACK_FRONTEND_IMAGE_DIGEST=sha256:", env_file)

    def test_step26_and_step27_install_pinned_builder_assets(self):
        config = parse_setup_config({})
        step26 = build_steps(config)[1]
        step27 = build_steps(config)[2]

        class _FakeRuntime:
            def __init__(self):
                self.commands = []
                self.ensure_calls = []
                self.operations = []
                self.put_dests = []

            def ensure_service_enabled(self, service):
                self.ensure_calls.append(service)

            def add_operation(self, _operation, **kwargs):
                self.operations.append((_operation, kwargs))
                self.commands.extend(kwargs.get("commands", []))
                dest = kwargs.get("dest")
                if dest:
                    self.put_dests.append(dest)
                return object()

        runtime = _FakeRuntime()
        step26.register(runtime)
        step27.register(runtime)

        self.assertEqual(runtime.ensure_calls, ["docker"])
        command_blob = "\n".join(runtime.commands)
        self.assertIn("docker --version", command_blob)
        self.assertIn("docker buildx version", command_blob)
        self.assertNotIn(
            "docker pull ghcr.io/railwayapp/railpack-frontend:v0.29.0@sha256:",
            command_blob,
        )
        image_operations = [
            kwargs for operation, kwargs in runtime.operations if operation == docker.image
        ]
        self.assertEqual(
            image_operations,
            [{"image": (f"{RAILPACK_FRONTEND_IMAGE}@{RAILPACK_FRONTEND_IMAGE_DIGEST}")}],
        )
        self.assertIn("/opt/deploydash/stack/railpack/railpack.env", runtime.put_dests)
        self.assertIn("/opt/deploydash/stack/railpack/README.md", runtime.put_dests)
        self.assertIn("/usr/local/bin/deploydash-railpack-build", runtime.put_dests)


if __name__ == "__main__":
    unittest.main()
