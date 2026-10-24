import shlex

from pyinfra.operations import files, server

from .app_config import AppConfig
from .common import AppAction, AppStep


def build_steps(config: AppConfig):
    quoted_private_key = shlex.quote(config.key_private_path)
    quoted_public_key = shlex.quote(config.key_public_path)
    quoted_known_hosts = shlex.quote(config.key_known_hosts_path)
    quoted_repo_host = shlex.quote(config.repo_host)
    quoted_comment = shlex.quote(f"deploydash-{config.project_slug}")

    def register_step(runtime):
        runtime.add_operation(
            files.directory,
            path=config.project_root,
            mode="755",
        )
        runtime.add_operation(
            files.directory,
            path=config.key_dir,
            mode="700",
        )
        runtime.add_operation(
            files.directory,
            path=config.source_root,
        )
        runtime.add_operation(
            server.shell,
            commands=[
                "command -v ssh-keygen >/dev/null",
                "command -v ssh-keyscan >/dev/null",
                "if [ ! -f "
                f"{quoted_private_key}"
                " ]; then "
                "ssh-keygen -t ed25519 -N '' "
                f"-C {quoted_comment} "
                f"-f {quoted_private_key}; "
                "fi",
            ],
        )
        runtime.add_operation(
            files.file,
            path=config.key_private_path,
            present=True,
            mode="600",
        )
        runtime.add_operation(
            files.file,
            path=config.key_public_path,
            present=True,
            mode="644",
        )
        runtime.add_operation(
            files.file,
            path=config.key_known_hosts_path,
            present=True,
            mode="600",
        )
        runtime.add_operation(
            server.shell,
            commands=[
                "if ! ssh-keygen -F "
                f"{quoted_repo_host} "
                f"-f {quoted_known_hosts} >/dev/null; then "
                "ssh-keyscan -H "
                f"{quoted_repo_host} >> {quoted_known_hosts}; "
                "fi",
                f"test -s {quoted_public_key}",
            ],
        )

    return [
        AppStep(
            id="app_prepare_step1_deploy_key",
            title="Prepare project deploy key on server",
            part="part0",
            commands=[
                "Create project build and key directories",
                "Generate project-scoped SSH deploy key when missing",
                "Seed known_hosts for GitHub SSH host key verification",
            ],
            actions=[
                AppAction(
                    id="app_prepare_step1_action_create_directories",
                    label="Create project/key directories",
                    description="Create persistent directories for source and deploy keys",
                    failure_phase="prepare",
                ),
                AppAction(
                    id="app_prepare_step1_action_generate_deploy_key",
                    label="Generate deploy key",
                    description="Create an ed25519 deploy key pair for repository access",
                    failure_phase="prepare",
                ),
                AppAction(
                    id="app_prepare_step1_action_seed_known_hosts",
                    label="Seed GitHub host key",
                    description="Enable strict host checking for git SSH operations",
                    failure_phase="prepare",
                ),
            ],
            register=register_step,
        ),
    ]
