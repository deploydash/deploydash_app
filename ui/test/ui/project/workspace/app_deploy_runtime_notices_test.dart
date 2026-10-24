import 'package:flutter_test/flutter_test.dart';

import '_support/project_workspace_harness.dart';

// Characterization for D-43 (T-013, commit 1): the rollback notices show
// exact copy and pop on OK; the two refresh-connection resolve blocks keep
// their divergent null dispositions (silent vs error-state). All green at
// base (hand-rolled dialogs), all green after routing through showAppNotice
// and _resolveRefreshConnection.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group(
    'runtime rollback notices and refresh dispositions',
    skip: !sqliteAvailable,
    () {
      testWidgets('rollback without a connection shows Server needed', (
        WidgetTester tester,
      ) async {
        // N2 (null connection; the N1 null-server twin is byte-identical and
        // routes to the same one-liner). Staged with a server id the test
        // connection resolver knows no credentials for, so the payload
        // resolves null while the UI still renders.
        const credentiallessServer = Server(
          id: 'server-no-credentials',
          name: 'srv.nocreds.local',
          host: '192.168.1.31',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.password,
          serviceDatabaseEnabled: false,
          serviceEmailEnabled: false,
          serviceDomainEnabled: false,
        );
        final releaseInventory = <Map<String, dynamic>>[
          <String, dynamic>{
            'release_id': '20260531t120000z-abcdef12',
            'status': 'live',
            'commit_sha': 'abcdef1234567890',
            'created_at': '2026-05-31T12:00:00Z',
            'live_at': '2026-05-31T12:02:00Z',
          },
          <String, dynamic>{
            'release_id': '20260530t113000z-fedcba98',
            'status': 'retained',
            'commit_sha': 'fedcba9876543210',
            'created_at': '2026-05-30T11:30:00Z',
          },
        ];
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await seedReleaseInventory(
          database,
          project: selectedProject,
          server: credentiallessServer,
          releases: releaseInventory,
        );

        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          server: credentiallessServer,
        );
        await expandAppDisclosure(
          tester,
          const Key('app-release-history-card'),
        );
        await tester.ensureVisible(
          find.byKey(const Key('app-release-row-rollback-0')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('app-release-row-rollback-0')));
        await tester.pumpAndSettle();

        expect(find.text('Server needed'), findsOneWidget);
        expect(
          find.text('Select a server before rolling back this web app.'),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(FilledButton, 'OK'));
        await tester.pumpAndSettle();
        expect(find.text('Server needed'), findsNothing);
      });

      testWidgets('successful rollback shows Rollback finished with the msg', (
        WidgetTester tester,
      ) async {
        final releaseInventory = <Map<String, dynamic>>[
          <String, dynamic>{
            'release_id': '20260531t120000z-abcdef12',
            'status': 'live',
            'commit_sha': 'abcdef1234567890',
            'created_at': '2026-05-31T12:00:00Z',
            'live_at': '2026-05-31T12:02:00Z',
          },
          <String, dynamic>{
            'release_id': '20260530t113000z-fedcba98',
            'status': 'retained',
            'commit_sha': 'fedcba9876543210',
            'created_at': '2026-05-30T11:30:00Z',
          },
        ];
        final sshService = RuntimeWorkflowSshService()
          ..listReleasesResponse = <String, dynamic>{
            'status': 'success',
            'msg': 'Release inventory captured.',
            'live_release_id': '20260531t120000z-abcdef12',
            'releases': releaseInventory,
          }
          ..rollbackResponse = <String, dynamic>{
            'status': 'success',
            'msg': 'Rollback completed.',
          };
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await seedReleaseInventory(
          database,
          project: selectedProject,
          server: serverWithRuntimeCredentials,
          releases: releaseInventory,
        );

        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
        );
        await expandAppDisclosure(
          tester,
          const Key('app-release-history-card'),
        );
        await tester.ensureVisible(
          find.byKey(const Key('app-release-row-rollback-0')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('app-release-row-rollback-0')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Rollback'));
        await tester.pumpAndSettle();

        expect(find.text('Rollback finished'), findsOneWidget);
        expect(find.text('Rollback completed.'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'OK'));
        await tester.pumpAndSettle();
        expect(find.text('Rollback finished'), findsNothing);
      });

      testWidgets('failed rollback shows Rollback failed with the error', (
        WidgetTester tester,
      ) async {
        final releaseInventory = <Map<String, dynamic>>[
          <String, dynamic>{
            'release_id': '20260531t120000z-abcdef12',
            'status': 'live',
            'commit_sha': 'abcdef1234567890',
            'created_at': '2026-05-31T12:00:00Z',
            'live_at': '2026-05-31T12:02:00Z',
          },
          <String, dynamic>{
            'release_id': '20260530t113000z-fedcba98',
            'status': 'retained',
            'commit_sha': 'fedcba9876543210',
            'created_at': '2026-05-30T11:30:00Z',
          },
        ];
        final sshService = _ThrowingRollbackSshService();
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await seedReleaseInventory(
          database,
          project: selectedProject,
          server: serverWithRuntimeCredentials,
          releases: releaseInventory,
        );

        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
        );
        await expandAppDisclosure(
          tester,
          const Key('app-release-history-card'),
        );
        await tester.ensureVisible(
          find.byKey(const Key('app-release-row-rollback-0')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('app-release-row-rollback-0')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Rollback'));
        await tester.pumpAndSettle();

        expect(find.text('Rollback failed'), findsOneWidget);
        expect(
          find.textContaining('Rollback failed: Bad state'),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(FilledButton, 'OK'));
        await tester.pumpAndSettle();
        expect(find.text('Rollback failed'), findsNothing);
      });

      testWidgets('release history without a connection keeps error-state', (
        WidgetTester tester,
      ) async {
        // D-43 NARROW: the release-history resolve block reports a missing
        // connection as error-state (never a silent return like resource
        // usage). Staged with a credential-less server id (see above).
        const credentiallessServer = Server(
          id: 'server-no-credentials',
          name: 'srv.nocreds.local',
          host: '192.168.1.31',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.password,
          serviceDatabaseEnabled: false,
          serviceEmailEnabled: false,
          serviceDomainEnabled: false,
        );
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await seedReleaseInventory(
          database,
          project: selectedProject,
          server: credentiallessServer,
          releases: <Map<String, dynamic>>[
            <String, dynamic>{
              'release_id': '20260531t120000z-abcdef12',
              'status': 'live',
              'commit_sha': 'abcdef1234567890',
              'created_at': '2026-05-31T12:00:00Z',
              'live_at': '2026-05-31T12:02:00Z',
            },
          ],
        );

        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          server: credentiallessServer,
        );
        await expandAppDisclosure(
          tester,
          const Key('app-release-history-card'),
        );

        await tester.tap(
          find.byKey(const Key('app-release-history-refresh-button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Select a server to read release history.'),
          findsOneWidget,
        );
      });
    },
  );
}

class _ThrowingRollbackSshService extends RuntimeWorkflowSshService {
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
    if (workflowId == 'app' && operationId == 'rollback') {
      throw StateError('rollback transport exploded');
    }
    return super.runWorkflowLegacy(
      workflowId: workflowId,
      operationId: operationId,
      connection: connection,
      params: params,
      onEvent: onEvent,
      onTaskStarted: onTaskStarted,
      serializePerHost: serializePerHost,
    );
  }
}
