# Releasing Deploy Dash Desktop

This document defines the release-channel scaffolding currently tracked in the
repository for Deploy Dash desktop distribution.

## Target Channels

- Ubuntu 24.04 LTS and newer
  - `.deb`
  - Snap
  - Flatpak / Flathub
- macOS on Apple Silicon (`arm64`) and Intel (`x64`) Macs
  - notarized `.dmg` per architecture (`DeployDash-vX.Y.Z-arm64.dmg`,
    `DeployDash-vX.Y.Z-x64.dmg`)
  - Mac App Store
- Windows 10 (64-bit) or later, on `x64` and `arm64`
  - Microsoft Store via per-arch MSIX
    (`DeployDash_<X.Y.Z.0>_{x64,arm64}.msixupload`)
  - MSI is local-manual only: never built, attached, or submitted
    by automation (see below)

## Current State

The Linux `.deb` channel is the currently validated release path today.

The repository now also contains:

- macOS bundle identity and `deploydash://callback` registration
- macOS signing/export scaffolds for DMG and App Store builds
- Windows product branding plus MSI/MSIX packaging templates
- Snap and Flatpak manifests
- a cross-platform backend runtime-bundle preparation script
- shared native bridge source at `ui/shared_native/bridge_exports.cc`
- Windows `bridge.dll` build plus embedded Python runtime staging, including
  `pythonw.exe` for console-free spawned task workers, `python.exe` for runtime
  diagnostics, and the CPython `DLLs/` extension-module layout in the install
  layout
- Windows bundle validation, including Drift's bundled encrypted SQLite
  `sqlite3mc.dll` required by the local database
- macOS Xcode build-phase staging for `libbridge.dylib` and the embedded
  Python runtime inside the `.app` bundle
- structured bridge/runtime startup diagnostics for embedded Python layout
  resolution, including Python home, candidate search paths, and bundled
  backend runtime presence
- a build-time runtime smoke check that imports the copied backend with missing
  or invalid GUI console streams and completes a background echo task
- mandatory Profile/Release process hardening with structured bridge
  diagnostics, 100% focused coverage gates, and optimized cross-platform E2E
- macOS Hardened Runtime/nested-code verification and Windows PE mitigation
  validation plus optional certificate-backed Authenticode signing
- anonymous Ed25519-signed release discovery through
  `https://updates.deploydash.com/v1/desktop/releases/check`
- a stable local device UUID used only for local rollout bucketing and
  per-device state; it is never included in the update request

The initial update-service deployment is a separate Node application at
`updates.deploydash.com`. It returns a signed `current` response for supported
installations and `unsupported` for development and MSI installations. Before
publishing a desktop build, configure the matching Ed25519 private key as a
deployment secret; it must never be committed or included in the application
image. GitHub release discovery and store publication automation are not part
of this initial service.

The remaining work is final real-device and store-submission validation rather
than a missing cross-platform bridge or process-hardening implementation.

Cross-platform packaging also assumes app-managed SSH key storage. Deploy Dash
now imports private key contents during server onboarding and materializes
temporary key files when building SSH payloads, instead of depending on long-
lived workstation key paths.

Cross-platform runtime validation should also preserve the current onboarding
security model:

- onboarding pivots successful servers onto the managed `ubuntu` account rather
  than leaving the original bootstrap login as the saved runtime identity
- onboarding generates and stores a Deploy Dash-managed SSH keypair
- final SSH hardening and the Docker-safe SSH-only firewall baseline happen
  only after a verified fresh `ubuntu` key-login succeeds
- Ubuntu automatic security updates are enabled by default during onboarding
- host-key replacement requires an explicit fingerprint-confirmation modal in
  the desktop UI

## Sandboxed Local-Path Model

The desktop app now treats persisted workstation file paths as a release and
confinement risk.

Current audited model:

- SSH private keys are imported into Deploy Dash-managed local storage and
  materialized into temporary runtime files only when building SSH payloads.
- Local database restore and export use a fresh OS file picker per action.
- PostgreSQL `.sql` import uses a fresh OS file picker per action.
- Workstation file access remains picker-based per action rather than depending
  on persisted workstation path reopening.
