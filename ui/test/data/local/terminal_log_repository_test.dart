import 'dart:io';

import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/terminal_log_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';
import '../../../integration_test/support/e2e_checklist.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('TerminalLogRepository', () {
    late AppDatabase database;
    late TerminalLogRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = TerminalLogRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('appendLog persists rendered and raw output', () async {
      await repository.appendLog(
        message: 'Starting server setup tasks',
        renderedLine: '[Server 12:00:00] Starting server setup tasks',
        serverLabel: 'Server',
        source: 'engine',
        taskType: 'setup',
      );

      final rows = await repository.listRecentLogs(limit: 10);
      expect(rows, hasLength(1));
      expect(rows.first.serverLabel, 'Server');
      expect(rows.first.message, 'Starting server setup tasks');
      expect(
        rows.first.renderedLine,
        '[Server 12:00:00] Starting server setup tasks',
      );
      expect(rows.first.source, 'engine');
      expect(rows.first.taskType, 'setup');
    }, skip: !sqliteAvailable);

    test(
      'appendLog sanitizes malicious legacy output before persistence',
      () async {
        const canary = 'DD_TEST_SECRET_DO_NOT_LOG_7f4c';
        await repository.appendLog(
          message: 'Authorization: Bearer $canary',
          renderedLine:
              '[Server] -----BEGIN PRIVATE KEY-----\n$canary\n-----END PRIVATE KEY-----',
          source: 'engine',
          taskType: 'app_deploy',
        );

        final row = (await repository.listRecentLogs(limit: 10)).single;
        expect(row.message, 'Authorization: Bearer ***');
        expect(row.renderedLine, isNot(contains(canary)));
        expect(row.renderedLine, isNot(contains('BEGIN PRIVATE KEY')));
      },
      skip: !sqliteAvailable,
    );

    test(
      'appendLog ignores blank values and normalizes source fields',
      () async {
        await repository.appendLog(
          message: '   ',
          renderedLine: '[Server] blank',
        );
        await repository.appendLog(
          message: 'Real line',
          renderedLine: '  [Server] Real line  ',
          serverLabel: '  Main  ',
          source: '   ',
          taskType: '  app_deploy  ',
        );

        final rows = await repository.listRecentLogs(limit: 10);
        expect(rows, hasLength(1));
        expect(rows.first.serverLabel, 'Main');
        expect(rows.first.renderedLine, '[Server] Real line');
        expect(rows.first.source, 'terminal');
        expect(rows.first.taskType, 'app_deploy');
      },
      skip: !sqliteAvailable,
    );

    test(
      'listRecentLogsForTaskType filters and keeps chronological order',
      () async {
        await repository.appendLog(
          message: 'Deploy one',
          renderedLine: '[deploy] Deploy one',
          taskType: 'app_deploy',
          createdAt: DateTime(2026, 4, 13, 10, 0, 0),
        );
        await repository.appendLog(
          message: 'Other task',
          renderedLine: '[setup] Other task',
          taskType: 'setup',
          createdAt: DateTime(2026, 4, 13, 10, 0, 1),
        );
        await repository.appendLog(
          message: 'Deploy two',
          renderedLine: '[deploy] Deploy two',
          taskType: 'app_deploy',
          createdAt: DateTime(2026, 4, 13, 10, 0, 2),
        );

        final rows = await repository.listRecentLogsForTaskType(
          taskType: '  app_deploy  ',
          limit: 10,
        );
        expect(rows.map((row) => row.message).toList(), [
          'Deploy one',
          'Deploy two',
        ]);
        expect(
          await repository.listRecentLogsForTaskType(taskType: '   '),
          isEmpty,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'scoped log queries only return selected project and server',
      () async {
        await repository.appendLog(
          projectId: 'project-a',
          serverId: 'server-a',
          message: 'Deploy A',
          renderedLine: '[deploy] Deploy A',
          taskType: 'app_deploy',
          createdAt: DateTime(2026, 4, 13, 10),
        );
        await repository.appendLog(
          projectId: 'project-b',
          serverId: 'server-a',
          message: 'Deploy B',
          renderedLine: '[deploy] Deploy B',
          taskType: 'app_deploy',
          createdAt: DateTime(2026, 4, 13, 10, 1),
        );
        await repository.appendLog(
          projectId: 'project-a',
          serverId: 'server-b',
          message: 'Deploy other server',
          renderedLine: '[deploy] Deploy other server',
          taskType: 'app_deploy',
          createdAt: DateTime(2026, 4, 13, 10, 2),
        );
        await repository.appendLog(
          message: 'Legacy unscoped',
          renderedLine: '[deploy] Legacy unscoped',
          taskType: 'app_deploy',
          createdAt: DateTime(2026, 4, 13, 10, 3),
        );

        final rows = await repository.listRecentLogsForScope(
          projectId: 'project-a',
          serverId: 'server-a',
        );

        expect(rows.map((row) => row.message), ['Deploy A']);
        expect(rows.single.projectId, 'project-a');
        expect(rows.single.serverId, 'server-a');
      },
      skip: !sqliteAvailable,
    );

    test('listRecentLogs returns oldest to newest order', () async {
      await repository.appendLog(
        message: 'Line one',
        renderedLine: '[Server 12:00:00] Line one',
        createdAt: DateTime(2026, 2, 11, 12, 0, 0),
      );
      await repository.appendLog(
        message: 'Line two',
        renderedLine: '[Server 12:00:01] Line two',
        createdAt: DateTime(2026, 2, 11, 12, 0, 1),
      );

      final rows = await repository.listRecentLogs(limit: 10);
      expect(rows, hasLength(2));
      expect(rows.first.message, 'Line one');
      expect(rows.last.message, 'Line two');
    }, skip: !sqliteAvailable);

    test(
      'appendLogBatchOnce stores one sanitized evidence batch idempotently',
      () async {
        const canary = 'DD_TEST_SECRET_DO_NOT_LOG_7f4c';
        final batchAt = DateTime.utc(2026, 9, 30, 12);
        final lines = <({String message, String renderedLine})>[
          (
            message: 'Authorization: Bearer $canary',
            renderedLine: '[Server 12:00:00] Authorization: Bearer $canary',
          ),
          (
            message: 'compiler failed',
            renderedLine: '[Server 12:00:00] compiler failed',
          ),
          (message: ' ', renderedLine: '[Server] blank'),
        ];

        await repository.appendLogBatchOnce(
          lines: lines,
          projectId: 'project-1',
          serverId: 'server-1',
          serverLabel: 'Server',
          source: 'app_deploy_failure_evidence',
          taskType: 'app_deploy',
          createdAt: batchAt,
        );
        await repository.appendLogBatchOnce(
          lines: lines,
          projectId: 'project-1',
          serverId: 'server-1',
          serverLabel: 'Server',
          source: 'app_deploy_failure_evidence',
          taskType: 'app_deploy',
          createdAt: batchAt,
        );

        final rows = await repository.listRecentLogsForScope(
          projectId: 'project-1',
          serverId: 'server-1',
        );
        expect(rows, hasLength(2));
        expect(rows.map((row) => row.source).toSet(), <String>{
          'app_deploy_failure_evidence',
        });
        expect(rows.map((row) => row.taskType).toSet(), <String?>{
          'app_deploy',
        });
        expect(
          rows.map((row) => row.message).join('\n'),
          isNot(contains(canary)),
        );
        expect(rows.first.message, 'Authorization: Bearer ***');
        expect(rows.last.message, 'compiler failed');

        await repository.appendLogBatchOnce(
          lines: const <({String message, String renderedLine})>[
            (message: ' ', renderedLine: ' '),
          ],
          projectId: 'project-1',
          serverId: 'server-1',
          serverLabel: 'Server',
          source: 'app_deploy_failure_evidence',
          taskType: 'app_deploy',
          createdAt: batchAt.add(const Duration(seconds: 1)),
        );
        expect(
          await repository.listRecentLogsForScope(
            projectId: 'project-1',
            serverId: 'server-1',
          ),
          hasLength(2),
        );
      },
      skip: !sqliteAvailable,
    );
  });

  group('TerminalLogRepository list limits (D-20)', () {
    late AppDatabase database;
    late TerminalLogRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = TerminalLogRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('lists honor their default limits', () async {
      final base = DateTime(2026, 4, 13, 10);
      for (var index = 0; index < 501; index++) {
        await repository.appendLog(
          projectId: 'project-a',
          serverId: 'server-a',
          message: 'line $index',
          renderedLine: '[log] line $index',
          taskType: 'app_deploy',
          createdAt: base.add(Duration(seconds: index)),
        );
      }

      // One fixture serves all three defaults: taskType 200, plain 500,
      // scope 500. Limits pass through raw -- no clamp in this file.
      expect(
        await repository.listRecentLogsForTaskType(taskType: 'app_deploy'),
        hasLength(200),
      );
      expect(await repository.listRecentLogs(), hasLength(500));
      expect(
        await repository.listRecentLogsForScope(
          projectId: 'project-a',
          serverId: 'server-a',
        ),
        hasLength(500),
      );
      expect(await repository.listRecentLogs(limit: 2001), hasLength(501));
    }, skip: !sqliteAvailable);

    test('scope lists require both project and server', () async {
      await repository.appendLog(
        projectId: 'project-a',
        serverId: 'server-a',
        message: 'Deploy A',
        renderedLine: '[deploy] Deploy A',
        taskType: 'app_deploy',
      );

      expect(
        await repository.listRecentLogsForScope(
          projectId: '   ',
          serverId: 'server-a',
        ),
        isEmpty,
      );
      expect(
        await repository.listRecentLogsForScope(
          projectId: 'project-a',
          serverId: '',
        ),
        isEmpty,
      );
      expect(
        await repository.listRecentLogsForScope(
          projectId: 'project-a',
          serverId: 'server-a',
        ),
        hasLength(1),
      );
    }, skip: !sqliteAvailable);
  });

  group('TerminalLogRepository collapsed list tail (D-20)', () {
    test('recent-logs lists share one tail owner', () {
      // Guard-style: one tail definition + three delegate call sites.
      final root = findRepositoryRoot();
      final source = File(
        '${root.path}/ui/lib/data/local/terminal_log_repository.dart',
      ).readAsStringSync();
      expect('_listRecent'.allMatches(source).length, 4);
    });
  });
}
