import base64
import unittest

from orchestrator.app_parts.app_config import WorkerConfig
from orchestrator.app_parts.worker_runtime import (
    build_runtime_env_docker_flags,
    build_worker_runtime_command_spec,
    build_worker_runtime_command_specs,
    render_runtime_env_stdin,
)


class TestWorkerRuntimeBuilder(unittest.TestCase):
    def _worker(self, *, enabled=True):
        return WorkerConfig(
            id="queue-worker",
            name="Queue worker",
            start_command="npm run worker:queue",
            cpu_limit=1.0,
            memory_mb=512,
            disk_mb=2048,
            enabled=enabled,
            database_user=None,
            database_name=None,
            database_password=None,
            database_engine=None,
            database_host=None,
            database_port=None,
        )

    def test_render_runtime_env_stdin_renders_sorted_base64_lines(self):
        rendered = render_runtime_env_stdin({"BETA": "2", "ALPHA": "1"})
        self.assertEqual(
            rendered,
            (
                f"ALPHA\t{base64.b64encode(b'1').decode('ascii')}\n"
                f"BETA\t{base64.b64encode(b'2').decode('ascii')}\n"
            ),
        )

    def test_render_runtime_env_stdin_preserves_multiline_values(self):
        rendered = render_runtime_env_stdin({"ALPHA": "line1\nline2"})
        self.assertEqual(
            rendered,
            "ALPHA\tbGluZTEKbGluZTI=\n",
        )

    def test_build_runtime_env_docker_flags_name_only(self):
        flags = build_runtime_env_docker_flags({"BETA": "2", "ALPHA": "1"})
        self.assertEqual(flags, "-e ALPHA -e BETA")

    def test_build_runtime_env_docker_flags_with_values(self):
        flags = build_runtime_env_docker_flags(
            {"BETA": "2", "ALPHA": "1"},
            include_values=True,
        )
        self.assertEqual(flags, "-e ALPHA=1 -e BETA=2")

    def test_build_worker_runtime_command_specs_skips_disabled_workers(self):
        specs = build_worker_runtime_command_specs(
            project_slug="remix-blog",
            image_name="deploydash_remix-blog:latest",
            workers=[self._worker(enabled=False)],
            runtime_env_docker_flags="",
            primary_network_env_var="WORKER_NETWORK",
            include_disabled=False,
        )
        self.assertEqual(specs, [])

    def test_worker_run_command_uses_entrypoint_compatible_runtime_guard(self):
        specs = build_worker_runtime_command_specs(
            project_slug="remix-blog",
            image_name="deploydash_remix-blog:latest",
            workers=[self._worker()],
            runtime_env_docker_flags="",
            primary_network_env_var="WORKER_NETWORK",
        )
        self.assertEqual(len(specs), 1)
        self.assertNotIn("--security-opt no-new-privileges", specs[0].run_command)
        self.assertNotIn("--cap-drop ALL", specs[0].run_command)
        self.assertIn("--pids-limit 512", specs[0].run_command)
        self.assertIn(
            "--entrypoint /bin/sh deploydash_remix-blog:latest -lc 'npm run worker:queue'",
            specs[0].run_command,
        )
        self.assertNotIn(
            "deploydash_remix-blog:latest sh -lc",
            specs[0].run_command,
        )

    def test_worker_run_command_includes_readonly_volume_flags(self):
        spec = build_worker_runtime_command_spec(
            project_slug="remix-blog",
            image_name="deploydash_remix-blog:latest",
            worker=self._worker(),
            runtime_env_docker_flags="",
            primary_network_env_var="WORKER_NETWORK",
            readonly_volume_docker_flags="-v snapshot:/snapshots/catalog:ro",
        )
        self.assertIn("-v snapshot:/snapshots/catalog:ro", spec.run_command)

    def test_worker_run_command_includes_postgres_env_flags(self):
        worker = WorkerConfig(
            id="queue-worker",
            name="Queue worker",
            start_command="npm run worker:queue",
            cpu_limit=1.0,
            memory_mb=512,
            disk_mb=2048,
            enabled=True,
            database_user="app_user",
            database_name="app_db",
            database_password="secret",
            database_engine="postgres",
            database_host="postgres.internal",
            database_port=5432,
        )
        spec = build_worker_runtime_command_spec(
            project_slug="remix-blog",
            image_name="deploydash_remix-blog:latest",
            worker=worker,
            runtime_env_docker_flags="-e APP_ENV=production",
            primary_network_env_var="WORKER_NETWORK",
        )
        self.assertIn("-e APP_ENV=production", spec.run_command)
        self.assertIn("-e DATABASE_ENGINE=postgres", spec.run_command)
        self.assertIn("-e DATABASE_HOST=postgres.internal", spec.run_command)
        self.assertIn("-e DATABASE_PORT=5432", spec.run_command)
        self.assertIn("-e DATABASE_NAME=app_db", spec.run_command)
        self.assertIn("-e DATABASE_USER=app_user", spec.run_command)
        self.assertIn("-e DATABASE_PASSWORD=secret", spec.run_command)

    def test_worker_run_command_connects_trust_networks(self):
        spec = build_worker_runtime_command_spec(
            project_slug="remix-blog",
            image_name="deploydash_remix-blog:latest",
            worker=self._worker(),
            runtime_env_docker_flags="",
            primary_network_env_var="WORKER_NETWORK",
            trust_network_names=("deploydash_trust_alpha",),
        )
        self.assertIn("for TRUST_NETWORK in deploydash_trust_alpha", spec.run_command)
        self.assertIn('docker network create "${TRUST_NETWORK}"', spec.run_command)
        self.assertIn(
            'docker network connect "${TRUST_NETWORK}" deploydash_worker_remix-blog_queue-worker',
            spec.run_command,
        )

    def test_worker_run_command_ignores_invalid_extra_labels(self):
        """Avoid rendering an empty labels segment from invalid optional entries."""
        spec = build_worker_runtime_command_spec(
            project_slug="remix-blog",
            image_name="deploydash_remix-blog:latest",
            worker=self._worker(),
            runtime_env_docker_flags="",
            primary_network_env_var="WORKER_NETWORK",
            extra_labels={"": "ignored", "also_ignored": ""},
        )

        self.assertNotIn("--label =ignored", spec.run_command)
        self.assertNotIn("--label also_ignored=", spec.run_command)

    def test_release_worker_uses_versioned_container_and_live_labels(self):
        specs = build_worker_runtime_command_specs(
            project_slug="remix-blog",
            image_name="deploydash_remix-blog:latest",
            workers=[self._worker()],
            runtime_env_docker_flags="",
            primary_network_env_var="WORKER_NETWORK",
            release_id="20260831T234900Z",
            live_label="true",
        )

        self.assertEqual(len(specs), 1)
        self.assertEqual(
            specs[0].container_name,
            "deploydash_worker_remix-blog_queue-worker_20260831T234900Z",
        )
        self.assertIn(
            "--label deploydash.release_id=20260831T234900Z",
            specs[0].run_command,
        )
        self.assertIn("--label deploydash.live=true", specs[0].run_command)


if __name__ == "__main__":
    unittest.main()
