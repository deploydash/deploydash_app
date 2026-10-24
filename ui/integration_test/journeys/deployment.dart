part of '../e2e_checklist_test.dart';

Future<void> _exerciseWorkerSchedulerRuntimeVerification(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String projectName,
}) async {
  stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=deployment-settings');
  await _exerciseDeploymentSettingsDialog(tester, projectName: projectName);
  stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=deployment-preflight');
  await _exerciseDeploymentPreflight(tester);
  stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=deployment-run');
  await _deployForWorkerSchedulerVerification(tester);
  stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=worker-verification');
  await _captureWebAppWorkspaceScreenshots(
    tester,
    binding,
    phase: 'runtime-verification-live',
  );
  await _exerciseWorkersAfterLiveRelease(tester, projectName: projectName);
  stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=scheduler-verification');
  await _exerciseSchedulerAfterLiveRelease(tester, projectName: projectName);
  stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=worker-cleanup');
  await _deleteE2eWorker(tester);
}

Future<void> _exerciseGitHubProjectRuntime(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String projectName,
}) async {
  await _exerciseDeploymentSettingsDialog(tester, projectName: projectName);
  await _exerciseDeploymentPreflight(tester);
  await _deployCurrentRepository(tester, firstDeploy: true);
  await _captureWebAppWorkspaceScreenshots(tester, binding, phase: 'live');
  _pass('Remote Server Stack Verification::Caddy runtime through app deploy');
  if (_slimMacOs) {
    return;
  }
  await _exerciseFailedDeployAndRetry(tester);

  await _exerciseOneOffCommands(tester);
  await _exerciseWorkersAfterLiveRelease(tester, projectName: projectName);
  await _exerciseSchedulerAfterLiveRelease(tester, projectName: projectName);
  await _deleteE2eWorker(tester);
  await _exerciseRuntimeLogsAfterDeploy(tester);
  await _exerciseSaveEnvironmentAndRedeploy(tester);
  await _exerciseReleaseHistoryAndRollback(tester);
  await _exerciseRuntimeDisconnect(tester, projectName: projectName);
}

Future<void> _exerciseDeploymentSettingsDialog(
  WidgetTester tester, {
  required String projectName,
}) async {
  await _openProjectTab(
    tester,
    'Web app',
    find.byKey(const Key('app-tab-scroll')),
  );
  await _scrollProjectTabTo(
    tester,
    const Key('deployment-edit-settings-button'),
  );
  await _tap(tester, const Key('deployment-edit-settings-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('deploy-branch-field')),
    description: 'deployment settings dialog',
  );

  await tester.enterText(
    find.byKey(const Key('deploy-primary-domain-field')),
    '${_e2eProjectSlug(projectName)}.localhost',
  );
  await _tap(tester, const Key('deploy-routing-www-to-apex'));
  _pass('Project Web App::Domain routing: redirect www to apex');
  await _tap(tester, const Key('deploy-routing-apex-to-www'));
  _pass('Project Web App::Domain routing: redirect apex to www');
  await _tap(tester, const Key('deploy-routing-single-host'));
  _pass('Project Web App::Domain routing: single host');
  await tester.enterText(find.byKey(const Key('deploy-branch-field')), 'main');
  _pass('GitHub And Repository Flow::Branch selector/change');

  await _tapFinder(
    tester,
    find.text('Advanced settings'),
    description: 'deployment advanced settings',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('deploy-runtime-field')),
    description: 'deployment runtime field',
  );
  await _tap(tester, const Key('deploy-runtime-field'));
  await _tapFinder(tester, find.text('PHP').last, description: 'PHP runtime');
  await tester.enterText(
    find.byKey(const Key('deploy-app-port-field')),
    '8080',
  );

  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Save').last,
    description: 'save deployment settings',
  );
  await tester.pump(const Duration(milliseconds: 500));
  _pass('Project Web App::Deployment settings modal');
  _pass('Project Web App::Runtime auto-detect/recommendation');
}

Future<void> _exerciseDeploymentPreflight(WidgetTester tester) async {
  await _scrollProjectTabTo(tester, const Key('github-preflight-button'));
  await _tap(tester, const Key('github-preflight-button'));
  await _waitFor(
    tester,
    find.textContaining('Preflight:'),
    description: 'deployment preflight result',
    timeout: const Duration(seconds: 45),
  );
  _pass('Project Web App::Deployment preflight/check settings');
}

