"""Parsing the app deploy settings into the config the workflow runs on.

`parse_app_config` and the dataclasses it produces. T-3.3.4 moved the pieces
around it out: the canonical defaults and the values the backend resolves into
`app_settings_schema.py`, the forty class C field validators into
`app_config_fields.py`, and the per-provider TLS credential matrix into
`app_tls_credentials.py`. What stays is the shape callers receive and the one
function that builds it.

Everything callers import from this module still imports from this module.
"""

import hashlib
import re
from dataclasses import dataclass

from .. import config_validation, server_identifiers
from .app_config_fields import (
    _accept_superseded_railpack_keys,
    _optional_app_subdirectory,
    _optional_command,
    _optional_domain,
    _optional_private_key,
    _optional_railpack_provider,
    _optional_runtime_env,
    _optional_sqlite_snapshot_mounts,
    _optional_sqlite_storage,
    _optional_ssh_sha256_fingerprint,
    _optional_tls_dns_credentials,
    _optional_tls_dns_provider,
    _optional_worker_command,
    _optional_workers,
    _required_branch,
    _required_domain_routing_mode,
    _required_node_mode,
    _required_port,
    _required_project_slug,
    _required_public_health_path,
    _required_repo_full_name,
    _required_repository_host_key_policy,
    _required_tls_challenge_mode,
    _strip_leading_www,
)
from .app_settings_schema import (
    _ALLOWED_SETTING_KEYS,
    APP_INTENT_DEFAULTS,
    CANONICAL_APP_SETTINGS,
    RESOLVED_APP_DEFAULTS,
    AppConfigValidationError,
    SqliteSnapshotMountConfig,
    SqliteStorageConfig,
    WorkerConfig,
    _optional_network_names,
    _required_bool,
    _required_container_name,
    _required_host,
    _required_string,
)
from .app_tls_credentials import _validate_dns_credentials

__all__ = [
    "APP_INTENT_DEFAULTS",
    "CANONICAL_APP_SETTINGS",
    "RESOLVED_APP_DEFAULTS",
    "AppConfig",
    "AppConfigValidationError",
    "SqliteSnapshotMountConfig",
    "SqliteStorageConfig",
    "WorkerConfig",
    "parse_app_config",
]


