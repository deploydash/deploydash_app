from __future__ import annotations

import unittest
from datetime import UTC, datetime

from orchestrator import app_parts
from orchestrator.app_parts import parse_app_config
from orchestrator.app_release_runtime import (
    append_or_replace_release,
    build_release_id,
    empty_release_manifest,
    find_release_entry,
    load_manifest_from_text,
    mark_release_failed,
    normalize_commit_sha,
    normalize_release_entry,
    normalize_release_manifest,
    normalize_worker_spec,
    previous_successful_release,
    prune_release_entries,
    release_entry_from_config,
    release_prune_candidates,
    render_manifest_write_command,
    set_live_release,
    sort_releases_newest_first,
    worker_specs_to_configs,
)


def _app_config():
    return parse_app_config(
        {
            "settings": {
                "project_slug": "remix-blog",
                "repository_full_name": "acme/remix-blog",
                "primary_domain": "blog.example.com",
                "workers": [
                    {
                        "id": "queue",
                        "name": "Queue worker",
                        "start_cmd": "python worker.py",
                        "cpu_limit": 0.5,
                        "memory_mb": 256,
                        "disk_mb": 1024,
                        "enabled": True,
                    }
                ],
            }
        }
    )


def _release_entry(
    *,
    release_id: str,
    commit_sha: str,
    status: str,
    deployment_kind: str,
    created_at: str,
):
    app_config = _app_config()
    entry = release_entry_from_config(
        app_config,
        release_id=release_id,
        commit_sha=commit_sha,
        status=status,
        deployment_kind=deployment_kind,
        image_name=app_config.release_image_name(release_id),
    )
    entry["created_at"] = created_at
    return entry


