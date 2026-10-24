# Deploy Dash Desktop App

Flutter desktop control plane for server onboarding, service management, web app
publishing, workers, backups, and day-2 operations.

## Stack

- Flutter desktop app using Riverpod for state
- Yaru desktop styling with Google Sans typography
- Shared desktop UI system in `lib/ui/system/` for theme tokens, section cards,
  rail actions, dialogs, and loading/empty states
- encrypted local SQLite state via Drift and SQLite3MultipleCiphers
- Native bridge integration for the bundled Python backend runtime
- Deep-link handling via `deploydash://...`

## Desktop UI rules

The desktop app follows strict shared UI rules:

- The desktop app follows the repository desktop UI rules.
- Use the shared UI system in `lib/ui/system/` before introducing new local
  card, button, dialog, or state widgets.
- Keep converging on one shared workspace kit for home, project, server,
  onboarding, and settings surfaces rather than letting feature-specific shell
  patterns diverge.
- Keep the desktop tone calm and native-feeling: restrained surfaces, measured
  spacing, moderate rounding, and minimal visual noise.
- Use one spacing scale, one radius scale, one border/surface language, and
  one content-width rhythm across desktop work.
- Design for novice developers first. The default path should feel simple,
  calm, and confidence-building.
- Use progressive disclosure. Show the main task first and keep technical
  detail in secondary reveals, logs, or details views.
- Use sentence case across desktop UI copy.
- Prefer one primary action per section. Filled buttons are for the primary
  action, outlined buttons for secondary actions, and icon-only buttons for
  utilities.
- In contextual row actions where the item is already obvious, icon-only is the
  default for quick verbs like run now, edit, delete, and refresh. The tooltip
  should carry the full action wording.
- Keep section-level and modal primary actions labeled by default. Add/create,
  save, deploy, restore, and similar workflow actions should stay text or
  icon+text unless they are attached directly to a clearly named section title.
- Use text buttons for low-emphasis actions inside dialogs or helper areas.
- Avoid multiple visually competing filled buttons in the same section.
- Reuse shared dialogs and state views instead of recreating local variants
  inside workspace features.
- Reuse the shared dialog/form kit before building local modal forms:
  `AppFormDialog`, `AppDestructiveConfirmDialog`, `AppFormSection`, and the
  `App*FormField` wrappers are the default path.
- Default new modal forms to `TextFormField`-based shared wrappers instead of
  raw `TextField` layouts.
- Whole-section initial loads should use the shared loading state, and empty
  states should use the shared empty-state pattern with a recommended next
  action.
- Avoid backend-facing wording like `task`, `payload`, `workflow`, or
  `operation id` in primary UI copy.

Current rollout direction:

1. shared tokens and theme extensions
2. shared buttons, cards, headers, dialogs, and form fields
3. server workspaces
4. project workspaces
5. home/dashboard and settings cleanup
6. final consistency pass across copy and action hierarchy

Current dialog/form migration order after Database:

1. Backup
2. Workers
3. Services / Scheduler

## Release Channels

The repo now tracks release scaffolds for:

- Ubuntu 24.04 LTS and newer:
  - `.deb`
  - Snap
  - Flatpak / Flathub
- macOS 13 Ventura or newer, on Apple Silicon (`arm64`) and Intel (`x64`) Macs:
  - notarized `.dmg` per architecture
  - Mac App Store
- Windows 10 (64-bit) or later, on `x64` and `arm64`:
  - Microsoft Store via per-arch MSIX
  - no MSI in any automated flow (local manual builds only)

Current state:

- Linux `.deb` is the fully wired packaged release path today.
- Snap, Flatpak, macOS, and Windows packaging scaffolds now exist in-repo.
- The remaining work for macOS and Windows is real-device/store submission
  validation rather than a missing bridge/runtime or process-hardening path.
- The desktop native bridge now comes from shared cross-platform source under
  `ui/shared_native/`.
- Windows release builds stage `bridge.dll`, `python.exe`, console-free worker
  launcher `pythonw.exe`, `python313.dll`, Drift's bundled encrypted SQLite
  `sqlite3mc.dll`, the Python standard library including its `DLLs/` extension
  modules such as `_socket.pyd`, and `data/py/site-packages`.
- Desktop builds package the backend from the same checkout by default and run
  a headless import plus background-task smoke check against the copied runtime
  before the native app bundle is produced.
