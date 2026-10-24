import 'package:flutter_test/flutter_test.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/models/deploy_failure_evidence.dart';
import 'package:ui/services/app_analytics_service.dart';

import 'fake_analytics_service.dart';

/// Contract for the shared analytics test double: every suite that stands in
/// for [AppAnalyticsService] uses this instead of a local private fake, so
/// recording shapes cannot drift apart between suites.
void main() {
  group('FakeAnalyticsService', () {
    test('counts initialize and app started calls', () async {
      final analytics = FakeAnalyticsService();

      await analytics.initialize();
      await analytics.initialize();
      analytics.trackAppStarted();

      expect(analytics.initializeCallCount, 2);
      expect(analytics.appStartedCallCount, 1);
    });

    test('records tracked events in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackAppStarted();
      analytics.trackWorkspaceOpened(
        workspace: 'home',
        entryPoint: 'rail',
        tab: 'servers',
      );

      expect(analytics.trackedEvents.map((event) => event.eventName), [
        'app_started',
        'workspace_opened',
      ]);
      expect(analytics.trackedEvents[0].props, <String, dynamic>{
        'surface': 'desktop',
      });
      expect(analytics.trackedEvents[1].props, <String, dynamic>{
        'workspace': 'home',
        'entry_point': 'rail',
        'tab': 'servers',
      });
    });

    test('records user attributes', () {
      final analytics = FakeAnalyticsService();

      analytics.setUserAttribute(
        AppUserAttribute.hasFirstDeploySucceeded,
        'true',
      );

      expect(analytics.userAttributes, [
        (attribute: AppUserAttribute.hasFirstDeploySucceeded, value: 'true'),
      ]);
    });

    test('records unlock failures', () {
      final analytics = FakeAnalyticsService();

      analytics.trackUnlockFailed(reason: UnlockFailureReason.dbMissing);

      expect(analytics.unlockFailures, [UnlockFailureReason.dbMissing]);
    });

    test('records GitHub OAuth stages in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackGitHubOAuth(stage: GitHubOAuthStage.started);
      analytics.trackGitHubOAuth(stage: GitHubOAuthStage.completed);

      expect(analytics.oauthStages, [
        GitHubOAuthStage.started,
        GitHubOAuthStage.completed,
      ]);
    });

    test('records onboarding steps in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackOnboardingStep(
        step: OnboardingStep.bootstrap,
        succeeded: true,
      );
      analytics.trackOnboardingStep(
        step: OnboardingStep.bootstrap,
        succeeded: false,
        attempt: 2,
      );

      expect(analytics.onboardingSteps, [
        (step: OnboardingStep.bootstrap, succeeded: true, attempt: 1),
        (step: OnboardingStep.bootstrap, succeeded: false, attempt: 2),
      ]);
    });

    test('records deploy events', () {
      final analytics = FakeAnalyticsService();

      analytics.trackDeployEvent(
        provider: DeployProvider.node,
        routingMode: 'single_host',
        stage: DeployStage.cutover,
        outcome: DeployOutcome.success,
        durationSeconds: 42,
      );

      expect(analytics.deployEvents, [
        (
          provider: DeployProvider.node,
          routingMode: 'single_host',
          stage: DeployStage.cutover,
          outcome: DeployOutcome.success,
          durationSeconds: 42,
        ),
      ]);
    });

    test('records only safe deploy failure metadata', () {
      final analytics = FakeAnalyticsService();

      analytics.trackDeployFailureEvidence(
        phase: DeployFailurePhase.trafficSwitch,
        source: DeployFailureSource.routedProbe,
        completeness: DeployFailureCompleteness.diagnostic,
        lineCount: 5,
        agentInitiated: true,
      );

      expect(
        analytics.trackedEvents.single.eventName,
        'deploy_failure_evidence',
      );
      expect(analytics.trackedEvents.single.props, <String, dynamic>{
        'phase': 'traffic_switch',
        'source': 'routed_probe',
        'completeness': 'diagnostic',
        'line_count_bucket': '4_6',
        'actor': 'agent',
      });
    });

    test('records control uses in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackControlUsed(control: AppControl.deployPressed);
      analytics.trackControlUsed(
        control: AppControl.placeholderViewed,
        tab: 'email',
      );

      expect(analytics.controlUses, [
        (control: AppControl.deployPressed, tab: null),
        (control: AppControl.placeholderViewed, tab: 'email'),
      ]);
    });

    test('records database events in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackDatabaseEvent(
        engine: DatabaseEngine.postgres,
        outcome: DataOperationOutcome.success,
      );
      analytics.trackDatabaseEvent(
        engine: DatabaseEngine.sqlite,
        outcome: DataOperationOutcome.failure,
      );

      expect(analytics.databaseEvents, [
        (
          engine: DatabaseEngine.postgres,
          outcome: DataOperationOutcome.success,
        ),
        (engine: DatabaseEngine.sqlite, outcome: DataOperationOutcome.failure),
      ]);
    });

    test('records backup events in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackBackupEvent(
        kind: BackupKind.postgres,
        outcome: DataOperationOutcome.failure,
      );

      expect(analytics.backupEvents, [
        (kind: BackupKind.postgres, outcome: DataOperationOutcome.failure),
      ]);
    });

    test('records restore events in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackRestoreEvent(
        outcome: DataOperationOutcome.success,
        durationSeconds: 12,
      );
      analytics.trackRestoreEvent(outcome: DataOperationOutcome.failure);

      expect(analytics.restoreEvents, [
        (outcome: DataOperationOutcome.success, durationSeconds: 12),
        (outcome: DataOperationOutcome.failure, durationSeconds: null),
      ]);
    });

    test('records scheduler events in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackSchedulerEvent(
        action: SchedulerAction.create,
        outcome: DataOperationOutcome.success,
      );
      analytics.trackSchedulerEvent(
        action: SchedulerAction.run,
        outcome: DataOperationOutcome.failure,
      );

      expect(analytics.schedulerEvents, [
        (action: SchedulerAction.create, outcome: DataOperationOutcome.success),
        (action: SchedulerAction.run, outcome: DataOperationOutcome.failure),
      ]);
    });

    test('records worker events in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackWorkerEvent(
        action: WorkerAction.apply,
        outcome: DataOperationOutcome.success,
      );

      expect(analytics.workerEvents, [
        (action: WorkerAction.apply, outcome: DataOperationOutcome.success),
      ]);
    });

    test('records service events in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackServiceEvent(
        action: ServiceAction.enable,
        outcome: DataOperationOutcome.success,
      );
      analytics.trackServiceEvent(
        action: ServiceAction.stop,
        outcome: DataOperationOutcome.failure,
      );

      expect(analytics.serviceEvents, [
        (action: ServiceAction.enable, outcome: DataOperationOutcome.success),
        (action: ServiceAction.stop, outcome: DataOperationOutcome.failure),
      ]);
    });

    test('records firewall events in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackFirewallEvent(
        action: FirewallAction.apply,
        outcome: DataOperationOutcome.success,
      );
      analytics.trackFirewallEvent(
        action: FirewallAction.rollback,
        outcome: DataOperationOutcome.failure,
      );

      expect(analytics.firewallEvents, [
        (action: FirewallAction.apply, outcome: DataOperationOutcome.success),
        (
          action: FirewallAction.rollback,
          outcome: DataOperationOutcome.failure,
        ),
      ]);
    });

    test('records update events in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackUpdateEvent(
        action: UpdateAction.check,
        outcome: DataOperationOutcome.success,
        fromVersion: '1.4.2',
      );
      analytics.trackUpdateEvent(
        action: UpdateAction.apply,
        outcome: DataOperationOutcome.failure,
        fromVersion: '1.4.2',
      );

      expect(analytics.updateEvents, [
        (
          action: UpdateAction.check,
          outcome: DataOperationOutcome.success,
          fromVersion: '1.4.2',
        ),
        (
          action: UpdateAction.apply,
          outcome: DataOperationOutcome.failure,
          fromVersion: '1.4.2',
        ),
      ]);
    });

    test('records terminal command events in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackTerminalCommand(outcome: DataOperationOutcome.success);
      analytics.trackTerminalCommand(outcome: DataOperationOutcome.failure);

      expect(analytics.terminalCommandEvents, [
        DataOperationOutcome.success,
        DataOperationOutcome.failure,
      ]);
    });

    test('records agent tool events in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackAgentTool(
        tool: 'deploydash_get_server_overview',
        outcome: DataOperationOutcome.success,
      );
      analytics.trackAgentTool(
        tool: 'deploydash_list_postgres_tables',
        outcome: DataOperationOutcome.failure,
      );

      expect(analytics.agentToolEvents, [
        (
          tool: 'deploydash_get_server_overview',
          outcome: DataOperationOutcome.success,
        ),
        (
          tool: 'deploydash_list_postgres_tables',
          outcome: DataOperationOutcome.failure,
        ),
      ]);
    });

    test('records agent redeploy events in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackAgentRedeploy(
        outcome: DataOperationOutcome.success,
        durationSeconds: 12,
      );
      analytics.trackAgentRedeploy(outcome: DataOperationOutcome.failure);

      expect(analytics.agentRedeployEvents, [
        (outcome: DataOperationOutcome.success, durationSeconds: 12),
        (outcome: DataOperationOutcome.failure, durationSeconds: null),
      ]);
    });

    test('records onboarding events in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackOnboardingEvent(
        outcome: DataOperationOutcome.success,
        provider: OnboardingAuthProvider.password,
        stage: OnboardingStage.services,
      );
      analytics.trackOnboardingEvent(outcome: DataOperationOutcome.failure);

      expect(analytics.onboardingEvents, [
        (
          outcome: DataOperationOutcome.success,
          provider: OnboardingAuthProvider.password,
          stage: OnboardingStage.services,
        ),
        (outcome: DataOperationOutcome.failure, provider: null, stage: null),
      ]);
    });

    test('records workflow failures in order', () {
      final analytics = FakeAnalyticsService();

      analytics.trackWorkflowFailed(
        workflowId: 'postgres',
        operationId: 'service_restart',
      );
      analytics.trackWorkflowFailed(workflowId: 'server', operationId: 'check');

      expect(analytics.workflowFailedEvents, [
        (workflowId: 'postgres', operationId: 'service_restart'),
        (workflowId: 'server', operationId: 'check'),
      ]);
    });

    test('counts session ends', () {
      final analytics = FakeAnalyticsService();

      expect(analytics.endSessionCalls, 0);
      analytics.endSession();
      analytics.endSession();

      expect(analytics.endSessionCalls, 2);
    });

    test('projects workspace opens in the shell map shape', () {
      final analytics = FakeAnalyticsService();

      analytics.trackAppStarted();
      analytics.trackWorkspaceOpened(workspace: 'home');
      analytics.trackWorkspaceOpened(
        workspace: 'server_management',
        entryPoint: 'home_dashboard',
        tab: 'services',
      );

      expect(analytics.workspaceEvents, [
        <String, String>{'workspace': 'home'},
        <String, String>{
          'workspace': 'server_management',
          'entry_point': 'home_dashboard',
          'tab': 'services',
        },
      ]);
    });

    test('throws on initialize and track when faulted', () async {
      final analytics = FakeAnalyticsService(
        throwOnInitialize: true,
        throwOnTrack: true,
      );

      await expectLater(analytics.initialize(), throwsStateError);
      expect(analytics.initializeCallCount, 1);

      expect(analytics.trackAppStarted, throwsStateError);
      expect(
        () => analytics.trackWorkspaceOpened(workspace: 'home'),
        throwsStateError,
      );
      expect(
        () => analytics.setUserAttribute(
          AppUserAttribute.hasCompletedOnboarding,
          'true',
        ),
        throwsStateError,
      );
      expect(
        () =>
            analytics.trackUnlockFailed(reason: UnlockFailureReason.authFailed),
        throwsStateError,
      );
      expect(
        () => analytics.trackGitHubOAuth(stage: GitHubOAuthStage.started),
        throwsStateError,
      );
      expect(
        () => analytics.trackOnboardingStep(
          step: OnboardingStep.bootstrap,
          succeeded: true,
        ),
        throwsStateError,
      );
      expect(
        () => analytics.trackDeployEvent(
          provider: DeployProvider.node,
          routingMode: 'single_host',
          stage: DeployStage.cutover,
          outcome: DeployOutcome.success,
        ),
        throwsStateError,
      );
      expect(
        () => analytics.trackDeployFailureEvidence(
          phase: DeployFailurePhase.build,
          source: DeployFailureSource.failedOperation,
          completeness: DeployFailureCompleteness.diagnostic,
          lineCount: 1,
          agentInitiated: false,
        ),
        throwsStateError,
      );
      expect(
        () => analytics.trackControlUsed(control: AppControl.deployPressed),
        throwsStateError,
      );
      expect(
        () => analytics.trackDatabaseEvent(
          engine: DatabaseEngine.postgres,
          outcome: DataOperationOutcome.success,
        ),
        throwsStateError,
      );
      expect(
        () => analytics.trackBackupEvent(
          kind: BackupKind.postgres,
          outcome: DataOperationOutcome.success,
        ),
        throwsStateError,
      );
      expect(
        () =>
            analytics.trackRestoreEvent(outcome: DataOperationOutcome.success),
        throwsStateError,
      );
      expect(
        () => analytics.trackSchedulerEvent(
          action: SchedulerAction.create,
          outcome: DataOperationOutcome.success,
        ),
        throwsStateError,
      );
      expect(
        () => analytics.trackWorkerEvent(
          action: WorkerAction.apply,
          outcome: DataOperationOutcome.success,
        ),
        throwsStateError,
      );
      expect(
        () => analytics.trackServiceEvent(
          action: ServiceAction.enable,
          outcome: DataOperationOutcome.success,
        ),
        throwsStateError,
      );
      expect(
        () => analytics.trackFirewallEvent(
          action: FirewallAction.apply,
          outcome: DataOperationOutcome.success,
        ),
        throwsStateError,
      );
      expect(
        () => analytics.trackUpdateEvent(
          action: UpdateAction.check,
          outcome: DataOperationOutcome.success,
          fromVersion: '1.4.2',
        ),
        throwsStateError,
      );
      expect(
        () => analytics.trackWorkflowFailed(
          workflowId: 'postgres',
          operationId: 'service_restart',
        ),
        throwsStateError,
      );
      expect(() => analytics.endSession(), throwsStateError);
      // Attempts count like flush attempts: the throw above still ran the
      // hook once.
      expect(analytics.endSessionCalls, 1);
      expect(analytics.trackedEvents, isEmpty);
      expect(analytics.userAttributes, isEmpty);
      expect(analytics.unlockFailures, isEmpty);
      expect(analytics.oauthStages, isEmpty);
      expect(analytics.onboardingSteps, isEmpty);
      expect(analytics.deployEvents, isEmpty);
      expect(analytics.controlUses, isEmpty);
      expect(analytics.databaseEvents, isEmpty);
      expect(analytics.backupEvents, isEmpty);
      expect(analytics.restoreEvents, isEmpty);
      expect(analytics.schedulerEvents, isEmpty);
      expect(analytics.workerEvents, isEmpty);
      expect(analytics.serviceEvents, isEmpty);
      expect(analytics.firewallEvents, isEmpty);
      expect(analytics.updateEvents, isEmpty);
      expect(analytics.workflowFailedEvents, isEmpty);
    });
  });

  group('FlushableFakeAnalyticsService', () {
    test('counts flush calls and still records events', () async {
      final analytics = FlushableFakeAnalyticsService();

      await analytics.flush();
      analytics.trackAppStarted();

      expect(analytics.flushCallCount, 1);
      expect(analytics.trackedEvents.map((event) => event.eventName), [
        'app_started',
      ]);
    });

    test('contains flush failures after counting the attempt', () async {
      final analytics = FlushableFakeAnalyticsService(throwOnFlush: true);

      await expectLater(analytics.flush(), throwsStateError);

      expect(analytics.flushCallCount, 1);
    });
  });
}
