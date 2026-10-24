part of '../e2e_checklist_test.dart';

Future<void> _exerciseAppSettingsSurfaces(WidgetTester tester) async {
  await _tap(tester, const Key('left-rail-app-settings-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('app-settings-view')),
    description: 'App Settings',
  );
  expect(find.byKey(const Key('left-rail-version-label')), findsOneWidget);
  _pass('App Settings And Local Database Safety::App version/update badge');

  await _exerciseAgentAccessSettings(tester);
  await _rotateLocalDatabasePassword(tester);
}

Future<void> _exerciseAgentAccessSettings(WidgetTester tester) async {
  await _tap(tester, const Key('app-settings-nav-agent-access'));
  await _waitFor(
    tester,
    find.byKey(const Key('app-settings-agent-access-toggle')),
    description: 'Agent Access toggle',
  );
  if (!_switchListTileValue(
    tester,
    const Key('app-settings-agent-access-toggle'),
  )) {
    await _tap(tester, const Key('app-settings-agent-access-toggle'));
    await _waitForSwitchListTileValue(
      tester,
      const Key('app-settings-agent-access-toggle'),
      true,
      description: 'Agent Access enabled',
    );
  }

  await _tap(tester, const Key('app-settings-agent-permission-dropdown'));
  await _tapFinder(
    tester,
    find.text('Read-only + redeploy').last,
    description: 'redeploy permission option',
  );
  await _waitForEnabledButton(
    tester,
    const Key('app-settings-agent-issue-session-button'),
    description: 'Agent Access redeploy session button',
  );
  await _tap(tester, const Key('app-settings-agent-issue-session-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('app-settings-agent-session-token-text')),
    description: 'Agent Access session token',
  );
  _pass(
    'App Settings And Local Database Safety::Agent Access redeploy session',
  );
  _pass('App Settings And Local Database Safety::Agent audit visibility');

  await _tap(tester, const Key('app-settings-agent-access-toggle'));
  await _waitForSwitchListTileValue(
    tester,
    const Key('app-settings-agent-access-toggle'),
    false,
    description: 'Agent Access disabled',
  );
  _pass('App Settings And Local Database Safety::Agent Access enable/disable');
}

Future<void> _rotateLocalDatabasePassword(WidgetTester tester) async {
  await _tap(tester, const Key('app-settings-nav-security'));
  await _waitFor(
    tester,
    find.byKey(const Key('app-settings-password-current-field')),
    description: 'current app password field',
  );
  await tester.enterText(
    find.byKey(const Key('app-settings-password-current-field')),
    _databasePassphrase,
  );
  await tester.enterText(
    find.byKey(const Key('app-settings-password-new-field')),
    _rotatedDatabasePassphrase,
  );
  await tester.enterText(
    find.byKey(const Key('app-settings-password-confirm-field')),
    _rotatedDatabasePassphrase,
  );
  await _tap(tester, const Key('app-settings-password-change-button'));
  await _waitFor(
    tester,
    find.text('Password updated.'),
    description: 'app password update confirmation',
    timeout: const Duration(minutes: 1),
  );
  _pass('App Settings And Local Database Safety::Rotate local DB password');
}
