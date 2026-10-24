from collections.abc import Callable
from typing import Any


def payload_params(data: dict[str, Any]) -> dict[str, Any]:
    params = data.get("params")
    return params if isinstance(params, dict) else {}


def extract_settings_payload(data: dict[str, Any]) -> dict[str, Any]:
    params = payload_params(data)
    if "settings" in params:
        return {"settings": params.get("settings")}
    if "settings" in data:
        return {"settings": data.get("settings")}
    return {}


def resolve_parts(data: dict[str, Any]) -> Any:
    params = payload_params(data)
    if "parts" in params:
        return params.get("parts")
    return data.get("parts")


def resolve_dry_run(
    data: dict[str, Any],
    *,
    default_value: bool,
    normalized_bool: Callable[[Any, bool], bool],
) -> bool:
    params = payload_params(data)
    if "dry_run" in params:
        return normalized_bool(params.get("dry_run"), default_value)
    return normalized_bool(data.get("dry_run"), default_value)


def connection_validation_error(
    connection_data: Any,
    *,
    error_result: Callable[..., dict[str, Any]],
) -> dict[str, Any] | None:
    if not isinstance(connection_data, dict):
        return error_result(
            "ENGINE_VALIDATION_ERROR",
            "Connection payload must be an object.",
            stage="validate_request",
        )

    host = connection_data.get("host") or connection_data.get("ip")
    user = connection_data.get("username")
    port = connection_data.get("port")

    if not host or not user:
        return error_result(
            "ENGINE_VALIDATION_ERROR",
            "Missing required fields: host and username are required",
            stage="validate_request",
        )
    if port is None:
        return error_result(
            "ENGINE_VALIDATION_ERROR",
            "Invalid SSH port. Must be an integer between 1 and 65535",
            stage="validate_request",
        )
    return None


def build_unimplemented_workflow_handler(
    *,
    workflow_registry: dict[str, dict[str, dict[str, Any]]],
    error_result: Callable[..., dict[str, Any]],
) -> Callable[[str, str], dict[str, Any]]:
    def _handle_unimplemented_workflow(
        workflow_id: str,
        operation_id: str,
    ) -> dict[str, Any]:
        operation_meta = workflow_registry[workflow_id][operation_id]
        if operation_id == "describe":
            return {
                "status": "success",
                "code": "OK",
                "workflow_id": workflow_id,
                "operation_id": operation_id,
                "msg": (f"{operation_meta['label']} is defined but not implemented yet."),
                "steps": [],
            }
        return error_result(
            "ENGINE_NOT_IMPLEMENTED",
            f"{operation_meta['label']} is not implemented yet.",
            stage="dispatch",
            extra={
                "workflow_id": workflow_id,
                "operation_id": operation_id,
            },
        )

    return _handle_unimplemented_workflow
