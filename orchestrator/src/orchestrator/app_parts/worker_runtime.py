from __future__ import annotations

import base64
import shlex
from collections.abc import Iterable
from dataclasses import dataclass

from .. import server_identifiers
from ..container_status import worker_process_check_shell
from ..runtime_security import (
    ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING,
    docker_runtime_security_flags,
)
from .app_config import WorkerConfig


def render_runtime_env_stdin(runtime_env: dict[str, str]) -> str:
    lines = []
    for key in sorted(runtime_env.keys()):
        encoded_value = base64.b64encode(runtime_env[key].encode("utf-8")).decode("ascii")
        lines.append(f"{key}\t{encoded_value}")
    rendered = "\n".join(lines)
    return f"{rendered}\n" if rendered else ""


def build_runtime_env_docker_flags(
    runtime_env: dict[str, str],
    *,
    include_values: bool = False,
) -> str:
    flags = []
    for key in sorted(runtime_env.keys()):
        if include_values:
            assignment = f"{key}={runtime_env[key]}"
            flags.append(f"-e {shlex.quote(assignment)}")
        else:
            flags.append(f"-e {shlex.quote(key)}")
    return " ".join(flags)


@dataclass(frozen=True)
class WorkerRuntimeCommandSpec:
    worker: WorkerConfig
    container_name: str
    run_command: str
    verify_command: str
    stop_command: str
    logs_command: str


def _label_flag(key: str, value: str) -> str:
    """Return one `--label key=value` Docker argument."""
    return f"--label {server_identifiers.label_pair(key, value)}"


def _worker_env_flags(
    worker: WorkerConfig,
    runtime_env_docker_flags: str,
) -> str:
    worker_env_flags = []
    if runtime_env_docker_flags:
        worker_env_flags.append(runtime_env_docker_flags)
    if worker.database_user is not None:
        worker_env_flags.extend(
            [
                "-e DATABASE_ENGINE=postgres",
                f"-e DATABASE_HOST={shlex.quote(worker.database_host)}",
                f"-e DATABASE_PORT={shlex.quote(str(worker.database_port))}",
                f"-e DATABASE_NAME={shlex.quote(worker.database_name)}",
                f"-e DATABASE_USER={shlex.quote(worker.database_user)}",
                f"-e DATABASE_PASSWORD={shlex.quote(worker.database_password)}",
            ]
        )
    return " ".join(worker_env_flags)


