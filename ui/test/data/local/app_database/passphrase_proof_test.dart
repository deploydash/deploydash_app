import 'package:flutter_test/flutter_test.dart';
import 'package:posix/posix.dart' as posix;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '_support/app_database_harness.dart';

/// D-27 passphrase proof + sidecar characterization.
///
/// Pins the observable contracts before the passphrase validators collapse
/// onto one prover and the pair-2 sidecar literals collapse onto one list
/// builder: live-vs-backup resolution, trimmed-passphrase use, no-throw
/// false results, handle hygiene, the chmod/delete sidecar sets, the
/// restore sweep's `.restoring` exclusion, and the per-behavior file guards
/// (return-false / void-return / throw with exact messages).
void main() {
  final encryptedSqliteAvailable = ensureEncryptedSqliteRuntimeAvailable();

  /// Seeds an encrypted database file holding one table.
  void seedEncryptedDatabase(File file, String passphrase) {
    final encryptedDatabase = sqlite.sqlite3.open(file.path);
    try {
      configureAppDatabaseEncryption(encryptedDatabase, passphrase: passphrase);
      encryptedDatabase.execute(
        'CREATE TABLE secret_notes (id INTEGER PRIMARY KEY, value TEXT);',
      );
      encryptedDatabase.execute(
        "INSERT INTO secret_notes (value) VALUES ('proof');",
      );
    } finally {
      encryptedDatabase.close();
    }
  }

  group('D-27 passphrase validators', () {
    tearDown(debugResetAppDatabaseTestState);

    test(
      'live validator resolves through the override and secures storage',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-d27-live-resolve-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));

        final databaseFile = File('${tempDirectory.path}/deploydash_state.db');
        const passphrase = 'live resolution passphrase';
        seedEncryptedDatabase(databaseFile, passphrase);
        posix.chmodWithMode(databaseFile.path, 0x1A4);

        debugOverrideAppDatabaseFileResolver(() async => databaseFile);

        expect(await validateAppDatabasePassphrase(passphrase), isTrue);
        expect((await databaseFile.stat()).mode & 0x1FF, 0x180);
      },
      skip: !encryptedSqliteAvailable,
    );

    test('live validator trims the passphrase before proving', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-live-trim-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final databaseFile = File('${tempDirectory.path}/deploydash_state.db');
      const passphrase = 'trimmed live passphrase';
      seedEncryptedDatabase(databaseFile, passphrase);

      debugOverrideAppDatabaseFileResolver(() async => databaseFile);

      expect(await validateAppDatabasePassphrase('  $passphrase\t'), isTrue);
    }, skip: !encryptedSqliteAvailable);

    test('live validator returns false for a blank passphrase', () async {
      debugOverrideAppDatabaseFileResolver(
        () async => File('/nonexistent-dir-proves-no-touch/deploydash.db'),
      );

      expect(await validateAppDatabasePassphrase('   '), isFalse);
    });

    test('live validator returns false for a missing database file', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-live-missing-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      debugOverrideAppDatabaseFileResolver(
        () async => File('${tempDirectory.path}/missing.db'),
      );

      expect(await validateAppDatabasePassphrase('any-passphrase'), isFalse);
    });

    test('live validator returns false for an empty database file', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-live-empty-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final databaseFile = File('${tempDirectory.path}/deploydash_state.db')
        ..writeAsBytesSync(<int>[]);
      debugOverrideAppDatabaseFileResolver(() async => databaseFile);

      expect(await validateAppDatabasePassphrase('any-passphrase'), isFalse);
    });

    test(
      'live validator returns false for a database it cannot open',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-d27-live-unencrypted-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));

        final databaseFile = File('${tempDirectory.path}/deploydash_state.db');
        final plainDatabase = sqlite.sqlite3.open(databaseFile.path);
        try {
          plainDatabase.execute('CREATE TABLE notes (id INTEGER PRIMARY KEY);');
        } finally {
          plainDatabase.close();
        }
        debugOverrideAppDatabaseFileResolver(() async => databaseFile);

        expect(
          await validateAppDatabasePassphrase('wrong key for plain db'),
          isFalse,
        );
      },
      skip: !encryptedSqliteAvailable,
    );

    test('live validator closes the database it opens', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-live-close-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final databaseFile = File('${tempDirectory.path}/deploydash_state.db');
      const passphrase = 'close hygiene passphrase';
      seedEncryptedDatabase(databaseFile, passphrase);

      debugOverrideAppDatabaseFileResolver(() async => databaseFile);

      expect(await validateAppDatabasePassphrase(passphrase), isTrue);

      final reopened = sqlite.sqlite3.open(databaseFile.path);
      try {
        configureAppDatabaseEncryption(reopened, passphrase: passphrase);
        reopened.execute("INSERT INTO secret_notes (value) VALUES ('x');");
      } finally {
        reopened.close();
      }
      await databaseFile.delete();
      expect(await databaseFile.exists(), isFalse);
    }, skip: !encryptedSqliteAvailable);

    test(
      'backup validator uses the caller path and skips the secure call',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-d27-backup-path-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));

        final backupFile = File('${tempDirectory.path}/backup.db');
        const passphrase = 'backup caller path passphrase';
        seedEncryptedDatabase(backupFile, passphrase);
        posix.chmodWithMode(backupFile.path, 0x1A4);

        // The live-database resolver points at nothing: a true result proves
        // the caller path was used.
        debugOverrideAppDatabaseFileResolver(
          () async => File('${tempDirectory.path}/missing-live.db'),
        );

        expect(
          await validateAppDatabaseBackupPassphrase(
            sourcePath: backupFile.path,
            passphrase: passphrase,
          ),
          isTrue,
        );
        // Unchanged mode proves storage was never secured on this path.
        expect((await backupFile.stat()).mode & 0x1FF, 0x1A4);
      },
      skip: !encryptedSqliteAvailable,
    );

    test('backup validator trims the passphrase before proving', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-backup-trim-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final backupFile = File('${tempDirectory.path}/backup.db');
      const passphrase = 'trimmed backup passphrase';
      seedEncryptedDatabase(backupFile, passphrase);

      expect(
        await validateAppDatabaseBackupPassphrase(
          sourcePath: backupFile.path,
          passphrase: ' $passphrase ',
        ),
        isTrue,
      );
    }, skip: !encryptedSqliteAvailable);

    test('backup validator returns false for a blank passphrase', () async {
      expect(
        await validateAppDatabaseBackupPassphrase(
          sourcePath: '/nonexistent-dir-proves-no-touch/backup.db',
          passphrase: '  ',
        ),
        isFalse,
      );
    });

    test('backup validator returns false for a missing source file', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-backup-missing-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      expect(
        await validateAppDatabaseBackupPassphrase(
          sourcePath: '${tempDirectory.path}/missing.db',
          passphrase: 'any-passphrase',
        ),
        isFalse,
      );
    });

    test('backup validator returns false for an empty source file', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-backup-empty-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final backupFile = File('${tempDirectory.path}/backup.db')
        ..writeAsBytesSync(<int>[]);
      expect(
        await validateAppDatabaseBackupPassphrase(
          sourcePath: backupFile.path,
          passphrase: 'any-passphrase',
        ),
        isFalse,
      );
    });

    test('backup validator returns false for a file it cannot open', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-backup-unencrypted-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final backupFile = File('${tempDirectory.path}/backup.db');
      final plainDatabase = sqlite.sqlite3.open(backupFile.path);
      try {
        plainDatabase.execute('CREATE TABLE notes (id INTEGER PRIMARY KEY);');
      } finally {
        plainDatabase.close();
      }

      expect(
        await validateAppDatabaseBackupPassphrase(
          sourcePath: backupFile.path,
          passphrase: 'wrong key for plain db',
        ),
        isFalse,
      );
    }, skip: !encryptedSqliteAvailable);
  });

  group('D-27 guard behaviors', () {
    tearDown(debugResetAppDatabaseTestState);

    test('appDatabaseExists reports only non-empty files', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-exists-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final databaseFile = File('${tempDirectory.path}/deploydash_state.db');
      debugOverrideAppDatabaseFileResolver(() async => databaseFile);

      expect(await appDatabaseExists(), isFalse);

      await databaseFile.writeAsBytes(<int>[]);
      expect(await appDatabaseExists(), isFalse);

      await databaseFile.writeAsString('non-empty');
      expect(await appDatabaseExists(), isTrue);
    });

    test('creation treats a zero-length database file as absent', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-create-empty-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final databaseFile = File('${tempDirectory.path}/deploydash_state.db')
        ..writeAsBytesSync(<int>[]);
      debugOverrideAppDatabaseFileResolver(() async => databaseFile);

      expect(
        await createAppDatabasePassphrase('zero length means absent'),
        isTrue,
      );
      expect(
        await validateAppDatabasePassphrase('zero length means absent'),
        isTrue,
      );
    }, skip: !encryptedSqliteAvailable);

    test('restore reports the exact missing-source message', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-restore-missing-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final targetFile = File('${tempDirectory.path}/deploydash_state.db');
      debugOverrideAppDatabaseFileResolver(() async => targetFile);

      await expectLater(
        () => restoreAppDatabaseFromBackupFile(
          sourcePath: '${tempDirectory.path}/missing.db',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Backup file does not exist.',
          ),
        ),
      );
    });

    test('restore reports the exact empty-source message', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-restore-empty-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final sourceFile = File('${tempDirectory.path}/backup.db')
        ..writeAsBytesSync(<int>[]);
      final targetFile = File('${tempDirectory.path}/deploydash_state.db');
      debugOverrideAppDatabaseFileResolver(() async => targetFile);

      await expectLater(
        () => restoreAppDatabaseFromBackupFile(sourcePath: sourceFile.path),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Backup file is empty.',
          ),
        ),
      );
    });

    test('restore reports the exact overwrite-refusal message', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-restore-overwrite-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final sourceFile = File('${tempDirectory.path}/backup.db')
        ..writeAsStringSync('backup bytes');
      final targetFile = File('${tempDirectory.path}/deploydash_state.db')
        ..writeAsStringSync('existing local db');
      debugOverrideAppDatabaseFileResolver(() async => targetFile);

      await expectLater(
        () => restoreAppDatabaseFromBackupFile(sourcePath: sourceFile.path),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Local Deploy Dash database already exists. '
                'Pass overwriteExisting: true to replace it.',
          ),
        ),
      );
    });

    test('format enforcement returns void for an empty source file', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-format-empty-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final backupFile = File('${tempDirectory.path}/backup.db')
        ..writeAsBytesSync(<int>[]);
      await expectLater(
        enforceSqliteBackupFormatVersion(
          sourcePath: backupFile.path,
          passphrase: 'unused',
        ),
        completes,
      );
    });
  });

  group('D-27 sidecar sets', () {
    tearDown(debugResetAppDatabaseTestState);

    test('creation deletes every stale database sidecar first', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-d27-create-sidecars-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final databaseFile = File('${tempDirectory.path}/deploydash_state.db')
        ..writeAsBytesSync(<int>[]);
      final staleWal = File('${databaseFile.path}-wal')
        ..writeAsStringSync('stale wal junk');
      final staleShm = File('${databaseFile.path}-shm')
        ..writeAsStringSync('stale shm junk');
      final staleRestoring = File('${databaseFile.path}.restoring')
        ..writeAsStringSync('stale restoring junk');
      debugOverrideAppDatabaseFileResolver(() async => databaseFile);

      const passphrase = 'sidecar sweep passphrase';
      expect(await createAppDatabasePassphrase(passphrase), isTrue);
      expect(await validateAppDatabasePassphrase(passphrase), isTrue);

      // No SQLite engine recreates `.restoring`, so it must be gone; the
      // journals may be recreated by the engine, but never with stale bytes.
      expect(await staleRestoring.exists(), isFalse);
      for (final journal in <File>[staleWal, staleShm]) {
        if (await journal.exists()) {
          expect(await journal.readAsString(), isNot(contains('stale')));
        }
      }
    }, skip: !encryptedSqliteAvailable);

    test(
      'restore sweep keeps the .restoring copy source for the rename',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-d27-restore-sweep-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));

        final sourceFile = File('${tempDirectory.path}/backup.db')
          ..writeAsStringSync('fresh restore payload');
        final targetFile = File('${tempDirectory.path}/deploydash_state.db')
          ..writeAsStringSync('stale local db');
        File('${targetFile.path}-wal').writeAsStringSync('stale wal');
        File('${targetFile.path}-shm').writeAsStringSync('stale shm');
        File(
          '${targetFile.path}.restoring',
        ).writeAsStringSync('stale temp content');

        debugOverrideAppDatabaseFileResolver(() async => targetFile);

        final restoredFile = await restoreAppDatabaseFromBackupFile(
          sourcePath: sourceFile.path,
          overwriteExisting: true,
        );

        // The target holds the source payload only if the fresh `.restoring`
        // copy survived the stale-sweep and was renamed into place.
        expect(await restoredFile.readAsString(), 'fresh restore payload');
        expect(await File('${targetFile.path}-wal').exists(), isFalse);
        expect(await File('${targetFile.path}-shm').exists(), isFalse);
        expect(await File('${targetFile.path}.restoring').exists(), isFalse);
      },
    );
  });

  group('D-27 collapsed structure', () {
    test('passphrase proof and sidecar list have one owner each', () {
      final source = File(
        'lib/data/local/app_database.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('Future<bool> _validatePassphraseForFile('),
        reason: 'one passphrase prover',
      );
      expect(
        source,
        contains('List<String> _databaseSidecarPaths('),
        reason: 'one sidecar-list builder',
      );
      expect(
        source,
        contains('Future<bool> _isNonEmptyFile('),
        reason: 'return-false/void guard owner',
      );
      expect(
        source,
        contains('Future<void> _requireNonEmptyFile('),
        reason: 'throw guard owner',
      );

      final rawProbeCount =
          'database.select(\'SELECT COUNT(*) AS c FROM sqlite_master;\');'
              .allMatches(source)
              .length;
      expect(
        rawProbeCount,
        1,
        reason:
            'the raw sqlite probe lives only in the prover '
            '(the two Drift customSelect uses are a different API)',
      );

      final openCount = 'sqlite.sqlite3.open('.allMatches(source).length;
      expect(
        openCount,
        2,
        reason: 'only the prover and the format enforcer open raw databases',
      );

      final restoringCodeLines = source
          .split('\n')
          .where(
            (line) => line.contains('.restoring') && !line.startsWith('///'),
          );
      expect(
        restoringCodeLines.length,
        2,
        reason:
            'the sidecar builder plus the restore temp-file construction; '
            'the 3-path stale-sweep must not gain one',
      );
    });
  });
}
