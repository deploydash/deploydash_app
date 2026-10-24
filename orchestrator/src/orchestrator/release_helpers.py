from __future__ import annotations

import hashlib
import json
import re
import struct
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZIP_DEFLATED, BadZipFile, ZipFile


class ReleaseContractError(RuntimeError):
    """Raised when a release-time file or metadata contract is violated."""


WINDOWS_STORE_PACKAGE_NAME = "TidyTechnology.DeployDash"
WINDOWS_STORE_PUBLISHER = "CN=4DF691A0-E545-4698-A115-C49614B329C6"
WINDOWS_STORE_PUBLISHER_DISPLAY_NAME = "Tidy Technology"
WINDOWS_STORE_PACKAGE_FAMILY_NAME = "TidyTechnology.DeployDash_rf5wcg4kb0x8a"
WINDOWS_STORE_PRODUCT_ID = "9P1GK6Z58B9T"
#: Filename and manifest tokens for Windows Store architectures. There is
#: no x86-style aliasing here: the Windows world (Flutter output dirs,
#: manifest values, update protocol) already speaks x64/arm64, so anything
#: else is rejected rather than normalized.
WINDOWS_STORE_ARCHITECTURES = frozenset({"x64", "arm64"})
WINDOWS_STORE_MINIMUM_VERSION = "10.0.17763.0"
WINDOWS_STORE_CAPABILITIES = {
    "internetClient",
    "privateNetworkClientServer",
    "runFullTrust",
}
WINDOWS_STORE_ASSET_DIMENSIONS = {
    "Assets/StoreLogo.png": (50, 50),
    "Assets/Square44x44Logo.png": (44, 44),
    "Assets/Square150x150Logo.png": (150, 150),
    "Assets/Wide310x150Logo.png": (310, 150),
}
WINDOWS_STORE_REQUIRED_PAYLOAD_PATHS = {
    "AppxManifest.xml",
    "deploydash.exe",
    "bridge.dll",
    "python.exe",
    "pythonw.exe",
    "python313.dll",
    "DLLs/_socket.pyd",
    "sqlite3mc.dll",
}
WINDOWS_STORE_REQUIRED_SYMBOL_NAMES = frozenset({"bridge.pdb", "deploydash.pdb"})
#: MakeAppx injects these into the .msix; they are absent from the source
#: package root the build manifest digests. Slim QA Expand-Archive trees
#: must ignore them so the payload digest still matches.
WINDOWS_STORE_MAKEAPPX_FOOTPRINT_NAMES = frozenset(
    {
        "AppxBlockMap.xml",
        "[Content_Types].xml",
        "AppxSignature.p7x",
    }
)
WINDOWS_STORE_MAKEAPPX_FOOTPRINT_PREFIXES = ("AppxMetadata/",)

_WINDOWS_STORE_PROHIBITED_SUFFIXES = {
    ".env",
    ".exp",
    ".key",
    ".lib",
    ".p12",
    ".pdb",
    ".pfx",
}
_WINDOWS_STORE_PROHIBITED_NAMES = {
    "authorized_keys",
    "dart-defines.local.json",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
    "id_rsa",
}
_PRIVATE_KEY_BLOCK_PATTERN = re.compile(
    rb"-----BEGIN (?P<label>(?:ENCRYPTED |OPENSSH |RSA |EC )?PRIVATE KEY)-----"
    rb"[ \t\r\n]+"
    rb"(?P<body>[A-Za-z0-9+/=\r\n]{32,})"
    rb"[ \t\r\n]+-----END (?P=label)-----"
)


def flutter_pubspec_build_metadata(app_dir: Path) -> tuple[str, str]:
    pubspec_path = app_dir / "pubspec.yaml"
    try:
        pubspec = pubspec_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ReleaseContractError(f"Unable to read Flutter pubspec: {pubspec_path}") from exc

    matches = re.findall(
        r"^version:[ \t]*(\d+\.\d+\.\d+)\+(\d+)[ \t]*(?:#.*)?$",
        pubspec,
        flags=re.MULTILINE,
    )
    if len(matches) != 1 or int(matches[0][1]) < 1:
        raise ReleaseContractError(
            "Flutter pubspec must contain one App Store-compatible version "
            "in the form version: X.Y.Z+N."
        )
    return matches[0]


def debian_package_version(
    *,
    app_dir: Path,
    build_name: str | None,
    build_number: str | None,
) -> str:
    """Return the Debian version paired with the Flutter release metadata.

    Flutter accepts a semantic build name and positive integer build number.
    Debian accepts ``+`` as a version separator and compares the trailing
    number naturally, so this keeps the package manager and in-app version
    aligned for release upgrades.
    """

    pubspec_name, pubspec_number = flutter_pubspec_build_metadata(app_dir)
    resolved_name = (build_name or "").strip() or pubspec_name
    resolved_number = (build_number or "").strip() or pubspec_number
    if not re.fullmatch(r"\d+\.\d+\.\d+", resolved_name):
        raise ReleaseContractError("Debian build name must use semantic version X.Y.Z.")
    if not re.fullmatch(r"[1-9]\d*", resolved_number):
        raise ReleaseContractError("Debian build number must be a positive integer.")
    return f"{resolved_name}+{resolved_number}"


