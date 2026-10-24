import 'dart:io';

import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/services/sqlite_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../_support/sqlite_test_harness.dart';

void main() {
  final encryptedSqliteAvailable = ensureEncryptedSqliteRuntimeAvailable();

  group('SqliteBackupService encrypted SQLite integration', () {
    test('native asset exposes an encryption-capable runtime', () {
      expect(encryptedSqliteAvailable, isTrue);
    });

    test('creates encrypted snapshot from a real encrypted database', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'deploydash-sqlcipher-snapshot-',
      );
      final sourceFile = File('${tempDir.path}/source.db');
      final snapshotFile = File('${tempDir.path}/snapshot.db');
      const passphrase = 'integration-passphrase';

      try {
        final sourceDb = sqlite.sqlite3.open(sourceFile.path);
        try {
          configureAppDatabaseEncryption(sourceDb, passphrase: passphrase);
          sourceDb.execute(
            'CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);',
          );
          sourceDb.execute(
            "INSERT INTO notes (body) VALUES ('backup smoke test');",
          );
          sourceDb.execute('PRAGMA user_version = 30;');
        } finally {
          sourceDb.close();
        }

        await createConsistentEncryptedSnapshot(
          sourcePath: sourceFile.path,
          snapshotPath: snapshotFile.path,
          passphrase: passphrase,
          metadata: SqliteBackupSnapshotMetadata(
            createdAtUtc: DateTime.utc(2026, 3, 16, 12, 34, 56),
            appBuildName: '1.0.0',
            appBuildNumber: '1',
          ),
        );

        final snapshotDb = sqlite.sqlite3.open(snapshotFile.path);
        try {
          configureAppDatabaseEncryption(snapshotDb, passphrase: passphrase);
          final rows = snapshotDb.select(
            'SELECT body FROM notes ORDER BY id LIMIT 1;',
          );
          expect(rows.single['body'], 'backup smoke test');
          expect(
            snapshotDb.select('PRAGMA user_version;').single.columnAt(0),
            30,
          );
          final metadataRows = snapshotDb.select(
            'SELECT backup_format_version, source_schema_version '
            'FROM deploydash_backup_metadata LIMIT 1;',
          );
          expect(metadataRows.single['backup_format_version'], 1);
          expect(metadataRows.single['source_schema_version'], 30);
        } finally {
          snapshotDb.close();
        }
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    }, skip: !encryptedSqliteAvailable);

    test('snapshot succeeds while another connection remains open', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'deploydash-sqlcipher-live-connection-',
      );
      final sourceFile = File('${tempDir.path}/source.db');
      final snapshotFile = File('${tempDir.path}/snapshot.db');
      const passphrase = 'integration-passphrase';

      try {
        final writerDb = sqlite.sqlite3.open(sourceFile.path);
        try {
          configureAppDatabaseEncryption(writerDb, passphrase: passphrase);
          writerDb.execute('PRAGMA journal_mode = WAL;');
          writerDb.execute(
            'CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);',
          );
          writerDb.execute(
            "INSERT INTO notes (body) VALUES ('first row'), ('second row');",
          );
        } finally {
          writerDb.close();
        }

        final liveDb = sqlite.sqlite3.open(sourceFile.path);
        try {
          configureAppDatabaseEncryption(liveDb, passphrase: passphrase);
          liveDb.execute('PRAGMA journal_mode = WAL;');
          liveDb.execute('BEGIN;');
          expect(
            liveDb.select('SELECT COUNT(*) AS c FROM notes;').single['c'],
            2,
          );

          await createConsistentEncryptedSnapshot(
            sourcePath: sourceFile.path,
            snapshotPath: snapshotFile.path,
            passphrase: passphrase,
            metadata: SqliteBackupSnapshotMetadata(
              createdAtUtc: DateTime.utc(2026, 3, 16, 12, 34, 56),
              appBuildName: '1.0.0',
              appBuildNumber: '1',
            ),
          );

          final snapshotDb = sqlite.sqlite3.open(snapshotFile.path);
          try {
            configureAppDatabaseEncryption(snapshotDb, passphrase: passphrase);
            expect(
              snapshotDb.select('SELECT COUNT(*) AS c FROM notes;').single['c'],
              2,
            );
          } finally {
            snapshotDb.close();
          }
        } finally {
          try {
            liveDb.execute('ROLLBACK;');
          } catch (_) {}
          liveDb.close();
        }
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    }, skip: !encryptedSqliteAvailable);

    test(
      'old and new exports remain tied to the password active at export time',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'deploydash-sqlcipher-rotation-export-',
        );
        final localDbFile = File('${tempDir.path}/deploydash_state.db');
        final oldExportFile = File('${tempDir.path}/old-export.db');
        final newExportFile = File('${tempDir.path}/new-export.db');
        const oldPassphrase = 'old-passphrase';
        const newPassphrase = 'new-passphrase';

        try {
          debugOverrideAppDatabaseFileResolver(() async => localDbFile);

          final seededDb = sqlite.sqlite3.open(localDbFile.path);
          try {
            configureAppDatabaseEncryption(seededDb, passphrase: oldPassphrase);
            seededDb.execute(
              'CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);',
            );
            seededDb.execute(
              "INSERT INTO notes (body) VALUES ('rotation export test');",
            );
          } finally {
            seededDb.close();
          }

          final liveDatabase = AppDatabase(passphrase: oldPassphrase);
          final noopPrefs = _NoopAppPreferencesRepository();

          try {
            final oldExportService = SqliteBackupService(
              databasePassphrase: oldPassphrase,
              preferencesRepository: noopPrefs,
              sourceFileResolver: () async => localDbFile,
            );
            await oldExportService.exportNow(
              destinationPath: oldExportFile.path,
            );

            await rotateAppDatabasePassphrase(
              database: liveDatabase,
              currentPassphrase: oldPassphrase,
              newPassphrase: newPassphrase,
            );

            final newExportService = SqliteBackupService(
              databasePassphrase: newPassphrase,
              preferencesRepository: noopPrefs,
              sourceFileResolver: () async => localDbFile,
            );
            await newExportService.exportNow(
              destinationPath: newExportFile.path,
            );
          } finally {
            await liveDatabase.close();
          }

          expect(_canUnlock(oldExportFile.path, oldPassphrase), isTrue);
          expect(_canUnlock(oldExportFile.path, newPassphrase), isFalse);
          expect(_canUnlock(newExportFile.path, oldPassphrase), isFalse);
          expect(_canUnlock(newExportFile.path, newPassphrase), isTrue);

          await restoreAppDatabaseFromBackupFile(
            sourcePath: oldExportFile.path,
            overwriteExisting: true,
          );
          expect(await validateAppDatabasePassphrase(oldPassphrase), isTrue);
          expect(await validateAppDatabasePassphrase(newPassphrase), isFalse);
        } finally {
          debugResetAppDatabaseTestState();
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        }
      },
      skip: !encryptedSqliteAvailable,
    );
  });
}

