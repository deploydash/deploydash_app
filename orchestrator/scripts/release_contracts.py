#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BACKEND_ROOT / "src"))

# Import after sys.path is extended above so the local package resolves
# without an install step.
from orchestrator.release_helpers import (  # noqa: E402
    ReleaseContractError,
    assert_artifact_exists,
    canonical_windows_store_payload_digest,
    create_windows_store_appxsym,
    create_windows_store_msixupload,
    debian_package_version,
    flutter_build_args,
    locate_macos_app_bundle,
    macos_dmg_name,
    macos_nested_signing_paths,
    read_last_published_windows_store_version,
    required_windows_signing_paths,
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
    write_windows_store_build_manifest,
)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    flutter_parser = subparsers.add_parser("flutter-build-args")
    flutter_parser.add_argument("--app-dir", required=True)
    flutter_parser.add_argument("--dart-defines-file", default="")
    flutter_parser.add_argument("--build-name", default="")
    flutter_parser.add_argument("--build-number", default="")
    flutter_parser.add_argument("--default-to-pubspec", action="store_true")

    debian_version_parser = subparsers.add_parser("debian-package-version")
    debian_version_parser.add_argument("--app-dir", required=True)
    debian_version_parser.add_argument("--build-name", default="")
    debian_version_parser.add_argument("--build-number", default="")

    snap_version_parser = subparsers.add_parser("snap-package-version")
    snap_version_parser.add_argument("--app-dir", required=True)
    snap_version_parser.add_argument("--build-name", default="")
    snap_version_parser.add_argument("--build-number", default="")

    windows_version_parser = subparsers.add_parser("windows-store-package-version")
    windows_version_parser.add_argument("--app-dir", required=True)
    windows_version_parser.add_argument("--build-name", default="")

    subparsers.add_parser("windows-store-identity").add_argument("--arch", required=True)

    windows_manifest_parser = subparsers.add_parser("validate-windows-store-manifest")
    windows_manifest_parser.add_argument("--manifest", required=True)
    windows_manifest_parser.add_argument("--package-version", required=True)
    windows_manifest_parser.add_argument("--arch", required=True)

    windows_build_manifest_parser = subparsers.add_parser("write-windows-store-build-manifest")
    windows_build_manifest_parser.add_argument("--output", required=True)
    windows_build_manifest_parser.add_argument("--package-version", required=True)
    windows_build_manifest_parser.add_argument("--arch", required=True)
    windows_build_manifest_parser.add_argument("--package-root", required=True)
    windows_build_manifest_parser.add_argument("--msix", required=True)
    windows_build_manifest_parser.add_argument("--appxsym", required=True)
    windows_build_manifest_parser.add_argument("--msixupload", required=True)

    windows_version_gate_parser = subparsers.add_parser("validate-windows-store-version")
    windows_version_gate_parser.add_argument("--package-version", required=True)
    windows_version_gate_parser.add_argument("--last-published-version-file", required=True)

    windows_artifact_names_parser = subparsers.add_parser("windows-store-artifact-names")
    windows_artifact_names_parser.add_argument("--package-version", required=True)
    windows_artifact_names_parser.add_argument("--arch", required=True)

    windows_payload_parser = subparsers.add_parser("validate-windows-store-package-root")
    windows_payload_parser.add_argument("--package-root", required=True)
    windows_payload_parser.add_argument("--package-version", required=True)
    windows_payload_parser.add_argument("--arch", required=True)
    windows_payload_parser.add_argument("--forbidden-values-file", default="")

    windows_payload_digest_parser = subparsers.add_parser("windows-store-payload-digest")
    windows_payload_digest_parser.add_argument("--package-root", required=True)

    windows_appxsym_parser = subparsers.add_parser("create-windows-store-appxsym")
    windows_appxsym_parser.add_argument("--build-dir", required=True)
    windows_appxsym_parser.add_argument("--output", required=True)

    windows_appxsym_validate_parser = subparsers.add_parser("validate-windows-store-appxsym")
    windows_appxsym_validate_parser.add_argument("--path", required=True)

    windows_upload_parser = subparsers.add_parser("create-windows-store-msixupload")
    windows_upload_parser.add_argument("--msix", required=True)
    windows_upload_parser.add_argument("--appxsym", required=True)
    windows_upload_parser.add_argument("--output", required=True)

    windows_upload_validate_parser = subparsers.add_parser("validate-windows-store-msixupload")
    windows_upload_validate_parser.add_argument("--msixupload", required=True)
    windows_upload_validate_parser.add_argument("--msix", required=True)
    windows_upload_validate_parser.add_argument("--appxsym", required=True)

    windows_msix_parser = subparsers.add_parser("validate-windows-store-msix")
    windows_msix_parser.add_argument("--msix", required=True)
    windows_msix_parser.add_argument("--package-version", required=True)
    windows_msix_parser.add_argument("--arch", required=True)
    windows_msix_parser.add_argument("--allow-signed", action="store_true")
    windows_msix_parser.add_argument("--forbidden-values-file", default="")

    windows_build_manifest_validate_parser = subparsers.add_parser(
        "validate-windows-store-build-manifest"
    )
    windows_build_manifest_validate_parser.add_argument("--manifest", required=True)
    windows_build_manifest_validate_parser.add_argument("--arch", required=True)
    windows_build_manifest_validate_parser.add_argument("--package-root", required=True)
    windows_build_manifest_validate_parser.add_argument("--msix", required=True)
    windows_build_manifest_validate_parser.add_argument("--appxsym", required=True)
    windows_build_manifest_validate_parser.add_argument("--msixupload", required=True)

    linux_parser = subparsers.add_parser("validate-linux-release-bundle")
    linux_parser.add_argument("--build-dir", required=True)

    windows_parser = subparsers.add_parser("validate-windows-release-bundle")
    windows_parser.add_argument("--build-dir", required=True)

    windows_hardening_parser = subparsers.add_parser("validate-windows-binary-hardening")
    windows_hardening_parser.add_argument("--build-dir", required=True)

    windows_signing_parser = subparsers.add_parser("windows-signing-paths")
    windows_signing_parser.add_argument("--build-dir", required=True)

    macos_parser = subparsers.add_parser("locate-macos-app-bundle")
    macos_parser.add_argument("--release-dir", required=True)

    macos_dmg_parser = subparsers.add_parser("macos-dmg-name")
    macos_dmg_parser.add_argument("--build-name", default="")
    macos_dmg_parser.add_argument("--arch", default="arm64")

    macos_signing_parser = subparsers.add_parser("macos-signing-paths")
    macos_signing_parser.add_argument("--app-bundle", required=True)

    subparsers.add_parser("select-macos-signing-identity")

    artifact_parser = subparsers.add_parser("assert-artifact")
    artifact_parser.add_argument("--path", required=True)
    artifact_parser.add_argument("--label", required=True)
    return parser


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()

    try:

        def forbidden_values(path_value: str) -> tuple[str, ...]:
            if not path_value:
                return ()
            try:
                return tuple(
                    value
                    for value in Path(path_value).read_text(encoding="utf-8").splitlines()
                    if value
                )
            except OSError as exc:
                raise ReleaseContractError(
                    f"Unable to read forbidden-values file: {path_value}"
                ) from exc

        if args.command == "flutter-build-args":
            values = flutter_build_args(
                app_dir=Path(args.app_dir),
                dart_defines_file=args.dart_defines_file,
                build_name=args.build_name,
                build_number=args.build_number,
                default_to_pubspec=args.default_to_pubspec,
            )
            for value in values:
                print(value)
            return

        if args.command == "debian-package-version":
            print(
                debian_package_version(
                    app_dir=Path(args.app_dir),
                    build_name=args.build_name,
                    build_number=args.build_number,
                )
            )
            return

        if args.command == "snap-package-version":
            print(
                snap_package_version(
                    app_dir=Path(args.app_dir),
                    build_name=args.build_name,
                    build_number=args.build_number,
                )
            )
            return

        if args.command == "windows-store-package-version":
            print(
                windows_store_package_version(
                    app_dir=Path(args.app_dir),
                    build_name=args.build_name,
                )
            )
            return

        if args.command == "windows-store-identity":
            print(json.dumps(windows_store_identity(arch=args.arch), sort_keys=True))
            return

        if args.command == "validate-windows-store-manifest":
            validate_windows_store_manifest(
                Path(args.manifest),
                package_version=args.package_version,
                arch=args.arch,
            )
            return

        if args.command == "write-windows-store-build-manifest":
            write_windows_store_build_manifest(
                Path(args.output),
                package_version=args.package_version,
                arch=args.arch,
                package_root=Path(args.package_root),
                msix_path=Path(args.msix),
                appxsym_path=Path(args.appxsym),
                msixupload_path=Path(args.msixupload),
            )
            return

        if args.command == "validate-windows-store-version":
            validate_windows_store_version(
                package_version=args.package_version,
                last_published_version=read_last_published_windows_store_version(
                    Path(args.last_published_version_file)
                ),
            )
            return

        if args.command == "windows-store-artifact-names":
            print(
                json.dumps(
                    windows_store_artifact_names(args.package_version, arch=args.arch),
                    sort_keys=True,
                )
            )
            return

        if args.command == "validate-windows-store-package-root":
            print(
                json.dumps(
                    validate_windows_store_package_root(
                        Path(args.package_root),
                        package_version=args.package_version,
                        arch=args.arch,
                        forbidden_values=forbidden_values(args.forbidden_values_file),
                    ),
                    sort_keys=True,
                )
            )
            return

        if args.command == "windows-store-payload-digest":
            print(
                json.dumps(
                    canonical_windows_store_payload_digest(Path(args.package_root)),
                    sort_keys=True,
                )
            )
            return

        if args.command == "create-windows-store-appxsym":
            create_windows_store_appxsym(
                Path(args.build_dir),
                Path(args.output),
            )
            return

        if args.command == "validate-windows-store-appxsym":
            validate_windows_store_appxsym(Path(args.path))
            return

        if args.command == "create-windows-store-msixupload":
            create_windows_store_msixupload(
                msix_path=Path(args.msix),
                appxsym_path=Path(args.appxsym),
                output_path=Path(args.output),
            )
            return

        if args.command == "validate-windows-store-msixupload":
            validate_windows_store_msixupload(
                msixupload_path=Path(args.msixupload),
                msix_path=Path(args.msix),
                appxsym_path=Path(args.appxsym),
            )
            return

        if args.command == "validate-windows-store-msix":
            validate_windows_store_msix(
                Path(args.msix),
                package_version=args.package_version,
                arch=args.arch,
                allow_signed=args.allow_signed,
                forbidden_values=forbidden_values(args.forbidden_values_file),
            )
            return

        if args.command == "validate-windows-store-build-manifest":
            validate_windows_store_build_manifest(
                Path(args.manifest),
                arch=args.arch,
                package_root=Path(args.package_root),
                msix_path=Path(args.msix),
                appxsym_path=Path(args.appxsym),
                msixupload_path=Path(args.msixupload),
            )
            return

        if args.command == "validate-linux-release-bundle":
            validate_linux_release_bundle(Path(args.build_dir))
            return

        if args.command == "validate-windows-release-bundle":
            validate_windows_release_bundle(Path(args.build_dir))
            return

        if args.command == "validate-windows-binary-hardening":
            validate_windows_binary_hardening(Path(args.build_dir))
            return

        if args.command == "windows-signing-paths":
            for path in required_windows_signing_paths(Path(args.build_dir)):
                print(path)
            return

        if args.command == "locate-macos-app-bundle":
            print(locate_macos_app_bundle(Path(args.release_dir)))
            return

        if args.command == "macos-dmg-name":
            print(macos_dmg_name(build_name=args.build_name, arch=args.arch))
            return

        if args.command == "macos-signing-paths":
            for path in macos_nested_signing_paths(Path(args.app_bundle)):
                print(path)
            return

        if args.command == "select-macos-signing-identity":
            print(select_macos_signing_identity(sys.stdin.read()))
            return

        if args.command == "assert-artifact":
            assert_artifact_exists(Path(args.path), args.label)
            return
    except ReleaseContractError as exc:
        raise SystemExit(str(exc)) from exc

    raise SystemExit(f"Unsupported command: {args.command}")


if __name__ == "__main__":
    main()
