import 'package:ui/data/local/server_repository.dart';
import 'package:ui/models/workspace_scope.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkspaceScope', () {
    test('normalizes valid ids and rejects missing scope ids', () {
      final scope = WorkspaceScope.fromIds(
        projectId: ' project-a ',
        serverId: ' server-1 ',
      );

      expect(scope, isNotNull);
      expect(scope!.projectId, 'project-a');
      expect(scope.serverId, 'server-1');
      expect(scope.key, 'project-a::server-1');
      expect(scope.matches(projectId: 'project-a', serverId: 'server-1'), true);
      expect(
        scope.matches(projectId: 'project-b', serverId: 'server-1'),
        false,
      );
      expect(
        WorkspaceScope.fromIds(projectId: '', serverId: 'server-1'),
        isNull,
      );
      expect(
        WorkspaceScope.fromIds(projectId: 'project-a', serverId: ' '),
        isNull,
      );
    });

    test('can be created from selected project and server models', () {
      const project = Project(
        id: 'project-a',
        name: 'Project A',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'a.example.com',
      );
      const server = Server(
        id: 'server-1',
        name: 'Server 1',
        host: '192.0.2.10',
        port: 22,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.password,
      );

      final scope = WorkspaceScope.fromSelection(project, server);

      expect(scope?.key, 'project-a::server-1');
      expect(WorkspaceScope.fromSelection(null, server), isNull);
      expect(WorkspaceScope.fromSelection(project, null), isNull);
    });
  });

  group('WorkspaceRunContext', () {
    test('requires matching scope, epoch, and discriminator when provided', () {
      const scope = WorkspaceScope(
        projectId: 'project-a',
        serverId: 'server-1',
      );
      const run = WorkspaceRunContext(
        scope: scope,
        epoch: 7,
        runId: 'run-7',
        discriminator: 'updated-1',
      );

      expect(
        run.isCurrent(
          currentScope: scope,
          currentEpoch: 7,
          currentDiscriminator: 'updated-1',
        ),
        true,
      );
      expect(
        run.isCurrent(
          currentScope: const WorkspaceScope(
            projectId: 'project-b',
            serverId: 'server-1',
          ),
          currentEpoch: 7,
          currentDiscriminator: 'updated-1',
        ),
        false,
      );
      expect(
        run.isCurrent(
          currentScope: scope,
          currentEpoch: 8,
          currentDiscriminator: 'updated-1',
        ),
        false,
      );
      expect(
        run.isCurrent(
          currentScope: scope,
          currentEpoch: 7,
          currentDiscriminator: 'updated-2',
        ),
        false,
      );
    });
  });

  group('WorkspaceBusyRegistry', () {
    test('tracks busy ids by scope and kind', () {
      final registry = WorkspaceBusyRegistry();
      const scopeA = WorkspaceScope(
        projectId: 'project-a',
        serverId: 'server-1',
      );
      const scopeB = WorkspaceScope(
        projectId: 'project-b',
        serverId: 'server-1',
      );

      final key = registry.markBusy(scope: scopeA, kind: 'worker', id: 'queue');

      expect(registry.isBusy(scope: scopeA, kind: 'worker', id: 'queue'), true);
      expect(
        registry.isBusy(scope: scopeA, kind: 'scheduler-task', id: 'queue'),
        false,
      );
      expect(
        registry.isBusy(scope: scopeB, kind: 'worker', id: 'queue'),
        false,
      );

      registry.remove(key);
      expect(
        registry.isBusy(scope: scopeA, kind: 'worker', id: 'queue'),
        false,
      );
    });

    test('can clear only the selected workspace scope', () {
      final registry = WorkspaceBusyRegistry();
      const scopeA = WorkspaceScope(
        projectId: 'project-a',
        serverId: 'server-1',
      );
      const scopeB = WorkspaceScope(
        projectId: 'project-b',
        serverId: 'server-1',
      );

      registry.markBusy(scope: scopeA, kind: 'worker', id: 'queue');
      registry.markBusy(scope: scopeB, kind: 'worker', id: 'queue');

      registry.clearScope(scopeA);

      expect(
        registry.isBusy(scope: scopeA, kind: 'worker', id: 'queue'),
        false,
      );
      expect(registry.isBusy(scope: scopeB, kind: 'worker', id: 'queue'), true);
    });
  });
}