- macOS release builds stage `libbridge.dylib` plus the embedded Python runtime
  into the `.app` bundle during the Xcode build.
- Desktop packaging and native desktop build rules honor
  `DEPLOYDASH_ORCHESTRATOR_ROOT`, so a separate backend checkout can be wired
  in without changing the current monorepo layout.
- The native bridge now emits structured startup diagnostics for the resolved
  embedded Python layout, including Python home, staged search paths, and
  bundled backend runtime presence plus active process-security controls, so
  packaged runtime failures are easier to debug on Linux/macOS/Windows runners.
- Profile and Release builds apply platform process hardening before Flutter
  or backend work starts. Linux disables dumpability/core files, Windows
  restricts DLL/image loading and verifies PE mitigations, and macOS release
  artifacts require Hardened Runtime plus nested-code signature validation.
  See `../docs/reference/desktop-process-hardening.md`.
- Server onboarding now reads SSH private key files once, imports SSH private key material into Deploy Dash, stores the key material in the encrypted local database, and sends inline private-key payloads at runtime, rather than relying on persisted workstation key paths or temp key files.
- Server onboarding now treats setup as a secure machine-ownership handoff:
  - the managed target user is `ubuntu`
  - Deploy Dash generates and stores a managed SSH keypair during onboarding
  - if onboarding started on another account, Deploy Dash creates or resets
    `ubuntu` into a managed baseline before pivoting to it
  - root login and password SSH are disabled only after a verified fresh
    `ubuntu` key-login succeeds
  - the saved server record is rewritten to the managed `ubuntu` key-based
    identity after setup succeeds
- Server onboarding now fails fast through a verified security checkpoint:
  - minimal bootstrap setup runs first
  - Deploy Dash verifies the managed `ubuntu` connection
  - Deploy Dash applies final SSH hardening and the Docker-safe SSH-only
    firewall baseline
  - only then does the rest of setup continue
- Baseline onboarding now also enables Ubuntu automatic security updates with
  sane defaults and no extra onboarding screens; later overrides live in
  Server Management -> System.
- Host-key mismatch handling in onboarding now uses a plain-language
  confirmation modal that shows the previous and new fingerprints before the
  app refreshes the saved known-host entry.
- Default onboarding still installs Railpack/build tooling, but it now uses
  the repo-pinned Railpack `v0.23.0` release rather than resolving `latest` on
  the server.
- Server Management includes an Updates tab that shows a grouped managed
  capability inventory. Railpack is refreshed as one build system instead of
  exposing its CLI, frontend image, defaults, and helper as separate update
  choices.
- Server Management -> Settings can show the space used by unused Docker
  images and Docker build cache, and can remove either unused set without
  deleting images still used by running containers.
- macOS and Windows protocol callbacks now flow through a shared Dart-owned
  ingress path, with native runners only relaying URIs and buffering startup
  delivery until Flutter is ready.
- GitHub Actions now has a direct-build workflow for signed/notarized macOS
  DMGs per architecture plus a private unsigned Windows Partner Center candidate. Windows Store
  outputs are never attached to a public GitHub Release.

Released desktop packages also include an anonymous signed update check. App
Settings shows the installed version, update availability, release notes, and
the platform-owned update action. The check sends only platform, architecture,
distribution, channel, version, build, database schema, and protocol. It does
not send the local device UUID or any server/project data. The full contract is
documented in [`../docs/contracts/desktop-update-contract.md`](../docs/contracts/desktop-update-contract.md).

## GitHub OAuth Local Setup

Create the local define file:

```bash
cd ui
cp config/dart-defines.local.example.json config/dart-defines.local.json
```

Set the GitHub OAuth credentials in
`config/dart-defines.local.json`:

- `DEPLOYDASH_GITHUB_CLIENT_ID`
- `DEPLOYDASH_GITHUB_CLIENT_SECRET`

Run locally with the define file:

```bash
cd ui
flutter run -d linux --dart-define-from-file=config/dart-defines.local.json
```

Release run example:

```bash
cd ui
flutter run -d linux --release --dart-define-from-file=config/dart-defines.local.json
```

Notes:

- GitHub callback URL must be `deploydash://callback`
- pending OAuth state is persisted locally so browser redirects can be handled
  on cold launch, not only while the app is already open
