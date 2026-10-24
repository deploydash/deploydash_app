import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'app_data_directory.dart';
import 'app_database_passphrase_logic.dart';

export 'app_data_directory.dart'
    show resolveAppDataDirectory, resolveWindowsStoreAppSupportDirectory;

part 'app_database.g.dart';

/// The local database schema version.
///
/// Collapsed from 48 to 1 in T-1.2.2. There were 43 incremental upgrade
/// branches across 35 tables, none of which had ever run on a machine other
/// than a developer's: no build had been distributed when the collapse
/// happened, confirmed in writing by the owner under T-0.4. Every branch was
/// permanent code, permanent test surface, and permanent risk in exchange for
/// compatibility with nothing.
///
/// A database written before the collapse cannot be opened by this build and
/// has no migration path to version 1. A later pre-release branch briefly used
/// version 2 to isolate SSH credentials from ordinary server rows. Before any
/// release or user adoption, that final shape was folded back into version 1;
/// the credential table is therefore created directly with the rest of the
/// baseline.
///
/// Version 2 is the first real migration: `servers.setup_complete` marks
/// whether provisioning finished, so an early-saved server (persisted before
/// setup runs) is distinguishable from a fully onboarded one. Every
/// pre-existing row backfills to complete, which is what all of them are.
const int appDatabaseSchemaVersion = 2;

/// The format version stamped into a SQLite backup snapshot's
/// `deploydash_backup_metadata` table (see `createConsistentEncryptedSnapshot`
/// in `services/sqlite_backup_service.dart`) and enforced on restore by
/// [enforceSqliteBackupFormatVersion]. A backup taken today must stay
/// restorable indefinitely, so unlike [appDatabaseSchemaVersion] this policy
/// is one-directional: refuse a format newer than this build knows about,
/// support every older format forever. See
/// docs/contracts/artifact-formats.md.
const int sqliteBackupFormatVersion = 1;

/// The servers Deploy Dash manages. Read through [ServerRepository].
///
/// Deliberately holds **no** credentials: those live in [ServerCredentials],
/// so a query that reads servers cannot accidentally carry a key or password
/// into a layer that has no business seeing one.
@DataClassName('ServerRow')
class Servers extends Table {
  /// The server's id, derived from its name and creation time.
  TextColumn get id => text()();

  /// What the user calls it.
  TextColumn get name => text()();

  /// Its hostname or IP address.
  TextColumn get host => text()();

  /// The SSH port. Defaults to 22.
  IntColumn get port => integer().withDefault(const Constant(22))();

  /// The account Deploy Dash connects as.
  TextColumn get sshUser => text()();

  /// `password` or `ssh_key`. Defaults to `password`, which is what a fresh
  /// server usually offers before onboarding installs a key.
  TextColumn get authMethod => text().withDefault(const Constant('password'))();

  /// The operating system, once a check has reported one.
  TextColumn get osName => text().nullable()();

  /// The CPU architecture, once reported.
  TextColumn get cpuArch => text().nullable()();

  /// Memory in MB, once reported.
  IntColumn get memoryMb => integer().nullable()();

  /// Disk in GB, once reported.
  IntColumn get diskGb => integer().nullable()();

  /// Whether managed PostgreSQL is set up here.
  BoolColumn get serviceDatabaseEnabled =>
      boolean().withDefault(const Constant(false))();

  /// Whether managed email is set up here. Always false today: Email is a
  /// navigation placeholder, so nothing writes this true.
  BoolColumn get serviceEmailEnabled =>
      boolean().withDefault(const Constant(false))();

  /// Whether managed DNS is set up here. Always false today, for the same
  /// reason as [serviceEmailEnabled].
  BoolColumn get serviceDomainEnabled =>
      boolean().withDefault(const Constant(false))();

  /// The Caddy configuration, as versioned JSON. Encoded and decoded only by
  /// `ServerConfigJsonCodecs`; null until the server is created.
  TextColumn get serviceWebServerConfigJson => text().nullable()();

  /// The managed PostgreSQL configuration, as versioned JSON.
  TextColumn get servicePostgresConfigJson => text().nullable()();

  /// The firewall configuration, as versioned JSON.
  TextColumn get serviceFirewallConfigJson => text().nullable()();

  /// The system configuration, as versioned JSON.
  TextColumn get serviceSystemConfigJson => text().nullable()();

  /// Which pinned versions of managed software this server runs, as versioned
  /// JSON. Null until something has been installed.
  TextColumn get managedSoftwareStatusJson => text().nullable()();

  /// How the last connectivity check ended.
  TextColumn get lastCheckStatus => text().nullable()();

  /// Why it failed, as a JSON object. Kept so a server that could not be
  /// reached still explains itself in the list rather than vanishing.
  TextColumn get lastError => text().nullable()();

  /// When that check ran.
  DateTimeColumn get lastCheckedAt => dateTime().nullable()();

  /// When the server was saved.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When the row last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  /// Whether provisioning finished for this server. Early saves (persisted
  /// before setup runs) store false; the managed handoff flips it to true.
  /// Defaults to true so the v1-to-v2 migration backfills every pre-existing
  /// row as complete, which is what all of them are.
  BoolColumn get setupComplete => boolean().withDefault(const Constant(true))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// SSH credentials, one row per server, isolated from [Servers].
///
/// Included directly in schema version 1 so credentials have their own table
/// and their own repository: [ServerCredentialRepository] is the only typed
/// way in or out, and no domain value or provider state can carry these fields
/// by accident.
@DataClassName('ServerCredentialRow')
class ServerCredentials extends Table {
  /// The server these credentials reach.
  TextColumn get serverId => text()();

  /// The SSH password, before onboarding replaces it with a managed key.
  TextColumn get sshPassword => text().nullable()();

  /// The private key's contents, stored inline rather than as a workstation
  /// path -- see `ServerDraft.keyPath` for why.
  TextColumn get privateKey => text().nullable()();

  /// The matching public key.
  TextColumn get publicKey => text().nullable()();

  /// The managed account's unix password, set during onboarding (#62).
  ///
  /// Setup generates it when bootstrapping as somebody else and returns it
  /// in the setup result; the desktop stores it here as a recoverable
  /// record alongside the key. Never sent as SSH authentication -- the
  /// managed connection authenticates by key, and sudo is passwordless via
  /// the sudoers drop-in. Pre-1.0 schema: added without a migration step
  /// (version stays 1, `onCreate` covers fresh installs; development
  /// databases reset via `ui/scripts/reset_state_db.sh`).
  TextColumn get managedUserPassword => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {serverId};
}

/// Where the app is in onboarding. Exactly one row, at id 1.
@DataClassName('OnboardingStateEntryRow')
class OnboardingStateEntries extends Table {
  /// Always 1. Pinning the row makes "there is one onboarding state"
  /// structural rather than a convention every writer must keep.
  IntColumn get id => integer()();

  /// Whether at least one server has been added.
  BoolColumn get isCompleted => boolean().withDefault(const Constant(false))();

  /// The selected server, or null when none is. Reconciled by
  /// `ServerRepository.deleteServer` so it cannot point at a deleted row.
  TextColumn get activeServerId => text().nullable()();

  /// The onboarding step being shown, so a restart resumes there.
  TextColumn get currentStep => text().nullable()();

  /// When this row last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The app's settings. Exactly one row, at id 1. See
/// [AppPreferencesRepository] for what each value means.
@DataClassName('AppPreferenceRow')
class AppPreferences extends Table {
  /// Always 1, for the same reason as [OnboardingStateEntries.id].
  IntColumn get id => integer()();

  /// Whether the terminal shows raw engine detail. Off by default.
  BoolColumn get terminalDebugView =>
      boolean().withDefault(const Constant(false))();

  /// `light`, `dark` or `system`. Follows the OS by default.
  TextColumn get themeMode => text().withDefault(const Constant('system'))();

  /// The OAuth `state` for a sign-in still in the browser. Persisted so a
  /// cold-launch callback can still be matched -- see
  /// [AppPreferencesRecord.gitHubPendingOauthState].
  TextColumn get gitHubPendingOauthState =>
      text().nullable()(); // coverage:ignore-line

  /// Where the encrypted database is backed up to, as JSON.
  TextColumn get sqliteBackupS3ConfigJson => text().nullable()();

  /// When that backup last ran.
  DateTimeColumn get sqliteBackupLastRunAt => dateTime().nullable()();

  /// How it ended.
  TextColumn get sqliteBackupLastStatus => text().nullable()();

  /// What it reported, including any note about retention pruning.
  TextColumn get sqliteBackupLastMessage => text().nullable()();

  /// Whether the local MCP endpoint is bound. Off by default.
  BoolColumn get agentAccessEnabled =>
      boolean().withDefault(const Constant(false))(); // coverage:ignore-line

  /// What an agent may do. Defaults to `read_only`, and an unrecognised value
  /// reads back as read-only too -- see `normalizeAgentAccessPermissionMode`.
  TextColumn get agentAccessPermissionMode =>
      text().withDefault(const Constant('read_only'))(); // coverage:ignore-line

  /// The current agent session token, when one has been issued.
  TextColumn get agentSessionToken =>
      text().nullable()(); // coverage:ignore-line

  /// When that token stops being accepted.
  DateTimeColumn get agentSessionExpiresAt =>
      dateTime().nullable()(); // coverage:ignore-line

  /// When server onboarding first completed (analytics milestone, write-once).
  ///
  /// Null until the onboarding hook records it; the analytics store reads it
  /// back into the lifecycle envelope. Pre-1.0 schema: added without a
  /// migration step (version stays 1, `onCreate` covers fresh installs;
  /// development databases reset via `ui/scripts/reset_state_db.sh`).
  DateTimeColumn get analyticsOnboardingCompletedAt => dateTime().nullable()();

