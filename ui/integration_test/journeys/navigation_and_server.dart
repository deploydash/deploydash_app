part of '../e2e_checklist_test.dart';

// system-apply-button's onPressed becomes null (disabled) the instant
// _isApplying flips true (system_tab.dart), before the button eventually
// disappears once the apply succeeds and _isDirty clears. That disabled
// state is a fast, purely client-side signal; a missed tap here would skip
// it entirely, leaving the button enabled and the caller's long wait for
// its disappearance just timing out with no useful signal.
Future<void> _tapSystemApplyAndConfirmStarted(WidgetTester tester) async {
  final applyButton = find.byKey(const Key('system-apply-button'));
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(tester, applyButton, description: 'apply system settings');
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
  fail('Tapping Apply changes never started applying system settings.');
}

// Both Docker storage prune confirmations tap a button inside a dialog and
// then wait up to 4 minutes for a "Finished removing..." result text, with
// nothing confirming the tap actually closed the dialog first. The prompt
// text disappearing is a fast, purely client-side signal a missed tap
// would skip, leaving the dialog open and the long wait for a result that
// will never come.
Future<void> _tapDockerPruneConfirmAndConfirmDialogClosed(
  WidgetTester tester, {
  required Key confirmKey,
  required Finder promptFinder,
  required String description,
}) async {
  final confirmButton = find.byKey(confirmKey);
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(tester, confirmButton, description: description);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (promptFinder.evaluate().isEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail('Tapping $description never closed the confirmation dialog.');
}

Future<void> _exerciseTerminalCollapsedExpandedStates(
  WidgetTester tester,
) async {
  await _waitFor(
    tester,
    find.byKey(const Key('terminal-sheet')),
    description: 'bottom terminal shell',
  );
  expect(find.byKey(const Key('terminal-selectable-output')), findsNothing);
  await _tap(tester, const Key('terminal-minimize-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('terminal-selectable-output')),
    description: 'expanded terminal output',
  );
  await _tap(tester, const Key('queue-tab-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('terminal-queue-list')),
    description: 'advanced activity queue',
  );
  await _tap(tester, const Key('terminal-tab-button'));
  _pass('Core App Shell::Advanced activity current vs old tasks');
  await _tap(tester, const Key('terminal-minimize-button'));
  await tester.pumpAndSettle(const Duration(milliseconds: 200));
  expect(find.byKey(const Key('terminal-selectable-output')), findsNothing);
  _pass('Core App Shell::Bottom terminal collapsed/expanded states');
}

Future<void> _restartAndUnlockExistingDatabase(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await tester.pumpWidget(_buildE2eRootApp());
  await _unlockLocalDatabase(tester);
  await _waitForHome(tester);
  _pass('Core App Shell::App restart and unlock existing isolated DB');
}

Future<void> _openServerManagementFromHome(WidgetTester tester) async {
  // Not the rail's 'left-rail-current-server' shortcut: that row is
  // deliberately hidden while workspaceMode is home (main.dart's
  // showCurrentServerRow only shows it inside server management or the add-
  // server flow -- see shell_page_test.dart's assertion that it is absent
  // from a project workspace too). The real, currently supported path from
  // Home is the manage-server button on the server's row in the Home
  // dashboard's servers card, exactly as shell_page_test.dart's own
  // _openServerManagementFromHome helper exercises it.
  final manageButton = find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> &&
        key.value.startsWith('home-server-manage-');
  });
  await _tapFinder(
    tester,
    manageButton,
    description: 'home dashboard manage-server button',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('server-management-nav-overview')),
    description: 'server management navigation',
  );
}

Future<void> _openHome(WidgetTester tester) async {
  await _tap(tester, const Key('left-rail-home-button'));
  await _waitForHome(tester);
}

