part of '../e2e_checklist_test.dart';

Future<void> _captureOnboardingUxAudit(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  if (_reuseE2eProfile) {
    fail(
      'DEPLOYDASH_E2E_CAPTURE_ONBOARDING_UX_AUDIT_ONLY requires a fresh profile.',
    );
  }

  await _waitFor(
    tester,
    find.byKey(const Key('server-onboarding-start-button')),
    description: 'server onboarding introduction',
  );
  await _captureCurrentSurfaceAtWideAndCompact(
    tester,
    binding,
    name: 'onboarding-intro',
  );

  await _tap(tester, const Key('server-onboarding-start-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('server-password-field')),
    description: 'password server credentials',
  );
  await _captureCurrentSurfaceAtWideAndCompact(
    tester,
    binding,
    name: 'onboarding-password-credentials',
  );

  await _tapFinder(
    tester,
    find.text('SSH key'),
    description: 'SSH key sign-in method',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('server-key-picker-button')),
    description: 'SSH key server credentials',
  );
  await _captureCurrentSurfaceAtWideAndCompact(
    tester,
    binding,
    name: 'onboarding-ssh-key-credentials',
  );

  stdout.writeln('DEPLOYDASH_E2E_ONBOARDING_UX_AUDIT_COMPLETE');
}

Future<void> _captureWorkspaceUxAudit(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  if (!_reuseE2eProfile) {
    fail(
      'DEPLOYDASH_E2E_CAPTURE_WORKSPACE_UX_AUDIT_ONLY requires profile reuse.',
    );
  }

  await _waitForHome(tester);
  await _captureCurrentSurfaceAtWideAndCompact(tester, binding, name: 'home');

  final container = ProviderScope.containerOf(
    tester.element(find.byKey(const Key('home-overview-panel'))),
    listen: false,
  );
  final projects = container.read(projectListProvider);
  final liveProjects = projects
      .where(
        (project) =>
            project.lastDeployedAt != null &&
            (project.lastDeployCommit?.trim().isNotEmpty ?? false),
      )
      .toList(growable: false);
  final repositoryProjects = liveProjects
      .where(
        (project) =>
            project.repositoryFullName?.trim() == _githubRepositoryFullName,
      )
      .toList(growable: false);
  final activeProjects = projects
      .where((project) => project.isActive)
      .toList(growable: false);
  final selectedProject = repositoryProjects.isNotEmpty
      ? repositoryProjects.last
      : liveProjects.isNotEmpty
      ? liveProjects.last
      : activeProjects.isNotEmpty
      ? activeProjects.last
      : projects.isNotEmpty
      ? projects.last
      : null;
  if (selectedProject == null) {
    fail('The reused E2E profile does not contain a project to audit.');
  }

  stdout.writeln(
    'DEPLOYDASH_E2E_WORKSPACE_UX_AUDIT_PROJECT=${selectedProject.name}',
  );
  await _openProjectFromHome(tester, selectedProject.name);

  await _captureProjectSurface(
    tester,
    binding,
    tabLabel: 'Workers',
    contentFinder: find.byKey(const Key('workers-tab-scroll')),
    name: 'project-workers',
  );
  await _captureProjectSurface(
    tester,
    binding,
    tabLabel: 'Database',
    contentFinder: find.byKey(const Key('database-tab-scroll')),
    name: 'project-database-sqlite',
  );
  final selectedServer = container.read(selectedServerProvider);
  if (selectedServer?.serviceDatabaseEnabled == true) {
    await _captureCurrentSurfaceAtWideAndCompact(
      tester,
      binding,
      name: 'project-database-postgres',
      prepareSurface: () => _selectPostgresDatabaseAuditSurface(tester),
    );
  } else {
    stdout.writeln(
      'DEPLOYDASH_E2E_WORKSPACE_UX_AUDIT_SKIPPED='
      'project-database-postgres:service-disabled',
    );
  }
  await _captureProjectSurface(
    tester,
    binding,
    tabLabel: 'Email',
    contentFinder: find.byKey(const Key('email-unavailable-state')),
    name: 'project-email',
  );
  await _captureProjectSurface(
    tester,
    binding,
    tabLabel: 'Domain',
    contentFinder: find.byKey(const Key('domain-unavailable-state')),
    name: 'project-domain',
  );
  await _captureProjectSurface(
    tester,
    binding,
    tabLabel: 'Backup',
    contentFinder: find.byKey(const Key('backup-add-destination-button')),
    alternateContentFinder: find.byKey(
      const Key('backup-open-server-services-button'),
    ),
    name: 'project-backup',
  );
  await _captureProjectSurface(
    tester,
    binding,
    tabLabel: 'Scheduler',
    contentFinder: find.byKey(const Key('scheduler-add-task-button')),
    name: 'project-scheduler',
  );
  await _captureProjectSurface(
    tester,
    binding,
    tabLabel: 'Log',
    contentFinder: find.byKey(const Key('app-log-card')),
    name: 'project-log-runtime',
  );
  await _captureCurrentSurfaceAtWideAndCompact(
    tester,
    binding,
    name: 'project-log-deployment',
    prepareSurface: () => _selectDeploymentLogAuditSurface(tester),
  );
  await _captureProjectSurface(
    tester,
    binding,
    tabLabel: 'Settings',
    contentFinder: find.byKey(const Key('settings-delete-button')),
    name: 'project-settings',
  );

  await _openHome(tester);
  await _openServerManagementFromHome(tester);
  await _captureServerManagementSurface(
    tester,
    binding,
    navigationKey: const Key('server-management-nav-overview'),
    contentKey: const Key('server-management-overview-tab'),
    name: 'server-overview',
  );
  await _captureServerManagementSurface(
    tester,
    binding,
    navigationKey: const Key('server-management-nav-services'),
    contentKey: const Key('server-management-services-tab'),
    name: 'server-services',
  );
  await _captureServerManagementSurface(
    tester,
    binding,
    navigationKey: const Key('server-management-nav-updates'),
    contentKey: const Key('server-management-updates-tab'),
    name: 'server-updates',
  );
  await _captureServerManagementSurface(
    tester,
    binding,
    navigationKey: const Key('server-management-nav-security'),
    contentKey: const Key('server-management-firewall-tab'),
    name: 'server-security',
  );
  await _captureServerManagementSurface(
    tester,
    binding,
    navigationKey: const Key('server-management-nav-settings'),
    contentKey: const Key('server-management-system-tab'),
    name: 'server-settings',
  );

  await _tap(tester, const Key('left-rail-app-settings-button'));
  await _captureAppSettingsSurface(
    tester,
    binding,
    navigationKey: const Key('app-settings-nav-appearance'),
    contentKey: const Key('app-settings-appearance-section'),
    name: 'app-settings-appearance',
  );
  await _captureAppSettingsSurface(
    tester,
    binding,
    navigationKey: const Key('app-settings-nav-agent-access'),
    contentKey: const Key('app-settings-agent-access-section'),
    name: 'app-settings-agent-access',
  );
  await _captureAppSettingsSurface(
    tester,
    binding,
    navigationKey: const Key('app-settings-nav-app-backup'),
    contentKey: const Key('app-settings-app-backup-section'),
    name: 'app-settings-app-backup',
  );
  await _captureAppSettingsSurface(
    tester,
    binding,
    navigationKey: const Key('app-settings-nav-security'),
    contentKey: const Key('app-settings-security-section'),
    name: 'app-settings-security',
  );

  const wideSize = Size(1200, 800);
  await windowManager.setSize(wideSize);
  await binding.setSurfaceSize(wideSize);
  await tester.pumpAndSettle();
  stdout.writeln('DEPLOYDASH_E2E_WORKSPACE_UX_AUDIT_COMPLETE');
}