def snap_package_version(
    *,
    app_dir: Path,
    build_name: str | None,
    build_number: str | None,
) -> str:
    """Return the Snap version paired with the Flutter release metadata."""

    pubspec_name, pubspec_number = flutter_pubspec_build_metadata(app_dir)
    resolved_name = (build_name or "").strip() or pubspec_name
    resolved_number = (build_number or "").strip() or pubspec_number
    if not re.fullmatch(r"\d+\.\d+\.\d+", resolved_name):
        raise ReleaseContractError("Snap build name must use semantic version X.Y.Z.")
    if not re.fullmatch(r"[1-9]\d*", resolved_number):
        raise ReleaseContractError("Snap build number must be a positive integer.")
    version = f"{resolved_name}+{resolved_number}"
    if len(version) > 32:
        raise ReleaseContractError("Snap package version must not exceed 32 characters.")
    return version


def windows_store_package_version(
    *,
    app_dir: Path,
    build_name: str | None,
) -> str:
    """Return the Store version, whose reserved revision must remain zero."""

    pubspec_name, _ = flutter_pubspec_build_metadata(app_dir)
    resolved_name = (build_name or "").strip() or pubspec_name
    if not re.fullmatch(r"\d+\.\d+\.\d+", resolved_name):
        raise ReleaseContractError("Windows Store build name must use semantic version X.Y.Z.")
    components = [int(value) for value in resolved_name.split(".")]
    if any(value > 65535 for value in components):
        raise ReleaseContractError("Windows Store version components must be between 0 and 65535.")
    return ".".join([*(str(value) for value in components), "0"])


def parse_windows_store_version(value: str, *, label: str) -> tuple[int, ...]:
    if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", value):
        raise ReleaseContractError(f"{label} must use version X.Y.Z.0.")
    components = tuple(int(component) for component in value.split("."))
    if any(component > 65535 for component in components):
        raise ReleaseContractError(f"{label} components must be between 0 and 65535.")
    if components[-1] != 0:
        raise ReleaseContractError(f"{label} revision must be zero.")
    return components


def validate_windows_store_version(
    *,
    package_version: str,
    last_published_version: str,
) -> None:
    package = parse_windows_store_version(
        package_version,
        label="Windows Store package version",
    )
    published = parse_windows_store_version(
        last_published_version,
        label="Last published Windows Store version",
    )
    if package <= published:
        raise ReleaseContractError(
            "Windows Store package version must be newer than the last "
            f"published version ({last_published_version})."
        )


def read_last_published_windows_store_version(path: Path) -> str:
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ReleaseContractError(
            f"Unable to read last published Windows Store version: {path}"
        ) from exc
    parse_windows_store_version(
        value,
        label="Last published Windows Store version",
    )
    return value


def _require_windows_store_arch(arch: str) -> str:
    token = (arch or "").strip()
    if token not in WINDOWS_STORE_ARCHITECTURES:
        raise ReleaseContractError("Windows Store architecture must be x64 or arm64.")
    return token


def windows_store_artifact_names(package_version: str, *, arch: str) -> dict[str, str]:
    parse_windows_store_version(
        package_version,
        label="Windows Store package version",
    )
    token = _require_windows_store_arch(arch)
    stem = f"DeployDash_{package_version}_{token}"
    return {
        "msix": f"{stem}.msix",
        "appxsym": f"{stem}.appxsym",
        "msixupload": f"{stem}.msixupload",
        "build_manifest": f"{stem}.build-manifest.json",
    }


def windows_store_identity(*, arch: str) -> dict[str, str]:
    """Return the immutable Partner Center identity used by release tooling."""

    return {
        "package_name": WINDOWS_STORE_PACKAGE_NAME,
        "publisher": WINDOWS_STORE_PUBLISHER,
        "publisher_display_name": WINDOWS_STORE_PUBLISHER_DISPLAY_NAME,
        "package_family_name": WINDOWS_STORE_PACKAGE_FAMILY_NAME,
        "product_id": WINDOWS_STORE_PRODUCT_ID,
        "architecture": _require_windows_store_arch(arch),
        "minimum_windows_version": WINDOWS_STORE_MINIMUM_VERSION,
    }


