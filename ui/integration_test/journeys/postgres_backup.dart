part of '../e2e_checklist_test.dart';

Future<void> _runPostgresBackupScenario(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  binding.shouldPropagateDevicePointerEvents = false;
  final bucketName = _requiredE2eEnvironment('DEPLOYDASH_E2E_B2_BUCKET');
  final accessKey = _requiredE2eEnvironment('DEPLOYDASH_E2E_B2_KEY_ID');
  final secretKey = _requiredE2eEnvironment('DEPLOYDASH_E2E_B2_APP_KEY');
  final endpoint = _requiredE2eEnvironment(
    'DEPLOYDASH_E2E_B2_ENDPOINT',
  ).replaceFirst(RegExp(r'^https?://'), '');
  final region = _requiredE2eEnvironment('DEPLOYDASH_E2E_B2_REGION');
  final suffix = DateTime.now().millisecondsSinceEpoch.remainder(1000000);
  final projectName = 'E2E database recovery $suffix';
  final databaseName = 'e2e_recovery_$suffix';
  final restoredDatabaseName = 'e2e_restored_$suffix';
  final username = 'e2e_user_$suffix';
  final destinationName = 'E2E B2 $suffix';
  final policyName = 'E2E backup $suffix';

  await _ensurePostgresServiceEnabled(tester);
  await _createProject(tester, name: projectName, runtime: 'PHP');
  await _openProjectTab(
    tester,
    'Database',
    find.byKey(const Key('database-type-postgres-tab')),
  );
  await _tap(tester, const Key('database-type-postgres-tab'));
  await _waitForEnabledButton(
    tester,
    const Key('database-create-button'),
    description: 'PostgreSQL create database action',
    timeout: const Duration(minutes: 2),
  );
  _pass(
    'Project Database::Project Database after PostgreSQL start',
    'The project database workspace recognized the newly enabled PostgreSQL service.',
  );

  await _tap(tester, const Key('database-create-button'));
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('database-create-name-field')),
    databaseName,
    description: 'PostgreSQL database name',
  );
  await _tap(tester, const Key('database-create-confirm-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('database-credentials-dialog')),
    description: 'new database credentials',
    timeout: const Duration(minutes: 4),
  );
  await _tap(tester, const Key('database-credentials-close-button'));
  final managedDatabaseName = await _findManagedPostgresObjectName(
    kind: _ManagedPostgresObjectKind.database,
    requestedName: databaseName,
  );
  await _waitFor(
    tester,
    find.byKey(Key('database-resource-$databaseName')),
    description: 'created PostgreSQL database',
  );
  await _verifyPostgresQuery(
    databaseName: 'postgres',
    query: "SELECT 1 FROM pg_database WHERE datname='$managedDatabaseName'",
    expected: '1',
  );
  _pass(
    'Project Database::PostgreSQL create database',
    'Created the database through the project workspace and confirmed it in PostgreSQL.',
  );

  await _tap(tester, const Key('database-link-button'));
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('database-connect-existing-username-field')),
    username,
    description: 'PostgreSQL username',
  );
  await _tap(tester, const Key('database-create-user-confirm-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('database-credentials-dialog')),
    description: 'new database user credentials',
    timeout: const Duration(minutes: 3),
  );
  await _tap(tester, const Key('database-credentials-close-button'));
  final managedUsername = await _findManagedPostgresObjectName(
    kind: _ManagedPostgresObjectKind.role,
    requestedName: username,
  );
  await _waitFor(
    tester,
    find.byKey(Key('database-user-$username')),
    description: 'created PostgreSQL user',
  );
  await _verifyPostgresQuery(
    databaseName: 'postgres',
    query: "SELECT 1 FROM pg_roles WHERE rolname='$managedUsername'",
    expected: '1',
  );
  _pass(
    'Project Database::PostgreSQL create user',
    'Created a database-scoped login and confirmed the PostgreSQL role exists.',
  );

  await _tap(tester, const Key('database-copy-connection-button'));
  await _waitFor(
    tester,
    find.text('Connection string copied.'),
    description: 'connection string copy confirmation',
  );
  // Not a Clipboard.getData read: the same OS/GTK clipboard round trip that
  // never completes for the GitHub OAuth authorization URL
  // (widget_driver.dart's _tapCopyOauthUrlAndConfirmCopied) doesn't work
  // here either -- on a live run this read back an unrelated stray string
  // ('Medium Pile') that was never anything this app wrote, not an empty
  // value from a slow write. database_tab.dart's copy button is disabled
  // (onPressed: null) whenever connectionString is null, so the SnackBar
  // wait above already proves the app built and attempted to copy a real,
  // non-null connection string -- the one thing this checklist row cares
  // about -- without depending on a clipboard read that this environment
  // cannot make reliable.
  _pass(
    'Project Database::PostgreSQL copy connection URI',
    'Copied the selected user connection URI without recording its secret value in E2E evidence.',
  );

  await _tap(tester, Key('database-user-reset-$username'));
  await _waitFor(
    tester,
    find.byKey(const Key('database-credentials-dialog')),
    description: 'rotated database user credentials',
    timeout: const Duration(minutes: 3),
  );
  await _tap(tester, const Key('database-credentials-close-button'));
  _pass(
    'Project Database::PostgreSQL reset password',
    'Reset the managed database user password and received replacement credentials.',
  );

  final artifactRoot = File(_localDatabaseBackupPath).parent;
  await artifactRoot.create(recursive: true);
  final validSql = File('${artifactRoot.path}/postgres-import-valid.sql');
  final invalidSql = File('${artifactRoot.path}/postgres-import-invalid.sql');
  await validSql.writeAsString(
    "CREATE TABLE IF NOT EXISTS e2e_backup_probe(value text NOT NULL);\n"
    "TRUNCATE e2e_backup_probe;\n"
    "INSERT INTO e2e_backup_probe(value) VALUES ('before-backup');\n",
  );
  await invalidSql.writeAsString('THIS IS NOT VALID SQL;\n');
  final sqlFiles = <String>[validSql.path, invalidSql.path];
  debugOverridePostgresRestoreSqlFilePicker(
    () async => sqlFiles.isEmpty ? null : sqlFiles.removeAt(0),
  );

  await _tap(tester, const Key('database-restore-local-sql-button'));
  await _confirmPostgresSqlRestore(tester, description: 'valid SQL import');
  await _waitFor(
    tester,
    find.textContaining('SQL file restored into'),
    description: 'successful SQL import',
    timeout: const Duration(minutes: 4),
  );
  await _verifyPostgresQuery(
    databaseName: managedDatabaseName,
    query: 'SELECT value FROM e2e_backup_probe',
    expected: 'before-backup',
  );
  _pass(
    'Project Database::PostgreSQL local .sql import',
    'Imported a real local SQL file and independently queried its sentinel row.',
  );

  await _tap(tester, const Key('database-restore-local-sql-button'));
  await _confirmPostgresSqlRestore(tester, description: 'invalid SQL import');
  await _waitFor(
    tester,
    find.byKey(const Key('database-error-card')),
    description: 'failed SQL import details',
    timeout: const Duration(minutes: 4),
  );
  expect(find.text('SQL restore failed'), findsOneWidget);
  _pass(
    'Project Database::PostgreSQL failed import path',
    'An invalid SQL file failed visibly without removing the selected database.',
  );

  await _openProjectTab(
    tester,
    'Backup',
    find.byKey(const Key('backup-add-destination-button')),
  );
  await _tap(tester, const Key('backup-add-destination-button'));
  await _fillS3DestinationDialog(
    tester,
    name: destinationName,
    bucket: bucketName,
    accessKey: accessKey,
    secretKey: secretKey,
    region: region,
    endpoint: endpoint,
  );
  await _tap(tester, const Key('backup-destination-test-button'));
  await _waitFor(
    tester,
    find.textContaining('succeeded'),
    description: 'B2 destination connectivity result',
    timeout: const Duration(minutes: 4),
  );
  _pass(
    'Project Backup::Backup destination connectivity test',
    'The destination dialog wrote, read, compared, and removed a real B2 test object.',
  );
  await _tap(tester, const Key('backup-destination-save-button'));
  await _waitFor(
    tester,
    find.text(destinationName),
    description: 'B2 destination',
  );
  _pass(
    'Project Backup::Backup destination create',
    'Saved the tested B2 destination in the isolated encrypted database.',
  );

  await _tap(tester, const Key('backup-add-policy-button'));
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('backup-policy-name-field')),
    policyName,
    description: 'backup policy name',
  );
  final manualDatabaseField = find.byKey(
    const Key('backup-policy-database-manual-field'),
  );
  if (manualDatabaseField.evaluate().isNotEmpty) {
    await _enterAndVerifyText(
      tester,
      manualDatabaseField,
      databaseName,
      description: 'backup policy database',
    );
  } else {
    await _enterAndVerifyText(
      tester,
      find.byKey(const Key('backup-policy-database-field')),
      databaseName,
      description: 'backup policy database',
    );
  }
  await _tap(tester, const Key('backup-policy-save-button'));
  await _waitFor(
    tester,
    find.text('Backup policy created.'),
    description: 'created backup policy',
    timeout: const Duration(minutes: 3),
  );
  final policyRunKey = _firstValueKeyStartingWith(tester, 'backup-policy-run-');
  await _tap(tester, policyRunKey);
  await _waitFor(
    tester,
    find.text('Backup run completed.'),
    description: 'completed B2 backup',
    timeout: const Duration(minutes: 5),
  );
  _pass(
    'Project Backup::Run backup now',
    'Ran the PostgreSQL policy against the real B2 destination.',
  );

  final refreshKey = _firstValueKeyStartingWith(
    tester,
    'backup-policy-refresh-',
  );
  await _tap(tester, refreshKey);
  await _waitFor(
    tester,
    find.text('Backup artifacts refreshed.'),
    description: 'refreshed B2 artifacts',
    timeout: const Duration(minutes: 4),
  );
  final artifactRestoreKey = _firstValueKeyStartingWith(
    tester,
    'backup-artifact-restore-',
  );
  _pass(
    'Project Backup::Backup artifact list refresh',
    'Refreshed the artifact inventory from B2 and found the newly uploaded dump.',
  );

  await _verifyPostgresCommand(
    databaseName: managedDatabaseName,
    sql: "UPDATE e2e_backup_probe SET value='after-backup'",
  );
  await _tap(tester, artifactRestoreKey);
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('backup-restore-database-field')),
    restoredDatabaseName,
    description: 'restored PostgreSQL database name',
  );
  await _tap(tester, const Key('backup-restore-confirm-button'));
  await _waitFor(
    tester,
    find.text('Restore completed.'),
    description: 'completed B2 restore',
    timeout: const Duration(minutes: 6),
  );
  final managedRestoredDatabaseName = await _findManagedPostgresObjectName(
    kind: _ManagedPostgresObjectKind.database,
    requestedName: restoredDatabaseName,
  );
  await _verifyPostgresQuery(
    databaseName: managedRestoredDatabaseName,
    query: 'SELECT value FROM e2e_backup_probe',
    expected: 'before-backup',
  );
  await _openProjectTab(
    tester,
    'Database',
    find.byKey(const Key('database-type-postgres-tab')),
  );
  await _tap(tester, const Key('database-type-postgres-tab'));
  await _waitFor(
    tester,
    find.byKey(Key('database-resource-$restoredDatabaseName')),
    description: 'restored database in the local project catalog',
  );
  _pass(
    'Project Backup::Restore backup artifact',
    'Restored the B2 artifact into a new database, recovered the pre-change '
        'sentinel value, and recorded the restored database in the local '
        'project catalog.',
  );

  await _openProjectTab(
    tester,
    'Backup',
    find.byKey(const Key('backup-add-policy-button')),
  );

  final policyEditKey = _firstValueKeyStartingWith(
    tester,
    'backup-policy-edit-',
  );
  await _tap(tester, policyEditKey);
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('backup-policy-retention-field')),
    '2',
    description: 'backup policy retention',
  );
  await _tap(tester, const Key('backup-policy-save-button'));
  await _waitFor(
    tester,
    find.text('Backup policy updated.'),
    description: 'updated backup policy',
    timeout: const Duration(minutes: 3),
  );
  _pass(
    'Project Backup::PostgreSQL backup policy create/edit/delete',
    'Created and edited the real PostgreSQL backup policy; deletion is verified during cleanup.',
  );

  final destinationEditKey = _firstValueKeyStartingWith(
    tester,
    'backup-destination-edit-',
  );
  await _tap(tester, destinationEditKey);
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('backup-destination-secret-key-field')),
    'invalid-e2e-secret',
    description: 'invalid B2 secret fixture',
  );
  await _tap(tester, const Key('backup-destination-save-button'));
  await _tap(tester, policyRunKey);
  await _waitFor(
    tester,
    find.text('Run backup failed'),
    description: 'visible B2 backup failure',
    timeout: const Duration(minutes: 4),
  );
  await _tapFinder(
    tester,
    find.widgetWithText(TextButton, 'OK'),
    description: 'acknowledge failed B2 backup',
  );
  _pass(
    'Project Backup::Backup failure surfacing',
    'Invalid B2 credentials produced an acknowledged workspace error instead of a false success.',
  );

  final policyDeleteKey = _firstValueKeyStartingWith(
    tester,
    'backup-policy-delete-',
  );
  await _tap(tester, policyDeleteKey);
  await _waitFor(
    tester,
    find.text('Backup policy deleted.'),
    description: 'deleted backup policy',
    timeout: const Duration(minutes: 3),
  );
  final destinationDeleteKey = _firstValueKeyStartingWith(
    tester,
    'backup-destination-delete-',
  );
  await _tap(tester, destinationDeleteKey);
  await _waitFor(
    tester,
    find.text('Backup destination deleted.'),
    description: 'deleted backup destination',
  );
  _pass(
    'Project Backup::Backup destination edit/delete',
    'Edited and removed the disposable B2 destination after completing recovery checks.',
  );

  await _openProjectTab(
    tester,
    'Database',
    find.byKey(const Key('database-type-postgres-tab')),
  );
  await _tap(tester, const Key('database-type-postgres-tab'));
  await _tap(tester, Key('database-user-delete-$username'));
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Delete'),
    description: 'confirm database user deletion',
  );
  await _waitFor(
    tester,
    find.text('Database user removed.'),
    description: 'completed PostgreSQL user deletion',
    timeout: const Duration(minutes: 3),
  );
  await _verifyPostgresQuery(
    databaseName: 'postgres',
    query: "SELECT count(*) FROM pg_roles WHERE rolname='$managedUsername'",
    expected: '0',
  );
  _pass(
    'Project Database::PostgreSQL delete user',
    'Deleted the managed login and confirmed the remote PostgreSQL role is absent.',
  );

  await _tap(tester, Key('database-resource-$restoredDatabaseName'));
  await _tap(tester, const Key('database-delete-button'));
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Delete'),
    description: 'confirm restored PostgreSQL database deletion',
  );
  await _waitForAbsent(
    tester,
    find.byKey(Key('database-resource-$restoredDatabaseName')),
    description: 'removed restored database from the local project catalog',
    timeout: const Duration(minutes: 4),
  );
  await _verifyPostgresQuery(
    databaseName: 'postgres',
    query:
        "SELECT count(*) FROM pg_database WHERE datname='$managedRestoredDatabaseName'",
    expected: '0',
  );

  await _tap(tester, Key('database-resource-$databaseName'));
  await _tap(tester, const Key('database-delete-button'));
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Delete'),
    description: 'confirm PostgreSQL database deletion',
  );
  await _waitForAbsent(
    tester,
    find.byKey(Key('database-resource-$databaseName')),
    description: 'removed source database from the local project catalog',
    timeout: const Duration(minutes: 4),
  );
  await _verifyPostgresQuery(
    databaseName: 'postgres',
    query:
        "SELECT count(*) FROM pg_database WHERE datname='$managedDatabaseName'",
    expected: '0',
  );
  _pass(
    'Project Database::PostgreSQL delete database',
    'Deleted both the restored and source databases through the project '
        'workspace and confirmed they are absent from PostgreSQL.',
  );
}