Future<void> _captureProjectSurface(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String tabLabel,
  required Finder contentFinder,
  Finder? alternateContentFinder,
  required String name,
}) async {
  await _tap(
    tester,
    Key(
      'project-workspace-nav-${switch (tabLabel) {
        'Workers' => 'workers',
        'Database' => 'database',
        'Email' => 'email',
        'Domain' => 'domain',
        'Backup' => 'backup',
        'Scheduler' => 'scheduler',
        'Log' => 'log',
        'Settings' => 'settings',
        _ => throw ArgumentError.value(tabLabel, 'tabLabel'),
      }}',
    ),
  );
  if (alternateContentFinder == null) {
    await _waitFor(tester, contentFinder, description: '$tabLabel audit tab');
  } else {
    await _waitForAny(
      tester,
      <String, Finder>{
        'primary': contentFinder,
        'alternate': alternateContentFinder,
      },
      description: '$tabLabel audit tab',
      timeout: const Duration(minutes: 2),
    );
  }
  await _captureCurrentSurfaceAtWideAndCompact(tester, binding, name: name);
}

Future<void> _captureServerManagementSurface(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required Key navigationKey,
  required Key contentKey,
  required String name,
}) async {
  await _tap(tester, navigationKey);
  await _waitFor(
    tester,
    find.byKey(contentKey),
    description: '$name audit surface',
    timeout: const Duration(minutes: 2),
  );
  await _waitForVisibleProgressToSettle(tester);
  await _captureCurrentSurfaceAtWideAndCompact(tester, binding, name: name);
}

