part of '../e2e_checklist_test.dart';

Future<void> _runAppRollbackScenario(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  final suffix = DateTime.now().millisecondsSinceEpoch.remainder(1000000);
  final projectName = 'E2E app rollback $suffix';
  final projectSlug = _e2eProjectSlug(projectName);
  await _createProject(tester, name: projectName, runtime: 'PHP');
  await _exerciseEnvironmentEditor(tester);
  await _ensureGitHubRepositorySelected(tester, binding);
  await _exerciseDeploymentSettingsDialog(tester, projectName: projectName);
  await _exerciseDeploymentPreflight(tester);
  await _deployCurrentRepository(tester, firstDeploy: true);
  await _exerciseSaveEnvironmentAndRedeploy(tester);

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
  await _waitForEnabledButton(
    tester,
    const Key('app-release-rollback-previous-button'),
    description: 'application rollback action',
    timeout: const Duration(minutes: 3),
  );

  final beforeSuccess = await _readVmReleaseState(projectSlug);
  await _tap(tester, const Key('app-release-rollback-previous-button'));
  await _confirmAppRollback(tester);
  await _waitFor(
    tester,
    find.text('Rollback finished'),
    description: 'successful application rollback result',
    timeout: const Duration(minutes: 8),
  );
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'OK'),
    description: 'acknowledge successful application rollback',
  );
  await _waitForStatusText(
    tester,
    const Key('github-status-text'),
    'Ready',
    description: 'ready app after rollback',
    timeout: const Duration(minutes: 3),
  );
  final afterSuccess = await _readVmReleaseState(projectSlug);
  expect(afterSuccess.liveReleaseId, isNot(beforeSuccess.liveReleaseId));
  expect(afterSuccess.liveDeploymentKind, 'rollback');
  expect(afterSuccess.liveRollbackFromReleaseId, beforeSuccess.liveReleaseId);
  expect(afterSuccess.liveImageName, beforeSuccess.rollbackImageName);
  _pass(
    'Project Web App::Rollback to previous release',
    'The UI rollback created a health-gated rollback release from the '
        'previous retained image and the routed app returned to Ready.',
    const <String, Object?>{
      'live_release_changed': true,
      'rollback_release_created': true,
      'retained_image_reused': true,
    },
  );

  await _removeVmRollbackTarget(projectSlug);
  await _tap(tester, const Key('app-release-history-refresh-button'));
  await _waitForEnabledButton(
    tester,
    const Key('app-release-rollback-previous-button'),
    description: 'application rollback failure action',
    timeout: const Duration(minutes: 3),
  );
  final beforeFailure = await _readVmReleaseState(projectSlug);
  await _tap(tester, const Key('app-release-rollback-previous-button'));
  await _confirmAppRollback(tester);
  await _waitFor(
    tester,
    find.text('Rollback failed'),
    description: 'failed application rollback result',
    timeout: const Duration(minutes: 5),
  );
  await _tapFinder(
    tester,
    find.widgetWithText(FilledButton, 'OK'),
    description: 'acknowledge failed application rollback',
  );
  final afterFailure = await _readVmReleaseState(projectSlug);
  expect(afterFailure.liveReleaseId, beforeFailure.liveReleaseId);
  final verification = await _runRequiredVmScript(
    'docker inspect -f "{{.State.Running}}" "\$LIVE_CONTAINER" | grep -Fx true',
    description: 'live application remains running after failed rollback',
    environment: <String, String>{
      'LIVE_CONTAINER': afterFailure.liveContainerName,
    },
    sudo: true,
  );
  _pass(
    'Project Web App::Rollback failure path',
    'A missing retained image produced a visible rollback failure without '
        'changing or stopping the live release.',
    <String, Object?>{
      'live_release_unchanged': true,
      'live_container_running': verification.exitCode == 0,
    },
  );
}

