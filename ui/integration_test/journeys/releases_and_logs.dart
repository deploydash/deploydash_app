part of '../e2e_checklist_test.dart';

Future<void> _exerciseRuntimeLogsAfterDeploy(WidgetTester tester) async {
  await _openProjectTab(tester, 'Log', find.byKey(const Key('app-log-card')));
  await _tapFinder(
    tester,
    find.widgetWithText(Tab, 'Web app runtime'),
    description: 'Web app runtime log tab',
  );
  await _tapFetchRuntimeLogsAndConfirmStarted(tester);
  await _waitFor(
    tester,
    find.widgetWithText(FilledButton, 'Fetch runtime logs'),
    description: 'completed runtime log fetch',
    timeout: const Duration(minutes: 3),
  );
  _pass('Project Logs::Runtime logs after successful deploy');
}

// The completion wait above necessarily re-matches the same
// find.widgetWithText(FilledButton, 'Fetch runtime logs') used to tap the
// button, since that is the only signal log_tab.dart exposes once the
// fetch finishes and _isFetchingRuntimeLogs clears. That means a missed
// tap, which never leaves the button's initial state at all, would match
// on the very first pump and silently report success without ever having
// fetched anything -- a false pass, not just a burnt wait. Confirm the
// button actually entered its "Fetching runtime logs..." disabled state
// before trusting the tap.
Future<void> _tapFetchRuntimeLogsAndConfirmStarted(WidgetTester tester) async {
  final fetchButton = find.widgetWithText(FilledButton, 'Fetch runtime logs');
  final fetchingButton = find.widgetWithText(
    FilledButton,
    'Fetching runtime logs...',
  );
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(tester, fetchButton, description: 'Fetch runtime logs');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (fetchingButton.evaluate().isNotEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail('Tapping Fetch runtime logs never started fetching.');
}

// Mirrors _tapOneOffRunButtonAndConfirmStarted's confirm-then-retry
// pattern, but confirms the env editor dialog actually closed (an instant,
// purely client-side signal from _closeWithResult's Navigator.pop). Not
// deploy-status-message: that Text widget is unconditionally mounted
// whenever a repository is selected (app_deployment_tab.dart's `if
// (isRepoSelected) ...`), well before and long after any single deploy, so
// its mere presence never actually confirmed a deploy had started -- and it
// lives inside app-live-state-card, near the top of the Web app tab, while
// this call site is scrolled down to env-edit-button, so find.byKey
// couldn't even see it mounted at that scroll position regardless. Two
// earlier versions of this fix both checked for it anyway (once folded into
// this tap-confirmation's own budget, once as a separate wait afterward)
// and both produced false failures on live runs where the redeploy had
// genuinely dispatched and completed -- confirmed by a new release image on
// the VM matching each failure's timestamp. The real completion signal
// this call site already had, and still has, is the existing
// github-status-text wait for 'Ready' further down.
Future<void> _tapSaveAndRedeployAndConfirmStarted(WidgetTester tester) async {
  final saveButton = find.byKey(const Key('env-save-redeploy-button'));
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(
      tester,
      saveButton,
      description: 'save environment and redeploy',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (saveButton.evaluate().isEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail('Tapping Save and redeploy never closed the environment editor.');
}

Future<void> _exerciseSaveEnvironmentAndRedeploy(WidgetTester tester) async {
  await _openProjectTab(
    tester,
    'Web app',
    find.byKey(const Key('app-tab-scroll')),
  );
  await _scrollProjectTabTo(tester, const Key('env-edit-button'));
  await _tapEnvEditAndConfirmOpened(tester);
  await tester.enterText(
    find.byKey(const Key('env-new-key-field')),
    'E2E_REDEPLOY_FLAG',
  );
  await tester.enterText(find.byKey(const Key('env-new-value-field')), 'true');
  await _tap(tester, const Key('env-add-row-button'));
  await _waitForEnabledButton(
    tester,
    const Key('env-save-redeploy-button'),
    description: 'Save and redeploy button',
  );
  await _tapSaveAndRedeployAndConfirmStarted(tester);
  _pass('Project Web App::Save environment and redeploy');
  // env-edit-button (and the redeploy dialog above it) sits well below
  // app-live-state-card in the Web app tab's lazy scroll view, and nothing
  // scrolls back up after the dialog closes. Both
  // _confirmRepositoryHostKeyIfPromptVisible and the Ready-status wait below
  // read github-status-text, which lives inside that card -- left scrolled
  // out of view, both would silently see it as unmounted for their entire
  // duration instead of actually observing the deploy's status, which is
  // exactly what happened live: the redeploy dispatched and completed (a
  // new release image appeared on the VM matching the timeout), but the
  // 12-minute wait timed out anyway because github-status-text was never
  // scrolled into view to observe it.
  await _scrollProjectTabToTop(tester);
  await _confirmRepositoryHostKeyIfPromptVisible(tester);
  await _waitForStatusText(
    tester,
    const Key('github-status-text'),
    'Ready',
    description: 'ready status after redeploy',
    timeout: const Duration(minutes: 12),
  );
  _pass('Project Web App::Redeploy after success');
}

Future<void> _exerciseReleaseHistoryAndRollback(WidgetTester tester) async {
  await _openProjectTab(
    tester,
    'Web app',
    find.byKey(const Key('app-tab-scroll')),
  );
  await _expandProjectDisclosure(
    tester,
    disclosureKey: const Key('app-release-history-card'),
    contentKey: const Key('app-release-history-refresh-button'),
  );
  await _tap(tester, const Key('app-release-history-refresh-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('app-release-row-0')),
    description: 'release history row',
    timeout: const Duration(minutes: 3),
  );
  _pass('Project Web App::Release history refresh');

  await _waitForEnabledButton(
    tester,
    const Key('app-release-rollback-previous-button'),
    description: 'rollback previous release button',
    timeout: const Duration(minutes: 3),
  );
  await _tap(tester, const Key('app-release-rollback-previous-button'));
  await _confirmAppRollback(tester);
  // Same scroll-position gap as the redeploy wait above: this call site is
  // scrolled to app-release-history-card, well below app-live-state-card,
  // and closing the rollback dialog doesn't scroll back up. Bring
  // github-status-text into view before waiting on it, or this wait times
  // out watching an unmounted widget regardless of the actual rollback
  // outcome.
  await _scrollProjectTabToTop(tester);
  await _waitForStatusText(
    tester,
    const Key('github-status-text'),
    'Ready',
    description: 'ready status after rollback',
    timeout: const Duration(minutes: 8),
  );
  await _dismissRollbackFinishedDialogIfPresent(
    tester,
    timeout: const Duration(seconds: 20),
  );
  _pass('Project Web App::Rollback to previous release');
}

// _rollbackToRelease (app_deployment_methods.dart) shows its own
// AppConfirmDialog ('Rollback finished' / 'Rollback completed.', OK to
// dismiss) once the rollback operation's own async chain completes,
// separately from and not necessarily soon after github-status-text
// reaches 'Ready'. Left open, it blocks every subsequent dialog-opening tap
// in this project -- including _exerciseRuntimeDisconnect's "Remove web app
// runtime" dialog, which never appeared behind it on two consecutive live
// runs even after a 10s poll here alone. Called at both the end of the
// rollback and the start of the disconnect step, since exactly how long
// after 'Ready' the dialog actually appears isn't reliable.
Future<void> _dismissRollbackFinishedDialogIfPresent(
  WidgetTester tester, {
  required Duration timeout,
}) async {
  final rollbackFinishedDialog = find.text('Rollback finished');
  final dialogDeadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(dialogDeadline) &&
      rollbackFinishedDialog.evaluate().isEmpty) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  if (rollbackFinishedDialog.evaluate().isNotEmpty) {
    await _tapFinder(
      tester,
      find.widgetWithText(FilledButton, 'OK').last,
      description: 'dismiss rollback finished dialog',
    );
    await _waitForAbsent(
      tester,
      rollbackFinishedDialog,
      description: 'dismissed rollback finished dialog',
    );
  }
}

Future<void> _exerciseRuntimeDisconnect(
  WidgetTester tester, {
  required String projectName,
}) async {
  await _dismissRollbackFinishedDialogIfPresent(
    tester,
    timeout: const Duration(seconds: 20),
  );
  await _expandProjectDisclosure(
    tester,
    disclosureKey: const Key('app-disconnect-card'),
    contentKey: const Key('app-disconnect-button'),
  );
  // One more check immediately before the tap this dialog actually blocks:
  // _expandProjectDisclosure's own retries can themselves take a while, and
  // this dialog's exact timing has proven unreliable across live runs.
  await _dismissRollbackFinishedDialogIfPresent(
    tester,
    timeout: const Duration(seconds: 5),
  );
  await _tap(tester, const Key('app-disconnect-button'));
  await _waitFor(
    tester,
    find.text('Remove web app runtime'),
    description: 'remove web app runtime dialog',
  );
  await tester.enterText(find.byType(TextField).last, projectName);
  await _tapFinder(
    tester,
    find.byType(CheckboxListTile).last,
    description: 'disconnect acknowledge checkbox',
  );
  await _waitForEnabledButtonByFinder(
    tester,
    find.widgetWithText(FilledButton, 'Remove web app').last,
    description: 'enabled remove web app button',
  );
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Remove web app').last,
    description: 'confirm remove web app runtime',
  );
  await _waitFor(
    tester,
    find.textContaining('disconnected').hitTestable(),
    description: 'web app disconnected',
    timeout: const Duration(minutes: 3),
  );
  _pass('Project Web App::Disconnect/remove web app runtime');
  _pass(
    'Project Email, Domain, And Settings::Runtime disconnect from Settings/Web app',
  );
}
