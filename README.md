# Deploy Dash

Deploy Dash is a desktop control plane for deploying and operating web apps on your own Ubuntu servers.

This repository holds everything needed to build the app: the [Flutter](https://github.com/flutter/flutter) desktop
application, the [Pyinfra](https://github.com/pyinfra-dev/pyinfra) package used for server orchestration, and
their test suites.

## Repository contents

- `ui/`: Flutter desktop application, cross-platform packaging
  scripts, and the Dart test suite (`test/`, `integration_test/`).
- `orchestrator/`: Pyinfra package for local request dispatch and
  remote server orchestration, with its unit tests under `tests/`.
- `.github/workflows/`: continuous integration and release automation.

## Build from source

Pyinfra package:

```bash
cd orchestrator
uv sync
./scripts/build_wheel.sh
./scripts/prepare_desktop_runtime_bundle.sh
```

Linux desktop package:

```bash
cd ui
flutter pub get
bash scripts/build_deb.sh
```

macOS desktop package (unsigned local build, must run on macOS):

```bash
cd ui
flutter pub get
bash scripts/build_macos_dmg.sh --package-only
```

Windows desktop package (unsigned local build, must run on Windows in PowerShell):

```powershell
cd ui
flutter pub get
.\scripts\build_windows_msi.ps1
```

Signed and notarized artifacts need the release credentials: a Developer ID
identity plus a `notarytool` Keychain profile for macOS (drop
`--package-only`), and `DEPLOYDASH_WINDOWS_SIGN_CERT_SHA1` for Windows.

## Tests

Every pull request and push to `main` runs the full Dart and Python suites:

```bash
cd ui && flutter analyze && flutter test
cd orchestrator && uv run python -m unittest discover -s tests -p '*_test.py'
```

Releases are cut from version tags (`vX.Y.Z`). The tag is the single source
of truth for the release version; the build number is the release
workflow's run number. A tag runs the suites, builds all platforms, stages
a draft release, and hands it to the quality assurance test suite
(detailed below); the draft flips to published only after QA reports
success.

## Quality assurance test suite

Every release candidate is certified by a private end-to-end suite before
it can publish. The suite tests the exact artifacts users install — the
Linux packages, the Windows Store package, and the notarized macOS disk
image — never development builds.

Coverage is click-driven and server-real: platform UI harnesses drive the
actual application through onboarding and deployment flows, provisioning
disposable servers and then independently verifying the server
state rather than trusting the app's own report. Package lifecycles,
production-safety gates, and a tracked manual checklist across every app
surface complete the matrix.

The suite currently runs more than 300 automated harness and runner
checks against a 184-surface coverage matrix.

A release stays a draft until this suite reports success, so a published
version means a version that has already onboarded a real server end to
end.

## Release secrets

The tag pipeline consumes these repository secrets (all masked in logs;
publish jobs run only on tags under the `release` environment):

- `DEPLOYDASH_GITHUB_CLIENT_ID`, `DEPLOYDASH_GITHUB_CLIENT_SECRET`,
  `DEPLOYDASH_SHOW_MANUAL_GITHUB_CALLBACK`,
  `DEPLOYDASH_GITHUB_ENABLE_DEPLOY_KEY_WRITE`,
  `DEPLOYDASH_AMPLITUDE_API_KEY` — compiled into release
  builds via a generated dart-defines file that is never uploaded.
- `DEPLOYDASH_APPLE_ID`, `DEPLOYDASH_APPLE_TEAM_ID`,
  `DEPLOYDASH_APPLE_APP_PASSWORD`,
  `DEPLOYDASH_MACOS_SIGN_CERT_P12_BASE64`,
  `DEPLOYDASH_MACOS_SIGN_CERT_P12_PASSWORD` — macOS signing and
  notarization.
- `AZURE_AD_TENANT_ID`, `AZURE_AD_APPLICATION_CLIENT_ID`,
  `AZURE_AD_APPLICATION_SECRET` — Microsoft Store submission
  service principal.
- `QA_DISPATCH_TOKEN` — personal access token with `repo` scope on
  `deploydash/deploydash_tests`, used to request QA validation and to
  receive its result.

## Configuration

Copy `ui/config/dart-defines.local.example.json` to
`ui/config/dart-defines.local.json` for local builds that need OAuth
or analytics configuration. Do not commit local secrets. CI generates this
file from repository secrets.

## License

Deploy Dash is released under the GNU Affero General Public License version 3.
See `LICENSE`.
