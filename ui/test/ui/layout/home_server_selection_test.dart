import 'package:ui/data/local/server_repository.dart';
import 'package:ui/data/local/project_deletion_recovery_repository.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:ui/ui/layout/home_dashboard_view.dart';
import 'package:ui/ui/system/app_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _server = Server(
  id: 'server-1',
  name: 'Prod-01',
  host: '203.0.113.10',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
  osName: 'Ubuntu 24.04',
  serviceDatabaseEnabled: true,
  serviceEmailEnabled: true,
  serviceDomainEnabled: true,
);

const _secondServer = Server(
  id: 'server-2',
  name: 'Staging-EU',
  host: '198.51.100.4',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
);

Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

Widget _home({
  List<Project> projects = const <Project>[],
  List<Server> servers = const <Server>[],
  Server? selectedServer,
  int? serverCount,
  DeletedProjectNotice? deletedProjectNotice,
  List<ProjectDeletionRecoveryRecord> recoveries =
      const <ProjectDeletionRecoveryRecord>[],
  Future<void> Function(ProjectDeletionRecoveryRecord)? onRetryProjectCleanup,
  Future<void> Function(ProjectDeletionRecoveryRecord)? onRemoveLocalRecord,
  ValueChanged<String>? onSelectServer,
  ValueChanged<String>? onOpenProject,
  VoidCallback? onCreateProject,
  VoidCallback? onAddServer,
  VoidCallback? onOpenServerManagement,
  VoidCallback? onDismiss,
}) {
  return HomeDashboardView(
    projects: projects,
    servers: servers,
    selectedServer: selectedServer,
    serverCount: serverCount ?? servers.length,
    deletedProjectNotice: deletedProjectNotice,
    projectDeletionRecoveries: recoveries,
    onDismissDeletedProjectNotice: onDismiss ?? () {},
    onRetryProjectCleanup: onRetryProjectCleanup,
    onRemovePendingProjectLocalRecord: onRemoveLocalRecord,
    onSelectServer: onSelectServer,
    onOpenProject: onOpenProject ?? (_) {},
    onCreateProject: onCreateProject ?? () {},
    onAddServer: onAddServer ?? () {},
    onOpenServerManagement: onOpenServerManagement ?? () {},
  );
}

void main() {
  testWidgets('highlights the chosen server when the panes are stacked', (
    WidgetTester tester,
  ) async {
    // 800 is below AppWorkspaceBreakpoints.twoColumn (960), so the servers and
    // projects panes stack -- the configuration issue #35 reported.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const [_server, _secondServer],
          selectedServer: _server,
          serverCount: 2,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<AppResourceRow>(find.byKey(const Key('home-server-server-1')))
          .selected,
      isTrue,
      reason: 'the chosen server is visibly selected at every width',
    );
    expect(
      tester
          .widget<AppResourceRow>(find.byKey(const Key('home-server-server-2')))
          .selected,
      isFalse,
      reason: 'only the chosen one is selected',
    );
  });

  testWidgets('offers server selection guidance when nothing is chosen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const [_server, _secondServer],
          selectedServer: null,
          serverCount: 2,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('home-projects-no-server-chosen')),
      findsOneWidget,
    );
    expect(find.text('Select a server'), findsOneWidget);
    expect(
      find.text('Connect a server first'),
      findsNothing,
      reason:
          'telling a user with two saved servers to connect one '
          'contradicts the servers card beside it (G-35)',
    );
  });

  testWidgets('still tells a user with no servers to connect one', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(_home(servers: const [], selectedServer: null, serverCount: 0)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Connect a server first'), findsOneWidget);
    expect(
      find.byKey(const Key('home-projects-no-server-chosen')),
      findsNothing,
    );
  });
}
