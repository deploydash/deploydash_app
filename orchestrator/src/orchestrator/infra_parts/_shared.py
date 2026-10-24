# ruff: noqa: F401
import json
import re
import shlex
from datetime import UTC, datetime

from pyinfra import facts

from .. import (
    platform_versions,
    server_identifiers,
    server_layout,
    server_paths,
    settings_ownership,
    shell_output,
)
from ..container_status import (
    bind_service_readiness_check_shell,
    caddy_service_readiness_check_shell,
    container_process_running_check_shell,
    container_status_from_payload,
    container_status_kv_shell,
    postgres_service_readiness_check_shell,
    postgres_service_readiness_wait_shell,
)
from ..dns_parts import (
    CANONICAL_DNS_SETTINGS,
    DnsConfigValidationError,
    parse_dns_config,
)
from ..dns_parts import (
    collect_steps as collect_dns_steps,
)
from ..dns_parts import (
    normalize_parts as normalize_dns_parts,
)
from ..dns_parts.dns_config import RESOLVED_DNS_DEFAULTS
from ..engine_metrics_parsers import (
    _get_primary_disk_gb,
    _parse_http_service_status_output,
    _parse_positive_int,
    _parse_server_overview_metrics_output,
)
from ..engine_runtime_common import _normalized_optional_string
from ..http_parts import (
    CANONICAL_HTTP_SETTINGS,
    HttpConfigValidationError,
    parse_http_config,
)
from ..http_parts import (
    collect_steps as collect_http_steps,
)
from ..http_parts import (
    normalize_parts as normalize_http_parts,
)
from ..http_parts.http_config import RESOLVED_HTTP_DEFAULTS
from ..http_parts.part1_foundation import caddy_builder_image
from ..managed_software import (
    MANAGED_SOFTWARE_LEDGER_PATH,
    build_managed_software_status,
    empty_software_ledger,
    encode_software_ledger,
    managed_software_manifest,
    normalize_component_ids,
    parse_software_ledger,
    record_component_action,
)
from ..postgres_parts import CANONICAL_POSTGRES_SETTINGS
from ..postgres_supply_chain import (
    postgres_extension_image_dockerfiles_by_variant,
    postgres_walg_install_command,
)
from ..railpack_contract import (
    RAILPACK_FRONTEND_IMAGE,
    RAILPACK_FRONTEND_IMAGE_DIGEST,
    RAILPACK_LINUX_AMD64_ASSET,
    RAILPACK_STACK_ROOT,
    RAILPACK_VERSION,
    RAILPACK_VERSION_NUMBER,
)
from ..runtime_ops import run_shell_command, write_remote_text_file
from ..setup_parts import (
    CANONICAL_SETUP_SETTINGS,
    SetupConfigValidationError,
    parse_setup_config,
)
from ..setup_parts import (
    collect_steps as collect_setup_steps,
)
from ..setup_parts import (
    normalize_parts as normalize_setup_parts,
)
from ..setup_parts.part3_docker_prep import _docker_pinned_install_command
from ..setup_postflight import (
    apply_onboarding_firewall_baseline,
    apply_verified_onboarding_ssh_hardening,
    set_sshd_options_command,
    verify_runtime_session_connection,
)
from ..setup_security import (
    build_managed_connection_result,
    existing_admin_account_probe_command,
    parse_existing_admin_account,
    resolve_managed_connection,
    unknown_admin_account,
)
from ..workflow_executor import run_plan_dry, run_plan_execute

POSTGRES_IMAGE_TAGS_BY_MAJOR = platform_versions.POSTGRES_IMAGE_TAGS_BY_MAJOR
WALG_VERSION = platform_versions.WALG_VERSION
_DOCKER_PACKAGE_VERSION_PREFIXES = platform_versions.DOCKER_PACKAGE_VERSION_PREFIXES

