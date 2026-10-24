import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/project_repository.dart';
import 'package:ui/data/local/project_network_trust_repository.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('ProjectNetworkTrustRepository', () {
    late AppDatabase database;
    late ProjectRepository projectRepository;
    late ProjectNetworkTrustRepository repository;

    setUp(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      projectRepository = ProjectRepository(database);
      repository = ProjectNetworkTrustRepository(database);
      await projectRepository.createProject(
        const Project(
          id: 'project-alpha',
          serverId: 'server-1',
          name: 'Alpha',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'alpha.example.com',
        ),
      );
      await projectRepository.createProject(
        const Project(
          id: 'project-beta',
          serverId: 'server-1',
          name: 'Beta',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'beta.example.com',
        ),
      );
    });

    tearDown(() async {
      await database.close();
    });

    test('links projects into deterministic trust network', () async {
      final group = await repository.linkProjects(
        serverId: 'server-1',
        projectIds: const ['project-beta', 'project-alpha'],
      );

      expect(group.memberProjectIds, ['project-alpha', 'project-beta']);
      expect(group.networkName, startsWith('deploydash_trust_trust-server-1'));
      expect(
        await repository.listTrustNetworkNamesForProject('project-alpha'),
        [group.networkName],
      );
      expect(await repository.listTrustNetworkNamesForProject('project-beta'), [
        group.networkName,
      ]);
    }, skip: !sqliteAvailable);

    test('project deletion removes empty trust groups', () async {
      final group = await repository.linkProjects(
        serverId: 'server-1',
        projectIds: const ['project-alpha', 'project-beta'],
      );

      await projectRepository.deleteProjectAndRelatedRecords('project-beta');

      expect(
        await repository.listTrustNetworkNamesForProject('project-alpha'),
        isEmpty,
      );
      final rows = await database
          .customSelect(
            'SELECT id FROM project_network_groups WHERE id = ?',
            variables: [Variable<String>(group.id)],
            readsFrom: {database.projectNetworkGroups},
          )
          .get();
      expect(rows, isEmpty);
    }, skip: !sqliteAvailable);

    test(
      'reports the linked-projects message when a link spans servers',
      () async {
        await projectRepository.createProject(
          const Project(
            id: 'project-other',
            serverId: 'server-2',
            name: 'Other',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'other.example.com',
          ),
        );

        await expectLater(
          repository.linkProjects(
            serverId: 'server-1',
            projectIds: const ['project-alpha', 'project-other'],
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Linked projects must be on the same server.',
            ),
          ),
        );
      },
      skip: !sqliteAvailable,
    );

    test('re-linking preserves the trust group creation time', () async {
      final first = await repository.linkProjects(
        serverId: 'server-1',
        projectIds: const ['project-alpha', 'project-beta'],
      );
      // Drift stores timestamps at second precision: without a gap crossing a
      // second boundary, a re-stamp would be indistinguishable from a preserve.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final second = await repository.linkProjects(
        serverId: 'server-1',
        projectIds: const ['project-alpha', 'project-beta'],
      );

      // The link path preserves createdAt; the grant path re-stamps it.
      // Both are pinned so the D-17 collapse cannot silently unify them.
      expect(second.createdAt, first.createdAt);
    }, skip: !sqliteAvailable);

    test('names the group from the caller or the default', () async {
      final defaultNamed = await repository.linkProjects(
        serverId: 'server-1',
        projectIds: const ['project-alpha', 'project-beta'],
      );
      expect(defaultNamed.displayName, 'Linked projects');

      final callerNamed = await repository.linkProjects(
        serverId: 'server-1',
        projectIds: const ['project-alpha', 'project-beta'],
        displayName: 'Backend pair',
      );
      expect(callerNamed.displayName, 'Backend pair');
    }, skip: !sqliteAvailable);
  });

  group('trust group helpers (D-17)', () {
    test('trims an id or throws the required-field error', () {
      expect(requireNonEmptyId('  project-1  ', 'projectId'), 'project-1');

      expect(
        () => requireNonEmptyId('   ', 'projectId'),
        throwsA(
          isA<ArgumentError>()
              .having((error) => error.name, 'name', 'projectId')
              .having((error) => error.message, 'message', 'Value is required.')
              .having((error) => error.invalidValue, 'invalidValue', '   '),
        ),
      );
    });

    test('joins server and members into a trust group id', () {
      expect(
        trustGroupIdFor(
          serverId: 'server-1',
          projectIds: const ['project-alpha', 'project-beta'],
        ),
        'trust-server-1-project-alpha-project-beta',
      );
    });

    test('scrubs tokens to lowercase docker-safe text', () {
      expect(dockerSafeToken('  API Gateway!! '), 'api-gateway');
      expect(dockerSafeToken('---'), 'group');
      expect(dockerSafeToken('   '), 'group');
      expect(dockerSafeToken('!!!', emptyFallback: 'sqlite'), 'sqlite');
    });

    test('caps tokens at the caller bound', () {
      const longId =
          'trust-server-1-project-alpha-project-beta-project-gamma-extra';
      expect(longId.length, greaterThan(48));
      expect(
        dockerSafeToken(longId),
        'trust-server-1-project-alpha-project-beta-projec',
      );
      expect(dockerSafeToken(longId).length, 48);
      expect(dockerSafeToken('abcdef', maxLength: 4), 'abcd');
    });
  });
}