def _validate_windows_store_manifest_root(
    root: ET.Element,
    *,
    package_version: str,
    arch: str,
) -> None:
    parse_windows_store_version(
        package_version,
        label="Windows Store package version",
    )

    namespace = {"appx": "http://schemas.microsoft.com/appx/manifest/foundation/windows10"}
    identity = root.find("appx:Identity", namespace)
    properties = root.find("appx:Properties", namespace)
    dependency = root.find("appx:Dependencies/appx:TargetDeviceFamily", namespace)
    application = root.find("appx:Applications/appx:Application", namespace)
    protocol = root.find(".//{http://schemas.microsoft.com/appx/manifest/uap/windows10}Protocol")
    capabilities = {
        element.attrib.get("Name", "") for element in root.findall("appx:Capabilities/*", namespace)
    }
    expected = windows_store_identity(arch=arch)
    checks = {
        "package name": identity is not None
        and identity.attrib.get("Name") == expected["package_name"],
        "publisher": identity is not None
        and identity.attrib.get("Publisher") == expected["publisher"],
        "package version": identity is not None
        and identity.attrib.get("Version") == package_version,
        "publisher display name": properties is not None
        and properties.findtext("appx:PublisherDisplayName", namespaces=namespace)
        == expected["publisher_display_name"],
        "Windows 10 minimum version": dependency is not None
        and dependency.attrib.get("Name") == "Windows.Desktop"
        and dependency.attrib.get("MinVersion") == expected["minimum_windows_version"],
        "processor architecture": application is not None
        and identity is not None
        and identity.attrib.get("ProcessorArchitecture") == expected["architecture"],
        "full-trust entry point": application is not None
        and application.attrib.get("EntryPoint") == "Windows.FullTrustApplication",
        "OAuth protocol": protocol is not None and protocol.attrib.get("Name") == "deploydash",
        "application executable": application is not None
        and application.attrib.get("Executable") == "deploydash.exe",
        "exact capabilities": capabilities == WINDOWS_STORE_CAPABILITIES,
    }
    failures = [label for label, passed in checks.items() if not passed]
    if failures:
        raise ReleaseContractError(
            "Windows Store manifest violates release contract: " + ", ".join(failures)
        )


def validate_windows_store_manifest(
    manifest_path: Path,
    *,
    package_version: str,
    arch: str,
) -> None:
    """Validate the rendered Appx manifest before MakeAppx sees it."""

    try:
        root = ET.parse(manifest_path).getroot()
    except (OSError, ET.ParseError) as exc:
        raise ReleaseContractError(
            f"Unable to read Windows Store manifest: {manifest_path}"
        ) from exc
    _validate_windows_store_manifest_root(root, package_version=package_version, arch=arch)


def _normalized_archive_name(value: str) -> str:
    normalized = value.replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def _validate_payload_names(
    names: list[str],
    *,
    allowed_prohibited_suffixes: frozenset[str] = frozenset(),
) -> set[str]:
    normalized = [_normalized_archive_name(name) for name in names]
    if len(normalized) != len(set(normalized)):
        raise ReleaseContractError("Windows Store payload contains duplicate paths.")
    for name in normalized:
        lowered = name.lower()
        parts = lowered.split("/")
        if not name or name.startswith("/") or ".." in parts:
            raise ReleaseContractError(f"Windows Store payload contains an unsafe path: {name}")
        basename = parts[-1]
        suffix = Path(basename).suffix
        contains_prohibited_part = (
            ".e2e-secrets" in parts or "credentials" in parts or "qa/e2e/local" in lowered
        )
        if (
            (
                suffix in _WINDOWS_STORE_PROHIBITED_SUFFIXES
                and suffix not in allowed_prohibited_suffixes
            )
            or basename in _WINDOWS_STORE_PROHIBITED_NAMES
            or contains_prohibited_part
        ):
            raise ReleaseContractError(
                f"Windows Store payload contains prohibited release material: {name}"
            )
    return set(normalized)


def _validate_payload_content(
    *,
    label: str,
    payload: bytes,
    forbidden_values: tuple[bytes, ...],
) -> None:
    if _PRIVATE_KEY_BLOCK_PATTERN.search(payload):
        raise ReleaseContractError(f"Windows Store payload contains private-key material: {label}")
    if any(value and value in payload for value in forbidden_values):
        raise ReleaseContractError(
            f"Windows Store payload contains a configured forbidden value: {label}"
        )


def _png_dimensions(payload: bytes, *, label: str) -> tuple[int, int]:
    if len(payload) < 24 or payload[:8] != b"\x89PNG\r\n\x1a\n" or payload[12:16] != b"IHDR":
        raise ReleaseContractError(f"Windows Store asset is not a valid PNG: {label}")
    return struct.unpack(">II", payload[16:24])


def _is_windows_store_makeappx_footprint(relative: str) -> bool:
    return relative in WINDOWS_STORE_MAKEAPPX_FOOTPRINT_NAMES or relative.startswith(
        WINDOWS_STORE_MAKEAPPX_FOOTPRINT_PREFIXES
    )


def canonical_windows_store_payload_digest(package_root: Path) -> dict[str, object]:
    if not package_root.is_dir():
        raise ReleaseContractError(f"Windows Store package root not found: {package_root}")
    records: list[tuple[str, int, str]] = []
    for path in sorted(package_root.rglob("*")):
        if path.is_symlink():
            raise ReleaseContractError(
                f"Windows Store package root contains a symbolic link: {path}"
            )
        if not path.is_file():
            continue
        relative = path.relative_to(package_root).as_posix()
        if _is_windows_store_makeappx_footprint(relative):
            continue
        try:
            payload = path.read_bytes()
        except OSError as exc:
            raise ReleaseContractError(
                f"Unable to read Windows Store payload file: {path}"
            ) from exc
        records.append((relative, len(payload), hashlib.sha256(payload).hexdigest()))
    if not records:
        raise ReleaseContractError("Windows Store package root is empty.")
    digest = hashlib.sha256()
    for relative, size, sha256 in records:
        digest.update(f"{relative}\0{size}\0{sha256}\n".encode())
    return {
        "algorithm": "sha256-path-size-content-v1",
        "sha256": digest.hexdigest(),
        "file_count": len(records),
        "total_size": sum(record[1] for record in records),
    }


