import 'package:ui/providers/worker_instance_provider.dart';
import 'package:ui/ui/project/workspace/workers/workers_tab_logic.dart';
import 'package:flutter_test/flutter_test.dart';

/// The worker tab's logic, exercised without pumping a widget.
///
/// Before T-3.3.6 these were private types inside a `part` of
/// `project_workspace.dart`, reachable only through the workspace widget. That
/// is the whole reason `*_logic.dart` files exist, so this file is what the
/// extraction was for.
void main() {
  ProjectWorkerInstance worker({
    String id = 'queue',
    bool enabled = true,
    String? databaseUser = 'queue_rw',
  }) {
    return ProjectWorkerInstance(
      id: id,
      projectId: 'project-blog',
      name: 'Queue',
      startCommand: 'php artisan queue:work',
      cpuLimit: 0.5,
      memoryMb: 512,
      diskMb: 1024,
      databaseUser: databaseUser,
      databaseName: 'blog',
      databasePassword: 'secret',
      databaseEngine: 'postgres',
      enabled: enabled,
      sortOrder: 3,
    );
  }

  group('WorkerDraft', () {
    test('round-trips a persisted worker without losing a field', () {
      final original = worker();

      final restored = WorkerDraft.fromWorker(
        original,
      ).toWorkerInstance(projectId: original.projectId, sortOrder: 3);

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.startCommand, original.startCommand);
      expect(restored.cpuLimit, original.cpuLimit);
      expect(restored.memoryMb, original.memoryMb);
      expect(restored.diskMb, original.diskMb);
      expect(restored.databaseUser, original.databaseUser);
      expect(restored.databaseName, original.databaseName);
      expect(restored.databasePassword, original.databasePassword);
      expect(restored.databaseEngine, original.databaseEngine);
      expect(restored.enabled, original.enabled);
      expect(restored.sortOrder, 3);
    });

    test('copyWith distinguishes "leave alone" from "set to null"', () {
      final draft = WorkerDraft.fromWorker(worker());

      // Omitted: the sentinel default means keep what is there.
      expect(draft.copyWith(enabled: true).databaseUser, 'queue_rw');
      // Passed explicitly as null: detach the worker from its database user.
      expect(
        draft.copyWith(databaseUser: null, enabled: true).databaseUser,
        isNull,
      );
      // Everything else survives the detach.
      expect(
        draft.copyWith(databaseUser: null, enabled: true).databaseName,
        'blog',
      );
    });

    test(
      'enabled is required on copyWith, so a toggle cannot be forgotten',
      () {
        final draft = WorkerDraft.fromWorker(worker());

        expect(draft.copyWith(enabled: false).enabled, isFalse);
        expect(draft.copyWith(enabled: true).enabled, isTrue);
      },
    );
  });

  group('WorkerDatabaseUser', () {
    test('keys on engine, user and database together', () {
      const user = WorkerDatabaseUser(
        engine: 'postgres',
        username: 'queue_rw',
        database: 'blog',
        accessMode: 'read_write',
      );
      const sameUserOtherDatabase = WorkerDatabaseUser(
        engine: 'postgres',
        username: 'queue_rw',
        database: 'analytics',
        accessMode: 'read_write',
      );

      expect(user.key, 'postgres::queue_rw::blog');
      expect(user.key, isNot(sameUserOtherDatabase.key));
    });

    test('is built at runtime from a discovery result', () {
      // Constructed non-const on purpose: these come back from a live
      // PostgreSQL user query, one per row, not from a literal.
      final rows = <Map<String, String>>[
        <String, String>{
          'user': 'queue_rw',
          'db': 'blog',
          'mode': 'read_write',
        },
        <String, String>{'user': 'queue_ro', 'db': 'blog', 'mode': 'read_only'},
      ];
      final discovered = WorkerDatabaseDiscoveryResult(
        users: <WorkerDatabaseUser>[
          for (final row in rows)
            WorkerDatabaseUser(
              engine: 'postgres',
              username: row['user']!,
              database: row['db']!,
              accessMode: row['mode']!,
            ),
        ],
      );

      expect(discovered.users, hasLength(2));
      expect(discovered.users.map((user) => user.key), <String>[
        'postgres::queue_rw::blog',
        'postgres::queue_ro::blog',
      ]);
      expect(discovered.users.last.accessLabel, 'Read only');
    });

    test('labels access mode in plain English', () {
      const readOnly = WorkerDatabaseUser(
        engine: 'postgres',
        username: 'queue_ro',
        database: 'blog',
        accessMode: 'read_only',
      );
      const readWrite = WorkerDatabaseUser(
        engine: 'postgres',
        username: 'queue_rw',
        database: 'blog',
        accessMode: 'read_write',
      );

      expect(readOnly.accessLabel, 'Read only');
      expect(readWrite.accessLabel, 'Read and write');
      expect(readOnly.engineLabel, 'PostgreSQL');
    });
  });

  group('nextWorkerId', () {
    test('slugifies the name', () {
      expect(nextWorkerId('Queue Worker', const <String>{}), 'queue-worker');
      expect(nextWorkerId('  Emails!  ', const <String>{}), 'emails');
    });

    test('suffixes until it no longer collides', () {
      expect(nextWorkerId('Queue', const <String>{'queue'}), 'queue-2');
      expect(
        nextWorkerId('Queue', const <String>{'queue', 'queue-2', 'queue-3'}),
        'queue-4',
      );
    });

    test('a name that slugifies to nothing still yields a usable id', () {
      // The id addresses the worker's container on the server, so an empty
      // one is not an option.
      expect(nextWorkerId('***', const <String>{}), 'worker');
      expect(nextWorkerId('', const <String>{'worker'}), 'worker-2');
    });
  });
}
