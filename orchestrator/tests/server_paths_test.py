"""Contract tests for the managed-server filesystem layout.

Written before `orchestrator.server_paths` existed (T-1.1.1, discipline D1).
Every expected value here is stated literally rather than derived from the
module under test: a test that builds its expectation by calling the same
join helper as the implementation proves only that the helper is
self-consistent, which is the failure mode the plan's forbidden-patterns list
names explicitly.
"""

import unittest

from orchestrator import server_paths


class TestLayoutRoots(unittest.TestCase):
    def test_every_managed_path_lives_under_one_branded_root(self):
        self.assertEqual(server_paths.DEPLOYDASH_ROOT, "/opt/deploydash")
        self.assertEqual(server_paths.STACK_ROOT, "/opt/deploydash/stack")
        self.assertEqual(server_paths.STATE_ROOT, "/opt/deploydash/state")
        self.assertEqual(server_paths.FIREWALL_ROOT, "/opt/deploydash/firewall")

    def test_logs_stay_outside_opt_because_fhs_puts_them_in_var_log(self):
        self.assertEqual(server_paths.LOG_ROOT, "/var/log/deploydash")

    def test_layout_version_file_sits_at_the_root_so_a_half_built_server_is_identifiable(self):
        self.assertEqual(
            server_paths.LAYOUT_VERSION_FILE,
            "/opt/deploydash/LAYOUT_VERSION",
        )

    def test_layout_version_is_an_integer_not_a_string(self):
        # It is compared with `>` against a value parsed off the server, so a
        # string here would make the too-new branch compare lexicographically
        # and accept version 10 as older than version 9.
        self.assertIsInstance(server_paths.LAYOUT_VERSION, int)
        self.assertEqual(server_paths.LAYOUT_VERSION, 2)


class TestStackDirectories(unittest.TestCase):
    def test_each_stack_component_has_its_own_directory(self):
        self.assertEqual(server_paths.apps_root(), "/opt/deploydash/stack/apps")
        self.assertEqual(server_paths.http_root(), "/opt/deploydash/stack/http")
        self.assertEqual(server_paths.dns_root(), "/opt/deploydash/stack/dns")
        self.assertEqual(server_paths.mail_root(), "/opt/deploydash/stack/mail")
        self.assertEqual(server_paths.proxy_root(), "/opt/deploydash/stack/proxy")
        self.assertEqual(server_paths.db_root(), "/opt/deploydash/stack/db")
        self.assertEqual(server_paths.postgres_root(), "/opt/deploydash/stack/postgres")
        self.assertEqual(server_paths.railpack_root(), "/opt/deploydash/stack/railpack")

    def test_railpack_env_file_sits_inside_the_railpack_directory(self):
        self.assertEqual(
            server_paths.railpack_env_file(),
            "/opt/deploydash/stack/railpack/railpack.env",
        )

    def test_postgres_tls_material_stays_inside_the_postgres_stack(self):
        """TLS trust and access policy must share the managed service lifecycle."""
        self.assertEqual(
            getattr(server_paths, "postgres_tls_root", lambda: None)(),
            "/opt/deploydash/stack/postgres/tls",
        )
        self.assertEqual(
            getattr(server_paths, "postgres_tls_certificate", lambda: None)(),
            "/opt/deploydash/stack/postgres/tls/server.crt",
        )
        self.assertEqual(
            getattr(server_paths, "postgres_tls_private_key", lambda: None)(),
            "/opt/deploydash/stack/postgres/tls/server.key",
        )
        self.assertEqual(
            getattr(server_paths, "postgres_hba_file", lambda: None)(),
            "/opt/deploydash/stack/postgres/tls/pg_hba.conf",
        )

    def test_app_dir_is_the_project_slug_under_the_apps_root(self):
        self.assertEqual(
            server_paths.app_dir("my-nextjs"),
            "/opt/deploydash/stack/apps/my-nextjs",
        )

    def test_app_dir_refuses_a_slug_that_would_escape_the_apps_root(self):
        # A traversing slug would place a managed app outside the layout
        # entirely, where nothing that cleans up projects would ever find it.
        for slug in ("../evil", "a/b", "/absolute", "", ".", ".."):
            with self.subTest(slug=slug), self.assertRaises(ValueError):
                server_paths.app_dir(slug)


