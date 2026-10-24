from io import StringIO

from pyinfra.operations import docker, files, server

from .. import server_paths
from ..railpack_contract import (
    RAILPACK_BUILDER_NAME,
    RAILPACK_FRONTEND_IMAGE,
    RAILPACK_FRONTEND_IMAGE_DIGEST,
    RAILPACK_STACK_ROOT,
    render_install_pinned_railpack_command,
)
from .common import SetupStep, StepAction
from .setup_config import SetupConfig


def _render_build_helper_script():
    return (
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n\n"
        'if [ "$#" -lt 2 ]; then\n'
        '  echo "Usage: deploydash-railpack-build <app_dir> <image_name> [plan_out] [info_out] [extra buildx args...]" >&2\n'
        "  exit 2\n"
        "fi\n\n"
        'APP_DIR="$1"\n'
        'IMAGE_NAME="$2"\n'
        'PLAN_OUT="${3:-${APP_DIR%/}/railpack-plan.json}"\n'
        'INFO_OUT="${4:-${APP_DIR%/}/railpack-info.json}"\n'
        'if [ "$#" -ge 4 ]; then\n'
        "  shift 4\n"
        'elif [ "$#" -eq 3 ]; then\n'
        "  shift 3\n"
        "else\n"
        "  shift 2\n"
        "fi\n"
        'EXTRA_BUILDX_ARGS=("$@")\n\n'
        f'RAILPACK_ENV_FILE="${{RAILPACK_ENV_FILE:-{server_paths.railpack_env_file()}}}"\n'
        'if [ -f "${RAILPACK_ENV_FILE}" ]; then\n'
        "  set -a\n"
        '  . "${RAILPACK_ENV_FILE}"\n'
        "  set +a\n"
        "fi\n\n"
        'EPHEMERAL_BUILDER="${RAILPACK_EPHEMERAL_BUILDER:-0}"\n'
        f'BUILDER_NAME="${{RAILPACK_BUILDER_NAME:-{RAILPACK_BUILDER_NAME}}}"\n'
        f'DEFAULT_FRONTEND_IMAGE="{RAILPACK_FRONTEND_IMAGE}"\n'
        f'DEFAULT_FRONTEND_DIGEST="{RAILPACK_FRONTEND_IMAGE_DIGEST}"\n'
        'FRONTEND_IMAGE="${RAILPACK_FRONTEND_IMAGE:-${DEFAULT_FRONTEND_IMAGE}}"\n'
        'FRONTEND_DIGEST="${RAILPACK_FRONTEND_IMAGE_DIGEST:-}"\n'
        'if [ "${FRONTEND_IMAGE}" = "${DEFAULT_FRONTEND_IMAGE}" ] && '
        '[ -z "${FRONTEND_DIGEST}" ]; then\n'
        '  FRONTEND_DIGEST="${DEFAULT_FRONTEND_DIGEST}"\n'
        "fi\n"
        'FRONTEND_SYNTAX="${FRONTEND_IMAGE}"\n'
        'if [ -n "${FRONTEND_DIGEST}" ]; then\n'
        '  FRONTEND_SYNTAX="${FRONTEND_IMAGE}@${FRONTEND_DIGEST}"\n'
        "fi\n"
        'CACHE_KEY="${RAILPACK_CACHE_KEY:-}"\n'
        'SECRETS_HASH="${RAILPACK_SECRETS_HASH:-}"\n'
        'RAILPACK_PROVIDER="${RAILPACK_PROVIDER:-}"\n'
        'MANAGED_CONFIG_FILE=""\n'
        'RAILPACK_START_CMD_VALUE="${RAILPACK_START_CMD:-${NIXPACKS_START_CMD:-}}"\n'
        'RAILPACK_BUILD_CMD_VALUE="${RAILPACK_BUILD_CMD:-${NIXPACKS_BUILD_CMD:-}}"\n'
        "PREPARE_ARGS=()\n"
        'if [ -n "${RAILPACK_BUILD_CMD_VALUE}" ]; then\n'
        '  PREPARE_ARGS+=(--build-cmd "${RAILPACK_BUILD_CMD_VALUE}")\n'
        "fi\n"
        'if [ -n "${RAILPACK_START_CMD_VALUE}" ]; then\n'
        '  PREPARE_ARGS+=(--start-cmd "${RAILPACK_START_CMD_VALUE}")\n'
        "fi\n\n"
        'command -v railpack >/dev/null 2>&1 || { echo "railpack not found in PATH" >&2; exit 1; }\n'
        'command -v docker >/dev/null 2>&1 || { echo "docker not found in PATH" >&2; exit 1; }\n\n'
        "cleanup() {\n"
        '  if [ -n "${MANAGED_CONFIG_FILE}" ] && [ -f "${MANAGED_CONFIG_FILE}" ]; then\n'
        '    rm -f "${MANAGED_CONFIG_FILE}" >/dev/null 2>&1 || true\n'
        "  fi\n"
        '  if [ "${EPHEMERAL_BUILDER}" = "1" ]; then\n'
        '    docker buildx rm -f "${BUILDER_NAME}" >/dev/null 2>&1 || true\n'
        "  fi\n"
        "}\n"
        "trap cleanup EXIT\n\n"
        'if [ "${EPHEMERAL_BUILDER}" = "1" ]; then\n'
        '  BUILDER_NAME="deploydash-railpack-$(date +%s)-$$"\n'
        '  docker buildx create --name "${BUILDER_NAME}" --driver docker-container --use >/dev/null\n'
        "else\n"
        '  docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1 || \\\n'
        '    docker buildx create --name "${BUILDER_NAME}" --driver docker-container >/dev/null\n'
        "fi\n"
        'docker buildx inspect --bootstrap "${BUILDER_NAME}" >/dev/null\n\n'
        'if [ -n "${RAILPACK_PROVIDER}" ]; then\n'
        '  command -v python3 >/dev/null 2>&1 || { echo "python3 not found in PATH" >&2; exit 1; }\n'
        '  MANAGED_CONFIG_FILE="${APP_DIR%/}/.deploydash-railpack.json"\n'
        '  RAILPACK_MANAGED_CONFIG="${MANAGED_CONFIG_FILE}" \\\n'
        '  RAILPACK_SOURCE_CONFIG="${APP_DIR%/}/railpack.json" \\\n'
        '  RAILPACK_PROVIDER_VALUE="${RAILPACK_PROVIDER}" \\\n'
        "  python3 - <<'PY'\n"
        "import json\n"
        "import os\n"
        "import pathlib\n"
        "import sys\n"
        "\n"
        'source_path = pathlib.Path(os.environ["RAILPACK_SOURCE_CONFIG"])\n'
        'managed_path = pathlib.Path(os.environ["RAILPACK_MANAGED_CONFIG"])\n'
        'provider = os.environ["RAILPACK_PROVIDER_VALUE"].strip()\n'
        "payload = {}\n"
        "if source_path.exists():\n"
        "    try:\n"
        "        payload = json.loads(source_path.read_text())\n"
        "    except Exception as exc:\n"
        '        print(f"Could not parse railpack.json: {exc}", file=sys.stderr)\n'
        "        raise SystemExit(1)\n"
        "    if not isinstance(payload, dict):\n"
        '        print("railpack.json must contain a JSON object.", file=sys.stderr)\n'
        "        raise SystemExit(1)\n"
        'payload["provider"] = provider\n'
        'managed_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\\n")\n'
        "PY\n"
        '  RAILPACK_CONFIG_FILE="${MANAGED_CONFIG_FILE}" railpack prepare "${APP_DIR}" --plan-out "${PLAN_OUT}" --info-out "${INFO_OUT}" "${PREPARE_ARGS[@]}"\n'
        "else\n"
        '  railpack prepare "${APP_DIR}" --plan-out "${PLAN_OUT}" --info-out "${INFO_OUT}" "${PREPARE_ARGS[@]}"\n'
        "fi\n\n"
        "build_cmd=(docker buildx build\n"
        '  --builder "${BUILDER_NAME}"\n'
        '  --build-arg "BUILDKIT_SYNTAX=${FRONTEND_SYNTAX}"\n'
        '  -f "${PLAN_OUT}"\n'
        '  --output "type=docker,name=${IMAGE_NAME}"\n'
        ")\n\n"
        'if [ -n "${CACHE_KEY}" ]; then\n'
        '  build_cmd+=(--build-arg "cache-key=${CACHE_KEY}")\n'
        "fi\n"
        'if [ -n "${SECRETS_HASH}" ]; then\n'
        '  build_cmd+=(--build-arg "secrets-hash=${SECRETS_HASH}")\n'
        "fi\n\n"
        'build_cmd+=("${EXTRA_BUILDX_ARGS[@]}")\n'
        'build_cmd+=("${APP_DIR}")\n\n'
        '"${build_cmd[@]}"\n'
    )


