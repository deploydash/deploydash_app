part of '../e2e_checklist_test.dart';

Future<void> _runLocalDatabaseSafetyScenario(WidgetTester tester) async {
  if (_localDatabaseBackupPath.trim().isEmpty) {
    fail(
      'DEPLOYDASH_E2E_LOCAL_DATABASE_BACKUP_PATH is required for the '
      'local_database_safety scenario.',
    );
  }
  final backupFile = File(_localDatabaseBackupPath);
  await backupFile.parent.create(recursive: true);
  if (await backupFile.exists()) {
    await backupFile.delete();
  }
  debugOverrideAppSettingsLocalBackupPickers(
    exportPathPicker: (_) async => backupFile.path,
    restorePathPicker: () async => backupFile.path,
  );
  debugOverrideDatabaseUnlockBackupFilePicker(() async => backupFile.path);

  await _waitForHome(tester);
  await _tap(tester, const Key('left-rail-app-settings-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('app-settings-view')),
    description: 'App Settings',
  );
  await _tap(tester, const Key('app-settings-nav-app-backup'));
  await _waitFor(
    tester,
    find.byKey(const Key('app-settings-backup-export-button')),
    description: 'local database export action',
  );
  await _tap(tester, const Key('app-settings-backup-export-button'));
  await _waitFor(
    tester,
    find.textContaining('Encrypted database exported to'),
    description: 'local database export confirmation',
    timeout: const Duration(minutes: 1),
  );
  if (!await backupFile.exists() || await backupFile.length() == 0) {
    fail('The local encrypted database export is missing or empty.');
  }
  final oldPasswordMatchesBeforeRotation =
      await validateAppDatabaseBackupPassphrase(
        sourcePath: backupFile.path,
        passphrase: _databasePassphrase,
      );
  final newPasswordMatchesBeforeRotation =
      await validateAppDatabaseBackupPassphrase(
        sourcePath: backupFile.path,
        passphrase: _rotatedDatabasePassphrase,
      );
  expect(oldPasswordMatchesBeforeRotation, isTrue);
  expect(newPasswordMatchesBeforeRotation, isFalse);
  _pass(
    'App Settings And Local Database Safety::Export encrypted local DB snapshot',
    'The App Settings export produced a non-empty encrypted database that '
        'opens only with the original password.',
    <String, Object?>{
      'file_size_bytes': await backupFile.length(),
      'original_password_valid': oldPasswordMatchesBeforeRotation,
      'rotated_password_valid': newPasswordMatchesBeforeRotation,
    },
  );

  await _rotateLocalDatabasePassword(tester);
  expect(await validateAppDatabasePassphrase(_databasePassphrase), isFalse);
  expect(
    await validateAppDatabasePassphrase(_rotatedDatabasePassphrase),
    isTrue,
  );

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await tester.pumpWidget(_buildE2eRootApp());
  await _unlockLocalDatabase(tester, passphrase: _rotatedDatabasePassphrase);
  await _waitForHome(tester);

  await _tap(tester, const Key('left-rail-app-settings-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('app-settings-view')),
    description: 'App Settings after password rotation',
  );
  await _tap(tester, const Key('app-settings-nav-app-backup'));
  await _tap(tester, const Key('app-settings-backup-restore-local-button'));
  await _waitFor(
    tester,
    find.text('Restore this local backup?'),
    description: 'local backup replacement confirmation',
  );
  await _tapFinder(
    tester,
    find.text('Replace app data from local backup'),
    description: 'confirm local backup replacement',
  );
  await _waitFor(
    tester,
    find.textContaining('does not match your current app password'),
    description: 'old backup password warning',
    timeout: const Duration(minutes: 1),
  );
  _pass(
    'App Settings And Local Database Safety::Existing exported DB still uses old password warning',
    'The running app rejected a pre-rotation backup because it retained the '
        'original encryption password.',
  );
  await _tapFinder(
    tester,
    find.text('OK'),
    description: 'dismiss restore error',
  );

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await tester.pumpWidget(_buildE2eRootApp());
  await _waitFor(
    tester,
    find.byKey(const Key('database-restore-launch-button')),
    description: 'startup database restore action',
  );
  await _tap(tester, const Key('database-restore-launch-button'));
  await _tap(tester, const Key('database-restore-browse-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('database-restore-path-field')),
    description: 'selected startup backup path',
  );
  expect(
    tester
        .widget<TextFormField>(
          find.byKey(const Key('database-restore-path-field')),
        )
        .controller!
        .text,
    backupFile.path,
  );
  await _tap(tester, const Key('database-restore-submit'));
  await _waitFor(
    tester,
    find.byKey(const Key('database-startup-status')),
    description: 'startup database restore confirmation',
  );
  await _unlockLocalDatabase(tester, passphrase: _databasePassphrase);
  await _waitForHome(tester);
  expect(await validateAppDatabasePassphrase(_databasePassphrase), isTrue);
  expect(
    await validateAppDatabasePassphrase(_rotatedDatabasePassphrase),
    isFalse,
  );
  _pass(
    'App Settings And Local Database Safety::Restore encrypted DB before unlock',
    'The startup restore replaced the isolated E2E database and unlocked it '
        'with the snapshot\'s original password.',
    <String, Object?>{
      'restored_file_size_bytes': await backupFile.length(),
      'original_password_valid_after_restore': true,
      'rotated_password_valid_after_restore': false,
    },
  );
}
