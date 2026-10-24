import 'package:flutter_test/flutter_test.dart';

import '_support/project_workspace_harness.dart';

/// Recent-screen tracking for the project workspace.
///
/// Split from `project_workspace_test.dart` by T-3.6.1.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('project workspace recents', () {
    testWidgets('clamps an out-of-range initial screen to the last screen', (
      tester,
    ) async {
      await pumpProjectWorkspace(
        tester,
        child: const ProjectWorkspace(initialTabIndex: 99),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithServicesDisabled),
        ],
      );

      expect(
        tester
            .getSemantics(
              find.byKey(const Key('project-workspace-nav-settings')),
            )
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
    });

    testWidgets('clamps a negative initial screen to the web app', (
      tester,
    ) async {
      await pumpProjectWorkspace(
        tester,
        child: const ProjectWorkspace(initialTabIndex: -3),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithServicesDisabled),
        ],
      );

      expect(
        tester
            .getSemantics(
              find.byKey(const Key('project-workspace-nav-web-app')),
            )
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
    });

    testWidgets('records a screen visit when the user switches screens', (
      tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithServicesDisabled),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      await ProjectRepository(database).createProject(
        const Project(
          id: 'project-runtime',
          name: 'Regs v3',
          type: 'Web app',
          gitUrl: 'https://github.com/example/buildingregs',
          primaryDomain: 'dev.buildingregs.app',
        ),
      );
      container
          .read(selectedProjectIdProvider.notifier)
          .select('project-runtime');

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1920, 1080);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ProjectWorkspace())),
        ),
      );
      await tester.pumpAndSettle();

      await openProjectWorkspaceDestination(tester, 'email');
      await tester.pumpAndSettle();

      final visits = await database.select(database.projectScreenVisits).get();
      expect(visits.map((visit) => visit.destinationId), contains('email'));
      expect(
        visits.every((visit) => visit.projectId == 'project-runtime'),
        isTrue,
      );
    });

    testWidgets('skips recording when no project is selected', (tester) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithServicesDisabled),
        ],
      );

      await openProjectWorkspaceDestination(tester, 'email');
      await tester.pumpAndSettle();

      expect(
        await database.select(database.projectScreenVisits).get(),
        isEmpty,
      );
    });
  }, skip: !sqliteAvailable);
}
