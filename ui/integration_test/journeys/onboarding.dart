part of '../e2e_checklist_test.dart';

Future<void> _completeFreshServerOnboarding(WidgetTester tester) async {
  // Fresh installs open on onboarding: the intro is the first surface, and
  // the database does not exist until enrollment at Finish below.
  await _openFirstRunOnboarding(tester);
  _pass('Core App Shell::First launch with isolated profile');
  await _reachConfirmationGreen(tester);
  if (_crashBeforeFinishE2e) {
    await _restartAppForCrashInjection(tester);
    // No database was created: the restart lands on the onboarding intro,
    // never on the unlock prompt.
    await _waitFor(
      tester,
      find.byKey(const Key('server-onboarding-start-button')),
      description: 'onboarding intro after pre-finish restart',
    );
    expect(find.text('Unlock app'), findsNothing);
    // Compatibility checks are read-only: provisioning never started, so
    // the managed tree must not exist on the server.
    await _runRequiredVmScript(
      '[ ! -e /opt/deploydash ]',
      description: 'server untouched before Finish',
    );
    _pass(
      'Server Onboarding::Quit before finish leaves no database',
      'Restarting before Finish reopens the onboarding intro with no '
          'database and no managed tree on the server.',
    );
    await _openFirstRunOnboarding(tester);
    await _reachConfirmationGreen(tester);
  }
  await _enrollThroughModal(tester);
  await _waitForSetupStart(tester);
  if (_crashMidSetupE2e) {
    await _restartAppForCrashInjection(tester);
    // Enrollment persisted: the restart lands on unlock, not onboarding.
    await _waitFor(
      tester,
      find.text('Unlock app'),
      description: 'unlock prompt after mid-setup restart',
    );
    await _unlockLocalDatabase(tester);
    await _waitForHome(tester);
    _pass(
      'Server Onboarding::Crash mid-setup resumes from unlock',
      'Restarting mid-setup unlocks the enrolled install onto Home with '
          'the incomplete server awaiting retry.',
    );
    await _openServerManagementFromHome(tester);
    await _waitFor(
      tester,
      find.byKey(const Key('server-management-retry-setup-button')),
      description: 'retry setup for the incomplete server',
    );
    await _tap(tester, const Key('server-management-retry-setup-button'));
    await _waitForSetupStart(tester);
  }
  await _waitForSetupCompletion(tester);
  if (_crashMidSetupE2e) {
    _pass(
      'Server Onboarding::Retry completes interrupted setup',
      'The incomplete server finished provisioning after retry.',
    );
  }
}

/// Fills the password-server form, runs the compatibility check, and waits
/// for the confirmation-green review. Leaves the wizard paused at Finish.
Future<void> _reachConfirmationGreen(WidgetTester tester) async {
  await _fillPasswordServerDetails(tester);
  await _tap(tester, const Key('server-check-button'));

  await _waitFor(
    tester,
    find.byKey(const Key('server-save-button')),
    description: 'server compatibility review',
    timeout: const Duration(minutes: 4),
  );
  expect(find.byKey(const Key('server-compatibility-summary')), findsOne);
  await _waitForEnabledFilledButton(
    tester,
    const Key('server-save-button'),
    blockingReasonKeyName: 'server-save-blocked-compatibility',
    description: 'enabled finish setup button',
  );
  _pass('Server Onboarding::Password-based SSH connection check');
  _pass('Server Onboarding::Compatibility review screen');
  _pass(
    'Remote Server Stack Verification::Ubuntu package reachability preflight',
  );
}

/// Taps Finish setup, fills the create-password modal it opens, and
/// submits it, which enrolls and provisions.
Future<void> _enrollThroughModal(
  WidgetTester tester, {
  String passphrase = _databasePassphrase,
}) async {
  await _tap(tester, const Key('server-save-button'));
  await _waitFor(
    tester,
    find.text('Create password and finish setup'),
    description: 'create-password modal',
  );
  final confirmField = find.byKey(
    const Key('database-confirm-passphrase-field'),
  );
  await _waitFor(
    tester,
    confirmField,
    description: 'enrollment passphrase confirmation',
  );
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('database-passphrase-field')),
    passphrase,
    description: 'enrollment passphrase',
  );
  await _enterAndVerifyText(
    tester,
    confirmField,
    passphrase,
    description: 'enrollment passphrase confirmation',
  );
  await _tap(tester, const Key('enrollment-submit-button'));
}

/// Restarts the app the way the existing recovery journeys do: drops the
/// widget tree and pumps a fresh root over the same profile directory.
Future<void> _restartAppForCrashInjection(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await tester.pumpWidget(_buildE2eRootApp());
}

Future<void> _waitForSetupStart(WidgetTester tester) async {
  final setupStartOutcome = await _waitForAny(
    tester,
    <String, Finder>{
      'progress': find.byKey(const Key('server-setup-progress-card')),
      'blocked': find.byKey(const Key('server-save-blocked-compatibility')),
      'failure': find.byKey(const Key('server-setup-failure-message')),
      'enroll_error': find.byKey(const Key('database-passphrase-error')),
    },
    description: 'setup progress card',
    timeout: const Duration(seconds: 20),
  );
  if (setupStartOutcome == 'blocked') {
    fail(_readWidgetText(tester, 'server-save-blocked-compatibility'));
  }
  if (setupStartOutcome == 'failure') {
    fail(_readSetupFailureDetails(tester));
  }
  if (setupStartOutcome == 'enroll_error') {
    fail(_readWidgetText(tester, 'database-passphrase-error'));
  }
  _pass('Server Onboarding::Long-running setup progress');
}