def validate_windows_store_package_root(
    package_root: Path,
    *,
    package_version: str,
    arch: str,
    forbidden_values: tuple[str, ...] = (),
) -> dict[str, object]:
    digest = canonical_windows_store_payload_digest(package_root)
    paths = [
        path.relative_to(package_root).as_posix()
        for path in package_root.rglob("*")
        if path.is_file()
    ]
    normalized = _validate_payload_names(paths)
    required = WINDOWS_STORE_REQUIRED_PAYLOAD_PATHS | set(WINDOWS_STORE_ASSET_DIMENSIONS)
    missing = required - normalized
    if missing:
        raise ReleaseContractError(
            "Windows Store package root is missing required runtime files: "
            + ", ".join(sorted(missing))
        )
    if not any(name.startswith("data/py/site-packages/orchestrator/") for name in normalized):
        raise ReleaseContractError(
            "Windows Store package root is missing the bundled backend package."
        )
    encoded_forbidden = tuple(value.encode("utf-8") for value in forbidden_values if value)
    for relative in sorted(normalized):
        path = package_root / Path(relative)
        payload = path.read_bytes()
        _validate_payload_content(
            label=relative,
            payload=payload,
            forbidden_values=encoded_forbidden,
        )
    validate_windows_store_manifest(
        package_root / "AppxManifest.xml",
        package_version=package_version,
        arch=arch,
    )
    for relative, expected in WINDOWS_STORE_ASSET_DIMENSIONS.items():
        actual = _png_dimensions(
            (package_root / Path(relative)).read_bytes(),
            label=relative,
        )
        if actual != expected:
            raise ReleaseContractError(
                f"Windows Store asset has incorrect dimensions ({actual[0]}x{actual[1]}): "
                f"{relative}; expected {expected[0]}x{expected[1]}."
            )
    validate_windows_binary_hardening(package_root)
    return digest


def _read_zip(path: Path, *, label: str) -> ZipFile:
    try:
        return ZipFile(path, "r")
    except (OSError, BadZipFile) as exc:
        raise ReleaseContractError(f"Unable to read {label}: {path}") from exc


def create_windows_store_appxsym(build_dir: Path, output_path: Path) -> None:
    if not build_dir.is_dir():
        raise ReleaseContractError(f"Windows release bundle not found: {build_dir}")
    symbols = sorted(
        path
        for path in build_dir.rglob("*.pdb")
        if path.is_file() and path.name.lower() in WINDOWS_STORE_REQUIRED_SYMBOL_NAMES
    )
    found_names = {path.name.lower() for path in symbols}
    if found_names != WINDOWS_STORE_REQUIRED_SYMBOL_NAMES:
        missing = WINDOWS_STORE_REQUIRED_SYMBOL_NAMES - found_names
        raise ReleaseContractError(
            "The Windows release bundle is missing first-party PDB symbols: "
            + ", ".join(sorted(missing))
        )
    try:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with ZipFile(output_path, "w", compression=ZIP_DEFLATED) as archive:
            for symbol in symbols:
                archive.write(symbol, symbol.relative_to(build_dir).as_posix())
    except OSError as exc:
        raise ReleaseContractError(
            f"Unable to create Windows Store symbol archive: {output_path}"
        ) from exc
    validate_windows_store_appxsym(output_path)


def validate_windows_store_appxsym(path: Path) -> None:
    with _read_zip(path, label="Windows Store symbol archive") as archive:
        names = _validate_payload_names(
            archive.namelist(),
            allowed_prohibited_suffixes=frozenset({".pdb"}),
        )
        if not names or any(not name.lower().endswith(".pdb") for name in names):
            raise ReleaseContractError("Windows Store symbol archive must contain only PDB files.")
        symbol_names = {Path(name).name.lower() for name in names}
        if symbol_names != WINDOWS_STORE_REQUIRED_SYMBOL_NAMES:
            raise ReleaseContractError(
                "Windows Store symbol archive must contain exactly the first-party "
                "runner and bridge PDB files."
            )
        for entry in archive.infolist():
            name = _normalized_archive_name(entry.filename)
            if not archive.read(entry):
                raise ReleaseContractError(
                    f"Windows Store symbol archive contains an empty PDB: {name}"
                )


def create_windows_store_msixupload(
    *,
    msix_path: Path,
    appxsym_path: Path,
    output_path: Path,
) -> None:
    for path, label in ((msix_path, "MSIX"), (appxsym_path, "Appx symbols")):
        if not path.is_file() or path.stat().st_size == 0:
            raise ReleaseContractError(
                f"Windows Store {label} artifact is missing or empty: {path}"
            )
    try:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with ZipFile(output_path, "w", compression=ZIP_DEFLATED) as archive:
            archive.write(msix_path, msix_path.name)
            archive.write(appxsym_path, appxsym_path.name)
    except OSError as exc:
        raise ReleaseContractError(
            f"Unable to create Windows Store upload archive: {output_path}"
        ) from exc
    validate_windows_store_msixupload(
        msixupload_path=output_path,
        msix_path=msix_path,
        appxsym_path=appxsym_path,
    )


