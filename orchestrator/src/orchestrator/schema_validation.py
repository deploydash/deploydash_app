"""A narrow JSON Schema draft 2020-12 validator (T-1.5.4).

`orchestrator` has exactly one dependency (`pyinfra`) and ships inside the
desktop bundle, so this implements only the keyword subset actually used by
`params_schema` entries across `WORKFLOW_REGISTRY`, rather than pulling in a
general-purpose JSON Schema library: `type` (including nullable arrays of
types), `properties`/`additionalProperties`/`required`, `enum`, `const`,
`pattern`, `minLength`/`maxLength`, `minimum`/`maximum`,
`minItems`/`maxItems`, `items`, `propertyNames`, `dependentRequired`,
`allOf`, and `if`/`then`/`else`. `format` is deliberately not enforced --
per the JSON Schema spec, format is an annotation by default, not an
assertion, and none of the current schemas rely on it being enforced.
"""

import re
from typing import Any


def validate_against_schema(
    instance: Any, schema: dict[str, Any], path: str = "params"
) -> list[str]:
    """Return a list of human-readable error strings (empty if valid).

    Each message is prefixed with the dotted field path of the offending
    value, e.g. "params.settings.database_name is required."
    """
    errors: list[str] = []
    _validate(instance, schema, path, errors)
    return errors


def _validate(instance: Any, schema: dict[str, Any], path: str, errors: list[str]) -> None:
    if not isinstance(schema, dict):
        return

    if "type" in schema and not _check_type(instance, schema["type"], path, errors):
        return

    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path} must equal {schema['const']!r}.")
        return

    if "enum" in schema and not _in_enum(instance, schema["enum"]):
        errors.append(f"{path} must be one of {schema['enum']!r}.")
        return

    if isinstance(instance, str):
        _validate_string(instance, schema, path, errors)
    elif isinstance(instance, bool):
        pass
    elif isinstance(instance, (int, float)):
        _validate_number(instance, schema, path, errors)
    elif isinstance(instance, list):
        _validate_array(instance, schema, path, errors)
    elif isinstance(instance, dict):
        _validate_object(instance, schema, path, errors)

    for subschema in schema.get("allOf", ()):
        _validate(instance, subschema, path, errors)

    if "if" in schema:
        if not validate_against_schema(instance, schema["if"], path):
            if "then" in schema:
                _validate(instance, schema["then"], path, errors)
        elif "else" in schema:
            _validate(instance, schema["else"], path, errors)


def _in_enum(instance: Any, allowed: list[Any]) -> bool:
    return any(type(instance) is type(candidate) and instance == candidate for candidate in allowed)


def _validate_string(instance: str, schema: dict[str, Any], path: str, errors: list[str]) -> None:
    if "minLength" in schema and len(instance) < schema["minLength"]:
        errors.append(f"{path} must be at least {schema['minLength']} characters.")
    if "maxLength" in schema and len(instance) > schema["maxLength"]:
        errors.append(f"{path} must be at most {schema['maxLength']} characters.")
    if "pattern" in schema and re.search(schema["pattern"], instance) is None:
        errors.append(f"{path} does not match the required pattern.")


def _validate_number(
    instance: int | float, schema: dict[str, Any], path: str, errors: list[str]
) -> None:
    if "minimum" in schema and instance < schema["minimum"]:
        errors.append(f"{path} must be >= {schema['minimum']}.")
    if "maximum" in schema and instance > schema["maximum"]:
        errors.append(f"{path} must be <= {schema['maximum']}.")


def _validate_array(
    instance: list[Any], schema: dict[str, Any], path: str, errors: list[str]
) -> None:
    if "minItems" in schema and len(instance) < schema["minItems"]:
        errors.append(f"{path} must have at least {schema['minItems']} item(s).")
    if "maxItems" in schema and len(instance) > schema["maxItems"]:
        errors.append(f"{path} must have at most {schema['maxItems']} item(s).")
    items_schema = schema.get("items")
    if items_schema is not None:
        for index, item in enumerate(instance):
            _validate(item, items_schema, f"{path}[{index}]", errors)


def _validate_object(
    instance: dict[Any, Any], schema: dict[str, Any], path: str, errors: list[str]
) -> None:
    for key in schema.get("required", ()):
        if key not in instance:
            errors.append(f"{path}.{key} is required.")

    properties = schema.get("properties")
    if properties is not None:
        for key, value in instance.items():
            if key in properties:
                _validate(value, properties[key], f"{path}.{key}", errors)

        if schema.get("additionalProperties") is False:
            extra = sorted(set(instance.keys()) - set(properties.keys()))
            for key in extra:
                errors.append(f"{path}.{key} is not a recognized field.")

    property_names_schema = schema.get("propertyNames")
    if property_names_schema is not None:
        for key in instance:
            _validate(key, property_names_schema, f"{path} key {key!r}", errors)

    for key, required_names in schema.get("dependentRequired", {}).items():
        if key not in instance:
            continue
        for required_name in required_names:
            if required_name not in instance:
                errors.append(f"{path}.{required_name} is required when {path}.{key} is set.")


def _check_type(
    instance: Any, allowed_types: str | list[str], path: str, errors: list[str]
) -> bool:
    if isinstance(allowed_types, str):
        allowed_types = [allowed_types]
    if _matches_any_type(instance, allowed_types):
        return True
    errors.append(f"{path} must be of type {' or '.join(allowed_types)}.")
    return False


def _matches_any_type(instance: Any, allowed_types: list[str]) -> bool:
    return any(_matches_type(instance, type_name) for type_name in allowed_types)


def _matches_type(instance: Any, type_name: str) -> bool:
    if type_name == "null":
        return instance is None
    if type_name == "boolean":
        return isinstance(instance, bool)
    if type_name == "integer":
        return isinstance(instance, int) and not isinstance(instance, bool)
    if type_name == "number":
        return isinstance(instance, (int, float)) and not isinstance(instance, bool)
    if type_name == "string":
        return isinstance(instance, str)
    if type_name == "array":
        return isinstance(instance, list)
    if type_name == "object":
        return isinstance(instance, dict)
    return False
