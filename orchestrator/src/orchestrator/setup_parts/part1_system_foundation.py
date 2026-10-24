import shlex

from pyinfra.operations import apt, files, server
from pyinfra.operations.util import any_changed

from .. import apt_runtime, server_paths
from .common import SetupStep, StepAction
from .setup_config import SetupConfig


def _register_sshd_option(runtime, option_name, option_value):
    return runtime.add_operation(
        files.line,
        path="/etc/ssh/sshd_config",
        line=rf"^\s*#?\s*{option_name}\s+.*$",
        replace=f"{option_name} {option_value}",
    )


def _hosts_alignment_command(
    hostname,
    hosts_path=server_paths.HOSTS_FILE,
    *,
    cloud_config_path=server_paths.CLOUD_INIT_CONFIG_FILE,
    cloud_config_dir=server_paths.CLOUD_INIT_CONFIG_DIR,
    cloud_hosts_template_path=server_paths.CLOUD_INIT_HOSTS_TEMPLATE,
):
    """Keep the live and cloud-init-owned hosts mappings aligned across boots."""
    shortname = hostname.split(".", 1)[0]
    hosts_line = f"127.0.1.1 {hostname}"
    if shortname != hostname:
        hosts_line = f"{hosts_line} {shortname}"
    return (
        "set -eu; "
        f"LIVE_HOSTS_FILE={shlex.quote(str(hosts_path))}; "
        f"CLOUD_CONFIG_FILE={shlex.quote(str(cloud_config_path))}; "
        f"CLOUD_CONFIG_DIR={shlex.quote(str(cloud_config_dir))}; "
        f"CLOUD_HOSTS_TEMPLATE={shlex.quote(str(cloud_hosts_template_path))}; "
        f"TARGET_HOSTNAME={shlex.quote(hostname)}; "
        f"MANAGED_LINE={shlex.quote(hosts_line)}; "
        'CLOUD_MANAGE_HOSTS="$({ '
        '[ ! -f "$CLOUD_CONFIG_FILE" ] || cat "$CLOUD_CONFIG_FILE"; '
        'if [ -d "$CLOUD_CONFIG_DIR" ]; then '
        "find \"$CLOUD_CONFIG_DIR\" -maxdepth 1 -type f -name '*.cfg' -print "
        "| sort | while IFS= read -r CLOUD_CONFIG_SNIPPET; do "
        'cat "$CLOUD_CONFIG_SNIPPET"; done; fi; '
        "} | awk -F: '/^[[:space:]]*manage_etc_hosts[[:space:]]*:/ { "
        'value=$0; sub(/^[^:]*:[[:space:]]*/, "", value); '
        'sub(/#.*/, "", value); gsub(/[[:space:]"\\047]/, "", value); '
        "setting=tolower(value) } END { print setting }')\"; "
        "for TARGET_KIND in live cloud_template; do "
        'if [ "$TARGET_KIND" = live ]; then HOSTS_FILE="$LIVE_HOSTS_FILE"; '
        'else case "$CLOUD_MANAGE_HOSTS" in true|localhost) ;; *) continue ;; esac; '
        '[ -f "$CLOUD_HOSTS_TEMPLATE" ] || continue; '
        'HOSTS_FILE="$CLOUD_HOSTS_TEMPLATE"; fi; '
        'TMP="$(mktemp)"; '
        "trap 'rm -f \"$TMP\"' EXIT HUP INT TERM; "
        'awk -v managed_line="$MANAGED_LINE" -v target_hostname="$TARGET_HOSTNAME" \' '
        '$1 == "127.0.0.1" && NF == 3 && $2 == target_hostname && $3 == "mail" { next } '
        '$1 == "127.0.1.1" { '
        "if (!managed_written) { print managed_line; managed_written = 1 } next "
        "} "
        "{ print } "
        "END { if (!managed_written) print managed_line }"
        '\' "$HOSTS_FILE" > "$TMP"; '
        'if ! cmp -s "$TMP" "$HOSTS_FILE"; then cat "$TMP" > "$HOSTS_FILE"; fi; '
        'rm -f "$TMP"; trap - EXIT HUP INT TERM; '
        "done"
    )