  /// When the first deploy first succeeded (analytics milestone, write-once).
  ///
  /// Same pre-1.0 terms as [analyticsOnboardingCompletedAt].
  DateTimeColumn get analyticsFirstDeploySucceededAt => dateTime().nullable()();

  /// When GitHub first connected (analytics milestone, write-once).
  ///
  /// Same pre-1.0 terms as [analyticsOnboardingCompletedAt].
  DateTimeColumn get analyticsGitHubConnectedAt => dateTime().nullable()();

  /// Whether anonymous usage reporting is on (`true`), off (`false`), or
  /// never answered (null). Null means on: telemetry is default-on behind a
  /// notice, and only an explicit `false` silences the backends.
  ///
  /// Same pre-1.0 terms as [analyticsOnboardingCompletedAt].
  BoolColumn get telemetryEnabled => boolean().nullable()();

  /// When the setup-progress telemetry notice was shown, or null before it
  /// has. Stamped at setup completion; the passive notice is recorded at
  /// most once.
  ///
  /// Same pre-1.0 terms as [analyticsOnboardingCompletedAt].
  DateTimeColumn get telemetryNoticeShownAt => dateTime().nullable()();

  /// When the post-first-deploy telemetry nag was shown, or null before it
  /// has. The nag fires only for explicitly opted-out installs, at most
  /// once.
  ///
  /// Same pre-1.0 terms as [analyticsOnboardingCompletedAt].
  DateTimeColumn get telemetryNagShownAt => dateTime().nullable()();

  /// When these preferences last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// This installation, and any others that have used this database file.
///
/// See [DeviceInstallationRecord]; the identity itself lives outside the
/// database, because it must be readable before unlock.
@DataClassName('DeviceInstallationRow')
class DeviceInstallations extends Table {
  /// The permanent installation id, from the identity file.
  TextColumn get id => text()();

  /// The machine's hostname, or `This device`.
  TextColumn get displayName => text()();

  /// `linux`, `macos`, `windows`, or `unknown`.
  TextColumn get platform => text()();

  /// `arm64`, `x64`, or `unknown`.
  TextColumn get architecture => text()();

  /// When the identity was created. No default: it comes from the identity
  /// file, not from when this row happened to be written.
  DateTimeColumn get createdAt => dateTime()();

  /// When the app last ran here.
  DateTimeColumn get lastSeenAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// What each installation remembers about desktop update checks. See
/// [DeviceUpdateStateRecord].
@DataClassName('DeviceUpdateStateRow')
class DeviceUpdateStates extends Table {
  /// The installation this belongs to.
  TextColumn get deviceId => text()();

  /// The channel being followed. `stable` by default.
  TextColumn get releaseChannel =>
      text().withDefault(const Constant('stable'))();

  /// When the last check ran.
  DateTimeColumn get lastCheckedAt => dateTime().nullable()();

  /// What it concluded, by `DesktopUpdateStatus` name.
  TextColumn get lastCheckStatus => text().nullable()();

  /// The newest release seen.
  TextColumn get lastKnownReleaseId => text().nullable()();

  /// The release the user asked to stop being told about.
  TextColumn get dismissedReleaseId => text().nullable()();

  /// The last signed response, kept so a `304` has something to re-verify --
  /// never trusted for having been verified before.
  TextColumn get cachedSignedEnvelope => text().nullable()();

  /// The `ETag` that makes the next check conditional.
  TextColumn get cachedEtag => text().nullable()();

  /// When this row last changed.
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {deviceId};
}

/// Engine output kept so a user can still read it after a restart. See
/// [TerminalLogRecord].
///
/// The scope indexes created in [AppDatabase.migration] exist for this table:
/// it is the largest by row count, and every read of it filters on project,
/// server and time.
@DataClassName('TerminalLogRow')
class TerminalLogs extends Table {
  /// Autoincrement row id. The tiebreak for lines sharing a timestamp.
  IntColumn get id => integer().autoIncrement()(); // coverage:ignore-line

  /// The project this line belongs to, when it belongs to one.
  TextColumn get projectId => text().nullable()();

  /// The server this line belongs to, when it belongs to one.
  TextColumn get serverId => text().nullable()();

  /// The server's name at the time, so an old line still reads sensibly after
  /// the server is renamed or deleted.
  TextColumn get serverLabel => text().nullable()();

  /// The raw message.
  TextColumn get message => text()();

  /// The line as it appeared, stored rather than re-derived so replaying an
  /// old log shows what the user actually saw.
  TextColumn get renderedLine => text()();

  /// Where the line came from. `terminal` by default.
  TextColumn get source => text().withDefault(const Constant('terminal'))();

  /// Which kind of operation produced it, so one operation's output can be
  /// replayed on its own.
  TextColumn get taskType => text().nullable()();

  /// When the line was produced.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line
}

/// The product's persisted unit: a project on a server. Read through
/// [ProjectRepository], which normalizes every value below before it is
/// stored.
///
/// Never reintroduce `bucket` for product state; that name belongs to storage
/// providers alone.
@DataClassName('ProjectRow')
class Projects extends Table {
  /// The project's id.
  TextColumn get id => text()();

  /// The server it is deployed to. Null while a project exists but has no
  /// server yet, which is a real state during onboarding.
  TextColumn get serverId => text().nullable()();

  /// What the user calls it. Also what its slug is derived from.
  TextColumn get name => text()();

  /// What kind of project it is.
  TextColumn get type => text()();

  /// The repository's git URL.
  TextColumn get gitUrl => text()();

  /// The domain the app is served on, lower-cased.
  ///
  /// For a redirect routing mode this is stored as the apex, with any leading
  /// `www.` stripped -- the redirect needs a fixed point to redirect to.
  TextColumn get primaryDomain => text()();

  /// `single_host`, `redirect_www_to_apex`, or `redirect_apex_to_www`.
  TextColumn get domainRoutingMode => text().withDefault(
    const Constant('single_host'),
  )(); // coverage:ignore-line

  /// The GitHub repository as `owner/name`.
  TextColumn get repositoryFullName => text().nullable()();

  /// The subdirectory within the repository to build from, for a monorepo.
  /// Null means the repository root.
  TextColumn get appSubdirectory => text().nullable()();

  /// The branch deployed. `main` by default.
  TextColumn get deployBranch => text().withDefault(const Constant('main'))();

  /// The port the app listens on. 3000 by default, and anything outside
  /// 1-65535 is normalized back to it.
  IntColumn get appPort => integer().withDefault(const Constant(3000))();

  /// Whether to check the public URL after a deploy. On by default.
  BoolColumn get publicHealthCheckEnabled =>
      boolean().withDefault(const Constant(true))();

  /// The path that check requests. Always starts with `/`; `/` by default, so
  /// an app with no health endpoint uses its home page.
  TextColumn get publicHealthCheckPath =>
      text().withDefault(const Constant('/'))();

  /// The commit of the last successful deploy.
  TextColumn get lastDeployCommit => text().nullable()();

  /// When that deploy happened.
  DateTimeColumn get lastDeployedAt => dateTime().nullable()();

  /// The build command. Blank means "let Railpack detect it"; the Node default
  /// is pre-filled here for projects created before a provider was recorded.
  TextColumn get railpackBuildCommand =>
      text().withDefault(const Constant('npm run build'))();

  /// The start command, with the same blank-means-detect rule.
  TextColumn get railpackRunCommand =>
      text().withDefault(const Constant('npm run start'))();

  /// The chosen Railpack provider, or null for auto-detection. An
  /// unrecognised value reads back as null -- see `normalizeRailpackProvider`.
  TextColumn get railpackProvider =>
      text().nullable()(); // coverage:ignore-line

  /// `auto` or `runtime`, deciding how Node is provided in the image.
  TextColumn get railpackNodeMode =>
      text().withDefault(const Constant('auto'))();

  /// `http` or `dns`, deciding how the TLS certificate is proven. `http` by
  /// default, since it needs no provider credentials.
  TextColumn get tlsChallengeMode =>
      text().withDefault(const Constant('http'))();

  /// The DNS provider for a `dns` challenge, from a closed set.
  TextColumn get tlsDnsProvider => text().nullable()();

  /// That provider's credentials as JSON. Cleared when the challenge mode
  /// moves away from `dns`, rather than left behind unused.
  TextColumn get tlsDnsConfigJson => text().nullable()();

  /// Whether the app has been disconnected from its server.
  BoolColumn get appDisconnected =>
      boolean().withDefault(const Constant(false))();

  /// Whether managed PostgreSQL credentials are wired into this project.
  BoolColumn get injectPostgresEnv =>
      boolean().withDefault(const Constant(false))();

  /// Whether the app has a SQLite volume mounted.
  BoolColumn get sqliteStorageEnabled =>
      boolean().withDefault(const Constant(false))();

  /// The Docker volume holding it. Null when the value would not be safe as a
  /// volume name -- the repository normalizes rather than storing it raw.
  TextColumn get sqliteVolumeName => text().nullable()();

  /// Where it mounts in the container, absolute and free of `.` and `..`.
  TextColumn get sqliteMountPath => text().nullable()();

  /// The database filename inside that mount.
  TextColumn get sqliteFileName => text().nullable()();

  /// Whether this is the selected project on its server. At most one is, per
  /// server; `ProjectRepository` maintains that.
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();

  /// When the project was created.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When the row last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// A project's SQLite databases. See [ProjectSqliteDatabaseRepository], which
/// keeps exactly one of them primary.
@DataClassName('ProjectSqliteDatabaseRow')
class ProjectSqliteDatabases extends Table {
  /// The database's id.
  TextColumn get id => text()();

  /// Which project owns it.
  TextColumn get projectId => text()();

  /// What the user calls it. Unique within the project, by constraint.
  TextColumn get name => text()();

  /// The Docker volume holding the file. Validated as a volume name before it
  /// is stored, because it reaches a Docker command.
  TextColumn get volumeName => text()();

