import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/server_repository.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/providers/shell_terminal_provider.dart';
import 'package:ui/providers/terminal_log_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  const server = Server(
    id: 'server-production',
    name: 'Production',
    host: '203.0.113.42',
    port: 22,
    sshUser: 'ubuntu',
    authMethod: ServerAuthMethod.password,
  );
  const project = Project(
    id: 'project-console',
    serverId: 'server-production',
    name: 'Console',
    type: 'Node.js',
    gitUrl: 'git@example.test:deploydash/console.git',
    primaryDomain: 'console.example.test',
  );

  test(
    'terminal controller streams and persists contextual rendered output',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          serverCatalogProvider.overrideWith(
            () => _FakeServerCatalogNotifier(
              const ServerCatalogState(
                isLoading: false,
                onboardingComplete: true,
                servers: <Server>[server],
                selectedServerId: 'server-production',
              ),
            ),
          ),
          selectedProjectProvider.overrideWithValue(project),
          selectedServerProvider.overrideWithValue(server),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(shellTerminalControllerProvider);
      final output = <String>[];
      final details = <bool>[];
      final subscription = controller.outputStream.listen((entry) {
        output.add(entry.message);
        details.add(entry.isDetail);
      });
      addTearDown(subscription.cancel);

      controller.updateContext(isOnboarding: false);
      controller.initialize();
      controller.initialize();
      controller.writeLine(
        'Deployment complete',
        source: 'ui',
        taskType: 'navigation',
      );
      controller.writeLine(
        'APP_REPOSITORY_HOST_KEY_CONFIRMATION_REQUIRED',
        source: 'engine',
      );
      await Future<void>.delayed(Duration.zero);

      expect(output, hasLength(2));
      expect(
        output.singleWhere((line) => line.contains('Deployment complete')),
        startsWith('[Production '),
      );
      expect(details, <bool>[false, true]);
      final logs = await container
          .read(terminalLogRepositoryProvider)
          .listRecentLogs();
      expect(logs, hasLength(2));
      expect(logs.last.projectId, project.id);
      expect(logs.last.serverId, server.id);
      expect(logs.last.source, 'ui');

      controller.updateContext(isOnboarding: true);
      controller.writeLine('Provisioning started', detail: true);
      await Future<void>.delayed(Duration.zero);

      expect(output.last, startsWith('[New Server '));
      expect(details.last, isTrue);
    },
    skip: !sqliteAvailable,
  );
}

class _FakeServerCatalogNotifier extends ServerCatalogNotifier {
  _FakeServerCatalogNotifier(this._catalog);

  final ServerCatalogState _catalog;

  @override
  ServerCatalogState build() => _catalog;
}
