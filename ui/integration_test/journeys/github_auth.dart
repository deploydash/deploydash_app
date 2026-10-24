part of '../e2e_checklist_test.dart';

Future<void> _exerciseOptionalGitHubBrowserLogin(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String projectName,
  bool workerSchedulerOnly = false,
}) async {
  if (_pauseAtManualGitHub) {
    await _waitForManualGitHubRepositorySelection(
      tester,
      binding,
      projectName: projectName,
      workerSchedulerOnly: workerSchedulerOnly,
    );
    return;
  }

  await _openProjectTab(
    tester,
    'Web app',
    find.byKey(const Key('app-tab-scroll')),
  );
  if (workerSchedulerOnly) {
    stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=github-entry');
  }
  final scrollableFinder = find
      .descendant(
        of: find.byKey(const Key('app-tab-scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
  tester.state<ScrollableState>(scrollableFinder).position.jumpTo(0);
  await tester.pumpAndSettle();
  final entry = await _waitForAny(
    tester,
    <String, Finder>{
      'connect': find.byKey(const Key('connect-github-button')),
      'repositories': find.byKey(const Key('github-repo-dropdown')),
    },
    description: 'GitHub connection or repository selector',
    timeout: const Duration(seconds: 45),
  );
  if (workerSchedulerOnly) {
    stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=github-$entry');
  }
  if (entry == 'connect') {
    final username = Platform.environment['DEPLOYDASH_E2E_GITHUB_USERNAME'];
    final password = Platform.environment['DEPLOYDASH_E2E_GITHUB_PASSWORD'];
    if (username == null ||
        username.trim().isEmpty ||
        password == null ||
        password.isEmpty) {
      if (workerSchedulerOnly) {
        fail(
          'The targeted runtime verification requires GitHub credentials '
          'when the isolated profile is not already connected.',
        );
      }
      return;
    }

    await _tap(tester, const Key('connect-github-button'));
    final authUrl = await _tapCopyOauthUrlAndConfirmCopied(tester);

    final callbackUrl = await _runGitHubRelayLogin(authUrl);
    if (!callbackUrl.startsWith('deploydash://callback?')) {
      fail('GitHub browser login did not return a Deploy Dash callback URL.');
    }

    await _waitFor(
      tester,
      find.byKey(const Key('github-callback-field')),
      description: 'manual GitHub callback field',
    );
    await tester.enterText(
      find.byKey(const Key('github-callback-field')),
      callbackUrl,
    );
    await _tap(tester, const Key('github-process-callback-button'));

    await _waitFor(
      tester,
      find.byKey(const Key('github-repo-dropdown')),
      description: 'GitHub repository dropdown',
      timeout: const Duration(minutes: 2),
    );
    expect(find.byKey(const Key('github-callback-field')), findsNothing);
    _pass('GitHub And Repository Flow::GitHub OAuth connect with human login');
  }

  await _tap(tester, const Key('github-repo-dropdown'));
  await _tapFinder(
    tester,
    find.text(_githubRepositoryFullName).last,
    description: _githubRepositoryFullName,
  );
  await _waitFor(
    tester,
    find.text(_githubRepositoryFullName),
    description: 'selected GitHub repository',
  );
  if (workerSchedulerOnly) {
    stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=repository-selected');
  }
  _pass('GitHub And Repository Flow::Repository list and selection');

  if (workerSchedulerOnly) {
    await _exerciseWorkerSchedulerRuntimeVerification(
      tester,
      binding,
      projectName: projectName,
    );
  } else {
    await _exerciseGitHubProjectRuntime(
      tester,
      binding,
      projectName: projectName,
    );
  }
}

Future<void> _waitForManualGitHubRepositorySelection(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String projectName,
  bool workerSchedulerOnly = false,
}) async {
  await windowManager.restore();
  await windowManager.show();
  await windowManager.focus();
  await windowManager.setAlwaysOnTop(true);
  await _openProjectTab(
    tester,
    'Web app',
    find.byKey(const Key('app-tab-scroll')),
  );
  final scrollableFinder = find
      .descendant(
        of: find.byKey(const Key('app-tab-scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
  tester.state<ScrollableState>(scrollableFinder).position.jumpTo(0);
  await tester.pumpAndSettle();
  final entry = await _waitForAny(
    tester,
    <String, Finder>{
      'connect': find.byKey(const Key('connect-github-button')),
      'repositories': find.byKey(const Key('github-repo-dropdown')),
    },
    description: 'GitHub connection or repository selector',
    timeout: const Duration(seconds: 45),
  );
  if (entry == 'repositories') {
    await _tap(tester, const Key('github-repo-dropdown'));
    await _tapFinder(
      tester,
      find.text(_githubRepositoryFullName).last,
      description: _githubRepositoryFullName,
    );
    await _continueAfterManualGitHubSelection(
      tester,
      binding,
      projectName: projectName,
      workerSchedulerOnly: workerSchedulerOnly,
    );
    return;
  }

  binding.shouldPropagateDevicePointerEvents = true;
  try {
    stdout.writeln('DEPLOYDASH_E2E_MANUAL_GITHUB_READY');
    stdout.writeln(
      'Connect GitHub in the app and select $_githubRepositoryFullName.',
    );

    final deadline = DateTime.now().add(const Duration(minutes: 20));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 500));
      if (_hasSelectedGitHubRepository(tester)) {
        binding.shouldPropagateDevicePointerEvents = false;
        await windowManager.setAlwaysOnTop(false);
        await _continueAfterManualGitHubSelection(
          tester,
          binding,
          projectName: projectName,
          workerSchedulerOnly: workerSchedulerOnly,
        );
        return;
      }
    }
  } finally {
    binding.shouldPropagateDevicePointerEvents = false;
    await windowManager.setAlwaysOnTop(false);
  }

  fail(
    'Timed out waiting for $_githubRepositoryFullName to be selected in the app.',
  );
}

bool _hasSelectedGitHubRepository(WidgetTester tester) {
  // Not github-repo-dropdown's initialValue: app_deployment_tab.dart's
  // primary action area is `!isRepoSelected ? DropdownButtonFormField(...) :
  // FilledButton(key: github-deploy-button, ...)` (since a4b0e93,
  // 2026-08-06), so the dropdown is replaced by the deploy button on the
  // very same rebuild that selecting a repository triggers -- there is no
  // intermediate frame where it persists with the new value. Checking the
  // dropdown's key or its .initialValue can therefore never observe a
  // successful selection; it can only ever see "not yet selected" or "gone".
  // The automated (non-paused) GitHub flow in this same file already gets
  // this right by waiting on the repository's name as plain text instead,
  // which survives the widget swap because it is not tied to one specific
  // widget.
  return find.text(_githubRepositoryFullName).evaluate().isNotEmpty;
}

Future<void> _continueAfterManualGitHubSelection(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String projectName,
  required bool workerSchedulerOnly,
}) async {
  await _waitFor(
    tester,
    find.text(_githubRepositoryFullName),
    description: 'selected GitHub repository',
  );
  if (!_hasSelectedGitHubRepository(tester)) {
    fail('The selected GitHub repository was not persisted in the app.');
  }
  stdout.writeln('DEPLOYDASH_E2E_MANUAL_GITHUB_COMPLETE');
  _pass('GitHub And Repository Flow::GitHub OAuth connect with human login');
  _pass('GitHub And Repository Flow::Repository list and selection');
  if (workerSchedulerOnly) {
    await _exerciseWorkerSchedulerRuntimeVerification(
      tester,
      binding,
      projectName: projectName,
    );
  } else {
    await _exerciseGitHubProjectRuntime(
      tester,
      binding,
      projectName: projectName,
    );
  }
}

Future<void> _verifyWorkerSchedulerRuntimeFromHome(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  if (!_reuseE2eProfile) {
    fail('DEPLOYDASH_E2E_VERIFY_WORKER_SCHEDULER_ONLY requires profile reuse.');
  }
  if (_workerSchedulerRuntimeProject.trim().isNotEmpty) {
    final projectName = _workerSchedulerRuntimeProject.trim();
    stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=reuse-live-project');
    await _openProjectFromHome(tester, projectName);
    await _exerciseWorkersAfterLiveRelease(tester, projectName: projectName);
    stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=scheduler-verification');
    await _exerciseSchedulerAfterLiveRelease(tester, projectName: projectName);
    await _deleteE2eWorker(tester);
    stdout.writeln('DEPLOYDASH_E2E_WORKER_SCHEDULER_VERIFICATION_COMPLETE');
    return;
  }
  final runSuffix = DateTime.now().millisecondsSinceEpoch.remainder(1000000);
  final projectName = 'E2E runtime verification $runSuffix';
  stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=project-create');
  await _createProject(tester, name: projectName, runtime: 'PHP');
  stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=environment-editor');
  await _exerciseEnvironmentEditor(tester);
  stdout.writeln('DEPLOYDASH_E2E_RUNTIME_PHASE=github-connect');
  await _exerciseOptionalGitHubBrowserLogin(
    tester,
    binding,
    projectName: projectName,
    workerSchedulerOnly: true,
  );
  stdout.writeln('DEPLOYDASH_E2E_WORKER_SCHEDULER_VERIFICATION_COMPLETE');
}

Future<void> _verifyPublicHealthFromHome(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  _requireReusableE2eProfile('DEPLOYDASH_E2E_VERIFY_PUBLIC_HEALTH_ONLY');
  final runSuffix = DateTime.now().millisecondsSinceEpoch.remainder(1000000);
  final projectName = 'E2E public health $runSuffix';

  stdout.writeln('DEPLOYDASH_E2E_PUBLIC_HEALTH_PHASE=project-create');
  await _createProject(tester, name: projectName, runtime: 'PHP');
  await _trustCaddyInternalCaInsideVm();
  await _exerciseEnvironmentEditor(tester, includeLaravelAppKey: false);
  await _selectGitHubRepositoryForFocusedDeployment(tester, binding);
  await _exerciseDeploymentSettingsDialog(tester, projectName: projectName);
  await _exerciseDeploymentPreflight(tester);
  await _deployForWorkerSchedulerVerification(tester);

  await _waitForStatusText(
    tester,
    const Key('github-status-text'),
    'Needs attention',
    description: 'public URL failure status',
    timeout: const Duration(minutes: 2),
  );
  await _waitFor(
    tester,
    find.byKey(const Key('app-public-health-warning')),
    description: 'public URL warning',
  );
  await _waitForKeyTextContains(
    tester,
    const Key('app-public-health-warning-detail'),
    'HTTP 500',
    description: 'public URL HTTP failure detail',
  );
  await _captureWebAppWorkspaceScreenshots(
    tester,
    binding,
    phase: 'public-health-failed',
  );
  stdout.writeln('DEPLOYDASH_E2E_PUBLIC_HEALTH_FAILURE_VISIBLE');

  await _tap(tester, const Key('app-public-health-environment-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('env-new-key-field')),
    description: 'environment editor after public health failure',
  );
  await _addLaravelAppKeyRow(tester);
  await _tap(tester, const Key('env-save-button'));
  await tester.pumpAndSettle();

  await _deployCurrentRepository(tester, firstDeploy: false);
  await _waitForAbsent(
    tester,
    find.byKey(const Key('app-public-health-warning')),
    description: 'cleared public URL warning',
    timeout: const Duration(minutes: 2),
  );
  await _waitForStatusText(
    tester,
    const Key('github-status-text'),
    'Ready',
    description: 'healthy public URL status',
  );
  stdout.writeln('DEPLOYDASH_E2E_PUBLIC_HEALTH_VERIFICATION_COMPLETE');
}

Future<void> _verifyCaddyRouteCleanupFromHome(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  _requireReusableE2eProfile('DEPLOYDASH_E2E_VERIFY_CADDY_ROUTE_CLEANUP_ONLY');
  final runSuffix = DateTime.now().millisecondsSinceEpoch.remainder(1000000);
  final projectName = 'E2E caddy cleanup $runSuffix';
  final projectSlug = _e2eProjectSlug(projectName);
  final domain = '$projectSlug.localhost';

  stdout.writeln('DEPLOYDASH_E2E_CADDY_CLEANUP_PHASE=project-create');
  await _createProject(tester, name: projectName, runtime: 'PHP');
  await _exerciseEnvironmentEditor(tester);
  await _selectGitHubRepositoryForFocusedDeployment(tester, binding);
  await _exerciseDeploymentSettingsDialog(tester, projectName: projectName);
  await _exerciseDeploymentPreflight(tester);
  await _armFirstRouteFailureInsideVm(projectSlug: projectSlug, domain: domain);

  await _deployExpectingPostCutoverFailure(tester);
  await _verifyRemovedCaddyRouteInsideVm(projectSlug: projectSlug);
  stdout.writeln('DEPLOYDASH_E2E_CADDY_CLEANUP_ROUTE_REMOVED');

  await _deployCurrentRepository(tester, firstDeploy: true);
  await _verifyRestoredCaddyRouteInsideVm(
    projectSlug: projectSlug,
    domain: domain,
  );
  await _captureWebAppWorkspaceScreenshots(
    tester,
    binding,
    phase: 'caddy-cleanup-retry-succeeded',
  );
  stdout.writeln('DEPLOYDASH_E2E_CADDY_CLEANUP_VERIFICATION_COMPLETE');
}

void _requireReusableE2eProfile(String mode) {
  if (!_reuseE2eProfile) {
    fail('$mode requires DEPLOYDASH_E2E_REUSE_PROFILE=true.');
  }
  if (_vmName.trim().isEmpty) {
    fail('$mode requires DEPLOYDASH_E2E_VM_NAME.');
  }
}

Future<void> _selectGitHubRepositoryForFocusedDeployment(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  await _openProjectTab(
    tester,
    'Web app',
    find.byKey(const Key('app-tab-scroll')),
  );
  final scrollableFinder = find
      .descendant(
        of: find.byKey(const Key('app-tab-scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
  tester.state<ScrollableState>(scrollableFinder).position.jumpTo(0);
  await tester.pumpAndSettle();

  final entry = await _waitForAny(
    tester,
    <String, Finder>{
      'connect': find.byKey(const Key('connect-github-button')),
      'repositories': find.byKey(const Key('github-repo-dropdown')),
    },
    description: 'GitHub repository selector for focused verification',
    timeout: const Duration(seconds: 45),
  );
  if (entry == 'connect') {
    if (!_pauseAtManualGitHub) {
      fail(
        'The reusable E2E profile is not connected to GitHub. Re-run with '
        'DEPLOYDASH_E2E_PAUSE_AT_GITHUB=1, connect GitHub in the app, and '
        'select $_githubRepositoryFullName.',
      );
    }
    await _waitForFocusedManualGitHubSelection(tester, binding);
    return;
  }

  await _tap(tester, const Key('github-repo-dropdown'));
  await _tapFinder(
    tester,
    find.text(_githubRepositoryFullName).last,
    description: _githubRepositoryFullName,
  );
  await _waitFor(
    tester,
    find.text(_githubRepositoryFullName),
    description: 'selected GitHub repository',
  );
  _pass('GitHub And Repository Flow::Repository list and selection');
}

Future<void> _waitForFocusedManualGitHubSelection(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  await windowManager.restore();
  await windowManager.show();
  await windowManager.focus();
  await windowManager.setAlwaysOnTop(true);
  binding.shouldPropagateDevicePointerEvents = true;
  try {
    stdout.writeln('DEPLOYDASH_E2E_MANUAL_GITHUB_READY');
    stdout.writeln(
      'Connect GitHub in the app and select $_githubRepositoryFullName.',
    );
    final deadline = DateTime.now().add(const Duration(minutes: 20));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 500));
      if (_hasSelectedGitHubRepository(tester)) {
        _pass(
          'GitHub And Repository Flow::GitHub OAuth connect with human login',
        );
        _pass('GitHub And Repository Flow::Repository list and selection');
        stdout.writeln('DEPLOYDASH_E2E_MANUAL_GITHUB_COMPLETE');
        return;
      }
    }
  } finally {
    binding.shouldPropagateDevicePointerEvents = false;
    await windowManager.setAlwaysOnTop(false);
  }
  fail(
    'Timed out waiting for $_githubRepositoryFullName to be selected in the app.',
  );
}