def _render_stack_readme():
    return (
        "# DeployDash Railpack build stack\n\n"
        "This stack configures production-oriented Railpack builds based on:\n"
        "- `railpack prepare` to generate `railpack-plan.json`\n"
        "- dedicated containerized BuildKit builder via Docker Buildx\n"
        f"- Railpack BuildKit frontend (`{RAILPACK_FRONTEND_IMAGE}`)\n\n"
        "Installed helper:\n\n"
        f"`{server_paths.railpack_build_helper()} <app_dir> <image_name>`\n\n"
        "Example:\n\n"
        f"`deploydash-railpack-build {server_paths.app_dir('my-nextjs')} my-nextjs:latest`\n"
    )


def _render_env_file():
    return (
        "RAILPACK_EPHEMERAL_BUILDER=0\n"
        f"# Used when RAILPACK_EPHEMERAL_BUILDER=0\nRAILPACK_BUILDER_NAME={RAILPACK_BUILDER_NAME}\n"
        f"RAILPACK_FRONTEND_IMAGE={RAILPACK_FRONTEND_IMAGE}\n"
        f"RAILPACK_FRONTEND_IMAGE_DIGEST={RAILPACK_FRONTEND_IMAGE_DIGEST}\n"
        "# Optional: isolate mount cache IDs per project/tenant\n"
        "# RAILPACK_CACHE_KEY=my-project\n"
        "# Optional: invalidate cache when secret values change\n"
        "# RAILPACK_SECRETS_HASH=<sha256-of-secret-values>\n"
    )


