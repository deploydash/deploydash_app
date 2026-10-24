"""The versioned deploy: build, candidate start, readiness, cutover, revert.

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
    _FakeOutput,
    copy,
    empty_release_manifest,
)


def _failure_evidence(result):
    """Serialize the canonical deploy evidence stored by the fixture envelope."""
    return serialize_failure_evidence(result["extra"]["failure_evidence"])


class TestVersionedReleaseDeploy(AppReleaseFlowTestCase):
    def test_execute_versioned_release_deploy_promotes_candidate_and_retains_previous_live(
        self,
    ):
        manifest, previous_live = self._live_manifest()
        manifest_writes = []
        caddy_targets = []
        label_updates = []
        stopped = []
        remote_calls = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            remote_calls.append({"label": label, "command": command, "kwargs": dict(kwargs)})
            return {"ok": True, "details": None, "output": SimpleNamespace(stdout_lines=[])}

        def fake_caddy_route(ctx, session, app_config, *, target_container_name, emit=None):
            caddy_targets.append(target_container_name)
            return {"ok": True, "details": None}

        def fake_set_labels(
            ctx,
            session,
            *,
            web_container_name,
            worker_container_names,
            live_value,
            emit=None,
        ):
            label_updates.append(
                {
                    "web": web_container_name,
                    "workers": list(worker_container_names),
                    "live_value": live_value,
                }
            )
            return {"ok": True}

        def fake_stop_runtime(
            ctx,
            session,
            *,
            web_container_name,
            worker_container_names,
            emit=None,
        ):
            stopped.append((web_container_name, list(worker_container_names)))
            return {"ok": True}

        with (
            patch.object(
                engine_app_ops,
                "_resolve_commit_sha",
                return_value="fedcba9876543210",
            ),
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t130000z-fedcba987654",
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
                    "status": "unhealthy",
                    "path": "/",
                    "http_status": 500,
                    "checked_at": "2026-08-06T12:00:00+00:00",
                    "error": "The public URL returned HTTP 500.",
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
                side_effect=fake_caddy_route,
            ),
            patch.object(
                engine_app_ops,
                "_set_release_live_labels",
                side_effect=fake_set_labels,
            ),
            patch.object(
                engine_app_ops,
                "_stop_release_runtime",
                side_effect=fake_stop_runtime,
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
            result = engine_app_ops._execute_versioned_release_deploy(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                normalized_parts=["preflight", "sync"],
            )

        self.assertEqual(result["status"], "success")
        self.assertNotIn("failure_evidence", result)
        self.assertEqual(result["release_id"], "20260531t130000z-fedcba987654")
        self.assertEqual(result["cutover_status"], "live")
        self.assertEqual(result["rollback_status"], "not_required")
        self.assertEqual(result["process_readiness"], {"status": "ready", "path": "/up"})
        self.assertEqual(result["public_health"]["status"], "unhealthy")
        self.assertEqual(result["public_health"]["http_status"], 500)
        self.assertEqual(result["retained_release_count"], 2)
        self.assertEqual(
            caddy_targets,
            [self.app_config.release_upstream_name("20260531t130000z-fedcba987654")],
        )
        self.assertEqual(
            label_updates[0]["web"],
            self.app_config.release_container_name("20260531t130000z-fedcba987654"),
        )
        self.assertEqual(label_updates[0]["live_value"], "true")
        self.assertEqual(label_updates[1]["web"], previous_live["web_container_name"])
        self.assertEqual(label_updates[1]["live_value"], "false")
        self.assertEqual(stopped[0][0], previous_live["web_container_name"])
        candidate_start_call = next(
            call for call in remote_calls if call["label"] == "Start candidate release runtime"
        )
        self.assertIn(
            "while IFS=\"$(printf '\\t')\" read -r key value_b64; do ",
            candidate_start_call["command"],
        )
        self.assertEqual(
            candidate_start_call["kwargs"]["stdin"],
            "NODE_ENV\tcHJvZHVjdGlvbg==\n",
        )
        final_manifest = manifest_writes[-1]
        self.assertEqual(final_manifest["releases"][0]["status"], "live")
        self.assertEqual(
            final_manifest["releases"][0]["release_id"],
            "20260531t130000z-fedcba987654",
        )
        retained = next(
            entry
            for entry in final_manifest["releases"]
            if entry["release_id"] == previous_live["release_id"]
        )
        self.assertEqual(retained["status"], "retained")
        self.assertEqual(
            result["release_entry"]["release_id"],
            "20260531t130000z-fedcba987654",
        )
        self.assertEqual(
            result["release_inventory"]["live_release_id"],
            "20260531t130000z-fedcba987654",
        )
        self.assertEqual(result["release_inventory"]["releases"], result["releases"])

    def test_execute_versioned_release_deploy_marks_release_failed_when_build_fails(
        self,
    ):
        manifest, previous_live = self._live_manifest()
        manifest_writes = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            if label == "Build release image":
                return {"ok": False, "details": "build failed", "output": _FakeOutput()}
            return {
                "ok": True,
                "details": None,
                "output": SimpleNamespace(stdout_lines=[]),
            }

        with (
            patch.object(
                engine_app_ops,
                "_resolve_commit_sha",
                return_value="fedcba9876543210",
            ),
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t130000z-fedcba987654",
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
            result = engine_app_ops._execute_versioned_release_deploy(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                normalized_parts=["preflight", "sync"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Build release image failed.")
        self.assertEqual(manifest_writes[-1]["releases"][0]["status"], "failed")

    def test_execute_versioned_release_deploy_marks_release_failed_when_candidate_start_fails(
        self,
    ):
        manifest, previous_live = self._live_manifest()
        manifest_writes = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            if label == "Start candidate release runtime":
                return {"ok": False, "details": "start failed", "output": _FakeOutput()}
            return {
                "ok": True,
                "details": None,
                "output": SimpleNamespace(stdout_lines=[]),
            }

        with (
            patch.object(
                engine_app_ops,
                "_resolve_commit_sha",
                return_value="fedcba9876543210",
            ),
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t130000z-fedcba987654",
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
            result = engine_app_ops._execute_versioned_release_deploy(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                normalized_parts=["preflight", "sync"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Start candidate release runtime failed.")
        self.assertEqual(manifest_writes[-1]["releases"][0]["status"], "failed")

    def test_execute_versioned_release_deploy_returns_sync_failure(self):
        with patch.object(
            engine_app_ops,
            "_run_remote_command",
            return_value={
                "ok": False,
                "details": "sync failed",
                "output": _FakeOutput(),
            },
        ):
            result = engine_app_ops._execute_versioned_release_deploy(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                normalized_parts=["preflight", "sync"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Sync repository failed.")

    def test_execute_versioned_release_deploy_keeps_previous_live_when_candidate_probe_fails(
        self,
    ):
        manifest, previous_live = self._live_manifest()
        manifest_writes = []
        cleanup_calls = []
        log_collection_calls = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        with (
            patch.object(
                engine_app_ops,
                "_resolve_commit_sha",
                return_value="fedcba9876543210",
            ),
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t130000z-fedcba987654",
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
                return_value={"ok": False, "path": None},
            ),
            patch.object(
                engine_app_ops,
                "_collect_release_runtime_logs",
                side_effect=lambda *args, **kwargs: (
                    log_collection_calls.append(kwargs)
                    or {
                        "ok": True,
                        "output": SimpleNamespace(
                            stdout_lines=[
                                "2026-07-05T10:00:00Z App booting",
                                "2026-07-05T10:00:01Z RuntimeError: missing APP_KEY",
                            ],
                        ),
                    }
                ),
            ),
            patch.object(
                engine_app_ops,
                "_remove_release_runtime",
                side_effect=lambda *args, **kwargs: cleanup_calls.append(kwargs) or {"ok": True},
            ),
            patch.object(
                engine_app_ops,
                "_write_caddy_route",
                side_effect=AssertionError("caddy cutover should not run"),
            ),
        ):
            result = engine_app_ops._execute_versioned_release_deploy(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                normalized_parts=["preflight", "sync"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(
            result["extra"]["cutover_status"],
            "pre_cutover_probe_failed",
        )
        self.assertEqual(result["extra"]["rollback_status"], "not_required")
        self.assertEqual(
            result["extra"]["readiness_failure_summary"],
            "Readiness failed. Last runtime log: "
            "2026-07-05T10:00:01Z RuntimeError: missing APP_KEY",
        )
        self.assertEqual(
            result["extra"]["runtime_log_excerpt"],
            [
                "2026-07-05T10:00:00Z App booting",
                "2026-07-05T10:00:01Z RuntimeError: missing APP_KEY",
            ],
        )
        self.assertEqual(result["extra"]["runtime_log_source"], "failed_candidate")
        self.assertEqual(
            result["extra"]["runtime_log_container_name"],
            self.app_config.release_container_name("20260531t130000z-fedcba987654"),
        )
        self.assertEqual(len(cleanup_calls), 1)
        self.assertEqual(
            log_collection_calls[0]["container_name"],
            self.app_config.release_container_name("20260531t130000z-fedcba987654"),
        )
        final_manifest = manifest_writes[-1]
        failed_candidate = final_manifest["releases"][0]
        self.assertEqual(failed_candidate["status"], "failed")
        previous = next(
            entry
            for entry in final_manifest["releases"]
            if entry["release_id"] == previous_live["release_id"]
        )
        self.assertEqual(previous["status"], "live")

    def test_execute_versioned_release_deploy_reverts_after_post_cutover_stabilization_failure(
        self,
    ):
        manifest, previous_live = self._live_manifest()
        manifest_writes = []
        caddy_targets = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        with (
            patch.object(
                engine_app_ops,
                "_resolve_commit_sha",
                return_value="fedcba9876543210",
            ),
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t130000z-fedcba987654",
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
                "_probe_routed_release",
                return_value={"ok": False, "path": None},
            ) as routed_probe_mock,
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
            patch.object(engine_app_ops.time, "sleep", return_value=None),
        ):
            result = engine_app_ops._execute_versioned_release_deploy(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                normalized_parts=["preflight", "sync"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(
            result["extra"]["cutover_status"],
            "reverted_after_stabilization_failure",
        )
        self.assertEqual(
            routed_probe_mock.call_count,
            engine_app_ops._RELEASE_STABILIZATION_ATTEMPTS,
        )
        self.assertEqual(
            result["extra"]["rollback_status"],
            "reverted_to_previous_live",
        )
        self.assertEqual(
            caddy_targets,
            [
                self.app_config.release_upstream_name("20260531t130000z-fedcba987654"),
                self.app_config.release_upstream_name(previous_live["release_id"]),
            ],
        )
        final_manifest = manifest_writes[-1]
        self.assertEqual(final_manifest["releases"][0]["status"], "failed")
        self.assertEqual(
            final_manifest["releases"][0]["rollback_reason"],
            "post_cutover_stabilization_failed",
        )

    def test_execute_versioned_release_deploy_removes_route_after_failed_first_cutover(
        self,
    ):
        manifest_writes = []
        cleanup_targets = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        with (
            patch.object(
                engine_app_ops,
                "_resolve_commit_sha",
                return_value="fedcba9876543210",
            ),
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t130000z-fedcba987654",
            ),
            patch.object(
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
                    "has_previous_live_route": False,
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
                return_value={"ok": False, "path": None},
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
                                    stderr_lines=["worker exited after cutover"],
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
                return_value={"ok": True, "details": None},
            ),
            patch.object(
                engine_app_ops,
                "_restore_or_remove_caddy_route",
                side_effect=lambda ctx, session, app_config, *, previous_route_target=None, emit=None: (
                    cleanup_targets.append(previous_route_target)
                    or {"ok": True, "action": "removed", "details": None}
                ),
            ),
            patch.object(
                engine_app_ops,
                "_remove_release_runtime",
                return_value={"ok": True},
            ),
            patch.object(engine_app_ops.time, "sleep", return_value=None),
        ):
            result = engine_app_ops._execute_versioned_release_deploy(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                normalized_parts=["preflight", "sync"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(
            result["extra"]["cutover_status"],
            "reverted_after_stabilization_failure",
        )
        self.assertEqual(
            routed_probe_mock.call_count,
            engine_app_ops._RELEASE_STABILIZATION_ATTEMPTS,
        )
        self.assertEqual(result["extra"]["rollback_status"], "not_required")
        self.assertEqual(_failure_evidence(result)["source"], "failed_operation")
        self.assertEqual(
            _failure_evidence(result)["lines"],
            ["worker exited after cutover"],
        )
        self.assertEqual(result["extra"]["route_cleanup_status"], "removed")
        self.assertEqual(cleanup_targets, [None])
        self.assertIsNone(result["extra"]["release_inventory"]["live_release_id"])
        self.assertEqual(
            result["extra"]["release_entry"]["release_id"],
            "20260531t130000z-fedcba987654",
        )
        self.assertEqual(
            result["extra"]["release_entry"]["status"],
            "failed",
        )
        self.assertEqual(
            result["extra"]["release_inventory"]["releases"],
            result["extra"]["releases"],
        )
        self.assertEqual(manifest_writes[-1]["releases"][0]["status"], "failed")
        self.assertEqual(
            manifest_writes[-1]["releases"][0]["rollback_reason"],
            "post_cutover_stabilization_failed",
        )

    def test_execute_versioned_release_deploy_recovers_from_cutover_exceptions(self):
        cleanup_targets = []

        def run_deploy(*, caddy_result, routed_probe_result=None):
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
                    "_resolve_commit_sha",
                    return_value="fedcba9876543210",
                ),
                patch.object(
                    engine_app_ops,
                    "build_release_id",
                    return_value="20260531t130000z-fedcba987654",
                ),
                patch.object(
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
                        or {"ok": True, "action": "removed", "details": None}
                    ),
                ),
                patch.object(
                    engine_app_ops,
                    "_remove_release_runtime",
                    return_value={"ok": True},
                ),
            ):
                return engine_app_ops._execute_versioned_release_deploy(
                    self.ctx,
                    session=self.session,
                    app_config=self.app_config,
                    normalized_parts=["preflight", "sync"],
                )

        cutover_exception = run_deploy(
            caddy_result=RuntimeError("Caddy write interrupted"),
        )
        stabilization_exception = run_deploy(
            caddy_result={"ok": True, "details": None},
            routed_probe_result=RuntimeError("Routed probe interrupted"),
        )

        self.assertEqual(cutover_exception["status"], "error")
        self.assertEqual(
            cutover_exception["extra"]["cutover_status"],
            "traffic_switch_failed",
        )
        self.assertEqual(cutover_exception["details"], "Caddy write interrupted")
        self.assertEqual(_failure_evidence(cutover_exception)["phase"], "traffic_switch")
        self.assertEqual(_failure_evidence(cutover_exception)["source"], "exception")
        self.assertEqual(
            _failure_evidence(cutover_exception)["lines"],
            ["Caddy write interrupted"],
        )
        self.assertEqual(stabilization_exception["status"], "error")
        self.assertEqual(
            stabilization_exception["extra"]["cutover_status"],
            "reverted_after_unexpected_error",
        )
        self.assertEqual(
            stabilization_exception["details"],
            "Routed probe interrupted",
        )
        self.assertEqual(
            _failure_evidence(stabilization_exception)["phase"],
            "post_cutover_stabilization",
        )
        self.assertEqual(
            _failure_evidence(stabilization_exception)["lines"],
            ["Routed probe interrupted"],
        )
        self.assertEqual(cleanup_targets, [None, None])

    def test_execute_versioned_release_deploy_marks_release_failed_when_caddy_cutover_fails(
        self,
    ):
        manifest, previous_live = self._live_manifest()
        manifest_writes = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        with (
            patch.object(
                engine_app_ops,
                "_resolve_commit_sha",
                return_value="fedcba9876543210",
            ),
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t130000z-fedcba987654",
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
                return_value={"ok": False, "details": "caddy failed"},
            ),
            patch.object(
                engine_app_ops,
                "_remove_release_runtime",
                return_value={"ok": True},
            ),
        ):
            result = engine_app_ops._execute_versioned_release_deploy(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                normalized_parts=["preflight", "sync"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Switch live traffic to candidate release failed.")
        self.assertEqual(result["extra"]["route_cleanup_status"], "failed")
        self.assertEqual(result["extra"]["route_cleanup_details"], "caddy failed")
        self.assertEqual(_failure_evidence(result)["phase"], "traffic_switch")
        self.assertEqual(_failure_evidence(result)["completeness"], "boundary_only")
        self.assertEqual(_failure_evidence(result)["lines"], [])
        self.assertEqual(manifest_writes[-1]["releases"][0]["status"], "failed")

    def test_execute_versioned_release_deploy_aborts_when_candidate_worker_verification_fails(
        self,
    ):
        manifest, previous_live = self._live_manifest()
        manifest_writes = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        with (
            patch.object(
                engine_app_ops,
                "_resolve_commit_sha",
                return_value="fedcba9876543210",
            ),
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t130000z-fedcba987654",
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
                    "worker_container_name": "deploydash_worker_remix-blog_queue_candidate",
                    "result": {
                        "ok": False,
                        "output": SimpleNamespace(
                            stdout_lines=[],
                            stderr_lines=["worker process exited"],
                        ),
                    },
                },
            ),
            patch.object(
                engine_app_ops,
                "_remove_release_runtime",
                return_value={"ok": True},
            ),
            patch.object(
                engine_app_ops,
                "_write_caddy_route",
                side_effect=AssertionError("caddy cutover should not run"),
            ),
        ):
            result = engine_app_ops._execute_versioned_release_deploy(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                normalized_parts=["preflight", "sync"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(
            result["msg"],
            "Verify candidate worker process state failed.",
        )
        self.assertEqual(_failure_evidence(result)["phase"], "candidate_start")
        self.assertEqual(_failure_evidence(result)["source"], "failed_operation")
        self.assertEqual(_failure_evidence(result)["lines"], ["worker process exited"])
        self.assertEqual(
            manifest_writes[-1]["releases"][0]["rollback_reason"],
            "candidate_worker_verify_failed",
        )

    def test_execute_versioned_release_deploy_aborts_when_candidate_worker_start_fails(
        self,
    ):
        manifest, previous_live = self._live_manifest()
        manifest_writes = []

        def fake_write_manifest(host, app_config, payload):
            manifest_writes.append(copy.deepcopy(payload))

        def fake_run_remote_command(ctx, session, label, command, **kwargs):
            if label == "Start candidate worker":
                return {
                    "ok": False,
                    "details": "worker start failed",
                    "output": SimpleNamespace(
                        stdout_lines=[],
                        stderr_lines=["worker start failed"],
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
                "_resolve_commit_sha",
                return_value="fedcba9876543210",
            ),
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t130000z-fedcba987654",
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
            result = engine_app_ops._execute_versioned_release_deploy(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                normalized_parts=["preflight", "sync"],
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["msg"], "Start candidate worker failed.")
        self.assertEqual(_failure_evidence(result)["phase"], "candidate_start")
        self.assertEqual(_failure_evidence(result)["source"], "failed_operation")
        self.assertEqual(_failure_evidence(result)["lines"], ["worker start failed"])
        self.assertEqual(
            manifest_writes[-1]["releases"][0]["rollback_reason"],
            "candidate_worker_start_failed",
        )

    def test_execute_versioned_release_deploy_cancellation_reverts_after_traffic_switch(
        self,
    ):
        manifest, previous_live = self._live_manifest()
        routed_probe_calls = []

        with (
            patch.object(
                engine_app_ops,
                "_resolve_commit_sha",
                return_value="fedcba9876543210",
            ),
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t130000z-fedcba987654",
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
            result = engine_app_ops._execute_versioned_release_deploy(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                normalized_parts=["preflight", "sync"],
                is_cancelled=lambda: True,
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(
            result["extra"]["cutover_status"],
            "cancelled_after_traffic_switch",
        )
        self.assertEqual(
            result["extra"]["route_cleanup_status"],
            "restored",
        )
        self.assertNotIn("failure_evidence", result["extra"])
        self.assertEqual(routed_probe_calls, [])

    def test_execute_versioned_release_deploy_cancellation_removes_first_route(self):
        cleanup_targets = []

        with (
            patch.object(
                engine_app_ops,
                "_resolve_commit_sha",
                return_value="fedcba9876543210",
            ),
            patch.object(
                engine_app_ops,
                "build_release_id",
                return_value="20260531t130000z-fedcba987654",
            ),
            patch.object(
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
                return_value={"ok": True, "details": None},
            ),
            patch.object(
                engine_app_ops,
                "_restore_or_remove_caddy_route",
                side_effect=lambda ctx, session, app_config, *, previous_route_target=None, emit=None: (
                    cleanup_targets.append(previous_route_target)
                    or {"ok": True, "action": "removed", "details": None}
                ),
            ),
            patch.object(
                engine_app_ops,
                "_remove_release_runtime",
                return_value={"ok": True},
            ),
        ):
            result = engine_app_ops._execute_versioned_release_deploy(
                self.ctx,
                session=self.session,
                app_config=self.app_config,
                normalized_parts=["preflight", "sync"],
                is_cancelled=lambda: True,
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(result["extra"]["route_cleanup_status"], "removed")
        self.assertNotIn("failure_evidence", result["extra"])
        self.assertEqual(cleanup_targets, [None])


if __name__ == "__main__":
    unittest.main()