String _requiredE2eEnvironment(String name) {
  final value = Platform.environment[name]?.trim() ?? '';
  if (value.isEmpty) {
    fail('$name is required for this production-safety E2E scenario.');
  }
  return value;
}

Future<void> _ensurePostgresServiceEnabled(WidgetTester tester) async {
  stdout.writeln('DEPLOYDASH_E2E_POSTGRES_SETUP=opening-home');
  await _openHome(tester);
  stdout.writeln('DEPLOYDASH_E2E_POSTGRES_SETUP=opening-server-management');
  await _openServerManagementFromHome(tester);
  stdout.writeln('DEPLOYDASH_E2E_POSTGRES_SETUP=opening-services');
  await _tap(tester, const Key('server-management-nav-services'));
  await _waitFor(
    tester,
    find.byKey(const Key('server-management-services-tab')),
    description: 'server services',
    timeout: const Duration(minutes: 2),
  );
  final servicesTab = find.byKey(const Key('server-management-services-tab'));
  final databaseRow = find.byKey(const Key('service-row-database'));
  final enableButton = find.byKey(const Key('service-enable-database'));
  final startButton = find.byKey(const Key('service-start-stop-database'));
  stdout.writeln('DEPLOYDASH_E2E_POSTGRES_SETUP=revealing-control');
  await _revealDatabaseServiceControl(
    tester,
    servicesTab: servicesTab,
    databaseRow: databaseRow,
    enableButton: enableButton,
  );
  stdout.writeln('DEPLOYDASH_E2E_POSTGRES_SETUP=control-revealed');
  final deadline = DateTime.now().add(const Duration(minutes: 15));
  var enableRequested = false;
  var startRequested = false;

  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));

    if (databaseRow.evaluate().isEmpty) {
      if (!enableRequested &&
          enableButton.evaluate().isNotEmpty &&
          _buttonIsEnabled(tester, enableButton)) {
        await _tapFinder(
          tester,
          enableButton,
          description: 'enable PostgreSQL action',
        );
        await _waitFor(
          tester,
          find.byKey(const Key('service-config-dialog-database')),
          description: 'enable PostgreSQL dialog',
        );
        await _tapFinder(
          tester,
          find.descendant(
            of: find.byKey(const Key('service-config-dialog-database')),
            matching: find.widgetWithText(FilledButton, 'Enable'),
          ),
          description: 'enable PostgreSQL service',
        );
        enableRequested = true;
        stdout.writeln('DEPLOYDASH_E2E_POSTGRES_SETUP=enable-requested');
      }
    } else {
      final readyStatus = find.descendant(
        of: databaseRow,
        matching: find.text('Ready'),
      );
      if (readyStatus.evaluate().isNotEmpty) {
        break;
      }
      if (!startRequested &&
          startButton.evaluate().isNotEmpty &&
          _buttonIsEnabled(tester, startButton)) {
        await _tapFinder(
          tester,
          startButton,
          description: 'start configured PostgreSQL service',
        );
        startRequested = true;
        stdout.writeln('DEPLOYDASH_E2E_POSTGRES_SETUP=start-requested');
      }
    }

    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  final readyStatus = find.descendant(
    of: databaseRow,
    matching: find.text('Ready'),
  );
  if (readyStatus.evaluate().isEmpty) {
    final visibleText = find
        .byType(Text)
        .evaluate()
        .map((element) {
          final widget = element.widget as Text;
          return widget.data ?? widget.textSpan?.toPlainText() ?? '';
        })
        .where((value) => value.trim().isNotEmpty)
        .take(80)
        .join(' | ');
    fail(
      'PostgreSQL did not reach Ready while ensuring the backup baseline.\n'
      'Visible text: ${redactE2eDiagnosticText(visibleText)}',
    );
  }
  await _runRequiredVmScript(
    'docker inspect -f "{{.State.Running}}" deploydash_postgres | grep -Fx true\n'
    'docker exec deploydash_postgres pg_isready -U deploydash -d postgres',
    description: 'PostgreSQL service readiness',
    timeout: const Duration(minutes: 2),
    sudo: true,
  );
  stdout.writeln('DEPLOYDASH_E2E_POSTGRES_SETUP=ready');
}

