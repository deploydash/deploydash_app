import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '_support/app_database_harness.dart';

/// database passphrase rotation.
///
/// One of six files T-3.6.2 split `app_database_test.dart` into, one per
/// group. Fixtures live in `_support/app_database_harness.dart`.
void main() {
  final encryptedSqliteAvailable = ensureEncryptedSqliteRuntimeAvailable();

  group('database passphrase rotation', () {
    tearDown(debugResetAppDatabaseTestState);

    test(
      'rotateAppDatabasePassphrase rekeys the live database to the new password',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-rotate-passphrase-',
        );
        addTearDown(() async {
          if (await tempDirectory.exists()) {
            await tempDirectory.delete(recursive: true);
          }
        });

        final databaseFile = File('${tempDirectory.path}/deploydash_state.db');
        const currentPassphrase = 'current horse battery staple';
        const newPassphrase = 'new horse battery staple';

        debugOverrideAppDatabaseFileResolver(() async => databaseFile);

        final seededDatabase = sqlite.sqlite3.open(databaseFile.path);
        try {
          configureAppDatabaseEncryption(
            seededDatabase,
            passphrase: currentPassphrase,
          );
          seededDatabase.execute(
            'CREATE TABLE secret_notes (id INTEGER PRIMARY KEY, value TEXT);',
          );
          seededDatabase.execute(
            "INSERT INTO secret_notes (value) VALUES ('restored');",
          );
        } finally {
          seededDatabase.close();
        }

        final database = AppDatabase(passphrase: currentPassphrase);
        addTearDown(database.close);

        final beforeRotation = await database
            .customSelect('SELECT value FROM secret_notes;')
            .getSingle();
        expect(beforeRotation.data['value'], 'restored');

        await rotateAppDatabasePassphrase(
          database: database,
          currentPassphrase: currentPassphrase,
          newPassphrase: newPassphrase,
        );

        final afterRotation = await database
            .customSelect('SELECT value FROM secret_notes;')
            .getSingle();
        expect(afterRotation.data['value'], 'restored');
        expect(await validateAppDatabasePassphrase(currentPassphrase), isFalse);
        expect(await validateAppDatabasePassphrase(newPassphrase), isTrue);
      },
      skip: !encryptedSqliteAvailable,
    );

    test(
      'rotateAppDatabasePassphrase rejects empty current password',
      () async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);

        await expectLater(
          () => rotateAppDatabasePassphrase(
            database: database,
            currentPassphrase: '   ',
            newPassphrase: 'new-passphrase',
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Current password is required.',
            ),
          ),
        );
      },
    );

    test('rotateAppDatabasePassphrase rejects empty new password', () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      await expectLater(
        () => rotateAppDatabasePassphrase(
          database: database,
          currentPassphrase: 'current-passphrase',
          newPassphrase: '   ',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'New password is required.',
          ),
        ),
      );
    });

    test(
      'rotateAppDatabasePassphrase rejects unchanged new password',
      () async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);

        await expectLater(
          () => rotateAppDatabasePassphrase(
            database: database,
            currentPassphrase: 'same-password',
            newPassphrase: 'same-password',
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'New password must be different from current password.',
            ),
          ),
        );
      },
    );

    test(
      'rotateAppDatabasePassphrase leaves the original password valid on failure',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-rotate-passphrase-fail-',
        );
        addTearDown(() async {
          if (await tempDirectory.exists()) {
            await tempDirectory.delete(recursive: true);
          }
        });

        final databaseFile = File('${tempDirectory.path}/deploydash_state.db');
        const currentPassphrase = 'correct horse battery staple';
        const newPassphrase = 'new correct horse battery staple';

        debugOverrideAppDatabaseFileResolver(() async => databaseFile);

        final seededDatabase = sqlite.sqlite3.open(databaseFile.path);
        try {
          configureAppDatabaseEncryption(
            seededDatabase,
            passphrase: currentPassphrase,
          );
          seededDatabase.execute(
            'CREATE TABLE secret_notes (id INTEGER PRIMARY KEY, value TEXT);',
          );
          seededDatabase.execute(
            "INSERT INTO secret_notes (value) VALUES ('restored');",
          );
        } finally {
          seededDatabase.close();
        }

        final database = AppDatabase(passphrase: currentPassphrase);
        addTearDown(database.close);

        await expectLater(
          () => rotateAppDatabasePassphrase(
            database: database,
            currentPassphrase: 'wrong-password',
            newPassphrase: newPassphrase,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Current password is incorrect.',
            ),
          ),
        );

        expect(await validateAppDatabasePassphrase(currentPassphrase), isTrue);
        expect(await validateAppDatabasePassphrase(newPassphrase), isFalse);
      },
      skip: !encryptedSqliteAvailable,
    );

    test(
      'rotateAppDatabasePassphrase rejects incorrect current password',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-rotate-passphrase-incorrect-',
        );
        addTearDown(() async {
          if (await tempDirectory.exists()) {
            await tempDirectory.delete(recursive: true);
          }
        });
        debugOverrideAppDatabaseFileResolver(
          () async => File('${tempDirectory.path}/missing.db'),
        );
        addTearDown(() => debugOverrideAppDatabaseFileResolver(null));

        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);

        await expectLater(
          () => rotateAppDatabasePassphrase(
            database: database,
            currentPassphrase: 'wrong-passphrase',
            newPassphrase: 'new-passphrase',
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Current password is incorrect.',
            ),
          ),
        );
      },
    );
  });
}
