"""The single owner of every managed identifier a Deploy Dash server carries.

The sibling of `server_paths.py`, and the division between them is exact:

    `server_paths.py` owns **where** something lives.
    This module owns **what it is called**.

A path may embed a name, so `server_paths` imports this module; a name never
embeds a path, so nothing here returns a value starting with `/`. Both rules
are checked by tests rather than left to discipline.

The rule this module enforces, stated once so the rest of the backend does
not have to repeat it:

    A managed identifier literal may appear here and nowhere else.

**These values are live.** Every string below is already the name of a
container, image, network, label, systemd unit, cron job, database role, or
object-storage prefix on customer servers today. Changing one does not rename
the resource -- it makes the product build a *different* name and lose the
existing one, leaving an orphan the app can no longer find, stop, or clean
up. Treat every value here as frozen unless a migration is written for it.

Three traps this module exists to remove, all observed in the code it
replaces:

- **Underscores and dots are not interchangeable.** Container names use
  `deploydash_`; Docker label keys use `deploydash.`. Both appear inside the
  same shell command, and swapping one for the other yields a filter that
  matches nothing and reports success.
- **The app container and the app image are different strings.** The
  container is `deploydash_app_<slug>`; the image is `deploydash_<slug>`,
  with no `app_` segment. They look like a naming inconsistency and are not
  safe to "correct".
- **`deploydash_https` is not a network.** It reads like a sibling of the
  `deploydash_http` Docker network; it names a Caddy request matcher in a
  generated Caddyfile. Substituting one for the other silently drops every
  hardening header.

Segment arguments are validated rather than trusted, for the same reason
`server_paths` validates them: a slug carrying a separator would forge a name
belonging to another project, or produce one that nothing enumerating managed
resources will ever match again.
"""

import hashlib
import re

__all__ = [
    "BACKUP_CONNECTION_TEST_PREFIX",
    "BACKUP_OBJECT_ROOT",
    "BIND_APPLY_HELPER_NAME",
    "CADDY_APPLY_HELPER_NAME",
    "CADDY_HTTPS_MATCHER",
    "DOCKER_BRIDGE_INTERFACE_PATTERNS",
    "HTTP_NETWORK",
    "LABEL_CADDY_BASE",
    "LABEL_LIVE",
    "LABEL_PROJECT",
    "LABEL_RELEASE_ID",
    "LABEL_ROLE",
    "LABEL_WORKER_CPU",
    "LABEL_WORKER_DISK_MB",
    "LABEL_WORKER_ID",
    "LABEL_WORKER_MEMORY_MB",
    "MANAGED_LABEL_PAIR",
    "MANAGED_PREFIX",
    "POSTGRES_EXTENSION_IMAGE_REPOSITORY",
    "POSTGRES_QUERY_ALIAS",
    "POSTGRES_ROLE_COMMENT_PREFIX",
    "POSTGRES_SUPERUSER",
    "RAILPACK_BUILD_HELPER_NAME",
    "ROLE_WORKER",
    "SUDOERS_MANAGED_DROPIN_NAME",
    "app_container",
    "app_image",
    "app_image_prefix",
    "bind_container",
    "caddy_container",
    "caddy_custom_image",
    "caddy_custom_previous_image",
    "label_pair",
    "legacy_worker_container",
    "network_name",
    "postgres_agent_reader_role_name",
    "postgres_backup_cron_name",
    "postgres_backup_object_prefix",
    "postgres_container",
    "postgres_extension_image",
    "postgres_owner_role_name",
    "postgres_role_comment",
    "release_app_container",
    "release_app_image",
    "release_worker_container",
    "safe_segment",
    "scheduler_script_name",
    "scheduler_service_unit",
    "scheduler_timer_unit",
    "scheduler_unit_base",
    "worker_container",
    "worker_container_prefix",
]

# The one brand token. Everything below is built from it, so a rebrand is a
# migration with a single starting point rather than a repository-wide search.
MANAGED_PREFIX = "deploydash"

