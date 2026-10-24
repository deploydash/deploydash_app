import 'package:ui/data/local/server_repository.dart';
import 'package:ui/providers/recent_projects_provider.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/services/local_search_index.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui/layout/app_navigation_rail.dart';

void main() {
  const seededServer = Server(
    id: 'server-prod-01',
    name: 'Prod-01',
    host: '203.0.113.10',
    port: 22,
    sshUser: 'root',
    authMethod: ServerAuthMethod.password,
  );

  final recentGroups = <RecentProjectGroup>[
    RecentProjectGroup(
      projectId: 'project-main',
      projectName: 'Main App',
      serverId: 'server-prod-01',
      serverName: 'Prod-01',
      screens: <RecentProjectScreen>[
        RecentProjectScreen(
          destinationId: 'web-app',
          label: 'Web app',
          visitedAt: DateTime.utc(2026, 8, 12),
        ),
      ],
    ),
    RecentProjectGroup(
      projectId: 'project-worker',
      projectName: 'Worker App',
      serverId: 'server-prod-01',
      serverName: 'Prod-01',
      screens: <RecentProjectScreen>[
        RecentProjectScreen(
          destinationId: 'workers',
          label: 'Workers',
          visitedAt: DateTime.utc(2026, 8, 11),
        ),
      ],
    ),
  ];

  Widget buildRail({required bool extended}) {
    return ProviderScope(
      overrides: [
        serverCatalogProvider.overrideWith(
          () => _FakeServerCatalogNotifier(
            const ServerCatalogState(
              isLoading: false,
              onboardingComplete: true,
              servers: [seededServer],
              selectedServerId: 'server-prod-01',
              onboardingStep: 'connected',
            ),
          ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: AppNavigationRail(
            extended: extended,
            recentProjectGroups: recentGroups,
            currentServerName: 'Prod-01',
            showCurrentServer: true,
            selectedSection: AppNavigationSection.project,
            searchResultsBuilder: (_) => const <LocalSearchResult>[],
            onSearchResultSelected: (_) {},
            onOpenProjectScreen: (_, _) {},
          ),
        ),
      ),
    );
  }

  testWidgets('AppNavigationRail toggles width and shows items', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildRail(extended: true));

    expect(
      find.byKey(const Key('left-rail-recent-projects-list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('left-rail-recent-projects-heading')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('left-rail-current-server')), findsOne);
    expect(find.byKey(const Key('left-rail-app-settings-button')), findsOne);
    expect(find.text('Deploy Dash development'), findsOneWidget);
    expect(find.byKey(const Key('app-search-field')), findsOne);
    final homeTop = tester.getTopLeft(
      find.byKey(const Key('left-rail-home-button')),
    );
    final searchTop = tester.getTopLeft(
      find.byKey(const Key('app-search-field')),
    );
    final currentServerTop = tester.getTopLeft(
      find.byKey(const Key('left-rail-current-server')),
    );
    expect(homeTop.dy, lessThan(searchTop.dy));
    expect(searchTop.dy, lessThan(currentServerTop.dy));
    final extendedSettingsBottom = tester.getBottomLeft(
      find.byKey(const Key('left-rail-app-settings-button')),
    );
    final extendedRailBottom = tester.getBottomLeft(
      find.byType(AppNavigationRail),
    );
    expect(
      (extendedRailBottom.dy - extendedSettingsBottom.dy).abs(),
      lessThanOrEqualTo(24),
    );

    await tester.pumpWidget(buildRail(extended: false));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('left-rail-app-settings-button')), findsOne);
    expect(find.text('dev'), findsOneWidget);
    expect(find.byKey(const Key('app-search-field')), findsNothing);
    expect(find.byKey(const Key('app-search-icon-button')), findsOne);
    final collapsedSettingsBottom = tester.getBottomLeft(
      find.byKey(const Key('left-rail-app-settings-button')),
    );
    final collapsedRailBottom = tester.getBottomLeft(
      find.byType(AppNavigationRail),
    );
    expect(
      (collapsedRailBottom.dy - collapsedSettingsBottom.dy).abs(),
      lessThanOrEqualTo(20),
    );
  });
}

class _FakeServerCatalogNotifier extends ServerCatalogNotifier {
  _FakeServerCatalogNotifier(this._seedState);

  final ServerCatalogState _seedState;

  @override
  ServerCatalogState build() => _seedState;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> selectServer(String serverId) async {
    state = state.copyWith(selectedServerId: serverId);
  }
}
