import 'dart:async';

import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/data/local/project_repository.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/models/result.dart';
import 'package:ui/main.dart';
import 'package:ui/ui/navigation/desktop_route.dart';
import 'package:ui/ui/shell/shell_page.dart';
import 'package:ui/providers/desktop_startup_provider.dart';
import 'package:ui/providers/pending_enrollment_provider.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/providers/server_provider.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/services/desktop_update_service.dart';
import 'package:ui/ui/terminal/terminal_bottom_sheet.dart';
import 'package:ui/ui/layout/app_navigation_rail.dart';
import 'package:ui/ui/project/project_workspace.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';
import '../../_support/legacy_ssh_service.dart';
import '../../_support/fake_analytics_service.dart';

const _seededServer = Server(
  id: 'server-prod-01',
  name: 'Prod-01',
  host: '203.0.113.10',
  port: 22,
  sshUser: 'root',
  authMethod: ServerAuthMethod.password,
  osName: 'Ubuntu 24.04 LTS',
);

const _secondServer = Server(
  id: 'server-staging-01',
  name: 'Staging-01',
  host: '203.0.113.11',
  port: 22,
  sshUser: 'root',
  authMethod: ServerAuthMethod.password,
  osName: 'Ubuntu 24.04 LTS',
);

Future<Map<String, dynamic>?> _shellServerConnectionPayload(
  Server server,
) async {
  if (server.id != _seededServer.id && server.id != _secondServer.id) {
    return null;
  }
  return <String, dynamic>{
    'host': server.host,
    'port': server.port,
    'username': server.sshUser,
    'password': 'test-password',
  };
}

Future<void> _pumpShellPage(
  WidgetTester tester, {
  required bool withServer,
  String onboardingStep = 'connected',
  DesktopRoute route = const DesktopRoute.home(),
  _FakeServerCatalogNotifier? serverCatalogNotifier,
  _FakeSshService? sshService,
  FakeAnalyticsService? analyticsService,
  DesktopUpdateController? desktopUpdateController,
  ServerNotifier? serverNotifier,
  AppDatabase? database,
  AppPreferencesRepository? preferencesRepository,
  PendingEnrollment? pendingEnrollment,
  bool freshEnrollmentSession = false,
  bool settle = true,
}) async {
  final notifier =
      serverCatalogNotifier ??
      _FakeServerCatalogNotifier(
        _seedServerCatalogState(onboardingStep: onboardingStep),
      );
  // Widget tests must never touch the real preferences database: the shell
  // now reads it post-frame for the telemetry nag and launch sync.
  final preferences =
      preferencesRepository ??
      (database != null
          ? AppPreferencesRepository(database)
          : _NoopAppPreferencesRepository());
  if (withServer) {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (database != null) appDatabaseProvider.overrideWithValue(database),
          appPreferencesRepositoryProvider.overrideWithValue(preferences),
          serverCatalogProvider.overrideWith(() => notifier),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            _shellServerConnectionPayload,
          ),
          if (serverNotifier != null)
            serverProvider.overrideWith(() => serverNotifier),
          if (sshService != null)
            sshServiceProvider.overrideWithValue(sshService),
          if (analyticsService != null)
            appAnalyticsServiceProvider.overrideWithValue(analyticsService),
          // No-op hydration: widget tests must never touch the real
          // identity file; hydration itself is covered at the provider
          // and service layers.
          analyticsContextHydratorProvider.overrideWithValue(() async {}),
          if (desktopUpdateController != null)
            desktopUpdateControllerProvider.overrideWith(
              () => desktopUpdateController,
            ),
          if (pendingEnrollment != null)
            pendingEnrollmentProvider.overrideWith(
              () => PendingEnrollmentNotifier(pendingEnrollment),
            ),
          if (freshEnrollmentSession)
            freshEnrollmentSessionProvider.overrideWithValue(true),
        ],
        child: MaterialApp(home: ShellPage(route: route)),
      ),
    );
  } else {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (database != null) appDatabaseProvider.overrideWithValue(database),
          appPreferencesRepositoryProvider.overrideWithValue(preferences),
          serverCatalogProvider.overrideWith(
            () =>
                serverCatalogNotifier ??
                _FakeServerCatalogNotifier(
                  const ServerCatalogState(
                    isLoading: false,
                    onboardingComplete: false,
                    servers: [],
                  ),
                ),
          ),
          if (serverNotifier != null)
            serverProvider.overrideWith(() => serverNotifier),
          if (sshService != null)
            sshServiceProvider.overrideWithValue(sshService),
          if (analyticsService != null)
            appAnalyticsServiceProvider.overrideWithValue(analyticsService),
          // No-op hydration: widget tests must never touch the real
          // identity file; hydration itself is covered at the provider
          // and service layers.
          analyticsContextHydratorProvider.overrideWithValue(() async {}),
          if (desktopUpdateController != null)
            desktopUpdateControllerProvider.overrideWith(
              () => desktopUpdateController,
            ),
          if (pendingEnrollment != null)
            pendingEnrollmentProvider.overrideWith(
              () => PendingEnrollmentNotifier(pendingEnrollment),
            ),
          if (freshEnrollmentSession)
            freshEnrollmentSessionProvider.overrideWithValue(true),
        ],
        child: MaterialApp(home: ShellPage(route: route)),
      ),
    );
  }
  if (settle) {
    await tester.pumpAndSettle();
  }
}

class _NoopAppPreferencesRepository implements AppPreferencesRepository {
  @override
  Future<AppPreferencesRecord> read() async {
    return AppPreferencesRecord(
      terminalDebugView: false,
      themeMode: 'system',
      gitHubPendingOauthState: null,
      sqliteBackupS3Config: null,
      agentAccessEnabled: false,
      agentAccessPermissionMode: agentAccessPermissionReadOnly,
      agentSessionToken: null,
      agentSessionExpiresAt: null,
      updatedAt: DateTime.utc(2026, 1, 1),
    );
  }

  @override
  Future<void> setTerminalDebugView(bool enabled) async {}

  @override
  Future<void> setThemeMode(String mode) async {}

  @override
  Future<void> setGitHubPendingOauthState(String? oauthState) async {}

  @override
  Future<void> setSqliteBackupS3Config(Map<String, dynamic>? config) async {}

  @override
  Future<void> recordSqliteBackupRun({
    required String status,
    String? message,
    DateTime? runAt,
  }) async {}

