import 'dart:ui' show Tristate;

import 'package:ui/data/local/project_screen_visit_repository.dart';
import 'package:ui/data/local/server_repository.dart';
import 'package:ui/providers/recent_projects_provider.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/services/local_search_index.dart';
import 'package:ui/ui/layout/app_navigation_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _server = Server(
  id: 'server-1',
  name: 'Prod-01',
  host: '203.0.113.10',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
);

class _FakeServerCatalogNotifier extends ServerCatalogNotifier {
  _FakeServerCatalogNotifier(this._state);

  final ServerCatalogState _state;

  @override
  ServerCatalogState build() => _state;
}

RecentProjectGroup _group({
  required String projectId,
  required String projectName,
  List<String> destinationIds = const <String>['web-app'],
  String? serverName,
  bool showServerName = false,
}) {
  return RecentProjectGroup(
    projectId: projectId,
    projectName: projectName,
    serverId: 'server-1',
    serverName: serverName,
    showServerName: showServerName,
    screens: <RecentProjectScreen>[
      for (var index = 0; index < destinationIds.length; index++)
        RecentProjectScreen(
          destinationId: destinationIds[index],
          label: destinationIds[index] == 'web-app' ? 'Web app' : 'Database',
          visitedAt: DateTime.utc(2026, 8, 12).subtract(Duration(hours: index)),
        ),
    ],
  );
}

