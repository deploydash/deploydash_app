import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/trim_or_null.dart';
import 'app_database.dart';
import 'project_network_trust_repository.dart';
import 'project_sqlite_database_repository.dart';
import 'sqlite_validation.dart';

/// A read-only copy of one project's SQLite database, published to another
/// project on the same server.
///
/// SQLite has no server to grant access through, so sharing means copying: the
/// owner's file is published into a separate volume that the consumer mounts.
/// The consumer therefore reads a *snapshot*, not the live database -- it sees
/// data as of the last publish, and cannot write back.
class ProjectSqliteSnapshotExportRecord {
  /// Records one publication.
  const ProjectSqliteSnapshotExportRecord({
    required this.id,
    required this.sourceSqliteDatabaseId,
    required this.ownerProjectId,
    required this.consumerProjectId,
    required this.trustGroupId,
    required this.snapshotVolumeName,
    required this.mountPath,
    required this.fileName,
    this.pathEnvKey,
    this.databaseUrlEnvKey,
    this.status = 'active',
    this.sourceUpdatedAt,
    this.lastPublishedAt,
  });

  /// Derived from the source database and the consumer, so publishing the
  /// same pair twice updates one record rather than making a second volume.
  final String id;

  /// The owner's SQLite database being published.
  final String sourceSqliteDatabaseId;

  /// The project that owns the data.
  final String ownerProjectId;

  /// The project allowed to read it.
  final String consumerProjectId;

  /// The trust group that authorises this. Publication follows linkage; it is
  /// not a second, independent grant.
  final String trustGroupId;

  /// The Docker volume the snapshot is copied into.
  final String snapshotVolumeName;

  /// Where the consumer's container mounts it.
  final String mountPath;

  /// The database filename inside that mount.
  final String fileName;

  /// The environment variable holding the file path, defaulted from the
  /// database's name when the caller does not choose one.
  final String? pathEnvKey;

  /// The environment variable holding the `sqlite://` URL.
  final String? databaseUrlEnvKey;

  /// `active` while the publication should be mounted.
  final String status;

  /// When the source was last observed to change.
  final DateTime? sourceUpdatedAt;

  /// When the snapshot was last actually copied. Null means configured but
  /// never published, and comparing it with [sourceUpdatedAt] is what says how
  /// stale the consumer's copy is.
  final DateTime? lastPublishedAt;

  /// The database's absolute path inside the consumer's container.
  String get databasePath => '$mountPath/$fileName';

  /// That path as a `sqlite://` URL, for libraries that take one.
  String get databaseUrl => 'sqlite:///$databasePath';
}

/// Stores which SQLite snapshots are published to which projects.
///
/// Every generated name -- volume, mount path, environment variable -- is
/// derived here from the source database and the consumer, so the desktop app
/// and the server agree on them without a second record to keep in sync, and
/// so none of them can carry a character that would be unsafe in a Docker
/// command.
class ProjectSqliteSnapshotRepository {
  /// Creates the repository over the app database.
  const ProjectSqliteSnapshotRepository(this._database);

  final AppDatabase _database;

