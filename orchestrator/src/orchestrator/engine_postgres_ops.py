# mypy: disallow_untyped_defs = False
# mypy: disallow_untyped_calls = False
"""Compatibility exports for PostgreSQL engine operations.

Implementations live in ``postgres_runtime_parts`` grouped by responsibility;
callers continue to import this module while the engine contract remains stable.
"""

# ruff: noqa: F403
from . import postgres_backup as _postgres_backup
from .postgres_runtime_parts.agent_access import *
from .postgres_runtime_parts.backup_support import *
from .postgres_runtime_parts.local_import_support import *
from .postgres_runtime_parts.project_router import run_project_operation as _run_project_operation
from .postgres_runtime_parts.service_configuration import *
from .postgres_runtime_parts.service_runtime import run_postgres_runtime_operation  # noqa: F401
from .postgres_runtime_parts.service_storage import *
from .postgres_runtime_parts.service_upgrade import *

_backup_env_export_block = _postgres_backup.backup_env_export_block
_backup_remote_base_path = _postgres_backup.backup_remote_base_path
_normalize_backup_policy_token = _postgres_backup.normalize_backup_policy_token
_postgres_backup_destination_test_command = (
    _postgres_backup.postgres_backup_destination_test_command
)
_postgres_backup_policy_apply_command = _postgres_backup.postgres_backup_policy_apply_command
_postgres_backup_policy_delete_command = _postgres_backup.postgres_backup_policy_delete_command
_postgres_backup_restore_format_check_command = (
    _postgres_backup.postgres_backup_restore_format_check_command
)
_postgres_parse_backup_artifacts_output = _postgres_backup.postgres_parse_backup_artifacts_output
_postgres_parse_backup_run_output = _postgres_backup.postgres_parse_backup_run_output
_postgres_walg_install_command = _postgres_backup.postgres_walg_install_command
_resolve_backup_destination = _postgres_backup.resolve_backup_destination


def run_postgres_project_operation(
    ctx,
    operation_id,
    ip,
    username,
    password=None,
    key_filename=None,
    port=22,
    dry_run=False,
    raw_data=None,
    emit=None,
    is_cancelled=None,
):
    """Route a project operation through the PostgreSQL runtime parts."""
    return _run_project_operation(
        ctx,
        operation_id,
        ip,
        username,
        password=password,
        key_filename=key_filename,
        port=port,
        dry_run=dry_run,
        raw_data=raw_data,
        emit=emit,
        is_cancelled=is_cancelled,
    )
