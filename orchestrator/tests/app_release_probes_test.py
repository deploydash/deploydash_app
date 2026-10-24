"""Candidate, routed and public-health probes -- the checks that gate traffic.

One of four files T-3.6.2 split `app_release_flow_test.py` into, along the
same seams as the production code. Fixtures and the base case are in
`tests/app_release_support.py`.
"""

from __future__ import annotations

import unittest
from unittest.mock import patch

from orchestrator.app_runtime_parts import release_lifecycle as engine_app_ops
from tests.app_release_support import (
    AppReleaseFlowTestCase,
    _FakeOutput,
    append_or_replace_release,
    empty_release_manifest,
    parse_app_config,
    release_entry_from_config,
)


class TestReleaseProbes(AppReleaseFlowTestCase):
    def test_release_helper_commands_cover_probe_route_and_cleanup_paths(self):
        candidate_commands = engine_app_ops._candidate_probe_commands(
            self.app_config,
            container_name="deploydash_app_remix-blog_candidate",
        )
        self.assertEqual(len(candidate_commands), 3)
        self.assertIn("http://${APP_IP}:3000/up", candidate_commands[0])
        self.assertIn("grep -m1 -v '^$'", candidate_commands[0])
        self.assertIn(engine_app_ops._RELEASE_PROBE_MARKER, candidate_commands[0])
        self.assertIn("CURL_EXIT", candidate_commands[0])

        routed_commands = engine_app_ops._routed_probe_commands(self.app_config)
        self.assertEqual(len(routed_commands), 3)
        self.assertIn("-L", routed_commands[0])
        self.assertIn("blog.example.com:443:127.0.0.1", routed_commands[0])
        self.assertIn("http://blog.example.com/up", routed_commands[0])
        self.assertNotIn("exit 0", routed_commands[0])
        self.assertIn(engine_app_ops._RELEASE_PROBE_MARKER, routed_commands[0])
        self.assertIn("CURL_EXIT", routed_commands[0])

        public_health_command = engine_app_ops._public_health_probe_command(self.app_config)
        self.assertIn("http://blog.example.com/", public_health_command)
        self.assertIn(engine_app_ops._PUBLIC_HEALTH_MARKER, public_health_command)
        self.assertIn("-o /dev/null", public_health_command)
        self.assertNotIn("curl -k", public_health_command)

        app_config_without_domain = parse_app_config(
            {
                "settings": {
                    "project_slug": "remix-blog",
                    "repository_full_name": "acme/remix-blog",
                    "primary_domain": None,
                }
            },
            require_domain=False,
        )
        self.assertEqual(
            engine_app_ops._routed_probe_commands(app_config_without_domain),
            [],
        )

        commands = []

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            commands.append((label, command))
            return {"ok": True, "details": None, "output": _FakeOutput()}

        with patch.object(
            engine_app_ops,
            "_run_remote_command",
            side_effect=fake_run_remote_command,
        ):
            engine_app_ops._set_release_live_labels(
                self.ctx,
                self.session,
                web_container_name="web-live",
                worker_container_names=["worker-a"],
                live_value="true",
            )
            engine_app_ops._remove_release_runtime(
                self.ctx,
                self.session,
                web_container_name="web-live",
                worker_container_names=["worker-a"],
                image_name="deploydash_remix-blog:release-1",
                remove_image=True,
            )
            engine_app_ops._stop_release_runtime(
                self.ctx,
                self.session,
                web_container_name="web-old",
                worker_container_names=["worker-old"],
            )

        self.assertEqual(
            commands[0],
            (
                "Remove release runtime",
                "docker rm -f web-live >/dev/null 2>&1 || true; "
                "docker rm -f worker-a >/dev/null 2>&1 || true; "
                "docker image rm deploydash_remix-blog:release-1 "
                ">/dev/null 2>&1 || true",
            ),
        )
        self.assertEqual(
            commands[1],
            (
                "Stop previous release runtime",
                "docker rm -f web-old >/dev/null 2>&1 || true; "
                "docker rm -f worker-old >/dev/null 2>&1 || true",
            ),
        )

        skipped = engine_app_ops._set_release_live_labels(
            self.ctx,
            self.session,
            web_container_name="web-live",
            worker_container_names=["worker-a"],
            live_value="true",
        )
        self.assertTrue(skipped["ok"])

    def test_release_probe_evidence_contains_only_safe_status_facts(self):
        """Parse path and curl status without exposing any HTTP response content."""
        marker = engine_app_ops._RELEASE_PROBE_MARKER
        result = {
            "output": _FakeOutput(
                stdout_lines=[f"{marker}/health|22|503", "private response body"],
            )
        }

        probe = engine_app_ops._release_probe_from_result(result, fallback_path="/up")

        self.assertEqual(probe.path, "/health")
        self.assertEqual(probe.curl_exit, 22)
        self.assertEqual(probe.http_status, 503)
        self.assertNotIn("private response body", repr(probe))

        malformed = engine_app_ops._release_probe_from_result(
            {
                "output": _FakeOutput(
                    stdout_lines=[
                        f"{marker}bad",
                        f"{marker}/up|not-an-int|503",
                        f"{marker}/private|22|503",
                    ]
                )
            },
            fallback_path="/up",
        )
        self.assertEqual(malformed.path, "/up")
        self.assertIsNone(malformed.curl_exit)
        self.assertIsNone(malformed.http_status)

        captured_invalid_path = engine_app_ops._probe_routed_release(
            self.ctx,
            self.session,
            self.app_config,
            path="/not-routed",
            capture_evidence=True,
        )
        self.assertIsNone(captured_invalid_path["result"])
        self.assertIsNone(captured_invalid_path["probe"])

    def test_public_health_results_are_normalized_without_response_content(self):
        marker = engine_app_ops._PUBLIC_HEALTH_MARKER
        with patch.object(
            engine_app_ops,
            "utc_now_iso",
            return_value="2026-08-06T12:00:00Z",
        ):
            healthy = engine_app_ops._public_health_from_output(
                self.app_config,
                _FakeOutput(stdout_lines=[f"{marker}0|204"]),
            )
            http_failure = engine_app_ops._public_health_from_output(
                self.app_config,
                _FakeOutput(stdout_lines=[f"{marker}0|500"]),
            )
            invalid_status = engine_app_ops._public_health_from_output(
                self.app_config,
                _FakeOutput(stdout_lines=[f"{marker}0|999"]),
            )
            malformed = engine_app_ops._public_health_from_output(
                self.app_config,
                _FakeOutput(stdout_lines=[f"{marker}bad"]),
            )
            after_noise = engine_app_ops._public_health_from_output(
                self.app_config,
                _FakeOutput(stdout_lines=["curl notice", f"{marker}0|200"]),
            )
            invalid_exit = engine_app_ops._public_health_from_output(
                self.app_config,
                _FakeOutput(stdout_lines=[f"{marker}bad|200"]),
            )
            non_numeric_status = engine_app_ops._public_health_from_output(
                self.app_config,
                _FakeOutput(stdout_lines=[f"{marker}0|bad"]),
            )

        self.assertEqual(healthy["status"], "healthy")
        self.assertEqual(healthy["http_status"], 204)
        self.assertEqual(healthy["path"], "/")
        self.assertEqual(healthy["checked_at"], "2026-08-06T12:00:00Z")
        self.assertIsNone(healthy["error"])
        self.assertEqual(http_failure["status"], "unhealthy")
        self.assertEqual(http_failure["http_status"], 500)
        self.assertEqual(http_failure["error"], "http_error")
        self.assertIsNone(invalid_status["http_status"])
        self.assertEqual(invalid_status["error"], "http_error")
        self.assertEqual(malformed["status"], "unknown")
        self.assertEqual(malformed["error"], "result_unavailable")
        self.assertEqual(after_noise["status"], "healthy")
        self.assertEqual(invalid_exit["status"], "unknown")
        self.assertEqual(non_numeric_status["status"], "unhealthy")
        self.assertIsNone(non_numeric_status["http_status"])

        expected_errors = {
            6: "dns",
            7: "connection",
            28: "timeout",
            35: "tls",
            51: "tls",
            58: "tls",
            60: "tls",
            1: "request_failed",
        }
        for curl_exit, expected_error in expected_errors.items():
            with self.subTest(curl_exit=curl_exit):
                result = engine_app_ops._public_health_from_output(
                    self.app_config,
                    _FakeOutput(stdout_lines=[f"{marker}{curl_exit}|000"]),
                )
                self.assertEqual(result["status"], "unhealthy")
                self.assertEqual(result["error"], expected_error)

    def test_public_health_supports_disabled_and_missing_domain_states(self):
        disabled_config = parse_app_config(
            {
                "settings": {
                    "public_health_check_enabled": False,
                    "public_health_check_path": "/api/ready",
                }
            }
        )
        self.assertIsNone(engine_app_ops._public_health_probe_command(disabled_config))
        self.assertEqual(
            engine_app_ops._probe_public_health(self.ctx, self.session, disabled_config),
            {
                "enabled": False,
                "status": "skipped",
                "path": "/api/ready",
                "http_status": None,
                "checked_at": None,
                "error": None,
            },
        )

        domainless_config = parse_app_config(
            {"settings": {"primary_domain": None}},
            require_domain=False,
        )
        self.assertIsNone(engine_app_ops._public_health_probe_command(domainless_config))
        domainless = engine_app_ops._probe_public_health(
            self.ctx,
            self.session,
            domainless_config,
        )
        self.assertEqual(domainless["status"], "unknown")
        self.assertEqual(domainless["error"], "domain_not_configured")

    def test_probe_public_health_uses_structured_marker_output(self):
        output = _FakeOutput(stdout_lines=[f"{engine_app_ops._PUBLIC_HEALTH_MARKER}0|200"])
        with patch.object(
            engine_app_ops,
            "_run_remote_command",
            return_value={"ok": True, "details": None, "output": output},
        ) as run_remote:
            result = engine_app_ops._probe_public_health(
                self.ctx,
                self.session,
                self.app_config,
            )

        self.assertEqual(result["status"], "healthy")
        self.assertEqual(result["http_status"], 200)
        self.assertEqual(run_remote.call_args.args[2], "Check public URL at /")

    def test_write_caddy_probe_verify_and_prune_helpers_cover_success_and_failure(self):
        call_log = []
        responses = [
            {
                "ok": False,
                "details": "write failed",
                "output": _FakeOutput(stderr_lines=["write failed"]),
            },
            {"ok": True, "details": None, "output": _FakeOutput()},
            {
                "ok": False,
                "details": "env failed",
                "output": _FakeOutput(stderr_lines=["env failed"]),
            },
            {"ok": True, "details": None, "output": _FakeOutput()},
            {"ok": True, "details": None, "output": _FakeOutput()},
            {
                "ok": False,
                "details": "reload failed",
                "output": _FakeOutput(stderr_lines=["reload failed"]),
            },
            {"ok": True, "details": None, "output": _FakeOutput()},
            {"ok": True, "details": None, "output": _FakeOutput()},
            {"ok": True, "details": None, "output": _FakeOutput()},
        ]

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            call_log.append(label)
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
                return_value="reload-caddy",
            ),
        ):
            failed_write = engine_app_ops._write_caddy_route(
                self.ctx,
                self.session,
                self.app_config,
                target_container_name="candidate-1",
            )
            failed_env = engine_app_ops._write_caddy_route(
                self.ctx,
                self.session,
                self.app_config,
                target_container_name="candidate-2",
            )
            failed_reload = engine_app_ops._write_caddy_route(
                self.ctx,
                self.session,
                self.app_config,
                target_container_name="candidate-3",
            )
            success = engine_app_ops._write_caddy_route(
                self.ctx,
                self.session,
                self.app_config,
                target_container_name="candidate-4",
            )

        self.assertFalse(failed_write["ok"])
        self.assertFalse(failed_env["ok"])
        self.assertFalse(failed_reload["ok"])
        self.assertTrue(success["ok"])
        self.assertIn("Reload Caddy", call_log)
        for result, expected_line in (
            (failed_write, "write failed"),
            (failed_env, "env failed"),
            (failed_reload, "reload failed"),
        ):
            with self.subTest(expected_line=expected_line):
                evidence = engine_app_ops._failure_evidence_from_result(
                    self.ctx,
                    phase="traffic_switch",
                    source="failed_operation",
                    result=result,
                )
                self.assertEqual(evidence.lines, (expected_line,))

        def fake_probe_and_verify_run_remote_command(ctx, session, label, command, **kwargs):
            if label.startswith("Probe candidate release"):
                return {"ok": False, "details": None}
            if label == "Probe routed release at /":
                return {"ok": True, "details": None}
            if label.startswith("Verify worker"):
                return {"ok": False, "details": None}
            raise AssertionError(f"Unexpected label: {label}")

        with (
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                side_effect=fake_probe_and_verify_run_remote_command,
            ),
            patch.object(engine_app_ops.time, "sleep", return_value=None),
        ):
            candidate_failure = engine_app_ops._probe_candidate_release(
                self.ctx,
                self.session,
                self.app_config,
                container_name="candidate",
            )
            routed_success = engine_app_ops._probe_routed_release(
                self.ctx,
                self.session,
                self.app_config,
                path="/",
            )
            worker_failure = engine_app_ops._verify_release_workers_running(
                self.ctx,
                self.session,
                worker_container_names=["worker-a"],
            )
            worker_success = engine_app_ops._verify_release_workers_running(
                self.ctx,
                self.session,
                worker_container_names=[],
            )

        self.assertEqual(candidate_failure, {"ok": False, "path": None})
        self.assertEqual(routed_success, {"ok": True, "path": "/"})
        self.assertEqual(
            worker_failure,
            {"ok": False, "worker_container_name": "worker-a"},
        )
        self.assertEqual(
            worker_success,
            {"ok": True, "worker_container_name": None},
        )

        manifest = empty_release_manifest()
        old_release = release_entry_from_config(
            self.app_config,
            release_id="20260526t120000z-abcdef00",
            commit_sha="abcdef1234567890",
            status="retained",
            deployment_kind="deploy",
            image_name=self.app_config.release_image_name("20260526t120000z-abcdef00"),
        )
        old_release["created_at"] = "2026-05-26T12:00:00Z"
        live_release = release_entry_from_config(
            self.app_config,
            release_id="20260531t120000z-abcdef06",
            commit_sha="abcdef1234567896",
            status="live",
            deployment_kind="deploy",
            image_name=self.app_config.release_image_name("20260531t120000z-abcdef06"),
        )
        live_release["created_at"] = "2026-05-31T12:00:00Z"
        previous_release = release_entry_from_config(
            self.app_config,
            release_id="20260531t110000z-abcdef05",
            commit_sha="abcdef1234567895",
            status="retained",
            deployment_kind="deploy",
            image_name=self.app_config.release_image_name("20260531t110000z-abcdef05"),
        )
        previous_release["created_at"] = "2026-05-31T11:00:00Z"
        for entry in (old_release, previous_release, live_release):
            manifest = append_or_replace_release(manifest, entry)
        manifest["releases"].append({"status": "retained", "release_id": None})
        manifest["retention_success_limit"] = 2

        pruned = []
        with patch.object(
            engine_app_ops,
            "_remove_release_runtime",
            side_effect=lambda *args, **kwargs: pruned.append(kwargs) or {"ok": True},
        ):
            prune_result = engine_app_ops._prune_release_artifacts(
                self.ctx,
                self.session,
                self.app_config,
                manifest,
            )

        self.assertEqual(prune_result["pruned_release_ids"], ["20260526t120000z-abcdef00"])
        self.assertEqual(pruned[0]["image_name"], old_release["image_name"])

    def test_probe_routed_release_and_prune_cover_empty_result_paths(self):
        self.assertEqual(
            engine_app_ops._release_route_target(
                self.app_config,
                container_name="deploydash_app_remix-blog_live",
            ),
            "deploydash_app_remix-blog_live",
        )

        with (
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                return_value={"ok": False, "details": None},
            ) as run_mock,
            patch.object(engine_app_ops.time, "sleep", return_value=None) as sleep_mock,
        ):
            routed_failure = engine_app_ops._probe_routed_release(
                self.ctx,
                self.session,
                self.app_config,
                path="/",
            )

        self.assertEqual(routed_failure, {"ok": False, "path": None})
        self.assertEqual(
            run_mock.call_count,
            len(engine_app_ops._RELEASE_PROBE_PATHS)
            * engine_app_ops._RELEASE_ROUTED_PROBE_ATTEMPTS,
        )
        self.assertEqual(
            sleep_mock.call_count,
            engine_app_ops._RELEASE_ROUTED_PROBE_ATTEMPTS - 1,
        )

        with patch.object(
            engine_app_ops,
            "_routed_probe_commands",
            return_value=[],
        ):
            routed_without_root = engine_app_ops._probe_routed_release(
                self.ctx,
                self.session,
                self.app_config,
                path="/",
            )

        self.assertEqual(routed_without_root, {"ok": False, "path": None})

        manifest = empty_release_manifest()
        prune_result = engine_app_ops._prune_release_artifacts(
            self.ctx,
            self.session,
            self.app_config,
            manifest,
        )
        self.assertIs(prune_result["manifest"], manifest)
        self.assertEqual(prune_result["pruned_release_ids"], [])

    def test_probe_routed_release_retries_transient_route_failure(self):
        with (
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                side_effect=[
                    {"ok": False, "details": None},
                    {"ok": False, "details": None},
                    {"ok": False, "details": None},
                    {"ok": True, "details": None},
                ],
            ) as run_mock,
            patch.object(engine_app_ops.time, "sleep", return_value=None) as sleep_mock,
        ):
            result = engine_app_ops._probe_routed_release(
                self.ctx,
                self.session,
                self.app_config,
                path="/up",
            )

        self.assertEqual(result, {"ok": True, "path": "/up"})
        self.assertEqual(run_mock.call_count, 4)
        sleep_mock.assert_called_once_with(engine_app_ops._RELEASE_ROUTED_PROBE_DELAY_SECONDS)

    def test_probe_routed_release_uses_home_page_when_selected_path_is_unrouted(self):
        labels = []

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            labels.append(label)
            return {"ok": label.endswith(" at /"), "details": None}

        with patch.object(
            engine_app_ops,
            "_run_remote_command",
            side_effect=fake_run_remote_command,
        ):
            result = engine_app_ops._probe_routed_release(
                self.ctx,
                self.session,
                self.app_config,
                path="/up",
            )

        self.assertEqual(
            labels,
            [
                "Probe routed release at /up",
                "Probe routed release at /health",
                "Probe routed release at /",
            ],
        )
        self.assertEqual(result, {"ok": True, "path": "/"})

    def test_probe_candidate_release_uses_probe_paths_in_order(self):
        labels = []

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            labels.append(label)
            return {"ok": label.endswith("/health"), "details": None}

        with patch.object(
            engine_app_ops,
            "_run_remote_command",
            side_effect=fake_run_remote_command,
        ):
            result = engine_app_ops._probe_candidate_release(
                self.ctx,
                self.session,
                self.app_config,
                container_name="deploydash_app_remix-blog_candidate",
            )

        self.assertEqual(
            labels,
            [
                "Probe candidate release at /up",
                "Probe candidate release at /health",
            ],
        )
        self.assertEqual(result, {"ok": True, "path": "/health"})

    def test_probe_candidate_release_uses_home_page_when_no_health_path_exists(self):
        labels = []

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            labels.append(label)
            return {"ok": label.endswith(" at /"), "details": None}

        with patch.object(
            engine_app_ops,
            "_run_remote_command",
            side_effect=fake_run_remote_command,
        ):
            result = engine_app_ops._probe_candidate_release(
                self.ctx,
                self.session,
                self.app_config,
                container_name="deploydash_app_remix-blog_candidate",
            )

        self.assertEqual(
            labels,
            [
                "Probe candidate release at /up",
                "Probe candidate release at /health",
                "Probe candidate release at /",
            ],
        )
        self.assertEqual(result, {"ok": True, "path": "/"})

    def test_probe_candidate_release_retries_before_returning_failure(self):
        labels = []

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            labels.append(label)
            return {"ok": False, "details": None}

        with (
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                side_effect=fake_run_remote_command,
            ),
            patch.object(engine_app_ops.time, "sleep", return_value=None) as sleep_mock,
        ):
            result = engine_app_ops._probe_candidate_release(
                self.ctx,
                self.session,
                self.app_config,
                container_name="deploydash_app_remix-blog_candidate",
            )

        self.assertEqual(result, {"ok": False, "path": None})
        self.assertEqual(
            labels,
            [
                "Probe candidate release at /up",
                "Probe candidate release at /health",
                "Probe candidate release at /",
            ]
            * engine_app_ops._RELEASE_CANDIDATE_PROBE_ATTEMPTS,
        )
        self.assertEqual(
            sleep_mock.call_count,
            engine_app_ops._RELEASE_CANDIDATE_PROBE_ATTEMPTS - 1,
        )


if __name__ == "__main__":
    unittest.main()
