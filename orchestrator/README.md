# Backend App Package

Standalone packaging root for the `orchestrator` Python package.

This package is the backend execution layer for Deploy Dash. The desktop app
invokes it through the bundled runtime, while local development can run it
through the `orchestrator` CLI.

## Stack

- Python 3.13.14 (pinned via `.python-version`)
- `uv` for environment and command execution
- pyinfra-backed remote orchestration
- unittest-based test suite

## What This Package Owns

`orchestrator` owns:

- workflow registry metadata and legacy action aliases
- request dispatch and runtime bootstrapping
- plugin-based workflow handlers for:
  - `core`
  - `server`
  - `setup`
  - `http`
  - `dns`
  - `postgres`
  - `mail`
  - `app`
  - `firewall`
  - `scheduler`
- pyinfra-backed server operations and workflow planning
- CLI entrypoints for direct payload execution and local backend testing
- the packaged Python runtime copied into the desktop app bundle

## Layout

- `src/orchestrator/`: package source
- `src/orchestrator/runner.py`: CLI entrypoint exposed as `orchestrator`
- `src/orchestrator/workflow_registry.py`: workflow registry and legacy aliases
- `src/orchestrator/engine_bootstrap.py`: plugin registration and runtime
  assembly
- `src/orchestrator/plugins/`: workflow-specific dispatch plugins
- `src/orchestrator/*_parts/`: workflow metadata, config parsing, and step-plan
  builders
- `src/orchestrator/engine_*_ops.py`: operational execution modules
- `tests/`: unit tests
- `scripts/build_wheel.sh`: wheel build helper
- `scripts/prepare_desktop_runtime_bundle.py`: cross-platform runtime bundle
  builder used by desktop packaging flows
- `scripts/prepare_desktop_runtime_bundle.sh`: shell wrapper for the Python
  runtime bundle builder
- `scripts/managed_software_coverage.sh`: focused 100% line-and-branch
  coverage gate for managed BIND, WAL-G, PostgreSQL update/rollback,
  rollback-backup hygiene, and readiness behavior
- `scripts/dns_runtime_coverage.sh`: focused 100% line-and-branch coverage gate
  for authoritative DNS runtime readiness and host-published answer checks
- `scripts/railpack_deploy_coverage.sh`: symbol-owned 100% line coverage gate
  for the pinned Railpack contract, deploy planning/execution, and managed
  server tooling handlers; named-function targets prevent source line movement
  from silently invalidating the gate
- `scripts/release_contracts.py`: shared CLI wrapper for release artifact and
  Flutter build-argument contracts used by desktop packaging scripts,
  including immutable Windows Store identity, `X.Y.Z.0` versioning, Appx
  manifest validation, and hashed Partner Center handoff metadata
- `scripts/resolve_build_metadata.py`: shared CI build metadata resolver used by
  GitHub Actions release workflows
- `scripts/pin_orchestrator_version.sh`: update the backend package pin
  (`DEPLOYDASH_BACKEND_VERSION_FILE` can redirect the pin file when the
  desktop and backend repos are split)
- `scripts/export_subtree_to_remote.sh`: export subtree history to a separate
  backend repository

## Workflow Surface

Current workflow domains are defined in
`src/orchestrator/workflow_registry.py`. It is the single source of
operation truth: every request addresses one `workflow_id`/`operation_id`
pair via the `run_workflow` action — there are no other action strings.
Five legacy bespoke action strings (`echo`, `check_server`,
`refresh_server_host_key`, `describe_setup`, `setup_server`) were removed in
T-1.5.2; they no longer exist anywhere in this codebase.

Implemented workflow groups include:

- `setup`: `describe`, `run`
- `server`: `check`, `refresh_host_key`, `overview_metrics`,
  `system_status`, `system_apply`, `system_restart`, `docker_storage_status`,
  `docker_storage_prune`, `tooling_status`, `tooling_update`,
  `tooling_rollback`
- `postgres`: service lifecycle, project DB/user, backup and restore
  operations
- `mail`: workflow metadata is registered, but runtime depth is still limited
- `dns`: DNS stack operations
- `http`: HTTP gateway and Caddy operations
- `app`: web app deploy, versioned release inventory/rollback, runtime logs,
  resource usage, one-off commands, and worker operations