  @override
  Future<void> setAgentAccessEnabled(bool enabled) async {}

  @override
  Future<void> setAgentAccessPermissionMode(String mode) async {}

  @override
  Future<void> issueAgentSession({
    required String token,
    required DateTime expiresAt,
  }) async {}

  @override
  Future<void> clearAgentSession() async {}

  @override
  Future<void> recordAnalyticsMilestone(
    AppUserAttribute attribute, {
    DateTime? reachedAt,
  }) async {}

  @override
  Future<void> setTelemetryEnabled({required bool enabled}) async {}

  @override
  Future<void> markTelemetryNoticeShown() async {}

  @override
  Future<void> markTelemetryNagShown() async {}
}

class _CountingDesktopUpdateController extends DesktopUpdateController {
  var checkCallCount = 0;

  @override
  Future<void> check() async {
    checkCallCount += 1;
  }
}

Matcher _containsWorkspaceEvent(
  String workspace, {
  String? entryPoint,
  String? tab,
}) {
  return contains(
    predicate<Map<String, String>>((event) {
      return event['workspace'] == workspace &&
          (entryPoint == null || event['entry_point'] == entryPoint) &&
          (tab == null || event['tab'] == tab);
    }),
  );
}

Future<void> _createProject(
  WidgetTester tester, {
  required String name,
  String runtime = 'Python',
}) async {
  await _openCreateProjectFromHome(tester);
  await tester.pumpAndSettle();

  await tester.enterText(
    find.byKey(const Key('create-project-name-field')),
    name,
  );
  await tester.tap(find.byKey(const Key('create-project-runtime-field')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(runtime).last);
  await tester.pumpAndSettle();

  final submitButton = find.byKey(const Key('create-project-submit-button'));
  final submitWidget = tester.widget<FilledButton>(submitButton);
  submitWidget.onPressed?.call();
  await tester.pumpAndSettle();
}

Finder _homeScrollable() {
  return find.descendant(
    of: find.byKey(const Key('home-dashboard-scroll')),
    matching: find.byType(Scrollable),
  );
}

Future<void> _openHome(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('left-rail-home-button')));
  await tester.pumpAndSettle();
}

Future<void> _scrollHomeTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(target, 240, scrollable: _homeScrollable());
  await tester.pumpAndSettle();
}

Future<void> _openCreateProjectFromHome(WidgetTester tester) async {
  await _openHome(tester);
  await _scrollHomeTo(tester, find.byKey(const Key('home-new-project-button')));
  await tester.tap(find.byKey(const Key('home-new-project-button')));
  await tester.pumpAndSettle();
}

Future<void> _showHomeServerAction(WidgetTester tester, String serverId) async {
  await _openHome(tester);
  await _scrollHomeTo(tester, find.byKey(Key('home-server-$serverId')));
}

Future<void> _showHomeProjectsCard(WidgetTester tester) async {
  await _openHome(tester);
  await _scrollHomeTo(tester, find.byKey(const Key('home-projects-card')));
}

Future<void> _openServerManagementFromHome(
  WidgetTester tester, {
  String serverId = 'server-prod-01',
}) async {
  await _showHomeServerAction(tester, serverId);
  await tester.tap(find.byKey(Key('home-server-manage-$serverId')));
  await tester.pumpAndSettle();
}