class TestStateDirectories(unittest.TestCase):
    def test_postgres_major_upgrade_ledger_is_part_of_layout_two(self):
        """Layout two owns the retained-volume ledger under server state."""
        self.assertEqual(
            server_paths.postgres_upgrade_ledger(),
            "/opt/deploydash/state/postgres-major-upgrades.json",
        )

    def test_ledger_lives_under_state_not_inside_the_stack(self):
        # The ledger describes the server, not one component of the stack.
        self.assertEqual(
            server_paths.managed_software_ledger(),
            "/opt/deploydash/state/managed-software-ledger.json",
        )

    def test_postgres_upgrade_ledger_lives_with_other_server_state(self):
        """Retained-volume ownership must survive independently of stack files."""
        self.assertEqual(
            server_paths.postgres_upgrade_ledger(),
            "/opt/deploydash/state/postgres-major-upgrades.json",
        )

    def test_scheduler_scripts_live_under_state(self):
        self.assertEqual(
            server_paths.scheduler_script_dir(),
            "/opt/deploydash/state/scheduler",
        )

    def test_upgrade_backups_live_under_state(self):
        self.assertEqual(
            server_paths.upgrade_backups_root(),
            "/opt/deploydash/state/upgrade-backups",
        )

    def test_upgrade_backup_dir_is_namespaced_by_service_then_timestamp(self):
        self.assertEqual(
            server_paths.upgrade_backup_dir("postgres", "20260828T101500Z"),
            "/opt/deploydash/state/upgrade-backups/postgres/20260828T101500Z",
        )

    def test_upgrade_backup_service_dir_omits_the_timestamp(self):
        # The rollback safety path needs the service directory itself, because
        # it appends a shell-evaluated timestamp on the server.
        self.assertEqual(
            server_paths.upgrade_backup_service_dir("postgresql_database_service"),
            "/opt/deploydash/state/upgrade-backups/postgresql_database_service",
        )

    def test_upgrade_backup_rejects_a_traversing_service_name(self):
        with self.assertRaises(ValueError):
            server_paths.upgrade_backup_dir("../..", "20260828T101500Z")
        with self.assertRaises(ValueError):
            server_paths.upgrade_backup_service_dir("../..")


class TestLogPaths(unittest.TestCase):
    def test_postgres_backup_log_is_named_for_its_policy(self):
        self.assertEqual(
            server_paths.postgres_backup_log("nightly"),
            "/var/log/deploydash/postgres-backup-nightly.log",
        )

    def test_postgres_backup_log_rejects_a_traversing_policy_token(self):
        with self.assertRaises(ValueError):
            server_paths.postgres_backup_log("../../etc/cron.d/evil")


class TestManagedFilesOutsideTheLayout(unittest.TestCase):
    """Files Deploy Dash owns in directories the OS owns.

    Every value here is transcribed from the call site that held it as a
    literal before T-3.4.2. Changing one orphans a file already written to
    customer servers: the product would then write a second config beside
    the first and never clean the first up.
    """

    def test_managed_drop_ins_sort_before_distribution_defaults(self):
        # The sshd drop-in is `00-` prefixed so it loads before anything the
        # distribution ships; the sysctl files are `99-` prefixed so they
        # load after. Both orderings are load-bearing.
        self.assertEqual(
            server_paths.SSHD_DROPIN_FILE,
            "/etc/ssh/sshd_config.d/00-deploydash.conf",
        )
        self.assertEqual(
            server_paths.SYSCTL_PERFORMANCE_FILE,
            "/etc/sysctl.d/99-deploydash-performance.conf",
        )
        self.assertEqual(
            server_paths.SYSCTL_SECURITY_FILE,
            "/etc/sysctl.d/99-deploydash-security.conf",
        )

    def test_the_remaining_managed_os_files(self):
        self.assertEqual(server_paths.CLOUD_INIT_CONFIG_FILE, "/etc/cloud/cloud.cfg")
        self.assertEqual(server_paths.CLOUD_INIT_CONFIG_DIR, "/etc/cloud/cloud.cfg.d")
        self.assertEqual(
            server_paths.CLOUD_INIT_HOSTS_TEMPLATE,
            "/etc/cloud/templates/hosts.debian.tmpl",
        )
        self.assertEqual(
            server_paths.JOURNALD_DROPIN_FILE,
            "/etc/systemd/journald.conf.d/deploydash.conf",
        )
        self.assertEqual(server_paths.AUDIT_RULES_FILE, "/etc/audit/rules.d/deploydash.rules")
        self.assertEqual(
            server_paths.MODPROBE_BLACKLIST_FILE,
            "/etc/modprobe.d/deploydash-blacklist.conf",
        )

    def test_managed_sudoers_dropin_grants_passwordless_sudo(self):
        """The onboarding sudo grant lives at one owned path.

        New with #62: part1 installs this drop-in so post-handoff steps
        can run `sudo -n`. The `90-` prefix sorts it after distribution
        defaults, matching the sysctl convention above.
        """
        self.assertEqual(
            server_paths.SUDOERS_MANAGED_DROPIN_FILE,
            "/etc/sudoers.d/90-deploydash-managed",
        )

    def test_the_sshd_backup_survives_a_reboot(self):
        # Not a temp prefix, unlike its two neighbours below. This backup is
        # the only way back from an onboarding that hardened SSH and then
        # died, and /tmp is cleared on the reboot such a recovery starts with.
        self.assertEqual(
            server_paths.SETUP_SSHD_BACKUP_PREFIX,
            "/opt/deploydash/state/setup-sshd-backup/deploydash-setup-sshd-",
        )
        self.assertTrue(
            server_paths.SETUP_SSHD_BACKUP_PREFIX.startswith(
                server_paths.STATE_ROOT + "/",
            ),
        )

    def test_temp_prefixes_end_where_the_server_appends_its_own_suffix(self):
        # Each call site appends `$(date +%s)-$$` on the server, so a
        # trailing separator here is what keeps concurrent runs apart.
        self.assertEqual(server_paths.SYSTEM_BACKUP_TEMP_PREFIX, "/tmp/deploydash-system-backup-")
        self.assertEqual(
            server_paths.POSTGRES_IMPORT_TEMP_PREFIX,
            "/tmp/deploydash-postgres-import-",
        )

    def test_helper_binaries_are_installed_on_the_default_path(self):
        self.assertEqual(
            server_paths.railpack_build_helper(),
            "/usr/local/bin/deploydash-railpack-build",
        )
        self.assertEqual(
            server_paths.caddy_apply_helper(),
            "/usr/local/bin/deploydash-caddy-apply",
        )
        self.assertEqual(server_paths.bind_apply_helper(), "/usr/local/bin/deploydash-bind-apply")

    def test_backup_cron_file_is_named_for_its_policy(self):
        self.assertEqual(
            server_paths.postgres_backup_cron_file("nightly"),
            "/etc/cron.d/deploydash-postgres-backup-nightly",
        )

    def test_backup_cron_file_rejects_a_traversing_policy_token(self):
        # A traversing token would drop a cron file anywhere on the server.
        with self.assertRaises(ValueError):
            server_paths.postgres_backup_cron_file("../../../root/.ssh/authorized_keys")


