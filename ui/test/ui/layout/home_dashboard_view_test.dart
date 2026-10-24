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

const _project = Project(
  id: 'project-1',
  serverId: 'server-1',
  name: 'Alpha App',
  type: 'app',
  gitUrl: 'https://github.com/example/alpha',
  primaryDomain: 'alpha.example.com',
);

final _deployedProject = Project(
  id: 'project-2',
  serverId: 'server-1',
  name: 'Beta Worker',
  type: 'Worker',
  gitUrl: 'https://github.com/example/beta',
  primaryDomain: '',
  lastDeployedAt: DateTime.utc(2026, 1, 2, 10, 30),
);

ProjectDeletionRecoveryRecord _recovery() {
  final now = DateTime.utc(2026, 8, 9, 12);
  return ProjectDeletionRecoveryRecord(
    projectId: 'project-pending',
    serverId: 'server-1',
    projectName: 'Pending App',
    projectSlug: 'pending-app',
    status: 'cleanup_failed',
    steps: const <ProjectDeletionStepState>[
      ProjectDeletionStepState(
        id: 'app_runtime',
        label: 'Remove web app runtime',
        status: ProjectDeletionStepStatus.failed,
        message: 'Connection interrupted.',
      ),
    ],
    lastError: 'Connection interrupted.',
    attemptCount: 1,
    requestedAt: now,
    lastAttemptAt: now,
    updatedAt: now,
  );
}

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
  Set<String> pendingSetupServerIds = const {},
  ValueChanged<String>? onRetryServerSetup,
  VoidCallback? onDismiss,
  bool nagVisible = false,
  VoidCallback? onShareNag,
  VoidCallback? onDismissNag,
}) {
  return HomeDashboardView(
    projects: projects,
    servers: servers,
    selectedServer: selectedServer,
    serverCount: serverCount ?? servers.length,
    deletedProjectNotice: deletedProjectNotice,
    projectDeletionRecoveries: recoveries,
    pendingSetupServerIds: pendingSetupServerIds,
    onDismissDeletedProjectNotice: onDismiss ?? () {},
    onRetryProjectCleanup: onRetryProjectCleanup,
    onRemovePendingProjectLocalRecord: onRemoveLocalRecord,
    onSelectServer: onSelectServer,
    onRetryServerSetup: onRetryServerSetup,
    onOpenProject: onOpenProject ?? (_) {},
    onCreateProject: onCreateProject ?? () {},
    onAddServer: onAddServer ?? () {},
    onOpenServerManagement: onOpenServerManagement ?? () {},
    telemetryNagVisible: nagVisible,
    onShareTelemetryNag: onShareNag,
    onDismissTelemetryNag: onDismissNag,
  );
}

