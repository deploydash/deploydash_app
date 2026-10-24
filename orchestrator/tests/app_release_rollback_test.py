"""Rolling back to a retained release, and every way that can fail.

One of four files T-3.6.2 split `app_release_flow_test.py` into, along the
same seams as the production code. Fixtures and the base case are in
`tests/app_release_support.py`.
"""

from __future__ import annotations

import unittest
from types import SimpleNamespace
from unittest.mock import patch

from orchestrator.app_runtime_parts import release_lifecycle as engine_app_ops
from orchestrator.failure_evidence import serialize_failure_evidence
from tests.app_release_support import (
    AppReleaseFlowTestCase,
    append_or_replace_release,
    copy,
    empty_release_manifest,
)


def _failure_evidence(result):
    """Serialize the canonical rollback evidence stored by the fixture envelope."""
    return serialize_failure_evidence(result["extra"]["failure_evidence"])


class TestReleaseRollback(AppReleaseFlowTestCase):
    def test_execute_release_rollback_promotes_selected_retained_release(self):
        manifest, previous_live, retained_release = self._manifest_with_retained_release()
        manifest_writes = []
        caddy_targets = []
        stopped = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        with (
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t140000z-fedcba987654",
            ),
            patch.object(
                engine_app_ops,
                "_release_runtime_targets",
                return_value={
                    "manifest": manifest,
                    "live_release": previous_live,
                    "live_release_id": previous_live["release_id"],
                    "web_container_name": previous_live["web_container_name"],
                    "image_name": previous_live["image_name"],
                    "worker_container_names": previous_live["worker_container_names"],
                    "legacy": False,
                },
            ),
            patch.object(
                engine_app_ops,
                "_write_release_manifest",
                side_effect=fake_write_manifest,
            ),
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                return_value={
                    "ok": True,
                    "details": None,
                    "output": SimpleNamespace(stdout_lines=[]),
                },
            ),
            patch.object(
                engine_app_ops,
                "_probe_candidate_release",
                return_value={"ok": True, "path": "/up"},
            ),
            patch.object(
                engine_app_ops,
                "_probe_routed_release",
                return_value={"ok": True, "path": "/up"},
            ),
            patch.object(
                engine_app_ops,
                "_probe_public_health",
                return_value={
                    "enabled": True,
                    "status": "healthy",
                    "path": "/",
                    "http_status": 200,
                    "checked_at": "2026-08-06T12:00:00+00:00",
                    "error": None,
                },
            ),
            patch.object(
                engine_app_ops,
                "_verify_release_workers_running",
                return_value={"ok": True, "worker_container_name": None},
            ),
            patch.object(
                engine_app_ops,
                "_write_caddy_route",
                side_effect=lambda ctx, session, app_config, *, target_container_name, emit=None: (
                    caddy_targets.append(target_container_name) or {"ok": True, "details": None}
                ),
            ),
            patch.object(
                engine_app_ops,
                "_set_release_live_labels",
                return_value={"ok": True},
            ),
            patch.object(
                engine_app_ops,
                "_stop_release_runtime",
                side_effect=lambda ctx, session, *, web_container_name, worker_container_names, emit=None: (
                    stopped.append((web_container_name, list(worker_container_names)))
                    or {"ok": True}
                ),
            ),
            patch.object(
                engine_app_ops,
                "_prune_release_artifacts",
                side_effect=lambda ctx, session, app_config, manifest, emit=None: {
                    "manifest": manifest,
                    "pruned_release_ids": [],
                },
            ),
            patch.object(engine_app_ops.time, "sleep", return_value=None),
        ):
            result = engine_app_ops._execute_release_rollback(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                requested_release_id=retained_release["release_id"],
            )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "rollback")
        self.assertEqual(result["target_release_id"], retained_release["release_id"])
        self.assertEqual(result["rollback_from_release_id"], previous_live["release_id"])
        self.assertEqual(
            result["live_release_id"],
            "20260531t140000z-fedcba987654",
        )
        self.assertEqual(
            caddy_targets,
            [self.app_config.release_upstream_name("20260531t140000z-fedcba987654")],
        )
        self.assertEqual(stopped[0][0], previous_live["web_container_name"])
        final_manifest = manifest_writes[-1]
        self.assertEqual(final_manifest["releases"][0]["status"], "live")
        self.assertEqual(
            final_manifest["releases"][0]["release_id"],
            "20260531t140000z-fedcba987654",
        )
        current_live = next(
            entry
            for entry in final_manifest["releases"]
            if entry["release_id"] == previous_live["release_id"]
        )
        self.assertEqual(current_live["status"], "retained")
        self.assertEqual(
            result["release_entry"]["release_id"],
            "20260531t140000z-fedcba987654",
        )
        self.assertEqual(
            result["release_inventory"]["live_release_id"],
            "20260531t140000z-fedcba987654",
        )
        self.assertEqual(result["release_inventory"]["releases"], result["releases"])
        self.assertEqual(result["process_readiness"], {"status": "ready", "path": "/up"})
        self.assertEqual(result["public_health"]["status"], "healthy")

    def test_execute_release_rollback_returns_validation_error_without_target(self):
        with patch.object(
            engine_app_ops,
            "_release_runtime_targets",
            return_value={
                "manifest": empty_release_manifest(),
                "live_release": None,
                "live_release_id": None,
                "web_container_name": None,
                "image_name": None,
                "worker_container_names": [],
                "legacy": False,
            },
        ):
            result = engine_app_ops._execute_release_rollback(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "No retained release is available for rollback.")

    def test_execute_release_rollback_returns_validation_error_when_image_missing(self):
        manifest, previous_live, retained_release = self._manifest_with_retained_release()
        retained_release["image_name"] = ""
        manifest = append_or_replace_release(manifest, retained_release)

        with patch.object(
            engine_app_ops,
            "_release_runtime_targets",
            return_value={
                "manifest": manifest,
                "live_release": previous_live,
                "live_release_id": previous_live["release_id"],
                "web_container_name": previous_live["web_container_name"],
                "image_name": previous_live["image_name"],
                "worker_container_names": previous_live["worker_container_names"],
                "legacy": False,
            },
        ):
            result = engine_app_ops._execute_release_rollback(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                requested_release_id=retained_release["release_id"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(
            result["msg"],
            "Selected release does not have a retained image reference.",
        )

    def test_execute_release_rollback_returns_error_when_candidate_start_fails(self):
        manifest, previous_live, retained_release = self._manifest_with_retained_release()
        manifest_writes = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            if label == "Start rollback candidate runtime":
                return {
                    "ok": False,
                    "details": "start failed",
                    "output": SimpleNamespace(
                        stdout_lines=[],
                        stderr_lines=["fatal: rollback web start failed"],
                    ),
                }
            return {
                "ok": True,
                "details": None,
                "output": SimpleNamespace(stdout_lines=[]),
            }

        with (
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t140000z-fedcba987654",
            ),
            patch.object(
                engine_app_ops,
                "_release_runtime_targets",
                return_value={
                    "manifest": manifest,
                    "live_release": previous_live,
                    "live_release_id": previous_live["release_id"],
                    "web_container_name": previous_live["web_container_name"],
                    "image_name": previous_live["image_name"],
                    "worker_container_names": previous_live["worker_container_names"],
                    "legacy": False,
                },
            ),
            patch.object(
                engine_app_ops,
                "_write_release_manifest",
                side_effect=fake_write_manifest,
            ),
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                side_effect=fake_run_remote_command,
            ),
        ):
            result = engine_app_ops._execute_release_rollback(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                requested_release_id=retained_release["release_id"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Start rollback candidate runtime failed.")
        self.assertEqual(_failure_evidence(result)["phase"], "rollback")
        self.assertEqual(
            _failure_evidence(result)["lines"],
            ["fatal: rollback web start failed"],
        )
        self.assertEqual(manifest_writes[-1]["releases"][0]["status"], "failed")

    def test_execute_release_rollback_returns_error_when_worker_start_fails(self):
        manifest, previous_live, retained_release = self._manifest_with_retained_release()
        manifest_writes = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            if label == "Start rollback worker":
                return {
                    "ok": False,
                    "details": "worker start failed",
                    "output": SimpleNamespace(
                        stdout_lines=[],
                        stderr_lines=["fatal: rollback worker start failed"],
                    ),
                }
            return {
                "ok": True,
                "details": None,
                "output": SimpleNamespace(stdout_lines=[]),
            }

        with (
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t140000z-fedcba987654",
            ),
            patch.object(
                engine_app_ops,
                "_release_runtime_targets",
                return_value={
                    "manifest": manifest,
                    "live_release": previous_live,
                    "live_release_id": previous_live["release_id"],
                    "web_container_name": previous_live["web_container_name"],
                    "image_name": previous_live["image_name"],
                    "worker_container_names": previous_live["worker_container_names"],
                    "legacy": False,
                },
            ),
            patch.object(
                engine_app_ops,
                "_write_release_manifest",
                side_effect=fake_write_manifest,
            ),
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                side_effect=fake_run_remote_command,
            ),
            patch.object(
                engine_app_ops,
                "_remove_release_runtime",
                return_value={"ok": True},
            ),
        ):
            result = engine_app_ops._execute_release_rollback(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                requested_release_id=retained_release["release_id"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Start rollback worker failed.")
        self.assertEqual(_failure_evidence(result)["phase"], "rollback")
        self.assertEqual(
            _failure_evidence(result)["lines"],
            ["fatal: rollback worker start failed"],
        )
        self.assertEqual(manifest_writes[-1]["releases"][0]["status"], "failed")

    def test_execute_release_rollback_returns_error_when_worker_verify_fails(self):
        manifest, previous_live, retained_release = self._manifest_with_retained_release()
        manifest_writes = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        with (
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t140000z-fedcba987654",
            ),
            patch.object(
                engine_app_ops,
                "_release_runtime_targets",
                return_value={
                    "manifest": manifest,
                    "live_release": previous_live,
                    "live_release_id": previous_live["release_id"],
                    "web_container_name": previous_live["web_container_name"],
                    "image_name": previous_live["image_name"],
                    "worker_container_names": previous_live["worker_container_names"],
                    "legacy": False,
                },
            ),
            patch.object(
                engine_app_ops,
                "_write_release_manifest",
                side_effect=fake_write_manifest,
            ),
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                return_value={
                    "ok": True,
                    "details": None,
                    "output": SimpleNamespace(stdout_lines=[]),
                },
            ),
            patch.object(
                engine_app_ops,
                "_verify_release_workers_running",
                return_value={
                    "ok": False,
                    "worker_container_name": "worker-a",
                    "result": {
                        "ok": False,
                        "output": SimpleNamespace(
                            stdout_lines=[],
                            stderr_lines=["worker exited with status 1"],
                        ),
                    },
                },
            ),
            patch.object(
                engine_app_ops,
                "_remove_release_runtime",
                return_value={"ok": True},
            ),
        ):
            result = engine_app_ops._execute_release_rollback(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                requested_release_id=retained_release["release_id"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Verify rollback worker process state failed.")
        self.assertEqual(_failure_evidence(result)["phase"], "rollback")
        self.assertEqual(
            _failure_evidence(result)["lines"],
            ["worker exited with status 1"],
        )
        self.assertEqual(manifest_writes[-1]["releases"][0]["status"], "failed")

    def test_execute_release_rollback_returns_error_when_candidate_probe_fails(self):
        manifest, previous_live, retained_release = self._manifest_with_retained_release()
        manifest_writes = []
        log_collection_calls = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        with (
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t140000z-fedcba987654",
            ),
            patch.object(
                engine_app_ops,
                "_release_runtime_targets",
                return_value={
                    "manifest": manifest,
                    "live_release": previous_live,
                    "live_release_id": previous_live["release_id"],
                    "web_container_name": previous_live["web_container_name"],
                    "image_name": previous_live["image_name"],
                    "worker_container_names": previous_live["worker_container_names"],
                    "legacy": False,
                },
            ),
            patch.object(
                engine_app_ops,
                "_write_release_manifest",
                side_effect=fake_write_manifest,
            ),
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                return_value={
                    "ok": True,
                    "details": None,
                    "output": SimpleNamespace(stdout_lines=[]),
                },
            ),
            patch.object(
                engine_app_ops,
                "_verify_release_workers_running",
                return_value={"ok": True, "worker_container_name": None},
            ),
            patch.object(
                engine_app_ops,
                "_probe_candidate_release",
                return_value={
                    "ok": False,
                    "path": None,
                    "probe": engine_app_ops.FailureEvidenceProbe(
                        path="/health",
                        curl_exit=22,
                        http_status=503,
                    ),
                },
            ),
            patch.object(
                engine_app_ops,
                "_collect_release_runtime_logs",
                side_effect=lambda *args, **kwargs: (
                    log_collection_calls.append(kwargs)
                    or {
                        "ok": True,
                        "output": SimpleNamespace(
                            stdout_lines=["FATAL rollback candidate exited"],
                            stderr_lines=[],
                        ),
                    }
                ),
            ),
            patch.object(
                engine_app_ops,
                "_remove_release_runtime",
                return_value={"ok": True},
            ),
        ):
            result = engine_app_ops._execute_release_rollback(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                requested_release_id=retained_release["release_id"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Rollback candidate did not pass readiness probes.")
        self.assertEqual(_failure_evidence(result)["phase"], "rollback")
        self.assertEqual(_failure_evidence(result)["source"], "candidate_runtime")
        self.assertEqual(
            _failure_evidence(result)["lines"],
            ["FATAL rollback candidate exited"],
        )
        self.assertEqual(
            result["extra"]["runtime_log_source"],
            "failed_rollback_candidate",
        )
        self.assertEqual(
            result["extra"]["runtime_log_container_name"],
            self.app_config.release_container_name("20260531t140000z-fedcba987654"),
        )
        self.assertEqual(manifest_writes[-1]["releases"][0]["status"], "failed")
        self.assertEqual(
            log_collection_calls[0]["container_name"],
            self.app_config.release_container_name("20260531t140000z-fedcba987654"),
        )

    def test_execute_release_rollback_returns_error_when_caddy_cutover_fails(self):
        manifest, previous_live, retained_release = self._manifest_with_retained_release()
        manifest_writes = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        with (
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t140000z-fedcba987654",
            ),
            patch.object(
                engine_app_ops,
                "_release_runtime_targets",
                return_value={
                    "manifest": manifest,
                    "live_release": previous_live,
                    "live_release_id": previous_live["release_id"],
                    "web_container_name": previous_live["web_container_name"],
                    "image_name": previous_live["image_name"],
                    "worker_container_names": previous_live["worker_container_names"],
                    "legacy": False,
                },
            ),
            patch.object(
                engine_app_ops,
                "_write_release_manifest",
                side_effect=fake_write_manifest,
            ),
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                return_value={
                    "ok": True,
                    "details": None,
                    "output": SimpleNamespace(stdout_lines=[]),
                },
            ),
            patch.object(
                engine_app_ops,
                "_verify_release_workers_running",
                return_value={"ok": True, "worker_container_name": None},
            ),
            patch.object(
                engine_app_ops,
                "_probe_candidate_release",
                return_value={"ok": True, "path": "/up"},
            ),
            patch.object(
                engine_app_ops,
                "_write_caddy_route",
                return_value={
                    "ok": False,
                    "details": "caddy failed",
                    "output": SimpleNamespace(
                        stdout_lines=[],
                        stderr_lines=["caddy reload failed"],
                    ),
                },
            ),
            patch.object(
                engine_app_ops,
                "_remove_release_runtime",
                return_value={"ok": True},
            ),
        ):
            result = engine_app_ops._execute_release_rollback(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                requested_release_id=retained_release["release_id"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Rollback traffic switch failed.")
        self.assertEqual(_failure_evidence(result)["phase"], "rollback")
        self.assertEqual(_failure_evidence(result)["lines"], ["caddy reload failed"])
        self.assertEqual(manifest_writes[-1]["releases"][0]["status"], "failed")

    def test_execute_release_rollback_cancellation_reverts_after_traffic_switch(self):
        manifest, previous_live, retained_release = self._manifest_with_retained_release()
        routed_probe_calls = []

        with (
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t140000z-fedcba987654",
            ),
            patch.object(
                engine_app_ops,
                "_release_runtime_targets",
                return_value={
                    "manifest": manifest,
                    "live_release": previous_live,
                    "live_release_id": previous_live["release_id"],
                    "web_container_name": previous_live["web_container_name"],
                    "image_name": previous_live["image_name"],
                    "worker_container_names": previous_live["worker_container_names"],
                    "legacy": False,
                },
            ),
            patch.object(engine_app_ops, "_write_release_manifest"),
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                return_value={
                    "ok": True,
                    "details": None,
                    "output": SimpleNamespace(stdout_lines=[]),
                },
            ),
            patch.object(
                engine_app_ops,
                "_probe_candidate_release",
                return_value={"ok": True, "path": "/up"},
            ),
            patch.object(
                engine_app_ops,
                "_probe_routed_release",
                side_effect=lambda *args, **kwargs: (
                    routed_probe_calls.append(True) or {"ok": True, "path": "/up"}
                ),
            ),
            patch.object(
                engine_app_ops,
                "_verify_release_workers_running",
                return_value={"ok": True, "worker_container_name": None},
            ),
            patch.object(
                engine_app_ops,
                "_write_caddy_route",
                return_value={"ok": True, "details": None},
            ),
            patch.object(
                engine_app_ops,
                "_set_release_live_labels",
                return_value={"ok": True},
            ),
            patch.object(
                engine_app_ops,
                "_stop_release_runtime",
                return_value={"ok": True},
            ),
            patch.object(
                engine_app_ops,
                "_prune_release_artifacts",
                side_effect=lambda ctx, session, app_config, manifest, emit=None: {
                    "manifest": manifest,
                    "pruned_release_ids": [],
                },
            ),
            patch.object(engine_app_ops.time, "sleep", return_value=None),
        ):
            result = engine_app_ops._execute_release_rollback(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                requested_release_id=retained_release["release_id"],
                is_cancelled=lambda: True,
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(result["extra"]["route_cleanup_status"], "restored")
        self.assertNotIn("failure_evidence", result["extra"])
        self.assertEqual(routed_probe_calls, [])

    def test_execute_release_rollback_recovers_from_cutover_exceptions(self):
        cleanup_targets = []

        def run_rollback(*, caddy_result, routed_probe_result=None):
            manifest, previous_live, retained_release = self._manifest_with_retained_release()
            caddy_patch_kwargs = (
                {"side_effect": caddy_result}
                if isinstance(caddy_result, BaseException)
                else {"return_value": caddy_result}
            )
            routed_probe_patch_kwargs = (
                {"side_effect": routed_probe_result}
                if isinstance(routed_probe_result, BaseException)
                else {"return_value": routed_probe_result}
            )
            with (
                patch.object(
                    engine_app_ops,
                    "build_release_id",
                    return_value="20260531t140000z-fedcba987654",
                ),
                patch.object(
                    engine_app_ops,
                    "_release_runtime_targets",
                    return_value={
                        "manifest": manifest,
                        "live_release": previous_live,
                        "live_release_id": previous_live["release_id"],
                        "web_container_name": previous_live["web_container_name"],
                        "image_name": previous_live["image_name"],
                        "worker_container_names": previous_live["worker_container_names"],
                        "legacy": False,
                    },
                ),
                patch.object(engine_app_ops, "_write_release_manifest"),
                patch.object(
                    engine_app_ops,
                    "_run_remote_command",
                    return_value={
                        "ok": True,
                        "details": None,
                        "output": SimpleNamespace(stdout_lines=[]),
                    },
                ),
                patch.object(
                    engine_app_ops,
                    "_probe_candidate_release",
                    return_value={"ok": True, "path": "/up"},
                ),
                patch.object(
                    engine_app_ops,
                    "_verify_release_workers_running",
                    return_value={"ok": True, "worker_container_name": None},
                ),
                patch.object(
                    engine_app_ops,
                    "_write_caddy_route",
                    **caddy_patch_kwargs,
                ),
                patch.object(
                    engine_app_ops,
                    "_probe_routed_release",
                    **routed_probe_patch_kwargs,
                ),
                patch.object(
                    engine_app_ops,
                    "_restore_or_remove_caddy_route",
                    side_effect=lambda ctx, session, app_config, *, previous_route_target=None, emit=None: (
                        cleanup_targets.append(previous_route_target)
                        or {"ok": True, "action": "restored", "details": None}
                    ),
                ),
                patch.object(
                    engine_app_ops,
                    "_remove_release_runtime",
                    return_value={"ok": True},
                ),
            ):
                return engine_app_ops._execute_release_rollback(
                    self.ctx,
                    session=self.session,
                    app_config=self.app_config,
                    requested_release_id=retained_release["release_id"],
                )

        cutover_exception = run_rollback(
            caddy_result=RuntimeError("Caddy write interrupted"),
        )
        stabilization_exception = run_rollback(
            caddy_result={"ok": True, "details": None},
            routed_probe_result=RuntimeError("Routed probe interrupted"),
        )

        self.assertEqual(cutover_exception["status"], "error")
        self.assertEqual(cutover_exception["details"], "Caddy write interrupted")
        self.assertEqual(_failure_evidence(cutover_exception)["phase"], "rollback")
        self.assertEqual(_failure_evidence(cutover_exception)["source"], "exception")
        self.assertEqual(
            _failure_evidence(cutover_exception)["lines"],
            ["Caddy write interrupted"],
        )
        self.assertEqual(stabilization_exception["status"], "error")
        self.assertEqual(
            stabilization_exception["details"],
            "Routed probe interrupted",
        )
        self.assertEqual(
            _failure_evidence(stabilization_exception)["lines"],
            ["Routed probe interrupted"],
        )
        self.assertEqual(
            cleanup_targets,
            [
                self.app_config.release_upstream_name("20260531t120000z-abcdef123456"),
                self.app_config.release_upstream_name("20260531t120000z-abcdef123456"),
            ],
        )

    def test_execute_release_rollback_reverts_when_post_cutover_stabilization_fails(
        self,
    ):
        manifest, previous_live, retained_release = self._manifest_with_retained_release()
        manifest_writes = []
        caddy_targets = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        with (
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t140000z-fedcba987654",
            ),
            patch.object(
                engine_app_ops,
                "_release_runtime_targets",
                return_value={
                    "manifest": manifest,
                    "live_release": previous_live,
                    "live_release_id": previous_live["release_id"],
                    "web_container_name": previous_live["web_container_name"],
                    "image_name": previous_live["image_name"],
                    "worker_container_names": previous_live["worker_container_names"],
                    "legacy": False,
                },
            ),
            patch.object(
                engine_app_ops,
                "_write_release_manifest",
                side_effect=fake_write_manifest,
            ),
            patch.object(
                engine_app_ops,
                "_run_remote_command",
                return_value={
                    "ok": True,
                    "details": None,
                    "output": SimpleNamespace(stdout_lines=[]),
                },
            ),
            patch.object(
                engine_app_ops,
                "_probe_candidate_release",
                return_value={"ok": True, "path": "/up"},
            ),
            patch.object(
                engine_app_ops,
                "_probe_routed_release",
                return_value={
                    "ok": False,
                    "path": None,
                    "probe": engine_app_ops.FailureEvidenceProbe(
                        path="/up",
                        curl_exit=22,
                        http_status=502,
                    ),
                },
            ) as routed_probe_mock,
            patch.object(
                engine_app_ops,
                "_verify_release_workers_running",
                side_effect=[
                    {"ok": True, "worker_container_name": None},
                    *[
                        {
                            "ok": False,
                            "worker_container_name": "worker-a",
                            "result": {
                                "ok": False,
                                "output": SimpleNamespace(
                                    stdout_lines=[],
                                    stderr_lines=["rollback worker exited"],
                                ),
                            },
                        }
                        for _ in range(engine_app_ops._RELEASE_STABILIZATION_ATTEMPTS)
                    ],
                ],
            ),
            patch.object(
                engine_app_ops,
                "_write_caddy_route",
                side_effect=lambda ctx, session, app_config, *, target_container_name, emit=None: (
                    caddy_targets.append(target_container_name) or {"ok": True, "details": None}
                ),
            ),
            patch.object(
                engine_app_ops,
                "_remove_release_runtime",
                return_value={"ok": True},
            ),
            patch.object(
                engine_app_ops,
                "_collect_release_runtime_logs",
                return_value={
                    "ok": True,
                    "output": SimpleNamespace(
                        stdout_lines=[],
                        stderr_lines=[],
                    ),
                },
            ),
            patch.object(engine_app_ops.time, "sleep", return_value=None),
        ):
            result = engine_app_ops._execute_release_rollback(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                requested_release_id=retained_release["release_id"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(
            result["msg"],
            "Rollback candidate failed post-cutover stabilization and was reverted.",
        )
        self.assertEqual(_failure_evidence(result)["phase"], "rollback")
        self.assertEqual(_failure_evidence(result)["source"], "failed_operation")
        self.assertEqual(
            _failure_evidence(result)["lines"],
            ["rollback worker exited"],
        )
        self.assertEqual(
            routed_probe_mock.call_count,
            engine_app_ops._RELEASE_STABILIZATION_ATTEMPTS,
        )
        self.assertEqual(
            caddy_targets,
            [
                self.app_config.release_upstream_name("20260531t140000z-fedcba987654"),
                self.app_config.release_upstream_name(previous_live["release_id"]),
            ],
        )
        self.assertEqual(manifest_writes[-1]["releases"][0]["status"], "failed")


if __name__ == "__main__":
    unittest.main()
