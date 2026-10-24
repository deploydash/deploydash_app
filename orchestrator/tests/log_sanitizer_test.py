import unittest

from orchestrator.log_sanitizer import sanitize_data, sanitize_text


class TestLogSanitizer(unittest.TestCase):
    def test_sanitize_data_redacts_every_descendant_of_environment_containers(self):
        canary = "DD_TEST_SECRET_DO_NOT_LOG_7f4c"
        payload = {
            "runtime_env": {
                "FEATURE_FLAG": canary,
                "NESTED": {"SAFE_NAME": canary},
                "LIST": [canary, {"PORT": 3000}],
            },
            "wrapper": {
                "env": {"ARBITRARY": canary},
                "env_vars": {"OTHER": canary},
                "environment": {"THIRD": canary},
            },
            "commit_sha": "abcdef1234567890",
        }

        sanitized = sanitize_data(payload)

        self.assertNotIn(canary, repr(sanitized))
        self.assertEqual(sanitized["runtime_env"]["FEATURE_FLAG"], "***")
        self.assertEqual(sanitized["runtime_env"]["NESTED"]["SAFE_NAME"], "***")
        self.assertEqual(sanitized["runtime_env"]["LIST"], ["***", {"PORT": "***"}])
        self.assertEqual(sanitized["commit_sha"], "abcdef1234567890")

    def test_sanitize_text_redacts_private_keys_and_authorization_headers(self):
        canary = "DD_TEST_SECRET_DO_NOT_LOG_7f4c"
        plain_pem = f"-----BEGIN PRIVATE KEY-----\n{canary}\n-----END PRIVATE KEY-----"
        escaped_pem = (
            f"-----BEGIN OPENSSH PRIVATE KEY-----\\n{canary}\\n-----END OPENSSH PRIVATE KEY-----"
        )
        message = (
            f"plain={plain_pem}\n"
            f'json={{"private_key":"{escaped_pem}"}}\n'
            f"Authorization: Bearer {canary}\n"
            f"authorization=Basic {canary}\n"
            "compiler=/workspace/lib/main.dart code=ERR_BUILD_42 commit=abcdef1234567890"
        )

        sanitized = sanitize_text(message)

        self.assertNotIn(canary, sanitized)
        self.assertNotIn("BEGIN PRIVATE KEY", sanitized)
        self.assertNotIn("BEGIN OPENSSH PRIVATE KEY", sanitized)
        self.assertIn("Authorization: Bearer ***", sanitized)
        self.assertIn("authorization=Basic ***", sanitized)
        self.assertIn("/workspace/lib/main.dart", sanitized)
        self.assertIn("ERR_BUILD_42", sanitized)
        self.assertIn("abcdef1234567890", sanitized)

    def test_sanitizers_preserve_collection_shapes_and_coerce_text(self):
        self.assertEqual(sanitize_text(42), "42")
        self.assertEqual(sanitize_text("Authorization: opaque"), "Authorization: ***")
        self.assertEqual(
            sanitize_data(("password=secret", 42)),
            ("password=***", 42),
        )
        self.assertEqual(
            sanitize_data({"environment": ({"PORT": 3000},)}),
            {"environment": ({"PORT": "***"},)},
        )

    def test_sanitize_text_redacts_password_assignments(self):
        message = "Authentication error (username=root, password=badsecret)"
        self.assertIn("password=***", sanitize_text(message))
        self.assertNotIn("badsecret", sanitize_text(message))

    def test_sanitize_text_redacts_mapping_style_fields(self):
        message = "args={'_sudo_password': 'test1234', 'username': 'ubuntu'}"
        sanitized = sanitize_text(message)
        self.assertIn("'_sudo_password': '***'", sanitized)
        self.assertNotIn("test1234", sanitized)

    def test_sanitize_text_redacts_prefixed_password_env_assignments(self):
        message = (
            "POSTGRES_PASSWORD=supersecret; SUPERUSER_PASSWORD=anothersecret; PGPASSWORD=pgsecret"
        )
        sanitized = sanitize_text(message)
        self.assertIn("POSTGRES_PASSWORD=***", sanitized)
        self.assertIn("SUPERUSER_PASSWORD=***", sanitized)
        self.assertIn("PGPASSWORD=***", sanitized)
        self.assertNotIn("supersecret", sanitized)
        self.assertNotIn("anothersecret", sanitized)
        self.assertNotIn("pgsecret", sanitized)

    def test_sanitize_text_redacts_generic_env_assignments(self):
        message = (
            "DATABASE_URL=postgresql://user:pass@example/db PORT=3000 APP_NAME='BuildingRegs.app'"
        )
        sanitized = sanitize_text(message)
        self.assertIn("DATABASE_URL=***", sanitized)
        self.assertIn("PORT=***", sanitized)
        self.assertIn("APP_NAME=***", sanitized)
        self.assertNotIn("postgresql://user:pass@example/db", sanitized)
        self.assertNotIn("3000", sanitized)
        self.assertNotIn("BuildingRegs.app", sanitized)

    def test_sanitize_text_redacts_env_mapping_and_tab_formats(self):
        message = (
            'runtime_env={"DATABASE_URL":"postgresql://user:pass@example/db","APP_NAME":"BuildingRegs.app"}\n'
            "DATABASE_URL\tcG9zdGdyZXM=\n"
            "PORT\tMzAwMA=="
        )
        sanitized = sanitize_text(message)
        self.assertIn('"DATABASE_URL":"***"', sanitized)
        self.assertIn('"APP_NAME":"***"', sanitized)
        self.assertIn("DATABASE_URL\t***", sanitized)
        self.assertIn("PORT\t***", sanitized)
        self.assertNotIn("postgresql://user:pass@example/db", sanitized)
        self.assertNotIn("BuildingRegs.app", sanitized)
        self.assertNotIn("cG9zdGdyZXM=", sanitized)
        self.assertNotIn("MzAwMA==", sanitized)

    def test_sanitize_text_redacts_managed_password_assignment(self):
        """The setup user command carries no secrets past the log boundary.

        The redactor is intentionally broad: every env-style assignment is
        masked, so non-secret values like the username vanish alongside the
        password rather than risking a miss on an unfamiliar name.
        """
        message = (
            "set -eu; ADMIN_USER=ubuntu; MANAGED_PASSWORD="
            "'C1nL0wlFXAbfMIXpr0LKaez51aai2qXW6kI_c3Qhq3Y'; adduser x"
        )
        redacted = sanitize_text(message)

        self.assertNotIn("C1nL0wlFXAbfMIXpr0LKaez51aai2qXW6kI_c3Qhq3Y", redacted)
        self.assertNotIn("ubuntu", redacted)
        self.assertEqual(redacted, "set -eu; ADMIN_USER=***; MANAGED_PASSWORD=***; adduser x")

    def test_sanitize_data_redacts_managed_user_password_field(self):
        """The setup result password never survives a sanitize boundary."""
        redacted = sanitize_data(
            {
                "status": "success",
                "managed_user_password": "C1nL0wlFXAbfMIXpr0LKaez51aai2qXW6kI_c3Qhq3Y",
            }
        )

        self.assertEqual(redacted["status"], "success")
        self.assertEqual(redacted["managed_user_password"], "***")

    def test_sanitize_data_redacts_nested_sensitive_keys(self):
        payload = {
            "username": "ubuntu",
            "password": "test1234",
            "nested": {
                "_sudo_password": "secret-value",
                "token": "abc123",
            },
            "messages": [
                "password=inline-secret",
                "safe-line",
            ],
        }

        sanitized = sanitize_data(payload)
        self.assertEqual(sanitized["password"], "***")
        self.assertEqual(sanitized["nested"]["_sudo_password"], "***")
        self.assertEqual(sanitized["nested"]["token"], "***")
        self.assertIn("password=***", sanitized["messages"][0])
        self.assertEqual(sanitized["messages"][1], "safe-line")


if __name__ == "__main__":
    unittest.main()