  /// Every snapshot published *to* a project, by mount path.
  Future<List<ProjectSqliteSnapshotExportRecord>> listForConsumerProject(
    String projectId,
  ) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return const <ProjectSqliteSnapshotExportRecord>[];
    }
    final rows =
        await (_database.select(_database.projectSqliteSnapshotExports)
              ..where(
                (table) => table.consumerProjectId.equals(normalizedProjectId),
              )
              ..orderBy([(table) => OrderingTerm.asc(table.mountPath)]))
            .get();
    return rows.map(_mapRow).toList(growable: false);
  }

  /// Every publication *of* one source database, by consumer.
  Future<List<ProjectSqliteSnapshotExportRecord>> listForSource(
    String sqliteDatabaseId,
  ) async {
    final normalizedId = sqliteDatabaseId.trim();
    if (normalizedId.isEmpty) {
      return const <ProjectSqliteSnapshotExportRecord>[];
    }
    final rows =
        await (_database.select(_database.projectSqliteSnapshotExports)
              ..where(
                (table) => table.sourceSqliteDatabaseId.equals(normalizedId),
              )
              ..orderBy([(table) => OrderingTerm.asc(table.consumerProjectId)]))
            .get();
    return rows.map(_mapRow).toList(growable: false);
  }

  /// The mount descriptors a consumer's deploy should send.
  ///
  /// Only `active` publications are included, so revoking a share stops it
  /// being mounted on the next deploy. Environment keys are omitted when
  /// blank rather than sent empty.
  Future<List<Map<String, dynamic>>> buildSnapshotMountPayloadsForConsumer(
    String projectId,
  ) async {
    final records = await listForConsumerProject(projectId);
    return records
        .where((record) => record.status == 'active')
        .map(
          (record) => <String, dynamic>{
            'volume_name': record.snapshotVolumeName,
            'mount_path': record.mountPath,
            'file_name': record.fileName,
            if (_isPresent(record.pathEnvKey))
              'path_env_key': record.pathEnvKey,
            if (_isPresent(record.databaseUrlEnvKey))
              'database_url_env_key': record.databaseUrlEnvKey,
          },
        )
        .toList(growable: false);
  }

  /// Creates or updates the publication of one database to one consumer.
  ///
  /// Every name is regenerated from the source and consumer, so re-publishing
  /// cannot drift onto a second volume and leave the first one mounted.
  /// [ProjectSqliteSnapshotExportRecord.lastPublishedAt] is carried over from
  /// any existing record: reconfiguring a share does not make an already-copied
  /// snapshot look uncopied.
  ///
  /// Throws [ArgumentError] when the consumer is the owner -- a project already
  /// has its own database, and a snapshot of itself would shadow the live one
  /// with a stale copy.
  Future<ProjectSqliteSnapshotExportRecord> upsertPublication({
    required ProjectSqliteDatabase sourceDatabase,
    required String consumerProjectId,
    required String trustGroupId,
    String? pathEnvKey,
    String? databaseUrlEnvKey,
  }) async {
    final normalizedSource = _normalizeSqliteSource(sourceDatabase);
    final normalizedConsumerProjectId = requiredSqliteField(
      consumerProjectId,
      'consumerProjectId',
    );
    final normalizedTrustGroupId = requiredSqliteField(
      trustGroupId,
      'trustGroupId',
    );
    if (normalizedSource.projectId == normalizedConsumerProjectId) {
      throw ArgumentError.value(
        consumerProjectId,
        'consumerProjectId',
        'SQLite snapshots are only needed for a different linked project.',
      );
    }

    final normalizedPathEnvKey =
        trimOrNull(pathEnvKey) ??
        _defaultEnvKey(normalizedSource.name, suffix: 'PATH');
    final normalizedDatabaseUrlEnvKey =
        trimOrNull(databaseUrlEnvKey) ??
        _defaultEnvKey(normalizedSource.name, suffix: 'DATABASE_URL');
    final id = dockerSafeToken(
      'sqlite-snapshot-${normalizedSource.id}-$normalizedConsumerProjectId',
      maxLength: 72,
      emptyFallback: 'sqlite',
    );
    final now = DateTime.now();
    final existing =
        await (_database.select(_database.projectSqliteSnapshotExports)
              ..where((table) => table.id.equals(id))
              ..limit(1))
            .getSingleOrNull();
    final record = ProjectSqliteSnapshotExportRecord(
      id: id,
      sourceSqliteDatabaseId: normalizedSource.id,
      ownerProjectId: normalizedSource.projectId,
      consumerProjectId: normalizedConsumerProjectId,
      trustGroupId: normalizedTrustGroupId,
      snapshotVolumeName: _defaultSnapshotVolumeName(
        sourceSqliteDatabaseId: normalizedSource.id,
        consumerProjectId: normalizedConsumerProjectId,
      ),
      mountPath: _defaultSnapshotMountPath(normalizedSource.name),
      fileName: normalizedSource.fileName,
      pathEnvKey: normalizedPathEnvKey,
      databaseUrlEnvKey: normalizedDatabaseUrlEnvKey,
      sourceUpdatedAt: normalizedSource.lastCheckedAt,
      lastPublishedAt: existing?.lastPublishedAt,
    );

    await _database
        .into(_database.projectSqliteSnapshotExports)
        .insertOnConflictUpdate(
          ProjectSqliteSnapshotExportsCompanion.insert(
            id: record.id,
            sourceSqliteDatabaseId: record.sourceSqliteDatabaseId,
            ownerProjectId: record.ownerProjectId,
            consumerProjectId: record.consumerProjectId,
            trustGroupId: record.trustGroupId,
            snapshotVolumeName: record.snapshotVolumeName,
            mountPath: record.mountPath,
            fileName: record.fileName,
            pathEnvKey: Value(record.pathEnvKey),
            databaseUrlEnvKey: Value(record.databaseUrlEnvKey),
            status: Value(record.status),
            sourceUpdatedAt: Value(record.sourceUpdatedAt),
            lastPublishedAt: Value(record.lastPublishedAt),
            createdAt: Value(existing?.createdAt ?? now),
            updatedAt: Value(now),
          ),
        );
    return record;
  }

  /// Records that the snapshot was copied, and marks the publication active.
  Future<void> markPublished({
    required String snapshotExportId,
    DateTime? publishedAt,
  }) async {
    final normalizedId = snapshotExportId.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    final now = DateTime.now();
    await (_database.update(
      _database.projectSqliteSnapshotExports,
    )..where((table) => table.id.equals(normalizedId))).write(
      ProjectSqliteSnapshotExportsCompanion(
        lastPublishedAt: Value(publishedAt ?? now),
        status: const Value('active'),
        updatedAt: Value(now),
      ),
    );
  }

  /// Removes every snapshot published to a project. Part of deleting the
  /// consumer.
  Future<void> deleteForConsumerProject(String projectId) => _deleteWhere(
    projectId,
    (table, id) => table.consumerProjectId.equals(id),
  );

  /// Removes every snapshot published by a project. Part of deleting the
  /// owner -- without it, consumers would keep mounting a snapshot of a
  /// project that no longer exists.
  Future<void> deleteForOwnerProject(String projectId) =>
      _deleteWhere(projectId, (table, id) => table.ownerProjectId.equals(id));

  /// Removes every publication of one source database.
  Future<void> deleteForSource(String sqliteDatabaseId) => _deleteWhere(
    sqliteDatabaseId,
    (table, id) => table.sourceSqliteDatabaseId.equals(id),
  );

  /// Deletes the snapshot exports matching [predicate] for one trimmed id.
  ///
  /// Why one owner taking the predicate: the three deletes share the
  /// trim-guard + delete-go and differ only in the where clause; the predicate
  /// receives the trimmed id so the guard cannot drift apart per call site.
  /// The table type is Drift's generated `$ProjectSqliteSnapshotExportsTable`
  /// (via `app_database.dart`), matching the live `where` call shape.
  Future<void> _deleteWhere(
    String rawId,
    Expression<bool> Function(
      $ProjectSqliteSnapshotExportsTable table,
      String id,
    )
    predicate,
  ) async {
    final normalizedId = rawId.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    await (_database.delete(
      _database.projectSqliteSnapshotExports,
    )..where((table) => predicate(table, normalizedId))).go();
  }

  ProjectSqliteSnapshotExportRecord _mapRow(
    ProjectSqliteSnapshotExportRow row,
  ) {
    return ProjectSqliteSnapshotExportRecord(
      id: row.id,
      sourceSqliteDatabaseId: row.sourceSqliteDatabaseId,
      ownerProjectId: row.ownerProjectId,
      consumerProjectId: row.consumerProjectId,
      trustGroupId: row.trustGroupId,
      snapshotVolumeName: row.snapshotVolumeName,
      mountPath: row.mountPath,
      fileName: row.fileName,
      pathEnvKey: trimOrNull(row.pathEnvKey),
      databaseUrlEnvKey: trimOrNull(row.databaseUrlEnvKey),
      status: row.status,
      sourceUpdatedAt: row.sourceUpdatedAt,
      lastPublishedAt: row.lastPublishedAt,
    );
  }

  static ProjectSqliteDatabase _normalizeSqliteSource(
    ProjectSqliteDatabase input,
  ) {
    return ProjectSqliteDatabase(
      id: requiredSqliteField(input.id, 'sourceDatabase.id'),
      projectId: requiredSqliteField(
        input.projectId,
        'sourceDatabase.projectId',
      ),
      // Lenient contract: no 64-char cap, pass-through mount path (D-6).
      name: requiredSqliteName(
        input.name,
        'sourceDatabase.name',
        patternMessage: 'must be a SQLite name',
      ),
      volumeName: requiredDockerName(
        input.volumeName,
        'sourceDatabase.volumeName',
        patternMessage: 'must be a Docker name',
      ),
      mountPath: requiredMountPath(
        input.mountPath,
        'sourceDatabase.mountPath',
        normalize: false,
        absoluteMessage: 'must be absolute',
        dotSegmentMessage: 'must not contain . or ..',
      ),
      fileName: requiredFileName(
        input.fileName,
        'sourceDatabase.fileName',
        patternMessage: 'must be a filename',
      ),
      isPrimary: input.isPrimary,
      volumeExists: input.volumeExists,
      volumeMountpoint: trimOrNull(input.volumeMountpoint),
      volumeSizeBytes: input.volumeSizeBytes,
      lastCheckedAt: input.lastCheckedAt,
    );
  }

  static String _defaultSnapshotVolumeName({
    required String sourceSqliteDatabaseId,
    required String consumerProjectId,
  }) {
    return 'deploydash_sqlite_snapshot_${dockerSafeToken('$sourceSqliteDatabaseId-$consumerProjectId', maxLength: 80, emptyFallback: 'sqlite')}';
  }

  static String _defaultSnapshotMountPath(String sqliteName) {
    final token = dockerSafeToken(
      sqliteName,
      maxLength: 40,
      emptyFallback: 'sqlite',
    );
    return '/var/lib/deploydash/sqlite-snapshots/$token';
  }

  /// Why a local slug rather than the shared token owner (D-6 decision):
  /// UPPER_SNAKE with `_` joins is a different contract from the lowercase
  /// `-` scrub, and this is the only UPPER_SNAKE site -- no sibling owner
  /// exists to share.
  static String _defaultEnvKey(String sqliteName, {required String suffix}) {
    final token = sqliteName
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final safeToken = token.isEmpty ? 'SQLITE' : token;
    return 'DEPLOYDASH_SQLITE_${safeToken}_$suffix';
  }

  static bool _isPresent(String? value) =>
      value != null && value.trim().isNotEmpty;
}

/// The app-wide SQLite snapshot repository.
final projectSqliteSnapshotRepositoryProvider =
    Provider<ProjectSqliteSnapshotRepository>((ref) {
      final database = ref.watch(appDatabaseProvider);
      return ProjectSqliteSnapshotRepository(database);
    });
