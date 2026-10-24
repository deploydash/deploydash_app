part of '../e2e_checklist_test.dart';

// workers-add-button opens the worker editor dialog via a plain showDialog
// call with no other confirmable state change first -- same shape as
// scheduler-add-task-button. Confirm the editor actually opened and retry
// rather than trust one dispatched tap.
Future<void> _tapWorkersAddAndConfirmOpened(WidgetTester tester) async {
  final addButton = find.byKey(const Key('workers-add-button'));
  final nameField = find.byKey(const Key('workers-editor-name-field'));
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(tester, addButton, description: 'Add worker');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (nameField.evaluate().isNotEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail('Tapping Add worker never opened the worker editor.');
}

// TerminalBottomSheet (the "Advanced activity" panel) can re-expand itself
// mid-sequence whenever a new background task starts tracking, shifting the
// whole "Web app" tab's layout in real time since this journey drives a
// live app process, not a fake-clock widget test -- a plain tap can land
// just after the run button moved. Confirm the app actually registered the
// tap (the button's own label flips to "Cancel running command") instead of
// trusting a single dispatched tap and waiting minutes to find out it
// silently missed.
Future<void> _tapOneOffRunButtonAndConfirmStarted(WidgetTester tester) async {
  final runButton = find.byKey(const Key('app-oneoff-run-button'));
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(tester, runButton, description: 'run one-off command');
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('Cancel running command').evaluate().isNotEmpty) {
        return;
      }
    }
  }
  fail('Tapping Run command never started the one-off command.');
}

// _cancelOneOffCommand sets app-oneoff-status-text to 'Cancellation
// requested...' synchronously, in the same setState call that requests the
// cancellation, before any backend round-trip -- a fast, purely
// client-side signal a missed tap would skip, leaving the command still
// "running" and the caller's 2-minute wait for a 'cancel' status timing
// out even though the command may still be running.
Future<void> _tapOneOffCancelButtonAndConfirmStarted(
  WidgetTester tester,
) async {
  final cancelButton = find.byKey(const Key('app-oneoff-run-button'));
  final statusText = find.byKey(const Key('app-oneoff-status-text'));
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(
      tester,
      cancelButton,
      description: 'cancel one-off command',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (statusText.evaluate().isNotEmpty &&
          _readVisibleText(
            tester,
            statusText,
          ).toLowerCase().contains('cancel')) {
        return;
      }
    }
  }
  fail('Tapping Cancel running command never requested a cancellation.');
}