Future<void> _captureAppSettingsSurface(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required Key navigationKey,
  required Key contentKey,
  required String name,
}) async {
  await _tap(tester, navigationKey);
  await _waitFor(
    tester,
    find.byKey(contentKey),
    description: '$name audit surface',
  );
  await _waitForVisibleProgressToSettle(tester);
  await _captureCurrentSurfaceAtWideAndCompact(tester, binding, name: name);
}

Future<void> _waitForVisibleProgressToSettle(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (find
        .byType(CircularProgressIndicator)
        .hitTestable()
        .evaluate()
        .isEmpty) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

Future<void> _selectPostgresDatabaseAuditSurface(WidgetTester tester) async {
  await _tap(tester, const Key('database-type-postgres-tab'));
  await _waitForAbsent(
    tester,
    find.byKey(const Key('database-sqlite-card')),
    description: 'PostgreSQL database audit surface',
  );
}

Future<void> _selectDeploymentLogAuditSurface(WidgetTester tester) async {
  await _tap(tester, const Key('log-deployment-tab'));
  await tester.pumpAndSettle();
  await _waitFor(
    tester,
    find.byKey(const Key('deployment-log-filter-field')).hitTestable(),
    description: 'deployment log audit surface',
  );
  expect(
    find.byKey(const Key('deployment-log-filter-field')).hitTestable(),
    findsOneWidget,
  );
  expect(find.byKey(const Key('log-filter-field')).hitTestable(), findsNothing);
}

Future<void> _captureCurrentSurfaceAtWideAndCompact(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String name,
  Future<void> Function()? prepareSurface,
}) async {
  if (!_captureE2eScreenshots) {
    return;
  }

  const wideSize = Size(1200, 800);
  await windowManager.setSize(wideSize);
  await binding.setSurfaceSize(wideSize);
  await tester.pumpAndSettle();
  await _waitForGlobalRailMode(tester, extended: true);
  await prepareSurface?.call();
  await _captureCurrentScrollableSurface(tester, name: '$name-wide');

  const compactSize = Size(760, 800);
  await windowManager.setSize(compactSize);
  await binding.setSurfaceSize(compactSize);
  await tester.pumpAndSettle();
  await _waitForGlobalRailMode(tester, extended: false);
  await prepareSurface?.call();
  await _captureCurrentScrollableSurface(tester, name: '$name-compact');

  await windowManager.setSize(wideSize);
  await binding.setSurfaceSize(wideSize);
  await tester.pumpAndSettle();
  await _waitForGlobalRailMode(tester, extended: true);
}

