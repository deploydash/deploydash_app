part of '../e2e_checklist_test.dart';

/// Slim macOS QA path (`DEPLOYDASH_E2E_SLIM_MACOS`): one project, environment
/// editor, GitHub connect/select, first deploy success. Everything after the
/// Caddy pass (failed-deploy retry, one-off commands, workers, scheduler,
/// logs, redeploy, rollback, disconnect) stays Linux-full-E2E-only.
Future<void> _exerciseSlimMacOsDeploy(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  final runSuffix = DateTime.now().millisecondsSinceEpoch.remainder(1000000);
  final name = 'E2E slim $runSuffix';
  await _createProject(tester, name: name, runtime: 'PHP');
  await _waitFor(
    tester,
    find.byKey(const Key('app-live-state-card')),
    description: 'web app state card',
  );
  await _waitForAny(tester, <String, Finder>{
    'connect': find.byKey(const Key('connect-github-button')),
    'repositories': find.byKey(const Key('github-repo-dropdown')),
  }, description: 'new project GitHub connection or repository selector');
  _pass('Project Web App::New project Web app empty state');
  await _exerciseEnvironmentEditor(tester);
  await _exerciseOptionalGitHubBrowserLogin(tester, binding, projectName: name);
  await _exerciseSlimFirstDeploy(tester, binding, projectName: name);
}

/// Slim deploy: settings, preflight, and first live deploy only. Everything
/// after a live release (failed-deploy retry, one-off commands, workers,
/// scheduler, logs, redeploy, rollback, disconnect) stays Linux-full-only.
/// Runs only when GitHub credentials are configured; without them there is
/// no repository to deploy and the flow ends after login selection.
Future<void> _exerciseSlimFirstDeploy(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String projectName,
}) async {
  final githubUsername = Platform.environment['DEPLOYDASH_E2E_GITHUB_USERNAME'];
  final githubPassword = Platform.environment['DEPLOYDASH_E2E_GITHUB_PASSWORD'];
  if (githubUsername == null ||
      githubUsername.trim().isEmpty ||
      githubPassword == null ||
      githubPassword.isEmpty) {
    return;
  }
  await _exerciseDeploymentSettingsDialog(tester, projectName: projectName);
  await _exerciseDeploymentPreflight(tester);
  await _deployCurrentRepository(tester, firstDeploy: true);
  await _captureWebAppWorkspaceScreenshots(tester, binding, phase: 'live');
  _pass('Remote Server Stack Verification::Caddy runtime through app deploy');
}

Future<void> _exerciseProjectChecklistSurfaces(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  final runSuffix = DateTime.now().millisecondsSinceEpoch.remainder(1000000);
  final alpha = 'E2E checklist alpha $runSuffix';
  final beta = 'E2E checklist beta $runSuffix';

  _pass('Packaging And Platform Smoke Tests::Linux debug run from repo');

  await _createProject(tester, name: alpha, runtime: 'PHP');
  await _exerciseProjectWorkspaceSurfaces(tester, binding, projectName: alpha);

  await _createProject(tester, name: beta);
  await _openProjectFromHome(tester, alpha);
  _pass('Core App Shell::Project selection from Home');

  await _openProjectFromRail(tester, beta);
  _pass(
    'Core App Shell::Project switching from rail recents with multiple projects',
  );

  await _deleteCurrentProject(tester, beta);
  _pass('Project Email, Domain, And Settings::Project delete workflow');
  await _dismissDeleteNoticeIfVisible(tester);

  await _openProjectFromHome(tester, alpha);
  await _deleteCurrentProject(tester, alpha);
  if (_reuseE2eProfile) {
    await _waitForHome(tester);
  } else {
    await _waitFor(
      tester,
      find.text('No projects yet'),
      description: 'empty Home project state',
    );
    _pass('Core App Shell::Delete last project and empty Home state');
  }
}

Future<void> _exerciseProjectWorkspaceSurfaces(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String projectName,
}) async {
  await _waitFor(
    tester,
    find.byKey(const Key('app-live-state-card')),
    description: 'web app state card',
  );
  // Not an unconditional expect(connect-github-button): GitHub connection is
  // account-level, not per-project, so with --reuse-profile a brand-new
  // project can find GitHub already connected and skip straight to
  // github-repo-dropdown. The downstream GitHub flows already handle both
  // entry points via the same _waitForAny pattern; this initial-state check
  // must match them instead of assuming a never-connected profile.
  await _waitForAny(tester, <String, Finder>{
    'connect': find.byKey(const Key('connect-github-button')),
    'repositories': find.byKey(const Key('github-repo-dropdown')),
  }, description: 'new project GitHub connection or repository selector');
  _pass('Project Web App::New project Web app empty state');
  await _captureWebAppWorkspaceScreenshots(
    tester,
    binding,
    phase: 'before-deploy',
  );

  await _exerciseWorkersBeforeLiveRelease(tester);
  await _exerciseDatabaseSurfaces(tester, projectName: projectName);
  await _exerciseBackupUnavailable(tester);
  await _exerciseSchedulerBeforeLiveRelease(tester);
  await _exerciseLogSurfaces(tester);
  await _exerciseEmailDomainAndSettings(tester);
  await _exerciseEnvironmentEditor(tester);
  await _exerciseOptionalGitHubBrowserLogin(
    tester,
    binding,
    projectName: projectName,
  );
}

Future<void> _exerciseEnvironmentEditor(
  WidgetTester tester, {
  bool includeLaravelAppKey = true,
}) async {
  await _openProjectTab(
    tester,
    'Web app',
    find.byKey(const Key('app-tab-scroll')),
  );
  await tester.scrollUntilVisible(
    find.byKey(const Key('env-edit-button')),
    260,
    scrollable: find
        .descendant(
          of: find.byKey(const Key('app-tab-scroll')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await _tapEnvEditAndConfirmOpened(tester);
  await tester.enterText(
    find.byKey(const Key('env-new-key-field')),
    'E2E_FLAG',
  );
  await tester.enterText(find.byKey(const Key('env-new-value-field')), 'true');
  await _tap(tester, const Key('env-add-row-button'));
  if (includeLaravelAppKey) {
    await _addLaravelAppKeyRow(tester);
  }
  await _tap(tester, const Key('env-save-button'));
  await tester.pumpAndSettle();
  _pass('Project Web App::Environment variable editor');
}

Future<void> _addLaravelAppKeyRow(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('env-new-key-field')), 'APP_KEY');
  await tester.enterText(
    find.byKey(const Key('env-new-value-field')),
    'base64:ZGVwbG95ZGFzaC1lMmUta2V5LTEyMzQ1Njc4OTAxMjM=',
  );
  await _tap(tester, const Key('env-add-row-button'));
}
