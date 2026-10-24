import json
import unittest

from orchestrator.infra_parts import docker_storage as engine_docker_storage


class _FakeOutput:
    def __init__(self, stdout_lines):
        self.stdout_lines = stdout_lines


def _parse(lines):
    # Why: pins _parse_docker_storage_status_output behavior so the B-11/B-52e
    # row-literal collapse (T-153) can prove output-identical for all inputs.
    return engine_docker_storage._parse_docker_storage_status_output(_FakeOutput(lines))


def _row(row_type, **fields):
    payload = {"Type": row_type}
    payload.update(fields)
    return json.dumps(payload)


class TestDockerStorageRowParsing(unittest.TestCase):
    def test_images_row_only_populates_images(self):
        parsed = _parse(
            [
                _row(
                    "Images",
                    TotalCount="14",
                    Active="7",
                    Size="1.25GB",
                    Reclaimable="700MB (56%)",
                )
            ]
        )

        self.assertEqual(parsed["images"]["size_bytes"], 1250000000)
        self.assertEqual(parsed["images"]["reclaimable_bytes"], 700000000)
        self.assertEqual(parsed["images"]["total_count"], 14)
        self.assertEqual(parsed["images"]["active_count"], 7)
        self.assertEqual(parsed["build_cache"], {})

    def test_build_cache_row_only_populates_build_cache(self):
        parsed = _parse(
            [
                _row(
                    "Build Cache",
                    TotalCount="28",
                    Active="0",
                    Size="450MB",
                    Reclaimable="450MB",
                )
            ]
        )

        self.assertEqual(parsed["images"], {})
        self.assertEqual(parsed["build_cache"]["size_bytes"], 450000000)
        self.assertEqual(parsed["build_cache"]["reclaimable_bytes"], 450000000)
        self.assertEqual(parsed["build_cache"]["total_count"], 28)
        self.assertEqual(parsed["build_cache"]["active_count"], 0)

    def test_both_rows_populate_both_slots(self):
        parsed = _parse(
            [
                _row("Images", TotalCount="1", Active="1", Size="5MB", Reclaimable="0B"),
                _row("Build Cache", TotalCount="2", Active="0", Size="6MB", Reclaimable="6MB"),
            ]
        )

        self.assertEqual(parsed["images"]["size_bytes"], 5000000)
        self.assertEqual(parsed["build_cache"]["size_bytes"], 6000000)

    def test_unknown_row_type_is_skipped(self):
        parsed = _parse(
            [
                _row("Containers", TotalCount="3", Active="1", Size="9MB", Reclaimable="0B"),
                _row("Volumes", TotalCount="4", Active="0", Size="1MB", Reclaimable="0B"),
            ]
        )

        self.assertEqual(parsed["images"], {})
        self.assertEqual(parsed["build_cache"], {})
        self.assertIn("checked_at", parsed)

    def test_bad_json_and_non_dict_rows_are_skipped(self):
        parsed = _parse(
            [
                "not json at all",
                "",
                "   ",
                "[]",
                "42",
                _row("Images", TotalCount="1", Active="1", Size="5MB", Reclaimable="0B"),
            ]
        )

        self.assertEqual(parsed["images"]["total_count"], 1)

    def test_repeated_row_type_last_wins(self):
        parsed = _parse(
            [
                _row("Images", TotalCount="1", Active="1", Size="5MB", Reclaimable="0B"),
                _row("Images", TotalCount="9", Active="2", Size="10MB", Reclaimable="1MB"),
                _row("Build Cache", TotalCount="3", Active="0", Size="7MB", Reclaimable="7MB"),
                _row("Build Cache", TotalCount="4", Active="1", Size="8MB", Reclaimable="2MB"),
            ]
        )

        self.assertEqual(parsed["images"]["total_count"], 9)
        self.assertEqual(parsed["images"]["size_bytes"], 10000000)
        self.assertEqual(parsed["build_cache"]["total_count"], 4)
        self.assertEqual(parsed["build_cache"]["size_bytes"], 8000000)

    def test_missing_keys_yield_none_fields(self):
        parsed = _parse([_row("Images")])

        self.assertEqual(
            parsed["images"],
            {
                "size_bytes": None,
                "reclaimable_bytes": None,
                "total_count": None,
                "active_count": None,
            },
        )

    def test_row_type_matching_ignores_case_and_whitespace(self):
        parsed = _parse(
            [
                _row("  IMAGES  ", TotalCount="1", Active="0", Size="1MB", Reclaimable="0B"),
                _row("  Build Cache\t", TotalCount="2", Active="0", Size="2MB", Reclaimable="0B"),
            ]
        )

        self.assertEqual(parsed["images"]["total_count"], 1)
        self.assertEqual(parsed["build_cache"]["total_count"], 2)

    def test_build_cache_row_at_loop_tail_keeps_fall_through(self):
        # Why: the build-cache arm has no trailing `continue`; a row AFTER it
        # must still be processed (e.g. an images row after build-cache wins).
        parsed = _parse(
            [
                _row("Build Cache", TotalCount="2", Active="0", Size="2MB", Reclaimable="0B"),
                _row("Images", TotalCount="5", Active="1", Size="3MB", Reclaimable="0B"),
            ]
        )

        self.assertEqual(parsed["build_cache"]["total_count"], 2)
        self.assertEqual(parsed["images"]["total_count"], 5)


if __name__ == "__main__":
    unittest.main()