  /// Where that volume mounts, absolute and free of `.` and `..`.
  TextColumn get mountPath => text()();

  /// The database filename inside the mount.
  TextColumn get fileName => text()();

  /// Whether this is the project's primary database.
  BoolColumn get isPrimary => boolean().withDefault(const Constant(false))();

  /// Whether the volume was found on the server. Null means never looked,
  /// which is not the same as looked and absent.
  BoolColumn get volumeExists => boolean().nullable()();

  /// Where Docker reports the volume lives on the host.
  TextColumn get volumeMountpoint => text().nullable()();

  /// Its size in bytes, as observed.
  IntColumn get volumeSizeBytes => integer().nullable()();

  /// When the volume was last inspected.
  DateTimeColumn get lastCheckedAt => dateTime().nullable()();

  /// When the row was created.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['UNIQUE(project_id, name)'];
}

/// Read-only SQLite copies published from one project to another. See
/// [ProjectSqliteSnapshotExportRecord] for why sharing SQLite means copying.
@DataClassName('ProjectSqliteSnapshotExportRow')
class ProjectSqliteSnapshotExports extends Table {
  /// The publication's id, derived from the source and consumer.
  TextColumn get id => text()();

  /// The owner's database being published.
  TextColumn get sourceSqliteDatabaseId => text()();

  /// The project that owns the data.
  TextColumn get ownerProjectId => text()();

  /// The project allowed to read it. Unique per source, by constraint.
  TextColumn get consumerProjectId => text()();

  /// The trust group that authorises this.
  TextColumn get trustGroupId => text()();

  /// The Docker volume the copy is written into.
  TextColumn get snapshotVolumeName => text()();

  /// Where the consumer mounts it.
  TextColumn get mountPath => text()();

  /// The database filename inside that mount.
  TextColumn get fileName => text()();

  /// The environment variable holding the file path.
  TextColumn get pathEnvKey => text().nullable()();

  /// The environment variable holding the `sqlite://` URL.
  TextColumn get databaseUrlEnvKey => text().nullable()();

  /// `active` while the publication should be mounted.
  TextColumn get status => text().withDefault(const Constant('active'))();

  /// When the source was last observed to change.
  DateTimeColumn get sourceUpdatedAt => dateTime().nullable()();

  /// When the copy was last actually made. Compared with [sourceUpdatedAt],
  /// this is what says how stale the consumer's copy is.
  DateTimeColumn get lastPublishedAt => dateTime().nullable()();

  /// When the publication was configured.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE(source_sqlite_database_id, consumer_project_id)',
  ];
}

/// Permission for one project to use another's managed database. See
/// [ProjectDatabaseAccessGrantRecord].
@DataClassName('ProjectDatabaseAccessGrantRow')
class ProjectDatabaseAccessGrants extends Table {
  /// The grant's id.
  TextColumn get id => text()();

  /// The server both projects are on. Sharing is same-server only.
  TextColumn get serverId => text()();

  /// The project that owns the database.
  TextColumn get ownerProjectId => text()();

  /// The project allowed to use it.
  TextColumn get consumerProjectId => text()();

  /// The engine. `postgres` today.
  TextColumn get engine => text().withDefault(const Constant('postgres'))();

  /// Which of the owner's databases is shared.
  TextColumn get databaseName => text().withDefault(const Constant(''))();

  /// When the grant was made.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE(server_id, owner_project_id, consumer_project_id, engine, database_name)',
  ];
}

/// Users the consumer created under a grant. See
/// [ProjectDatabaseAccessUserRecord].
@DataClassName('ProjectDatabaseAccessUserRow')
class ProjectDatabaseAccessUsers extends Table {
  /// The user record's id.
  TextColumn get id => text()();

  /// The grant that authorises it. Deleting the grant deletes these rows.
  TextColumn get grantId => text()();

  /// The engine.
  TextColumn get engine => text()();

  /// The database this user connects to.
  TextColumn get databaseName => text()();

  /// The role name on the server. Unique per grant and database, by
  /// constraint.
  TextColumn get username => text()();

  /// `read_only` or `read_write`, defaulting to `read_write`.
  TextColumn get accessMode =>
      text().withDefault(const Constant('read_write'))();

  /// The host to connect to.
  TextColumn get host => text().nullable()();

  /// The port to connect on.
  IntColumn get port => integer().nullable()();

  /// The full connection URI, for the connection-details panel.
  TextColumn get connectionUri => text().nullable()();

  /// When the user was created.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE(grant_id, engine, database_name, username)',
  ];
}

/// A local mirror of the managed databases a project owns. See
/// [ProjectManagedDatabaseRecord]; the server is the authority, not this
/// table.
@DataClassName('ProjectManagedDatabaseRow')
class ProjectManagedDatabases extends Table {
  /// Derived from the scope and database name, so re-observing updates one
  /// row.
  TextColumn get id => text()();

  /// Which project owns it.
  TextColumn get projectId => text()();

  /// Which server it lives on.
  TextColumn get serverId => text()();

  /// The engine. `postgres` today.
  TextColumn get engine => text().withDefault(const Constant('postgres'))();

  /// The database's name on the server. Unique within the scope, by
  /// constraint.
  TextColumn get databaseName => text()();

  /// Whether this is the project's main database.
  BoolColumn get isPrimary => boolean().withDefault(const Constant(false))();

  /// When the server last confirmed it. What separates "we saw this" from
  /// "we once wrote this down".
  DateTimeColumn get lastAppliedAt => dateTime().nullable()();

  /// When the row was created.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE(server_id, project_id, engine, database_name)',
  ];
}

/// A local mirror of a project's managed database users, with their
/// credentials. See [ProjectManagedDatabaseUserRecord].
@DataClassName('ProjectManagedDatabaseUserRow')
class ProjectManagedDatabaseUsers extends Table {
  /// Derived from the database's id plus the username.
  TextColumn get id => text()();

  /// Which project owns it.
  TextColumn get projectId => text()();

  /// Which server it lives on.
  TextColumn get serverId => text()();

  /// The engine.
  TextColumn get engine => text().withDefault(const Constant('postgres'))();

  /// The database this user connects to.
  TextColumn get databaseName => text()();

  /// The role name on the server. Unique within the scope, by constraint.
  TextColumn get username => text()();

  /// `read_only` or `read_write`, defaulting to `read_write`.
  TextColumn get accessMode =>
      text().withDefault(const Constant('read_write'))();

  /// The user's password, held inside the encrypted database so the
  /// connection-details panel need not ask the server again.
  TextColumn get password => text().nullable()();

  /// The host to connect to.
  TextColumn get host => text().nullable()();

  /// The port to connect on.
  IntColumn get port => integer().nullable()();

  /// The full connection URI.
  TextColumn get connectionUri => text().nullable()();

  /// When the server last confirmed this user.
  DateTimeColumn get lastAppliedAt => dateTime().nullable()();

  /// When the row was created.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE(server_id, project_id, engine, database_name, username)',
  ];
}

/// Sets of projects that share a Docker network. See
/// [ProjectNetworkGroupRecord]; a group never has fewer than two members.
@DataClassName('ProjectNetworkGroupRow')
class ProjectNetworkGroups extends Table {
  /// Derived from the server and sorted member ids, so linking the same
  /// projects twice reuses one group rather than making a second network.
  TextColumn get id => text()();

  /// The server every member is on.
  TextColumn get serverId => text()();

  /// What the user calls the group.
  TextColumn get displayName => text()();

  /// The Docker network name, unique per server by constraint. What actually
  /// exists on the machine.
  TextColumn get networkName => text()();

  /// When the group was created.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['UNIQUE(server_id, network_name)'];
}

/// Which projects belong to which network group.
@DataClassName('ProjectNetworkGroupMemberRow')
class ProjectNetworkGroupMembers extends Table {
  /// The group.
  TextColumn get groupId => text()();

  /// The member project.
  TextColumn get projectId => text()();

  /// When it joined.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  @override
  Set<Column<Object>> get primaryKey => {groupId, projectId};
}

/// The GitHub OAuth token. Exactly one row, at a fixed id.
@DataClassName('GitHubAuthTokenRow')
class GitHubAuthTokens extends Table {
  /// Always 1. There is one signed-in GitHub account, and pinning the row
  /// makes that structural rather than a convention.
  IntColumn get id => integer()();

  /// The OAuth access token.
  TextColumn get accessToken => text()();

  /// When it was first stored.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it was last replaced.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Per-repository deploy keys. See [GitHubDeployKeyRecord] for why they are
/// per repository rather than per account.
@DataClassName('GitHubDeployKeyRow')
class GitHubDeployKeys extends Table {
  /// The repository, as `owner/name`. One key per repository.
  TextColumn get repositoryFullName => text()();

  /// The public half, added to the repository on GitHub.
  TextColumn get publicKey => text()();

  /// The private half, sent inline with a clone so the server keeps no copy.
  TextColumn get privateKey => text()();

  /// When the key was generated.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it was last replaced.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {repositoryFullName};
}

/// The environment variables a project's app is deployed with. See
/// [AppEnvironmentVariableRecord]: these are the only ones a deploy sends.
@DataClassName('AppEnvironmentVariableRow')
class AppEnvironmentVariables extends Table {
  /// Autoincrement row id. The tiebreak for rows sharing a position.
  IntColumn get id => integer().autoIncrement()(); // coverage:ignore-line

  /// Which project they belong to.
  TextColumn get projectId => text()();

  /// The variable name. Unique within a project, enforced on write rather
  /// than by constraint, because a save replaces the whole list.
  TextColumn get envKey => text()();

  /// The value, stored as typed.
  TextColumn get envValue => text()();

  /// Whether to mask it in the editor. A display concern only -- every row is
  /// stored the same way, inside the encrypted database.
  BoolColumn get isSecret => boolean().withDefault(const Constant(false))();

