import json
import traceback
from collections.abc import Callable
from typing import Any

from .compat import resolve_request_target
from .contracts import EmitFn, RequestTarget
from .schema_validation import validate_against_schema

# T-1.5.2 kept these four operations on their original flat/top-level
# payload shape (to dodge setup_config.py's settings-must-stay-top-level
# trap) rather than moving them onto SSHService.runWorkflowStream's
# connection/params nesting like every other operation. Their params_schema
# entries describe that top-level payload, not payload["params"] -- see
# workflow_registry.py's own note on the same seam.
LEGACY_FLAT_PARAMS_SCHEMA_OPERATIONS = frozenset(
    {
        ("setup", "describe"),
        ("setup", "run"),
        ("server", "check"),
        ("server", "refresh_host_key"),
    }
)

# The highest envelope protocol version this build understands (T-1.5.1).
# There is no version 0: this is the first version ever shipped, so an
# absent field is accepted as this version rather than rejected -- every
# client and every recorded envelope predates the field existing at all.
# TODO(next release): once every shipped client sends `protocol`, make an
# absent field a validation error instead of silently defaulting it.
KNOWN_PROTOCOL_VERSION = 1


class EngineRuntime:
    def __init__(
        self,
        *,
        workflow_registry_getter: Callable[[], dict[str, dict[str, dict[str, Any]]]],
        workflow_handlers_getter: Callable[[], dict[tuple[str, str], Any]],
        error_result: Callable[..., dict[str, Any]],
        emit_event: Callable[..., None],
        unimplemented_handler: Callable[[str, str], dict[str, Any]],
    ):
        self._workflow_registry_getter = workflow_registry_getter
        self._workflow_handlers_getter = workflow_handlers_getter
        self._error_result = error_result
        self._emit_event = emit_event
        self._unimplemented_handler = unimplemented_handler

    def handle_request_json(
        self,
        json_str: str,
        emit: EmitFn | None = None,
        is_cancelled: Callable[[], bool] | None = None,
    ) -> str:
        try:
            payload = json.loads(json_str)
        except json.JSONDecodeError:
            return json.dumps(
                self._error_result(
                    "ENGINE_INVALID_JSON",
                    "Invalid JSON payload",
                    stage="parse_request",
                ),
            )

        if not isinstance(payload, dict):
            return json.dumps(
                self._error_result(
                    "ENGINE_INVALID_JSON",
                    "JSON payload must be an object.",
                    stage="parse_request",
                ),
            )

        protocol_error = self._validate_protocol(payload)
        if protocol_error is not None:
            return json.dumps(protocol_error)

        target, resolution_error = resolve_request_target(
            payload,
            error_result=self._error_result,
        )
        if resolution_error is not None:
            return json.dumps(resolution_error)
        if target is None:
            action = payload.get("action")
            return json.dumps(
                self._error_result(
                    "ENGINE_UNKNOWN_ACTION",
                    f"Unknown action: {action}",
                    stage="dispatch",
                ),
            )

        workflow_registry = self._workflow_registry_getter()
        workflow = workflow_registry.get(target.workflow_id)
        if not isinstance(workflow, dict) or target.operation_id not in workflow:
            return json.dumps(
                self._error_result(
                    "ENGINE_VALIDATION_ERROR",
                    f"Unknown workflow operation: {target.workflow_id}/{target.operation_id}",
                    stage="validate_request",
                ),
            )

        schema_error = self._validate_params_schema(payload, target, workflow)
        if schema_error is not None:
            return json.dumps(schema_error)

        handlers = self._workflow_handlers_getter()
        handler = handlers.get((target.workflow_id, target.operation_id))

        try:
            if handler is None:
                response = self._unimplemented_handler(
                    target.workflow_id,
                    target.operation_id,
                )
            else:
                response = handler(payload, emit=emit, is_cancelled=is_cancelled)
        except Exception as exc:
            details = traceback.format_exc()
            self._emit_event(
                emit,
                "engine_unhandled_exception",
                str(exc),
                level="error",
                data={
                    "workflow_id": target.workflow_id,
                    "operation_id": target.operation_id,
                },
            )
            response = self._error_result(
                "ENGINE_RUNTIME_ERROR",
                str(exc),
                stage="dispatch",
                details=details,
                extra={
                    "workflow_id": target.workflow_id,
                    "operation_id": target.operation_id,
                },
            )

        return json.dumps(response)

    def _validate_params_schema(
        self,
        payload: dict[str, Any],
        target: RequestTarget,
        workflow: dict[str, dict[str, Any]],
    ) -> dict[str, Any] | None:
        """`None` if the request satisfies the operation's params_schema.

        Validates payload["params"] for every operation except the T-1.5.2
        legacy-flat four (see LEGACY_FLAT_PARAMS_SCHEMA_OPERATIONS), whose
        params_schema describes the whole top-level payload instead. Runs
        before the handler, so a malformed request never reaches SSH.
        """
        operation = workflow[target.operation_id]
        params_schema = operation.get("params_schema")
        if not isinstance(params_schema, dict):
            return None

        instance: dict[str, Any]
        if (target.workflow_id, target.operation_id) in (LEGACY_FLAT_PARAMS_SCHEMA_OPERATIONS):
            instance = payload
            path = "payload"
        else:
            raw_instance = payload.get("params")
            instance = raw_instance if isinstance(raw_instance, dict) else {}
            path = "params"

        errors = validate_against_schema(instance, params_schema, path=path)
        if not errors:
            return None

        return self._error_result(
            "ENGINE_VALIDATION_ERROR",
            errors[0],
            stage="validate_request",
            extra={"schema_errors": errors},
        )

    def _validate_protocol(self, payload: dict[str, Any]) -> dict[str, Any] | None:
        """`None` if the envelope's `protocol` field is acceptable.

        Three branches, matching T-1.5.1 exactly: absent is accepted as
        `KNOWN_PROTOCOL_VERSION` (see that constant's own comment); a
        present value that isn't an integer is a validation error; a
        present integer greater than `KNOWN_PROTOCOL_VERSION` means this
        build is older than the caller expects, and refusing outright is
        safer than guessing at an unknown envelope shape.
        """
        if "protocol" not in payload:
            return None

        protocol = payload["protocol"]
        if not isinstance(protocol, int) or isinstance(protocol, bool):
            return self._error_result(
                "ENGINE_VALIDATION_ERROR",
                "protocol must be an integer.",
                stage="parse_request",
            )

        if protocol > KNOWN_PROTOCOL_VERSION:
            return self._error_result(
                "ENGINE_PROTOCOL_TOO_NEW",
                "This build understands request envelope protocol "
                f"{KNOWN_PROTOCOL_VERSION}, but the request declared "
                f"protocol {protocol}. Update Deploy Dash and retry.",
                stage="parse_request",
            )

        return None
