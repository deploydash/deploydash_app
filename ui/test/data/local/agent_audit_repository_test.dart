import 'package:ui/data/local/agent_audit_repository.dart';
import 'package:ui/data/local/app_database.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('AgentAuditRepository', () {
    late AppDatabase database;
    late AgentAuditRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = AgentAuditRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('append ignores blank required fields', () async {
      await repository.append(
        toolName: '   ',
        accessLevel: 'read_only',
        status: 'success',
        summary: 'summary',
      );
      await repository.append(
        toolName: 'deploydash_status',
        accessLevel: '   ',
        status: 'success',
        summary: 'summary',
      );
      await repository.append(
        toolName: 'deploydash_status',
        accessLevel: 'read_only',
        status: '   ',
        summary: 'summary',
      );
      await repository.append(
        toolName: 'deploydash_status',
        accessLevel: 'read_only',
        status: 'success',
        summary: '   ',
      );

      expect(await repository.listRecent(), isEmpty);
    }, skip: !sqliteAvailable);

    test('append and listRecent normalize fields and decode details', () async {
      await repository.append(
        toolName: '  deploydash_status  ',
        accessLevel: ' read_only ',
        status: ' SUCCESS ',
        summary: '  fetched status  ',
        details: const <String, dynamic>{'count': 1},
      );
      await repository.append(
        toolName: 'deploydash_list_servers',
        accessLevel: 'read_only',
        status: 'failed',
        summary: 'Listed servers.',
      );

      final rows = await repository.listRecent(limit: 5);
      expect(rows, hasLength(2));
      final statusRow = rows.singleWhere(
        (row) => row.toolName == 'deploydash_status',
      );
      final listRow = rows.singleWhere(
        (row) => row.toolName == 'deploydash_list_servers',
      );
      expect(listRow.summary, 'Listed servers.');
      expect(statusRow.accessLevel, 'read_only');
      expect(statusRow.status, 'success');
      expect(statusRow.summary, 'fetched status');
      expect(statusRow.details, const <String, dynamic>{'count': 1});
    }, skip: !sqliteAvailable);

    test(
      'listRecent returns entries written in the same second newest first',
      () async {
        // `createdAt` defaults to SQLite's `currentDateAndTime`, which is
        // whole seconds. A burst of agent tool calls -- the normal case, not
        // an edge one -- therefore shares a single timestamp, and ordering by
        // `createdAt` alone leaves those rows in whatever order SQLite
        // happens to return. That is why the test above reaches for
        // `singleWhere` rather than an index.
        for (var index = 1; index <= 5; index++) {
          await repository.append(
            toolName: 'tool_$index',
            accessLevel: 'read_only',
            status: 'success',
            summary: 'entry $index',
          );
        }

        final rows = await repository.listRecent(limit: 5);

        expect(rows.map((row) => row.toolName).toList(), <String>[
          'tool_5',
          'tool_4',
          'tool_3',
          'tool_2',
          'tool_1',
        ]);
      },
      skip: !sqliteAvailable,
    );

    test('listRecent falls back and never caps the limit', () async {
      for (var index = 0; index < 1001; index++) {
        await repository.append(
          toolName: 'tool_$index',
          accessLevel: 'read_only',
          status: 'success',
          summary: 'entry $index',
        );
      }

      // One-sided: non-positive falls back to 20, huge passes through.
      expect(await repository.listRecent(limit: 0), hasLength(20));
      expect(await repository.listRecent(limit: 1000000), hasLength(1001));
    }, skip: !sqliteAvailable);

    test('listRecent returns null details for invalid stored json', () async {
      await database
          .into(database.agentAuditEntries)
          .insert(
            AgentAuditEntriesCompanion.insert(
              toolName: 'deploydash_status',
              accessLevel: 'read_only',
              status: 'success',
              summary: 'Ready',
              detailsJson: const Value('[]'),
            ),
          );
      await database
          .into(database.agentAuditEntries)
          .insert(
            AgentAuditEntriesCompanion.insert(
              toolName: 'deploydash_list_servers',
              accessLevel: 'read_only',
              status: 'success',
              summary: 'Ready',
              detailsJson: const Value('{not-json'),
            ),
          );

      final rows = await repository.listRecent(limit: 10);
      expect(rows.first.details, isNull);
      expect(rows.last.details, isNull);
    }, skip: !sqliteAvailable);
  });
}