bool _canUnlock(String path, String passphrase) {
  final db = sqlite.sqlite3.open(path);
  try {
    configureAppDatabaseEncryption(db, passphrase: passphrase);
    db.select('SELECT COUNT(*) AS c FROM sqlite_master;');
    return true;
  } catch (_) {
    return false;
  } finally {
    db.close();
  }
}

class _NoopAppPreferencesRepository implements AppPreferencesRepository {
  @override
  Future<AppPreferencesRecord> read() async {
    return AppPreferencesRecord(
      terminalDebugView: false,
      themeMode: 'system',
      gitHubPendingOauthState: null,
      sqliteBackupS3Config: null,
      agentAccessEnabled: false,
      agentAccessPermissionMode: agentAccessPermissionReadOnly,
      agentSessionToken: null,
      agentSessionExpiresAt: null,
      updatedAt: DateTime.utc(2026, 1, 1),
    );
  }

  @override
  Future<void> recordSqliteBackupRun({
    required String status,
    String? message,
    DateTime? runAt,
  }) async {}

  @override
  Future<void> setGitHubPendingOauthState(String? oauthState) async {}

  @override
  Future<void> setSqliteBackupS3Config(Map<String, dynamic>? config) async {}

  @override
  Future<void> setTerminalDebugView(bool enabled) async {}

  @override
  Future<void> setThemeMode(String mode) async {}

  @override
  Future<void> setAgentAccessEnabled(bool enabled) async {}

  @override
  Future<void> setAgentAccessPermissionMode(String mode) async {}

  @override
  Future<void> issueAgentSession({
    required String token,
    required DateTime expiresAt,
  }) async {}

  @override
  Future<void> clearAgentSession() async {}

  @override
  Future<void> recordAnalyticsMilestone(
    AppUserAttribute attribute, {
    DateTime? reachedAt,
  }) async {}

  @override
  Future<void> setTelemetryEnabled({required bool enabled}) async {}

  @override
  Future<void> markTelemetryNoticeShown() async {}

  @override
  Future<void> markTelemetryNagShown() async {}
}