_SAFE_SEGMENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def safe_segment(value: str, what: str) -> str:
    """Return `value` if it is safe as a single identifier segment.

    Raises `ValueError` otherwise. Rejects separators, leading dots (which
    covers `.` and `..`), and the empty string. Shared with `server_paths`,
    which validates path segments against the same rule -- one definition, so
    the two modules cannot drift into accepting different things.
    """
    if not isinstance(value, str) or not _SAFE_SEGMENT.match(value):
        raise ValueError(f"{what} must be a single safe segment, got {value!r}")
    return value


# --- Docker containers ------------------------------------------------------


def app_container(project_slug: str) -> str:
    """Return the container name for a project's live web application."""
    return f"{MANAGED_PREFIX}_app_{safe_segment(project_slug, 'project slug')}"


def release_app_container(project_slug: str, release_id: str) -> str:
    """Return the container name for one candidate or retained app release."""
    return f"{app_container(project_slug)}_{safe_segment(release_id, 'release id')}"


def worker_container(project_slug: str, worker_id: str) -> str:
    """Return the container name for one of a project's background workers."""
    return f"{worker_container_prefix(project_slug)}{safe_segment(worker_id, 'worker id')}"


def release_worker_container(project_slug: str, worker_id: str, release_id: str) -> str:
    """Return the container name for one worker of one app release."""
    return f"{worker_container(project_slug, worker_id)}_{safe_segment(release_id, 'release id')}"


def legacy_worker_container(project_slug: str) -> str:
    """Return the pre-multi-worker container name for a project's worker.

    Projects deployed before workers gained ids have a container named
    without one. The runtime reconciliation path still looks for it; dropping
    this would orphan that container on a real server.
    """
    return f"{MANAGED_PREFIX}_worker_{safe_segment(project_slug, 'project slug')}"


def worker_container_prefix(project_slug: str) -> str:
    """Return the prefix every worker container of a project shares.

    The trailing separator is load-bearing: pruning by `deploydash_worker_demo`
    without it would also match project `demo-staging`.
    """
    return f"{legacy_worker_container(project_slug)}_"


def caddy_container() -> str:
    """Return the managed HTTP gateway container name."""
    return f"{MANAGED_PREFIX}_caddy"


def postgres_container() -> str:
    """Return the managed PostgreSQL service container name."""
    return f"{MANAGED_PREFIX}_postgres"


def bind_container() -> str:
    """Return the managed authoritative DNS container name."""
    return f"{MANAGED_PREFIX}_bind9"


# --- Docker images ----------------------------------------------------------


def app_image(project_slug: str) -> str:
    """Return the image tag built for a project's current deployment.

    Deliberately **not** `app_container`'s spelling: the image carries no
    `app_` segment. See the module docstring.
    """
    return f"{app_image_prefix(project_slug)}latest"


def release_app_image(project_slug: str, release_id: str) -> str:
    """Return the image tag retained for one app release."""
    return f"{app_image_prefix(project_slug)}release-{safe_segment(release_id, 'release id')}"


def app_image_prefix(project_slug: str) -> str:
    """Return the repository-and-separator prefix of a project's app images."""
    return f"{MANAGED_PREFIX}_{safe_segment(project_slug, 'project slug')}:"


def caddy_custom_image() -> str:
    """Return the locally built Caddy image carrying the managed plugins."""
    return f"{MANAGED_PREFIX}_caddy_custom:local"


def caddy_custom_previous_image() -> str:
    """Return the tag holding the last working custom Caddy build."""
    return f"{MANAGED_PREFIX}_caddy_custom:previous"


POSTGRES_EXTENSION_IMAGE_REPOSITORY = f"{MANAGED_PREFIX}/postgres-ext"