_COMPATIBILITY_SERVICE_PROBES = (
    {
        "id": "docker_absent",
        "label": "Docker not already installed",
        "service_name": "Docker",
        "commands": ("docker", "docker-compose"),
        "packages": (
            "docker-ce",
            "docker-ce-cli",
            "docker.io",
            "docker-compose-plugin",
            "containerd.io",
        ),
        "units": ("docker.service", "containerd.service"),
    },
    {
        "id": "apache_absent",
        "label": "Apache not already installed",
        "service_name": "Apache",
        "commands": ("apache2", "httpd"),
        "packages": ("apache2", "apache2-bin"),
        "units": ("apache2.service", "httpd.service"),
    },
    {
        "id": "nginx_absent",
        "label": "Nginx not already installed",
        "service_name": "Nginx",
        "commands": ("nginx",),
        "packages": ("nginx", "nginx-common"),
        "units": ("nginx.service",),
    },
    {
        "id": "caddy_absent",
        "label": "Caddy not already installed",
        "service_name": "Caddy",
        "commands": ("caddy",),
        "packages": ("caddy",),
        "units": ("caddy.service",),
    },
    {
        "id": "traefik_absent",
        "label": "Traefik not already installed",
        "service_name": "Traefik",
        "commands": ("traefik",),
        "packages": ("traefik",),
        "units": ("traefik.service",),
    },
    {
        "id": "postgres_absent",
        "label": "Postgres not already installed",
        "service_name": "Postgres",
        "commands": ("postgres", "psql"),
        "packages": ("postgresql", "postgresql-client"),
        "units": ("postgresql.service",),
    },
    {
        "id": "mysql_absent",
        "label": "MySQL not already installed",
        "service_name": "MySQL",
        "commands": ("mysql", "mysqld"),
        "packages": ("mysql-server", "mariadb-server"),
        "units": ("mysql.service", "mysqld.service", "mariadb.service"),
    },
    {
        "id": "bind9_absent",
        "label": "BIND9 not already installed",
        "service_name": "BIND9",
        "commands": ("named", "rndc"),
        "packages": ("bind9",),
        "units": ("bind9.service", "named.service"),
    },
)

_COMPATIBILITY_REACHABILITY_PROBES = (
    {
        "id": "ubuntu_package_repository_reachable",
        "label": "Ubuntu package repository is reachable",
        "url": "https://archive.ubuntu.com/ubuntu/dists/{codename}/InRelease",
        "expected": "The server can reach Ubuntu package metadata over HTTPS.",
        "success_message": "Ubuntu package metadata is reachable.",
        "failure_message": (
            "The server cannot reach Ubuntu package metadata. Check outbound "
            "HTTPS, DNS, proxy, or firewall rules before setup."
        ),
    },
    {
        "id": "docker_package_repository_reachable",
        "label": "Docker package repository is reachable",
        "url": "https://download.docker.com/linux/ubuntu/dists/{codename}/InRelease",
        "expected": "The server can reach the official Docker apt repository.",
        "success_message": "Docker package repository is reachable.",
        "failure_message": (
            "The server cannot reach Docker's package repository. Setup would "
            "fail while installing Docker."
        ),
    },
    {
        "id": "github_releases_reachable",
        "label": "GitHub releases are reachable",
        "url": (
            "https://github.com/railwayapp/railpack/releases/download/"
            f"{RAILPACK_VERSION}/{RAILPACK_LINUX_AMD64_ASSET}"
        ),
        "expected": "The server can download pinned release assets from GitHub.",
        "success_message": "Pinned GitHub release assets are reachable.",
        "failure_message": (
            "The server cannot reach GitHub release downloads. Setup would "
            "fail while installing Railpack or related release assets."
        ),
    },
    {
        "id": "ghcr_registry_reachable",
        "label": "GitHub Container Registry is reachable",
        "url": "https://ghcr.io/v2/",
        "expected": "The server can reach GitHub Container Registry.",
        "success_message": "GitHub Container Registry is reachable.",
        "failure_message": (
            "The server cannot reach ghcr.io. Railpack build images may not "
            "pull during setup or deploy."
        ),
    },
    {
        "id": "docker_hub_registry_reachable",
        "label": "Docker Hub registry is reachable",
        "url": "https://registry-1.docker.io/v2/",
        "expected": "The server can reach Docker Hub registry APIs.",
        "success_message": "Docker Hub registry is reachable.",
        "failure_message": (
            "The server cannot reach Docker Hub. Managed service images may not pull during setup."
        ),
    },
)

_SETUP_BOOTSTRAP_HANDOFF_STEP_IDS = (
    "part1_step1_system_update",
    "part1_step2_user_sanitization",
    "part1_step3_ssh_hardening",
)

# The operation-family modules import this deliberately internal dependency
# surface. Keeping it explicit lets moved functions retain their existing names
# without duplicating shared protocol constants or infrastructure adapters.
__all__ = tuple(name for name in globals() if not name.startswith("__"))