- Persisted path fields that still exist in project state are server-side or
  container-side paths, such as:
  - SQLite mount paths
  - app subdirectories inside a checked-out repo
  - remote backup artifact paths
- Release validation for Snap, Flatpak, and the Mac App Store should reject
  any regression that depends on reopening arbitrary host workstation paths
  without a new picker selection.

## Linux

### Debian package

```bash
cd ui
bash scripts/build_deb.sh
```

The package target is Ubuntu 24.04 LTS and newer. The direct-build workflow
builds the package on an Ubuntu 24.04 runner; installed-package smoke
(`run_deb_install_smoke.sh`) and the release-candidate journey below run
in the private QA gate before release publication — see the QA checkout
note under Validation for where those runners live now.

The package installs the Deploy Dash archive public key and a deb822 source for
`https://updates.deploydash.com/apt`. `Update now` opens the system package
manager through `apt:`; the app does not run `sudo`, request an administrator
password, or install packages silently. Publish signed APT metadata before
making the corresponding update response available.

Run this only in CI or on a disposable host. Its cleanup removes any installed
`deploydash` package.

Before public release, run the installed-package release candidate journey:

```bash
bash qa/e2e/runners/run_deb_release.sh
```

It uses the shared cross-platform release baseline with Linux and Debian
adapters. Two disposable Multipass VMs exercise a clean candidate install and
onboarding lane, followed by a pristine-volume-checkpoint A-to-B upgrade and
uninstall/reinstall retention lane. The gate independently verifies SSH
hardening, Docker, Caddy, firewall state, fail2ban, and automatic security
updates on the managed VM. It deliberately excludes GitHub and deployment,
which are covered by the workflow E2E suite. Reports are written beneath
`qa/e2e/local/runs/desktop-release/`. A failed run retains its VMs and evidence;
a successful run deletes them unless `--keep-vms` is supplied.

The platform-neutral entrypoint is:

```bash
bash qa/e2e/runners/run_desktop_release.sh --platform linux --package deb
```

### Snap

```bash
cd ui
bash scripts/build_snap.sh
```

Notes:

- requires Snapcraft, LXD, and `squashfs-tools` on an Ubuntu amd64 build host
- builds in a clean `core24` Snapcraft environment
- emits `build/snap/deploydash_<version>_amd64.snap`
- validates strict confinement, stable grade, runtime contents, and lint output

Before moving a release into the Store candidate channel, run:

```bash
bash qa/e2e/runners/run_snap_release.sh
```

The gate uses a unique short-lived Store branch, exercises clean install and
`snap refresh --amend`, validates automatic snapshot restoration and purge
reset, and promotes only the exact tested revision to `latest/candidate` after
all checks pass. It refuses to overwrite a candidate channel that changed
during the run and closes its temporary branch on success or failure. See
`qa/e2e/runbooks/snap-release.md` for credential setup and the full contract.

### Flatpak

```bash
cd ui
bash scripts/build_flatpak.sh
```

Notes:

- requires `flatpak` and `flatpak-builder`
- emits `build/flatpak/com.deploydash.desktop.flatpak`

## macOS

macOS release builds ship one DMG per architecture: `arm64` (Apple
Silicon, built on `macos-latest`) and `x64` (Intel, built on
`macos-26-intel`, where the whole toolchain produces x64 natively).
`ARCHS` follows `DEPLOYDASH_MACOS_ARCH` (`arm64` default, `x64` on the
Intel leg) through the Xcode configs; filenames follow
`DeployDash-vX.Y.Z-{arm64,x64}.dmg` from the single `macos-dmg-name`
contract. Intel Macs are supported operating systems, not
second-class targets: same signing, notarization, stapling, and
Hardened Runtime verification on both legs.

Minimum supported macOS is 13 Ventura on both architectures. The
encrypted database asset is compiled for macOS 13 by the Flutter
toolchain and nothing in the app can lower that, so the Xcode
deployment target, the bridge compile flag, and the installer's
minimum-system version all state 13.0 — do not reintroduce an older
floor without replacing the sqlite asset pipeline first.

### DMG

```bash
cd ui
DEPLOYDASH_MACOS_ARCH=x64 bash scripts/build_macos_dmg.sh
```

