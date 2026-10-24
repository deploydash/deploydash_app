import argparse
import json
from pathlib import Path

from . import engine as _engine_bootstrap  # noqa: F401
from . import settings_ownership
from .api import handle_request
from .setup_parts import ALL_PARTS, CANONICAL_SETUP_SETTINGS


def _parse_args():
    parser = argparse.ArgumentParser(
        description="Run Deploy Dash engine actions directly via Python.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        help="Optional local JSON config file containing reusable VM targets.",
    )
    parser.add_argument(
        "--target",
        help="Target key from --config (falls back to default_target when set).",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    echo_parser = subparsers.add_parser("echo", help="Run engine echo action.")
    echo_parser.add_argument("--data", default="hello")
    echo_parser.add_argument("--pretty", action="store_true")

    check_parser = subparsers.add_parser(
        "check-server",
        help="Run the server connection check against a target host.",
    )
    check_parser.add_argument("--host")
    check_parser.add_argument("--ip", dest="host")
    check_parser.add_argument("--port", type=int)
    check_parser.add_argument("--username")
    check_parser.add_argument("--password")
    check_parser.add_argument("--key-path")
    check_parser.add_argument("--pretty", action="store_true")

    setup_parser = subparsers.add_parser(
        "setup-server",
        help="Run server setup against a target host.",
    )
    setup_parser.add_argument("--host")
    setup_parser.add_argument("--ip", dest="host")
    setup_parser.add_argument("--port", type=int)
    setup_parser.add_argument("--username")
    setup_parser.add_argument("--password")
    setup_parser.add_argument("--key-path")
    setup_parser.add_argument(
        "--parts",
        help=f"Comma-separated setup parts to run ({', '.join(ALL_PARTS)}).",
    )
    setup_parser.add_argument("--hostname")
    setup_parser.add_argument("--timezone")
    setup_parser.add_argument("--ssh-public-key")
    setup_parser.add_argument("--ssh-public-key-file", type=Path)
    setup_parser.add_argument("--disable-password-auth", action="store_true")
    setup_parser.add_argument("--disable-root-login", action="store_true")
    setup_parser.add_argument("--ssh-banner-text")
    setup_parser.add_argument(
        "--settings-json",
        help="Optional JSON object merged into payload.settings.",
    )
    setup_parser.add_argument(
        "--settings-file",
        type=Path,
        help="Optional JSON file merged into payload.settings.",
    )
    setup_parser.add_argument(
        "--execute",
        action="store_true",
        help="Apply setup changes on the VM (default is dry-run).",
    )
    setup_parser.add_argument("--pretty", action="store_true")

    payload_parser = subparsers.add_parser(
        "run-payload",
        help="Run raw payload JSON through engine.handle_request.",
    )
    payload_group = payload_parser.add_mutually_exclusive_group(required=True)
    payload_group.add_argument("--payload")
    payload_group.add_argument("--payload-file", type=Path)
    payload_parser.add_argument("--pretty", action="store_true")

    return parser.parse_args()


def _load_config(config_path):
    if config_path is None:
        return {}
    if not config_path.exists():
        raise ValueError(f"Config file not found: {config_path}")
    try:
        return json.loads(config_path.read_text())
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid JSON in config file: {config_path}") from exc


def _resolve_target(config, target_name):
    targets = config.get("targets")
    if not isinstance(targets, dict):
        return {}

    key = target_name or config.get("default_target")
    if key is None:
        return {}
    if key not in targets:
        raise ValueError(f"Target '{key}' not found in config.")

    target_value = targets[key]
    if not isinstance(target_value, dict):
        raise ValueError(f"Target '{key}' must be a JSON object.")
    return target_value


def _validate_required(payload, command_name):
    missing = [field_name for field_name in ("host", "username") if not payload.get(field_name)]
    if missing:
        missing_fields = ", ".join(missing)
        raise ValueError(
            f"Missing required fields for {command_name}: {missing_fields}",
        )


def _build_check_server_payload(args, target):
    payload = {
        "action": "run_workflow",
        "workflow_id": "server",
        "operation_id": "check",
        "host": args.host or target.get("host") or target.get("ip"),
        "port": args.port if args.port is not None else target.get("port", 22),
        "username": args.username or target.get("username"),
        "password": (args.password if args.password is not None else target.get("password")),
        "key_path": (args.key_path if args.key_path is not None else target.get("key_path")),
    }
    _validate_required(payload, "check-server")
    return payload


def _parse_parts(parts_text):
    if not parts_text:
        return None

    requested = [value.strip() for value in parts_text.split(",") if value.strip()]
    allowed = set(ALL_PARTS)
    invalid = sorted({value for value in requested if value not in allowed})
    if invalid:
        allowed_text = ", ".join(sorted(allowed))
        invalid_text = ", ".join(invalid)
        raise ValueError(f"Invalid parts: {invalid_text}. Allowed: {allowed_text}")
    return requested


def _parse_json_object(raw_json, label):
    try:
        value = json.loads(raw_json)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid JSON for {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object.")
    return value


def _load_json_object(path, label):
    if not path.exists():
        raise ValueError(f"{label} file not found: {path}")
    return _parse_json_object(path.read_text(), label)


def _build_setup_settings(args, target):
    target_settings = target.get("settings")
    settings = settings_ownership.wire_defaults(CANONICAL_SETUP_SETTINGS)
    if isinstance(target_settings, dict):
        settings.update(target_settings)

    if args.settings_file is not None:
        settings.update(_load_json_object(args.settings_file, "settings-file"))
    if args.settings_json is not None:
        settings.update(_parse_json_object(args.settings_json, "settings-json"))

    ssh_public_key = args.ssh_public_key
    if ssh_public_key is None and args.ssh_public_key_file is not None:
        if not args.ssh_public_key_file.exists():
            raise ValueError(
                f"ssh-public-key-file not found: {args.ssh_public_key_file}",
            )
        ssh_public_key = args.ssh_public_key_file.read_text().strip()

    if args.hostname is not None:
        settings["hostname"] = args.hostname
    if args.timezone is not None:
        settings["timezone"] = args.timezone
    if ssh_public_key is not None:
        settings["ssh_public_key"] = ssh_public_key
    if args.disable_password_auth:
        settings["disable_password_auth"] = True
    if args.disable_root_login:
        settings["disable_root_login"] = True
    if args.ssh_banner_text is not None:
        settings["ssh_banner_text"] = args.ssh_banner_text

    return settings


def _build_setup_server_payload(args, target):
    parts = _parse_parts(args.parts)
    if parts is None:
        target_parts = target.get("parts")
        if isinstance(target_parts, list) and target_parts:
            parts = target_parts

    settings = _build_setup_settings(args, target)
    payload = {
        "action": "run_workflow",
        "workflow_id": "setup",
        "operation_id": "run",
        "host": args.host or target.get("host") or target.get("ip"),
        "port": args.port if args.port is not None else target.get("port", 22),
        "username": args.username or target.get("username"),
        "password": (args.password if args.password is not None else target.get("password")),
        "key_path": (args.key_path if args.key_path is not None else target.get("key_path")),
        "dry_run": not args.execute,
    }
    if parts is not None:
        payload["parts"] = parts
    if settings:
        payload["settings"] = settings
    _validate_required(payload, "setup-server")
    return payload


def _build_payload(args, target):
    if args.command == "echo":
        return {
            "action": "run_workflow",
            "workflow_id": "core",
            "operation_id": "echo",
            "data": args.data,
        }

    if args.command == "check-server":
        return _build_check_server_payload(args, target)

    if args.command == "setup-server":
        return _build_setup_server_payload(args, target)

    if args.command == "run-payload":
        if args.payload is not None:
            return json.loads(args.payload)
        return json.loads(args.payload_file.read_text())

    raise ValueError(f"Unknown command: {args.command}")


def _print_json(data, pretty=False):
    if pretty:
        print(json.dumps(data, indent=2))
        return
    print(json.dumps(data))


def main():
    try:
        args = _parse_args()
        config = _load_config(args.config)
        target = _resolve_target(config, args.target)
        payload = _build_payload(args, target)

        result_json = handle_request(json.dumps(payload))
        result = json.loads(result_json)
        _print_json(result, pretty=args.pretty)

        return 0 if result.get("status") == "success" else 1
    except json.JSONDecodeError as exc:
        _print_json({"status": "error", "msg": f"Invalid JSON: {exc}"}, pretty=True)
        return 2
    except ValueError as exc:
        _print_json({"status": "error", "msg": str(exc)}, pretty=True)
        return 2
    except Exception as exc:
        _print_json({"status": "error", "msg": str(exc)}, pretty=True)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
