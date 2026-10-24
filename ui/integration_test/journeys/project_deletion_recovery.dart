part of '../e2e_checklist_test.dart';

Future<void> _runProjectDeletionRecoveryScenario(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  binding.shouldPropagateDevicePointerEvents = false;
  final suffix = DateTime.now().millisecondsSinceEpoch.remainder(1000000);
  final projectName = 'E2E deletion recovery $suffix';
  final projectSlug = _e2eProjectSlug(projectName);
  await _createProject(tester, name: projectName, runtime: 'PHP');
  final container = ProviderScope.containerOf(
    tester.element(find.byKey(const Key('app-tab-scroll'))),
    listen: false,
  );
  final project = container
      .read(projectListProvider)
      .singleWhere((item) => item.name == projectName);
  await _runRequiredVmScript(
    'mkdir -p "/opt/deploydash/stack/apps/\$PROJECT_SLUG"\n'
    'printf recovery > "/opt/deploydash/stack/apps/\$PROJECT_SLUG/e2e-marker"',
    description: 'project deletion remote fixture',
    environment: <String, String>{'PROJECT_SLUG': projectSlug},
    sudo: true,
  );

  await _stopE2eVm();
  await _openProjectTab(
    tester,
    'Settings',
    find.byKey(const Key('settings-delete-button')),
  );
  await _tap(tester, const Key('settings-delete-button'));
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('settings-delete-confirm-input')),
    projectName,
    description: 'project deletion confirmation name',
  );
  await _tap(tester, const Key('settings-delete-confirm-checkbox'));
  await _tap(tester, const Key('settings-delete-confirm-button'));
  final recoveryCard = find.byKey(Key('home-project-cleanup-${project.id}'));
  await _waitFor(
    tester,
    recoveryCard,
    description: 'durable project cleanup recovery',
    timeout: const Duration(minutes: 3),
  );
  expect(find.text('Cleanup required for $projectName'), findsOneWidget);
  _pass(
    'Project Email, Domain, And Settings::Project delete failure/warning path',
    'A remote outage hid the project from normal use and exposed a retryable cleanup record on Home.',
  );

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await tester.pumpWidget(_buildE2eRootApp());
  await _unlockLocalDatabase(tester);
  await _waitForHome(tester);
  await _waitFor(
    tester,
    recoveryCard,
    description: 'project cleanup recovery after restart',
  );

  await _startE2eVm();
  await _tap(tester, Key('home-project-cleanup-retry-${project.id}'));
  await _waitForAbsent(
    tester,
    recoveryCard,
    description: 'completed project cleanup recovery',
    timeout: const Duration(minutes: 6),
  );
  await _runRequiredVmScript(
    '[ ! -e "/opt/deploydash/stack/apps/\$PROJECT_SLUG" ]',
    description: 'project remote cleanup completion',
    environment: <String, String>{'PROJECT_SLUG': projectSlug},
    sudo: true,
  );
  expect(find.text(projectName), findsNothing);
  _pass(
    'Project Email, Domain, And Settings::Project delete workflow',
    'Retried the durable tombstone and completed all remote and local cleanup steps.',
  );
  _pass(
    'Core App Shell::Delete last project and empty Home state',
    'The only disposable project remained hidden through failure and was removed after retry.',
  );
}

Future<void> _stopE2eVm() async {
  final result = await Process.run(_multipassBin, <String>['stop', _vmName]);
  if (result.exitCode != 0) {
    fail('Could not stop E2E VM $_vmName: ${result.stderr}');
  }
}

Future<void> _startE2eVm() async {
  final result = await Process.run(_multipassBin, <String>['start', _vmName]);
  if (result.exitCode != 0) {
    fail('Could not start E2E VM $_vmName: ${result.stderr}');
  }
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (DateTime.now().isBefore(deadline)) {
    Socket? socket;
    try {
      socket = await Socket.connect(
        _vmHost,
        22,
        timeout: const Duration(seconds: 2),
      );
    } on Object {
      socket = null;
    }
    if (socket != null) {
      socket.destroy();
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  fail('SSH did not return after starting E2E VM $_vmName.');
}
