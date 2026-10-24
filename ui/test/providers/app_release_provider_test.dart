import 'package:ui/data/local/app_database.dart'
    show AppDatabase, appDatabaseProvider;
import 'package:ui/data/local/app_release_repository.dart';
import 'package:ui/providers/app_release_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_support/sqlite_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  test(
    'upsertRuntimeSnapshot preserves existing health and resource fields',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(appReleaseProvider.notifier);
      await notifier.upsertRuntimeSnapshot(
        AppRuntimeSnapshotRecord(
          projectId: 'project-web',
          serverId: 'server-one',
          healthStatus: 'ready',
          publicHealthJson: '{"status":"healthy"}',
          healthCheckedAt: DateTime.utc(2026, 1, 1, 12),
          updatedAt: DateTime.utc(2026, 1, 1, 12),
        ),
      );
      await notifier.upsertRuntimeSnapshot(
        AppRuntimeSnapshotRecord(
          projectId: 'project-web',
          serverId: 'server-one',
          resourceUsageJson: '{"cpu":"1%"}',
          resourceCheckedAt: DateTime.utc(2026, 1, 1, 12, 5),
          updatedAt: DateTime.utc(2026, 1, 1, 12, 5),
        ),
      );
      await notifier.upsertRuntimeSnapshot(
        AppRuntimeSnapshotRecord(
          projectId: 'project-web',
          serverId: 'server-one',
          healthStatus: 'degraded',
          healthCheckedAt: DateTime.utc(2026, 1, 1, 12, 10),
          updatedAt: DateTime.utc(2026, 1, 1, 12, 10),
        ),
      );

      final snapshot = await AppReleaseRepository(
        database,
      ).readRuntimeSnapshot(projectId: 'project-web', serverId: 'server-one');
      expect(snapshot?.healthStatus, 'degraded');
      expect(
        snapshot?.healthCheckedAt?.toUtc(),
        DateTime.utc(2026, 1, 1, 12, 10),
      );
      expect(snapshot?.resourceUsageJson, '{"cpu":"1%"}');
      expect(snapshot?.publicHealthJson, '{"status":"healthy"}');
      expect(
        snapshot?.resourceCheckedAt?.toUtc(),
        DateTime.utc(2026, 1, 1, 12, 5),
      );

      final scope = container
          .read(appReleaseProvider)
          .scopeFor(projectId: 'project-web', serverId: 'server-one');
      expect(scope.runtimeSnapshot?.healthStatus, 'degraded');
      expect(scope.runtimeSnapshot?.resourceUsageJson, '{"cpu":"1%"}');
      expect(scope.runtimeSnapshot?.publicHealthJson, '{"status":"healthy"}');
    },
    skip: !sqliteAvailable,
  );
}