Future<void> _waitForGlobalRailMode(
  WidgetTester tester, {
  required bool extended,
}) async {
  final homeButton = find.byKey(const Key('left-rail-home-button'));
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (homeButton.evaluate().isNotEmpty) {
      final width = tester.getSize(homeButton).width;
      if ((extended && width > 100) || (!extended && width <= 60)) {
        return;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail(
    'Global navigation rail did not enter '
    '${extended ? 'extended' : 'compact'} mode.',
  );
}

Future<void> _captureCurrentScrollableSurface(
  WidgetTester tester, {
  required String name,
}) async {
  Finder? selectedScrollable;
  double selectedArea = -1;
  final scrollables = find.byType(Scrollable);
  for (var index = 0; index < scrollables.evaluate().length; index += 1) {
    final candidate = scrollables.at(index);
    final state = tester.state<ScrollableState>(candidate);
    final direction = state.position.axisDirection;
    if (direction != AxisDirection.down && direction != AxisDirection.up) {
      continue;
    }
    final box = tester.renderObject<RenderBox>(candidate);
    final origin = box.localToGlobal(Offset.zero);
    if (origin.dx < 80 || origin.dy < 40) {
      continue;
    }
    final area = box.size.width * box.size.height;
    if (area > selectedArea) {
      selectedArea = area;
      selectedScrollable = candidate;
    }
  }

  if (selectedScrollable == null) {
    await _writeE2eScreenshot(tester, '$name-01-top');
    return;
  }

  final position = tester.state<ScrollableState>(selectedScrollable).position;
  position.jumpTo(position.minScrollExtent);
  await tester.pumpAndSettle();
  await _writeE2eScreenshot(tester, '$name-01-top');

  final step = position.viewportDimension * 0.8;
  var currentOffset = position.pixels;
  var screenshotIndex = 1;
  while (currentOffset < position.maxScrollExtent - 1) {
    final nextOffset = (currentOffset + step).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    position.jumpTo(nextOffset);
    await tester.pumpAndSettle();
    final actualOffset = position.pixels;
    if (actualOffset <= currentOffset + 1) {
      break;
    }
    screenshotIndex += 1;
    final atBottom = actualOffset >= position.maxScrollExtent - 1;
    final suffix = atBottom ? 'bottom' : 'section-$screenshotIndex';
    await _writeE2eScreenshot(
      tester,
      '$name-${screenshotIndex.toString().padLeft(2, '0')}-$suffix',
    );
    currentOffset = actualOffset;
  }

  position.jumpTo(position.minScrollExtent);
  await tester.pumpAndSettle();
}

Widget _buildE2eRootApp() => RepaintBoundary(
  key: const Key('e2e-app-screenshot-boundary'),
  child: app.buildDeployDashRootApp(),
);

Future<void> _resumeSelectedProjectLiveWebAppAudit(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  if (!_reuseE2eProfile) {
    fail('DEPLOYDASH_E2E_RESUME_LIVE_AUDIT requires profile reuse.');
  }

  final container = ProviderScope.containerOf(
    tester.element(find.byKey(const Key('home-overview-panel'))),
    listen: false,
  );
  Project? selectedProject;
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    final projects = container.read(projectListProvider);
    final activeProjects = projects
        .where((project) => project.isActive)
        .toList(growable: false);
    if (_captureSelectedProjectLiveAuditOnly && activeProjects.isNotEmpty) {
      selectedProject = activeProjects.last;
      break;
    }
    final matches = projects
        .where(
          (project) =>
              project.repositoryFullName?.trim() == _githubRepositoryFullName,
        )
        .toList(growable: false);
    if (matches.isNotEmpty) {
      selectedProject = matches.last;
      break;
    }
    if (activeProjects.isNotEmpty) {
      selectedProject = activeProjects.last;
      break;
    }
  }
  if (selectedProject == null) {
    final projects = container.read(projectListProvider);
    if (projects.isNotEmpty) {
      selectedProject = projects.last;
    } else {
      fail('The reused E2E profile does not contain a project.');
    }
  }

  stdout.writeln(
    'DEPLOYDASH_E2E_RESUME_LIVE_AUDIT_PROJECT=${selectedProject.name}',
  );
  await _openProjectFromHome(tester, selectedProject.name);
  if (_captureSelectedProjectLiveAuditOnly) {
    final hasSuccessfulDeployment =
        selectedProject.lastDeployedAt != null &&
        (selectedProject.lastDeployCommit?.trim().isNotEmpty ?? false);
    if (hasSuccessfulDeployment) {
      await _waitForAbsent(
        tester,
        find.text('Not synced yet'),
        description: 'persisted live deployment state',
        timeout: const Duration(seconds: 30),
      );
    }
    await _captureWebAppWorkspaceScreenshots(
      tester,
      binding,
      phase: hasSuccessfulDeployment ? 'live-stable' : 'before-deploy-stable',
    );
    stdout.writeln('DEPLOYDASH_E2E_CAPTURE_LIVE_AUDIT_ONLY_COMPLETE');
    return;
  }

  final selectedRepository = find.text(_githubRepositoryFullName);
  final repositoryOutcome = await _waitForAny(
    tester,
    <String, Finder>{
      'selected': selectedRepository,
      'dropdown': find.byKey(const Key('github-repo-dropdown')),
    },
    description: 'GitHub repository selection',
    timeout: const Duration(minutes: 2),
  );
  if (repositoryOutcome == 'dropdown') {
    await _tap(tester, const Key('github-repo-dropdown'));
    await _tapFinder(
      tester,
      find.text(_githubRepositoryFullName).last,
      description: _githubRepositoryFullName,
    );
  }
  await _waitFor(
    tester,
    selectedRepository,
    description: 'GitHub repository selection',
    timeout: const Duration(minutes: 2),
  );
  expect(find.byKey(const Key('github-callback-field')), findsNothing);
  stdout.writeln('DEPLOYDASH_E2E_RESUME_LIVE_AUDIT_REPOSITORY_READY');
  await _exerciseDeploymentSettingsDialog(
    tester,
    projectName: selectedProject.name,
  );
  stdout.writeln('DEPLOYDASH_E2E_RESUME_LIVE_AUDIT_SETTINGS_READY');
  await _exerciseDeploymentPreflight(tester);
  stdout.writeln('DEPLOYDASH_E2E_RESUME_LIVE_AUDIT_PREFLIGHT_READY');
  await _deployCurrentRepository(tester, firstDeploy: true);
  stdout.writeln('DEPLOYDASH_E2E_RESUME_LIVE_AUDIT_DEPLOY_READY');
  await _captureWebAppWorkspaceScreenshots(tester, binding, phase: 'live');
  stdout.writeln('DEPLOYDASH_E2E_RESUME_LIVE_AUDIT_COMPLETE');
}

Future<void> _captureServerOverviewScreenshots(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  if (!_captureE2eScreenshots) {
    return;
  }

  await tester.pumpAndSettle();
  await _writeE2eScreenshot(tester, 'server-overview-wide');

  const compactSize = Size(760, 800);
  await windowManager.setSize(compactSize);
  await binding.setSurfaceSize(compactSize);
  await tester.pumpAndSettle();
  await _writeE2eScreenshot(tester, 'server-overview-compact');

  const wideSize = Size(1200, 800);
  await windowManager.setSize(wideSize);
  await binding.setSurfaceSize(wideSize);
  await tester.pumpAndSettle();
}

Future<void> _captureWebAppWorkspaceScreenshots(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String phase,
}) async {
  if (!_captureE2eScreenshots) {
    return;
  }

  await _openProjectTab(
    tester,
    'Web app',
    find.byKey(const Key('app-tab-scroll')),
  );
  await tester.pumpAndSettle();

  await _captureScrollableWebAppWorkspace(tester, phase: phase);

  const compactSize = Size(760, 800);
  await windowManager.setSize(compactSize);
  await binding.setSurfaceSize(compactSize);
  await tester.pumpAndSettle();
  await _captureScrollableWebAppWorkspace(tester, phase: '$phase-compact');

  const wideSize = Size(1200, 800);
  await windowManager.setSize(wideSize);
  await binding.setSurfaceSize(wideSize);
  await tester.pumpAndSettle();
}

