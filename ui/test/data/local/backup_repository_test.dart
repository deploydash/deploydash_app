import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/backup_repository.dart';

import '../../_support/sqlite_test_harness.dart';
import '../../../integration_test/support/e2e_checklist.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('BackupRepository scope lists (D-14)', () {
    late AppDatabase database;
    late BackupRepository repository;

    setUp(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = BackupRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    Future<List<BackupDestinationRecord>> destinations() {
      return repository.listDestinationsForScope(
        projectId: 'project-1',
        serverId: 'server-1',
      );
    }

    test('empty scopes list nothing', () async {
      await repository.upsertDestination(
        const BackupDestinationRecord(
          id: 'dest-1',
          projectId: 'project-1',
          serverId: 'server-1',
          name: 'Primary',
          type: BackupDestinationType.s3,
          config: <String, dynamic>{'bucket': 'backups'},
        ),
      );

      for (final projectId in ['   ', 'project-1']) {
        for (final serverId in ['   ', 'server-1']) {
          if (projectId != '   ' && serverId != '   ') {
            continue;
          }
          expect(
            await repository.listDestinationsForScope(
              projectId: projectId,
              serverId: serverId,
            ),
            isEmpty,
          );
          expect(
            await repository.listPoliciesForScope(
              projectId: projectId,
              serverId: serverId,
            ),
            isEmpty,
          );
          expect(
            await repository.listArtifactsForScope(
              projectId: projectId,
              serverId: serverId,
            ),
            isEmpty,
          );
          expect(
            await repository.listRunsForScope(
              projectId: projectId,
              serverId: serverId,
            ),
            isEmpty,
          );
        }
      }
      expect(await destinations(), hasLength(1));
    }, skip: !sqliteAvailable);

    test('destinations list by name', () async {
      for (final (id, name) in [('dest-b', 'Beta'), ('dest-a', 'Alpha')]) {
        await repository.upsertDestination(
          BackupDestinationRecord(
            id: id,
            projectId: 'project-1',
            serverId: 'server-1',
            name: name,
            type: BackupDestinationType.s3,
            config: const <String, dynamic>{'bucket': 'backups'},
          ),
        );
      }

      final listed = await destinations();
      expect(listed.map((destination) => destination.name), ['Alpha', 'Beta']);
    }, skip: !sqliteAvailable);

    test('policies merge and sort by name', () async {
      for (final (id, name) in [
        ('policy-beta', 'beta'),
        ('policy-alpha-1', 'alpha'),
        ('policy-alpha-2', 'alpha'),
      ]) {
        await repository.upsertPolicy(
          BackupPolicyRecord(
            id: id,
            projectId: 'project-1',
            serverId: 'server-1',
            name: name,
            destinationId: 'dest-1',
            databaseName: 'owner_db',
            scheduleMode: 'daily_once',
            time1Hhmm: '02:00',
            managedTaskId: 'task-$id',
          ),
        );
      }

      final listed = await repository.listPoliciesForScope(
        projectId: 'project-1',
        serverId: 'server-1',
      );
      expect(listed.map((policy) => policy.name), ['alpha', 'alpha', 'beta']);
    }, skip: !sqliteAvailable);

    test('artifacts filter by engine and policy', () async {
      BackupArtifactRecord artifact(String id, String policyId, int day) {
        return BackupArtifactRecord(
          id: id,
          policyId: policyId,
          projectId: 'project-1',
          serverId: 'server-1',
          destinationId: 'dest-1',
          databaseName: 'owner_db',
          remotePath: 'backups/$id.dump',
          createdAtRemote: DateTime.utc(2026, 5, day),
        );
      }

      // One replace per policy: a replace swaps that policy's whole set.
      await repository.replaceArtifactsForPolicy(
        policyId: 'policy-1',
        projectId: 'project-1',
        serverId: 'server-1',
        artifacts: [
          artifact('artifact-1', 'policy-1', 3),
          artifact('artifact-2', 'policy-1', 2),
        ],
      );
      await repository.replaceArtifactsForPolicy(
        policyId: 'policy-2',
        projectId: 'project-1',
        serverId: 'server-1',
        artifacts: [artifact('artifact-3', 'policy-2', 1)],
      );

      Future<List<String>> idsWith({String? policyId, bool useEngine = true}) {
        return repository
            .listArtifactsForScope(
              projectId: 'project-1',
              serverId: 'server-1',
              engine: useEngine ? BackupEngine.postgres : null,
              policyId: policyId,
            )
            .then((rows) => rows.map((row) => row.id).toList());
      }

      // Newest first by remote creation time.
      expect(await idsWith(), ['artifact-1', 'artifact-2', 'artifact-3']);
      expect(await idsWith(useEngine: false), [
        'artifact-1',
        'artifact-2',
        'artifact-3',
      ]);
      expect(await idsWith(policyId: 'policy-1'), ['artifact-1', 'artifact-2']);
      // A blank policy id means unfiltered, not equals('').
      expect(await idsWith(policyId: '   '), [
        'artifact-1',
        'artifact-2',
        'artifact-3',
      ]);
    }, skip: !sqliteAvailable);

    test('runs clamp the limit and filter by engine', () async {
      for (var day = 1; day <= 1005; day++) {
        await repository.appendRun(
          BackupRunRecord(
            projectId: 'project-1',
            serverId: 'server-1',
            policyId: 'policy-1',
            operationType: BackupOperationType.backup,
            status: 'success',
            startedAt: DateTime.utc(2026, 1, 1).add(Duration(days: day)),
          ),
        );
      }

      Future<int> countWith({int limit = 200, bool useEngine = true}) {
        return repository
            .listRunsForScope(
              projectId: 'project-1',
              serverId: 'server-1',
              engine: useEngine ? BackupEngine.postgres : null,
              limit: limit,
            )
            .then((rows) => rows.length);
      }

      // Behavior only: T-051 owns the clamp expression itself.
      expect(await countWith(limit: 0), 1);
      expect(await countWith(), 200);
      expect(await countWith(limit: 2001), 1000);
      expect(await countWith(limit: 2001, useEngine: false), 1000);
    }, skip: !sqliteAvailable);

    test('deletes ignore single-blank ids', () async {
      await repository.upsertDestination(
        const BackupDestinationRecord(
          id: 'dest-1',
          projectId: 'project-1',
          serverId: 'server-1',
          name: 'Primary',
          type: BackupDestinationType.s3,
          config: <String, dynamic>{'bucket': 'backups'},
        ),
      );
      await repository.upsertPolicy(
        BackupPolicyRecord(
          id: 'policy-1',
          projectId: 'project-1',
          serverId: 'server-1',
          name: 'Daily',
          destinationId: 'dest-1',
          databaseName: 'owner_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'task-policy-1',
        ),
      );

      const blank = '   ';
      await repository.deleteDestination(
        id: blank,
        projectId: 'project-1',
        serverId: 'server-1',
      );
      await repository.deleteDestination(
        id: 'dest-1',
        projectId: blank,
        serverId: 'server-1',
      );
      await repository.deleteDestination(
        id: 'dest-1',
        projectId: 'project-1',
        serverId: blank,
      );
      await repository.deletePolicy(
        id: blank,
        projectId: 'project-1',
        serverId: 'server-1',
      );
      await repository.deletePolicy(
        id: 'policy-1',
        projectId: blank,
        serverId: 'server-1',
      );
      await repository.deletePolicy(
        id: 'policy-1',
        projectId: 'project-1',
        serverId: blank,
      );
      await repository.replaceArtifactsForPolicy(
        policyId: blank,
        projectId: 'project-1',
        serverId: 'server-1',
        artifacts: const [],
      );
      await repository.replaceArtifactsForPolicy(
        policyId: 'policy-1',
        projectId: blank,
        serverId: 'server-1',
        artifacts: const [],
      );
      await repository.replaceArtifactsForPolicy(
        policyId: 'policy-1',
        projectId: 'project-1',
        serverId: blank,
        artifacts: const [],
      );
      await repository.updatePolicyRuntime(
        policyId: blank,
        projectId: 'project-1',
        serverId: 'server-1',
      );
      await repository.updatePolicyRuntime(
        policyId: 'policy-1',
        projectId: blank,
        serverId: 'server-1',
      );
      await repository.updatePolicyRuntime(
        policyId: 'policy-1',
        projectId: 'project-1',
        serverId: blank,
      );

      expect(await destinations(), hasLength(1));
      expect(
        await repository.listPoliciesForScope(
          projectId: 'project-1',
          serverId: 'server-1',
        ),
        hasLength(1),
      );
    }, skip: !sqliteAvailable);

    test('policy runtime updates observations and enabled', () async {
      await repository.upsertPolicy(
        BackupPolicyRecord(
          id: 'policy-1',
          projectId: 'project-1',
          serverId: 'server-1',
          name: 'Daily',
          destinationId: 'dest-1',
          databaseName: 'owner_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'task-policy-1',
        ),
      );

      await repository.updatePolicyRuntime(
        policyId: 'policy-1',
        projectId: 'project-1',
        serverId: 'server-1',
        lastRunAt: DateTime.utc(2026, 5, 4, 2),
        lastStatus: '  success  ',
        lastMessage: '  ok  ',
        enabled: false,
      );

      final stored = (await repository.listPoliciesForScope(
        projectId: 'project-1',
        serverId: 'server-1',
      )).single;
      expect(stored.lastStatus, 'success');
      expect(stored.lastMessage, 'ok');
      expect(stored.enabled, isFalse);

      await repository.updatePolicyRuntime(
        policyId: 'policy-1',
        projectId: 'project-1',
        serverId: 'server-1',
        lastStatus: 'failed',
      );
      final kept = (await repository.listPoliciesForScope(
        projectId: 'project-1',
        serverId: 'server-1',
      )).single;
      expect(kept.lastStatus, 'failed');
      expect(kept.enabled, isFalse);
    }, skip: !sqliteAvailable);

    test('server cleanup removes plans but keeps destinations', () async {
      await repository.upsertDestination(
        const BackupDestinationRecord(
          id: 'dest-1',
          projectId: 'project-1',
          serverId: 'server-1',
          name: 'Primary',
          type: BackupDestinationType.s3,
          config: <String, dynamic>{'bucket': 'backups'},
        ),
      );
      for (final serverId in ['server-1', 'server-2']) {
        await repository.upsertPolicy(
          BackupPolicyRecord(
            id: 'policy-$serverId',
            projectId: 'project-1',
            serverId: serverId,
            name: 'Daily',
            destinationId: 'dest-1',
            databaseName: 'owner_db',
            scheduleMode: 'daily_once',
            time1Hhmm: '02:00',
            managedTaskId: 'task-$serverId',
          ),
        );
      }
      await repository.appendRun(
        BackupRunRecord(
          projectId: 'project-1',
          serverId: 'server-1',
          policyId: 'policy-server-1',
          operationType: BackupOperationType.backup,
          status: 'success',
        ),
      );

      await repository.deletePoliciesForServer('   ');
      expect(
        await repository.listPoliciesForScope(
          projectId: 'project-1',
          serverId: 'server-1',
        ),
        hasLength(1),
      );

      await repository.deletePoliciesForServer('server-1');
      expect(
        await repository.listPoliciesForScope(
          projectId: 'project-1',
          serverId: 'server-1',
        ),
        isEmpty,
      );
      expect(
        await repository.listRunsForScope(
          projectId: 'project-1',
          serverId: 'server-1',
        ),
        isEmpty,
      );
      expect(
        await repository.listPoliciesForScope(
          projectId: 'project-1',
          serverId: 'server-2',
        ),
        hasLength(1),
      );
      expect(await destinations(), hasLength(1));
    }, skip: !sqliteAvailable);

    test('runs without a scope are dropped', () async {
      BackupRunRecord runWith({String projectId = 'project-1'}) {
        return BackupRunRecord(
          projectId: projectId,
          serverId: 'server-1',
          policyId: 'policy-1',
          operationType: BackupOperationType.backup,
          status: 'success',
        );
      }

      await repository.appendRun(runWith(projectId: '   '));
      await repository.appendRun(
        BackupRunRecord(
          projectId: 'project-1',
          serverId: '   ',
          policyId: 'policy-1',
          operationType: BackupOperationType.backup,
          status: 'success',
        ),
      );
      expect(
        await repository.listRunsForScope(
          projectId: 'project-1',
          serverId: 'server-1',
        ),
        isEmpty,
      );

      await repository.appendRun(runWith());
      expect(
        await repository.listRunsForScope(
          projectId: 'project-1',
          serverId: 'server-1',
        ),
        hasLength(1),
      );
    }, skip: !sqliteAvailable);

    test('destinations drop blank config keys', () async {
      await repository.upsertDestination(
        const BackupDestinationRecord(
          id: 'dest-1',
          projectId: 'project-1',
          serverId: 'server-1',
          name: 'Primary',
          type: BackupDestinationType.s3,
          config: <String, dynamic>{'': 'stray', 'bucket': 'backups'},
        ),
      );

      final stored = (await destinations()).single;
      expect(stored.config, {'bucket': 'backups'});
    }, skip: !sqliteAvailable);

    test('policies normalize schedules and fall back on bad times', () async {
      Future<BackupPolicyRecord> stored(String id) {
        return repository
            .listPoliciesForScope(projectId: 'project-1', serverId: 'server-1')
            .then((rows) => rows.singleWhere((row) => row.id == id));
      }

      Future<void> savePolicy({
        required String id,
        required String scheduleMode,
        required String time1Hhmm,
        String? time2Hhmm,
      }) {
        return repository.upsertPolicy(
          BackupPolicyRecord(
            id: id,
            projectId: 'project-1',
            serverId: 'server-1',
            name: id,
            destinationId: 'dest-1',
            databaseName: 'owner_db',
            scheduleMode: scheduleMode,
            time1Hhmm: time1Hhmm,
            time2Hhmm: time2Hhmm,
            managedTaskId: 'task-$id',
          ),
        );
      }

      await savePolicy(
        id: 'twice',
        scheduleMode: 'daily_twice',
        time1Hhmm: '2:30',
        time2Hhmm: '15:05',
      );
      await savePolicy(
        id: 'twice-defaults',
        scheduleMode: 'daily_twice',
        time1Hhmm: 'nope',
      );
      await savePolicy(
        id: 'bad-hour',
        scheduleMode: 'daily_once',
        time1Hhmm: '25:00',
      );
      await savePolicy(
        id: 'bad-minute',
        scheduleMode: 'daily_once',
        time1Hhmm: '02:99',
      );

      expect((await stored('twice')).time1Hhmm, '02:30');
      expect((await stored('twice')).time2Hhmm, '15:05');
      expect((await stored('twice-defaults')).time1Hhmm, '02:00');
      expect((await stored('twice-defaults')).time2Hhmm, '14:00');
      expect((await stored('bad-hour')).time1Hhmm, '02:00');
      expect((await stored('bad-minute')).time1Hhmm, '02:00');
    }, skip: !sqliteAvailable);

    test('destination configs tolerate stored non-map json', () async {
      // D-58 contract: blank, non-map, and malformed configJson all read
      // back as an empty map rather than throwing. Written directly: the
      // upsert path always encodes a map, so only legacy rows read this way.
      for (final (id, configJson) in [
        ('dest-blank', ''),
        ('dest-list', '[1, 2]'),
        ('dest-broken', '{"bucket": oops}'),
      ]) {
        await database
            .into(database.backupDestinations)
            .insert(
              BackupDestinationsCompanion.insert(
                id: id,
                projectId: 'project-1',
                serverId: 'server-1',
                name: id,
                type: 's3',
                configJson: configJson,
              ),
            );
      }

      final listed = await destinations();
      expect(listed, hasLength(3));
      for (final destination in listed) {
        expect(destination.config, isEmpty);
      }
    }, skip: !sqliteAvailable);
  });

  group('BackupRepository collapsed scope owner (D-14)', () {
    test('scope lists route through one guard owner', () {
      // Guard-style: one helper definition + four delegate call sites. The
      // four inline trim-guards collapse here, so the empty-scope contract
      // cannot drift apart per list.
      final root = findRepositoryRoot();
      final source = File(
        '${root.path}/ui/lib/data/local/backup_repository.dart',
      ).readAsStringSync();
      expect('_listForScope'.allMatches(source).length, 5);
    });
  });
}
