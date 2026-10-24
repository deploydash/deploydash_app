from __future__ import annotations

import json
import struct
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from zipfile import ZIP_DEFLATED, ZipFile

from orchestrator import release_helpers
from orchestrator.release_helpers import (
    ReleaseContractError,
    _normalized_archive_name,
    _png_dimensions,
    _validate_payload_content,
    _validate_payload_names,
    assert_artifact_exists,
    canonical_windows_store_payload_digest,
    create_windows_store_appxsym,
    create_windows_store_msixupload,
    debian_package_version,
    expected_linux_release_bundle_dir,
    expected_macos_app_store_export_path,
    expected_macos_dmg_path,
    expected_macos_release_dir,
    expected_windows_appxsym_path,
    expected_windows_msi_path,
    expected_windows_msix_path,
    expected_windows_msixupload_path,
    expected_windows_release_bundle_dir,
    expected_windows_store_build_manifest_path,
    flutter_build_args,
    flutter_pubspec_build_metadata,
    is_macho_binary,
    locate_macos_app_bundle,
    macos_dmg_name,
    macos_nested_signing_paths,
    parse_windows_store_version,
    read_last_published_windows_store_version,
    read_pe_dll_characteristics,
    required_windows_signing_paths,
    resolve_build_metadata,
    resolve_dart_defines_arg,
    select_macos_signing_identity,
    snap_package_version,
    validate_linux_release_bundle,
    validate_windows_binary_hardening,
    validate_windows_release_bundle,
    validate_windows_store_appxsym,
    validate_windows_store_build_manifest,
    validate_windows_store_manifest,
    validate_windows_store_msix,
    validate_windows_store_msixupload,
    validate_windows_store_package_root,
    validate_windows_store_version,
    windows_store_artifact_names,
    windows_store_identity,
    windows_store_package_version,
    write_github_env,
    write_windows_store_build_manifest,
)


