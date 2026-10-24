import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/models/deploy_failure_evidence.dart';
import 'package:ui/services/app_analytics_service.dart';

/// In-memory [AppAnalyticsService] recording exactly what it receives, with
/// optional faults for isolation tests.
///
/// Single owner of the analytics test double: every suite that stands in for
/// the service imports this instead of declaring a local private fake, so the
/// recorded shapes ([trackedEvents], [userAttributes], [unlockFailures],
/// [oauthStages], [onboardingSteps], [deployEvents], [controlUses],
/// [databaseEvents], [backupEvents], [restoreEvents], [schedulerEvents],
/// [workerEvents], [serviceEvents], [firewallEvents], [updateEvents],
/// [terminalCommandEvents], [agentToolEvents], [agentRedeployEvents],
/// [onboardingEvents], [workflowFailedEvents], [previousSessionCrashes],
/// [workspaceEvents]) cannot drift apart between suites.
/// Backends with queued
/// state use
/// [FlushableFakeAnalyticsService].
class FakeAnalyticsService implements AppAnalyticsService {
  /// Creates the fake. [throwOnInitialize] fails [initialize];
  /// [throwOnTrack] fails every recording call. [throwAsException] makes
  /// those faults plain [Exception]s instead of [StateError]s, so the
  /// guarded paths prove they contain operational faults of either shape
  /// while still letting programming errors through.
  FakeAnalyticsService({
    this.throwOnInitialize = false,
    this.throwOnTrack = false,
    this.throwAsException = false,
  });

  /// Fault switches for isolation tests.
  final bool throwOnInitialize;
  final bool throwOnTrack;
  final bool throwAsException;

  /// The fault this fake throws, in the shape the test selected.
  Object _fault(String message) =>
      throwAsException ? Exception(message) : StateError(message);

  /// How often the app under test initialized analytics.
  var initializeCallCount = 0;

  /// How often the app under test reported startup.
  var appStartedCallCount = 0;

  /// How often a fresh install opened server onboarding.
  var onboardingStartedCallCount = 0;

  /// Every passphrase enrollment resolving, in order.
  final enrollmentOutcomes = <DataOperationOutcome>[];

  /// The wizard setup-run number behind each incomplete row, in order.
  final setupIncompleteAttempts = <int>[];

  /// How often a setup resume was entered from Home or Server Management.
  var setupResumedCallCount = 0;

  /// How often the app under test flipped the usage-reporting switch.
  var setTelemetryCallCount = 0;

  /// The last usage-reporting switch value, or null before the first flip.
  bool? lastSetTelemetryEnabled;

  /// Whether usage reporting is currently on. Starts on: telemetry is
  /// default-on behind a notice, and only an explicit `false` silences it.
  bool _telemetryEnabled = true;