@dataclass(frozen=True)
class AppConfig:
    apps_root: str
    project_slug: str
    repository_full_name: str
    branch: str
    primary_domain: str | None
    domain_routing_mode: str
    app_port: int
    public_health_check_enabled: bool
    public_health_check_path: str
    repo_host: str
    railpack_build_helper: str
    railpack_env_file: str
    railpack_build_command: str
    railpack_run_command: str
    railpack_provider: str | None
    app_subdirectory: str
    worker_run_command: str | None
    caddy_stack_root: str
    caddy_container_name: str
    caddy_apply_helper: str
    railpack_node_mode: str
    deploy_private_key: str | None
    repository_host_key_policy: str
    accepted_repository_host_key_fingerprint: str | None
    runtime_env: dict[str, str]
    sqlite_storage: SqliteStorageConfig | None
    sqlite_snapshot_mounts: tuple[SqliteSnapshotMountConfig, ...]
    trust_network_names: tuple[str, ...]
    tls_challenge_mode: str
    tls_dns_provider: str | None
    tls_dns_credentials: dict[str, str]
    workers: tuple[WorkerConfig, ...]

    @property
    def repository_ssh_url(self):
        return f"git@{self.repo_host}:{self.repository_full_name}.git"

    @property
    def project_root(self):
        return f"{self.apps_root}/{self.project_slug}"

    @property
    def source_root(self):
        return f"{self.project_root}/src"

    @property
    def source_app_root(self):
        if not self.app_subdirectory:
            return self.source_root
        return f"{self.source_root}/{self.app_subdirectory}"

    @property
    def deploy_data_root(self):
        return f"{self.apps_root}/.deploydash"

    @property
    def release_data_root(self):
        return f"{self.deploy_data_root}/apps/{self.project_slug}"

    @property
    def release_manifest_path(self):
        return f"{self.release_data_root}/releases.json"

    @property
    def key_dir(self):
        return f"{self.deploy_data_root}/keys/{self.project_slug}"

    @property
    def key_private_path(self):
        return f"{self.key_dir}/id_ed25519"

    @property
    def key_public_path(self):
        return f"{self.key_private_path}.pub"

    @property
    def key_known_hosts_path(self):
        return f"{self.key_dir}/known_hosts"

    @property
    def repository_known_hosts_path(self):
        return f"{self.deploy_data_root}/repository-known-hosts/{self.project_slug}/known_hosts"

    @property
    def railpack_plan_path(self):
        return f"{self.project_root}/railpack-plan.json"

    @property
    def railpack_info_path(self):
        return f"{self.project_root}/railpack-info.json"

    @property
    def image_name(self):
        return server_identifiers.app_image(self.project_slug)

    def release_image_name(self, release_id: str):
        return server_identifiers.release_app_image(self.project_slug, release_id)

    @property
    def container_name(self):
        return server_identifiers.app_container(self.project_slug)

    def release_container_name(self, release_id: str):
        return server_identifiers.release_app_container(self.project_slug, release_id)

    def release_upstream_name(self, release_id: str):
        slug = re.sub(r"[^a-z0-9-]+", "-", self.project_slug.lower()).strip("-")
        if not slug:
            slug = "app"
        digest = hashlib.sha1(f"{self.project_slug}:{release_id}".encode()).hexdigest()[:10]
        slug_budget = 63 - len("dd-app-") - len("-") - len(digest)
        short_slug = slug[: max(slug_budget, 1)].strip("-")
        if not short_slug:
            short_slug = "app"
        return f"dd-app-{short_slug}-{digest}"

    def release_worker_container_name(self, release_id: str, worker_id: str):
        return server_identifiers.release_worker_container(
            self.project_slug,
            worker_id,
            release_id,
        )

    @property
    def caddy_snippet_path(self):
        return f"{self.caddy_stack_root}/caddy/conf.d/20-{self.project_slug}.caddy"

    @property
    def caddy_env_file_path(self):
        return f"{self.caddy_stack_root}/caddy/.env"

    @property
    def tls_env_prefix(self):
        normalized = re.sub(r"[^A-Za-z0-9]+", "_", self.project_slug).upper()
        return f"DEPLOYDASH_{normalized}_"

    @property
    def app_http_url(self):
        if self.canonical_domain:
            return f"http://{self.canonical_domain}"
        return None

    @property
    def app_https_url(self):
        if self.canonical_domain:
            return f"https://{self.canonical_domain}"
        return None

    @property
    def apex_domain(self):
        if self.primary_domain is None:
            return None
        return _strip_leading_www(self.primary_domain)

    @property
    def www_domain(self):
        if self.apex_domain is None:
            return None
        return f"www.{self.apex_domain}"

    @property
    def canonical_domain(self):
        if self.primary_domain is None:
            return None
        if self.domain_routing_mode == "redirect_apex_to_www":
            return self.www_domain
        if self.domain_routing_mode == "redirect_www_to_apex":
            return self.apex_domain
        return self.primary_domain

    @property
    def redirect_domain(self):
        if self.primary_domain is None:
            return None
        if self.domain_routing_mode == "redirect_apex_to_www":
            return self.apex_domain
        if self.domain_routing_mode == "redirect_www_to_apex":
            return self.www_domain
        return None

    @property
    def managed_domains(self):
        if self.primary_domain is None:
            return tuple()
        if self.domain_routing_mode == "single_host":
            return (self.primary_domain,)
        return (self.apex_domain, self.www_domain)