The command above is the production path. It rebuilds with the Tidy Technology
Ltd Developer ID identity, signs the DMG, notarizes it with the
`deploydash-notary` Keychain profile, staples the ticket, and validates the
result. The production chain requires `DEPLOYDASH_BUILD_NAME` (a release
build without a version cannot produce a versioned filename); local
`--package-only` builds keep the unversioned name. The build passes
`config/dart-defines.local.json` to Flutter by default
and fails if that local-only file is absent. Set
`DEPLOYDASH_DART_DEFINES_FILE` to use a different relative or absolute JSON
file.

Direct DMG builds include pinned Sparkle `2.9.2`, the release public key,
and the stable appcast URL baked per arch. Mac App Store
archives explicitly exclude Sparkle and remain App Store managed.

### Signing and notarization diagnostics

```bash
cd ui
bash scripts/rebuild_macos_dmg.sh
DEPLOYDASH_MACOS_NOTARY_PROFILE=deploydash-notary \
  bash scripts/notarize_macos_dmg.sh
```

### Mac App Store export

```bash
cd ui
bash scripts/build_macos_app_store.sh
```

Notes:

- both commands must run on macOS
- App Store builds default to Apple Team `CAZ3ADRS95` and use the tag
  version (`X.Y.Z`) with the workflow run-number build (`N`); never
  hand-pick a build number
- `build_macos_dmg.sh` always runs the production direct-distribution chain:
  Developer ID rebuild, DMG signing, Apple notarization, ticket stapling, and
  final validation
- `build_macos_dmg.sh --package-only` is the lower-level packaging mode used
  internally by `rebuild_macos_dmg.sh` and by unsigned CI artifact builds
- packaging fails before building when no suitable Keychain identity is
  available because ad-hoc signatures cannot satisfy Hardened Runtime library
  validation for embedded Flutter frameworks
- `rebuild_macos_dmg.sh` signs every nested framework, native/Python binary,
  the outer app, and the DMG with the Tidy Technology Ltd Developer ID
  identity by default; set `DEPLOYDASH_MACOS_DMG_SIGN_IDENTITY` only to
  override that identity
- `notarize_macos_dmg.sh` supports either an `xcrun notarytool`
  keychain profile or direct Apple ID / team ID / app-specific password
  credentials
- Gatekeeper assessment runs only after DMG notarization and stapling, using
  the DMG primary-signature context
- the repo tracks the App Store export template at
  `packaging/macos/ExportOptions.appstore.plist.template`
- the app is configured for the `deploydash://callback` URL scheme and sandbox
  entitlements needed for network access plus user-selected file access
- release packaging discovers nested code by Mach-O headers rather than file
  extensions, then verifies Hardened Runtime and matching Team IDs on the app,
  Flutter plugin frameworks, and every nested Python/native module; it also
  verifies required sandbox entitlements and the absence of library-validation
  bypass entitlements
- the Runner Release configuration disables Xcode base-entitlement injection
  so distribution builds cannot inherit the debugging-only
  `com.apple.security.get-task-allow` entitlement

### macOS builds run on GitHub Actions

macOS builds run in
`.github/workflows/desktop-direct-builds.yml` (called by `release.yml`
on tags, runnable manually via `workflow_dispatch`) on stock
`macos-15` hosted runners — sign, notarize, and staple included
(WWDR G3+G4 intermediates are fetched into the CI keychain since
hosted runners carry none, and `stapler staple` retries 3x against
transient Apple CDN failures). There is no Xcode Cloud workflow:
its `ci_scripts` are deleted. The Intel leg is suspended (native
builds need `macos-26-intel`); the desk Mac self-hosted runner
(`dd-mac-dmg`) stays warm as a one-commit `runs-on` fallback if
hosted Mac minutes or notarization-from-hosted ever regress.
Dispatch with `macos_only=true` to rehearse the macOS leg alone.
Tags build Windows + macOS by default (`winmac_only`); the Ubuntu
and Snap legs stay parked until their QA gates land. The certifying
macOS gate (install + server onboarding against the app-built DMG)
runs on `macos-15` via `qa-public-macos-slim.yml`, which checks out
and runs the private suite from `deploydash/deploydash_qa` (Swift
AX tools over self-SSH, no VoiceOver anywhere); the QA repo's own
`desk-macos-slim.yml` remains the desk fallback. There is no app-repo
install check. macOS release signing uses the repository secrets
(`DEPLOYDASH_MACOS_SIGN_CERT_P12_BASE64` and friends); see the root
`README.md` for the full secret list. The `.p12`-from-file path died
with the Xcode Cloud scripts and must not be reintroduced.

