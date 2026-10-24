# Changelog

All notable changes to `orchestrator` are documented in this file.

The format is based on Keep a Changelog and this project follows Semantic
Versioning.

## [0.1.0] - 2026-03-03

### Added
- Initial `orchestrator` package scaffold in `src/orchestrator`.
- Framework runtime components:
  - `runtime.EngineRuntime`
  - `plugins.base.WorkflowPlugin`
  - `registry` helper utilities
  - `compat` request target resolution.
- Plugin builders for workflow domains:
  `core`, `server`, `setup`, `http`, `dns`, `postgres`, `app`,
  `firewall`, and `scheduler`.
- Public API entrypoints:
  - `api.build_runtime`
  - `api.build_default_runtime`
  - `api.handle_request`
- Wheel build script: `scripts/build_wheel.sh`.
- Monorepo subtree export script: `scripts/export_subtree_to_remote.sh`.
