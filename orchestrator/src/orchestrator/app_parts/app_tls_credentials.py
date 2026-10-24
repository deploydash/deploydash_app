"""The per-provider required-key matrix for DNS-01 TLS credentials.

Split out of `app_config.py` by T-3.3.4, which names it specifically: T-1.5.3
recorded this five-way conditional as a known simplification in the app
schema, because `params_schema` cannot express "these keys are required, but
only for this provider". The validation therefore lives in code, and it is
worth being able to find.

Each provider is a row: what it must have, what it may have, and -- for
ClouDNS, which accepts either of two identifiers -- what it must have one of.
"""

from .app_settings_schema import AppConfigValidationError


def _validate_dns_credentials(provider: str, credentials: dict[str, str]) -> None:
    required_by_provider = {
        "cloudflare": ("api_token",),
        "porkbun": ("api_key", "api_secret_key"),
        "namecheap": ("api_user", "api_key"),
        "cloudns": ("auth_password",),
        "easydns": ("api_token", "api_key"),
    }
    allowed_by_provider = {
        "cloudflare": {"api_token"},
        "porkbun": {"api_key", "api_secret_key"},
        "namecheap": {"api_user", "api_key", "client_ip", "api_endpoint"},
        "cloudns": {"auth_id", "sub_auth_id", "auth_password"},
        "easydns": {"api_token", "api_key", "api_url"},
    }

    required_fields = required_by_provider.get(provider, ())
    missing = [field for field in required_fields if field not in credentials]
    if missing:
        raise AppConfigValidationError(
            "settings.tls_dns_credentials is missing required keys for "
            f"{provider}: {', '.join(missing)}",
        )

    if provider == "cloudns":
        has_auth_id = "auth_id" in credentials
        has_sub_auth_id = "sub_auth_id" in credentials
        if not has_auth_id and not has_sub_auth_id:
            raise AppConfigValidationError(
                "settings.tls_dns_credentials for cloudns must include either "
                "auth_id or sub_auth_id.",
            )

    allowed = allowed_by_provider.get(provider, set())
    extra = sorted(key for key in credentials if key not in allowed)
    if extra:
        raise AppConfigValidationError(
            f"settings.tls_dns_credentials has unsupported keys for {provider}: {', '.join(extra)}",
        )
