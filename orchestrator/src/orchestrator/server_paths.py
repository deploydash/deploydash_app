"""The single owner of every managed path on a Deploy Dash server.

This module exists because the layout was previously twenty-three string
literals spread across eleven modules, which made it unchangeable in
practice: no reader could tell which literals were the same path, and no
change could be made without finding all of them.

The rule this module enforces, stated once so the rest of the backend does
not have to repeat it:

    A managed path literal may appear here and nowhere else.

Its sibling `server_identifiers.py` owns the other half: this module owns
**where** something lives, that one owns **what it is called**. A path may
embed a name, which is why the import points this way and never back.

Two consequences are deliberate and should not be "fixed" later:

- **No builder accepts a root argument.** The layout is defined here, not
  passed in. A builder taking a root would re-open the door this module
  closes, because a caller could then hand it a stale root arriving over the
  wire from an old client -- which is exactly the defect T-1.1.4 removes.
- **Segment arguments are validated, not trusted.** A project slug or policy
  token that escaped its parent directory would place a managed resource
  outside the layout entirely, where nothing that enumerates or cleans up
  projects would ever find it again. Rejecting is cheap; an orphaned
  container on a customer's machine is not.

The on-disk layout, versioned by `LAYOUT_VERSION`:

    /opt/deploydash/
      LAYOUT_VERSION          single integer, newline-terminated, mode 0644
      stack/                  was /opt/docker-stack
        apps/ db/ dns/ http/ mail/ postgres/ proxy/ railpack/
      state/                  was /opt/docker-stack/.deploydash
        managed-software-ledger.json
        postgres-major-upgrades.json
        scheduler/
        upgrade-backups/
      firewall/               unchanged
    /var/log/deploydash/      unchanged; correct per FHS

Deploy Dash also owns individual files in directories the OS owns -- sshd and
journald drop-ins, sysctl and modprobe files, audit rules, cron jobs, and the
helper binaries under /usr/local/bin. They are not part of the layout above
and are not versioned by `LAYOUT_VERSION`, but they are managed paths, so
they are declared here rather than as literals at their call sites.

See `docs/contracts/server-layout.md` for the version semantics and the
connect-time compatibility branches.
"""

from . import server_identifiers

__all__ = [
    "APT_LOCK_TIMEOUT_DROPIN_FILE",
    "AUDIT_RULES_FILE",
    "CLOUD_INIT_CONFIG_DIR",
    "CLOUD_INIT_CONFIG_FILE",
    "CLOUD_INIT_HOSTS_TEMPLATE",
    "DEPLOYDASH_ROOT",
    "FIREWALL_ROOT",
    "HOSTS_FILE",
    "JOURNALD_DROPIN_FILE",
    "LAYOUT_VERSION",
    "LAYOUT_VERSION_FILE",
    "LOG_ROOT",
    "MODPROBE_BLACKLIST_FILE",
    "POSTGRES_IMPORT_TEMP_PREFIX",
    "SETUP_SSHD_BACKUP_PREFIX",
    "SSHD_DROPIN_FILE",
    "STACK_ROOT",
    "STATE_ROOT",
    "SUDOERS_MANAGED_DROPIN_FILE",
    "SYSCTL_PERFORMANCE_FILE",
    "SYSCTL_SECURITY_FILE",
    "SYSTEM_BACKUP_TEMP_PREFIX",
    "app_dir",
    "apps_root",
    "bind_apply_helper",
    "caddy_apply_helper",
    "db_root",
    "dns_root",
    "http_root",
    "mail_root",
    "managed_software_ledger",
    "postgres_backup_cron_file",
    "postgres_backup_log",
    "postgres_hba_file",
    "postgres_root",
    "postgres_tls_certificate",
    "postgres_tls_private_key",
    "postgres_tls_root",
    "postgres_upgrade_ledger",
    "proxy_root",
    "railpack_build_helper",
    "railpack_env_file",
    "railpack_root",
    "scheduler_script_dir",
    "stack_setup_directories",
    "upgrade_backup_dir",
    "upgrade_backup_service_dir",
    "upgrade_backups_root",
]


# Bumped only when the on-disk layout changes shape. An int, not a string:
# it is compared with `>` against a value read off the server, and a string
# comparison would treat version 10 as older than version 9.
LAYOUT_VERSION = 2