class TestModuleContract(unittest.TestCase):
    def test_no_builder_accepts_a_root_argument(self):
        # The plan's rule: the layout is defined here and nowhere else. A
        # builder that accepts a root re-opens the door this module closes,
        # because a caller could then pass a stale root from the wire.
        import inspect

        builders = [
            name
            for name, value in vars(server_paths).items()
            if callable(value)
            and not name.startswith("_")
            and getattr(value, "__module__", None) == server_paths.__name__
        ]
        self.assertGreater(len(builders), 10)
        for name in builders:
            with self.subTest(builder=name):
                params = inspect.signature(getattr(server_paths, name)).parameters
                for param in params:
                    self.assertNotIn(
                        "root",
                        param.lower(),
                        f"{name} accepts a root argument",
                    )

    def test_every_builder_returns_an_absolute_path(self):
        self.assertTrue(
            all(
                value.startswith("/")
                for value in (
                    server_paths.apps_root(),
                    server_paths.app_dir("demo"),
                    server_paths.http_root(),
                    server_paths.dns_root(),
                    server_paths.mail_root(),
                    server_paths.proxy_root(),
                    server_paths.db_root(),
                    server_paths.postgres_root(),
                    server_paths.railpack_root(),
                    server_paths.railpack_env_file(),
                    server_paths.managed_software_ledger(),
                    server_paths.postgres_upgrade_ledger(),
                    server_paths.scheduler_script_dir(),
                    server_paths.upgrade_backups_root(),
                    server_paths.upgrade_backup_dir("postgres", "t"),
                    server_paths.upgrade_backup_service_dir("postgres"),
                    server_paths.postgres_backup_log("nightly"),
                    server_paths.postgres_backup_cron_file("nightly"),
                    server_paths.railpack_build_helper(),
                    server_paths.caddy_apply_helper(),
                    server_paths.bind_apply_helper(),
                )
            )
        )

    def test_setup_creates_the_root_before_any_subdirectory(self):
        # T-1.1.5 depends on this ordering: the version marker is written
        # first so a server that dies mid-provision is still identifiable.
        self.assertEqual(server_paths.stack_setup_directories()[0], "/opt/deploydash")
        self.assertEqual(server_paths.stack_setup_directories()[1], "/opt/deploydash/stack")
        self.assertIn("/opt/deploydash/stack/apps", server_paths.stack_setup_directories())


if __name__ == "__main__":
    unittest.main()
