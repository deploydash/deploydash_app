from io import StringIO

from pyinfra.operations import apt, files, server
from pyinfra.operations.util import any_changed

from .. import server_paths
from .common import SetupStep, StepAction
from .setup_config import SetupConfig


def build_steps(config: SetupConfig):
    banner_text = config.ssh_banner_text

    def register_step18(runtime):
        runtime.ensure_apt_updated()
        runtime.add_operation(
            apt.packages,
            update=False,
            packages=["auditd", "audispd-plugins"],
        )
        rules_file = runtime.add_operation(
            files.put,
            src=StringIO(
                "-w /etc/passwd -p wa -k identity\n"
                "-w /etc/shadow -p wa -k identity\n"
                "-w /etc/docker/daemon.json -p wa -k docker-daemon\n",
            ),
            dest=server_paths.AUDIT_RULES_FILE,
            mode="640",
        )
        runtime.add_operation(
            server.shell,
            commands=["augenrules --load"],
            _if=rules_file.did_change,
        )
        runtime.add_operation(
            server.service,
            service="auditd",
            running=True,
            enabled=True,
        )

    def register_step20(runtime):
        banner_file = runtime.add_operation(
            files.put,
            src=StringIO(f"{banner_text}\n"),
            dest="/etc/issue.net",
            mode="644",
        )
        banner_line = runtime.add_operation(
            files.line,
            path="/etc/ssh/sshd_config",
            line=r"^\s*#?\s*Banner\s+.*$",
            replace="Banner /etc/issue.net",
        )
        config_changed = any_changed(banner_file, banner_line)
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

    def register_step23(runtime):
        runtime.add_operation(
            server.sysctl,
            key="kernel.dmesg_restrict",
            value=1,
            persist=True,
            persist_file=server_paths.SYSCTL_SECURITY_FILE,
        )

    def register_step24(runtime):
        blacklist_file = runtime.add_operation(
            files.put,
            src=StringIO(
                "install usb-storage /bin/true\n"
                "blacklist usb-storage\n"
                "install floppy /bin/true\n"
                "blacklist floppy\n",
            ),
            dest=server_paths.MODPROBE_BLACKLIST_FILE,
            mode="644",
        )
        runtime.add_operation(
            server.shell,
            commands=["modprobe -r usb-storage || true", "modprobe -r floppy || true"],
            _if=blacklist_file.did_change,
        )

    return [
        SetupStep(
            id="part4_step18_auditd",
            title="Auditd implementation",
            part="part4",
            commands=[
                "Install auditd and audispd-plugins",
                f"Write {server_paths.AUDIT_RULES_FILE}",
                "Load audit rules on changes and ensure auditd is running",
            ],
            actions=[
                StepAction(
                    id="part4_step18_action_install_auditd",
                    label="Install auditd packages",
                    description="Install Linux audit logging components",
                ),
                StepAction(
                    id="part4_step18_action_write_audit_rules",
                    label="Write audit watch rules",
                    description="Track sensitive file modifications reliably",
                ),
                StepAction(
                    id="part4_step18_action_enable_auditd",
                    label="Enable auditd service",
                    description="Start audit daemon and persist boot",
                ),
            ],
            register=register_step18,
        ),
        SetupStep(
            id="part4_step20_ssh_banner",
            title="SSH banner",
            part="part4",
            commands=[
                "Write /etc/issue.net banner text",
                "Set Banner /etc/issue.net in sshd_config",
                "Validate and restart SSH daemon when banner config changes",
            ],
            actions=[
                StepAction(
                    id="part4_step20_action_write_banner",
                    label="Write SSH banner",
                    description="Create legal SSH warning banner text",
                ),
                StepAction(
                    id="part4_step20_action_set_banner_config",
                    label="Set sshd banner path",
                    description="Point sshd to banner file",
                ),
                StepAction(
                    id="part4_step20_action_reload_sshd",
                    label="Reload SSH daemon",
                    description="Apply SSH banner configuration changes",
                ),
            ],
            register=register_step20,
        ),
        SetupStep(
            id="part4_step23_dmesg_restrict",
            title="Restrict dmesg access",
            part="part4",
            commands=[
                "Set kernel.dmesg_restrict=1 with persistent sysctl config",
            ],
            actions=[
                StepAction(
                    id="part4_step23_action_restrict_dmesg",
                    label="Restrict dmesg output",
                    description="Hide kernel messages from unprivileged users",
                ),
            ],
            register=register_step23,
        ),
        SetupStep(
            id="part4_step24_blacklist_filesystems",
            title="Disable removable storage drivers",
            part="part4",
            commands=[
                f"Write removable storage driver blocklist to {server_paths.MODPROBE_BLACKLIST_FILE}",
                "Unload usb-storage/floppy drivers when the blocklist changes",
            ],
            notes=(
                "USB drives will not mount while this block is active. To restore USB "
                f"storage, remove {server_paths.MODPROBE_BLACKLIST_FILE} and run "
                "sudo modprobe usb-storage."
            ),
            actions=[
                StepAction(
                    id="part4_step24_action_write_module_blacklist",
                    label="Block removable storage drivers",
                    description=(
                        "Prevent USB mass-storage and floppy drivers from loading; "
                        "USB drives will not mount"
                    ),
                ),
                StepAction(
                    id="part4_step24_action_unload_modules",
                    label="Unload removable storage drivers",
                    description=(
                        "Apply the block immediately by unloading active USB storage "
                        "and floppy drivers"
                    ),
                ),
            ],
            register=register_step24,
        ),
    ]
