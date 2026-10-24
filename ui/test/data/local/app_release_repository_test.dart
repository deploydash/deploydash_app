import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_release_repository.dart';

import '../../_support/sqlite_test_harness.dart';

/// Proves the operation journal is a sanitized recovery boundary.
void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  test(
    'journal sanitizes requests and results even for legacy opt-out callers',
    () async {
      const canary = 'DD_TEST_SECRET_DO_NOT_LOG_7f4c';
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = AppReleaseRepository(database);

      final journal = await repository.createJournalEntry(
        projectId: 'project-1',
        serverId: 'server-1',
        surface: 'app',
        operationType: 'run',
        request: <String, dynamic>{
          'runtime_env': <String, dynamic>{'FEATURE_FLAG': canary},
          'message': 'Authorization: Bearer $canary',
        },
      );
      await repository.updateJournalStatus(
        id: journal.id,
        status: 'remote_success',
        result: <String, dynamic>{
          'status': 'success',
          'runtime_env': <String, dynamic>{'FEATURE_FLAG': canary},
          'details':
              '-----BEGIN PRIVATE KEY-----\n$canary\n-----END PRIVATE KEY-----',
          'commit_sha': 'abcdef1234567890',
        },
        sanitizeResult: false,
      );

      final stored = (await repository.listRemoteSuccessJournal()).single;
      final request = jsonDecode(stored.requestJson!) as Map<String, dynamic>;
      final result = jsonDecode(stored.resultJson!) as Map<String, dynamic>;
      expect(request.toString(), isNot(contains(canary)));
      expect(result.toString(), isNot(contains(canary)));
      expect(result['details'], isNot(contains('BEGIN PRIVATE KEY')));
      expect(result['status'], 'success');
      expect(result['commit_sha'], 'abcdef1234567890');
    },
    skip: !sqliteAvailable,
  );

  test(
    'latest failed deploy lookup is exact and a newer success suppresses it',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = AppReleaseRepository(database);

      final ignored = await repository.createJournalEntry(
        projectId: 'project-1',
        serverId: 'server-1',
        surface: 'database',
        operationType: 'run',
      );
      await repository.updateJournalStatus(
        id: ignored.id,
        status: 'failed',
        result: <String, dynamic>{'status': 'error', 'msg': 'wrong surface'},
      );
      final failed = await repository.createJournalEntry(
        projectId: 'project-1',
        serverId: 'server-1',
        surface: 'app',
        operationType: 'run',
      );
      await repository.updateJournalStatus(
        id: failed.id,
        status: 'failed',
        result: <String, dynamic>{'status': 'error', 'msg': 'deploy failed'},
      );

      expect(
        (await repository.readLatestFailedJournalForOperation(
          projectId: ' project-1 ',
          serverId: ' server-1 ',
          surface: ' app ',
          operationType: ' run ',
        ))?.id,
        failed.id,
      );
      expect(
        await repository.readLatestFailedJournalForOperation(
          projectId: 'project-2',
          serverId: 'server-1',
          surface: 'app',
          operationType: 'run',
        ),
        isNull,
      );
      expect(
        await repository.readLatestFailedJournalForOperation(
          projectId: 'project-1',
          serverId: 'server-1',
          surface: 'app',
          operationType: 'rollback',
        ),
        isNull,
      );
      expect(
        await repository.readLatestFailedJournalForOperation(
          projectId: ' ',
          serverId: 'server-1',
          surface: 'app',
          operationType: 'run',
        ),
        isNull,
      );

      await Future<void>.delayed(const Duration(milliseconds: 1));
      final succeeded = await repository.createJournalEntry(
        projectId: 'project-1',
        serverId: 'server-1',
        surface: 'app',
        operationType: 'run',
      );
      await repository.updateJournalStatus(
        id: succeeded.id,
        status: 'committed_local',
        result: <String, dynamic>{'status': 'success'},
      );

      expect(
        await repository.readLatestFailedJournalForOperation(
          projectId: 'project-1',
          serverId: 'server-1',
          surface: 'app',
          operationType: 'run',
        ),
        isNull,
      );
      expect(database.schemaVersion, appDatabaseSchemaVersion);
      expect(appDatabaseSchemaVersion, 2);
    },
    skip: !sqliteAvailable,
  );

  test(
    'snapshots read back what was written, scoped by project and server',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = AppReleaseRepository(database);
      final updatedAt = DateTime.utc(2026, 5, 1, 12);

      await repository.upsertRuntimeSnapshot(
        AppRuntimeSnapshotRecord(
          projectId: 'project-1',
          serverId: 'server-1',
          healthStatus: 'healthy',
          updatedAt: updatedAt,
        ),
      );
      await repository.upsertRuntimeSnapshot(
        AppRuntimeSnapshotRecord(
          projectId: 'project-1',
          serverId: 'server-2',
          healthStatus: 'degraded',
          updatedAt: updatedAt,
        ),
      );

      final first = await repository.readRuntimeSnapshot(
        projectId: 'project-1',
        serverId: 'server-1',
      );
      final second = await repository.readRuntimeSnapshot(
        projectId: 'project-1',
        serverId: 'server-2',
      );
      expect(first?.healthStatus, 'healthy');
      expect(second?.healthStatus, 'degraded');
      expect(
        await repository.readRuntimeSnapshot(
          projectId: 'project-1',
          serverId: 'server-9',
        ),
        isNull,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'snapshot readers return null for blank scopes and missing rows',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = AppReleaseRepository(database);

      expect(
        await repository.readRuntimeSnapshot(
          projectId: '   ',
          serverId: 'server-1',
        ),
        isNull,
      );
      expect(
        await repository.readWorkerRuntimeSnapshot(
          projectId: 'project-1',
          serverId: '   ',
        ),
        isNull,
      );
      expect(
        await repository.readImportState(
          projectId: 'project-1',
          serverId: 'server-1',
        ),
        isNull,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'runtime writer trims json while the worker writer stores raw',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = AppReleaseRepository(database);
      final updatedAt = DateTime.utc(2026, 5, 1, 12);

      await repository.upsertRuntimeSnapshot(
        AppRuntimeSnapshotRecord(
          projectId: 'project-1',
          serverId: 'server-1',
          resourceUsageJson: '  {"cpu": 1}  ',
          updatedAt: updatedAt,
        ),
      );
      await repository.upsertWorkerRuntimeSnapshot(
        WorkerRuntimeSnapshotRecord(
          projectId: 'project-1',
          serverId: 'server-1',
          snapshotJson: '  {"workers": []}  ',
          updatedAt: updatedAt,
        ),
      );

      // The trim-vs-raw split is deliberate: the runtime shape is this file's
      // to normalize, the worker payload belongs to the workers workflow.
      expect(
        (await repository.readRuntimeSnapshot(
          projectId: 'project-1',
          serverId: 'server-1',
        ))?.resourceUsageJson,
        '{"cpu": 1}',
      );
      expect(
        (await repository.readWorkerRuntimeSnapshot(
          projectId: 'project-1',
          serverId: 'server-1',
        ))?.snapshotJson,
        '  {"workers": []}  ',
      );
    },
    skip: !sqliteAvailable,
  );

  test('worker writer drops empty payloads', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = AppReleaseRepository(database);

    await repository.upsertWorkerRuntimeSnapshot(
      WorkerRuntimeSnapshotRecord(
        projectId: 'project-1',
        serverId: 'server-1',
        snapshotJson: '   ',
        updatedAt: DateTime.utc(2026, 5, 1, 12),
      ),
    );

    expect(
      await repository.readWorkerRuntimeSnapshot(
        projectId: 'project-1',
        serverId: 'server-1',
      ),
      isNull,
    );
  }, skip: !sqliteAvailable);

  test('import writer records scalar state with its own timestamp', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = AppReleaseRepository(database);

    await repository.upsertImportState(
      projectId: 'project-1',
      serverId: 'server-1',
      status: ' importing ',
      errorMessage: '  boom  ',
    );
    final after = DateTime.now();

    final state = await repository.readImportState(
      projectId: 'project-1',
      serverId: 'server-1',
    );
    expect(state?.status, 'importing');
    expect(state?.errorMessage, 'boom');
    expect(state?.startedAt, isNull);
    expect(state?.finishedAt, isNull);
    // The scalar writer mints its own timestamp (there is no record param to
    // take one from); storage keeps whole seconds, hence the tolerance.
    expect(after.difference(state!.updatedAt).inSeconds.abs(), lessThan(5));
  }, skip: !sqliteAvailable);

  test('journal lists filter by status and order oldest first', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = AppReleaseRepository(database);

    Future<void> insertJournalRow({
      required String id,
      required String status,
      required DateTime createdAt,
    }) async {
      await database
          .into(database.projectManagedOperationJournal)
          .insert(
            ProjectManagedOperationJournalCompanion.insert(
              id: id,
              projectId: 'project-1',
              serverId: 'server-1',
              surface: 'app',
              operationType: 'run',
              status: status,
              createdAt: Value(createdAt),
              updatedAt: Value(createdAt),
            ),
          );
    }

    // Inserted out of order on purpose: the listing must sort, not echo.
    await insertJournalRow(
      id: 'success-new',
      status: 'remote_success',
      createdAt: DateTime.utc(2021),
    );
    await insertJournalRow(
      id: 'failed-old',
      status: 'failed',
      createdAt: DateTime.utc(2020),
    );
    await insertJournalRow(
      id: 'pending-row',
      status: 'pending_remote',
      createdAt: DateTime.utc(2022),
    );
    await insertJournalRow(
      id: 'failed-new',
      status: 'failed',
      createdAt: DateTime.utc(2023),
    );

    final successes = await repository.listRemoteSuccessJournal();
    expect(successes.map((row) => row.id), ['success-new']);

    final failures = await repository.listFailedJournal();
    expect(failures.map((row) => row.id), ['failed-old', 'failed-new']);
  }, skip: !sqliteAvailable);

  test('journal lists clamp the limit to 1 through 1000', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = AppReleaseRepository(database);

    for (var index = 0; index < 3; index += 1) {
      await database
          .into(database.projectManagedOperationJournal)
          .insert(
            ProjectManagedOperationJournalCompanion.insert(
              id: 'success-$index',
              projectId: 'project-1',
              serverId: 'server-1',
              surface: 'app',
              operationType: 'run',
              status: 'remote_success',
              createdAt: Value(DateTime.utc(2021, 1, index + 1)),
              updatedAt: Value(DateTime.utc(2021, 1, index + 1)),
            ),
          );
    }

    expect(await repository.listRemoteSuccessJournal(limit: 0), hasLength(1));
    expect(await repository.listRemoteSuccessJournal(limit: 2), hasLength(2));
    expect(
      await repository.listRemoteSuccessJournal(limit: 5000),
      hasLength(3),
    );
    expect(await repository.listFailedJournal(limit: 0), isEmpty);
  }, skip: !sqliteAvailable);

  test('journal and release ids scrub unsafe tokens', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = AppReleaseRepository(database);

    final journal = await repository.createJournalEntry(
      projectId: 'project-1',
      serverId: 'server-1',
      surface: 'My App!!',
      operationType: 'run now',
    );
    expect(journal.id, matches(RegExp(r'journal-\d+-my-app-run-now')));

    final blanked = await repository.createJournalEntry(
      projectId: 'project-1',
      serverId: 'server-1',
      surface: '!!!',
      operationType: 'run',
    );
    expect(blanked.id, contains('-item-'));

    final release = AppReleaseRepository.fromBackendRelease(
      projectId: 'P 1',
      serverId: 'S-1',
      payload: const {'release_id': 'R.2'},
    );
    // Dots survive the scrubber (container/db identifiers, not URL slugs).
    expect(release?.id, 'release-s-1-p-1-r.2');
  }, skip: !sqliteAvailable);
}
