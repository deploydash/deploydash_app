import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/project_sqlite_database.dart';
import '../../utils/trim_or_null.dart';
import 'app_database.dart';
import 'sqlite_validation.dart';

export '../../domain/project_sqlite_database.dart';

/// Stores which SQLite databases a project has, and which one is primary.
///
/// A project's SQLite databases live in Docker volumes on its server; these
/// rows are the desktop app's record of them. Exactly one is primary, and this
/// repository is what keeps that true -- see [upsert] and [delete].
///
/// Every name, volume, mount path and filename is validated before it is
/// written, because all four end up in shell and Docker commands on a
/// customer's machine.
class ProjectSqliteDatabaseRepository {
  /// Creates the repository over the app database.
  const ProjectSqliteDatabaseRepository(this._database);

  final AppDatabase _database;

  /// Every SQLite database for a project, primary first, then by name.
  Future<List<ProjectSqliteDatabase>> listForProject(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return const <ProjectSqliteDatabase>[];
    }

    final rows =
        await (_database.select(_database.projectSqliteDatabases)
              ..where((table) => table.projectId.equals(normalizedProjectId))
              ..orderBy([
                (table) => OrderingTerm.desc(table.isPrimary),
                (table) => OrderingTerm.asc(table.name),
              ]))
            .get();