Future<void> _openProjectFromHome(WidgetTester tester, String name) async {
  await _openHome(tester);
  await _scrollHomeTo(tester, find.text(name).last);
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  testWidgets(
    'Release shell initialization checks for desktop updates after the first frame',
    (WidgetTester tester) async {
      final updateController = _CountingDesktopUpdateController();
      debugOverrideDeployDashDataDirPublisher(() async {});
      addTearDown(() => debugOverrideDeployDashDataDirPublisher(null));

      await _pumpShellPage(
        tester,
        withServer: false,
        desktopUpdateController: updateController,
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(updateController.checkCallCount, 1);
    },
    skip: desktopDistribution == 'development',
  );

  testWidgets('First run shows add-server onboarding', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(tester, withServer: false);

    expect(find.text('Connect your first server'), findsWidgets);
    expect(find.byKey(const Key('server-onboarding-start-button')), findsOne);
  });

  testWidgets('First-run Home action opens the safe no-server dashboard', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(tester, withServer: false);

    final homeAction = find.byKey(const Key('left-rail-home-button'));
    expect(homeAction, findsOneWidget);

    await tester.tap(
      find.descendant(of: homeAction, matching: find.byType(IconButton)),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('home-servers-card')),
      300,
      scrollable: find.descendant(
        of: find.byKey(const Key('home-dashboard-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.byKey(const Key('home-servers-card')), findsOneWidget);
    expect(find.text('Home'), findsWidgets);
    expect(find.byKey(const Key('server-onboarding-first-run')), findsNothing);
  });

  testWidgets('Shell reserves bottom space for minimized terminal', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(tester, withServer: true);

    final padding = tester.widget<Padding>(
      find.byKey(const Key('shell-workspace-safe-area')),
    );

    expect(padding.padding, const EdgeInsets.only(bottom: 52));
  });

  testWidgets(
    'Verification tasks do not auto-open the terminal sheet during onboarding',
    (WidgetTester tester) async {
      final notifier = _FakeServerCatalogNotifier(
        _seedServerCatalogState(onboardingStep: 'connected'),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serverCatalogProvider.overrideWith(() => notifier),
            serverProvider.overrideWith(
              () => _FakeLoadingServerNotifier(
                ServerState(
                  isLoading: true,
                  taskType: ServerTaskType.verification,
                ),
              ),
            ),
            // No-op hydration: see _pumpShellPage.
            analyticsContextHydratorProvider.overrideWithValue(() async {}),
          ],
          child: const MaterialApp(home: ShellPage()),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('terminal-sheet')), findsOneWidget);
      expect(find.byKey(const Key('terminal-selectable-output')), findsNothing);
      expect(
        tester.getSize(find.byKey(const Key('terminal-sheet'))).height,
        closeTo(TerminalBottomSheet.collapsedHeight, 0.01),
      );
    },
  );

  testWidgets('Server name can be a friendly display name', (
    WidgetTester tester,
  ) async {
    final serverNotifier = _FakeCheckingServerNotifier();
    await _pumpShellPage(
      tester,
      withServer: false,
      serverNotifier: serverNotifier,
    );

    final startButton = tester.widget<FilledButton>(
      find.byKey(const Key('server-onboarding-start-button')),
    );
    startButton.onPressed?.call();
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('server-name-field')),
      'Prod-01',
    );
    await tester.enterText(
      find.byKey(const Key('server-host-field')),
      '203.0.113.10',
    );
    await tester.enterText(
      find.byKey(const Key('server-password-field')),
      'test-password',
    );

    final connectButton = find.byKey(const Key('server-check-button'));
    final connectWidget = tester.widget<FilledButton>(connectButton);
    connectWidget.onPressed?.call();
    await tester.pumpAndSettle();

    expect(find.text('Review server details'), findsOneWidget);
    expect(serverNotifier.checkCalls, 1);
  });

  testWidgets('Home create action switches workspace to create mode', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(tester, withServer: true);

    expect(find.text('Home'), findsWidgets);

    await _openCreateProjectFromHome(tester);

    expect(find.text('Create new project'), findsOneWidget);
    expect(
      find.byKey(const Key('create-project-focused-flow')),
      findsOneWidget,
    );
    expect(find.text('Create a project'), findsOneWidget);
  });

  testWidgets('Back button returns to project workspace', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(tester, withServer: true);

    await _openCreateProjectFromHome(tester);

    await tester.tap(find.byKey(const Key('create-project-cancel-button')));
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsWidgets);
    await _showHomeProjectsCard(tester);
    expect(find.byKey(const Key('home-projects-card')), findsOneWidget);
    expect(find.text('Project details'), findsNothing);
  });

  testWidgets('Home manage action opens server management workspace', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(tester, withServer: true);

    await _openServerManagementFromHome(tester);

    expect(find.text('Server: Prod-01'), findsOneWidget);
    expect(find.byKey(const Key('left-rail-current-server')), findsNothing);
    expect(
      find.text('Ubuntu 24.04 LTS • IP: 203.0.113.10'),
      findsAtLeastNWidgets(1),
    );
    expect(find.byKey(const Key('server-management-nav-overview')), findsOne);
    expect(find.byKey(const Key('server-management-nav-services')), findsOne);
    expect(find.byKey(const Key('server-management-nav-security')), findsOne);
    expect(find.byKey(const Key('server-management-nav-settings')), findsOne);
  });

  testWidgets('Home resume entry retries setup with stored credentials', (
    WidgetTester tester,
  ) async {
    final setupNotifier = _FakeSetupServerNotifier(
      setupResult: const <String, dynamic>{'status': 'error'},
      setupError: 'apt update failed',
    );
    final analytics = FakeAnalyticsService();
    await _pumpShellPage(
      tester,
      withServer: true,
      serverNotifier: setupNotifier,
      analyticsService: analytics,
      serverCatalogNotifier: _FakeServerCatalogNotifier(
        _seedServerCatalogState(
          onboardingStep: 'setup_in_progress',
          pendingSetupServerIds: const {'server-prod-01'},
        ),
      ),
    );

    await _openHome(tester);
    await _scrollHomeTo(
      tester,
      find.byKey(const Key('home-projects-resume-setup-button')),
    );
    await tester.tap(
      find.byKey(const Key('home-projects-resume-setup-button')),
    );
    await tester.pumpAndSettle();

    expect(setupNotifier.setupCalls, 1);
    expect(setupNotifier.lastSetupPassword, 'test-password');
    expect(setupNotifier.lastSetupUsername, 'root');
    expect(find.text('Setup needs attention'), findsOneWidget);
    expect(analytics.setupResumedCallCount, 1);
  });

  testWidgets('fresh enrollment resumes the first-run wizard end to end', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final setupNotifier = _PendingSetupServerNotifier();
    await _pumpShellPage(
      tester,
      withServer: false,
      database: database,
      serverNotifier: setupNotifier,
      pendingEnrollment: PendingEnrollment(
        draft: const ServerDraft(
          name: 'Production web server',
          host: '203.0.113.10',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        checkResult: const <String, dynamic>{
          'status': 'success',
          'compatibility': <String, dynamic>{
            'status': 'pass',
            'summary': 'Server meets add-server compatibility requirements.',
            'checks': <Map<String, dynamic>>[],
          },
        },
      ),
    );

    expect(setupNotifier.setupCalls, 1);
    expect(find.text('Choose services'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ShellPage)),
    );
    final servers = container.read(serverCatalogProvider).servers;
    expect(servers, hasLength(1));
    expect(servers.first.host, '203.0.113.10');
    // The enrolled save cleared the stash: relaunching the wizard opens
    // blank instead of saving a second record.
    expect(container.read(pendingEnrollmentProvider), isNull);
  });

  testWidgets('first-run setup stays on the wizard while provisioning runs', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final setupGate = Completer<void>();
    final setupNotifier = _PendingSetupServerNotifier(setupGate: setupGate);
    await _pumpShellPage(
      tester,
      withServer: false,
      database: database,
      serverNotifier: setupNotifier,
      settle: false,
      freshEnrollmentSession: true,
      pendingEnrollment: PendingEnrollment(
        draft: const ServerDraft(
          name: 'Production web server',
          host: '203.0.113.10',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        checkResult: const <String, dynamic>{
          'status': 'success',
          'compatibility': <String, dynamic>{
            'status': 'pass',
            'summary': 'Server meets add-server compatibility requirements.',
            'checks': <Map<String, dynamic>>[],
          },
        },
      ),
    );

    // The early save lands while provisioning is still gated: frames
    // render with a saved server and an unfinished setup, exactly like
    // the minutes-long real run.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ShellPage)),
    );
    for (
      var i = 0;
      i < 50 && container.read(serverCatalogProvider).servers.isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(container.read(serverCatalogProvider).servers, hasLength(1));
    expect(setupNotifier.setupCalls, 1);
    // One more frame so the tree renders the saved state the loop just
    // observed in the provider.
    await tester.pump(const Duration(milliseconds: 100));

    // The wizard must stay on progress, not drop to Home mid-setup.
    expect(
      find.byKey(const Key('server-onboarding-first-run')),
      findsOneWidget,
    );
    expect(find.text('Setting up server'), findsOneWidget);

    // A catalog loading window mid-setup (the save's own flip, a
    // reload) must not unmount the wizard: it keeps showing progress
    // instead of flashing the loading spinner.
    final catalogNotifier =
        container.read(serverCatalogProvider.notifier)
            as _FakeServerCatalogNotifier;
    catalogNotifier.setLoading(true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const Key('server-onboarding-first-run')),
      findsOneWidget,
    );
    expect(find.text('Setting up server'), findsOneWidget);
    catalogNotifier.setLoading(false);
    await tester.pump(const Duration(milliseconds: 100));

    setupGate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Choose services'), findsOneWidget);
  });

  testWidgets('an explicit add-server opening wins during a fresh setup', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(
      tester,
      withServer: true,
      route: const DesktopRoute.onboarding(),
      freshEnrollmentSession: true,
      serverCatalogNotifier: _FakeServerCatalogNotifier(
        _seedServerCatalogState(
          onboardingStep: 'setup_in_progress',
          pendingSetupServerIds: const {'server-prod-01'},
        ),
      ),
    );

    // The user explicitly opened Add server: the additional wizard
    // (credentials) shows, not the first-run wizard (intro), even
    // though the fresh session's first setup is still pending.
    expect(find.text('Server details'), findsOneWidget);
    expect(find.text('Connect to your server'), findsNothing);
  });

  testWidgets('a restored incomplete server does not reopen the wizard', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(
      tester,
      withServer: true,
      serverCatalogNotifier: _FakeServerCatalogNotifier(
        _seedServerCatalogState(
          onboardingStep: 'setup_in_progress',
          pendingSetupServerIds: const {'server-prod-01'},
        ),
      ),
    );

    // No fresh enrollment this session: Home stays, with retry offered
    // there, instead of bouncing to a blank wizard.
    await _openHome(tester);
    await _scrollHomeTo(tester, find.byKey(const Key('home-servers-card')));
    expect(find.byKey(const Key('home-servers-card')), findsOneWidget);
    expect(find.byKey(const Key('server-onboarding-first-run')), findsNothing);
    expect(find.byKey(const Key('server-onboarding-additional')), findsNothing);
  });

  testWidgets('a completed first setup returns home', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(
      tester,
      withServer: true,
      freshEnrollmentSession: true,
    );

    await _openHome(tester);
    await _scrollHomeTo(tester, find.byKey(const Key('home-servers-card')));
    expect(find.byKey(const Key('home-servers-card')), findsOneWidget);
    expect(find.byKey(const Key('server-onboarding-first-run')), findsNothing);
  });

  testWidgets('New project stays disabled while the server setup is pending', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(
      tester,
      withServer: true,
      serverCatalogNotifier: _FakeServerCatalogNotifier(
        _seedServerCatalogState(
          onboardingStep: 'setup_in_progress',
          pendingSetupServerIds: const {'server-prod-01'},
        ),
      ),
    );

    await _openHome(tester);
    await _scrollHomeTo(
      tester,
      find.byKey(const Key('home-new-project-button')),
    );

    final createButton = tester.widget<FilledButton>(
      find.byKey(const Key('home-new-project-button')),
    );
    expect(createButton.onPressed, isNull);
  });

  testWidgets('Create project submission is blocked while setup is pending', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(
      tester,
      withServer: true,
      route: const DesktopRoute.createProject(),
      serverCatalogNotifier: _FakeServerCatalogNotifier(
        _seedServerCatalogState(
          onboardingStep: 'setup_in_progress',
          pendingSetupServerIds: const {'server-prod-01'},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('create-project-name-field')),
      'Blocked App',
    );
    await tester.tap(find.byKey(const Key('create-project-runtime-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Python').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-project-submit-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('Finish setting up this server before creating a project.'),
      findsOneWidget,
    );
    expect(find.text('Create new project'), findsOneWidget);
  });

  testWidgets('Leaving onboarding clears a pending setup retry', (
    WidgetTester tester,
  ) async {
    final setupNotifier = _FakeSetupServerNotifier(
      setupResult: const <String, dynamic>{'status': 'error'},
      setupError: 'apt update failed',
    );
    await _pumpShellPage(
      tester,
      withServer: true,
      serverNotifier: setupNotifier,
      serverCatalogNotifier: _FakeServerCatalogNotifier(
        _seedServerCatalogState(
          onboardingStep: 'setup_in_progress',
          pendingSetupServerIds: const {'server-prod-01'},
        ),
      ),
    );

    await _openHome(tester);
    await _scrollHomeTo(
      tester,
      find.byKey(const Key('home-projects-resume-setup-button')),
    );
    await tester.tap(
      find.byKey(const Key('home-projects-resume-setup-button')),
    );
    await tester.pumpAndSettle();
    expect(setupNotifier.setupCalls, 1);

    await _openHome(tester);
    await _scrollHomeTo(
      tester,
      find.byKey(const Key('home-add-server-button')),
    );
    await tester.tap(find.byKey(const Key('home-add-server-button')));
    await tester.pumpAndSettle();

    // A cleared retry id opens the credentials form instead of auto-running
    // setup for the previous server.
    expect(setupNotifier.setupCalls, 1);
    expect(find.text('Server details'), findsOneWidget);
  });

  testWidgets('Left rail settings button opens global app settings', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(tester, withServer: true);

    await tester.tap(find.byKey(const Key('left-rail-app-settings-button')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('App Settings'), findsOneWidget);
    expect(
      find.text('Application-wide preferences and security'),
      findsOneWidget,
    );
  });

  testWidgets('Left rail collapses before workspace content becomes cramped', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpShellPage(tester, withServer: true);

    expect(
      tester.widget<AppNavigationRail>(find.byType(AppNavigationRail)).extended,
      isTrue,
    );

    tester.view.physicalSize = const Size(800, 800);
    await tester.pumpAndSettle();

    expect(
      tester.widget<AppNavigationRail>(find.byType(AppNavigationRail)).extended,
      isFalse,
    );
    expect(find.byTooltip('Home'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
  });

  testWidgets('Workspace navigation reports analytics events', (
    WidgetTester tester,
  ) async {
    final analyticsService = FakeAnalyticsService();
    await _pumpShellPage(
      tester,
      withServer: true,
      analyticsService: analyticsService,
    );

    await _openCreateProjectFromHome(tester);
    await tester.tap(find.byKey(const Key('create-project-cancel-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('left-rail-app-settings-button')));
    await tester.pump(const Duration(milliseconds: 100));
    await _openServerManagementFromHome(tester);

    expect(
      analyticsService.workspaceEvents,
      _containsWorkspaceEvent('create_project', entryPoint: 'home_dashboard'),
    );
    expect(analyticsService.workspaceEvents, _containsWorkspaceEvent('home'));
    expect(
      analyticsService.workspaceEvents,
      _containsWorkspaceEvent('app_settings', entryPoint: 'sidebar'),
    );
    expect(
      analyticsService.workspaceEvents,
      _containsWorkspaceEvent('server_management', tab: 'overview'),
    );
  });

  testWidgets('Create project adds and selects new project', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(tester, withServer: true);

    await _createProject(tester, name: 'Worker App');

    expect(find.text('Project: Worker App'), findsOneWidget);
    expect(find.text('Web app • Server: Prod-01'), findsOneWidget);
    expect(find.byKey(const Key('left-rail-current-server')), findsNothing);
  });

  testWidgets(
    'A newly created project appears in the rail recents immediately',
    (WidgetTester tester) async {
      // _handleCreateProject (main.dart) used to select and open the new
      // project without ever calling recentProjectVisitsProvider's
      // recordVisit -- unlike _openProjectScreen, which every other "open a
      // project" path (Home, rail, search) goes through. The workspace
      // shell's own recordVisit call only fires from an explicit tab switch
      // (AppWorkspaceScaffold's onSelected), not on initial mount, so a
      // freshly created project a user never manually re-clicks a tab in
      // stayed permanently invisible in "Recent projects" until they did.
      //
      // The explicit size matches app_navigation_rail_test.dart's own rail
      // tests -- left-rail-recent-projects-list doesn't render at this file's
      // other tests' default surface size. The in-memory database is required
      // too: without it, appDatabaseProvider falls back to a real
      // passphrase-backed AppDatabase that hangs opening in this harness.
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      await _pumpShellPage(tester, withServer: true, database: database);

      await _createProject(tester, name: 'Freshly Created App');
      await tester.pumpAndSettle();

      final recentsList = find.byKey(
        const Key('left-rail-recent-projects-list'),
      );
      expect(
        find.descendant(
          of: recentsList,
          matching: find.text('Freshly Created App'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Left rail shows Home first and switches between Home and project',
    (WidgetTester tester) async {
      await _pumpShellPage(tester, withServer: true);

      expect(find.text('Home'), findsWidgets);

      await _createProject(tester, name: 'Gamma App');

      expect(find.text('Project: Gamma App'), findsOneWidget);

      await _showHomeProjectsCard(tester);
      expect(find.byKey(const Key('home-projects-card')), findsOneWidget);
      expect(find.text('Project: Gamma App'), findsNothing);

      await _openProjectFromHome(tester, 'Gamma App');

      expect(find.text('Project: Gamma App'), findsOneWidget);
    },
  );

  testWidgets('Home project list entries open the chosen project', (
    WidgetTester tester,
  ) async {
    await _pumpShellPage(tester, withServer: true);

    await _createProject(tester, name: 'Delta App');
    await _openProjectFromHome(tester, 'Delta App');

    expect(find.text('Project: Delta App'), findsOneWidget);
  });

  testWidgets('A recent screen entry opens the screen it names', (
    WidgetTester tester,
  ) async {
    // The extended rail, which is the only one that renders per-screen
    // rows, needs at least AppWorkspaceBreakpoints.twoColumn (960).
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    int visibleTabIndex() => tester
        .widget<ProjectWorkspace>(find.byType(ProjectWorkspace))
        .initialTabIndex;

    await _pumpShellPage(tester, withServer: true, database: database);
    await _createProject(tester, name: 'Alpha App');
    expect(visibleTabIndex(), 0, reason: 'a new project opens on Web app');

    await tester.tap(find.text('Database').first);
    await tester.pumpAndSettle();
    expect(visibleTabIndex(), 2, reason: 'Database is the third destination');

    await _openHome(tester);

    final recentDatabaseScreen = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('left-rail-recent-screen-') &&
          key.value.endsWith('-database');
    });
    expect(
      recentDatabaseScreen,
      findsOneWidget,
      reason: 'the visit to Database is recorded as its own recent screen',
    );

    await tester.tap(recentDatabaseScreen);
    await tester.pumpAndSettle();

    expect(
      visibleTabIndex(),
      2,
      reason: 'the recent entry opens Database, not the default Web app',
    );
  }, skip: !sqliteAvailable);

  testWidgets('A newly created project opens on Web app', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    await _pumpShellPage(tester, withServer: true, database: database);
    await _createProject(tester, name: 'Brand New App');

    final workspace = tester.widget<ProjectWorkspace>(
      find.byType(ProjectWorkspace),
    );
    expect(
      workspace.initialTabIndex,
      0,
      reason: 'a fresh project opens on Web app (tab 0)',
    );
  }, skip: !sqliteAvailable);

  testWidgets('Home and rail only show projects for the selected server', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final projectRepository = ProjectRepository(database);
    await projectRepository.createProject(
      const Project(
        id: 'project-prod',
        serverId: 'server-prod-01',
        name: 'Prod App',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'prod.example.com',
        isActive: true,
      ),
    );
    await projectRepository.createProject(
      const Project(
        id: 'project-staging',
        serverId: 'server-staging-01',
        name: 'Staging App',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'staging.example.com',
        isActive: true,
      ),
    );
    final catalogNotifier = _FakeServerCatalogNotifier(
      const ServerCatalogState(
        isLoading: false,
        onboardingComplete: true,
        servers: [_seededServer, _secondServer],
        selectedServerId: 'server-staging-01',
        onboardingStep: 'connected',
      ),
    );

    await _pumpShellPage(
      tester,
      withServer: true,
      database: database,
      serverCatalogNotifier: catalogNotifier,
    );
    await _openHome(tester);
    expect(find.text('Projects on Staging-01'), findsOneWidget);

    await _showHomeProjectsCard(tester);

    expect(find.text('Staging App'), findsWidgets);
    expect(find.text('Prod App'), findsNothing);
    expect(find.text('Projects on Staging-01'), findsOneWidget);

    await _showHomeServerAction(tester, 'server-prod-01');
    await tester.tap(find.byKey(const Key('home-server-server-prod-01')));
    await tester.pumpAndSettle();

    expect(catalogNotifier.state.selectedServerId, 'server-prod-01');
    expect(find.text('Projects on Prod-01'), findsOneWidget);
  });

  testWidgets('Home server actions open add server and server management', (
    WidgetTester tester,
  ) async {
    final analyticsService = FakeAnalyticsService();
    await _pumpShellPage(
      tester,
      withServer: true,
      analyticsService: analyticsService,
    );

    await _openServerManagementFromHome(tester);

    expect(find.text('Server: Prod-01'), findsOneWidget);

    await _openHome(tester);
    await _scrollHomeTo(
      tester,
      find.byKey(const Key('home-add-server-button')),
    );
    expect(find.text('Add server'), findsWidgets);
    await tester.tap(find.byKey(const Key('home-add-server-button')));
    await tester.pumpAndSettle();

    expect(find.text('Add server'), findsWidgets);
    expect(
      find.byKey(const Key('server-onboarding-additional')),
      findsOneWidget,
    );
    expect(
      analyticsService.workspaceEvents,
      _containsWorkspaceEvent('server_management', tab: 'overview'),
    );
    expect(
      analyticsService.workspaceEvents,
      _containsWorkspaceEvent('add_server', entryPoint: 'home_dashboard'),
    );
  });

  testWidgets('Deleting a project routes the shell back to Home', (
    WidgetTester tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    final sshService = _FakeSshService();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await database.close();
    });
    await _pumpShellPage(
      tester,
      withServer: true,
      sshService: sshService,
      database: database,
    );

    await _createProject(tester, name: 'Alpha App');
    await _createProject(tester, name: 'Beta App');

    await _openProjectFromHome(tester, 'Alpha App');

    expect(find.text('Project: Alpha App'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('settings-delete-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-delete-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('settings-delete-confirm-input')),
      'Alpha App',
    );
    await tester.tap(find.byKey(const Key('settings-delete-confirm-checkbox')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-delete-confirm-button')));
    for (var attempt = 0; attempt < 20; attempt += 1) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byKey(const Key('home-projects-card')).evaluate().isNotEmpty) {
        break;
      }
    }

    await _showHomeProjectsCard(tester);
    expect(find.byKey(const Key('home-projects-card')), findsOneWidget);
    expect(find.text('Project: Beta App'), findsNothing);
    expect(find.text('Beta App'), findsWidgets);
  });

  testWidgets('Deleting the last project shows Home empty state', (
    WidgetTester tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    final sshService = _FakeSshService();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await database.close();
    });
    await _pumpShellPage(
      tester,
      withServer: true,
      sshService: sshService,
      database: database,
    );

    await _createProject(tester, name: 'Solo App');

    await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('settings-delete-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-delete-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('settings-delete-confirm-input')),
      'Solo App',
    );
    await tester.tap(find.byKey(const Key('settings-delete-confirm-checkbox')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-delete-confirm-button')));
    for (var attempt = 0; attempt < 20; attempt += 1) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byKey(const Key('home-projects-card')).evaluate().isNotEmpty) {
        break;
      }
    }

    await _showHomeProjectsCard(tester);
    expect(find.byKey(const Key('home-projects-card')), findsOneWidget);
    expect(
      find.text(
        'Create a project to configure a web app, workers, backups, and '
        'supporting services.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Home shows retry state after incomplete project cleanup', (
    WidgetTester tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    final sshService = _FakeSshService();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await database.close();
    });
    final warningNotifier = _FakeServerCatalogNotifier(
      _seedServerCatalogState(selectedServer: _warningSeededServer),
    );
    await _pumpShellPage(
      tester,
      withServer: true,
      sshService: sshService,
      database: database,
      serverCatalogNotifier: warningNotifier,
    );

    await _createProject(tester, name: 'Warn App');
    await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('settings-delete-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-delete-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('settings-delete-confirm-input')),
      'Warn App',
    );
    await tester.tap(find.byKey(const Key('settings-delete-confirm-checkbox')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-delete-confirm-button')));
    for (var attempt = 0; attempt < 20; attempt += 1) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find
          .byKey(const Key('home-delete-notice-card'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }

    expect(find.byKey(const Key('home-delete-notice-card')), findsOneWidget);
    expect(find.text('Project cleanup needs attention'), findsOneWidget);
    expect(find.text('Cleanup required for Warn App'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry cleanup'), findsOneWidget);
    expect(find.textContaining('No active server selected'), findsNothing);
    expect(find.textContaining('needs to be reconnected'), findsWidgets);
  });

  testWidgets('Dismissing the delete notice clears the Home warning card', (
    WidgetTester tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    final sshService = _FakeSshService();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await database.close();
    });
    final warningNotifier = _FakeServerCatalogNotifier(
      _seedServerCatalogState(selectedServer: _warningSeededServer),
    );
    await _pumpShellPage(
      tester,
      withServer: true,
      sshService: sshService,
      database: database,
      serverCatalogNotifier: warningNotifier,
    );

    await _createProject(tester, name: 'Dismiss App');
    await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('settings-delete-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-delete-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('settings-delete-confirm-input')),
      'Dismiss App',
    );
    await tester.tap(find.byKey(const Key('settings-delete-confirm-checkbox')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-delete-confirm-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-delete-notice-card')), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('home-delete-notice-dismiss-button')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-delete-notice-card')), findsNothing);
  });

  testWidgets('Open server services action switches to the Services tab', (
    WidgetTester tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    final analyticsService = FakeAnalyticsService();
    // The Services tab reads the desktop's known databases for the storage
    // section, so it needs the in-memory database like the tests above: the
    // real AppDatabase hangs opening in this harness.
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await _pumpShellPage(
      tester,
      withServer: true,
      database: database,
      analyticsService: analyticsService,
    );

    await _createProject(tester, name: 'Service Jump App');
    await tester.ensureVisible(find.widgetWithText(Tab, 'Backup'));
    await tester.tap(find.widgetWithText(Tab, 'Backup'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('backup-open-server-services-button')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('backup-open-server-services-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Server: Prod-01'), findsOneWidget);
    expect(
      find.byKey(const Key('server-management-services-tab')),
      findsOneWidget,
    );
    expect(
      analyticsService.workspaceEvents,
      _containsWorkspaceEvent('server_management', tab: 'services'),
    );
  });

  testWidgets(
    'Services selection enables Postgres immediately during onboarding',
    (WidgetTester tester) async {
      final serverCatalogNotifier = _FakeServerCatalogNotifier(
        _seedServerCatalogState(onboardingStep: 'services_selection'),
      );
      final sshService = _FakeSshService();

      await _pumpShellPage(
        tester,
        withServer: true,
        onboardingStep: 'services_selection',
        serverCatalogNotifier: serverCatalogNotifier,
        sshService: sshService,
      );

      expect(find.text('Choose services'), findsOneWidget);
      final databasesToggle = find.byKey(const Key('service-toggle-databases'));
      await tester.ensureVisible(databasesToggle);
      await tester.pumpAndSettle();
      await tester.tap(databasesToggle);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('service-postgres-version-dropdown')),
        findsOneWidget,
      );

      final continueButton = find.byKey(
        const Key('services-selection-continue-button'),
      );
      await tester.scrollUntilVisible(
        continueButton,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      final continueWidget = tester.widget<FilledButton>(continueButton);
      continueWidget.onPressed?.call();
      await tester.pumpAndSettle();

      final enableCalls = sshService.workflowCalls
          .where((call) {
            return call['workflowId'] == 'postgres' &&
                call['operationId'] == 'service_enable';
          })
          .toList(growable: false);
      expect(enableCalls, hasLength(1));
      final enableParams =
          enableCalls.single['params'] as Map<String, dynamic>?;
      final enableSettings = enableParams?['settings'] as Map<String, dynamic>?;
      expect(enableSettings?['superuser_password'], isNotNull);
      expect(
        serverCatalogNotifier.state.selectedServer?.serviceDatabaseEnabled,
        isTrue,
      );
      expect(
        serverCatalogNotifier
            .state
            .selectedServer
            ?.postgresConfig
            .superuserPassword,
        isNotNull,
      );
      expect(find.text('Server: Prod-01'), findsOneWidget);
    },
  );

  testWidgets('Rail search submit reports the search control', (
    WidgetTester tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    // The extended rail renders the search field inline; at the default
    // surface size only the icon button exists.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final analyticsService = FakeAnalyticsService();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await ProjectRepository(database).createProject(
      const Project(
        id: 'project-search',
        serverId: 'server-prod-01',
        name: 'Zebra Deploy',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'zebra.example.com',
        isActive: true,
      ),
    );
    await _pumpShellPage(
      tester,
      withServer: true,
      database: database,
      analyticsService: analyticsService,
    );

    final searchField = find.byKey(const Key('app-search-field'));
    expect(searchField, findsOneWidget);
    await tester.enterText(searchField, 'zebra');
    // The overlay debounces keystrokes before searching.
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(analyticsService.controlUses, [
      (control: AppControl.railSearchSubmitted, tab: null),
    ]);
    expect(
      analyticsService.workspaceEvents,
      _containsWorkspaceEvent('project'),
    );
  });

  testWidgets('Opening a placeholder destination reports it with its tab', (
    WidgetTester tester,
  ) async {
    if (!sqliteAvailable) {
      return;
    }
    final analyticsService = FakeAnalyticsService();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await _pumpShellPage(
      tester,
      withServer: true,
      database: database,
      analyticsService: analyticsService,
    );

    await _createProject(tester, name: 'Mail App');

    await tester.tap(find.text('Email').first);
    await tester.pumpAndSettle();

    expect(analyticsService.controlUses, [
      (control: AppControl.placeholderViewed, tab: 'email'),
    ]);

    await tester.tap(find.text('Database').first);
    await tester.pumpAndSettle();

    // Shipped destinations report no control: only placeholders do.
    expect(analyticsService.controlUses, hasLength(1));
  });
}

class _FakeServerCatalogNotifier extends ServerCatalogNotifier {
  _FakeServerCatalogNotifier(this._seedState);

  final ServerCatalogState _seedState;

  @override
  ServerCatalogState build() => _seedState;

  @override
  Future<void> refresh() async {}

  /// Flips the loading flag without touching servers, simulating the
  /// transient loading windows (saves, reloads) the shell must ride
  /// through without unmounting the wizard.
  void setLoading(bool loading) {
    state = state.copyWith(isLoading: loading);
  }

  @override
  Future<void> selectServer(String serverId) async {
    state = state.copyWith(selectedServerId: serverId);
  }

  @override
  Future<void> setOnboardingStep(String step) async {
    state = state.copyWith(onboardingStep: step);
  }

  @override
  Future<void> updateSelectedServerServices({
    required bool enableDatabases,
    required bool enableEmailAccounts,
    required bool enableDomains,
  }) async {
    final selectedId = state.selectedServerId;
    if (selectedId == null) {
      return;
    }
    final updatedServers = state.servers
        .map((server) {
          if (server.id != selectedId) {
            return server;
          }
          return _copyServer(
            server,
            serviceDatabaseEnabled: enableDatabases,
            serviceEmailEnabled: enableEmailAccounts,
            serviceDomainEnabled: enableDomains,
          );
        })
        .toList(growable: false);
    state = state.copyWith(servers: updatedServers);
  }

  @override
  Future<void> updateSelectedServerPostgresConfig(
    ServerPostgresConfig config,
  ) async {
    final selectedId = state.selectedServerId;
    if (selectedId == null) {
      return;
    }
    final updatedServers = state.servers
        .map((server) {
          if (server.id != selectedId) {
            return server;
          }
          return _copyServer(server, postgresConfig: config);
        })
        .toList(growable: false);
    state = state.copyWith(servers: updatedServers);
  }

  @override
  Future<void> updateSelectedServerSystemConfig(
    ServerSystemConfig config,
  ) async {
    final selectedId = state.selectedServerId;
    if (selectedId == null) {
      return;
    }
    final updatedServers = state.servers
        .map((server) {
          if (server.id != selectedId) {
            return server;
          }
          return _copyServer(server, systemConfig: config);
        })
        .toList(growable: false);
    state = state.copyWith(servers: updatedServers);
  }

  @override
  Future<void> updateSelectedServerConnectionPort(int port) async {
    final selectedId = state.selectedServerId;
    if (selectedId == null) {
      return;
    }
    final updatedServers = state.servers
        .map((server) {
          if (server.id != selectedId) {
            return server;
          }
          return _copyServer(server, port: port);
        })
        .toList(growable: false);
    state = state.copyWith(servers: updatedServers);
  }

  Server _copyServer(
    Server server, {
    int? port,
    bool? serviceDatabaseEnabled,
    bool? serviceEmailEnabled,
    bool? serviceDomainEnabled,
    ServerPostgresConfig? postgresConfig,
    ServerSystemConfig? systemConfig,
  }) {
    return Server(
      id: server.id,
      name: server.name,
      host: server.host,
      port: port ?? server.port,
      sshUser: server.sshUser,
      authMethod: server.authMethod,
      osName: server.osName,
      cpuArch: server.cpuArch,
      memoryMb: server.memoryMb,
      diskGb: server.diskGb,
      serviceDatabaseEnabled:
          serviceDatabaseEnabled ?? server.serviceDatabaseEnabled,
      serviceEmailEnabled: serviceEmailEnabled ?? server.serviceEmailEnabled,
      serviceDomainEnabled: serviceDomainEnabled ?? server.serviceDomainEnabled,
      webServerConfig: server.webServerConfig,
      postgresConfig: postgresConfig ?? server.postgresConfig,
      systemConfig: systemConfig ?? server.systemConfig,
      lastCheckStatus: server.lastCheckStatus,
      lastError: server.lastError,
      lastCheckedAt: server.lastCheckedAt,
      createdAt: server.createdAt,
      updatedAt: DateTime.now(),
    );
  }
}

class _FakeLoadingServerNotifier extends ServerNotifier {
  _FakeLoadingServerNotifier(this._seedState);

  final ServerState _seedState;

  @override
  ServerState build() => _seedState;
}

class _FakeCheckingServerNotifier extends ServerNotifier {
  int checkCalls = 0;

  @override
  ServerState build() => ServerState();

  @override
  Future<void> checkServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
  }) async {
    checkCalls += 1;
    state = state.copyWith(
      isLoading: false,
      result: const <String, dynamic>{
        'status': 'success',
        'os': 'Ubuntu 24.04 LTS',
        'cpu': 'x86_64',
        'memory_mb': 8192,
        'disk_gb': 120,
        'compatibility': <String, dynamic>{
          'status': 'pass',
          'summary': 'Server meets add-server compatibility requirements.',
          'checks': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'os_ubuntu_24_04',
              'label': 'Operating system is Ubuntu 24.04.x',
              'passed': true,
              'message': 'OS requirement satisfied.',
            },
          ],
        },
      },
      taskType: ServerTaskType.verification,
    );
  }

  @override
  Future<void> loadSetupPlan({
    List<String>? parts,
    Map<String, dynamic>? settings,
  }) async {}
}

