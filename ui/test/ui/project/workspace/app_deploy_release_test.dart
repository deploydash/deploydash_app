import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/data/local/app_database.dart';
import 'package:ui/models/deploy_failure_evidence.dart';
import 'package:ui/services/app_analytics_service.dart';

import '../../../_support/fake_analytics_service.dart';
import '_support/project_workspace_harness.dart';

/// project workspace releases and deploys.
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

  group('project workspace releases and deploys', () {
    testWidgets('Failed deployment shows its phase and relevant output', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final notifier = MutableGitHubIntegrationNotifier(
        GitHubIntegrationState(
          connectStatus: GitHubConnectStatus.connected,
          authToken: 'token',
          selectedRepositoryFullName: 'deploydash/laravel-example-app',
          selectedRepositoryFullNameByProjectId: const <String, String>{
            'project-1': 'deploydash/laravel-example-app',
          },
          projectDeployStates: <String, GitHubProjectDeployState>{
            selectedProject.id: GitHubProjectDeployState(
              selectedRepositoryFullName: 'deploydash/laravel-example-app',
              deployStatus: GitHubDeployStatus.error,
              statusMessage: 'Deployment failed while building the release.',
              failureEvidence: DeployFailureEvidence(
                phase: DeployFailurePhase.build,
                source: DeployFailureSource.failedOperation,
                completeness: DeployFailureCompleteness.diagnostic,
                lines: const <String>['compiler: missing generated file'],
              ),
            ),
          },
        ),
      );

      await pumpProjectWorkspace(
        tester,
        overrides: [
          gitHubIntegrationProvider.overrideWith(() => notifier),
          projectListProvider.overrideWith(
            () => StaticProjectListNotifier([selectedProject]),
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(
            serverWithRuntimeCredentials,
          ),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
      );

      expect(
        find.text('Deployment failed while building the release.'),
        findsOneWidget,
      );
      expect(find.text('Deployment stopped during build'), findsOneWidget);
      expect(find.text('Relevant failure output'), findsOneWidget);
      expect(find.text('compiler: missing generated file'), findsOneWidget);

      MethodCall? clipboardCall;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          clipboardCall = call;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.byKey(const Key('deploy-failure-copy-button')));
      await tester.pump();
      expect(clipboardCall?.method, 'Clipboard.setData');
      expect(clipboardCall?.arguments, <String, dynamic>{
        'text':
            'Deployment stopped during build\n'
            'Deployment failed while building the release.\n'
            'Relevant failure output\n'
            'compiler: missing generated file',
      });

      await tester.tap(
        find.byKey(const Key('deploy-failure-open-logs-button')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('log-deployment-tab')), findsOneWidget);
      expect(analytics.controlUses.map((event) => event.control.name), <String>[
        'deployFailureDetailsCopied',
        'deployFailureLogsOpened',
      ]);
    });

    testWidgets(
      'Failure card follows project selection and only renders for errors',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectA = projectFixture(
          id: 'project-failure-a',
          name: 'Project A',
          serverId: serverWithRuntimeCredentials.id,
          primaryDomain: 'a.example.com',
        );
        final projectB = projectFixture(
          id: 'project-failure-b',
          name: 'Project B',
          serverId: serverWithRuntimeCredentials.id,
          primaryDomain: 'b.example.com',
        );
        final evidenceA = DeployFailureEvidence(
          phase: DeployFailurePhase.build,
          source: DeployFailureSource.failedOperation,
          completeness: DeployFailureCompleteness.diagnostic,
          lines: const <String>['project A output'],
        );
        final evidenceB = DeployFailureEvidence(
          phase: DeployFailurePhase.candidateReadiness,
          source: DeployFailureSource.candidateProbe,
          completeness: DeployFailureCompleteness.diagnostic,
          lines: const <String>['project B output'],
        );
        final notifier = MutableGitHubIntegrationNotifier(
          GitHubIntegrationState(
            connectStatus: GitHubConnectStatus.connected,
            authToken: 'token',
            selectedRepositoryFullNameByProjectId: <String, String>{
              projectA.id: 'deploydash/deploydash-agent-access',
              projectB.id: 'deploydash/amplitude-flutter-desktop',
            },
            projectDeployStates: <String, GitHubProjectDeployState>{
              projectA.id: GitHubProjectDeployState(
                selectedRepositoryFullName:
                    'deploydash/deploydash-agent-access',
                deployStatus: GitHubDeployStatus.error,
                statusMessage: 'Project A failed.',
                failureEvidence: evidenceA,
              ),
              projectB.id: GitHubProjectDeployState(
                selectedRepositoryFullName:
                    'deploydash/amplitude-flutter-desktop',
                deployStatus: GitHubDeployStatus.error,
                statusMessage: 'Project B failed.',
                failureEvidence: evidenceB,
              ),
            },
          ),
        );
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            gitHubIntegrationProvider.overrideWith(() => notifier),
            projectListProvider.overrideWith(
              () => StaticProjectListNotifier([projectA, projectB]),
            ),
            selectedServerIdProvider.overrideWithValue(
              serverWithRuntimeCredentials.id,
            ),
            selectedServerProvider.overrideWithValue(
              serverWithRuntimeCredentials,
            ),
            serverConnectionPayloadResolverProvider.overrideWithValue(
              testServerConnectionPayload,
            ),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });
        container.read(selectedProjectIdProvider.notifier).select(projectA.id);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1920, 1080);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: ProjectWorkspace())),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('project A output'), findsOneWidget);
        expect(find.text('project B output'), findsNothing);

        container.read(selectedProjectIdProvider.notifier).select(projectB.id);
        await tester.pump();
        await tester.pump();
        expect(find.text('project A output'), findsNothing);
        expect(find.text('project B output'), findsOneWidget);

        for (final status in GitHubDeployStatus.values.where(
          (status) => status != GitHubDeployStatus.error,
        )) {
          notifier.publish(
            GitHubIntegrationState(
              connectStatus: GitHubConnectStatus.connected,
              authToken: 'token',
              selectedRepositoryFullNameByProjectId: <String, String>{
                projectB.id: 'deploydash/amplitude-flutter-desktop',
              },
              projectDeployStates: <String, GitHubProjectDeployState>{
                projectB.id: GitHubProjectDeployState(
                  selectedRepositoryFullName:
                      'deploydash/amplitude-flutter-desktop',
                  deployStatus: status,
                  statusMessage: status == GitHubDeployStatus.idle
                      ? 'Deployment cancelled.'
                      : 'Not a failed deployment.',
                  failureEvidence: evidenceB,
                ),
              },
            ),
          );
          await tester.pump();
          expect(
            find.byKey(const Key('deploy-failure-card')),
            findsNothing,
            reason: 'Unexpected card for $status',
          );
        }
      },
    );

    testWidgets('Web app tab keeps pre-deploy setup focused and neutral', (
      WidgetTester tester,
    ) async {
      await pumpProjectWorkspace(tester);

      expect(
        find.byKey(
          const Key('app-context-navigation-project-workspace-vertical'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('app-live-state-card')), findsOneWidget);
      expect(find.text('Not deployed'), findsOneWidget);
      expect(find.text('Checking'), findsNothing);
      expect(find.byKey(const Key('app-new-deploy-card')), findsOneWidget);
      expect(find.byKey(const Key('connect-github-button')), findsOneWidget);
      expect(find.byKey(const Key('github-repo-dropdown')), findsNothing);
      expect(find.byKey(const Key('github-deploy-button')), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const Key('app-new-deploy-card'))).dy,
        lessThan(tester.getTopLeft(find.text('Current deployment')).dy),
      );
      final appScroll = find
          .descendant(
            of: find.byKey(const Key('app-tab-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('app-env-card')),
        300,
        scrollable: appScroll,
      );
      expect(find.byKey(const Key('env-edit-button')), findsOneWidget);
      expect(find.byKey(const Key('app-env-empty-state')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('app-env-empty-state')),
          matching: find.byType(AppEmptyStateView),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('app-oneoff-command-card')), findsNothing);
      expect(find.byKey(const Key('app-release-history-card')), findsNothing);
      expect(find.byKey(const Key('app-disconnect-card')), findsNothing);
      expect(find.byKey(const Key('app-activity-card')), findsNothing);
      expect(find.byKey(const Key('app-history-card')), findsNothing);
      expect(find.byKey(const Key('app-runtime-card')), findsNothing);
      expect(
        find.byKey(const Key('github-callback-field')),
        showManualGitHubCallbackToolsForTest ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const Key('github-process-callback-button')),
        showManualGitHubCallbackToolsForTest ? findsOneWidget : findsNothing,
      );
    });

    testWidgets('Connect GitHub shows visible progress and OAuth fallback', (
      WidgetTester tester,
    ) async {
      await pumpProjectWorkspace(
        tester,
        overrides: [
          gitHubAuthGatewayProvider.overrideWithValue(GitHubReadyGateway()),
        ],
      );

      await tester.tap(find.byKey(const Key('connect-github-button')));
      await tester.pump();

      expect(find.byKey(const Key('github-connect-feedback')), findsOneWidget);
      expect(find.byKey(const Key('github-connect-progress')), findsOneWidget);
      expect(
        find.byKey(const Key('github-connect-status-message')),
        findsOneWidget,
      );
      expect(
        find.text(
          'Authorize Deploy Dash in browser, then return via deploydash://callback.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('github-copy-oauth-url-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('github-open-oauth-url-button')),
        findsOneWidget,
      );
    });

    testWidgets('manual GitHub callback tools process an entered callback', (
      WidgetTester tester,
    ) async {
      await pumpProjectWorkspace(tester);

      await tester.enterText(
        find.byKey(const Key('github-callback-field')),
        'deploydash://callback?code=manual-code',
      );
      await tester.tap(find.byKey(const Key('github-process-callback-button')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    }, skip: !showManualGitHubCallbackToolsForTest);

    testWidgets('Repository selection fills the compact deployment panel', (
      WidgetTester tester,
    ) async {
      const unselectedProject = Project(
        id: 'project-without-repository',
        name: 'New web app',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'new.example.com',
      );
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(unselectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: unselectedProject,
        projectNotifier: projectNotifier,
        selectRepository: false,
        viewSize: const Size(480, 900),
      );

      final dropdown = find.byKey(const Key('github-repo-dropdown'));
      expect(dropdown, findsOneWidget);
      final panel = find.byKey(const Key('app-new-deploy-card'));
      expect(
        tester.getSize(dropdown).width,
        lessThanOrEqualTo(tester.getSize(panel).width),
      );
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('deploydash/laravel-example-app').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('github-deploy-button')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Deployment preflight renders each checked requirement', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
      );

      await tester.ensureVisible(
        find.byKey(const Key('github-preflight-button')),
      );
      await tester.tap(find.byKey(const Key('github-preflight-button')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.textContaining('Preflight:'), findsOneWidget);
      expect(find.textContaining('GitHub authorization:'), findsOneWidget);
      expect(find.textContaining('Repository selected:'), findsOneWidget);
      expect(find.textContaining('Primary domain:'), findsOneWidget);
    });

    testWidgets(
      'restored deployment metadata keeps its existing repository label',
      (WidgetTester tester) async {
        const restoredProject = Project(
          id: 'project-restored-without-repository',
          name: 'Restored web app',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'restored.example.com',
          lastDeployCommit: 'restoredcommit1234',
          appPort: 3000,
        );
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(restoredProject),
            selectedServerProvider.overrideWithValue(
              serverWithRuntimeCredentials,
            ),
          ],
        );

        expect(find.text('Not selected'), findsAtLeastNWidgets(1));
        expect(find.byKey(const Key('app-live-state-card')), findsOneWidget);
      },
    );

    testWidgets(
      'deployment surface keeps the local view usable after history load failure',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final history = ThrowingAppDeploymentHistoryRepository(
          StateError('history database unavailable'),
        );
        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            appDeploymentHistoryRepositoryProvider.overrideWithValue(history),
            selectedProjectProvider.overrideWithValue(
              selectedProjectWithLiveRuntime,
            ),
            selectedServerProvider.overrideWithValue(
              serverWithRuntimeCredentials,
            ),
          ],
        );

        await expandAppDisclosure(
          tester,
          const Key('app-release-history-card'),
        );

        expect(
          find.textContaining(
            'Could not read saved release history: Bad state: history database unavailable',
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('app-new-deploy-card')), findsOneWidget);
      },
    );

    testWidgets('malformed release env json propagates its FormatException', (
      WidgetTester tester,
    ) async {
      // D-45 pair 2 (T-021) characterization: N1 has no try/catch, so
      // malformed runtimeEnvJson throws out of the mapper. Two sinks
      // exist (the load-path catch that sets the history banner, and
      // the tab-build mapper call); this pins the throw itself, which
      // the stringify routing must preserve.
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
      final now = DateTime.utc(2026, 1, 1);
      await AppReleaseRepository(database).upsertRelease(
        AppReleaseRecord(
          id: 'release-row',
          projectId: selectedProject.id,
          serverId: serverWithRuntimeCredentials.id,
          releaseId: 'release-one',
          status: 'live',
          runtimeEnvJson: '{malformed',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(
            serverWithRuntimeCredentials,
          ),
        ],
      );
      await tester.pumpAndSettle();

      // Every escape is the decode FormatException (rebuilds re-throw).
      var sawThrow = false;
      Object? pending;
      do {
        pending = tester.takeException();
        if (pending != null) {
          sawThrow = true;
          expect(pending, isFormatException);
        }
      } while (pending != null);
      expect(sawThrow, isTrue);
    });

    testWidgets('current deployment opens its valid public URL externally', (
      WidgetTester tester,
    ) async {
      final previousLauncher = UrlLauncherPlatform.instance;
      final launcher = RecordingUrlLauncher();
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() => UrlLauncherPlatform.instance = previousLauncher);

      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        seedLiveRelease: true,
      );

      final openUrl = find.byTooltip('Open URL');
      await tester.ensureVisible(openUrl);
      await tester.tap(openUrl);
      await tester.pumpAndSettle();

      expect(launcher.launchedUrl, 'https://dev.buildingregs.app');
    });

    testWidgets('GitHub deployment state transitions stay project-scoped', (
      WidgetTester tester,
    ) async {
      const otherProject = Project(
        id: 'project-other',
        name: 'Other web app',
        type: 'Web app',
        gitUrl: 'https://github.com/example/other',
        primaryDomain: 'other.example.com',
        repositoryFullName: 'deploydash/amplitude-flutter-desktop',
        appSubdirectory: 'website',
        appPort: 3000,
      );
      final notifier = MutableGitHubIntegrationNotifier(
        const GitHubIntegrationState(
          connectStatus: GitHubConnectStatus.connected,
          deployStatus: GitHubDeployStatus.idle,
          authToken: 'token',
        ),
      );
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final sshService = RuntimeWorkflowSshService();
      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          gitHubIntegrationProvider.overrideWith(() => notifier),
          projectListProvider.overrideWith(
            () => StaticProjectListNotifier([selectedProject, otherProject]),
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(
            serverWithRuntimeCredentials,
          ),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );
      addTearDown(sshService.dispose);

      notifier.publish(
        GitHubIntegrationState(
          connectStatus: GitHubConnectStatus.connected,
          deployStatus: GitHubDeployStatus.generatingServerKey,
          authToken: 'token',
          activeDeployProjectId: selectedProject.id,
          projectDeployStates: {
            selectedProject.id: const GitHubProjectDeployState(
              deployStatus: GitHubDeployStatus.generatingServerKey,
              activeRunId: 'run-1',
            ),
          },
        ),
      );
      await tester.pumpAndSettle();

      notifier.publish(
        GitHubIntegrationState(
          connectStatus: GitHubConnectStatus.connected,
          deployStatus: GitHubDeployStatus.success,
          authToken: 'token',
          activeDeployProjectId: selectedProject.id,
          projectDeployStates: {
            selectedProject.id: const GitHubProjectDeployState(
              deployStatus: GitHubDeployStatus.success,
              processReadinessStatus: 'ready',
            ),
          },
        ),
      );
      await tester.pumpAndSettle();

      notifier.publish(
        const GitHubIntegrationState(
          connectStatus: GitHubConnectStatus.connected,
          deployStatus: GitHubDeployStatus.idle,
          authToken: 'token',
        ),
      );
      await tester.pumpAndSettle();

      notifier.publish(
        GitHubIntegrationState(
          connectStatus: GitHubConnectStatus.connected,
          deployStatus: GitHubDeployStatus.generatingServerKey,
          authToken: 'token',
          activeDeployProjectId: otherProject.id,
        ),
      );
      await tester.pumpAndSettle();
      notifier.publish(
        GitHubIntegrationState(
          connectStatus: GitHubConnectStatus.connected,
          deployStatus: GitHubDeployStatus.success,
          authToken: 'token',
          activeDeployProjectId: otherProject.id,
          projectDeployStates: {
            otherProject.id: const GitHubProjectDeployState(
              deployStatus: GitHubDeployStatus.success,
              processReadinessStatus: 'ready',
            ),
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('app-new-deploy-card')), findsOneWidget);
    });

    testWidgets('Active deploy shows progress without blocked error copy', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService()
        ..deployRunCompleter = Completer<void>();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
      );

      await tester.tap(find.byKey(const Key('github-deploy-button')));
      await tester.pump();
      for (var attempt = 0; attempt < 20; attempt += 1) {
        if (sshService.workflowCalls.any(
          (call) =>
              call['workflow_id'] == 'app' && call['operation_id'] == 'run',
        )) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(find.text('A deployment is already in progress.'), findsNothing);
      expect(
        find.text('Running web app build and deployment on server...'),
        findsOneWidget,
      );
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('github-deploy-button')),
      );
      expect(button.onPressed, isNull);

      sshService.deployRunCompleter!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('Redeploy button re-enables after successful deploy', (
      WidgetTester tester,
    ) async {
      final deployedProject = selectedProject.copyWith(
        lastDeployCommit: 'abcdef123456',
        lastDeployedAt: DateTime.utc(2026, 3, 21, 12, 0),
      );
      final sshService = RuntimeWorkflowSshService()
        ..deployRunCompleter = Completer<void>();
      addTearDown(() {
        if (!sshService.deployRunCompleter!.isCompleted) {
          sshService.deployRunCompleter!.complete();
        }
        sshService.dispose();
      });
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(deployedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: deployedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
      );

      final buttonBefore = tester.widget<FilledButton>(
        find.byKey(const Key('github-deploy-button')),
      );
      expect(find.widgetWithText(FilledButton, 'Redeploy'), findsOneWidget);
      expect(buttonBefore.onPressed, isNotNull);

      await tester.tap(find.byKey(const Key('github-deploy-button')));
      await tester.pump();
      for (var attempt = 0; attempt < 20; attempt += 1) {
        if (sshService.workflowCalls.any(
          (call) =>
              call['workflow_id'] == 'app' && call['operation_id'] == 'run',
        )) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(find.widgetWithText(FilledButton, 'Deploying...'), findsOneWidget);
      final buttonDuring = tester.widget<FilledButton>(
        find.byKey(const Key('github-deploy-button')),
      );
      expect(buttonDuring.onPressed, isNull);

      sshService.deployRunCompleter!.complete();
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Redeploy'), findsOneWidget);
      final buttonAfter = tester.widget<FilledButton>(
        find.byKey(const Key('github-deploy-button')),
      );
      expect(buttonAfter.onPressed, isNotNull);
    });

    testWidgets(
      'Successful deploy without readiness evidence does not show Ready',
      (WidgetTester tester) async {
        final sshService = RuntimeWorkflowSshService()
          ..resourceUsageResponse = const <String, dynamic>{
            'status': 'success',
            'public_health': <String, dynamic>{
              'enabled': true,
              'status': 'unknown',
              'path': '/',
            },
          };
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
        );

        await tester.tap(find.byKey(const Key('github-deploy-button')));
        await tester.pumpAndSettle();

        expect(
          tester.widget<Text>(find.byKey(const Key('github-status-text'))).data,
          'Public URL not checked',
        );
      },
    );

    testWidgets(
      'Successful deploy with failed public health shows Needs attention',
      (WidgetTester tester) async {
        const publicFailure = <String, dynamic>{
          'enabled': true,
          'status': 'unhealthy',
          'path': '/',
          'http_status': 500,
        };
        final sshService = RuntimeWorkflowSshService()
          ..appRunResponse = const <String, dynamic>{
            'status': 'success',
            'msg': 'Web app deployed.',
            'process_readiness': <String, dynamic>{'status': 'ready'},
            'public_health': publicFailure,
          }
          ..resourceUsageResponse = const <String, dynamic>{
            'status': 'success',
            'container_status': <String, dynamic>{
              'present': true,
              'docker_state': 'running',
              'running': true,
              'health': 'healthy',
              'effective_status': 'ready',
            },
            'public_health': publicFailure,
          };
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
        );

        await tester.tap(find.byKey(const Key('github-deploy-button')));
        await tester.pumpAndSettle();

        expect(
          tester.widget<Text>(find.byKey(const Key('github-status-text'))).data,
          'Needs attention',
        );
        expect(
          find.byKey(const Key('app-public-health-warning')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('app-public-health-warning-detail')),
          findsOneWidget,
        );
      },
    );

    testWidgets('Failed deploy persists failed release inventory', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService()
        ..appRunResponse = const <String, dynamic>{
          'status': 'error',
          'msg':
              'Candidate release failed post-cutover stabilization and was reverted.',
          'release_id': '20260808t120000z-deadbeef1234',
          'commit_sha': 'deadbeef1234567890',
          'rollback_status': 'not_required',
          'release_inventory': <String, dynamic>{
            'live_release_id': null,
            'releases': <Map<String, dynamic>>[
              <String, dynamic>{
                'release_id': '20260808t120000z-deadbeef1234',
                'status': 'failed',
                'deployment_kind': 'deploy',
                'branch': 'main',
                'commit_sha': 'deadbeef1234567890',
                'created_at': '2026-08-08T12:00:00Z',
                'rollback_reason': 'post_cutover_stabilization_failed',
              },
            ],
          },
        };
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
      );

      await tester.tap(find.byKey(const Key('github-deploy-button')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('github-status-text'))).data,
        'Attention needed',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('deploy-status-message')))
            .data,
        'Candidate release failed post-cutover stabilization and was reverted.',
      );
      final releases = await AppReleaseRepository(database)
          .listReleasesForScope(
            projectId: selectedProject.id,
            serverId: serverWithRuntimeCredentials.id,
          );
      expect(releases, hasLength(1));
      expect(releases.single.releaseId, '20260808t120000z-deadbeef1234');
      expect(releases.single.status, 'failed');
      expect(
        releases.single.rollbackReason,
        'post_cutover_stabilization_failed',
      );
    });

    testWidgets('Web app live operations stay collapsed at compact widths', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        viewSize: const Size(650, 1000),
        seedLiveRelease: true,
      );

      expect(
        find.byKey(
          const Key('app-context-navigation-project-workspace-horizontal'),
        ),
        findsOneWidget,
      );

      expect(find.byKey(const Key('app-env-card')), findsOneWidget);
      expect(find.byKey(const Key('app-oneoff-command-card')), findsOneWidget);
      expect(find.byKey(const Key('app-oneoff-command-field')), findsNothing);
      expect(find.text('Publish your next release'), findsOneWidget);
      expect(find.text('Step 3: Review settings'), findsNothing);

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
      expect(find.byKey(const Key('app-oneoff-command-field')), findsOneWidget);
      expect(
        find.byKey(const Key('app-oneoff-output-empty-state')),
        findsOneWidget,
      );
    });

    testWidgets(
      'Web app live release and danger actions stay secondary and local-first',
      (WidgetTester tester) async {
        final sshService = RuntimeWorkflowSshService();
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
          seedLiveRelease: true,
        );

        expect(
          find.byKey(const Key('app-release-history-card')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('app-disconnect-card')), findsOneWidget);
        expect(
          find.byKey(const Key('app-release-history-refresh-button')),
          findsNothing,
        );
        expect(find.byKey(const Key('app-disconnect-button')), findsNothing);

        await expandAppDisclosure(
          tester,
          const Key('app-release-history-card'),
        );
        expect(
          find.byKey(const Key('app-release-history-refresh-button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('app-release-history-empty-text')),
          findsOneWidget,
        );
        expect(find.text('No previous releases'), findsOneWidget);
        expect(find.text('Recent releases'), findsNothing);

        await expandAppDisclosure(tester, const Key('app-disconnect-card'));
        expect(find.byKey(const Key('app-disconnect-button')), findsOneWidget);
        expect(
          sshService.workflowCalls.any(
            (call) =>
                call['workflow_id'] == 'app' &&
                call['operation_id'] == 'list_releases',
          ),
          isFalse,
        );
      },
    );

    testWidgets(
      'Web app release history shows loading state while refreshing',
      (WidgetTester tester) async {
        final sshService = RuntimeWorkflowSshService()
          ..listReleasesCompleter = Completer<void>();
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
          seedLiveRelease: true,
        );

        await expandAppDisclosure(
          tester,
          const Key('app-release-history-card'),
        );
        await tester.tap(
          find.byKey(const Key('app-release-history-refresh-button')),
        );
        await tester.pump();

        expect(
          find.byKey(const Key('app-release-history-loading-text')),
          findsOneWidget,
        );
        expect(find.text('Reading release history...'), findsOneWidget);

        sshService.listReleasesCompleter!.complete();
        await tester.pumpAndSettle();
      },
    );

    testWidgets('Web app restores last-known ready state after restart', (
      WidgetTester tester,
    ) async {
      final deployedProject = selectedProject.copyWith(
        lastDeployCommit: 'abcdef123456',
        lastDeployedAt: DateTime.utc(2026, 3, 21, 12, 0),
      );
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(deployedProject);
      await AppReleaseRepository(database).upsertRuntimeSnapshot(
        AppRuntimeSnapshotRecord(
          projectId: deployedProject.id,
          serverId: serverWithRuntimeCredentials.id,
          healthStatus: 'ready',
          publicHealthJson:
              '{"enabled":true,"status":"healthy","path":"/","http_status":200}',
          healthCheckedAt: DateTime.utc(2026, 3, 21, 12, 1),
          updatedAt: DateTime.utc(2026, 3, 21, 12, 1),
        ),
      );

      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: deployedProject,
        projectNotifier: projectNotifier,
      );

      expect(find.byKey(const Key('app-live-state-card')), findsOneWidget);
      expect(find.byKey(const Key('github-status-text')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('github-status-text'))).data,
        'Ready',
      );
      expect(find.text('abcdef123456'), findsOneWidget);
      expect(find.text('Checking'), findsNothing);
    });

    testWidgets(
      'Web app separates process readiness from failed public URL health',
      (WidgetTester tester) async {
        final deployedProject = selectedProject.copyWith(
          lastDeployCommit: 'abcdef123456',
          lastDeployedAt: DateTime.utc(2026, 3, 21, 12),
        );
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(deployedProject);
        await AppReleaseRepository(database).upsertRuntimeSnapshot(
          AppRuntimeSnapshotRecord(
            projectId: deployedProject.id,
            serverId: serverWithRuntimeCredentials.id,
            healthStatus: 'ready',
            publicHealthJson:
                '{"enabled":true,"status":"unhealthy","path":"/","http_status":500,"error":"The public URL returned HTTP 500."}',
            healthCheckedAt: DateTime.utc(2026, 3, 21, 12, 1),
            updatedAt: DateTime.utc(2026, 3, 21, 12, 1),
          ),
        );

        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: deployedProject,
          projectNotifier: projectNotifier,
        );

        expect(find.text('Needs attention'), findsOneWidget);
        expect(find.text('Ready'), findsOneWidget);
        expect(
          find.byKey(const Key('app-public-health-warning')),
          findsOneWidget,
        );
        expect(
          find.textContaining('Public URL check failed (HTTP 500) at /.'),
          findsOneWidget,
        );

        await tester.ensureVisible(
          find.byKey(const Key('app-public-health-environment-button')),
        );
        await tester.tap(
          find.byKey(const Key('app-public-health-environment-button')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Environment variables'), findsWidgets);
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('app-public-health-runtime-logs-button')),
        );
        await tester.tap(
          find.byKey(const Key('app-public-health-runtime-logs-button')),
        );
        await tester.pumpAndSettle();
        expect(find.widgetWithText(Tab, 'Web app runtime'), findsOneWidget);
      },
    );

    testWidgets('Web app restores failed deploy attempt after restart', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await AppDeploymentHistoryRepository(database).append(
        projectId: selectedProject.id,
        status: 'failed',
        deployedAt: DateTime.utc(2026, 3, 21, 12, 0),
        durationSeconds: 17,
        actor: 'local-user',
        branch: 'main',
        commit: 'badcafe123456',
      );

      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
      );

      expect(find.byKey(const Key('app-live-state-card')), findsOneWidget);
      expect(find.text('Attention needed'), findsOneWidget);
      expect(find.text('badcafe123456'), findsOneWidget);
      expect(find.text('Not synced yet'), findsNothing);
      expect(find.text('Never'), findsNothing);
    });

    testWidgets(
      'Web app restores the latest failed deploy evidence once after restart',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        final repository = AppReleaseRepository(database);
        final journal = await repository.createJournalEntry(
          projectId: selectedProject.id,
          serverId: serverWithRuntimeCredentials.id,
          surface: 'app',
          operationType: 'run',
        );
        await repository.updateJournalStatus(
          id: journal.id,
          status: 'failed',
          result: <String, dynamic>{
            'status': 'error',
            'code': 'ENGINE_OPERATION_FAILED',
            'msg': 'Build failed.',
            'failure_evidence': <String, dynamic>{
              'schema_version': 1,
              'phase': 'build',
              'source': 'failed_operation',
              'completeness': 'diagnostic',
              'lines': <String>['compiler failed at lib/main.dart:12'],
              'failed_step_id': 'release',
              'failed_action_id': 'build',
              'probe': null,
            },
          },
        );

        final container = await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
        );

        var state = container.read(gitHubIntegrationProvider);
        expect(
          state.failureEvidenceForProject(selectedProject.id)?.lines,
          <String>['compiler failed at lib/main.dart:12'],
        );
        expect(
          state.statusMessageForProject(selectedProject.id),
          'Build failed.',
        );
        await container
            .read(gitHubIntegrationProvider.notifier)
            .restoreLatestDeployFailure(
              projectId: selectedProject.id,
              server: serverWithRuntimeCredentials,
            );
        state = container.read(gitHubIntegrationProvider);
        expect(state.failureEvidence?.lines, <String>[
          'compiler failed at lib/main.dart:12',
        ]);

        final logs = await TerminalLogRepository(database)
            .listRecentLogsForScope(
              projectId: selectedProject.id,
              serverId: serverWithRuntimeCredentials.id,
            );
        expect(logs, hasLength(1));
        expect(logs.single.source, 'app_deploy_failure_evidence');
        expect(logs.single.message, 'compiler failed at lib/main.dart:12');
      },
    );

    testWidgets(
      'newer successful deploy suppresses older failed journal evidence',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        final repository = AppReleaseRepository(database);
        final failed = await repository.createJournalEntry(
          projectId: selectedProject.id,
          serverId: serverWithRuntimeCredentials.id,
          surface: 'app',
          operationType: 'run',
        );
        await repository.updateJournalStatus(
          id: failed.id,
          status: 'failed',
          result: <String, dynamic>{
            'status': 'error',
            'msg': 'Old failure.',
            'failure_evidence': <String, dynamic>{
              'schema_version': 1,
              'phase': 'build',
              'source': 'failed_operation',
              'completeness': 'diagnostic',
              'lines': <String>['old compiler failure'],
              'failed_step_id': 'release',
              'failed_action_id': 'build',
              'probe': null,
            },
          },
        );
        final succeeded = await repository.createJournalEntry(
          projectId: selectedProject.id,
          serverId: serverWithRuntimeCredentials.id,
          surface: 'app',
          operationType: 'run',
        );
        await repository.updateJournalStatus(
          id: succeeded.id,
          status: 'committed_local',
          result: <String, dynamic>{'status': 'success'},
        );

        final container = await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
        );

        expect(
          container
              .read(gitHubIntegrationProvider)
              .failureEvidenceForProject(selectedProject.id),
          isNull,
        );
        expect(
          await TerminalLogRepository(database).listRecentLogsForScope(
            projectId: selectedProject.id,
            serverId: serverWithRuntimeCredentials.id,
          ),
          isEmpty,
        );
      },
    );

    testWidgets(
      'malformed and wrong-operation journal results are ignored safely',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        final repository = AppReleaseRepository(database);
        final wrongOperation = await repository.createJournalEntry(
          projectId: selectedProject.id,
          serverId: serverWithRuntimeCredentials.id,
          surface: 'app',
          operationType: 'rollback',
        );
        await repository.updateJournalStatus(
          id: wrongOperation.id,
          status: 'failed',
          result: <String, dynamic>{'status': 'error'},
        );
        final malformed = await repository.createJournalEntry(
          projectId: selectedProject.id,
          serverId: serverWithRuntimeCredentials.id,
          surface: 'app',
          operationType: 'run',
        );
        await (database.update(
          database.projectManagedOperationJournal,
        )..where((table) => table.id.equals(malformed.id))).write(
          const ProjectManagedOperationJournalCompanion(
            status: Value('failed'),
            resultJson: Value('{not json'),
          ),
        );

        final container = await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
        );

        expect(tester.takeException(), isNull);
        expect(
          container
              .read(gitHubIntegrationProvider)
              .failureEvidenceForProject(selectedProject.id),
          isNull,
        );
      },
    );

    testWidgets('Web app release history shows live and retained releases', (
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
        <String, dynamic>{
          'release_id': '20260529t101500z-deadbeef',
          'status': 'failed',
          'commit_sha': 'deadbeef12345678',
          'created_at': '2026-05-29T10:15:00Z',
          'rollback_from_release_id': '20260531t120000z-abcdef12',
        },
      ];
      final sshService = RuntimeWorkflowSshService()
        ..listReleasesResponse = <String, dynamic>{
          'status': 'success',
          'msg': 'Release inventory captured.',
          'live_release_id': '20260531t120000z-abcdef12',
          'releases': releaseInventory,
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

      await expandAppDisclosure(tester, const Key('app-release-history-card'));

      expect(find.text('20260531t120000z-abcdef12'), findsOneWidget);
      expect(find.textContaining('fedcba987654'), findsOneWidget);
      expect(find.text('Current live release'), findsNothing);
      expect(find.text('Previous releases'), findsOneWidget);
      expect(find.text('Rollback to previous release'), findsOneWidget);
      expect(find.text('Rollback to this release'), findsOneWidget);
      expect(
        sshService.workflowCalls.any(
          (call) =>
              call['workflow_id'] == 'app' &&
              call['operation_id'] == 'list_releases',
        ),
        isFalse,
      );
    });

    testWidgets('Web app release rows truncate commits and name unknowns', (
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
        <String, dynamic>{
          'release_id': '20260529t101500z-unknownsha',
          'status': 'failed',
          'created_at': '2026-05-29T10:15:00Z',
        },
      ];
      final sshService = RuntimeWorkflowSshService()
        ..listReleasesResponse = <String, dynamic>{
          'status': 'success',
          'msg': 'Release inventory captured.',
          'live_release_id': '20260531t120000z-abcdef12',
          'releases': releaseInventory,
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

      await expandAppDisclosure(tester, const Key('app-release-history-card'));

      // Exact text: a substring match would also accept an untruncated sha.
      expect(find.text('Commit fedcba987654'), findsOneWidget);
      expect(find.text('Commit Unknown'), findsOneWidget);
    });

    testWidgets('Web app release rollback forwards the retained release id', (
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
          'release_id': '20260531t130000z-fedcba98',
          'rollback_from_release_id': '20260531t120000z-abcdef12',
          'commit_sha': 'fedcba9876543210',
          'release_entry': <String, dynamic>{
            'release_id': '20260531t130000z-fedcba98',
            'status': 'live',
            'deployment_kind': 'rollback',
            'rollback_from_release_id': '20260531t120000z-abcdef12',
            'commit_sha': 'fedcba9876543210',
            'created_at': '2026-05-31T13:00:00Z',
            'live_at': '2026-05-31T13:02:00Z',
          },
          'release_inventory': <String, dynamic>{
            'live_release_id': '20260531t130000z-fedcba98',
            'releases': <Map<String, dynamic>>[
              <String, dynamic>{
                'release_id': '20260531t130000z-fedcba98',
                'status': 'live',
                'deployment_kind': 'rollback',
                'rollback_from_release_id': '20260531t120000z-abcdef12',
                'commit_sha': 'fedcba9876543210',
                'created_at': '2026-05-31T13:00:00Z',
                'live_at': '2026-05-31T13:02:00Z',
              },
              <String, dynamic>{
                'release_id': '20260531t120000z-abcdef12',
                'status': 'retained',
                'commit_sha': 'abcdef1234567890',
                'created_at': '2026-05-31T12:00:00Z',
                'live_at': '2026-05-31T12:02:00Z',
              },
            ],
          },
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

      await expandAppDisclosure(tester, const Key('app-release-history-card'));

      await tester.ensureVisible(
        find.byKey(const Key('app-release-row-rollback-0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('app-release-row-rollback-0')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Rollback'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Rollback'));
      await tester.pumpAndSettle();

      final rollbackCall = sshService.workflowCalls.lastWhere(
        (call) =>
            call['workflow_id'] == 'app' && call['operation_id'] == 'rollback',
      );
      final params = rollbackCall['params'] as Map<String, dynamic>;
      expect(params['release_id'], '20260530t113000z-fedcba98');

      final rows = await AppDeploymentHistoryRepository(
        database,
      ).listForProject(selectedProject.id);
      expect(rows.first.deploymentKind, 'rollback');
      expect(rows.first.releaseId, '20260531t130000z-fedcba98');
      expect(rows.first.rollbackFromReleaseId, '20260531t120000z-abcdef12');
      expect(
        sshService.workflowCalls
            .where(
              (call) =>
                  call['workflow_id'] == 'app' &&
                  call['operation_id'] == 'list_releases',
            )
            .length,
        0,
      );
      final releases = await AppReleaseRepository(database)
          .listReleasesForScope(
            projectId: selectedProject.id,
            serverId: serverWithRuntimeCredentials.id,
          );
      expect(releases.first.releaseId, '20260531t130000z-fedcba98');
      expect(releases.first.deploymentKind, 'rollback');
    });

    testWidgets('Web app release history refresh shows workflow failure text', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService()
        ..listReleasesResponse = const <String, dynamic>{
          'status': 'error',
          'msg': 'Release inventory unavailable.',
        };
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);

      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-release-history-card'));

      await tester.tap(
        find.byKey(const Key('app-release-history-refresh-button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('app-release-history-error-text')),
        findsOneWidget,
      );
      expect(find.text('Release inventory unavailable.'), findsOneWidget);
    });

    testWidgets('Web app rollback to previous release uses automatic target', (
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
        ..rollbackResponse = const <String, dynamic>{
          'status': 'success',
          'msg': 'Rollback completed.',
          'release_id': '20260531t130000z-fedcba98',
          'rollback_from_release_id': '20260531t120000z-abcdef12',
          'commit_sha': 'fedcba9876543210',
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

      await expandAppDisclosure(tester, const Key('app-release-history-card'));

      await tester.tap(
        find.byKey(const Key('app-release-rollback-previous-button')),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Rollback'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Rollback'));
      await tester.pumpAndSettle();

      final rollbackCall = sshService.workflowCalls.lastWhere(
        (call) =>
            call['workflow_id'] == 'app' && call['operation_id'] == 'rollback',
      );
      final params = rollbackCall['params'] as Map<String, dynamic>;
      expect(params['release_id'], isNull);
      expect(
        sshService.workflowCalls.any(
          (call) =>
              call['workflow_id'] == 'app' &&
              call['operation_id'] == 'list_releases',
        ),
        isFalse,
      );
    });

    testWidgets('Web app deploy button shows Deploy before first success', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
      );

      expect(find.byKey(const Key('github-deploy-button')), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Deploy'), findsOneWidget);
      expect(find.text('Redeploy'), findsNothing);
      expect(
        find.text('Review the setup, then publish the first version.'),
        findsOneWidget,
      );
    });

    testWidgets('Web app deploy button shows Redeploy after a success', (
      WidgetTester tester,
    ) async {
      final deployedProject = selectedProject.copyWith(
        lastDeployCommit: 'abcdef123456',
        lastDeployedAt: DateTime.utc(2026, 3, 21, 12, 0),
      );
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(deployedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: deployedProject,
        projectNotifier: projectNotifier,
      );

      expect(find.byKey(const Key('github-deploy-button')), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Redeploy'), findsOneWidget);
      expect(
        find.text('Publish the latest code with your saved settings.'),
        findsOneWidget,
      );
      expect(find.text('Publish your next release'), findsOneWidget);
      expect(find.text('Step 3: Review settings'), findsNothing);
      expect(find.byTooltip('Check settings'), findsOneWidget);
      expect(find.byTooltip('Change settings'), findsOneWidget);
    });

    testWidgets(
      'Remove web app runtime action forwards runtime connection payload',
      (WidgetTester tester) async {
        final sshService = RuntimeWorkflowSshService();
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
          seedLiveRelease: true,
        );

        await confirmRemoveWebAppRuntime(tester, project: selectedProject);

        final disconnectCall = sshService.workflowCalls.lastWhere(
          (call) =>
              call['workflow_id'] == 'app' &&
              call['operation_id'] == 'disconnect',
        );
        final connection = disconnectCall['connection'] as Map<String, dynamic>;
        expect(connection['host'], serverWithRuntimeCredentials.host);
        expect(connection['port'], serverWithRuntimeCredentials.port);
        expect(connection['username'], serverWithRuntimeCredentials.sshUser);
        expect(connection['password'], 'super-secret');
      },
    );

    testWidgets('Reconnect web app restores the local runtime state', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await confirmRemoveWebAppRuntime(tester, project: selectedProject);

      expect(find.text('Web app connection'), findsOneWidget);
      expect(find.byKey(const Key('app-reconnect-button')), findsOneWidget);

      await tester.drag(
        find.byKey(const Key('app-tab-scroll')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('app-reconnect-button')));
      await tester.pumpAndSettle();

      expect(find.text('Danger zone'), findsOneWidget);
      expect(find.byKey(const Key('app-reconnect-button')), findsNothing);
      expect(projectNotifier.updateRuntimeStateCalls, 2);
      expect(projectNotifier.lastAppDisconnected, isFalse);
    });

    testWidgets('Remove web app runtime surfaces backend failure text', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService()
        ..disconnectResponse = const <String, dynamic>{
          'status': 'error',
          'msg': 'Container is still draining.',
        };
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await confirmRemoveWebAppRuntime(tester, project: selectedProject);

      expect(find.text('Container is still draining.'), findsOneWidget);
    });

    testWidgets('Remove web app runtime surfaces thrown exceptions', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService()
        ..disconnectError = Exception('disconnect exploded');
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await confirmRemoveWebAppRuntime(tester, project: selectedProject);

      expect(
        find.text('Runtime action failed: Exception: disconnect exploded'),
        findsOneWidget,
      );
    });
  }, skip: !sqliteAvailable);
}