// workers-apply-runtime-button's onPressed becomes null while _isApplying
// (workers_tab.dart), matching system-apply-button's pattern -- a fast,
// purely client-side signal a missed tap would skip, leaving the button
// enabled and the caller's long wait for "Worker runtime applied" timing
// out with nothing having happened server-side.
Future<void> _tapWorkersApplyAndConfirmStarted(WidgetTester tester) async {
  final applyButton = find.byKey(const Key('workers-apply-runtime-button'));
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(tester, applyButton, description: 'apply workers runtime');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (applyButton.evaluate().isEmpty ||
          !_buttonIsEnabled(tester, applyButton)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail('Tapping Apply changes never started applying the workers runtime.');
}

// Restart/Stop/Start worker's onPressed becomes null while the worker is
// busy (workers_tab.dart's _isWorkerBusy), the same fast client-side signal
// used above -- a missed tap here would leave the button enabled and the
// caller's long wait for a "Worker restarted/stopped/started" message
// timing out with nothing having happened.
Future<void> _tapWorkerActionAndConfirmStarted(
  WidgetTester tester, {
  required String tooltip,
}) async {
  // Not find.byTooltip: that matches the Tooltip wrapper widget, not the
  // IconButton itself, so _buttonIsEnabled's onPressed check below would
  // never see the real button. Match the IconButton directly by its
  // tooltip property instead.
  final actionButton = find
      .byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == tooltip,
      )
      .first;
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(tester, actionButton, description: tooltip);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (actionButton.evaluate().isEmpty ||
          !_buttonIsEnabled(tester, actionButton)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail('Tapping "$tooltip" never started the worker action.');
}

Future<void> _exerciseOneOffCommands(WidgetTester tester) async {
  await _expandProjectDisclosure(
    tester,
    disclosureKey: const Key('app-oneoff-command-card'),
    contentKey: const Key('app-oneoff-command-field'),
  );
  await tester.enterText(
    find.byKey(const Key('app-oneoff-command-field')),
    'php -v',
  );
  await tester.enterText(
    find.byKey(const Key('app-oneoff-timeout-field')),
    '120',
  );
  await _tapOneOffRunButtonAndConfirmStarted(tester);
  await _waitForKeyTextContains(
    tester,
    const Key('app-oneoff-output-text'),
    'PHP',
    description: 'one-off command PHP output',
    timeout: const Duration(minutes: 3),
  );
  await _waitForKeyTextContains(
    tester,
    const Key('app-oneoff-exit-code-text'),
    '0',
    description: 'one-off command exit code',
    timeout: const Duration(minutes: 1),
  );
  _pass('Project Web App::One-off command success');
  _pass('Project Web App::Resource usage refresh');

  await tester.enterText(
    find.byKey(const Key('app-oneoff-command-field')),
    "php -r \"fwrite(STDERR, 'e2e failure'); exit(7);\"",
  );
  await _tapOneOffRunButtonAndConfirmStarted(tester);
  await _waitForKeyTextContains(
    tester,
    const Key('app-oneoff-exit-code-text'),
    '7',
    description: 'one-off failure exit code',
    timeout: const Duration(minutes: 3),
  );
  _pass('Project Web App::One-off command failure');

  await tester.enterText(
    find.byKey(const Key('app-oneoff-command-field')),
    'sleep 60',
  );
  await _tapOneOffRunButtonAndConfirmStarted(tester);
  await _waitForKeyTextContains(
    tester,
    const Key('app-oneoff-status-text'),
    'running',
    description: 'running one-off command',
    timeout: const Duration(seconds: 30),
  );
  await _tapOneOffCancelButtonAndConfirmStarted(tester);
  await _waitForKeyTextContains(
    tester,
    const Key('app-oneoff-status-text'),
    'cancel',
    description: 'cancelled one-off command',
    timeout: const Duration(minutes: 2),
  );
  _pass('Project Web App::One-off command cancel');
}

Future<void> _exerciseWorkersAfterLiveRelease(
  WidgetTester tester, {
  required String projectName,
}) async {
  const workerId = 'e2e-worker';
  final projectSlug = _e2eProjectSlug(projectName);
  await _openProjectTab(
    tester,
    'Workers',
    find.byKey(const Key('workers-tab-scroll')),
  );
  await _deleteExistingE2eFixtures(
    tester,
    keyPrefix: 'worker-delete-e2e-worker',
    dialogTitle: 'Delete worker',
    description: 'existing E2E worker',
  );
  await _waitForEnabledButton(
    tester,
    const Key('workers-add-button'),
    description: 'enabled Add worker button',
  );
  _pass('Project Workers::Workers tab after live release');

  await tester.ensureVisible(find.byKey(const Key('workers-add-button')));
  await tester.pump();
  await _tapWorkersAddAndConfirmOpened(tester);
  _pass('Project Workers::Add worker modal');
  expect(
    find.byKey(const Key('workers-editor-db-password-field')),
    findsNothing,
  );
  _pass('Project Workers::Worker database-password field relevance');
  await tester.enterText(
    find.byKey(const Key('workers-editor-name-field')),
    'E2E Worker',
  );
  await tester.enterText(
    find.byKey(const Key('workers-editor-command-field')),
    'sleep 3600',
  );
  await _tap(tester, const Key('workers-editor-save-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('worker-row-$workerId')),
    description: 'created worker row',
  );
  _pass('Project Workers::Create worker');

  await _tapWorkersApplyAndConfirmStarted(tester);
  await _waitFor(
    tester,
    find.textContaining('Worker runtime applied').hitTestable(),
    description: 'worker runtime update result',
    timeout: const Duration(minutes: 5),
  );
  await _tap(tester, const Key('workers-refresh-status-button'));
  await _waitFor(
    tester,
    find.text('running').hitTestable(),
    description: 'worker running status',
    timeout: const Duration(minutes: 2),
  );
  await _verifyWorkerRuntimeInsideVm(
    projectSlug: projectSlug,
    workerId: workerId,
    expectedCommand: 'sleep 3600',
  );
  await _writeE2eScreenshot(tester, 'workers-runtime-live-verified');
  _pass('Project Workers::Apply worker runtime');
  _pass('Project Workers::Worker status refresh');

  await _tap(tester, Key('worker-edit-$workerId'));
  await _waitFor(
    tester,
    find.byKey(const Key('workers-editor-command-field')),
    description: 'edit worker dialog',
  );
  await tester.enterText(
    find.byKey(const Key('workers-editor-command-field')),
    'sleep 1800',
  );
  await _tap(tester, const Key('workers-editor-save-button'));
  await _waitFor(
    tester,
    find.text('sleep 1800'),
    description: 'edited worker command',
  );
  _pass('Project Workers::Edit worker');

  await _tapWorkersApplyAndConfirmStarted(tester);
  await _waitFor(
    tester,
    find.textContaining('Worker runtime applied').hitTestable(),
    description: 'worker runtime update result',
    timeout: const Duration(minutes: 5),
  );
  await _tap(tester, const Key('workers-refresh-status-button'));
  await _waitFor(
    tester,
    find.textContaining('running').hitTestable(),
    description: 'worker running status',
    timeout: const Duration(minutes: 2),
  );
  await _verifyWorkerRuntimeInsideVm(
    projectSlug: projectSlug,
    workerId: workerId,
    expectedCommand: 'sleep 1800',
  );

  await _tapWorkerActionAndConfirmStarted(tester, tooltip: 'Restart worker');
  await _waitFor(
    tester,
    find.textContaining('Worker restarted').hitTestable(),
    description: 'worker restarted',
    timeout: const Duration(minutes: 3),
  );
  await _tapWorkerActionAndConfirmStarted(tester, tooltip: 'Stop worker');
  await _waitFor(
    tester,
    find.textContaining('Worker stopped').hitTestable(),
    description: 'worker stopped',
    timeout: const Duration(minutes: 3),
  );
  await _tapWorkerActionAndConfirmStarted(tester, tooltip: 'Start worker');
  await _waitFor(
    tester,
    find.textContaining('Worker started').hitTestable(),
    description: 'worker started',
    timeout: const Duration(minutes: 3),
  );
  _pass('Project Workers::Worker start/stop/restart');

  await _tapFinder(
    tester,
    find.byTooltip('View worker activity').first,
    description: 'worker activity',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('workers-logs-refresh-button')),
    description: 'worker logs dialog',
    timeout: const Duration(minutes: 2),
  );
  await _tapFinder(
    tester,
    find.widgetWithText(TextButton, 'Close').last,
    description: 'close worker logs',
  );
  _pass('Project Workers::Worker logs');
}

Future<void> _deleteE2eWorker(WidgetTester tester) async {
  const workerId = 'e2e-worker';
  await _openProjectTab(
    tester,
    'Workers',
    find.byKey(const Key('workers-tab-scroll')),
  );
  await _tap(tester, Key('worker-delete-$workerId'));
  await _waitFor(
    tester,
    find.text('Delete worker'),
    description: 'delete worker dialog',
  );
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Delete').last,
    description: 'confirm delete worker',
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 500));
  _pass('Project Workers::Delete worker');
}