class _FakeSetupServerNotifier extends ServerNotifier {
  _FakeSetupServerNotifier({required this.setupResult, this.setupError});

  Map<String, dynamic> setupResult;
  String? setupError;
  int setupCalls = 0;
  String? lastSetupPassword;
  String? lastSetupUsername;

  @override
  ServerState build() => ServerState();

  @override
  Future<void> setupServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    Map<String, dynamic>? managedConnection,
    List<String>? parts,
    Map<String, dynamic>? settings,
    bool dryRun = false,
  }) async {
    setupCalls += 1;
    lastSetupPassword = password;
    lastSetupUsername = username;
    final error = setupError;
    state = state.copyWith(isLoading: false, result: setupResult, error: error);
  }

  @override
  Future<void> loadSetupPlan({
    List<String>? parts,
    Map<String, dynamic>? settings,
  }) async {}
}

class _PendingSetupServerNotifier extends ServerNotifier {
  _PendingSetupServerNotifier({this.setupGate});

  /// Holds provisioning open so a test can observe frames rendered
  /// while the setup is still running.
  final Completer<void>? setupGate;

  int setupCalls = 0;

  @override
  ServerState build() => ServerState();

  @override
  Future<void> setupServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    Map<String, dynamic>? managedConnection,
    List<String>? parts,
    Map<String, dynamic>? settings,
    bool dryRun = false,
  }) async {
    setupCalls += 1;
    final setupGate = this.setupGate;
    if (setupGate != null) {
      state = state.copyWith(isLoading: true, taskType: ServerTaskType.setup);
      await setupGate.future;
    }
    state = state.copyWith(
      isLoading: false,
      setupResult: const <String, dynamic>{'status': 'success'},
    );
  }

  @override
  Future<void> loadSetupPlan({
    List<String>? parts,
    Map<String, dynamic>? settings,
  }) async {}
}

