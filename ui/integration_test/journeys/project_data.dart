part of '../e2e_checklist_test.dart';

// settings_tab.dart's _deleteProject resolves showDialog<bool> and closes
// settings-delete-confirm-dialog on tap, well before the actual backend
// delete starts -- a fast, purely client-side signal a missed tap would
// skip, leaving the dialog open and the caller's 2-minute wait for the Home
// notice timing out with nothing having happened.
Future<void> _tapProjectDeleteConfirmAndConfirmDialogClosed(
  WidgetTester tester,
) async {
  final dialog = find.byKey(const Key('settings-delete-confirm-dialog'));
  final confirmButton = find.byKey(const Key('settings-delete-confirm-button'));
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(
      tester,
      confirmButton,
      description: 'confirm project delete',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (dialog.evaluate().isEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail('Tapping Delete project never closed the confirmation dialog.');
}

Future<void> _exerciseWorkersBeforeLiveRelease(WidgetTester tester) async {
  await _openProjectTab(
    tester,
    'Workers',
    find.byKey(const Key('workers-tab-scroll')),
  );
  expect(
    find.byKey(const Key('workers-app-runtime-required-callout')),
    findsOneWidget,
  );
  // Not OutlinedButton: a67a6b2 (2026-08-05) made "Add worker" the primary
  // action for this empty state, per AGENTS.md's one-filled-primary-action
  // rule, well before this branch existed.
  final addButton = tester.widget<FilledButton>(
    find.byKey(const Key('workers-add-button')),
  );
  expect(addButton.onPressed, isNull);
  _pass('Project Workers::Workers tab before live release');
}

Future<void> _exerciseDatabaseSurfaces(
  WidgetTester tester, {
  required String projectName,
}) async {
  await _openProjectTab(
    tester,
    'Database',
    find.byKey(const Key('database-tab-scroll')),
  );
  await _tap(tester, const Key('database-type-postgres-tab'));
  await _waitFor(
    tester,
    find.byKey(const Key('database-managed-service-state-card')),
    description: 'disabled PostgreSQL service card',
  );
  _pass('Project Database::Database tab with PostgreSQL disabled');

  await _tap(tester, const Key('database-open-server-services-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('server-management-services-tab')),
    description: 'server services tab from database',
  );
  _pass('Project Database::Open server services action');
  await _openProjectFromRail(tester, projectName);
  await _openProjectTab(
    tester,
    'Database',
    find.byKey(const Key('database-tab-scroll')),
  );
  await _exerciseSqliteDatabaseStorage(tester);
}

Future<void> _exerciseSqliteDatabaseStorage(WidgetTester tester) async {
  await _waitFor(
    tester,
    find.byKey(const Key('database-sqlite-card')),
    description: 'SQLite database card',
  );
  await _createSqliteDatabase(tester, name: 'primary');
  _pass('Project Database::SQLite create database storage');
  await _createSqliteDatabase(tester, name: 'secondary');

  await _tapFinder(
    tester,
    find.widgetWithText(OutlinedButton, 'Set primary').last,
    description: 'Set primary SQLite database',
  );
  await tester.pumpAndSettle();
  _pass('Project Database::SQLite set primary');

  // Not OutlinedButton with visible text: a67a6b2 (2026-08-05) made both the
  // refresh and delete SQLite-storage actions icon-only IconButton.outlined
  // controls with a per-database key and a tooltip carrying the verb,
  // matching AGENTS.md's rule that row-level quick actions default to
  // icon-only. Located by key prefix since the id is generated per database.
  await _tapFinder(
    tester,
    find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('database-sqlite-refresh-');
    }).first,
    description: 'Refresh SQLite storage',
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 500));
  _pass('Project Database::SQLite refresh storage usage');

  await _tapFinder(
    tester,
    find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('database-sqlite-delete-');
    }).last,
    description: 'Delete SQLite database',
  );
  await _waitFor(
    tester,
    find.text('Delete SQLite database'),
    description: 'SQLite delete confirmation',
  );
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Delete').last,
    description: 'Confirm SQLite delete',
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 500));
  _pass('Project Database::SQLite delete database storage');
}

Future<void> _createSqliteDatabase(
  WidgetTester tester, {
  required String name,
}) async {
  await _waitForEnabledButton(
    tester,
    const Key('database-sqlite-create-button'),
    description: 'Create SQLite DB button',
  );
  await _tap(tester, const Key('database-sqlite-create-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('database-sqlite-name-field')),
    description: 'SQLite create dialog',
  );
  await tester.enterText(
    find.byKey(const Key('database-sqlite-name-field')),
    name,
  );
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Create').last,
    description: 'Create SQLite database',
  );
  await _waitFor(
    tester,
    find.text(name),
    description: 'created SQLite database $name',
    timeout: const Duration(minutes: 2),
  );
  await _waitForEnabledButton(
    tester,
    const Key('database-sqlite-create-button'),
    description: 'Create SQLite DB button ready',
    timeout: const Duration(minutes: 3),
  );
}