class TestAppReleaseRuntime(unittest.TestCase):
    def test_normalize_commit_sha_and_manual_release_id_fallback(self):
        self.assertIsNone(normalize_commit_sha(None))
        self.assertIsNone(normalize_commit_sha("not-a-sha"))
        self.assertEqual(
            normalize_commit_sha(" ABCDEF1234567890 "),
            "abcdef1234567890",
        )

        release_id = build_release_id(
            None,
            now=datetime(2026, 5, 31, 14, 23, 55, tzinfo=UTC),
        )
        self.assertEqual(release_id, "20260531t142355z-manual")

    def test_build_release_id_uses_timestamp_and_commit_prefix(self):
        release_id = build_release_id(
            "abcdef1234567890",
            now=datetime(2026, 5, 31, 14, 23, 55, tzinfo=UTC),
        )

        self.assertEqual(release_id, "20260531t142355z-abcdef123456")

    def test_normalize_release_manifest_filters_invalid_entries_and_defaults(self):
        manifest = normalize_release_manifest(
            {
                "retention_success_limit": 7,
                "releases": [
                    {
                        "release_id": " 20260531T120000Z-ABCDEF12 ",
                        "commit_sha": "ABCDEF1234567890",
                        "status": "unexpected",
                        "worker_specs": [
                            "bad-entry",
                            {
                                "id": "queue",
                                "name": "Queue worker",
                                "start_command": "python worker.py",
                            },
                        ],
                        "runtime_env": {"NODE_ENV": "production", "": "skip"},
                        "trust_network_names": ["deploydash_shared", "", 3],
                        "sqlite_snapshot_mounts": [{"mount_path": "/tmp"}],
                        "rollback_from_release_id": "prev-release",
                        "rollback_reason": "probe_failed",
                        "live_at": "2026-05-31T12:01:00Z",
                    },
                    {"release_id": None},
                ],
            }
        )

        self.assertEqual(manifest["retention_success_limit"], 7)
        self.assertEqual(len(manifest["releases"]), 1)
        entry = manifest["releases"][0]
        self.assertEqual(entry["release_id"], "20260531t120000z-abcdef12")
        self.assertEqual(entry["status"], "failed")
        self.assertEqual(entry["runtime_env"], {"NODE_ENV": "production"})
        self.assertEqual(entry["trust_network_names"], ["deploydash_shared"])
        self.assertEqual(entry["workers"][0]["id"], "queue")
        self.assertEqual(entry["rollback_from_release_id"], "prev-release")
        self.assertEqual(entry["rollback_reason"], "probe_failed")
        self.assertEqual(entry["live_at"], "2026-05-31T12:01:00Z")

        defaulted = normalize_release_manifest({"releases": "not-a-list"})
        self.assertEqual(defaulted, empty_release_manifest())
        self.assertEqual(normalize_release_manifest("bad-payload"), empty_release_manifest())

    def test_normalize_release_entry_and_worker_spec_validate_inputs(self):
        self.assertIsNone(normalize_release_entry(None))
        self.assertIsNone(normalize_release_entry({"release_id": None}))
        self.assertIsNone(normalize_release_entry({"release_id": "INVALID!"}))

        entry = normalize_release_entry(
            {
                "release_id": "release-1",
                "commit_sha": "abcdef1234567890",
                "branch": 5,
                "created_at": 10,
                "deployment_kind": 3,
                "web_container_name": 8,
                "worker_container_names": ["worker-1", "", None],
                "image_name": 4,
                "runtime_env": "bad",
                "app_port": "3000",
                "sqlite_storage": "bad",
                "sqlite_snapshot_mounts": "bad",
                "trust_network_names": "bad",
                "rollback_from_release_id": 5,
                "rollback_reason": 6,
                "live_at": 7,
            }
        )
        self.assertEqual(entry["branch"], "main")
        self.assertEqual(entry["deployment_kind"], "deploy")
        self.assertEqual(entry["web_container_name"], "")
        self.assertEqual(entry["worker_container_names"], ["worker-1"])
        self.assertEqual(entry["image_name"], "")
        self.assertEqual(entry["runtime_env"], {})
        self.assertIsNone(entry["app_port"])
        self.assertIsNone(entry["sqlite_storage"])
        self.assertEqual(entry["sqlite_snapshot_mounts"], [])
        self.assertEqual(entry["trust_network_names"], [])
        self.assertIsNone(entry["rollback_from_release_id"])
        self.assertIsNone(entry["rollback_reason"])
        self.assertIsNone(entry["live_at"])

        self.assertIsNone(normalize_worker_spec(None))
        self.assertIsNone(normalize_worker_spec({"id": "", "name": "x", "start_command": "run"}))
        self.assertIsNone(normalize_worker_spec({"id": "x", "name": "", "start_command": "run"}))
        self.assertIsNone(normalize_worker_spec({"id": "x", "name": "Worker", "start_command": ""}))

        worker = normalize_worker_spec(
            {
                "id": "queue",
                "name": "Queue worker",
                "start_command": "python worker.py",
            }
        )
        self.assertEqual(worker["cpu_limit"], 0.5)
        self.assertEqual(worker["memory_mb"], 256)
        self.assertEqual(worker["disk_mb"], 1024)
        self.assertTrue(worker["enabled"])

    def test_set_live_release_promotes_candidate_and_retains_previous_live(self):
        manifest = empty_release_manifest()
        manifest = append_or_replace_release(
            manifest,
            _release_entry(
                release_id="20260531t120000z-abcdef12",
                commit_sha="abcdef1234567890",
                status="live",
                deployment_kind="deploy",
                created_at="2026-05-31T12:00:00Z",
            ),
        )
        manifest = append_or_replace_release(
            manifest,
            _release_entry(
                release_id="20260531t130000z-fedcba98",
                commit_sha="fedcba9876543210",
                status="candidate",
                deployment_kind="deploy",
                created_at="2026-05-31T13:00:00Z",
            ),
        )

        set_live_release(
            manifest,
            live_release_id="20260531t130000z-fedcba98",
            retained_release_id="20260531t120000z-abcdef12",
        )

        self.assertEqual(
            manifest["releases"][0]["release_id"],
            "20260531t130000z-fedcba98",
        )
        self.assertEqual(manifest["releases"][0]["status"], "live")
        self.assertIsNotNone(manifest["releases"][0]["live_at"])
        previous = previous_successful_release(
            manifest,
            excluding_release_id="20260531t130000z-fedcba98",
        )
        self.assertIsNotNone(previous)
        self.assertEqual(previous["release_id"], "20260531t120000z-abcdef12")
        self.assertEqual(previous["status"], "retained")

        manifest = append_or_replace_release(
            empty_release_manifest(),
            _release_entry(
                release_id="20260531t150000z-aabbccdd",
                commit_sha="aabbccddeeff0011",
                status="live",
                deployment_kind="deploy",
                created_at="2026-05-31T15:00:00Z",
            ),
        )
        manifest = append_or_replace_release(
            manifest,
            _release_entry(
                release_id="20260531t160000z-bbccddee",
                commit_sha="bbccddee11223344",
                status="candidate",
                deployment_kind="deploy",
                created_at="2026-05-31T16:00:00Z",
            ),
        )
        set_live_release(
            manifest,
            live_release_id="20260531t160000z-bbccddee",
        )
        self.assertEqual(
            find_release_entry(manifest, "20260531t150000z-aabbccdd")["status"],
            "retained",
        )

    def test_find_sort_and_previous_release_helpers_cover_edge_cases(self):
        manifest = empty_release_manifest()
        live = _release_entry(
            release_id="20260531t120000z-abcdef12",
            commit_sha="abcdef1234567890",
            status="live",
            deployment_kind="deploy",
            created_at="2026-05-31T12:00:00Z",
        )
        retained = _release_entry(
            release_id="20260530t120000z-fedcba98",
            commit_sha="fedcba9876543210",
            status="retained",
            deployment_kind="deploy",
            created_at="2026-05-30T12:00:00Z",
        )
        manifest = append_or_replace_release(manifest, retained)
        manifest = append_or_replace_release(manifest, live)

        self.assertIsNone(find_release_entry(manifest, None))
        self.assertEqual(
            find_release_entry(manifest, " 20260531T120000Z-ABCDEF12 ")["status"],
            "live",
        )
        self.assertEqual(
            [entry["release_id"] for entry in sort_releases_newest_first([retained, live])],
            ["20260531t120000z-abcdef12", "20260530t120000z-fedcba98"],
        )
        self.assertEqual(
            previous_successful_release(
                manifest,
                excluding_release_id="20260531t120000z-abcdef12",
            )["release_id"],
            "20260530t120000z-fedcba98",
        )
        retained["status"] = "failed"
        self.assertEqual(
            previous_successful_release(
                manifest,
                excluding_release_id="20260530t120000z-fedcba98",
            )["release_id"],
            "20260531t120000z-abcdef12",
        )
        self.assertIsNone(
            previous_successful_release(
                empty_release_manifest(),
                excluding_release_id="missing",
            )
        )

    def test_release_prune_candidates_keeps_live_previous_and_recent_limit(self):
        manifest = empty_release_manifest()
        manifest["retention_success_limit"] = 3

        for index, (release_id, status) in enumerate(
            [
                ("20260527t120000z-abcdef01", "retained"),
                ("20260528t120000z-abcdef02", "retained"),
                ("20260529t120000z-abcdef03", "retained"),
                ("20260530t120000z-abcdef04", "retained"),
                ("20260531t120000z-abcdef05", "live"),
            ],
            start=1,
        ):
            manifest = append_or_replace_release(
                manifest,
                _release_entry(
                    release_id=release_id,
                    commit_sha=f"abcdef123456789{index}",
                    status=status,
                    deployment_kind="deploy",
                    created_at=f"2026-05-{26 + index:02d}T12:00:00Z",
                ),
            )

        prune_candidates = release_prune_candidates(manifest)

        self.assertEqual(
            [entry["release_id"] for entry in prune_candidates],
            [
                "20260528t120000z-abcdef02",
                "20260527t120000z-abcdef01",
            ],
        )

    def test_release_prune_candidates_defaults_and_prune_entries(self):
        manifest = empty_release_manifest()
        self.assertEqual(release_prune_candidates(manifest), [])

        manifest["retention_success_limit"] = 1
        for index, (release_id, status) in enumerate(
            [
                ("20260526t120000z-abcdef00", "retained"),
                ("20260527t120000z-abcdef01", "retained"),
                ("20260528t120000z-abcdef02", "retained"),
                ("20260529t120000z-abcdef03", "retained"),
                ("20260530t120000z-abcdef04", "retained"),
                ("20260531t110000z-abcdef05", "retained"),
                ("20260531t120000z-abcdef06", "live"),
            ],
            start=1,
        ):
            manifest = append_or_replace_release(
                manifest,
                _release_entry(
                    release_id=release_id,
                    commit_sha=f"abcdef123456789{index}",
                    status=status,
                    deployment_kind="deploy",
                    created_at=f"2026-05-{25 + index:02d}T12:00:00Z",
                ),
            )

        prune_candidates = release_prune_candidates(manifest)
        self.assertEqual(
            [entry["release_id"] for entry in prune_candidates],
            [
                "20260527t120000z-abcdef01",
                "20260526t120000z-abcdef00",
            ],
        )
        prune_release_entries(
            manifest,
            [
                "20260527t120000z-abcdef01",
                "20260526t120000z-abcdef00",
                4,
            ],
        )
        self.assertIsNone(find_release_entry(manifest, "20260527t120000z-abcdef01"))
        self.assertIsNone(find_release_entry(manifest, "20260526t120000z-abcdef00"))

        retained_only = empty_release_manifest()
        retained_only["retention_success_limit"] = 2
        for index in range(3):
            retained_only = append_or_replace_release(
                retained_only,
                _release_entry(
                    release_id=f"2026052{index + 1}t120000z-retained{index}",
                    commit_sha=f"abcdef123456789{index}",
                    status="retained",
                    deployment_kind="deploy",
                    created_at=f"2026-05-2{index + 1}T12:00:00Z",
                ),
            )
        self.assertEqual(len(release_prune_candidates(retained_only)), 1)

    def test_mark_release_failed_preserves_rollback_metadata(self):
        manifest = append_or_replace_release(
            empty_release_manifest(),
            _release_entry(
                release_id="20260531t120000z-abcdef12",
                commit_sha="abcdef1234567890",
                status="candidate",
                deployment_kind="rollback",
                created_at="2026-05-31T12:00:00Z",
            ),
        )

        mark_release_failed(
            manifest,
            release_id="20260531t120000z-abcdef12",
            rollback_from_release_id="20260530t110000z-fedcba98",
            rollback_reason="post_cutover_stabilization_failed",
        )

        entry = manifest["releases"][0]
        self.assertEqual(entry["status"], "failed")
        self.assertEqual(
            entry["rollback_from_release_id"],
            "20260530t110000z-fedcba98",
        )
        self.assertEqual(
            entry["rollback_reason"],
            "post_cutover_stabilization_failed",
        )

        untouched = mark_release_failed(
            manifest,
            release_id="missing-release",
            rollback_from_release_id="other",
            rollback_reason="noop",
        )
        self.assertIs(untouched, manifest)

        without_rollback_metadata = append_or_replace_release(
            empty_release_manifest(),
            _release_entry(
                release_id="20260531t130000z-fedcba98",
                commit_sha="fedcba9876543210",
                status="candidate",
                deployment_kind="deploy",
                created_at="2026-05-31T13:00:00Z",
            ),
        )
        mark_release_failed(
            without_rollback_metadata,
            release_id="20260531t130000z-fedcba98",
        )
        self.assertIsNone(without_rollback_metadata["releases"][0]["rollback_from_release_id"])
        self.assertIsNone(without_rollback_metadata["releases"][0]["rollback_reason"])

    def test_params_schema_allows_an_optional_empty_payload(self):
        """Cover the operation shape with no required settings or top-level keys."""
        schema = app_parts._params_schema()

        self.assertNotIn("required", schema)
        self.assertEqual(schema["properties"]["settings"]["required"], [])

    def test_render_manifest_write_command_and_load_manifest_from_text(self):
        app_config = _app_config()
        canary = "DD_TEST_SECRET_DO_NOT_LOG_7f4c"
        manifest = empty_release_manifest()
        manifest["releases"] = [
            {
                "release_id": "20260531t120000z-abcdef12",
                "status": "live",
                "runtime_env": {"FEATURE_FLAG": canary},
            }
        ]
        command = render_manifest_write_command(app_config, manifest)
        self.assertIn(app_config.release_manifest_path, command)
        self.assertIn("chmod 600", command)
        self.assertNotIn(canary, command)
        self.assertNotIn('"releases"', command)

        self.assertEqual(load_manifest_from_text(None), empty_release_manifest())
        self.assertEqual(load_manifest_from_text("not-json"), empty_release_manifest())
        loaded = load_manifest_from_text(
            '{"releases":[{"release_id":"release-1","status":"retained"}]}'
        )
        self.assertEqual(loaded["releases"][0]["release_id"], "release-1")

    def test_worker_specs_to_configs_skips_invalid_items(self):
        configs = worker_specs_to_configs(
            [
                "bad-entry",
                {
                    "id": "queue",
                    "name": "Queue worker",
                    "start_command": "python worker.py",
                    "enabled": False,
                },
            ]
        )
        self.assertEqual(len(configs), 1)
        self.assertEqual(configs[0].id, "queue")
        self.assertFalse(configs[0].enabled)


if __name__ == "__main__":
    unittest.main()
