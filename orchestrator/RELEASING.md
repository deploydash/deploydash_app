# Releasing `orchestrator`

This document defines the backend package release workflow, desktop-app pin
update process, and the architecture checks that should happen before cutting a
new backend package release.

## Preconditions

- Clean git working tree in the backend repository or subtree.
- Access to the internal Python package index.
- `uv` installed.
- Python 3.13.14 available for the backend venv.

## Release Checklist

Before publishing a release, confirm all of the following:

- The workstation hooks are installed with
  `git config core.hooksPath .githooks`: pre-commit runs the seconds-only
  checks (Ruff, formatting, workflow secret-masking and duplicate-key scans,
  staged-Dart formatting), and pre-push runs the full under-5-minute gate
  (pre-commit checks plus mypy, the full backend suite including backend
  architecture invariants, Flutter analysis and tests, scaffold validation,
  and generated-code freshness) before every push.
- From a clean checkout with `qa/e2e/local/e2e.env`, run the required pre-tag
  release tier: `bash qa/e2e/runners/run_linux_full_suite.sh`, every scoped
  `*coverage*.sh` gate under both `orchestrator/scripts/` and
  `ui/scripts/`, and `cd ui && flutter test` (including the
  Dart architecture invariants).
- On a `v*` tag, GitHub Actions runs the release workflows, including the
  macOS and Windows legs. `workflow_dispatch` remains available for an
  on-demand hosted check.
- `pyproject.toml` version and `CHANGELOG.md` are updated.
- The backend test suite passes with explicit unittest discovery.
- The runtime bundle can be rebuilt from the published package or local wheel.
- `engine.py` remains a bootstrap module and has not quietly re-accumulated
  workflow dispatch logic.
- Every WAL-G and pg_search asset name and SHA-256 digest in
  `src/orchestrator/platform_versions.py` matches the selected publisher
  release, and the pgvector pin is the immutable commit for its selected tag.

When refreshing PostgreSQL support downloads, review the publisher's GitHub
release metadata and update each version, architecture-specific asset name,
and `sha256:` digest together. Keep separate WAL-G host and image-build pin
records even when a release uses the same artifact in both contexts. Resolve
the pgvector tag to its full commit and update that immutable commit instead
of passing a mutable tag to the image build. Then run:

```bash
cd orchestrator
uv run python -m unittest tests.postgres_supply_chain_test
bash scripts/backup_coverage.sh
./scripts/managed_software_coverage.sh
```

Do not publish when an architecture is missing a reviewed asset and digest, a
renderer contains a release-API lookup or fallback candidate loop, or either
host and image-build checksum-failure assertion is absent.

The last point is intentional. A release is a good forcing function to catch
architecture regressions before they get normalized.

macOS- and Windows-only regressions are intentionally detected at release
time rather than on every branch push. For this pre-1.0 private repository,
that keeps the cross-platform workflows affordable enough to remain enabled;
a failing tag blocks the release rather than allowing an unobserved defect to
ship.

## 1) Validate Backend Before Cutting The Release

Run the full backend test suite with discovery:

```bash
cd orchestrator
uv run python -m unittest discover -s tests -p '*_test.py'
```

For changes that touch runtime bootstrap, plugins, workflow dispatch, or the
public `engine` contract, also run the focused engine suites:

```bash
cd orchestrator
uv run python -m unittest \
  tests.engine_test \
  tests.architecture.engine_contract_guardrails_test \
  tests.orchestrator_runtime_test
```

For post-Milvus workflow-registry or bootstrap changes, also run:

```bash
cd orchestrator
./scripts/post_milvus_removal_coverage.sh
```

Plain `uv run python -m unittest` is not sufficient in this repository because
it currently does not discover the test suite.

For database-dispatch changes, also run the database coverage gate:

```bash
cd orchestrator
./scripts/database_coverage.sh
```

For managed server software update, rollback, or container-readiness changes,
also run:

```bash
cd orchestrator
./scripts/managed_software_coverage.sh
```

This gate now also enforces 100% coverage for the release-critical helper
modules that desktop packaging relies on:

- `src/orchestrator/release_helpers.py`
- `src/orchestrator/runtime_bundle.py`

For Railpack contract, app build planning, or managed Railpack update changes,
also run the symbol-owned Railpack gate:

```bash
cd orchestrator
./scripts/railpack_deploy_coverage.sh
```

## 2) Architecture Review Before Publishing