## Windows

### Local debug build

Run the wrapper from the app directory. Drift builds and bundles the encrypted
SQLite native asset, so no vcpkg or OpenSSL setup is required for the local
database:

```powershell
cd C:\dev\deploydash\ui
powershell -ExecutionPolicy Bypass -File scripts/build_windows_debug.ps1
```

The script cleans stale CMake configuration unless `-SkipClean` is specified.
It uses `uv` to resolve Python 3.13.14 and does not require a system `python`
command. Before reporting success, it verifies that the debug bundle contains
the encrypted SQLite `sqlite3mc.dll` alongside the executable.

### MSI

```powershell
cd ui
powershell -ExecutionPolicy Bypass -File scripts/build_windows_msi.ps1
```

MSI is local-manual only. It identifies itself as `msi` and the update
endpoint must return `unsupported` for that distribution. CI never
builds it, no workflow references it (the scaffold gate fails if one
does), and it is never attached to releases or submitted anywhere.
Unsigned direct-download MSI installs with a SmartScreen warning; that
trade-off is accepted for a compat fallback and is the reason MSIX is
the only automated vehicle.

### Microsoft Store (MSIX)

```powershell
cd ui
powershell -ExecutionPolicy Bypass -File scripts/build_windows_store.ps1 -Arch x64
```

`Arch` is mandatory (`x64` or `arm64`, no default); CI sets it per
matrix leg (`windows-latest` builds x64, `windows-11-arm` builds
arm64, each host-native — nothing cross-compiles).

Notes:

- the command must run on Windows 10 64-bit or newer (x64 leg) or
  Windows 11 on ARM64 (arm64 leg)
- MSI uses the WiX template at `packaging/windows/wix/DeployDash.wxs`
  for local manual builds only — never in this flow
- Store packaging uses the MSIX manifest at
  `packaging/windows/msix/Package.appxmanifest`, rendered per arch
  (`__PACKAGE_VERSION__`, `__ARCHITECTURE__`) with floor
  `MinVersion 10.0.17763.0` (Windows 10 1809)
- the Store identity is fixed to `TidyTechnology.DeployDash`, publisher
  `CN=4DF691A0-E545-4698-A115-C49614B329C6`, and Product ID
  `9P1GK6Z58B9T`; release operators must not override it
- Store versions are `X.Y.Z.0`; the fourth component remains zero for Store
  certification; both archs share one version and one
  `store-last-published-version.txt` monotonicity gate
- production output per arch is the unsigned versioned
  `DeployDash_<X.Y.Z.0>_{x64,arm64}.msixupload` plus its `.msix`,
  `.appxsym`, and `.build-manifest.json`; Partner Center signs the
  accepted Store package
- release packaging validates ASLR, high-entropy VA, DEP/NX, and Control Flow
  Guard on the runner and bridge before building an installer