  /// Display position, renumbered from zero on every save.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// When the row was written.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// Finished deploys and rollbacks. See [AppDeploymentHistoryRecord]: a row
/// exists only once a deploy has ended, successfully or not.
@DataClassName('AppDeploymentHistoryRow')
class AppDeploymentHistory extends Table {
  /// Autoincrement row id. The tiebreak for same-second deploys.
  IntColumn get id => integer().autoIncrement()(); // coverage:ignore-line

  /// Which project was deployed.
  TextColumn get projectId => text()();

  /// `success` or `failed`. Nothing else is written.
  TextColumn get status => text()(); // coverage:ignore-line

  /// The release produced, or null when the deploy failed before one existed.
  TextColumn get releaseId => text().nullable()();

  /// `deploy` or a rollback.
  TextColumn get deploymentKind =>
      text().withDefault(const Constant('deploy'))();

  /// For a rollback, the release that was live before it.
  TextColumn get rollbackFromReleaseId => text().nullable()();

  /// When the deploy ran. No default: it is the deploy's own time, not the
  /// time the row happened to be written.
  DateTimeColumn get deployedAt => dateTime()();

  /// How long it took. Never negative.
  IntColumn get durationSeconds => integer()();

  /// Who started it. `local-user` for the desktop app, so an agent-initiated
  /// redeploy is distinguishable.
  TextColumn get actor => text()();

  /// The branch deployed. `main` when unstated.
  TextColumn get branch => text()();

  /// The commit deployed. `unknown` when it could not be determined.
  TextColumn get commit => text()();

  /// When the row was written.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line
}

/// A local mirror of the versioned releases on a server. See
/// [AppReleaseRecord]: retained releases are what make a rollback a traffic
/// switch rather than a rebuild.
@DataClassName('AppReleaseRow')
class AppReleases extends Table {
  /// Derived from the server, project and release id.
  TextColumn get id => text()();

  /// Which project.
  TextColumn get projectId => text()();

  /// Which server.
  TextColumn get serverId => text()();

  /// The server's own id for the release. Unique within the scope, by
  /// constraint.
  TextColumn get releaseId => text()();

  /// `live`, `candidate`, `retained` or `failed`. An unrecognised value reads
  /// back as `retained`, the status that claims least.
  TextColumn get status => text()();

  /// `deploy` or a rollback.
  TextColumn get deploymentKind =>
      text().withDefault(const Constant('deploy'))();

  /// The branch deployed. `main` by default.
  TextColumn get branch => text().withDefault(const Constant('main'))();

  /// The commit deployed.
  TextColumn get commitSha => text().nullable()();

  /// The image built for it.
  TextColumn get imageName => text().nullable()();

  /// The container running it.
  TextColumn get webContainerName => text().nullable()();

  /// The port the app listens on inside that container.
  IntColumn get appPort => integer().nullable()();

  /// When the server created it.
  DateTimeColumn get createdAtRemote => dateTime().nullable()();

  /// When it took live traffic, or null if it never did.
  DateTimeColumn get liveAt => dateTime().nullable()();

  /// For a rollback, the release that was live before it.
  TextColumn get rollbackFromReleaseId => text().nullable()();

  /// Why the rollback happened -- typically a failed health gate.
  TextColumn get rollbackReason => text().nullable()();

  /// The runtime environment as JSON, as the server reported it.
  TextColumn get runtimeEnvJson => text().nullable()();

  /// The workers bound to this release, as JSON.
  TextColumn get workersJson => text().nullable()();

  /// When the server last confirmed the release still exists.
  DateTimeColumn get lastObservedAt => dateTime().nullable()();

  /// When the row was written.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'UNIQUE(project_id, server_id, release_id)',
  ];
}

/// The current runtime picture of a project's app. One row per project and
/// server, overwritten rather than appended. See [AppRuntimeSnapshotRecord].
@DataClassName('AppRuntimeSnapshotRow')
class AppRuntimeSnapshots extends Table {
  /// Which project.
  TextColumn get projectId => text()();

  /// Which server.
  TextColumn get serverId => text()();

  /// CPU, memory and disk as JSON.
  TextColumn get resourceUsageJson => text().nullable()();

  /// The container's effective status, as one word.
  TextColumn get healthStatus => text().nullable()();

  /// The public-URL check result as JSON, decoded by
  /// `AppPublicHealthSnapshot`.
  TextColumn get publicHealthJson => text().nullable()();

  /// When health was last checked.
  DateTimeColumn get healthCheckedAt => dateTime().nullable()();

  /// When resource usage was last read. Separate because the two are polled
  /// independently -- resource usage is expensive and health is not.
  DateTimeColumn get resourceCheckedAt => dateTime().nullable()();

  /// When this row last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {projectId, serverId};
}

/// The background workers a project runs. See [WorkerInstanceRecord] for the
/// clamps applied to the resource limits.
@DataClassName('WorkerInstanceRow')
class WorkerInstances extends Table {
  /// The worker's id, and what its container is named after.
  TextColumn get id => text()();

  /// Which project it belongs to.
  TextColumn get projectId => text()();

  /// What the user calls it. Falls back to [id] when left blank.
  TextColumn get name => text()();

  /// The command the container runs.
  TextColumn get startCommand => text()();

  /// CPU cores. Half a core by default, clamped to 0.1-64 on write so one
  /// worker cannot starve the web app beside it.
  RealColumn get cpuLimit => real().withDefault(const Constant(0.5))();

  /// Memory in MB. 256 by default, clamped to 128-1048576.
  IntColumn get memoryMb => integer().withDefault(const Constant(256))();

  /// Disk in MB. 1024 by default, clamped to 256-1048576.
  IntColumn get diskMb => integer().withDefault(const Constant(1024))();

  /// The managed database user this worker connects as. The four database
  /// columns stand or fall together -- without a user, the rest are cleared.
  TextColumn get databaseUser => text().nullable()();

  /// The database that user connects to.
  TextColumn get databaseName => text().nullable()();

  /// That user's password.
  TextColumn get databasePassword => text().nullable()();

  /// Which engine. Only `postgres` is recognised; anything else stores null.
  TextColumn get databaseEngine => text().nullable()();

  /// Whether the worker should be running. On by default.
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// Display position, renumbered from zero on every save.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// When the worker was defined.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {projectId, id};
}

/// The current state of a project's workers. One row per project and server.
/// See [WorkerRuntimeSnapshotRecord].
@DataClassName('WorkerRuntimeSnapshotRow')
class WorkerRuntimeSnapshots extends Table {
  /// Which project.
  TextColumn get projectId => text()();

  /// Which server.
  TextColumn get serverId => text()();

  /// The whole worker status payload as JSON, stored opaquely because the
  /// shape belongs to the workers workflow rather than to this table.
  TextColumn get snapshotJson => text()();

  /// When the workers were last inspected.
  DateTimeColumn get lastCheckedAt => dateTime().nullable()();

  /// When this row last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {projectId, serverId};
}

/// Recurring commands a project runs on its server. See
/// [SchedulerTaskRecord] for the split between user-written and
/// service-managed tasks.
@DataClassName('SchedulerTaskRow')
class SchedulerTasks extends Table {
  /// The task's id, and how the server addresses it.
  TextColumn get id => text()();

  /// Which project it belongs to.
  TextColumn get projectId => text()();

  /// `custom` or `service`, saying what created it.
  TextColumn get sourceType => text().withDefault(const Constant('custom'))();

  /// Whether a Deploy Dash feature owns it. A managed task must not be
  /// hand-edited: its owner replaces every one of its tasks on each save.
  BoolColumn get managedByService =>
      boolean().withDefault(const Constant(false))();

  /// What the user calls it.
  TextColumn get name => text()();

  /// What the command runs against -- the app container, or a worker.
  TextColumn get targetType => text()();

  /// Which worker, when the target is one. Cleared for any other target.
  TextColumn get targetRef => text().nullable()();

  /// The command to run.
  TextColumn get command => text()();

  /// `daily_at`, or an interval schedule.
  TextColumn get scheduleType => text()();

  /// Minutes between runs, clamped to 1-1440. Null for a `daily_at` schedule;
  /// this and [dailyTime] are mutually exclusive.
  IntColumn get intervalValue => integer().nullable()();

  /// `HH:MM` for a `daily_at` schedule, defaulting to `02:00` when
  /// unparseable.
  TextColumn get dailyTime => text().nullable()();

  /// Whether the task should run. On by default.
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// What the server last reported about it.
  TextColumn get lastKnownState => text().nullable()();

  /// The detail behind that state.
  TextColumn get lastKnownMessage => text().nullable()();

  /// When it last ran, as the server reported.
  DateTimeColumn get lastRunAt => dateTime().nullable()();

  /// When it is next due, as the server reported.
  DateTimeColumn get nextRunAt => dateTime().nullable()();

  /// Display position within its group.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// When the task was defined.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {projectId, id};
}

/// Executions of scheduled tasks. Trimmed per task rather than per project,
/// so a frequent task cannot crowd out a daily one's history.
@DataClassName('SchedulerTaskRunRow')
class SchedulerTaskRuns extends Table {
  /// Autoincrement row id. The tiebreak for runs sharing a timestamp.
  IntColumn get id => integer().autoIncrement()(); // coverage:ignore-line

  /// Which task ran.
  TextColumn get taskId => text()();

  /// Which project it belongs to.
  TextColumn get projectId => text()();

  /// How it ended, as the server reported.
  TextColumn get status => text()(); // coverage:ignore-line

  /// The detail behind that status.
  TextColumn get message => text().nullable()();

  /// Whether a person pressed "run now" rather than the schedule firing. Kept
  /// because an unexpected run is explained by this and nothing else.
  BoolColumn get triggeredManually =>
      boolean().withDefault(const Constant(false))();

  /// When the run started.
  DateTimeColumn get triggeredAt =>
      dateTime().withDefault(currentDateAndTime)();

