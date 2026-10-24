import 'package:flutter_test/flutter_test.dart';

import '_support/project_workspace_harness.dart';

/// project workspace PostgreSQL catalog.
///
/// One of sixteen files T-3.6.1 split `project_workspace_test.dart` into. That
/// file was 16,030 lines holding 230 tests in two groups: a directory's worth
/// of tests wearing a filename, which nobody could hold in view, so a coverage
/// gap in it was invisible by construction.
///
/// Fixtures and pump helpers live in
/// `_support/project_workspace_harness.dart`.
///
/// Seeds the project list so settings tests control the known-slug set.
class _SeededProjectListNotifier extends ProjectListNotifier {
  _SeededProjectListNotifier(this.projects);

  final List<Project> projects;

  @override
  List<Project> build() => projects;
}

/// Scripts separate dry-run and apply answers for one postgres operation.
///
/// The shared fakes answer by operation id, but normalize calls the same
/// operation twice with different `dry_run` params, so this fake switches
/// on the param instead.
class _DryRunAwarePostgresSshService extends LegacySshService {
  _DryRunAwarePostgresSshService({
    required this.projectListResponse,
    required this.operationId,
    required this.dryRunResponse,
    required this.applyResponse,
  }) : super(taskClient: NoopTaskClient()) {
    registerManagedPostgresCatalogSeed(projectListResponse);
  }

  final Map<String, dynamic> projectListResponse;
  final String operationId;
  final Map<String, dynamic> dryRunResponse;
  final Map<String, dynamic> applyResponse;
  final List<Map<String, dynamic>> callLog = <Map<String, dynamic>>[];

  /// Calls for [operationId] split by their `dry_run` param.
  Iterable<Map<String, dynamic>> callsFor({required bool dryRun}) {
    return callLog.where(
      (call) =>
          call['workflow_id'] == 'postgres' &&
          call['operation_id'] == operationId &&
          (call['params'] as Map?)?['dry_run'] == dryRun,
    );
  }

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    callLog.add(<String, dynamic>{
      'workflow_id': workflowId,
      'operation_id': operationId,
      'params': params == null ? null : Map<String, dynamic>.from(params),
    });
    if (workflowId == 'postgres' && operationId == 'project_list') {
      return projectListResponse;
    }
    if (workflowId == 'postgres' && operationId == this.operationId) {
      return params?['dry_run'] == true ? dryRunResponse : applyResponse;
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('project workspace PostgreSQL catalog', () {
    testWidgets(
      'Database tab keeps saved catalog local when the selected server config changes',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'host': '10.9.0.9',
            'port': 5432,
            'databases': <String>['regs_db'],
            'users': <Map<String, dynamic>>[],
          },
        );
        final initialUpdatedAt = DateTime(2026, 4, 23, 13, 0);
        final updatedUpdatedAt = initialUpdatedAt.add(
          const Duration(minutes: 1),
        );
        final initialServer = Server(
          id: serverWithDatabaseEnabled.id,
          name: serverWithDatabaseEnabled.name,
          host: serverWithDatabaseEnabled.host,
          port: serverWithDatabaseEnabled.port,
          sshUser: serverWithDatabaseEnabled.sshUser,
          authMethod: serverWithDatabaseEnabled.authMethod,
          serviceDatabaseEnabled:
              serverWithDatabaseEnabled.serviceDatabaseEnabled,
          serviceEmailEnabled: serverWithDatabaseEnabled.serviceEmailEnabled,
          serviceDomainEnabled: serverWithDatabaseEnabled.serviceDomainEnabled,
          updatedAt: initialUpdatedAt,
        );
        final updatedServer = Server(
          id: initialServer.id,
          name: initialServer.name,
          host: initialServer.host,
          port: initialServer.port,
          sshUser: initialServer.sshUser,
          authMethod: initialServer.authMethod,
          serviceDatabaseEnabled: initialServer.serviceDatabaseEnabled,
          serviceEmailEnabled: initialServer.serviceEmailEnabled,
          serviceDomainEnabled: initialServer.serviceDomainEnabled,
          updatedAt: updatedUpdatedAt,
        );

        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(initialServer),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();

        expect(find.text('regs_db'), findsWidgets);
        expect(sshService.countCalls('postgres', 'project_list'), 0);

        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(updatedServer),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();

        expect(find.text('regs_db'), findsWidgets);
        expect(sshService.countCalls('postgres', 'project_list'), 0);
      },
    );

