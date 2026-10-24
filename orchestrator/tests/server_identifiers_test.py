"""Contract tests for the managed-server identifier vocabulary.

Written before `orchestrator.server_identifiers` existed (T-3.4.1, discipline
D1). Every expected value is stated literally rather than derived from the
module under test: a test that builds its expectation with the same f-string
as the implementation proves only that the f-string is self-consistent.

The literals here are not arbitrary. Each one is the value the backend
already writes onto customer servers today, transcribed from the call site it
came from. **Changing one renames a live container, network, or label on a
running customer server**, which is why T-3.4.2 is a characterization task and
why these assertions are spelled out rather than generated.
"""

import unittest

from orchestrator import server_identifiers


class TestContainerNames(unittest.TestCase):
    def test_app_container_is_the_slug_under_the_app_prefix(self):
        # engine_scheduler_ops._task_container_name, app_config.container_name
        self.assertEqual(
            server_identifiers.app_container("my-nextjs"),
            "deploydash_app_my-nextjs",
        )

    def test_release_app_container_appends_the_release_id(self):
        # app_config.release_container_name
        self.assertEqual(
            server_identifiers.release_app_container("my-nextjs", "20260903t101500z-abc123"),
            "deploydash_app_my-nextjs_20260903t101500z-abc123",
        )

    def test_worker_container_names_the_project_then_the_worker(self):
        # worker_runtime, release_lifecycle, engine_scheduler_ops all build this.
        self.assertEqual(
            server_identifiers.worker_container("my-nextjs", "queue-worker"),
            "deploydash_worker_my-nextjs_queue-worker",
        )

    def test_release_worker_container_appends_the_release_id(self):
        self.assertEqual(
            server_identifiers.release_worker_container(
                "my-nextjs",
                "queue-worker",
                "20260903t101500z-abc123",
            ),
            "deploydash_worker_my-nextjs_queue-worker_20260903t101500z-abc123",
        )

    def test_legacy_worker_container_has_no_worker_segment(self):
        # runtime_operations still looks for the pre-multi-worker name when
        # reconciling a project deployed before workers gained ids. Dropping
        # it would orphan that container on a real server.
        self.assertEqual(
            server_identifiers.legacy_worker_container("my-nextjs"),
            "deploydash_worker_my-nextjs",
        )

    def test_worker_container_prefix_ends_with_the_separator(self):
        # release_lifecycle prunes by prefix; without the trailing underscore
        # "demo" would also match "demo-staging".
        self.assertEqual(
            server_identifiers.worker_container_prefix("demo"),
            "deploydash_worker_demo_",
        )

    def test_the_three_managed_service_containers_have_fixed_names(self):
        self.assertEqual(server_identifiers.caddy_container(), "deploydash_caddy")
        self.assertEqual(server_identifiers.postgres_container(), "deploydash_postgres")
        self.assertEqual(server_identifiers.bind_container(), "deploydash_bind9")

    def test_container_builders_reject_a_segment_that_could_forge_another_name(self):
        # A slug carrying the separator would produce a name that collides
        # with, or impersonates, another project's container.
        for slug in ("a b", "a/b", "", ".", "..", "-leading", "a$b"):
            with self.subTest(slug=slug), self.assertRaises(ValueError):
                server_identifiers.app_container(slug)
        with self.assertRaises(ValueError):
            server_identifiers.worker_container("demo", "bad worker")


class TestImageNames(unittest.TestCase):
    def test_app_image_is_the_slug_tagged_latest(self):
        # app_config.image_name -- note the app IMAGE has no `app_` segment,
        # unlike the container. They are deliberately different strings.
        self.assertEqual(server_identifiers.app_image("my-nextjs"), "deploydash_my-nextjs:latest")

    def test_release_app_image_uses_a_release_tag_on_the_same_repository(self):
        self.assertEqual(
            server_identifiers.release_app_image("my-nextjs", "20260903t101500z-abc123"),
            "deploydash_my-nextjs:release-20260903t101500z-abc123",
        )

    def test_app_image_prefix_ends_at_the_tag_separator(self):
        # runtime_operation_plans greps image listings with this prefix.
        self.assertEqual(server_identifiers.app_image_prefix("my-nextjs"), "deploydash_my-nextjs:")

    def test_custom_caddy_image_is_built_locally(self):
        self.assertEqual(
            server_identifiers.caddy_custom_image(),
            "deploydash_caddy_custom:local",
        )

    # A gateway update tags the working custom build aside before
    # rebuilding, so a failed build or a rollback can bring it back (#91).
    def test_custom_caddy_previous_image_holds_the_last_working_build(self):
        self.assertEqual(
            server_identifiers.caddy_custom_previous_image(),
            "deploydash_caddy_custom:previous",
        )

    def test_postgres_extension_image_is_tagged_by_major_and_variant(self):
        self.assertEqual(
            server_identifiers.postgres_extension_image("17", "vector"),
            "deploydash/postgres-ext:17-vector",
        )

    def test_postgres_extension_image_without_a_variant_omits_the_suffix(self):
        self.assertEqual(
            server_identifiers.postgres_extension_image("17"),
            "deploydash/postgres-ext:17",
        )

    def test_postgres_extension_repository_is_exposed_for_prefix_matching(self):
        # managed_software and tooling both test membership by prefix.
        self.assertEqual(
            server_identifiers.POSTGRES_EXTENSION_IMAGE_REPOSITORY,
            "deploydash/postgres-ext",
        )