  /// When the row was written.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line
}

/// Where a project's backups can be written. See
/// [BackupDestinationRecord].
@DataClassName('BackupDestinationRow')
class BackupDestinations extends Table {
  /// The destination's id.
  TextColumn get id => text()();

  /// Which project owns it.
  TextColumn get projectId => text()();

  /// Which server it is configured for.
  TextColumn get serverId => text()();

  /// What the user calls it.
  TextColumn get name => text()();

  /// `s3` or `filesystem`.
  TextColumn get type => text()();

  /// Type-specific settings as JSON -- bucket, keys and region for S3, a path
  /// prefix for a filesystem. An open shape, because the two have nothing in
  /// common.
  TextColumn get configJson => text()();

  /// When the destination was created.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Backup schedules for managed PostgreSQL. See [BackupPolicyRecord].
///
/// Per engine rather than one table with an engine column, so adding a second
/// engine is a schema decision someone has to make rather than a value that
/// quietly appears.
@DataClassName('PostgresBackupPolicyRow')
class PostgresBackupPolicies extends Table {
  /// The plan's id, and what its scheduler task id is derived from.
  TextColumn get id => text()();

  /// Which project owns it.
  TextColumn get projectId => text()();

  /// Which server it runs on.
  TextColumn get serverId => text()();

  /// What the user calls it. Falls back to [id] when left blank.
  TextColumn get name => text()();

  /// The destination backups are written to.
  TextColumn get destinationId => text()();

  /// The database being backed up.
  TextColumn get databaseName => text()();

  /// `daily_once` or `daily_twice`.
  TextColumn get scheduleMode => text()();

  /// The first run time as `HH:MM`, defaulting to `02:00` when unparseable.
  TextColumn get time1Hhmm => text()();

  /// The second run time for a twice-daily plan, defaulting to `14:00`. Null
  /// for a once-daily plan.
  TextColumn get time2Hhmm => text().nullable()();

  /// How many backups to keep. Seven by default, clamped to 1-3650 -- never
  /// zero, which would delete each backup as soon as it was made.
  IntColumn get retentionKeepLast => integer().withDefault(const Constant(7))();

  /// Whether the plan should run. On by default.
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// The scheduler task on the server that fires it. Derived from [id], so
  /// both sides agree without a second record to keep in sync.
  TextColumn get managedTaskId => text()();

  /// When the plan last ran.
  DateTimeColumn get lastRunAt => dateTime().nullable()();

  /// How that run ended.
  TextColumn get lastStatus => text().nullable()();

  /// What it reported.
  TextColumn get lastMessage => text().nullable()();

  /// When the plan was created.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Backup files discovered at a destination. See [BackupArtifactRecord]:
/// discovered by listing, so what the restore picker offers is what is there.
@DataClassName('BackupArtifactRow')
class BackupArtifacts extends Table {
  /// Derived from the policy and remote path, so re-listing does not
  /// duplicate rows.
  TextColumn get id => text()();

  /// Which engine produced it.
  TextColumn get engine => text().withDefault(const Constant('postgres'))();

  /// The plan it belongs to.
  TextColumn get policyId => text()();

  /// Which project.
  TextColumn get projectId => text()();

  /// Which server.
  TextColumn get serverId => text()();

  /// The destination it lives at.
  TextColumn get destinationId => text()();

  /// The database it holds.
  TextColumn get databaseName => text()();

  /// Its path at the destination. The artifact's real identity, and what a
  /// restore acts on.
  TextColumn get remotePath => text()();

  /// When the destination says it was created.
  DateTimeColumn get createdAtRemote => dateTime().nullable()();

  /// Its size in bytes, when reported.
  IntColumn get sizeBytes => integer().nullable()();

  /// Format and build metadata as JSON, for restore diagnostics.
  TextColumn get metadataJson => text().nullable()();

  /// When Deploy Dash last saw it in a listing.
  DateTimeColumn get discoveredAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Backups and restores that have happened. See [BackupRunRecord].
@DataClassName('BackupRunRow')
class BackupRuns extends Table {
  /// Autoincrement row id. The tiebreak for runs sharing a start time.
  IntColumn get id => integer().autoIncrement()(); // coverage:ignore-line

  /// Which engine.
  TextColumn get engine => text().withDefault(const Constant('postgres'))();

  /// Which project.
  TextColumn get projectId => text()();

  /// Which server.
  TextColumn get serverId => text()();

  /// The plan behind it, or null for a one-off restore no plan scheduled.
  TextColumn get policyId => text().nullable()();

  /// `backup` or `restore`.
  TextColumn get operationType => text()();

  /// How it ended. `unknown` when the caller did not say.
  TextColumn get status => text()(); // coverage:ignore-line

  /// What it reported.
  TextColumn get message => text().nullable()();

  /// Whether a person started it rather than the schedule.
  BoolColumn get triggeredManually =>
      boolean().withDefault(const Constant(false))();

  /// The scheduler task that fired it, when one did.
  TextColumn get taskId => text().nullable()();

  /// The artifact it produced or restored from.
  TextColumn get artifactId => text().nullable()();

  /// When it began.
  DateTimeColumn get startedAt => dateTime().withDefault(currentDateAndTime)();

  /// When it ended, or null while still running.
  DateTimeColumn get finishedAt => dateTime().nullable()();

  /// When the row was written.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line
}

/// How far the first import of a project's existing server state has got.
/// See [ProjectWorkspaceImportStateRecord].
@DataClassName('ProjectWorkspaceImportStateRow')
class ProjectWorkspaceImportStates extends Table {
  /// Which project.
  TextColumn get projectId => text()();

  /// Which server.
  TextColumn get serverId => text()();

  /// `pending`, `importing`, `imported`, `failed` or `skipped`. Defaults to
  /// `pending`, and an unrecognised value reads back as pending -- so the
  /// import is retried rather than assumed done.
  TextColumn get status => text().withDefault(const Constant('pending'))();

  /// When the import began.
  DateTimeColumn get startedAt => dateTime().nullable()();

  /// When it ended.
  DateTimeColumn get finishedAt => dateTime().nullable()();

  /// Why it failed.
  TextColumn get errorMessage => text().nullable()();

  /// When this row last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {projectId, serverId};
}

/// Managed operations recorded before they run, so one that finishes while
/// the app is closing is not lost. See [ProjectManagedOperationJournalRecord].
@DataClassName('ProjectManagedOperationJournalRow')
class ProjectManagedOperationJournal extends Table {
  /// The entry's id, generated from the time, surface and operation.
  TextColumn get id => text()();

  /// Which project.
  TextColumn get projectId => text()();

  /// Which server.
  TextColumn get serverId => text()();

  /// Which part of the app started it.
  TextColumn get surface => text()();

  /// Which operation was run.
  TextColumn get operationType => text()();

  /// `pending_remote`, `remote_success` or `failed`.
  TextColumn get status => text()();

  /// The request as JSON, **with sensitive fields redacted** -- these rows
  /// outlive the operation and are read on a later launch.
  TextColumn get requestJson => text().nullable()();

  /// The result as JSON, redacted the same way unless the caller needed it
  /// intact to update the local mirror.
  TextColumn get resultJson => text().nullable()();

  /// Why it failed.
  TextColumn get errorMessage => text().nullable()();

  /// When the entry was created, which is before the operation ran.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line

  /// When it last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Deletions that have started but not finished. See
/// [ProjectDeletionRecoveryRecord].
///
/// While a row exists here, its project is hidden from every ordinary read --
/// which is what stops a project whose cleanup is still running from
/// reappearing as though nothing had happened.
@DataClassName('ProjectDeletionRecoveryStateRow')
class ProjectDeletionRecoveryStates extends Table {
  /// The project being deleted.
  TextColumn get projectId => text()();

  /// Its server, when it had one.
  TextColumn get serverId => text().nullable()();

  /// Its name, copied here so the retry screen can still name it after the
  /// project row is gone.
  TextColumn get projectName => text()();

  /// Its slug, copied for the same reason: the engine addresses resources by
  /// slug, and a retry needs it once the project row no longer exists.
  TextColumn get projectSlug => text()();

  /// `pending_remote` while cleanup can proceed, `cleanup_failed` once a step
  /// has failed and the user must decide.
  TextColumn get status =>
      text().withDefault(const Constant('pending_remote'))();

  /// Each step and how it ended, as a JSON list. The list a retry works from.
  TextColumn get stepStatesJson => text().withDefault(const Constant('{}'))();

  /// The most recent failure message.
  TextColumn get lastError => text().nullable()();

  /// How many times cleanup has been attempted.
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();

  /// When the user asked for the deletion. No default: it is preserved across
  /// retries rather than reset by them.
  DateTimeColumn get requestedAt => dateTime()();

  /// When cleanup was last attempted.
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();

  /// When this row last changed.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {projectId};
}

/// Which project screens have been opened, for the rail's recent list. See
/// [ProjectScreenVisitRecord].
@DataClassName('ProjectScreenVisitRow')
class ProjectScreenVisits extends Table {
  /// The project that was open.
  TextColumn get projectId => text()();

  /// Which screen within it. One row per project and screen, by primary key,
  /// so a repeatedly visited screen cannot crowd out everything else.
  TextColumn get destinationId => text()();

  /// When it was last opened. Updated in place.
  DateTimeColumn get visitedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {projectId, destinationId};
}

/// The user's record of what an external agent did on their behalf. See
/// [AgentAuditEntryRecord]; failed attempts are recorded as well as
/// successful ones.
@DataClassName('AgentAuditEntryRow')
class AgentAuditEntries extends Table {
  /// Autoincrement row id. Also the tiebreak that makes "recent" mean recent,
  /// since [createdAt] is only accurate to the second.
  IntColumn get id => integer().autoIncrement()(); // coverage:ignore-line