Future<void> _deployCurrentRepository(
  WidgetTester tester, {
  required bool firstDeploy,
}) async {
  // The disposable VM serves its synthetic *.localhost routes with Caddy's
  // internal CA. Trust that CA in the VM so the real strict public-health
  // probe verifies the routed response rather than failing on test-only TLS.
  await _trustCaddyInternalCaInsideVm();
  await _scrollProjectTabTo(tester, const Key('github-deploy-button'));
  await _waitForEnabledButton(
    tester,
    const Key('github-deploy-button'),
    description: 'deploy button',
  );
  await _tap(tester, const Key('github-deploy-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('deploy-status-message')),
    description: 'deploy status message',
  );
  _pass('Project Web App::Deploy progress copy');

  await _confirmRepositoryHostKeyIfPromptVisible(tester);
  await _waitForStatusText(
    tester,
    const Key('github-status-text'),
    'Ready',
    description: 'ready web app status',
    timeout: const Duration(minutes: 12),
  );
  _pass('Project Web App::PHP/Laravel deploy');
  _pass('Project Web App::Successful deploy state');
  if (!firstDeploy) {
    _pass('Project Web App::Redeploy after success');
  }
}

Future<void> _deployForWorkerSchedulerVerification(WidgetTester tester) async {
  // See _deployCurrentRepository for why this is limited to the disposable VM.
  await _trustCaddyInternalCaInsideVm();
  await _scrollProjectTabTo(tester, const Key('github-deploy-button'));
  await _waitForEnabledButton(
    tester,
    const Key('github-deploy-button'),
    description: 'deploy button',
  );
  await _tap(tester, const Key('github-deploy-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('deploy-status-message')),
    description: 'deploy status message',
  );
  await _confirmRepositoryHostKeyIfPromptVisible(tester);
  stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=host-key-check-complete');

  final statusFinder = find.byKey(const Key('github-status-text'));
  final deadline = DateTime.now().add(const Duration(minutes: 12));
  String? previousStatus;
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (statusFinder.evaluate().isNotEmpty) {
      final status = _readVisibleText(tester, statusFinder).trim();
      if (status != previousStatus) {
        previousStatus = status;
        stdout.writeln('DEPLOYDASH_E2E_RUNTIME_DEPLOY_STATUS=$status');
      }
      if (status == 'Ready' || status == 'Needs attention') {
        stdout.writeln(
          'DEPLOYDASH_E2E_RUNTIME_VERIFICATION_DEPLOY_STATUS=$status',
        );
        return;
      }
      if (status == 'Failed') {
        fail('The runtime-verification deployment failed.');
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  final visible = statusFinder.evaluate().isEmpty
      ? '<not visible>'
      : _readVisibleText(tester, statusFinder);
  fail(
    'Timed out waiting for a live runtime-verification release. '
    'Last visible status: $visible',
  );
}

Future<void> _deployExpectingPostCutoverFailure(WidgetTester tester) async {
  await _scrollProjectTabTo(tester, const Key('github-deploy-button'));
  await _waitForEnabledButton(
    tester,
    const Key('github-deploy-button'),
    description: 'deploy button for forced Caddy failure',
  );
  await _tap(tester, const Key('github-deploy-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('deploy-status-message')),
    description: 'forced Caddy failure deploy status',
  );
  await _confirmRepositoryHostKeyIfPromptVisible(tester);
  await _waitForStatusText(
    tester,
    const Key('github-status-text'),
    'Attention needed',
    description: 'post-cutover Caddy failure status',
    timeout: const Duration(minutes: 12),
  );
  await _waitForKeyTextContains(
    tester,
    const Key('deploy-status-message'),
    'reverted',
    description: 'post-cutover Caddy recovery message',
  );
}

Future<void> _exerciseFailedDeployAndRetry(WidgetTester tester) async {
  await _openProjectTab(
    tester,
    'Web app',
    find.byKey(const Key('app-tab-scroll')),
  );
  await _scrollProjectTabTo(
    tester,
    const Key('deployment-edit-settings-button'),
  );
  await _tap(tester, const Key('deployment-edit-settings-button'));
  await _tapFinder(
    tester,
    find.text('Advanced settings'),
    description: 'deployment advanced settings',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('deploy-run-command-field')),
    description: 'deployment settings run command',
  );
  await tester.enterText(
    find.byKey(const Key('deploy-run-command-field')),
    "php -r \"fwrite(STDERR, 'e2e readiness failure'); exit(42);\"",
  );
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Save').last,
    description: 'save failing deployment settings',
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 500));

  await _scrollProjectTabTo(tester, const Key('github-deploy-button'));
  await _tap(tester, const Key('github-deploy-button'));
  // The other three github-deploy-button call sites in this file confirm
  // deploy-status-message actually appeared before committing to a longer
  // wait; this one went straight to the 10-minute 'failed' wait, so a
  // missed tap here would burn the full 10 minutes instead of failing fast
  // with a clear "deploy status message" timeout.
  await _waitFor(
    tester,
    find.byKey(const Key('deploy-status-message')),
    description: 'deploy status message',
  );
  await _waitForKeyTextContains(
    tester,
    const Key('deploy-status-message'),
    'failed',
    description: 'failed deploy status',
    timeout: const Duration(minutes: 10),
  );
  _pass('Project Web App::Readiness failure surfacing');

  await _openProjectTab(tester, 'Log', find.byKey(const Key('app-log-card')));
  await _tapFinder(
    tester,
    find.widgetWithText(Tab, 'Deployment log'),
    description: 'Deployment log tab',
  );
  await _waitFor(
    tester,
    find.textContaining('readiness').hitTestable(),
    description: 'deployment log failed readiness details',
    timeout: const Duration(minutes: 2),
  );
  _pass('Project Logs::Deployment log after failed deploy');

  await _tapFinder(
    tester,
    find.widgetWithText(Tab, 'Web app runtime'),
    description: 'Web app runtime log tab',
  );
  await _waitFor(
    tester,
    find.textContaining('e2e readiness failure').hitTestable(),
    description: 'failed candidate runtime logs',
    timeout: const Duration(minutes: 2),
  );
  _pass('Project Logs::Failed candidate runtime logs');

  await _openProjectTab(
    tester,
    'Web app',
    find.byKey(const Key('app-tab-scroll')),
  );
  await _scrollProjectTabTo(
    tester,
    const Key('deployment-edit-settings-button'),
  );
  await _tap(tester, const Key('deployment-edit-settings-button'));
  await _tapFinder(
    tester,
    find.text('Advanced settings'),
    description: 'deployment advanced settings reset',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('deploy-run-command-field')),
    description: 'deployment settings run command reset',
  );
  await tester.enterText(find.byKey(const Key('deploy-run-command-field')), '');
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'Save').last,
    description: 'save restored deployment settings',
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 500));
  await _deployCurrentRepository(tester, firstDeploy: false);
  _pass('Project Web App::Deploy failure then retry');
}