class TestNetworkNames(unittest.TestCase):
    def test_network_name_prefixes_the_role(self):
        self.assertEqual(server_identifiers.network_name("http"), "deploydash_http")

    def test_the_http_network_constant_matches_the_compose_file(self):
        self.assertEqual(server_identifiers.HTTP_NETWORK, "deploydash_http")

    def test_docker_bridge_interface_patterns_have_one_owner(self):
        """Firewall bridge exemptions must share the canonical Docker patterns."""
        self.assertEqual(
            getattr(server_identifiers, "DOCKER_BRIDGE_INTERFACE_PATTERNS", None),
            ("docker0", "br-+"),
        )


class TestLabels(unittest.TestCase):
    def test_every_managed_label_key_is_dot_separated_not_underscore(self):
        # Docker label keys use dots here while container names use
        # underscores. Both appear in the same shell commands, and swapping
        # them silently produces a filter that matches nothing.
        self.assertEqual(server_identifiers.LABEL_MANAGED, "deploydash.managed")
        self.assertEqual(server_identifiers.LABEL_PROJECT, "deploydash.project")
        self.assertEqual(server_identifiers.LABEL_ROLE, "deploydash.role")
        self.assertEqual(server_identifiers.LABEL_RELEASE_ID, "deploydash.release_id")
        self.assertEqual(server_identifiers.LABEL_LIVE, "deploydash.live")
        self.assertEqual(server_identifiers.LABEL_WORKER_ID, "deploydash.worker_id")
        self.assertEqual(server_identifiers.LABEL_WORKER_CPU, "deploydash.worker_cpu")
        self.assertEqual(server_identifiers.LABEL_WORKER_MEMORY_MB, "deploydash.worker_memory_mb")
        self.assertEqual(server_identifiers.LABEL_WORKER_DISK_MB, "deploydash.worker_disk_mb")

    def test_the_only_declared_role_value_is_worker(self):
        # App containers carry no role label; only workers do. A reader adding
        # `role=app` filtering would silently match nothing.
        self.assertEqual(server_identifiers.ROLE_WORKER, "worker")

    # The custom Caddy build stamps the stock base it was built from, so
    # gateway status can tell a current custom build from a stale one (#91).
    def test_caddy_base_label_key_is_dot_separated(self):
        self.assertEqual(
            server_identifiers.LABEL_CADDY_BASE,
            "deploydash.caddy_base",
        )

    def test_label_pair_joins_key_and_value_with_one_equals(self):
        self.assertEqual(
            server_identifiers.label_pair(server_identifiers.LABEL_PROJECT, "demo"),
            "deploydash.project=demo",
        )

    def test_managed_true_is_the_label_every_managed_container_carries(self):
        self.assertEqual(server_identifiers.MANAGED_LABEL_PAIR, "deploydash.managed=true")


class TestSystemdUnits(unittest.TestCase):
    def test_scheduler_unit_base_joins_project_and_task_with_hyphens(self):
        # engine_scheduler_ops._task_unit_names -- hyphens, not the
        # underscores container names use.
        self.assertEqual(
            server_identifiers.scheduler_unit_base("my-nextjs", "nightly-prune"),
            "deploydash-my-nextjs-nightly-prune",
        )

    def test_scheduler_service_and_timer_units_share_that_base(self):
        self.assertEqual(
            server_identifiers.scheduler_service_unit("my-nextjs", "nightly-prune"),
            "deploydash-my-nextjs-nightly-prune.service",
        )
        self.assertEqual(
            server_identifiers.scheduler_timer_unit("my-nextjs", "nightly-prune"),
            "deploydash-my-nextjs-nightly-prune.timer",
        )

    def test_scheduler_script_name_carries_the_shell_suffix(self):
        self.assertEqual(
            server_identifiers.scheduler_script_name("my-nextjs", "nightly-prune"),
            "deploydash-my-nextjs-nightly-prune.sh",
        )


