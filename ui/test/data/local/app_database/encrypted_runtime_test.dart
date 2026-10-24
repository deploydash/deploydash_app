import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:posix/posix.dart' as posix;

import '_support/app_database_harness.dart';

/// encrypted SQLite runtime.
///
/// One of six files T-3.6.2 split `app_database_test.dart` into, one per
/// group. Fixtures live in `_support/app_database_harness.dart`.
void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();
  final encryptedSqliteAvailable = ensureEncryptedSqliteRuntimeAvailable();

  group('encrypted SQLite runtime', () {
    tearDown(debugResetAppDatabaseTestState);

    test('resolves Windows Store data under package-managed LocalState', () {
      expect(
        resolveWindowsStoreAppSupportDirectory(
          runsOnWindows: true,
          packageFamilyName: ' TidyTechnology.DeployDash_test ',
          localAppData: r' C:\Users\tester\AppData\Local ',
        ),
        p.join(
          r'C:\Users\tester\AppData\Local',
          'Packages',
          'TidyTechnology.DeployDash_test',
          'LocalState',
          'Deploy Dash',
        ),
      );
      expect(
        resolveWindowsStoreAppSupportDirectory(
          runsOnWindows: false,
          packageFamilyName: 'TidyTechnology.DeployDash_test',
          localAppData: r'C:\Users\tester\AppData\Local',
        ),
        isNull,
      );
      expect(
        resolveWindowsStoreAppSupportDirectory(
          runsOnWindows: true,
          packageFamilyName: ' ',
          localAppData: r'C:\Users\tester\AppData\Local',
        ),
        isNull,
      );
      for (final localAppData in <String?>[' ', null]) {
        expect(
          () => resolveWindowsStoreAppSupportDirectory(
            runsOnWindows: true,
            packageFamilyName: 'TidyTechnology.DeployDash_test',
            localAppData: localAppData,
          ),
          throwsStateError,
        );
      }
    });

    test('uses package-managed LocalState for a Windows Store build', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-windows-store-data-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      debugOverrideAppDatabaseWindowsCheck(() => true);
      debugOverrideWindowsStoreDatabaseEnvironment(
        packageFamilyLoader: () => 'TidyTechnology.DeployDash_test',
        localAppDataLoader: () => tempDirectory.path,
      );

      final databaseFile = await resolveAppDatabaseFile();

      expect(
        databaseFile.path,
        p.join(
          tempDirectory.path,
          'Packages',
          'TidyTechnology.DeployDash_test',
          'LocalState',
          'Deploy Dash',
          'deploydash_state.db',
        ),
      );
      expect(await databaseFile.parent.exists(), isTrue);
    });

    test('reports an encryption-capable native SQLite runtime', () {
      expect(encryptedSqliteAvailable, isTrue);
    }, skip: !sqliteAvailable);

    test('rejects SQLite runtimes without an encryption cipher', () {
      final database = sqlite.sqlite3.openInMemory();
      addTearDown(database.close);

      expect(
        () => configureAppDatabaseEncryption(
          CipherProbeDatabase(database.select('SELECT 1 WHERE 0')),
          passphrase: 'test-passphrase',
        ),
        throwsStateError,
      );
      expect(
        () => configureAppDatabaseEncryption(
          CipherProbeDatabase(database.select('SELECT NULL')),
          passphrase: 'test-passphrase',
        ),
        throwsStateError,
      );
    });

    test(
      'validateAppDatabasePassphrase unlocks an encrypted database',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-app-db-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));

        final databaseFile = File('${tempDirectory.path}/deploydash_state.db');
        const passphrase = 'correct horse battery staple';

        debugOverrideAppDatabaseFileResolver(() async => databaseFile);
        final encryptedDatabase = sqlite.sqlite3.open(databaseFile.path);
        try {
          configureAppDatabaseEncryption(
            encryptedDatabase,
            passphrase: passphrase,
          );
          encryptedDatabase.execute(
            'CREATE TABLE secret_notes (id INTEGER PRIMARY KEY, value TEXT);',
          );
          encryptedDatabase.execute(
            "INSERT INTO secret_notes (value) VALUES ('restored');",
          );
        } finally {
          encryptedDatabase.close();
        }

        expect(await validateAppDatabasePassphrase(passphrase), isTrue);
        expect(
          await validateAppDatabasePassphrase('wrong-passphrase'),
          isFalse,
        );
      },
      skip: !encryptedSqliteAvailable,
    );

    test(
      'createAppDatabasePassphrase creates an encrypted database that can be '
      'reopened with the same password',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-app-db-create-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));

        final databaseFile = File('${tempDirectory.path}/deploydash_state.db');
        const passphrase = 'fresh horse battery staple';
        if (!Platform.isWindows) {
          posix.chmodWithMode(tempDirectory.path, 0x1ED);
        }

        debugOverrideAppDatabaseFileResolver(() async => databaseFile);

        expect(await appDatabaseExists(), isFalse);
        expect(await createAppDatabasePassphrase(passphrase), isTrue);
        expect(await appDatabaseExists(), isTrue);
        if (!Platform.isWindows) {
          expect((await tempDirectory.stat()).mode & 0x1FF, 0x1C0);
          expect((await databaseFile.stat()).mode & 0x1FF, 0x180);
        }
        expect(await validateAppDatabasePassphrase(passphrase), isTrue);
        expect(
          await validateAppDatabasePassphrase('wrong-passphrase'),
          isFalse,
        );
      },
      skip: !encryptedSqliteAvailable,
    );

    test(
      'createAppDatabasePassphrase records a redacted diagnostic on failure',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-app-db-create-failure-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));

        const passphrase = 'secret-passphrase';
        final blockedParent = File('${tempDirectory.path}/not-a-directory');
        await blockedParent.writeAsString('blocked');
        final databaseFile = File('${blockedParent.path}/deploydash_state.db');

        debugOverrideAppDatabaseFileResolver(() async => databaseFile);

        expect(await createAppDatabasePassphrase(passphrase), isFalse);
        final details = appDatabasePassphraseCreationFailureDetails();
        expect(details, isNotNull);
        expect(details, isNot(contains(passphrase)));
        expect(await databaseFile.exists(), isFalse);
      },
      skip: !encryptedSqliteAvailable,
    );

    test(
      'secures database storage files and preserves the Windows ACL path',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-app-db-permissions-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));

        final databaseFile = File('${tempDirectory.path}/deploydash_state.db')
          ..writeAsStringSync('encrypted database bytes');
        final sidecars = <File>[
          File('${databaseFile.path}-wal')..writeAsStringSync('wal bytes'),
          File('${databaseFile.path}-shm')..writeAsStringSync('shm bytes'),
          File('${databaseFile.path}.restoring')
            ..writeAsStringSync('temp bytes'),
        ];
        posix.chmodWithMode(tempDirectory.path, 0x1ED);
        for (final file in <File>[databaseFile, ...sidecars]) {
          posix.chmodWithMode(file.path, 0x1A4);
        }

        debugOverrideAppDatabaseWindowsCheck(() => false);
        await debugSecureAppDatabaseStorage(databaseFile);

        expect((await tempDirectory.stat()).mode & 0x1FF, 0x1C0);
        for (final file in <File>[databaseFile, ...sidecars]) {
          expect((await file.stat()).mode & 0x1FF, 0x180);
        }

        posix.chmodWithMode(tempDirectory.path, 0x1ED);
        debugOverrideAppDatabaseWindowsCheck(() => true);
        await debugSecureAppDatabaseStorage(databaseFile);

        expect((await tempDirectory.stat()).mode & 0x1FF, 0x1ED);
      },
    );

    test(
      'validateAppDatabaseBackupPassphrase checks an encrypted backup file',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-app-db-backup-validate-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));

        final backupFile = File('${tempDirectory.path}/backup.db');
        const passphrase = 'backup validation passphrase';

        final encryptedDatabase = sqlite.sqlite3.open(backupFile.path);
        try {
          configureAppDatabaseEncryption(
            encryptedDatabase,
            passphrase: passphrase,
          );
          encryptedDatabase.execute(
            'CREATE TABLE secret_notes (id INTEGER PRIMARY KEY, value TEXT);',
          );
          encryptedDatabase.execute(
            "INSERT INTO secret_notes (value) VALUES ('backup');",
          );
        } finally {
          encryptedDatabase.close();
        }

        expect(
          await validateAppDatabaseBackupPassphrase(
            sourcePath: backupFile.path,
            passphrase: passphrase,
          ),
          isTrue,
        );
        expect(
          await validateAppDatabaseBackupPassphrase(
            sourcePath: backupFile.path,
            passphrase: 'wrong-passphrase',
          ),
          isFalse,
        );
      },
      skip: !encryptedSqliteAvailable,
    );
  });
}
