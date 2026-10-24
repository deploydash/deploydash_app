import unittest

from pyinfra.operations import apt

from orchestrator import server_paths
from orchestrator.setup_parts.part3_docker_prep import build_steps
from orchestrator.setup_parts.setup_config import parse_setup_config


class _FakeOperationResult:
    did_change = True


class _FakeRuntime:
    def __init__(self):
        self.calls = []

    def ensure_apt_updated(self, *args, **kwargs):
        self.calls.append(("ensure_apt_updated", args, kwargs))
        return object()

    def add_operation(self, operation_func, **kwargs):
        self.calls.append(("add_operation", operation_func, kwargs))
        return _FakeOperationResult()

    def ensure_service_enabled(self, service_name):
        self.calls.append(("ensure_service_enabled", service_name))
        return object()


class TestSetupPart3DockerPrep(unittest.TestCase):
    def test_part3_step_metadata_is_exposed(self):
        config = parse_setup_config({})
        steps = build_steps(config)

        self.assertEqual([step.part for step in steps], ["part3", "part3", "part3"])
        self.assertEqual(
            [step.id for step in steps],
            [
                "part3_step11_docker_install",
                "part3_step12_docker_log_rotation",
                "part3_step13_docker_directories",
            ],
        )

    def test_step11_forces_apt_refresh_after_docker_repo_added(self):
        config = parse_setup_config({})
        step = build_steps(config)[0]
        runtime = _FakeRuntime()

        step.register(runtime)

        add_ops = [entry for entry in runtime.calls if entry[0] == "add_operation"]
        key_ops = [kwargs for _, op_func, kwargs in add_ops if op_func == apt.key]
        self.assertEqual(
            key_ops,
            [
                {
                    "src": "https://download.docker.com/linux/ubuntu/gpg",
                    "dest": "docker.gpg",
                }
            ],
        )
        shell_commands = [
            command
            for _, op_func, kwargs in add_ops
            if op_func.__name__ == "shell"
            for command in kwargs.get("commands", [])
        ]
        self.assertFalse(
            any("gpg --batch --yes --dearmor" in command for command in shell_commands)
        )

        def _find_index(predicate):
            for idx, (_, op_func, kwargs) in enumerate(add_ops):
                if predicate(op_func, kwargs):
                    return idx
            return None

        repo_idx = _find_index(
            lambda op, kwargs: (
                op.__name__ == "shell"
                and any(
                    "/etc/apt/sources.list.d/docker.list" in command
                    for command in kwargs.get("commands", [])
                )
            )
        )
        refresh_idx = _find_index(
            lambda op, kwargs: op == apt.update and kwargs.get("cache_time") == 0
        )
        install_idx = _find_index(
            lambda op, kwargs: (
                op.__name__ == "shell"
                and any(
                    "apt-get -o DPkg::Lock::Timeout=300 install" in command
                    and "docker-ce=" in command
                    for command in kwargs.get("commands", [])
                )
            )
        )

        self.assertIsNotNone(repo_idx)
        self.assertIsNotNone(refresh_idx)
        self.assertIsNotNone(install_idx)
        self.assertLess(repo_idx, refresh_idx)
        self.assertLess(refresh_idx, install_idx)

    def test_step11_installs_pinned_docker_packages(self):
        config = parse_setup_config({})
        step = build_steps(config)[0]
        runtime = _FakeRuntime()

        step.register(runtime)

        commands = [
            command
            for call in runtime.calls
            if call[0] == "add_operation"
            for command in call[2].get("commands", [])
        ]
        install_commands = [
            command
            for command in commands
            if "apt-get -o DPkg::Lock::Timeout=300 install" in command and "docker-ce=" in command
        ]

        self.assertEqual(len(install_commands), 1)
        install_command = install_commands[0]
        self.assertIn("jammy) DOCKER_UBUNTU_VERSION=22.04", install_command)
        self.assertIn("noble) DOCKER_UBUNTU_VERSION=24.04", install_command)
        self.assertIn(
            '"docker-ce=5:29.6.0-1~ubuntu.${DOCKER_UBUNTU_VERSION}~${DOCKER_UBUNTU_CODENAME}"',
            install_command,
        )
        self.assertIn(
            '"docker-ce-cli=5:29.6.0-1~ubuntu.${DOCKER_UBUNTU_VERSION}~${DOCKER_UBUNTU_CODENAME}"',
            install_command,
        )
        self.assertIn(
            '"containerd.io=2.2.5-1~ubuntu.${DOCKER_UBUNTU_VERSION}~${DOCKER_UBUNTU_CODENAME}"',
            install_command,
        )
        self.assertIn(
            '"docker-compose-plugin=5.1.4-1~ubuntu.${DOCKER_UBUNTU_VERSION}~'
            '${DOCKER_UBUNTU_CODENAME}"',
            install_command,
        )
        self.assertIn(
            "apt-mark hold docker-ce docker-ce-cli containerd.io docker-compose-plugin",
            install_command,
        )

    def test_step12_writes_daemon_log_rotation_and_restarts_docker(self):
        config = parse_setup_config({})
        step = build_steps(config)[1]
        runtime = _FakeRuntime()

        step.register(runtime)

        add_ops = [entry for entry in runtime.calls if entry[0] == "add_operation"]
        docker_dir = [
            kwargs
            for _, op_func, kwargs in add_ops
            if op_func.__name__ == "directory" and kwargs.get("path") == "/etc/docker"
        ]
        daemon_files = [
            kwargs
            for _, op_func, kwargs in add_ops
            if op_func.__name__ == "put" and kwargs.get("dest") == "/etc/docker/daemon.json"
        ]
        service_restarts = [
            kwargs
            for _, op_func, kwargs in add_ops
            if op_func.__name__ == "service" and kwargs.get("service") == "docker"
        ]

        self.assertEqual(docker_dir, [{"path": "/etc/docker", "mode": "755"}])
        self.assertEqual(len(daemon_files), 1)
        daemon_body = daemon_files[0]["src"].getvalue()
        self.assertIn('"log-driver": "json-file"', daemon_body)
        self.assertIn('"max-size": "10m"', daemon_body)
        self.assertIn('"max-file": "3"', daemon_body)
        self.assertEqual(daemon_files[0]["mode"], "644")
        self.assertEqual(
            service_restarts,
            [{"service": "docker", "restarted": True, "_if": True}],
        )

    def test_step13_writes_the_layout_version_marker(self):
        # Without a version marker on disk no future layout migration can
        # determine what it is migrating from, so every future layout change
        # becomes guesswork.
        config = parse_setup_config({})
        step = build_steps(config)[2]
        runtime = _FakeRuntime()

        step.register(runtime)

        puts = [
            kwargs
            for call, op_func, kwargs in runtime.calls
            if call == "add_operation" and op_func.__name__ == "put"
        ]
        markers = [entry for entry in puts if entry["dest"] == "/opt/deploydash/LAYOUT_VERSION"]
        self.assertEqual(len(markers), 1)
        marker = markers[0]
        self.assertEqual(marker["src"].getvalue(), "2\n")
        self.assertEqual(marker["mode"], "644")

    def test_step13_writes_the_marker_before_creating_any_subdirectory(self):
        # Writing it first means a server that dies part-way through
        # provisioning is still identifiable as a Deploy Dash server at
        # layout 2, rather than looking like an unprovisioned machine with
        # stray directories on it.
        config = parse_setup_config({})
        step = build_steps(config)[2]
        runtime = _FakeRuntime()

        step.register(runtime)

        order = [
            (op_func.__name__, kwargs.get("path") or kwargs.get("dest"))
            for call, op_func, kwargs in runtime.calls
            if call == "add_operation"
        ]
        marker_index = order.index(("put", "/opt/deploydash/LAYOUT_VERSION"))
        root_index = order.index(("directory", "/opt/deploydash"))
        first_subdirectory = min(
            i
            for i, (name, path) in enumerate(order)
            if name == "directory" and path != "/opt/deploydash"
        )
        self.assertLess(root_index, marker_index)
        self.assertLess(marker_index, first_subdirectory)

    def test_step13_marker_content_matches_the_declared_layout_version(self):
        # Guards the marker against drifting from the constant the connect
        # path compares against; a mismatch would make every server report a
        # version the code does not believe in.
        config = parse_setup_config({})
        step = build_steps(config)[2]
        runtime = _FakeRuntime()

        step.register(runtime)

        marker = next(
            kwargs
            for call, op_func, kwargs in runtime.calls
            if call == "add_operation"
            and op_func.__name__ == "put"
            and kwargs["dest"] == server_paths.LAYOUT_VERSION_FILE
        )
        self.assertEqual(marker["src"].getvalue(), f"{server_paths.LAYOUT_VERSION}\n")

    def test_step13_creates_stack_directories_for_admin_user(self):
        config = parse_setup_config({})
        step = build_steps(config)[2]
        runtime = _FakeRuntime()

        step.register(runtime)

        directories = [
            kwargs
            for call, op_func, kwargs in runtime.calls
            if call == "add_operation" and op_func.__name__ == "directory"
        ]

        # The branded root comes first, and the state root is now created at
        # provisioning rather than lazily by whichever consumer happened to
        # write there first. T-1.1.5 writes LAYOUT_VERSION into the root, so
        # the root must exist before anything else does; a server that dies
        # part-way through provisioning is then still identifiable.
        self.assertEqual(
            [entry["path"] for entry in directories],
            [
                "/opt/deploydash",
                "/opt/deploydash/stack",
                "/opt/deploydash/state",
                "/opt/deploydash/stack/proxy",
                "/opt/deploydash/stack/mail",
                "/opt/deploydash/stack/dns",
                "/opt/deploydash/stack/db",
                "/opt/deploydash/stack/apps",
            ],
        )
        self.assertTrue(
            all(
                entry["user"] == "ubuntu" and entry["group"] == "ubuntu" and entry["mode"] == "755"
                for entry in directories
            )
        )


if __name__ == "__main__":
    unittest.main()
