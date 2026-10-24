import 'package:flutter_test/flutter_test.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/services/backup_logic.dart';

import '../../../_support/fake_analytics_service.dart';
import '_support/project_workspace_harness.dart';

/// Holds one backup-scope read so tests can move the workspace selection.
class _DelayedBackupRepository extends BackupRepository {
  _DelayedBackupRepository(super.database);

  bool delayNextScopeLoad = false;
  Object? delayedScopeLoadError;
  final Completer<void> scopeLoadStarted = Completer<void>();
  final Completer<void> releaseScopeLoad = Completer<void>();

  /// Exposes the stale-bind boundary without delaying unrelated repository use.
  @override
  Future<List<BackupDestinationRecord>> listDestinationsForScope({
    required String projectId,
    required String serverId,
  }) async {
    if (delayNextScopeLoad) {
      delayNextScopeLoad = false;
      scopeLoadStarted.complete();
      await releaseScopeLoad.future;
      final error = delayedScopeLoadError;
      if (error != null) {
        throw error;
      }
    }
    return super.listDestinationsForScope(
      projectId: projectId,
      serverId: serverId,
    );
  }
}

/// project workspace backup tab.
///
/// One of sixteen files T-3.6.1 split `project_workspace_test.dart` into. That
/// file was 16,030 lines holding 230 tests in two groups: a directory's worth
/// of tests wearing a filename, which nobody could hold in view, so a coverage
/// gap in it was invisible by construction.
///
/// Fixtures and pump helpers live in
/// `_support/project_workspace_harness.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('project workspace backup tab', () {
    testWidgets(
      'Backup tab opens server services when PostgreSQL is disabled',
      (WidgetTester tester) async {
        var openedServices = false;
        await pumpProjectWorkspace(
          tester,
          child: ProjectWorkspace(
            initialTabIndex: 5,
            onOpenServerServices: () {
              openedServices = true;
            },
          ),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(
              serverWithServicesDisabled,
            ),
          ],
        );

        expect(find.text('Backups'), findsOneWidget);
        expect(
          find.byKey(const Key('backup-service-disabled-message')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('backup-open-server-services-button')),
        );
        await tester.pumpAndSettle();
        expect(openedServices, isTrue);
      },
    );

    testWidgets('Backup tab surfaces backup scope loading failures', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          backupRepositoryProvider.overrideWithValue(
            ThrowingBackupRepository(database),
          ),
        ],
      );

      expect(find.byKey(const Key('backup-inline-error-text')), findsOneWidget);
      expect(
        find.text(
          'Couldn’t load backup details.\nException: backup scope exploded',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'Backup bind drops a selection that changes before DB loading',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final backupRepository = _DelayedBackupRepository(database);
        const otherProject = Project(
          id: 'project-other-backup-bind',
          serverId: 'server-database-enabled',
          name: 'Other backup app',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'other-backup.example.com',
        );
        await pumpProjectWorkspace(
          tester,
          database: database,
          child: const ProjectWorkspace(initialTabIndex: 5),
          overrides: [
            selectedProjectProvider.overrideWith(
              (ref) => ref.watch(mutableSelectedProjectProvider),
            ),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            backupRepositoryProvider.overrideWithValue(backupRepository),
          ],
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ProjectWorkspace)),
        );

        backupRepository.delayNextScopeLoad = true;
        container
            .read(mutableSelectedProjectProvider.notifier)
            .select(otherProject);
        await tester.pump();
        await backupRepository.scopeLoadStarted.future;
        container
            .read(mutableSelectedProjectProvider.notifier)
            .select(selectedProject);
        await tester.pump();
        await tester.pump();
        backupRepository.releaseScopeLoad.complete();
        await tester.pumpAndSettle();

        expect(find.text('Backups'), findsOneWidget);
        expect(find.byKey(const Key('backup-inline-error-text')), findsNothing);
      },
    );

    testWidgets('Backup bind drops database results after selection changes', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final managedRepository = DelayedProjectManagedDatabaseRepository(
        database,
      );
      const otherProject = Project(
        id: 'project-other-backup-database',
        serverId: 'server-database-enabled',
        name: 'Other database app',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'other-database.example.com',
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWith(
            (ref) => ref.watch(mutableSelectedProjectProvider),
          ),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          projectManagedDatabaseRepositoryProvider.overrideWithValue(
            managedRepository,
          ),
        ],
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProjectWorkspace)),
      );

      managedRepository.delayNextDatabaseLoad = true;
      container
          .read(mutableSelectedProjectProvider.notifier)
          .select(otherProject);
      await tester.pump();
      await managedRepository.databaseLoadStarted.future;
      container
          .read(mutableSelectedProjectProvider.notifier)
          .select(selectedProject);
      await tester.pump();
      await tester.pump();
      managedRepository.releaseDatabaseLoad.complete();
      await tester.pumpAndSettle();

      expect(find.text('Backups'), findsOneWidget);
      expect(find.byKey(const Key('backup-inline-error-text')), findsNothing);
    });

    testWidgets('Backup bind drops failures from a stale selection', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final backupRepository = _DelayedBackupRepository(database);
      const otherProject = Project(
        id: 'project-other-backup-error',
        serverId: 'server-database-enabled',
        name: 'Other failing backup app',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'other-failing-backup.example.com',
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWith(
            (ref) => ref.watch(mutableSelectedProjectProvider),
          ),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          backupRepositoryProvider.overrideWithValue(backupRepository),
        ],
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProjectWorkspace)),
      );

      backupRepository
        ..delayNextScopeLoad = true
        ..delayedScopeLoadError = StateError('stale load failed');
      container
          .read(mutableSelectedProjectProvider.notifier)
          .select(otherProject);
      await tester.pump();
      await backupRepository.scopeLoadStarted.future;
      container
          .read(mutableSelectedProjectProvider.notifier)
          .select(selectedProject);
      await tester.pump();
      await tester.pump();
      backupRepository.releaseScopeLoad.complete();
      await tester.pumpAndSettle();

      expect(find.text('Backups'), findsOneWidget);
      expect(find.byKey(const Key('backup-inline-error-text')), findsNothing);
    });

    testWidgets(
      'Backup tab hides Add PostgreSQL policy until a destination exists',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });
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
          child: const ProjectWorkspace(initialTabIndex: 5),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        expect(find.text('Backups'), findsOneWidget);
        expect(
          find.byKey(const Key('backup-add-destination-button')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('backup-add-policy-button')), findsNothing);
      },
    );

    testWidgets(
      'Backup tab shows Add PostgreSQL policy below destinations list once a destination exists',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });
        final backupRepository = BackupRepository(database);
        await backupRepository.upsertDestination(
          BackupDestinationRecord(
            id: 'dest-primary',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Primary S3',
            type: BackupDestinationType.s3,
            config: const <String, dynamic>{
              'prefix': 's3://bucket/postgres',
              'access_key_id': 'AKIA_TEST',
              'secret_access_key': 'SECRET_TEST',
              'region': 'eu-west-2',
              'endpoint': 'https://s3.example.com',
              'force_path_style': true,
            },
          ),
        );
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
          child: const ProjectWorkspace(initialTabIndex: 5),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        expect(find.text('Primary S3'), findsOneWidget);
        final policyButton = find.byKey(const Key('backup-add-policy-button'));
        expect(policyButton, findsOneWidget);
        expect(find.text('Add PostgreSQL policy'), findsOneWidget);
        expect(
          tester.getTopLeft(policyButton).dy,
          greaterThan(tester.getTopLeft(find.text('Primary S3')).dy),
        );
      },
    );

    testWidgets('Backup destination dialog tests S3 connectivity before save', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
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
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'backup_destination_test': <String, dynamic>{
            'status': 'success',
            'msg': 'PostgreSQL backup destination test succeeded.',
            'backup_destination_type': 's3',
            'tested_remote_path': 'deploydash/connection-tests/sample.txt',
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.byKey(const Key('backup-add-destination-button')));
      await tester.pumpAndSettle();

      final dialogFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(dialogFields.at(0), 'Primary S3');
      await tester.enterText(dialogFields.at(1), 's3://bucket/postgres');
      await tester.enterText(dialogFields.at(2), 'AKIA_TEST');
      await tester.enterText(dialogFields.at(3), 'SECRET_TEST');
      await tester.enterText(dialogFields.at(4), 'eu-west-2');
      await tester.enterText(dialogFields.at(5), 'https://s3.example.com');
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Test connection'));
      await tester.pumpAndSettle();

      final backupTestCall = sshService.callLog.lastWhere(
        (call) =>
            call['workflow_id'] == 'postgres' &&
            call['operation_id'] == 'backup_destination_test',
      );
      final params = backupTestCall['params'] as Map<String, dynamic>;
      final settings = params['settings'] as Map<String, dynamic>;
      expect(settings['backup_destination_type'], 's3');
      expect(settings['backup_s3_prefix'], 's3://bucket/postgres');
      expect(settings['backup_aws_access_key_id'], 'AKIA_TEST');
      expect(settings['backup_aws_secret_access_key'], 'SECRET_TEST');
      expect(settings['backup_aws_region'], 'eu-west-2');
      expect(settings['backup_aws_endpoint'], 'https://s3.example.com');
      expect(settings['backup_aws_force_path_style'], isTrue);
      expect(
        find.text('PostgreSQL backup destination test succeeded.'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Add destination'));
      await tester.pumpAndSettle();
      expect(find.text('Primary S3'), findsOneWidget);
    });

    testWidgets(
      'Backup destination probe validates input and surfaces transport failures',
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
            'databases': <String>['alpha_db'],
            'users': <Map<String, dynamic>>[],
          },
          throwingOperations: const {'backup_destination_test'},
        );
        await pumpProjectWorkspace(
          tester,
          database: database,
          child: const ProjectWorkspace(initialTabIndex: 5),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(
          find.byKey(const Key('backup-add-destination-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Test connection'));
        await tester.pumpAndSettle();
        expect(find.text('Destination name is required.'), findsOneWidget);

        final dialogFields = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextFormField),
        );
        await tester.enterText(dialogFields.at(0), 'Primary S3');
        await tester.enterText(dialogFields.at(1), 's3://bucket/postgres');
        await tester.enterText(dialogFields.at(2), 'AKIA_TEST');
        await tester.enterText(dialogFields.at(3), 'SECRET_TEST');
        await tester.enterText(dialogFields.at(4), 'eu-west-2');
        await tester.tap(find.widgetWithText(TextButton, 'Test connection'));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Backup destination test failed: Bad state: backup_destination_test unavailable',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Backup destination dialog validates and saves a filesystem path',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        await pumpProjectWorkspace(
          tester,
          database: database,
          child: const ProjectWorkspace(initialTabIndex: 5),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          ],
        );

        await tester.tap(
          find.byKey(const Key('backup-add-destination-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('S3'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Local filesystem').last);
        await tester.pumpAndSettle();

        final dialogFields = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextFormField),
        );
        await tester.enterText(dialogFields.at(0), 'Local snapshots');
        await tester.tap(find.widgetWithText(FilledButton, 'Add destination'));
        await tester.pumpAndSettle();
        expect(
          find.text('Filesystem path prefix is required.'),
          findsOneWidget,
        );

        await tester.enterText(dialogFields.at(1), '/srv/deploydash/backups');
        await tester.tap(find.widgetWithText(FilledButton, 'Add destination'));
        await tester.pumpAndSettle();

        expect(find.text('Local snapshots'), findsOneWidget);
        expect(find.text('/srv/deploydash/backups'), findsOneWidget);
      },
    );

    testWidgets(
      'Backup cards preserve destination edits and expose scheduled actions',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final backupRepository = BackupRepository(database);
        await backupRepository.upsertDestination(
          BackupDestinationRecord(
            id: 'dest-editable',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Editable S3',
            type: BackupDestinationType.s3,
            config: const <String, dynamic>{
              'prefix': 's3://bucket/postgres',
              'access_key_id': 'AKIA_TEST',
              'secret_access_key': 'SECRET_TEST',
              'region': 'eu-west-2',
              'endpoint': 'https://s3.example.com',
              'force_path_style': true,
            },
          ),
        );
        await backupRepository.upsertPolicy(
          BackupPolicyRecord(
            id: 'twice-daily',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Twice daily',
            destinationId: 'dest-editable',
            databaseName: 'alpha_db',
            scheduleMode: 'daily_twice',
            time1Hhmm: '02:00',
            time2Hhmm: '14:00',
            managedTaskId: 'backup-pg-twice-daily',
          ),
        );
        await backupRepository.replaceArtifactsForPolicy(
          engine: BackupEngine.postgres,
          policyId: 'twice-daily',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          artifacts: const <BackupArtifactRecord>[
            BackupArtifactRecord(
              id: 'twice-daily-artifact',
              policyId: 'twice-daily',
              projectId: 'project-selected',
              serverId: 'server-database-enabled',
              destinationId: 'dest-editable',
              databaseName: 'alpha_db',
              remotePath: 'deploydash/postgres/twice-daily/alpha.dump',
            ),
          ],
        );
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
          child: const ProjectWorkspace(initialTabIndex: 5),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        expect(find.text('Schedule: 02:00 and 14:00 daily'), findsOneWidget);
        final workspaceScroll = find.byType(Scrollable).last;

        await tester.tap(find.byKey(const Key('backup-add-policy-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('backup-policy-name-field')),
          'Added from backup card',
        );
        await tester.enterText(
          find.byKey(const Key('backup-policy-database-manual-field')),
          'alpha_db',
        );
        await tester.tap(find.byKey(const Key('backup-policy-save-button')));
        await tester.pumpAndSettle();
        expect(find.text('Added from backup card'), findsOneWidget);

        await tester.tap(
          find.byKey(const Key('backup-destination-edit-dest-editable')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Edit backup destination'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('backup-destination-edit-dest-editable')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();

        final policyEdit = find.byKey(
          const Key('backup-policy-edit-twice-daily'),
        );
        await tester.scrollUntilVisible(
          policyEdit,
          300,
          scrollable: workspaceScroll,
        );
        await tester.tap(policyEdit);
        await tester.pumpAndSettle();
        expect(find.text('Edit backup plan'), findsOneWidget);
        await tester.tap(find.byKey(const Key('backup-policy-save-button')));
        await tester.pumpAndSettle();

        // G-42: opening the screen refreshes artifacts from the server, so
        // the locally seeded one is replaced. Find the control by its label
        // rather than by an id that now depends on the server's response.
        final restore = find.widgetWithText(
          OutlinedButton,
          'Restore into new database',
        );
        await tester.scrollUntilVisible(
          restore,
          300,
          scrollable: workspaceScroll,
        );
        await tester.tap(restore);
        await tester.pumpAndSettle();
        expect(find.text('Restore backup'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();

        final policyDelete = find.byKey(
          const Key('backup-policy-delete-twice-daily'),
        );
        await tester.scrollUntilVisible(
          policyDelete,
          300,
          scrollable: workspaceScroll,
        );
        await tester.tap(policyDelete);
        await tester.pumpAndSettle();
        expect(sshService.countCalls('postgres', 'backup_policy_delete'), 1);

        final destinationDelete = find.byKey(
          const Key('backup-destination-delete-dest-editable'),
        );
        await tester.scrollUntilVisible(
          destinationDelete,
          -300,
          scrollable: workspaceScroll,
        );
        await tester.tap(destinationDelete);
        await tester.pumpAndSettle();
        expect(
          await backupRepository.listDestinationsForScope(
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
          ),
          isEmpty,
        );
      },
    );

    testWidgets(
      'Backup policy creation stops when its destination disappears in the dialog',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final backupRepository = BackupRepository(database);
        await backupRepository.upsertDestination(
          BackupDestinationRecord(
            id: 'dest-disappearing-add',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Disappearing S3',
            type: BackupDestinationType.s3,
            config: const <String, dynamic>{
              'prefix': 's3://bucket/postgres',
              'access_key_id': 'AKIA_TEST',
              'secret_access_key': 'SECRET_TEST',
              'region': 'eu-west-2',
            },
          ),
        );
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
          child: const ProjectWorkspace(initialTabIndex: 5),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.byKey(const Key('backup-add-policy-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('backup-policy-name-field')),
          'No destination plan',
        );
        await tester.enterText(
          find.byKey(const Key('backup-policy-database-manual-field')),
          'alpha_db',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ProjectWorkspace)),
        );
        await backupRepository.deleteDestination(
          id: 'dest-disappearing-add',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
        );
        await container
            .read(projectBackupProvider.notifier)
            .loadScope(
              projectId: selectedProject.id,
              serverId: serverWithDatabaseEnabled.id,
            );
        await tester.pump();

        await tester.tap(find.byKey(const Key('backup-policy-save-button')));
        await tester.pump();
        expect(
          find.text('Selected destination no longer exists.'),
          findsOneWidget,
        );
        await tester.pumpAndSettle();

        expect(
          await backupRepository.listPoliciesForScope(
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
          ),
          isEmpty,
        );
        expect(sshService.countCalls('postgres', 'backup_policy_upsert'), 0);
      },
    );

    testWidgets(
      'Backup policy creation stops after project selection changes',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final backupRepository = BackupRepository(database);
        await backupRepository.upsertDestination(
          BackupDestinationRecord(
            id: 'dest-selection-add',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Selection destination',
            type: BackupDestinationType.filesystem,
            config: const <String, dynamic>{'file_prefix': '/srv/backups'},
          ),
        );
        await pumpProjectWorkspace(
          tester,
          database: database,
          child: const ProjectWorkspace(initialTabIndex: 5),
          overrides: [
            selectedProjectProvider.overrideWith(
              (ref) => ref.watch(mutableSelectedProjectProvider),
            ),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          ],
        );

        await tester.tap(find.byKey(const Key('backup-add-policy-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('backup-policy-name-field')),
          'Wrong project policy',
        );
        await tester.enterText(
          find.byKey(const Key('backup-policy-database-field')),
          'alpha_db',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ProjectWorkspace)),
        );
        container
            .read(mutableSelectedProjectProvider.notifier)
            .select(
              const Project(
                id: 'project-other-policy-add',
                serverId: 'server-database-enabled',
                name: 'Other policy app',
                type: 'Web app',
                gitUrl: '',
                primaryDomain: 'other-policy.example.com',
              ),
            );
        await tester.pump();
        await tester.pump();
        await tester.tap(find.byKey(const Key('backup-policy-save-button')));
        await tester.pumpAndSettle();

        expect(
          await backupRepository.listPoliciesForScope(
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
          ),
          isEmpty,
        );
      },
    );

    testWidgets('Backup policy editing stops after project selection changes', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-selection-edit',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Selection destination',
          type: BackupDestinationType.filesystem,
          config: const <String, dynamic>{'file_prefix': '/srv/backups'},
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'policy-selection-edit',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Selection policy',
          destinationId: 'dest-selection-edit',
          databaseName: 'alpha_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-pg-selection-edit',
        ),
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWith(
            (ref) => ref.watch(mutableSelectedProjectProvider),
          ),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
        ],
      );

      final editButton = find.byKey(
        const Key('backup-policy-edit-policy-selection-edit'),
      );
      await tester.scrollUntilVisible(
        editButton,
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(editButton);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('backup-policy-name-field')),
        'Wrong project edit',
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProjectWorkspace)),
      );
      container
          .read(mutableSelectedProjectProvider.notifier)
          .select(
            const Project(
              id: 'project-other-policy-edit',
              serverId: 'server-database-enabled',
              name: 'Other edited policy app',
              type: 'Web app',
              gitUrl: '',
              primaryDomain: 'other-edited-policy.example.com',
            ),
          );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('backup-policy-save-button')));
      await tester.pumpAndSettle();

      final policies = await backupRepository.listPoliciesForScope(
        projectId: selectedProject.id,
        serverId: serverWithDatabaseEnabled.id,
      );
      expect(policies.single.name, 'Selection policy');
    });

    testWidgets(
      'Backup policy editing stops when its destination disappears in the dialog',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final backupRepository = BackupRepository(database);
        await backupRepository.upsertDestination(
          BackupDestinationRecord(
            id: 'dest-disappearing-edit',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Disappearing S3',
            type: BackupDestinationType.s3,
            config: const <String, dynamic>{
              'prefix': 's3://bucket/postgres',
              'access_key_id': 'AKIA_TEST',
              'secret_access_key': 'SECRET_TEST',
              'region': 'eu-west-2',
            },
          ),
        );
        await backupRepository.upsertPolicy(
          BackupPolicyRecord(
            id: 'plan-disappearing-edit',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Original plan',
            destinationId: 'dest-disappearing-edit',
            databaseName: 'alpha_db',
            scheduleMode: 'daily_once',
            time1Hhmm: '02:00',
            managedTaskId: 'backup-pg-original-plan',
          ),
        );
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
          child: const ProjectWorkspace(initialTabIndex: 5),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        final policyEdit = find.byKey(
          const Key('backup-policy-edit-plan-disappearing-edit'),
        );
        await tester.scrollUntilVisible(
          policyEdit,
          300,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(policyEdit);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('backup-policy-name-field')),
          'Updated plan',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ProjectWorkspace)),
        );
        await backupRepository.deleteDestination(
          id: 'dest-disappearing-edit',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
        );
        await container
            .read(projectBackupProvider.notifier)
            .loadScope(
              projectId: selectedProject.id,
              serverId: serverWithDatabaseEnabled.id,
            );
        await tester.pump();

        await tester.tap(find.byKey(const Key('backup-policy-save-button')));
        await tester.pump();
        expect(
          find.text('Selected destination no longer exists.'),
          findsOneWidget,
        );
        await tester.pumpAndSettle();

        final policies = await backupRepository.listPoliciesForScope(
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
        );
        expect(policies.single.name, 'Original plan');
        expect(sshService.countCalls('postgres', 'backup_policy_upsert'), 0);
      },
    );

    testWidgets('Backup run reports missing server credentials', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-no-credentials',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabledMissingPassword.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{
            'prefix': 's3://bucket/postgres',
            'access_key_id': 'AKIA_TEST',
            'secret_access_key': 'SECRET_TEST',
            'region': 'eu-west-2',
          },
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-no-credentials',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabledMissingPassword.id,
          name: 'Daily Main',
          destinationId: 'dest-no-credentials',
          databaseName: 'alpha_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-task-no-credentials',
        ),
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(
            serverWithDatabaseEnabledMissingPassword,
          ),
        ],
      );

      await tester.tap(find.byTooltip('Run backup now'));
      await tester.pumpAndSettle();

      expect(find.text('Run backup failed'), findsOneWidget);
      expect(
        find.textContaining('can’t reach this server yet'),
        findsOneWidget,
      );
    });

    testWidgets('Backup run success refreshes artifacts automatically', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-primary',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{
            'prefix': 's3://bucket/postgres',
            'access_key_id': 'AKIA_TEST',
            'secret_access_key': 'SECRET_TEST',
            'region': 'eu-west-2',
            'endpoint': 'https://s3.example.com',
            'force_path_style': true,
          },
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-main',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily Main',
          destinationId: 'dest-primary',
          databaseName: 'alpha_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-task',
        ),
      );

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
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'backup_run_now': <String, dynamic>{
            'status': 'success',
            'msg': 'PostgreSQL logical backup completed.',
          },
          'backup_artifact_list': <String, dynamic>{
            'status': 'success',
            'msg': 'Backup artifacts listed.',
            'artifacts': <Map<String, dynamic>>[
              <String, dynamic>{
                'remote_path':
                    'deploydash/postgres/test/daily-main/20260416T123052Z__alpha_db.dump',
                'created_at': '2026-04-16T12:30:52Z',
                'size_bytes': 56194478,
              },
            ],
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.byTooltip('Run backup now'));
      await tester.pumpAndSettle();

      expect(sshService.countCalls('postgres', 'backup_run_now'), 1);
      // One on open (G-42), one after the run completes.
      expect(sshService.countCalls('postgres', 'backup_artifact_list'), 2);
      expect(
        find.text(
          'deploydash/postgres/test/daily-main/20260416T123052Z__alpha_db.dump',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'Backup workspace reports a failed artifact listing without losing what it has',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final backupRepository = BackupRepository(database);
        await backupRepository.upsertDestination(
          BackupDestinationRecord(
            id: 'dest-failing',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Failing S3',
            type: BackupDestinationType.s3,
            config: const <String, dynamic>{'prefix': 's3://bucket/pg'},
          ),
        );
        await backupRepository.upsertPolicy(
          BackupPolicyRecord(
            id: 'daily-main',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Daily main',
            destinationId: 'dest-failing',
            databaseName: 'alpha_db',
            scheduleMode: 'daily_once',
            time1Hhmm: '02:00',
            managedTaskId: 'backup-pg-daily-main',
          ),
        );

        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{'status': 'success'},
          postgresOperationResponses: const <String, Map<String, dynamic>>{
            'backup_artifact_list': <String, dynamic>{
              'status': 'error',
              'msg': 'The bucket rejected the listing request.',
            },
          },
        );

        await pumpProjectWorkspace(
          tester,
          database: database,
          child: const ProjectWorkspace(initialTabIndex: 5),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        expect(
          find.text('The bucket rejected the listing request.'),
          findsOneWidget,
          reason: "a listing the server refused is reported, not swallowed",
        );
      },
      skip: !sqliteAvailable,
    );

    testWidgets('Backup workspace keeps stored backups when a refresh dedupes', (
      WidgetTester tester,
    ) async {
      // Why: a refresh tapped while the identical listing is still running
      // answers ENGINE_OPERATION_DEDUPED with no artifacts key. Storing
      // that as an empty list wiped the screen to "No backups are ready
      // to restore yet" until the next refresh.
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-dedup',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Dedup S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{'prefix': 's3://bucket/pg'},
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-main',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily main',
          destinationId: 'dest-dedup',
          databaseName: 'alpha_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-pg-daily-main',
        ),
      );
      await backupRepository.replaceArtifactsForPolicy(
        engine: BackupEngine.postgres,
        policyId: 'daily-main',
        projectId: selectedProject.id,
        serverId: serverWithDatabaseEnabled.id,
        artifacts: const <BackupArtifactRecord>[
          BackupArtifactRecord(
            id: 'daily-main-stored',
            policyId: 'daily-main',
            projectId: 'project-selected',
            serverId: 'server-database-enabled',
            destinationId: 'dest-dedup',
            databaseName: 'alpha_db',
            remotePath: 'deploydash/postgres/stored/alpha.dump',
          ),
        ],
      );

      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{'status': 'success'},
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'backup_artifact_list': <String, dynamic>{
            'status': 'success',
            'code': 'ENGINE_OPERATION_DEDUPED',
            'msg':
                'Duplicate operation request ignored (already queued/running).',
            'duplicate_of_operation_id': 'op-1',
          },
        },
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      // The open-time auto-refresh deduped too, and must not have wiped.
      expect(
        find.text('deploydash/postgres/stored/alpha.dump'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Refresh backups'));
      await tester.pumpAndSettle();

      // The manual refresh reports the wait instead of storing emptiness.
      expect(
        find.text('deploydash/postgres/stored/alpha.dump'),
        findsOneWidget,
        reason: "a deduped refresh must not clear stored backups",
      );
      expect(
        find.text(backupArtifactRefreshDuplicateMessage()),
        findsWidgets,
        reason: "a deduped refresh names the wait, not success",
      );
    }, skip: !sqliteAvailable);

    testWidgets('Backup workspace refreshes recent backups on request', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-primary',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{
            'prefix': 's3://bucket/postgres',
            'access_key_id': 'AKIA_TEST',
            'secret_access_key': 'SECRET_TEST',
            'region': 'eu-west-2',
            'endpoint': 'https://s3.example.com',
            'force_path_style': true,
          },
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-main',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily Main',
          destinationId: 'dest-primary',
          databaseName: 'alpha_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-task',
        ),
      );

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
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'backup_artifact_list': <String, dynamic>{
            'status': 'success',
            'msg': 'Backup artifacts listed.',
            'artifacts': <Map<String, dynamic>>[
              <String, dynamic>{
                'remote_path':
                    'deploydash/postgres/test/daily-main/20260416T123052Z__alpha_db.dump',
                'created_at': '2026-04-16T12:30:52Z',
                'size_bytes': 56194478,
              },
            ],
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      // G-42: the screen fetches on open, so this is 1 before the button is
      // pressed rather than 0. That the count still moves is what proves the
      // manual refresh does its own fetch.
      expect(sshService.countCalls('postgres', 'backup_artifact_list'), 1);
      await tester.tap(find.byTooltip('Refresh backups'));
      await tester.pumpAndSettle();

      expect(sshService.countCalls('postgres', 'backup_artifact_list'), 2);
      expect(
        find.text(
          'deploydash/postgres/test/daily-main/20260416T123052Z__alpha_db.dump',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'Backup run failures surface detailed error text and terminal lines',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });
        final backupRepository = BackupRepository(database);
        await backupRepository.upsertDestination(
          BackupDestinationRecord(
            id: 'dest-primary',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Primary S3',
            type: BackupDestinationType.s3,
            config: const <String, dynamic>{
              'prefix': 's3://bucket/postgres',
              'access_key_id': 'AKIA_TEST',
              'secret_access_key': 'SECRET_TEST',
              'region': 'eu-west-2',
              'endpoint': 'https://s3.example.com',
              'force_path_style': true,
            },
          ),
        );
        await backupRepository.upsertPolicy(
          BackupPolicyRecord(
            id: 'daily-main',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Daily Main',
            destinationId: 'dest-primary',
            databaseName: 'alpha_db',
            scheduleMode: 'daily_once',
            time1Hhmm: '02:00',
            managedTaskId: 'backup-task',
          ),
        );

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
          postgresOperationResponses: const <String, Map<String, dynamic>>{
            'backup_run_now': <String, dynamic>{
              'status': 'error',
              'msg': 'Task ended unexpectedly.',
              'details':
                  'Worker process terminated before returning a result. Exit code: 17.',
            },
          },
          operationEvents: const <String, List<Map<String, dynamic>>>{
            'backup_run_now': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'pyinfra_operation_stdout',
                'message': 'pg_basebackup started',
              },
            ],
          },
        );
        final terminalLines = <String>[];
        final terminalDetails = <bool>[];
        await pumpProjectWorkspace(
          tester,
          database: database,
          child: ProjectWorkspace(
            initialTabIndex: 5,
            onTerminalLine:
                (line, {source = 'backup', taskType, detail = false}) {
                  terminalLines.add(line);
                  terminalDetails.add(detail);
                },
          ),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.byTooltip('Run backup now'));
        await tester.pumpAndSettle();

        expect(find.text('Run backup failed'), findsOneWidget);
        expect(
          find.text(
            'Task ended unexpectedly.\nWorker process terminated before returning a result. Exit code: 17.',
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('backup-inline-error-text')), findsNothing);
        expect(terminalLines, contains('pg_basebackup started'));
        // D-84 characterization: pyinfra_operation_stdout is a backup-6
        // detail member.
        expect(
          terminalDetails[terminalLines.indexOf('pg_basebackup started')],
          isTrue,
        );
        expect(
          terminalLines.any(
            (line) =>
                line.contains('Run backup now | Task ended unexpectedly.'),
          ),
          isTrue,
        );
        expect(
          terminalLines.any((line) => line.contains('Exit code: 17.')),
          isTrue,
        );
      },
    );

    testWidgets(
      'Backup restore persists the restored database before committing its journal',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async => database.close());
        final backupRepository = BackupRepository(database);
        await backupRepository.upsertDestination(
          BackupDestinationRecord(
            id: 'dest-restore-success',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Primary S3',
            type: BackupDestinationType.s3,
            config: const <String, dynamic>{
              'prefix': 's3://bucket/postgres',
              'access_key_id': 'AKIA_TEST',
              'secret_access_key': 'SECRET_TEST',
              'region': 'eu-west-2',
              'endpoint': 'https://s3.example.com',
              'force_path_style': true,
            },
          ),
        );
        await backupRepository.upsertPolicy(
          BackupPolicyRecord(
            id: 'restore-success',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Restore success',
            destinationId: 'dest-restore-success',
            databaseName: 'alpha_db',
            scheduleMode: 'daily_once',
            time1Hhmm: '02:00',
            managedTaskId: 'restore-success-task',
          ),
        );
        await backupRepository.replaceArtifactsForPolicy(
          engine: BackupEngine.postgres,
          policyId: 'restore-success',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          artifacts: [
            BackupArtifactRecord(
              id: 'restore-success-artifact',
              policyId: 'restore-success',
              projectId: selectedProject.id,
              serverId: serverWithDatabaseEnabled.id,
              destinationId: 'dest-restore-success',
              databaseName: 'alpha_db',
              remotePath: 'deploydash/postgres/test/restore-success/alpha.dump',
              sizeBytes: 42,
            ),
          ],
        );
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
          postgresOperationResponses: const <String, Map<String, dynamic>>{
            'restore_run_now': <String, dynamic>{
              'status': 'success',
              'msg': 'PostgreSQL restore completed.',
              'database_name': 'restored_app',
              'target_database_name': 'dd_runtime_restored_app',
            },
          },
        );
        await pumpProjectWorkspace(
          tester,
          database: database,
          child: const ProjectWorkspace(initialTabIndex: 5),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(
          find.widgetWithText(OutlinedButton, 'Restore into new database'),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog).first,
            matching: find.byType(TextFormField),
          ),
          'restored_app',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
        await tester.pumpAndSettle();

        expect(find.text('Restore completed.'), findsOneWidget);
        expect(
          (await ProjectManagedDatabaseRepository(
                database,
              ).listDatabasesForScope(
                projectId: selectedProject.id,
                serverId: serverWithDatabaseEnabled.id,
              ))
              .map((row) => row.databaseName),
          contains('restored_app'),
        );
        expect(
          await AppReleaseRepository(database).listRemoteSuccessJournal(),
          isEmpty,
        );
      },
      skip: !sqliteAvailable,
    );

    testWidgets('Backup policy save sends the logical database name', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-logical-names',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{
            'prefix': 's3://bucket/postgres',
            'access_key_id': 'AKIA_TEST',
            'secret_access_key': 'SECRET_TEST',
            'region': 'eu-west-2',
          },
        ),
      );
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
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.byKey(const Key('backup-add-policy-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('backup-policy-name-field')),
        'Logical names plan',
      );
      await tester.enterText(
        find.byKey(const Key('backup-policy-database-manual-field')),
        'dd_regs_v3_main',
      );
      await tester.tap(find.byKey(const Key('backup-policy-save-button')));
      await tester.pumpAndSettle();

      final applyCall = sshService.callLog.lastWhere(
        (call) =>
            call['workflow_id'] == 'postgres' &&
            call['operation_id'] == 'backup_policy_apply',
      );
      final params = applyCall['params'] as Map<String, dynamic>;
      final settings = params['settings'] as Map<String, dynamic>;
      expect(settings['backup_database_name'], 'main');
    });

    testWidgets('Backup run sends the logical database name', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-logical-run',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{
            'prefix': 's3://bucket/postgres',
            'access_key_id': 'AKIA_TEST',
            'secret_access_key': 'SECRET_TEST',
            'region': 'eu-west-2',
          },
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-logical-run',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily Main',
          destinationId: 'dest-logical-run',
          databaseName: 'dd_regs_v3_main',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-task-logical-run',
        ),
      );
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
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'backup_run_now': <String, dynamic>{
            'status': 'success',
            'msg': 'PostgreSQL logical backup completed.',
          },
          'backup_artifact_list': <String, dynamic>{
            'status': 'success',
            'artifacts': <Map<String, dynamic>>[],
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.byTooltip('Run backup now'));
      await tester.pumpAndSettle();

      final runCall = sshService.callLog.lastWhere(
        (call) =>
            call['workflow_id'] == 'postgres' &&
            call['operation_id'] == 'backup_run_now',
      );
      final params = runCall['params'] as Map<String, dynamic>;
      final settings = params['settings'] as Map<String, dynamic>;
      expect(settings['backup_database_name'], 'main');
    });

    testWidgets('Backup artifact refresh sends the logical database name', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-logical-refresh',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{'prefix': 's3://bucket/pg'},
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-logical-refresh',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily Main',
          destinationId: 'dest-logical-refresh',
          databaseName: 'dd_regs_v3_main',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-task-logical-refresh',
        ),
      );
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
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'backup_artifact_list': <String, dynamic>{
            'status': 'success',
            'artifacts': <Map<String, dynamic>>[],
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      // The open-time auto-refresh already listed with the stored policy name.
      final listCall = sshService.callLog.firstWhere(
        (call) =>
            call['workflow_id'] == 'postgres' &&
            call['operation_id'] == 'backup_artifact_list',
      );
      final params = listCall['params'] as Map<String, dynamic>;
      final settings = params['settings'] as Map<String, dynamic>;
      expect(settings['backup_database_name'], 'main');
    });

    testWidgets('Backup restore sends the logical database name', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-logical-restore',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{
            'prefix': 's3://bucket/postgres',
            'access_key_id': 'AKIA_TEST',
            'secret_access_key': 'SECRET_TEST',
            'region': 'eu-west-2',
          },
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-logical-restore',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily Main',
          destinationId: 'dest-logical-restore',
          databaseName: 'dd_regs_v3_main',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-task-logical-restore',
        ),
      );
      await backupRepository.replaceArtifactsForPolicy(
        engine: BackupEngine.postgres,
        policyId: 'daily-logical-restore',
        projectId: selectedProject.id,
        serverId: serverWithDatabaseEnabled.id,
        artifacts: [
          BackupArtifactRecord(
            id: 'logical-restore-artifact',
            policyId: 'daily-logical-restore',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            destinationId: 'dest-logical-restore',
            databaseName: 'dd_regs_v3_main',
            remotePath: 'deploydash/postgres/test/daily-main/alpha.dump',
            sizeBytes: 42,
          ),
        ],
      );
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
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'restore_run_now': <String, dynamic>{
            'status': 'success',
            'msg': 'PostgreSQL restore completed.',
            'target_database_name': 'dd_regs_v3_restored',
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Restore into new database'),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog).first,
          matching: find.byType(TextFormField),
        ),
        'restored',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
      await tester.pumpAndSettle();

      final restoreCall = sshService.callLog.lastWhere(
        (call) =>
            call['workflow_id'] == 'postgres' &&
            call['operation_id'] == 'restore_run_now',
      );
      final params = restoreCall['params'] as Map<String, dynamic>;
      final settings = params['settings'] as Map<String, dynamic>;
      expect(settings['backup_database_name'], 'main');
      expect(settings['backup_target_database_name'], 'restored');
    });

    testWidgets('Backup runs report the backup event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-primary',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{
            'prefix': 's3://bucket/postgres',
            'access_key_id': 'AKIA_TEST',
            'secret_access_key': 'SECRET_TEST',
            'region': 'eu-west-2',
            'endpoint': 'https://s3.example.com',
            'force_path_style': true,
          },
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-main',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily Main',
          destinationId: 'dest-primary',
          databaseName: 'alpha_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-task',
        ),
      );

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
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'backup_run_now': <String, dynamic>{
            'status': 'success',
            'msg': 'PostgreSQL logical backup completed.',
          },
          'backup_artifact_list': <String, dynamic>{
            'status': 'success',
            'artifacts': <Map<String, dynamic>>[],
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
      );

      await tester.tap(find.byTooltip('Run backup now'));
      await tester.pumpAndSettle();

      expect(find.text('Backup run completed.'), findsOneWidget);
      expect(analytics.backupEvents, [
        (kind: BackupKind.postgres, outcome: DataOperationOutcome.success),
      ]);
    });

    testWidgets('Backup run failures report the backup event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-primary',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{
            'prefix': 's3://bucket/postgres',
            'access_key_id': 'AKIA_TEST',
            'secret_access_key': 'SECRET_TEST',
            'region': 'eu-west-2',
          },
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-main',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily Main',
          destinationId: 'dest-primary',
          databaseName: 'alpha_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-task',
        ),
      );

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
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'backup_run_now': <String, dynamic>{
            'status': 'error',
            'msg': 'Task ended unexpectedly.',
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
      );

      await tester.tap(find.byTooltip('Run backup now'));
      await tester.pumpAndSettle();

      expect(find.text('Run backup failed'), findsOneWidget);
      expect(analytics.backupEvents, [
        (kind: BackupKind.postgres, outcome: DataOperationOutcome.failure),
      ]);
    });

    testWidgets('Backup restores report the restore event with a duration', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => database.close());
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-restore-event',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{
            'prefix': 's3://bucket/postgres',
            'access_key_id': 'AKIA_TEST',
            'secret_access_key': 'SECRET_TEST',
            'region': 'eu-west-2',
          },
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'restore-event',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Restore event',
          destinationId: 'dest-restore-event',
          databaseName: 'alpha_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'restore-event-task',
        ),
      );
      await backupRepository.replaceArtifactsForPolicy(
        engine: BackupEngine.postgres,
        policyId: 'restore-event',
        projectId: selectedProject.id,
        serverId: serverWithDatabaseEnabled.id,
        artifacts: [
          BackupArtifactRecord(
            id: 'restore-event-artifact',
            policyId: 'restore-event',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            destinationId: 'dest-restore-event',
            databaseName: 'alpha_db',
            remotePath: 'deploydash/postgres/test/restore-event/alpha.dump',
            sizeBytes: 42,
          ),
        ],
      );
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
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'restore_run_now': <String, dynamic>{
            'status': 'success',
            'msg': 'PostgreSQL restore completed.',
            'target_database_name': 'dd_runtime_restored_app',
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
      );

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Restore into new database'),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog).first,
          matching: find.byType(TextFormField),
        ),
        'restored_app',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
      await tester.pumpAndSettle();

      expect(find.text('Restore completed.'), findsOneWidget);
      expect(analytics.restoreEvents, hasLength(1));
      expect(
        analytics.restoreEvents.single.outcome,
        DataOperationOutcome.success,
      );
      expect(
        analytics.restoreEvents.single.durationSeconds,
        greaterThanOrEqualTo(0),
      );
    });

    testWidgets(
      'Backup restore failures surface a modal instead of the page-level inline error',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });
        final backupRepository = BackupRepository(database);
        await backupRepository.upsertDestination(
          BackupDestinationRecord(
            id: 'dest-primary',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Primary S3',
            type: BackupDestinationType.s3,
            config: const <String, dynamic>{
              'prefix': 's3://bucket/postgres',
              'access_key_id': 'AKIA_TEST',
              'secret_access_key': 'SECRET_TEST',
              'region': 'eu-west-2',
              'endpoint': 'https://s3.example.com',
              'force_path_style': true,
            },
          ),
        );
        await backupRepository.upsertPolicy(
          BackupPolicyRecord(
            id: 'daily-main',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Daily Main',
            destinationId: 'dest-primary',
            databaseName: 'alpha_db',
            scheduleMode: 'daily_once',
            time1Hhmm: '02:00',
            managedTaskId: 'backup-task',
          ),
        );
        await backupRepository.replaceArtifactsForPolicy(
          engine: BackupEngine.postgres,
          policyId: 'daily-main',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          artifacts: [
            BackupArtifactRecord(
              id: 'artifact-1',
              policyId: 'daily-main',
              projectId: selectedProject.id,
              serverId: serverWithDatabaseEnabled.id,
              destinationId: 'dest-primary',
              databaseName: 'alpha_db',
              remotePath:
                  'deploydash/postgres/test/daily-main/20260416T123052Z__alpha_db.dump',
              sizeBytes: 56194478,
            ),
          ],
        );

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
          postgresOperationResponses: const <String, Map<String, dynamic>>{
            'backup_artifact_list': <String, dynamic>{
              'status': 'success',
              'msg': 'Backup artifacts listed.',
              'artifacts': <Map<String, dynamic>>[
                <String, dynamic>{
                  'remote_path':
                      'deploydash/postgres/test/daily-main/20260416T123052Z__alpha_db.dump',
                  'created_at': '2026-04-16T12:30:52Z',
                  'size_bytes': 56194478,
                },
              ],
            },
            'restore_run_now': <String, dynamic>{
              'status': 'error',
              'msg':
                  'Target database already exists. Choose a new database name.',
            },
          },
        );
        await pumpProjectWorkspace(
          tester,
          database: database,
          child: const ProjectWorkspace(initialTabIndex: 5),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        // G-42: one fetch already happened when the screen opened.
        expect(sshService.countCalls('postgres', 'backup_artifact_list'), 1);
        await tester.tap(find.byTooltip('Refresh backups'));
        await tester.pumpAndSettle();
        expect(sshService.countCalls('postgres', 'backup_artifact_list'), 2);
        await tester.tap(
          find.widgetWithText(OutlinedButton, 'Restore into new database'),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog).first,
            matching: find.byType(TextFormField),
          ),
          'alpha_db',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
        await tester.pumpAndSettle();

        expect(find.text('Restore backup failed'), findsOneWidget);
        expect(
          find.text(
            'Target database already exists. Choose a new database name.',
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('backup-inline-error-text')), findsNothing);
      },
    );

    testWidgets('Backup backlog cleanup deletes only after confirmation', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => database.close());
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-cleanup-confirm',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{
            'prefix': 's3://bucket/postgres',
            'access_key_id': 'AKIA_TEST',
            'secret_access_key': 'SECRET_TEST',
            'region': 'eu-west-2',
          },
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-cleanup-confirm',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily Main',
          destinationId: 'dest-cleanup-confirm',
          databaseName: 'alpha_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-task-cleanup-confirm',
        ),
      );
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
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'backup_backlog_report': <String, dynamic>{
            'status': 'success',
            'msg': 'Backup backlog reported.',
            'beyond_retention_count': 2,
            'beyond_retention_bytes': 456,
            'beyond_retention_unknown_size_count': 0,
            'retention_keep_last': 1,
          },
          'backup_backlog_cleanup': <String, dynamic>{
            'status': 'success',
            'msg': 'Backup backlog cleaned up.',
            'deleted_count': 2,
            'deleted_bytes': 456,
            'deleted': <String>['old-a.dump', 'old-b.dump'],
            'manifests_missing': <String>[],
          },
          'backup_artifact_list': <String, dynamic>{
            'status': 'success',
            'artifacts': <Map<String, dynamic>>[],
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(
        find.byKey(const Key('backup-policy-cleanup-daily-cleanup-confirm')),
      );
      await tester.pumpAndSettle();

      expect(sshService.countCalls('postgres', 'backup_backlog_report'), 1);
      expect(sshService.countCalls('postgres', 'backup_backlog_cleanup'), 0);
      expect(
        find.text(
          '2 artifacts beyond retention (~456 B). '
          'The newest 1 backup is kept.',
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('backup-backlog-cleanup-confirm-button')),
      );
      await tester.pumpAndSettle();

      expect(sshService.countCalls('postgres', 'backup_backlog_cleanup'), 1);
      // One on open (G-42), one after the cleanup completes.
      expect(sshService.countCalls('postgres', 'backup_artifact_list'), 2);
      expect(find.text('Deleted 2 old backups.'), findsOneWidget);
      expect(
        await AppReleaseRepository(database).listRemoteSuccessJournal(),
        isEmpty,
      );
      await tester.scrollUntilVisible(
        find.text('CLEANUP · success'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('CLEANUP · success'), findsOneWidget);
    }, skip: !sqliteAvailable);

    testWidgets('Backup backlog cleanup cancel deletes nothing', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-cleanup-cancel',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{'prefix': 's3://bucket/pg'},
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-cleanup-cancel',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily Main',
          destinationId: 'dest-cleanup-cancel',
          databaseName: 'alpha_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-task-cleanup-cancel',
        ),
      );
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{'status': 'success'},
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          // No retention_keep_last: the dialog falls back to the plan's
          // own retention for the kept-backups note.
          'backup_backlog_report': <String, dynamic>{
            'status': 'success',
            'msg': 'Backup backlog reported.',
            'beyond_retention_count': 2,
            'beyond_retention_bytes': 456,
            'beyond_retention_unknown_size_count': 0,
          },
          'backup_artifact_list': <String, dynamic>{
            'status': 'success',
            'artifacts': <Map<String, dynamic>>[],
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(
        find.byKey(const Key('backup-policy-cleanup-daily-cleanup-cancel')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('backup-backlog-cleanup-dialog')),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(sshService.countCalls('postgres', 'backup_backlog_cleanup'), 0);
      expect(
        find.byKey(const Key('backup-backlog-cleanup-dialog')),
        findsNothing,
      );
    }, skip: !sqliteAvailable);

    testWidgets(
      'Backup backlog cleanup reports an empty backlog without a dialog',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final backupRepository = BackupRepository(database);
        await backupRepository.upsertDestination(
          BackupDestinationRecord(
            id: 'dest-cleanup-empty',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Primary S3',
            type: BackupDestinationType.s3,
            config: const <String, dynamic>{'prefix': 's3://bucket/pg'},
          ),
        );
        await backupRepository.upsertPolicy(
          BackupPolicyRecord(
            id: 'daily-cleanup-empty',
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
            name: 'Daily Main',
            destinationId: 'dest-cleanup-empty',
            databaseName: 'alpha_db',
            scheduleMode: 'daily_once',
            time1Hhmm: '02:00',
            managedTaskId: 'backup-task-cleanup-empty',
          ),
        );
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{'status': 'success'},
          postgresOperationResponses: const <String, Map<String, dynamic>>{
            'backup_backlog_report': <String, dynamic>{
              'status': 'success',
              'msg': 'Backup backlog reported.',
              'beyond_retention_count': 0,
              'beyond_retention_bytes': 0,
              'beyond_retention_unknown_size_count': 0,
              'retention_keep_last': 7,
            },
            'backup_artifact_list': <String, dynamic>{
              'status': 'success',
              'artifacts': <Map<String, dynamic>>[],
            },
          },
        );
        await pumpProjectWorkspace(
          tester,
          database: database,
          child: const ProjectWorkspace(initialTabIndex: 5),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(
          find.byKey(const Key('backup-policy-cleanup-daily-cleanup-empty')),
        );
        await tester.pumpAndSettle();

        expect(find.text('No old backups to clean up.'), findsOneWidget);
        expect(
          find.byKey(const Key('backup-backlog-cleanup-dialog')),
          findsNothing,
        );
        expect(sshService.countCalls('postgres', 'backup_backlog_cleanup'), 0);
      },
      skip: !sqliteAvailable,
    );

    testWidgets('Backup backlog cleanup surfaces report failures', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-cleanup-report-fails',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{'prefix': 's3://bucket/pg'},
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-cleanup-report-fails',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily Main',
          destinationId: 'dest-cleanup-report-fails',
          databaseName: 'alpha_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-task-cleanup-report-fails',
        ),
      );
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{'status': 'success'},
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'backup_backlog_report': <String, dynamic>{
            'status': 'error',
            'msg': 'The bucket refused the listing.',
          },
          'backup_artifact_list': <String, dynamic>{
            'status': 'success',
            'artifacts': <Map<String, dynamic>>[],
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(
        find.byKey(
          const Key('backup-policy-cleanup-daily-cleanup-report-fails'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Clean up old backups failed'), findsOneWidget);
      expect(find.text('The bucket refused the listing.'), findsOneWidget);
      expect(sshService.countCalls('postgres', 'backup_backlog_cleanup'), 0);
    }, skip: !sqliteAvailable);

    testWidgets('Backup backlog cleanup surfaces cleanup failures', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-cleanup-fails',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{'prefix': 's3://bucket/pg'},
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-cleanup-fails',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily Main',
          destinationId: 'dest-cleanup-fails',
          databaseName: 'alpha_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-task-cleanup-fails',
        ),
      );
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{'status': 'success'},
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'backup_backlog_report': <String, dynamic>{
            'status': 'success',
            'msg': 'Backup backlog reported.',
            'beyond_retention_count': 1,
            'beyond_retention_bytes': 100,
            'beyond_retention_unknown_size_count': 0,
            'retention_keep_last': 1,
          },
          'backup_backlog_cleanup': <String, dynamic>{
            'status': 'error',
            'msg': 'PostgreSQL backup backlog cleanup failed.',
            'details': 'Failed to delete: old-a.dump',
          },
          'backup_artifact_list': <String, dynamic>{
            'status': 'success',
            'artifacts': <Map<String, dynamic>>[],
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(
        find.byKey(const Key('backup-policy-cleanup-daily-cleanup-fails')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('backup-backlog-cleanup-confirm-button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Clean up old backups failed'), findsOneWidget);
      expect(
        find.text(
          'PostgreSQL backup backlog cleanup failed.\n'
          'Failed to delete: old-a.dump',
        ),
        findsOneWidget,
      );
    }, skip: !sqliteAvailable);

    testWidgets('Backup backlog cleanup surfaces transport failures', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final backupRepository = BackupRepository(database);
      await backupRepository.upsertDestination(
        BackupDestinationRecord(
          id: 'dest-cleanup-throws',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Primary S3',
          type: BackupDestinationType.s3,
          config: const <String, dynamic>{'prefix': 's3://bucket/pg'},
        ),
      );
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-cleanup-throws',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily Main',
          destinationId: 'dest-cleanup-throws',
          databaseName: 'alpha_db',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'backup-task-cleanup-throws',
        ),
      );
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{'status': 'success'},
        postgresOperationResponses: const <String, Map<String, dynamic>>{
          'backup_artifact_list': <String, dynamic>{
            'status': 'success',
            'artifacts': <Map<String, dynamic>>[],
          },
        },
        throwingOperations: const {'backup_backlog_report'},
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: const ProjectWorkspace(initialTabIndex: 5),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(
        find.byKey(const Key('backup-policy-cleanup-daily-cleanup-throws')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Clean up old backups failed'), findsOneWidget);
      expect(
        find.textContaining('Could not clean up old backups:'),
        findsOneWidget,
      );
    }, skip: !sqliteAvailable);
  }, skip: !sqliteAvailable);
}