DEPLOYDASH_ROOT = "/opt/deploydash"
LAYOUT_VERSION_FILE = f"{DEPLOYDASH_ROOT}/LAYOUT_VERSION"
STACK_ROOT = f"{DEPLOYDASH_ROOT}/stack"
STATE_ROOT = f"{DEPLOYDASH_ROOT}/state"
FIREWALL_ROOT = f"{DEPLOYDASH_ROOT}/firewall"

# Logs stay under /var/log rather than moving into /opt/deploydash: the FHS
# puts variable log data there, and operators, logrotate, and journald
# tooling all expect to find it there.
LOG_ROOT = "/var/log/deploydash"

_PREFIX = server_identifiers.MANAGED_PREFIX

# Managed files in OS-owned directories. Ordered by the directory they live
# in, because that is how an operator looking for them will search.
APT_LOCK_TIMEOUT_DROPIN_FILE = "/etc/apt/apt.conf.d/50deploydash-lock-timeout"
CLOUD_INIT_CONFIG_FILE = "/etc/cloud/cloud.cfg"
CLOUD_INIT_CONFIG_DIR = "/etc/cloud/cloud.cfg.d"
CLOUD_INIT_HOSTS_TEMPLATE = "/etc/cloud/templates/hosts.debian.tmpl"
HOSTS_FILE = "/etc/hosts"
SSHD_DROPIN_FILE = f"/etc/ssh/sshd_config.d/00-{_PREFIX}.conf"
JOURNALD_DROPIN_FILE = f"/etc/systemd/journald.conf.d/{_PREFIX}.conf"
SYSCTL_PERFORMANCE_FILE = f"/etc/sysctl.d/99-{_PREFIX}-performance.conf"
SYSCTL_SECURITY_FILE = f"/etc/sysctl.d/99-{_PREFIX}-security.conf"
AUDIT_RULES_FILE = f"/etc/audit/rules.d/{_PREFIX}.rules"
MODPROBE_BLACKLIST_FILE = f"/etc/modprobe.d/{_PREFIX}-blacklist.conf"
# The onboarding sudo grant for the managed user. Installed 0440 root:root
# after visudo validation by part1 step 2; every post-handoff step runs
# through `sudo -n`, which fails rather than prompting.
SUDOERS_MANAGED_DROPIN_FILE = f"/etc/sudoers.d/{server_identifiers.SUDOERS_MANAGED_DROPIN_NAME}"

# Prefixes, not paths: each call site appends a timestamp and PID on the
# server so concurrent runs cannot collide.
# Onboarding backs the SSH daemon configuration up here before hardening it,
# and restores from it if the managed login cannot be verified afterwards.
#
# Deliberately under STATE_ROOT rather than /tmp. A backup in /tmp is cleared
# on reboot and is therefore useless for exactly the recovery it exists for:
# an onboarding that hardened SSH and then died. See G-2 in
# docs/contracts/onboarding-invariants.md.
SETUP_SSHD_BACKUP_PREFIX = f"{STATE_ROOT}/setup-sshd-backup/{_PREFIX}-setup-sshd-"
SYSTEM_BACKUP_TEMP_PREFIX = f"/tmp/{_PREFIX}-system-backup-"
POSTGRES_IMPORT_TEMP_PREFIX = f"/tmp/{_PREFIX}-postgres-import-"

_HELPER_BIN_DIR = "/usr/local/bin"


def _segment(value: str, what: str) -> str:
    """Return `value` if it is safe as a single path segment.

    Raises `ValueError` otherwise. Rejects anything containing a separator,
    anything starting with a dot (which covers `.` and `..`), and the empty
    string.

    Delegates to `server_identifiers.safe_segment`: a path segment and an
    identifier segment are the same rule, and two copies of it would be free
    to drift into accepting different things.
    """
    return server_identifiers.safe_segment(value, what)


def apps_root() -> str:
    """Return the directory holding one subdirectory per deployed project."""
    return f"{STACK_ROOT}/apps"


def app_dir(project_slug: str) -> str:
    """Return the managed directory for one project's deployed application."""
    return f"{apps_root()}/{_segment(project_slug, 'project slug')}"


def http_root() -> str:
    """Return the HTTP gateway (Caddy) stack directory."""
    return f"{STACK_ROOT}/http"


def dns_root() -> str:
    """Return the authoritative DNS (BIND) stack directory."""
    return f"{STACK_ROOT}/dns"


def mail_root() -> str:
    """Return the mail server stack directory."""
    return f"{STACK_ROOT}/mail"


def proxy_root() -> str:
    """Return the proxy stack directory."""
    return f"{STACK_ROOT}/proxy"