class _FakeSshService extends LegacySshService {
  _FakeSshService();

  final List<Map<String, dynamic>> workflowCalls = <Map<String, dynamic>>[];
  final Map<String, dynamic> checkServerResult = const <String, dynamic>{
    'status': 'success',
    'os': 'Ubuntu 24.04 LTS',
    'cpu': 'x86_64',
    'memory_mb': 8192,
    'disk_gb': 120,
  };

  @override
  Future<Result<Map<String, dynamic>>> checkServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
  }) async {
    return Ok<Map<String, dynamic>>(checkServerResult);
  }

  @override
  Future<Result<Map<String, dynamic>>> runWorkflow({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    workflowCalls.add(<String, dynamic>{
      'workflowId': workflowId,
      'operationId': operationId,
      'connection': connection,
      'params': params,
    });
    onEvent?.call(const <String, dynamic>{
      'type': 'pyinfra_operation_stdout',
      'level': 'info',
      'message': '[postgres] Running service_enable',
    });
    return const Ok<Map<String, dynamic>>(<String, dynamic>{
      'status': 'success',
      'msg': 'Database service enabled.',
    });
  }
}

const _warningSeededServer = Server(
  id: 'server-warning-01',
  name: 'Warn-01',
  host: '203.0.113.11',
  port: 22,
  sshUser: 'root',
  authMethod: ServerAuthMethod.password,
  osName: 'Ubuntu 24.04 LTS',
);

ServerCatalogState _seedServerCatalogState({
  String onboardingStep = 'connected',
  Server selectedServer = _seededServer,
  Set<String> pendingSetupServerIds = const {},
}) {
  return ServerCatalogState(
    isLoading: false,
    onboardingComplete: true,
    servers: [selectedServer],
    selectedServerId: selectedServer.id,
    onboardingStep: onboardingStep,
    pendingSetupServerIds: pendingSetupServerIds,
  );
}
