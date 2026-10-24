WORKFLOW_ID = "scheduler"

# T-1.5.3: params_schema describes payload["params"]. Unlike every other
# workflow, scheduler has genuinely distinct per-operation parse functions
# (engine_scheduler_ops.py::_parse_task_upsert_settings and friends) rather
# than one shared settings dataclass -- so each operation below has its own
# tailored schema instead of sharing one settings-properties dict.
_PROJECT_SLUG = {"type": "string", "pattern": r"^[a-z0-9][a-z0-9-]{0,62}$"}
_TASK_ID = {"type": "string", "pattern": r"^[a-z0-9][a-z0-9-]{0,62}$"}
_WORKER_REF = {"type": "string", "pattern": r"^[a-z0-9][a-z0-9_-]{0,62}$"}
_DAILY_TIME = {"type": "string", "pattern": r"^(?:[01]?\d|2[0-3]):[0-5]\d$"}


def _settings_schema(properties, required):
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "dry_run": {"type": "boolean"},
            "settings": {
                "type": "object",
                "additionalProperties": False,
                "properties": properties,
                "required": required,
            },
        },
    }


_TASK_UPSERT_CONDITIONALS = {
    "allOf": [
        {
            "if": {
                "properties": {"target_type": {"const": "worker"}},
                "required": ["target_type"],
            },
            "then": {"required": ["target_ref"]},
        },
        {
            "if": {
                "properties": {
                    "schedule_type": {"enum": ["every_minutes", "every_hours"]},
                },
                "required": ["schedule_type"],
            },
            "then": {"required": ["interval_value"]},
        },
    ],
}


def _task_upsert_schema():
    schema = _settings_schema(
        properties={
            "project_slug": _PROJECT_SLUG,
            "task_id": _TASK_ID,
            "name": {"type": "string", "minLength": 1},
            "command": {"type": "string", "minLength": 1},
            "target_type": {"type": "string", "enum": ["web_app", "worker"]},
            "target_ref": _WORKER_REF,
            "schedule_type": {
                "type": "string",
                "enum": ["every_minutes", "every_hours", "daily_at"],
            },
            "interval_value": {"type": "integer", "minimum": 1, "maximum": 1440},
            "daily_time": _DAILY_TIME,
            "enabled": {"type": "boolean"},
        },
        required=[
            "project_slug",
            "task_id",
            "name",
            "command",
            "target_type",
            "schedule_type",
        ],
    )
    schema["properties"]["settings"].update(_TASK_UPSERT_CONDITIONALS)
    return schema


def _task_delete_schema():
    return _settings_schema(
        properties={"project_slug": _PROJECT_SLUG, "task_id": _TASK_ID},
        required=["project_slug", "task_id"],
    )


def _task_set_enabled_schema():
    return _settings_schema(
        properties={
            "project_slug": _PROJECT_SLUG,
            "task_id": _TASK_ID,
            "enabled": {"type": "boolean"},
        },
        required=["project_slug", "task_id"],
    )


def _task_run_now_schema():
    schema = _settings_schema(
        properties={
            "project_slug": _PROJECT_SLUG,
            "task_id": _TASK_ID,
            # An optional override of the stored task's command/target for
            # this one run -- both command and target_type must be sent
            # together for the override to apply (engine_scheduler_ops.py's
            # _parse_task_run_now_settings silently ignores either alone).
            "command": {"type": "string", "minLength": 1},
            "target_type": {"type": "string", "enum": ["web_app", "worker"]},
            "target_ref": _WORKER_REF,
        },
        required=["project_slug", "task_id"],
    )
    schema["properties"]["settings"]["allOf"] = [
        {
            "if": {
                "properties": {"target_type": {"const": "worker"}},
                "required": ["target_type"],
            },
            "then": {"required": ["target_ref"]},
        },
    ]
    return schema


def _task_status_schema():
    return _settings_schema(
        properties={
            "project_slug": _PROJECT_SLUG,
            "task_ids": {
                "type": "array",
                "minItems": 1,
                "items": _TASK_ID,
            },
        },
        required=["project_slug", "task_ids"],
    )


def _describe_schema():
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "properties": {"dry_run": {"type": "boolean"}},
    }


OPERATIONS = {
    "describe": {
        "id": "describe",
        "label": "Describe scheduler plan",
        "description": "Describe project task scheduling capabilities",
        "params_schema": _describe_schema(),
    },
    "task_upsert": {
        "id": "task_upsert",
        "label": "Create or update scheduled task",
        "description": "Write systemd service/timer units for a project task",
        "params_schema": _task_upsert_schema(),
    },
    "task_delete": {
        "id": "task_delete",
        "label": "Delete scheduled task",
        "description": "Remove systemd service/timer units for a project task",
        "params_schema": _task_delete_schema(),
    },
    "task_set_enabled": {
        "id": "task_set_enabled",
        "label": "Enable or disable task",
        "description": "Enable/disable project task timer without deleting task",
        "params_schema": _task_set_enabled_schema(),
    },
    "task_run_now": {
        "id": "task_run_now",
        "label": "Run scheduled task now",
        "description": "Trigger a one-shot run of the scheduled task service",
        "params_schema": _task_run_now_schema(),
    },
    "task_status": {
        "id": "task_status",
        "label": "Read task status",
        "description": "Read timer/service runtime status for project tasks",
        "params_schema": _task_status_schema(),
    },
}
