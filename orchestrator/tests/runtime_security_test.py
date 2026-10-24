import unittest

from orchestrator.runtime_security import (
    DEFAULT_CONTAINER_PIDS_LIMIT,
    DEFAULT_HSTS_VALUE,
    DEFAULT_PERMISSIONS_POLICY,
    ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING,
    caddy_default_header_lines,
    docker_compose_security_lines,
    docker_runtime_security_flags,
)


class TestRuntimeSecurity(unittest.TestCase):
    def test_docker_runtime_security_flags_render_defaults(self):
        self.assertEqual(
            docker_runtime_security_flags(),
            "--security-opt no-new-privileges --cap-drop ALL "
            f"--pids-limit {DEFAULT_CONTAINER_PIDS_LIMIT}",
        )

    def test_docker_runtime_security_flags_render_entrypoint_compatible_profile(self):
        self.assertEqual(
            docker_runtime_security_flags(profile=ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING),
            f"--pids-limit {DEFAULT_CONTAINER_PIDS_LIMIT}",
        )

    def test_docker_runtime_security_flags_rejects_invalid_limit(self):
        with self.assertRaises(ValueError):
            docker_runtime_security_flags(pids_limit=0)
        with self.assertRaises(ValueError):
            docker_runtime_security_flags(profile="unknown")

    def test_docker_compose_security_lines_render_defaults(self):
        rendered = docker_compose_security_lines()

        self.assertIn("    security_opt:\n      - no-new-privileges:true", rendered)
        self.assertIn("    cap_drop:\n      - ALL", rendered)
        self.assertIn(f"    pids_limit: {DEFAULT_CONTAINER_PIDS_LIMIT}", rendered)
        self.assertNotIn("cap_add:", rendered)

    def test_docker_compose_security_lines_render_cap_add(self):
        rendered = docker_compose_security_lines(cap_add=("NET_BIND_SERVICE",))

        self.assertIn("    cap_add:\n      - NET_BIND_SERVICE", rendered)

    def test_docker_compose_security_lines_render_entrypoint_compatible_profile(self):
        rendered = docker_compose_security_lines(profile=ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING)

        self.assertNotIn("security_opt:", rendered)
        self.assertNotIn("cap_drop:", rendered)
        self.assertIn(f"    pids_limit: {DEFAULT_CONTAINER_PIDS_LIMIT}", rendered)

    def test_docker_compose_security_lines_rejects_invalid_values(self):
        with self.assertRaises(ValueError):
            docker_compose_security_lines(pids_limit=0)
        with self.assertRaises(ValueError):
            docker_compose_security_lines(cap_add=("",))
        with self.assertRaises(ValueError):
            docker_compose_security_lines(profile="unknown")
        with self.assertRaises(ValueError):
            docker_compose_security_lines(
                cap_add=("NET_BIND_SERVICE",),
                profile=ENTRYPOINT_COMPATIBLE_CONTAINER_HARDENING,
            )

    def test_caddy_default_header_lines_without_hsts(self):
        lines = caddy_default_header_lines(include_hsts=False)
        rendered = "\n".join(lines)
        self.assertIn("?X-Content-Type-Options nosniff", rendered)
        self.assertIn("?Referrer-Policy strict-origin-when-cross-origin", rendered)
        self.assertIn(f"?Permissions-Policy {DEFAULT_PERMISSIONS_POLICY}", rendered)
        self.assertIn("?X-Frame-Options SAMEORIGIN", rendered)
        self.assertNotIn("Strict-Transport-Security", rendered)

    def test_caddy_default_header_lines_with_hsts(self):
        lines = caddy_default_header_lines(include_hsts=True)
        rendered = "\n".join(lines)
        self.assertIn("@deploydash_https protocol https", rendered)
        self.assertIn(
            f"?Strict-Transport-Security {DEFAULT_HSTS_VALUE}",
            rendered,
        )


if __name__ == "__main__":
    unittest.main()
