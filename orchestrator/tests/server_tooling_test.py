import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from typing import ClassVar
from unittest.mock import Mock, patch

from orchestrator import engine, managed_software
from orchestrator.infra_parts import tooling as engine_infra_ops
from orchestrator.managed_software import (
    MANAGED_SOFTWARE_MANIFEST,
    ManagedSoftwareLedgerFormatError,
    _status_from_current,
    build_managed_software_status,
    empty_software_ledger,
    encode_software_ledger,
    normalize_component_ids,
    normalize_walg_version,
    parse_software_ledger,
    record_component_action,
)
from orchestrator.plugins.server_plugin import build_plugin
from orchestrator.postgres_supply_chain import (
    postgres_extension_image_dockerfiles_by_variant,
)
from tests.engine_context_fixtures import build_test_context


class _FakeOutput:
    stdout_lines: ClassVar[list[str]] = [
        "railpack_version=0.29.0",
        "helper_present=1",
        "helper_current=1",
        "env_present=1",
        "env_current=1",
        "docker_version=26.1.0",
        "docker_compose_version=2.27.0",
        "containerd_version=1.7.0",
        "docker_daemon_config_present=1",
        "docker_daemon_config_current=1",
        "caddy_stack_present=1",
        "caddy_compose_image=caddy:2.11.2-alpine",
        "caddy_image_current=1",
        "caddy_helper_present=1",
        "caddy_helper_current=1",
        "postgres_stack_present=0",
        "postgres_compose_image=",
        "postgres_container_present=0",
        "postgres_container_running=0",
        "fail2ban_version=1.0",
        "auditd_version=3.0",
        "unattended_upgrades_version=2.9",
        "sysstat_version=12.6",
        "haveged_version=1.9",
        "unattended_upgrades_enabled=1",
    ]
    stderr_lines: ClassVar[list[str]] = []


class _FakeHost:
    def __init__(self, ok=True):
        self.ok = ok
        self.commands = []

    def run_shell_command(self, command, _timeout=None, _sudo=True):
        self.command = command
        self.commands.append(command)
        self.timeout = _timeout
        self.sudo = _sudo
        return self.ok, _FakeOutput()


class _FakeSession:
    def __init__(self, ok=True, disconnect_error=None):
        self.host = _FakeHost(ok=ok)
        self.disconnect_error = disconnect_error

    def close(self):
        return {"disconnect_error": self.disconnect_error}