Future<void> _ensureGitHubRepositorySelected(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  await _openProjectTab(
    tester,
    'Web app',
    find.byKey(const Key('app-tab-scroll')),
  );
  final entry = await _waitForAny(
    tester,
    <String, Finder>{
      'connect': find.byKey(const Key('connect-github-button')),
      'repositories': find.byKey(const Key('github-repo-dropdown')),
    },
    description: 'GitHub connection for production-safety scenario',
    timeout: const Duration(seconds: 45),
  );
  if (entry == 'connect') {
    if (_pauseAtManualGitHub) {
      await _waitForFocusedManualGitHubSelection(tester, binding);
      return;
    }
    final username = Platform.environment['DEPLOYDASH_E2E_GITHUB_USERNAME'];
    final password = Platform.environment['DEPLOYDASH_E2E_GITHUB_PASSWORD'];
    if (username == null ||
        username.trim().isEmpty ||
        password == null ||
        password.isEmpty) {
      fail('GitHub E2E credentials are required for this scenario.');
    }
    await _tap(tester, const Key('connect-github-button'));
    final authUrl = await _tapCopyOauthUrlAndConfirmCopied(tester);
    final callbackUrl = await _runGitHubBrowserLogin(authUrl);
    await _waitFor(
      tester,
      find.byKey(const Key('github-callback-field')),
      description: 'GitHub callback field',
    );
    await tester.enterText(
      find.byKey(const Key('github-callback-field')),
      callbackUrl,
    );
    await _tap(tester, const Key('github-process-callback-button'));
    await _waitFor(
      tester,
      find.byKey(const Key('github-repo-dropdown')),
      description: 'GitHub repositories after authentication',
      timeout: const Duration(minutes: 2),
    );
    binding.shouldPropagateDevicePointerEvents = false;
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
}

class _VmReleaseState {
  const _VmReleaseState({
    required this.liveReleaseId,
    required this.liveContainerName,
    required this.liveImageName,
    required this.liveDeploymentKind,
    required this.liveRollbackFromReleaseId,
    required this.rollbackReleaseId,
    required this.rollbackContainerName,
    required this.rollbackImageName,
  });

  final String liveReleaseId;
  final String liveContainerName;
  final String liveImageName;
  final String liveDeploymentKind;
  final String? liveRollbackFromReleaseId;
  final String rollbackReleaseId;
  final String rollbackContainerName;
  final String rollbackImageName;
}

Future<_VmReleaseState> _readVmReleaseState(String projectSlug) async {
  final result = await _runRequiredVmScript(
    r'''python3 - "$PROJECT_SLUG" <<'PY'
import json
import pathlib
import sys

slug = sys.argv[1]
path = pathlib.Path('/opt/deploydash/stack/apps/.deploydash/apps') / slug / 'releases.json'
payload = json.loads(path.read_text(encoding='utf-8'))
releases = payload.get('releases') or []
live = next((item for item in releases if item.get('status') == 'live'), None)
rollback = next((item for item in releases if item.get('status') == 'retained'), None)
if live is None or rollback is None:
    raise SystemExit('Expected one live and one retained release.')
print(json.dumps({
    'live_release_id': live.get('release_id', ''),
    'live_container_name': live.get('web_container_name', ''),
    'live_image_name': live.get('image_name', ''),
    'live_deployment_kind': live.get('deployment_kind', ''),
    'live_rollback_from_release_id': live.get('rollback_from_release_id'),
    'rollback_release_id': rollback.get('release_id', ''),
    'rollback_container_name': rollback.get('web_container_name', ''),
    'rollback_image_name': rollback.get('image_name', ''),
}))
PY''',
    description: 'read application release manifest',
    environment: <String, String>{'PROJECT_SLUG': projectSlug},
    sudo: true,
  );
  final decoded = jsonDecode(result.stdout.toString().trim());
  if (decoded is! Map<String, dynamic>) {
    fail('The application release manifest evidence was malformed.');
  }
  String requiredValue(String key) {
    final value = decoded[key]?.toString().trim() ?? '';
    if (value.isEmpty) {
      fail('The application release manifest omitted $key.');
    }
    return value;
  }

  String? optionalValue(String key) {
    final value = decoded[key]?.toString().trim() ?? '';
    return value.isEmpty ? null : value;
  }

  return _VmReleaseState(
    liveReleaseId: requiredValue('live_release_id'),
    liveContainerName: requiredValue('live_container_name'),
    liveImageName: requiredValue('live_image_name'),
    liveDeploymentKind: requiredValue('live_deployment_kind'),
    liveRollbackFromReleaseId: optionalValue('live_rollback_from_release_id'),
    rollbackReleaseId: requiredValue('rollback_release_id'),
    rollbackContainerName: requiredValue('rollback_container_name'),
    rollbackImageName: requiredValue('rollback_image_name'),
  );
}

Future<void> _removeVmRollbackTarget(String projectSlug) async {
  final state = await _readVmReleaseState(projectSlug);
  await _runRequiredVmScript(
    'docker rm -f "\$ROLLBACK_CONTAINER" >/dev/null 2>&1 || true\n'
    'docker image rm -f "\$ROLLBACK_IMAGE" >/dev/null',
    description: 'remove retained application rollback target',
    environment: <String, String>{
      'ROLLBACK_CONTAINER': state.rollbackContainerName,
      'ROLLBACK_IMAGE': state.rollbackImageName,
    },
    sudo: true,
  );
}