  /// Which MCP tool was called.
  TextColumn get toolName => text()(); // coverage:ignore-line

  /// What that tool is allowed to do.
  TextColumn get accessLevel => text()(); // coverage:ignore-line

  /// How the call ended, lower-cased.
  TextColumn get status => text()(); // coverage:ignore-line

  /// One line describing what happened.
  TextColumn get summary => text()(); // coverage:ignore-line

  /// Structured detail as JSON.
  TextColumn get detailsJson => text().nullable()(); // coverage:ignore-line

  /// When it happened. SQLite's clock, so whole seconds.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)(); // coverage:ignore-line
}

/// The operation queue, mirrored so operations in flight when the app dies
/// are visible after a restart. Exactly one row, at id 1.
///
/// Restored entries are always reported as failed and uncertain -- see
/// `OperationConcurrencyEngine.restoreRecoveredSnapshots`.
@DataClassName('OperationRecoveryStateRow')
class OperationRecoveryStates extends Table {
  /// Always 1.
  IntColumn get id => integer()();

  /// The whole queue as a JSON list, capped by the writer. One column rather
  /// than a row per operation, because it is written whole on every queue
  /// change and never queried by field.
  TextColumn get snapshotsJson => text().withDefault(const Constant('[]'))();

  /// When the queue was last mirrored.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    Servers,
    ServerCredentials,
    OnboardingStateEntries,
    AppPreferences,
    DeviceInstallations,
    DeviceUpdateStates,
    TerminalLogs,
    Projects,
    ProjectSqliteDatabases,
    ProjectSqliteSnapshotExports,
    ProjectDatabaseAccessGrants,
    ProjectDatabaseAccessUsers,
    ProjectManagedDatabases,
    ProjectManagedDatabaseUsers,
    ProjectNetworkGroups,
    ProjectNetworkGroupMembers,
    GitHubAuthTokens,
    GitHubDeployKeys,
    AppEnvironmentVariables,
    AppDeploymentHistory,
    AppReleases,
    AppRuntimeSnapshots,
    WorkerInstances,
    WorkerRuntimeSnapshots,
    SchedulerTasks,
    SchedulerTaskRuns,
    BackupDestinations,
    PostgresBackupPolicies,
    BackupArtifacts,
    BackupRuns,
    ProjectWorkspaceImportStates,
    ProjectManagedOperationJournal,
    ProjectDeletionRecoveryStates,
    ProjectScreenVisits,
    AgentAuditEntries,
    OperationRecoveryStates,
  ],
)
/// The encrypted local database. Everything Deploy Dash persists lives here,
/// except the device identity, which must be readable before unlock.
///
/// Local-first: this is the authority for the user's own configuration, and a
/// mirror for everything that actually lives on their servers.
class AppDatabase extends _$AppDatabase {
  /// Opens the database, encrypted with [passphrase].
  ///
  /// Without a passphrase the connection is unencrypted, which is only
  /// meaningful before one has been created.
  AppDatabase({QueryExecutor? executor, String? passphrase})
    : super(executor ?? _openConnection(passphrase: passphrase));

  /// Opens the database over a caller-supplied executor, for tests.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => appDatabaseSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.addColumn(servers, servers.setupComplete);
      }
    },
    onCreate: (migrator) async {
      await migrator.createAll();
      await into(
        onboardingStateEntries,
      ).insert(OnboardingStateEntriesCompanion.insert(id: const Value(1)));
      await into(
        appPreferences,
      ).insert(AppPreferencesCompanion.insert(id: const Value(1)));
      await into(
        operationRecoveryStates,
      ).insert(OperationRecoveryStatesCompanion.insert(id: const Value(1)));
      await _createWorkspaceScopeIndexes();
    },
    beforeOpen: (details) async {
      final existing = await (select(
        onboardingStateEntries,
      )..where((table) => table.id.equals(1))).getSingleOrNull();
      if (existing == null) {
        await into(
          onboardingStateEntries,
        ).insert(OnboardingStateEntriesCompanion.insert(id: const Value(1)));
      }
      final preferences = await (select(
        appPreferences,
      )..where((table) => table.id.equals(1))).getSingleOrNull();
      if (preferences == null) {
        await into(
          appPreferences,
        ).insert(AppPreferencesCompanion.insert(id: const Value(1)));
      }
      final operationRecovery = await (select(
        operationRecoveryStates,
      )..where((table) => table.id.equals(1))).getSingleOrNull();
      if (operationRecovery == null) {
        await into(
          operationRecoveryStates,
        ).insert(OperationRecoveryStatesCompanion.insert(id: const Value(1)));
      }
    },
  );

  // coverage-gate: workspace_scope_indexes
  Future<void> _createWorkspaceScopeIndexes() async {
    if (!await _tableExists(this, 'terminal_logs')) {
      return;
    }
    await customStatement(
      'CREATE INDEX IF NOT EXISTS terminal_logs_scope_created_at_idx '
      'ON terminal_logs(project_id, server_id, created_at, id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS terminal_logs_task_scope_created_at_idx '
      'ON terminal_logs(task_type, project_id, server_id, created_at, id);',
    );
  }
  // end coverage-gate