def db_root() -> str:
    """Return the general database stack directory.

    Distinct from `postgres_root`: this is the shared database area created
    at provisioning time, whereas the PostgreSQL directory holds the managed
    PostgreSQL service specifically.
    """
    return f"{STACK_ROOT}/db"


def postgres_root() -> str:
    """Return the managed PostgreSQL service directory."""
    return f"{STACK_ROOT}/postgres"


def postgres_tls_root() -> str:
    """Return the directory holding persistent PostgreSQL TLS policy files."""
    return f"{postgres_root()}/tls"


def postgres_tls_certificate() -> str:
    """Return the public certificate clients trust for PostgreSQL TLS."""
    return f"{postgres_tls_root()}/server.crt"


def postgres_tls_private_key() -> str:
    """Return the private server key readable only by the PostgreSQL process."""
    return f"{postgres_tls_root()}/server.key"


def postgres_hba_file() -> str:
    """Return the managed access policy that requires TLS for TCP clients."""
    return f"{postgres_tls_root()}/pg_hba.conf"


def railpack_root() -> str:
    """Return the Railpack build tooling directory."""
    return f"{STACK_ROOT}/railpack"


def railpack_env_file() -> str:
    """Return the Railpack build environment file read by the build helper."""
    return f"{railpack_root()}/railpack.env"


def managed_software_ledger() -> str:
    """Return the ledger recording installed managed-software versions.

    Under `state/` rather than `stack/` because it describes the server as a
    whole, not any one component of the stack.
    """
    return f"{STATE_ROOT}/managed-software-ledger.json"


def postgres_upgrade_ledger() -> str:
    """Return the ledger recording retained pre-upgrade PostgreSQL volumes.

    Under `state/` for the same reason as the managed-software ledger:
    retained volumes outlive any one compose file, and removal matches
    them by ledger membership rather than by name heuristics (#86).
    """
    return f"{STATE_ROOT}/postgres-major-upgrades.json"


def scheduler_script_dir() -> str:
    """Return the directory holding generated scheduled-task scripts."""
    return f"{STATE_ROOT}/scheduler"


def upgrade_backups_root() -> str:
    """Return the root under which pre-upgrade backups are kept."""
    return f"{STATE_ROOT}/upgrade-backups"


def upgrade_backup_service_dir(service: str) -> str:
    """Return the pre-upgrade backup directory for one managed service."""
    return f"{upgrade_backups_root()}/{_segment(service, 'service name')}"


def upgrade_backup_dir(service: str, timestamp: str) -> str:
    """Return one timestamped pre-upgrade backup directory for a service."""
    return f"{upgrade_backup_service_dir(service)}/{_segment(timestamp, 'timestamp')}"


def postgres_backup_log(policy_token: str) -> str:
    """Return the log file written by one PostgreSQL backup policy's cron job."""
    token = _segment(policy_token, "policy token")
    return f"{LOG_ROOT}/postgres-backup-{token}.log"


def railpack_build_helper() -> str:
    """Return the installed Railpack build helper binary."""
    return f"{_HELPER_BIN_DIR}/{server_identifiers.RAILPACK_BUILD_HELPER_NAME}"


def caddy_apply_helper() -> str:
    """Return the installed Caddy apply helper binary."""
    return f"{_HELPER_BIN_DIR}/{server_identifiers.CADDY_APPLY_HELPER_NAME}"


def bind_apply_helper() -> str:
    """Return the installed BIND apply helper binary."""
    return f"{_HELPER_BIN_DIR}/{server_identifiers.BIND_APPLY_HELPER_NAME}"


def postgres_backup_cron_file(policy_token: str) -> str:
    """Return the cron file driving one PostgreSQL backup policy."""
    return f"/etc/cron.d/{server_identifiers.postgres_backup_cron_name(policy_token)}"


def stack_setup_directories() -> list[str]:
    """Return the managed directories to create at provisioning, in order.

    The order is load-bearing. `/opt/deploydash` is first so that the
    `LAYOUT_VERSION` marker can be written into it before anything else
    exists: a server that dies part-way through provisioning is then still
    identifiable by a later connect, rather than looking like an
    unprovisioned machine with stray directories on it.
    """
    return [
        DEPLOYDASH_ROOT,
        STACK_ROOT,
        STATE_ROOT,
        proxy_root(),
        mail_root(),
        dns_root(),
        db_root(),
        apps_root(),
    ]
