part of '../e2e_checklist_test.dart';

// scheduler-run-now-<id>'s onPressed becomes null while the task is busy
// (scheduler_tab.dart's taskBusy), the same fast client-side signal already
// used for workers/system-apply -- a missed tap here would leave the
// button enabled and the caller's multi-minute wait for a completion or
// failure message timing out with nothing having run.
Future<void> _tapSchedulerRunNowAndConfirmStarted(
  WidgetTester tester, {
  required String taskId,
}) async {
  final runButton = find.byKey(Key('scheduler-run-now-$taskId'));
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(tester, runButton, description: 'run scheduled job now');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (runButton.evaluate().isEmpty ||
          !_buttonIsEnabled(tester, runButton)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail('Tapping Run now never started the scheduled job.');
}

// scheduler-add-task-button opens the task editor dialog via a plain
// showDialog call with no other confirmable state change first -- the same
// unconfirmed-tap shape already fixed elsewhere in this journey, just not
// caught by the audit that found those because the default 30s _waitFor
// here happens to be under the 60s threshold that audit used to prioritize
// sites. It still genuinely missed on a live run. Confirm the editor
// actually opened and retry rather than trust one dispatched tap.
Future<void> _tapSchedulerAddTaskAndConfirmOpened(WidgetTester tester) async {
  final addButton = find.byKey(const Key('scheduler-add-task-button'));
  final nameField = find.byKey(const Key('scheduler-editor-name-field'));
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(tester, addButton, description: 'Add scheduled job');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (nameField.evaluate().isNotEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail('Tapping Add scheduled job never opened the task editor.');
}

Future<void> _exerciseSchedulerAfterLiveRelease(
  WidgetTester tester, {
  required String projectName,
}) async {
  const taskId = 'e2e-php-version';
  const failureTaskId = 'e2e-failure';
  const workerTaskId = 'e2e-worker-job';
  final projectSlug = _e2eProjectSlug(projectName);

  await _openProjectTab(
    tester,
    'Scheduler',
    find.byKey(const Key('scheduler-add-task-button')),
  );
  await _deleteExistingE2eFixtures(
    tester,
    keyPrefix: 'scheduler-delete-e2e-',
    dialogTitle: 'Delete scheduled job',
    description: 'existing E2E scheduled job',
  );
  await _waitForEnabledButton(
    tester,
    const Key('scheduler-add-task-button'),
    description: 'enabled scheduler add button',
  );
  _pass('Project Scheduler::Add scheduled job after live release');

  await _createSchedulerTask(
    tester,
    name: 'E2E PHP version',
    command: 'php -v',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('scheduler-run-now-$taskId')),
    description: 'created scheduler task',
  );
  _pass('Project Scheduler::Command persistence with arguments');
  await _installLegacySchedulerWrapperInsideVm(
    projectSlug: projectSlug,
    taskId: taskId,
  );

  await _tapSchedulerRunNowAndConfirmStarted(tester, taskId: taskId);
  await _waitFor(
    tester,
    find.textContaining('completed').hitTestable(),
    description: 'scheduler run completed',
    timeout: const Duration(minutes: 4),
  );
  await _waitFor(
    tester,
    find.textContaining('PHP ').hitTestable(),
    description: 'scheduler command output',
    timeout: const Duration(minutes: 2),
  );
  await _verifySchedulerWrapperRepairInsideVm(
    projectSlug: projectSlug,
    taskId: taskId,
  );
  await _writeE2eScreenshot(tester, 'scheduler-legacy-repair-completed');
  _pass('Project Scheduler::Legacy scheduler wrappers after app fixes');
  _pass('Project Scheduler::Run now for web-app job');

  await _waitForEnabledButton(
    tester,
    Key('scheduler-edit-$taskId'),
    description: 'enabled scheduler edit button after run completion',
    timeout: const Duration(minutes: 2),
  );
  await _tap(tester, Key('scheduler-edit-$taskId'));
  await _waitFor(
    tester,
    find.byKey(const Key('scheduler-editor-command-field')),
    description: 'scheduler editor',
  );
  await tester.enterText(
    find.byKey(const Key('scheduler-editor-command-field')),
    "php -r \"echo 'edited';\"",
  );
  await _tap(tester, const Key('scheduler-editor-save-button'));
  await _waitFor(
    tester,
    find.textContaining('edited'),
    description: 'edited scheduler command',
  );
  _pass('Project Scheduler::Edit scheduled job');

  await _tap(tester, Key('scheduler-task-enabled-$taskId'));
  await tester.pumpAndSettle(const Duration(milliseconds: 500));
  await _tap(tester, Key('scheduler-task-enabled-$taskId'));
  await tester.pumpAndSettle(const Duration(milliseconds: 500));
  _pass('Project Scheduler::Enable/disable scheduled job');

  await _tap(tester, const Key('scheduler-refresh-status-button'));
  await _waitFor(
    tester,
    find.textContaining('active').hitTestable(),
    description: 'scheduler status refresh',
    timeout: const Duration(minutes: 3),
  );
  _pass('Project Scheduler::Scheduler status refresh');
  _pass('Project Scheduler::Scheduler after redeploy');

  await _createSchedulerTask(
    tester,
    name: 'E2E Worker job',
    command: 'echo worker',
    targetWorker: true,
  );
  await _waitFor(
    tester,
    find.byKey(const Key('scheduler-run-now-$workerTaskId')),
    description: 'created worker-target scheduler task',
  );
  _pass('Project Scheduler::Scheduler worker target');

  await _createSchedulerTask(
    tester,
    name: 'E2E failure',
    command: "php -r \"fwrite(STDERR, 'scheduled failure'); exit(9);\"",
  );
  await _tapSchedulerRunNowAndConfirmStarted(tester, taskId: failureTaskId);
  await _waitFor(
    tester,
    find.text('Scheduled job did not start'),
    description: 'scheduler failure dialog',
    timeout: const Duration(minutes: 4),
  );
  await _waitFor(
    tester,
    find.textContaining('exit code 9').hitTestable(),
    description: 'scheduler failure exit code',
  );
  _pass('Project Scheduler::Scheduler failure details after latest fixes');
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'OK'),
    description: 'acknowledge expected scheduler failure',
  );

  await _deleteSchedulerTask(tester, workerTaskId);
  await _deleteSchedulerTask(tester, failureTaskId);
  await _deleteSchedulerTask(tester, taskId);
  _pass('Project Scheduler::Delete scheduled job');
}