def parse_app_config(raw_data, require_domain=True):
    settings = config_validation.select_settings(
        raw_data,
        canonical=CANONICAL_APP_SETTINGS,
        error_class=AppConfigValidationError,
        normalize=_accept_superseded_railpack_keys,
    )
    config_validation.validate_unknown_setting_keys(
        settings,
        allowed=_ALLOWED_SETTING_KEYS,
        error_class=AppConfigValidationError,
    )

    apps_root = _required_string(settings["apps_root"], "settings.apps_root")
    project_slug = _required_project_slug(
        settings["project_slug"],
        "settings.project_slug",
    )
    repository_full_name = _required_repo_full_name(
        settings["repository_full_name"],
        "settings.repository_full_name",
    )
    branch = _required_branch(settings["branch"], "settings.branch")
    domain_routing_mode = _required_domain_routing_mode(
        settings["domain_routing_mode"],
        "settings.domain_routing_mode",
    )

    primary_domain = _optional_domain(
        settings["primary_domain"],
        "settings.primary_domain",
    )
    if primary_domain is not None and domain_routing_mode != "single_host":
        primary_domain = _strip_leading_www(primary_domain)
    if require_domain and primary_domain is None:
        raise AppConfigValidationError(
            "settings.primary_domain is required for web app deployment.",
        )

    app_port = _required_port(settings["app_port"], "settings.app_port")
    public_health_check_enabled = _required_bool(
        settings["public_health_check_enabled"],
        "settings.public_health_check_enabled",
    )
    public_health_check_path = _required_public_health_path(
        settings["public_health_check_path"],
        "settings.public_health_check_path",
    )
    repo_host = _required_host(settings["repo_host"], "settings.repo_host")
    railpack_build_helper = _required_string(
        settings["railpack_build_helper"],
        "settings.railpack_build_helper",
    )
    railpack_env_file = _required_string(
        settings["railpack_env_file"],
        "settings.railpack_env_file",
    )
    railpack_build_command = _optional_command(
        settings["railpack_build_cmd"],
        "settings.railpack_build_cmd",
    )
    railpack_run_command = _optional_command(
        settings["railpack_start_cmd"],
        "settings.railpack_start_cmd",
    )
    railpack_provider = _optional_railpack_provider(
        settings["railpack_provider"],
        "settings.railpack_provider",
    )
    app_subdirectory = _optional_app_subdirectory(
        settings["app_subdirectory"],
        "settings.app_subdirectory",
    )
    worker_run_command = _optional_worker_command(
        settings["worker_start_cmd"],
        "settings.worker_start_cmd",
    )
    workers = _optional_workers(
        settings["workers"],
        "settings.workers",
    )
    if not workers and worker_run_command is not None:
        workers = (
            WorkerConfig(
                id="default",
                name="Default worker",
                start_command=worker_run_command,
                cpu_limit=0.5,
                memory_mb=256,
                disk_mb=1024,
                enabled=True,
                database_user=None,
                database_name=None,
                database_password=None,
                database_engine=None,
                database_host=None,
                database_port=None,
            ),
        )
    caddy_stack_root = _required_string(
        settings["caddy_stack_root"],
        "settings.caddy_stack_root",
    )
    caddy_container_name = _required_container_name(
        settings["caddy_container_name"],
        "settings.caddy_container_name",
    )
    caddy_apply_helper = _required_string(
        settings["caddy_apply_helper"],
        "settings.caddy_apply_helper",
    )
    railpack_node_mode = _required_node_mode(
        settings["railpack_node_mode"],
        "settings.railpack_node_mode",
    )
    deploy_private_key = _optional_private_key(
        settings["deploy_private_key"],
        "settings.deploy_private_key",
    )
    repository_host_key_policy = _required_repository_host_key_policy(
        settings["repository_host_key_policy"],
        "settings.repository_host_key_policy",
    )
    accepted_repository_host_key_fingerprint = _optional_ssh_sha256_fingerprint(
        settings["accepted_repository_host_key_fingerprint"],
        "settings.accepted_repository_host_key_fingerprint",
    )
    if repository_host_key_policy != "strict" and (
        accepted_repository_host_key_fingerprint is None
    ):
        raise AppConfigValidationError(
            "settings.accepted_repository_host_key_fingerprint is required "
            "when repository host-key trust is being confirmed.",
        )
    runtime_env = _optional_runtime_env(
        settings["runtime_env"],
        "settings.runtime_env",
    )
    sqlite_storage = _optional_sqlite_storage(
        settings["sqlite_storage"],
        "settings.sqlite_storage",
    )
    sqlite_snapshot_mounts = _optional_sqlite_snapshot_mounts(
        settings["sqlite_snapshot_mounts"],
        "settings.sqlite_snapshot_mounts",
    )
    trust_network_names = _optional_network_names(
        settings["trust_network_names"],
        "settings.trust_network_names",
    )
    tls_challenge_mode = _required_tls_challenge_mode(
        settings["tls_challenge_mode"],
        "settings.tls_challenge_mode",
    )
    tls_dns_provider = _optional_tls_dns_provider(
        settings["tls_dns_provider"],
        "settings.tls_dns_provider",
    )
    tls_dns_credentials = _optional_tls_dns_credentials(
        settings["tls_dns_credentials"],
        "settings.tls_dns_credentials",
    )
    if tls_challenge_mode == "dns":
        if tls_dns_provider is None:
            raise AppConfigValidationError(
                "settings.tls_dns_provider is required when DNS challenge mode is enabled.",
            )
        _validate_dns_credentials(tls_dns_provider, tls_dns_credentials)
    else:
        tls_dns_provider = None
        tls_dns_credentials = {}

    return AppConfig(
        apps_root=apps_root,
        project_slug=project_slug,
        repository_full_name=repository_full_name,
        branch=branch,
        primary_domain=primary_domain,
        domain_routing_mode=domain_routing_mode,
        app_port=app_port,
        public_health_check_enabled=public_health_check_enabled,
        public_health_check_path=public_health_check_path,
        repo_host=repo_host,
        railpack_build_helper=railpack_build_helper,
        railpack_env_file=railpack_env_file,
        railpack_build_command=railpack_build_command,
        railpack_run_command=railpack_run_command,
        railpack_provider=railpack_provider,
        app_subdirectory=app_subdirectory,
        worker_run_command=worker_run_command,
        caddy_stack_root=caddy_stack_root,
        caddy_container_name=caddy_container_name,
        caddy_apply_helper=caddy_apply_helper,
        railpack_node_mode=railpack_node_mode,
        deploy_private_key=deploy_private_key,
        repository_host_key_policy=repository_host_key_policy,
        accepted_repository_host_key_fingerprint=(accepted_repository_host_key_fingerprint),
        runtime_env=runtime_env,
        sqlite_storage=sqlite_storage,
        sqlite_snapshot_mounts=sqlite_snapshot_mounts,
        trust_network_names=trust_network_names,
        tls_challenge_mode=tls_challenge_mode,
        tls_dns_provider=tls_dns_provider,
        tls_dns_credentials=tls_dns_credentials,
        workers=workers,
    )
