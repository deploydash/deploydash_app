import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:posix/posix.dart' as posix;

import '_support/app_database_harness.dart';

/// restored backup compatibility.
///
/// One of six files T-3.6.2 split `app_database_test.dart` into, one per
/// group. Fixtures live in `_support/app_database_harness.dart`.
void main() {
  final encryptedSqliteAvailable = ensureEncryptedSqliteRuntimeAvailable();

  group('restored backup compatibility', () {
    test('repairs missing user_version for current restored schema', () {
      final rawDb = sqlite.sqlite3.openInMemory();
      try {
        rawDb.execute(
          'CREATE TABLE onboarding_state_entries '
          '(id INTEGER PRIMARY KEY, is_completed INTEGER DEFAULT 0);',
        );
        rawDb.execute(
          'CREATE TABLE app_preferences '
          '(id INTEGER PRIMARY KEY, updated_at TEXT);',
        );
        rawDb.execute(
          'CREATE TABLE projects '
          '(id TEXT PRIMARY KEY, domain_routing_mode TEXT);',
        );
        rawDb.execute(
          'CREATE TABLE server_credentials '
          '(server_id TEXT PRIMARY KEY, private_key TEXT);',
        );
        rawDb.execute('INSERT INTO onboarding_state_entries (id) VALUES (1);');

        expect(rawDb.select('PRAGMA user_version;').single.columnAt(0), 0);

        debugRepairMissingAppDatabaseUserVersion(rawDb);

        expect(rawDb.select('PRAGMA user_version;').single.columnAt(0), 2);
      } finally {
        rawDb.close();
      }
    });

    test('does not repair a schema missing the credential table', () {
      final rawDb = sqlite.sqlite3.openInMemory();
      try {
        rawDb.execute(
          'CREATE TABLE onboarding_state_entries '
          '(id INTEGER PRIMARY KEY, is_completed INTEGER DEFAULT 0);',
        );
        rawDb.execute(
          'CREATE TABLE app_preferences '
          '(id INTEGER PRIMARY KEY, updated_at TEXT);',
        );
        rawDb.execute(
          'CREATE TABLE projects '
          '(id TEXT PRIMARY KEY, domain_routing_mode TEXT);',
        );

        debugRepairMissingAppDatabaseUserVersion(rawDb);

        expect(rawDb.select('PRAGMA user_version;').single.columnAt(0), 0);
      } finally {
        rawDb.close();
      }
    });

    test('does not repair empty databases with missing user_version', () {
      final rawDb = sqlite.sqlite3.openInMemory();
      try {
        expect(rawDb.select('PRAGMA user_version;').single.columnAt(0), 0);

        debugRepairMissingAppDatabaseUserVersion(rawDb);

        expect(rawDb.select('PRAGMA user_version;').single.columnAt(0), 0);
      } finally {
        rawDb.close();
      }
    });

    test(
      'restoreAppDatabaseFromBackupFile replaces target database and sidecars',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-restore-',
        );
        addTearDown(() async {
          if (await tempDirectory.exists()) {
            await tempDirectory.delete(recursive: true);
          }
        });

        final sourceFile = File('${tempDirectory.path}/backup.db')
          ..writeAsStringSync('restored backup bytes');
        final targetFile = File('${tempDirectory.path}/deploydash_state.db')
          ..writeAsStringSync('stale local db');
        File('${targetFile.path}-wal').writeAsStringSync('stale wal');
        File('${targetFile.path}-shm').writeAsStringSync('stale shm');
        if (!Platform.isWindows) {
          posix.chmodWithMode(tempDirectory.path, 0x1ED);
          posix.chmodWithMode(sourceFile.path, 0x1A4);
        }

        debugOverrideAppDatabaseFileResolver(() async => targetFile);
        addTearDown(() => debugOverrideAppDatabaseFileResolver(null));

        final restoredFile = await restoreAppDatabaseFromBackupFile(
          sourcePath: sourceFile.path,
          overwriteExisting: true,
        );

        expect(restoredFile.path, targetFile.path);
        expect(await restoredFile.readAsString(), 'restored backup bytes');
        expect(await File('${targetFile.path}-wal').exists(), isFalse);
        expect(await File('${targetFile.path}-shm').exists(), isFalse);
        if (!Platform.isWindows) {
          expect((await tempDirectory.stat()).mode & 0x1FF, 0x1C0);
          expect((await restoredFile.stat()).mode & 0x1FF, 0x180);
        }
      },
    );

    test(
      'restoreAppDatabaseFromBackupFile rejects empty backup files',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-restore-empty-',
        );
        addTearDown(() async {
          if (await tempDirectory.exists()) {
            await tempDirectory.delete(recursive: true);
          }
        });

        final sourceFile = File('${tempDirectory.path}/backup.db')
          ..writeAsBytesSync(<int>[]);
        final targetFile = File('${tempDirectory.path}/deploydash_state.db');

        debugOverrideAppDatabaseFileResolver(() async => targetFile);
        addTearDown(() => debugOverrideAppDatabaseFileResolver(null));

        await expectLater(
          () => restoreAppDatabaseFromBackupFile(sourcePath: sourceFile.path),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'restoreAppDatabaseFromBackupFile rejects missing backup files',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-restore-missing-',
        );
        addTearDown(() async {
          if (await tempDirectory.exists()) {
            await tempDirectory.delete(recursive: true);
          }
        });

        final missingSourcePath = '${tempDirectory.path}/missing.db';
        final targetFile = File('${tempDirectory.path}/deploydash_state.db');

        debugOverrideAppDatabaseFileResolver(() async => targetFile);
        addTearDown(() => debugOverrideAppDatabaseFileResolver(null));

        await expectLater(
          () => restoreAppDatabaseFromBackupFile(sourcePath: missingSourcePath),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('does not exist'),
            ),
          ),
        );
      },
    );

    test(
      'restoreAppDatabaseFromBackupFile rejects overwrite when local db exists',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-restore-overwrite-',
        );
        addTearDown(() async {
          if (await tempDirectory.exists()) {
            await tempDirectory.delete(recursive: true);
          }
        });

        final sourceFile = File('${tempDirectory.path}/backup.db')
          ..writeAsStringSync('restored backup bytes');
        final targetFile = File('${tempDirectory.path}/deploydash_state.db')
          ..writeAsStringSync('existing local db');

        debugOverrideAppDatabaseFileResolver(() async => targetFile);
        addTearDown(() => debugOverrideAppDatabaseFileResolver(null));

        await expectLater(
          () => restoreAppDatabaseFromBackupFile(sourcePath: sourceFile.path),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('already exists'),
            ),
          ),
        );
      },
    );

    test(
      'restoreAppDatabaseFromBackupFile removes stale .restoring file before copy',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-restore-temp-',
        );
        addTearDown(() async {
          if (await tempDirectory.exists()) {
            await tempDirectory.delete(recursive: true);
          }
        });

        final sourceFile = File('${tempDirectory.path}/backup.db')
          ..writeAsStringSync('fresh restore bytes');
        final targetFile = File('${tempDirectory.path}/deploydash_state.db');
        final staleRestoreFile = File('${targetFile.path}.restoring')
          ..writeAsStringSync('stale temp content');

        debugOverrideAppDatabaseFileResolver(() async => targetFile);
        addTearDown(() => debugOverrideAppDatabaseFileResolver(null));

        final restoredFile = await restoreAppDatabaseFromBackupFile(
          sourcePath: sourceFile.path,
          overwriteExisting: true,
        );

        expect(restoredFile.path, targetFile.path);
        expect(await restoredFile.readAsString(), 'fresh restore bytes');
        expect(await staleRestoreFile.exists(), isFalse);
      },
    );

    test(
      'enforceSqliteBackupFormatVersion allows a file with no metadata table',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-backup-format-none-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));

        final backupFile = File('${tempDirectory.path}/backup.db');
        const passphrase = 'format check no metadata';

        final encryptedDatabase = sqlite.sqlite3.open(backupFile.path);
        try {
          configureAppDatabaseEncryption(
            encryptedDatabase,
            passphrase: passphrase,
          );
          encryptedDatabase.execute(
            'CREATE TABLE unrelated (id INTEGER PRIMARY KEY);',
          );
        } finally {
          encryptedDatabase.close();
        }

        await expectLater(
          enforceSqliteBackupFormatVersion(
            sourcePath: backupFile.path,
            passphrase: passphrase,
          ),
          completes,
        );
      },
      skip: !encryptedSqliteAvailable,
    );

    test(
      'enforceSqliteBackupFormatVersion allows the current and older formats',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-backup-format-ok-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));
        const passphrase = 'format check ok';

        for (final version in <int>[0, sqliteBackupFormatVersion]) {
          final backupFile = File('${tempDirectory.path}/backup-$version.db');
          final encryptedDatabase = sqlite.sqlite3.open(backupFile.path);
          try {
            configureAppDatabaseEncryption(
              encryptedDatabase,
              passphrase: passphrase,
            );
            encryptedDatabase.execute(
              'CREATE TABLE deploydash_backup_metadata ('
              'id INTEGER PRIMARY KEY, backup_format_version INTEGER NOT NULL'
              ');',
            );
            encryptedDatabase.execute(
              'INSERT INTO deploydash_backup_metadata '
              '(id, backup_format_version) VALUES (1, $version);',
            );
          } finally {
            encryptedDatabase.close();
          }

          await expectLater(
            enforceSqliteBackupFormatVersion(
              sourcePath: backupFile.path,
              passphrase: passphrase,
            ),
            completes,
            reason: 'format_version $version should be supported',
          );
        }
      },
      skip: !encryptedSqliteAvailable,
    );

    test(
      'enforceSqliteBackupFormatVersion refuses a newer format version',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-backup-format-newer-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));

        final backupFile = File('${tempDirectory.path}/backup.db');
        const passphrase = 'format check newer';
        const futureVersion = 99;

        final encryptedDatabase = sqlite.sqlite3.open(backupFile.path);
        try {
          configureAppDatabaseEncryption(
            encryptedDatabase,
            passphrase: passphrase,
          );
          encryptedDatabase.execute(
            'CREATE TABLE deploydash_backup_metadata ('
            'id INTEGER PRIMARY KEY, backup_format_version INTEGER NOT NULL'
            ');',
          );
          encryptedDatabase.execute(
            'INSERT INTO deploydash_backup_metadata '
            '(id, backup_format_version) VALUES (1, $futureVersion);',
          );
        } finally {
          encryptedDatabase.close();
        }

        await expectLater(
          () => enforceSqliteBackupFormatVersion(
            sourcePath: backupFile.path,
            passphrase: passphrase,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              allOf(contains('$futureVersion'), contains('newer')),
            ),
          ),
        );
      },
      skip: !encryptedSqliteAvailable,
    );

    test(
      'enforceSqliteBackupFormatVersion is a no-op for a missing source file',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-backup-format-missing-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));

        await expectLater(
          enforceSqliteBackupFormatVersion(
            sourcePath: '${tempDirectory.path}/missing.db',
            passphrase: 'unused',
          ),
          completes,
        );
      },
    );
  });
}