class TestReleaseHelpers(unittest.TestCase):
    @staticmethod
    def _write_pe(path: Path, dll_characteristics: int) -> None:
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
            dll_characteristics,
        )
        path.write_bytes(payload)

    @staticmethod
    def _png(width: int, height: int) -> bytes:
        return b"\x89PNG\r\n\x1a\n" + b"\0\0\0\rIHDR" + struct.pack(">II", width, height)

    def _write_windows_store_package_root(
        self,
        package_root: Path,
        *,
        package_version: str = "1.2.3.0",
        dll_characteristics: int = 0x4160,
    ) -> None:
        package_root.mkdir(parents=True, exist_ok=True)
        payloads = {
            "AppxManifest.xml": self._windows_store_manifest()
            .replace("1.2.3.0", package_version)
            .encode("utf-8"),
            "deploydash.exe": None,
            "bridge.dll": None,
            "python.exe": b"python",
            "pythonw.exe": b"pythonw",
            "python313.dll": b"python313",
            "DLLs/_socket.pyd": b"socket",
            "sqlite3mc.dll": b"sqlite",
            "data/py/site-packages/orchestrator/__init__.py": b"",
            "Assets/StoreLogo.png": self._png(50, 50),
            "Assets/Square44x44Logo.png": self._png(44, 44),
            "Assets/Square150x150Logo.png": self._png(150, 150),
            "Assets/Wide310x150Logo.png": self._png(310, 150),
        }
        for relative, content in payloads.items():
            path = package_root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            if relative in {"deploydash.exe", "bridge.dll"}:
                self._write_pe(path, dll_characteristics)
            else:
                path.write_bytes(content)

    @staticmethod
    def _write_msix_from_package_root(
        package_root: Path,
        output_path: Path,
        *,
        include_metadata: bool = True,
        include_signature: bool = False,
    ) -> None:
        with ZipFile(output_path, "w", compression=ZIP_DEFLATED) as archive:
            for path in package_root.rglob("*"):
                if path.is_file():
                    archive.write(path, path.relative_to(package_root).as_posix())
            if include_metadata:
                archive.writestr("AppxBlockMap.xml", "<BlockMap />")
                archive.writestr("[Content_Types].xml", "<Types />")
            if include_signature:
                archive.writestr("AppxSignature.p7x", "signature")

    def test_debian_package_version_uses_explicit_build_metadata(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            (app_dir / "pubspec.yaml").write_text(
                "name: deploydash\nversion: 1.0.0+1\n",
                encoding="utf-8",
            )
            self.assertEqual(
                debian_package_version(
                    app_dir=app_dir,
                    build_name="2.3.4",
                    build_number="900001",
                ),
                "2.3.4+900001",
            )

    def test_debian_package_version_falls_back_to_pubspec_metadata(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            (app_dir / "pubspec.yaml").write_text(
                "name: deploydash\nversion: 2.3.4+9\n",
                encoding="utf-8",
            )
            self.assertEqual(
                debian_package_version(
                    app_dir=app_dir,
                    build_name="",
                    build_number="",
                ),
                "2.3.4+9",
            )

    def test_debian_package_version_rejects_invalid_explicit_metadata(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            (app_dir / "pubspec.yaml").write_text(
                "name: deploydash\nversion: 2.3.4+9\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                ReleaseContractError,
                "semantic version",
            ):
                debian_package_version(
                    app_dir=app_dir,
                    build_name="2.3",
                    build_number="10",
                )
            with self.assertRaisesRegex(
                ReleaseContractError,
                "positive integer",
            ):
                debian_package_version(
                    app_dir=app_dir,
                    build_name="2.3.4",
                    build_number="0",
                )

    def test_snap_package_version_uses_pubspec_and_explicit_metadata(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            (app_dir / "pubspec.yaml").write_text(
                "name: deploydash\nversion: 2.3.4+9\n",
                encoding="utf-8",
            )
            self.assertEqual(
                snap_package_version(
                    app_dir=app_dir,
                    build_name="",
                    build_number="",
                ),
                "2.3.4+9",
            )
            self.assertEqual(
                snap_package_version(
                    app_dir=app_dir,
                    build_name="3.4.5",
                    build_number="12",
                ),
                "3.4.5+12",
            )

    def test_snap_package_version_rejects_invalid_or_long_metadata(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            (app_dir / "pubspec.yaml").write_text(
                "name: deploydash\nversion: 1.0.0+1\n",
                encoding="utf-8",
            )
            for build_name, build_number, message in (
                ("1.2", "1", "semantic version"),
                ("1.2.3", "0", "positive integer"),
                (
                    "1234567890.1234567890.1234567890",
                    "1",
                    "must not exceed 32",
                ),
            ):
                with (
                    self.subTest(
                        build_name=build_name,
                        build_number=build_number,
                    ),
                    self.assertRaisesRegex(ReleaseContractError, message),
                ):
                    snap_package_version(
                        app_dir=app_dir,
                        build_name=build_name,
                        build_number=build_number,
                    )

    def test_windows_store_package_version_reserves_revision_zero(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            (app_dir / "pubspec.yaml").write_text(
                "name: deploydash\nversion: 2.3.4+9\n",
                encoding="utf-8",
            )
            self.assertEqual(
                windows_store_package_version(
                    app_dir=app_dir,
                    build_name="",
                ),
                "2.3.4.0",
            )
            self.assertEqual(
                windows_store_package_version(
                    app_dir=app_dir,
                    build_name="3.4.5",
                ),
                "3.4.5.0",
            )

    def test_windows_store_package_version_rejects_invalid_or_large_values(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            (app_dir / "pubspec.yaml").write_text(
                "name: deploydash\nversion: 1.0.0+1\n",
                encoding="utf-8",
            )
            for build_name, message in (
                ("1.2", "semantic version"),
                ("65536.0.0", "between 0 and 65535"),
            ):
                with (
                    self.subTest(build_name=build_name),
                    self.assertRaisesRegex(ReleaseContractError, message),
                ):
                    windows_store_package_version(
                        app_dir=app_dir,
                        build_name=build_name,
                    )

    @staticmethod
    def _windows_store_manifest() -> str:
        return """<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
 xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
 xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities">
 <Identity Name="TidyTechnology.DeployDash"
  Publisher="CN=4DF691A0-E545-4698-A115-C49614B329C6"
  Version="1.2.3.0" ProcessorArchitecture="x64" />
 <Properties><PublisherDisplayName>Tidy Technology</PublisherDisplayName></Properties>
 <Dependencies><TargetDeviceFamily Name="Windows.Desktop"
  MinVersion="10.0.17763.0" /></Dependencies>
 <Applications><Application Executable="deploydash.exe"
  EntryPoint="Windows.FullTrustApplication">
  <Extensions><uap:Extension><uap:Protocol Name="deploydash" /></uap:Extension></Extensions>
 </Application></Applications>
 <Capabilities><Capability Name="internetClient" />
  <Capability Name="privateNetworkClientServer" />
  <rescap:Capability Name="runFullTrust" /></Capabilities>
</Package>
"""

    def test_windows_store_identity_and_manifest_contract(self):
        identity = windows_store_identity(arch="x64")
        self.assertEqual(identity["package_name"], "TidyTechnology.DeployDash")
        self.assertEqual(identity["product_id"], "9P1GK6Z58B9T")
        self.assertEqual(identity["architecture"], "x64")
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "AppxManifest.xml"
            manifest_path.write_text(self._windows_store_manifest(), encoding="utf-8")
            validate_windows_store_manifest(
                manifest_path,
                package_version="1.2.3.0",
                arch="x64",
            )

    def test_windows_store_manifest_rejects_unreadable_or_invalid_xml(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for path in (root / "missing.xml", root / "invalid.xml"):
                if path.name == "invalid.xml":
                    path.write_text("<Package", encoding="utf-8")
                with (
                    self.subTest(path=path.name),
                    self.assertRaisesRegex(
                        ReleaseContractError,
                        "Unable to read Windows Store manifest",
                    ),
                ):
                    validate_windows_store_manifest(
                        path,
                        package_version="1.2.3.0",
                        arch="x64",
                    )

    def test_windows_store_manifest_rejects_each_contract_violation(self):
        valid = self._windows_store_manifest()
        mutations = {
            "package name": valid.replace("TidyTechnology.DeployDash", "Wrong.Package"),
            "publisher": valid.replace("CN=4DF691A0-E545-4698-A115-C49614B329C6", "CN=Wrong"),
            "package version": valid.replace("1.2.3.0", "1.2.4.0"),
            "publisher display name": valid.replace("Tidy Technology", "Wrong Publisher"),
            "Windows 10 minimum version": valid.replace("10.0.17763.0", "10.0.22000.0"),
            "processor architecture": valid.replace('"x64"', '"arm64"'),
            "full-trust entry point": valid.replace(
                "Windows.FullTrustApplication", "Wrong.EntryPoint"
            ),
            "application executable": valid.replace(
                'Executable="deploydash.exe"', 'Executable="wrong.exe"'
            ),
            "OAuth protocol": valid.replace('Name="deploydash"', 'Name="wrong"'),
            "exact capabilities": valid.replace('<rescap:Capability Name="runFullTrust" />', ""),
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "AppxManifest.xml"
            for expected, payload in mutations.items():
                with self.subTest(expected=expected):
                    manifest_path.write_text(payload, encoding="utf-8")
                    with self.assertRaisesRegex(ReleaseContractError, expected):
                        validate_windows_store_manifest(
                            manifest_path,
                            package_version="1.2.3.0",
                            arch="x64",
                        )

    def test_windows_store_manifest_rejects_missing_required_sections(self):
        valid = self._windows_store_manifest()
        mutations = (
            valid.replace(
                valid[
                    valid.index(" <Identity") : valid.index(" />", valid.index(" <Identity")) + 3
                ],
                "",
            ),
            valid.replace(
                " <Properties><PublisherDisplayName>Tidy Technology</PublisherDisplayName></Properties>\n",
                "",
            ),
            valid.replace(
                ' <Dependencies><TargetDeviceFamily Name="Windows.Desktop"\n  MinVersion="10.0.17763.0" /></Dependencies>\n',
                "",
            ),
            valid.replace(
                ' <Applications><Application Executable="deploydash.exe"\n'
                '  EntryPoint="Windows.FullTrustApplication">',
                " <Applications>",
            ).replace(" </Application></Applications>", " </Applications>"),
            valid.replace('<uap:Protocol Name="deploydash" />', ""),
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "AppxManifest.xml"
            for index, payload in enumerate(mutations):
                with self.subTest(index=index):
                    manifest_path.write_text(payload, encoding="utf-8")
                    with self.assertRaises(ReleaseContractError):
                        validate_windows_store_manifest(
                            manifest_path,
                            package_version="1.2.3.0",
                            arch="x64",
                        )

    def test_windows_store_version_and_artifact_helpers_reject_invalid_inputs(self):
        self.assertEqual(
            parse_windows_store_version("1.2.3.0", label="Package"),
            (1, 2, 3, 0),
        )
        for value, message in (
            ("1.2.3", "must use version"),
            ("1.2.3.65536", "between 0 and 65535"),
            ("1.2.3.4", "revision must be zero"),
        ):
            with self.subTest(value=value), self.assertRaisesRegex(ReleaseContractError, message):
                parse_windows_store_version(value, label="Package")

        validate_windows_store_version(
            package_version="1.2.4.0",
            last_published_version="1.2.3.0",
        )
        with self.assertRaisesRegex(ReleaseContractError, "must be newer"):
            validate_windows_store_version(
                package_version="1.2.3.0",
                last_published_version="1.2.3.0",
            )
        self.assertEqual(
            windows_store_artifact_names("1.2.3.0", arch="x64")["msixupload"],
            "DeployDash_1.2.3.0_x64.msixupload",
        )
        with self.assertRaises(ReleaseContractError):
            windows_store_artifact_names("1.2.3.4", arch="x64")

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            published = root / "published-version.txt"
            published.write_text("1.2.3.0\n", encoding="utf-8")
            self.assertEqual(read_last_published_windows_store_version(published), "1.2.3.0")
            for path, message in (
                (root / "missing.txt", "Unable to read"),
                (root / "invalid.txt", "must use version"),
            ):
                if path.name == "invalid.txt":
                    path.write_text("not-a-version", encoding="utf-8")
                with (
                    self.subTest(path=path.name),
                    self.assertRaisesRegex(ReleaseContractError, message),
                ):
                    read_last_published_windows_store_version(path)

    def test_windows_store_payload_name_content_and_digest_contracts(self):
        self.assertEqual(_normalized_archive_name(".\\./payload.txt"), "payload.txt")
        self.assertEqual(
            _validate_payload_names(["./payload.txt", "Assets/logo.png"]),
            {"payload.txt", "Assets/logo.png"},
        )
        for names, message in (
            (["payload.txt", "./payload.txt"], "duplicate paths"),
            (["../payload.txt"], "unsafe path"),
            (["credentials/key.txt"], "prohibited release material"),
            (["symbol.pdb"], "prohibited release material"),
        ):
            with self.subTest(names=names), self.assertRaisesRegex(ReleaseContractError, message):
                _validate_payload_names(names)
        self.assertEqual(
            _validate_payload_names(
                ["symbol.pdb"],
                allowed_prohibited_suffixes=frozenset({".pdb"}),
            ),
            {"symbol.pdb"},
        )

        _validate_payload_content(label="safe.txt", payload=b"safe", forbidden_values=(b"",))
        for payload, forbidden_values, message in (
            (
                b"-----BEGIN PRIVATE KEY-----\n" + b"a" * 32 + b"\n-----END PRIVATE KEY-----",
                (),
                "private-key material",
            ),
            (b"configured secret", (b"secret",), "configured forbidden value"),
        ):
            with (
                self.subTest(message=message),
                self.assertRaisesRegex(ReleaseContractError, message),
            ):
                _validate_payload_content(
                    label="bad.txt",
                    payload=payload,
                    forbidden_values=forbidden_values,
                )
        self.assertEqual(_png_dimensions(self._png(12, 34), label="asset"), (12, 34))
        with self.assertRaisesRegex(ReleaseContractError, "not a valid PNG"):
            _png_dimensions(b"not-a-png", label="asset")

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            with self.assertRaisesRegex(ReleaseContractError, "package root not found"):
                canonical_windows_store_payload_digest(root / "missing")
            empty = root / "empty"
            empty.mkdir()
            with self.assertRaisesRegex(ReleaseContractError, "package root is empty"):
                canonical_windows_store_payload_digest(empty)
            payload = root / "payload"
            payload.mkdir()
            (payload / "one.txt").write_bytes(b"one")
            digest = canonical_windows_store_payload_digest(payload)
            self.assertEqual(digest["file_count"], 1)
            self.assertEqual(digest["total_size"], 3)
            with (
                mock.patch.object(Path, "read_bytes", side_effect=OSError("blocked")),
                self.assertRaisesRegex(
                    ReleaseContractError, "Unable to read Windows Store payload"
                ),
            ):
                canonical_windows_store_payload_digest(payload)
            linked = root / "linked"
            linked.symlink_to(payload / "one.txt")
            with self.assertRaisesRegex(ReleaseContractError, "symbolic link"):
                canonical_windows_store_payload_digest(root)

    def test_windows_store_payload_digest_ignores_makeappx_footprint(self):
        """Slim QA expands the MSIX; MakeAppx footprint must not shift the digest.

        The build manifest digests the source package root. MakeAppx then adds
        AppxBlockMap.xml / [Content_Types].xml (and optionally a signature and
        AppxMetadata/) into the .msix. Expand-Archive of that package must
        still match the manifest payload digest.
        """
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_root = root / "package"
            self._write_windows_store_package_root(package_root)
            digest_from_root = canonical_windows_store_payload_digest(package_root)

            msix_path = root / "app.msix"
            appxsym_path = root / "app.appxsym"
            upload_path = root / "app.msixupload"
            for path in (msix_path, appxsym_path, upload_path):
                path.write_bytes(path.name.encode())
            manifest_path = root / "build-manifest.json"
            write_windows_store_build_manifest(
                manifest_path,
                package_version="1.2.3.0",
                arch="x64",
                package_root=package_root,
                msix_path=msix_path,
                appxsym_path=appxsym_path,
                msixupload_path=upload_path,
            )

            (package_root / "AppxBlockMap.xml").write_bytes(b"<BlockMap />")
            (package_root / "[Content_Types].xml").write_bytes(b"<Types />")
            (package_root / "AppxSignature.p7x").write_bytes(b"signature")
            metadata_dir = package_root / "AppxMetadata"
            metadata_dir.mkdir()
            (metadata_dir / "CodeIntegrity.cat").write_bytes(b"catalog")

            digest_from_unpacked = canonical_windows_store_payload_digest(package_root)
            self.assertEqual(digest_from_root, digest_from_unpacked)
            validate_windows_store_build_manifest(
                manifest_path,
                arch="x64",
                package_root=package_root,
                msix_path=msix_path,
                appxsym_path=appxsym_path,
                msixupload_path=upload_path,
            )

            (package_root / "python.exe").write_bytes(b"tampered-python")
            with self.assertRaisesRegex(ReleaseContractError, "payload digest does not match"):
                validate_windows_store_build_manifest(
                    manifest_path,
                    arch="x64",
                    package_root=package_root,
                    msix_path=msix_path,
                    appxsym_path=appxsym_path,
                    msixupload_path=upload_path,
                )

            footprint_only = root / "footprint-only"
            footprint_only.mkdir()
            (footprint_only / "AppxBlockMap.xml").write_bytes(b"<BlockMap />")
            (footprint_only / "[Content_Types].xml").write_bytes(b"<Types />")
            with self.assertRaisesRegex(ReleaseContractError, "package root is empty"):
                canonical_windows_store_payload_digest(footprint_only)

    def test_windows_store_package_root_validates_payload_contents(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_root = root / "package"
            self._write_windows_store_package_root(package_root)
            digest = validate_windows_store_package_root(
                package_root,
                package_version="1.2.3.0",
                arch="x64",
            )
            self.assertEqual(digest["file_count"], 13)

            incomplete = root / "incomplete"
            incomplete.mkdir()
            (incomplete / "AppxManifest.xml").write_text(
                self._windows_store_manifest(),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ReleaseContractError, "missing required runtime"):
                validate_windows_store_package_root(
                    incomplete,
                    package_version="1.2.3.0",
                    arch="x64",
                )

            no_backend = root / "no-backend"
            self._write_windows_store_package_root(no_backend)
            (no_backend / "data" / "py" / "site-packages" / "orchestrator" / "__init__.py").unlink()
            with self.assertRaisesRegex(ReleaseContractError, "bundled backend package"):
                validate_windows_store_package_root(
                    no_backend,
                    package_version="1.2.3.0",
                    arch="x64",
                )

            bad_asset = root / "bad-asset"
            self._write_windows_store_package_root(bad_asset)
            (bad_asset / "Assets" / "StoreLogo.png").write_bytes(self._png(1, 1))
            with self.assertRaisesRegex(ReleaseContractError, "incorrect dimensions"):
                validate_windows_store_package_root(
                    bad_asset,
                    package_version="1.2.3.0",
                    arch="x64",
                )

            secret = root / "secret"
            self._write_windows_store_package_root(secret)
            (secret / "payload.txt").write_text("configured secret", encoding="utf-8")
            with self.assertRaisesRegex(ReleaseContractError, "configured forbidden value"):
                validate_windows_store_package_root(
                    secret,
                    package_version="1.2.3.0",
                    arch="x64",
                    forbidden_values=("secret",),
                )

            weak_binaries = root / "weak-binaries"
            self._write_windows_store_package_root(weak_binaries, dll_characteristics=0)
            with self.assertRaisesRegex(ReleaseContractError, "missing required mitigations"):
                validate_windows_store_package_root(
                    weak_binaries,
                    package_version="1.2.3.0",
                    arch="x64",
                )

    def test_windows_store_symbol_and_upload_archives_validate_contents(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            build_dir = root / "build"
            (build_dir / "nested").mkdir(parents=True)
            (build_dir / "deploydash.pdb").write_bytes(b"runner symbols")
            (build_dir / "nested" / "bridge.pdb").write_bytes(b"bridge symbols")
            appxsym_path = root / "artifacts" / "symbols.appxsym"
            create_windows_store_appxsym(build_dir, appxsym_path)
            validate_windows_store_appxsym(appxsym_path)

            with self.assertRaisesRegex(ReleaseContractError, "bundle not found"):
                create_windows_store_appxsym(root / "missing", root / "missing.appxsym")
            missing_symbol_dir = root / "missing-symbol"
            missing_symbol_dir.mkdir()
            (missing_symbol_dir / "bridge.pdb").write_bytes(b"bridge")
            with self.assertRaisesRegex(ReleaseContractError, "missing first-party PDB"):
                create_windows_store_appxsym(
                    missing_symbol_dir,
                    root / "missing-symbol.appxsym",
                )

            invalid_archive = root / "invalid.appxsym"
            invalid_archive.write_bytes(b"not a zip")
            with self.assertRaisesRegex(ReleaseContractError, "Unable to read"):
                validate_windows_store_appxsym(invalid_archive)
            with ZipFile(invalid_archive, "w", compression=ZIP_DEFLATED) as archive:
                archive.writestr("wrong.txt", "wrong")
            with self.assertRaisesRegex(ReleaseContractError, "only PDB"):
                validate_windows_store_appxsym(invalid_archive)
            with ZipFile(invalid_archive, "w", compression=ZIP_DEFLATED) as archive:
                archive.writestr("deploydash.pdb", "runner")
            with self.assertRaisesRegex(ReleaseContractError, "exactly the first-party"):
                validate_windows_store_appxsym(invalid_archive)
            with ZipFile(invalid_archive, "w", compression=ZIP_DEFLATED) as archive:
                archive.writestr("deploydash.pdb", "")
                archive.writestr("bridge.pdb", "bridge")
            with self.assertRaisesRegex(ReleaseContractError, "empty PDB"):
                validate_windows_store_appxsym(invalid_archive)
            with (
                mock.patch.object(release_helpers, "ZipFile", side_effect=OSError("blocked")),
                self.assertRaisesRegex(ReleaseContractError, "Unable to create"),
            ):
                create_windows_store_appxsym(build_dir, root / "blocked.appxsym")

            msix_path = root / "package.msix"
            msix_path.write_bytes(b"MSIX")
            upload_path = root / "package.msixupload"
            create_windows_store_msixupload(
                msix_path=msix_path,
                appxsym_path=appxsym_path,
                output_path=upload_path,
            )
            validate_windows_store_msixupload(
                msixupload_path=upload_path,
                msix_path=msix_path,
                appxsym_path=appxsym_path,
            )
            with self.assertRaisesRegex(ReleaseContractError, "missing or empty"):
                create_windows_store_msixupload(
                    msix_path=root / "missing.msix",
                    appxsym_path=appxsym_path,
                    output_path=root / "missing.msixupload",
                )
            with ZipFile(upload_path, "w", compression=ZIP_DEFLATED) as archive:
                archive.writestr("wrong.msix", b"wrong")
            with self.assertRaisesRegex(ReleaseContractError, "exactly the MSIX"):
                validate_windows_store_msixupload(
                    msixupload_path=upload_path,
                    msix_path=msix_path,
                    appxsym_path=appxsym_path,
                )
            with ZipFile(upload_path, "w", compression=ZIP_DEFLATED) as archive:
                archive.writestr(msix_path.name, b"wrong")
                archive.writestr(appxsym_path.name, appxsym_path.read_bytes())
            with self.assertRaisesRegex(ReleaseContractError, "content does not match"):
                validate_windows_store_msixupload(
                    msixupload_path=upload_path,
                    msix_path=msix_path,
                    appxsym_path=appxsym_path,
                )
            with (
                mock.patch.object(release_helpers, "ZipFile", side_effect=OSError("blocked")),
                self.assertRaisesRegex(ReleaseContractError, "Unable to create"),
            ):
                create_windows_store_msixupload(
                    msix_path=msix_path,
                    appxsym_path=appxsym_path,
                    output_path=root / "blocked.msixupload",
                )

    def test_windows_store_msix_and_build_manifest_contracts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_root = root / "package"
            self._write_windows_store_package_root(package_root)
            msix_path = root / "package.msix"
            self._write_msix_from_package_root(package_root, msix_path)
            validate_windows_store_msix(
                msix_path,
                package_version="1.2.3.0",
                arch="x64",
            )

            missing_payload = root / "missing-payload.msix"
            with ZipFile(missing_payload, "w", compression=ZIP_DEFLATED):
                pass
            with self.assertRaisesRegex(ReleaseContractError, "missing required runtime"):
                validate_windows_store_msix(
                    missing_payload,
                    package_version="1.2.3.0",
                    arch="x64",
                )

            no_metadata = root / "no-metadata.msix"
            self._write_msix_from_package_root(
                package_root,
                no_metadata,
                include_metadata=False,
            )
            with self.assertRaisesRegex(ReleaseContractError, "required Appx package metadata"):
                validate_windows_store_msix(
                    no_metadata,
                    package_version="1.2.3.0",
                    arch="x64",
                )

            no_backend_root = root / "no-backend-package"
            self._write_windows_store_package_root(no_backend_root)
            (
                no_backend_root / "data" / "py" / "site-packages" / "orchestrator" / "__init__.py"
            ).unlink()
            no_backend = root / "no-backend.msix"
            self._write_msix_from_package_root(no_backend_root, no_backend)
            with self.assertRaisesRegex(ReleaseContractError, "bundled backend package"):
                validate_windows_store_msix(
                    no_backend,
                    package_version="1.2.3.0",
                    arch="x64",
                )

            invalid_manifest_root = root / "invalid-manifest-package"
            self._write_windows_store_package_root(invalid_manifest_root)
            (invalid_manifest_root / "AppxManifest.xml").write_text("<Package", encoding="utf-8")
            invalid_manifest = root / "invalid-manifest.msix"
            self._write_msix_from_package_root(invalid_manifest_root, invalid_manifest)
            with self.assertRaisesRegex(ReleaseContractError, "invalid Appx manifest"):
                validate_windows_store_msix(
                    invalid_manifest,
                    package_version="1.2.3.0",
                    arch="x64",
                )

            signed = root / "signed.msix"
            self._write_msix_from_package_root(
                package_root,
                signed,
                include_signature=True,
            )
            with self.assertRaisesRegex(ReleaseContractError, "must remain unsigned"):
                validate_windows_store_msix(
                    signed,
                    package_version="1.2.3.0",
                    arch="x64",
                )
            validate_windows_store_msix(
                signed,
                package_version="1.2.3.0",
                arch="x64",
                allow_signed=True,
            )

            bad_asset_root = root / "bad-asset-package"
            self._write_windows_store_package_root(bad_asset_root)
            (bad_asset_root / "Assets" / "StoreLogo.png").write_bytes(self._png(1, 1))
            bad_asset = root / "bad-asset.msix"
            self._write_msix_from_package_root(bad_asset_root, bad_asset)
            with self.assertRaisesRegex(ReleaseContractError, "incorrect dimensions"):
                validate_windows_store_msix(
                    bad_asset,
                    package_version="1.2.3.0",
                    arch="x64",
                )

            weak_root = root / "weak-package"
            self._write_windows_store_package_root(weak_root, dll_characteristics=0)
            weak_msix = root / "weak.msix"
            self._write_msix_from_package_root(weak_root, weak_msix)
            with self.assertRaisesRegex(ReleaseContractError, "missing required mitigations"):
                validate_windows_store_msix(
                    weak_msix,
                    package_version="1.2.3.0",
                    arch="x64",
                )

            appxsym_path = root / "symbols.appxsym"
            appxsym_path.write_bytes(b"symbols")
            upload_path = root / "package.msixupload"
            upload_path.write_bytes(b"upload")
            build_manifest_path = root / "build-manifest.json"
            write_windows_store_build_manifest(
                build_manifest_path,
                package_version="1.2.3.0",
                arch="x64",
                package_root=package_root,
                msix_path=msix_path,
                appxsym_path=appxsym_path,
                msixupload_path=upload_path,
            )
            validate_windows_store_build_manifest(
                build_manifest_path,
                arch="x64",
                package_root=package_root,
                msix_path=msix_path,
                appxsym_path=appxsym_path,
                msixupload_path=upload_path,
            )
            valid_manifest = json.loads(build_manifest_path.read_text(encoding="utf-8"))
            mutations = {
                "schema": ("schema_version", 1, "schema is invalid"),
                "identity": ("identity", {}, "identity is invalid"),
                "distribution": ("distribution", "other", "distribution is invalid"),
                "payload": ("payload", {}, "payload digest does not match"),
                "artifacts": ("artifacts", {}, "artifact hashes do not match"),
                "version": ("package_version", 1, "package version is invalid"),
            }
            for label, (field, value, message) in mutations.items():
                with self.subTest(label=label):
                    payload = {**valid_manifest, field: value}
                    build_manifest_path.write_text(json.dumps(payload), encoding="utf-8")
                    with self.assertRaisesRegex(ReleaseContractError, message):
                        validate_windows_store_build_manifest(
                            build_manifest_path,
                            arch="x64",
                            package_root=package_root,
                            msix_path=msix_path,
                            appxsym_path=appxsym_path,
                            msixupload_path=upload_path,
                        )
            build_manifest_path.write_text("not-json", encoding="utf-8")
            with self.assertRaisesRegex(ReleaseContractError, "Unable to read"):
                validate_windows_store_build_manifest(
                    build_manifest_path,
                    arch="x64",
                    package_root=package_root,
                    msix_path=msix_path,
                    appxsym_path=appxsym_path,
                    msixupload_path=upload_path,
                )
            write_windows_store_build_manifest(
                build_manifest_path,
                package_version="1.2.3.0",
                arch="x64",
                package_root=package_root,
                msix_path=msix_path,
                appxsym_path=appxsym_path,
                msixupload_path=upload_path,
            )
            with self.assertRaisesRegex(
                ReleaseContractError, "Unable to read Windows Store msix artifact"
            ):
                validate_windows_store_build_manifest(
                    build_manifest_path,
                    arch="x64",
                    package_root=package_root,
                    msix_path=root / "missing.msix",
                    appxsym_path=appxsym_path,
                    msixupload_path=upload_path,
                )

    def test_windows_store_build_manifest_hashes_artifacts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = [root / name for name in ("app.msix", "app.appxsym", "app.msixupload")]
            for index, path in enumerate(paths, start=1):
                path.write_bytes(bytes([index]) * index)
            output_path = root / "build-manifest.json"
            package_root = root / "package"
            package_root.mkdir()
            (package_root / "payload").write_bytes(b"payload")
            write_windows_store_build_manifest(
                output_path,
                package_version="1.2.3.0",
                arch="x64",
                package_root=package_root,
                msix_path=paths[0],
                appxsym_path=paths[1],
                msixupload_path=paths[2],
            )
            payload = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(payload["schema_version"], 2)
            self.assertEqual(payload["package_version"], "1.2.3.0")
            self.assertEqual(payload["distribution"], "windows_store")
            self.assertEqual(payload["artifacts"]["appxsym"]["size"], 2)
            self.assertEqual(len(payload["artifacts"]["msix"]["sha256"]), 64)

    def test_windows_store_build_manifest_rejects_missing_or_empty_artifacts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            valid = root / "valid"
            valid.write_bytes(b"valid")
            missing = root / "missing"
            empty = root / "empty"
            empty.touch()
            for invalid, message in (
                (missing, "Unable to read"),
                (empty, "artifact is empty"),
            ):
                with (
                    self.subTest(invalid=invalid.name),
                    self.assertRaisesRegex(ReleaseContractError, message),
                ):
                    write_windows_store_build_manifest(
                        root / "output.json",
                        package_version="1.2.3.0",
                        arch="x64",
                        package_root=root,
                        msix_path=invalid,
                        appxsym_path=valid,
                        msixupload_path=valid,
                    )

    def test_windows_store_build_manifest_reports_output_failure(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            artifact = root / "artifact"
            artifact.write_bytes(b"valid")
            output_path = root / "output-directory"
            output_path.mkdir()
            with self.assertRaisesRegex(ReleaseContractError, "Unable to write"):
                write_windows_store_build_manifest(
                    output_path,
                    package_version="1.2.3.0",
                    arch="x64",
                    package_root=root,
                    msix_path=artifact,
                    appxsym_path=artifact,
                    msixupload_path=artifact,
                )

    @staticmethod
    def _write_macho(path: Path, magic: bytes = b"\xcf\xfa\xed\xfe") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(magic + b"deploydash")

    def test_resolve_build_metadata_prefers_explicit_inputs(self):
        result = resolve_build_metadata(
            input_build_name=" 1.2.3-custom ",
            input_build_number=" 44 ",
            github_run_number="7",
            github_ref_type="tag",
            github_ref_name="v9.9.9",
        )
        self.assertEqual(
            result,
            {
                "DEPLOYDASH_BUILD_NAME": "1.2.3-custom",
                "DEPLOYDASH_BUILD_NUMBER": "44",
            },
        )

    def test_flutter_pubspec_build_metadata_reads_release_version(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            (app_dir / "pubspec.yaml").write_text(
                "name: deploydash\nversion: 1.2.3+45 # release\n",
                encoding="utf-8",
            )
            self.assertEqual(
                flutter_pubspec_build_metadata(app_dir),
                ("1.2.3", "45"),
            )

    def test_flutter_pubspec_build_metadata_rejects_missing_pubspec(self):
        with (
            tempfile.TemporaryDirectory() as temp_dir,
            self.assertRaisesRegex(
                ReleaseContractError,
                "Unable to read Flutter pubspec",
            ),
        ):
            flutter_pubspec_build_metadata(Path(temp_dir))

    def test_flutter_pubspec_build_metadata_rejects_invalid_version(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            (app_dir / "pubspec.yaml").write_text(
                "name: deploydash\nversion: latest\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                ReleaseContractError,
                "version: X.Y.Z\\+N",
            ):
                flutter_pubspec_build_metadata(app_dir)

    def test_resolve_build_metadata_uses_tag_semver_and_run_number_fallback(self):
        result = resolve_build_metadata(
            input_build_name="",
            input_build_number="",
            github_run_number="6",
            github_ref_type="tag",
            github_ref_name="v0.0.7",
        )
        self.assertEqual(
            result,
            {
                "DEPLOYDASH_BUILD_NAME": "0.0.7",
                "DEPLOYDASH_BUILD_NUMBER": "6",
            },
        )

    def test_resolve_build_metadata_ignores_non_semver_tag(self):
        result = resolve_build_metadata(
            input_build_name="",
            input_build_number="",
            github_run_number="12",
            github_ref_type="tag",
            github_ref_name="release-candidate",
        )
        self.assertEqual(result, {"DEPLOYDASH_BUILD_NUMBER": "12"})

    def test_resolve_build_metadata_can_return_empty_result(self):
        result = resolve_build_metadata(
            input_build_name="",
            input_build_number="",
            github_run_number="",
            github_ref_type="branch",
            github_ref_name="main",
        )
        self.assertEqual(result, {})

    def test_write_github_env_appends_lines(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            env_file = Path(temp_dir) / "github.env"
            write_github_env(
                env_file,
                {
                    "DEPLOYDASH_BUILD_NAME": "0.0.7",
                    "DEPLOYDASH_BUILD_NUMBER": "6",
                },
            )
            self.assertEqual(
                env_file.read_text(encoding="utf-8"),
                "DEPLOYDASH_BUILD_NAME=0.0.7\nDEPLOYDASH_BUILD_NUMBER=6\n",
            )

    def test_resolve_dart_defines_arg_prefers_explicit_existing_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            explicit = app_dir / "ci.json"
            explicit.write_text("{}", encoding="utf-8")
            result = resolve_dart_defines_arg(
                app_dir=app_dir,
                dart_defines_file="ci.json",
            )
            self.assertEqual(result, "--dart-define-from-file=ci.json")

    def test_resolve_dart_defines_arg_accepts_absolute_existing_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            explicit = app_dir / "ci.json"
            explicit.write_text("{}", encoding="utf-8")
            result = resolve_dart_defines_arg(
                app_dir=app_dir,
                dart_defines_file=str(explicit),
            )
            self.assertEqual(
                result,
                f"--dart-define-from-file={explicit}",
            )

    def test_resolve_dart_defines_arg_uses_local_default_when_present(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            config_dir = app_dir / "config"
            config_dir.mkdir()
            (config_dir / "dart-defines.local.json").write_text(
                "{}",
                encoding="utf-8",
            )
            result = resolve_dart_defines_arg(
                app_dir=app_dir,
                dart_defines_file="",
            )
            self.assertEqual(
                result,
                "--dart-define-from-file=config/dart-defines.local.json",
            )

    def test_resolve_dart_defines_arg_raises_for_missing_explicit_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            with self.assertRaisesRegex(
                ReleaseContractError,
                "DEPLOYDASH_DART_DEFINES_FILE does not exist",
            ):
                resolve_dart_defines_arg(
                    app_dir=app_dir,
                    dart_defines_file="missing.json",
                )

    def test_flutter_build_args_collects_release_flags(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            config_dir = app_dir / "config"
            config_dir.mkdir()
            (config_dir / "dart-defines.local.json").write_text(
                "{}",
                encoding="utf-8",
            )
            result = flutter_build_args(
                app_dir=app_dir,
                dart_defines_file="",
                build_name="0.0.7",
                build_number="6",
            )
            self.assertEqual(
                result,
                [
                    "--dart-define-from-file=config/dart-defines.local.json",
                    "--build-name=0.0.7",
                    "--dart-define=DEPLOYDASH_RELEASE_VERSION=0.0.7",
                    "--build-number=6",
                    "--dart-define=DEPLOYDASH_RELEASE_BUILD=6",
                ],
            )

    def test_flutter_build_args_can_return_no_optional_flags(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            result = flutter_build_args(
                app_dir=app_dir,
                dart_defines_file="",
                build_name="",
                build_number="",
            )
            self.assertEqual(result, [])

    def test_flutter_build_args_defaults_release_metadata_to_pubspec(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            (app_dir / "pubspec.yaml").write_text(
                "name: deploydash\nversion: 2.3.4+9\n",
                encoding="utf-8",
            )
            result = flutter_build_args(
                app_dir=app_dir,
                dart_defines_file="",
                build_name="",
                build_number="",
                default_to_pubspec=True,
            )
            self.assertEqual(
                result,
                [
                    "--build-name=2.3.4",
                    "--dart-define=DEPLOYDASH_RELEASE_VERSION=2.3.4",
                    "--build-number=9",
                    "--dart-define=DEPLOYDASH_RELEASE_BUILD=9",
                ],
            )

    def test_flutter_build_args_keeps_partial_release_override(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_dir = Path(temp_dir)
            (app_dir / "pubspec.yaml").write_text(
                "name: deploydash\nversion: 2.3.4+9\n",
                encoding="utf-8",
            )
            result = flutter_build_args(
                app_dir=app_dir,
                dart_defines_file="",
                build_name="3.0.0",
                build_number="",
                default_to_pubspec=True,
            )
            self.assertEqual(
                result,
                [
                    "--build-name=3.0.0",
                    "--dart-define=DEPLOYDASH_RELEASE_VERSION=3.0.0",
                    "--build-number=9",
                    "--dart-define=DEPLOYDASH_RELEASE_BUILD=9",
                ],
            )

    def test_expected_paths_match_release_contract(self):
        app_dir = Path("/tmp/deploydash/ui")
        self.assertEqual(
            expected_linux_release_bundle_dir(app_dir),
            app_dir / "build" / "linux" / "x64" / "release" / "bundle",
        )
        self.assertEqual(
            expected_windows_release_bundle_dir(app_dir),
            app_dir / "build" / "windows" / "x64" / "runner" / "Release",
        )
        self.assertEqual(
            expected_windows_msi_path(app_dir),
            app_dir / "build" / "windows" / "installer" / "DeployDash.msi",
        )
        self.assertEqual(
            expected_windows_msix_path(app_dir, "3.2.1.0", "x64"),
            app_dir / "build" / "windows" / "installer" / "DeployDash_3.2.1.0_x64.msix",
        )
        self.assertEqual(
            expected_windows_appxsym_path(app_dir, "3.2.1.0", "x64"),
            app_dir / "build" / "windows" / "installer" / "DeployDash_3.2.1.0_x64.appxsym",
        )
        self.assertEqual(
            expected_windows_msixupload_path(app_dir, "3.2.1.0", "x64"),
            app_dir / "build" / "windows" / "installer" / "DeployDash_3.2.1.0_x64.msixupload",
        )
        self.assertEqual(
            expected_windows_msix_path(app_dir, "3.2.1.0", "arm64"),
            app_dir / "build" / "windows" / "installer" / "DeployDash_3.2.1.0_arm64.msix",
        )
        self.assertEqual(
            expected_windows_store_build_manifest_path(app_dir, "3.2.1.0", "x64"),
            app_dir
            / "build"
            / "windows"
            / "installer"
            / "DeployDash_3.2.1.0_x64.build-manifest.json",
        )
        self.assertEqual(
            expected_macos_release_dir(app_dir),
            app_dir / "build" / "macos" / "Build" / "Products" / "Release",
        )
        self.assertEqual(
            expected_macos_dmg_path(app_dir),
            app_dir / "build" / "macos" / "distribution" / "DeployDash.dmg",
        )
        self.assertEqual(
            expected_macos_dmg_path(app_dir, build_name="1.0.0", arch="arm64"),
            app_dir / "build" / "macos" / "distribution" / "DeployDash-v1.0.0-arm64.dmg",
        )
        self.assertEqual(
            expected_macos_dmg_path(app_dir, build_name="1.0.0", arch="x86_64"),
            app_dir / "build" / "macos" / "distribution" / "DeployDash-v1.0.0-x64.dmg",
        )
        self.assertEqual(
            expected_macos_app_store_export_path(app_dir),
            app_dir / "build" / "macos" / "app_store" / "export",
        )

    def test_is_macho_binary_accepts_thin_and_fat_headers(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "binary"
            for magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
                self._write_macho(path, magic)
                self.assertTrue(is_macho_binary(path))
            path.write_bytes(b"not-mach-o")
            self.assertFalse(is_macho_binary(path))

    def test_is_macho_binary_reports_unreadable_path(self):
        with self.assertRaisesRegex(ReleaseContractError, "Unable to inspect macOS code"):
            is_macho_binary(Path("/definitely/missing/macos-code"))

    def test_macos_nested_signing_paths_includes_framework_executables(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_bundle = Path(temp_dir) / "Deploy Dash.app"
            frameworks = app_bundle / "Contents" / "Frameworks"
            plugin = frameworks / "device_info_plus.framework"
            plugin_binary = plugin / "Versions" / "A" / "device_info_plus"
            sparkle_xpc = (
                frameworks
                / "Sparkle.framework"
                / "Versions"
                / "B"
                / "XPCServices"
                / "Installer.xpc"
            )
            sparkle_xpc_binary = sparkle_xpc / "Contents" / "MacOS" / "Installer"
            python_extension = (
                app_bundle
                / "Contents"
                / "Resources"
                / "data"
                / "py"
                / "site-packages"
                / "cryptography.so"
            )
            self._write_macho(plugin_binary)
            self._write_macho(sparkle_xpc_binary)
            self._write_macho(python_extension)
            (frameworks / "not-code.txt").write_text("text", encoding="utf-8")
            (plugin / "Versions" / "Current").symlink_to("A")

            signing_paths = macos_nested_signing_paths(app_bundle)
            self.assertIn(python_extension, signing_paths)
            self.assertIn(plugin_binary, signing_paths)
            self.assertIn(sparkle_xpc_binary, signing_paths)
            self.assertLess(signing_paths.index(sparkle_xpc), signing_paths.index(plugin))
            self.assertEqual(signing_paths[-1], plugin)

    def test_macos_nested_signing_paths_handles_absent_optional_roots(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app_bundle = Path(temp_dir) / "Deploy Dash.app"
            app_bundle.mkdir()
            self.assertEqual(macos_nested_signing_paths(app_bundle), [])

    def test_macos_nested_signing_paths_requires_app_bundle(self):
        with self.assertRaisesRegex(ReleaseContractError, "macOS app bundle not found"):
            macos_nested_signing_paths(Path("/definitely/missing/Deploy Dash.app"))

    def test_select_macos_signing_identity_prefers_apple_development(self):
        listing = """
  1) 4EE60348 "Developer ID Application: Deploy Dash Ltd (TEAM000002)"
  2) BB07B75B "Apple Development: developer@example.com (TEAM000001)"
     2 valid identities found
"""
        self.assertEqual(
            select_macos_signing_identity(listing),
            "Apple Development: developer@example.com (TEAM000001)",
        )

    def test_select_macos_signing_identity_falls_back_to_developer_id(self):
        listing = '  1) 4EE60348 "Developer ID Application: Deploy Dash Ltd (TEAM000002)"\n'
        self.assertEqual(
            select_macos_signing_identity(listing),
            "Developer ID Application: Deploy Dash Ltd (TEAM000002)",
        )

    def test_select_macos_signing_identity_rejects_unsuitable_listing(self):
        listing = '  1) 4EE60348 "Apple Distribution: Deploy Dash Ltd"\n'
        with self.assertRaisesRegex(
            ReleaseContractError,
            "No suitable macOS code-signing identity",
        ):
            select_macos_signing_identity(listing)

    def test_validate_windows_release_bundle_success(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            (build_dir / "data" / "py" / "site-packages" / "orchestrator").mkdir(parents=True)
            (build_dir / "deploydash.exe").write_text("", encoding="utf-8")
            (build_dir / "bridge.dll").write_text("", encoding="utf-8")
            (build_dir / "python.exe").write_text("", encoding="utf-8")
            (build_dir / "pythonw.exe").write_text("", encoding="utf-8")
            (build_dir / "python313.dll").write_text("", encoding="utf-8")
            (build_dir / "DLLs").mkdir()
            (build_dir / "DLLs" / "_socket.pyd").write_text("", encoding="utf-8")
            (build_dir / "sqlite3mc.dll").write_text("", encoding="utf-8")
            validate_windows_release_bundle(build_dir)

    def test_validate_windows_release_bundle_rejects_unused_tk_runtime(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            (build_dir / "data" / "py" / "site-packages" / "orchestrator").mkdir(parents=True)
            for filename in [
                "deploydash.exe",
                "bridge.dll",
                "python.exe",
                "pythonw.exe",
                "python313.dll",
                "sqlite3mc.dll",
            ]:
                (build_dir / filename).write_text("", encoding="utf-8")
            (build_dir / "DLLs").mkdir()
            (build_dir / "DLLs" / "_socket.pyd").write_text("", encoding="utf-8")
            (build_dir / "DLLs" / "tcl86t.dll").write_text("", encoding="utf-8")

            with self.assertRaisesRegex(
                ReleaseContractError,
                "Unused Tcl/Tk runtime artifacts",
            ):
                validate_windows_release_bundle(build_dir)

    def test_required_windows_signing_paths_are_explicit(self):
        build_dir = Path("C:/DeployDash")
        self.assertEqual(
            required_windows_signing_paths(build_dir),
            [
                build_dir / "deploydash.exe",
                build_dir / "bridge.dll",
                build_dir / "python.exe",
                build_dir / "pythonw.exe",
                build_dir / "python313.dll",
                build_dir / "sqlite3mc.dll",
            ],
        )

    def test_validate_windows_binary_hardening_accepts_required_flags(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            flags = 0x0020 | 0x0040 | 0x0100 | 0x4000
            self._write_pe(build_dir / "deploydash.exe", flags)
            self._write_pe(build_dir / "bridge.dll", flags)

            validate_windows_binary_hardening(build_dir)
            self.assertEqual(
                read_pe_dll_characteristics(build_dir / "deploydash.exe"),
                flags,
            )

    def test_validate_windows_binary_hardening_reports_missing_flags(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            self._write_pe(build_dir / "deploydash.exe", 0)
            self._write_pe(build_dir / "bridge.dll", 0x4160)
            with self.assertRaisesRegex(
                ReleaseContractError,
                "high-entropy VA, dynamic base, NX compatible, control-flow guard",
            ):
                validate_windows_binary_hardening(build_dir)

    def test_read_pe_dll_characteristics_rejects_unreadable_file(self):
        with self.assertRaisesRegex(
            ReleaseContractError,
            "Unable to read Windows binary",
        ):
            read_pe_dll_characteristics(Path("/definitely/missing.exe"))

    def test_read_pe_dll_characteristics_rejects_invalid_dos_header(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "invalid.exe"
            path.write_bytes(b"not a PE")
            with self.assertRaisesRegex(ReleaseContractError, "Invalid Windows PE"):
                read_pe_dll_characteristics(path)

    def test_read_pe_dll_characteristics_rejects_invalid_pe_header(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "invalid.exe"
            payload = bytearray(128)
            payload[:2] = b"MZ"
            struct.pack_into("<I", payload, 0x3C, 120)
            path.write_bytes(payload)
            with self.assertRaisesRegex(ReleaseContractError, "Invalid Windows PE header"):
                read_pe_dll_characteristics(path)

    def test_read_pe_dll_characteristics_rejects_optional_header_magic(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "invalid.exe"
            self._write_pe(path, 0x4160)
            payload = bytearray(path.read_bytes())
            struct.pack_into("<H", payload, 0x80 + 24, 0x999)
            path.write_bytes(payload)
            with self.assertRaisesRegex(
                ReleaseContractError,
                "Unsupported Windows optional-header format",
            ):
                read_pe_dll_characteristics(path)

    def test_read_pe_dll_characteristics_rejects_truncated_optional_header(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "invalid.exe"
            payload = bytearray(0x80 + 24 + 2)
            payload[:2] = b"MZ"
            struct.pack_into("<I", payload, 0x3C, 0x80)
            payload[0x80:0x84] = b"PE\0\0"
            struct.pack_into("<H", payload, 0x80 + 24, 0x20B)
            path.write_bytes(payload)
            with self.assertRaisesRegex(
                ReleaseContractError,
                "Truncated Windows optional header",
            ):
                read_pe_dll_characteristics(path)

    def test_validate_windows_release_bundle_detects_missing_dir(self):
        with self.assertRaisesRegex(
            ReleaseContractError,
            "Windows release bundle not found",
        ):
            validate_windows_release_bundle(Path("/definitely/missing"))

    def test_validate_windows_release_bundle_detects_missing_runtime_artifact(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            with self.assertRaisesRegex(
                ReleaseContractError,
                "Required runtime artifact missing from Windows bundle",
            ):
                validate_windows_release_bundle(build_dir)

    def test_validate_windows_release_bundle_requires_encrypted_sqlite_library(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            (build_dir / "data" / "py" / "site-packages" / "orchestrator").mkdir(parents=True)
            (build_dir / "deploydash.exe").write_text("", encoding="utf-8")
            (build_dir / "bridge.dll").write_text("", encoding="utf-8")
            (build_dir / "python.exe").write_text("", encoding="utf-8")
            (build_dir / "pythonw.exe").write_text("", encoding="utf-8")
            (build_dir / "python313.dll").write_text("", encoding="utf-8")
            (build_dir / "DLLs").mkdir()
            (build_dir / "DLLs" / "_socket.pyd").write_text("", encoding="utf-8")

            with self.assertRaisesRegex(
                ReleaseContractError,
                r"sqlite3mc\.dll",
            ):
                validate_windows_release_bundle(build_dir)

    def test_validate_windows_release_bundle_requires_worker_executable(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            (build_dir / "data" / "py" / "site-packages" / "orchestrator").mkdir(parents=True)
            (build_dir / "deploydash.exe").write_text("", encoding="utf-8")
            (build_dir / "bridge.dll").write_text("", encoding="utf-8")
            (build_dir / "python313.dll").write_text("", encoding="utf-8")
            (build_dir / "DLLs").mkdir()
            (build_dir / "DLLs" / "_socket.pyd").write_text("", encoding="utf-8")
            (build_dir / "sqlite3mc.dll").write_text("", encoding="utf-8")

            with self.assertRaisesRegex(
                ReleaseContractError,
                r"python\.exe",
            ):
                validate_windows_release_bundle(build_dir)

    def test_validate_windows_release_bundle_requires_gui_worker_executable(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            (build_dir / "data" / "py" / "site-packages" / "orchestrator").mkdir(parents=True)
            (build_dir / "deploydash.exe").write_text("", encoding="utf-8")
            (build_dir / "bridge.dll").write_text("", encoding="utf-8")
            (build_dir / "python.exe").write_text("", encoding="utf-8")
            (build_dir / "python313.dll").write_text("", encoding="utf-8")
            (build_dir / "DLLs").mkdir()
            (build_dir / "DLLs" / "_socket.pyd").write_text("", encoding="utf-8")
            (build_dir / "sqlite3mc.dll").write_text("", encoding="utf-8")

            with self.assertRaisesRegex(
                ReleaseContractError,
                r"pythonw\.exe",
            ):
                validate_windows_release_bundle(build_dir)

    def test_validate_windows_release_bundle_requires_standard_library_extensions(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            (build_dir / "data" / "py" / "site-packages" / "orchestrator").mkdir(parents=True)
            (build_dir / "deploydash.exe").write_text("", encoding="utf-8")
            (build_dir / "bridge.dll").write_text("", encoding="utf-8")
            (build_dir / "python.exe").write_text("", encoding="utf-8")
            (build_dir / "pythonw.exe").write_text("", encoding="utf-8")
            (build_dir / "python313.dll").write_text("", encoding="utf-8")
            (build_dir / "sqlite3mc.dll").write_text("", encoding="utf-8")

            with self.assertRaisesRegex(
                ReleaseContractError,
                r"DLLs[/\\]_socket\.pyd",
            ):
                validate_windows_release_bundle(build_dir)

    def test_validate_linux_release_bundle_success(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            (build_dir / "deploydash").write_text("", encoding="utf-8")
            (build_dir / "data" / "flutter_assets").mkdir(parents=True)
            (build_dir / "data" / "py" / "site-packages" / "orchestrator").mkdir(parents=True)
            (build_dir / "data" / "icudtl.dat").write_text("", encoding="utf-8")
            (build_dir / "lib").mkdir(parents=True)
            for filename in [
                "libbridge.so",
                "libapp.so",
                "libflutter_linux_gtk.so",
                "libpython3.13.so.1.0",
            ]:
                (build_dir / "lib" / filename).write_text("", encoding="utf-8")
            (build_dir / "python" / "bin").mkdir(parents=True)
            (build_dir / "python" / "bin" / "python3.13").write_text("", encoding="utf-8")
            validate_linux_release_bundle(build_dir)

    def test_validate_linux_release_bundle_detects_missing_dir(self):
        with self.assertRaisesRegex(
            ReleaseContractError,
            "Linux release bundle not found",
        ):
            validate_linux_release_bundle(Path("/definitely/missing"))

    def test_validate_linux_release_bundle_detects_missing_worker_interpreter(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            (build_dir / "deploydash").write_text("", encoding="utf-8")
            (build_dir / "data" / "flutter_assets").mkdir(parents=True)
            (build_dir / "data" / "py" / "site-packages" / "orchestrator").mkdir(parents=True)
            (build_dir / "data" / "icudtl.dat").write_text("", encoding="utf-8")
            (build_dir / "lib").mkdir(parents=True)
            for filename in [
                "libbridge.so",
                "libapp.so",
                "libflutter_linux_gtk.so",
                "libpython3.13.so.1.0",
            ]:
                (build_dir / "lib" / filename).write_text("", encoding="utf-8")

            with self.assertRaisesRegex(
                ReleaseContractError,
                r"python[/\\]bin[/\\]python3\.13",
            ):
                validate_linux_release_bundle(build_dir)

    def test_validate_linux_release_bundle_detects_missing_runtime_artifact(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            with self.assertRaisesRegex(
                ReleaseContractError,
                "Required runtime artifact missing from Linux bundle",
            ):
                validate_linux_release_bundle(build_dir)

    def test_validate_linux_release_bundle_detects_missing_python_library(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            build_dir = Path(temp_dir)
            (build_dir / "deploydash").write_text("", encoding="utf-8")
            (build_dir / "data" / "flutter_assets").mkdir(parents=True)
            (build_dir / "data" / "py" / "site-packages" / "orchestrator").mkdir(parents=True)
            (build_dir / "data" / "icudtl.dat").write_text("", encoding="utf-8")
            (build_dir / "lib").mkdir(parents=True)
            (build_dir / "python" / "bin").mkdir(parents=True)
            (build_dir / "python" / "bin" / "python3.13").write_text("", encoding="utf-8")
            for filename in [
                "libbridge.so",
                "libapp.so",
                "libflutter_linux_gtk.so",
            ]:
                (build_dir / "lib" / filename).write_text("", encoding="utf-8")

            with self.assertRaisesRegex(
                ReleaseContractError,
                "Required runtime artifact missing from Linux bundle",
            ):
                validate_linux_release_bundle(build_dir)

    def test_macos_dmg_name_uses_version_and_arch(self):
        self.assertEqual(
            macos_dmg_name(build_name="1.0.0", arch="arm64"),
            "DeployDash-v1.0.0-arm64.dmg",
        )
        self.assertEqual(
            macos_dmg_name(build_name="2.3.4", arch="x64"),
            "DeployDash-v2.3.4-x64.dmg",
        )
        self.assertEqual(
            macos_dmg_name(build_name="2.3.4", arch="x86_64"),
            "DeployDash-v2.3.4-x64.dmg",
        )

    def test_macos_dmg_name_falls_back_to_legacy_name(self):
        self.assertEqual(
            macos_dmg_name(build_name="", arch="arm64"),
            "DeployDash.dmg",
        )
        self.assertEqual(
            macos_dmg_name(build_name="", arch=""),
            "DeployDash.dmg",
        )

    def test_macos_dmg_name_rejects_invalid_inputs(self):
        with self.assertRaisesRegex(ReleaseContractError, "semantic version"):
            macos_dmg_name(build_name="1.2", arch="arm64")
        with self.assertRaisesRegex(ReleaseContractError, "macOS DMG architecture"):
            macos_dmg_name(build_name="1.2.3", arch="riscv")

    def test_locate_macos_app_bundle_finds_first_bundle(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            release_dir = Path(temp_dir)
            (release_dir / "Deploy Dash.app").mkdir()
            self.assertEqual(
                locate_macos_app_bundle(release_dir),
                release_dir / "Deploy Dash.app",
            )

    def test_locate_macos_app_bundle_rejects_missing_directory(self):
        with self.assertRaisesRegex(
            ReleaseContractError,
            "macOS release products directory not found",
        ):
            locate_macos_app_bundle(Path("/definitely/missing"))

    def test_locate_macos_app_bundle_rejects_missing_bundle(self):
        with (
            tempfile.TemporaryDirectory() as temp_dir,
            self.assertRaisesRegex(
                ReleaseContractError,
                "Unable to locate the built macOS .app bundle",
            ),
        ):
            locate_macos_app_bundle(Path(temp_dir))

    def test_assert_artifact_exists_handles_success_and_failure(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            artifact_path = Path(temp_dir) / "artifact.dmg"
            with self.assertRaisesRegex(
                ReleaseContractError,
                "DMG was not produced at expected path",
            ):
                assert_artifact_exists(artifact_path, "DMG")
            artifact_path.write_text("", encoding="utf-8")
            assert_artifact_exists(artifact_path, "DMG")


if __name__ == "__main__":
    unittest.main()
