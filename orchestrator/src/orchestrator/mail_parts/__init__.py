WORKFLOW_ID = "mail"

# Neither operation has a real handler yet -- both fall through to
# unimplemented_handler (engine_bootstrap.py's plugin list has no mail entry).
# It therefore owns no operation parameters.  Keep the empty *closed* schema:
# accepting an arbitrary parameter would make a speculative wire contract that
# callers could mistake for supported mail configuration.  Replace it with a
# derived schema when mail_parts grows a config module and plugin.
_UNIMPLEMENTED_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "additionalProperties": False,
    "properties": {},
}

OPERATIONS = {
    "describe": {
        "id": "describe",
        "label": "Describe mail server plan",
        "description": "Preview Stalwart mail setup and hardening actions",
        "params_schema": _UNIMPLEMENTED_SCHEMA,
    },
    "run": {
        "id": "run",
        "label": "Run mail server plan",
        "description": "Apply Stalwart mail setup and hardening actions",
        "params_schema": _UNIMPLEMENTED_SCHEMA,
    },
}