def validate_windows_store_msixupload(
    *,
    msixupload_path: Path,
    msix_path: Path,
    appxsym_path: Path,
) -> None:
    expected = {msix_path.name, appxsym_path.name}
    with _read_zip(msixupload_path, label="Windows Store upload archive") as archive:
        names = _validate_payload_names(archive.namelist())
        if names != expected:
            raise ReleaseContractError(
                "Windows Store upload archive must contain exactly the MSIX and AppxSym."
            )
        for source in (msix_path, appxsym_path):
            if archive.read(source.name) != source.read_bytes():
                raise ReleaseContractError(
                    f"Windows Store upload archive content does not match: {source.name}"
                )


def validate_windows_store_msix(
    msix_path: Path,
    *,
    package_version: str,
    arch: str,
    allow_signed: bool = False,
    forbidden_values: tuple[str, ...] = (),
) -> None:
    encoded_forbidden = tuple(value.encode("utf-8") for value in forbidden_values if value)
    with _read_zip(msix_path, label="Windows Store MSIX") as archive:
        names = _validate_payload_names(archive.namelist())
        required = WINDOWS_STORE_REQUIRED_PAYLOAD_PATHS | set(WINDOWS_STORE_ASSET_DIMENSIONS)
        missing = required - names
        if missing:
            raise ReleaseContractError(
                "Windows Store MSIX is missing required runtime files: "
                + ", ".join(sorted(missing))
            )
        if not any(name.startswith("data/py/site-packages/orchestrator/") for name in names):
            raise ReleaseContractError("Windows Store MSIX is missing the bundled backend package.")
        if "AppxBlockMap.xml" not in names or "[Content_Types].xml" not in names:
            raise ReleaseContractError(
                "Windows Store MSIX is missing required Appx package metadata."
            )
        has_signature = "AppxSignature.p7x" in names
        if has_signature and not allow_signed:
            raise ReleaseContractError(
                "Production Windows Store MSIX must remain unsigned before upload."
            )
        try:
            manifest_root = ET.fromstring(archive.read("AppxManifest.xml"))
        except ET.ParseError as exc:
            raise ReleaseContractError(
                "Windows Store MSIX contains an invalid Appx manifest."
            ) from exc
        _validate_windows_store_manifest_root(
            manifest_root,
            package_version=package_version,
            arch=arch,
        )
        for name in sorted(names):
            payload = archive.read(name)
            _validate_payload_content(
                label=name,
                payload=payload,
                forbidden_values=encoded_forbidden,
            )
        for relative, expected in WINDOWS_STORE_ASSET_DIMENSIONS.items():
            actual = _png_dimensions(archive.read(relative), label=relative)
            if actual != expected:
                raise ReleaseContractError(
                    f"Windows Store asset has incorrect dimensions: {relative}"
                )
        for name in ("deploydash.exe", "bridge.dll"):
            characteristics = _read_pe_dll_characteristics(
                archive.read(name),
                label=name,
            )
            missing_mitigations = [
                label
                for label, flag in _PE_REQUIRED_DLL_CHARACTERISTICS.items()
                if characteristics & flag == 0
            ]
            if missing_mitigations:
                raise ReleaseContractError(
                    "Windows Store MSIX binary is missing required mitigations "
                    f"({', '.join(missing_mitigations)}): {name}"
                )


def write_windows_store_build_manifest(
    output_path: Path,
    *,
    package_version: str,
    arch: str,
    package_root: Path,
    msix_path: Path,
    appxsym_path: Path,
    msixupload_path: Path,
) -> None:
    """Write hashes and immutable identity metadata for Store handoff."""

    artifacts: dict[str, dict[str, object]] = {}
    for label, path in (
        ("msix", msix_path),
        ("appxsym", appxsym_path),
        ("msixupload", msixupload_path),
    ):
        try:
            payload = path.read_bytes()
        except OSError as exc:
            raise ReleaseContractError(
                f"Unable to read Windows Store {label} artifact: {path}"
            ) from exc
        if not payload:
            raise ReleaseContractError(f"Windows Store {label} artifact is empty: {path}")
        artifacts[label] = {
            "file": path.name,
            "size": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }

    document: dict[str, object] = {
        "schema_version": 2,
        "identity": windows_store_identity(arch=arch),
        "package_version": package_version,
        "distribution": "windows_store",
        "payload": canonical_windows_store_payload_digest(package_root),
        "artifacts": artifacts,
    }
    try:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except OSError as exc:
        raise ReleaseContractError(
            f"Unable to write Windows Store build manifest: {output_path}"
        ) from exc