Future<void> _captureScrollableWebAppWorkspace(
  WidgetTester tester, {
  required String phase,
}) async {
  final scrollableFinder = find
      .descendant(
        of: find.byKey(const Key('app-tab-scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
  final position = tester.state<ScrollableState>(scrollableFinder).position;
  final step = position.viewportDimension * 0.8;
  position.jumpTo(0);
  await tester.pumpAndSettle();
  await _writeE2eScreenshot(tester, 'web-app-$phase-01-top');

  var currentOffset = position.pixels;
  var screenshotIndex = 1;
  while (currentOffset < position.maxScrollExtent - 1) {
    final nextOffset = (currentOffset + step).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    position.jumpTo(nextOffset);
    await tester.pumpAndSettle();
    final actualOffset = position.pixels;
    if (actualOffset <= currentOffset + 1) {
      break;
    }
    screenshotIndex += 1;
    final atBottom = actualOffset >= position.maxScrollExtent - 1;
    final suffix = atBottom ? 'bottom' : 'section-$screenshotIndex';
    await _writeE2eScreenshot(
      tester,
      'web-app-$phase-${screenshotIndex.toString().padLeft(2, '0')}-$suffix',
    );
    currentOffset = actualOffset;
  }

  position.jumpTo(0);
  await tester.pumpAndSettle();
}

Future<void> _writeE2eScreenshot(WidgetTester tester, String name) async {
  final directoryPath = _e2eScreenshotDirectory.trim();
  if (directoryPath.isEmpty) {
    fail('DEPLOYDASH_E2E_SCREENSHOT_DIR is required for E2E screenshots.');
  }

  final collapsedSummary = find.byKey(
    const Key('terminal-collapsed-latest-output'),
  );
  if (collapsedSummary.evaluate().isNotEmpty) {
    final summary = tester.widget<Text>(collapsedSummary).data ?? '';
    final normalized = summary.toLowerCase();
    expect(normalized, isNot(contains('[ui] opening')));
    expect(normalized, isNot(contains('connected to')));
    expect(normalized, isNot(contains('connecting to')));
    expect(normalized, isNot(contains('disconnected from')));
    expect(normalized, isNot(contains('preparing connection for')));
    expect(normalized, isNot(contains('runtime operation')));
    expect(normalized, isNot(contains('task completed')));
  }

  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('e2e-app-screenshot-boundary')),
  );
  boundary.markNeedsPaint();
  await tester.pump();
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      fail('Flutter could not encode the $name E2E screenshot.');
    }
    final directory = Directory(directoryPath);
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}