Future<void> _exerciseBackupUnavailable(WidgetTester tester) async {
  await _openProjectTab(
    tester,
    'Backup',
    find.byKey(const Key('backup-service-disabled-message')),
  );
  expect(
    find.byKey(const Key('backup-open-server-services-button')),
    findsOneWidget,
  );
  _pass('Project Backup::Backup tab with PostgreSQL unavailable');
}

Future<void> _exerciseSchedulerBeforeLiveRelease(WidgetTester tester) async {
  await _openProjectTab(
    tester,
    'Scheduler',
    find.byKey(const Key('scheduler-app-runtime-required-callout')),
  );
  final addButton = tester.widget<FilledButton>(
    find.byKey(const Key('scheduler-add-task-button')),
  );
  expect(addButton.onPressed, isNull);
  _pass('Project Scheduler::Scheduler before live release');
}

Future<void> _exerciseLogSurfaces(WidgetTester tester) async {
  await _openProjectTab(tester, 'Log', find.byKey(const Key('app-log-card')));
  await _tap(tester, const Key('log-runtime-tab'));
  await tester.pumpAndSettle();
  await _waitFor(
    tester,
    find.byKey(const Key('log-filter-field')),
    description: 'runtime log filter',
  );
  // log_tab.dart's runtime-logs empty state has read 'No runtime logs yet'
  // (no trailing period) since a67a6b2 (2026-08-05).
  expect(find.text('No runtime logs yet'), findsOneWidget);
  _pass('Project Logs::Runtime logs empty-app-output state');

  await _tap(tester, const Key('log-runtime-stream-switch'));
  expect(
    tester
        .widget<Switch>(find.byKey(const Key('log-runtime-stream-switch')))
        .value,
    isTrue,
  );
  await _tap(tester, const Key('log-runtime-stream-switch'));
  await _waitFor(
    tester,
    find.textContaining('Runtime log streaming paused'),
    description: 'runtime log streaming paused status',
  );
  _pass('Project Logs::Runtime live stream toggle');

  await _tap(tester, const Key('log-deployment-tab'));
  await tester.pumpAndSettle();
  await _waitFor(
    tester,
    find.byKey(const Key('deployment-log-filter-field')),
    description: 'deployment log filter',
  );
  await tester.enterText(
    find.byKey(const Key('deployment-log-filter-field')),
    'e2e',
  );
  await tester.pump();
  _pass('Project Logs::Deployment log filtering');
}

Future<void> _exerciseEmailDomainAndSettings(WidgetTester tester) async {
  // Not an "enable services" button: Email and Domain are navigation
  // placeholders, not shipped features (AGENTS.md). email_domain_tabs.dart
  // renders AppEmptyStateView 'not available yet' states for both, and has
  // done so since a67a6b2 (2026-08-05) removed 568 lines of the pre-existing
  // implementation these keys targeted.
  await _openProjectTab(
    tester,
    'Email',
    find.byKey(const Key('email-unavailable-state')),
  );
  _pass('Project Email, Domain, And Settings::Email tab');

  await _openProjectTab(
    tester,
    'Domain',
    find.byKey(const Key('domain-unavailable-state')),
  );
  _pass('Project Email, Domain, And Settings::Domain tab');

  await _openProjectTab(
    tester,
    'Settings',
    find.byKey(const Key('settings-delete-button')),
  );
  _pass('Project Email, Domain, And Settings::Project Settings tab viewed');
}

Future<void> _deleteCurrentProject(
  WidgetTester tester,
  String projectName,
) async {
  await _openProjectTab(
    tester,
    'Settings',
    find.byKey(const Key('settings-delete-button')),
  );
  await _tap(tester, const Key('settings-delete-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('settings-delete-confirm-input')),
    description: 'project delete confirmation',
  );
  await tester.enterText(
    find.byKey(const Key('settings-delete-confirm-input')),
    projectName,
  );
  await _tap(tester, const Key('settings-delete-confirm-checkbox'));
  await _waitForEnabledButton(
    tester,
    const Key('settings-delete-confirm-button'),
    description: 'confirm project delete button',
  );
  await _tapProjectDeleteConfirmAndConfirmDialogClosed(tester);
  await _waitFor(
    tester,
    find.byKey(const Key('home-delete-notice-card')),
    description: 'project deleted Home notice',
    timeout: const Duration(minutes: 2),
  );
}

Future<void> _dismissDeleteNoticeIfVisible(WidgetTester tester) async {
  final dismiss = find.byKey(const Key('home-delete-notice-dismiss-button'));
  if (dismiss.evaluate().isEmpty) {
    return;
  }
  await _tap(tester, const Key('home-delete-notice-dismiss-button'));
  await tester.pumpAndSettle();
}