- `config/dart-defines.local.json` is gitignored and must stay local
- `DEPLOYDASH_SHOW_MANUAL_GITHUB_CALLBACK` can be set to `"true"` for local
  debugging
- `DEPLOYDASH_GITHUB_ENABLE_DEPLOY_KEY_WRITE` controls live deploy-key write
  behavior
- on macOS and Windows, native runner relay paths feed the same Dart protocol
  ingress so the existing app session can complete OAuth without moving session
  logic out of Riverpod

## Local Database

Deploy Dash stores local app state in an encrypted SQLite database named
`deploydash_state.db`. Drift packages SQLite3MultipleCiphers through its
native-asset support and configures SQLCipher v4 compatibility so existing
Deploy Dash databases and exports remain readable.

Resolved path:

- stored under the platform application support directory (single local data
  root for the encrypted database, device identity, and SSH known_hosts)
- layout under that root:
  - `deploydash_state.db`
  - `device_identity.json`
  - `ssh/known_hosts`
- Linux: typically `~/.local/share/com.deploydash.desktop/`
- macOS: typically `~/Library/Application Support/com.deploydash.desktop/`
- Windows (direct/MSI): under `%APPDATA%` from the app VERSIONINFO
- Microsoft Store builds store it under package-managed Windows `LocalState`
  so updates preserve it and package removal deletes it
- the desktop app publishes that root to the embedded Python runtime as
  `DEPLOYDASH_DATA_DIR` before engine/SSH work starts
- Deploy Dash does not use `~/.deploydash` for local workstation state

The current local schema also persists:

- GitHub pending OAuth state for cold-launch callback recovery
- SSH operation recovery snapshots for restart recovery, stored inside the
  encrypted app database rather than a plaintext temp file
- project domain routing mode for canonical apex/`www` deploy behavior
- server, project, env var, worker, backup, scheduler, and terminal state
- one stable local device record plus per-device update cache/dismissal state;
  existing app preferences remain installation-wide in the free tier

## Restore After Reinstall (Downloaded Backup File)

If the OS has been reformatted or local state is gone, restore from a downloaded
backup file before creating a new workspace.

Startup UI path:

1. Launch Deploy Dash.
2. Click the bottom-left restore icon on the startup screen.
3. Select a downloaded `deploydash_state_*.db` file.
4. Click `Restore`.
5. Enter the original database passphrase to unlock.

This installs the backup as the local database in the app support directory.
The restore operation also clears stale `-wal` and `-shm` sidecar files.

After unlock, Deploy Dash now lands on a top-level `Home` dashboard instead of
opening a project immediately. Home is the full local directory: saved servers
form the master list, the selected server's projects form the detail list, both
lists gain a filter field once they grow, and the quick actions stay at the top.
Successful project deletion also routes back to this Home screen so users do not
accidentally continue inside another project's settings tab.

The left rail is now a "where you just were" surface rather than a full project
list. It contains `Home`, a search field, recent projects grouped by project
with their recently visited screens nested underneath, a contextual row for the
current server that opens Server Management, and `Settings`. Recent visits are
stored in the encrypted local database, capped at ten screens, and pruned when a
project is deleted.

Search covers saved servers, projects, and project screens using only local
database values. `Ctrl+K` (`Cmd+K` on macOS) focuses it from any screen, arrow
keys and `Enter` pick a result, and `Escape` closes the results. Opening a
project from Home or from search resumes its last visited screen.

Project deletion writes a durable local cleanup record before changing the
server. If SSH or a remote cleanup step fails, the project is hidden from normal
use and Home offers `Retry cleanup`. The local project catalog is retained until
remote cleanup succeeds, unless the user explicitly confirms that Deploy Dash
should remove only the local record while remote resources may remain.

Backup snapshots now also include embedded metadata in
`deploydash_backup_metadata` (format version, created timestamp, source schema
version, and app build identifiers) for restore diagnostics.

## Database Export And Password Change

App Settings now exposes two local-first database management actions:

- `Export encrypted database file`
- `Change password`

Current behavior:

- local export writes an encrypted `deploydash_state_*.db` snapshot directly to
  a user-selected workstation path
- local export uses the same encrypted snapshot format and embedded
  `deploydash_backup_metadata` table as S3 backups
- password change rekeys the local encrypted database in place and keeps the
  current app session usable
- future unlocks, S3 backups, and local exports use the new password
- previously exported or downloaded database files still require the old
  password

## Reset Local State