  /// Reads the mirrored operation queue, or an empty list.
  ///
  /// Swallows a SQLite error, malformed JSON, and a closed database alike:
  /// recovery snapshots are a convenience, and neither a corrupt row nor a
  /// race with shutdown may stop the app starting or resurrect a stale queue.
  Future<List<Map<String, dynamic>>> readOperationRecoverySnapshotMaps() async {
    try {
      final entry = await (select(
        operationRecoveryStates,
      )..where((table) => table.id.equals(1))).getSingleOrNull();
      if (entry == null || entry.snapshotsJson.trim().isEmpty) {
        return const <Map<String, dynamic>>[];
      }

      final decoded = jsonDecode(entry.snapshotsJson);
      if (decoded is! List) {
        return const <Map<String, dynamic>>[];
      }

      final snapshots = <Map<String, dynamic>>[];
      // D-58 (T-014): left — String-map items are aliased in (not copied)
      // like normalizeList; mapListFrom copies every entry instead.
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          snapshots.add(item);
          continue;
        }
        if (item is Map) {
          snapshots.add(
            item.map((key, value) => MapEntry(key.toString(), value)),
          );
        }
      }
      return snapshots;
    } on sqlite.SqliteException {
      return const <Map<String, dynamic>>[];
    } on FormatException {
      return const <Map<String, dynamic>>[];
    } on StateError {
      // Recovery snapshots are optional; a closed database cannot block
      // startup or resurrect a stale operation queue.
      return const <Map<String, dynamic>>[];
    }
  }

  /// Mirrors the operation queue, replacing whatever was there.
  ///
  /// The caller caps the list first; this writes what it is given.
  Future<void> writeOperationRecoverySnapshotMaps(
    List<Map<String, dynamic>> snapshots,
  ) async {
    final serialized = jsonEncode(snapshots);
    await into(operationRecoveryStates).insertOnConflictUpdate(
      OperationRecoveryStatesCompanion.insert(
        id: const Value(1),
        snapshotsJson: Value(serialized),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }
}

/// Prepares encrypted SQLite. A no-op on every current platform.
///
/// Kept as an explicit call site because it was once platform-specific and
/// may be again: `sqlite3`'s native asset hook now bundles
/// SQLite3MultipleCiphers everywhere, so no dynamic-library override is
/// needed.
Future<void> initializeAppDatabaseEncryption() async {
  // sqlite3's native asset hook bundles SQLite3MultipleCiphers on every
  // desktop platform. No platform-specific dynamic-library override is needed.
}

// coverage-gate: app_database_passphrase_proof
/// Whether [file] exists and holds at least one byte.
///
/// Why: the return-false guards (validators, existence checks) and the
/// void-return guard (format enforcement) all ask this one question; the
/// throw sites do NOT use it -- they need distinct missing/empty messages
/// (see [_requireNonEmptyFile]). A zero-length file counts as absent -- it
/// is what an interrupted creation leaves behind.
Future<bool> _isNonEmptyFile(File file) async {
  return await file.exists() && await file.length() > 0;
}

/// Throws when [file] is missing or empty, naming which.
///
/// Why: restore's source checks are the only throw-behavior guards in this
/// file -- every other guard returns false or void. One owner keeps the
/// sequential-check structure (missing first, then empty) and the two
/// messages from drifting apart.
Future<void> _requireNonEmptyFile(
  File file, {
  required String missingMessage,
  required String emptyMessage,
}) async {
  if (!await file.exists()) {
    throw StateError(missingMessage);
  }
  if (await file.length() == 0) {
    throw StateError(emptyMessage);
  }
}

/// Whether a non-empty database file already exists.
///
/// A zero-length file counts as absent -- it is what an interrupted creation
/// leaves behind, and treating it as a real database would lock the user out
/// of an app they had not yet used.
Future<bool> appDatabaseExists() async {
  final file = await _resolveDatabaseFile();
  return _isNonEmptyFile(file);
}

/// Whether [passphrase] opens the live database.
///
/// Actually opens it and reads `sqlite_master`, because that is the only
/// thing that proves a passphrase: SQLCipher accepts any key at open time and
/// fails on the first read.
Future<bool> validateAppDatabasePassphrase(String passphrase) async {
  final databaseFile = await _resolveDatabaseFile();
  return _validatePassphraseForFile(
    databaseFile,
    passphrase,
    secureStorage: _secureAppDatabaseStorage,
  );
}

/// Whether [passphrase] opens the backup file at [sourcePath].
///
/// The same proof as [validateAppDatabasePassphrase], applied to a file the
/// user picked -- checked *before* it is copied over their live database.
Future<bool> validateAppDatabaseBackupPassphrase({
  required String sourcePath,
  required String passphrase,
}) async {
  return _validatePassphraseForFile(File(sourcePath), passphrase);
}

/// Proves [passphrase] opens [file], returning false instead of throwing.
///
/// Why: the live-database and backup-file validators share trim-guard,
/// exists-guard, open-configure-probe-close and differ only in file
/// resolution; one owner keeps the probe (and its no-throw contract) single.
///
/// [file] is the RESOLVED file: resolution stays at the call sites (the live
/// validator resolves, the backup validator takes the caller path).
/// [passphrase] is trimmed inside, and the trimmed value is what the
/// encryption is configured with. [secureStorage] null means skip (the
/// backup path never secures); non-null is awaited before the exists check
/// (the live path).
Future<bool> _validatePassphraseForFile(
  File file,
  String passphrase, {
  Future<void> Function(File file)? secureStorage,
}) async {
  final trimmedPassphrase = passphrase.trim();
  if (trimmedPassphrase.isEmpty) {
    return false;
  }
  if (secureStorage != null) {
    await secureStorage(file);
  }
  if (!await _isNonEmptyFile(file)) {
    return false;
  }
  final database = sqlite.sqlite3.open(file.path);
  try {
    configureAppDatabaseEncryption(database, passphrase: trimmedPassphrase);
    database.select('SELECT COUNT(*) AS c FROM sqlite_master;');
    return true;
  } on sqlite.SqliteException {
    return false;
  } finally {
    database.close();
  }
}
// end coverage-gate

/// Creates the encrypted database with [passphrase], or leaves nothing
/// behind.
///
/// See `createDatabasePassphraseWithDependencies` for the sequence and why
/// each step is there. A failure is recorded for
/// [appDatabasePassphraseCreationFailureDetails] rather than thrown, since
/// this runs on the first-run screen where the message must be shown, not
/// propagated.
Future<bool> createAppDatabasePassphrase(String passphrase) async {
  _lastAppDatabasePassphraseCreationFailure = null;
  final databaseFile = await _resolveDatabaseFile();
  return createDatabasePassphraseWithDependencies(
    passphrase: passphrase,
    databaseAlreadyExists: () => _isNonEmptyFile(databaseFile),
    deleteDatabaseFiles: () => _deleteDatabaseFileAndSidecars(databaseFile),
    openDatabase: (normalizedPassphrase) async =>
        _AppDatabasePassphraseCreationHandle(
          AppDatabase(passphrase: normalizedPassphrase),
          databaseFile,
        ),
    validatePassphrase: validateAppDatabasePassphrase,
    reportFailure: (error) {
      _lastAppDatabasePassphraseCreationFailure =
          _sanitizeAppDatabasePassphraseCreationFailure(
            error: error,
            passphrase: passphrase.trim(),
          );
    },
  );
}

// coverage-gate: app_database_passphrase_failure
/// Why the last creation attempt failed, or null.
///
/// The passphrase is stripped from the text and the result is truncated:
/// this string reaches a diagnostics view, and the one thing it must never
/// carry is the password the user just typed.
String? appDatabasePassphraseCreationFailureDetails() {
  return _lastAppDatabasePassphraseCreationFailure;
}

String _sanitizeAppDatabasePassphraseCreationFailure({
  required Object error,
  required String passphrase,
}) {
  final details = error.toString().replaceAll(passphrase, '[redacted]');
  const maximumLength = 1000;
  if (details.length <= maximumLength) {
    return details;
  }
  return '${details.substring(0, maximumLength)}...';
}

// end coverage-gate
/// The redaction applied to a creation failure, exposed for tests.
String debugSanitizeAppDatabasePassphraseCreationFailure({
  required Object error,
  required String passphrase,
}) {
  return _sanitizeAppDatabasePassphraseCreationFailure(
    error: error,
    passphrase: passphrase,
  );
}

// coverage-gate: app_database_passphrase_creation_handle
class _AppDatabasePassphraseCreationHandle
    implements DatabasePassphraseCreationHandle {
  _AppDatabasePassphraseCreationHandle(this._database, this._databaseFile);

  final AppDatabase _database;
  final File _databaseFile;

  @override
  Future<void> warmUp() async {
    await _database
        .customSelect('SELECT COUNT(*) AS c FROM sqlite_master;')
        .get();
    await _secureAppDatabaseStorage(_databaseFile);
  }

  @override
  Future<void> close() => _database.close();
}

/// Changes the database password in place.
///
/// The current password is verified first, so a typo cannot re-key the
/// database to something the user did not intend. After `PRAGMA rekey` a read
/// is forced, because a rekey that has not been exercised is not yet proof
/// the new key works.
///
/// **Files already exported keep the old password.** Rekeying changes the
/// live database only; every previously exported snapshot still needs the
/// password in force when it was written.
///
/// Throws [StateError] for a blank current or new password, for a new
/// password equal to the current one, or when the current one is wrong.
Future<void> rotateAppDatabasePassphrase({
  required AppDatabase database,
  required String currentPassphrase,
  required String newPassphrase,
}) async {
  final normalizedCurrentPassphrase = currentPassphrase.trim();
  final normalizedNewPassphrase = newPassphrase.trim();

  if (normalizedCurrentPassphrase.isEmpty) {
    throw StateError('Current password is required.');
  }
  if (normalizedNewPassphrase.isEmpty) {
    throw StateError('New password is required.');
  }
  if (normalizedCurrentPassphrase == normalizedNewPassphrase) {
    throw StateError('New password must be different from current password.');
  }
  if (!await validateAppDatabasePassphrase(normalizedCurrentPassphrase)) {
    throw StateError('Current password is incorrect.');
  }

  await database.customStatement(
    "PRAGMA rekey = '${escapeSqlLiteral(normalizedNewPassphrase)}';",
  );
  await database.customSelect('SELECT COUNT(*) AS c FROM sqlite_master;').get();
}

// end coverage-gate
LazyDatabase _openConnection({String? passphrase}) {
  final normalizedPassphrase = passphrase?.trim();
  return LazyDatabase(() async {
    final file = await _resolveDatabaseFile();
    await _secureAppDatabaseStorage(file);
    final executor = NativeDatabase.createInBackground(
      file,
      setup: (rawDb) {
        if (normalizedPassphrase == null || normalizedPassphrase.isEmpty) {
          return;
        }
        configureAppDatabaseEncryption(rawDb, passphrase: normalizedPassphrase);
        _repairMissingAppDatabaseUserVersion(rawDb);
      },
    );
    return executor;
  });
}

Future<File> Function()? _databaseFileResolverOverride;
String? _lastAppDatabasePassphraseCreationFailure;

/// Puts a raw connection into the app's encryption configuration.
///
/// Verifies an encrypted SQLite build is present before doing anything --
/// `PRAGMA cipher` returning nothing means the runtime cannot encrypt, and
/// proceeding would silently create a plaintext database holding the user's
/// server credentials.
///
/// Pins SQLCipher v4 compatibility so databases and backups written by
/// earlier builds stay readable.
///
/// Throws [StateError] when the encrypted runtime is unavailable.
void configureAppDatabaseEncryption(
  sqlite.Database rawDb, {
  required String passphrase,
}) {
  final rows = rawDb.select('PRAGMA cipher;');
  if (rows.isEmpty) {
    throw StateError('Encrypted SQLite runtime is not available.');
  }
  final cipher = rows.first.columnAt(0)?.toString().trim() ?? '';
  if (cipher.isEmpty) {
    throw StateError('Encrypted SQLite runtime is not available.');
  }
  // Retain compatibility with SQLCipher v4 databases and prior app backups.
  rawDb.execute("PRAGMA cipher = 'sqlcipher';");
  rawDb.execute('PRAGMA legacy = 4;');
  rawDb.execute("PRAGMA key = '${escapeSqlLiteral(passphrase)}';");
}

/// Escapes [input] for embedding in a single-quoted SQL literal.
///
/// Why: the encryption-key pragmas and the backup snapshot's provenance
/// INSERT share this one doubling rule; one owner keeps a second spelling
/// (and a SQL-injection-shaped divergence) from appearing.
String escapeSqlLiteral(String input) {
  return input.replaceAll("'", "''");
}

void _repairMissingAppDatabaseUserVersion(sqlite.Database rawDb) {
  if (readSqliteUserVersion(rawDb) != 0) {
    return;
  }
  if (!_looksLikeCurrentAppDatabaseSchema(rawDb)) {
    return;
  }
  rawDb.execute('PRAGMA user_version = $appDatabaseSchemaVersion;');
}

/// Reads `PRAGMA user_version`, defaulting to 0 when it is missing.
///
/// Why: the repair path and the backup snapshotter both need the schema
/// stamp; one owner keeps the empty/null defaulting single. A missing or
/// null version reads as 0 (never set), which is what the repair check
/// compares against.
int readSqliteUserVersion(sqlite.Database database) {
  final rows = database.select('PRAGMA user_version;');
  if (rows.isEmpty) {
    return 0;
  }
  return rows.first.columnAt(0) as int? ?? 0;
}

Future<bool> _tableExists(GeneratedDatabase database, String tableName) async {
  final rows = await database
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;",
        variables: [Variable<String>(tableName)],
      )
      .get();
  return rows.isNotEmpty;
}

bool _looksLikeCurrentAppDatabaseSchema(sqlite.Database rawDb) {
  final requiredTables = <String>{
    'onboarding_state_entries',
    'app_preferences',
    'projects',
    'server_credentials',
  };
  final presentTables = rawDb
      .select(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' AND name IN "
        "('onboarding_state_entries', 'app_preferences', 'projects', "
        "'server_credentials');",
      )
      .map((row) => row['name'] as String?)
      .whereType<String>()
      .toSet();
  if (!presentTables.containsAll(requiredTables)) {
    return false;
  }

  final columns = rawDb
      .select('PRAGMA table_info(projects);')
      .map((row) => row['name'] as String?)
      .whereType<String>()
      .toSet();
  return columns.contains('domain_routing_mode');
}

