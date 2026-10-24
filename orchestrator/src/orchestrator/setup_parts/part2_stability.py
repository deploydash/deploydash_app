from io import StringIO

from pyinfra.operations import apt, files, server, systemd

from .. import server_paths
from ..swap_management import render_initial_swap_command
from .common import SetupStep, StepAction
from .setup_config import SetupConfig


def _render_fail2ban_jail_local():
    return (
        "[DEFAULT]\n"
        "backend = systemd\n"
        "bantime = 1h\n"
        "findtime = 10m\n"
        "maxretry = 5\n"
        "\n"
        "[sshd]\n"
        "enabled = true\n"
    )


def build_steps(config: SetupConfig):
    def register_step7(runtime):
        runtime.add_operation(
            server.shell,
            commands=[
                render_initial_swap_command(),
            ],
        )

    def register_step8(runtime):
        runtime.add_operation(
            files.directory,
            path="/etc/systemd/journald.conf.d",
            mode="755",
        )
        journald_config = runtime.add_operation(
            files.put,
            src=StringIO("[Journal]\nSystemMaxUse=500M\nSystemMaxFileSize=50M\n"),
            dest=server_paths.JOURNALD_DROPIN_FILE,
            mode="644",
        )
        runtime.add_operation(
            server.service,
            service="systemd-journald",
            restarted=True,
            _if=journald_config.did_change,
        )

    def register_step9(runtime):
        persist_file = server_paths.SYSCTL_PERFORMANCE_FILE
        runtime.add_operation(
            files.line,
            path=persist_file,
            line=r"^\s*fs\.file-max\s*=.*$",
            present=False,
        )
        runtime.add_operation(
            server.shell,
            commands=[
                'CURRENT_FILE_MAX="$(sysctl -n fs.file-max)"; '
                '[ "${CURRENT_FILE_MAX}" = "9223372036854775807" ] || '
                "sysctl -w fs.file-max=9223372036854775807",
            ],
        )
        runtime.add_operation(
            server.sysctl,
            key="vm.swappiness",
            value=10,
            persist=True,
            persist_file=persist_file,
        )
        runtime.add_operation(
            server.sysctl,
            key="net.core.somaxconn",
            value=65535,
            persist=True,
            persist_file=persist_file,
        )

    def register_step10(runtime):
        runtime.ensure_apt_updated()
        runtime.add_operation(
            apt.packages,
            update=False,
            packages=[
                "vim",
                "curl",
                "git",
                "htop",
                "net-tools",
                "iotop",
                "unzip",
                "fail2ban",
            ],
        )
        jail_local = runtime.add_operation(
            files.put,
            src=StringIO(_render_fail2ban_jail_local()),
            dest="/etc/fail2ban/jail.local",
            mode="644",
        )
        runtime.add_operation(
            server.service,
            service="fail2ban",
            restarted=True,
            _if=jail_local.did_change,
        )
        runtime.add_operation(
            server.service,
            service="fail2ban",
            running=True,
            enabled=True,
        )

    def register_step11(runtime):
        retention_days = 90
        runtime.ensure_apt_updated()
        runtime.add_operation(
            apt.packages,
            update=False,
            packages=["sysstat"],
        )
        runtime.add_operation(
            files.line,
            path="/etc/default/sysstat",
            line=r"^\s*#?\s*ENABLED=.*$",
            replace='ENABLED="true"',
        )
        runtime.add_operation(
            files.line,
            path="/etc/sysstat/sysstat",
            line=r"^\s*#?\s*HISTORY=.*$",
            replace=f"HISTORY={retention_days}",
        )
        runtime.add_operation(
            files.line,
            path="/etc/sysstat/sysstat",
            line=r"^\s*#?\s*SADC_OPTIONS=.*$",
            replace='SADC_OPTIONS="-S DISK"',
        )
        runtime.add_operation(
            systemd.service,
            service="sysstat-collect.timer",
            running=True,
            enabled=True,
        )
        runtime.add_operation(
            systemd.service,
            service="sysstat-summary.timer",
            running=True,
            enabled=True,
        )
        runtime.add_operation(
            server.shell,
            commands=[
                "/usr/lib/sysstat/sa1 1 1 >/dev/null 2>&1 || true; "
                "find /var/log/sysstat -maxdepth 1 -type f \\( -name 'sa*' -o -name 'sar*' \\) "
                f"-mtime +{retention_days} -delete >/dev/null 2>&1 || true",
            ],
        )

    def register_step12(runtime):
        runtime.ensure_apt_updated()
        runtime.add_operation(
            apt.packages,
            update=False,
            packages=["unattended-upgrades", "apt-listchanges"],
        )
        runtime.add_operation(
            files.put,
            src=StringIO(
                'APT::Periodic::Update-Package-Lists "1";\n'
                'APT::Periodic::Unattended-Upgrade "1";\n'
                'APT::Periodic::AutocleanInterval "7";\n',
            ),
            dest="/etc/apt/apt.conf.d/20auto-upgrades",
            mode="644",
        )
        runtime.add_operation(
            files.put,
            src=StringIO(
                'Unattended-Upgrade::Automatic-Reboot "false";\n'
                'Unattended-Upgrade::Automatic-Reboot-Time "03:00";\n'
                'Unattended-Upgrade::Automatic-Reboot-WithUsers "true";\n',
            ),
            dest="/etc/apt/apt.conf.d/52unattended-upgrades-local",
            mode="644",
        )
        runtime.add_operation(
            systemd.service,
            service="apt-daily.timer",
            running=True,
            enabled=True,
        )
        runtime.add_operation(
            systemd.service,
            service="apt-daily-upgrade.timer",
            running=True,
            enabled=True,
        )

    return [
        SetupStep(
            id="part2_step7_swap",
            title="Optimize storage & swap",
            part="part2",
            commands=[
                "Ensure /swapfile exists, has correct permissions, and is enabled",
                "Ensure /swapfile entry exists in /etc/fstab",
            ],
            actions=[
                StepAction(
                    id="part2_step7_action_create_swapfile",
                    label="Provision swap file",
                    description="Create and enable persistent swap space",
                ),
                StepAction(
                    id="part2_step7_action_update_fstab",
                    label="Persist swap in fstab",
                    description="Mount swap automatically on reboot",
                ),
            ],
            register=register_step7,
        ),
        SetupStep(
            id="part2_step8_journald_limits",
            title="Configure journald limits",
            part="part2",
            commands=[
                f"Write {server_paths.JOURNALD_DROPIN_FILE}",
                "Restart systemd-journald only when config changes",
            ],
            actions=[
                StepAction(
                    id="part2_step8_action_write_journald_config",
                    label="Write journald limits",
                    description="Cap system log disk usage",
                ),
                StepAction(
                    id="part2_step8_action_restart_journald",
                    label="Restart journald service",
                    description="Apply journald limit changes safely",
                ),
            ],
            register=register_step8,
        ),
        SetupStep(
            id="part2_step9_kernel_params",
            title="Kernel parameters for performance",
            part="part2",
            commands=[
                "Remove the obsolete system-wide file-handle cap and restore the kernel default",
                "Set vm.swappiness and net.core.somaxconn with persistence",
            ],
            actions=[
                StepAction(
                    id="part2_step9_action_tune_swappiness",
                    label="Tune swappiness",
                    description="Prefer RAM before swap usage",
                ),
                StepAction(
                    id="part2_step9_action_tune_somaxconn",
                    label="Tune socket backlog",
                    description="Increase backlog for traffic spikes",
                ),
            ],
            register=register_step9,
        ),
        SetupStep(
            id="part2_step10_tooling",
            title="Install essential tooling",
            part="part2",
            commands=[
                "Install vim, curl, git, htop, net-tools, iotop, unzip, fail2ban",
                "Write managed /etc/fail2ban/jail.local for SSH bans",
                "Enable and start fail2ban",
            ],
            actions=[
                StepAction(
                    id="part2_step10_action_install_tooling",
                    label="Install diagnostics tooling",
                    description="Install essential server troubleshooting tools",
                ),
                StepAction(
                    id="part2_step10_action_write_fail2ban_policy",
                    label="Write fail2ban SSH policy",
                    description="Configure deterministic SSH ban thresholds",
                ),
                StepAction(
                    id="part2_step10_action_enable_fail2ban",
                    label="Enable fail2ban",
                    description="Start baseline intrusion ban service",
                ),
            ],
            register=register_step10,
        ),
        SetupStep(
            id="part2_step11_sysstat_metrics",
            title="Provision sysstat metrics retention",
            part="part2",
            commands=[
                "Install sysstat",
                "Enable sysstat collection and set retention to 90 days",
                "Prime one sample and prune sysstat logs older than 90 days",
            ],
            actions=[
                StepAction(
                    id="part2_step11_action_install_sysstat",
                    label="Install sysstat",
                    description="Install lightweight server metrics collector",
                ),
                StepAction(
                    id="part2_step11_action_configure_sysstat_retention",
                    label="Configure 90-day retention",
                    description="Enable sysstat timers and enforce history retention",
                ),
                StepAction(
                    id="part2_step11_action_prune_sysstat_history",
                    label="Prune old sysstat logs",
                    description="Remove metric files older than 90 days",
                ),
            ],
            register=register_step11,
        ),
        SetupStep(
            id="part2_step12_security_updates",
            title="Enable automatic security updates",
            part="part2",
            commands=[
                "Install unattended-upgrades",
                "Enable daily apt package list refresh and unattended upgrades",
                "Apply conservative reboot defaults for unattended upgrades",
            ],
            actions=[
                StepAction(
                    id="part2_step12_action_install_unattended_upgrades",
                    label="Install unattended upgrades",
                    description="Install Ubuntu automatic security update tooling",
                ),
                StepAction(
                    id="part2_step12_action_enable_periodic_updates",
                    label="Enable daily security updates",
                    description="Refresh package metadata and apply updates each day",
                ),
                StepAction(
                    id="part2_step12_action_set_reboot_defaults",
                    label="Set maintenance defaults",
                    description="Keep automatic reboots off until the user enables them",
                ),
            ],
            register=register_step12,
        ),
    ]