def validate_windows_store_build_manifest(
    manifest_path: Path,
    *,
    arch: str,
    package_root: Path,
    msix_path: Path,
    appxsym_path: Path,
    msixupload_path: Path,
) -> None:
    try:
        document = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ReleaseContractError(
            f"Unable to read Windows Store build manifest: {manifest_path}"
        ) from exc
    if document.get("schema_version") != 2:
        raise ReleaseContractError("Windows Store build manifest schema is invalid.")
    if document.get("identity") != windows_store_identity(arch=arch):
        raise ReleaseContractError("Windows Store build manifest identity is invalid.")
    if document.get("distribution") != "windows_store":
        raise ReleaseContractError("Windows Store build manifest distribution is invalid.")
    if document.get("payload") != canonical_windows_store_payload_digest(package_root):
        raise ReleaseContractError("Windows Store build manifest payload digest does not match.")
    expected_artifacts: dict[str, dict[str, object]] = {}
    for label, path in (
        ("msix", msix_path),
        ("appxsym", appxsym_path),
        ("msixupload", msixupload_path),
    ):
        try:
            payload = path.read_bytes()
        except OSError as exc:
            raise ReleaseContractError(
                f"Unable to read Windows Store {label} artifact: {path}"
            ) from exc
        expected_artifacts[label] = {
            "file": path.name,
            "size": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }
    if document.get("artifacts") != expected_artifacts:
        raise ReleaseContractError("Windows Store build manifest artifact hashes do not match.")
    package_version = document.get("package_version")
    if not isinstance(package_version, str):
        raise ReleaseContractError("Windows Store build manifest package version is invalid.")
    parse_windows_store_version(
        package_version,
        label="Windows Store build manifest package version",
    )


def resolve_build_metadata(
    *,
    input_build_name: str | None,
    input_build_number: str | None,
    github_run_number: str | None,
    github_ref_type: str | None,
    github_ref_name: str | None,
) -> dict[str, str]:
    build_name = (input_build_name or "").strip()
    build_number = (input_build_number or "").strip()

    if not build_number:
        build_number = (github_run_number or "").strip()

    if not build_name and (github_ref_type or "").strip() == "tag":
        tag_name = (github_ref_name or "").strip()
        if tag_name.startswith("v"):
            tag_name = tag_name[1:]
        if re.fullmatch(r"\d+\.\d+\.\d+", tag_name):
            build_name = tag_name

    result: dict[str, str] = {}
    if build_name:
        result["DEPLOYDASH_BUILD_NAME"] = build_name
    if build_number:
        result["DEPLOYDASH_BUILD_NUMBER"] = build_number
    return result


def write_github_env(env_file: Path, values: dict[str, str]) -> None:
    with env_file.open("a", encoding="utf-8") as handle:
        for key, value in values.items():
            handle.write(f"{key}={value}\n")


def flutter_build_args(
    *,
    app_dir: Path,
    dart_defines_file: str | None,
    build_name: str | None,
    build_number: str | None,
    default_to_pubspec: bool = False,
) -> list[str]:
    args: list[str] = []
    resolved_dart_defines = resolve_dart_defines_arg(
        app_dir=app_dir,
        dart_defines_file=dart_defines_file,
    )
    if resolved_dart_defines is not None:
        args.append(resolved_dart_defines)

    resolved_build_name = (build_name or "").strip()
    resolved_build_number = (build_number or "").strip()
    if default_to_pubspec and (not resolved_build_name or not resolved_build_number):
        pubspec_build_name, pubspec_build_number = flutter_pubspec_build_metadata(app_dir)
        resolved_build_name = resolved_build_name or pubspec_build_name
        resolved_build_number = resolved_build_number or pubspec_build_number

    if resolved_build_name:
        args.append(f"--build-name={resolved_build_name}")
        args.append(f"--dart-define=DEPLOYDASH_RELEASE_VERSION={resolved_build_name}")
    if resolved_build_number:
        args.append(f"--build-number={resolved_build_number}")
        args.append(f"--dart-define=DEPLOYDASH_RELEASE_BUILD={resolved_build_number}")
    return args


def resolve_dart_defines_arg(
    *,
    app_dir: Path,
    dart_defines_file: str | None,
) -> str | None:
    value = (dart_defines_file or "").strip()
    if value:
        candidate = Path(value)
        if not candidate.is_absolute():
            candidate = app_dir / candidate
        if not candidate.exists():
            raise ReleaseContractError(f"DEPLOYDASH_DART_DEFINES_FILE does not exist: {value}")
        return f"--dart-define-from-file={value}"

    local_defines = app_dir / "config" / "dart-defines.local.json"
    if local_defines.exists():
        return "--dart-define-from-file=config/dart-defines.local.json"
    return None


def expected_windows_release_bundle_dir(app_dir: Path) -> Path:
    return app_dir / "build" / "windows" / "x64" / "runner" / "Release"


def expected_linux_release_bundle_dir(app_dir: Path) -> Path:
    return app_dir / "build" / "linux" / "x64" / "release" / "bundle"


def expected_windows_msi_path(app_dir: Path) -> Path:
    return app_dir / "build" / "windows" / "installer" / "DeployDash.msi"


def expected_windows_msix_path(app_dir: Path, package_version: str, arch: str) -> Path:
    name = windows_store_artifact_names(package_version, arch=arch)["msix"]
    return app_dir / "build" / "windows" / "installer" / name


def expected_windows_appxsym_path(app_dir: Path, package_version: str, arch: str) -> Path:
    name = windows_store_artifact_names(package_version, arch=arch)["appxsym"]
    return app_dir / "build" / "windows" / "installer" / name


