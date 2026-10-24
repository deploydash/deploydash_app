"""Per-operation command plans for managed web-app runtime actions."""

import re

from .. import server_identifiers


def _disconnect(resources):
    image_prefix = server_identifiers.app_image_prefix(resources.app_config.project_slug)
    return [
        (
            "Remove release containers",
            "docker ps -a "
            f"--filter label={resources.quoted_worker_project_label} "
            "--format '{{.Names}}' | xargs -r docker rm -f >/dev/null 2>&1 || true; "
            f"docker rm -f {resources.quoted_container_name} >/dev/null 2>&1 || true",
            True,
        ),
        ("Remove managed worker containers", resources.worker_cleanup_command, True),
        (
            "Remove legacy worker container",
            f"docker rm -f {resources.quoted_worker_legacy_container_name} >/dev/null 2>&1 || true",
            True,
        ),
        (
            "Remove app image",
            "docker images --format '{{.Repository}}:{{.Tag}}' | "
            f"grep -E '^{re.escape(image_prefix)}' | "
            "xargs -r docker image rm >/dev/null 2>&1 || true",
            True,
        ),
        ("Remove app project files", f"rm -rf {resources.quoted_project_root}", True),
        (
            "Remove release manifest",
            f"rm -f {resources.quoted_release_manifest_path} >/dev/null 2>&1 || true",
            True,
        ),
        ("Remove Caddy route snippet", f"rm -f {resources.quoted_caddy_snippet_path}", True),
        (
            "Remove Caddy DNS credential environment variables",
            resources.cleanup_caddy_dns_env_command,
            True,
        ),
        ("Reload Caddy", resources.caddy_apply_command, True),
    ]


def _resource_usage(resources):
    return resources.resource_usage_steps


def _runtime_logs(resources):
    return [
        (
            "Collect app container runtime logs",
            "if docker inspect "
            f"{resources.quoted_container_name} >/dev/null 2>&1; then "
            f"docker logs --tail {resources.normalized_log_tail_lines} "
            f"--timestamps {resources.quoted_container_name}; "
            "else "
            "echo 'App container is not present on server.' >&2; "
            "exit 1; "
            "fi",
            False,
        ),
    ]


def _exec(resources):
    return [
        (
            "Run one-off app command",
            resources.app_exec_command,
            False,
        ),
    ]


def _sqlite_volume_ensure(resources):
    return [
        ("Ensure sqlite volume exists", resources.sqlite_volume_ensure_command, False),
        ("Collect sqlite storage metadata", resources.sqlite_meta_command, True),
    ]


def _sqlite_volume_status(resources):
    return [("Collect sqlite storage metadata", resources.sqlite_meta_command, True)]


def _sqlite_volume_delete(resources):
    return [
        ("Delete sqlite volume", resources.sqlite_volume_delete_command, False),
        ("Collect sqlite storage metadata", resources.sqlite_meta_command, True),
    ]


def _workers_apply(resources):
    return [
        ("Resolve worker network", resources.worker_network_command, False),
        ("Verify web app image exists", resources.worker_image_check_command, False),
        ("Remove stale worker containers", resources.worker_cleanup_command, True),
        *[
            (
                f"Start worker {entry.worker.id}",
                resources.with_worker_network_resolution(entry.run_command),
                False,
            )
            for entry in resources.worker_runtime_commands
        ],
        *[
            ("Verify worker process state", entry.verify_command, False)
            for entry in resources.worker_runtime_commands
        ],
        ("Collect worker runtime status", resources.worker_status_command, True),
    ]


def _workers_precheck(resources):
    return [("Inspect worker runtime prerequisites", resources.worker_precheck_command, True)]


def _workers_status(resources):
    return [("Collect worker runtime status", resources.worker_status_command, True)]


def _worker_start(resources):
    target = resources.target_worker_commands
    return [
        ("Resolve worker network", resources.worker_network_command, False),
        ("Verify web app image exists", resources.worker_image_check_command, False),
        (
            f"Start worker {resources.normalized_worker_id}",
            resources.with_worker_network_resolution(target.run_command) if target else "false",
            False,
        ),
        ("Verify worker process state", target.verify_command if target else "false", False),
        ("Collect worker runtime status", resources.worker_status_command, True),
    ]


def _worker_stop(resources):
    return [
        (
            f"Stop worker {resources.normalized_worker_id}",
            resources.target_worker_stop_command or "false",
            True,
        ),
        ("Collect worker runtime status", resources.worker_status_command, True),
    ]


def _worker_restart(resources):
    target = resources.target_worker_commands
    return [
        ("Resolve worker network", resources.worker_network_command, False),
        ("Verify web app image exists", resources.worker_image_check_command, False),
        (
            f"Restart worker {resources.normalized_worker_id}",
            resources.with_worker_network_resolution(target.run_command) if target else "false",
            False,
        ),
        ("Verify worker process state", target.verify_command if target else "false", False),
        ("Collect worker runtime status", resources.worker_status_command, True),
    ]


def _worker_logs(resources):
    target = resources.target_worker_commands
    return [
        (
            f"Collect worker logs for {resources.normalized_worker_id}",
            target.logs_command if target else "false",
            False,
        ),
    ]


_BUILDERS = {
    "disconnect": _disconnect,
    "resource_usage": _resource_usage,
    "runtime_logs": _runtime_logs,
    "exec": _exec,
    "sqlite_volume_ensure": _sqlite_volume_ensure,
    "sqlite_volume_status": _sqlite_volume_status,
    "sqlite_volume_delete": _sqlite_volume_delete,
    "workers_apply": _workers_apply,
    "workers_precheck": _workers_precheck,
    "workers_status": _workers_status,
    "worker_start": _worker_start,
    "worker_stop": _worker_stop,
    "worker_restart": _worker_restart,
    "worker_logs": _worker_logs,
}


def build_runtime_operation_steps(operation_id, resources):
    """Build the concrete command steps for one validated runtime operation."""
    builder = _BUILDERS.get(operation_id)
    return builder(resources) if builder is not None else None