Store submission runs from CI after QA publication (`.github/workflows/store-submit.yml`,
Microsoft's own publisher action + `msstore` CLI): both `.msixupload`s
download from the draft release, credentials reconfigure from the four
Entra/Seller secrets, and `msstore publish -id 9P1GK6Z58B9T` runs per
arch submission. Certification takes hours typically, up to three
business days; the GitHub release never waits for it. Poll state with
the scheduled `store-cert-watch.yml` job. Until all four Store secrets are
configured, that read-only watcher exits successfully with a visible warning
and job summary instead of making `main` permanently red. The publishing
workflow remains fail-closed when those credentials are absent.

MSIX download follows the post-certification Store-signed package
only (manual Partner Center fetch for v1; attach to the published
release; never the unsigned CI `.msix`). The sideloaded-MSIX update
rule is undecided — sideloaded installs do not get Store updates, and
no rule may ship until it is written down here first.

Before Partner Center upload, run the installed-package gate. It exclusively
leases the existing `win11` QA VM, runs every Windows lane serially there, and
creates only the disposable Ubuntu managed-server VM:

```bash
bash qa/e2e/runners/run_windows_store_release.sh
```

It builds separately self-signed E2E packages for real App Installer clicks,
upgrade, protocol activation, and WACK. Never upload an `.e2e.msix` or its
temporary certificate. Upload only the versioned `.msixupload`, first to the
private audience and then through the configured package flight. Promote to
the public listing manually after certification and Store-install validation.

## Desktop Update Publication

The client/API contract, signed payload schema, distribution-to-installer
mapping, privacy boundary, and key-rotation rules live in
[`../docs/contracts/desktop-update-contract.md`](../docs/contracts/desktop-update-contract.md).

For every release:

1. Push a `vX.Y.Z` tag. The tag is the version; the workflow run number
   is the build number. Never hand-pick either, and never reuse a
   Windows Store `X.Y.Z.0` version.
2. Build, sign, and verify every target artifact (CI does this; the
   Ubuntu and macOS legs each attach their arch's versioned package to
   the draft).
3. Publish immutable artifacts and platform metadata first (draft
   release; QA gate plus Store-live gate flip it to published, in tandem
   with every other store leg).
4. Smoke-test installation and platform update discovery.
5. Sign the update payload with the offline desktop release key.
6. Publish the signed response last, initially with a staged rollout if needed.

Security and critical updates remain advisory in the client. They use stronger
copy but never lock users out of their local control plane.

## Validation

Run the release-scaffold checks after touching platform packaging files:

```bash
cd ui
bash scripts/validate_release_scaffolds.sh
```

Run the focused process-security coverage gates locally:

```bash
./scripts/process_security_diagnostics_coverage.sh
./scripts/native_process_security_coverage.sh
```

All `qa/e2e/...` runners below live in `deploydash/deploydash_tests`;
run them from a checkout of that repository with `DEPLOYDASH_APP_ROOT`
pointing at this one. The Linux optimized E2E runs in the disposable
Multipass VM gate:

```bash
bash qa/e2e/runners/run_linux_vm_gates.sh
```

`run_platform_security.sh` remains the direct optimized E2E entrypoint for
macOS. Do not run its Linux variant on a workstation or hosted GitHub runner;
the disposable Multipass VM gate provides the required Linux isolation and
provenance evidence.

## CI Coverage

Platform-aware release validation runs in `.github/workflows/`:

- `ci.yml`: PR/main gates (analyze, unit tests, scaffold + secret audits).
- `release.yml`: tag pipeline — test gate, platform builds to a draft
  release, hosted Windows slim, private QA handoff for the remaining
  legs, publish on QA success.
- `qa-public-windows-slim.yml` (reusable, called by `release.yml`):
  checks out the private QA suite via a read-only deploy key and runs
  the Windows slim gate on a hosted runner (free minutes). Logs and
  artifacts are public by design; the suite's code never leaves the
  private repo. Treat workflow write access as the security boundary:
  any writer can exfiltrate secrets via workflow edits, so keep the
  writer circle minimal and pin third-party actions by SHA.
- `desktop-release-scaffolds.yml`, `desktop-dart.yml`,
  `desktop-database-coverage.yml`, `backend-engine.yml`: scoped gates.
- `desktop-direct-builds.yml` (reusable, called by `release.yml`):
  dual-arch Ubuntu `.deb`, dual-arch signed DMGs with slim per-arch
  install checks, and dual-arch unsigned Windows Store candidates;
  artifacts attach to the draft release only.
- `desktop-snap-build.yml` (reusable): Snap build with draft attach.

Actions are official, vendor-official, or in-repo only (see the repo
root task list); Flutter comes from the pinned in-repo composite,
release upload goes through `gh`, and every consumed secret is
masked and audited.

The hosted Snap workflow builds in Snapcraft destructive mode on its disposable
Ubuntu 24.04 runner, which matches the `core24` base and avoids an LXD managed
build-instance network restriction. Local `build_snap.sh` calls continue to
use the isolated LXD provider by default.

## GitHub Direct-Build Workflow

The repo tracks direct-install GitHub build automation in
`.github/workflows/desktop-direct-builds.yml` (reusable; called by
`release.yml` on tags, runnable manually via `workflow_dispatch`).

Current behavior:

- builds Ubuntu 24.04 `.deb` packages for amd64 on `ubuntu-24.04` and
  arm64 on `ubuntu-24.04-arm`
- builds signed, notarized, stapled DMGs per arch (arm64 on
  `macos-latest`, x64 on `macos-26-intel`), each followed by its slim
  install check
- builds an unsigned private Windows Partner Center candidate per
  arch (`windows-latest` + `windows-11-arm`), each followed by its
  slim install check
- resolves build name/build number through the shared backend metadata helper
- validates expected artifact paths through the shared release contract helper
- uploads the platform outputs as GitHub Actions artifacts
- attaches versioned artifacts (`deploydash_X.Y.Z_{amd64,arm64}.deb`,
  `DeployDash-vX.Y.Z-{arm64,x64}.dmg`, and per-arch
  `DeployDash_X.Y.Z.0_{x64,arm64}.msixupload` + build manifests —
  never the unsigned `.msix`) to a draft GitHub release on tag pushes
- attaches one `SHA256SUMS`, generated only after all six architecture
  legs succeed, covering the two `.deb` files, two DMGs, two private
  `.msixupload` candidates, and their two build manifests
- supports an optional CI Dart defines file through repository secrets, but can
  build without it for direct artifact generation
- imports macOS signing material into a temporary keychain and removes it after
  the job; Windows Store candidates do not use repository signing secrets

Current scope:

- produces runner-built `.deb` packages for amd64 and arm64,
  production-signed/notarized DMGs per arch, and per-arch private
  unsigned Windows `.msixupload` sets
- submits to the Microsoft Store from CI after QA publication
  (`store-submit.yml`); App Store submission remains manual

### Stable website download suffixes

The customer-facing website resolver matches release assets by suffix, not by
an exact versioned filename. These suffixes are therefore a cross-repository
contract with `deploydash/website`:

| Customer target | Attached filename form | Resolver suffix |
| --- | --- | --- |
| Ubuntu x64 | `deploydash_X.Y.Z_amd64.deb` | `_amd64.deb` |
| Ubuntu arm64 | `deploydash_X.Y.Z_arm64.deb` | `_arm64.deb` |
| macOS Intel | `DeployDash-vX.Y.Z-x64.dmg` | `-x64.dmg` |
| macOS Apple Silicon | `DeployDash-vX.Y.Z-arm64.dmg` | `-arm64.dmg` |

Windows customer downloads resolve through the Microsoft Store. The attached
`_x64.msixupload` and `_arm64.msixupload` files are Partner Center submission
archives, not installable customer downloads, and the website must never offer
them as installers. Renaming any suffix in this section requires the matching
website route mapping and its contract tests to change in the same coordinated
release.

Required direct-release repository secrets:

- `DEPLOYDASH_MACOS_SIGN_CERT_P12_BASE64`
- `DEPLOYDASH_MACOS_SIGN_CERT_P12_PASSWORD`
- `DEPLOYDASH_APPLE_ID`
- `DEPLOYDASH_APPLE_TEAM_ID`
- `DEPLOYDASH_APPLE_APP_PASSWORD`

Required Store-submission secrets (Entra/Partner Center, see the
Microsoft Store CLI doc for where each value lives):

- `AZURE_AD_TENANT_ID`
- `AZURE_AD_APPLICATION_CLIENT_ID`
- `AZURE_AD_APPLICATION_SECRET` (note its expiry on creation day;
  rotation is update-this-one-secret only)
- `SELLER_ID`

The Apple certificate secret contains base64-encoded `.p12` bytes. Store
submission and certification remain separate manual release steps.

## Store Metadata And Submission Checklists

Use these files as the release source of truth before any public submission:

- `packaging/STORE_SUBMISSION_CHECKLIST.md`
- `packaging/STORE_METADATA_TEMPLATE.md`

They track:

- screenshots
- support/privacy URLs
- storefront descriptions
- review notes
- platform-specific submission checks for Snap, Flathub, Mac App Store, and
  Microsoft Store
