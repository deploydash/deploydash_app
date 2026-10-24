from .part1_foundation import build_steps as build_part1_steps
from .part2_runtime import build_steps as build_part2_steps

PART_BUILDERS = {
    "part1": build_part1_steps,
    "part2": build_part2_steps,
}

ALL_PARTS = tuple(PART_BUILDERS.keys())


def normalize_parts(parts_value):
    if parts_value is None:
        return list(ALL_PARTS)

    if isinstance(parts_value, str):
        values = [value.strip() for value in parts_value.split(",") if value.strip()]
    elif isinstance(parts_value, list):
        values = [
            value.strip() for value in parts_value if isinstance(value, str) and value.strip()
        ]
    else:
        return None

    if not values:
        return list(ALL_PARTS)

    seen = set()
    ordered = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        ordered.append(value)

    return ordered


def collect_steps(parts, http_config):
    steps = []
    invalid_parts = [part for part in parts if part not in PART_BUILDERS]
    if invalid_parts:
        return {"ok": False, "invalid_parts": invalid_parts}

    for part in parts:
        builder = PART_BUILDERS[part]
        steps.extend(builder(http_config))

    return {"ok": True, "steps": steps}
