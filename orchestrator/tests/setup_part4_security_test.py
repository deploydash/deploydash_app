import unittest

from orchestrator.setup_parts.part4_passive_security import build_steps
from orchestrator.setup_parts.setup_config import parse_setup_config


class _OperationMeta:
    def __init__(self, did_change=False):
        self.did_change = did_change


class _Runtime:
    def __init__(self):
        self.calls = []

    def ensure_apt_updated(self, *args, **kwargs):
        self.calls.append(("ensure_apt_updated", args, kwargs))
        return _OperationMeta(did_change=False)

    def add_operation(self, op, **kwargs):
        name = getattr(op, "__name__", str(op))
        self.calls.append((name, kwargs))
        if name in ("put", "line"):
            return _OperationMeta(did_change=True)
        return _OperationMeta(did_change=False)


class TestSetupPart4Security(unittest.TestCase):
    @staticmethod
    def _op_calls(runtime):
        return [entry for entry in runtime.calls if len(entry) == 2]

    def test_part4_excludes_obsolete_security_daemons(self):
        """The supported Ubuntu baseline must not install redundant daemons."""
        config = parse_setup_config({})
        steps = build_steps(config)

        step_ids = [step.id for step in steps]
        self.assertNotIn("part4_step19_rkhunter", step_ids)
        self.assertNotIn("part4_step22_entropy", step_ids)
        self.assertEqual(
            step_ids,
            [
                "part4_step18_auditd",
                "part4_step20_ssh_banner",
                "part4_step23_dmesg_restrict",
                "part4_step24_blacklist_filesystems",
            ],
        )

    def test_step18_registers_auditd_install_and_service(self):
        config = parse_setup_config({})
        step = next(item for item in build_steps(config) if item.id == "part4_step18_auditd")
        runtime = _Runtime()
        step.register(runtime)

        self.assertTrue(any(name == "ensure_apt_updated" for name, *_ in runtime.calls))
        package_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "packages"]
        self.assertTrue(
            any(call.get("packages") == ["auditd", "audispd-plugins"] for call in package_calls)
        )
        service_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "service"]
        self.assertTrue(
            any(
                call.get("service") == "auditd"
                and call.get("running") is True
                and call.get("enabled") is True
                for call in service_calls
            )
        )

    def test_step20_writes_banner_and_restarts_ssh_when_changed(self):
        config = parse_setup_config({})
        step = next(item for item in build_steps(config) if item.id == "part4_step20_ssh_banner")
        runtime = _Runtime()
        step.register(runtime)

        line_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "line"]
        self.assertTrue(any(call.get("path") == "/etc/ssh/sshd_config" for call in line_calls))
        shell_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "shell"]
        self.assertTrue(any(call.get("commands") == ["sshd -t"] for call in shell_calls))
        service_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "service"]
        self.assertTrue(
            any(
                call.get("service") == "ssh" and call.get("restarted") is True
                for call in service_calls
            )
        )

    def test_steps23_and24_configure_sysctl_and_blacklist(self):
        """The remaining passive-security steps keep their kernel hardening."""
        config = parse_setup_config({})
        steps = {item.id: item for item in build_steps(config)}

        runtime23 = _Runtime()
        steps["part4_step23_dmesg_restrict"].register(runtime23)
        self.assertTrue(
            any(
                name == "sysctl"
                and kwargs.get("key") == "kernel.dmesg_restrict"
                and kwargs.get("value") == 1
                for name, kwargs in self._op_calls(runtime23)
            )
        )

        runtime24 = _Runtime()
        steps["part4_step24_blacklist_filesystems"].register(runtime24)
        self.assertTrue(
            any(
                name == "put" and kwargs.get("dest") == "/etc/modprobe.d/deploydash-blacklist.conf"
                for name, kwargs in self._op_calls(runtime24)
            )
        )
        self.assertTrue(
            any(
                name == "shell"
                and kwargs.get("commands")
                == [
                    "modprobe -r usb-storage || true",
                    "modprobe -r floppy || true",
                ]
                for name, kwargs in self._op_calls(runtime24)
            )
        )

    def test_step24_names_and_discloses_the_removable_storage_block(self):
        """The review plan must explain the physical-server impact and recovery path."""
        config = parse_setup_config({})
        step = next(
            item for item in build_steps(config) if item.id == "part4_step24_blacklist_filesystems"
        )

        self.assertEqual(step.title, "Disable removable storage drivers")
        self.assertEqual(
            step.notes,
            "USB drives will not mount while this block is active. To restore USB "
            "storage, remove /etc/modprobe.d/deploydash-blacklist.conf and run "
            "sudo modprobe usb-storage.",
        )
        self.assertEqual(
            [action.to_dict() for action in step.actions],
            [
                {
                    "id": "part4_step24_action_write_module_blacklist",
                    "label": "Block removable storage drivers",
                    "description": (
                        "Prevent USB mass-storage and floppy drivers from loading; "
                        "USB drives will not mount"
                    ),
                },
                {
                    "id": "part4_step24_action_unload_modules",
                    "label": "Unload removable storage drivers",
                    "description": (
                        "Apply the block immediately by unloading active USB storage "
                        "and floppy drivers"
                    ),
                },
            ],
        )

        runtime = _Runtime()
        step.register(runtime)
        blacklist_call = next(
            kwargs
            for name, kwargs in self._op_calls(runtime)
            if name == "put" and kwargs.get("dest") == "/etc/modprobe.d/deploydash-blacklist.conf"
        )
        rendered_blacklist = blacklist_call["src"].getvalue()
        self.assertNotIn("squashfs", rendered_blacklist)


if __name__ == "__main__":
    unittest.main()