void main() {
  test('displayProjectTypeLabel normalizes app labels', () {
    expect(displayProjectTypeLabel('app'), 'Web app');
    expect(displayProjectTypeLabel('Web app'), 'Web app');
    expect(displayProjectTypeLabel(''), 'Project');
    expect(displayProjectTypeLabel('Worker'), 'Worker');
  });

  testWidgets('Home dashboard guides the first server connection', (
    WidgetTester tester,
  ) async {
    var addServerCount = 0;

    await tester.pumpWidget(
      _wrap(_home(onAddServer: () => addServerCount += 1)),
    );

    expect(find.byKey(const Key('home-servers-card')), findsOneWidget);
    expect(find.byKey(const Key('home-projects-card')), findsOneWidget);
    expect(find.text('Add server'), findsOneWidget);
    expect(find.text('New project'), findsOneWidget);
    expect(find.text('No servers yet'), findsOneWidget);
    expect(find.text('Connect a server first'), findsOneWidget);
    expect(
      find.text('Add a server before creating a project.'),
      findsOneWidget,
    );
    expect(find.text('Choose a server to see its projects.'), findsOneWidget);
    expect(
      find.byKey(const Key('home-servers-empty-add-button')),
      findsNothing,
    );

    final createButton = tester.widget<FilledButton>(
      find.byKey(const Key('home-new-project-button')),
    );
    final connectButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('home-add-server-button')),
    );
    expect(createButton.onPressed, isNull);
    expect(connectButton.autofocus, isTrue);
    expect(
      tester.getBottomRight(find.byKey(const Key('home-overview-panel'))).dy,
      lessThanOrEqualTo(tester.view.physicalSize.height),
    );

    await tester.tap(find.byKey(const Key('home-add-server-button')));
    await tester.pump();
    expect(addServerCount, 1);
  });

  testWidgets('Home dashboard shows the directory below the primary action', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const <Server>[_server],
          selectedServer: _server,
          projects: <Project>[_project, _deployedProject],
        ),
      ),
    );

    final overviewTop = tester
        .getTopLeft(find.byKey(const Key('home-overview-panel')))
        .dy;
    final serversTop = tester
        .getTopLeft(find.byKey(const Key('home-servers-card')))
        .dy;

    expect(overviewTop, lessThan(serversTop));
    expect(find.text('Projects on Prod-01'), findsOneWidget);
    expect(find.text('1 server saved on this computer.'), findsOneWidget);
    expect(find.text('203.0.113.10 - Ubuntu 24.04'), findsOneWidget);
    expect(find.text('Web app - alpha.example.com'), findsOneWidget);
    expect(find.text('Worker'), findsOneWidget);
    expect(find.text('2 projects'), findsOneWidget);
    expect(find.text('Databases'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Domains'), findsOneWidget);
    expect(find.text('Not deployed yet'), findsOneWidget);
    expect(find.text('Deployed 2026-01-02'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const Key('home-add-server-button')),
          )
          .autofocus,
      isFalse,
    );
  });

  testWidgets('Home dashboard project list entries open the chosen project', (
    WidgetTester tester,
  ) async {
    String? openedProjectId;
    var createCount = 0;
    var addServerCount = 0;

    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const <Server>[_server],
          selectedServer: _server,
          projects: const <Project>[_project],
          onOpenProject: (projectId) => openedProjectId = projectId,
          onCreateProject: () => createCount += 1,
          onAddServer: () => addServerCount += 1,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('home-project-project-1')));
    await tester.pump();
    expect(openedProjectId, 'project-1');

    await tester.tap(find.byKey(const Key('home-new-project-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('home-add-server-button')));
    await tester.pump();

    expect(createCount, 1);
    expect(addServerCount, 1);
  });

  testWidgets('Home dashboard server rows select and manage servers', (
    WidgetTester tester,
  ) async {
    final selectedServerIds = <String>[];
    var manageCount = 0;

    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const <Server>[_server, _secondServer],
          selectedServer: _server,
          projects: const <Project>[_project],
          onSelectServer: selectedServerIds.add,
          onOpenServerManagement: () => manageCount += 1,
        ),
      ),
    );

    expect(find.text('2 servers saved on this computer.'), findsOneWidget);
    expect(find.text('198.51.100.4'), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-server-server-2')));
    await tester.pump();
    expect(selectedServerIds, <String>['server-2']);
    expect(manageCount, 0);

    await tester.tap(find.byKey(const Key('home-server-manage-server-2')));
    await tester.pump();
    expect(selectedServerIds, <String>['server-2', 'server-2']);
    expect(manageCount, 1);
    expect(find.byTooltip('Manage server'), findsNWidgets(2));
  });

  testWidgets('Home dashboard opens management when selection is fixed', (
    WidgetTester tester,
  ) async {
    var manageCount = 0;

    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const <Server>[_server, _secondServer],
          selectedServer: _server,
          onOpenServerManagement: () => manageCount += 1,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('home-server-server-1')));
    await tester.pump();
    expect(manageCount, 1);

    final unselectedRow = tester.widget<InkWell>(
      find
          .descendant(
            of: find.byKey(const Key('home-server-server-2')),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(unselectedRow.onTap, isNull);
  });

  testWidgets('Home dashboard filters long server and project lists', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final servers = <Server>[
      for (var index = 0; index < homeServerFilterThreshold; index++)
        Server(
          id: 'server-$index',
          name: 'Server $index',
          host: '203.0.113.$index',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.password,
        ),
    ];
    final projects = <Project>[
      for (var index = 0; index < homeProjectFilterThreshold; index++)
        Project(
          id: 'project-$index',
          serverId: 'server-0',
          name: 'Project $index',
          type: 'app',
          gitUrl: 'https://github.com/example/project-$index',
          primaryDomain: 'project-$index.example.com',
        ),
    ];

    await tester.pumpWidget(
      _wrap(
        _home(
          servers: servers,
          selectedServer: servers.first,
          projects: projects,
          onSelectServer: (_) {},
        ),
      ),
    );

    expect(find.byKey(const Key('home-server-filter-field')), findsOneWidget);
    expect(find.byKey(const Key('home-project-filter-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('home-server-filter-field')),
      '203.0.113.3',
    );
    await tester.pump();
    expect(find.byKey(const Key('home-server-server-3')), findsOneWidget);
    expect(find.byKey(const Key('home-server-server-2')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('home-server-filter-field')),
      'nothing',
    );
    await tester.pump();
    expect(find.byKey(const Key('home-servers-filter-empty')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('home-project-filter-field')),
      'project-4.example.com',
    );
    await tester.pump();
    expect(find.byKey(const Key('home-project-project-4')), findsOneWidget);
    expect(find.byKey(const Key('home-project-project-5')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('home-project-filter-field')),
      'nothing',
    );
    await tester.pump();
    expect(find.byKey(const Key('home-projects-filter-empty')), findsOneWidget);
  });

  testWidgets('Home dashboard explains a server without projects', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const <Server>[_secondServer],
          selectedServer: _secondServer,
        ),
      ),
    );

    expect(find.text('No projects yet'), findsOneWidget);
    expect(
      find.textContaining('Create a project to configure a web app'),
      findsOneWidget,
    );
    expect(find.text('Projects on Staging-EU'), findsOneWidget);
    expect(
      tester.widget<AppStatusBadge>(find.byType(AppStatusBadge).first).label,
      '0 projects',
    );
  });

  testWidgets('Home dashboard delete notice variants render and dismiss', (
    WidgetTester tester,
  ) async {
    var dismissCount = 0;

    await tester.pumpWidget(
      _wrap(
        _home(
          deletedProjectNotice: const DeletedProjectNotice(
            projectName: 'Alpha App',
            warnings: <String>[],
          ),
          onDismiss: () => dismissCount += 1,
        ),
      ),
    );

    expect(find.text('Project deleted'), findsOneWidget);
    expect(
      find.textContaining('You are back on the Home screen'),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('home-delete-notice-dismiss-button')),
    );
    await tester.pump();
    expect(dismissCount, 1);

    await tester.pumpWidget(
      _wrap(
        _home(
          deletedProjectNotice: const DeletedProjectNotice(
            projectName: 'Beta App',
            warnings: <String>['remote cleanup pending'],
          ),
        ),
      ),
    );

    expect(find.text('Project deleted with follow-up items'), findsOneWidget);
    expect(find.text('Remote cleanup warnings:'), findsOneWidget);
    expect(find.text('- remote cleanup pending'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(
        _home(
          deletedProjectNotice: const DeletedProjectNotice(
            projectName: 'Gamma App',
            warnings: <String>['server unavailable'],
            completed: false,
          ),
        ),
      ),
    );

    expect(find.text('Project cleanup needs attention'), findsOneWidget);
    expect(
      find.text(
        '"Gamma App" is hidden from normal use until cleanup succeeds.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Home dashboard retries and explicitly forgets cleanup records', (
    WidgetTester tester,
  ) async {
    var retryCount = 0;
    var removeCount = 0;
    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const <Server>[_server],
          selectedServer: _server,
          recoveries: <ProjectDeletionRecoveryRecord>[_recovery()],
          onRetryProjectCleanup: (_) async => retryCount += 1,
          onRemoveLocalRecord: (_) async => removeCount += 1,
        ),
      ),
    );

    expect(find.text('Cleanup required for Pending App'), findsOneWidget);
    expect(find.textContaining('Connection interrupted.'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('home-project-cleanup-retry-project-pending')),
    );
    await tester.pumpAndSettle();
    expect(retryCount, 1);

    await tester.tap(
      find.byKey(const Key('home-project-cleanup-forget-project-pending')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('home-project-cleanup-forget-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(removeCount, 0);

    await tester.tap(
      find.byKey(const Key('home-project-cleanup-forget-project-pending')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('home-project-cleanup-forget-confirm-button')),
    );
    await tester.pumpAndSettle();
    expect(removeCount, 1);
  });

  testWidgets(
    'Home dashboard keeps cleanup errors visible and disables absent actions',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          _home(
            servers: const <Server>[_server],
            selectedServer: _server,
            recoveries: <ProjectDeletionRecoveryRecord>[_recovery()],
            onRetryProjectCleanup: (_) async {
              throw StateError('server still unavailable');
            },
          ),
        ),
      );

      await tester.tap(
        find.byKey(const Key('home-project-cleanup-retry-project-pending')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('home-project-cleanup-error-project-pending')),
        findsOneWidget,
      );
      final forgetButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('home-project-cleanup-forget-project-pending')),
      );
      expect(forgetButton.onPressed, isNull);
    },
  );

  testWidgets('Home dashboard ignores cleanup taps while one is running', (
    WidgetTester tester,
  ) async {
    var retryCount = 0;
    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const <Server>[_server],
          selectedServer: _server,
          recoveries: <ProjectDeletionRecoveryRecord>[_recovery()],
          onRetryProjectCleanup: (_) async {
            retryCount += 1;
            await Future<void>.delayed(const Duration(milliseconds: 40));
          },
        ),
      ),
    );

    await tester.tap(
      find.byKey(const Key('home-project-cleanup-retry-project-pending')),
    );
    await tester.pump();
    expect(find.text('Retrying...'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('home-project-cleanup-retry-project-pending')),
    );
    await tester.pumpAndSettle();
    expect(retryCount, 1);
  });

  testWidgets('Home dashboard shows the telemetry nag once and answers it', (
    WidgetTester tester,
  ) async {
    var shareCount = 0;
    var dismissCount = 0;

    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const <Server>[_server],
          selectedServer: _server,
          nagVisible: true,
          onShareNag: () => shareCount += 1,
          onDismissNag: () => dismissCount += 1,
        ),
      ),
    );

    expect(find.byKey(const Key('home-telemetry-nag-card')), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-telemetry-nag-share-button')));
    await tester.pump();
    expect(shareCount, 1);

    await tester.tap(
      find.byKey(const Key('home-telemetry-nag-dismiss-button')),
    );
    await tester.pump();
    expect(dismissCount, 1);
  });

  testWidgets('Home dashboard hides the telemetry nag by default', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(_home(servers: const <Server>[_server], selectedServer: _server)),
    );

    expect(find.byKey(const Key('home-telemetry-nag-card')), findsNothing);
  });

  testWidgets('Home dashboard window title reflects the server selection', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_wrap(_home()));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      _wrap(_home(servers: const <Server>[_server], selectedServer: _server)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home dashboard badges a server with incomplete setup', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const <Server>[_server, _secondServer],
          selectedServer: _secondServer,
          pendingSetupServerIds: const {'server-2'},
        ),
      ),
    );

    expect(find.text('Setup incomplete'), findsOneWidget);
    expect(find.text('No projects yet'), findsNothing);
  });

  testWidgets('Home dashboard resumes setup from the detail pane', (
    WidgetTester tester,
  ) async {
    var retriedServerId = 'unset';
    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const <Server>[_secondServer],
          selectedServer: _secondServer,
          pendingSetupServerIds: const {'server-2'},
          onRetryServerSetup: (serverId) => retriedServerId = serverId,
        ),
      ),
    );

    expect(find.text('Finish setting up Staging-EU'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('home-projects-resume-setup-button')),
    );
    expect(retriedServerId, 'server-2');
  });

  testWidgets('Home dashboard hides the resume action without a retry entry', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const <Server>[_secondServer],
          selectedServer: _secondServer,
          pendingSetupServerIds: const {'server-2'},
        ),
      ),
    );

    expect(find.text('Finish setting up Staging-EU'), findsOneWidget);
    expect(
      find.byKey(const Key('home-projects-resume-setup-button')),
      findsNothing,
    );
  });

  testWidgets('Home dashboard disables new project while setup is pending', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const <Server>[_server, _secondServer],
          selectedServer: _secondServer,
          pendingSetupServerIds: const {'server-2'},
        ),
      ),
    );

    final createButton = tester.widget<FilledButton>(
      find.byKey(const Key('home-new-project-button')),
    );
    expect(createButton.onPressed, isNull);

    await tester.pumpWidget(
      _wrap(
        _home(
          servers: const <Server>[_server, _secondServer],
          selectedServer: _server,
          pendingSetupServerIds: const {'server-2'},
        ),
      ),
    );

    final enabledButton = tester.widget<FilledButton>(
      find.byKey(const Key('home-new-project-button')),
    );
    expect(enabledButton.onPressed, isNotNull);
  });
}
