part of '../e2e_checklist_test.dart';

class _NoopAnalyticsService implements AppAnalyticsService {
  @override
  Future<void> initialize() async {}

  @override
  bool get isInitialized => true;

  @override
  void setTelemetryEnabled(bool enabled) {}

  @override
  void trackAppStarted() {}

  @override
  void trackWorkspaceOpened({
    required String workspace,
    String? entryPoint,
    String? tab,
  }) {}

  @override
  void setUserAttribute(AppUserAttribute attribute, String value) {}

  @override
  void trackUnlockFailed({required UnlockFailureReason reason}) {}

  @override
  void trackGitHubOAuth({required GitHubOAuthStage stage}) {}

  @override
  void trackOnboardingStep({
    required OnboardingStep step,
    required bool succeeded,
    int attempt = 1,
  }) {}

  @override
  void trackOnboardingStarted() {}

  @override
  void trackEnrollment({required DataOperationOutcome outcome}) {}

  @override
  void trackSetupIncomplete({required int attempt}) {}

  @override
  void trackSetupResumed() {}

  @override
  void trackDeployEvent({
    required DeployProvider provider,
    required String routingMode,
    required DeployStage stage,
    required DeployOutcome outcome,
    int? durationSeconds,
  }) {}

  /// Keeps checklist runs isolated from deploy-failure telemetry.
  @override
  void trackDeployFailureEvidence({
    required Object phase,
    required Object source,
    required Object completeness,
    required int lineCount,
    required bool agentInitiated,
  }) {}

  @override
  void trackControlUsed({required AppControl control, String? tab}) {}

  @override
  void trackDatabaseEvent({
    required DatabaseEngine engine,
    required DataOperationOutcome outcome,
  }) {}

  @override
  void trackBackupEvent({
    required BackupKind kind,
    required DataOperationOutcome outcome,
  }) {}

  @override
  void trackRestoreEvent({
    required DataOperationOutcome outcome,
    int? durationSeconds,
  }) {}

  @override
  void trackSchedulerEvent({
    required SchedulerAction action,
    required DataOperationOutcome outcome,
  }) {}

  @override
  void trackWorkerEvent({
    required WorkerAction action,
    required DataOperationOutcome outcome,
  }) {}

  @override
  void trackServiceEvent({
    required ServiceAction action,
    required DataOperationOutcome outcome,
  }) {}

  @override
  void trackFirewallEvent({
    required FirewallAction action,
    required DataOperationOutcome outcome,
  }) {}

  @override
  void trackUpdateEvent({
    required UpdateAction action,
    required DataOperationOutcome outcome,
    required String fromVersion,
  }) {}

  @override
  void trackTerminalCommand({required DataOperationOutcome outcome}) {}

  @override
  void trackAgentTool({
    required String tool,
    required DataOperationOutcome outcome,
  }) {}

  @override
  void trackAgentRedeploy({
    required DataOperationOutcome outcome,
    int? durationSeconds,
  }) {}

  @override
  void trackOnboardingEvent({
    required DataOperationOutcome outcome,
    OnboardingAuthProvider? provider,
    OnboardingStage? stage,
  }) {}

  @override
  void trackWorkflowFailed({
    required String workflowId,
    required String operationId,
  }) {}

  @override
  void trackPreviousSessionCrash({required String errorType}) {}

  @override
  void endSession() {}
}
