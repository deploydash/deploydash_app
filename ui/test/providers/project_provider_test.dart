import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:ui/data/local/project_repository.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/models/railpack_runtime.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:ui/providers/project_lifecycle_provider.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_support/fake_analytics_service.dart';

Future<void> _waitForProjectLoad(ProviderContainer container) async {
  for (var i = 0; i < 50; i += 1) {
    final list = container.read(projectListProvider);
    if (list.isNotEmpty) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  late ProviderContainer container;
  late _FakeProjectRepository repository;
  late FakeAnalyticsService analytics;
  late List<(String projectId, String destinationId)> initialVisits;

  setUp(() {
    repository = _FakeProjectRepository();
    analytics = FakeAnalyticsService();
    initialVisits = <(String projectId, String destinationId)>[];
    container = ProviderContainer(
      overrides: [
        projectRepositoryProvider.overrideWithValue(repository),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
        selectedServerIdProvider.overrideWithValue(null),
        projectInitialVisitWriterProvider.overrideWithValue(({
          required projectId,
          required destinationId,
        }) async {
          initialVisits.add((projectId, destinationId));
        }),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  test('addProject creates active project and persists it', () async {
    final notifier = container.read(projectListProvider.notifier);
    final created = notifier.addProject(
      name: 'Blog',
      type: 'Web app',
      gitUrl: 'git@github.com:me/blog.git',
      primaryDomain: 'blog.example.com',
    );

    expect(created.id, contains('project-blog-'));
    expect(created.isActive, isTrue);
    expect(container.read(projectListProvider), hasLength(1));
    expect(
      container.read(selectedProjectProvider)?.primaryDomain,
      'blog.example.com',
    );

    await Future<void>.delayed(const Duration(milliseconds: 5));
    final persisted = await repository.listProjects();
    expect(persisted, hasLength(1));
    expect(persisted.single.id, created.id);
    expect(persisted.single.isActive, isTrue);
  });

  test(
    'project lifecycle creates and selects a project outside widget state',
    () async {
      final project = container
          .read(projectLifecycleActionsProvider)
          .createProject(
            serverId: 'server-1',
            name: 'Lifecycle app',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'lifecycle.example.com',
            railpackProvider: 'node',
            railpackBuildCommand: 'npm run build',
            railpackRunCommand: 'npm run start',
            appPort: 3000,
            initialDestinationId: 'web_app',
          );

      expect(project.serverId, 'server-1');
      expect(container.read(selectedProjectIdProvider), project.id);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect((await repository.listProjects()).single.id, project.id);
    },
  );

  test(
    'project lifecycle selects and records a project visit outside widget state',
    () {
      const projectId = 'project-navigation';

      container
          .read(projectLifecycleActionsProvider)
          .openProject(
            projectId: projectId,
            destinationId: 'database',
            hasServers: false,
          );

      expect(container.read(selectedProjectIdProvider), projectId);
      expect(initialVisits, [(projectId, 'database')]);
    },
  );

  test('updateDeploymentConfig normalizes persisted settings', () async {
    final notifier = container.read(projectListProvider.notifier);
    final project = notifier.addProject(
      name: 'Docs',
      type: 'Web app',
      gitUrl: '',
      primaryDomain: 'docs.example.com',
    );

    notifier.updateDeploymentConfig(
      projectId: project.id,
      primaryDomain: ' app.example.com ',
      domainRoutingMode: 'redirect_apex_to_www',
      repositoryFullName: ' me/docs ',
      appSubdirectory: r' website\frontend ',
      deployBranch: ' main ',
      appPort: 70000,
      publicHealthCheckEnabled: false,
      publicHealthCheckPath: 'invalid-path',
      railpackNodeMode: 'RUNTIME',
      railpackProvider: 'PYTHON',
      tlsChallengeMode: 'dns',
      tlsDnsProvider: 'CLOUDFLARE',
      tlsDnsCredentials: const {' API_TOKEN ': ' token-1 '},
      sqliteStorageEnabled: true,
      sqliteVolumeName: ' deploydash_sqlite_docs ',
      sqliteMountPath: ' /var/lib/deploydash/sqlite ',
      sqliteFileName: ' app.sqlite3 ',
      railpackBuildCommand: ' ',
      railpackRunCommand: ' ',
    );

    await Future<void>.delayed(const Duration(milliseconds: 5));
    final persisted = await repository.listProjects();
    expect(persisted, hasLength(1));
    final item = persisted.single;
    expect(item.primaryDomain, 'app.example.com');
    expect(item.domainRoutingMode, 'redirect_apex_to_www');
    expect(item.repositoryFullName, 'me/docs');
    expect(item.appSubdirectory, 'website/frontend');
    expect(item.deployBranch, 'main');
    expect(item.appPort, 3000);
    expect(item.publicHealthCheckEnabled, isFalse);
    expect(item.publicHealthCheckPath, '/');
    expect(item.railpackNodeMode, 'runtime');
    expect(item.railpackProvider, 'python');
    expect(item.railpackBuildCommand, isEmpty);
    expect(item.railpackRunCommand, isEmpty);
    expect(item.tlsChallengeMode, 'dns');
    expect(item.tlsDnsProvider, 'cloudflare');
    expect(item.tlsDnsCredentials, const {'api_token': 'token-1'});
    expect(item.sqliteStorageEnabled, isTrue);
    expect(item.sqliteVolumeName, 'deploydash_sqlite_docs');
    expect(item.sqliteMountPath, '/var/lib/deploydash/sqlite');
    expect(item.sqliteFileName, 'app.sqlite3');
  });

  test(
    'updateDeploymentConfig strips leading www for redirect modes',
    () async {
      final notifier = container.read(projectListProvider.notifier);
      final project = notifier.addProject(
        name: 'Docs',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'docs.example.com',
      );

      notifier.updateDeploymentConfig(
        projectId: project.id,
        primaryDomain: 'www.docs.example.com',
        domainRoutingMode: 'redirect_www_to_apex',
        repositoryFullName: 'me/docs',
        appSubdirectory: null,
        deployBranch: 'main',
        appPort: 3000,
        railpackNodeMode: 'auto',
        railpackProvider: null,
        tlsChallengeMode: 'http',
        tlsDnsProvider: null,
        tlsDnsCredentials: const {},
        sqliteStorageEnabled: false,
        sqliteVolumeName: null,
        sqliteMountPath: null,
        sqliteFileName: null,
        railpackBuildCommand: null,
        railpackRunCommand: null,
      );

      await Future<void>.delayed(const Duration(milliseconds: 5));
      final persisted = await repository.listProjects();
      expect(persisted.single.primaryDomain, 'docs.example.com');
      expect(persisted.single.domainRoutingMode, 'redirect_www_to_apex');
    },
  );

  test(
    'runtime and deploy state updates are reflected in selected project',
    () async {
      final notifier = container.read(projectListProvider.notifier);
      final project = notifier.addProject(
        name: 'API',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'api.example.com',
      );

      final deployedAt = DateTime.utc(2026, 2, 20, 2, 30);
      notifier.updateLastDeployState(
        projectId: project.id,
        commit: ' abcdef123456 ',
        deployedAt: deployedAt,
      );
      notifier.updateRuntimeState(projectId: project.id, appDisconnected: true);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final selected = container.read(selectedProjectProvider);
      expect(selected, isNotNull);
      expect(selected!.lastDeployCommit, 'abcdef123456');
      expect(selected.lastDeployedAt, deployedAt);
      expect(selected.appDisconnected, isTrue);
    },
  );

  test(
    'selectedProjectId loads persisted active project and select persists',
    () async {
      await repository.createProject(
        const Project(
          id: 'project-a',
          name: 'A',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'a.example.com',
          isActive: false,
        ),
      );
      await repository.createProject(
        const Project(
          id: 'project-b',
          name: 'B',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'b.example.com',
          isActive: true,
        ),
      );

      container.read(projectListProvider);
      await _waitForProjectLoad(container);

      container.read(selectedProjectIdProvider);
      for (var i = 0; i < 30; i += 1) {
        if (container.read(selectedProjectIdProvider) == 'project-b') {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(container.read(selectedProjectIdProvider), 'project-b');
      expect(container.read(selectedProjectProvider)?.id, 'project-b');

      container.read(selectedProjectIdProvider.notifier).select('project-a');
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(container.read(selectedProjectIdProvider), 'project-a');
      expect(container.read(selectedProjectProvider)?.id, 'project-a');
      expect(await repository.readActiveProjectId(), 'project-a');
    },
  );

  test(
    'updateDatabaseWiring updates selected project and persists values',
    () async {
      final notifier = container.read(projectListProvider.notifier);
      final project = notifier.addProject(
        name: 'Vectors',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'vectors.example.com',
      );

      notifier.updateDatabaseWiring(
        projectId: project.id,
        injectPostgresEnv: true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 5));
      final selected = container.read(selectedProjectProvider);
      expect(selected, isNotNull);
      expect(selected!.injectPostgresEnv, isTrue);

      final persisted = await repository.listProjects();
      expect(persisted.single.injectPostgresEnv, isTrue);
    },
  );

  test(
    'updates keep untargeted projects unchanged and selection falls back sanely',
    () async {
      final notifier = container.read(projectListProvider.notifier);
      final first = notifier.addProject(
        name: 'First',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'first.example.com',
      );
      final second = notifier.addProject(
        name: 'Second',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'second.example.com',
      );

      notifier.updateDeploymentConfig(
        projectId: second.id,
        primaryDomain: ' www.second.example.com ',
        domainRoutingMode: 'redirect_www_to_apex',
        repositoryFullName: 'me/second',
        appSubdirectory: null,
        deployBranch: 'main',
        appPort: 8080,
        railpackNodeMode: 'auto',
        railpackProvider: null,
        tlsChallengeMode: 'http',
        tlsDnsProvider: null,
        tlsDnsCredentials: const {},
        sqliteStorageEnabled: false,
        sqliteVolumeName: null,
        sqliteMountPath: null,
        sqliteFileName: null,
        railpackBuildCommand: null,
        railpackRunCommand: null,
      );
      notifier.updateRuntimeState(projectId: second.id, appDisconnected: null);
      notifier.updateDatabaseWiring(
        projectId: second.id,
        injectPostgresEnv: true,
      );
      notifier.updateLastDeployState(
        projectId: second.id,
        commit: '   ',
        deployedAt: DateTime.utc(2026, 3, 1, 10),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final projects = container.read(projectListProvider);
      final unchanged = projects.singleWhere(
        (project) => project.id == first.id,
      );
      final updated = projects.singleWhere(
        (project) => project.id == second.id,
      );
      expect(unchanged.primaryDomain, 'first.example.com');
      expect(unchanged.injectPostgresEnv, isFalse);
      expect(updated.primaryDomain, 'second.example.com');
      expect(updated.appDisconnected, isFalse);
      expect(updated.lastDeployCommit, isNull);

      container.read(selectedProjectIdProvider.notifier).clear();
      expect(container.read(selectedProjectIdProvider), isEmpty);
      expect(container.read(selectedProjectProvider)?.id, second.id);
    },
  );

  test(
    'deleteProject trims ids and falls back when repository returns stale next id',
    () async {
      repository.deleteResultOverride = 'missing-project';
      final notifier = container.read(projectListProvider.notifier);
      final first = notifier.addProject(
        name: 'First',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'first.example.com',
      );
      final second = notifier.addProject(
        name: 'Second',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'second.example.com',
      );

      expect(await notifier.deleteProject('   '), isNull);

      final nextActiveId = await notifier.deleteProject(second.id);
      expect(nextActiveId, first.id);

      final projects = container.read(projectListProvider);
      expect(projects, hasLength(1));
      expect(projects.single.id, first.id);
      expect(projects.single.isActive, isTrue);
    },
  );

  test(
    'deleteProject returns persisted next id when notifier is disposed mid-flight',
    () async {
      final slowRepository = _FakeProjectRepository()
        ..deleteDelay = const Duration(milliseconds: 10);
      final slowContainer = ProviderContainer(
        overrides: [
          projectRepositoryProvider.overrideWithValue(slowRepository),
        ],
      );
      var disposed = false;
      addTearDown(() {
        if (!disposed) {
          slowContainer.dispose();
        }
      });

      final notifier = slowContainer.read(projectListProvider.notifier);
      final first = notifier.addProject(
        name: 'First',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'first.example.com',
      );
      notifier.addProject(
        name: 'Second',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'second.example.com',
      );

      final deleteFuture = notifier.deleteProject(first.id);
      slowContainer.dispose();
      disposed = true;

      expect(await deleteFuture, isNotNull);
    },
  );

  test('hidePendingProject removes it and promotes a remaining project', () {
    final notifier = container.read(projectListProvider.notifier);
    final first = notifier.addProject(
      name: 'First',
      type: 'Web app',
      gitUrl: '',
      primaryDomain: 'first.example.com',
    );
    final second = notifier.addProject(
      name: 'Second',
      type: 'Web app',
      gitUrl: '',
      primaryDomain: 'second.example.com',
    );

    notifier.hidePendingProject('   ');
    expect(container.read(projectListProvider), hasLength(2));

    notifier.hidePendingProject(second.id);
    final remaining = container.read(projectListProvider);
    expect(remaining, hasLength(1));
    expect(remaining.single.id, first.id);
    expect(remaining.single.isActive, isTrue);

    notifier.hidePendingProject(first.id);
    expect(container.read(projectListProvider), isEmpty);
  });

  test('hidePendingProject retains an active project on another server', () {
    final notifier = container.read(projectListProvider.notifier);
    final first = notifier.addProject(
      serverId: 'server-a',
      name: 'First',
      type: 'Web app',
      gitUrl: '',
      primaryDomain: 'first.example.com',
    );
    final second = notifier.addProject(
      serverId: 'server-b',
      name: 'Second',
      type: 'Web app',
      gitUrl: '',
      primaryDomain: 'second.example.com',
    );

    notifier.hidePendingProject(second.id);

    expect(container.read(projectListProvider).single.id, first.id);
    expect(container.read(projectListProvider).single.isActive, isTrue);
  });

  test('reloadFromDatabase replaces stale in-memory project state', () async {
    final notifier = container.read(projectListProvider.notifier);
    notifier.addProject(
      name: 'Stale',
      type: 'Web app',
      gitUrl: '',
      primaryDomain: 'stale.example.com',
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final stale = (await repository.listProjects()).single;
    await repository.deleteProjectAndRelatedRecords(stale.id);
    await repository.createProject(
      const Project(
        id: 'fresh',
        name: 'Fresh',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'fresh.example.com',
        isActive: true,
      ),
    );

    await notifier.reloadFromDatabase();

    expect(container.read(projectListProvider).single.id, 'fresh');
  });

  test('load failures leave the project list empty', () async {
    repository.listProjectsError = StateError('list failed');

    container.read(projectListProvider);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(container.read(projectListProvider), isEmpty);
  });

  test('an unreadable local database leaves the project list empty', () async {
    // The other half of the same guard. A closed repository throws
    // StateError; a database that cannot be read throws SqliteException, and
    // that branch had never been executed -- which for a local-first app is
    // the likelier of the two, since it is what a corrupt or locked file
    // produces.
    repository.listProjectsError = sqlite.SqliteException(
      extendedResultCode: 11,
      message: 'database disk image is malformed',
    );

    container.read(projectListProvider);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(container.read(projectListProvider), isEmpty);
  });

  test(
    'active project load failures leave the selected id unchanged',
    () async {
      repository.throwOnReadActiveProjectId = true;

      expect(container.read(selectedProjectIdProvider), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(container.read(selectedProjectIdProvider), isEmpty);
    },
  );

  test(
    'selected project falls back to the first loaded project when none are active',
    () async {
      await repository.createProject(
        const Project(
          id: 'project-b',
          name: 'B',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'b.example.com',
          isActive: false,
        ),
      );
      await repository.createProject(
        const Project(
          id: 'project-a',
          name: 'A',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'a.example.com',
          isActive: false,
        ),
      );

      container.read(projectListProvider);
      await _waitForProjectLoad(container);

      expect(container.read(selectedProjectIdProvider), isEmpty);
      expect(container.read(selectedProjectProvider)?.id, 'project-a');
    },
  );

  test('selected project only falls back within the selected server', () async {
    final scopedRepository = _FakeProjectRepository();
    await scopedRepository.createProject(
      const Project(
        id: 'project-a',
        serverId: 'server-a',
        name: 'A',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'a.example.com',
        isActive: true,
      ),
    );
    await scopedRepository.createProject(
      const Project(
        id: 'project-b',
        serverId: 'server-b',
        name: 'B',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'b.example.com',
        isActive: true,
      ),
    );
    final scopedContainer = ProviderContainer(
      overrides: [
        projectRepositoryProvider.overrideWithValue(scopedRepository),
        selectedServerIdProvider.overrideWithValue('server-b'),
      ],
    );
    addTearDown(scopedContainer.dispose);

    scopedContainer.read(projectListProvider);
    await _waitForProjectLoad(scopedContainer);
    scopedContainer
        .read(selectedProjectIdProvider.notifier)
        .select('project-a');

    expect(scopedContainer.read(selectedProjectProvider)?.id, 'project-b');
  });

  test('adding a project preserves active projects on other servers', () async {
    final notifier = container.read(projectListProvider.notifier);
    final first = notifier.addProject(
      serverId: 'server-a',
      name: 'First',
      type: 'Web app',
      gitUrl: '',
      primaryDomain: 'first.example.com',
    );

    final second = notifier.addProject(
      serverId: 'server-b',
      name: 'Second',
      type: 'Web app',
      gitUrl: '',
      primaryDomain: 'second.example.com',
    );

    final projects = container.read(projectListProvider);
    expect(
      projects.singleWhere((project) => project.id == first.id).isActive,
      isTrue,
    );
    expect(
      projects.singleWhere((project) => project.id == second.id).isActive,
      isTrue,
    );
  });

  test('project lifecycle refreshes the project count bucket', () {
    final notifier = container.read(projectListProvider.notifier);
    Project add(String name, String domain) => notifier.addProject(
      name: name,
      type: 'Web app',
      gitUrl: '',
      primaryDomain: domain,
    );

    add('First', 'first.example.com');
    add('Second', 'second.example.com');
    add('Third', 'third.example.com');

    expect(analytics.userAttributes, [
      (attribute: AppUserAttribute.projectCountBucket, value: '1'),
      (attribute: AppUserAttribute.projectCountBucket, value: '2'),
      (attribute: AppUserAttribute.projectCountBucket, value: '3plus'),
    ]);
  });

  test('project removal paths move the bucket down', () async {
    final notifier = container.read(projectListProvider.notifier);
    final first = notifier.addProject(
      name: 'First',
      type: 'Web app',
      gitUrl: '',
      primaryDomain: 'first.example.com',
    );
    final second = notifier.addProject(
      name: 'Second',
      type: 'Web app',
      gitUrl: '',
      primaryDomain: 'second.example.com',
    );
    final third = notifier.addProject(
      name: 'Third',
      type: 'Web app',
      gitUrl: '',
      primaryDomain: 'third.example.com',
    );

    await notifier.deleteProject(second.id);
    notifier.hidePendingProject(third.id);

    expect(analytics.userAttributes.map((entry) => entry.value), [
      '1',
      '2',
      '3plus',
      '2',
      '1',
    ]);
    expect(analytics.userAttributes.map((entry) => entry.attribute).toSet(), {
      AppUserAttribute.projectCountBucket,
    });
    expect(container.read(projectListProvider).single.id, first.id);
  });

  test('project failures leave the project count bucket alone', () async {
    final notifier = container.read(projectListProvider.notifier);

    // Blank ids never reach the repository: nothing changed, nothing reported.
    expect(await notifier.deleteProject('   '), isNull);
    notifier.hidePendingProject('   ');

    repository.throwOnDelete = StateError('delete failed');
    final project = notifier.addProject(
      name: 'First',
      type: 'Web app',
      gitUrl: '',
      primaryDomain: 'first.example.com',
    );
    await expectLater(
      () => notifier.deleteProject(project.id),
      throwsA(isA<StateError>()),
    );

    // Only the successful add moved the bucket.
    expect(analytics.userAttributes, [
      (attribute: AppUserAttribute.projectCountBucket, value: '1'),
    ]);
  });
}

class _FakeProjectRepository implements ProjectRepository {
  final Map<String, Project> _recordsById = {};

  /// What `listProjects` throws, or null to answer normally.
  ///
  /// An Object rather than a bool because the provider handles
  /// `SqliteException` and `StateError` in separate branches, and a test that
  /// can only produce one of them leaves the other unexecuted.
  Object? listProjectsError;
  bool throwOnReadActiveProjectId = false;
  Object? throwOnDelete;
  Duration deleteDelay = Duration.zero;
  String? deleteResultOverride;

  @override
  Future<void> createProject(Project project) async {
    if (project.isActive) {
      for (final entry in _recordsById.entries) {
        final sameServer =
            entry.value.serverId == project.serverId ||
            project.serverId == null;
        _recordsById[entry.key] = _copyRecord(
          entry.value,
          isActive: sameServer ? false : entry.value.isActive,
        );
      }
    }
    _recordsById[project.id] = _copyRecord(
      project,
      repositoryFullName: _trimOrNull(project.repositoryFullName),
      appSubdirectory: _normalizedAppSubdirectory(project.appSubdirectory),
      deployBranch: _normalizedBranch(project.deployBranch),
      appPort: _normalizedPort(project.appPort),
      railpackNodeMode: _normalizedRailpackNodeMode(project.railpackNodeMode),
      railpackBuildCommand: _normalizedCommand(project.railpackBuildCommand),
      railpackRunCommand: _normalizedCommand(project.railpackRunCommand),
      railpackProvider: normalizeRailpackProvider(project.railpackProvider),
      tlsChallengeMode: _normalizedTlsChallengeMode(project.tlsChallengeMode),
      tlsDnsProvider: _normalizedTlsDnsProvider(project.tlsDnsProvider),
      tlsDnsCredentials: _normalizedTlsDnsCredentials(
        project.tlsDnsCredentials,
      ),
    );
  }

  @override
  Future<List<Project>> listProjects({
    String? serverId,
    bool includePendingDeletion = false,
  }) async {
    if (listProjectsError != null) {
      throw listProjectsError!;
    }
    final normalizedServerId = _trimOrNull(serverId);
    final records = _recordsById.values
        .where(
          (record) =>
              normalizedServerId == null ||
              record.serverId == normalizedServerId,
        )
        .toList(growable: false);
    records.sort((left, right) => left.name.compareTo(right.name));
    return records;
  }

  @override
  Future<Project?> readProject(
    String projectId, {
    bool includePendingDeletion = false,
  }) async {
    return _recordsById[projectId.trim()];
  }

  @override
  Future<String?> readActiveProjectId({String? serverId}) async {
    if (throwOnReadActiveProjectId) {
      throw StateError('read active failed');
    }
    final normalizedServerId = _trimOrNull(serverId);
    for (final record in _recordsById.values) {
      if (record.isActive &&
          (normalizedServerId == null ||
              record.serverId == normalizedServerId)) {
        return record.id;
      }
    }
    return null;
  }

  @override
  Future<void> setActiveProject(String projectId) async {
    final target = _recordsById[projectId];
    if (target == null) {
      return;
    }
    for (final entry in _recordsById.entries) {
      final sameServer =
          target.serverId == null || entry.value.serverId == target.serverId;
      _recordsById[entry.key] = _copyRecord(
        entry.value,
        isActive: sameServer ? entry.key == projectId : entry.value.isActive,
      );
    }
  }

  @override
  Future<void> updateDeploymentConfig({
    required String projectId,
    required String primaryDomain,
    required String domainRoutingMode,
    required String repositoryFullName,
    required String? appSubdirectory,
    required String deployBranch,
    required int appPort,
    bool? publicHealthCheckEnabled,
    String? publicHealthCheckPath,
    required String railpackNodeMode,
    String? railpackProvider,
    required String tlsChallengeMode,
    required String? tlsDnsProvider,
    required Map<String, String> tlsDnsCredentials,
    required bool sqliteStorageEnabled,
    String? sqliteVolumeName,
    String? sqliteMountPath,
    String? sqliteFileName,
    String? railpackBuildCommand,
    String? railpackRunCommand,
  }) async {
    final record = _recordsById[projectId];
    if (record == null) {
      return;
    }
    final normalizedMode = _normalizedTlsChallengeMode(tlsChallengeMode);
    _recordsById[projectId] = _copyRecord(
      record,
      primaryDomain: primaryDomain.trim(),
      domainRoutingMode: domainRoutingMode.trim().toLowerCase(),
      repositoryFullName: repositoryFullName.trim(),
      appSubdirectory: _normalizedAppSubdirectory(appSubdirectory),
      deployBranch: _normalizedBranch(deployBranch),
      appPort: _normalizedPort(appPort),
      publicHealthCheckEnabled:
          publicHealthCheckEnabled ?? record.publicHealthCheckEnabled,
      publicHealthCheckPath:
          publicHealthCheckPath?.trim().startsWith('/') == true
          ? publicHealthCheckPath!.trim()
          : '/',
      railpackNodeMode: _normalizedRailpackNodeMode(railpackNodeMode),
      railpackProvider: normalizeRailpackProvider(railpackProvider),
      railpackBuildCommand: railpackBuildCommand == null
          ? record.railpackBuildCommand
          : _normalizedCommand(railpackBuildCommand),
      railpackRunCommand: railpackRunCommand == null
          ? record.railpackRunCommand
          : _normalizedCommand(railpackRunCommand),
      tlsChallengeMode: normalizedMode,
      tlsDnsProvider: normalizedMode == 'dns'
          ? _normalizedTlsDnsProvider(tlsDnsProvider)
          : null,
      tlsDnsCredentials: normalizedMode == 'dns'
          ? _normalizedTlsDnsCredentials(tlsDnsCredentials)
          : const <String, String>{},
      sqliteStorageEnabled: sqliteStorageEnabled,
      sqliteVolumeName: sqliteStorageEnabled
          ? _normalizedSqliteVolumeName(sqliteVolumeName)
          : null,
      sqliteMountPath: sqliteStorageEnabled
          ? _normalizedSqliteMountPath(sqliteMountPath)
          : null,
      sqliteFileName: sqliteStorageEnabled
          ? _normalizedSqliteFileName(sqliteFileName)
          : null,
    );
  }

  @override
  Future<void> updateLastDeployState({
    required String projectId,
    String? commit,
    required DateTime deployedAt,
  }) async {
    final record = _recordsById[projectId];
    if (record == null) {
      return;
    }
    _recordsById[projectId] = _copyRecord(
      record,
      lastDeployCommit: _trimOrNull(commit),
      lastDeployedAt: deployedAt,
    );
  }

  @override
  Future<void> updateRuntimeState({
    required String projectId,
    bool? appDisconnected,
  }) async {
    final record = _recordsById[projectId];
    if (record == null || appDisconnected == null) {
      return;
    }
    _recordsById[projectId] = _copyRecord(
      record,
      appDisconnected: appDisconnected,
    );
  }

  @override
  Future<void> updateDatabaseWiring({
    required String projectId,
    required bool injectPostgresEnv,
  }) async {
    final record = _recordsById[projectId];
    if (record == null) {
      return;
    }
    _recordsById[projectId] = _copyRecord(
      record,
      injectPostgresEnv: injectPostgresEnv,
    );
  }

  @override
  Future<String?> deleteProjectAndRelatedRecords(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return readActiveProjectId();
    }
    final error = throwOnDelete;
    if (error != null) {
      throw error;
    }
    if (deleteDelay > Duration.zero) {
      await Future<void>.delayed(deleteDelay);
    }
    final deletedServerId = _recordsById[normalizedProjectId]?.serverId;
    _recordsById.remove(normalizedProjectId);

    if (_recordsById.isEmpty) {
      return null;
    }

    String? nextActiveId;
    for (final record in _recordsById.values) {
      if (deletedServerId != null && record.serverId != deletedServerId) {
        continue;
      }
      if (record.isActive) {
        nextActiveId = record.id;
        break;
      }
    }
    nextActiveId ??= _recordsById.values
        .firstWhere(
          (record) =>
              deletedServerId == null || record.serverId == deletedServerId,
          orElse: () => _recordsById.values.first,
        )
        .id;

    for (final entry in _recordsById.entries) {
      final sameServer =
          deletedServerId == null || entry.value.serverId == deletedServerId;
      _recordsById[entry.key] = _copyRecord(
        entry.value,
        isActive: sameServer ? entry.key == nextActiveId : entry.value.isActive,
      );
    }
    return deleteResultOverride ?? nextActiveId;
  }

  static String? _trimOrNull(String? input) {
    if (input == null) {
      return null;
    }
    final trimmed = input.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String _normalizedBranch(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? 'main' : trimmed;
  }

  static int _normalizedPort(int value) {
    if (value < 1 || value > 65535) {
      return 3000;
    }
    return value;
  }

  static String _normalizedRailpackNodeMode(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'runtime') {
      return 'runtime';
    }
    return 'auto';
  }

  static String _normalizedCommand(String value) {
    return value.trim();
  }

  static String? _normalizedAppSubdirectory(String? value) {
    if (value == null) {
      return null;
    }
    final normalized = value
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) {
      return null;
    }
    final segments = normalized.split('/');
    final cleaned = <String>[];
    for (final segment in segments) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') {
        return null;
      }
      cleaned.add(trimmed);
    }
    if (cleaned.isEmpty) {
      return null;
    }
    return cleaned.join('/');
  }

  static String _normalizedTlsChallengeMode(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'dns') {
      return 'dns';
    }
    return 'http';
  }

  static String? _normalizedTlsDnsProvider(String? value) {
    if (value == null) {
      return null;
    }
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  static Map<String, String> _normalizedTlsDnsCredentials(
    Map<String, String> raw,
  ) {
    final normalized = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key.trim().toLowerCase();
      final value = entry.value.trim();
      if (key.isEmpty || value.isEmpty) {
        continue;
      }
      normalized[key] = value;
    }
    return normalized;
  }

  static String? _normalizedSqliteVolumeName(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(trimmed)) {
      return null;
    }
    return trimmed;
  }

  static String? _normalizedSqliteMountPath(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('/')) {
      return null;
    }
    final parts = trimmed.split('/');
    final cleaned = <String>[];
    for (final part in parts) {
      final segment = part.trim();
      if (segment.isEmpty) {
        continue;
      }
      if (segment == '.' || segment == '..') {
        return null;
      }
      cleaned.add(segment);
    }
    if (cleaned.isEmpty) {
      return null;
    }
    return '/${cleaned.join('/')}';
  }

  static String? _normalizedSqliteFileName(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.contains('/')) {
      return null;
    }
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(trimmed)) {
      return null;
    }
    return trimmed;
  }

  static Project _copyRecord(
    Project record, {
    String? name,
    String? serverId,
    String? type,
    String? gitUrl,
    String? primaryDomain,
    String? domainRoutingMode,
    String? repositoryFullName,
    String? appSubdirectory,
    String? deployBranch,
    int? appPort,
    bool? publicHealthCheckEnabled,
    String? publicHealthCheckPath,
    String? lastDeployCommit,
    DateTime? lastDeployedAt,
    String? railpackBuildCommand,
    String? railpackRunCommand,
    String? railpackProvider,
    String? railpackNodeMode,
    String? tlsChallengeMode,
    String? tlsDnsProvider,
    Map<String, String>? tlsDnsCredentials,
    bool? appDisconnected,
    bool? injectPostgresEnv,
    bool? sqliteStorageEnabled,
    String? sqliteVolumeName,
    String? sqliteMountPath,
    String? sqliteFileName,
    bool? isActive,
  }) {
    return Project(
      id: record.id,
      serverId: serverId ?? record.serverId,
      name: name ?? record.name,
      type: type ?? record.type,
      gitUrl: gitUrl ?? record.gitUrl,
      primaryDomain: primaryDomain ?? record.primaryDomain,
      domainRoutingMode: domainRoutingMode ?? record.domainRoutingMode,
      repositoryFullName: repositoryFullName ?? record.repositoryFullName,
      appSubdirectory: appSubdirectory ?? record.appSubdirectory,
      deployBranch: deployBranch ?? record.deployBranch,
      appPort: appPort ?? record.appPort,
      publicHealthCheckEnabled:
          publicHealthCheckEnabled ?? record.publicHealthCheckEnabled,
      publicHealthCheckPath:
          publicHealthCheckPath ?? record.publicHealthCheckPath,
      lastDeployCommit: lastDeployCommit ?? record.lastDeployCommit,
      lastDeployedAt: lastDeployedAt ?? record.lastDeployedAt,
      railpackBuildCommand: railpackBuildCommand ?? record.railpackBuildCommand,
      railpackRunCommand: railpackRunCommand ?? record.railpackRunCommand,
      railpackProvider: railpackProvider ?? record.railpackProvider,
      railpackNodeMode: railpackNodeMode ?? record.railpackNodeMode,
      tlsChallengeMode: tlsChallengeMode ?? record.tlsChallengeMode,
      tlsDnsProvider: tlsDnsProvider ?? record.tlsDnsProvider,
      tlsDnsCredentials: tlsDnsCredentials ?? record.tlsDnsCredentials,
      appDisconnected: appDisconnected ?? record.appDisconnected,
      injectPostgresEnv: injectPostgresEnv ?? record.injectPostgresEnv,
      sqliteStorageEnabled: sqliteStorageEnabled ?? record.sqliteStorageEnabled,
      sqliteVolumeName: sqliteVolumeName ?? record.sqliteVolumeName,
      sqliteMountPath: sqliteMountPath ?? record.sqliteMountPath,
      sqliteFileName: sqliteFileName ?? record.sqliteFileName,
      isActive: isActive ?? record.isActive,
    );
  }
}
