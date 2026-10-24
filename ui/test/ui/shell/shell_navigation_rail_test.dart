import 'package:ui/data/local/server_repository.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/providers/recent_projects_provider.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/services/desktop_update_service.dart';
import 'package:ui/services/local_search_index.dart';
import 'package:ui/ui/layout/app_navigation_rail.dart';
import 'package:ui/ui/navigation/desktop_route.dart';
import 'package:ui/ui/shell/shell_navigation_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const server = Server(
    id: 'server-production',
    name: 'Production',
    host: '203.0.113.42',
    port: 22,
    sshUser: 'ubuntu',
    authMethod: ServerAuthMethod.password,
  );
  const project = Project(
    id: 'project-console',
    serverId: 'server-production',
    name: 'Console',
    type: 'Node.js',
    gitUrl: 'git@example.test:deploydash/console.git',
    primaryDomain: 'console.example.test',
  );

  group('ShellNavigationActions', () {
    test('preserves rail route side effects', () {
      final harness = _NavigationHarness();
      final actions = harness.actions;

      actions.openCreateProject();
      actions.openHome();
      actions.openAddServer();
      actions.openProject('project-console');
      actions.openServerManagementServices();
      actions.openAppSettings();
      actions.openDesktopUpdates();

      expect(harness.routes, <DesktopRoute>[
        const DesktopRoute.createProject(),
        const DesktopRoute.home(),
        const DesktopRoute.onboarding(),
        DesktopRoute.project(
          projectId: 'project-console',
          destinationId: 'workers',
        ),
        const DesktopRoute.serverManagement(
          tab: DesktopServerManagementTab.services,
        ),
        const DesktopRoute.appSettings(),
        const DesktopRoute.appSettings(
          destination: DesktopAppSettingsDestination.updates,
        ),
      ]);
      expect(harness.clearDeletedProjectNoticeCalls, 6);
      expect(harness.prepareAddServerCalls, 1);
      expect(
        harness.workspaceEvents,
        containsAll(<Map<String, String>>[
          <String, String>{
            'workspace': 'create_project',
            'entry_point': 'home_dashboard',
          },
          <String, String>{'workspace': 'home'},
          <String, String>{'workspace': 'server_management', 'tab': 'services'},
          <String, String>{
            'workspace': 'app_settings',
            'entry_point': 'update_badge',
          },
        ]),
      );
      expect(
        harness.terminalLines,
        contains('[ui] Opening selected project workspace'),
      );
    });

    test('search and destination actions preserve their typed fallbacks', () {
      final harness = _NavigationHarness();
      final actions = harness.actions;

      actions.openSearchResult(
        const LocalSearchResult(
          kind: LocalSearchResultKind.server,
          title: 'Production',
          serverId: 'server-production',
        ),
      );
      actions.openSearchResult(
        const LocalSearchResult(
          kind: LocalSearchResultKind.project,
          title: 'Console',
          serverId: 'server-production',
          projectId: 'project-console',
        ),
      );
      actions.openSearchResult(
        const LocalSearchResult(
          kind: LocalSearchResultKind.screen,
          title: 'Backup',
          projectId: 'project-console',
          destinationId: 'backup',
        ),
      );
      expect(harness.controlUses, <({AppControl control, String? tab})>[
        (control: AppControl.railSearchSubmitted, tab: null),
        (control: AppControl.railSearchSubmitted, tab: null),
        (control: AppControl.railSearchSubmitted, tab: null),
      ], reason: 'every submit path reports exactly once');
      actions.selectServerFromHome('server-staging');
      actions.openProjectDestination(
        projectId: '   ',
        destinationId: 'workers',
      );
      actions.openProjectDestination(
        projectId: 'project-console',
        destinationId: 'workers',
      );
      actions.openServerManagementDestination(-1);
      actions.openServerManagementDestination(99);
      actions.openServerManagementDestination(
        DesktopServerManagementTab.security.index,
      );
      actions.openAppSettingsDestination('agent-access');

      expect(harness.selectedServerIds, <String>[
        'server-production',
        'server-production',
        'server-staging',
      ]);
      expect(harness.routes, <DesktopRoute>[
        const DesktopRoute.serverManagement(),
        DesktopRoute.project(projectId: 'project-console'),
        DesktopRoute.project(
          projectId: 'project-console',
          destinationId: 'backup',
        ),
        DesktopRoute.project(
          projectId: 'project-console',
          destinationId: 'workers',
        ),
        const DesktopRoute.serverManagement(
          tab: DesktopServerManagementTab.security,
        ),
        const DesktopRoute.appSettings(
          destination: DesktopAppSettingsDestination.agentAccess,
        ),
      ]);
    });
  });

  test(
    'rail state derives unlock selection and searches provider-owned data',
    () async {
      final container = ProviderContainer(
        overrides: [
          serverCatalogProvider.overrideWith(
            () => _FakeServerCatalogNotifier(
              const ServerCatalogState(
                isLoading: false,
                onboardingComplete: true,
                servers: <Server>[server],
                selectedServerId: 'server-production',
              ),
            ),
          ),
          projectListProvider.overrideWith(
            () => _FakeProjectListNotifier(const <Project>[project]),
          ),
          recentProjectGroupsProvider.overrideWithValue(
            const <RecentProjectGroup>[],
          ),
          desktopUpdateControllerProvider.overrideWith(
            _FakeDesktopUpdateController.new,
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(desktopUpdateControllerProvider.future);
      final state = container.read(
        shellNavigationRailStateProvider(
          const ShellNavigationRailContext(
            route: DesktopRoute.unlock(),
            showFirstRunOnboarding: false,
          ),
        ),
      );

      expect(state.selectedSection, AppNavigationSection.settings);
      expect(state.currentServerName, 'Production');
      expect(state.hasServers, isTrue);
      expect(state.showCurrentServer, isFalse);
      expect(
        state.search('production'),
        contains(
          isA<LocalSearchResult>()
              .having(
                (result) => result.kind,
                'kind',
                LocalSearchResultKind.server,
              )
              .having((result) => result.serverId, 'server ID', server.id),
        ),
      );
    },
  );

  test('rail state hides the server row on server management routes', () {
    final container = ProviderContainer(
      overrides: [
        serverCatalogProvider.overrideWith(
          () => _FakeServerCatalogNotifier(
            const ServerCatalogState(
              isLoading: false,
              onboardingComplete: true,
              servers: <Server>[server],
              selectedServerId: 'server-production',
            ),
          ),
        ),
        projectListProvider.overrideWith(
          () => _FakeProjectListNotifier(const <Project>[project]),
        ),
        recentProjectGroupsProvider.overrideWithValue(
          const <RecentProjectGroup>[],
        ),
        desktopUpdateControllerProvider.overrideWith(
          _FakeDesktopUpdateController.new,
        ),
      ],
    );
    addTearDown(container.dispose);

    final serverManagementState = container.read(
      shellNavigationRailStateProvider(
        const ShellNavigationRailContext(
          route: DesktopRoute.serverManagement(),
          showFirstRunOnboarding: false,
        ),
      ),
    );
    final onboardingState = container.read(
      shellNavigationRailStateProvider(
        const ShellNavigationRailContext(
          route: DesktopRoute.onboarding(),
          showFirstRunOnboarding: false,
        ),
      ),
    );

    expect(serverManagementState.showCurrentServer, isFalse);
    expect(onboardingState.showCurrentServer, isTrue);
  });

  testWidgets('Ctrl+K focuses the scoped rail search node', (
    WidgetTester tester,
  ) async {
    late FocusNode searchFocusNode;
    final otherFocusNode = FocusNode(debugLabel: 'other-control');
    addTearDown(otherFocusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ShellNavigationSearchShortcutScope(
          child: Builder(
            builder: (context) {
              searchFocusNode =
                  ShellNavigationSearchShortcutScope.maybeFocusNodeOf(context)!;
              return Column(
                children: <Widget>[
                  Focus(
                    focusNode: otherFocusNode,
                    child: const SizedBox(height: 20),
                  ),
                  Focus(
                    focusNode: searchFocusNode,
                    child: const SizedBox(height: 20),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    otherFocusNode.requestFocus();
    await tester.pump();
    expect(otherFocusNode.hasFocus, isTrue);
    expect(searchFocusNode.hasFocus, isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(searchFocusNode.hasFocus, isTrue);
  });
}

class _NavigationHarness {
  final List<DesktopRoute> routes = <DesktopRoute>[];
  final List<String> selectedServerIds = <String>[];
  final List<Map<String, String>> workspaceEvents = <Map<String, String>>[];
  final List<({AppControl control, String? tab})> controlUses =
      <({AppControl control, String? tab})>[];
  final List<String> terminalLines = <String>[];
  var clearDeletedProjectNoticeCalls = 0;
  var prepareAddServerCalls = 0;

  ShellNavigationActions get actions {
    return ShellNavigationActions(
      navigate: routes.add,
      clearDeletedProjectNotice: () => clearDeletedProjectNoticeCalls += 1,
      prepareAddServer: () => prepareAddServerCalls += 1,
      selectServer: selectedServerIds.add,
      lastVisitedDestination: (_) => 'workers',
      trackWorkspaceOpened: ({required workspace, entryPoint, tab}) {
        workspaceEvents.add(<String, String>{
          'workspace': workspace,
          ...?(entryPoint == null
              ? null
              : <String, String>{'entry_point': entryPoint}),
          ...?(tab == null ? null : <String, String>{'tab': tab}),
        });
      },
      trackControlUsed: ({required control, tab}) {
        controlUses.add((control: control, tab: tab));
      },
      writeTerminalNavigationLine: terminalLines.add,
    );
  }
}

class _FakeProjectListNotifier extends ProjectListNotifier {
  _FakeProjectListNotifier(this._projects);

  final List<Project> _projects;

  @override
  List<Project> build() => _projects;
}

class _FakeServerCatalogNotifier extends ServerCatalogNotifier {
  _FakeServerCatalogNotifier(this._catalog);

  final ServerCatalogState _catalog;

  @override
  ServerCatalogState build() => _catalog;
}

class _FakeDesktopUpdateController extends DesktopUpdateController {
  @override
  Future<DesktopUpdateSnapshot> build() async {
    return DesktopUpdateSnapshot.notChecked(
      const DesktopBuildInfo(version: '0.1.0', build: '1'),
    );
  }
}