    return rows.map(_mapRow).toList(growable: false);
  }

  /// The project's primary database, or null when it has none.
  Future<ProjectSqliteDatabase?> readPrimaryForProject(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return null;
    }
    final row =
        await (_database.select(_database.projectSqliteDatabases)
              ..where((table) => table.projectId.equals(normalizedProjectId))
              ..where((table) => table.isPrimary.equals(true))
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }

  /// Inserts or updates a database, keeping exactly one primary.
  ///
  /// In one transaction: marking this one primary demotes the others first,
  /// and saving a non-primary one promotes it anyway if the project would
  /// otherwise be left with no primary at all.
  ///
  /// Throws [ArgumentError] naming the field when a value would not be safe to
  /// use as a Docker volume name, a mount path, or a filename.
  Future<void> upsert(ProjectSqliteDatabase record) async {
    final normalized = _normalizeRecord(record);
    final now = DateTime.now();

    await _database.transaction(() async {
      if (normalized.isPrimary) {
        await (_database.update(_database.projectSqliteDatabases)
              ..where((table) => table.projectId.equals(normalized.projectId)))
            .write(
              const ProjectSqliteDatabasesCompanion(isPrimary: Value(false)),
            );
      }

      await _database
          .into(_database.projectSqliteDatabases)
          .insertOnConflictUpdate(
            ProjectSqliteDatabasesCompanion.insert(
              id: normalized.id,
              projectId: normalized.projectId,
              name: normalized.name,
              volumeName: normalized.volumeName,
              mountPath: normalized.mountPath,
              fileName: normalized.fileName,
              isPrimary: Value(normalized.isPrimary),
              volumeExists: Value(normalized.volumeExists),
              volumeMountpoint: Value(normalized.volumeMountpoint),
              volumeSizeBytes: Value(normalized.volumeSizeBytes),
              lastCheckedAt: Value(normalized.lastCheckedAt),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );

      if (!normalized.isPrimary) {
        final existingPrimary =
            await (_database.select(_database.projectSqliteDatabases)
                  ..where(
                    (table) => table.projectId.equals(normalized.projectId),
                  )
                  ..where((table) => table.isPrimary.equals(true))
                  ..limit(1))
                .getSingleOrNull();
        if (existingPrimary == null) {
          await (_database.update(
            _database.projectSqliteDatabases,
          )..where((table) => table.id.equals(normalized.id))).write(
            ProjectSqliteDatabasesCompanion(
              isPrimary: const Value(true),
              updatedAt: Value(now),
            ),
          );
        }
      }
    });
  }

  /// Makes one database the project's primary, demoting the rest, in one
  /// transaction.
  Future<void> setPrimary({
    required String projectId,
    required String sqliteDatabaseId,
  }) async {
    final ids = _normalizedIds(projectId, sqliteDatabaseId);
    if (ids == null) {
      return;
    }

    final now = DateTime.now();
    await _database.transaction(() async {
      await (_database.update(
        _database.projectSqliteDatabases,
      )..where((table) => table.projectId.equals(ids.$1))).write(
        ProjectSqliteDatabasesCompanion(
          isPrimary: const Value(false),
          updatedAt: Value(now),
        ),
      );

      await (_database.update(_database.projectSqliteDatabases)
            ..where((table) => table.id.equals(ids.$2))
            ..where((table) => table.projectId.equals(ids.$1)))
          .write(
            ProjectSqliteDatabasesCompanion(
              isPrimary: const Value(true),
              updatedAt: Value(now),
            ),
          );
    });
  }

  /// Records what was observed about the database's volume on the server.
  ///
  /// Separate from [upsert] because these are *observations*, not
  /// configuration: they change when the server is inspected, not when the
  /// user edits anything.
  Future<void> updateRuntimeMetadata({
    required String projectId,
    required String sqliteDatabaseId,
    bool? volumeExists,
    String? volumeMountpoint,
    int? volumeSizeBytes,
    DateTime? checkedAt,
  }) async {
    final ids = _normalizedIds(projectId, sqliteDatabaseId);
    if (ids == null) {
      return;
    }

    await (_database.update(_database.projectSqliteDatabases)..where((table) {
          return table.projectId.equals(ids.$1) & table.id.equals(ids.$2);
        }))
        .write(
          ProjectSqliteDatabasesCompanion(
            volumeExists: Value(volumeExists),
            volumeMountpoint: Value(trimOrNull(volumeMountpoint)),
            volumeSizeBytes: Value(volumeSizeBytes),
            lastCheckedAt: Value(checkedAt ?? DateTime.now()),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  /// Removes a database and its snapshot exports, then repairs the primary.
  ///
  /// All in one transaction. Deleting the primary promotes the
  /// alphabetically first survivor, so a project never ends up with databases
  /// but no primary -- a state the workspace has no way to display.
  Future<void> delete({
    required String projectId,
    required String sqliteDatabaseId,
  }) async {
    final ids = _normalizedIds(projectId, sqliteDatabaseId);
    if (ids == null) {
      return;
    }

    final now = DateTime.now();
    await _database.transaction(() async {
      await (_database.delete(_database.projectSqliteSnapshotExports)..where(
            (table) =>
                table.ownerProjectId.equals(ids.$1) &
                table.sourceSqliteDatabaseId.equals(ids.$2),
          ))
          .go();
      await (_database.delete(_database.projectSqliteDatabases)..where((table) {
            return table.projectId.equals(ids.$1) & table.id.equals(ids.$2);
          }))
          .go();

      final primaryExists =
          await (_database.select(_database.projectSqliteDatabases)
                ..where((table) => table.projectId.equals(ids.$1))
                ..where((table) => table.isPrimary.equals(true))
                ..limit(1))
              .getSingleOrNull();
      if (primaryExists != null) {
        return;
      }

      final fallback =
          await (_database.select(_database.projectSqliteDatabases)
                ..where((table) => table.projectId.equals(ids.$1))
                ..orderBy([(table) => OrderingTerm.asc(table.name)])
                ..limit(1))
              .getSingleOrNull();
      if (fallback == null) {
        return;
      }
      await (_database.update(
        _database.projectSqliteDatabases,
      )..where((table) => table.id.equals(fallback.id))).write(
        ProjectSqliteDatabasesCompanion(
          isPrimary: const Value(true),
          updatedAt: Value(now),
        ),
      );
    });
  }

  ProjectSqliteDatabase _normalizeRecord(ProjectSqliteDatabase input) {
    final id = _requiredString(input.id, 'id');
    final projectId = _requiredString(input.projectId, 'projectId');
    // Strict contract: 64-char cap, normalizing mount path (D-6).
    final name = requiredSqliteName(
      input.name,
      'name',
      patternMessage:
          'must start with alphanumeric and use letters, numbers, spaces, '
          '_, -, .',
      lengthCap: (max: 64, message: 'must be 64 characters or fewer'),
    );
    final volumeName = requiredDockerName(
      input.volumeName,
      'volumeName',
      patternMessage: 'must be a valid Docker volume name',
    );
    final mountPath = requiredMountPath(
      input.mountPath,
      'mountPath',
      normalize: true,
      absoluteMessage: 'must be an absolute path',
      dotSegmentMessage: 'must not include . or .. segments',
      emptySegmentsMessage: 'must include path segments',
    );
    final fileName = requiredFileName(
      input.fileName,
      'fileName',
      patternMessage: 'must contain only letters, numbers, _, -, .',
      slashMessage: 'must be a plain filename without /, . or ..',
    );
    return ProjectSqliteDatabase(
      id: id,
      projectId: projectId,
      name: name,
      volumeName: volumeName,
      mountPath: mountPath,
      fileName: fileName,
      isPrimary: input.isPrimary,
      volumeExists: input.volumeExists,
      volumeMountpoint: trimOrNull(input.volumeMountpoint),
      volumeSizeBytes: input.volumeSizeBytes,
      lastCheckedAt: input.lastCheckedAt,
    );
  }

  ProjectSqliteDatabase _mapRow(ProjectSqliteDatabaseRow row) {
    return ProjectSqliteDatabase(
      id: row.id,
      projectId: row.projectId,
      name: row.name,
      volumeName: row.volumeName,
      mountPath: row.mountPath,
      fileName: row.fileName,
      isPrimary: row.isPrimary,
      volumeExists: row.volumeExists,
      volumeMountpoint: trimOrNull(row.volumeMountpoint),
      volumeSizeBytes: row.volumeSizeBytes,
      lastCheckedAt: row.lastCheckedAt,
    );
  }

  /// Why a delegate over the shared owner (D-6): this name stays pinned in
  /// the one-owner guard (`_requiredString`, desktop-update context), so the
  /// database side keeps the spelling while the shared
  /// `requiredSqliteField` owns the body. Brace-bodied: the guard only
  /// observes `{` bodies, and an arrow would drop this source from the pin.
  static String _requiredString(String value, String fieldName) {
    return requiredSqliteField(value, fieldName);
  }

  /// The trimmed (projectId, sqliteDatabaseId) pair, or null when either is blank.
  ///
  /// Why a private pair-or-null instead of two trimOrNull calls: the three
  /// callers share the trim-two-then-guard preamble byte-identically (D-87),
  /// and the guard reads both empties together.
  static (String, String)? _normalizedIds(
    String projectId,
    String sqliteDatabaseId,
  ) {
    final normalizedProjectId = projectId.trim();
    final normalizedId = sqliteDatabaseId.trim();
    if (normalizedProjectId.isEmpty || normalizedId.isEmpty) {
      return null;
    }
    return (normalizedProjectId, normalizedId);
  }
}

/// The app-wide SQLite database repository.
final projectSqliteDatabaseRepositoryProvider =
    Provider<ProjectSqliteDatabaseRepository>((ref) {
      final database = ref.watch(appDatabaseProvider);
      return ProjectSqliteDatabaseRepository(database);
    });