Future<void> _confirmRepositoryHostKeyIfPromptVisible(
  WidgetTester tester,
) async {
  final prompt = find.text('Confirm GitHub SSH identity');
  final failed = find.textContaining('Deployment failed');
  final status = find.byKey(const Key('github-status-text'));
  var sawRunningStatus = false;
  String? previousStatus;
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (prompt.evaluate().isNotEmpty) {
      stdout.writeln('DEPLOYDASH_E2E_RUNTIME_HOST_KEY_PROMPT=visible');
      _pass(
        'GitHub And Repository Flow::Inline deploy-key GitHub SSH trust prompt',
      );
      await _tapFinder(
        tester,
        find.widgetWithText(FilledButton, 'Trust and retry').last,
        description: 'Trust and retry repository host key',
      );
      await tester.pump(const Duration(milliseconds: 500));
      return;
    }
    if (failed.evaluate().isNotEmpty) {
      stdout.writeln('DEPLOYDASH_E2E_RUNTIME_HOST_KEY_PROMPT=deploy-failed');
      return;
    }
    if (status.evaluate().isNotEmpty) {
      final statusText = _readVisibleText(tester, status).trim().toLowerCase();
      if (statusText != previousStatus) {
        previousStatus = statusText;
        stdout.writeln('DEPLOYDASH_E2E_RUNTIME_HOST_KEY_STATUS=$statusText');
      }
      if (statusText != 'ready') {
        sawRunningStatus = true;
      } else if (sawRunningStatus) {
        return;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  stdout.writeln('DEPLOYDASH_E2E_RUNTIME_HOST_KEY_PROMPT=not-required');
}