def build_worker_runtime_command_spec(
    *,
    project_slug: str,
    image_name: str,
    worker: WorkerConfig,
    runtime_env_docker_flags: str,
    primary_network_env_var: str,
    readonly_volume_docker_flags: str = "",
    trust_network_names: Iterable[str] = (),
    log_tail_lines: int = 200,
    container_name_override: str | None = None,
    extra_labels: dict[str, str] | None = None,
) -> WorkerRuntimeCommandSpec:
    worker_container_name = (
        container_name_override
        if isinstance(container_name_override, str) and container_name_override.strip()
        else server_identifiers.worker_container(project_slug, worker.id)
    )
    quoted_worker_container_name = shlex.quote(worker_container_name)
    worker_cpu_limit = shlex.quote(f"{worker.cpu_limit:g}")
    worker_memory_limit = shlex.quote(f"{worker.memory_mb}m")
    worker_disk_limit = shlex.quote(f"{worker.disk_mb}m")
    worker_command = shlex.quote(worker.start_command)
    quoted_project_slug = shlex.quote(project_slug)
    quoted_image_name = shlex.quote(image_name)
    primary_network_ref = f"${{{primary_network_env_var}}}"
    worker_env_flags_rendered = _worker_env_flags(worker, runtime_env_docker_flags)
    quoted_trust_network_names = [
        shlex.quote(network.strip())
        for network in trust_network_names
        if isinstance(network, str) and network.strip()
    ]
    runtime_security_flags = docker_runtime_security_flags(
        profile=ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING
    )
    worker_labels = (
        " ".join(
            [
                f"--label {server_identifiers.MANAGED_LABEL_PAIR}",
                _label_flag(server_identifiers.LABEL_PROJECT, quoted_project_slug),
                _label_flag(server_identifiers.LABEL_ROLE, server_identifiers.ROLE_WORKER),
                _label_flag(server_identifiers.LABEL_WORKER_ID, shlex.quote(worker.id)),
                _label_flag(server_identifiers.LABEL_WORKER_CPU, worker_cpu_limit),
                _label_flag(
                    server_identifiers.LABEL_WORKER_MEMORY_MB,
                    shlex.quote(str(worker.memory_mb)),
                ),
                _label_flag(
                    server_identifiers.LABEL_WORKER_DISK_MB,
                    shlex.quote(str(worker.disk_mb)),
                ),
            ]
        )
        + " "
    )
    rendered_extra_labels = ""
    if extra_labels:
        rendered_extra_labels = " ".join(
            f"--label {shlex.quote(f'{key}={value}')}"
            for key, value in sorted(extra_labels.items())
            if isinstance(key, str) and key.strip() and isinstance(value, str) and value.strip()
        )
        if rendered_extra_labels:
            rendered_extra_labels += " "

    network_connect_commands = []
    if quoted_trust_network_names:
        network_list = " ".join(quoted_trust_network_names)
        network_connect_commands.append(
            f"for TRUST_NETWORK in {network_list}; do "
            f'if [ "${{TRUST_NETWORK}}" != "{primary_network_ref}" ]; then '
            'docker network inspect "${TRUST_NETWORK}" >/dev/null 2>&1 || '
            'docker network create "${TRUST_NETWORK}" >/dev/null 2>&1; '
            f'docker network connect "${{TRUST_NETWORK}}" {quoted_worker_container_name} '
            ">/dev/null 2>&1 || true; "
            "fi; "
            "done"
        )
    worker_network_connect_suffix = (
        "; " + "; ".join(network_connect_commands) if network_connect_commands else ""
    )

    run_with_storage = (
        "docker run -d "
        f"--name {quoted_worker_container_name} "
        "--restart unless-stopped "
        f'--network "{primary_network_ref}" '
        "--add-host host.docker.internal:host-gateway "
        f"{runtime_security_flags} "
        f"--cpus {worker_cpu_limit} "
        f"--memory {worker_memory_limit} "
        f"--storage-opt size={worker_disk_limit} "
        f"{readonly_volume_docker_flags} "
        f"{worker_env_flags_rendered} "
        f"{worker_labels}"
        f"{rendered_extra_labels}"
        f"--entrypoint /bin/sh "
        f"{quoted_image_name} -lc {worker_command}"
    )
    run_without_storage = (
        "docker run -d "
        f"--name {quoted_worker_container_name} "
        "--restart unless-stopped "
        f'--network "{primary_network_ref}" '
        "--add-host host.docker.internal:host-gateway "
        f"{runtime_security_flags} "
        f"--cpus {worker_cpu_limit} "
        f"--memory {worker_memory_limit} "
        f"{readonly_volume_docker_flags} "
        f"{worker_env_flags_rendered} "
        f"{worker_labels}"
        f"{rendered_extra_labels}"
        f"--entrypoint /bin/sh "
        f"{quoted_image_name} -lc {worker_command}"
    )
    run_command = (
        f"docker rm -f {quoted_worker_container_name} >/dev/null 2>&1 || true; "
        f"{run_with_storage} >/dev/null 2>&1 || "
        f"(docker rm -f {quoted_worker_container_name} >/dev/null 2>&1 || true; "
        f"{run_without_storage})"
        f"{worker_network_connect_suffix}"
    )
    verify_command = worker_process_check_shell(quoted_worker_container_name)
    stop_command = f"docker rm -f {quoted_worker_container_name} >/dev/null 2>&1 || true"
    logs_command = (
        "if docker inspect "
        f"{quoted_worker_container_name} >/dev/null 2>&1; then "
        f"docker logs --tail {log_tail_lines} "
        f"--timestamps {quoted_worker_container_name}; "
        "else "
        f"echo 'Worker container {worker_container_name} is not present on server.' >&2; "
        "exit 1; "
        "fi"
    )
    return WorkerRuntimeCommandSpec(
        worker=worker,
        container_name=worker_container_name,
        run_command=run_command,
        verify_command=verify_command,
        stop_command=stop_command,
        logs_command=logs_command,
    )


def build_worker_runtime_command_specs(
    *,
    project_slug: str,
    image_name: str,
    workers: Iterable[WorkerConfig],
    runtime_env_docker_flags: str,
    primary_network_env_var: str,
    readonly_volume_docker_flags: str = "",
    trust_network_names: Iterable[str] = (),
    log_tail_lines: int = 200,
    include_disabled: bool = False,
    release_id: str | None = None,
    live_label: str | None = None,
) -> list[WorkerRuntimeCommandSpec]:
    command_specs = []
    for worker in workers:
        if not include_disabled and not worker.enabled:
            continue
        container_name_override = None
        extra_labels = {}
        if isinstance(release_id, str) and release_id.strip():
            container_name_override = server_identifiers.release_worker_container(
                project_slug,
                worker.id,
                release_id,
            )
            extra_labels[server_identifiers.LABEL_RELEASE_ID] = release_id
        if isinstance(live_label, str) and live_label.strip():
            extra_labels[server_identifiers.LABEL_LIVE] = live_label
        command_specs.append(
            build_worker_runtime_command_spec(
                project_slug=project_slug,
                image_name=image_name,
                worker=worker,
                runtime_env_docker_flags=runtime_env_docker_flags,
                readonly_volume_docker_flags=readonly_volume_docker_flags,
                primary_network_env_var=primary_network_env_var,
                trust_network_names=trust_network_names,
                log_tail_lines=log_tail_lines,
                container_name_override=container_name_override,
                extra_labels=extra_labels,
            )
        )
    return command_specs
