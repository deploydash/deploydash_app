import functools
import secrets
from dataclasses import dataclass

from .. import config_validation

SSH_BANNER_TEXT = """\

██╗    ██╗ █████╗ ██████╗ ███╗   ██╗██╗███╗   ██╗ ██████╗
██║    ██║██╔══██╗██╔══██╗████╗  ██║██║████╗  ██║██╔════╝
██║ █╗ ██║███████║██████╔╝██╔██╗ ██║██║██╔██╗ ██║██║  ███╗
██║███╗██║██╔══██║██╔══██╗██║╚██╗██║██║██║╚██╗██║██║   ██║
╚███╔███╔╝██║  ██║██║  ██║██║ ╚████║██║██║ ╚████║╚██████╔╝
 ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═══╝ ╚═════╝

Unauthorized access to this system is forbidden and will be
prosecuted by law. By accessing this system, you agree that
your actions will be monitored.
"""


CANONICAL_SETUP_SETTINGS = {
    "admin_user": "ubuntu",
    "hostname": None,
    "timezone": "UTC",
    "ssh_public_key": None,
    "disable_password_auth": True,
    "disable_root_login": True,
    "ssh_banner_text": SSH_BANNER_TEXT,
}

REQUIRED_SETUP_SETTING_KEYS = tuple(CANONICAL_SETUP_SETTINGS.keys())


class SetupConfigValidationError(ValueError):
    pass


# Bound once per module rather than passed at all 5 call sites below.
#
# These are not copies -- T-3.8.1 deleted those. Each is `config_validation`'s
# single implementation with this module's error class already supplied, which
# is the same "parameterise the original, bind the exception class" shape
# `settings_ownership.reject_server_owned_keys(raw, error_class)` established.
_required_string = functools.partial(
    config_validation.required_string,
    error_class=SetupConfigValidationError,
)
_required_bool = functools.partial(
    config_validation.required_bool,
    error_class=SetupConfigValidationError,
)


@dataclass(frozen=True)
class SetupConfig:
    admin_user: str
    bootstrap_username: str | None
    hostname: str | None
    timezone: str
    ssh_public_key: str | None
    disable_password_auth: bool
    disable_root_login: bool
    ssh_banner_text: str
    managed_user_password: str | None


def parse_setup_config(raw_data):
    # merge=False: setup's contract is that a caller sends a complete
    # settings object, so merging the canonical defaults underneath would
    # fill every key in and the missing-key check below could never fire.
    settings = config_validation.select_settings(
        raw_data,
        canonical=CANONICAL_SETUP_SETTINGS,
        error_class=SetupConfigValidationError,
        merge=False,
    )
    # admin_user is the one server-owned key in this dict (T-1.4.8); every
    # other key stays required exactly as before.
    settings.setdefault("admin_user", CANONICAL_SETUP_SETTINGS["admin_user"])
    config_validation.validate_setting_keys(
        settings,
        allowed=REQUIRED_SETUP_SETTING_KEYS,
        required=REQUIRED_SETUP_SETTING_KEYS,
        error_class=SetupConfigValidationError,
    )

    admin_user = _required_string(
        settings["admin_user"],
        "settings.admin_user",
    )
    hostname = _optional_string(
        settings["hostname"],
        "settings.hostname",
    )
    timezone = _required_string(
        settings["timezone"],
        "settings.timezone",
    )
    ssh_public_key = _optional_string(
        settings["ssh_public_key"],
        "settings.ssh_public_key",
    )
    disable_password_auth = _required_bool(
        settings["disable_password_auth"],
        "settings.disable_password_auth",
    )
    disable_root_login = _required_bool(
        settings["disable_root_login"],
        "settings.disable_root_login",
    )
    ssh_banner_text = _required_string(
        settings["ssh_banner_text"],
        "settings.ssh_banner_text",
        strip=False,
    )
    bootstrap_username = _extract_bootstrap_username(raw_data)

    if _requires_hardening_key(raw_data) and not disable_root_login:
        # Owner decision, 2026-09-04 (G-3). Onboarding's whole sequence exists
        # to hand ownership to a verified managed key and then close the door
        # behind it. A setup that leaves root SSH enabled has done the
        # destructive half -- taking over the account -- without the half that
        # justifies it, and nothing downstream told the user. Password
        # authentication stays the caller's choice; root login does not.
        raise SetupConfigValidationError(
            "settings.disable_root_login must be true. Onboarding disables root "
            "SSH login after verifying the managed key, and a server that keeps "
            "it is not one Deploy Dash can claim to have secured.",
        )

    if _requires_hardening_key(raw_data) and not ssh_public_key:
        # This once also tested `disable_password_auth or disable_root_login`.
        # G-3 above now rejects a request that leaves root login enabled, so
        # by this line that clause is true on every path that reaches it, and
        # a condition that cannot be false describes a case that cannot
        # happen. Onboarding always hardens; it therefore always needs a key.
        raise SetupConfigValidationError(
            "SSH hardening requested but settings.ssh_public_key is missing.",
        )

    managed_user_password = None
    if bootstrap_username and bootstrap_username != admin_user:
        managed_user_password = secrets.token_urlsafe(32)

    return SetupConfig(
        admin_user=admin_user,
        bootstrap_username=bootstrap_username,
        hostname=hostname,
        timezone=timezone,
        ssh_public_key=ssh_public_key,
        disable_password_auth=disable_password_auth,
        disable_root_login=disable_root_login,
        ssh_banner_text=ssh_banner_text,
        managed_user_password=managed_user_password,
    )


def _extract_bootstrap_username(raw_data):
    if not isinstance(raw_data, dict):
        return None

    connection = raw_data.get("connection")
    if isinstance(connection, dict):
        username = connection.get("username") or connection.get("ssh_user")
        return _optional_string(username, "connection.username")

    username = raw_data.get("username")
    return _optional_string(username, "username")


def _requires_hardening_key(raw_data):
    if not isinstance(raw_data, dict):
        return False
    if raw_data.get("connection") or raw_data.get("username"):
        return True
    params = raw_data.get("params")
    return isinstance(params, dict) and bool(params.get("managed_connection"))


def _optional_string(value, field_name):
    if value is None:
        return None
    if not isinstance(value, str):
        raise SetupConfigValidationError(f"{field_name} must be a string or null.")
    trimmed = value.strip()
    return trimmed if trimmed else None