Future<void> _createSchedulerTask(
  WidgetTester tester, {
  required String name,
  required String command,
  bool targetWorker = false,
}) async {
  await _tapSchedulerAddTaskAndConfirmOpened(tester);
  await tester.enterText(
    find.byKey(const Key('scheduler-editor-name-field')),
    name,
  );
  if (targetWorker) {
    await _tap(tester, const Key('scheduler-editor-target-type'));
    await _tapFinder(
      tester,
      find.text('Worker container').last,
      description: 'worker target option',
    );
    await _waitFor(
      tester,
      find.byKey(const Key('scheduler-editor-worker-target')),
      description: 'worker target dropdown',
    );
    await _tap(tester, const Key('scheduler-editor-worker-target'));
    await _tapFinder(
      tester,
      find.textContaining('E2E Worker').last,
      description: 'E2E worker target',
    );
  }
  await tester.enterText(
    find.byKey(const Key('scheduler-editor-command-field')),
    command,
  );
  await tester.enterText(
    find.byKey(const Key('scheduler-editor-interval-field')),
    '60',
  );
  await _tap(tester, const Key('scheduler-editor-save-button'));
  await tester.pumpAndSettle(const Duration(milliseconds: 500));
}

Future<void> _deleteSchedulerTask(WidgetTester tester, String taskId) async {
  await _tap(tester, Key('scheduler-delete-$taskId'));
  await _waitFor(
    tester,
    find.text('Delete scheduled job'),
    description: 'delete scheduled job dialog',
  );
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Delete').last,
    description: 'confirm delete scheduled job',
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 500));
}

Future<void> _deleteExistingE2eFixtures(
  WidgetTester tester, {
  required String keyPrefix,
  required String dialogTitle,
  required String description,
}) async {
  final controls = find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> && key.value.startsWith(keyPrefix);
  });
  while (controls.evaluate().isNotEmpty) {
    final previousCount = controls.evaluate().length;
    await _tapFinder(
      tester,
      controls.hitTestable().first,
      description: 'delete $description',
    );
    await _waitFor(
      tester,
      find.text(dialogTitle),
      description: '$description delete dialog',
    );
    await _tapFinder(
      tester,
      find.widgetWithText(FilledButton, 'Delete').last,
      description: 'confirm deleting $description',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (controls.evaluate().length >= previousCount &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    if (controls.evaluate().length >= previousCount) {
      fail('Timed out deleting $description.');
    }
  }
}
