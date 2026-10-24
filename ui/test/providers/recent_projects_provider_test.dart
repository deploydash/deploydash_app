import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/project_screen_visit_repository.dart';
import 'package:ui/data/local/server_repository.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:ui/providers/recent_projects_provider.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/ui/project/workspace/shell/project_destinations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectScreenVisitRecord _visit({
  required String projectId,
  required String destinationId,
  required DateTime visitedAt,
  String projectName = 'Billing',
  String? serverId = 'server-1',
}) {
  return ProjectScreenVisitRecord(
    projectId: projectId,
    destinationId: destinationId,
    visitedAt: visitedAt,
    projectName: projectName,
    serverId: serverId,
  );
}

/// Stands in for the encrypted database, which these tests never touch.
class _UnusedDatabase implements AppDatabase {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
      'The recents providers must not query the database.',
    );
  }
}

class _StubVisitRepository extends ProjectScreenVisitRepository {
  _StubVisitRepository(
    this._visits, {
    this.failRecording = false,
    this.failListing = false,
  }) : super(_UnusedDatabase());

  final List<ProjectScreenVisitRecord> _visits;
  final bool failRecording;
  final bool failListing;
  final recordedVisits = <String>[];

  @override
  Future<void> recordVisit({
    required String projectId,
    required String destinationId,
  }) async {
    if (failRecording) {
      throw StateError('recording failed');
    }
    recordedVisits.add('$projectId/$destinationId');
  }

  @override
  Future<List<ProjectScreenVisitRecord>> listRecentVisits({
    int limit = 200,
  }) async {
    if (failListing) {
      throw StateError('listing failed');
    }
    return _visits;
  }
}

class _FakeServerCatalogNotifier extends ServerCatalogNotifier {
  _FakeServerCatalogNotifier(this._state);

  final ServerCatalogState _state;

  @override
  ServerCatalogState build() => _state;
}

class _FakeProjectListNotifier extends ProjectListNotifier {
  _FakeProjectListNotifier(this._projects);

  final List<Project> _projects;

  @override
  List<Project> build() => _projects;
}