Future<File> _resolveDatabaseFile() async {
  final override = _databaseFileResolverOverride;
  if (override != null) {
    return override();
  }
  final appSupportDirectory = await resolveAppDataDirectory();
  final databasePath = p.join(appSupportDirectory.path, 'deploydash_state.db');
  final databaseFile = File(databasePath);
  await _secureAppDatabaseStorage(databaseFile);
  return databaseFile;
}

/// The live database file, honouring any test override.
Future<File> resolveAppDatabaseFile() => _resolveDatabaseFile();

/// Refuses to proceed with a SQLite backup this build does not understand.
///
/// The backup at [sourcePath] is opened with [passphrase] (the caller must
/// already have validated it separately -- this function trusts that
/// invariant rather than re-checking it) and its
/// `deploydash_backup_metadata` table, if present, is read for
/// `backup_format_version`. A file with no such table (older than the
/// metadata table itself) or a `backup_format_version` at or below
/// [sqliteBackupFormatVersion] is supported and this returns normally. A
/// `backup_format_version` greater than [sqliteBackupFormatVersion] throws
/// [StateError]: this build cannot know what a newer format may have
/// changed, so it refuses rather than guessing.
Future<void> enforceSqliteBackupFormatVersion({
  required String sourcePath,
  required String passphrase,
}) async {
  final sourceFile = File(sourcePath);
  if (!await _isNonEmptyFile(sourceFile)) {
    return;
  }

  final database = sqlite.sqlite3.open(sourceFile.path);
  try {
    configureAppDatabaseEncryption(database, passphrase: passphrase.trim());
    final tableRows = database.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name = 'deploydash_backup_metadata';",
    );
    if (tableRows.isEmpty) {
      return;
    }
    final metadataRows = database.select(
      'SELECT backup_format_version FROM deploydash_backup_metadata LIMIT 1;',
    );
    if (metadataRows.isEmpty) {
      return;
    }
    final version = metadataRows.first['backup_format_version'] as int?;
    if (version != null && version > sqliteBackupFormatVersion) {
      throw StateError(
        'This backup was created by a newer version of Deploy Dash '
        '(backup format $version) and cannot be restored by this build, '
        'which supports up to format $sqliteBackupFormatVersion. Update '
        'Deploy Dash and try again.',
      );
    }
  } finally {
    database.close();
  }
}

/// Same policy as [enforceSqliteBackupFormatVersion], applied to whichever
/// file is currently installed as the live app database. Startup restore
/// (`DatabaseUnlockGate`) copies a chosen backup file into place before any
/// passphrase is known, so it cannot check the source file up front the way
/// App Settings' restore-from-S3 flow can; this is the next point in that
/// flow where a passphrase becomes available, immediately before the app
/// proceeds to actually use the (possibly just-restored) database.
Future<void> enforceCurrentAppDatabaseBackupFormatVersion(
  String passphrase,
) async {
  final file = await _resolveDatabaseFile();
  await enforceSqliteBackupFormatVersion(
    sourcePath: file.path,
    passphrase: passphrase,
  );
}

/// Installs a backup file as the live database.
///
/// Staged through a `.restoring` temporary and renamed into place, with the
/// stale `-wal` and `-shm` sidecars removed first -- leaving them would make
/// SQLite read a journal belonging to the previous database over the restored
/// one.
///
/// Refuses to replace an existing database unless [overwriteExisting] is set;
/// restoring over someone's data is not something to do by default. Restoring
/// a file that is already the live database returns it unchanged.
///
/// Throws [StateError] when the source is missing, empty, or would overwrite
/// an existing database without permission.
Future<File> restoreAppDatabaseFromBackupFile({
  required String sourcePath,
  bool overwriteExisting = false,
}) async {
  final sourceFile = File(sourcePath);
  await _requireNonEmptyFile(
    sourceFile,
    missingMessage: 'Backup file does not exist.',
    emptyMessage: 'Backup file is empty.',
  );

  final targetFile = await _resolveDatabaseFile();
  final normalizedSourcePath = p.normalize(sourceFile.absolute.path);
  final normalizedTargetPath = p.normalize(targetFile.absolute.path);
  if (normalizedSourcePath == normalizedTargetPath) {
    return targetFile;
  }

  if (!overwriteExisting &&
      await targetFile.exists() &&
      await targetFile.length() > 0) {
    throw StateError(
      'Local Deploy Dash database already exists. '
      'Pass overwriteExisting: true to replace it.',
    );
  }

  await targetFile.parent.create(recursive: true);
  await _secureAppDatabaseStorage(targetFile);
  final tempRestoreFile = File('${targetFile.path}.restoring');
  if (await tempRestoreFile.exists()) {
    await tempRestoreFile.delete();
  }

  await sourceFile.copy(tempRestoreFile.path);

  for (final stalePath in <String>[
    targetFile.path,
    '${targetFile.path}-wal',
    '${targetFile.path}-shm',
  ]) {
    final staleFile = File(stalePath);
    if (await staleFile.exists()) {
      await staleFile.delete();
    }
  }

  await tempRestoreFile.rename(targetFile.path);
  await _secureAppDatabaseStorage(targetFile);
  return targetFile;
}

// coverage-gate: app_database_sidecar_paths
/// The database file plus every sidecar the engine may have created.
///
/// Why: chmod-on-secure and delete-on-remove must cover the same set; one
/// list builder keeps them from drifting apart. Restore's stale-sweep
/// deliberately does NOT use this (its `.restoring` file is the copy source).
List<String> _databaseSidecarPaths(File databaseFile) {
  return <String>[
    databaseFile.path,
    '${databaseFile.path}-wal',
    '${databaseFile.path}-shm',
    '${databaseFile.path}.restoring',
  ];
}

Future<void> _secureAppDatabaseStorage(File databaseFile) async {
  if (appDataDirectoryRunsOnWindows()) {
    return;
  }

  final directory = databaseFile.parent;
  if (!await directory.exists()) {
    return;
  }
  posix.chmodWithMode(directory.path, 0x1C0);

  for (final path in _databaseSidecarPaths(databaseFile)) {
    final file = File(path);
    if (await file.exists()) {
      posix.chmodWithMode(file.path, 0x180);
    }
  }
}

Future<void> _deleteDatabaseFileAndSidecars(File databaseFile) async {
  for (final stalePath in _databaseSidecarPaths(databaseFile)) {
    final staleFile = File(stalePath);
    if (await staleFile.exists()) {
      await staleFile.delete();
    }
  }
}
// end coverage-gate

/// Points the database file somewhere else, for tests. Null restores the
/// real resolver.
void debugOverrideAppDatabaseFileResolver(Future<File> Function()? resolver) {
  _databaseFileResolverOverride = resolver;
}

/// Applies the owner-only permissions the database and its sidecars get,
/// exposed for tests.
Future<void> debugSecureAppDatabaseStorage(File databaseFile) {
  return _secureAppDatabaseStorage(databaseFile);
}

/// Overrides the Windows platform check, so the Store path can be exercised
/// from any host.
void debugOverrideAppDatabaseWindowsCheck(bool Function()? check) {
  debugOverrideAppDataDirectoryWindowsCheck(check);
}

/// Overrides the environment lookups the Windows Store path depends on.
void debugOverrideWindowsStoreDatabaseEnvironment({
  String Function()? packageFamilyLoader,
  String? Function()? localAppDataLoader,
}) {
  debugOverrideWindowsStoreAppDataEnvironment(
    packageFamilyLoader: packageFamilyLoader,
    localAppDataLoader: localAppDataLoader,
  );
}

/// Restores every override in this file and clears the recorded creation
/// failure. Call from a test teardown; these are process-wide globals.
void debugResetAppDatabaseTestState() {
  _databaseFileResolverOverride = null;
  debugResetAppDataDirectoryTestState();
  _lastAppDatabasePassphraseCreationFailure = null;
}

// coverage-gate: debug_repair_missing_app_database_user_version
/// Runs the `user_version` repair, exposed for tests.
///
/// A database whose `user_version` reads 0 but whose tables match the current
/// schema had its version lost rather than never set -- stamping it prevents
/// Drift from trying to create tables that already exist.
void debugRepairMissingAppDatabaseUserVersion(sqlite.Database rawDb) {
  _repairMissingAppDatabaseUserVersion(rawDb);
}
// end coverage-gate

/// The passphrase a container starts with. Null in the app; overridden by
/// tests and by the unlock flow.
final initialDatabasePassphraseProvider = Provider<String?>((ref) => null);

/// Holds the passphrase the database is currently open with.
///
/// In memory only, for the life of the session: it is the key to everything
/// the app stores, so it is never itself persisted.
class DatabasePassphraseNotifier extends Notifier<String?> {
  @override
  String? build() {
    final initialPassphrase = ref.watch(initialDatabasePassphraseProvider);
    final normalizedPassphrase = initialPassphrase?.trim();
    if (normalizedPassphrase == null || normalizedPassphrase.isEmpty) {
      return null;
    }
    return normalizedPassphrase;
  }

  /// Sets the passphrase, treating blank as none.
  ///
  /// Setting it rebuilds [appDatabaseProvider], which opens a new connection
  /// and disposes the old one.
  void setPassphrase(String? passphrase) {
    final normalizedPassphrase = passphrase?.trim();
    state = normalizedPassphrase == null || normalizedPassphrase.isEmpty
        ? null
        : normalizedPassphrase;
  }
}

/// The current passphrase, or null while locked.
final databasePassphraseProvider =
    NotifierProvider<DatabasePassphraseNotifier, String?>(
      DatabasePassphraseNotifier.new,
    );

/// The app-wide database, reopened whenever the passphrase changes and
/// closed when the container disposes.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final passphrase = ref.watch(databasePassphraseProvider);
  final database = AppDatabase(passphrase: passphrase);
  ref.onDispose(database.close);
  return database;
});
