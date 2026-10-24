"""The commands and parsers the deploy and rollback paths call.

One of four files T-3.6.2 split `app_release_flow_test.py` into, along the
same seams as the production code. Fixtures and the base case are in
`tests/app_release_support.py`.
"""

from __future__ import annotations

import unittest
from types import SimpleNamespace
from unittest.mock import patch

from orchestrator.app_runtime_parts import release_lifecycle as engine_app_ops
from tests.app_release_support import (
    AppReleaseFlowTestCase,
    _FakeHost,
    _FakeOutput,
    base64,
    copy,
    empty_release_manifest,
    parse_app_config,
    replace,
)


class TestReleaseHelpers(AppReleaseFlowTestCase):
    def test_clone_update_fetches_selected_branch_for_both_deploy_key_modes(self):
        branch = "experiment/agentic-grounded-eval"
        expected_refspec = (
            "fetch --depth 1 --no-tags origin "
            "+refs/heads/experiment/agentic-grounded-eval:"
            "refs/remotes/origin/experiment/agentic-grounded-eval"
        )
        file_key_config = replace(self.app_config, branch=branch)
        inline_key_config = replace(
            self.app_config,
            branch=branch,
            deploy_private_key=(
                "-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----\n"
            ),
        )

        for app_config, expected_stdin in (
            (file_key_config, None),
            (inline_key_config, inline_key_config.deploy_private_key),
        ):
            command, stdin = engine_app_ops._build_clone_or_update_command(
                app_config,
            )

            self.assertIn(expected_refspec, command)
            self.assertNotIn("fetch --prune origin", command)
            self.assertIn("StrictHostKeyChecking=yes", command)
            self.assertIn("checkout -B experiment/agentic-grounded-eval", command)
            if expected_stdin is None:
                self.assertIsNone(stdin)
            else:
                self.assertEqual(stdin, f"{expected_stdin.rstrip()}\n")

    def test_run_remote_command_targets_manifest_and_commit_helpers(self):
        failing_session = SimpleNamespace(
            host=_FakeHost(status=False, output=_FakeOutput(stderr_lines=["boom"]))
        )
        result = engine_app_ops._run_remote_command(
            self.ctx,
            failing_session,
            "Sync repository",
            "echo fail",
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["details"], "remote command failed")

        successful_host = _FakeHost(
            status=True,
            output=_FakeOutput(stdout_lines=["abcdef1234567890"]),
        )
        successful_session = SimpleNamespace(host=successful_host)
        result = engine_app_ops._run_remote_command(
            self.ctx,
            successful_session,
            "Sync repository",
            "echo ok",
            stdin="TOKEN=1\n",
        )
        self.assertTrue(result["ok"])
        self.assertEqual(
            successful_host.calls[0]["kwargs"]["_stdin"],
            "TOKEN=1\n",
        )

        allowed_failure = engine_app_ops._run_remote_command(
            self.ctx,
            failing_session,
            "Probe candidate release at /up",
            "exit 1",
            allow_failure=True,
        )
        self.assertFalse(allowed_failure["ok"])
        self.assertEqual(allowed_failure["details"], "remote command failed")

        _manifest, previous_live = self._live_manifest()
        manifest_text = (
            '{"releases":[{"release_id":"%s","status":"live","web_container_name":"%s","image_name":"%s","worker_container_names":["%s"]}]}'  # noqa: UP031
            % (
                previous_live["release_id"],
                previous_live["web_container_name"],
                previous_live["image_name"],
                previous_live["worker_container_names"][0],
            )
        )
        manifest_ctx = replace(
            self.ctx,
            read_remote_file_text=lambda *args, **kwargs: manifest_text,
        )
        targets = engine_app_ops._release_runtime_targets(
            manifest_ctx,
            SimpleNamespace(),
            self.app_config,
        )
        self.assertEqual(targets["live_release_id"], previous_live["release_id"])
        self.assertFalse(targets["legacy"])

        empty_manifest_ctx = replace(
            self.ctx,
            read_remote_file_text=lambda *args, **kwargs: "",
        )
        with patch.object(
            engine_app_ops,
            "_legacy_container_is_running",
            return_value=True,
        ):
            legacy_targets = engine_app_ops._release_runtime_targets(
                empty_manifest_ctx,
                SimpleNamespace(),
                self.app_config,
            )
        self.assertTrue(legacy_targets["legacy"])
        self.assertTrue(legacy_targets["has_previous_live_route"])
        self.assertEqual(
            legacy_targets["web_container_name"],
            self.app_config.container_name,
        )

        with patch.object(
            engine_app_ops,
            "_legacy_container_is_running",
            return_value=False,
        ):
            first_release_targets = engine_app_ops._release_runtime_targets(
                empty_manifest_ctx,
                SimpleNamespace(),
                self.app_config,
            )
        self.assertFalse(first_release_targets["has_previous_live_route"])

        running_legacy_host = _FakeHost(status=True)
        stopped_legacy_host = _FakeHost(status=False)
        self.assertTrue(
            engine_app_ops._legacy_container_is_running(
                running_legacy_host,
                self.app_config.container_name,
            )
        )
        self.assertFalse(
            engine_app_ops._legacy_container_is_running(
                stopped_legacy_host,
                self.app_config.container_name,
            )
        )
        self.assertIn(
            self.app_config.container_name,
            running_legacy_host.calls[0]["command"],
        )
        self.assertEqual(running_legacy_host.calls[0]["timeout"], 10)
        self.assertTrue(running_legacy_host.calls[0]["sudo"])

        self.assertFalse(
            engine_app_ops._legacy_container_is_running(
                SimpleNamespace(),
                self.app_config.container_name,
            )
        )

        def _raise_missing_manifest_file(*args, **kwargs):
            raise RuntimeError(
                "Unable to read remote file: /tmp/release.json "
                "(cat:/tmp/release.json : No such file or directory)"
            )

        missing_manifest = engine_app_ops._load_release_manifest(
            replace(self.ctx, read_remote_file_text=_raise_missing_manifest_file),
            SimpleNamespace(),
            self.app_config,
        )
        self.assertEqual(missing_manifest, empty_release_manifest())

        def _raise_permission_denied(*args, **kwargs):
            raise RuntimeError("permission denied")

        with self.assertRaises(RuntimeError):
            engine_app_ops._load_release_manifest(
                replace(self.ctx, read_remote_file_text=_raise_permission_denied),
                SimpleNamespace(),
                self.app_config,
            )

        with patch.object(
            engine_app_ops,
            "_run_remote_command",
            return_value={
                "ok": True,
                "details": None,
                "output": _FakeOutput(
                    stdout_lines=["origin/main", "abcdef1234567890"],
                ),
            },
        ):
            commit_sha = engine_app_ops._resolve_commit_sha(
                self.ctx,
                self.session,
                self.app_config,
            )
        self.assertEqual(commit_sha, "abcdef1234567890")

        with patch.object(
            engine_app_ops,
            "_run_remote_command",
            return_value={
                "ok": False,
                "details": "bad",
                "output": _FakeOutput(),
            },
        ):
            self.assertIsNone(
                engine_app_ops._resolve_commit_sha(self.ctx, self.session, self.app_config)
            )

    def test_write_release_manifest_renders_and_executes_managed_write(self):
        host = _FakeHost(status=True)
        manifest = empty_release_manifest()
        manifest["releases"] = [
            {
                "release_id": "20260531t120000z-abcdef12",
                "status": "live",
                "runtime_env": {
                    "FEATURE_FLAG": "DD_TEST_SECRET_DO_NOT_LOG_7f4c",
                },
            }
        ]

        with patch.object(
            engine_app_ops,
            "render_manifest_write_command",
            return_value="write-manifest",
        ):
            status, output = engine_app_ops._write_release_manifest(
                host,
                self.app_config,
                manifest,
            )

        self.assertTrue(status)
        self.assertIsInstance(output, _FakeOutput)
        self.assertEqual(host.calls[0]["command"], "write-manifest")
        self.assertTrue(host.calls[0]["sudo"])
        self.assertEqual(
            host.calls[0]["kwargs"].get("_stdin"),
            '{"releases":[{"release_id":"20260531t120000z-abcdef12",'
            '"runtime_env":{"FEATURE_FLAG":"DD_TEST_SECRET_DO_NOT_LOG_7f4c"},'
            '"status":"live"}],"retention_success_limit":5,"schema_version":1}',
        )

    def test_build_worker_runtime_snapshot_retains_orphan_rows(self):
        snapshot = engine_app_ops._build_worker_runtime_snapshot(
            self.app_config,
            [
                {
                    "worker_id": "queue",
                    "container_name": "deploydash_worker_remix-blog_queue",
                    "state": "running",
                },
                {
                    "container_name": "deploydash_worker_remix-blog_unknown",
                    "state": "exited",
                },
                {
                    "worker_id": "removed",
                    "container_name": "deploydash_worker_remix-blog_removed",
                    "state": "running",
                },
            ],
        )

        self.assertEqual(snapshot["configured"][0]["runtime"]["state"], "running")
        self.assertEqual(
            [row["container_name"] for row in snapshot["orphans"]],
            [
                "deploydash_worker_remix-blog_removed",
                "deploydash_worker_remix-blog_unknown",
            ],
        )

    def test_build_release_run_command_injects_runtime_env_via_stdin(self):
        runtime = engine_app_ops._build_release_run_command(
            self.app_config,
            release_id="20260531t130000z-fedcba987654",
            image_name=self.app_config.release_image_name("20260531t130000z-fedcba987654"),
            live_label="false",
        )

        self.assertIn(
            "while IFS=\"$(printf '\\t')\" read -r key value_b64; do ",
            runtime["run_command"],
        )
        self.assertIn("base64 -d", runtime["run_command"])
        self.assertIn(
            f"--network-alias {self.app_config.release_upstream_name('20260531t130000z-fedcba987654')}",
            runtime["run_command"],
        )
        self.assertIn("-e NODE_ENV ", runtime["run_command"])
        self.assertIn(
            f"NODE_ENV\t{base64.b64encode(b'production').decode('ascii')}",
            runtime["runtime_env_stdin"],
        )

    def test_build_release_run_command_connects_configured_trust_networks(self):
        config_payload = {
            "settings": {
                "project_slug": "remix-blog",
                "repository_full_name": "acme/remix-blog",
                "primary_domain": "blog.example.com",
                "trust_network_names": ["deploydash_trust_alpha"],
            }
        }
        trusted_config = parse_app_config(config_payload, require_domain=True)

        runtime = engine_app_ops._build_release_run_command(
            trusted_config,
            release_id="20260531t130000z-fedcba987654",
            image_name=trusted_config.release_image_name("20260531t130000z-fedcba987654"),
            live_label="false",
        )

        self.assertIn(
            "for TRUST_NETWORK in deploydash_trust_alpha; do ",
            runtime["run_command"],
        )
        self.assertIn(
            'if [ "${TRUST_NETWORK}" != "${CADDY_NETWORK}" ]; then ',
            runtime["run_command"],
        )
        self.assertIn(
            'docker network connect "${TRUST_NETWORK}" '
            "deploydash_app_remix-blog_20260531t130000z-fedcba987654",
            runtime["run_command"],
        )

    def test_build_release_run_command_preserves_escaped_newline_env_values(self):
        encoded_config = parse_app_config(
            {
                "settings": {
                    "project_slug": "remix-blog",
                    "repository_full_name": "acme/remix-blog",
                    "primary_domain": "blog.example.com",
                    "runtime_env": {
                        "GOOGLE_APPLICATION_CREDENTIALS_JSON": "line1\\nline2",
                    },
                }
            },
            require_domain=True,
        )

        runtime = engine_app_ops._build_release_run_command(
            encoded_config,
            release_id="20260531t130000z-fedcba987654",
            image_name=encoded_config.release_image_name("20260531t130000z-fedcba987654"),
            live_label="false",
        )

        self.assertIn(
            "GOOGLE_APPLICATION_CREDENTIALS_JSON\tbGluZTFcbmxpbmUy",
            runtime["runtime_env_stdin"],
        )

    def test_route_cleanup_helpers_remove_or_restore_only_current_project_route(self):
        calls = []
        responses = [
            {"ok": True, "details": None, "output": _FakeOutput()},
            {"ok": True, "details": None, "output": _FakeOutput()},
            {"ok": True, "details": None, "output": _FakeOutput()},
            {"ok": True, "details": None, "output": _FakeOutput()},
        ]

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            calls.append((label, command, kwargs))
            return responses.pop(0)

        with (
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                side_effect=fake_run_remote_command,
            ),
            patch.object(
                engine_app_ops,
                "_build_caddy_apply_command",
                return_value="validate-and-reload-caddy",
            ),
        ):
            removed = engine_app_ops._restore_or_remove_caddy_route(
                self.ctx,
                self.session,
                self.app_config,
            )
            missing_route_removed = engine_app_ops._restore_or_remove_caddy_route(
                self.ctx,
                self.session,
                self.app_config,
            )

        self.assertEqual(removed["action"], "removed")
        self.assertEqual(missing_route_removed["action"], "removed")
        self.assertEqual(
            [label for label, _, _ in calls],
            [
                "Remove candidate Caddy route",
                "Reload Caddy after route cleanup",
                "Remove candidate Caddy route",
                "Reload Caddy after route cleanup",
            ],
        )
        remove_commands = [
            command for label, command, _ in calls if label == "Remove candidate Caddy route"
        ]
        self.assertEqual(
            remove_commands,
            [
                f"rm -f {self.app_config.caddy_snippet_path}",
                f"rm -f {self.app_config.caddy_snippet_path}",
            ],
        )
        self.assertTrue(all(kwargs["allow_failure"] for _, _, kwargs in calls))

        restored_targets = []
        with patch.object(
            engine_app_ops,
            "_write_caddy_route",
            side_effect=lambda ctx, session, app_config, *, target_container_name, emit=None: (
                restored_targets.append(target_container_name) or {"ok": True, "details": None}
            ),
        ):
            restored = engine_app_ops._restore_or_remove_caddy_route(
                self.ctx,
                self.session,
                self.app_config,
                previous_route_target="previous-release",
            )

        self.assertEqual(restored["action"], "restored")
        self.assertEqual(restored_targets, ["previous-release"])

        with patch.object(
            engine_app_ops,
            "_write_caddy_route",
            return_value={"ok": False, "details": "reload failed"},
        ):
            failed_restore = engine_app_ops._restore_or_remove_caddy_route(
                self.ctx,
                self.session,
                self.app_config,
                previous_route_target="previous-release",
            )

        self.assertFalse(failed_restore["ok"])
        self.assertEqual(failed_restore["action"], "failed")

        with patch.object(
            engine_app_ops,
            "_run_remote_command",
            return_value={"ok": False, "details": "remove failed"},
        ):
            failed_remove = engine_app_ops._restore_or_remove_caddy_route(
                self.ctx,
                self.session,
                self.app_config,
            )
        self.assertFalse(failed_remove["ok"])
        self.assertEqual(failed_remove["action"], "failed")

        with (
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                side_effect=[
                    {"ok": True, "details": None},
                    {"ok": False, "details": "reload failed"},
                ],
            ),
            patch.object(
                engine_app_ops,
                "_build_caddy_apply_command",
                return_value="validate-and-reload-caddy",
            ),
        ):
            failed_reload = engine_app_ops._restore_or_remove_caddy_route(
                self.ctx,
                self.session,
                self.app_config,
            )
        self.assertFalse(failed_reload["ok"])
        self.assertEqual(failed_reload["action"], "failed")

        self.assertEqual(
            engine_app_ops._route_cleanup_extra(failed_restore),
            {
                "route_cleanup_status": "failed",
                "route_cleanup_details": "reload failed",
            },
        )
        self.assertEqual(
            engine_app_ops._route_cleanup_extra(None),
            {"route_cleanup_status": "failed", "route_cleanup_details": None},
        )

    def test_cleanup_failed_release_after_route_cutover_preserves_cleanup_error(self):
        manifest, previous_live = self._live_manifest()
        manifest_writes = []
        remove_calls = []

        with (
            patch.object(
                engine_app_ops,
                "_restore_or_remove_caddy_route",
                side_effect=RuntimeError("Caddy route cleanup failed"),
            ),
            patch.object(
                engine_app_ops,
                "_remove_release_runtime",
                side_effect=lambda *args, **kwargs: remove_calls.append(kwargs) or {"ok": True},
            ),
            patch.object(
                engine_app_ops,
                "_write_release_manifest",
                side_effect=lambda host, app_config, payload: manifest_writes.append(
                    copy.deepcopy(payload)
                ),
            ),
        ):
            result = engine_app_ops._cleanup_failed_release_after_route_cutover(
                self.ctx,
                self.session,
                self.app_config,
                manifest=manifest,
                release_id=previous_live["release_id"],
                rollback_from_release_id=previous_live["release_id"],
                image_name="deploydash/remix-blog:candidate",
                rollback_reason="post_cutover_stabilization_failed",
            )

        self.assertFalse(result["route_cleanup"]["ok"])
        self.assertEqual(result["route_cleanup"]["action"], "failed")
        self.assertEqual(
            result["route_cleanup"]["details"],
            "Caddy route cleanup failed",
        )
        self.assertEqual(len(remove_calls), 1)
        failed_release = next(
            entry
            for entry in manifest_writes[-1]["releases"]
            if entry["release_id"] == previous_live["release_id"]
        )
        self.assertEqual(
            failed_release["rollback_reason"],
            "post_cutover_stabilization_failed",
        )

    def test_parse_sqlite_meta_output_ignores_invalid_volume_size(self):
        payload = engine_app_ops._parse_sqlite_meta_output(
            _FakeOutput(
                stdout_lines=[
                    "SQLITE_META_ENABLED=true",
                    "SQLITE_META_VOLUME_NAME=deploydash_sqlite_demo",
                    "SQLITE_META_MOUNT_PATH=/data",
                    "SQLITE_META_FILE_NAME=main.db",
                    "SQLITE_META_DATABASE_PATH=/data/main.db",
                    "SQLITE_META_DATABASE_URL=sqlite:////data/main.db",
                    "SQLITE_META_VOLUME_SIZE_KB=abc",
                ]
            )
        )

        self.assertTrue(payload["enabled"])
        self.assertIsNone(payload["volume_size_bytes"])

        negative = engine_app_ops._parse_sqlite_meta_output(
            _FakeOutput(
                stdout_lines=[
                    "SQLITE_META_ENABLED=true",
                    "SQLITE_META_VOLUME_SIZE_KB=-1",
                ]
            )
        )
        absent = engine_app_ops._parse_sqlite_meta_output(
            _FakeOutput(stdout_lines=["SQLITE_META_ENABLED=true"])
        )
        self.assertIsNone(negative["volume_size_bytes"])
        self.assertIsNone(absent["volume_size_bytes"])

    def test_parse_sqlite_meta_output_skips_invalid_meta_lines_and_disabled_state(self):
        payload = engine_app_ops._parse_sqlite_meta_output(
            _FakeOutput(
                stdout_lines=[
                    "SQLITE_META_ENABLED=false",
                    "SQLITE_META_INVALID_LINE",
                ]
            )
        )

        self.assertEqual(payload, {"enabled": False})

    def test_collect_release_runtime_logs_runs_managed_docker_logs_command(self):
        calls = []

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            calls.append(
                {
                    "session": session,
                    "label": label,
                    "command": command,
                    "kwargs": kwargs,
                }
            )
            return {"ok": True, "details": None}

        with patch.object(
            engine_app_ops,
            "_run_remote_command",
            side_effect=fake_run_remote_command,
        ):
            result = engine_app_ops._collect_release_runtime_logs(
                self.ctx,
                self.session,
                container_name="deploydash_app_demo",
                tail_lines=25,
            )

        self.assertTrue(result["ok"])
        self.assertEqual(calls[0]["label"], "Collect candidate release runtime logs")
        self.assertIn("docker logs --tail 25 --timestamps deploydash_app_demo", calls[0]["command"])
        self.assertTrue(calls[0]["kwargs"]["allow_failure"])

    def test_runtime_log_excerpt_uses_recent_unique_sanitized_lines(self):
        """Derive legacy excerpts from the canonical selected evidence only."""
        sanitizing_ctx = replace(
            self.ctx,
            sanitize_message=lambda value: value.replace("secret-token", "***"),
        )
        evidence = engine_app_ops._failure_evidence_from_result(
            sanitizing_ctx,
            phase="candidate_readiness",
            source="candidate_runtime",
            result={
                "output": _FakeOutput(
                    stdout_lines=[
                        "first line",
                        "duplicate line",
                        "duplicate line",
                        "secret-token failed",
                        "",
                    ],
                    stderr_lines=["stderr line"],
                ),
            },
        )
        excerpt = engine_app_ops._runtime_log_excerpt_from_evidence(
            evidence,
            max_lines=5,
        )

        self.assertEqual(
            excerpt,
            [
                "stderr line",
                "first line",
                "duplicate line",
                "*** failed",
            ],
        )

        evidence = engine_app_ops._failure_evidence_from_result(
            sanitizing_ctx,
            phase="candidate_readiness",
            source="candidate_runtime",
            result={
                "output": _FakeOutput(
                    stdout_lines=["first line", "second line"],
                    stderr_lines=["third line", "fourth line"],
                ),
            },
        )
        self.assertEqual(
            engine_app_ops._runtime_log_excerpt_from_evidence(
                evidence,
                max_lines=3,
            ),
            ["fourth line", "first line", "second line"],
        )

    def test_failure_evidence_from_exception_is_secret_safe(self):
        """Sanitize an abrupt transport exception before it crosses the boundary."""
        sanitizing_ctx = replace(
            self.ctx,
            sanitize_message=lambda value: str(value).replace("secret-token", "***"),
        )
        evidence = engine_app_ops._failure_evidence_from_result(
            sanitizing_ctx,
            phase="build",
            source="failed_operation",
            result={
                "ok": False,
                "exception": "connection reset with secret-token",
            },
        )

        self.assertEqual(evidence.phase, "build")
        self.assertEqual(evidence.source, "exception")
        self.assertEqual(evidence.lines, ("connection reset with ***",))

        probe_only = engine_app_ops._failure_evidence_from_result(
            sanitizing_ctx,
            phase="candidate_readiness",
            source="candidate_runtime",
            result={"ok": False},
            probe=engine_app_ops.FailureEvidenceProbe(path="/up", http_status=503),
            probe_source="candidate_probe",
        )
        self.assertEqual(probe_only.source, "candidate_probe")
        self.assertEqual(probe_only.completeness, "diagnostic")

    def test_readiness_failure_summary_has_fallback_without_logs(self):
        self.assertEqual(
            engine_app_ops._readiness_failure_summary([]),
            "Readiness failed. The app container did not answer the health checks.",
        )

        self.assertEqual(
            engine_app_ops._readiness_failure_summary(["last line", "  "]),
            "Readiness failed. Last runtime log: last line",
        )
        self.assertEqual(
            engine_app_ops._runtime_log_excerpt_from_evidence(
                SimpleNamespace(lines=("ignored",)),
                max_lines=0,
            ),
            [],
        )

    def test_worker_verification_can_capture_the_failed_operation(self):
        """Return the failed command only when the release caller requests evidence."""
        results = iter(
            [
                {"ok": True, "details": None},
                {"ok": False, "details": "worker failed"},
            ]
        )
        with patch.object(
            engine_app_ops,
            "_run_remote_command",
            side_effect=lambda *args, **kwargs: next(results),
        ):
            result = engine_app_ops._verify_release_workers_running(
                self.ctx,
                self.session,
                worker_container_names=["worker-a", "worker-b"],
                capture_evidence=True,
            )

        self.assertEqual(result["worker_container_name"], "worker-b")
        self.assertEqual(result["result"]["details"], "worker failed")

    def test_worker_status_parser_ignores_non_data_lines(self):
        self.assertEqual(
            engine_app_ops._worker_container_name("project", "queue"),
            "deploydash_worker_project_queue",
        )
        self.assertEqual(
            engine_app_ops._parse_worker_status_lines(
                [
                    None,
                    " ",
                    "STAT|incomplete",
                    "META|incomplete",
                    "META|deploydash_worker_project_queue_20260808|running|Up|abc123",
                ],
                "project",
            ),
            [
                {
                    "container_name": "deploydash_worker_project_queue_20260808",
                    "container_id": "abc123",
                    "worker_id": "queue",
                    "state": "running",
                    "status": "Up",
                    "running": True,
                    "container_status": {
                        "present": True,
                        "docker_state": "running",
                        "running": True,
                        "health": "none",
                        "exit_code": None,
                        "image": "",
                        "started_at": "",
                        "effective_status": "ready",
                        "readiness": {"status": "not_checked", "detail": ""},
                    },
                },
            ],
        )
        foreign = engine_app_ops._parse_worker_status_lines(
            ["META|foreign_worker|running|Up|abc123"],
            "project",
        )
        self.assertIsNone(foreign[0]["worker_id"])


if __name__ == "__main__":
    unittest.main()
