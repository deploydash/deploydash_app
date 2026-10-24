import json
import unittest

from engine import handle_request


def _connection():
    return {
        "ip": "203.0.113.10",
        "port": 22,
        "username": "root",
        "password": "secret",
    }


def _request(workflow_id, operation_id, *, connection=None, params=None, top_level=None):
    payload = {
        "action": "run_workflow",
        "workflow_id": workflow_id,
        "operation_id": operation_id,
    }
    if connection is not None:
        payload["connection"] = connection
    if params is not None:
        payload["params"] = params
    if top_level:
        payload.update(top_level)
    return json.loads(handle_request(json.dumps(payload)))


class TestParamsSchemaValidation(unittest.TestCase):
    """T-1.5.4: params_schema is enforced at dispatch, before any handler
    (and therefore before any SSH connection) runs. Ten operations across
    eight workflows, each with a payload the schema accepts and one it
    rejects."""

    def _assert_schema_rejected(self, result, *, mentions=None):
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["code"], "ENGINE_VALIDATION_ERROR")
        self.assertEqual(result["stage"], "validate_request")
        if mentions:
            self.assertIn(mentions, result["msg"])

    def _assert_schema_accepted(self, result):
        self.assertNotEqual(result.get("code"), "ENGINE_VALIDATION_ERROR")

    def test_postgres_project_create_database(self):
        valid = _request(
            "postgres",
            "project_create_database",
            connection=_connection(),
            params={
                "dry_run": True,
                "settings": {"project_slug": "demo", "database_name": "demo"},
            },
        )
        self._assert_schema_accepted(valid)

        missing_settings = _request(
            "postgres",
            "project_create_database",
            connection=_connection(),
            params={"dry_run": True},
        )
        self._assert_schema_rejected(missing_settings, mentions="settings")

        invalid = _request(
            "postgres",
            "project_create_database",
            connection=_connection(),
            params={"dry_run": True, "settings": {"project_slug": "demo"}},
        )
        self._assert_schema_rejected(invalid, mentions="database_name")

    def test_postgres_service_enable(self):
        valid = _request(
            "postgres",
            "service_enable",
            connection=_connection(),
            params={
                "dry_run": True,
                "settings": {
                    "postgres_version": "17",
                    "superuser_password": "secret",
                    "enabled_extensions": [],
                },
            },
        )
        self._assert_schema_accepted(valid)

        missing_settings = _request(
            "postgres",
            "service_enable",
            connection=_connection(),
            params={"dry_run": True},
        )
        self._assert_schema_rejected(missing_settings, mentions="settings")

        missing_password = _request(
            "postgres",
            "service_enable",
            connection=_connection(),
            params={
                "dry_run": True,
                "settings": {
                    "postgres_version": "17",
                    "enabled_extensions": [],
                },
            },
        )
        self._assert_schema_rejected(missing_password, mentions="superuser_password")

    def test_postgres_backup_run_now(self):
        valid = _request(
            "postgres",
            "backup_run_now",
            connection=_connection(),
            params={
                "dry_run": True,
                "settings": {
                    "project_slug": "demo",
                    "backup_policy_id": "nightly",
                    "backup_database_name": "demo",
                    "backup_destination_type": "s3",
                    "backup_s3_prefix": "prefix",
                    "backup_aws_access_key_id": "key",
                    "backup_aws_secret_access_key": "secret",
                    "backup_aws_region": "us-east-1",
                },
            },
        )
        self._assert_schema_accepted(valid)

        invalid = _request(
            "postgres",
            "backup_run_now",
            connection=_connection(),
            params={
                "dry_run": True,
                "settings": {
                    "project_slug": "demo",
                    "backup_policy_id": "nightly",
                    "backup_database_name": "demo",
                    "backup_destination_type": "s3",
                },
            },
        )
        self._assert_schema_rejected(invalid, mentions="backup_s3_prefix")

    def test_app_exec(self):
        valid = _request(
            "app",
            "exec",
            connection=_connection(),
            params={
                "dry_run": True,
                "command": "ls",
                "settings": {"project_slug": "demo"},
            },
        )
        self._assert_schema_accepted(valid)

        missing_settings = _request(
            "app",
            "exec",
            connection=_connection(),
            params={"dry_run": True, "command": "ls"},
        )
        self._assert_schema_rejected(missing_settings, mentions="settings")

        invalid = _request(
            "app",
            "exec",
            connection=_connection(),
            params={"dry_run": True, "settings": {"project_slug": "demo"}},
        )
        self._assert_schema_rejected(invalid, mentions="command")

    def test_app_deploy_requires_deployment_identity_settings(self):
        valid = _request(
            "app",
            "describe",
            params={
                "dry_run": True,
                "settings": {
                    "project_slug": "demo",
                    "repository_full_name": "example-org/demo",
                    "branch": "main",
                    "primary_domain": "demo.example.com",
                },
            },
        )
        self._assert_schema_accepted(valid)

        missing_branch = _request(
            "app",
            "describe",
            params={
                "dry_run": True,
                "settings": {
                    "project_slug": "demo",
                    "repository_full_name": "example-org/demo",
                    "primary_domain": "demo.example.com",
                },
            },
        )
        self._assert_schema_rejected(missing_branch, mentions="branch")

    def test_app_worker_start(self):
        valid = _request(
            "app",
            "worker_start",
            connection=_connection(),
            params={
                "dry_run": True,
                "worker_id": "queue",
                "settings": {
                    "project_slug": "demo",
                    "workers": [
                        {
                            "id": "queue",
                            "start_cmd": "run-worker",
                            "cpu_limit": 0.5,
                            "memory_mb": 256,
                            "disk_mb": 1024,
                        }
                    ],
                },
            },
        )
        self._assert_schema_accepted(valid)

        invalid = _request(
            "app",
            "worker_start",
            connection=_connection(),
            params={"dry_run": True, "settings": {}},
        )
        self._assert_schema_rejected(invalid, mentions="worker_id")

    def test_http_run(self):
        valid = _request(
            "http",
            "run",
            connection=_connection(),
            params={"dry_run": True, "settings": {"serve_ip_over_https": True}},
        )
        self._assert_schema_accepted(valid)

        invalid = _request(
            "http",
            "run",
            connection=_connection(),
            params={"dry_run": True, "settings": {"serve_ip_over_https": "yes"}},
        )
        self._assert_schema_rejected(invalid, mentions="serve_ip_over_https")

    def test_dns_run(self):
        valid = _request(
            "dns",
            "run",
            connection=_connection(),
            params={
                "dry_run": True,
                "settings": {"allow_recursion": False, "forwarders": []},
            },
        )
        self._assert_schema_accepted(valid)

        invalid = _request(
            "dns",
            "run",
            connection=_connection(),
            params={
                "dry_run": True,
                "settings": {"allow_recursion": True, "forwarders": []},
            },
        )
        self._assert_schema_rejected(invalid, mentions="allow_recursion")

    def test_firewall_apply_staged(self):
        valid = _request(
            "firewall",
            "apply_staged",
            connection=_connection(),
            params={
                "dry_run": True,
                "settings": {
                    "locked_ports": [22],
                    "custom_rules": [
                        {"protocol": "tcp", "port_start": 8080},
                    ],
                },
            },
        )
        self._assert_schema_accepted(valid)

        invalid = _request(
            "firewall",
            "apply_staged",
            connection=_connection(),
            params={
                "dry_run": True,
                "settings": {
                    "custom_rules": [
                        {"protocol": "icmp", "port_start": 8080},
                    ],
                },
            },
        )
        self._assert_schema_rejected(invalid, mentions="protocol")

    def test_scheduler_task_upsert(self):
        base_settings = {
            "project_slug": "demo",
            "task_id": "nightly-job",
            "name": "Nightly job",
            "command": "run-report",
            "target_type": "web_app",
            "schedule_type": "daily_at",
        }
        valid = _request(
            "scheduler",
            "task_upsert",
            connection=_connection(),
            params={"dry_run": True, "settings": base_settings},
        )
        self._assert_schema_accepted(valid)

        invalid_settings = dict(base_settings)
        del invalid_settings["name"]
        invalid = _request(
            "scheduler",
            "task_upsert",
            connection=_connection(),
            params={"dry_run": True, "settings": invalid_settings},
        )
        self._assert_schema_rejected(invalid, mentions="name")

    def test_setup_run(self):
        complete_settings = {
            "hostname": None,
            "timezone": "UTC",
            # A real onboarding request hardens SSH, so it must carry the key
            # that replaces the access it removes. See G-3 in
            # docs/contracts/onboarding-invariants.md. This test is about
            # schema completeness, so it must otherwise be a valid request.
            "ssh_public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA deploydash",
            "disable_password_auth": False,
            "disable_root_login": True,
            "ssh_banner_text": "Authorized access only.",
        }
        valid = _request(
            "setup",
            "run",
            connection=_connection(),
            top_level={
                "dry_run": True,
                "settings": complete_settings,
                "managed_connection": {
                    "username": "ubuntu",
                    "private_key": "-----BEGIN OPENSSH PRIVATE KEY-----\nkey\n",
                },
            },
        )
        self._assert_schema_accepted(valid)

        incomplete_settings = dict(complete_settings)
        del incomplete_settings["timezone"]
        invalid = _request(
            "setup",
            "run",
            connection=_connection(),
            top_level={"dry_run": True, "settings": incomplete_settings},
        )
        self._assert_schema_rejected(invalid, mentions="timezone")

    def test_server_tooling_rollback(self):
        valid = _request(
            "server",
            "tooling_rollback",
            connection=_connection(),
            params={"dry_run": True, "component_id": "docker_runtime"},
        )
        self._assert_schema_accepted(valid)

        invalid = _request(
            "server",
            "tooling_rollback",
            connection=_connection(),
            params={"dry_run": True, "component_id": "not_a_real_component"},
        )
        self._assert_schema_rejected(invalid, mentions="component_id")

    # The explicit postgres data-restore choice travels as a boolean
    # rollback param; anything else is rejected before any handler runs.
    def test_server_tooling_rollback_restore_data_choice(self):
        valid = _request(
            "server",
            "tooling_rollback",
            connection=_connection(),
            params={
                "dry_run": True,
                "component_id": "postgresql_database_service",
                "restore_data": True,
            },
        )
        self._assert_schema_accepted(valid)

        invalid = _request(
            "server",
            "tooling_rollback",
            connection=_connection(),
            params={
                "dry_run": True,
                "component_id": "postgresql_database_service",
                "restore_data": "yes",
            },
        )
        self._assert_schema_rejected(invalid, mentions="restore_data")

    def test_setup_run_omitting_settings_entirely_uses_defaults(self):
        # "settings" itself is optional (T-1.5.4 bugfix): omitting it
        # entirely must NOT be rejected by the schema, only an incomplete
        # settings object should be. Checked directly against the
        # validator rather than through full dispatch: a schema-omitted
        # "settings" defaults to hardening-enabled-with-no-key, which
        # setup_server legitimately rejects for an unrelated reason
        # (SSH hardening needs a key) -- that's real handler behavior, not
        # a schema question, so asserting on it here would couple this
        # test to a fact this test isn't about.
        from orchestrator.schema_validation import validate_against_schema
        from orchestrator.workflow_registry import WORKFLOW_REGISTRY

        schema = WORKFLOW_REGISTRY["setup"]["run"]["params_schema"]
        errors = validate_against_schema({"dry_run": True}, schema, path="payload")
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