Future<void> _waitForSetupCompletion(WidgetTester tester) async {
  final setupOutcome = await _waitForAny(
    tester,
    <String, Finder>{
      'services': find.byKey(const Key('services-selection-continue-button')),
      'home': find.byKey(const Key('home-overview-panel')),
      'failure': find.byKey(const Key('server-setup-failure-message')),
    },
    description: 'setup completion',
    timeout: const Duration(minutes: 45),
  );

  if (setupOutcome == 'failure') {
    fail(_readSetupFailureDetails(tester));
  }

  _pass('Server Onboarding::Successful baseline setup');
  _pass('Remote Server Stack Verification::Docker install via setup');
  _pass('Remote Server Stack Verification::Railpack install via setup');

  if (setupOutcome == 'services') {
    expect(find.byKey(const Key('service-toggle-databases')), findsOne);
    _pass('Server Onboarding::Service selection during onboarding');
    _pass('Server Onboarding::Onboarding with optional services disabled');
    _pass('Server Onboarding::Onboarding on Ubuntu 24.04');
    await _tap(tester, const Key('services-selection-continue-button'));
    await _waitFor(
      tester,
      find.byKey(const Key('server-management-nav-overview')),
      description: 'server management after service selection',
    );
    await _openHome(tester);
  } else {
    await _waitForHome(tester);
  }
}

/// Unlocks the existing local database after a restart. Creation never
/// happens here: fresh installs onboard first and enroll on the review
/// screen, so by the time any journey restarts, a database exists.
Future<void> _unlockLocalDatabase(
  WidgetTester tester, {
  String passphrase = _databasePassphrase,
}) async {
  await _waitFor(
    tester,
    find.text('Unlock app'),
    description: 'settled database startup mode',
  );
  final passphraseField = find.byKey(const Key('database-passphrase-field'));
  await _enterAndVerifyText(
    tester,
    passphraseField,
    passphrase,
    description: 'database passphrase',
  );
  await _tap(tester, const Key('database-passphrase-submit'));
  final outcome = await _waitForAny(tester, <String, Finder>{
    'onboarding': find.byKey(const Key('server-onboarding-start-button')),
    'home': find.byKey(const Key('home-overview-panel')),
    'server_details': find.byKey(const Key('server-name-field')),
    'database_error': find.byKey(const Key('database-passphrase-error')),
  }, description: 'unlocked app workspace');
  if (outcome == 'database_error') {
    final summary = _readWidgetText(tester, 'database-passphrase-error');
    final detailsTile = find.byKey(
      const Key('database-creation-failure-details'),
    );
    var details = 'Technical details were not available.';
    if (detailsTile.evaluate().isNotEmpty) {
      await tester.tap(detailsTile);
      await tester.pumpAndSettle();
      final detailsText = find.descendant(
        of: detailsTile,
        matching: find.byType(SelectableText),
      );
      if (detailsText.evaluate().isNotEmpty) {
        details = tester.widget<SelectableText>(detailsText).data ?? details;
      }
    }
    fail('$summary\nTechnical details: $details');
  }
}

Future<void> _enterAndVerifyText(
  WidgetTester tester,
  Finder finder,
  String value, {
  required String description,
}) async {
  await _waitFor(tester, finder, description: description);
  await tester.tap(finder);
  await tester.pump();
  await tester.enterText(finder, value);
  await tester.pump();
  final editableText = find.descendant(
    of: finder,
    matching: find.byType(EditableText),
  );
  expect(
    editableText,
    findsOneWidget,
    reason: 'The E2E driver could not inspect $description.',
  );
  final field = tester.widget<EditableText>(editableText);
  expect(
    field.controller.text,
    value,
    reason: 'The E2E driver could not enter $description.',
  );
}

Future<void> _openFirstRunOnboarding(WidgetTester tester) async {
  final startButton = find.byKey(const Key('server-onboarding-start-button'));
  if (startButton.evaluate().isNotEmpty) {
    await _tap(tester, const Key('server-onboarding-start-button'));
  }
  await _waitFor(
    tester,
    find.byKey(const Key('server-name-field')),
    description: 'server details form',
  );
}

Future<void> _fillPasswordServerDetails(WidgetTester tester) async {
  // Tap-then-verify every field like _enterAndVerifyText: raw enterText can
  // silently miss an unfocused field (seen on macOS), leaving placeholders
  // behind and failing much later at the compatibility review.
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('server-name-field')),
    'E2E fresh VM',
    description: 'server name',
  );
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('server-host-field')),
    _vmHost,
    description: 'server host',
  );
  if (_vmPort != 22) {
    await _enterAndVerifyText(
      tester,
      find.byKey(const Key('server-port-field')),
      '$_vmPort',
      description: 'server port',
    );
  }
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('server-user-field')),
    _vmUser,
    description: 'server username',
  );
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('server-password-field')),
    _vmPassword,
    description: 'server password',
  );
  await tester.pump();
}

Future<void> _waitForHome(WidgetTester tester) async {
  await _waitFor(
    tester,
    find.byKey(const Key('home-overview-panel')),
    description: 'Home dashboard',
  );
}
