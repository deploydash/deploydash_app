import unittest

from orchestrator import engine_metrics_parsers


class _FakeOutput:
    def __init__(self, stdout_lines=None, stderr_lines=None):
        self.stdout_lines = stdout_lines or []
        self.stderr_lines = stderr_lines or []


class TestEngineMetricsParsers(unittest.TestCase):
    def test_parse_server_overview_metrics_output_includes_uptime(self):
        output = _FakeOutput(
            stdout_lines=[
                "",
                "garbage",
                "retention_days=90",
                "uptime_seconds=93784",
                "booted_at=2026-02-19T10:15:00Z",
                "cpu_idle=84.50",
                "load_avg=0.14 0.09 0.06",
                "mem=4096 2048 1024 1700",
                "swap=2048 128 1920",
                "disk_root=21474836480 10737418240 10737418240 50%",
                "inode_root=11%",
                "sysstat_files=27",
                "sysstat_oldest=/var/log/sysstat/sa20251122",
                "sysstat_newest=/var/log/sysstat/sa20260220",
                "net_dev=eth0,12.4,7.8",
                "disk_dev=nvme0n1,240.5,210.8,88.1",
            ]
        )

        metrics = engine_metrics_parsers._parse_server_overview_metrics_output(output)

        self.assertEqual(metrics["system"]["uptime_seconds"], 93784)
        self.assertEqual(metrics["system"]["booted_at"], "2026-02-19T10:15:00Z")
        self.assertAlmostEqual(metrics["cpu"]["usage_percent"], 15.5, places=2)
        self.assertEqual(metrics["memory"]["used_percent"], 50.0)
        self.assertEqual(metrics["memory"]["swap_used_percent"], 6.25)
        self.assertEqual(metrics["disk"]["root_free_gb"], 10.0)
        self.assertEqual(metrics["network"]["top_interface"]["name"], "eth0")
        self.assertEqual(metrics["io"]["top_device"]["name"], "nvme0n1")
        self.assertEqual(metrics["collection"]["retention_days"], 90)

    def test_parse_server_overview_metrics_output_ignores_invalid_uptime(self):
        output = _FakeOutput(
            stdout_lines=[
                "uptime_seconds=-1",
                "booted_at=",
            ]
        )

        metrics = engine_metrics_parsers._parse_server_overview_metrics_output(output)

        self.assertEqual(metrics["system"], {})


if __name__ == "__main__":
    unittest.main()
