import unittest

from orchestrator.schema_validation import validate_against_schema


class TestSchemaValidation(unittest.TestCase):
    def test_non_dict_schema_is_a_no_op(self):
        self.assertEqual(validate_against_schema("anything", None), [])
        self.assertEqual(validate_against_schema("anything", "not-a-schema"), [])

    def test_type_mismatch_reports_and_stops(self):
        errors = validate_against_schema("text", {"type": "integer"}, path="x")
        self.assertEqual(errors, ["x must be of type integer."])

    def test_unrecognized_type_name_matches_nothing(self):
        errors = validate_against_schema("text", {"type": "not-a-real-type"}, path="x")
        self.assertEqual(errors, ["x must be of type not-a-real-type."])

    def test_nullable_type_array_accepts_either(self):
        schema = {"type": ["string", "null"]}
        self.assertEqual(validate_against_schema(None, schema), [])
        self.assertEqual(validate_against_schema("ok", schema), [])
        self.assertEqual(
            validate_against_schema(5, schema, path="x"),
            ["x must be of type string or null."],
        )

    def test_const_mismatch(self):
        errors = validate_against_schema("b", {"const": "a"}, path="x")
        self.assertEqual(errors, ["x must equal 'a'."])

    def test_enum_mismatch(self):
        errors = validate_against_schema("c", {"enum": ["a", "b"]}, path="x")
        self.assertEqual(errors, ["x must be one of ['a', 'b']."])

    def test_enum_allows_a_null_candidate_to_match_none(self):
        errors = validate_against_schema(None, {"enum": ["a", None]})
        self.assertEqual(errors, [])

    def test_string_min_length(self):
        errors = validate_against_schema("ab", {"minLength": 3}, path="x")
        self.assertEqual(errors, ["x must be at least 3 characters."])
        self.assertEqual(validate_against_schema("abc", {"minLength": 3}), [])

    def test_string_max_length(self):
        errors = validate_against_schema("abcd", {"maxLength": 3}, path="x")
        self.assertEqual(errors, ["x must be at most 3 characters."])
        self.assertEqual(validate_against_schema("abc", {"maxLength": 3}), [])

    def test_string_pattern(self):
        schema = {"pattern": r"^[a-z]+$"}
        errors = validate_against_schema("ABC", schema, path="x")
        self.assertEqual(errors, ["x does not match the required pattern."])
        self.assertEqual(validate_against_schema("abc", schema), [])

    def test_number_minimum(self):
        errors = validate_against_schema(1, {"minimum": 2}, path="x")
        self.assertEqual(errors, ["x must be >= 2."])
        self.assertEqual(validate_against_schema(2, {"minimum": 2}), [])

    def test_number_maximum(self):
        errors = validate_against_schema(5, {"maximum": 4}, path="x")
        self.assertEqual(errors, ["x must be <= 4."])
        self.assertEqual(validate_against_schema(4, {"maximum": 4}), [])

    def test_array_min_items(self):
        errors = validate_against_schema([], {"minItems": 1}, path="x")
        self.assertEqual(errors, ["x must have at least 1 item(s)."])
        self.assertEqual(validate_against_schema([1], {"minItems": 1}), [])

    def test_array_max_items(self):
        errors = validate_against_schema([1, 2], {"maxItems": 1}, path="x")
        self.assertEqual(errors, ["x must have at most 1 item(s)."])
        self.assertEqual(validate_against_schema([1], {"maxItems": 1}), [])

    def test_array_items_recurses_with_indexed_path(self):
        schema = {"items": {"type": "integer"}}
        errors = validate_against_schema([1, "two"], schema, path="x")
        self.assertEqual(errors, ["x[1] must be of type integer."])

    def test_object_required(self):
        errors = validate_against_schema({}, {"required": ["a"]}, path="x")
        self.assertEqual(errors, ["x.a is required."])
        self.assertEqual(validate_against_schema({"a": 1}, {"required": ["a"]}), [])

    def test_object_properties_recurses(self):
        schema = {"properties": {"a": {"type": "integer"}}}
        errors = validate_against_schema({"a": "not-int"}, schema, path="x")
        self.assertEqual(errors, ["x.a must be of type integer."])

    def test_object_additional_properties_false_rejects_unknown_keys(self):
        schema = {"properties": {"a": {}}, "additionalProperties": False}
        errors = validate_against_schema({"a": 1, "b": 2}, schema, path="x")
        self.assertEqual(errors, ["x.b is not a recognized field."])

    def test_object_additional_properties_absent_allows_unknown_keys(self):
        schema = {"properties": {"a": {}}}
        errors = validate_against_schema({"a": 1, "b": 2}, schema, path="x")
        self.assertEqual(errors, [])

    def test_property_names_validates_each_key(self):
        schema = {"propertyNames": {"pattern": r"^[a-z]+$"}}
        errors = validate_against_schema({"BAD": 1}, schema, path="x")
        self.assertEqual(errors, ["x key 'BAD' does not match the required pattern."])

    def test_dependent_required(self):
        schema = {"dependentRequired": {"a": ["b", "c"]}}
        errors = validate_against_schema({"a": 1}, schema, path="x")
        self.assertEqual(
            sorted(errors),
            ["x.b is required when x.a is set.", "x.c is required when x.a is set."],
        )
        self.assertEqual(validate_against_schema({}, schema), [])
        self.assertEqual(validate_against_schema({"a": 1, "b": 2, "c": 3}, schema), [])

    def test_all_of_accumulates_errors_from_every_subschema(self):
        schema = {"allOf": [{"minimum": 5}, {"maximum": 1}]}
        errors = validate_against_schema(3, schema, path="x")
        self.assertEqual(sorted(errors), ["x must be <= 1.", "x must be >= 5."])

    def test_if_then_runs_then_when_if_matches(self):
        schema = {
            "if": {"const": "a"},
            "then": {"enum": ["a", "b"]},
            "else": {"enum": ["c"]},
        }
        self.assertEqual(validate_against_schema("a", schema), [])

    def test_if_then_runs_else_when_if_does_not_match(self):
        schema = {
            "if": {"const": "a"},
            "then": {"enum": ["z"]},
            "else": {"enum": ["c"]},
        }
        self.assertEqual(validate_against_schema("c", schema), [])
        errors = validate_against_schema("d", schema, path="x")
        self.assertEqual(errors, ["x must be one of ['c']."])

    def test_if_without_then_when_if_matches_is_a_no_op(self):
        # Covers the branch where "if" matches but the schema declares no
        # "then" -- nothing should be asserted.
        schema = {"if": {"const": "a"}}
        self.assertEqual(validate_against_schema("a", schema), [])

    def test_if_without_else_when_if_does_not_match_is_a_no_op(self):
        schema = {"if": {"const": "a"}, "then": {"enum": ["z"]}}
        self.assertEqual(validate_against_schema("b", schema), [])


if __name__ == "__main__":
    unittest.main()
