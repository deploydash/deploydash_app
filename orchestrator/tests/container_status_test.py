import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from orchestrator.container_status import (
    bind_service_readiness_check_shell,
    caddy_service_readiness_check_shell,
    container_process_running_check_shell,
    container_status_from_payload,
    container_status_from_worker_row,
    normalize_container_status,
    postgres_service_readiness_check_shell,
    postgres_service_readiness_wait_shell,
    worker_process_check_shell,
)


class ContainerStatusTest(unittest.TestCase):
    def test_normalizes_core_effective_statuses(self):
        self.assertEqual(
            normalize_container_status(present=False)["effective_status"],
            "missing",
        )
        self.assertEqual(
            normalize_container_status(
                present=True,
                docker_state="exited",
                running=False,
                exit_code=1,
            )["effective_status"],
            "stopped",
        )
        self.assertEqual(
            normalize_container_status(
                present=True,
                docker_state="restarting",
                running=True,
            )["effective_status"],
            "restarting",
        )
        self.assertEqual(
            normalize_container_status(
                present=True,
                docker_state="running",
                running=True,
                health="starting",
            )["effective_status"],
            "starting",
        )
        self.assertEqual(
            normalize_container_status(
                present=True,
                docker_state="running",
                running=True,
                health="unhealthy",
            )["effective_status"],
            "unhealthy",
        )
        self.assertEqual(
            normalize_container_status(
                present=True,
                docker_state="running",
                running=True,
                health="healthy",
                readiness_status="ready",
            )["effective_status"],
            "ready",
        )

    def test_readiness_failure_overrides_running_and_healthy_container(self):
        status = normalize_container_status(
            present=True,
            docker_state="running",
            running=True,
            health="healthy",
            readiness_status="unhealthy",
            readiness_detail="pg_isready failed",
        )

        self.assertEqual(status["effective_status"], "unhealthy")
        self.assertEqual(status["readiness"]["detail"], "pg_isready failed")

    def test_builds_status_from_key_value_payload(self):
        status = container_status_from_payload(
            {
                "postgres_container_present": "1",
                "postgres_container_docker_state": "running",
                "postgres_container_running": "true",
                "postgres_container_health": "healthy",
                "postgres_container_exit_code": "0",
                "postgres_container_image": "deploydash/postgres-ext:17",
                "postgres_container_started_at": "2026-07-01T12:00:00Z",
                "postgres_container_readiness_status": "ready",
            },
            "postgres_container",
        )

        self.assertTrue(status["present"])
        self.assertTrue(status["running"])
        self.assertEqual(status["image"], "deploydash/postgres-ext:17")
        self.assertEqual(status["effective_status"], "ready")

    def test_worker_row_derives_health_from_docker_status_text(self):
        status = container_status_from_worker_row(
            {
                "state": "running",
                "status": "Up 5 seconds (unhealthy)",
            },
        )

        self.assertEqual(status["health"], "unhealthy")
        self.assertEqual(status["effective_status"], "unhealthy")

    def test_shared_shell_helpers_express_service_readiness(self):
        self.assertIn(
            "docker inspect -f '{{.State.Running}}' deploydash_worker",
            worker_process_check_shell("deploydash_worker"),
        )
        self.assertEqual(
            worker_process_check_shell("deploydash_worker"),
            container_process_running_check_shell("deploydash_worker"),
        )

        caddy = caddy_service_readiness_check_shell("deploydash_caddy")
        self.assertIn("docker inspect -f '{{.State.Running}}'", caddy)
        self.assertIn(
            "caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile",
            caddy,
        )

        bind = bind_service_readiness_check_shell("deploydash_bind9")
        self.assertIn("pgrep -x named", bind)
        self.assertIn("named-checkconf /etc/bind/named.conf", bind)

        postgres = postgres_service_readiness_check_shell(
            "deploydash_postgres",
            '"$POSTGRES_USER"',
        )
        self.assertIn(
            'pg_isready -U "$POSTGRES_USER" -d postgres',
            postgres,
        )

    def test_postgres_readiness_wait_retries_until_the_service_is_ready(self):
        command = postgres_service_readiness_wait_shell(
            "deploydash_postgres",
            "deploydash",
            max_attempts=3,
            delay_seconds=0,
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            docker = Path(temp_dir) / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                'case "$1" in\n'
                "  inspect) echo true; exit 0 ;;\n"
                "  exec)\n"
                '    count=$(cat "$TEST_COUNTER" 2>/dev/null || echo 0)\n'
                "    count=$((count+1))\n"
                '    echo "$count" > "$TEST_COUNTER"\n'
                '    [ "$count" -ge 2 ]\n'
                "    ;;\n"
                "  logs) exit 0 ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)
            counter = Path(temp_dir) / "counter"
            result = subprocess.run(
                ["sh", "-c", command],
                capture_output=True,
                text=True,
                check=False,
                env={
                    **os.environ,
                    "PATH": f"{temp_dir}:{os.environ['PATH']}",
                    "TEST_COUNTER": str(counter),
                },
            )
            attempts = counter.read_text(encoding="utf-8").strip()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(attempts, "2")

    def test_postgres_readiness_wait_fails_after_the_attempt_limit(self):
        command = postgres_service_readiness_wait_shell(
            "deploydash_postgres",
            "deploydash",
            max_attempts=2,
            delay_seconds=0,
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            docker = Path(temp_dir) / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                'case "$1" in\n'
                "  inspect) exit 1 ;;\n"
                "  logs) echo diagnostics >&2; exit 0 ;;\n"
                "esac\n"
                "exit 1\n",
                encoding="utf-8",
            )
            docker.chmod(0o755)
            result = subprocess.run(
                ["sh", "-c", command],
                capture_output=True,
                text=True,
                check=False,
                env={
                    **os.environ,
                    "PATH": f"{temp_dir}:{os.environ['PATH']}",
                },
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed after 2 attempts", result.stderr)
        self.assertIn("diagnostics", result.stderr)

    def test_postgres_readiness_wait_rejects_invalid_limits(self):
        with self.assertRaisesRegex(ValueError, "positive integer"):
            postgres_service_readiness_wait_shell(
                "postgres",
                "deploydash",
                max_attempts=0,
            )
        with self.assertRaisesRegex(ValueError, "non-negative integer"):
            postgres_service_readiness_wait_shell(
                "postgres",
                "deploydash",
                delay_seconds=-1,
            )
        # Bools are ints to isinstance but render as True/False in shell,
        # which the [ -le ] comparison and sleep both reject.
        with self.assertRaisesRegex(ValueError, "positive integer"):
            postgres_service_readiness_wait_shell(
                "postgres",
                "deploydash",
                max_attempts=True,
            )
        with self.assertRaisesRegex(ValueError, "non-negative integer"):
            postgres_service_readiness_wait_shell(
                "postgres",
                "deploydash",
                delay_seconds=False,
            )


if __name__ == "__main__":
    unittest.main()