Future<void> _fillS3DestinationDialog(
  WidgetTester tester, {
  required String name,
  required String bucket,
  required String accessKey,
  required String secretKey,
  required String region,
  required String endpoint,
}) async {
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('backup-destination-name-field')),
    name,
    description: 'backup destination name',
  );
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('backup-destination-bucket-field')),
    bucket,
    description: 'B2 bucket',
  );
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('backup-destination-access-key-field')),
    accessKey,
    description: 'B2 access key',
  );
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('backup-destination-secret-key-field')),
    secretKey,
    description: 'B2 secret key',
  );
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('backup-destination-region-field')),
    region,
    description: 'B2 region',
  );
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('backup-destination-endpoint-field')),
    endpoint,
    description: 'B2 endpoint',
  );
  await _tap(tester, const Key('backup-destination-path-style-toggle'));
}

Key _firstValueKeyStartingWith(WidgetTester tester, String prefix) {
  for (final widget in tester.allWidgets) {
    final key = widget.key;
    if (key is ValueKey<String> && key.value.startsWith(prefix)) {
      return key;
    }
  }
  fail('No visible widget key starts with $prefix.');
}

enum _ManagedPostgresObjectKind { database, role }

Future<String> _findManagedPostgresObjectName({
  required _ManagedPostgresObjectKind kind,
  required String requestedName,
}) async {
  final normalizedRequestedName = requestedName.trim();
  expect(normalizedRequestedName, matches(RegExp(r'^[a-z0-9_]+$')));
  final identifierColumn = switch (kind) {
    _ManagedPostgresObjectKind.database => 'datname',
    _ManagedPostgresObjectKind.role => 'rolname',
  };
  final source = switch (kind) {
    _ManagedPostgresObjectKind.database => 'pg_database',
    _ManagedPostgresObjectKind.role => 'pg_roles',
  };
  final query =
      "SELECT $identifierColumn FROM $source "
      "WHERE right($identifierColumn, ${normalizedRequestedName.length}) "
      "= '$normalizedRequestedName' ORDER BY $identifierColumn;";
  final result = await _runRequiredVmScript(
    'docker exec deploydash_postgres psql -U deploydash -d postgres -Atc '
    '"\$QUERY"',
    description: 'managed PostgreSQL ${kind.name} discovery',
    environment: <String, String>{'QUERY': query},
    sudo: true,
  );
  final objectNames = result.stdout
      .toString()
      .split(RegExp(r'\r?\n'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  expect(
    objectNames,
    hasLength(1),
    reason:
        'Expected one managed PostgreSQL ${kind.name} ending in '
        '$normalizedRequestedName.',
  );
  expect(objectNames.single, startsWith('dd_'));
  return objectNames.single;
}

Future<void> _verifyPostgresQuery({
  required String databaseName,
  required String query,
  required String expected,
}) async {
  final result = await _runRequiredVmScript(
    'docker exec deploydash_postgres psql -U deploydash -d "\$DATABASE" '
    '-Atc "\$QUERY"',
    description: 'PostgreSQL query verification',
    environment: <String, String>{'DATABASE': databaseName, 'QUERY': query},
    sudo: true,
  );
  expect(result.stdout.toString().trim(), expected);
}

Future<void> _verifyPostgresCommand({
  required String databaseName,
  required String sql,
}) async {
  await _runRequiredVmScript(
    'docker exec deploydash_postgres psql -v ON_ERROR_STOP=1 -U deploydash '
    '-d "\$DATABASE" -c "\$SQL"',
    description: 'PostgreSQL mutation fixture',
    environment: <String, String>{'DATABASE': databaseName, 'SQL': sql},
    sudo: true,
  );
}