def postgres_extension_image(tag: str, variant: str | None = None) -> str:
    """Return the managed PostgreSQL image for one major version and variant.

    `variant` is omitted for the base image; the extension builds append it.
    """
    suffix = safe_segment(tag, "image tag")
    if variant is not None:
        suffix = f"{suffix}-{safe_segment(variant, 'image variant')}"
    return f"{POSTGRES_EXTENSION_IMAGE_REPOSITORY}:{suffix}"


# --- Docker networks --------------------------------------------------------


def network_name(role: str) -> str:
    """Return the managed Docker network name for one role."""
    return f"{MANAGED_PREFIX}_{safe_segment(role, 'network role')}"


HTTP_NETWORK = f"{MANAGED_PREFIX}_http"

# iptables treats a trailing `+` as a prefix wildcard. These are the only
# ingress interfaces trusted to carry container-to-container traffic around
# the published-port firewall; every physical, private, VPN, and future
# interface remains subject to the managed allowlist.
DOCKER_BRIDGE_INTERFACE_PATTERNS = ("docker0", "br-+")


# --- Docker labels ----------------------------------------------------------

# Dots, not underscores. See the module docstring.
#
# LABEL_MANAGED is deliberately absent from __all__: every call site wants
# the whole `deploydash.managed=true` pair, so exporting the bare key would
# be a declaration with no caller -- which the ownership invariant rejects.
LABEL_MANAGED = f"{MANAGED_PREFIX}.managed"
# Stamped into the custom Caddy build with the stock base image it was
# built from, so gateway status can tell a current custom build from a
# stale one without parsing tags.
LABEL_CADDY_BASE = f"{MANAGED_PREFIX}.caddy_base"
LABEL_PROJECT = f"{MANAGED_PREFIX}.project"
LABEL_ROLE = f"{MANAGED_PREFIX}.role"
LABEL_RELEASE_ID = f"{MANAGED_PREFIX}.release_id"
LABEL_LIVE = f"{MANAGED_PREFIX}.live"
LABEL_WORKER_ID = f"{MANAGED_PREFIX}.worker_id"
LABEL_WORKER_CPU = f"{MANAGED_PREFIX}.worker_cpu"
LABEL_WORKER_MEMORY_MB = f"{MANAGED_PREFIX}.worker_memory_mb"
LABEL_WORKER_DISK_MB = f"{MANAGED_PREFIX}.worker_disk_mb"

# The only role value in use. App containers carry no role label at all, so a
# `role=app` filter would match nothing and report success.
ROLE_WORKER = "worker"


def label_pair(key: str, value: str) -> str:
    """Return one `key=value` label argument for a Docker command."""
    return f"{key}={value}"


MANAGED_LABEL_PAIR = f"{LABEL_MANAGED}=true"


# --- systemd units ----------------------------------------------------------


def scheduler_unit_base(project_slug: str, task_id: str) -> str:
    """Return the base name shared by one scheduled task's unit files.

    Hyphen-separated, unlike container names: systemd unit names conventionally
    use hyphens, and these are read by operators in `systemctl` output.
    """
    return (
        f"{MANAGED_PREFIX}-{safe_segment(project_slug, 'project slug')}"
        f"-{safe_segment(task_id, 'task id')}"
    )


def scheduler_service_unit(project_slug: str, task_id: str) -> str:
    """Return the systemd service unit name for one scheduled task."""
    return f"{scheduler_unit_base(project_slug, task_id)}.service"


def scheduler_timer_unit(project_slug: str, task_id: str) -> str:
    """Return the systemd timer unit name for one scheduled task."""
    return f"{scheduler_unit_base(project_slug, task_id)}.timer"


def scheduler_script_name(project_slug: str, task_id: str) -> str:
    """Return the generated shell script filename for one scheduled task."""
    return f"{scheduler_unit_base(project_slug, task_id)}.sh"


# --- cron jobs --------------------------------------------------------------


def postgres_backup_cron_name(policy_token: str) -> str:
    """Return the cron job filename for one PostgreSQL backup policy."""
    return f"{MANAGED_PREFIX}-postgres-backup-{safe_segment(policy_token, 'policy token')}"


