import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_environment_variable_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('AppEnvironmentVariableRepository', () {
    late AppDatabase database;
    late AppEnvironmentVariableRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = AppEnvironmentVariableRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('replaces and loads env vars for a project', () async {
      await repository.replaceForProject(
        projectId: 'project-a',
        rows: const [
          AppEnvironmentVariableRecord(
            projectId: 'project-a',
            key: 'API_URL',
            value: 'https://example.com',
            secret: false,
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-a',
            key: 'API_KEY',
            value: 'secret-123',
            secret: true,
          ),
        ],
      );

      final rows = await repository.listForProject('project-a');
      expect(rows, hasLength(2));
      expect(rows[0].key, 'API_URL');
      expect(rows[0].value, 'https://example.com');
      expect(rows[0].secret, isFalse);
      expect(rows[1].key, 'API_KEY');
      expect(rows[1].value, 'secret-123');
      expect(rows[1].secret, isTrue);
    }, skip: !sqliteAvailable);

    test('replace removes old rows and deduplicates by key', () async {
      await repository.replaceForProject(
        projectId: 'project-a',
        rows: const [
          AppEnvironmentVariableRecord(
            projectId: 'project-a',
            key: 'APP_ENV',
            value: 'production',
          ),
        ],
      );
      await repository.replaceForProject(
        projectId: 'project-a',
        rows: const [
          AppEnvironmentVariableRecord(
            projectId: 'project-a',
            key: ' APP_ENV ',
            value: 'staging',
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-a',
            key: 'APP_ENV',
            value: 'dev',
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-a',
            key: 'FEATURE_FLAG',
            value: '1',
          ),
        ],
      );

      final rows = await repository.listForProject('project-a');
      expect(rows, hasLength(2));
      expect(rows[0].key, 'APP_ENV');
      expect(rows[0].value, 'dev');
      expect(rows[1].key, 'FEATURE_FLAG');
      expect(rows[1].value, '1');
    }, skip: !sqliteAvailable);

    test('empty project ids are ignored and empty keys are dropped', () async {
      await repository.replaceForProject(
        projectId: '   ',
        rows: const [
          AppEnvironmentVariableRecord(
            projectId: 'ignored',
            key: 'APP_ENV',
            value: 'production',
          ),
        ],
      );
      expect(await repository.listForProject('project-a'), isEmpty);

      await repository.replaceForProject(
        projectId: 'project-a',
        rows: const [
          AppEnvironmentVariableRecord(
            projectId: 'project-a',
            key: '   ',
            value: 'ignored',
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-a',
            key: 'FEATURE_FLAG',
            value: '1',
          ),
        ],
      );

      final rows = await repository.listForProject('project-a');
      expect(rows, hasLength(1));
      expect(rows.single.key, 'FEATURE_FLAG');
      expect(rows.single.value, '1');
      expect(await repository.listForProject('   '), isEmpty);
    }, skip: !sqliteAvailable);

    test('stores values verbatim without trimming', () async {
      await repository.replaceForProject(
        projectId: 'project-a',
        rows: const [
          AppEnvironmentVariableRecord(
            projectId: 'project-a',
            key: '  PADDED_KEY  ',
            value: '  spaced value  ',
            secret: true,
          ),
        ],
      );

      final rows = await repository.listForProject('project-a');
      expect(rows.single.key, 'PADDED_KEY');
      expect(rows.single.value, '  spaced value  ');
      expect(rows.single.secret, isTrue);
    }, skip: !sqliteAvailable);

    test('provider resolves repository from the database provider', () async {
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);

      final provided = container.read(appEnvironmentVariableRepositoryProvider);
      await provided.replaceForProject(
        projectId: 'project-provider',
        rows: const [
          AppEnvironmentVariableRecord(
            projectId: 'project-provider',
            key: 'FROM_PROVIDER',
            value: '1',
          ),
        ],
      );

      final rows = await provided.listForProject('project-provider');
      expect(rows, hasLength(1));
      expect(rows.single.key, 'FROM_PROVIDER');
    }, skip: !sqliteAvailable);
  });
}