    testWidgets(
      'PostgreSQL delete selected database triggers the delete workflow',
      (WidgetTester tester) async {
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'alpha_user',
                'database': 'alpha_db',
                'access_mode': 'read_write',
              },
            ],
          },
        );
        await pumpProjectWorkspace(
          tester,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();

        expect(find.text('Delete database'), findsOneWidget);
        expect(find.byKey(const Key('database-delete-button')), findsOneWidget);

        await tester.tap(find.byKey(const Key('database-delete-button')));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Delete PostgreSQL database "alpha_db" and remove its managed users?',
          ),
          findsOneWidget,
        );

        await tester.tap(find.widgetWithText(FilledButton, 'Delete').last);
        await tester.pumpAndSettle();

        expect(sshService.countCalls('postgres', 'project_delete_database'), 1);
        final deleteCall = sshService.callLog.lastWhere(
          (call) =>
              call['workflow_id'] == 'postgres' &&
              call['operation_id'] == 'project_delete_database',
        );
        final params = deleteCall['params'] as Map<String, dynamic>?;
        final settings = params?['settings'] as Map?;
        expect(settings?['database_name'], 'alpha_db');
      },
    );

    testWidgets('PostgreSQL delete database sends the logical database name', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['dd_regs_v3_main'],
          'users': <Map<String, dynamic>>[
            <String, dynamic>{
              'username': 'dd_regs_v3_main_user',
              'database': 'dd_regs_v3_main',
              'access_mode': 'read_write',
            },
          ],
        },
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-delete-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete').last);
      await tester.pumpAndSettle();

      expect(sshService.countCalls('postgres', 'project_delete_database'), 1);
      final deleteCall = sshService.callLog.lastWhere(
        (call) =>
            call['workflow_id'] == 'postgres' &&
            call['operation_id'] == 'project_delete_database',
      );
      final params = deleteCall['params'] as Map<String, dynamic>?;
      final settings = params?['settings'] as Map?;
      expect(settings?['database_name'], 'main');
    });

    testWidgets('Database requests carry the known project slugs', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['dd_regs_v3_main'],
          'users': <Map<String, dynamic>>[],
        },
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          projectListProvider.overrideWith(
            () => _SeededProjectListNotifier(<Project>[
              projectFixture(
                id: 'project-runtime',
                name: 'Regs v3',
                serverId: serverWithDatabaseEnabled.id,
                primaryDomain: 'regs.example.com',
              ),
              projectFixture(
                id: 'project-shop-api',
                name: 'Shop API',
                serverId: serverWithDatabaseEnabled.id,
                primaryDomain: 'shop.example.com',
              ),
              projectFixture(
                id: 'project-elsewhere',
                name: 'Elsewhere',
                serverId: 'server-elsewhere',
                primaryDomain: 'else.example.com',
              ),
            ]),
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-delete-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete').last);
      await tester.pumpAndSettle();

      final deleteCall = sshService.callLog.firstWhere(
        (call) => call['operation_id'] == 'project_delete_database',
      );
      final settings =
          (deleteCall['params'] as Map<String, dynamic>)['settings']
              as Map<String, dynamic>;
      expect(settings['known_project_slugs'], <String>['regs-v3', 'shop-api']);
    });

    testWidgets(
      'Databases card shows a novice-friendly empty state when no databases exist',
      (WidgetTester tester) async {
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>[],
            'users': <Map<String, dynamic>>[],
          },
        );
        await pumpProjectWorkspace(
          tester,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();

        final actionsCard = find.byKey(const Key('database-actions-card'));
        expect(
          find.descendant(
            of: actionsCard,
            matching: find.text('No databases created yet.'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: actionsCard,
            matching: find.text('Create your first database to continue.'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Delete and restore actions stay visible but disabled when no database is selected',
      (WidgetTester tester) async {
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db', 'beta_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'alpha_user',
                'database': 'alpha_db',
                'access_mode': 'read_write',
              },
            ],
          },
        );
        await pumpProjectWorkspace(
          tester,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('database-actions-select-database-dropdown')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Select a database').last);
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('database-delete-button')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('database-restore-local-sql-button')),
              )
              .onPressed,
          isNull,
        );
        expect(
          find.text('Select a database before deleting it.'),
          findsOneWidget,
        );
        expect(
          find.text('Select a database before restoring a .sql file.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('Delete selected database dialog cancel keeps the database', (
      WidgetTester tester,
    ) async {
      final sshService = OperationOverrideDatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        operationResponses: const <String, Map<String, dynamic>>{},
      );

      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-delete-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pumpAndSettle();

      expect(
        sshService.callLog.any(
          (call) =>
              call['workflow_id'] == 'postgres' &&
              call['operation_id'] == 'project_delete_database',
        ),
        isFalse,
      );
    });

    testWidgets(
      'PostgreSQL database tab no longer exposes add-to-web-app wiring',
      (WidgetTester tester) async {
        final projectNotifier = RecordingDatabaseWiringProjectNotifier(
          selectedProject,
        );
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'alpha_user',
                'database': 'alpha_db',
                'access_mode': 'read_write',
              },
            ],
          },
        );
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        await AppEnvironmentVariableRepository(database).replaceForProject(
          projectId: selectedProject.id,
          rows: const [
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_PASSWORD',
              value: 'alpha-secret',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_USER',
              value: 'alpha_user',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_NAME',
              value: 'alpha_db',
            ),
          ],
        );
        final envRepository =
            DelegatingThrowingAppEnvironmentVariableRepository(
              AppEnvironmentVariableRepository(database),
            );
        addTearDown(() async => database.close());

        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            projectListProvider.overrideWith(() => projectNotifier),
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
            appEnvironmentVariableRepositoryProvider.overrideWithValue(
              envRepository,
            ),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('database-add-postgres-webapp-button')),
          findsNothing,
        );
        expect(
          find.textContaining('Environment variables editor'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Could not save PostgreSQL app environment variables:',
          ),
          findsNothing,
        );
      },
    );

    testWidgets('Database dropdown changes the selected database', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db', 'beta_db'],
          'users': <Map<String, dynamic>>[
            <String, dynamic>{
              'username': 'alpha_user',
              'database': 'alpha_db',
              'access_mode': 'read_write',
            },
            <String, dynamic>{
              'username': 'beta_user',
              'database': 'beta_db',
              'access_mode': 'read_write',
            },
          ],
        },
      );

      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('database-actions-select-database-dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('beta_db').last);
      await tester.pumpAndSettle();

      expect(find.text('Selected: beta_db'), findsOneWidget);
      expect(
        find.text('Select the database you want to work with'),
        findsOneWidget,
      );
    });

    testWidgets('Project access card shows linked project network groups', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => database.close());
      final server = serverWithDatabaseEnabled;
      final ownerProject = projectFixture(
        id: 'project-owner-linked-network',
        name: 'Owner project',
        serverId: server.id,
        primaryDomain: 'owner-linked.example.com',
      );
      final consumerProject = projectFixture(
        id: 'project-consumer-linked-network',
        name: 'Consumer project',
        serverId: server.id,
        primaryDomain: 'consumer-linked.example.com',
      );
      final projectRepository = ProjectRepository(database);
      await projectRepository.createProject(
        projectRecord(ownerProject, serverId: server.id, isActive: true),
      );
      await projectRepository.createProject(
        projectRecord(consumerProject, serverId: server.id),
      );
      final group = await ProjectNetworkTrustRepository(database).linkProjects(
        serverId: server.id,
        projectIds: <String>[ownerProject.id, consumerProject.id],
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          projectListProvider.overrideWith(
            () => StaticProjectListNotifier([ownerProject, consumerProject]),
          ),
          selectedProjectProvider.overrideWithValue(ownerProject),
          selectedServerProvider.overrideWithValue(server),
          sshServiceProvider.overrideWithValue(
            SharingDatabaseWorkflowSshService(
              postgresProjectListBySlug: const {
                'owner-project': {
                  'status': 'success',
                  'service_status': {'configured': true, 'running': true},
                  'databases': ['owner_db'],
                  'users': <dynamic>[],
                },
              },
            ),
          ),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('database-tab-scroll')),
        const Offset(0, -1200),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('database-owner-sharing-card')),
        findsOneWidget,
      );
      expect(find.text('Linked projects'), findsWidgets);
      expect(find.text('Linked with Consumer project'), findsOneWidget);
      expect(find.text(group.networkName), findsOneWidget);
      expect(
        find.byKey(const Key('database-owner-add-share-button')),
        findsNothing,
      );
    });

    testWidgets('Project access card explains unlinked project state', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => database.close());
      final server = serverWithDatabaseEnabled;
      final ownerProject = projectFixture(
        id: 'project-owner-unlinked-network',
        name: 'Owner project',
        serverId: server.id,
        primaryDomain: 'owner-unlinked.example.com',
      );
      await ProjectRepository(database).createProject(
        projectRecord(ownerProject, serverId: server.id, isActive: true),
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          projectListProvider.overrideWith(
            () => StaticProjectListNotifier([ownerProject]),
          ),
          selectedProjectProvider.overrideWithValue(ownerProject),
          selectedServerProvider.overrideWithValue(server),
          sshServiceProvider.overrideWithValue(
            SharingDatabaseWorkflowSshService(
              postgresProjectListBySlug: const {
                'owner-project': {
                  'status': 'success',
                  'service_status': {'configured': true, 'running': true},
                  'databases': ['owner_db'],
                  'users': <dynamic>[],
                },
              },
            ),
          ),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('database-tab-scroll')),
        const Offset(0, -1200),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('This project is not linked to another project'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('database-owner-sharing-card')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Deploy Dash no longer creates a separate'),
        findsNothing,
      );
    });

    testWidgets('Database tab surfaces linked project loading failures', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => database.close());
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
          projectNetworkTrustRepositoryProvider.overrideWithValue(
            ThrowingProjectNetworkTrustRepository(database),
          ),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('database-error-card')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('database-error-text'))).data,
        'Could not load linked projects: '
        'Bad state: linked project lookup failed',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('database-error-retry-button')),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('Legacy shared database controls stay hidden', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => database.close());
      final server = serverWithDatabaseEnabled;
      final ownerProject = projectFixture(
        id: 'project-owner-legacy-sharing',
        name: 'Owner project',
        serverId: server.id,
        primaryDomain: 'owner-legacy.example.com',
      );
      final consumerProject = projectFixture(
        id: 'project-consumer-legacy-sharing',
        name: 'Consumer project',
        serverId: server.id,
        primaryDomain: 'consumer-legacy.example.com',
      );
      final projectRepository = ProjectRepository(database);
      await projectRepository.createProject(
        projectRecord(ownerProject, serverId: server.id),
      );
      await projectRepository.createProject(
        projectRecord(consumerProject, serverId: server.id, isActive: true),
      );
      final accessRepository = ProjectDatabaseAccessRepository(database);
      final grant = await accessRepository.upsertGrant(
        serverId: server.id,
        ownerProjectId: ownerProject.id,
        consumerProjectId: consumerProject.id,
      );
      await accessRepository.upsertUser(
        ProjectDatabaseAccessUserRecord(
          id: 'legacy-shared-user',
          grantId: grant.id,
          engine: 'postgres',
          databaseName: 'owner_db',
          username: 'legacy_reader',
          accessMode: 'read_only',
          createdAt: DateTime.utc(2026, 4, 23),
          updatedAt: DateTime.utc(2026, 4, 23),
        ),
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          projectListProvider.overrideWith(
            () => StaticProjectListNotifier([ownerProject, consumerProject]),
          ),
          selectedProjectProvider.overrideWithValue(consumerProject),
          selectedServerProvider.overrideWithValue(server),
          sshServiceProvider.overrideWithValue(
            SharingDatabaseWorkflowSshService(
              postgresProjectListBySlug: const {
                'consumer-project': {
                  'status': 'success',
                  'service_status': {'configured': true, 'running': true},
                  'databases': <dynamic>[],
                  'users': <dynamic>[],
                },
              },
            ),
          ),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('database-tab-scroll')),
        const Offset(0, -1200),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('database-shared-create-user-button')),
        findsNothing,
      );
      expect(find.widgetWithText(OutlinedButton, 'Delete user'), findsNothing);
      expect(find.text('legacy_reader'), findsNothing);
      expect(
        find.textContaining('Create database users in the project that owns'),
        findsNothing,
      );
    });

    testWidgets(
      'Row actions show scoped busy state without locking top actions',
      (WidgetTester tester) async {
        final sshService = DelayedOperationDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'alpha_user',
                'database': 'alpha_db',
                'access_mode': 'read_write',
              },
              <String, dynamic>{
                'username': 'beta_user',
                'database': 'alpha_db',
                'access_mode': 'read_only',
              },
            ],
          },
          delayedOperationId: 'project_delete_user',
        );
        await pumpProjectWorkspace(
          tester,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const Key('database-tab-scroll')),
          const Offset(0, -700),
        );
        await tester.pumpAndSettle();

        final databaseScroll = find
            .descendant(
              of: find.byKey(const Key('database-tab-scroll')),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.widgetWithText(OutlinedButton, 'Delete user').first,
          300,
          scrollable: databaseScroll,
        );
        final removeButton = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Delete user').first,
        );
        expect(removeButton.onPressed, isNotNull);
        removeButton.onPressed!.call();
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Delete user'),
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            'Delete database user "alpha_user"? This removes the login and its access to this project\'s databases.',
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(FilledButton, 'Delete'),
          ),
        );
        await sshService.operationStarted.future;
        await tester.pump();

        expect(find.text('Deleting...'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.byKey(const Key('database-link-button')),
          -300,
          scrollable: databaseScroll,
        );
        final createButton = tester.widget<OutlinedButton>(
          find.byKey(const Key('database-link-button')),
        );
        expect(createButton.onPressed, isNotNull);

        sshService.releaseOperation.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      },
    );

    testWidgets(
      'Managed database build tolerates a missing project selection',
      (WidgetTester tester) async {
        await pumpProjectWorkspace(
          tester,
          overrides: [
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('database-tab-scroll')), findsOneWidget);
      },
    );

    testWidgets('Managed database build schedules sqlite project loading', (
      WidgetTester tester,
    ) async {
      final sqliteNotifier = RecordingProjectSqliteDatabasesNotifier();
      await pumpProjectWorkspace(
        tester,
        overrides: [
          projectSqliteDatabasesProvider.overrideWith(() => sqliteNotifier),
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      expect(sqliteNotifier.loadedProjects, contains(selectedProject.id));
    });

    testWidgets('PostgreSQL refresh button reloads managed database state', (
      WidgetTester tester,
    ) async {
      final sshService = DelayedProjectListDatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'engine_version': '16.4',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        delayedCallNumber: 99,
      );

      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );
      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-postgres-tab')));
      await tester.pumpAndSettle();

      expect(find.text('PostgreSQL 16.4'), findsNothing);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('PostgreSQL 16.4'), findsOneWidget);
      expect(sshService.projectListCalls, 1);
    });

    testWidgets(
      'Managed database rebind does not refresh server state automatically',
      (WidgetTester tester) async {
        const reboundServer = Server(
          id: 'server-database-rebound',
          name: 'srv.database-rebound.local',
          host: '192.168.1.41',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.password,
          serviceDatabaseEnabled: true,
          serviceEmailEnabled: false,
          serviceDomainEnabled: false,
        );
        final serverCatalog = MutableServerCatalogNotifier(
          ServerCatalogState(
            isLoading: false,
            onboardingComplete: true,
            servers: const <Server>[serverWithDatabaseEnabled, reboundServer],
            selectedServerId: serverWithDatabaseEnabled.id,
            onboardingStep: 'connected',
          ),
        );
        final sshService = DelayedProjectListDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'engine_version': '16.4',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db'],
            'users': <Map<String, dynamic>>[],
          },
          delayedCallNumber: 2,
        );

        await pumpProjectWorkspace(
          tester,
          overrides: [
            serverCatalogProvider.overrideWith(() => serverCatalog),
            selectedProjectProvider.overrideWithValue(selectedProject),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );
        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('database-type-postgres-tab')));
        await tester.pumpAndSettle();

        serverCatalog.setSelectedServer(reboundServer);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(sshService.projectListCalls, 0);
        expect(sshService.projectListStarted.isCompleted, isFalse);
        expect(
          find.byKey(const Key('database-managed-loading-card')),
          findsNothing,
        );
      },
    );
    testWidgets('Normalize action enables only when a database is selected', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('database-normalize-button')),
            )
            .onPressed,
        isNotNull,
      );

      await tester.tap(
        find.byKey(const Key('database-actions-select-database-dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select a database').last);
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('database-normalize-button')),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets(
      'Normalize dry run shows the report and cancel applies nothing',
      (WidgetTester tester) async {
        final sshService = _DryRunAwarePostgresSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'alpha_user',
                'database': 'alpha_db',
                'access_mode': 'read_write',
              },
            ],
          },
          operationId: 'project_normalize_database',
          dryRunResponse: const <String, dynamic>{
            'status': 'success',
            'read_write_users': <String>['alpha_user'],
            'read_only_users': <String>['alpha_reader'],
            'roles_losing_connect': <String>['stray_role'],
          },
          applyResponse: const <String, dynamic>{'status': 'success'},
        );
        await pumpProjectWorkspace(
          tester,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('database-normalize-button')));
        await tester.pumpAndSettle();

        expect(sshService.callsFor(dryRun: true), hasLength(1));
        expect(find.text('Normalize database isolation'), findsOneWidget);
        final normalizeDialog = find.ancestor(
          of: find.byKey(const Key('database-normalize-confirm-button')),
          matching: find.byType(Dialog),
        );
        expect(
          find.descendant(
            of: normalizeDialog,
            matching: find.text('alpha_user'),
          ),
          findsOneWidget,
        );
        expect(find.text('alpha_reader'), findsOneWidget);
        expect(find.text('stray_role'), findsOneWidget);

        await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
        await tester.pumpAndSettle();

        expect(sshService.callsFor(dryRun: false), isEmpty);
      },
    );

    testWidgets('Normalize confirm applies the reviewed plan', (
      WidgetTester tester,
    ) async {
      final sshService = _DryRunAwarePostgresSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[
            <String, dynamic>{
              'username': 'alpha_user',
              'database': 'alpha_db',
              'access_mode': 'read_write',
            },
          ],
        },
        operationId: 'project_normalize_database',
        dryRunResponse: const <String, dynamic>{
          'status': 'success',
          'read_write_users': <String>['alpha_user'],
          'read_only_users': <String>['alpha_reader'],
          'roles_losing_connect': <String>['stray_role'],
        },
        applyResponse: const <String, dynamic>{
          'status': 'success',
          'msg': 'Database isolation normalized.',
        },
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-normalize-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('database-normalize-confirm-button')),
      );
      await tester.pumpAndSettle();

      final applyCalls = sshService.callsFor(dryRun: false).toList();
      expect(applyCalls, hasLength(1));
      final settings =
          (applyCalls.single['params'] as Map<String, dynamic>)['settings']
              as Map<String, dynamic>;
      expect(settings['database_name'], 'alpha_db');
      expect(settings['confirmed_normalize_users'], <String>[
        'alpha_user',
        'alpha_reader',
      ]);
      expect(settings['confirmed_lost_connect_roles'], <String>['stray_role']);
      expect(find.text('Database isolation normalized.'), findsOneWidget);
      expect(find.byKey(const Key('database-error-card')), findsNothing);
    });

    testWidgets('Normalize dry-run failure surfaces the backend message', (
      WidgetTester tester,
    ) async {
      final sshService = _DryRunAwarePostgresSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        operationId: 'project_normalize_database',
        dryRunResponse: const <String, dynamic>{
          'status': 'error',
          'msg': 'Database is locked.',
          'details': 'terminate backends first',
        },
        applyResponse: const <String, dynamic>{'status': 'success'},
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-normalize-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('database-error-card')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('database-error-text'))).data,
        'Database is locked.',
      );
      expect(find.text('terminate backends first'), findsOneWidget);
      expect(find.text('Normalize database isolation'), findsNothing);
      expect(sshService.callsFor(dryRun: false), isEmpty);
    });

    testWidgets('Normalize dry-run failure without details still explains', (
      WidgetTester tester,
    ) async {
      final sshService = _DryRunAwarePostgresSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        operationId: 'project_normalize_database',
        dryRunResponse: const <String, dynamic>{'status': 'error'},
        applyResponse: const <String, dynamic>{'status': 'success'},
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-normalize-button')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('database-error-text'))).data,
        'Could not load the normalization plan.',
      );
    });

    testWidgets('Normalize shows busy state while the dry run is in flight', (
      WidgetTester tester,
    ) async {
      final sshService = DelayedOperationDatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        delayedOperationId: 'project_normalize_database',
        delayedResponse: const <String, dynamic>{
          'status': 'success',
          'read_write_users': <String>['alpha_user'],
          'read_only_users': <String>[],
          'roles_losing_connect': <String>[],
        },
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-normalize-button')));
      await sshService.operationStarted.future;
      await tester.pump();

      expect(find.text('Normalizing...'), findsOneWidget);

      sshService.releaseOperation.complete();
      await tester.pumpAndSettle();

      expect(find.text('Normalize database isolation'), findsOneWidget);
    });

    testWidgets('Normalize handles an empty plan', (WidgetTester tester) async {
      final sshService = _DryRunAwarePostgresSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        operationId: 'project_normalize_database',
        dryRunResponse: const <String, dynamic>{'status': 'success'},
        applyResponse: const <String, dynamic>{'status': 'success'},
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-normalize-button')));
      await tester.pumpAndSettle();

      expect(find.text('No users to normalize.'), findsOneWidget);
      expect(find.text('No roles lose access.'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('database-normalize-confirm-button')),
      );
      await tester.pumpAndSettle();

      final applyCalls = sshService.callsFor(dryRun: false).toList();
      expect(applyCalls, hasLength(1));
      final settings =
          (applyCalls.single['params'] as Map<String, dynamic>)['settings']
              as Map<String, dynamic>;
      expect(settings['confirmed_normalize_users'], <String>[]);
      expect(settings['confirmed_lost_connect_roles'], <String>[]);
    });

    testWidgets('Normalize disposes quietly when the tab closes mid-flight', (
      WidgetTester tester,
    ) async {
      final sshService = DelayedOperationDatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        delayedOperationId: 'project_normalize_database',
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-normalize-button')));
      await sshService.operationStarted.future;

      await tester.pumpWidget(Container());
      sshService.releaseOperation.complete();
      await tester.pumpAndSettle();
    });
  }, skip: !sqliteAvailable);
}
