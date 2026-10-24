from . import server_paths

RAILPACK_VERSION = "v0.29.0"
RAILPACK_VERSION_NUMBER = RAILPACK_VERSION.removeprefix("v")
RAILPACK_BUILDER_NAME = "deploydash-railpack-builder"
RAILPACK_STACK_ROOT = server_paths.railpack_root()
RAILPACK_FRONTEND_IMAGE = f"ghcr.io/railwayapp/railpack-frontend:{RAILPACK_VERSION}"
RAILPACK_FRONTEND_IMAGE_DIGEST = (
    "sha256:683f0eba680f38d009290100ae3ceded667a1536687ce25696fe9f4e91abfd2b"
)
RAILPACK_LINUX_AMD64_ASSET = f"railpack-{RAILPACK_VERSION}-x86_64-unknown-linux-musl.tar.gz"
RAILPACK_LINUX_AMD64_SHA256 = "25cad96e4d2e9c9a3d47bf7abc46b0abb8e46360e8f13e0c24d5ea279933d247"


def render_detect_railpack_version_command(variable_name="DEPLOYDASH_RAILPACK_VERSION"):
    return (
        f'{variable_name}=""; '
        "if command -v railpack >/dev/null 2>&1; then "
        f'{variable_name}="$(railpack --version 2>/dev/null | '
        "sed -n 's/.*\\([0-9][0-9]*\\.[0-9][0-9]*\\.[0-9][0-9]*\\).*/\\1/p' "
        '2>/dev/null | head -n1 || true)"; '
        "fi"
    )


def render_install_pinned_railpack_command():
    version_variable = "DEPLOYDASH_RAILPACK_VERSION"
    return (
        f"{render_detect_railpack_version_command(version_variable)}; "
        f'if [ "${{{version_variable}}}" != "{RAILPACK_VERSION_NUMBER}" ]; then '
        'TMP_DIR="$(mktemp -d)" && '
        'cleanup(){ rm -rf "${TMP_DIR}" >/dev/null 2>&1 || true; } && '
        "trap cleanup EXIT INT TERM && "
        f"ASSET={RAILPACK_LINUX_AMD64_ASSET!r} && "
        f"EXPECTED_SHA256={RAILPACK_LINUX_AMD64_SHA256!r} && "
        f"URL=https://github.com/railwayapp/railpack/releases/download/{RAILPACK_VERSION}/${{ASSET}} && "
        'curl -fsSL "${URL}" -o "${TMP_DIR}/railpack.tar.gz" && '
        "printf '%s  %s\\n' "
        '"${EXPECTED_SHA256}" "${TMP_DIR}/railpack.tar.gz" | sha256sum -c - && '
        'tar -xzf "${TMP_DIR}/railpack.tar.gz" -C "${TMP_DIR}" railpack && '
        'install -m 0755 "${TMP_DIR}/railpack" /usr/local/bin/railpack; '
        "fi"
    )


def render_railpack_version_guard_command():
    version_variable = "DEPLOYDASH_RAILPACK_VERSION"
    return (
        f"{render_detect_railpack_version_command(version_variable)}; "
        f'[ "${{{version_variable}}}" = "{RAILPACK_VERSION_NUMBER}" ] || '
        '(if [ -z "${DEPLOYDASH_RAILPACK_VERSION}" ]; then '
        "echo 'Railpack is not installed. Open Server Management and run setup again "
        "to install Deploy Dash build tooling, then redeploy.' >&2; "
        "else "
        'echo "Deploy Dash requires Railpack '
        f"{RAILPACK_VERSION_NUMBER} on this server, but found "
        "${DEPLOYDASH_RAILPACK_VERSION}. Open Server Management and run setup again "
        'to update build tooling, then redeploy." >&2; '
        "fi; exit 1)"
    )