  /// Every tracked event, in order.
  final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];

  /// Every user attribute, in order.
  final userAttributes = <({AppUserAttribute attribute, String value})>[];

  /// Every unlock failure reason, in order.
  final unlockFailures = <UnlockFailureReason>[];

  @override
  Future<void> initialize() async {
    initializeCallCount += 1;
    if (throwOnInitialize) {
      throw _fault('backend unavailable');
    }
  }

  @override
  bool get isInitialized => initializeCallCount > 0;

  @override
  void setTelemetryEnabled(bool enabled) {
    setTelemetryCallCount += 1;
    lastSetTelemetryEnabled = enabled;
    _telemetryEnabled = enabled;
  }

  @override
  void trackAppStarted() {
    appStartedCallCount += 1;
    _record('app_started', const <String, Object?>{'surface': 'desktop'});
  }

  @override
  void trackWorkspaceOpened({
    required String workspace,
    String? entryPoint,
    String? tab,
  }) {
    final properties = <String, Object?>{'workspace': workspace};
    if (entryPoint != null) {
      properties['entry_point'] = entryPoint;
    }
    if (tab != null) {
      properties['tab'] = tab;
    }
    _record('workspace_opened', properties);
  }

  void _record(String eventName, Map<String, Object?> properties) {
    if (!_telemetryEnabled) {
      return;
    }
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    trackedEvents.add((
      eventName: eventName,
      props: Map<String, dynamic>.from(properties),
    ));
  }

  @override
  void setUserAttribute(AppUserAttribute attribute, String value) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    userAttributes.add((attribute: attribute, value: value));
  }

  @override
  void trackUnlockFailed({required UnlockFailureReason reason}) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    unlockFailures.add(reason);
  }

  /// Every GitHub OAuth stage, in order.
  final oauthStages = <GitHubOAuthStage>[];

  /// Every onboarding checkpoint row, in order.
  final onboardingSteps =
      <({OnboardingStep step, bool succeeded, int attempt})>[];

  @override
  void trackGitHubOAuth({required GitHubOAuthStage stage}) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    oauthStages.add(stage);
  }

  @override
  void trackOnboardingStep({
    required OnboardingStep step,
    required bool succeeded,
    int attempt = 1,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    onboardingSteps.add((step: step, succeeded: succeeded, attempt: attempt));
  }

  @override
  void trackOnboardingStarted() {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    onboardingStartedCallCount += 1;
    _record('onboarding_started', const <String, Object?>{
      'surface': 'desktop',
    });
  }

  @override
  void trackEnrollment({required DataOperationOutcome outcome}) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    enrollmentOutcomes.add(outcome);
  }

  @override
  void trackSetupIncomplete({required int attempt}) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    setupIncompleteAttempts.add(attempt);
  }

  @override
  void trackSetupResumed() {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    setupResumedCallCount += 1;
  }

  /// Every deploy resolution, in order.
  final deployEvents =
      <
        ({
          DeployProvider provider,
          String routingMode,
          DeployStage stage,
          DeployOutcome outcome,
          int? durationSeconds,
        })
      >[];

  @override
  void trackDeployEvent({
    required DeployProvider provider,
    required String routingMode,
    required DeployStage stage,
    required DeployOutcome outcome,
    int? durationSeconds,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    deployEvents.add((
      provider: provider,
      routingMode: routingMode,
      stage: stage,
      outcome: outcome,
      durationSeconds: durationSeconds,
    ));
  }

  /// Records only the production-safe failure metadata shape.
  @override
  void trackDeployFailureEvidence({
    required DeployFailurePhase phase,
    required DeployFailureSource source,
    required DeployFailureCompleteness completeness,
    required int lineCount,
    required bool agentInitiated,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    _record(
      'deploy_failure_evidence',
      deployFailureAnalyticsProperties(
        phase: phase,
        source: source,
        completeness: completeness,
        lineCount: lineCount,
        agentInitiated: agentInitiated,
      ),
    );
  }

  /// Every control use, in order.
  final controlUses = <({AppControl control, String? tab})>[];

  @override
  void trackControlUsed({required AppControl control, String? tab}) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    controlUses.add((control: control, tab: tab));
  }

  /// Every database event, in order.
  final databaseEvents =
      <({DatabaseEngine engine, DataOperationOutcome outcome})>[];

  @override
  void trackDatabaseEvent({
    required DatabaseEngine engine,
    required DataOperationOutcome outcome,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    databaseEvents.add((engine: engine, outcome: outcome));
  }

  /// Every backup event, in order.
  final backupEvents = <({BackupKind kind, DataOperationOutcome outcome})>[];

  @override
  void trackBackupEvent({
    required BackupKind kind,
    required DataOperationOutcome outcome,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    backupEvents.add((kind: kind, outcome: outcome));
  }

  /// Every restore event, in order.
  final restoreEvents =
      <({DataOperationOutcome outcome, int? durationSeconds})>[];

  @override
  void trackRestoreEvent({
    required DataOperationOutcome outcome,
    int? durationSeconds,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    restoreEvents.add((outcome: outcome, durationSeconds: durationSeconds));
  }

  /// Every scheduler event, in order.
  final schedulerEvents =
      <({SchedulerAction action, DataOperationOutcome outcome})>[];

  @override
  void trackSchedulerEvent({
    required SchedulerAction action,
    required DataOperationOutcome outcome,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    schedulerEvents.add((action: action, outcome: outcome));
  }

  /// Every worker event, in order.
  final workerEvents =
      <({WorkerAction action, DataOperationOutcome outcome})>[];

  @override
  void trackWorkerEvent({
    required WorkerAction action,
    required DataOperationOutcome outcome,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    workerEvents.add((action: action, outcome: outcome));
  }

  /// Every service event, in order.
  final serviceEvents =
      <({ServiceAction action, DataOperationOutcome outcome})>[];

  @override
  void trackServiceEvent({
    required ServiceAction action,
    required DataOperationOutcome outcome,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    serviceEvents.add((action: action, outcome: outcome));
  }

  /// Every firewall event, in order.
  final firewallEvents =
      <({FirewallAction action, DataOperationOutcome outcome})>[];

  @override
  void trackFirewallEvent({
    required FirewallAction action,
    required DataOperationOutcome outcome,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    firewallEvents.add((action: action, outcome: outcome));
  }

  /// Every update event, in order.
  final updateEvents =
      <
        ({
          UpdateAction action,
          DataOperationOutcome outcome,
          String fromVersion,
        })
      >[];

  @override
  void trackUpdateEvent({
    required UpdateAction action,
    required DataOperationOutcome outcome,
    required String fromVersion,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    updateEvents.add((
      action: action,
      outcome: outcome,
      fromVersion: fromVersion,
    ));
  }

  /// Every terminal command outcome, in order. The command text never
  /// reaches analytics, so there is nothing else to record.
  final terminalCommandEvents = <DataOperationOutcome>[];

  @override
  void trackTerminalCommand({required DataOperationOutcome outcome}) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    terminalCommandEvents.add(outcome);
  }

  /// Every agent tool call, in order.
  final agentToolEvents = <({String tool, DataOperationOutcome outcome})>[];

  @override
  void trackAgentTool({
    required String tool,
    required DataOperationOutcome outcome,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    agentToolEvents.add((tool: tool, outcome: outcome));
  }

  /// Every agent redeploy handoff, in order.
  final agentRedeployEvents =
      <({DataOperationOutcome outcome, int? durationSeconds})>[];

  @override
  void trackAgentRedeploy({
    required DataOperationOutcome outcome,
    int? durationSeconds,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    agentRedeployEvents.add((
      outcome: outcome,
      durationSeconds: durationSeconds,
    ));
  }

  /// Every onboarding wizard closing, in order.
  final onboardingEvents =
      <
        ({
          DataOperationOutcome outcome,
          OnboardingAuthProvider? provider,
          OnboardingStage? stage,
        })
      >[];

  @override
  void trackOnboardingEvent({
    required DataOperationOutcome outcome,
    OnboardingAuthProvider? provider,
    OnboardingStage? stage,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    onboardingEvents.add((outcome: outcome, provider: provider, stage: stage));
  }

  /// Every engine workflow failure, in order.
  final workflowFailedEvents = <({String workflowId, String operationId})>[];

  @override
  void trackWorkflowFailed({
    required String workflowId,
    required String operationId,
  }) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    workflowFailedEvents.add((
      workflowId: workflowId,
      operationId: operationId,
    ));
  }

  /// Every previous-launch crash error type, in order. Type only, matching
  /// the production marker: the fake never sees messages or stacks either.
  final previousSessionCrashes = <String>[];

  @override
  void trackPreviousSessionCrash({required String errorType}) {
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
    previousSessionCrashes.add(errorType);
  }

  /// How often the session hook ran. A counter, not an event list: the fake
  /// stays a dumb recorder while the real backends own exactly-once.
  var endSessionCalls = 0;

  @override
  void endSession() {
    endSessionCalls += 1;
    if (throwOnTrack) {
      throw _fault('backend unavailable');
    }
  }

  /// Workspace opens projected into the shell suites' map shape: only the
  /// keys the call site passed, so their matchers read unchanged.
  List<Map<String, String>> get workspaceEvents {
    return [
      for (final event in trackedEvents)
        if (event.eventName == 'workspace_opened')
          (event.props ?? const <String, dynamic>{}).map(
            (key, value) => MapEntry(key, value as String),
          ),
    ];
  }
}

/// In-memory backend holding flushable queued state for close tests.
///
/// Separate class (rather than a flag) so a composite holding a plain
/// [FakeAnalyticsService] next to this one still proves flush fan-out
/// reaches flushable children only.
class FlushableFakeAnalyticsService extends FakeAnalyticsService
    implements AnalyticsFlushable {
  /// Creates the flushable fake. [throwOnFlush] fails [flush] after
  /// counting the attempt, proving close containment.
  FlushableFakeAnalyticsService({
    this.throwOnFlush = false,
    super.throwAsException,
  });

  /// Whether [flush] throws after counting the attempt.
  final bool throwOnFlush;

  /// How often queued events were pushed out.
  var flushCallCount = 0;

  @override
  Future<void> flush() async {
    flushCallCount += 1;
    if (throwOnFlush) {
      throw _fault('flush unavailable');
    }
  }
}