Widget _wrap(Widget child, {ServerCatalogNotifier? serverCatalogNotifier}) {
  return ProviderScope(
    overrides: [
      serverCatalogProvider.overrideWith(
        () =>
            serverCatalogNotifier ??
            _FakeServerCatalogNotifier(
              ServerCatalogState(
                isLoading: false,
                onboardingComplete: true,
                servers: const <Server>[_server],
                selectedServerId: 'server-1',
              ),
            ),
      ),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  testWidgets('Expanded rail shows Home first and main actions', (
    WidgetTester tester,
  ) async {
    var openedProjectId = '';
    var openedDestinationId = '';
    var homeCount = 0;
    var manageCount = 0;
    var settingsCount = 0;

    await tester.pumpWidget(
      _wrap(
        AppNavigationRail(
          selectedSection: AppNavigationSection.project,
          extended: true,
          recentProjectGroups: <RecentProjectGroup>[
            _group(
              projectId: 'project-1',
              projectName: 'Alpha App',
              destinationIds: const <String>['web-app', 'database'],
            ),
          ],
          currentProjectId: 'project-1',
          currentDestinationId: 'web-app',
          currentServerName: 'Prod-01',
          showCurrentServer: true,
          onOpenProjectScreen: (projectId, destinationId) {
            openedProjectId = projectId;
            openedDestinationId = destinationId;
          },
          onOpenHome: () => homeCount += 1,
          onOpenServerManagement: () => manageCount += 1,
          onOpenAppSettings: () => settingsCount += 1,
        ),
      ),
    );

    expect(find.text('Alpha App'), findsOneWidget);
    expect(find.text('Deploy Dash development'), findsOneWidget);
    expect(
      find.byKey(const Key('left-rail-recent-projects-heading')),
      findsOneWidget,
    );
    final recentsHeading = tester.widget<Text>(find.text('Recent projects'));
    final headingTheme = Theme.of(tester.element(find.text('Recent projects')));
    expect(
      recentsHeading.style?.fontSize,
      headingTheme.textTheme.labelLarge?.fontSize,
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const Key('left-rail-recent-screen-project-1-web-app')),
          )
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );

    await tester.tap(find.byKey(const Key('left-rail-home-button')));
    await tester.pump();
    expect(homeCount, 1);

    await tester.tap(
      find.byKey(const Key('left-rail-recent-screen-project-1-database')),
    );
    await tester.pump();
    expect(openedProjectId, 'project-1');
    expect(openedDestinationId, 'database');

    await tester.tap(find.byKey(const Key('left-rail-current-server')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('left-rail-app-settings-button')));
    await tester.pump();

    expect(manageCount, 1);
    expect(settingsCount, 1);
  });

  testWidgets('Expanded rail names the server when projects share a name', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AppNavigationRail(
          extended: true,
          recentProjectGroups: <RecentProjectGroup>[
            _group(
              projectId: 'project-1',
              projectName: 'api',
              serverName: 'prod-01',
              showServerName: true,
            ),
            _group(
              projectId: 'project-2',
              projectName: 'api',
              serverName: 'staging',
              showServerName: true,
            ),
          ],
          onOpenProjectScreen: (_, _) {},
        ),
      ),
    );

    expect(find.text('api'), findsNWidgets(2));
    expect(find.text('prod-01'), findsOneWidget);
    expect(find.text('staging'), findsOneWidget);
  });

  testWidgets('Collapsed rail uses icon actions and project selection', (
    WidgetTester tester,
  ) async {
    var homeCount = 0;
    var settingsCount = 0;
    var openedDestinationId = '';

    await tester.pumpWidget(
      _wrap(
        AppNavigationRail(
          selectedSection: AppNavigationSection.project,
          extended: false,
          recentProjectGroups: <RecentProjectGroup>[
            _group(
              projectId: 'project-1',
              projectName: 'Alpha App',
              destinationIds: const <String>['database'],
            ),
          ],
          currentProjectId: 'project-1',
          currentDestinationId: 'database',
          currentServerName: 'Prod-01',
          showCurrentServer: true,
          onOpenProjectScreen: (_, destinationId) {
            openedDestinationId = destinationId;
          },
          onOpenHome: () => homeCount += 1,
          onOpenServerManagement: () {},
          onOpenAppSettings: () => settingsCount += 1,
        ),
      ),
    );

    expect(find.byTooltip('Home'), findsOneWidget);
    expect(find.byTooltip('Alpha App'), findsOneWidget);
    expect(find.byTooltip('Manage Prod-01'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.text('dev'), findsOneWidget);
    expect(find.byTooltip('Deploy Dash development'), findsOneWidget);
    expect(find.byKey(const Key('left-rail-recent-empty')), findsNothing);

    await tester.tap(
      find.byKey(const Key('left-rail-recent-project-project-1')),
    );
    await tester.pump();
    expect(openedDestinationId, 'database');

    await tester.tap(find.byKey(const Key('left-rail-home-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('left-rail-app-settings-button')));
    await tester.pump();

    expect(homeCount, 1);
    expect(settingsCount, 1);
  });

  testWidgets('Collapsed rail tooltips name the server for duplicates', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AppNavigationRail(
          extended: false,
          showCurrentServer: true,
          recentProjectGroups: <RecentProjectGroup>[
            _group(
              projectId: 'project-1',
              projectName: 'api',
              serverName: 'staging',
              showServerName: true,
            ),
          ],
        ),
      ),
    );

    expect(find.byTooltip('api on staging'), findsOneWidget);
    expect(find.byTooltip('Manage Server'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('left-rail-recent-project-project-1')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('update badge opens Updates in expanded and collapsed rails', (
    WidgetTester tester,
  ) async {
    var openCount = 0;
    Future<void> pumpRail(bool extended) {
      return tester.pumpWidget(
        _wrap(
          AppNavigationRail(
            extended: extended,
            updateAvailable: true,
            onOpenUpdates: () => openCount += 1,
          ),
        ),
      );
    }

    await pumpRail(true);
    expect(find.byKey(const Key('left-rail-update-badge')), findsOneWidget);
    await tester.tap(find.byKey(const Key('left-rail-version-label')));
    expect(openCount, 1);

    await pumpRail(false);
    expect(
      find.byTooltip('Deploy Dash development. Update available.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('left-rail-version-label')));
    expect(openCount, 2);
  });

  testWidgets('Expanded rail explains an empty recents list', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AppNavigationRail(
          selectedSection: AppNavigationSection.server,
          extended: true,
          onOpenHome: () {},
          onOpenServerManagement: () {},
          onOpenAppSettings: () {},
        ),
      ),
    );

    expect(find.byKey(const Key('left-rail-recent-empty')), findsOneWidget);
    expect(find.text('No recent projects'), findsOneWidget);
    expect(
      find.text('Open a project from Home to see it here.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('left-rail-current-server')), findsNothing);
  });

  testWidgets('Rail search opens results for a matching query', (
    WidgetTester tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    LocalSearchResult? selected;

    await tester.pumpWidget(
      _wrap(
        AppNavigationRail(
          extended: true,
          searchFocusNode: focusNode,
          searchResultsBuilder: (query) => query.isEmpty
              ? const <LocalSearchResult>[]
              : const <LocalSearchResult>[
                  LocalSearchResult(
                    kind: LocalSearchResultKind.server,
                    title: 'Prod-01',
                    subtitle: '203.0.113.10',
                    serverId: 'server-1',
                  ),
                ],
          onSearchResultSelected: (result) => selected = result,
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('app-search-field')), 'prod');
    await tester.pump();
    await tester.tap(find.byKey(const Key('app-search-result-server-0')));
    await tester.pump();

    expect(selected?.serverId, 'server-1');
  });

  testWidgets('Rail hides search when no search callbacks are supplied', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_wrap(const AppNavigationRail(extended: true)));

    expect(find.byKey(const Key('app-search-field')), findsNothing);
  });

  testWidgets('Rail owns a focus node when the shell does not supply one', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AppNavigationRail(
          extended: true,
          searchResultsBuilder: (_) => const <LocalSearchResult>[],
          onSearchResultSelected: (_) {},
        ),
      ),
    );

    expect(find.byKey(const Key('app-search-field')), findsOneWidget);
    await tester.pumpWidget(_wrap(const AppNavigationRail(extended: true)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Recent projects scroll without moving the fixed footer', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final groups = <RecentProjectGroup>[
      for (var index = 0; index < 20; index++)
        _group(
          projectId: 'project-$index',
          projectName: 'Project ${index + 1}',
        ),
    ];

    await tester.pumpWidget(
      _wrap(
        AppNavigationRail(
          selectedSection: AppNavigationSection.server,
          extended: true,
          recentProjectGroups: groups,
          onOpenProjectScreen: (_, _) {},
          onOpenHome: () {},
          onOpenServerManagement: () {},
          onOpenAppSettings: () {},
        ),
      ),
    );

    final settingsBefore = tester.getBottomLeft(
      find.byKey(const Key('left-rail-app-settings-button')),
    );
    await tester.scrollUntilVisible(
      find.text('Project 20'),
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('left-rail-recent-projects-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(find.text('Project 20'), findsOneWidget);
    expect(
      tester.getBottomLeft(
        find.byKey(const Key('left-rail-app-settings-button')),
      ),
      settingsBefore,
    );
  });

  testWidgets('Recent project rows still render without callbacks', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AppNavigationRail(
          extended: true,
          recentProjectGroups: <RecentProjectGroup>[
            _group(projectId: 'project-1', projectName: 'Alpha App'),
          ],
        ),
      ),
    );

    expect(
      tester
          .widget<InkWell>(
            find.byKey(const Key('left-rail-recent-screen-project-1-web-app')),
          )
          .onTap,
      isNull,
    );
  });

  testWidgets('Recent screen labels come from the shared destinations', (
    WidgetTester tester,
  ) async {
    final visit = ProjectScreenVisitRecord(
      projectId: 'project-1',
      destinationId: 'database',
      visitedAt: DateTime.utc(2026, 8, 12),
      projectName: 'Alpha App',
      serverId: 'server-1',
    );

    await tester.pumpWidget(
      _wrap(
        AppNavigationRail(
          extended: true,
          recentProjectGroups: groupRecentProjectVisits(
            <ProjectScreenVisitRecord>[visit],
            serverNamesById: const {'server-1': 'Prod-01'},
          ),
          onOpenProjectScreen: (_, _) {},
        ),
      ),
    );

    expect(find.text('Database'), findsOneWidget);
  });
}
