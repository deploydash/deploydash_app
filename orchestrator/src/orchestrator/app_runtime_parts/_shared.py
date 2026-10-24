# ruff: noqa: F401
import re
import shlex
import time
from dataclasses import replace
from datetime import UTC, datetime
from types import SimpleNamespace

from .. import settings_ownership
from ..app_parts import (
    AppConfigValidationError,
    build_prepare_key_steps,
    parse_app_config,
)
from ..app_parts import (
    collect_steps as collect_app_steps,
)
from ..app_parts import (
    normalize_parts as normalize_app_parts,
)
from ..app_parts.app_config import RESOLVED_APP_DEFAULTS
from ..app_parts.part1_deploy import (
    _build_caddy_env_sync_command,
    _dns_tls_block_and_env,
    _render_caddy_snippet,
    render_selected_branch_fetch_command,
)
from ..app_parts.repository_host_key import (
    CONFIRMATION_CODE as REPOSITORY_HOST_KEY_CONFIRMATION_CODE,
)
from ..app_parts.repository_host_key import (
    parse_repository_host_key_confirmation_output,
    render_repository_host_key_preflight_command,
)
from ..app_parts.worker_runtime import (
    build_runtime_env_docker_flags,
    build_worker_runtime_command_specs,
    render_runtime_env_stdin,
)
from ..app_release_runtime import (
    append_or_replace_release,
    build_release_id,
    empty_release_manifest,
    find_release_entry,
    live_release_entry,
    load_manifest_from_text,
    mark_release_failed,
    normalize_commit_sha,
    previous_successful_release,
    prune_release_entries,
    release_entry_from_config,
    release_prune_candidates,
    render_manifest_write_command,
    render_manifest_write_payload,
    set_live_release,
    sort_releases_newest_first,
    utc_now_iso,
    worker_specs_to_configs,
)
from ..container_status import (
    caddy_service_readiness_check_shell,
    container_process_running_check_shell,
    container_status_from_payload,
    container_status_from_worker_row,
    container_status_kv_shell,
    normalize_container_status,
    worker_process_check_shell,
)
from ..engine_metrics_parsers import _parse_docker_stats_output
from ..http_parts import CANONICAL_HTTP_SETTINGS
from ..runtime_security import (
    ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING,
    docker_runtime_security_flags,
)
from ..workflow_executor import run_plan_dry, run_plan_execute

_APP_EXEC_EXIT_MARKER = "__DEPLOYDASH_APP_EXEC_EXIT_CODE__="
_APP_EXEC_DEFAULT_TIMEOUT_SECONDS = 600
_APP_EXEC_MAX_TIMEOUT_SECONDS = 3600
_APP_EXEC_MAX_COMMAND_LENGTH = 2000
_RELEASE_PROBE_PATHS = ("/up", "/health", "/")
_RELEASE_CANDIDATE_PROBE_ATTEMPTS = 6
_RELEASE_CANDIDATE_PROBE_DELAY_SECONDS = 5
_RELEASE_ROUTED_PROBE_ATTEMPTS = 3
_RELEASE_ROUTED_PROBE_DELAY_SECONDS = 2
_RELEASE_STABILIZATION_ATTEMPTS = 6
_RELEASE_STABILIZATION_DELAY_SECONDS = 5
_RELEASE_COMMIT_SHA_RE = re.compile(r"\b[a-f0-9]{7,40}\b", re.IGNORECASE)

# The release state machine's clock, and the only one it has.
#
# §2.2 gave every remote call a single injectable seam -- `run_shell_command`
# with an injected `host` -- which is what makes deterministic fault injection
# possible. Waiting had no equivalent: the machine called `time.sleep` on
# module constants at six sites, so a test could only neutralise it by
# patching the three constants to zero. That works, and it throws away the
# thing worth asserting: with the delays at zero a test cannot tell a deploy
# that waited out the full stabilization window from one that skipped it, and
# "did the candidate get its readiness window before traffic switched" is a
# question about a customer's site staying up.
#
# One function, so a test replaces one thing and can record what was asked
# for. `release_sleep` is the only place this module family waits; adding a
# second `time.sleep` re-opens what this closes.
release_sleep_override_for_tests = None


def release_sleep(seconds):
    """Wait [seconds], or hand the request to the test override."""

    override = release_sleep_override_for_tests
    if override is not None:
        override(seconds)
        return
    time.sleep(seconds)


_PUBLIC_HEALTH_MARKER = "DEPLOYDASH_PUBLIC_HEALTH|"

__all__ = tuple(name for name in globals() if not name.startswith("__"))
