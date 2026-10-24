from __future__ import annotations

import json
import struct
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from zipfile import ZIP_DEFLATED, ZipFile

from orchestrator.release_helpers import (
    ReleaseContractError,
    canonical_windows_store_payload_digest,
    create_windows_store_appxsym,
    create_windows_store_msixupload,
    parse_windows_store_version,
    read_last_published_windows_store_version,
    validate_windows_store_appxsym,
    validate_windows_store_build_manifest,
    validate_windows_store_manifest,
    validate_windows_store_msix,
    validate_windows_store_msixupload,
    validate_windows_store_package_root,
    validate_windows_store_version,
    windows_store_artifact_names,
    windows_store_identity,
    write_windows_store_build_manifest,
)


class TestWindowsStoreRelease(unittest.TestCase):
    package_version = "1.2.3.0"

    @staticmethod
    def _manifest(
        version: str = "1.2.3.0",
        arch: str = "x64",
        min_version: str = "10.0.17763.0",
    ) -> bytes:
        return f"""<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
 xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
 xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities">
 <Identity Name="TidyTechnology.DeployDash"
  Publisher="CN=4DF691A0-E545-4698-A115-C49614B329C6"
  Version="{version}" ProcessorArchitecture="{arch}" />
 <Properties><PublisherDisplayName>Tidy Technology</PublisherDisplayName></Properties>
 <Dependencies><TargetDeviceFamily Name="Windows.Desktop"
  MinVersion="{min_version}" /></Dependencies>
 <Applications><Application Executable="deploydash.exe"
  EntryPoint="Windows.FullTrustApplication">
  <Extensions><uap:Extension><uap:Protocol Name="deploydash" /></uap:Extension></Extensions>
 </Application></Applications>
 <Capabilities><Capability Name="internetClient" />
  <Capability Name="privateNetworkClientServer" />
  <rescap:Capability Name="runFullTrust" /></Capabilities>
</Package>
""".encode()

    @staticmethod
    def _pe(characteristics: int = 0x4160) -> bytes:
        payload = bytearray(512)
        payload[:2] = b"MZ"
        struct.pack_into("<I", payload, 0x3C, 0x80)
        payload[0x80:0x84] = b"PE\0\0"
        optional_header_offset = 0x80 + 24
        struct.pack_into("<H", payload, optional_header_offset, 0x20B)
        struct.pack_into(
            "<H",
            payload,
            optional_header_offset + 70,
            characteristics,
        )
        return bytes(payload)

    @staticmethod
    def _png(width: int, height: int) -> bytes:
        return (
            b"\x89PNG\r\n\x1a\n"
            + struct.pack(">I", 13)
            + b"IHDR"
            + struct.pack(">II", width, height)
        )

    def _payloads(self) -> dict[str, bytes]:
        return {
            "AppxManifest.xml": self._manifest(),
            "deploydash.exe": self._pe(),
            "bridge.dll": self._pe(),
            "python.exe": b"python",
            "pythonw.exe": b"pythonw",
            "python313.dll": b"python-dll",
            "DLLs/_socket.pyd": b"socket",
            "sqlite3mc.dll": b"sqlite",
            "data/py/site-packages/orchestrator/__init__.py": b"backend",
            "Assets/StoreLogo.png": self._png(50, 50),
            "Assets/Square44x44Logo.png": self._png(44, 44),
            "Assets/Square150x150Logo.png": self._png(150, 150),
            "Assets/Wide310x150Logo.png": self._png(310, 150),
        }

    def _write_package_root(self, root: Path) -> Path:
        package_root = root / "package"
        for relative, payload in self._payloads().items():
            path = package_root / Path(relative)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
        return package_root

    def _write_msix(
        self,
        path: Path,
        *,
        mutations: dict[str, bytes | None] | None = None,
        signed: bool = False,
    ) -> None:
        payloads = self._payloads()
        payloads.update(
            {
                "AppxBlockMap.xml": b"block-map",
                "[Content_Types].xml": b"content-types",
            }
        )
        if signed:
            payloads["AppxSignature.p7x"] = b"signature"
        for name, payload in (mutations or {}).items():
            if payload is None:
                payloads.pop(name, None)
            else:
                payloads[name] = payload
        with ZipFile(path, "w", compression=ZIP_DEFLATED) as archive:
            for name, payload in payloads.items():
                archive.writestr(name, payload)

    def test_version_contract_and_artifact_names(self):
        self.assertEqual(
            parse_windows_store_version("1.2.3.0", label="Version"),
            (1, 2, 3, 0),
        )
        validate_windows_store_version(
            package_version="1.2.3.0",
            last_published_version="1.2.2.0",
        )
        self.assertEqual(
            windows_store_artifact_names("1.2.3.0", arch="x64"),
            {
                "msix": "DeployDash_1.2.3.0_x64.msix",
                "appxsym": "DeployDash_1.2.3.0_x64.appxsym",
                "msixupload": "DeployDash_1.2.3.0_x64.msixupload",
                "build_manifest": "DeployDash_1.2.3.0_x64.build-manifest.json",
            },
        )
        for value, message in (
            ("1.2.3", "X.Y.Z.0"),
            ("65536.0.0.0", "between 0 and 65535"),
            ("1.2.3.1", "revision must be zero"),
        ):
            with self.subTest(value=value), self.assertRaisesRegex(ReleaseContractError, message):
                parse_windows_store_version(value, label="Version")
        for package in ("1.2.2.0", "1.2.3.0"):
            with (
                self.subTest(package=package),
                self.assertRaisesRegex(ReleaseContractError, "must be newer"),
            ):
                validate_windows_store_version(
                    package_version=package,
                    last_published_version="1.2.3.0",
                )

    def test_windows_store_artifact_names_use_explicit_arch(self):
        self.assertEqual(
            windows_store_artifact_names("1.2.3.0", arch="x64"),
            {
                "msix": "DeployDash_1.2.3.0_x64.msix",
                "appxsym": "DeployDash_1.2.3.0_x64.appxsym",
                "msixupload": "DeployDash_1.2.3.0_x64.msixupload",
                "build_manifest": "DeployDash_1.2.3.0_x64.build-manifest.json",
            },
        )
        self.assertEqual(
            windows_store_artifact_names("1.2.3.0", arch="arm64"),
            {
                "msix": "DeployDash_1.2.3.0_arm64.msix",
                "appxsym": "DeployDash_1.2.3.0_arm64.appxsym",
                "msixupload": "DeployDash_1.2.3.0_arm64.msixupload",
                "build_manifest": "DeployDash_1.2.3.0_arm64.build-manifest.json",
            },
        )
        with self.assertRaisesRegex(ReleaseContractError, "architecture"):
            windows_store_artifact_names("1.2.3.0", arch="riscv")

    def test_windows_store_identity_carries_explicit_arch(self):
        self.assertEqual(windows_store_identity(arch="x64")["architecture"], "x64")
        self.assertEqual(windows_store_identity(arch="arm64")["architecture"], "arm64")
        self.assertEqual(
            windows_store_identity(arch="arm64")["minimum_windows_version"],
            "10.0.17763.0",
        )
        with self.assertRaisesRegex(ReleaseContractError, "architecture"):
            windows_store_identity(arch="x86")

    def test_windows_store_manifest_matches_arch_and_floor(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "AppxManifest.xml"
            manifest_path.write_bytes(
                self._manifest(version="1.2.3.0", arch="arm64"),
            )
            validate_windows_store_manifest(
                manifest_path,
                package_version="1.2.3.0",
                arch="arm64",
            )
            with self.assertRaisesRegex(ReleaseContractError, "Windows Store manifest violates"):
                validate_windows_store_manifest(
                    manifest_path,
                    package_version="1.2.3.0",
                    arch="x64",
                )
            manifest_path.write_bytes(
                self._manifest(version="1.2.3.0", min_version="10.0.22000.0"),
            )
            with self.assertRaisesRegex(ReleaseContractError, "Windows Store manifest violates"):
                validate_windows_store_manifest(
                    manifest_path,
                    package_version="1.2.3.0",
                    arch="x64",
                )

    def test_last_published_version_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "version.txt"
            path.write_text("1.0.0.0\n", encoding="utf-8")
            self.assertEqual(
                read_last_published_windows_store_version(path),
                "1.0.0.0",
            )
            path.write_text("invalid", encoding="utf-8")
            with self.assertRaisesRegex(ReleaseContractError, "X.Y.Z.0"):
                read_last_published_windows_store_version(path)
            path.unlink()
            with self.assertRaisesRegex(ReleaseContractError, "Unable to read"):
                read_last_published_windows_store_version(path)

    def test_package_root_validation_and_digest_are_deterministic(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_root = self._write_package_root(root)
            first = validate_windows_store_package_root(
                package_root,
                package_version=self.package_version,
                arch="x64",
            )
            second = canonical_windows_store_payload_digest(package_root)
            self.assertEqual(first, second)
            self.assertEqual(first["file_count"], len(self._payloads()))
            self.assertEqual(len(str(first["sha256"])), 64)

            public_certificate = package_root / "data" / "ca-bundle.pem"
            public_certificate.write_text(
                "-----BEGIN CERTIFICATE-----\npublic\n-----END CERTIFICATE-----\n",
                encoding="utf-8",
            )
            validate_windows_store_package_root(
                package_root,
                package_version=self.package_version,
                arch="x64",
            )

            compiled_binary = package_root / "data" / "app.so"
            compiled_binary.write_bytes(
                b"\x00-----BEGIN PRIVATE KEY-----\x00-----END PRIVATE KEY-----\x00"
            )
            validate_windows_store_package_root(
                package_root,
                package_version=self.package_version,
                arch="x64",
            )

    def test_package_root_validation_rejects_invalid_payloads(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            with self.assertRaisesRegex(ReleaseContractError, "not found"):
                canonical_windows_store_payload_digest(root / "missing")
            empty = root / "empty"
            empty.mkdir()
            with self.assertRaisesRegex(ReleaseContractError, "is empty"):
                canonical_windows_store_payload_digest(empty)

            package_root = self._write_package_root(root)
            symlink = package_root / "link"
            symlink.symlink_to(package_root / "python.exe")
            with self.assertRaisesRegex(ReleaseContractError, "symbolic link"):
                canonical_windows_store_payload_digest(package_root)
            symlink.unlink()

            cases = (
                ("python.exe", None, "missing required runtime"),
                (
                    "data/py/site-packages/orchestrator/__init__.py",
                    None,
                    "missing the bundled backend",
                ),
                ("private.pfx", b"secret", "prohibited release material"),
                ("credentials/token.txt", b"secret", "prohibited release material"),
                ("id_rsa", b"secret", "prohibited release material"),
                (
                    "note.txt",
                    b"-----BEGIN PRIVATE KEY-----\n"
                    b"QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB\n"
                    b"-----END PRIVATE KEY-----\n",
                    "private-key material",
                ),
                ("note.txt", b"configured-secret", "forbidden value"),
                ("Assets/StoreLogo.png", b"not-png", "not a valid PNG"),
                (
                    "Assets/StoreLogo.png",
                    self._png(51, 50),
                    "incorrect dimensions",
                ),
                ("bridge.dll", self._pe(0), "missing required mitigations"),
            )
            for relative, replacement, message in cases:
                with self.subTest(relative=relative, message=message):
                    case_root = root / (
                        "case-" + str(cases.index((relative, replacement, message)))
                    )
                    package = self._write_package_root(case_root)
                    target = package / Path(relative)
                    if replacement is None:
                        target.unlink()
                    else:
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(replacement)
                    forbidden = ("configured-secret",) if message == "forbidden value" else ()
                    with self.assertRaisesRegex(ReleaseContractError, message):
                        validate_windows_store_package_root(
                            package,
                            package_version=self.package_version,
                            arch="x64",
                            forbidden_values=forbidden,
                        )

    def test_payload_path_validation_rejects_duplicates_and_traversal(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for name in ("duplicate.msix", "traversal.msix"):
                path = root / name
                with ZipFile(path, "w") as archive:
                    archive.writestr("AppxManifest.xml", self._manifest())
                    if name.startswith("duplicate"):
                        with self.assertWarns(UserWarning):
                            archive.writestr("AppxManifest.xml", self._manifest())
                    else:
                        archive.writestr("../secret", b"secret")
                with self.assertRaisesRegex(
                    ReleaseContractError,
                    "duplicate paths|unsafe path",
                ):
                    validate_windows_store_msix(
                        path,
                        package_version=self.package_version,
                        arch="x64",
                    )

    def test_appxsym_create_and_validate(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            build = root / "build"
            (build / "nested").mkdir(parents=True)
            (build / "deploydash.pdb").write_bytes(b"app-symbols")
            (build / "nested" / "bridge.pdb").write_bytes(b"bridge-symbols")
            (build / "third-party.pdb").write_bytes(b"not-public")
            output = root / "out" / "symbols.appxsym"
            create_windows_store_appxsym(build, output)
            validate_windows_store_appxsym(output)
            with ZipFile(output) as archive:
                self.assertEqual(
                    set(archive.namelist()),
                    {"deploydash.pdb", "nested/bridge.pdb"},
                )

    def test_appxsym_rejects_invalid_inputs(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            with self.assertRaisesRegex(ReleaseContractError, "bundle not found"):
                create_windows_store_appxsym(root / "missing", root / "out")
            build = root / "build"
            build.mkdir()
            with self.assertRaisesRegex(ReleaseContractError, "first-party PDB"):
                create_windows_store_appxsym(build, root / "out")
            (build / "deploydash.pdb").write_bytes(b"symbols")
            with self.assertRaisesRegex(ReleaseContractError, "bridge.pdb"):
                create_windows_store_appxsym(build, root / "out")
            invalid_zip = root / "invalid"
            invalid_zip.write_bytes(b"invalid")
            with self.assertRaisesRegex(ReleaseContractError, "Unable to read"):
                validate_windows_store_appxsym(invalid_zip)
            for name, payload, message in (
                ("file.txt", b"value", "only PDB"),
                ("file.pdb", b"symbols", "exactly the first-party"),
            ):
                archive_path = root / f"{name}.zip"
                with ZipFile(archive_path, "w") as archive:
                    archive.writestr(name, payload)
                with self.assertRaisesRegex(ReleaseContractError, message):
                    validate_windows_store_appxsym(archive_path)
            normalized = root / "normalized.appxsym"
            with ZipFile(normalized, "w") as archive:
                archive.writestr("./deploydash.pdb", b"symbols")
                archive.writestr("./bridge.pdb", b"symbols")
            validate_windows_store_appxsym(normalized)
            empty = root / "empty.appxsym"
            with ZipFile(empty, "w") as archive:
                archive.writestr("deploydash.pdb", b"")
                archive.writestr("bridge.pdb", b"symbols")
            with self.assertRaisesRegex(ReleaseContractError, "empty PDB"):
                validate_windows_store_appxsym(empty)
            output_dir = root / "output-dir"
            output_dir.mkdir()
            (build / "bridge.pdb").write_bytes(b"symbols")
            with self.assertRaisesRegex(ReleaseContractError, "Unable to create"):
                create_windows_store_appxsym(build, output_dir)

    def test_msixupload_create_and_validate(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            msix = root / "app.msix"
            appxsym = root / "app.appxsym"
            msix.write_bytes(b"msix")
            appxsym.write_bytes(b"symbols")
            output = root / "out" / "app.msixupload"
            create_windows_store_msixupload(
                msix_path=msix,
                appxsym_path=appxsym,
                output_path=output,
            )
            validate_windows_store_msixupload(
                msixupload_path=output,
                msix_path=msix,
                appxsym_path=appxsym,
            )

            with ZipFile(output, "w") as archive:
                archive.writestr(msix.name, b"wrong")
                archive.writestr(appxsym.name, b"symbols")
            with self.assertRaisesRegex(ReleaseContractError, "does not match"):
                validate_windows_store_msixupload(
                    msixupload_path=output,
                    msix_path=msix,
                    appxsym_path=appxsym,
                )

    def test_msixupload_rejects_invalid_inputs(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            valid = root / "valid"
            valid.write_bytes(b"valid")
            for invalid in (root / "missing", root / "empty"):
                if invalid.name == "empty":
                    invalid.touch()
                with (
                    self.subTest(invalid=invalid.name),
                    self.assertRaisesRegex(ReleaseContractError, "missing or empty"),
                ):
                    create_windows_store_msixupload(
                        msix_path=invalid,
                        appxsym_path=valid,
                        output_path=root / "output",
                    )
            output_dir = root / "directory"
            output_dir.mkdir()
            with self.assertRaisesRegex(ReleaseContractError, "Unable to create"):
                create_windows_store_msixupload(
                    msix_path=valid,
                    appxsym_path=valid,
                    output_path=output_dir,
                )
            wrong = root / "wrong.msixupload"
            with ZipFile(wrong, "w") as archive:
                archive.writestr("wrong", b"value")
            with self.assertRaisesRegex(ReleaseContractError, "exactly"):
                validate_windows_store_msixupload(
                    msixupload_path=wrong,
                    msix_path=valid,
                    appxsym_path=valid,
                )

    def test_msix_validation_accepts_unsigned_and_explicitly_signed_packages(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            unsigned = root / "unsigned.msix"
            signed = root / "signed.msix"
            self._write_msix(unsigned)
            self._write_msix(signed, signed=True)
            validate_windows_store_msix(
                unsigned,
                package_version=self.package_version,
                arch="x64",
            )
            validate_windows_store_msix(
                signed,
                package_version=self.package_version,
                arch="x64",
                allow_signed=True,
            )
            with self.assertRaisesRegex(ReleaseContractError, "must remain unsigned"):
                validate_windows_store_msix(
                    signed,
                    package_version=self.package_version,
                    arch="x64",
                )

    def test_msix_validation_rejects_invalid_packages(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            invalid = root / "invalid.msix"
            invalid.write_bytes(b"invalid")
            with self.assertRaisesRegex(ReleaseContractError, "Unable to read"):
                validate_windows_store_msix(
                    invalid,
                    package_version=self.package_version,
                    arch="x64",
                )
            cases = (
                ({"python.exe": None}, "missing required runtime", ()),
                (
                    {"data/py/site-packages/orchestrator/__init__.py": None},
                    "missing the bundled backend",
                    (),
                ),
                ({"AppxBlockMap.xml": None}, "package metadata", ()),
                ({"AppxManifest.xml": b"<Package"}, "invalid Appx manifest", ()),
                ({"secret.pfx": b"secret"}, "prohibited release material", ()),
                (
                    {
                        "note.txt": b"-----BEGIN OPENSSH PRIVATE KEY-----\n"
                        b"QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB\n"
                        b"-----END OPENSSH PRIVATE KEY-----\n"
                    },
                    "private-key material",
                    (),
                ),
                ({"note.txt": b"forbidden"}, "forbidden value", ("forbidden",)),
                (
                    {"Assets/StoreLogo.png": self._png(51, 50)},
                    "incorrect dimensions",
                    (),
                ),
                ({"bridge.dll": self._pe(0)}, "missing required mitigations", ()),
            )
            for index, (mutations, message, forbidden) in enumerate(cases):
                with self.subTest(message=message):
                    path = root / f"case-{index}.msix"
                    self._write_msix(path, mutations=mutations)
                    with self.assertRaisesRegex(ReleaseContractError, message):
                        validate_windows_store_msix(
                            path,
                            package_version=self.package_version,
                            arch="x64",
                            forbidden_values=forbidden,
                        )

    def test_build_manifest_write_and_validation(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_root = self._write_package_root(root)
            msix = root / "app.msix"
            appxsym = root / "app.appxsym"
            upload = root / "app.msixupload"
            for path, payload in (
                (msix, b"msix"),
                (appxsym, b"symbols"),
                (upload, b"upload"),
            ):
                path.write_bytes(payload)
            manifest = root / "build.json"
            write_windows_store_build_manifest(
                manifest,
                package_version=self.package_version,
                arch="x64",
                package_root=package_root,
                msix_path=msix,
                appxsym_path=appxsym,
                msixupload_path=upload,
            )
            validate_windows_store_build_manifest(
                manifest,
                arch="x64",
                package_root=package_root,
                msix_path=msix,
                appxsym_path=appxsym,
                msixupload_path=upload,
            )

    def test_build_manifest_validation_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_root = self._write_package_root(root)
            paths = [root / name for name in ("app.msix", "app.appxsym", "app.msixupload")]
            for path in paths:
                path.write_bytes(path.name.encode())
            manifest = root / "build.json"
            write_windows_store_build_manifest(
                manifest,
                package_version=self.package_version,
                arch="x64",
                package_root=package_root,
                msix_path=paths[0],
                appxsym_path=paths[1],
                msixupload_path=paths[2],
            )
            original = json.loads(manifest.read_text(encoding="utf-8"))
            mutations = (
                ("schema", {**original, "schema_version": 1}, "schema"),
                ("identity", {**original, "identity": {}}, "identity"),
                ("distribution", {**original, "distribution": "wrong"}, "distribution"),
                ("payload", {**original, "payload": {}}, "payload digest"),
                ("artifacts", {**original, "artifacts": {}}, "artifact hashes"),
                ("version", {**original, "package_version": 1}, "package version"),
            )
            for label, document, message in mutations:
                with self.subTest(label=label):
                    manifest.write_text(json.dumps(document), encoding="utf-8")
                    with self.assertRaisesRegex(ReleaseContractError, message):
                        validate_windows_store_build_manifest(
                            manifest,
                            arch="x64",
                            package_root=package_root,
                            msix_path=paths[0],
                            appxsym_path=paths[1],
                            msixupload_path=paths[2],
                        )
            manifest.write_text("invalid", encoding="utf-8")
            with self.assertRaisesRegex(ReleaseContractError, "Unable to read"):
                validate_windows_store_build_manifest(
                    manifest,
                    arch="x64",
                    package_root=package_root,
                    msix_path=paths[0],
                    appxsym_path=paths[1],
                    msixupload_path=paths[2],
                )
            write_windows_store_build_manifest(
                manifest,
                package_version=self.package_version,
                arch="x64",
                package_root=package_root,
                msix_path=paths[0],
                appxsym_path=paths[1],
                msixupload_path=paths[2],
            )
            paths[0].unlink()
            with self.assertRaisesRegex(ReleaseContractError, "Unable to read"):
                validate_windows_store_build_manifest(
                    manifest,
                    arch="x64",
                    package_root=package_root,
                    msix_path=paths[0],
                    appxsym_path=paths[1],
                    msixupload_path=paths[2],
                )

    def test_payload_digest_reports_unreadable_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = root / "payload"
            payload.write_bytes(b"value")
            original = Path.read_bytes

            def fail_selected(path: Path) -> bytes:
                if path == payload:
                    raise OSError("denied")
                return original(path)

            with (
                mock.patch.object(Path, "read_bytes", fail_selected),
                self.assertRaisesRegex(ReleaseContractError, "Unable to read"),
            ):
                canonical_windows_store_payload_digest(root)


if __name__ == "__main__":
    unittest.main()
