import unittest
from unittest.mock import patch

from orchestrator.app_parts import app_plan


class TestAppPlan(unittest.TestCase):
    def test_normalize_parts_defaults_to_all(self):
        self.assertEqual(
            app_plan.normalize_parts(None),
            list(app_plan.ALL_PARTS),
        )

    def test_normalize_parts_from_string_deduplicates(self):
        parts = app_plan.normalize_parts("part1, part1, part2")
        self.assertEqual(parts, ["part1", "part2"])

    def test_normalize_parts_from_list_filters_invalid_items(self):
        parts = app_plan.normalize_parts([" part1 ", "", 123, "part2", "part1"])
        self.assertEqual(parts, ["part1", "part2"])

    def test_normalize_parts_rejects_invalid_type(self):
        self.assertIsNone(app_plan.normalize_parts({"part": "part1"}))

    def test_collect_steps_rejects_unknown_parts(self):
        result = app_plan.collect_steps(["unknown"], app_config={})
        self.assertEqual(result["ok"], False)
        self.assertEqual(result["invalid_parts"], ["unknown"])

    def test_collect_steps_uses_builders_in_order(self):
        app_config = {"env": "test"}

        def _build_a(config):
            self.assertIs(config, app_config)
            return ["a1", "a2"]

        def _build_b(config):
            self.assertIs(config, app_config)
            return ["b1"]

        with patch.dict(
            app_plan.PART_BUILDERS,
            {"partA": _build_a, "partB": _build_b},
            clear=True,
        ):
            result = app_plan.collect_steps(["partB", "partA"], app_config=app_config)

        self.assertEqual(result["ok"], True)
        self.assertEqual(result["steps"], ["b1", "a1", "a2"])


if __name__ == "__main__":
    unittest.main()