def expected_windows_msixupload_path(app_dir: Path, package_version: str, arch: str) -> Path:
    name = windows_store_artifact_names(package_version, arch=arch)["msixupload"]
    return app_dir / "build" / "windows" / "installer" / name


def expected_windows_store_build_manifest_path(
    app_dir: Path,
    package_version: str,
    arch: str,
) -> Path:
    name = windows_store_artifact_names(package_version, arch=arch)["build_manifest"]
    return app_dir / "build" / "windows" / "installer" / name


def expected_macos_release_dir(app_dir: Path) -> Path:
    return app_dir / "build" / "macos" / "Build" / "Products" / "Release"


#: Filename tokens for macOS DMG architectures, matching the update wire
#: protocol. The Xcode spelling ``x86_64`` is accepted and normalized here —
#: this function is the single place that mapping lives.
MACOS_DMG_ARCHITECTURES = {
    "arm64": "arm64",
    "x64": "x64",
    "x86_64": "x64",
}

MACOS_DMG_LEGACY_NAME = "DeployDash.dmg"


def macos_dmg_name(*, build_name: str, arch: str) -> str:
    """Return the versioned macOS DMG filename for a release build.

    An empty build name (local dev builds outside the release pipeline)
    yields the historical unversioned name so existing local flows keep
    working byte-for-byte.
    """

    resolved_name = (build_name or "").strip()
    if not resolved_name:
        return MACOS_DMG_LEGACY_NAME
    if not re.fullmatch(r"\d+\.\d+\.\d+", resolved_name):
        raise ReleaseContractError("macOS DMG build name must use semantic version X.Y.Z.")
    token = MACOS_DMG_ARCHITECTURES.get((arch or "").strip())
    if token is None:
        raise ReleaseContractError("macOS DMG architecture must be arm64 or x64.")
    return f"DeployDash-v{resolved_name}-{token}.dmg"


def expected_macos_dmg_path(
    app_dir: Path,
    *,
    build_name: str = "",
    arch: str = "arm64",
) -> Path:
    return (
        app_dir
        / "build"
        / "macos"
        / "distribution"
        / macos_dmg_name(build_name=build_name, arch=arch)
    )


def expected_macos_app_store_export_path(app_dir: Path) -> Path:
    return app_dir / "build" / "macos" / "app_store" / "export"


def required_windows_runtime_paths(build_dir: Path) -> list[Path]:
    return [
        build_dir / "deploydash.exe",
        build_dir / "bridge.dll",
        build_dir / "python.exe",
        build_dir / "pythonw.exe",
        build_dir / "python313.dll",
        build_dir / "DLLs" / "_socket.pyd",
        build_dir / "sqlite3mc.dll",
        build_dir / "data" / "py" / "site-packages" / "orchestrator",
    ]


def required_windows_signing_paths(build_dir: Path) -> list[Path]:
    return [
        build_dir / "deploydash.exe",
        build_dir / "bridge.dll",
        build_dir / "python.exe",
        build_dir / "pythonw.exe",
        build_dir / "python313.dll",
        build_dir / "sqlite3mc.dll",
    ]


_PE_REQUIRED_DLL_CHARACTERISTICS = {
    "high-entropy VA": 0x0020,
    "dynamic base": 0x0040,
    "NX compatible": 0x0100,
    "control-flow guard": 0x4000,
}

_MACHO_MAGICS = {
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
}


