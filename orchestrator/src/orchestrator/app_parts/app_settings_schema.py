"""Canonical app settings, and the values the backend resolves itself.

Split out of `app_config.py` by T-3.3.4 along the boundary §1.4 introduced:
**resolved (class A/B) on this side, caller intent (class C) on the other.**
The parser had grown past the point where that split was visible in the file's
shape, which is the whole reason it is worth seeing.

What lives here: the two defaults dicts and the canonical merge of them, the
patterns and closed value sets every validator matches against, the module's
error class, and the validators for values the **backend** resolves -- a
container name, a Docker network -- rather than ones a caller sends.

`app_config.py` re-exports what callers import, so the public path is
unchanged.
"""

import functools
import re
from dataclasses import dataclass
from typing import Any

from .. import config_validation, server_identifiers, server_paths

# Class A (docs/contracts/settings-ownership.md): resolved by the backend.
# `caddy_container_name` has no `server_identifiers.py` to resolve from yet,
# and `railpack_build_helper`/`caddy_apply_helper` are binary paths outside
# the managed `/opt/deploydash` tree `server_paths.py` owns -- see the note
# on RESOLVED_HTTP_DEFAULTS in http_config.py; same deferral to T-3.4.1.
RESOLVED_APP_DEFAULTS = {
    "apps_root": server_paths.apps_root(),
    "railpack_build_helper": server_paths.railpack_build_helper(),
    "railpack_env_file": server_paths.railpack_env_file(),
    "caddy_stack_root": server_paths.http_root(),
    "caddy_container_name": server_identifiers.caddy_container(),
    "caddy_apply_helper": server_paths.caddy_apply_helper(),
}

# Class C: the wire's actual contract.
APP_INTENT_DEFAULTS = {
    "project_slug": "sample-app",
    "repository_full_name": "example-org/example-repo",
    "branch": "main",
    "primary_domain": "app.example.com",
    "domain_routing_mode": "single_host",
    "app_port": 3000,
    "public_health_check_enabled": True,
    "public_health_check_path": "/",
    "repo_host": "github.com",
    "railpack_build_cmd": "",
    "railpack_start_cmd": "",
    "railpack_provider": None,
    "app_subdirectory": "",
    "worker_start_cmd": None,
    "workers": None,
    "railpack_node_mode": "auto",
    "deploy_private_key": None,
    "repository_host_key_policy": "strict",
    "accepted_repository_host_key_fingerprint": None,
    "runtime_env": None,
    "sqlite_storage": None,
    "sqlite_snapshot_mounts": None,
    "trust_network_names": None,
    "tls_challenge_mode": "http",
    "tls_dns_provider": None,
    "tls_dns_credentials": None,
}

# T-1.4.3 splits the dictionary; T-1.4.4 is what actually stops
# RESOLVED_APP_DEFAULTS keys from being wire-accepted. Until then this stays
# the full merge, byte-for-byte the same dictionary parse_app_config saw
# before this split.
CANONICAL_APP_SETTINGS = {**RESOLVED_APP_DEFAULTS, **APP_INTENT_DEFAULTS}

_ALLOWED_SETTING_KEYS = set(CANONICAL_APP_SETTINGS.keys())

_FQDN_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$"
)
_REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
_BRANCH_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
_HOST_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$"
)
_WORKER_HOST_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9_-]{0,61}[a-z0-9])?\.)*"
    r"[a-z0-9](?:[a-z0-9_-]{0,61}[a-z0-9])$"
)
_ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_WORKER_ID_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
_TLS_PROVIDERS = (
    "cloudflare",
    "porkbun",
    "namecheap",
    "cloudns",
    "easydns",
)
_DOMAIN_ROUTING_MODES = (
    "single_host",
    "redirect_www_to_apex",
    "redirect_apex_to_www",
)
_RAILPACK_PROVIDERS = (
    "node",
    "python",
    "php",
    "ruby",
    "golang",
    "java",
    "rust",
    "dotnet",
    "deno",
    "elixir",
    "shell",
    "staticfile",
)
_REPOSITORY_HOST_KEY_POLICIES = (
    "strict",
    "accept_new",
    "replace_confirmed",
)
_SSH_SHA256_FINGERPRINT_RE = re.compile(r"^SHA256:[A-Za-z0-9+/=]+$")


class AppConfigValidationError(ValueError):
    pass


# Bound once per module rather than passed at all 21 call sites below.
#
# These are not copies -- T-3.8.1 deleted those. Each is `config_validation`'s
# single implementation with this module's error class already supplied, which
# is the same "parameterise the original, bind the exception class" shape
# `settings_ownership.reject_server_owned_keys(raw, error_class)` established.
_required_string = functools.partial(
    config_validation.required_string,
    error_class=AppConfigValidationError,
)
_required_bool = functools.partial(
    config_validation.required_bool,
    error_class=AppConfigValidationError,
)


def _required_host(value: Any, field_name: str) -> str:
    host = _required_string(value, field_name).lower().rstrip(".")
    if not _HOST_RE.match(host):
        raise AppConfigValidationError(f"{field_name} must be a valid hostname.")
    return host


def _required_container_name(value: Any, field_name: str) -> str:
    name = _required_string(value, field_name)
    if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", name):
        raise AppConfigValidationError(
            f"{field_name} must be a valid Docker container name.",
        )
    return name


def _optional_network_name(value: Any, field_name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise AppConfigValidationError(f"{field_name} must be a string or null.")
    name = value.strip()
    if not name:
        return None
    if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", name):
        raise AppConfigValidationError(
            f"{field_name} must be a valid Docker network name.",
        )
    return name


def _optional_network_names(value: Any, field_name: str) -> tuple[str, ...]:
    if value is None:
        return tuple()
    if not isinstance(value, list):
        raise AppConfigValidationError(f"{field_name} must be an array or null.")

    names = []
    seen = set()
    for index, item in enumerate(value):
        name = _optional_network_name(item, f"{field_name}[{index}]")
        if name is None:
            raise AppConfigValidationError(
                f"{field_name}[{index}] must be a non-empty Docker network name.",
            )
        if name in seen:
            continue
        seen.add(name)
        names.append(name)
    return tuple(names)


# The value types validated settings become.
#
# Here rather than in `app_config.py` because the field validators build
# them and `app_config.py` imports those validators -- keeping them beside
# `parse_app_config` made a cycle. `AppConfig` itself stays there: nothing
# but the parser constructs it.
@dataclass(frozen=True)
class WorkerConfig:
    id: str
    name: str
    start_command: str
    cpu_limit: float
    memory_mb: int
    disk_mb: int
    enabled: bool
    database_user: str | None
    database_name: str | None
    database_password: str | None
    database_engine: str | None
    database_host: str | None
    database_port: int | None


@dataclass(frozen=True)
class SqliteStorageConfig:
    volume_name: str
    mount_path: str
    file_name: str

    @property
    def database_path(self) -> str:
        return f"{self.mount_path}/{self.file_name}"

    @property
    def database_url(self) -> str:
        return f"sqlite:///{self.database_path}"


@dataclass(frozen=True)
class SqliteSnapshotMountConfig:
    volume_name: str
    mount_path: str
    file_name: str
    path_env_key: str | None
    database_url_env_key: str | None

    @property
    def database_path(self) -> str:
        return f"{self.mount_path}/{self.file_name}"

    @property
    def database_url(self) -> str:
        return f"sqlite:///{self.database_path}"