def build_steps(config: SetupConfig):
    admin_user = config.admin_user
    bootstrap_username = config.bootstrap_username
    timezone = config.timezone
    hostname = config.hostname
    ssh_public_key = config.ssh_public_key
    managed_user_password = config.managed_user_password

    quoted_admin_user = shlex.quote(admin_user)
    quoted_bootstrap_username = shlex.quote(bootstrap_username) if bootstrap_username else "''"
    quoted_managed_user_password = (
        shlex.quote(managed_user_password) if managed_user_password else "''"
    )
    quoted_timezone = shlex.quote(timezone)
    quoted_hostname = shlex.quote(hostname) if hostname else None

    def register_step1(runtime):
        runtime.ensure_apt_updated(cache_time=0)
        runtime.add_operation(apt.upgrade)

    def register_step2(runtime):
        runtime.add_operation(
            server.shell,
            commands=[
                "set -eu; "
                f"ADMIN_USER={quoted_admin_user}; "
                f"BOOTSTRAP_USER={quoted_bootstrap_username}; "
                f"MANAGED_PASSWORD={quoted_managed_user_password}; "
                'if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then '
                "adduser --disabled-password --gecos '' \"$ADMIN_USER\"; "
                "fi; "
                'usermod -aG sudo "$ADMIN_USER"; '
                'SUDOERS_TMP="$(mktemp)"; '
                'printf \'%s ALL=(ALL) NOPASSWD:ALL\\n\' "$ADMIN_USER" > "$SUDOERS_TMP"; '
                'visudo -c -f "$SUDOERS_TMP"; '
                'install -m 0440 -o root -g root "$SUDOERS_TMP" '
                f"{server_paths.SUDOERS_MANAGED_DROPIN_FILE}; "
                'rm -f "$SUDOERS_TMP"; '
                'usermod -s /bin/bash "$ADMIN_USER"; '
                'TARGET_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"; '
                'install -d -o "$ADMIN_USER" -g "$ADMIN_USER" -m 700 '
                '"${TARGET_HOME}/.ssh"; '
                'if [ -n "$BOOTSTRAP_USER" ] && [ "$BOOTSTRAP_USER" != "$ADMIN_USER" ]; then '
                'printf \'%s:%s\\n\' "$ADMIN_USER" "$MANAGED_PASSWORD" | chpasswd; '
                "fi; "
                'chown -R "$ADMIN_USER:$ADMIN_USER" "${TARGET_HOME}/.ssh"; '
                'chmod 700 "${TARGET_HOME}/.ssh"; '
                'touch "${TARGET_HOME}/.ssh/authorized_keys"; '
                'chown "$ADMIN_USER:$ADMIN_USER" '
                '"${TARGET_HOME}/.ssh/authorized_keys"; '
                'chmod 600 "${TARGET_HOME}/.ssh/authorized_keys";',
            ],
        )

    def register_step3(runtime):
        ssh_config_ops = [_register_sshd_option(runtime, "PubkeyAuthentication", "yes")]

        if ssh_public_key:
            runtime.add_operation(
                server.user_authorized_keys,
                user=admin_user,
                group=admin_user,
                public_keys=[ssh_public_key],
                delete_keys=False,
            )

        config_changed = any_changed(*ssh_config_ops)
        runtime.add_operation(
            files.directory,
            path="/run/sshd",
            mode="755",
            _if=config_changed,
        )
        runtime.add_operation(
            server.shell,
            commands=["sshd -t"],
            _if=config_changed,
        )
        runtime.add_operation(
            server.service,
            service="ssh",
            restarted=True,
            _if=config_changed,
        )

    def register_step4(runtime):
        runtime.add_operation(
            server.hostname,
            hostname=hostname,
        )
        runtime.add_operation(
            server.shell,
            commands=[_hosts_alignment_command(hostname)],
        )

    def register_step5(runtime):
        runtime.add_operation(
            server.timezone,
            timezone=timezone,
        )
        runtime.add_operation(
            server.service,
            service="systemd-timesyncd",
            running=True,
            enabled=True,
        )

    ssh_actions = [
        StepAction(
            id="part1_step3_action_enable_pubkey",
            label="Enable SSH public-key auth",
            description="Allow the managed SSH key to sign in",
        ),
    ]
    if ssh_public_key:
        ssh_actions.append(
            StepAction(
                id="part1_step3_action_authorize_admin_key",
                label="Deploy Dash adds 1 SSH key",
                description="Install the Deploy Dash SSH key for ubuntu",
            ),
        )
    ssh_actions.append(
        StepAction(
            id="part1_step3_action_reload_sshd",
            label="Reload SSH daemon",
            description="Validate and restart SSH daemon",
        ),
    )

    steps = [
        SetupStep(
            id="part1_step1_system_update",
            title="System update & patching",
            part="part1",
            commands=[
                apt_runtime.apt_get_command("update"),
                apt_runtime.apt_get_command("upgrade -y"),
            ],
            actions=[
                StepAction(
                    id="part1_step1_action_update_cache",
                    label="Update package cache",
                    description="Refresh apt package metadata safely",
                ),
                StepAction(
                    id="part1_step1_action_upgrade_packages",
                    label="Upgrade installed packages",
                    description="Apply pending OS package updates",
                ),
            ],
            register=register_step1,
        ),
        SetupStep(
            id="part1_step2_user_sanitization",
            title="Managed user setup",
            part="part1",
            commands=[
                f"Create or reuse managed user {quoted_admin_user}",
                f"Grant sudo access to {quoted_admin_user}",
            ],
            actions=[
                StepAction(
                    id="part1_step2_action_create_admin_user",
                    label="Prepare ubuntu account",
                    description="Create or normalize the managed ubuntu user",
                ),
                StepAction(
                    id="part1_step2_action_grant_sudo",
                    label="Grant sudo access",
                    description="Allow ubuntu to run administrative commands",
                ),
            ],
            register=register_step2,
        ),
        SetupStep(
            id="part1_step3_ssh_hardening",
            title="Managed SSH access",
            part="part1",
            commands=[
                "Configure sshd PubkeyAuthentication yes",
                "Install the Deploy Dash managed SSH key for ubuntu",
                "Validate and restart SSH daemon on config changes",
            ],
            notes=(
                "Deploy Dash verifies ubuntu key login before disabling root "
                "or password SSH access."
            ),
            actions=ssh_actions,
            register=register_step3,
        ),
    ]

    if hostname:
        steps.append(
            SetupStep(
                id="part1_step4_hostname_alignment",
                title="Hostname & FQDN alignment",
                part="part1",
                commands=[
                    f"hostnamectl set-hostname {quoted_hostname}",
                    "Ensure one conventional 127.0.1.1 FQDN/shortname mapping",
                    "Remove obsolete Deploy Dash 127.0.0.1 mail aliases",
                ],
                actions=[
                    StepAction(
                        id="part1_step4_action_set_hostname",
                        label="Set server hostname",
                        description="Align hostname with server FQDN",
                    ),
                    StepAction(
                        id="part1_step4_action_update_hosts",
                        label="Update local hosts mapping",
                        description="Align local resolution with Ubuntu and cloud-init",
                    ),
                ],
                register=register_step4,
            ),
        )

    steps.append(
        SetupStep(
            id="part1_step5_time_sync",
            title="Timezone & NTP sync",
            part="part1",
            commands=[
                f"timedatectl set-timezone {quoted_timezone}",
                "systemctl enable --now systemd-timesyncd",
            ],
            actions=[
                StepAction(
                    id="part1_step5_action_set_timezone",
                    label="Set timezone",
                    description="Standardize server timezone to UTC",
                ),
                StepAction(
                    id="part1_step5_action_enable_ntp",
                    label="Enable NTP sync",
                    description="Keep server clock synchronized automatically",
                ),
            ],
            register=register_step5,
        ),
    )

    return steps
