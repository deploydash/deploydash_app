from io import StringIO

from pyinfra.operations import apt, files, server

from .. import apt_runtime, platform_versions, server_paths
from .common import SetupStep, StepAction
from .setup_config import SetupConfig

_DOCKER_PACKAGE_VERSION_PREFIXES = platform_versions.DOCKER_PACKAGE_VERSION_PREFIXES
_DOCKER_SUPPORTED_UBUNTU_RELEASES = {
    "jammy": "22.04",
    "noble": "24.04",
}


def _docker_pinned_install_command():
    package_specs = " ".join(
        f'"{name}={version}~ubuntu.${{DOCKER_UBUNTU_VERSION}}~${{DOCKER_UBUNTU_CODENAME}}"'
        for name, version in _DOCKER_PACKAGE_VERSION_PREFIXES.items()
    )
    package_names = " ".join(_DOCKER_PACKAGE_VERSION_PREFIXES)
    release_cases = " ".join(
        f"{codename}) DOCKER_UBUNTU_VERSION={version} ;;"
        for codename, version in _DOCKER_SUPPORTED_UBUNTU_RELEASES.items()
    )
    return (
        "set -eu; "
        ". /etc/os-release; "
        'DOCKER_UBUNTU_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"; '
        'case "${DOCKER_UBUNTU_CODENAME}" in '
        f"{release_cases} "
        "*) "
        "echo "
        '"Unsupported Ubuntu release for pinned Docker packages: '
        '${DOCKER_UBUNTU_CODENAME:-unknown}" >&2; '
        "exit 1 ;; "
        "esac; "
        f"apt-mark unhold {package_names} >/dev/null 2>&1 || true; "
        f"{apt_runtime.apt_get_command('install -y --allow-change-held-packages --allow-downgrades ' + package_specs)}; "
        f"apt-mark hold {package_names} >/dev/null"
    )


def build_steps(config: SetupConfig):
    admin_user = config.admin_user

    def register_step11(runtime):
        runtime.ensure_apt_updated()
        runtime.add_operation(
            apt.packages,
            update=False,
            packages=["ca-certificates", "curl", "gnupg", "lsb-release"],
        )
        runtime.add_operation(
            apt.key,
            src="https://download.docker.com/linux/ubuntu/gpg",
            dest="docker.gpg",
        )

        runtime.add_operation(
            server.shell,
            commands=[
                "bash -lc 'source /etc/os-release && echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable\" > /etc/apt/sources.list.d/docker.list'",
            ],
        )

        # Force refresh apt metadata after adding Docker repository.
        # `ensure_apt_updated` is run-once and may have already executed earlier
        # in setup, before docker.list existed.
        runtime.add_operation(
            apt.update,
            cache_time=0,
        )
        runtime.add_operation(
            server.shell,
            commands=[_docker_pinned_install_command()],
        )
        runtime.ensure_service_enabled("docker")

    def register_step12(runtime):
        runtime.add_operation(
            files.directory,
            path="/etc/docker",
            mode="755",
        )
        daemon_config = runtime.add_operation(
            files.put,
            src=StringIO(
                "{\n"
                '  "log-driver": "json-file",\n'
                '  "log-opts": {\n'
                '    "max-size": "10m",\n'
                '    "max-file": "3"\n'
                "  }\n"
                "}\n",
            ),
            dest="/etc/docker/daemon.json",
            mode="644",
        )
        runtime.add_operation(
            server.service,
            service="docker",
            restarted=True,
            _if=daemon_config.did_change,
        )

    def register_step13(runtime):
        directories = server_paths.stack_setup_directories()
        root, subdirectories = directories[0], directories[1:]

        runtime.add_operation(
            files.directory,
            path=root,
            user=admin_user,
            group=admin_user,
            mode="755",
        )
        # The layout marker is written immediately after the root exists and
        # before any subdirectory. A server that dies part-way through
        # provisioning is then still identifiable as layout 1, rather than
        # looking like an unprovisioned machine with stray directories on it.
        # It is root-owned and world-readable: every later connect reads it,
        # nothing but provisioning and a future migration may write it.
        runtime.add_operation(
            files.put,
            src=StringIO(f"{server_paths.LAYOUT_VERSION}\n"),
            dest=server_paths.LAYOUT_VERSION_FILE,
            user="root",
            group="root",
            mode="644",
        )
        for directory in subdirectories:
            runtime.add_operation(
                files.directory,
                path=directory,
                user=admin_user,
                group=admin_user,
                mode="755",
            )

    return [
        SetupStep(
            id="part3_step11_docker_install",
            title="Install Docker engine (official repository)",
            part="part3",
            commands=[
                "Install Docker apt prerequisites and keyring",
                "Configure official Docker apt repository",
                "Install pinned Docker engine, CLI, containerd, and Compose plugin packages",
                "Enable and start Docker service",
            ],
            actions=[
                StepAction(
                    id="part3_step11_action_install_prerequisites",
                    label="Install Docker prerequisites",
                    description="Install apt, TLS, and GPG prerequisites",
                ),
                StepAction(
                    id="part3_step11_action_configure_repository",
                    label="Configure Docker repository",
                    description="Trust and add official Docker repo",
                ),
                StepAction(
                    id="part3_step11_action_install_docker_packages",
                    label="Install Docker packages",
                    description="Install Docker engine and runtime components",
                ),
                StepAction(
                    id="part3_step11_action_enable_docker_service",
                    label="Enable Docker service",
                    description="Start Docker now and at boot",
                ),
            ],
            register=register_step11,
        ),
        SetupStep(
            id="part3_step12_docker_log_rotation",
            title="Configure Docker log rotation",
            part="part3",
            commands=[
                "Write /etc/docker/daemon.json with json-file rotation",
                "Restart Docker only when daemon config changes",
            ],
            actions=[
                StepAction(
                    id="part3_step12_action_write_daemon_config",
                    label="Write Docker daemon config",
                    description="Set Docker container log rotation policy",
                ),
                StepAction(
                    id="part3_step12_action_restart_docker",
                    label="Restart Docker daemon",
                    description="Apply daemon configuration changes safely",
                ),
            ],
            register=register_step12,
        ),
        SetupStep(
            id="part3_step13_docker_directories",
            title="Create standardized directory structure",
            part="part3",
            commands=[
                f"Write {server_paths.LAYOUT_VERSION_FILE}",
                "Create /opt/deploydash/stack/{proxy,mail,dns,db,apps}",
                f"Set ownership to {admin_user}:{admin_user}",
            ],
            actions=[
                StepAction(
                    id="part3_step13_action_create_stack_directories",
                    label="Create stack directories",
                    description="Create standardized Docker stack directories",
                ),
                StepAction(
                    id="part3_step13_action_set_directory_ownership",
                    label="Set stack ownership",
                    description="Assign directory ownership to admin user",
                ),
            ],
            register=register_step13,
        ),
    ]