def build_steps(config: SetupConfig):
    admin_user = config.admin_user

    def register_step25(runtime):
        runtime.add_operation(
            server.shell,
            commands=[
                render_install_pinned_railpack_command(),
                "railpack --version",
            ],
        )

    def register_step26(runtime):
        runtime.ensure_service_enabled("docker")
        runtime.add_operation(
            server.shell,
            commands=[
                "docker --version",
                "docker buildx version",
            ],
        )
        runtime.add_operation(
            docker.image,
            image=f"{RAILPACK_FRONTEND_IMAGE}@{RAILPACK_FRONTEND_IMAGE_DIGEST}",
        )

    def register_step27(runtime):
        runtime.add_operation(
            files.directory,
            path=RAILPACK_STACK_ROOT,
            user=admin_user,
            group=admin_user,
            mode="755",
        )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_env_file()),
            dest=f"{RAILPACK_STACK_ROOT}/railpack.env",
            user=admin_user,
            group=admin_user,
            mode="644",
        )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_stack_readme()),
            dest=f"{RAILPACK_STACK_ROOT}/README.md",
            user=admin_user,
            group=admin_user,
            mode="644",
        )
        runtime.add_operation(
            files.put,
            src=StringIO(_render_build_helper_script()),
            dest=server_paths.railpack_build_helper(),
            mode="755",
        )

    return [
        SetupStep(
            id="part5_step25_install_railpack_cli",
            title="Install Railpack CLI",
            part="part5",
            commands=[
                "Install Railpack from official install script when missing",
                "Verify Railpack CLI availability",
            ],
            actions=[
                StepAction(
                    id="part5_step25_action_install_railpack",
                    label="Install Railpack CLI",
                    description="Install railpack binary for build plan generation",
                ),
                StepAction(
                    id="part5_step25_action_verify_railpack",
                    label="Verify Railpack",
                    description="Confirm Railpack CLI is available on PATH",
                ),
            ],
            register=register_step25,
        ),
        SetupStep(
            id="part5_step26_bootstrap_buildkit_builder",
            title="Bootstrap containerized BuildKit builder",
            part="part5",
            commands=[
                "Ensure Docker daemon is active",
                "Verify buildx plugin and pre-pull Railpack frontend image",
            ],
            notes=(
                "This follows Railpack production guidance: use prepare + frontend "
                "with BuildKit, not high-throughput CLI-only builds. The default "
                "helper mode uses a persistent buildx builder for cache reuse "
                "across deploys."
            ),
            actions=[
                StepAction(
                    id="part5_step26_action_enable_docker",
                    label="Enable Docker daemon",
                    description="Ensure Docker service is active for build infrastructure",
                ),
                StepAction(
                    id="part5_step26_action_verify_buildx",
                    label="Verify Buildx availability",
                    description="Confirm buildx plugin is available for Railpack builds",
                ),
                StepAction(
                    id="part5_step26_action_pull_frontend",
                    label="Pull Railpack frontend",
                    description="Cache frontend image used as BuildKit syntax",
                ),
            ],
            register=register_step26,
        ),
        SetupStep(
            id="part5_step27_install_railpack_helpers",
            title="Install Railpack build helpers",
            part="part5",
            commands=[
                f"Create {RAILPACK_STACK_ROOT} metadata directory",
                "Write railpack.env defaults and usage README",
                f"Install {server_paths.railpack_build_helper()} helper",
            ],
            actions=[
                StepAction(
                    id="part5_step27_action_write_railpack_env",
                    label="Write Railpack defaults",
                    description="Store builder/frontend defaults for automation",
                ),
                StepAction(
                    id="part5_step27_action_write_railpack_readme",
                    label="Write Railpack README",
                    description="Document operational build flow and helper usage",
                ),
                StepAction(
                    id="part5_step27_action_install_build_helper",
                    label="Install build helper",
                    description="Install helper script for prepare + frontend builds",
                ),
            ],
            register=register_step27,
        ),
    ]