void main() {
  group('groupRecentProjectVisits', () {
    test(
      'groups screens per project, orders projects newest first, and sorts screens canonically',
      () {
        final groups = groupRecentProjectVisits(
          [
            _visit(
              projectId: 'project-1',
              destinationId: 'web-app',
              visitedAt: DateTime.utc(2026, 8, 10),
            ),
            _visit(
              projectId: 'project-2',
              destinationId: 'database',
              visitedAt: DateTime.utc(2026, 8, 14),
              projectName: 'Marketing',
              serverId: 'server-2',
            ),
            _visit(
              projectId: 'project-1',
              destinationId: 'log',
              visitedAt: DateTime.utc(2026, 8, 12),
            ),
          ],
          serverNamesById: const {'server-1': 'prod-01', 'server-2': 'staging'},
        );

        expect(groups.map((group) => group.projectId), <String>[
          'project-2',
          'project-1',
        ]);
        expect(groups.first.serverName, 'staging');
        expect(groups.first.lastVisitedAt, DateTime.utc(2026, 8, 14));
        expect(
          groups.last.screens.map((screen) => screen.destinationId),
          <String>['web-app', 'log'],
        );
        expect(groups.last.screens.first.label, 'Web app');
        expect(groups.last.screens.last.label, 'Log');
        expect(groups.every((group) => group.showServerName), isFalse);
      },
    );

    test('caps the result at the total subscreen limit across projects', () {
      final visits = [
        for (var index = 0; index < 14; index++)
          _visit(
            projectId: 'project-$index',
            destinationId: 'web-app',
            visitedAt: DateTime.utc(2026, 8, 1).add(Duration(hours: index)),
            projectName: 'Project $index',
          ),
      ];

      final groups = groupRecentProjectVisits(
        visits,
        serverNamesById: const <String, String>{},
      );

      expect(groups, hasLength(10));
      expect(groups.first.projectName, 'Project 13');
      expect(
        groupRecentProjectVisits(
          visits,
          serverNamesById: const <String, String>{},
          maxTotalSubscreens: 0,
        ),
        isEmpty,
      );
    });

    test('stops adding projects when total subscreens reaches limit', () {
      final visits = [
        // Project 1: 3 screens (visited newest)
        _visit(
          projectId: 'b1',
          destinationId: 'web-app',
          visitedAt: DateTime.utc(2026, 8, 20),
        ),
        _visit(
          projectId: 'b1',
          destinationId: 'database',
          visitedAt: DateTime.utc(2026, 8, 20),
        ),
        _visit(
          projectId: 'b1',
          destinationId: 'workers',
          visitedAt: DateTime.utc(2026, 8, 20),
        ),
        // Project 2: 4 screens
        _visit(
          projectId: 'b2',
          destinationId: 'web-app',
          visitedAt: DateTime.utc(2026, 8, 19),
        ),
        _visit(
          projectId: 'b2',
          destinationId: 'database',
          visitedAt: DateTime.utc(2026, 8, 19),
        ),
        _visit(
          projectId: 'b2',
          destinationId: 'workers',
          visitedAt: DateTime.utc(2026, 8, 19),
        ),
        _visit(
          projectId: 'b2',
          destinationId: 'scheduler',
          visitedAt: DateTime.utc(2026, 8, 19),
        ),
        // Project 3: 3 screens (total reaches 10)
        _visit(
          projectId: 'b3',
          destinationId: 'web-app',
          visitedAt: DateTime.utc(2026, 8, 18),
        ),
        _visit(
          projectId: 'b3',
          destinationId: 'database',
          visitedAt: DateTime.utc(2026, 8, 18),
        ),
        _visit(
          projectId: 'b3',
          destinationId: 'settings',
          visitedAt: DateTime.utc(2026, 8, 18),
        ),
        // Project 4: 2 screens (should not be included because total screens reached 10)
        _visit(
          projectId: 'b4',
          destinationId: 'web-app',
          visitedAt: DateTime.utc(2026, 8, 17),
        ),
        _visit(
          projectId: 'b4',
          destinationId: 'database',
          visitedAt: DateTime.utc(2026, 8, 17),
        ),
      ];

      final groups = groupRecentProjectVisits(
        visits,
        serverNamesById: const <String, String>{},
        maxTotalSubscreens: 10,
      );

      expect(groups.map((g) => g.projectId), <String>['b1', 'b2', 'b3']);
      final totalScreens = groups.fold<int>(
        0,
        (sum, g) => sum + g.screens.length,
      );
      expect(totalScreens, 10);
    });

    test('shows the server name when project names collide', () {
      final groups = groupRecentProjectVisits(
        [
          _visit(
            projectId: 'project-1',
            destinationId: 'web-app',
            visitedAt: DateTime.utc(2026, 8, 12),
            projectName: 'api',
          ),
          _visit(
            projectId: 'project-2',
            destinationId: 'web-app',
            visitedAt: DateTime.utc(2026, 8, 11),
            projectName: 'api',
            serverId: 'server-2',
          ),
          _visit(
            projectId: 'project-3',
            destinationId: 'web-app',
            visitedAt: DateTime.utc(2026, 8, 10),
            projectName: 'web',
            serverId: null,
          ),
        ],
        serverNamesById: const {'server-1': 'prod-01', 'server-2': 'staging'},
      );

      expect(groups[0].showServerName, isTrue);
      expect(groups[0].serverName, 'prod-01');
      expect(groups[1].showServerName, isTrue);
      expect(groups[1].serverName, 'staging');
      expect(groups[2].showServerName, isFalse);
      expect(groups[2].serverName, isNull);
    });

    test('falls back to the default label for unknown screens', () {
      final groups = groupRecentProjectVisits([
        _visit(
          projectId: 'project-1',
          destinationId: 'not-a-screen',
          visitedAt: DateTime.utc(2026, 8, 12),
        ),
      ], serverNamesById: const <String, String>{});

      expect(groups.single.screens.single.label, 'Web app');
    });
  });

  group('recents providers', () {
    ProviderContainer buildContainer(
      List<ProjectScreenVisitRecord> visits, {
      _StubVisitRepository? repository,
      List<Project> projects = const <Project>[],
    }) {
      final container = ProviderContainer(
        overrides: [
          projectScreenVisitRepositoryProvider.overrideWithValue(
            repository ?? _StubVisitRepository(visits),
          ),
          projectListProvider.overrideWith(
            () => _FakeProjectListNotifier(projects),
          ),
          serverCatalogProvider.overrideWith(
            () => _FakeServerCatalogNotifier(
              const ServerCatalogState(
                isLoading: false,
                onboardingComplete: true,
                servers: <Server>[
                  Server(
                    id: 'server-1',
                    name: 'prod-01',
                    host: '203.0.113.10',
                    port: 22,
                    sshUser: 'ubuntu',
                    authMethod: ServerAuthMethod.password,
                  ),
                ],
                selectedServerId: 'server-1',
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        recentProjectVisitsProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      return container;
    }

    test('groups the loaded visits once they resolve', () async {
      final container = buildContainer([
        _visit(
          projectId: 'project-1',
          destinationId: 'database',
          visitedAt: DateTime.utc(2026, 8, 12),
        ),
      ]);

      expect(container.read(recentProjectGroupsProvider), isEmpty);
      await container.read(recentProjectVisitsProvider.notifier).refresh();

      final groups = container.read(recentProjectGroupsProvider);
      expect(groups.single.projectName, 'Billing');
      expect(groups.single.serverName, 'prod-01');
      expect(groups.single.screens.single.label, 'Database');
    });

    test('resolves the last visited screen with a default fallback', () async {
      final container = buildContainer([
        _visit(
          projectId: 'project-1',
          destinationId: 'log',
          visitedAt: DateTime.utc(2026, 8, 10),
        ),
        _visit(
          projectId: 'project-1',
          destinationId: 'backup',
          visitedAt: DateTime.utc(2026, 8, 12),
        ),
        _visit(
          projectId: 'project-2',
          destinationId: 'gone',
          visitedAt: DateTime.utc(2026, 8, 12),
        ),
      ]);
      await container.read(recentProjectVisitsProvider.notifier).refresh();

      final resolve = container.read(lastVisitedDestinationProvider);
      expect(resolve('project-1'), 'backup');
      expect(resolve('project-2'), defaultProjectDestinationId);
      expect(resolve('project-unknown'), defaultProjectDestinationId);
    });

    test(
      'recording a visit preserves project position and inserts screen canonically',
      () async {
        final repository = _StubVisitRepository([
          _visit(
            projectId: 'project-1',
            destinationId: 'web-app',
            visitedAt: DateTime.utc(2026, 8, 12),
          ),
          _visit(
            projectId: 'project-2',
            destinationId: 'web-app',
            visitedAt: DateTime.utc(2026, 8, 10),
            projectName: 'Auth',
          ),
        ]);
        final container = buildContainer(
          const <ProjectScreenVisitRecord>[],
          repository: repository,
        );

        await container.read(recentProjectVisitsProvider.notifier).refresh();
        expect(
          container.read(recentProjectGroupsProvider).map((g) => g.projectId),
          ['project-1', 'project-2'],
        );

        // Visit a new screen in project-2: it should NOT jump to the top
        await container
            .read(recentProjectVisitsProvider.notifier)
            .recordVisit(projectId: 'project-2', destinationId: 'database');

        final groups = container.read(recentProjectGroupsProvider);
        expect(groups.map((g) => g.projectId), [
          'project-1',
          'project-2',
        ]); // Project position preserved!
        expect(groups[1].screens.map((s) => s.destinationId), [
          'web-app',
          'database',
        ]); // Screen sorted canonically!
        expect(repository.recordedVisits, <String>['project-2/database']);
      },
    );

    test(
      'opening a new project prepends it to the session recents list',
      () async {
        final repository = _StubVisitRepository([
          _visit(
            projectId: 'project-1',
            destinationId: 'web-app',
            visitedAt: DateTime.utc(2026, 8, 12),
          ),
        ]);
        final container = buildContainer(
          const <ProjectScreenVisitRecord>[],
          repository: repository,
        );

        await container.read(recentProjectVisitsProvider.notifier).refresh();
        expect(
          container.read(recentProjectGroupsProvider).map((g) => g.projectId),
          ['project-1'],
        );

        // Open new project project-new
        await container
            .read(recentProjectVisitsProvider.notifier)
            .recordVisit(
              projectId: 'project-new',
              destinationId: 'database',
              projectName: 'New Service',
            );

        final groups = container.read(recentProjectGroupsProvider);
        expect(groups.map((g) => g.projectId), ['project-new', 'project-1']);
        expect(groups.first.projectName, 'New Service');
        expect(groups.first.screens.single.destinationId, 'database');
      },
    );

    test(
      'resolves the real name for a brand-new project when the caller '
      'omits projectName, instead of falling back to the literal "Project"',
      () async {
        // Every real call site (workspace_shell.dart, main.dart) records a
        // visit WITHOUT passing projectName -- unlike every test above this
        // one, which all supply it explicitly and so never exercise the
        // fallback a real user's first visit to a brand-new project
        // actually takes. Neither `state` (empty; nothing recorded yet) nor
        // `_rawVisits` (loaded once at provider build, before this project
        // existed) can resolve the name for a project this new, so the
        // notifier must fall back to looking the project up directly.
        final container = buildContainer(
          const <ProjectScreenVisitRecord>[],
          projects: const <Project>[
            Project(
              id: 'project-new',
              serverId: 'server-1',
              name: 'E2E checklist alpha',
              type: 'web_app',
              gitUrl: '',
              primaryDomain: '',
            ),
          ],
        );

        await container
            .read(recentProjectVisitsProvider.notifier)
            .recordVisit(projectId: 'project-new', destinationId: 'web-app');

        final groups = container.read(recentProjectGroupsProvider);
        expect(groups.single.projectId, 'project-new');
        expect(groups.single.projectName, 'E2E checklist alpha');
        expect(groups.single.serverId, 'server-1');
      },
    );

    test('keeps the recents list empty when the database fails', () async {
      final failingRecorder = _StubVisitRepository(
        const <ProjectScreenVisitRecord>[],
        failRecording: true,
      );
      final recordContainer = buildContainer(
        const <ProjectScreenVisitRecord>[],
        repository: failingRecorder,
      );
      await recordContainer
          .read(recentProjectVisitsProvider.notifier)
          .recordVisit(projectId: 'project-1', destinationId: 'web-app');
      expect(recordContainer.read(recentProjectVisitsProvider), isEmpty);

      final failingReader = _StubVisitRepository(
        const <ProjectScreenVisitRecord>[],
        failListing: true,
      );
      final readContainer = buildContainer(
        const <ProjectScreenVisitRecord>[],
        repository: failingReader,
      );
      await readContainer.read(recentProjectVisitsProvider.notifier).refresh();
      expect(readContainer.read(recentProjectGroupsProvider), isEmpty);
    });
  });
}
