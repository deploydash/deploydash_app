import unittest

from orchestrator.setup_parts.part2_stability import build_steps
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
        if name == "put":
            return _OperationMeta(did_change=True)
        return _OperationMeta(did_change=False)


class TestSetupPart2Stability(unittest.TestCase):
    @staticmethod
    def _op_calls(runtime):
        return [entry for entry in runtime.calls if len(entry) == 2]

    def test_part2_includes_sysstat_retention_step(self):
        config = parse_setup_config({})
        steps = build_steps(config)

        step_ids = [step.id for step in steps]
        self.assertEqual(
            step_ids,
            [
                "part2_step7_swap",
                "part2_step8_journald_limits",
                "part2_step9_kernel_params",
                "part2_step10_tooling",
                "part2_step11_sysstat_metrics",
                "part2_step12_security_updates",
            ],
        )

    def test_step8_restarts_journald_via_service_operation(self):
        config = parse_setup_config({})
        step = next(
            item for item in build_steps(config) if item.id == "part2_step8_journald_limits"
        )
        runtime = _Runtime()
        step.register(runtime)

        service_calls = [kwargs for name, kwargs in runtime.calls if name == "service"]
        self.assertTrue(
            any(
                call.get("service") == "systemd-journald" and call.get("restarted") is True
                for call in service_calls
            )
        )

    def test_step7_provisions_swap(self):
        config = parse_setup_config({})
        step = next(item for item in build_steps(config) if item.id == "part2_step7_swap")
        runtime = _Runtime()
        step.register(runtime)

        shell_call = next(kwargs for name, kwargs in self._op_calls(runtime) if name == "shell")
        self.assertEqual(len(shell_call["commands"]), 1)
        self.assertIn("/swapfile", shell_call["commands"][0])
        self.assertIn("MemTotal", shell_call["commands"][0])
        self.assertIn("df --output=avail -B1 /", shell_call["commands"][0])
        self.assertNotIn("dd if=/dev/zero", shell_call["commands"][0])

    def test_step9_persists_kernel_sysctls(self):
        config = parse_setup_config({})
        step = next(item for item in build_steps(config) if item.id == "part2_step9_kernel_params")
        runtime = _Runtime()
        step.register(runtime)

        sysctl_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "sysctl"]
        self.assertEqual(
            [(call["key"], call["value"]) for call in sysctl_calls],
            [("vm.swappiness", 10), ("net.core.somaxconn", 65535)],
        )
        self.assertTrue(
            all(
                call.get("persist_file") == "/etc/sysctl.d/99-deploydash-performance.conf"
                for call in sysctl_calls
            )
        )
        line_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "line"]
        self.assertEqual(
            line_calls,
            [
                {
                    "path": "/etc/sysctl.d/99-deploydash-performance.conf",
                    "line": r"^\s*fs\.file-max\s*=.*$",
                    "present": False,
                }
            ],
        )
        shell_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "shell"]
        self.assertEqual(len(shell_calls), 1)
        self.assertIn(
            "sysctl -w fs.file-max=9223372036854775807",
            shell_calls[0]["commands"][0],
        )
        self.assertNotIn("fs.file-max", "\n".join(step.commands))
        self.assertEqual(
            [action.id for action in step.actions],
            [
                "part2_step9_action_tune_swappiness",
                "part2_step9_action_tune_somaxconn",
            ],
        )

    def test_step10_uses_server_service_for_fail2ban(self):
        config = parse_setup_config({})
        step = next(item for item in build_steps(config) if item.id == "part2_step10_tooling")
        runtime = _Runtime()
        step.register(runtime)

        put_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "put"]
        self.assertTrue(any(call.get("dest") == "/etc/fail2ban/jail.local" for call in put_calls))
        jail_payload = next(
            call["src"].getvalue()
            for call in put_calls
            if call.get("dest") == "/etc/fail2ban/jail.local"
        )
        self.assertIn("backend = systemd", jail_payload)
        self.assertIn("bantime = 1h", jail_payload)
        self.assertIn("findtime = 10m", jail_payload)
        self.assertIn("maxretry = 5", jail_payload)
        self.assertIn("[sshd]", jail_payload)

        service_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "service"]
        self.assertTrue(
            any(
                call.get("service") == "fail2ban" and call.get("restarted") is True
                for call in service_calls
            )
        )
        self.assertTrue(
            any(
                call.get("service") == "fail2ban"
                and call.get("running") is True
                and call.get("enabled") is True
                for call in service_calls
            )
        )

    def test_step11_configures_sysstat_with_line_and_systemd_services(self):
        config = parse_setup_config({})
        step = next(
            item for item in build_steps(config) if item.id == "part2_step11_sysstat_metrics"
        )
        runtime = _Runtime()
        step.register(runtime)

        line_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "line"]
        self.assertEqual(len(line_calls), 3)
        self.assertTrue(any(call.get("path") == "/etc/default/sysstat" for call in line_calls))
        self.assertTrue(any(call.get("path") == "/etc/sysstat/sysstat" for call in line_calls))

        service_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "service"]
        self.assertTrue(
            any(call.get("service") == "sysstat-collect.timer" for call in service_calls)
        )
        self.assertTrue(
            any(call.get("service") == "sysstat-summary.timer" for call in service_calls)
        )

    def test_step12_enables_unattended_upgrades_and_apt_timers(self):
        config = parse_setup_config({})
        step = next(
            item for item in build_steps(config) if item.id == "part2_step12_security_updates"
        )
        runtime = _Runtime()
        step.register(runtime)

        package_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "packages"]
        self.assertTrue(
            any(
                call.get("packages") == ["unattended-upgrades", "apt-listchanges"]
                for call in package_calls
            )
        )

        put_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "put"]
        self.assertEqual(len(put_calls), 2)
        self.assertTrue(
            any(call.get("dest") == "/etc/apt/apt.conf.d/20auto-upgrades" for call in put_calls)
        )
        self.assertTrue(
            any(
                call.get("dest") == "/etc/apt/apt.conf.d/52unattended-upgrades-local"
                for call in put_calls
            )
        )

        service_calls = [kwargs for name, kwargs in self._op_calls(runtime) if name == "service"]
        self.assertTrue(any(call.get("service") == "apt-daily.timer" for call in service_calls))
        self.assertTrue(
            any(call.get("service") == "apt-daily-upgrade.timer" for call in service_calls)
        )


if __name__ == "__main__":
    unittest.main()