Before every release tag, and after each phase of
`docs/implementation-plans/pre-1.0-architecture-tasks.md` closes, run the
recurring architecture audit described in
`docs/contracts/architecture-invariants.md`. Record its dimensions, clean
measurements, findings, and next rotation position in that contract. A finding
that is a class of defect blocks the audit until it has produced a new
architecture invariant; fixing only the currently observed instances is not a
closure.

If the release touched backend internals, do a short architecture review:

- `src/orchestrator/engine.py` should contain bootstrap wiring, compatibility
  exports, and default runtime initialization only.
- Workflow dispatch belongs in `src/orchestrator/plugins/`.
- Shared request parsing and validation helpers belong in
  `src/orchestrator/engine_dispatch_support.py` or a workflow-local helper.
- Workflow execution belongs in `src/orchestrator/engine_*_ops.py` modules or
  their future subpackages.
- Workflow metadata and config parsing belong in the relevant `*_parts/`
  packages.

If you see new workflow-specific handler code being added directly to
`engine.py`, treat that as release-blocking technical debt and move it before
publishing.

## 3) Cut Backend Package Release

1. Update version in `pyproject.toml`.
2. Append release notes in `CHANGELOG.md`.
3. Build the wheel:
   ```bash
   cd orchestrator
   ./scripts/build_wheel.sh
   ```
4. Publish the wheel to the internal index using your organization's standard
   artifact publishing flow.

## 4) Update Desktop App Pinned Version

1. Set the new version pin:
   ```bash
   cd orchestrator
   ./scripts/pin_orchestrator_version.sh <new-version>
   ```
   If the backend and desktop repos are split, set
   `DEPLOYDASH_BACKEND_VERSION_FILE` to the pin file in the current checkout.
2. Build the current checkout as a wheel and populate the desktop bundled
   runtime:
   ```bash
   ./scripts/prepare_desktop_runtime_bundle.sh
   ```
   The bundle preparation step also imports the copied runtime with GUI-style
   missing or invalid console streams and completes a background echo task.
   Packaged Profile/Release processes also fail closed when the native runner
   or Python worker cannot verify required process hardening.
3. To validate an explicitly published package instead of the current
   checkout:
   ```bash
   ORCHESTRATOR_PACKAGE_SOURCE=published \
   ORCHESTRATOR_ALLOW_LOCAL_FALLBACK=0 \
   ./scripts/prepare_desktop_runtime_bundle.sh
   ```

The desktop packaging workflows and scripts now share the release contract
helpers in `src/orchestrator/release_helpers.py` through:

- `scripts/prepare_desktop_runtime_bundle.py`
- `scripts/release_contracts.py`
- `scripts/resolve_build_metadata.py`

The same helpers own the Windows Store package identity and version contract.
Store builds must validate the rendered Appx manifest and write the hashed
`.msix`/`.appxsym`/`.msixupload` handoff manifest through
`scripts/release_contracts.py`; PowerShell release scripts must not duplicate
or override those values.

Legacy `DEPLOYDASH_ENGINE_*` environment variable names are still accepted for
compatibility, but new documentation and automation should use `ORCHESTRATOR_*`.

## 5) Validate Desktop Parity Before Shipping

After updating the pin and rebuilding the runtime bundle:

```bash
cd orchestrator
uv run python -m unittest discover -s tests -p '*_test.py'
```

Optional Linux bundle validation:

```bash
cd ui
flutter build linux --release
```

If the backend release changes payload contracts, workflow IDs, event shapes, or
runtime bootstrap behavior, also run the affected desktop integration and UI
tests before shipping the desktop app.

For embedded process-security changes, also run:

```bash
cd ui
./scripts/process_security_diagnostics_coverage.sh
./scripts/native_process_security_coverage.sh
cd ..
bash qa/e2e/runners/run_platform_security.sh
```

## 6) Ship Desktop Release

After parity checks pass, proceed with the desktop app release process.

## Future Modularization Policy

Use releases to enforce modular code, not just package versioning.

When preparing a backend release:

- Prefer adding new workflows through a plugin module and workflow metadata
  package rather than extending `engine.py`.
- Split oversized `engine_*_ops.py` modules by responsibility before they become
  another bootstrap-scale file.
- Keep patchable compatibility surfaces stable for tests and desktop runtime
  consumers.
- Update this document and `README.md` when the runtime architecture or release
  validation steps change.
