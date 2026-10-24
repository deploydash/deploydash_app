import 'package:ui/data/local/app_database.dart';
import 'package:ui/providers/terminal_log_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  test('terminal transcript actions persist a rendered shell line', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);

    await container
        .read(terminalTranscriptActionsProvider)
        .append(
          message: 'Deployment complete',
          renderedLine: '[Production 12:00:00] Deployment complete',
          serverLabel: 'Production',
          projectId: 'project-1',
          serverId: 'server-1',
          source: 'engine',
          taskType: 'app_deploy',
          createdAt: DateTime(2026, 9, 2, 12),
        );

    final logs = await container
        .read(terminalLogRepositoryProvider)
        .listRecentLogs();
    expect(logs, hasLength(1));
    expect(logs.single.message, 'Deployment complete');
    expect(logs.single.projectId, 'project-1');
  }, skip: !sqliteAvailable);
}
