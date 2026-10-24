# Store Submission Checklist

Use this checklist before shipping Deploy Dash through any desktop release
channel beyond the Linux `.deb`.

## Cross-Platform Readiness

- Verify the packaged app launches and unlocks the local database.
- Verify GitHub OAuth returns through `deploydash://callback`.
- Verify server onboarding works with password authentication.
- Verify server onboarding works with imported SSH private key
  authentication.
- Verify web app deploy, deploy logs, and runtime logs.
- Verify Agent Access can bind locally.
- Verify local database export and restore.
- Verify one-off app command execution.
- Verify PostgreSQL `.sql` import from a workstation file picker.
- Confirm no workflow depends on reopening an arbitrary persisted workstation
  path outside a fresh user file-picker selection.

## Linux

### Debian package

- Build on Ubuntu 22.04 or newer.
- Test install, launch, upgrade, and uninstall on Ubuntu 22.04 and 24.04.
- Confirm the launcher appears once as `Deploy Dash`.
- Confirm `deploydash://callback` registration.

### Snap

- Build and lint the strict `core24` amd64 artifact with
  `bash ui/scripts/build_snap.sh`.
- Run `bash qa/e2e/runners/run_snap_release.sh` with a time-limited,
  Snap-scoped Store credential before changing `latest/candidate`.
- Confirm the gate tests a clean Store install, local-to-Store refresh,
  automatic snapshot restore, purge reset, and the exact Store revision being
  promoted.
- Confirm the temporary Store branch is closed after both successful and
  failed runs.
- Confirm Store review has granted the `deploydash-dbus` slot declaration for
  the session name `com.deploydash.desktop`; the strict Flutter app cannot
  claim its application ID without it.
- Confirm imported SSH keys work without host-path persistence.
- Confirm the `home`, `network`, `network-bind`, and `removable-media`
  interfaces are documented for Store review.

### Flatpak / Flathub

- Validate portal-based file access.
- Confirm metadata and screenshots satisfy Flathub requirements.
- Confirm imported SSH keys and workstation file import/export flows still work
  through portals.

## macOS

### Direct distribution (`.dmg`)

- Build an Apple Silicon-only app (`arm64`); Intel (`x86_64`) Macs are not
  supported.
- Verify the app bundle includes `libbridge.dylib` and the embedded Python
  runtime.
- Sign the app with the release identity.
- Notarize and staple the DMG.
- Test launch on Apple Silicon across the oldest and newest supported macOS
  releases.

### Mac App Store

- Confirm sandbox entitlements still match shipped behavior:
  - outgoing network access
  - localhost/listener behavior
  - user-selected file access
- Prepare review notes that explain:
  - Deploy Dash connects to user-owned remote servers over SSH.
  - Deploy Dash embeds a self-contained Python runtime for local task
    execution.
  - Deploy Dash never exposes arbitrary shell access to third-party agents.
- Run an App Store viability submission before treating the channel as GA.

## Windows

### MSI

Local manual builds only — never built, attached, or submitted by
automation (see the reorg task list D1/D6). The checklist below
covers MSIX only.

- Build and install on Windows 11 x64.
- Test install, launch, upgrade, and uninstall.
- Confirm the installed bundle includes `bridge.dll`, `python313.dll`, `Lib`,
  and `data\\py\\site-packages`.

### Microsoft Store (MSIX)

- Support Windows 10 (64-bit) or later, on `x64` and `arm64`, from one
  submission per arch (confirm combined submissions in Partner Center
  before assuming otherwise).
- Build a `.msixupload` per arch with package name `TidyTechnology.DeployDash`,
  publisher `CN=4DF691A0-E545-4698-A115-C49614B329C6`, revision `0`,
  and floor `MinVersion 10.0.17763.0`.
- Confirm the versioned per-arch `.msix`, first-party-only `.appxsym`,
  `.msixupload`, and build-manifest hashes validate before uploading
  the candidate.
- Run the 100% scoped Flutter accessibility and PowerShell Pester coverage
  gates before the installed-package journey.
- Run `bash qa/e2e/runners/run_windows_store_release.sh` and retain the passing
  App Installer, WACK, screenshots, UI tree, upgrade, and uninstall evidence.
- Submission is automatic: after QA passes, the release pipeline submits
  the draft `.msixupload` assets to Partner Center and commits for
  certification; the scheduled Store Publish Watch then publishes the
  GitHub release (attaching the Microsoft web installer stub) once the
  submission is live. Manual retries replay the same scripts via the
  store-submit workflow dispatch.
- Confirm `deploydash://callback` opens the running app rather than leaving the
  OAuth flow in a second instance.
- Verify keyboard navigation, visible focus, and stable accessible names for
  first-run database creation, unlock, and server onboarding. Do not claim the
  Store accessibility declaration until the full app has been audited.
- Prepare Partner Center notes that explain remote-server orchestration and the
  embedded runtime.