# --- managed helper binaries ------------------------------------------------

# Basenames only. `server_paths` owns the directory they are installed into.
RAILPACK_BUILD_HELPER_NAME = f"{MANAGED_PREFIX}-railpack-build"
CADDY_APPLY_HELPER_NAME = f"{MANAGED_PREFIX}-caddy-apply"
BIND_APPLY_HELPER_NAME = f"{MANAGED_PREFIX}-bind-apply"


# --- sudoers drop-in ----------------------------------------------------------

# Basename only. `server_paths` owns the /etc/sudoers.d directory it is
# installed into. No dot: sudo silently ignores sudoers.d entries whose
# names contain one. The `90-` prefix sorts it after distribution
# defaults, so the managed grant wins without editing /etc/sudoers.
SUDOERS_MANAGED_DROPIN_NAME = f"90-{MANAGED_PREFIX}-managed"


# --- PostgreSQL identities --------------------------------------------------

POSTGRES_SUPERUSER = MANAGED_PREFIX

# Managed roles carry a namespaced comment; a role without this prefix is
# somebody else's and is left alone.
POSTGRES_ROLE_COMMENT_PREFIX = f"{MANAGED_PREFIX}:"


def postgres_owner_role_name(remote_database_name: str) -> str:
    """Return the NOLOGIN owner role for one managed database (#81).

    Deterministic from the remote database name alone, so delete and
    normalization flows derive it without a registry read. The stem carries
    the database name for greppability; the sha256 suffix keeps two names
    whose stems truncate identically from colliding. Always inside
    PostgreSQL's 63-character role limit.
    """
    validated = safe_segment(remote_database_name, "database name")
    digest = hashlib.sha256(validated.encode("utf-8")).hexdigest()[:12]
    stem = validated[:33].rstrip("_")
    return f"{MANAGED_PREFIX}_owner_{stem}_{digest}"


def postgres_agent_reader_role_name(remote_database_name: str) -> str:
    """Return the LOGIN reader role for one managed database (#83).

    Same shape as the owner name: deterministic from the remote database
    name alone, greppable stem, sha256 suffix against truncation
    collisions, always inside the 63-character role limit. The kind infix
    keeps reader names disjoint from owner names.
    """
    validated = safe_segment(remote_database_name, "database name")
    digest = hashlib.sha256(validated.encode("utf-8")).hexdigest()[:12]
    stem = validated[:26].rstrip("_")
    return f"{MANAGED_PREFIX}_agent_reader_{stem}_{digest}"


def postgres_role_comment(project_slug: str, database_name: str, access_mode: str) -> str:
    """Return the comment attached to one managed database role.

    Parsed back by the agent-access reader, so the writer and the reader must
    agree on this shape exactly.
    """
    return (
        f"{POSTGRES_ROLE_COMMENT_PREFIX}project={project_slug};"
        f"db={database_name};access={access_mode}"
    )


# Reserved alias wrapping a caller's read-only SQL. Namespaced so it cannot
# collide with an alias the caller chose.
POSTGRES_QUERY_ALIAS = f"{MANAGED_PREFIX}_query"


# --- object-storage keys ----------------------------------------------------

BACKUP_OBJECT_ROOT = f"{MANAGED_PREFIX}/"

# Kept separate from backup data so a destination test can never write where
# a restore would read.
BACKUP_CONNECTION_TEST_PREFIX = f"{MANAGED_PREFIX}/connection-tests"


def postgres_backup_object_prefix(project_slug: str, policy_token: str) -> str:
    """Return the object-storage key prefix for one project's backup policy."""
    return (
        f"{BACKUP_OBJECT_ROOT}postgres/{safe_segment(project_slug, 'project slug')}"
        f"/{safe_segment(policy_token, 'policy token')}"
    )


# --- Caddy configuration ----------------------------------------------------

# A Caddy request matcher, not a Docker network. See the module docstring.
CADDY_HTTPS_MATCHER = f"@{MANAGED_PREFIX}_https"