class TestServerToolingOperations(unittest.TestCase):
    @staticmethod
    def _error_result(code, msg, stage, details=None, extra=None):
        return {
            "status": "error",
            "code": code,
            "msg": msg,
            "stage": stage,
            "details": details,
            **(extra or {}),
        }

    @staticmethod
    def _managed_update_status(component_id, *, status="update_available"):
        return {
            "ok": True,
            "payload": {},
            "tooling": {},
            "capabilities": {},
            "software_ledger": empty_software_ledger(),
            "managed_software": {
                component_id: {
                    "label": MANAGED_SOFTWARE_MANIFEST[component_id]["label"],
                    "current": "current-version",
                    "target": "target-version",
                    "can_update": status == "update_available",
                    "status": status,
                }
            },
        }

    def test_tooling_status_from_payload_marks_stale_components(self):
        status = engine_infra_ops._tooling_status_from_payload(
            {
                "railpack_version": "0.18.0",
                "helper_present": "1",
                "helper_current": "0",
                "env_present": "0",
                "env_current": "0",
            }
        )

        self.assertEqual(status["railpack"]["status"], "update_available")
        self.assertEqual(status["railpack"]["current"], "0.18.0")
        self.assertEqual(status["railpack"]["target"], "0.29.0")
        self.assertEqual(
            status["railpack_build_helper"]["status"],
            "update_available",
        )
        self.assertEqual(status["railpack_defaults"]["status"], "missing")
        self.assertTrue(engine_infra_ops._tooling_update_available(status))

    def test_tooling_status_from_payload_marks_current_components(self):
        status = engine_infra_ops._tooling_status_from_payload(
            {
                "railpack_version": "0.29.0",
                "helper_present": "1",
                "helper_current": "1",
                "env_present": "1",
                "env_current": "1",
            }
        )

        self.assertEqual(status["railpack"]["status"], "current")
        self.assertEqual(status["railpack_build_helper"]["status"], "current")
        self.assertEqual(status["railpack_defaults"]["status"], "current")
        self.assertFalse(engine_infra_ops._tooling_update_available(status))

    def test_server_capabilities_group_managed_artifacts(self):
        capabilities = engine_infra_ops._server_capabilities_from_payload(
            {
                "railpack_version": "0.18.0",
                "helper_present": "1",
                "helper_current": "0",
                "env_present": "1",
                "env_current": "0",
                "docker_version": "26.1.0",
                "docker_compose_version": "2.27.0",
                "containerd_version": "1.7.0",
                "docker_daemon_config_present": "1",
                "docker_daemon_config_current": "1",
                "caddy_stack_present": "1",
                "caddy_compose_image": "caddy:2.11.2-alpine",
                "caddy_helper_present": "1",
                "caddy_helper_current": "1",
                "postgres_stack_present": "0",
                "postgres_container_present": "0",
                "fail2ban_version": "1.0",
                "auditd_version": "3.0",
                "unattended_upgrades_version": "2.9",
                "sysstat_version": "12.6",
                "haveged_version": "1.9",
                "unattended_upgrades_enabled": "1",
            }
        )

        railpack = capabilities["railpack_build_system"]
        self.assertEqual(railpack["status"], "update_available")
        self.assertEqual(railpack["action_label"], "Update Railpack build system")
        self.assertTrue(railpack["can_update"])
        self.assertEqual(
            capabilities["postgresql_database_service"]["status"],
            "not_configured",
        )
        security = capabilities["server_security_baseline"]
        self.assertEqual(
            security["summary"],
            "fail2ban, auditd, sysstat, unattended upgrades",
        )
        self.assertNotIn("haveged", [detail["label"] for detail in security["details"]])
        self.assertTrue(engine_infra_ops._capability_update_available(capabilities))

    def test_server_capabilities_do_not_advertise_removed_milvus_service(self):
        capabilities = engine_infra_ops._server_capabilities_from_payload(
            {
                "railpack_version": "0.29.0",
                "helper_present": "1",
                "helper_current": "1",
                "env_present": "1",
                "env_current": "1",
                "docker_version": "26.1.0",
                "docker_compose_version": "2.27.0",
                "containerd_version": "1.7.0",
                "docker_daemon_config_present": "1",
                "docker_daemon_config_current": "1",
                "caddy_stack_present": "1",
                "caddy_compose_image": "caddy:2.11.2-alpine",
                "caddy_helper_present": "1",
                "caddy_helper_current": "1",
                "postgres_stack_present": "1",
                "postgres_compose_image": (
                    "deploydash/postgres-ext:17.10-bookworm-vector-pg-search"
                ),
                "postgres_container_present": "1",
                "postgres_container_running": "1",
                "fail2ban_version": "1.0",
                "auditd_version": "3.0",
                "unattended_upgrades_version": "2.9",
                "sysstat_version": "12.6",
                "haveged_version": "1.9",
                "unattended_upgrades_enabled": "1",
            }
        )

        self.assertTrue(capabilities)
        self.assertFalse(any("milvus" in key.lower() for key in capabilities))
        self.assertFalse(
            any(
                "milvus" in capability["label"].lower()
                or "milvus" in capability["description"].lower()
                for capability in capabilities.values()
            )
        )

    def test_capability_helpers_cover_stale_missing_and_attention_states(self):
        stale = engine_infra_ops._capability_detail(
            label="Helper",
            current="old",
            target="new",
        )
        missing = engine_infra_ops._capability_detail(
            label="Helper",
            current="",
            target="new",
        )
        absent_image = engine_infra_ops._stack_image_detail(
            {},
            "missing_image",
            "Image",
            "target:image",
        )

        self.assertEqual(stale["status"], "update_available")
        self.assertEqual(missing["status"], "missing")
        self.assertEqual(absent_image["status"], "not_configured")
        self.assertEqual(
            engine_infra_ops._details_status([missing]),
            "missing",
        )
        self.assertEqual(
            engine_infra_ops._details_status(
                [{"status": "needs_attention"}],
            ),
            "needs_attention",
        )

    def test_tooling_status_command_checks_pinned_railpack_contract(self):
        command = engine_infra_ops._build_server_tooling_status_command()

        self.assertIn("railpack --version", command)
        self.assertIn(
            "ghcr.io/railwayapp/railpack-frontend:v0.29.0",
            command,
        )
        self.assertIn(
            "sha256:683f0eba680f38d009290100ae3ceded667a1536687ce25696fe9f4e91abfd2b",
            command,
        )
        self.assertIn("RAILPACK_FRONTEND_IMAGE_DIGEST=", command)
        self.assertIn("/usr/local/bin/deploydash-railpack-build", command)
        self.assertIn("caddy validate --config /etc/caddy/Caddyfile", command)
        self.assertIn("caddy_container_readiness_status", command)
        self.assertIn("named-checkconf /etc/bind/named.conf", command)
        self.assertIn("bind_container_readiness_status", command)
        self.assertIn('pg_isready -U "$POSTGRES_USER" -d postgres', command)
        self.assertIn("postgres_container_readiness_status", command)
        self.assertIn("/opt/deploydash/stack/railpack/railpack.env", command)
        self.assertIn("/opt/deploydash/stack/postgres", command)
        self.assertIn("caddy:2.11.2-alpine", command)
        self.assertNotIn("haveged", command)

    def test_tooling_status_command_checks_for_newer_docker_series_patches(self):
        """The status probe must compare held packages with their apt series."""
        command = engine_infra_ops._build_server_tooling_status_command()

        self.assertIn("apt-cache madison", command)
        self.assertIn("dpkg --compare-versions", command)
        self.assertIn("docker_ce_patch_candidate", command)
        self.assertIn("docker_ce_cli_patch_candidate", command)
        self.assertIn("containerd_patch_candidate", command)
        self.assertIn("docker_compose_plugin_patch_candidate", command)

    def test_docker_patch_probe_ignores_absent_and_unparseable_candidates(self):
        """Madison noise must not hide a valid newer patch or invent an update."""
        script = (
            'kv(){ printf "%s=%s\\n" "$1" "$2"; }; '
            'pkg(){ case "$1" in '
            'docker-ce|docker-ce-cli) printf "%s" "5:29.6.0-1" ;; '
            'containerd.io) printf "%s" "2.2.5-1" ;; '
            'docker-compose-plugin) printf "%s" "5.1.4-1" ;; '
            "esac; }; "
            'apt-cache(){ case "$2" in '
            'docker-ce) printf "%s\\n" '
            '" docker-ce | 5:29.7.0-1 | repo" '
            '" docker-ce | 5:29.6.bad | repo" '
            '" docker-ce | 5:29.6.1-1 | repo" ;; '
            'docker-ce-cli) printf "%s\\n" '
            '" docker-ce-cli | 5:29.6.0-1 | repo" ;; '
            'containerd.io) printf "%s\\n" '
            '" containerd.io | 2.3.0-1 | repo" ;; '
            'docker-compose-plugin) printf "%s\\n" '
            '" docker-compose-plugin | nonsense | repo" ;; '
            "esac; }; " + engine_infra_ops._docker_patch_probe_shell()
        )

        result = subprocess.run(
            ["bash", "-c", script],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(payload["docker_ce_patch_candidate"], "5:29.6.1-1")
        self.assertEqual(payload["docker_ce_cli_patch_candidate"], "")
        self.assertEqual(payload["containerd_patch_candidate"], "")
        self.assertEqual(payload["docker_compose_plugin_patch_candidate"], "")

    # Gateway status must read the base label stamped into the custom
    # Caddy build, so a current custom build reports current (#91).
    def test_tooling_status_command_reads_custom_caddy_base_label(self):
        command = engine_infra_ops._build_server_tooling_status_command()

        self.assertIn("caddy_base_label", command)
        self.assertIn('index .Config.Labels "deploydash.caddy_base"', command)
        self.assertIn("docker image inspect", command)
        self.assertIn("deploydash_caddy_custom:local", command)

    def test_managed_backup_hygiene_tightens_the_existing_tree(self):
        """The next managed mutation must make every existing snapshot private."""
        command = engine_infra_ops._managed_backup_hygiene_command()

        self.assertIn("umask 077", command)
        self.assertIn("install -d -m 700 /opt/deploydash/state/upgrade-backups", command)
        self.assertIn("chown -R root:root", command)
        self.assertIn("-type d -exec chmod 700", command)
        self.assertIn("-type f -exec chmod 600", command)

    def test_managed_backup_retention_keeps_the_protected_snapshot_and_two_newest(self):
        """Pruning must bound storage without deleting the ledger rollback target."""
        with tempfile.TemporaryDirectory() as temp_dir:
            service_dirs = {
                "postgres": f"{temp_dir}/postgres",
                "postgresql_database_service": f"{temp_dir}/postgresql_database_service",
            }
            snapshots = [
                f"{service_dirs['postgres']}/20260101T000000Z",
                f"{service_dirs['postgres']}/20260201T000000Z",
                f"{service_dirs['postgres']}/20260301T000000Z",
                f"{service_dirs['postgresql_database_service']}/pre-rollback-20260401T000000Z",
            ]
            for index, snapshot in enumerate(snapshots, start=1):
                os.makedirs(snapshot)
                os.utime(snapshot, (index, index))

            with patch.object(
                engine_infra_ops.server_paths,
                "upgrade_backup_service_dir",
                side_effect=lambda service: service_dirs[service],
            ):
                command = engine_infra_ops._managed_backup_retention_command(
                    "postgresql_database_service",
                    protected_backup_dir=snapshots[0],
                )
            completed = subprocess.run(
                ["bash", "-c", command],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue(os.path.isdir(snapshots[0]))
            self.assertFalse(os.path.exists(snapshots[1]))
            self.assertTrue(os.path.isdir(snapshots[2]))
            self.assertTrue(os.path.isdir(snapshots[3]))
            retained = engine_infra_ops._parse_managed_backup_retention_output(
                Mock(stdout_lines=completed.stdout.splitlines()),
            )
            self.assertEqual(
                {item["path"] for item in retained},
                {snapshots[0], snapshots[2], snapshots[3]},
            )
            self.assertTrue(all(item["size_bytes"] >= 0 for item in retained))

    def test_managed_backup_retention_parser_rejects_untrusted_records(self):
        """Only unique paths with non-negative byte counts may enter the ledger."""
        output = Mock(
            stdout_lines=[
                "noise",
                "removed_upgrade_backup=/old",
                "retained_upgrade_backup=no-tab",
                "retained_upgrade_backup=\t2",
                "retained_upgrade_backup=/bad\tnot-a-number",
                "retained_upgrade_backup=/negative\t-1",
                "retained_upgrade_backup=/kept\t7",
                "retained_upgrade_backup=/kept\t8",
            ]
        )

        self.assertEqual(
            engine_infra_ops._parse_managed_backup_retention_output(output),
            [{"path": "/kept", "size_bytes": 7}],
        )
        self.assertEqual(
            engine_infra_ops._parse_managed_backup_retention_output(Mock(stdout_lines=None)),
            [],
        )

    def test_non_postgres_retention_uses_only_its_component_namespace(self):
        """One component must never enumerate another component's snapshots."""
        command = engine_infra_ops._managed_backup_retention_command(
            "http_gateway",
            protected_backup_dir="/opt/deploydash/state/upgrade-backups/http_gateway/current",
        )

        self.assertIn("upgrade-backups/http_gateway", command)
        self.assertNotIn("upgrade-backups/postgres ", command)
        self.assertNotIn("upgrade-backups/postgresql_database_service", command)

    def test_tooling_status_dry_run_describes_checks(self):
        ctx = build_test_context()
        result = engine_infra_ops.run_server_tooling_status_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            dry_run=True,
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "tooling_status")
        self.assertIn("Read Railpack CLI version", result["actions"])

    def test_tooling_status_returns_preflight_cancellation_error(self):
        ctx = build_test_context()
        result = engine_infra_ops.run_server_tooling_status_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            is_cancelled=lambda: True,
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(result["stage"], "preflight")

    def test_tooling_status_returns_open_session_error(self):
        open_error = {
            "status": "error",
            "code": "ENGINE_CONNECTION_FAILED",
            "msg": "Could not connect.",
            "stage": "open_runtime_session",
            "details": None,
        }

        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": False, "error": open_error},
        )
        result = engine_infra_ops.run_server_tooling_status_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
        )

        self.assertEqual(result, open_error)

    def test_tooling_status_returns_runtime_error_from_status_reader(self):
        session = _FakeSession()
        runtime_error = {
            "status": "error",
            "code": "ENGINE_RUNTIME_ERROR",
            "msg": "Failed to read tooling status.",
            "stage": "execute_runtime_operation",
            "details": "remote failed",
        }

        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
        )
        with patch.object(
            engine_infra_ops,
            "_read_server_tooling_status",
            lambda *_args, **_kwargs: {
                "ok": False,
                "error": runtime_error,
            },
        ):
            result = engine_infra_ops.run_server_tooling_status_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
            )

        self.assertEqual(result, runtime_error)

    def test_tooling_status_live_operation_reports_capabilities(self):
        session = _FakeSession()
        tooling = {
            "railpack": {"status": "current"},
        }
        capabilities = {
            "railpack_build_system": {"status": "current", "can_update": False},
        }
        managed_software = {
            "railpack_build_system": {"status": "current", "can_update": False},
        }

        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
        )
        with patch.object(
            engine_infra_ops,
            "_read_server_tooling_status",
            lambda *_args, **_kwargs: {
                "ok": True,
                "tooling": tooling,
                "capabilities": capabilities,
                "managed_software": managed_software,
                "software_ledger": {},
            },
        ):
            result = engine_infra_ops.run_server_tooling_status_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
            )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "tooling_status")
        self.assertEqual(result["tooling"], tooling)
        self.assertEqual(result["capabilities"], capabilities)
        self.assertEqual(result["managed_software"], managed_software)
        self.assertFalse(result["update_available"])
        self.assertEqual(result["msg"], "Server capabilities are up to date.")

    def test_tooling_status_emits_disconnect_warning(self):
        session = _FakeSession(disconnect_error="disconnect failed")
        emit_event = Mock()

        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=emit_event,
        )
        with patch.object(
            engine_infra_ops,
            "_read_server_tooling_status",
            lambda *_args, **_kwargs: {
                "ok": True,
                "tooling": {},
                "capabilities": {},
                "managed_software": {},
                "software_ledger": {},
            },
        ):
            result = engine_infra_ops.run_server_tooling_status_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
            )

        self.assertEqual(result["status"], "success")
        emit_event.assert_any_call(
            None,
            "connection_disconnect_error",
            "disconnect failed",
            level="warning",
        )

    def test_read_server_tooling_status_parses_remote_payload(self):
        session = _FakeSession()
        ctx = build_test_context()

        result = engine_infra_ops._read_server_tooling_status(ctx, session)

        self.assertTrue(result["ok"])
        self.assertEqual(result["tooling"]["railpack"]["status"], "current")
        self.assertEqual(
            result["capabilities"]["railpack_build_system"]["status"],
            "current",
        )
        self.assertEqual(
            result["capabilities"]["postgresql_database_service"]["status"],
            "not_configured",
        )
        self.assertEqual(
            result["managed_software"]["railpack_build_system"]["status"],
            "current",
        )
        self.assertIn("railpack --version", session.host.commands[0])
        self.assertEqual(session.host.timeout, 20)
        self.assertTrue(session.host.sudo)

    def test_read_server_tooling_status_returns_runtime_error(self):
        session = _FakeSession(ok=False)
        ctx = build_test_context(
            error_result=lambda code, msg, stage, details=None, extra=None: {
                "status": "error",
                "code": code,
                "msg": msg,
                "stage": stage,
                "details": details,
                **(extra or {}),
            },
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "",
        )

        result = engine_infra_ops._read_server_tooling_status(ctx, session)

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "ENGINE_RUNTIME_ERROR")

    def test_software_ledger_remote_read_and_write_failure_paths(self):
        session = _FakeSession(ok=False)
        ctx = build_test_context()
        self.assertEqual(
            engine_infra_ops._read_remote_software_ledger(ctx, session),
            empty_software_ledger(),
        )

        expected = {"ok": True}
        with patch.object(
            engine_infra_ops,
            "write_remote_text_file",
            return_value=expected,
        ) as write_remote_text_file:
            result = engine_infra_ops._write_remote_software_ledger(
                ctx,
                session,
                empty_software_ledger(),
            )

        self.assertIs(result, expected)
        self.assertEqual(
            write_remote_text_file.call_args.kwargs["path"],
            engine_infra_ops.MANAGED_SOFTWARE_LEDGER_PATH,
        )

    def test_software_ledger_write_errors_are_structured_and_defensive(self):
        """Only an explicit failed remote write becomes a mutation error."""
        ctx = build_test_context(error_result=self._error_result)

        self.assertIsNone(engine_infra_ops._software_ledger_write_error(ctx, None, "ignored"))
        self.assertIsNone(
            engine_infra_ops._software_ledger_write_error(
                ctx,
                {"ok": True},
                "ignored",
            )
        )
        error = engine_infra_ops._software_ledger_write_error(
            ctx,
            {"ok": False, "details": ""},
            "Could not write ledger.",
        )

        self.assertEqual(error["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(error["msg"], "Could not write ledger.")
        self.assertEqual(error["details"], "managed-software ledger write failed")

    def test_tooling_update_dry_run_reports_selected_components(self):
        ctx = build_test_context()
        result = engine_infra_ops.run_server_tooling_update_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            component_ids=["railpack_build_system"],
            dry_run=True,
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "tooling_update")
        self.assertEqual(result["component_ids"], ["railpack_build_system"])
        self.assertIn("managed_software_manifest", result)

    def test_tooling_update_dry_run_rejects_unknown_component(self):
        ctx = build_test_context(
            error_result=lambda code, msg, stage, details=None, extra=None: {
                "status": "error",
                "code": code,
                "msg": msg,
                "stage": stage,
                "details": details,
                **(extra or {}),
            },
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "",
        )

        result = engine_infra_ops.run_server_tooling_update_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            component_ids=["unknown"],
            dry_run=True,
        )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")

    def test_tooling_update_dry_run_allows_missing_event_emitter(self):
        def _unconfigured_emit_event(*_args, **_kwargs):
            raise AssertionError("emit_event should not be called in dry_run")

        ctx = build_test_context(
            error_result=lambda code, msg, stage, details=None, extra=None: {
                "status": "error",
                "code": code,
                "msg": msg,
                "stage": stage,
                "details": details,
                **(extra or {}),
            },
            emit_event=_unconfigured_emit_event,
            emit_shell_output_lines=lambda *_args, **_kwargs: None,
            command_error_details=lambda _output: "",
        )

        result = engine_infra_ops.run_server_tooling_update_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            dry_run=True,
            emit=object(),
        )

        self.assertEqual(result["status"], "success")

    def test_tooling_update_returns_preflight_cancellation_error(self):
        ctx = build_test_context(error_result=self._error_result)
        result = engine_infra_ops.run_server_tooling_update_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            is_cancelled=lambda: True,
        )

        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(result["stage"], "preflight")

    def test_tooling_update_returns_open_session_error(self):
        open_error = self._error_result(
            "ENGINE_CONNECTION_FAILED",
            "Could not connect.",
            "open_runtime_session",
        )
        ctx = build_test_context(
            error_result=self._error_result,
            open_runtime_session=lambda **_kwargs: {"ok": False, "error": open_error},
        )
        result = engine_infra_ops.run_server_tooling_update_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            component_ids=["railpack_build_system"],
        )

        self.assertIs(result, open_error)

    def test_tooling_update_returns_status_reader_error(self):
        session = _FakeSession()
        status_error = self._error_result(
            "ENGINE_RUNTIME_ERROR",
            "Could not read status.",
            "execute_runtime_operation",
        )
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
        )
        with patch.object(
            engine_infra_ops,
            "_read_server_tooling_status",
            lambda *_args, **_kwargs: {
                "ok": False,
                "error": status_error,
            },
        ):
            result = engine_infra_ops.run_server_tooling_update_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_ids=["railpack_build_system"],
            )

        self.assertIs(result, status_error)

    def test_tooling_update_honors_cancellation_during_component_loop(self):
        session = _FakeSession()
        status_before = self._managed_update_status("railpack_build_system")
        is_cancelled = Mock(side_effect=[False, True])
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
            error_result=self._error_result,
        )
        with patch.object(
            engine_infra_ops,
            "_read_server_tooling_status",
            lambda *_args, **_kwargs: status_before,
        ):
            result = engine_infra_ops.run_server_tooling_update_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_ids=["railpack_build_system"],
                is_cancelled=is_cancelled,
            )

        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(result["stage"], "execute_runtime_operation")

    def test_tooling_update_skips_unconfigured_component_and_warns_on_disconnect(self):
        session = _FakeSession(disconnect_error="disconnect failed")
        status_before = self._managed_update_status(
            "railpack_build_system",
            status="not_configured",
        )
        emit_event = Mock()
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=emit_event,
        )
        with patch.object(
            engine_infra_ops,
            "_read_server_tooling_status",
            Mock(side_effect=[status_before, {"ok": False}]),
        ):
            result = engine_infra_ops.run_server_tooling_update_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_ids=["railpack_build_system"],
            )

        self.assertEqual(result["status"], "success")
        emit_event.assert_any_call(
            None,
            "connection_disconnect_error",
            "disconnect failed",
            level="warning",
        )

    def test_tooling_update_records_docker_package_versions(self):
        session = _FakeSession()
        status_before = self._managed_update_status("docker_runtime")
        status_before["payload"] = {
            "docker_ce_version": "docker-ce-version",
            "docker_ce_cli_version": "docker-cli-version",
            "containerd_version": "containerd-version",
            "docker_compose_plugin_version": "compose-version",
        }
        ledger_writes = []
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_server_tooling_status=Mock(
                side_effect=[status_before, {"ok": False}],
            ),
            _write_remote_software_ledger=(
                lambda _ctx, _session, ledger, **_kwargs: ledger_writes.append(ledger)
            ),
            _managed_update_command=lambda *_args, **_kwargs: "true",
            run_shell_command=lambda *_args, **_kwargs: {
                "ok": True,
                "details": "",
                "output": _FakeOutput(),
            },
        ):
            result = engine_infra_ops.run_server_tooling_update_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_ids=["docker_runtime"],
            )

        self.assertEqual(result["status"], "success")
        package_versions = ledger_writes[-1]["components"]["docker_runtime"]["package_versions"]
        self.assertEqual(package_versions["docker-ce"], "docker-ce-version")
        self.assertEqual(
            package_versions["docker-compose-plugin"],
            "compose-version",
        )

    def test_tooling_update_records_the_rollback_target_before_pruning(self):
        """A crash during pruning must leave the ledger pointing at the protected backup."""
        session = _FakeSession()
        status_before = self._managed_update_status("postgresql_database_service")
        events = []

        def write_ledger(_ctx, _session, ledger, **_kwargs):
            """Capture ledger state at each durability boundary in the workflow."""
            record = ledger["components"]["postgresql_database_service"]
            events.append(
                (
                    "write",
                    record["status"],
                    record.get("backup_dir", ""),
                    tuple(item["path"] for item in record.get("retained_backups", [])),
                )
            )

        def run_command(_host, command, **_kwargs):
            """Return retention evidence only after observing the generated prune command."""
            events.append(("run", command))
            output = _FakeOutput()
            if command == "prune":
                output = Mock(stdout_lines=["retained_upgrade_backup=/rollback/current\t42"])
            return {"ok": True, "details": "", "output": output}

        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_server_tooling_status=Mock(
                side_effect=[status_before, {"ok": False}],
            ),
            _write_remote_software_ledger=write_ledger,
            _backup_dir=lambda *_args, **_kwargs: "/rollback/current",
            _managed_backup_hygiene_command=lambda: "harden",
            _managed_update_command=lambda *_args, **_kwargs: "update",
            _managed_backup_retention_command=lambda *_args, **_kwargs: "prune",
            run_shell_command=run_command,
        ):
            result = engine_infra_ops.run_server_tooling_update_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_ids=["postgresql_database_service"],
            )

        self.assertEqual(result["status"], "success")
        self.assertEqual(
            events,
            [
                ("write", "in_progress", "", ()),
                ("run", "harden; update"),
                ("write", "success", "/rollback/current", ()),
                ("run", "prune"),
                (
                    "write",
                    "success",
                    "/rollback/current",
                    ("/rollback/current",),
                ),
            ],
        )

    def test_tooling_update_reports_retention_failure_after_preserving_rollback_target(self):
        """A cleanup failure must be loud without reverting the durable rollback pointer."""
        session = _FakeSession()
        status_before = self._managed_update_status("http_gateway")
        written = []
        commands = []

        def run_command(_host, command, **_kwargs):
            """Succeed at the update and fail only the post-success pruning step."""
            commands.append(command)
            if len(commands) == 1:
                return {"ok": True, "details": "", "output": _FakeOutput()}
            return {"ok": False, "details": "", "output": _FakeOutput()}

        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
            error_result=self._error_result,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_server_tooling_status=lambda *_args, **_kwargs: status_before,
            _write_remote_software_ledger=(
                lambda _ctx, _session, ledger, **_kwargs: written.append(ledger)
            ),
            _backup_dir=lambda *_args, **_kwargs: "/rollback/current",
            _managed_backup_hygiene_command=lambda: "harden",
            _managed_update_command=lambda *_args, **_kwargs: "update",
            _managed_backup_retention_command=lambda *_args, **_kwargs: "prune",
            run_shell_command=run_command,
        ):
            result = engine_infra_ops.run_server_tooling_update_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_ids=["http_gateway"],
            )

        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("could not enforce rollback-backup retention", result["msg"])
        self.assertEqual(result["details"], "remote retention command failed")
        record = written[-1]["components"]["http_gateway"]
        self.assertEqual(record["status"], "success")
        self.assertEqual(record["backup_dir"], "/rollback/current")

    def test_tooling_update_stops_at_each_failed_ledger_durability_boundary(self):
        """No later mutation may run after its prerequisite ledger write fails."""

        def run_case(failed_write):
            """Run one update whose selected ledger publication fails."""
            session = _FakeSession()
            status_before = self._managed_update_status("http_gateway")
            writes = 0
            commands = []

            def write_ledger(*_args, **_kwargs):
                """Fail exactly one selected durable boundary."""
                nonlocal writes
                writes += 1
                if writes == failed_write:
                    return {"ok": False, "details": "disk full"}
                return {"ok": True, "details": None}

            ctx = build_test_context(
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": session,
                },
                emit_event=lambda *_args, **_kwargs: None,
                error_result=self._error_result,
            )
            with patch.multiple(
                engine_infra_ops,
                _read_server_tooling_status=lambda *_args, **_kwargs: status_before,
                _write_remote_software_ledger=write_ledger,
                _managed_backup_hygiene_command=lambda: "harden",
                _managed_update_command=lambda *_args, **_kwargs: "update",
                _managed_backup_retention_command=lambda *_args, **_kwargs: "prune",
                run_shell_command=(
                    lambda _host, command, **_kwargs: (
                        commands.append(command)
                        or {
                            "ok": True,
                            "details": "",
                            "output": Mock(
                                stdout_lines=["retained_upgrade_backup=/rollback/current\t42"]
                            ),
                        }
                    )
                ),
            ):
                result = engine_infra_ops.run_server_tooling_update_operation(
                    ctx,
                    ip="203.0.113.10",
                    username="ubuntu",
                    component_ids=["http_gateway"],
                )
            return result, commands

        expected = {
            1: (0, "Could not record the managed-software update state."),
            2: (1, "could not record its rollback snapshot"),
            3: (2, "could not record the retained set"),
        }
        for failed_write, (expected_commands, expected_message) in expected.items():
            with self.subTest(failed_write=failed_write):
                result, commands = run_case(failed_write)

                self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
                self.assertIn(expected_message, result["msg"])
                self.assertEqual(result["details"], "disk full")
                self.assertEqual(len(commands), expected_commands)

    # The update operation hands the live compose image to the command
    # builder, which is how a custom gateway stack gets the rebuild
    # command instead of the stock image rewrite (#91).
    def test_tooling_update_selects_caddy_rebuild_for_custom_image(self):
        session = _FakeSession()
        status_before = self._managed_update_status("http_gateway")
        status_before["payload"] = {
            "caddy_compose_image": "deploydash_caddy_custom:local",
        }
        seen = {}

        def fake_update_command(
            component_id,
            *,
            backup_dir,
            caddy_compose_image="",
        ):
            seen["component_id"] = component_id
            seen["caddy_compose_image"] = caddy_compose_image
            return "true"

        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_server_tooling_status=lambda *_args, **_kwargs: status_before,
            _write_remote_software_ledger=lambda *_args, **_kwargs: None,
            _managed_update_command=fake_update_command,
            run_shell_command=lambda *_args, **_kwargs: {
                "ok": True,
                "details": "",
                "output": _FakeOutput(),
            },
        ):
            result = engine_infra_ops.run_server_tooling_update_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_ids=["http_gateway"],
            )

        self.assertEqual(result["status"], "success")
        self.assertEqual(seen["component_id"], "http_gateway")
        self.assertEqual(
            seen["caddy_compose_image"],
            "deploydash_caddy_custom:local",
        )

    # The rebuild command carries an inline Dockerfile rewriter: it moves
    # both FROM tags to the pinned base/builder and re-stamps the base
    # label, including Dockerfiles written before labels existed (#91).
    # The script runs here verbatim, extracted from the generated command.
    def test_caddy_rebuild_dockerfile_rewriter_moves_from_tags(self):
        command = engine_infra_ops._managed_update_command(
            "http_gateway",
            backup_dir="/rollback/http",
            caddy_compose_image="deploydash_caddy_custom:local",
        )
        script = command.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]

        old_shape = (
            "FROM caddy:2.10.0-builder AS builder\n"
            "RUN xcaddy build --with github.com/caddy-dns/cloudflare@v0.2.2\n"
            "FROM caddy:2.10.0-alpine\n"
            "COPY --from=builder /usr/bin/caddy /usr/bin/caddy\n"
        )
        new_shape = old_shape.replace(
            "FROM caddy:2.10.0-alpine\n",
            'FROM caddy:2.10.0-alpine\nLABEL deploydash.caddy_base="caddy:2.10.0-alpine"\n',
        )
        for shape in (old_shape, new_shape):
            with self.subTest(labelled="LABEL" in shape):
                with tempfile.TemporaryDirectory() as temp_dir:
                    dockerfile_path = f"{temp_dir}/Dockerfile"
                    with open(dockerfile_path, "w", encoding="utf-8") as handle:
                        handle.write(shape)
                    result = subprocess.run(
                        [
                            sys.executable,
                            "-",
                            dockerfile_path,
                            "caddy:2.11.2-builder",
                            "caddy:2.11.2-alpine",
                            "deploydash.caddy_base",
                        ],
                        input=script,
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    with open(dockerfile_path, encoding="utf-8") as handle:
                        rewritten = handle.read()

                self.assertIn("FROM caddy:2.11.2-builder AS builder", rewritten)
                self.assertIn("FROM caddy:2.11.2-alpine", rewritten)
                self.assertIn(
                    'LABEL deploydash.caddy_base="caddy:2.11.2-alpine"',
                    rewritten,
                )
                self.assertEqual(rewritten.count("LABEL deploydash.caddy_base="), 1)
                self.assertIn("caddy-dns/cloudflare", rewritten)

    # A Dockerfile that does not look generated must fail the rewrite
    # loudly instead of producing a half-edited file (#91).
    def test_caddy_rebuild_dockerfile_rewriter_rejects_unknown_shape(self):
        command = engine_infra_ops._managed_update_command(
            "http_gateway",
            backup_dir="/rollback/http",
            caddy_compose_image="deploydash_caddy_custom:local",
        )
        script = command.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]

        with tempfile.TemporaryDirectory() as temp_dir:
            dockerfile_path = f"{temp_dir}/Dockerfile"
            with open(dockerfile_path, "w", encoding="utf-8") as handle:
                handle.write("FROM scratch\n")
            result = subprocess.run(
                [
                    sys.executable,
                    "-",
                    dockerfile_path,
                    "caddy:2.11.2-builder",
                    "caddy:2.11.2-alpine",
                    "deploydash.caddy_base",
                ],
                input=script,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unexpected shape", result.stderr)
            with open(dockerfile_path, encoding="utf-8") as handle:
                self.assertEqual(handle.read(), "FROM scratch\n")

    def test_tooling_update_records_remote_command_failure(self):
        session = _FakeSession()
        status_before = self._managed_update_status("railpack_build_system")
        ledger_writes = []
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
            error_result=self._error_result,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_server_tooling_status=lambda *_args, **_kwargs: status_before,
            _write_remote_software_ledger=(
                lambda _ctx, _session, ledger, **_kwargs: ledger_writes.append(ledger)
            ),
            _managed_update_command=lambda *_args, **_kwargs: "false",
            run_shell_command=lambda *_args, **_kwargs: {
                "ok": False,
                "details": "snapshot failed",
                "output": _FakeOutput(),
            },
        ):
            result = engine_infra_ops.run_server_tooling_update_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_ids=["railpack_build_system"],
            )

        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["details"], "snapshot failed")
        self.assertEqual(
            ledger_writes[-1]["components"]["railpack_build_system"]["status"],
            "failed",
        )

    def test_tooling_update_records_railpack_executor_failure(self):
        session = _FakeSession()
        status_before = self._managed_update_status("railpack_build_system")
        ledger_writes = []
        plan_error = {"status": "error", "code": "ENGINE_OPERATION_FAILED"}
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_server_tooling_status=lambda *_args, **_kwargs: status_before,
            _write_remote_software_ledger=(
                lambda _ctx, _session, ledger, **_kwargs: ledger_writes.append(ledger)
            ),
            _managed_update_command=lambda *_args, **_kwargs: "true",
            run_shell_command=lambda *_args, **_kwargs: {
                "ok": True,
                "details": "",
                "output": _FakeOutput(),
            },
            run_plan_execute=lambda **_kwargs: plan_error,
        ):
            result = engine_infra_ops.run_server_tooling_update_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_ids=["railpack_build_system"],
            )

        self.assertIs(result, plan_error)
        self.assertEqual(
            ledger_writes[-1]["components"]["railpack_build_system"]["status"],
            "failed",
        )

    def test_tooling_rollback_dry_run_reports_component(self):
        ctx = build_test_context()
        result = engine_infra_ops.run_server_tooling_rollback_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            component_id="http_gateway",
            dry_run=True,
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["operation_id"], "tooling_rollback")
        self.assertEqual(result["component_id"], "http_gateway")

    def test_managed_manifest_exposes_unique_component_ids(self):
        ids = [component["id"] for component in MANAGED_SOFTWARE_MANIFEST.values()]

        self.assertEqual(sorted(MANAGED_SOFTWARE_MANIFEST), sorted(ids))
        self.assertEqual(len(ids), len(set(ids)))
        self.assertIn("docker_runtime", ids)
        self.assertIn("postgresql_database_service", ids)

    def test_software_ledger_parses_missing_malformed_and_current_format(self):
        self.assertEqual(parse_software_ledger(""), empty_software_ledger())
        self.assertEqual(parse_software_ledger("not json"), empty_software_ledger())
        self.assertEqual(parse_software_ledger("[]"), empty_software_ledger())
        self.assertEqual(
            parse_software_ledger('{"format_version":1,"components":[]}'),
            empty_software_ledger(),
        )

        current = parse_software_ledger(
            '{"format_version":1,"components":{"railpack_build_system":{"status":"success"},"bad":"value"}}'
        )
        self.assertEqual(current["format_version"], 1)
        self.assertEqual(
            current["components"]["railpack_build_system"]["status"],
            "success",
        )
        self.assertNotIn("bad", current["components"])

        built = record_component_action(
            empty_software_ledger(),
            "walg_backup_tool",
            action="update",
            status="success",
            installed_version="v3.0.7",
            previous_version="v3.0.7",
            target_version="v3.0.8",
            backup_path="/tmp/wal-g",
        )
        self.assertEqual(
            built["components"]["walg_backup_tool"]["installed_version"],
            "v3.0.7",
        )
        self.assertEqual(
            built["components"]["walg_backup_tool"]["backup_path"],
            "/tmp/wal-g",
        )
        self.assertEqual(
            encode_software_ledger(
                {
                    "format_version": 1,
                    "components": {
                        "walg_backup_tool": {"status": "success"},
                        "bad": "value",
                    },
                }
            ),
            '{"components":{"walg_backup_tool":{"status":"success"}},"format_version":1}',
        )

    def test_software_ledger_refuses_missing_format_version(self):
        # A dict-shaped ledger with no format_version at all is what an
        # unversioned legacy ledger (or a hand-edited/corrupted one) looks
        # like -- the ledger drives update/rollback decisions, so silently
        # trusting it is exactly how you roll back to the wrong version.
        with self.assertRaises(ManagedSoftwareLedgerFormatError):
            parse_software_ledger('{"components":{"railpack_build_system":{"status":"success"}}}')

    def test_software_ledger_refuses_newer_format_version(self):
        with self.assertRaises(ManagedSoftwareLedgerFormatError):
            parse_software_ledger(
                '{"format_version":99,"components":{"walg_backup_tool":{"status":"success"}}}'
            )

    def test_software_ledger_refuses_older_format_version(self):
        # Not just "absent" and "newer" -- any format_version other than the
        # exact known one refuses, including an explicit older value. The
        # ledger is read to make update/rollback decisions, not just
        # displayed, so there is no "probably still fine" tier.
        with self.assertRaises(ManagedSoftwareLedgerFormatError):
            parse_software_ledger(
                '{"format_version":0,"components":{"walg_backup_tool":{"status":"success"}}}'
            )

    def test_encode_software_ledger_refuses_unrecognized_format_version(self):
        with self.assertRaises(ManagedSoftwareLedgerFormatError):
            encode_software_ledger(
                {
                    "format_version": 99,
                    "components": {"walg_backup_tool": {"status": "success"}},
                }
            )

    def test_normalize_component_ids_accepts_strings_and_rejects_bad_input(self):
        self.assertEqual(
            normalize_component_ids("railpack_build_system"),
            ["railpack_build_system"],
        )
        self.assertEqual(
            normalize_component_ids(["railpack_build_system", "railpack_build_system", ""]),
            ["railpack_build_system"],
        )
        with self.assertRaisesRegex(ValueError, "component_ids must be a list"):
            normalize_component_ids({"railpack_build_system": True})
        with self.assertRaisesRegex(ValueError, "Choose at least one"):
            normalize_component_ids(["", "   "])

    def test_managed_status_maps_missing_current_and_invalid_ledger_shapes(self):
        self.assertEqual(
            _status_from_current("installed", "installed"),
            "current",
        )
        status = build_managed_software_status(
            {
                "railpack_version": "0.29.0",
                "docker_ce_version": "26.1.0",
                "docker_ce_cli_version": "26.1.0",
                "containerd_version": "1.7.0",
                "docker_compose_plugin_version": "2.27.0",
                "caddy_stack_present": "1",
                "caddy_compose_image": "caddy:2.11.2-alpine",
                "bind_stack_present": "1",
                "bind_compose_image": "",
            },
            {"components": []},
        )

        self.assertEqual(status["railpack_build_system"]["status"], "current")
        self.assertEqual(status["http_gateway"]["status"], "current")
        self.assertEqual(status["dns_service"]["status"], "missing")
        self.assertFalse(status["dns_service"]["can_rollback"])

    def test_docker_series_version_accepts_only_parseable_pinned_series(self):
        """Repository candidates outside the app-owned series must be ignored."""
        normalizer = getattr(managed_software, "docker_package_series_version", None)
        self.assertIsNotNone(
            normalizer,
            "managed software must own Docker patch-series normalization",
        )
        self.assertEqual(
            normalizer(
                "5:29.6.1-1~ubuntu.24.04~noble",
                "5:29.6.0-1",
            ),
            "5:29.6.1-1~ubuntu.24.04~noble",
        )
        self.assertEqual(normalizer("", "5:29.6.0-1"), "")
        self.assertEqual(
            normalizer("5:29.7.0-1", "5:29.6.0-1"),
            "",
        )
        self.assertEqual(
            normalizer("5:29.6.not-a-version", "5:29.6.0-1"),
            "",
        )
        self.assertEqual(
            normalizer("5:29.6.1-1", "not-a-version"),
            "",
        )

    def test_managed_status_surfaces_newer_docker_patch_in_pinned_series(self):
        """A newer held-package patch must become an explicit update action."""
        status = build_managed_software_status(
            {
                "docker_ce_version": "5:29.6.0-1~ubuntu.24.04~noble",
                "docker_ce_cli_version": "5:29.6.0-1~ubuntu.24.04~noble",
                "containerd_version": "2.2.5-1~ubuntu.24.04~noble",
                "docker_compose_plugin_version": "5.1.4-1~ubuntu.24.04~noble",
                "docker_ce_patch_candidate": "5:29.6.1-1~ubuntu.24.04~noble",
                "docker_ce_cli_patch_candidate": "5:29.6.1-1~ubuntu.24.04~noble",
                "containerd_patch_candidate": "",
                "docker_compose_plugin_patch_candidate": "unparseable",
            }
        )

        docker = status["docker_runtime"]
        self.assertEqual(docker["status"], "update_available")
        self.assertTrue(docker["can_update"])
        self.assertTrue(docker["patch_update_available"])
        self.assertEqual(
            docker["action_label"],
            "Install Docker runtime patch update",
        )
        self.assertIn("may restart", docker["description"])
        self.assertIn("docker-ce 5:29.6.1-1~ubuntu.24.04~noble", docker["target"])
        self.assertIn(
            "docker-compose-plugin 5.1.4-1~ubuntu.24.04~noble",
            docker["current"],
        )

    def test_managed_status_accepts_installed_patch_with_no_newer_candidate(self):
        """A held patch already inside every pinned series must report current."""
        status = build_managed_software_status(
            {
                "docker_ce_version": "5:29.6.2-1~ubuntu.24.04~noble",
                "docker_ce_cli_version": "5:29.6.2-1~ubuntu.24.04~noble",
                "containerd_version": "2.2.6-1~ubuntu.24.04~noble",
                "docker_compose_plugin_version": "5.1.5-1~ubuntu.24.04~noble",
            }
        )

        docker = status["docker_runtime"]
        self.assertEqual(docker["status"], "current")
        self.assertFalse(docker["can_update"])
        self.assertFalse(docker["patch_update_available"])

    def test_managed_status_keeps_version_current_separate_from_service_health(self):
        status = build_managed_software_status(
            {
                "postgres_stack_present": "1",
                "postgres_compose_image": "deploydash/postgres-ext:17.10-bookworm-vector",
                "postgres_container_present": "1",
                "postgres_container_docker_state": "running",
                "postgres_container_running": "true",
                "postgres_container_health": "unhealthy",
                "postgres_container_exit_code": "0",
                "postgres_container_image": "deploydash/postgres-ext:17.10-bookworm-vector",
                "postgres_container_started_at": "2026-07-01T12:00:00Z",
                "postgres_container_readiness_status": "unhealthy",
                "postgres_container_readiness_detail": "pg_isready failed",
            },
            {"components": {}},
        )

        postgres = status["postgresql_database_service"]
        self.assertEqual(postgres["status"], "current")
        self.assertFalse(postgres["can_update"])
        self.assertEqual(
            postgres["service_status"]["effective_status"],
            "unhealthy",
        )
        self.assertEqual(
            postgres["service_status"]["readiness"]["detail"],
            "pg_isready failed",
        )

    def test_walg_version_normalization_accepts_walg_owned_version_output(self):
        self.assertEqual(
            normalize_walg_version("wal-g version v3.0.8 linux/amd64"),
            "v3.0.8",
        )
        self.assertEqual(
            normalize_walg_version("WAL-G version: 3.0.8, git: abc123"),
            "v3.0.8",
        )
        self.assertEqual(
            normalize_walg_version("wal-g v3.0.8 built with go1.24.2"),
            "v3.0.8",
        )

    def test_walg_version_normalization_rejects_embedded_dependency_versions(self):
        self.assertEqual(
            normalize_walg_version("version.BuildVersion=v6.01.21 go=1.24.2 wal-g build metadata"),
            "",
        )
        self.assertEqual(normalize_walg_version("v6.01.21"), "")
        self.assertEqual(normalize_walg_version(""), "")

    def test_managed_status_uses_normalized_walg_version(self):
        status = build_managed_software_status(
            {
                "railpack_version": "0.29.0",
                "docker_ce_version": "26.1.0",
                "docker_ce_cli_version": "26.1.0",
                "containerd_version": "1.7.0",
                "docker_compose_plugin_version": "2.27.0",
                "caddy_stack_present": "1",
                "caddy_compose_image": "caddy:2.11.2-alpine",
                "bind_stack_present": "1",
                "bind_compose_image": "internetsystemsconsortium/bind9:9.20",
                "walg_version_raw": ("wal-g version v3.0.8 version.BuildVersion=v6.01.21"),
            }
        )

        walg = status["walg_backup_tool"]
        self.assertEqual(walg["current"], "v3.0.8")
        self.assertEqual(walg["status"], "current")
        self.assertFalse(walg["can_update"])

    def test_managed_status_maps_ledger_versions_and_rollback_availability(self):
        ledger = record_component_action(
            empty_software_ledger(),
            "railpack_build_system",
            action="update",
            status="success",
            installed_version="0.28.0",
            previous_version="0.28.0",
            target_version="0.29.0",
            backup_dir="/rollback/railpack",
        )
        status = engine_infra_ops.build_managed_software_status(
            {
                "railpack_version": "0.29.0",
                "docker_ce_version": "26.1.0",
                "docker_ce_cli_version": "26.1.0",
                "containerd_version": "1.7.0",
                "docker_compose_plugin_version": "2.27.0",
            },
            ledger,
        )

        railpack = status["railpack_build_system"]
        self.assertEqual(railpack["installed_version"], "0.28.0")
        self.assertEqual(railpack["previous_version"], "0.28.0")
        self.assertEqual(railpack["backup_dir"], "/rollback/railpack")
        self.assertTrue(railpack["rollback_available"])
        self.assertTrue(railpack["can_rollback"])

    def test_managed_status_reports_retained_backup_count_and_size(self):
        """Operators need the actual retained rollback footprint in status."""
        retained = [
            {"path": "/rollback/postgres/one", "size_bytes": 1024},
            {"path": "/rollback/postgres/two", "size_bytes": 512},
        ]
        ledger = record_component_action(
            empty_software_ledger(),
            "postgresql_database_service",
            action="update",
            status="success",
            backup_dir="/rollback/postgres/two",
            retained_backups=retained,
        )
        status = build_managed_software_status(
            {
                "postgres_stack_present": "1",
                "postgres_compose_image": "deploydash/postgres-ext:17.10-bookworm-base",
            },
            ledger,
        )

        postgres = status["postgresql_database_service"]
        self.assertEqual(postgres["retained_backups"], retained)
        self.assertEqual(postgres["retained_backup_count"], 2)
        self.assertEqual(postgres["retained_backup_bytes"], 1536)
        self.assertIn(
            {
                "label": "Retained rollback backups",
                "status": "current",
                "current": "2 backups using 1,536 bytes",
                "target": "Keep at most 3",
            },
            postgres["details"],
        )

    def test_managed_status_filters_malformed_retained_backup_records(self):
        """Hand-edited ledger data cannot corrupt the visible footprint total."""
        ledger = empty_software_ledger()
        ledger["components"]["http_gateway"] = {
            "retained_backups": [
                "wrong-shape",
                {},
                {"path": "/kept", "size_bytes": 9},
                {"path": "/kept", "size_bytes": 10},
                {"path": "/bad", "size_bytes": "not-a-number"},
                {"path": "/negative", "size_bytes": -1},
            ]
        }

        gateway = build_managed_software_status({}, ledger)["http_gateway"]

        self.assertEqual(
            gateway["retained_backups"],
            [{"path": "/kept", "size_bytes": 9}],
        )
        self.assertEqual(gateway["retained_backup_count"], 1)
        self.assertEqual(gateway["retained_backup_bytes"], 9)
        self.assertIn(
            {
                "label": "Retained rollback backups",
                "status": "current",
                "current": "1 backup using 9 bytes",
                "target": "Keep at most 3",
            },
            gateway["details"],
        )

    # A custom-image stack whose base label matches the pin is current:
    # there is nothing to update to (#91).
    def test_managed_status_reports_current_custom_caddy_build(self):
        from orchestrator.managed_software import caddy_image_is_current

        status = build_managed_software_status(
            {
                "caddy_stack_present": "1",
                "caddy_compose_image": "deploydash_caddy_custom:local",
                "caddy_base_label": "caddy:2.11.2-alpine",
            }
        )

        gateway = status["http_gateway"]
        self.assertEqual(gateway["status"], "current")
        self.assertFalse(gateway["can_update"])
        self.assertTrue(
            caddy_image_is_current(
                "deploydash_caddy_custom:local",
                "caddy:2.11.2-alpine",
            )
        )
        self.assertTrue(caddy_image_is_current("caddy:2.11.2-alpine", ""))
        self.assertFalse(
            caddy_image_is_current(
                "deploydash_caddy_custom:local",
                "caddy:2.10.0-alpine",
            )
        )
        self.assertFalse(caddy_image_is_current("caddy:2.10.0-alpine", ""))

    # A custom build from a stale base (or from before labels existed,
    # which reads back empty) still offers the update (#91).
    def test_managed_status_offers_update_for_stale_custom_caddy_build(self):
        for base_label in ("caddy:2.10.0-alpine", "", "<no value>"):
            with self.subTest(base_label=base_label):
                status = build_managed_software_status(
                    {
                        "caddy_stack_present": "1",
                        "caddy_compose_image": "deploydash_caddy_custom:local",
                        "caddy_base_label": base_label,
                    }
                )

                gateway = status["http_gateway"]
                self.assertEqual(gateway["status"], "update_available")
                self.assertTrue(gateway["can_update"])

    def test_managed_update_defaults_to_updateable_components_only(self):
        session = _FakeSession()
        commands = []

        status_before = {
            "ok": True,
            "payload": {},
            "tooling": {},
            "capabilities": {},
            "software_ledger": empty_software_ledger(),
            "managed_software": {
                "railpack_build_system": {
                    "label": "Railpack build system",
                    "current": "0.28.0",
                    "target": "0.29.0",
                    "can_update": True,
                },
                "http_gateway": {
                    "label": "HTTP gateway",
                    "current": "caddy:2.11.2-alpine",
                    "target": "caddy:2.11.2-alpine",
                    "can_update": False,
                },
            },
        }
        status_after = {
            **status_before,
            "managed_software": {
                "railpack_build_system": {"can_update": False},
                "http_gateway": {"can_update": False},
            },
        }

        def run_plan(**kwargs):
            emit_from_executor = kwargs["emit_event"]
            emit_from_executor("railpack_progress", "Railpack progress")
            return {"status": "success"}

        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_server_tooling_status=Mock(side_effect=[status_before, status_after]),
            _write_remote_software_ledger=lambda *_args, **_kwargs: None,
            _managed_update_command=lambda component_id, **_kwargs: (
                commands.append(component_id) or "true"
            ),
            run_plan_execute=run_plan,
            run_shell_command=lambda *_args, **_kwargs: {
                "ok": True,
                "details": "",
                "output": _FakeOutput(),
            },
        ):
            result = engine_infra_ops.run_server_tooling_update_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
            )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["component_ids"], ["railpack_build_system"])
        self.assertEqual(commands, ["railpack_build_system"])

    def test_railpack_update_command_snapshots_managed_files(self):
        command = engine_infra_ops._managed_railpack_update_command(
            backup_dir="/rollback/railpack build",
        )
        dispatched = engine_infra_ops._managed_update_command(
            "railpack_build_system",
            backup_dir="/rollback/railpack build",
        )

        self.assertIn("umask 077", command)
        self.assertIn("install -d -m 700 '/rollback/railpack build'", command)
        self.assertIn("cp -a /usr/local/bin/railpack", command)
        self.assertIn("deploydash-railpack-build", command)
        self.assertIn("/opt/deploydash/stack/railpack/railpack.env", command)
        self.assertEqual(dispatched, command)

    def test_managed_update_commands_select_gateway_dns_and_docker_contracts(self):
        http_command = engine_infra_ops._managed_update_command(
            "http_gateway",
            backup_dir="/rollback/http",
        )
        dns_command = engine_infra_ops._managed_update_command(
            "dns_service",
            backup_dir="/rollback/dns",
        )
        docker_command = engine_infra_ops._managed_update_command(
            "docker_runtime",
            backup_dir="/rollback/docker",
        )

        self.assertIn(engine_infra_ops.CANONICAL_HTTP_SETTINGS["caddy_image"], http_command)
        self.assertIn(engine_infra_ops.CANONICAL_DNS_SETTINGS["bind_image"], dns_command)
        self.assertIn(engine_infra_ops.CANONICAL_DNS_SETTINGS["container_name"], dns_command)
        self.assertIn("apt-cache madison", docker_command)
        self.assertIn("dpkg --compare-versions", docker_command)
        self.assertIn("trap restore_docker_holds EXIT INT TERM", docker_command)
        self.assertIn("apt-mark hold", docker_command)
        self.assertIn("systemctl restart docker", docker_command)
        self.assertIn("RUNNING_MANAGED_CONTAINERS", docker_command)
        with self.assertRaisesRegex(ValueError, "Unknown managed software component"):
            engine_infra_ops._managed_update_command(
                "not-a-component",
                backup_dir="/rollback/unknown",
            )

    def test_docker_patch_update_selects_latest_and_restores_holds_on_failure(self):
        """The update must choose valid patches and re-hold packages on every exit."""
        command = engine_infra_ops._managed_update_command(
            "docker_runtime",
            backup_dir="/rollback/docker",
        )
        fake_commands = r"""
apt-cache(){
  case "$2" in
    docker-ce|docker-ce-cli) printf '%s\n' " $2 | 5:29.6.0-1 | repo" " $2 | 5:29.6.bad | repo" " $2 | 5:29.6.1-1 | repo" ;;
    containerd.io) printf '%s\n' " containerd.io | 2.2.6-1 | repo" ;;
    docker-compose-plugin) printf '%s\n' " docker-compose-plugin | 5.1.5-1 | repo" ;;
  esac
}
apt-mark(){ printf 'apt-mark %s\n' "$*" >> "$TRACE"; }
apt-get(){ printf 'apt-get %s\n' "$*" >> "$TRACE"; [ "${FAIL_APT:-0}" != 1 ]; }
dpkg-query(){
  package="${@: -1}"
  case "$package" in
    docker-ce|docker-ce-cli) printf '5:29.6.1-1' ;;
    containerd.io) printf '2.2.6-1' ;;
    docker-compose-plugin) printf '5.1.5-1' ;;
  esac
}
docker(){
  printf 'docker %s\n' "$*" >> "$TRACE"
  case "$1" in
    ps) if [[ "$*" == *'--filter label='* ]]; then printf 'managed-id\n'; fi ;;
    inspect) printf 'true\n' ;;
  esac
}
containerd(){ printf 'containerd %s\n' "$*" >> "$TRACE"; }
systemctl(){ printf 'systemctl %s\n' "$*" >> "$TRACE"; }
"""

        for fail_apt in ("0", "1"):
            with self.subTest(fail_apt=fail_apt), tempfile.NamedTemporaryFile() as trace:
                result = subprocess.run(
                    ["bash", "-c", fake_commands + command],
                    text=True,
                    capture_output=True,
                    check=False,
                    env={**os.environ, "TRACE": trace.name, "FAIL_APT": fail_apt},
                )
                trace.seek(0)
                output = trace.read().decode()

            self.assertEqual(result.returncode, int(fail_apt))
            self.assertIn("docker-ce=5:29.6.1-1", output)
            self.assertNotIn("5:29.6.bad", output)
            self.assertEqual(output.count("apt-mark hold"), 1)
            if fail_apt == "0":
                self.assertIn("systemctl restart docker", output)
                self.assertIn("docker inspect -f {{.State.Running}} managed-id", output)
            else:
                self.assertNotIn("systemctl restart docker", output)

    # A custom-image gateway stack updates by rebuilding: the old outage
    # rewrote the image line to stock and dropped every DNS plugin (#91).
    # The rebuild path tags the working build aside, rewrites the
    # Dockerfile base/builder tags, rebuilds, and verifies the provider
    # modules still load -- and never touches the image line.
    def test_http_update_rebuilds_custom_caddy_image(self):
        command = engine_infra_ops._managed_update_command(
            "http_gateway",
            backup_dir="/rollback/http",
            caddy_compose_image="deploydash_caddy_custom:local",
        )

        self.assertIn("Custom Caddy Dockerfile is missing", command)
        self.assertIn("caddy/Dockerfile", command)
        self.assertIn("deploydash_caddy_custom:previous", command)
        self.assertIn("docker compose -f", command)
        self.assertIn("build --pull", command)
        self.assertIn("up -d --remove-orphans", command)
        self.assertIn("caddy list-modules", command)
        self.assertIn("dns.providers.", command)
        self.assertIn("caddy:2.11.2-builder", command)
        self.assertNotIn("lines[index] = f'{indent}image:", command)

    # The stock update path keeps working exactly as before, with one
    # addition: it refuses to run when the compose file names the custom
    # build, so a stale status read can never recreate the #91 outage.
    def test_http_update_refuses_custom_stack_on_stock_path(self):
        command = engine_infra_ops._managed_update_command(
            "http_gateway",
            backup_dir="/rollback/http",
        )

        self.assertIn("Custom Caddy build detected", command)
        self.assertIn("refusing to rewrite the image line", command)
        self.assertIn("deploydash_caddy_custom:local", command)
        self.assertIn(
            engine_infra_ops.CANONICAL_HTTP_SETTINGS["caddy_image"],
            command,
        )

    # Gateway rollback restores the Dockerfile snapshot and the tagged
    # previous build when they exist, and stays a plain compose restore
    # for stock stacks that have neither (#91).
    def test_http_rollback_restores_custom_build_tag(self):
        command = engine_infra_ops._managed_rollback_command(
            "http_gateway",
            {"backup_dir": "/rollback/http"},
        )

        self.assertIn("caddy validate", command)
        self.assertIn("[ ! -f /rollback/http/Dockerfile ] ||", command)
        self.assertIn("deploydash_caddy_custom:previous", command)
        self.assertIn("docker tag", command)
        self.assertIn("docker image inspect", command)

    def test_managed_rollback_commands_validate_component_specific_records(self):
        dns_command = engine_infra_ops._managed_rollback_command(
            "dns_service",
            {"backup_dir": "/rollback/dns"},
        )

        self.assertIn("DNS rollback snapshot is missing", dns_command)
        self.assertIn(engine_infra_ops.CANONICAL_DNS_SETTINGS["container_name"], dns_command)
        with self.assertRaisesRegex(ValueError, "No WAL-G rollback binary"):
            engine_infra_ops._managed_rollback_command("walg_backup_tool", {})
        with self.assertRaisesRegex(ValueError, "No previous Docker package versions"):
            engine_infra_ops._managed_rollback_command("docker_runtime", {})
        with self.assertRaisesRegex(ValueError, "Unknown managed software component"):
            engine_infra_ops._managed_rollback_command("not-a-component", {})

    def test_rollback_command_verifies_restored_component_health(self):
        railpack = engine_infra_ops._managed_rollback_command(
            "railpack_build_system",
            {
                "backup_dir": "/rollback/railpack",
                "previous_version": "0.28.0",
            },
        )
        caddy = engine_infra_ops._managed_rollback_command(
            "http_gateway",
            {"backup_dir": "/rollback/http"},
        )
        walg = engine_infra_ops._managed_rollback_command(
            "walg_backup_tool",
            {"backup_dir": "/rollback/walg"},
        )
        docker = engine_infra_ops._managed_rollback_command(
            "docker_runtime",
            {
                "package_versions": {
                    "docker-ce": "26.1.0-1",
                    "docker-ce-cli": "26.1.0-1",
                    "containerd.io": "1.7.0-1",
                    "docker-compose-plugin": "2.27.0-1",
                }
            },
        )

        self.assertIn('railpack --version | grep -F "$EXPECTED"', railpack)
        self.assertIn("test -x /usr/local/bin/deploydash-railpack-build", railpack)
        self.assertIn("caddy validate", caddy)
        self.assertIn("wal-g --version", walg)
        self.assertIn("apt-cache policy", docker)
        self.assertIn("containerd --version", docker)
        self.assertIn("docker compose version", docker)
        self.assertIn("label=deploydash.managed=true", docker)

    def test_postgres_update_requires_non_empty_pre_upgrade_backup(self):
        command = engine_infra_ops._managed_update_command(
            "postgresql_database_service",
            backup_dir="/rollback/postgres",
        )

        self.assertIn("PostgreSQL service must be ready before upgrade", command)
        self.assertIn("pg_isready -U deploydash -d postgres", command)
        self.assertIn("pg_dumpall -U deploydash", command)
        self.assertIn("test -s /rollback/postgres/pg_dumpall.sql", command)
        self.assertIn("umask 077", command)
        self.assertIn("install -d -m 700 /rollback/postgres", command)
        self.assertIn('POSTGRES_ENV_OUTPUT="$(python3', command)
        self.assertIn(')" || exit 1', command)
        self.assertIn("POSTGRES_TARGET_IMAGE", command)
        self.assertIn(
            'target = f"deploydash/postgres-ext:{target_tag}-{variant}"',
            command,
        )
        self.assertIn("docker build --pull", command)
        self.assertIn('docker compose -f "$COMPOSE" config', command)
        self.assertIn(
            'docker compose -f "$COMPOSE" up -d --remove-orphans',
            command,
        )
        self.assertIn(
            "docker inspect -f '{{.Config.Image}}' deploydash_postgres | "
            'grep -Fx "$POSTGRES_TARGET_IMAGE"',
            command,
        )
        self.assertIn('pg_isready -U "$POSTGRES_USER"', command)
        self.assertIn("psql -U \"$POSTGRES_USER\" postgres -c '\\l'", command)
        self.assertIn("psql -U \"$POSTGRES_USER\" postgres -c '\\du'", command)

    def test_walg_update_reinstalls_and_verifies_the_pinned_version(self):
        command = engine_infra_ops._managed_update_command(
            "walg_backup_tool",
            backup_dir="/rollback/walg",
        )

        self.assertIn("cp -a /usr/local/bin/wal-g", command)
        self.assertNotIn("if command -v wal-g", command)
        self.assertIn("install -m 0755", command)
        self.assertIn(
            "grep -E '^wal-g version v3\\.0\\.8([[:space:]]|$)'",
            command,
        )

    def test_postgres_update_target_accepts_legacy_major_only_image_tags(self):
        target = engine_infra_ops._postgres_managed_update_target(
            "deploydash/postgres-ext:17-bookworm-vector-pg-search"
        )

        self.assertEqual(
            target["current"],
            "deploydash/postgres-ext:17-bookworm-vector-pg-search",
        )
        self.assertEqual(
            target["target"],
            "deploydash/postgres-ext:17.10-bookworm-vector-pg-search",
        )
        self.assertEqual(target["base"], "postgres:17.10-bookworm")
        self.assertEqual(target["major"], "17")
        self.assertEqual(target["variant"], "vector-pg-search")

    def test_postgres_update_target_preserves_current_variants(self):
        cases = {
            "deploydash/postgres-ext:16-bookworm": (
                "deploydash/postgres-ext:16.14-bookworm-base",
                "base",
            ),
            "deploydash/postgres-ext:18.4-bookworm-vector-postgis": (
                "deploydash/postgres-ext:18.4-bookworm-vector-postgis",
                "vector-postgis",
            ),
            "deploydash/postgres-ext:18-bookworm-pg-search": (
                "deploydash/postgres-ext:18.4-bookworm-pg-search",
                "pg-search",
            ),
        }

        for current, expected in cases.items():
            with self.subTest(current=current):
                target = engine_infra_ops._postgres_managed_update_target(current)
                self.assertEqual(target["target"], expected[0])
                self.assertEqual(target["variant"], expected[1])

    def test_postgres_update_target_rejects_unsupported_images(self):
        with self.assertRaisesRegex(ValueError, "Unsupported PostgreSQL image"):
            engine_infra_ops._postgres_managed_update_target("postgres:17.10-bookworm")

    def test_postgres_update_dockerfile_writer_preserves_shell_variables(self):
        command = engine_infra_ops._managed_update_command(
            "postgresql_database_service",
            backup_dir="/rollback/postgres",
        )
        marker = "python3 - \"${BUILD_DIR}/Dockerfile\" <<'PY'\n"
        script = command.split(marker, 1)[1].split("\nPY\n  docker build", 1)[0]
        env = {
            **os.environ,
            "POSTGRES_DOCKERFILES_JSON": json.dumps(
                postgres_extension_image_dockerfiles_by_variant(),
            ),
            "POSTGRES_VARIANT": "vector-pg-search",
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            dockerfile_path = f"{temp_dir}/Dockerfile"
            result = subprocess.run(
                [sys.executable, "-", dockerfile_path],
                input=script,
                text=True,
                capture_output=True,
                env=env,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            with open(dockerfile_path, encoding="utf-8") as handle:
                dockerfile = handle.read()

        self.assertIn("FROM ${BASE_IMAGE}", dockerfile)
        self.assertIn('WALG_TMP="$(mktemp -d)"', dockerfile)
        self.assertNotIn("release.json", dockerfile)
        self.assertIn("sha256sum -c -", dockerfile)
        self.assertIn("778dacf20c07caf904557a88705142631818d8cb", dockerfile)
        self.assertIn("pg_search checksum verification failed", dockerfile)
        self.assertIn('"${BIN_PATH}"', dockerfile)
        self.assertIn("\\( -name 'wal-g-pg-*'", dockerfile)

    def test_postgres_update_uses_postgres_backup_directory(self):
        self.assertEqual(
            engine_infra_ops._backup_dir(
                "postgresql_database_service",
                "20260621T120000Z",
            ),
            "/opt/deploydash/state/upgrade-backups/postgres/20260621T120000Z",
        )

    # The explicit data-restore path keeps the old destroy-and-replay shape:
    # it exists for genuine major-version rollbacks and user choice, and
    # stays labelled destructive while the default becomes non-destructive.
    def test_postgres_rollback_restore_data_rebuilds_service_and_verifies_visibility(self):
        command = engine_infra_ops._managed_rollback_command(
            "postgresql_database_service",
            {"backup_dir": "/rollback/postgres"},
            restore_data=True,
        )

        self.assertIn("PostgreSQL rollback backup is missing", command)
        self.assertIn("pre-rollback-", command)
        self.assertIn("umask 077", command)
        self.assertIn('install -d -m 700 "$SAFETY"', command)
        self.assertIn('test -s "$SAFETY/pg_dumpall.sql"', command)
        self.assertIn("down --remove-orphans --volumes", command)
        self.assertIn('while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]', command)
        self.assertIn("PostgreSQL readiness probe failed", command)
        self.assertIn("sed '/^CREATE ROLE deploydash;$/d'", command)
        self.assertIn("psql -v ON_ERROR_STOP=1", command)
        self.assertIn("psql -U deploydash postgres -c '\\l'", command)
        self.assertIn("psql -U deploydash postgres -c '\\du'", command)

    def test_postgres_rollback_requires_recorded_backup(self):
        with self.assertRaisesRegex(ValueError, "No rollback snapshot"):
            engine_infra_ops._managed_rollback_command(
                "postgresql_database_service",
                {},
            )

    def test_postgres_rollback_default_preserves_data_without_volumes_or_restore(self):
        # #87: managed updates never cross a major, so the default rollback
        # puts the previous image back on the live volume instead of
        # destroying it and replaying the pre-update dump.
        command = engine_infra_ops._managed_rollback_command(
            "postgresql_database_service",
            {
                "backup_dir": "/rollback/postgres",
                "previous_version": "deploydash/postgres-ext:17.9-bookworm-base",
            },
        )

        self.assertNotIn("--volumes", command)
        self.assertNotIn("ON_ERROR_STOP", command)
        self.assertNotIn("pg_dumpall.sql |", command)
        self.assertIn("PostgreSQL current compose file is missing", command)
        self.assertIn("pre-rollback-", command)
        self.assertIn("umask 077", command)
        self.assertIn('install -d -m 700 "$SAFETY"', command)
        self.assertIn('test -s "$SAFETY/pg_dumpall.sql"', command)
        self.assertIn(
            "COMPOSE=/opt/deploydash/stack/postgres/docker-compose.yml",
            command,
        )
        self.assertIn('cp -a "$COMPOSE" "$SAFETY/docker-compose.yml"', command)
        self.assertIn("up -d --remove-orphans", command)
        self.assertIn("PostgreSQL readiness probe failed", command)
        self.assertIn(
            'grep -Fx "$POSTGRES_TARGET_IMAGE"',
            command,
        )
        self.assertIn("psql -U deploydash postgres -c '\\l'", command)
        self.assertIn("psql -U deploydash postgres -c '\\du'", command)

    def test_postgres_rollback_preserves_the_current_storage_layout(self):
        """A later storage migration must survive an older image rollback."""
        previous_image = "deploydash/postgres-ext:18.3-bookworm-base"
        command = engine_infra_ops._managed_rollback_command(
            "postgresql_database_service",
            {
                "backup_dir": "/rollback/postgres",
                "previous_version": previous_image,
            },
        )

        self.assertNotIn(
            "cp -a /rollback/postgres/docker-compose.yml "
            "/opt/deploydash/stack/postgres/docker-compose.yml",
            command,
        )
        self.assertIn('cp -a "$COMPOSE" "$SAFETY/docker-compose.yml"', command)
        marker = 'python3 - "$COMPOSE" rollback '
        script = command.split(marker, 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        migrated_compose = (
            "volumes:\n"
            "  postgres_data:\n"
            "    name: postgres_postgres_data_pg18\n"
            "services:\n"
            "  postgres:\n"
            "    image: deploydash/postgres-ext:18.4-bookworm-base\n"
            "    environment:\n"
            "      PGDATA: /var/lib/postgresql/data/pgdata\n"
            "    volumes:\n"
            "      - postgres_data:/var/lib/postgresql/data\n"
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            compose_path = f"{temp_dir}/docker-compose.yml"
            with open(compose_path, "w", encoding="utf-8") as handle:
                handle.write(migrated_compose)
            result = subprocess.run(
                [
                    sys.executable,
                    "-",
                    compose_path,
                    "rollback",
                    engine_infra_ops._POSTGRES_MANAGED_IMAGE_PATTERN,
                    previous_image,
                ],
                input=script,
                text=True,
                capture_output=True,
                check=False,
            )
            with open(compose_path, encoding="utf-8") as handle:
                rewritten = handle.read()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"image: {previous_image}", rewritten)
        self.assertIn("name: postgres_postgres_data_pg18", rewritten)
        self.assertIn("PGDATA: /var/lib/postgresql/data/pgdata", rewritten)
        self.assertIn("postgres_data:/var/lib/postgresql/data", rewritten)

    def test_postgres_rollback_refuses_a_cross_major_snapshot(self):
        """A stale pre-upgrade image must never run against newer data."""
        previous_image = "deploydash/postgres-ext:17.9-bookworm-base"
        command = engine_infra_ops._managed_rollback_command(
            "postgresql_database_service",
            {
                "backup_dir": "/rollback/postgres",
                "previous_version": previous_image,
            },
        )
        marker = 'python3 - "$COMPOSE" rollback '
        script = command.split(marker, 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        current_compose = (
            "services:\n"
            "  postgres:\n"
            "    image: deploydash/postgres-ext:18.4-bookworm-base\n"
            "    volumes:\n"
            "      - postgres_data:/var/lib/postgresql/data\n"
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            compose_path = f"{temp_dir}/docker-compose.yml"
            with open(compose_path, "w", encoding="utf-8") as handle:
                handle.write(current_compose)
            result = subprocess.run(
                [
                    sys.executable,
                    "-",
                    compose_path,
                    "rollback",
                    engine_infra_ops._POSTGRES_MANAGED_IMAGE_PATTERN,
                    previous_image,
                ],
                input=script,
                text=True,
                capture_output=True,
                check=False,
            )
            with open(compose_path, encoding="utf-8") as handle:
                after = handle.read()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("major version changed", result.stderr)
        self.assertEqual(after, current_compose)

    # Without a recorded previous image, an image-only rollback has no safe
    # target. Restoring the old compose would also restore stale storage.
    def test_postgres_rollback_default_requires_previous_version(self):
        with self.assertRaisesRegex(ValueError, "previous PostgreSQL image"):
            engine_infra_ops._managed_rollback_command(
                "postgresql_database_service",
                {"backup_dir": "/rollback/postgres"},
            )

    # previous_version comes from the on-server ledger, so the image-pin
    # check must neutralize shell metacharacters rather than interpolate
    # the raw value into the double-quoted grep pattern.
    def test_postgres_rollback_default_escapes_hostile_previous_version(self):
        previous_version = 'evil"; $(touch /tmp/pwned) "$x`id`\\'
        command = engine_infra_ops._managed_rollback_command(
            "postgresql_database_service",
            {
                "backup_dir": "/rollback/postgres",
                "previous_version": previous_version,
            },
        )

        self.assertIn(shlex.quote(previous_version), command)
        self.assertNotIn('grep -Fx "evil', command)

    # The manifest must describe both postgres rollback paths: the
    # non-destructive same-major image revert users get by default, and the
    # destructive pre-update-backup restore they can explicitly choose.
    def test_postgres_manifest_marks_default_rollback_non_destructive(self):
        manifest = MANAGED_SOFTWARE_MANIFEST["postgresql_database_service"]

        self.assertEqual(manifest["risk_level"], "medium")
        self.assertEqual(manifest["rollback_mode"], "same_major_image_revert")
        self.assertEqual(
            manifest["data_restore_mode"],
            "restore_recorded_pg_dumpall_backup",
        )
        self.assertEqual(manifest["data_restore_risk_level"], "destructive")
        self.assertEqual(
            manifest["data_restore_label"],
            "Restore data from the pre-update backup",
        )

    # The dry-run plan for a default postgres rollback must no longer
    # report destructive metadata: same-major rollback keeps the data.
    def test_tooling_rollback_dry_run_reports_non_destructive_default(self):
        ctx = build_test_context()
        result = engine_infra_ops.run_server_tooling_rollback_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            component_id="postgresql_database_service",
            dry_run=True,
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["risk_level"], "medium")
        self.assertFalse(result["destructive"])

    # The explicit data-restore choice stays destructive in dry-run plans
    # so the UI can warn before replaying the pre-update backup.
    def test_tooling_rollback_dry_run_reports_destructive_restore_path(self):
        ctx = build_test_context()
        result = engine_infra_ops.run_server_tooling_rollback_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            component_id="postgresql_database_service",
            dry_run=True,
            restore_data=True,
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["risk_level"], "destructive")
        self.assertTrue(result["destructive"])

    # The ledger records which rollback path ran so later support and UI
    # can tell a compose restore apart from a data restore.
    def test_record_component_action_stores_rollback_path(self):
        ledger = record_component_action(
            empty_software_ledger(),
            "postgresql_database_service",
            action="rollback",
            status="success",
            rollback_path="same_major_image_revert",
        )

        record = ledger["components"]["postgresql_database_service"]
        self.assertEqual(record["rollback_path"], "same_major_image_revert")
        self.assertEqual(record["last_action"], "rollback")

    # A default postgres rollback runs the image-only command and files
    # that path in the ledger, leaving the data volume alone.
    def test_postgres_rollback_records_image_path_in_ledger(self):
        session = _FakeSession()
        ledger = record_component_action(
            empty_software_ledger(),
            "postgresql_database_service",
            action="update",
            status="success",
            previous_version="deploydash/postgres-ext:17.9-bookworm-base",
            backup_dir="/rollback/postgres",
        )
        commands = []
        written = []
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_remote_software_ledger=lambda *_args, **_kwargs: ledger,
            _write_remote_software_ledger=(lambda *_args, **_kwargs: written.append(_args[2])),
            run_shell_command=lambda _host, command, **_kwargs: (
                commands.append(command)
                or {
                    "ok": True,
                    "details": "",
                    "output": _FakeOutput(),
                }
            ),
        ):
            result = engine_infra_ops.run_server_tooling_rollback_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_id="postgresql_database_service",
            )

        self.assertEqual(result["status"], "success")
        self.assertNotIn("--volumes", commands[0])
        self.assertIn("up -d --remove-orphans", commands[0])
        record = written[-1]["components"]["postgresql_database_service"]
        self.assertEqual(record["last_action"], "rollback")
        self.assertEqual(record["status"], "success")
        self.assertEqual(record["rollback_path"], "same_major_image_revert")

    # The explicit data-restore rollback runs the destroy-and-replay
    # command and files the restore path in the ledger.
    def test_postgres_rollback_restore_data_records_restore_path_in_ledger(self):
        session = _FakeSession()
        ledger = record_component_action(
            empty_software_ledger(),
            "postgresql_database_service",
            action="update",
            status="success",
            previous_version="deploydash/postgres-ext:17.9-bookworm-base",
            backup_dir="/rollback/postgres",
        )
        commands = []
        written = []
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_remote_software_ledger=lambda *_args, **_kwargs: ledger,
            _write_remote_software_ledger=(lambda *_args, **_kwargs: written.append(_args[2])),
            run_shell_command=lambda _host, command, **_kwargs: (
                commands.append(command)
                or {
                    "ok": True,
                    "details": "",
                    "output": _FakeOutput(),
                }
            ),
        ):
            result = engine_infra_ops.run_server_tooling_rollback_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_id="postgresql_database_service",
                restore_data=True,
            )

        self.assertEqual(result["status"], "success")
        self.assertIn("--volumes", commands[0])
        self.assertIn("psql -v ON_ERROR_STOP=1", commands[0])
        record = written[-1]["components"]["postgresql_database_service"]
        self.assertEqual(record["last_action"], "rollback")
        self.assertEqual(record["status"], "success")
        self.assertEqual(
            record["rollback_path"],
            "restore_recorded_pg_dumpall_backup",
        )

    # Rollback honours preflight cancellation before touching the server.
    def test_tooling_rollback_returns_preflight_cancellation_error(self):
        ctx = build_test_context(error_result=self._error_result)
        result = engine_infra_ops.run_server_tooling_rollback_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            component_id="http_gateway",
            is_cancelled=lambda: True,
        )

        self.assertEqual(result["code"], "ENGINE_TASK_CANCELLED")
        self.assertEqual(result["stage"], "preflight")

    # An unknown component id is rejected before any session opens.
    def test_tooling_rollback_rejects_unknown_component(self):
        ctx = build_test_context(error_result=self._error_result)
        result = engine_infra_ops.run_server_tooling_rollback_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            component_id="not-a-component",
        )

        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["stage"], "validate_request")

    # A failed session open surfaces the connection error unchanged.
    def test_tooling_rollback_returns_open_session_error(self):
        open_error = self._error_result(
            "ENGINE_CONNECTION_FAILED",
            "Could not connect.",
            "open_runtime_session",
        )
        ctx = build_test_context(
            error_result=self._error_result,
            open_runtime_session=lambda **_kwargs: {"ok": False, "error": open_error},
        )
        result = engine_infra_ops.run_server_tooling_rollback_operation(
            ctx,
            ip="203.0.113.10",
            username="ubuntu",
            component_id="http_gateway",
        )

        self.assertIs(result, open_error)

    # Rollback without any ledger record explains itself instead of
    # running a snapshot command against an unknown backup.
    def test_tooling_rollback_requires_ledger_record(self):
        session = _FakeSession()
        no_record = self._error_result(
            "ENGINE_VALIDATION_ERROR",
            "No rollback record is available for this component.",
            "validate_request",
        )
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
            error_result=self._error_result,
        )
        with patch.object(
            engine_infra_ops,
            "_read_remote_software_ledger",
            lambda *_args, **_kwargs: empty_software_ledger(),
        ):
            result = engine_infra_ops.run_server_tooling_rollback_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_id="http_gateway",
            )

        self.assertEqual(result, no_record)

    # A ledger record too thin to build a command from (here WAL-G with
    # no recorded binary) is rejected before anything runs remotely.
    def test_tooling_rollback_rejects_unusable_ledger_record(self):
        session = _FakeSession()
        thin_ledger = record_component_action(
            empty_software_ledger(),
            "walg_backup_tool",
            action="update",
            status="success",
        )
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
            error_result=self._error_result,
        )
        with patch.object(
            engine_infra_ops,
            "_read_remote_software_ledger",
            lambda *_args, **_kwargs: thin_ledger,
        ):
            result = engine_infra_ops.run_server_tooling_rollback_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_id="walg_backup_tool",
            )

        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertIn("WAL-G rollback binary", result["msg"])

    # A disconnect warning on session close still reports rollback success.
    def test_tooling_rollback_warns_on_disconnect_after_success(self):
        session = _FakeSession(disconnect_error="disconnect failed")
        ledger = record_component_action(
            empty_software_ledger(),
            "http_gateway",
            action="update",
            status="success",
            backup_dir="/rollback/http",
        )
        emit_event = Mock()
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=emit_event,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_remote_software_ledger=lambda *_args, **_kwargs: ledger,
            _write_remote_software_ledger=lambda *_args, **_kwargs: None,
            run_shell_command=lambda *_args, **_kwargs: {
                "ok": True,
                "details": "",
                "output": _FakeOutput(),
            },
        ):
            result = engine_infra_ops.run_server_tooling_rollback_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_id="http_gateway",
            )

        self.assertEqual(result["status"], "success")
        emit_event.assert_any_call(
            None,
            "connection_disconnect_error",
            "disconnect failed",
            level="warning",
        )

    def test_tooling_rollback_reports_retention_failure_after_recording_success(self):
        """A completed rollback stays recorded even when its cleanup step fails."""
        session = _FakeSession()
        ledger = record_component_action(
            empty_software_ledger(),
            "http_gateway",
            action="update",
            status="success",
            backup_dir="/rollback/http",
        )
        written = []
        calls = 0

        def run_command(*_args, **_kwargs):
            """Succeed at rollback, then fail its retention command with detail."""
            nonlocal calls
            calls += 1
            if calls == 1:
                return {"ok": True, "details": "", "output": _FakeOutput()}
            return {
                "ok": False,
                "details": "retention failed",
                "output": _FakeOutput(),
            }

        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
            error_result=self._error_result,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_remote_software_ledger=lambda *_args, **_kwargs: ledger,
            _write_remote_software_ledger=(lambda *_args, **_kwargs: written.append(_args[2])),
            run_shell_command=run_command,
        ):
            result = engine_infra_ops.run_server_tooling_rollback_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_id="http_gateway",
            )

        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertEqual(result["details"], "retention failed")
        self.assertEqual(
            written[-1]["components"]["http_gateway"]["status"],
            "success",
        )

    def test_tooling_rollback_stops_at_each_failed_ledger_durability_boundary(self):
        """Rollback pruning must wait for both durable ledger publications."""

        def run_case(failed_write):
            """Run one rollback whose selected ledger publication fails."""
            session = _FakeSession()
            ledger = record_component_action(
                empty_software_ledger(),
                "http_gateway",
                action="update",
                status="success",
                backup_dir="/rollback/http",
            )
            writes = 0
            commands = []

            def write_ledger(*_args, **_kwargs):
                """Fail the selected post-rollback ledger publication."""
                nonlocal writes
                writes += 1
                if writes == failed_write:
                    return {"ok": False, "details": "read-only filesystem"}
                return {"ok": True, "details": None}

            ctx = build_test_context(
                open_runtime_session=lambda **_kwargs: {
                    "ok": True,
                    "session": session,
                },
                emit_event=lambda *_args, **_kwargs: None,
                error_result=self._error_result,
            )
            with patch.multiple(
                engine_infra_ops,
                _read_remote_software_ledger=lambda *_args, **_kwargs: ledger,
                _write_remote_software_ledger=write_ledger,
                _managed_backup_hygiene_command=lambda: "harden",
                _managed_backup_retention_command=lambda *_args, **_kwargs: "prune",
                run_shell_command=(
                    lambda _host, command, **_kwargs: (
                        commands.append(command)
                        or {
                            "ok": True,
                            "details": "",
                            "output": Mock(
                                stdout_lines=["retained_upgrade_backup=/rollback/http\t42"]
                            ),
                        }
                    )
                ),
            ):
                result = engine_infra_ops.run_server_tooling_rollback_operation(
                    ctx,
                    ip="203.0.113.10",
                    username="ubuntu",
                    component_id="http_gateway",
                )
            return result, commands

        for failed_write, expected_commands in ((1, 1), (2, 2)):
            with self.subTest(failed_write=failed_write):
                result, commands = run_case(failed_write)

                self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
                self.assertEqual(result["details"], "read-only filesystem")
                self.assertEqual(len(commands), expected_commands)

    def test_successful_docker_rollback_skips_filesystem_retention(self):
        """Package rollback has no snapshot directory and must not invent one."""
        session = _FakeSession()
        ledger = record_component_action(
            empty_software_ledger(),
            "docker_runtime",
            action="update",
            status="success",
            package_versions={"docker-ce": "26.1.0-1"},
        )
        commands = []
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_remote_software_ledger=lambda *_args, **_kwargs: ledger,
            _write_remote_software_ledger=lambda *_args, **_kwargs: None,
            _read_server_tooling_status=lambda *_args, **_kwargs: {"ok": False},
            _managed_backup_hygiene_command=lambda: "harden",
            run_shell_command=(
                lambda _host, command, **_kwargs: (
                    commands.append(command) or {"ok": True, "details": "", "output": _FakeOutput()}
                )
            ),
        ):
            result = engine_infra_ops.run_server_tooling_rollback_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_id="docker_runtime",
            )

        self.assertEqual(result["status"], "success")
        self.assertEqual(len(commands), 1)
        self.assertTrue(commands[0].startswith("harden; "))

    # When the post-rollback status re-read fails, the rollback itself
    # still succeeded: the response reports success without fresh status.
    def test_tooling_rollback_succeeds_when_status_reread_fails(self):
        session = _FakeSession()
        ledger = record_component_action(
            empty_software_ledger(),
            "http_gateway",
            action="update",
            status="success",
            backup_dir="/rollback/http",
        )
        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            emit_event=lambda *_args, **_kwargs: None,
            error_result=self._error_result,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_remote_software_ledger=lambda *_args, **_kwargs: ledger,
            _write_remote_software_ledger=lambda *_args, **_kwargs: None,
            run_shell_command=Mock(
                side_effect=[
                    {"ok": True, "details": "", "output": _FakeOutput()},
                    {"ok": True, "details": "", "output": _FakeOutput()},
                    {
                        "ok": False,
                        "details": "status read failed",
                        "output": _FakeOutput(),
                    },
                ]
            ),
        ):
            result = engine_infra_ops.run_server_tooling_rollback_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_id="http_gateway",
            )

        self.assertEqual(result["status"], "success")
        self.assertEqual(result["component_id"], "http_gateway")
        self.assertNotIn("tooling", result)

    # The server plugin forwards the explicit data-restore choice to the
    # rollback operation so the UI can offer it per component.
    def test_server_plugin_forwards_postgres_restore_choice(self):
        calls = []

        def extract_connection_payload(_data):
            return {
                "ip": "203.0.113.10",
                "username": "ubuntu",
                "password": None,
                "private_key": "KEY",
                "port": 22,
            }

        ctx = build_test_context(
            extract_connection_payload=extract_connection_payload,
            connection_validation_error=lambda _connection: None,
            run_server_tooling_rollback_operation=(
                lambda **kwargs: calls.append(kwargs) or {"status": "success"}
            ),
            resolve_dry_run=lambda _data, _default: False,
        )
        plugin = build_plugin(
            operations={"tooling_rollback": {}},
            ctx=ctx,
        )

        result = plugin.handlers["tooling_rollback"](
            {
                "params": {
                    "component_id": "postgresql_database_service",
                    "restore_data": True,
                }
            },
            emit="emit",
        )

        self.assertEqual(result["status"], "success")
        self.assertEqual(
            calls[0]["component_id"],
            "postgresql_database_service",
        )
        self.assertTrue(calls[0]["restore_data"])

    def test_docker_rollback_surfaces_unavailable_previous_apt_versions(self):
        session = _FakeSession()
        ledger = record_component_action(
            empty_software_ledger(),
            "docker_runtime",
            action="update",
            status="success",
            package_versions={
                "docker-ce": "26.1.0-1",
                "docker-ce-cli": "26.1.0-1",
            },
        )

        ctx = build_test_context(
            open_runtime_session=lambda **_kwargs: {"ok": True, "session": session},
            error_result=(
                lambda code, msg, stage, details=None, extra=None: {
                    "status": "error",
                    "code": code,
                    "msg": msg,
                    "stage": stage,
                    "details": details,
                    **(extra or {}),
                }
            ),
            emit_event=lambda *_args, **_kwargs: None,
        )
        with patch.multiple(
            engine_infra_ops,
            _read_remote_software_ledger=lambda *_args, **_kwargs: ledger,
            _write_remote_software_ledger=lambda *_args, **_kwargs: None,
            run_shell_command=lambda *_args, **_kwargs: {
                "ok": False,
                "details": "apt-cache policy did not find previous version",
                "output": _FakeOutput(),
            },
        ):
            result = engine_infra_ops.run_server_tooling_rollback_operation(
                ctx,
                ip="203.0.113.10",
                username="ubuntu",
                component_id="docker_runtime",
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_RUNTIME_ERROR")
        self.assertIn("apt-cache policy", result["details"])

    def test_engine_tooling_wrappers_support_dry_run(self):
        status = engine.run_server_tooling_status_operation(
            ip="203.0.113.10",
            username="ubuntu",
            dry_run=True,
        )
        update = engine.run_server_tooling_update_operation(
            ip="203.0.113.10",
            username="ubuntu",
            component_ids=["railpack_build_system"],
            dry_run=True,
        )
        rollback = engine.run_server_tooling_rollback_operation(
            ip="203.0.113.10",
            username="ubuntu",
            component_id="http_gateway",
            dry_run=True,
        )

        self.assertEqual(status["operation_id"], "tooling_status")
        self.assertEqual(update["operation_id"], "tooling_update")
        self.assertEqual(rollback["operation_id"], "tooling_rollback")

    def test_server_plugin_routes_tooling_operations(self):
        calls = []

        def extract_connection_payload(_data):
            return {
                "ip": "203.0.113.10",
                "username": "ubuntu",
                "password": None,
                "private_key": "KEY",
                "port": 22,
            }

        ctx = build_test_context(
            extract_connection_payload=extract_connection_payload,
            connection_validation_error=lambda _connection: None,
            run_server_tooling_status_operation=(
                lambda **kwargs: calls.append(("status", kwargs)) or {"status": "success"}
            ),
            run_server_tooling_update_operation=(
                lambda **kwargs: calls.append(("update", kwargs)) or {"status": "success"}
            ),
            run_server_tooling_rollback_operation=(
                lambda **kwargs: calls.append(("rollback", kwargs)) or {"status": "success"}
            ),
            resolve_dry_run=lambda _data, _default: False,
        )
        plugin = build_plugin(
            operations={
                "tooling_status": {},
                "tooling_update": {},
                "tooling_rollback": {},
            },
            ctx=ctx,
        )

        self.assertEqual(
            plugin.handlers["tooling_status"]({}, emit="emit")["status"],
            "success",
        )
        self.assertEqual(
            plugin.handlers["tooling_update"](
                {"params": {"component_ids": ["http_gateway"]}},
                emit="emit",
            )["status"],
            "success",
        )
        self.assertEqual(
            plugin.handlers["tooling_rollback"](
                {"params": {"component_id": "http_gateway"}},
                emit="emit",
            )["status"],
            "success",
        )
        self.assertEqual([call[0] for call in calls], ["status", "update", "rollback"])
        self.assertEqual(calls[0][1]["key_filename"], "KEY")
        self.assertEqual(calls[1][1]["port"], 22)
        self.assertEqual(calls[1][1]["component_ids"], ["http_gateway"])
        self.assertEqual(calls[2][1]["component_id"], "http_gateway")

        plugin.handlers["tooling_update"]({"params": []})
        plugin.handlers["tooling_rollback"]({"params": []})
        self.assertIsNone(calls[-2][1]["component_ids"])
        self.assertIsNone(calls[-1][1]["component_id"])

    def test_server_plugin_returns_connection_errors_for_tooling_operations(self):
        error = {"status": "error", "msg": "Missing connection."}
        ctx = build_test_context(
            extract_connection_payload=lambda _data: {},
            connection_validation_error=lambda _connection: error,
            resolve_dry_run=lambda _data, _default: False,
        )
        plugin = build_plugin(
            operations={
                "tooling_status": {},
                "tooling_update": {},
                "tooling_rollback": {},
            },
            ctx=ctx,
        )

        self.assertIs(plugin.handlers["tooling_status"]({}), error)
        self.assertIs(plugin.handlers["tooling_update"]({}), error)
        self.assertIs(plugin.handlers["tooling_rollback"]({}), error)


if __name__ == "__main__":
    unittest.main()