- `firewall`: status, scoped staging, commit, and rollback operations; rollback
  restores only Deploy Dash-managed chains and their parent jumps, so newer
  Docker, fail2ban, and operator rules remain untouched
- `scheduler`: task CRUD, run-now, and enable/disable operations
- `core`: `echo`

Every workflow's `settings` object follows one rule: the wire carries intent,
not infrastructure. Which keys a caller may send, which are resolved by the
server and rejected if sent, and what the `resolved_config` response block
contains are documented in
[`docs/contracts/settings-ownership.md`](../docs/contracts/settings-ownership.md).
The envelope shape, protocol versioning, error codes, and the
`params_schema` JSON Schema conventions that validate every request before
its handler runs are documented in
[`docs/contracts/engine-protocol.md`](../docs/contracts/engine-protocol.md).

## Engine Dependency Injection (T-2.2.1 and T-3.3.5)

**Status:** implemented. `engine.py` constructs one frozen `EngineContext`
per engine instance and passes that same instance through the engine and
plugin paths. Do not add module-level `_name = None` dependency slots or
`configure_runtime_dependencies()` calls.

### Current boundary

`EngineContext` is deliberately the single broad **construction** shape: it
preserves the established runtime wiring and test seams. Consumer functions do
not use it as their parameter annotation. Instead, they use a
`@runtime_checkable` capability protocol from `engine_context.py`:
`EngineCore` provides the nine dependencies common to several consumers, and
each `Supports*` protocol adds only the fields used by one consumer group.
`engine.py` and `engine_bootstrap.py` are the only permitted concrete-context
annotation boundaries.

The protocol callables have explicit parameter and return signatures; there
are no `Callable[..., Any]` declarations in the protocol layer. The retained
broad callables on the concrete construction dataclass are compatibility
annotations whose individual owners can be tightened separately. The
architecture test in `tests/architecture/engine_context_protocol_test.py`
enforces both boundaries, checks one concrete context against all consumer
protocols, and rejects a broad callable in any protocol.

### The problem

Six modules (`engine_runtime_common.py`, `engine_scheduler_ops.py`,
`engine_firewall_ops.py`, `engine_app_ops.py`, `engine_postgres_ops.py`,
`engine_infra_ops.py`) each declare a handful of `_name = None` module
globals and a `configure_runtime_dependencies(**kwargs)` function that does
`global _name; _name = value` for each. `engine.py` calls the matching
`_sync_*_dependencies()` helper before every delegated call, re-populating
those globals from its own top-level state immediately before use. That is
34 slots across the six modules (verified by enumerating every
`configure_runtime_dependencies` signature: 4 + 5 + 5 + 10 + 5 + 5 = 34),
collapsing to **11 unique dependency names** once duplicates across modules
are merged. The `plugins/*.py` package has the same problem in a different
shape: `build_plugin(*, operations, dependencies)` looks up roughly a dozen
callables from a `dict[str, Any]` by string key, so a typo is a runtime
`KeyError` with no static check.