class TestCronJobNames(unittest.TestCase):
    def test_postgres_backup_cron_name_is_namespaced_by_policy(self):
        self.assertEqual(
            server_identifiers.postgres_backup_cron_name("nightly"),
            "deploydash-postgres-backup-nightly",
        )

    def test_postgres_backup_cron_name_rejects_a_traversing_policy_token(self):
        with self.assertRaises(ValueError):
            server_identifiers.postgres_backup_cron_name("../../etc/cron.d/evil")


class TestSudoersDropinName(unittest.TestCase):
    def test_managed_sudoers_dropin_has_one_declared_basename(self):
        """The onboarding sudo grant is addressable by exactly one name.

        New with #62 rather than transcribed: part1 installs this drop-in
        to give the managed user passwordless sudo. The filename carries
        no dot because sudo ignores sudoers.d entries containing one.
        """
        self.assertEqual(
            server_identifiers.SUDOERS_MANAGED_DROPIN_NAME,
            "90-deploydash-managed",
        )


class TestHelperBinaryNames(unittest.TestCase):
    def test_each_managed_helper_has_one_declared_basename(self):
        self.assertEqual(
            server_identifiers.RAILPACK_BUILD_HELPER_NAME,
            "deploydash-railpack-build",
        )
        self.assertEqual(server_identifiers.CADDY_APPLY_HELPER_NAME, "deploydash-caddy-apply")
        self.assertEqual(server_identifiers.BIND_APPLY_HELPER_NAME, "deploydash-bind-apply")


class TestPostgresIdentities(unittest.TestCase):
    def test_the_managed_superuser_is_the_bare_brand_name(self):
        self.assertEqual(server_identifiers.POSTGRES_SUPERUSER, "deploydash")

    def test_role_comments_are_namespaced_so_unmanaged_roles_are_ignored(self):
        # agent_access._parse_postgres_role_comment reads this back and treats
        # a role without the prefix as unmanaged, so the writer and the reader
        # must agree on it exactly.
        self.assertEqual(server_identifiers.POSTGRES_ROLE_COMMENT_PREFIX, "deploydash:")
        self.assertEqual(
            server_identifiers.postgres_role_comment("demo", "demo_main", "read_only"),
            "deploydash:project=demo;db=demo_main;access=read_only",
        )

    def test_readonly_query_wrapper_alias_is_reserved(self):
        # agent_access wraps a caller's SQL in a subquery with this alias; a
        # collision with a caller's own alias would break the query.
        self.assertEqual(server_identifiers.POSTGRES_QUERY_ALIAS, "deploydash_query")

    def test_owner_role_name_is_deterministic_and_greppable_from_the_database(self):
        # #81: one NOLOGIN owner role per database. The stem carries the
        # remote database name so the role is greppable in \du output; the
        # hash suffix (sha256 of the full remote name, independent of this
        # builder) keeps two truncated names from colliding.
        self.assertEqual(
            server_identifiers.postgres_owner_role_name("dd_shop_db"),
            "deploydash_owner_dd_shop_db_67a59fc5ef19",
        )
        self.assertEqual(
            server_identifiers.postgres_owner_role_name("dd_shop_db"),
            server_identifiers.postgres_owner_role_name("dd_shop_db"),
        )

    def test_owner_role_name_stays_inside_the_63_character_limit(self):
        # A 63-character database name still yields a 63-character role: the
        # stem truncates but the hash keeps it unique per database.
        name = server_identifiers.postgres_owner_role_name("a" * 63)
        self.assertEqual(
            name,
            "deploydash_owner_" + "a" * 33 + "_7d3e74a05d7d",
        )
        self.assertLessEqual(len(name), 63)

    def test_owner_role_name_rejects_a_segment_that_could_forge_another_name(self):
        for raw in ("a b", "a/b", "", ".", "..", "-leading", "a$b"):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                server_identifiers.postgres_owner_role_name(raw)

    def test_agent_reader_role_name_is_deterministic_and_greppable_from_the_database(self):
        # #83: one LOGIN reader role per database for the agent tools. Same
        # shape as the owner name: a greppable stem plus a sha256 suffix
        # (of the full remote name, independent of this builder) so two
        # truncated names cannot collide. The kind infix keeps reader names
        # disjoint from owner names.
        self.assertEqual(
            server_identifiers.postgres_agent_reader_role_name("dd_shop_db"),
            "deploydash_agent_reader_dd_shop_db_67a59fc5ef19",
        )
        self.assertEqual(
            server_identifiers.postgres_agent_reader_role_name("dd_shop_db"),
            server_identifiers.postgres_agent_reader_role_name("dd_shop_db"),
        )
        self.assertNotEqual(
            server_identifiers.postgres_agent_reader_role_name("dd_shop_db"),
            server_identifiers.postgres_owner_role_name("dd_shop_db"),
        )

    def test_agent_reader_role_name_stays_inside_the_63_character_limit(self):
        name = server_identifiers.postgres_agent_reader_role_name("a" * 63)
        self.assertEqual(
            name,
            "deploydash_agent_reader_" + "a" * 26 + "_7d3e74a05d7d",
        )
        self.assertLessEqual(len(name), 63)

    def test_agent_reader_role_name_rejects_a_segment_that_could_forge_another_name(
        self,
    ):
        for raw in ("a b", "a/b", "", ".", "..", "-leading", "a$b"):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                server_identifiers.postgres_agent_reader_role_name(raw)


