import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/safe_token.dart';
import '../../utils/trim_or_null.dart';
import 'app_database.dart';

/// One managed database a project owns on a server.
///
/// A local mirror of what exists remotely, not the authority: the server is.
/// Rows are written from what an engine operation actually reported, which is
/// why every one carries [lastAppliedAt].
class ProjectManagedDatabaseRecord {
  /// Records one managed database.
  const ProjectManagedDatabaseRecord({
    required this.id,
    required this.projectId,
    required this.serverId,
    this.engine = 'postgres',
    required this.databaseName,
    this.isPrimary = false,
    this.lastAppliedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Derived from the project, server, engine and database name rather than
  /// generated, so re-observing the same database updates one row instead of
  /// accumulating duplicates.
  final String id;

  /// Which project owns it.
  final String projectId;

  /// Which server it lives on.
  final String serverId;

  /// The engine. `postgres` today.
  final String engine;

  /// The database's name on the server.
  final String databaseName;

  /// Whether this is the project's main database.
  final bool isPrimary;

  /// When the server last confirmed this. What separates "we saw this" from
  /// "we once wrote this down".
  final DateTime? lastAppliedAt;

  /// When the row was first written.
  final DateTime createdAt;

  /// When it last changed.
  final DateTime updatedAt;
}

/// One managed database user, with the credentials to reach it.
class ProjectManagedDatabaseUserRecord {
  /// Records one managed user.
  const ProjectManagedDatabaseUserRecord({
    required this.id,
    required this.projectId,
    required this.serverId,
    this.engine = 'postgres',
    required this.databaseName,
    required this.username,
    this.accessMode = 'read_write',
    this.password,
    this.host,
    this.port,
    this.connectionUri,
    this.lastAppliedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Derived from the database's id plus the username, for the same reason as
  /// [ProjectManagedDatabaseRecord.id].
  final String id;

  /// Which project owns it.
  final String projectId;

  /// Which server it lives on.
  final String serverId;

  /// The engine.
  final String engine;

  /// The database this user connects to.
  final String databaseName;

  /// The role name on the server.
  final String username;

  /// `read_only` or `read_write`. Anything else becomes `read_write`, matching
  /// what the workflow will create.
  final String accessMode;

  /// The user's password, stored inside the encrypted database so the
  /// connection-details panel can show it without asking the server again.
  final String? password;

  /// The host to connect to.
  final String? host;

  /// The port to connect on.
  final int? port;

  /// The full connection URI. Also the fallback the other fields are parsed
  /// out of when the engine reports only this.
  final String? connectionUri;

  /// When the server last confirmed this user.
  final DateTime? lastAppliedAt;

  /// When the row was first written.
  final DateTime createdAt;

  /// When it last changed.
  final DateTime updatedAt;
}

/// Mirrors a project's managed databases and users locally.
///
/// Everything here is scoped by project, server and engine together. A project
/// can move between servers, and the same database name can exist on both, so
/// any narrower key would let one server's rows describe the other's.
///
/// Ids are derived from that scope rather than generated, which makes every
/// write idempotent: re-applying the same engine result updates the same row
/// instead of creating a second one.
class ProjectManagedDatabaseRepository {
  /// Creates the repository over the app database.
  const ProjectManagedDatabaseRepository(this._database);

  final AppDatabase _database;

  /// The databases in one scope, primary first, then by name.
  Future<List<ProjectManagedDatabaseRecord>> listDatabasesForScope({
    required String projectId,
    required String serverId,
    String engine = 'postgres',
  }) async {
    final scope = _normalizeScope(
      projectId: projectId,
      serverId: serverId,
      engine: engine,
    );
    if (scope == null) {
      return const [];
    }
    final rows =
        await (_database.select(_database.projectManagedDatabases)
              ..where(
                (table) =>
                    table.projectId.equals(scope.projectId) &
                    table.serverId.equals(scope.serverId) &
                    table.engine.equals(scope.engine),
              )
              ..orderBy([
                (table) => OrderingTerm.desc(table.isPrimary),
                (table) => OrderingTerm.asc(table.databaseName),
              ]))
            .get();
    return rows.map(_databaseFromRow).toList(growable: false);
  }

  /// The users in one scope, by database then username.
  Future<List<ProjectManagedDatabaseUserRecord>> listUsersForScope({
    required String projectId,
    required String serverId,
    String engine = 'postgres',
  }) async {
    final scope = _normalizeScope(
      projectId: projectId,
      serverId: serverId,
      engine: engine,
    );
    if (scope == null) {
      return const [];
    }
    final rows =
        await (_database.select(_database.projectManagedDatabaseUsers)
              ..where(
                (table) =>
                    table.projectId.equals(scope.projectId) &
                    table.serverId.equals(scope.serverId) &
                    table.engine.equals(scope.engine),
              )
              ..orderBy([
                (table) => OrderingTerm.asc(table.databaseName),
                (table) => OrderingTerm.asc(table.username),
              ]))
            .get();
    return rows.map(_userFromRow).toList(growable: false);
  }

  /// Stores one database, preserving its original creation time.
  ///
  /// A record that does not normalize -- a blank project, server or name -- is
  /// dropped rather than stored, since its derived id would collide with every
  /// other blank one.
  Future<void> upsertDatabase(ProjectManagedDatabaseRecord record) async {
    final normalized = _normalizeDatabase(record);
    if (normalized == null) {
      return;
    }
    final existing =
        await (_database.select(_database.projectManagedDatabases)
              ..where((table) => table.id.equals(normalized.id))
              ..limit(1))
            .getSingleOrNull();
    await _database
        .into(_database.projectManagedDatabases)
        .insertOnConflictUpdate(
          ProjectManagedDatabasesCompanion.insert(
            id: normalized.id,
            projectId: normalized.projectId,
            serverId: normalized.serverId,
            engine: Value(normalized.engine),
            databaseName: normalized.databaseName,
            isPrimary: Value(normalized.isPrimary),
            lastAppliedAt: Value(normalized.lastAppliedAt),
            createdAt: Value(existing?.createdAt ?? normalized.createdAt),
            updatedAt: Value(normalized.updatedAt),
          ),
        );
  }

  /// Stores one user, preserving its original creation time.
  Future<void> upsertUser(ProjectManagedDatabaseUserRecord record) async {
    final normalized = _normalizeUser(record);
    if (normalized == null) {
      return;
    }
    final existing =
        await (_database.select(_database.projectManagedDatabaseUsers)
              ..where((table) => table.id.equals(normalized.id))
              ..limit(1))
            .getSingleOrNull();
    await _database
        .into(_database.projectManagedDatabaseUsers)
        .insertOnConflictUpdate(
          ProjectManagedDatabaseUsersCompanion.insert(
            id: normalized.id,
            projectId: normalized.projectId,
            serverId: normalized.serverId,
            engine: Value(normalized.engine),
            databaseName: normalized.databaseName,
            username: normalized.username,
            accessMode: Value(normalized.accessMode),
            password: Value(normalized.password),
            host: Value(normalized.host),
            port: Value(normalized.port),
            connectionUri: Value(normalized.connectionUri),
            lastAppliedAt: Value(normalized.lastAppliedAt),
            createdAt: Value(existing?.createdAt ?? normalized.createdAt),
            updatedAt: Value(normalized.updatedAt),
          ),
        );
  }

  /// Replaces everything known about one scope, in one transaction.
  ///
  /// What a full inspection of the server writes: the server's answer is the
  /// truth, so a database or user no longer there is removed rather than left
  /// as a row the UI would still offer to connect to.
  Future<void> replaceScope({
    required String projectId,
    required String serverId,
    String engine = 'postgres',
    required List<ProjectManagedDatabaseRecord> databases,
    required List<ProjectManagedDatabaseUserRecord> users,
  }) async {
    final scope = _normalizeScope(
      projectId: projectId,
      serverId: serverId,
      engine: engine,
    );
    if (scope == null) {
      return;
    }
    final normalizedDatabases = databases
        .map(_normalizeDatabase)
        .whereType<ProjectManagedDatabaseRecord>()
        .toList(growable: false);
    final normalizedUsers = users
        .map(_normalizeUser)
        .whereType<ProjectManagedDatabaseUserRecord>()
        .toList(growable: false);
    await _database.transaction(() async {
      await (_database.delete(_database.projectManagedDatabaseUsers)..where(
            (table) =>
                table.projectId.equals(scope.projectId) &
                table.serverId.equals(scope.serverId) &
                table.engine.equals(scope.engine),
          ))
          .go();
      await (_database.delete(_database.projectManagedDatabases)..where(
            (table) =>
                table.projectId.equals(scope.projectId) &
                table.serverId.equals(scope.serverId) &
                table.engine.equals(scope.engine),
          ))
          .go();
      for (final database in normalizedDatabases) {
        await upsertDatabase(database);
      }
      for (final user in normalizedUsers) {
        await upsertUser(user);
      }
    });
  }

  /// Removes a database and its users from the local mirror.
  ///
  /// Local only, and it takes the users with it: a credential for a database
  /// that no longer exists cannot connect, so keeping it would only mislead.
  Future<void> deleteDatabase({
    required String projectId,
    required String serverId,
    String engine = 'postgres',
    required String databaseName,
  }) async {
    final scope = _normalizeScope(
      projectId: projectId,
      serverId: serverId,
      engine: engine,
    );
    final normalizedName = databaseName.trim();
    if (scope == null || normalizedName.isEmpty) {
      return;
    }
    await _database.transaction(() async {
      await (_database.delete(_database.projectManagedDatabaseUsers)..where(
            (table) =>
                table.projectId.equals(scope.projectId) &
                table.serverId.equals(scope.serverId) &
                table.engine.equals(scope.engine) &
                table.databaseName.equals(normalizedName),
          ))
          .go();
      await (_database.delete(_database.projectManagedDatabases)..where(
            (table) =>
                table.projectId.equals(scope.projectId) &
                table.serverId.equals(scope.serverId) &
                table.engine.equals(scope.engine) &
                table.databaseName.equals(normalizedName),
          ))
          .go();
    });
  }

  /// Removes one user from the local mirror.
  Future<void> deleteUser({
    required String projectId,
    required String serverId,
    String engine = 'postgres',
    required String databaseName,
    required String username,
  }) async {
    final scope = _normalizeScope(
      projectId: projectId,
      serverId: serverId,
      engine: engine,
    );
    final normalizedDatabase = databaseName.trim();
    final normalizedUsername = username.trim();
    if (scope == null ||
        normalizedDatabase.isEmpty ||
        normalizedUsername.isEmpty) {
      return;
    }
    await (_database.delete(_database.projectManagedDatabaseUsers)..where(
          (table) =>
              table.projectId.equals(scope.projectId) &
              table.serverId.equals(scope.serverId) &
              table.engine.equals(scope.engine) &
              table.databaseName.equals(normalizedDatabase) &
              table.username.equals(normalizedUsername),
        ))
        .go();
  }

  /// Updates the mirror from what a managed-database operation reported.
  ///
  /// The single place engine results become local rows, so every operation
  /// records its outcome the same way. Delete operations remove rows; anything
  /// else upserts what was observed.
  ///
  /// Fields are resolved from the result, then the request, then by parsing
  /// the connection URI -- because operations report their own outcomes
  /// unevenly, and the URI often carries the username, host, port and database
  /// when the top-level fields do not. Whatever cannot be resolved is skipped
  /// rather than guessed: a row with the wrong database name would point the
  /// user's connection details at someone else's database.
  Future<void> applyOperationResult({
    required String projectId,
    required String serverId,
    String engine = 'postgres',
    required String operationType,
    Map<String, dynamic>? request,
    required Map<String, dynamic> result,
  }) async {
    final normalizedEngine = _normalizeEngine(engine);
    // coverage-gate: journal_credential_uri
    final connectionUri = _credentialValueOrNull(result['connection_uri']);
    final parsedConnection = _parseConnectionUri(connectionUri);
    // end coverage-gate
    final databaseName =
        trimOrNull(result['database_name']?.toString()) ??
        trimOrNull(result['deleted_database_name']?.toString()) ??
        trimOrNull(result['target_database_name']?.toString()) ??
        trimOrNull(request?['database_name']?.toString()) ??
        parsedConnection.databaseName;
    final username =
        trimOrNull(result['username']?.toString()) ??
        trimOrNull(result['deleted_username']?.toString()) ??
        trimOrNull(request?['username']?.toString()) ??
        parsedConnection.username;
    final normalizedOperation = operationType.trim();
    if (normalizedOperation == 'project_delete_database') {
      if (databaseName != null) {
        await deleteDatabase(
          projectId: projectId,
          serverId: serverId,
          engine: normalizedEngine,
          databaseName: databaseName,
        );
      }
      return;
    }
    if (normalizedOperation == 'project_delete_user') {
      if (databaseName != null && username != null) {
        await deleteUser(
          projectId: projectId,
          serverId: serverId,
          engine: normalizedEngine,
          databaseName: databaseName,
          username: username,
        );
      }
      return;
    }

    final observedAt = DateTime.now();
    if (databaseName != null) {
      final database = fromBackendDatabase(
        projectId: projectId,
        serverId: serverId,
        engine: normalizedEngine,
        databaseName: databaseName,
        observedAt: observedAt,
      );
      if (database != null) {
        await upsertDatabase(database);
      }
    }
    if (databaseName != null && username != null) {
      final user = fromBackendUser(
        projectId: projectId,
        serverId: serverId,
        engine: normalizedEngine,
        databaseName: databaseName,
        username: username,
        accessMode:
            trimOrNull(result['access_mode']?.toString()) ??
            trimOrNull(request?['access_mode']?.toString()) ??
            'read_write',
        // coverage-gate: journal_credential_password
        password:
            _credentialValueOrNull(result['password']) ??
            parsedConnection.password,
        // end coverage-gate
        host: trimOrNull(result['host']?.toString()) ?? parsedConnection.host,
        port: _asInt(result['port']) ?? parsedConnection.port,
        connectionUri: connectionUri,
        observedAt: observedAt,
      );
      if (user != null) {
        await upsertUser(user);
      }
    }
  }

  /// Replays one journalled operation into the mirror.
  ///
  /// Used to catch the local mirror up on operations that completed while the
  /// app was not watching. Throws [FormatException] when the entry has no
  /// result: there is nothing to apply, and applying a partial entry would
  /// write a row describing something that may not have happened.
  Future<void> applyJournaledOperation({
    required String projectId,
    required String serverId,
    required String operationType,
    String? requestJson,
    String? resultJson,
  }) async {
    final result = _decodeJsonMap(resultJson);
    if (result == null) {
      throw const FormatException('Journal entry is missing result data.');
    }
    await applyOperationResult(
      projectId: projectId,
      serverId: serverId,
      operationType: operationType,
      request: _decodeJsonMap(requestJson),
      result: result,
    );
  }

  /// Builds a database record from what the engine reported, or null when it
  /// lacks a project, server or name.
  static ProjectManagedDatabaseRecord? fromBackendDatabase({
    required String projectId,
    required String serverId,
    String engine = 'postgres',
    required String databaseName,
    bool isPrimary = false,
    DateTime? observedAt,
  }) {
    final now = DateTime.now();
    final normalizedEngine = _normalizeEngine(engine);
    final normalizedName = databaseName.trim();
    if (projectId.trim().isEmpty ||
        serverId.trim().isEmpty ||
        normalizedName.isEmpty) {
      return null;
    }
    return ProjectManagedDatabaseRecord(
      id: _databaseId(
        projectId: projectId,
        serverId: serverId,
        engine: normalizedEngine,
        databaseName: normalizedName,
      ),
      projectId: projectId.trim(),
      serverId: serverId.trim(),
      engine: normalizedEngine,
      databaseName: normalizedName,
      isPrimary: isPrimary,
      lastAppliedAt: observedAt ?? now,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Builds a user record from what the engine reported, or null when it
  /// lacks a project, server, database or username.
  static ProjectManagedDatabaseUserRecord? fromBackendUser({
    required String projectId,
    required String serverId,
    String engine = 'postgres',
    required String databaseName,
    required String username,
    String accessMode = 'read_write',
    String? password,
    String? host,
    int? port,
    String? connectionUri,
    DateTime? observedAt,
  }) {
    final now = DateTime.now();
    final normalizedEngine = _normalizeEngine(engine);
    final normalizedDatabase = databaseName.trim();
    final normalizedUsername = username.trim();
    if (projectId.trim().isEmpty ||
        serverId.trim().isEmpty ||
        normalizedDatabase.isEmpty ||
        normalizedUsername.isEmpty) {
      return null;
    }
    return ProjectManagedDatabaseUserRecord(
      id: _userId(
        projectId: projectId,
        serverId: serverId,
        engine: normalizedEngine,
        databaseName: normalizedDatabase,
        username: normalizedUsername,
      ),
      projectId: projectId.trim(),
      serverId: serverId.trim(),
      engine: normalizedEngine,
      databaseName: normalizedDatabase,
      username: normalizedUsername,
      accessMode: _normalizeAccessMode(accessMode),
      password: trimOrNull(password),
      host: trimOrNull(host),
      port: port,
      connectionUri: trimOrNull(connectionUri),
      lastAppliedAt: observedAt ?? now,
      createdAt: now,
      updatedAt: now,
    );
  }

  static ({String projectId, String serverId, String engine})? _normalizeScope({
    required String projectId,
    required String serverId,
    required String engine,
  }) {
    final normalizedProjectId = projectId.trim();
    final normalizedServerId = serverId.trim();
    if (normalizedProjectId.isEmpty || normalizedServerId.isEmpty) {
      return null;
    }
    return (
      projectId: normalizedProjectId,
      serverId: normalizedServerId,
      engine: _normalizeEngine(engine),
    );
  }

  static ProjectManagedDatabaseRecord? _normalizeDatabase(
    ProjectManagedDatabaseRecord row,
  ) {
    return fromBackendDatabase(
      projectId: row.projectId,
      serverId: row.serverId,
      engine: row.engine,
      databaseName: row.databaseName,
      isPrimary: row.isPrimary,
      observedAt: row.lastAppliedAt ?? row.updatedAt,
    );
  }

  static ProjectManagedDatabaseUserRecord? _normalizeUser(
    ProjectManagedDatabaseUserRecord row,
  ) {
    return fromBackendUser(
      projectId: row.projectId,
      serverId: row.serverId,
      engine: row.engine,
      databaseName: row.databaseName,
      username: row.username,
      accessMode: row.accessMode,
      password: row.password,
      host: row.host,
      port: row.port,
      connectionUri: row.connectionUri,
      observedAt: row.lastAppliedAt ?? row.updatedAt,
    );
  }

  static ProjectManagedDatabaseRecord _databaseFromRow(
    ProjectManagedDatabaseRow row,
  ) {
    return ProjectManagedDatabaseRecord(
      id: row.id,
      projectId: row.projectId,
      serverId: row.serverId,
      engine: row.engine,
      databaseName: row.databaseName,
      isPrimary: row.isPrimary,
      lastAppliedAt: row.lastAppliedAt,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  static ProjectManagedDatabaseUserRecord _userFromRow(
    ProjectManagedDatabaseUserRow row,
  ) {
    return ProjectManagedDatabaseUserRecord(
      id: row.id,
      projectId: row.projectId,
      serverId: row.serverId,
      engine: row.engine,
      databaseName: row.databaseName,
      username: row.username,
      accessMode: row.accessMode,
      password: row.password,
      host: row.host,
      port: row.port,
      connectionUri: row.connectionUri,
      lastAppliedAt: row.lastAppliedAt,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  static String _normalizeEngine(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'postgres' ? 'postgres' : normalized;
  }

  static String _normalizeAccessMode(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'read_only' ? 'read_only' : 'read_write';
  }

  // D-58 (T-014): left — lets FormatException propagate (no try) where
  // backup/prefs catch it; unifying is a data-migration question (D-58).
  static Map<String, dynamic>? _decodeJsonMap(String? value) {
    final raw = trimOrNull(value);
    if (raw == null) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString().trim() ?? '');
  }

  /// Rejects sanitizer markers so replay never persists them as credentials.
  // coverage-gate: journal_credential_marker
  static String? _credentialValueOrNull(Object? value) {
    final normalized = trimOrNull(value?.toString());
    if (normalized == null ||
        normalized.contains('***') ||
        normalized.contains('[redacted]')) {
      return null;
    }
    return normalized;
  }
  // end coverage-gate

  static ({
    String? username,
    String? password,
    String? host,
    int? port,
    String? databaseName,
  })
  _parseConnectionUri(String? value) {
    final uri = Uri.tryParse(value ?? '');
    if (uri == null) {
      return (
        username: null,
        password: null,
        host: null,
        port: null,
        databaseName: null,
      );
    }
    final userInfo = uri.userInfo;
    String? username;
    String? password;
    if (userInfo.isNotEmpty) {
      final parts = userInfo.split(':');
      username = Uri.decodeComponent(parts.first);
      if (parts.length > 1) {
        password = Uri.decodeComponent(parts.sublist(1).join(':'));
      }
    }
    return (
      username: trimOrNull(username),
      password: trimOrNull(password),
      host: trimOrNull(uri.host),
      port: uri.hasPort ? uri.port : null,
      databaseName: trimOrNull(
        uri.pathSegments.isEmpty ? null : uri.pathSegments.last,
      ),
    );
  }

  static String _databaseId({
    required String projectId,
    required String serverId,
    required String engine,
    required String databaseName,
  }) {
    return 'managed-db-${safeToken(serverId)}-${safeToken(projectId)}-'
        '${safeToken(engine)}-${safeToken(databaseName)}';
  }

  static String _userId({
    required String projectId,
    required String serverId,
    required String engine,
    required String databaseName,
    required String username,
  }) {
    return '${_databaseId(projectId: projectId, serverId: serverId, engine: engine, databaseName: databaseName)}-${safeToken(username)}';
  }
}

/// The app-wide managed database repository.
final projectManagedDatabaseRepositoryProvider =
    Provider<ProjectManagedDatabaseRepository>((ref) {
      final database = ref.watch(appDatabaseProvider);
      return ProjectManagedDatabaseRepository(database);
    });