To clear local Deploy Dash state:

```bash
cd ui
bash scripts/reset_state_db.sh
```

Optional: remove a specific DB path directly:

```bash
cd ui
bash scripts/reset_state_db.sh /absolute/path/to/deploydash_state.db
```

The script also removes matching `-wal` and `-shm` files.

## Web App Domain Routing

The desktop app currently supports first-class canonical host routing for web
app deploys:

- `single_host`
- `redirect_www_to_apex`
- `redirect_apex_to_www`

The selected mode is persisted with the project bucket and sent to the backend
when publishing through Caddy.

## Agent Access

App Settings now includes `Agent Access` for local AI tooling integration.

Current behavior:

- the desktop app can bind a localhost MCP endpoint at `http://127.0.0.1:46337/mcp` once the encrypted local database is unlocked
- permission modes are `Read-only` and `Read-only + redeploy`
- only one redeploy-capable session can be active at a time; revoke the current session before issuing another
- redeploy-capable sessions are short-lived and expose a bearer token that redeploy-capable MCP clients must send
- repository selection is constrained to the connected GitHub repository list; hostname behavior and runtime are fixed agent-selectable options
- recent agent actions, current running app tasks, and recent app task results are visible in the same settings card
- redeploy requests return the underlying `app/run` task handle immediately so MCP clients can follow progress through task status, event, and result tools
- the repo includes end-user Agent Access skill docs at
  `../DEPLOYDASH_SKILL.md` and in the standalone publishable skill repo
  `../deploydash-agent-access-skill/`

## Web App Runtime Selection

Web app deploy settings now store an explicit Railpack runtime/provider for
language-neutral onboarding.

Current runtime options:

- Auto-detect
- Node.js
- Python
- PHP
- Ruby
- Go
- Java
- Rust
- .NET
- Deno
- Elixir
- Shell
- Static site

Behavior:

- selecting a runtime lets Deploy Dash pass an explicit Railpack provider
  during deploy instead of relying on repo guessing
- build/run commands are no longer required for non-Node runtimes
- blank build/run commands mean "use provider defaults"
- Node.js still pre-fills `npm run build` and `npm run start`, but those can be
  cleared to fall back to Railpack detection

## One-Off App Commands

The Web app workspace can now run a one-off non-interactive command inside the
managed app container for a deployed project.

Current behavior:

- intended for app-scoped maintenance tasks such as `npm run db:migrate`
- runs through the existing app runtime workflow as `app/exec`
- automatically inherits the running app process `PATH`, so plain
  `npx`/`npm`/runtime-tool commands do not need a manual `/proc/1/environ`
  prefix
- streams stdout/stderr into the workspace and stores the output in terminal
  history as `app_exec`
- returns the final exit code, supports cancellation, and keeps a timestamped recent-command list for the current workspace session
- disabled for `staticfile` apps and for projects without a running app
  container
- desktop-user-only in this phase; not exposed through Agent Access / MCP

## Build Linux `.deb`

Build a Debian package from the Flutter Linux release bundle:

```bash
cd ui
bash scripts/build_deb.sh
```

For the full local remove/build/reinstall flow:

```bash
cd ui
bash scripts/reinstall_deb.sh
```

Current packaging behavior:

- runs `flutter build linux --release --dart-define-from-file=config/dart-defines.local.json`
- packages `build/linux/x64/release/bundle/` into a Debian filesystem layout
- writes output to `ui/build/deb/`
- installs the desktop launcher as `com.deploydash.desktop.desktop`

The direct-build workflow installs the resulting package on an Ubuntu 24.04
runner, launches it in an isolated Xvfb session, and uninstalls it. Run the
same fast installed-artifact smoke test locally after a build:

```bash
bash qa/e2e/runners/run_deb_install_smoke.sh --skip-build
```

Run this only in CI or on a disposable host: it removes any installed
`deploydash` package during cleanup.

For release-candidate sign-off, use the two-VM installed-package journey. It is
implemented by the cross-platform desktop release baseline with Linux AT-SPI
and Debian adapters. It validates a clean candidate install, encrypted database
creation and restart/unlock, onboarding and server postconditions, then restores
pristine VM snapshots for the A-to-B upgrade and uninstall/reinstall retention
lane. It stores classified, redacted reports and evidence under
`qa/e2e/local/runs/desktop-release/`:

```bash
bash qa/e2e/runners/run_deb_release.sh
```

