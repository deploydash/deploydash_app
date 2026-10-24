"""Own the bounded dpkg-lock policy for Ubuntu host package operations."""

APT_LOCK_TIMEOUT_SECONDS = 300
APT_LOCK_TIMEOUT_CONFIG = f'DPkg::Lock::Timeout "{APT_LOCK_TIMEOUT_SECONDS}";\n'
_APT_LOCK_WAIT_MESSAGE = (
    f"Waiting for Ubuntu's package manager (up to {APT_LOCK_TIMEOUT_SECONDS} seconds)."
)


def apt_lock_notice_command() -> str:
    """Explain an observed package-manager wait before apt begins blocking."""
    return (
        "if command -v fuser >/dev/null 2>&1 "
        "&& fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then "
        f'printf "%s\\n" "{_APT_LOCK_WAIT_MESSAGE}"; '
        "fi"
    )


def apt_get_command(arguments: str) -> str:
    """Apply the one bounded lock policy to a trusted internal apt-get action."""
    return (
        f"{apt_lock_notice_command()}; "
        "DEBIAN_FRONTEND=noninteractive "
        f"apt-get -o DPkg::Lock::Timeout={APT_LOCK_TIMEOUT_SECONDS} {arguments}"
    )