class TestObjectStorageKeys(unittest.TestCase):
    def test_backup_objects_are_namespaced_by_project_then_policy(self):
        self.assertEqual(
            server_identifiers.postgres_backup_object_prefix("demo", "nightly"),
            "deploydash/postgres/demo/nightly",
        )

    def test_the_connection_test_prefix_is_separate_from_backup_data(self):
        # A destination test must never write where a restore would read.
        self.assertEqual(
            server_identifiers.BACKUP_CONNECTION_TEST_PREFIX,
            "deploydash/connection-tests",
        )

    def test_the_managed_object_root_is_the_prefix_restores_verify(self):
        self.assertEqual(server_identifiers.BACKUP_OBJECT_ROOT, "deploydash/")


class TestCaddyIdentifiers(unittest.TestCase):
    def test_the_https_matcher_is_a_caddy_matcher_not_a_docker_network(self):
        # `deploydash_https` reads like a sibling of the `deploydash_http`
        # network and is not one: it names a Caddy request matcher inside a
        # generated Caddyfile. Substituting one for the other would silently
        # drop every hardening header.
        self.assertEqual(server_identifiers.CADDY_HTTPS_MATCHER, "@deploydash_https")


class TestModuleContract(unittest.TestCase):
    def test_every_builder_returns_a_branded_identifier(self):
        values = (
            server_identifiers.app_container("demo"),
            server_identifiers.worker_container("demo", "w"),
            server_identifiers.caddy_container(),
            server_identifiers.postgres_container(),
            server_identifiers.bind_container(),
            server_identifiers.app_image("demo"),
            server_identifiers.caddy_custom_image(),
            server_identifiers.postgres_extension_image("17"),
            server_identifiers.network_name("http"),
            server_identifiers.scheduler_unit_base("demo", "t"),
            server_identifiers.postgres_backup_cron_name("nightly"),
            server_identifiers.postgres_backup_object_prefix("demo", "nightly"),
            server_identifiers.postgres_owner_role_name("dd_demo_db"),
            server_identifiers.postgres_agent_reader_role_name("dd_demo_db"),
        )
        for value in values:
            with self.subTest(value=value):
                self.assertTrue(value.startswith("deploydash"))

    def test_no_builder_returns_an_absolute_path(self):
        # Paths belong to server_paths.py. This module owns names; a builder
        # returning a path here would give the two modules one concept each
        # to fight over.
        import inspect

        builders = [
            name
            for name, value in vars(server_identifiers).items()
            if callable(value)
            and not name.startswith("_")
            and getattr(value, "__module__", None) == server_identifiers.__name__
        ]
        self.assertGreater(len(builders), 10)
        for name in builders:
            builder = getattr(server_identifiers, name)
            arity = len(
                [
                    parameter
                    for parameter in inspect.signature(builder).parameters.values()
                    if parameter.default is inspect.Parameter.empty
                ]
            )
            if name in {"label_pair", "safe_segment"}:
                continue
            result = builder(*(["demo", "worker", "release"][:arity]))
            with self.subTest(builder=name):
                self.assertFalse(result.startswith("/"), f"{name} returned a path")


if __name__ == "__main__":
    unittest.main()