The command needs `multipass` with snapshot support and no longer depends on a
local `launch-vm` helper. It deliberately does not test GitHub or app
deployment; those are covered by the separate workflow E2E suite. Failures
retain both disposable VMs automatically.

For channel-specific release checklists and store metadata prep, see:

- `RELEASING.md`
- `packaging/STORE_SUBMISSION_CHECKLIST.md`
- `packaging/STORE_METADATA_TEMPLATE.md`

## Build Snap

```bash
cd ui
bash scripts/build_snap.sh
```

Current behavior:

- builds the Flutter app and bundled Python runtime inside a clean Snapcraft
  LXD environment instead of repackaging a host-built bundle
- emits a deterministic versioned amd64 artifact under `build/snap/`
- uses strict confinement and the `core24` base from
  `packaging/snap/snapcraft.yaml`
- lints and inspects the final SquashFS artifact before reporting success

Before promoting a Store candidate, run the two-VM installed-package gate:

```bash
bash qa/e2e/runners/run_snap_release.sh
```

It tests Store installation/refresh, automatic snapshot restore, purge reset,
and exact-revision promotion. Setup and operator details live in
`qa/e2e/runbooks/snap-release.md`.

## Build Flatpak

```bash
cd ui
bash scripts/build_flatpak.sh
```

Current behavior:

- consumes the existing Linux release bundle
- uses the Flatpak manifest at
  `packaging/flatpak/com.deploydash.desktop.yml`

## Build macOS Artifacts

Run these on macOS:

```bash
cd ui
DEPLOYDASH_MACOS_ARCH=x64 bash scripts/build_macos_dmg.sh
```

Set `DEPLOYDASH_MACOS_ARCH` to `arm64` (default) or `x64`; the DMG is
named `DeployDash-vX.Y.Z-{arm64,x64}.dmg` from `DEPLOYDASH_BUILD_NAME`
(the production chain fails closed without it; `--package-only` keeps
the unversioned name for local work).

This is the normal production DMG command. It rebuilds with the Tidy
Technology Ltd Developer ID identity, signs the DMG, submits it to Apple,
staples the notarization ticket, and validates the finished artifact. It uses
the `deploydash-notary` Keychain profile by default.

Lower-level signing-only command for diagnosing a failure before notarization:

```bash
cd ui
bash scripts/rebuild_macos_dmg.sh
```

```bash
cd ui
DEPLOYDASH_MACOS_NOTARY_PROFILE=deploydash-notary \
  bash scripts/notarize_macos_dmg.sh
```

```bash
cd ui
bash scripts/build_macos_app_store.sh
```

Current behavior:

- the bundle identifier is `com.deploydash.desktop`
- the app registers `deploydash://callback`
- `build_macos_dmg.sh` is the production direct-distribution path: it rebuilds,
  Developer ID signs, notarizes, staples, and validates the DMG
- `build_macos_dmg.sh --package-only` is reserved for the lower-level rebuild
  flow and unsigned CI artifact jobs; it does not notarize
- macOS packaging fails closed when no suitable Keychain identity is available;
  ad-hoc signatures cannot satisfy Hardened Runtime library validation
- `rebuild_macos_dmg.sh` rebuilds the `.app`, signs all nested code, the outer
  app, and the DMG with the Tidy Technology Ltd Developer ID identity, and
  verifies both signatures in one step; set
  `DEPLOYDASH_MACOS_DMG_SIGN_IDENTITY` only to override that default
- `notarize_macos_dmg.sh` submits the signed DMG to Apple notarization, waits
  for approval, staples the DMG, and validates the stapled artifact
- App Store export uses
  `packaging/macos/ExportOptions.appstore.plist.template`
- App Store builds default to Apple Team `CAZ3ADRS95` and read their build
  name and number from the release tag via the shared metadata helper;
  never hand-pick a build number

## Build Windows Artifacts

Run these on Windows:

For a local debug build, use the wrapper. It clears stale CMake state by
default, uses Drift's native SQLite asset configuration, and resolves Python
3.13.14 through `uv`; no separately installed system `python`, vcpkg, or OpenSSL
setup is required for the local database.

```powershell
cd C:\dev\deploydash\ui
powershell -ExecutionPolicy Bypass -File scripts/build_windows_debug.ps1
```

The wrapper verifies the completed bundle, including Drift's bundled encrypted
SQLite `sqlite3mc.dll`, before it reports a successful build.

