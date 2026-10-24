"""Real-shaped pyinfra facts shared by orchestrator tests."""


def ubuntu_linux_distribution(
    version_id: str,
    *,
    pretty_name: str | None = None,
) -> dict[str, object]:
    """Mirror LinuxDistribution so fixtures cannot conceal fact-schema drift."""

    major, _, minor = version_id.partition(".")
    return {
        "name": "Ubuntu",
        "major": major,
        "minor": minor,
        "release_meta": {
            "PRETTY_NAME": pretty_name or f"Ubuntu {version_id}",
            "VERSION_ID": version_id,
        },
    }