Consequences, all real and all present today: import order is load-bearing
(a module used before its `configure_runtime_dependencies()` call fails with
`NoneType is not callable`); two engine instances cannot coexist in one
process, because the dependencies live in module globals shared by every
caller; static analysis cannot follow the seam (T-2.1.4 had to leave all six
`engine_*_ops.py` modules on mypy's exclusion list for exactly this reason);
and `engine_postgres_ops.py` has an extra wrinkle — `_sync_postgres_ops_dependencies()`
also does `engine_postgres_ops._run_postgres_psql_query = _run_postgres_psql_query`,
overwriting that module's own `_run_postgres_psql_query = _run_postgres_psql_query_impl`
alias with a wrapper defined in `engine.py`, purely so tests can patch one
name and intercept ~30 internal call sites indirectly through `engine.py`.
That indirection is a symptom of the same problem, not a separate one — see
"What collapses" below.

### Original migration design (historical)

The following is the T-2.2.1 migration record. It explains why the single
runtime instance remains, but its proposed eleven-field declaration and
forward-looking task language have been superseded by the implemented boundary
above.

One frozen dataclass, `EngineContext`, defined in a new module
`src/orchestrator/engine_context.py`:

```python
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, Protocol


class RuntimeSession(Protocol):
    """Whatever create_runtime_session/open_runtime_session hand back today.

    Deliberately Any-shaped for now (matches current behavior exactly) --
    tightening this is out of scope for T-2.2.1 and belongs with whichever
    migration task first needs a precise session type.
    """


@dataclass(frozen=True)
class EngineContext:
    create_runtime_session: Callable[..., Any]
    open_runtime_session: Callable[..., dict[str, Any]]
    error_result: Callable[..., dict[str, Any]]
    emit_event: Callable[..., None]
    sanitize_message: Callable[[str], str]
    emit_shell_output_lines: Callable[..., None]
    command_error_details: Callable[..., str]
    read_remote_file_text: Callable[..., str]
    probe_http_gateway_fast_path: Callable[..., dict[str, Any] | None]
    setup_http_gateway: Callable[..., dict[str, Any]]
    normalize_runtime_log_tail: Callable[..., int]
```

(Exact parameter/return types get filled in against each real implementation
during migration -- the field list and the threading rule below are the part
that needs agreement now.) These are exactly the 11 unique names from the
current 34 `configure_runtime_dependencies` parameters; no new capability is
being added, only a shape for the existing one.

**Threading rule:** every function -- public or private -- that needs any
dependency takes `ctx: EngineContext` as its **first positional parameter**,
and passes `ctx` down to every call it makes that itself needs one. This
applies below the module's public entry points too: `_get_hardware_specs_fast(ctx, host, emit=None)`,
not just `get_hardware_specs(ctx, host, emit=None)`. A function that touches
no dependency, directly or transitively, does not take `ctx` -- do not add it
"for consistency." `ctx.error_result(...)` replaces the module-global
`_error_result(...)` call; `global _error_result` and the `_name = None`
declaration both disappear.

**Plugins use the same type.** T-2.2.8 replaces
`build_plugin(*, operations, dependencies: dict[str, Any])` with
`build_plugin(*, operations, ctx: EngineContext)` across all eight plugin
modules, and every `dependencies["some_name"]` lookup becomes `ctx.some_name`.
One type serves both call paths (`engine.py` -> `engine_*_ops.py`, and
`engine_bootstrap.py` -> `plugins/*.py`) -- there is no second, plugin-specific
context type.

**Construction happens once per engine instance**, in `engine.py` (or
`engine_bootstrap.py`, whichever ends up holding it after T-2.2.10 removes
the `_sync_*` plumbing -- that call site decision is small and can be made
during T-2.2.2, not here), from `engine.py`'s own real implementations of
`error_result`, `emit_event`, `sanitize_message`, and the handful of
functions `engine_runtime_common.py` owns
(`open_runtime_session`, `read_remote_file_text`, `command_error_details`,
`emit_shell_output_lines`, `probe_http_gateway_fast_path`,
`normalize_runtime_log_tail`). That `EngineContext` instance is then the one
value threaded through every subsequent call, in both engine modules and
plugins.

### What collapses

`engine_postgres_ops.py`'s `_run_postgres_psql_query`/`_run_postgres_psql_query_impl`
indirection (see "The problem" above) exists only so a test can patch one
attribute and intercept every internal caller. Under `ctx` threading this
need disappears: a test constructs an `EngineContext` with a fake
`error_result`/`emit_event`/etc. and calls the function under test directly
-- no module-attribute patching, no risk of one test's patch leaking into
another. T-2.2.6 should delete the `engine.py`-side `_run_postgres_psql_query`
wrapper and the `_sync_postgres_ops_dependencies()`-driven attribute
overwrite entirely, and have every internal call site in
`engine_postgres_ops.py` call `_run_postgres_psql_query_impl(ctx, session,
config, sql, ...)` (or a locally renamed equivalent) directly. Do not
re-invent an equivalent indirection to preserve some other test's patching
habit -- fix the test to pass a fake `ctx` instead, per T-2.2.2's own
"update its tests to construct a context rather than patch globals" step,
which applies identically here.

### What this buys (T-2.2.9)

Two engine instances in one process is now just two `EngineContext` values:
`ops1 = engine_infra_ops` functions called with `ctx1`, `ops2` the same
functions called with `ctx2`. No shared mutable state exists between them by
construction -- there is nothing left to reset between tests, and nothing for
a forgotten `configure_runtime_dependencies()` call to leave at `None`. This
is the property the QA plan's Tier 0 in-process fault-injection harness
needs, and it falls out of the design rather than needing separate proving.

### Migration order (unchanged from the task list, restated for continuity)

`engine_runtime_common.py` first (T-2.2.2) -- it is both the smallest module
and the one that owns the real implementations several of the *other* five
modules currently receive only as re-exported wrappers through `engine.py`,
so migrating it first establishes the canonical versions everything else
threads through. Then `engine_scheduler_ops.py`, `engine_firewall_ops.py`
(T-2.2.3, T-2.2.4 -- both small, same pattern), `engine_app_ops.py`,
`engine_postgres_ops.py`, `engine_infra_ops.py` (T-2.2.5–T-2.2.7 -- the three
4,000+ line modules, in that order), then the `plugins/` package (T-2.2.8),
then the two-engines acceptance test (T-2.2.9), then deletion of every
`configure_runtime_dependencies` and `_sync_*_dependencies` definition
(T-2.2.10) -- **all six** of them: `_sync_runtime_common_dependencies`,
`_sync_infra_ops_dependencies`, `_sync_app_ops_dependencies`,
`_sync_postgres_ops_dependencies`, `_sync_scheduler_ops_dependencies`, and
`_sync_firewall_ops_dependencies`. T-2.2.10's own "Files" list names only
the first three; the other three exist in `engine.py` today (verified while
writing this section) and must be deleted too, or T-2.2.10's own
`grep -rn "configure_runtime_dependencies\|_sync_.*_dependencies" orchestrator/src`
done-when check will still find them.

## Current Setup / Onboarding Behavior

The shipped `setup/run` workflow now treats server onboarding as a secure
ownership handoff.

Current behavior:

- the managed target account is `ubuntu`
- setup defaults are secure by default:
  - disable password SSH
  - disable root login
- minimal bootstrap setup runs first:
  - OS update/system prep
  - create or reset `ubuntu` into a Deploy Dash-managed baseline
  - install the Deploy Dash-managed SSH key and ensure pubkey auth is ready
- Deploy Dash then performs a verified connection handoff:
  - reconnect as `ubuntu`
  - disable root, direct-password, and PAM keyboard-interactive SSH through an
    early root-owned `/etc/ssh/sshd_config.d/00-deploydash.conf` override
  - verify effective authentication values with `sshd -T`, so cloud-image
    drop-ins cannot silently override the intended policy
  - keep PAM keyboard-interactive authentication disabled even when the user
    deliberately enables direct SSH password authentication in System settings
  - apply the Docker-safe SSH-only firewall baseline
  - verify the managed connection again
- only after that checkpoint succeeds does setup continue with the remaining
  provisioning steps
- hostname alignment keeps one conventional `127.0.1.1` mapping in the live
  hosts file and, when `manage_etc_hosts` is enabled, in cloud-init's Debian
  template; legacy cleanup is limited to the exact current-host `mail` alias
- onboarding also configures real Ubuntu automatic security updates with sane
  defaults
- onboarding writes a managed `/etc/fail2ban/jail.local` for SSH with
  `backend=systemd`, `bantime=1h`, `findtime=10m`, and `maxretry=5`
- staged firewall changes snapshot only the managed IPv4/IPv6 INPUT and
  DOCKER-USER chains plus whether their parent jumps existed. Manual and timed
  rollback reconstruct that scoped state without replacing whole iptables
  tables or discarding rules another service added after the stage began
- the add-server review reports whether `ufw` is installed and active, lists
  active allow rules, and explains that Deploy Dash replaces `ufw`. If a stage
  then fails or rolls back after active `ufw` was removed, the result and a
  durable server marker report the firewall as `unprotected`; the Security
  workspace keeps that warning visible until a retry stages protected rules
- Docker engine setup installs exact pinned official Docker apt package
  versions and holds those packages after installation. The Updates status
  probe still checks the official Docker repository for newer patches inside
  each app-owned major/minor series. A user-triggered runtime update installs
  the newest in-series package set through the shared bounded dpkg-lock wait,
  restores every hold even on failure, restarts Docker, and verifies that
  previously running managed containers return; the UI warns that Docker,
  containerd, and containers may restart.
- default Railpack installation during setup is pinned to repo-controlled
  `v0.29.0`, not `latest`
- the Railpack BuildKit frontend is used through the repo-pinned image digest,
  not only the mutable frontend tag
- web app deploy preflight rejects stale Railpack CLI/helper installs before
  build, with a prompt to use Server Management -> Updates so old servers do
  not fail later with misleading build or repository-access messages
- `server/tooling_status` returns a grouped capability inventory for Railpack,
  Docker, HTTP gateway, PostgreSQL, security baseline, and Ubuntu
  package maintenance; sub-artifacts are diagnostics, not separate update
  operations
- managed update and rollback snapshots are root-owned and private; the next
  managed mutation also tightens legacy snapshots, then keeps at most three
  per component after success while protecting the ledger's active rollback
  target. The retained count and byte total appear in that component's
  tooling-status details.

Host-key mismatch handling is also no longer a blind refresh path. The backend
returns the old/new fingerprint details needed for the desktop app to ask the
user for explicit confirmation before replacing the saved known-host entry.
Inline deploy-key app clones also use strict repository SSH host-key checking
against a persistent server-side known-hosts file; missing or changed
repository identities return a structured confirmation-required result instead
of accepting new keys silently.

## Current Runtime Hardening Behavior

Current backend-managed runtime defaults include:

- web app deploys now use versioned releases with health-gated cutover:
  - start a candidate release and probe `/up`, then `/health`, then `/`, so
    applications without dedicated health endpoints can use their normal home
    page for readiness
  - route Caddy traffic through a short per-release Docker network alias rather
    than the raw release container name
  - switch Caddy traffic only after the routed release passes the same
    `/up`, `/health`, then `/` fallback sequence
  - keep the candidate live throughout the full routed-stabilization window so
    Docker DNS and Caddy routing can settle; only persistent failures revert it
  - automatically revert to the previous live release if post-cutover
    stabilization fails
  - restore the previous Caddy route on any failed or cancelled cutover, or
    remove the project-specific candidate route and validate/reload Caddy when
    the failed release was the first deployment
  - retain recent successful releases for fast rollback and prune older
    release containers/images automatically
  - separately check the configured public HTTPS path after stabilization,
    following redirects and validating TLS without collecting response bodies
  - return process readiness and public URL health as separate results so a
    process-ready release with a failing visitor route is reported as needing
    attention rather than as unqualified ready
- Caddy and Bind9 containers launch with strict baseline runtime hardening:
  - `--security-opt no-new-privileges`
  - `--cap-drop ALL`
  - `--pids-limit 512`
- Caddy adds back only `NET_BIND_SERVICE`. Bind9 also receives `SETUID` and
  `SETGID` so the official image entrypoint can initialize groups and drop PID
  1 to the unprivileged `bind` account before serving DNS.
- BIND readiness requires Docker to publish both TCP and UDP port 53, then
  verifies authoritative SOA answers over UDP and TCP through the configured
  server address; systemd-resolved's loopback listener cannot satisfy it.
- managed web app, worker, and PostgreSQL containers keep the shared
  `--pids-limit 512` guard, but do not use `no-new-privileges` or
  `cap-drop ALL` because Railpack/runtime and database entrypoints may need
  startup privilege transitions or file capabilities before dropping privileges
- default Caddy-managed routes add baseline response hardening headers with
  `?header` semantics so app-specific header blocks can still override them:
  - `X-Content-Type-Options: nosniff`
  - `Referrer-Policy: strict-origin-when-cross-origin`
  - `Permissions-Policy` restrictive baseline
  - `X-Frame-Options: SAMEORIGIN`
  - `Strict-Transport-Security` on HTTPS routes only
- shipped Caddy image pin is `caddy:2.11.2-alpine`

## CLI Usage

The package exposes `orchestrator` via `orchestrator.runner:main`.

Available top-level commands:

- `echo`
- `check-server`
- `setup-server`
- `run-payload`

Examples:

```bash
cd orchestrator
uv run orchestrator echo --data hello --pretty
```

```bash
cd orchestrator
uv run orchestrator check-server \
  --host 203.0.113.10 \
  --username ubuntu \
  --key-path ~/.ssh/id_ed25519 \
  --pretty
```

```bash
cd orchestrator
uv run orchestrator run-payload \
  --payload '{"action":"run_workflow","workflow_id":"core","operation_id":"echo"}' \
  --pretty
```

Deploy Dash Agent Access:

The shipped desktop app now hosts the MCP server directly at
`http://127.0.0.1:46337/mcp` once the encrypted local database is unlocked.
The backend package no longer ships separate MCP wrapper commands.

Notes:

- the desktop MCP server exposes live server overview, deploy/runtime logs, task history/status/events/results, conflict preview, GitHub repo/branch discovery, workflow/audit resources, and managed PostgreSQL inspection/query tools for the selected project's own databases
- PostgreSQL query tools are read-only only, bounded, return actual row data, do not need a redeploy session, and run with operator-level read-only visibility rather than app-user permissions
- redeploy and cancel tools require the one active short-lived bearer token from the desktop app
- redeploy requests return the `app/run` task id immediately; use the task tools to follow progress
- end-user guidance for installing and using the Agent Access skill lives in
  the public `deploydash/deploydash-agent-access` repository

Server system/runtime notes:

- `server/system_status` reports Ubuntu's reboot-required marker, package list,
  package-list readability, and marker modification time alongside the
  persisted system settings
- `server/system_apply` resizes managed swap through a temporary active swap;
  if restoring the old swap fails, it leaves the temporary safety swap active
  and reports the rollback failure explicitly
- `server/system_restart` schedules a delayed reboot, proves SSH went away and
  returned, then allows a bounded settling period while independently verifying
  Docker, every managed container inventoried before the reboot, both managed
  firewall chains, configured swap, the SSH listener, and that Ubuntu cleared
  the reboot-required marker
- `server/docker_storage_status` reads the space currently occupied by unused
  Docker images and Docker build cache on the remote host
- `server/docker_storage_prune` supports targeted cleanup for either unused
  images or build cache; it does not remove images that are still in use by
  containers


## Tests

Testing discipline is repository policy and lives in
[`AGENTS.md`](../AGENTS.md#testing-guidelines). Two rules override any local
habit:

- **A test that has never failed is not known to work.** Every new test must be
  proven capable of failing — written red-first, or mutation-checked by
  deliberately breaking the behaviour it covers and observing the failure.
  State which in the commit message.
- **Pick the discipline that matches the work.** New behaviour with enumerable
  branches is contract-first (TDD). A pure refactor is characterization: write
  no new tests, and existing assertions must not change. Deleting code requires
  a census of the tests that covered it.

100% coverage for any area you touch remains required, and remains necessary
rather than sufficient.


Use explicit discovery:

```bash
cd orchestrator
uv run python -m unittest discover -s tests -p '*_test.py'
```

For targeted engine refactors, also run:

```bash
cd orchestrator
uv run python -m unittest \
  tests.engine_test \
  tests.architecture.engine_contract_guardrails_test \
  tests.orchestrator_runtime_test
```

For the workflow-registry/bootstrap guardrail after the Milvus removal:

```bash
cd orchestrator
./scripts/post_milvus_removal_coverage.sh
```

This checks 100% touched coverage for the remaining workflow registry,
bootstrap, engine wiring, and server tooling capability surfaces:

- `src/orchestrator/workflow_registry.py`
- `src/orchestrator/engine_bootstrap.py`
- the bootstrap/runtime export range in `src/orchestrator/engine.py`
- the server tooling capability/status range in `src/orchestrator/engine_infra_ops.py`

For the database-specific coverage gate:

```bash
cd orchestrator
./scripts/database_coverage.sh
```

This checks 100% line coverage for the hand-written PostgreSQL boundary and
release-critical helper modules:

- `src/orchestrator/postgres_parts/postgres_config.py`
- `src/orchestrator/plugins/postgres_plugin.py`
- `src/orchestrator/release_helpers.py`
- `src/orchestrator/runtime_bundle.py`

For the authoritative DNS runtime coverage gate:

```bash
cd orchestrator
./scripts/dns_runtime_coverage.sh
```

This checks 100% line and branch coverage for the BIND runtime readiness,
published TCP/UDP port checks, and host-address authoritative DNS probes in
`src/orchestrator/dns_parts/part2_runtime.py`.

For the embedded desktop runtime coverage gate:

```bash
cd orchestrator
./scripts/desktop_runtime_coverage.sh
```

This checks 100% line and branch coverage for the GUI-hosted Python bootstrap,
runtime bundle builder, and release artifact contracts:

- `src/orchestrator/embedded_runtime.py`
- `src/orchestrator/task_runtime.py`
- `src/orchestrator/runtime_bundle.py`
- `src/orchestrator/release_helpers.py`

The embedded runtime also verifies mandatory desktop process controls before a
background task is dispatched. Linux workers require non-dumpable processes
and disabled core files; Windows workers require the restricted image-load
policy configured by the native runner. See
`docs/reference/desktop-process-hardening.md` for the cross-platform contract.

For the PostgreSQL Agent Access coverage gate:

```bash
cd orchestrator
./scripts/postgres_agent_access_coverage.sh
```

This checks the new read-only PostgreSQL Agent Access surface at 100% across:

- `src/orchestrator/postgres_parts/postgres_config.py`
- `src/orchestrator/plugins/postgres_plugin.py`
- the read-only PostgreSQL query helper/operation ranges in
  `src/orchestrator/engine_postgres_ops.py`

## Packaging And Desktop Runtime Bundle

Build a wheel:

```bash
cd orchestrator
./scripts/build_wheel.sh
```

Prepare the desktop runtime bundle from the current checkout:

```bash
cd orchestrator
./scripts/prepare_desktop_runtime_bundle.sh
```

The builder creates and installs a local wheel, copies the resulting
`site-packages`, then verifies that the copied runtime imports with GUI-style
missing or invalid console streams and completes a background echo task.

Prepare the desktop runtime bundle from an explicitly published package:

```bash
cd orchestrator
ORCHESTRATOR_PACKAGE_SOURCE=published \
ORCHESTRATOR_ALLOW_LOCAL_FALLBACK=0 \
./scripts/prepare_desktop_runtime_bundle.sh
```

The shell wrapper now delegates to a cross-platform Python script so macOS and
Windows release packaging can rebuild the same runtime bundle contract without a
Linux-only shell implementation.

## Current Behavioral Notes

- web app publish validation now requires successful Caddy apply/reload,
  canonical HTTP routing, and any configured apex/`www` redirect behavior
- the final best-effort HTTPS propagation probe is intentionally not part of the
  deploy success contract
- PostgreSQL project users created with `read_write` access receive ownership
  needed to create, alter, and drop tables in their assigned database
- PostgreSQL server management supports bundled `pgvector`, `pg_search`, and
  `postgis` extension installation in the managed Postgres image
- project database user deletion is exposed as `project_delete_user` for
  PostgreSQL-managed users
- project database deletion force-closes sessions that reconnect after the
  initial termination pass; a remaining failure names the database and directs
  the user to stop the reconnecting app or worker before retrying
- PostgreSQL backup restores run in a disposable client with a single
  transaction and fail-fast errors, reject artifact keys outside the calling
  project's object prefix, verify the new database, register it to the project,
  and force-drop any failed target so the same name can be retried
- `app/exec` runs a one-off non-interactive command inside the managed web app
  container for deployed non-`staticfile` projects and returns streamed output,
  exit code, timeout, cancellation semantics, and a final terminal-result event
  through the standard runtime task flow; the exec shell now inherits PID 1's
  runtime `PATH` so plain `npx`/`npm`/language-tool invocations can work
  without manual environment prefixing
- the desktop app now hosts the shipped Agent Access MCP endpoint directly, so
  backend packaging no longer carries separate wrapper entrypoints

## License

This package is covered by the repository-root AGPL-3.0 `LICENSE`.
Third-party dependencies and vendored content keep their respective
upstream licenses.

## Release Flow

1. Update `pyproject.toml` version.
2. Add release notes in `CHANGELOG.md`.
3. Build the wheel.
4. Publish the wheel to the package index.
5. Update the pinned backend version file for the current checkout.
6. Rebuild the desktop runtime bundle.
7. Run backend parity tests and desktop bundle checks.

See `RELEASING.md` for the full release and pin-update process.