Use `-SkipClean` only for subsequent builds when the CMake dependency
configuration has not changed.

For release packages:

```powershell
cd ui
powershell -ExecutionPolicy Bypass -File scripts/build_windows_msi.ps1
```

To Authenticode-sign the bundle and MSI, install the signing certificate in
the Windows certificate store and set:

```powershell
$env:DEPLOYDASH_WINDOWS_SIGN_CERT_SHA1="<certificate thumbprint>"
$env:DEPLOYDASH_WINDOWS_SIGNING_REQUIRED="1"
```

```powershell
cd ui
powershell -ExecutionPolicy Bypass -File scripts/build_windows_store.ps1
```

Current behavior:

- MSI uses the WiX template at `packaging/windows/wix/DeployDash.wxs`
- MSIX uses the Store manifest at
  `packaging/windows/msix/Package.appxmanifest`
- both package scripts reject Release binaries missing ASLR, high-entropy VA,
  DEP/NX, or Control Flow Guard flags
- MSI signing is performed when a certificate thumbprint is configured and
  fails closed when `DEPLOYDASH_WINDOWS_SIGNING_REQUIRED=1`
- Store packaging always uses the immutable Partner Center identity and emits
  versioned unsigned `DeployDash_<X.Y.Z.0>_x64` `.msixupload`, `.msix`,
  `.appxsym`, and hashed build-manifest artifacts; Partner Center signs the
  accepted Store package
- the embedded Windows Python runtime excludes unused Tcl/Tk GUI components;
  the backend remains headless and their binaries prevent MSIX signing
- `build_windows_store_e2e_pair.ps1` creates separate disposable self-signed
  packages for App Installer/WACK testing and never creates a publishable
  artifact
- `qa/e2e/runners/run_windows_store_release.sh` exclusively leases the existing
  `win11` QA VM, runs App Installer, first-run database, onboarding, restart,
  upgrade, protocol, WACK, uninstall, and reinstall checks serially, and
  provisions only the disposable Ubuntu managed-server target

## GitHub Actions

- test gates (`ci.yml`) run on every pull request and push to `main`;
  builds run on `v*` tags through `release.yml` (plus manual
  `workflow_dispatch`)
- Windows Store submission and certification run after QA publication
  (`store-submit.yml`, `store-cert-watch.yml`)

## Validate Release Scaffolds

```bash
cd ui
bash scripts/validate_release_scaffolds.sh
```

If the release bundle already exists and you only want to package it:

```bash
cd ui
bash scripts/build_deb.sh --skip-build
```

If you want the same reinstall flow without rebuilding the Linux bundle:

```bash
cd ui
bash scripts/reinstall_deb.sh --skip-build
```

Optional environment overrides:

- `DEB_PACKAGE_NAME`
- `DEB_BINARY_NAME`
- `DEB_APP_DISPLAY_NAME`
- `DEB_APP_ID`
- `DEB_MAINTAINER`
- `DEB_DESCRIPTION`
- `DEB_DESCRIPTION_LONG`
- `DEB_HOMEPAGE`
- `DEB_SECTION`
- `DEB_PRIORITY`
- `DEB_ARCHITECTURE`
- `DEB_DEPENDS`

## Development Checks

Before writing or changing tests, read
[`AGENTS.md`](../AGENTS.md#testing-guidelines). The two rules that override any
local habit: **a test that has never failed is not known to work** (prove every
new test can fail, red-first or mutation-checked, and say which in the commit
message), and **pick the discipline that matches the work** — contract-first
for new behaviour, characterization for pure refactors, census for deletions.

Dart and Flutter style also follows the engineering half of
[Flutter's AI rules](https://raw.githubusercontent.com/flutter/flutter/refs/heads/main/docs/rules/rules.md).
Deploy Dash's conformance, deliberate deviations, and the visual rules it
rejects are recorded in
[`docs/reference/flutter-dart-rules-conformance.md`](../docs/reference/flutter-dart-rules-conformance.md).


```bash
cd ui
flutter analyze
flutter test
```

Run code generation after Drift or annotated model changes:

```bash
cd ui
flutter pub run build_runner build
```

## License

This desktop source tree is covered by the repository-root AGPL-3.0
`LICENSE`. Third-party packages,
generated artifacts, and imported assets keep their respective upstream
licenses.