Future<void> _createProject(
  WidgetTester tester, {
  required String name,
  String runtime = 'Python',
}) async {
  await _openHome(tester);
  await _tap(tester, const Key('home-new-project-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('create-project-name-field')),
    description: 'create project form',
  );
  await tester.enterText(
    find.byKey(const Key('create-project-name-field')),
    name,
  );
  await _tap(tester, const Key('create-project-runtime-field'));
  await _tapFinder(tester, find.text(runtime).last, description: runtime);
  await _tap(tester, const Key('create-project-submit-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('app-tab-scroll')),
    description: 'created project workspace',
  );
}

Future<void> _openProjectFromHome(
  WidgetTester tester,
  String projectName,
) async {
  await _openHome(tester);
  final projectsCard = find.byKey(const Key('home-projects-card'));
  final projectText = find.descendant(
    of: projectsCard,
    matching: find.text(projectName),
  );
  await _scrollUntilMounted(
    tester,
    projectText,
    within: find.byKey(const Key('home-dashboard-scroll')),
    description: 'Home project $projectName',
  );
  await tester.ensureVisible(projectText.first);
  await tester.pumpAndSettle();
  await _tapFinder(tester, projectText.first, description: projectName);
  await _waitFor(
    tester,
    find.byKey(const Key('app-tab-scroll')),
    description: 'project workspace for $projectName',
  );
}

String? _railWidgetKeyValue(Widget widget) {
  final key = widget.key;
  return key is ValueKey<String> ? key.value : null;
}

Finder _railWidgetsWithKeyPrefix(String prefix) => find.byWidgetPredicate(
  (widget) => _railWidgetKeyValue(widget)?.startsWith(prefix) ?? false,
);

Future<void> _openProjectFromRail(
  WidgetTester tester,
  String projectName,
) async {
  final recentsList = find.byKey(const Key('left-rail-recent-projects-list'));
  final railProject = find.descendant(
    of: recentsList,
    matching: find.text(projectName),
  );
  // recordVisit() is deliberately fire-and-forget (unawaited) so the rail
  // never blocks the UI on the encrypted local database write -- see
  // RecentProjectVisitsNotifier.recordVisit. That means the rail can still
  // be showing left-rail-recent-empty (no left-rail-recent-projects-list
  // mounted at all yet) right after a tab switch, which made
  // scrollUntilVisible's internal use of Finder.first crash with
  // "Bad state: No element" rather than time out, because it assumes the
  // scrollable already exists. Wait for the project to actually be findable
  // first; _waitFor tolerates the list not existing yet and keeps polling.
  await _waitFor(
    tester,
    railProject,
    description: 'recent project $projectName to be recorded',
    timeout: const Duration(seconds: 15),
  );
  await tester.scrollUntilVisible(
    railProject,
    120,
    scrollable: find
        .descendant(of: recentsList, matching: find.byType(Scrollable))
        .first,
  );
  await tester.pumpAndSettle();
  await _waitFor(
    tester,
    railProject,
    description: 'recent project $projectName',
  );
  final header = find.ancestor(
    of: railProject.first,
    matching: _railWidgetsWithKeyPrefix('left-rail-recent-project-'),
  );
  final headerKey = _railWidgetKeyValue(tester.widget(header.first));
  if (headerKey == null) {
    fail('Recent project header for $projectName has no usable key');
  }
  final projectId = headerKey.substring('left-rail-recent-project-'.length);
  final screenRow = _railWidgetsWithKeyPrefix(
    'left-rail-recent-screen-$projectId-',
  );
  await _tapFinder(
    tester,
    screenRow.first,
    description: 'recent screen for $projectName',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('app-tab-scroll')),
    description: 'project workspace for $projectName',
  );
}

Future<void> _openProjectTab(
  WidgetTester tester,
  String tabLabel,
  Finder contentFinder,
) async {
  const destinationIds = <String, String>{
    'Web app': 'web-app',
    'Workers': 'workers',
    'Database': 'database',
    'Email': 'email',
    'Domain': 'domain',
    'Backup': 'backup',
    'Scheduler': 'scheduler',
    'Log': 'log',
    'Settings': 'settings',
  };
  final destinationId = destinationIds[tabLabel];
  if (destinationId == null) {
    fail('Unknown project workspace destination: $tabLabel');
  }
  await _tap(tester, Key('project-workspace-nav-$destinationId'));
  await _waitFor(tester, contentFinder, description: '$tabLabel tab content');
}

Future<void> _exerciseServerManagementTabs(WidgetTester tester) async {
  await _waitFor(
    tester,
    find.byKey(const Key('server-management-overview-tab')),
    description: 'server overview tab',
    timeout: const Duration(minutes: 2),
  );
  _pass('Server Management::Overview tab load');

  await _tap(tester, const Key('server-management-nav-services'));
  await _waitFor(
    tester,
    find.byKey(const Key('server-management-services-tab')),
    description: 'server services tab',
  );
  _pass('Server Management::Services tab load');
  _pass('Server Management::Services container status copy');

  await _tap(tester, const Key('server-management-nav-updates'));
  await _waitFor(
    tester,
    find.byKey(const Key('server-management-updates-tab')),
    description: 'server updates tab',
  );
  _pass('Server Management::Updates tab load');
  _pass('Server Management::Updates version vs health separation');

  await _tap(tester, const Key('server-management-nav-security'));
  await _waitFor(
    tester,
    find.byKey(const Key('server-management-firewall-tab')),
    description: 'server security tab',
  );
  expect(find.text('Firewall status'), findsOneWidget);
  expect(find.byKey(const Key('firewall-refresh-button')), findsOneWidget);
  _pass('Server Management::Firewall status');
  _pass('Server Management::Firewall scan open ports');

  await _tap(tester, const Key('server-management-nav-settings'));
  await _waitFor(
    tester,
    find.byKey(const Key('server-management-system-tab')),
    description: 'server settings tab',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('system-server-host-input')),
    description: 'server address field',
  );
  _pass('Server Management::Server hostname/IP edit in Settings');

  final automaticSecurityUpdates = find.text('Automatic Security Updates');
  await _scrollUntilMounted(
    tester,
    automaticSecurityUpdates,
    within: find.byKey(const Key('server-management-system-tab')),
    description: 'Automatic Security Updates settings',
  );
  await tester.ensureVisible(automaticSecurityUpdates);
  await tester.pumpAndSettle();
  final autoRebootTile = find.ancestor(
    of: find.text('Auto-Reboot for Security Updates'),
    matching: find.byType(SwitchListTile),
  );
  await _tapFinder(
    tester,
    autoRebootTile.first,
    description: 'Auto-Reboot for Security Updates',
  );
  await _waitForEnabledButton(
    tester,
    const Key('system-apply-button'),
    description: 'system apply button',
  );
  await _tapSystemApplyAndConfirmStarted(tester);
  // Not 'In sync': that persistent status label was removed from
  // system_tab.dart on 2026-08-05 (a67a6b2) in favor of a transient apply
  // toolbar. The toolbar (the apply button and 'Unsaved changes' label) is
  // shown only while `_isDirty || _isApplying`, so its disappearance is the
  // current, correct signal that the apply finished and the config is no
  // longer dirty -- waiting for a literal success message would couple this
  // journey to backend wording that is not part of any contract.
  await _waitForAbsent(
    tester,
    find.byKey(const Key('system-apply-button')),
    description: 'applied system settings',
    timeout: const Duration(minutes: 3),
  );
  _pass('Server Management::System settings load/apply');
  _pass('Server Management::Automatic updates settings');

  final dockerStorageSection = find.byKey(
    const Key('server-management-docker-storage-section'),
  );
  await _scrollUntilMounted(
    tester,
    dockerStorageSection,
    within: find.byKey(const Key('server-management-system-tab')),
    description: 'Docker storage section',
  );
  await tester.ensureVisible(dockerStorageSection);
  await tester.pumpAndSettle();
  await _tap(tester, const Key('docker-storage-refresh-button'));
  await _waitFor(
    tester,
    find.text('Docker storage'),
    description: 'Docker storage usage section',
    timeout: const Duration(minutes: 2),
  );
  _pass('Server Management::Docker image/cache usage scan');

  await _waitForEnabledButton(
    tester,
    const Key('docker-storage-prune-cache-button'),
    description: 'Docker build cache prune button',
    timeout: const Duration(minutes: 2),
  );
  await _tap(tester, const Key('docker-storage-prune-cache-button'));
  await _waitFor(
    tester,
    find.text('Delete Docker build cache?'),
    description: 'Docker build cache prune confirmation',
  );
  await _tapDockerPruneConfirmAndConfirmDialogClosed(
    tester,
    confirmKey: const Key('docker-storage-confirm-build-cache-button'),
    promptFinder: find.text('Delete Docker build cache?'),
    description: 'confirm Docker build cache prune',
  );
  await _waitFor(
    tester,
    find.textContaining('Finished removing the Docker build cache'),
    description: 'Docker build cache prune result',
    timeout: const Duration(minutes: 4),
  );

  await _waitForEnabledButton(
    tester,
    const Key('docker-storage-prune-images-button'),
    description: 'unused Docker images prune button',
    timeout: const Duration(minutes: 2),
  );
  await _tap(tester, const Key('docker-storage-prune-images-button'));
  await _waitFor(
    tester,
    find.text('Delete unused Docker images?'),
    description: 'unused Docker images prune confirmation',
  );
  await _tapDockerPruneConfirmAndConfirmDialogClosed(
    tester,
    confirmKey: const Key('docker-storage-confirm-unused-images-button'),
    promptFinder: find.text('Delete unused Docker images?'),
    description: 'confirm unused Docker images prune',
  );
  await _waitFor(
    tester,
    find.textContaining('Finished removing unused Docker images'),
    description: 'unused Docker images prune result',
    timeout: const Duration(minutes: 4),
  );
  _pass('Server Management::Docker image/cache prune');
}