def is_macho_binary(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(4) in _MACHO_MAGICS
    except OSError as exc:
        raise ReleaseContractError(f"Unable to inspect macOS code: {path}") from exc


def macos_nested_signing_paths(app_bundle: Path) -> list[Path]:
    if not app_bundle.is_dir():
        raise ReleaseContractError(f"macOS app bundle not found: {app_bundle}")

    code_roots = (
        app_bundle / "Contents" / "Frameworks",
        app_bundle / "Contents" / "Resources" / "data" / "py",
        app_bundle / "Contents" / "Resources" / "python",
    )
    binaries: set[Path] = set()
    code_bundles: set[Path] = set()
    for root in code_roots:
        if not root.is_dir():
            continue
        for candidate in root.rglob("*"):
            if candidate.is_symlink():
                continue
            if candidate.is_dir() and candidate.suffix in {
                ".app",
                ".framework",
                ".xpc",
            }:
                code_bundles.add(candidate)
                continue
            if candidate.is_file() and is_macho_binary(candidate):
                binaries.add(candidate)

    def by_depth_then_path(path: Path) -> tuple[int, str]:
        return (-len(path.parts), str(path))

    return sorted(binaries, key=by_depth_then_path) + sorted(
        code_bundles,
        key=by_depth_then_path,
    )


def select_macos_signing_identity(identity_listing: str) -> str:
    identity_pattern = re.compile(r'^\s*\d+\)\s+[0-9A-Fa-f]+\s+"(?P<identity>[^"]+)"\s*$')
    identities = [
        match.group("identity")
        for line in identity_listing.splitlines()
        if (match := identity_pattern.match(line)) is not None
    ]
    for prefix in ("Apple Development:", "Developer ID Application:"):
        for identity in identities:
            if identity.startswith(prefix):
                return identity
    raise ReleaseContractError(
        "No suitable macOS code-signing identity is available. Install an "
        "Apple Development or Developer ID Application certificate, or set "
        "DEPLOYDASH_MACOS_APP_SIGN_IDENTITY."
    )


def _read_pe_dll_characteristics(payload: bytes, *, label: str) -> int:
    if len(payload) < 0x40 or payload[:2] != b"MZ":
        raise ReleaseContractError(f"Invalid Windows PE binary: {label}")

    pe_offset = struct.unpack_from("<I", payload, 0x3C)[0]
    optional_header_offset = pe_offset + 24
    magic_offset_end = optional_header_offset + 2
    if magic_offset_end > len(payload) or payload[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise ReleaseContractError(f"Invalid Windows PE header: {label}")

    magic = struct.unpack_from("<H", payload, optional_header_offset)[0]
    if magic not in {0x10B, 0x20B}:
        raise ReleaseContractError(f"Unsupported Windows optional-header format in: {label}")

    dll_characteristics_offset = optional_header_offset + 70
    if dll_characteristics_offset + 2 > len(payload):
        raise ReleaseContractError(f"Truncated Windows optional header in: {label}")
    return struct.unpack_from("<H", payload, dll_characteristics_offset)[0]


def read_pe_dll_characteristics(path: Path) -> int:
    try:
        payload = path.read_bytes()
    except OSError as exc:
        raise ReleaseContractError(
            f"Unable to read Windows binary for hardening validation: {path}"
        ) from exc
    return _read_pe_dll_characteristics(payload, label=str(path))


def validate_windows_binary_hardening(build_dir: Path) -> None:
    for path in [build_dir / "deploydash.exe", build_dir / "bridge.dll"]:
        characteristics = read_pe_dll_characteristics(path)
        missing = [
            label
            for label, flag in _PE_REQUIRED_DLL_CHARACTERISTICS.items()
            if characteristics & flag == 0
        ]
        if missing:
            raise ReleaseContractError(
                f"Windows binary is missing required mitigations ({', '.join(missing)}): {path}"
            )


def required_linux_runtime_paths(build_dir: Path) -> list[Path]:
    return [
        build_dir / "deploydash",
        build_dir / "data" / "flutter_assets",
        build_dir / "data" / "icudtl.dat",
        build_dir / "data" / "py" / "site-packages" / "orchestrator",
        build_dir / "lib" / "libbridge.so",
        build_dir / "lib" / "libapp.so",
        build_dir / "lib" / "libflutter_linux_gtk.so",
        # Spawn worker interpreter: task_runtime re-execs this binary for
        # every engine task (fork is unavailable/unsafe on some platforms),
        # so the bundle must carry it next to the lib/ tree it resolves
        # against (see ui/linux/CMakeLists.txt spawn-interpreter install).
        build_dir / "python" / "bin" / "python3.13",
    ]


def validate_windows_release_bundle(build_dir: Path) -> None:
    if not build_dir.exists():
        raise ReleaseContractError(f"Windows release bundle not found: {build_dir}")

    for required_path in required_windows_runtime_paths(build_dir):
        if not required_path.exists():
            raise ReleaseContractError(
                f"Required runtime artifact missing from Windows bundle: {required_path}"
            )

    unsupported_tk_paths = [
        build_dir / "DLLs" / "_tkinter.pyd",
        build_dir / "DLLs" / "tcl86t.dll",
        build_dir / "DLLs" / "tk86t.dll",
        build_dir / "Lib" / "tkinter",
    ]
    present_tk_paths = [path for path in unsupported_tk_paths if path.exists()]
    if present_tk_paths:
        raise ReleaseContractError(
            "Unused Tcl/Tk runtime artifacts must not be included in the "
            "Windows release bundle: " + ", ".join(str(path) for path in present_tk_paths)
        )

    # The runtime is pinned to CPython 3.13.14, which ships no
    # DLLs/zlib1.dll at all, so no signing-blocking exclusion is needed.


def validate_linux_release_bundle(build_dir: Path) -> None:
    if not build_dir.exists():
        raise ReleaseContractError(f"Linux release bundle not found: {build_dir}")

    for required_path in required_linux_runtime_paths(build_dir):
        if not required_path.exists():
            raise ReleaseContractError(
                f"Required runtime artifact missing from Linux bundle: {required_path}"
            )

    if not list((build_dir / "lib").glob("libpython3.13.so*")):
        raise ReleaseContractError(
            "Required runtime artifact missing from Linux bundle: "
            f"{build_dir / 'lib' / 'libpython3.13.so*'}"
        )


def locate_macos_app_bundle(release_dir: Path) -> Path:
    if not release_dir.exists():
        raise ReleaseContractError(f"macOS release products directory not found: {release_dir}")

    matches = sorted(release_dir.glob("*.app"))
    if not matches:
        raise ReleaseContractError("Unable to locate the built macOS .app bundle.")
    return matches[0]


def assert_artifact_exists(path: Path, label: str) -> None:
    if not path.exists():
        raise ReleaseContractError(f"{label} was not produced at expected path: {path}")
