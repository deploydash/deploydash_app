import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:amplitude_flutter/amplitude.dart';
import 'package:amplitude_flutter/configuration.dart';
import 'package:amplitude_flutter/constants.dart';
import 'package:amplitude_flutter/events/base_event.dart';
import 'package:amplitude_flutter/events/identify.dart';
import 'package:amplitude_flutter/tracking_options.dart';
import 'package:aptabase_flutter/aptabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../data/local/app_preferences_repository.dart';
import '../models/app_user_attribute.dart';
import '../models/deploy_failure_evidence.dart';
import 'device_identity_service.dart';

const String _aptabaseAppKey = String.fromEnvironment(
  'DEPLOYDASH_APTABASE_APP_KEY',
  defaultValue: 'A-EU-3209480801',
);

/// The Amplitude project API key baked into release builds as the fallback
/// when no `--dart-define=DEPLOYDASH_AMPLITUDE_API_KEY` was provided.
///
/// A public project identifier by design (Amplitude project keys ship
/// client-side; the Aptabase key above already ships the same way), not a
/// confidential credential: it names the property events go to. CI-provided
/// defines still win whenever present; debug builds stay empty so local
/// development never reports into the production property.
const String shippedAmplitudeApiKey = '68183525883a7d764e1debc0579d4685';

/// Resolves the Amplitude API key: the built-in define first, then the
/// shipped fallback in release builds only, otherwise empty (fail closed).
///
/// [environmentValue] and [isReleaseMode] are seams so tests pin each source
/// without build defines; production passes nothing and reads both live.
String resolveAmplitudeApiKey({String? environmentValue, bool? isReleaseMode}) {
  final defined =
      environmentValue ??
      const String.fromEnvironment(
        'DEPLOYDASH_AMPLITUDE_API_KEY',
        defaultValue: '',
      );
  if (defined.isNotEmpty) {
    return defined;
  }
  return (isReleaseMode ?? kReleaseMode) ? shippedAmplitudeApiKey : '';
}

const Duration _analyticsTickDuration = Duration(seconds: 5);

/// Starts the Aptabase SDK. Injectable so tests never reach the network.
typedef AptabaseInitializer =
    Future<void> Function(String appKey, InitOptions options);

/// Sends one event to the SDK. Injectable so tests can assert on exactly what
/// would have been sent.
typedef AptabaseEventTracker =
    void Function(String eventName, Map<String, dynamic>? props);

// coverage-gate: analytics_service_contract
/// The events Deploy Dash reports, and nothing else.
///
/// Deliberately a closed interface rather than a general `track(name, props)`:
/// the set of things this app is willing to report is a product decision, and
/// naming each one here is what keeps it reviewable. Adding an event means
/// adding a method, which means someone reads what it carries.
abstract class AppAnalyticsService {
  /// Starts the analytics backend. Safe to call more than once.
  Future<void> initialize();

  /// Whether [initialize] has completed. The post-unlock launch sync reads
  /// this to avoid reporting `app_started` a second time after `main` ran
  /// the as-shipped init before unlock.
  bool get isInitialized;

  /// Turns usage reporting on or off at runtime. Off silences every later
  /// event; the stored preference picks the value, and the setup notice,
  /// the Privacy destination, and the launch sync all funnel through this.
  void setTelemetryEnabled(bool enabled);

  /// Reports that the desktop app started.
  void trackAppStarted();

  /// Reports that a workspace was opened.
  ///
  /// [workspace] and [tab] are the app's own screen names; [entryPoint] is how
  /// the user got there. None of the three ever carries a project name, server
  /// address, or anything else belonging to the user -- callers pass screen
  /// identifiers, and [sanitizeAnalyticsProperties] is the backstop.
  void trackWorkspaceOpened({
    required String workspace,
    String? entryPoint,
    String? tab,
  });

  /// Sets a coarse user attribute for cohort analysis (activation milestones,
  /// install facts). Both the attribute and the value come from closed
  /// vocabularies at the call site; blank values are dropped. Backends
  /// without user properties ignore it.
  void setUserAttribute(AppUserAttribute attribute, String value);

  /// Reports a failed unlock attempt with its closed-vocabulary reason.
  ///
  /// Form validation (empty passphrase, mismatched confirmation, no file
  /// picked) is not an attempt and reports nothing -- only a rejected
  /// credential, an unavailable database, or an unusable one.
  void trackUnlockFailed({required UnlockFailureReason reason});

  /// Reports a GitHub OAuth connect-flow transition.
  ///
  /// [GitHubOAuthStage.started] fires when a flow begins -- an explicit
  /// connect tap or a cold-launch recovery of a pending callback. Exactly one
  /// of `completed` or `failed` follows per flow; input that is not an
  /// attempt (an unparseable URL, a callback for no known flow) reports
  /// nothing, mirroring the unlock gate's form-validation silence.
  void trackGitHubOAuth({required GitHubOAuthStage stage});

  /// Reports one server-onboarding checkpoint transition.
  ///
  /// A successful setup run reports every baseline checkpoint in fixed order
  /// ([OnboardingStep.values] order up to [OnboardingStep.ownershipHandoff])
  /// and then [OnboardingStep.completed], all with the run's [attempt]
  /// number: setup success means the fixed baseline fully applied, because
  /// the backend fails fast and aborts the run on any fault. That inference
  /// is the only per-step success signal the desktop has -- the provisioning
  /// stages run inside one backend call with no per-stage result contract.
  ///
  /// A failed run reports only the checkpoint the backend names by error
  /// code (see [onboardingFailedStepForCode]): a code is a statement, and an
  /// unmappable failure reports nothing rather than a guessed step.
  ///
  /// Closing the wizard without setup ever succeeding reports
  /// ([OnboardingStep.abandoned], `succeeded: false`, `attempt: 0`). The
  /// zero attempt is the convention that marks an abandon: a genuine step
  /// failure always carries the attempt number (`>= 1`) of the run that
  /// produced it. The wizard layer cannot name a last step -- it observes
  /// wizard screens, not provisioning checkpoints -- so it reports
  /// [OnboardingStep.abandoned] rather than guessing one.
  void trackOnboardingStep({
    required OnboardingStep step,
    required bool succeeded,
    int attempt = 1,
  });

  /// Reports that a fresh install opened server onboarding.
  ///
  /// Fired exactly once per launch without a local database, before any
  /// passphrase exists. Pairs with [trackEnrollment] to answer the
  /// acquisition stage's day-zero question (PRODUCT-STRATEGY §2):
  /// `onboarding_started` vs enrollment now measures what "Launch →
  /// unlock" used to, with the passphrase gate moved after value.
  void trackOnboardingStarted();

  /// Reports one passphrase enrollment resolving.
  ///
  /// Fired exactly once per passphrase the wizard's enrollment step
  /// submits: success when the database is created, failure when
  /// creation rejects it. Form validation (empty passphrase, mismatched
  /// confirmation) is not an attempt and reports nothing, mirroring the
  /// unlock gate's form-validation silence.
  void trackEnrollment({required DataOperationOutcome outcome});

  /// Reports a setup run that left its server incomplete.
  ///
  /// Fired once per failed provisioning run, including failures the
  /// checkpoint funnel cannot name by code (network, packages) and
  /// handoff failures after a successful run. [attempt] is the wizard
  /// opening's 1-based setup-run number, so the activation stage can see
  /// whether retries save people or bury them (PRODUCT-STRATEGY §3).
  void trackSetupIncomplete({required int attempt});

  /// Reports a setup resume entered from Home or Server Management.
  ///
  /// Fired once per tap of a retry/resume entry for a setup-incomplete
  /// server. In-wizard retries need no row here: the checkpoint funnel's
  /// attempt numbers already count them.
  void trackSetupResumed();

  /// Reports one web-app deploy resolution.
  ///
  /// Fired exactly once per deploy attempt from the deploy outcome funnel,
  /// which is the single point where the health-gated result is known: a
  /// successful run reports ([DeployStage.stabilize], [DeployOutcome.success])
  /// because success means the candidate passed probes, took traffic, and
  /// held it through stabilization; failures name the furthest stage the
  /// backend's `cutover_status` vocabulary places them at (see
  /// [deployStageForResult] and [deployOutcomeForResult] for the mapping --
  /// the backend step ids stay uncontracted internals the desktop reads but
  /// never sends).
  ///
  /// [durationSeconds] is the wall-clock run time when the funnel measured
  /// one; validation rejections before a run starts carry none.
  void trackDeployEvent({
    required DeployProvider provider,
    required String routingMode,
    required DeployStage stage,
    required DeployOutcome outcome,
    int? durationSeconds,
  });

  /// Reports whether bounded deploy-failure evidence was available.
  ///
  /// Only closed metadata crosses this boundary. Diagnostic lines, project
  /// configuration, repository and domain values, commands, paths, and
  /// environment data cannot be supplied by this method.
  void trackDeployFailureEvidence({
    required DeployFailurePhase phase,
    required DeployFailureSource source,
    required DeployFailureCompleteness completeness,
    required int lineCount,
    required bool agentInitiated,
  });

  /// Reports one use of a strategy-relevant control.
  ///
  /// Discrete events, not tallies: pre-1.0 volume is low enough that one row
  /// per use is cheap, and when the minute-tally mechanism lands these exact
  /// call sites feed it unchanged. [control] is the closed control
  /// vocabulary ([AppControl]) -- new controls arrive as one enum value plus
  /// one call site, reviewed for cardinality before merge. [tab] rides only
  /// [AppControl.placeholderViewed] (which placeholder tab was shown),
  /// following the [trackWorkspaceOpened] tab convention; every other control
  /// reports no tab.
  void trackControlUsed({required AppControl control, String? tab});

  /// Reports one managed-database mutation resolving, for the data and
  /// safety family (Task 3.6a): every remote database mutation reports
  /// exactly once, at its resolve point. Reads (catalog/status refreshes)
  /// and local-only selection changes stay silent.
  void trackDatabaseEvent({
    required DatabaseEngine engine,
    required DataOperationOutcome outcome,
  });

  /// Reports one manual backup run resolving. Policy saves and artifact
  /// list refreshes are management, not backup runs, and stay silent.
  void trackBackupEvent({
    required BackupKind kind,
    required DataOperationOutcome outcome,
  });

  /// Reports one restore resolving, with its wall-clock duration when the
  /// call site measured one (backup-artifact restores and local `.sql`
  /// imports both report here).
  void trackRestoreEvent({
    required DataOperationOutcome outcome,
    int? durationSeconds,
  });

  /// Reports one scheduled action resolving, for the operations family
  /// (Task 3.6b): creates, updates (dialog saves and the enable toggle),
  /// manual runs, and deletes each report exactly once, at their resolve
  /// points. Status refreshes and validation rejects stay silent.
  void trackSchedulerEvent({
    required SchedulerAction action,
    required DataOperationOutcome outcome,
  });

  /// Reports one worker runtime apply resolving. Local catalog writes
  /// (`_persistWorkers`), row start/stop/restart operations, log views, and
  /// status refreshes stay silent: this is the remote apply only.
  void trackWorkerEvent({
    required WorkerAction action,
    required DataOperationOutcome outcome,
  });

  /// Reports one managed-service action resolving (web server and database
  /// lifecycles share the two funnels). Configuration payloads are never
  /// reported, only the action and its outcome. Precheck blocks,
  /// validation rejects, and stale runs stay silent.
  void trackServiceEvent({
    required ServiceAction action,
    required DataOperationOutcome outcome,
  });

  /// Reports one firewall rule change resolving: staging, committing, and
  /// rolling back, including the temporary database-access open/close. Rule
  /// contents (ports, addresses) are never reported, only the action and
  /// its outcome. Status reads and validation rejects stay silent.
  void trackFirewallEvent({
    required FirewallAction action,
    required DataOperationOutcome outcome,
  });

  /// Reports one desktop update check or install handoff resolving.
  /// [fromVersion] is the running version that checked or handed off (the
  /// upgrade cohort); only the version, never the build, bounds
  /// cardinality. A check that never ran (no snapshot) reports nothing.
  void trackUpdateEvent({
    required UpdateAction action,
    required DataOperationOutcome outcome,
    required String fromVersion,
  });

  /// Reports one terminal one-off command resolving.
  ///
  /// The command text never leaves the device: [DataOperationOutcome] is the
  /// whole payload.
  void trackTerminalCommand({required DataOperationOutcome outcome});

  /// Reports one Agent Access MCP tool call resolving.
  ///
  /// [tool] is a frozen MCP catalog name (`mcpToolDefinitions`). Only catalog
  /// names are reported; unknown tool names stay silent at the call site, so
  /// the analytics vocabulary can never gain a client-invented value.
  void trackAgentTool({
    required String tool,
    required DataOperationOutcome outcome,
  });

  /// Reports one agent-driven web app redeploy handoff resolving.
  ///
  /// This is the handoff the agent waited for (accepted vs refused and how
  /// long the reply took), not the deploy itself: the deploy funnel reports
  /// the end-to-end outcome separately when the health-gated result is known.
  void trackAgentRedeploy({
    required DataOperationOutcome outcome,
    int? durationSeconds,
  });

  /// Reports one server-onboarding wizard opening closing.
  ///
  /// The completion-funnel lens: exactly one row per wizard opening, success
  /// when services selection completed (the shell moved on), failure
  /// otherwise. The per-checkpoint funnel ([trackOnboardingStep]) says where
  /// a run stopped in provisioning terms; [stage] says where the wizard
  /// itself stood, and [provider] which credential shape it ran with. Both
  /// stay null when the flow closed before they were known.
  void trackOnboardingEvent({
    required DataOperationOutcome outcome,
    OnboardingAuthProvider? provider,
    OnboardingStage? stage,
  });

  /// Reports one engine workflow failure resolving, for the failure heatmap.
  ///
  /// Fired exactly once per failed `run_workflow` task from
  /// `SSHService.runTaskStream`, the single funnel every workflow runs
  /// through. [workflowId] and [operationId] are the orchestrator
  /// `WORKFLOW_REGISTRY` ids; anything outside the registry stays silent at
  /// the call site ([isKnownEngineWorkflowOperation]), so the analytics
  /// vocabulary can never gain a client-invented value. Cancellations,
  /// rejections, and dedupes are not failures and report nothing.
  void trackWorkflowFailed({
    required String workflowId,
    required String operationId,
  });

  /// Reports that the previous launch crashed, with the crashed error's
  /// runtime type.
  ///
  /// Fired at most once per launch by the startup sequence, and only when a
  /// crash marker from the previous launch exists (see the crash-marker
  /// helpers): no marker means no call. [errorType] is a code identifier
  /// (`runtimeType`), never a message or stack trace; blank clamps to
  /// `unknown` on the wire. The marker stays as the always-on lightweight
  /// signal when Sentry lands (see the Sentry handoff note there).
  void trackPreviousSessionCrash({required String errorType});

  /// Ends the launch session, reporting one `session_ended` row carrying
  /// `duration_seconds`.
  ///
  /// Fires on window detach (see `MainLayout`), exactly once no matter how
  /// often detach repeats, and not at all when nothing was tracked this
  /// launch. Never throws: the detach path must not crash on analytics.
  void endSession();
}

/// Why an unlock attempt failed, as the gate diagnoses it.
///
/// Mapped against the validator code, not guessed: the passphrase
/// validators collapse wrong-passphrase and missing-file into a single
/// `false` (a rejected credential reads as [authFailed] either way);
/// startup-mode check failures and restore install failures mean the local
/// data is unavailable ([dbMissing]); a passphrase that validates but whose
/// database then fails the format check is present but unusable
/// ([dbCorrupt], including newer-format files this build refuses).
enum UnlockFailureReason {
  /// The credential was rejected (wrong passphrase, creation failed).
  authFailed,

  /// The local data is unavailable (unreadable directory, missing or
  /// uninstallable restore file).
  dbMissing,

  /// The database is present but unusable (malformed, or a newer backup
  /// format than this build supports).
  dbCorrupt;

  /// The analytics storage value for this reason.
  String get storageKey {
    switch (this) {
      case UnlockFailureReason.authFailed:
        return 'auth_failed';
      case UnlockFailureReason.dbMissing:
        return 'db_missing';
      case UnlockFailureReason.dbCorrupt:
        return 'db_corrupt';
    }
  }
}

/// Where a GitHub OAuth connect flow stands, as the Riverpod flow reports it.
///
/// Closed by construction like every other reporting vocabulary: [started]
/// opens a flow, [completed] and [failed] close it, and each value maps to
/// one analytics storage key via [storageKey] (exhaustive switch, no
/// default -- adding a value without a key fails compilation).
enum GitHubOAuthStage {
  /// A connect flow began (explicit tap or cold-launch callback recovery).
  started,

  /// The flow exchanged its code and loaded repositories.
  completed,

  /// The flow ended without connecting (browser, callback, or exchange fault).
  failed;

  /// The analytics storage value for this stage.
  String get storageKey {
    switch (this) {
      case GitHubOAuthStage.started:
        return 'started';
      case GitHubOAuthStage.completed:
        return 'completed';
      case GitHubOAuthStage.failed:
        return 'failed';
    }
  }
}

/// Which credential shape a server-onboarding run used, as the desktop reports
/// it.
///
/// Closed by construction like every other reporting vocabulary: each value
/// maps to one analytics storage key via [storageKey] (exhaustive switch, no
/// default -- adding a value without a key fails compilation). The method,
/// never the key material: cardinality two, forever.
enum OnboardingAuthProvider {
  /// Password authentication.
  password,

  /// Imported SSH key authentication.
  sshKey;

  /// The analytics storage value for this provider.
  String get storageKey {
    switch (this) {
      case OnboardingAuthProvider.password:
        return 'password';
      case OnboardingAuthProvider.sshKey:
        return 'ssh_key';
    }
  }
}

/// Where the server-onboarding wizard stood, as the desktop reports it.
///
/// The wizard screens, not the provisioning checkpoints ([OnboardingStep]):
/// the completion funnel counts openings by furthest screen reached. Closed
/// by construction like every other reporting vocabulary: each value maps to
/// one analytics storage key via [storageKey] (exhaustive switch, no default
/// -- adding a value without a key fails compilation).
enum OnboardingStage {
  /// The intro screen.
  intro,

  /// The server-details form.
  credentials,

  /// The review-and-confirm screen.
  confirmation,

  /// The setup-progress screen.
  setupProgress,

  /// The services-selection screen.
  services;

  /// The analytics storage value for this stage.
  String get storageKey {
    switch (this) {
      case OnboardingStage.intro:
        return 'intro';
      case OnboardingStage.credentials:
        return 'credentials';
      case OnboardingStage.confirmation:
        return 'confirmation';
      case OnboardingStage.setupProgress:
        return 'setup_progress';
      case OnboardingStage.services:
        return 'services';
    }
  }
}

/// One server-onboarding checkpoint, as the desktop reports it.
///
/// The nine baseline members mirror the shipped provisioning stages in the
/// order a successful setup applies them; [completed] closes a successful
/// run and [hostkeyMismatch] rides the host-key confirmation dialog (confirm
/// reports success, dismiss reports failure). Closed by construction like
/// every other reporting vocabulary: each value maps to one analytics
/// storage key via [storageKey] (exhaustive switch, no default -- adding a
/// value without a key fails compilation).
enum OnboardingStep {
  /// Initial server assimilation and layout validation.
  bootstrap,

  /// The managed ubuntu login verified over a fresh key session.
  ubuntuLoginVerified,

  /// SSH daemon hardened through the early drop-in.
  sshHardened,

  /// Docker-safe SSH-only firewall baseline applied.
  firewallBaselined,

  /// Managed fail2ban SSH jail written.
  fail2ban,

  /// Ubuntu automatic security updates configured.
  autoUpdates,

  /// Exact pinned official Docker packages installed and held.
  dockerPinned,

  /// Repo-pinned Railpack release and BuildKit frontend installed.
  railpackPinned,

  /// Secure ownership handoff to the managed ubuntu identity finished.
  ownershipHandoff,

  /// The host-key change dialog answered (confirm keeps, dismiss drops).
  hostkeyMismatch,

  /// A setup run applied the whole baseline; always the last success row.
  completed,

  /// The wizard closed without setup ever succeeding; always reported with
  /// `succeeded: false` and `attempt: 0`.
  abandoned;

  /// The analytics storage value for this step.
  String get storageKey {
    switch (this) {
      case OnboardingStep.bootstrap:
        return 'bootstrap';
      case OnboardingStep.ubuntuLoginVerified:
        return 'ubuntu_login_verified';
      case OnboardingStep.sshHardened:
        return 'ssh_hardened';
      case OnboardingStep.firewallBaselined:
        return 'firewall_baselined';
      case OnboardingStep.fail2ban:
        return 'fail2ban';
      case OnboardingStep.autoUpdates:
        return 'auto_updates';
      case OnboardingStep.dockerPinned:
        return 'docker_pinned';
      case OnboardingStep.railpackPinned:
        return 'railpack_pinned';
      case OnboardingStep.ownershipHandoff:
        return 'ownership_handoff';
      case OnboardingStep.hostkeyMismatch:
        return 'hostkey_mismatch';
      case OnboardingStep.completed:
        return 'completed';
      case OnboardingStep.abandoned:
        return 'abandoned';
    }
  }
}

/// Which Railpack runtime built the deployed app, as the desktop reports it.
///
/// The twelve canonical members mirror [normalizeRailpackProvider]'s accepted
/// set exactly; [autoDetect] covers both picker auto-detect (the default, so
/// the default path stays in the funnel) and ids this build does not know --
/// the same degradation rule as [railpackRuntimeForProvider]. It reports what
/// the user chose, never a guessed provider. Closed by construction like
/// every other reporting vocabulary: each value maps to one analytics
/// storage key via [storageKey] (exhaustive switch, no default -- adding a
/// value without a key fails compilation).
enum DeployProvider {
  /// Node.js runtime.
  node,

  /// Python runtime.
  python,

  /// PHP runtime.
  php,

  /// Ruby runtime.
  ruby,

  /// Go runtime.
  golang,

  /// Java runtime.
  java,

  /// Rust runtime.
  rust,

  /// .NET runtime.
  dotnet,

  /// Deno runtime.
  deno,

  /// Elixir runtime.
  elixir,

  /// Custom shell-script runtime.
  shell,

  /// Static-site output.
  staticfile,

  /// No pinned provider: auto-detect, or an id this build does not know.
  autoDetect;

  /// The analytics storage value for this provider.
  String get storageKey {
    switch (this) {
      case DeployProvider.node:
        return 'node';
      case DeployProvider.python:
        return 'python';
      case DeployProvider.php:
        return 'php';
      case DeployProvider.ruby:
        return 'ruby';
      case DeployProvider.golang:
        return 'golang';
      case DeployProvider.java:
        return 'java';
      case DeployProvider.rust:
        return 'rust';
      case DeployProvider.dotnet:
        return 'dotnet';
      case DeployProvider.deno:
        return 'deno';
      case DeployProvider.elixir:
        return 'elixir';
      case DeployProvider.shell:
        return 'shell';
      case DeployProvider.staticfile:
        return 'staticfile';
      case DeployProvider.autoDetect:
        return 'auto_detect';
    }
  }
}

/// Where in the health-gated release pipeline a deploy resolved.
///
/// The three stages are the furthest point the backend's `cutover_status`
/// vocabulary places the run at: candidate readiness probes, the live-traffic
/// switch, and the post-cutover stabilization window. Closed by construction
/// like every other reporting vocabulary.
enum DeployStage {
  /// Candidate readiness probes (or never reaching them).
  probe,

  /// The live-traffic switch.
  cutover,

  /// The post-cutover stabilization window (and every success: success means
  /// the candidate held traffic through it).
  stabilize;

  /// The analytics storage value for this stage.
  String get storageKey {
    switch (this) {
      case DeployStage.probe:
        return 'probe';
      case DeployStage.cutover:
        return 'cutover';
      case DeployStage.stabilize:
        return 'stabilize';
    }
  }
}

/// How a deploy resolved, as the desktop reports it.
///
/// Read off the backend result, never guessed: `cancelled` only when the
/// backend names `cancelled_after_traffic_switch`, `rolled_back` only when it
/// names `reverted_to_previous_live`. Closed by construction like every other
/// reporting vocabulary.
enum DeployOutcome {
  /// The candidate went live and held through stabilization.
  success,

  /// The run failed without reverting traffic.
  failure,

  /// The run failed and live traffic reverted to the previous release.
  rolledBack,

  /// The run was cancelled after taking traffic.
  cancelled;

  /// The analytics storage value for this outcome.
  String get storageKey {
    switch (this) {
      case DeployOutcome.success:
        return 'success';
      case DeployOutcome.failure:
        return 'failure';
      case DeployOutcome.rolledBack:
        return 'rolled_back';
      case DeployOutcome.cancelled:
        return 'cancelled';
    }
  }
}

/// Which control the user used, as the desktop reports it.
///
/// The starting set answers the strategy's control questions: how users
/// arrive at screens (search submit pairs with the `workspace_opened` row
/// that follows it), deploy attempts (a superset of `deploy_event`: presses
/// that validation rejects never reach the outcome funnel), scheduled-job
/// runs, empty-state acts (the numerator for per-card dead-end conversion
/// once a seen-side event exists), and placeholder views (which shipped-later
/// tabs users already open). Each member names one hook site, documented
/// below; a new control is one value plus one call site, reviewed for
/// cardinality before merge. Closed by construction like every other
/// reporting vocabulary.
// coverage-gate: deploy_failure_analytics_metadata
enum AppControl {
  /// A rail search result was chosen (keyboard enter or row tap).
  railSearchSubmitted,

  /// The deploy button (or the env dialog's redeploy) was pressed. Agent
  /// redeploys and the internal host-key trust retry are not presses.
  deployPressed,

  /// A scheduled job's row-level "Run now" was pressed.
  runNowPressed,

  /// An empty state's action button was pressed (scheduler and workers
  /// "Add ..." buttons; the only empty states carrying actions).
  emptyStateAction,

  /// An unshipped placeholder destination (email, domain) was opened.
  placeholderViewed,

  /// The bounded deployment-failure details were copied.
  deployFailureDetailsCopied,

  /// The deployment log surface was opened from a failure card.
  deployFailureLogsOpened;

  /// The analytics storage value for this control.
  String get storageKey {
    switch (this) {
      case AppControl.railSearchSubmitted:
        return 'rail_search_submitted';
      case AppControl.deployPressed:
        return 'deploy_pressed';
      case AppControl.runNowPressed:
        return 'run_now_pressed';
      case AppControl.emptyStateAction:
        return 'empty_state_action';
      case AppControl.placeholderViewed:
        return 'placeholder_viewed';
      case AppControl.deployFailureDetailsCopied:
        return 'deploy_failure_details_copied';
      case AppControl.deployFailureLogsOpened:
        return 'deploy_failure_logs_opened';
    }
  }
}

/// Builds the only analytics payload allowed for deploy-failure evidence.
///
/// Accepting closed enums and a bucketed count makes it impossible for a
/// caller to send repository, domain, path, command, environment, or output
/// text through this event.
Map<String, Object?> deployFailureAnalyticsProperties({
  required DeployFailurePhase phase,
  required DeployFailureSource source,
  required DeployFailureCompleteness completeness,
  required int lineCount,
  required bool agentInitiated,
}) => <String, Object?>{
  'phase': phase.storageKey,
  'source': source.storageKey,
  'completeness': completeness.storageKey,
  'line_count_bucket': switch (lineCount) {
    <= 0 => '0',
    <= 3 => '1_3',
    <= 6 => '4_6',
    _ => '7_12',
  },
  'actor': agentInitiated ? 'agent' : 'local_user',
};
// end coverage-gate

/// Which managed-database engine a database event acted on.
///
/// Mirrors the engines the workspace can mutate remotely. Closed by
/// construction like every other reporting vocabulary: a new engine is one
/// value plus its hook sites.
enum DatabaseEngine {
  /// Managed PostgreSQL (the `_runDatabaseMutation` funnel).
  postgres,

  /// Managed SQLite volume storage (ensure and delete).
  sqlite;

  /// The analytics storage value for this engine.
  String get storageKey {
    switch (this) {
      case DatabaseEngine.postgres:
        return 'postgres';
      case DatabaseEngine.sqlite:
        return 'sqlite';
    }
  }
}

/// Which backup kind a backup event ran.
///
/// A single value today (only PostgreSQL has backup plans); kept as a
/// closed enum so a later engine arrives as one value plus one hook site,
/// never as a free-form string.
enum BackupKind {
  /// Managed PostgreSQL logical backup.
  postgres;

  /// The analytics storage value for this kind.
  String get storageKey {
    switch (this) {
      case BackupKind.postgres:
        return 'postgres';
    }
  }
}

/// How a data or safety operation resolved.
///
/// Shared by the whole Task 3.6a family: database mutations, backup runs,
/// and restores all resolve to exactly one of these. Rollback and
/// cancellation states belong to the deploy funnel, not here.
enum DataOperationOutcome {
  /// The operation completed.
  success,

  /// The operation was attempted and did not complete, including attempts
  /// that reached the resolve funnel but never ran remotely (an unreachable
  /// server means the mutation never ran).
  failure;

  /// The analytics storage value for this outcome.
  String get storageKey {
    switch (this) {
      case DataOperationOutcome.success:
        return 'success';
      case DataOperationOutcome.failure:
        return 'failure';
    }
  }
}

/// Which scheduled action a scheduler event acted on.
///
/// Every remote-resolving scheduler operation maps to exactly one value:
/// dialog saves report create or update by [isEdit], the enable toggle
/// reports update, row runs report run, and deletes report delete. Closed
/// by construction like every other reporting vocabulary.
enum SchedulerAction {
  /// A new scheduled job was saved.
  create,

  /// An existing scheduled job was saved or toggled.
  update,

  /// A scheduled job was run now.
  run,

  /// A scheduled job was deleted.
  delete;

  /// The analytics storage value for this action.
  String get storageKey {
    switch (this) {
      case SchedulerAction.create:
        return 'create';
      case SchedulerAction.update:
        return 'update';
      case SchedulerAction.run:
        return 'run';
      case SchedulerAction.delete:
        return 'delete';
    }
  }
}

/// Which worker action a worker event acted on.
///
/// A single value today: the remote runtime apply is the only worker
/// operation that reports. Kept as a closed enum so a later action arrives
/// as one value plus one hook site, never as a free-form string.
enum WorkerAction {
  /// The worker runtime was applied to the server.
  apply;

  /// The analytics storage value for this action.
  String get storageKey {
    switch (this) {
      case WorkerAction.apply:
        return 'apply';
    }
  }
}

/// Which managed-service action a service event acted on.
///
/// Covers every operation id the two service funnels dispatch; an unknown
/// future operation id reports nothing until it is mapped here.
enum ServiceAction {
  /// A service was enabled.
  enable,

  /// A service was started.
  start,

  /// A service was stopped.
  stop,

  /// A service was restarted.
  restart,

  /// Service settings were saved.
  configure,

  /// The database service was deleted.
  delete,

  /// The database was migrated into the named storage volume.
  migrateStorage,

  /// The old storage copy kept from migration was removed.
  removeLegacyStorage,

  /// The database moved to another PostgreSQL major version.
  upgradeMajor;

  /// The analytics storage value for this action.
  String get storageKey {
    switch (this) {
      case ServiceAction.enable:
        return 'enable';
      case ServiceAction.start:
        return 'start';
      case ServiceAction.stop:
        return 'stop';
      case ServiceAction.restart:
        return 'restart';
      case ServiceAction.configure:
        return 'configure';
      case ServiceAction.delete:
        return 'delete';
      case ServiceAction.migrateStorage:
        return 'migrate_storage';
      case ServiceAction.removeLegacyStorage:
        return 'remove_legacy_storage';
      case ServiceAction.upgradeMajor:
        return 'upgrade_major';
    }
  }
}

/// Which firewall rule change a firewall event acted on.
///
/// Stage, commit, and rollback on the Firewall tab, plus the temporary
/// database-access open (apply) and close (rollback). Never carries rule
/// contents: only the action and its outcome leave the device.
enum FirewallAction {
  /// Rule changes were staged (or temporary access opened).
  apply,

  /// Staged rule changes were committed.
  commit,

  /// Staged rule changes were rolled back (or temporary access closed).
  rollback;

  /// The analytics storage value for this action.
  String get storageKey {
    switch (this) {
      case FirewallAction.apply:
        return 'apply';
      case FirewallAction.commit:
        return 'commit';
      case FirewallAction.rollback:
        return 'rollback';
    }
  }
}

/// Which desktop update step an update event acted on.
enum UpdateAction {
  /// An update check resolved.
  check,

  /// An install handoff to the platform updater resolved.
  apply;

  /// The analytics storage value for this action.
  String get storageKey {
    switch (this) {
      case UpdateAction.check:
        return 'check';
      case UpdateAction.apply:
        return 'apply';
    }
  }
}
// end coverage-gate

/// The analytics service, for callers inside the Riverpod graph.
final appAnalyticsServiceProvider = Provider<AppAnalyticsService>(
  (ref) => appAnalyticsService,
);

AppAnalyticsService _appAnalyticsService = _createDefaultAppAnalyticsService();

/// The analytics service, for callers outside the Riverpod graph.
///
/// A global because app startup reports [AppAnalyticsService.trackAppStarted]
/// before any container exists. Both accessors return the same instance, so
/// [debugOverrideAppAnalyticsService] silences the provider too.
AppAnalyticsService get appAnalyticsService => _appAnalyticsService;

AppAnalyticsService _createDefaultAppAnalyticsService() {
  return createAnalyticsService(amplitudeApiKey: resolveAmplitudeApiKey());
}

Future<void> _defaultAptabaseInitializer(
  String appKey,
  InitOptions options,
) async {
  await Aptabase.init(appKey, options);
}

void _defaultAptabaseEventTracker(
  String eventName,
  Map<String, dynamic>? props,
) {
  Aptabase.instance.trackEvent(eventName, props);
}

// coverage-gate: aptabase_analytics_implementation
/// The shipped implementation, reporting to Aptabase.
///
/// Every path here fails closed. An empty app key -- a build made without the
/// define -- initializes nothing, and an event tracked before initialization
/// completes is dropped rather than queued. Losing an event is not a defect
/// worth code to prevent; sending one from a build that was never configured
/// to report would be.
class AptabaseAppAnalytics
    with AnalyticsContextUpdatable
    implements AppAnalyticsService {
  /// Creates the implementation over an injected initializer and tracker.
  ///
  /// [context] carries the same cross-cutting envelope as the Amplitude
  /// backend, so the backup dataset stays cohort-compatible.
  AptabaseAppAnalytics({
    required String appKey,
    required AptabaseInitializer initializer,
    required AptabaseEventTracker tracker,
    this.context = const AnalyticsEventContext(),
  }) : _appKey = appKey.trim(),
       _initializer = initializer,
       _tracker = tracker,
       _sessionStart = (context.clock ?? DateTime.now)();

  final String _appKey;
  final AptabaseInitializer _initializer;
  final AptabaseEventTracker _tracker;

  /// When this backend's launch session started, read from the context clock
  /// so tests control time through the existing seam.
  final DateTime _sessionStart;

  /// Events actually sent this launch. Zero means the session never started
  /// for reporting purposes, so [endSession] stays silent.
  int _trackedEvents = 0;

  /// Whether [endSession] already ran: one launch ends exactly once.
  bool _sessionEnded = false;

  /// Cross-cutting context merged under every event's own properties.
  ///
  /// Mutable so post-unlock hydration ([refreshAnalyticsContext]) can fill in
  /// production values without rebuilding the backend; the launch session id
  /// is always preserved across updates.
  @override
  AnalyticsEventContext context;

  bool _initialized = false;
  Future<void>? _initializationFuture;

  /// Live usage-reporting switch. Starts on: telemetry is default-on behind
  /// a notice, and only an explicit `false` silences the funnel below.
  bool _telemetryEnabled = true;

  @override
  Future<void> initialize() async {
    if (_initialized || _appKey.isEmpty) {
      return;
    }
    if (_initializationFuture != null) {
      return _initializationFuture;
    }

    final future = _initializer(
      _appKey,
      InitOptions(
        printDebugMessages: kDebugMode,
        tickDuration: _analyticsTickDuration,
      ),
    );
    _initializationFuture = future;
    try {
      await future;
      _initialized = true;
    } finally {
      _initializationFuture = null;
    }
  }

  @override
  void trackAppStarted() {
    trackEvent('app_started', const <String, Object?>{'surface': 'desktop'});
  }

  @override
  void trackWorkspaceOpened({
    required String workspace,
    String? entryPoint,
    String? tab,
  }) {
    final properties = <String, Object?>{'workspace': workspace};
    if (entryPoint != null && entryPoint.trim().isNotEmpty) {
      properties['entry_point'] = entryPoint.trim();
    }
    if (tab != null && tab.trim().isNotEmpty) {
      properties['tab'] = tab.trim();
    }

    trackEvent('workspace_opened', properties);
  }

  @override
  bool get isInitialized => _initialized;

  @override
  void setTelemetryEnabled(bool enabled) {
    _telemetryEnabled = enabled;
  }

  /// Sends one sanitized event, or nothing at all if not yet initialized or
  /// usage reporting was switched off.
  ///
  /// The single funnel every tracking method goes through, which is what makes
  /// [sanitizeAnalyticsProperties] unavoidable rather than a convention.
  /// Properties that sanitize to nothing are sent as null rather than as an
  /// empty map.
  @visibleForTesting
  void trackEvent(String eventName, [Map<String, Object?>? properties]) {
    if (!_initialized || !_telemetryEnabled) {
      return;
    }
    _trackedEvents += 1;
    final sanitizedProperties = sanitizeAnalyticsProperties(properties);
    final merged = mergeAnalyticsContext(sanitizedProperties, context.envelope);
    _tracker(eventName, merged.isEmpty ? null : merged);
  }

  @override
  void setUserAttribute(AppUserAttribute attribute, String value) {
    // Aptabase has no user properties: documented no-op. The event stream
    // stays the backup contract; attributes live on Amplitude only.
  }

  @override
  void trackUnlockFailed({required UnlockFailureReason reason}) {
    trackEvent('unlock_failed', <String, Object?>{'reason': reason.storageKey});
  }

  @override
  void trackGitHubOAuth({required GitHubOAuthStage stage}) {
    trackEvent('github_oauth', <String, Object?>{'stage': stage.storageKey});
  }

  @override
  void trackOnboardingStep({
    required OnboardingStep step,
    required bool succeeded,
    int attempt = 1,
  }) {
    // `succeeded` rides as text: the shared property sanitizer keeps strings
    // and numbers only, and both backends must store the same shape. The
    // interface still takes a bool -- the encoding is a transport detail,
    // like `hasFirstDeploySucceeded` reporting `'true'`.
    trackEvent('onboarding_step', <String, Object?>{
      'step': step.storageKey,
      'succeeded': succeeded ? 'true' : 'false',
      'attempt': attempt,
    });
  }

  @override
  void trackOnboardingStarted() {
    trackEvent('onboarding_started', const <String, Object?>{
      'surface': 'desktop',
    });
  }

  @override
  void trackEnrollment({required DataOperationOutcome outcome}) {
    trackEvent('enrollment', <String, Object?>{'outcome': outcome.storageKey});
  }

  @override
  void trackSetupIncomplete({required int attempt}) {
    trackEvent('setup_incomplete', <String, Object?>{'attempt': attempt});
  }

  @override
  void trackSetupResumed() {
    trackEvent('setup_resumed');
  }

  @override
  void trackDeployEvent({
    required DeployProvider provider,
    required String routingMode,
    required DeployStage stage,
    required DeployOutcome outcome,
    int? durationSeconds,
  }) {
    trackEvent('deploy_event', <String, Object?>{
      'provider': provider.storageKey,
      'routing_mode': routingMode,
      'stage': stage.storageKey,
      'outcome': outcome.storageKey,
      ...?_timedEventDurationProperties(durationSeconds),
    });
  }

  /// Sends only the closed deploy-failure metadata shape to Aptabase.
  @override
  void trackDeployFailureEvidence({
    required DeployFailurePhase phase,
    required DeployFailureSource source,
    required DeployFailureCompleteness completeness,
    required int lineCount,
    required bool agentInitiated,
  }) {
    trackEvent(
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

  @override
  void trackControlUsed({required AppControl control, String? tab}) {
    trackEvent('control_used', <String, Object?>{
      'control': control.storageKey,
      if (tab != null && tab.trim().isNotEmpty) 'tab': tab.trim(),
    });
  }

  @override
  void trackDatabaseEvent({
    required DatabaseEngine engine,
    required DataOperationOutcome outcome,
  }) {
    trackEvent('database_event', <String, Object?>{
      'engine': engine.storageKey,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackBackupEvent({
    required BackupKind kind,
    required DataOperationOutcome outcome,
  }) {
    trackEvent('backup_event', <String, Object?>{
      'kind': kind.storageKey,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackRestoreEvent({
    required DataOperationOutcome outcome,
    int? durationSeconds,
  }) => trackEvent(
    'restore_event',
    _restoreEventProperties(outcome: outcome, durationSeconds: durationSeconds),
  );

  @override
  void trackSchedulerEvent({
    required SchedulerAction action,
    required DataOperationOutcome outcome,
  }) {
    trackEvent('scheduler_event', <String, Object?>{
      'action': action.storageKey,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackWorkerEvent({
    required WorkerAction action,
    required DataOperationOutcome outcome,
  }) {
    trackEvent('worker_event', <String, Object?>{
      'action': action.storageKey,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackServiceEvent({
    required ServiceAction action,
    required DataOperationOutcome outcome,
  }) {
    trackEvent('service_event', <String, Object?>{
      'action': action.storageKey,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackFirewallEvent({
    required FirewallAction action,
    required DataOperationOutcome outcome,
  }) {
    trackEvent('firewall_event', <String, Object?>{
      'action': action.storageKey,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackUpdateEvent({
    required UpdateAction action,
    required DataOperationOutcome outcome,
    required String fromVersion,
  }) {
    trackEvent('update_event', <String, Object?>{
      'action': action.storageKey,
      'outcome': outcome.storageKey,
      'from_version': fromVersion,
    });
  }

  @override
  void trackTerminalCommand({required DataOperationOutcome outcome}) {
    trackEvent('terminal_command', <String, Object?>{
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackAgentTool({
    required String tool,
    required DataOperationOutcome outcome,
  }) {
    trackEvent('agent_tool', <String, Object?>{
      'tool': tool,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackAgentRedeploy({
    required DataOperationOutcome outcome,
    int? durationSeconds,
  }) {
    trackEvent('agent_redeploy', <String, Object?>{
      'outcome': outcome.storageKey,
      ...?_timedEventDurationProperties(durationSeconds),
    });
  }

  @override
  void trackOnboardingEvent({
    required DataOperationOutcome outcome,
    OnboardingAuthProvider? provider,
    OnboardingStage? stage,
  }) {
    trackEvent('onboarding_event', <String, Object?>{
      'outcome': outcome.storageKey,
      if (provider != null) 'provider': provider.storageKey,
      if (stage != null) 'stage': stage.storageKey,
    });
  }

  @override
  void trackWorkflowFailed({
    required String workflowId,
    required String operationId,
  }) {
    trackEvent('workflow_failed', <String, Object?>{
      'workflow_id': workflowId,
      'operation_id': operationId,
    });
  }

  @override
  void trackPreviousSessionCrash({required String errorType}) {
    trackEvent('previous_session_crashed', <String, Object?>{
      'error_type': crashErrorTypeOrUnknown(errorType),
    });
  }

  @override
  void endSession() {
    if (_sessionEnded) {
      return;
    }
    _sessionEnded = true;
    if (_trackedEvents == 0) {
      return;
    }
    final clockNow = context.clock ?? DateTime.now;
    final elapsedSeconds = clockNow().difference(_sessionStart).inSeconds;
    try {
      trackEvent('session_ended', <String, Object?>{
        'duration_seconds': elapsedSeconds < 0 ? 0 : elapsedSeconds,
      });
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Aptabase session end failed: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Aptabase session end failed: $error');
      }
    }
  }
}

/// The optional `duration_seconds` property shared by timed backend events.
///
/// One owner for the duration idiom: deploy, restore, and agent redeploy on
/// both backends spread this entry instead of each spelling its own
/// conditional.
Map<String, Object?>? _timedEventDurationProperties(int? durationSeconds) {
  return switch (durationSeconds) {
    final int seconds => {'duration_seconds': seconds},
    null => null,
  };
}

/// The `restore_event` property map, shared by both backends.
///
/// One owner for the restore payload: Aptabase and Amplitude report the
/// same map instead of each spelling its own inline literal.
Map<String, Object?> _restoreEventProperties({
  required DataOperationOutcome outcome,
  int? durationSeconds,
}) {
  return <String, Object?>{
    'outcome': outcome.storageKey,
    ...?_timedEventDurationProperties(durationSeconds),
  };
}

// coverage-gate: amplitude_analytics_implementation
/// Configuration handed to the Amplitude backend initializer. Plain data so
/// tests can assert exactly what the backend would be built with, without
/// ever constructing platform channels.
class AmplitudeBackendConfig {
  /// Creates the backend configuration passed to the SDK initializer.
  const AmplitudeBackendConfig({
    required this.apiKey,
    required this.serverZone,
    required this.trackingOptions,
  });

  /// The Amplitude project API key. Blank means unconfigured (fail closed).
  final String apiKey;

  /// The Amplitude data-residency zone. Always EU for this app.
  final ServerZone serverZone;

  /// Explicit collection toggles. Never SDK defaults — the pinned values are
  /// asserted by tests.
  final TrackingOptions trackingOptions;
}

/// Builds the Amplitude backend from [config]. Injectable so tests never
/// construct platform channels.
typedef AmplitudeInitializer =
    Future<void> Function(AmplitudeBackendConfig config);

/// Sends one event to Amplitude. Injectable so tests can assert on exactly
/// what would have been sent.
typedef AmplitudeEventTracker =
    Future<void> Function(String eventName, Map<String, dynamic>? props);

/// Flushes queued Amplitude events. Injectable so tests observe close
/// behavior without a backend.
typedef AmplitudeFlusher = Future<void> Function();

/// Sets user properties on Amplitude in one identify call. Injectable so
/// tests assert exact attributes without a backend.
typedef AmplitudeIdentifier =
    Future<void> Function(Map<String, String> attributes);

/// Install channels the release scaffolds stamp into builds. Source of truth
/// is the packaging scripts (`--dart-define=DEPLOYDASH_DISTRIBUTION=...`);
/// anything else is omitted, never sent as "unknown".
const Set<String> _knownDistributionChannels = <String>{
  'apt',
  'deb',
  'dmg',
  'flatpak',
  'mac_app_store',
  'msi',
  'snap',
  'windows_store',
};

/// Engine workflow operations, snapshotted from the orchestrator
/// `WORKFLOW_REGISTRY` (`orchestrator/src/orchestrator/workflow_registry.py`).
///
/// Table-driven like [_knownDistributionChannels]: the reporting vocabulary
/// is the snapshot rather than a second live reader. The Python architecture
/// guard compares it directly with the live registry, so any registry change
/// fails before a drifted entry can drop a real failure or report a retired
/// operation.
const Map<String, Set<String>> knownEngineWorkflowOperations = {
  'app': {
    'describe',
    'disconnect',
    'exec',
    'list_releases',
    'prepare_key',
    'resource_usage',
    'rollback',
    'run',
    'runtime_logs',
    'sqlite_volume_delete',
    'sqlite_volume_ensure',
    'sqlite_volume_status',
    'worker_logs',
    'worker_restart',
    'worker_start',
    'worker_stop',
    'workers_apply',
    'workers_precheck',
    'workers_status',
  },
  'core': {'echo'},
  'dns': {'describe', 'run'},
  'firewall': {
    'apply_staged',
    'commit',
    'describe',
    'rollback',
    'scan_open_ports',
    'status',
  },
  'http': {
    'describe',
    'run',
    'service_configure',
    'service_enable',
    'service_restart',
    'service_start',
    'service_status',
    'service_stop',
  },
  'mail': {'describe', 'run'},
  'postgres': {
    'backup_artifact_list',
    'backup_backlog_cleanup',
    'backup_backlog_report',
    'backup_destination_test',
    'backup_policy_apply',
    'backup_policy_delete',
    'backup_run_now',
    'describe',
    'import_local_sql',
    'project_create_database',
    'project_create_user',
    'project_delete',
    'project_delete_database',
    'project_delete_user',
    'project_describe_table',
    'project_execute_readonly_query',
    'project_explain_readonly_query',
    'project_list',
    'project_list_schemas',
    'project_list_tables',
    'project_normalize_database',
    'project_rotate_password',
    'restore_run_now',
    'run',
    'service_configure',
    'service_delete',
    'service_enable',
    'service_migrate_storage',
    'service_remove_legacy_storage',
    'service_restart',
    'service_start',
    'service_status',
    'service_stop',
    'service_upgrade_major',
  },
  'scheduler': {
    'describe',
    'task_delete',
    'task_run_now',
    'task_set_enabled',
    'task_status',
    'task_upsert',
  },
  'server': {
    'check',
    'docker_storage_prune',
    'docker_storage_status',
    'overview_metrics',
    'refresh_host_key',
    'system_apply',
    'system_restart',
    'system_status',
    'tooling_rollback',
    'tooling_status',
    'tooling_update',
  },
  'setup': {'describe', 'run'},
};

/// Whether [workflowId]/[operationId] names a real orchestrator operation.
///
/// The call-site gate for [AppAnalyticsService.trackWorkflowFailed]:
/// unknown ids report nothing, so the analytics vocabulary is the frozen
/// registry snapshot, not whatever a payload carried. Trims defensively;
/// blank is unknown.
bool isKnownEngineWorkflowOperation(String workflowId, String operationId) {
  final operations = knownEngineWorkflowOperations[workflowId.trim()];
  if (operations == null) {
    return false;
  }
  return operations.contains(operationId.trim());
}

/// Desktop CPU architectures, keyed by runtime ABI. Table-driven (not a
/// switch) so every entry is plain data: a single lookup line stays covered
/// on any host instead of one covered branch per machine running the tests.
/// Unlisted ABIs (mobile, wasm, future silicon) resolve to empty and are
/// omitted, never sent as "unknown".
const Map<Abi, String> _hostArchitectureNames = <Abi, String>{
  Abi.linuxX64: 'linux_x64',
  Abi.linuxArm64: 'linux_arm64',
  Abi.macosX64: 'macos_x64',
  Abi.macosArm64: 'macos_arm64',
  Abi.windowsX64: 'windows_x64',
  Abi.windowsArm64: 'windows_arm64',
};

/// Resolves this machine's CPU architecture to its closed-vocabulary name,
/// or empty when the ABI is not a shipped desktop target.
String defaultHostArchitecture() => _hostArchitectureNames[Abi.current()] ?? '';

/// Clock seam for tenure math. Injectable so tests pin time; production
/// passes nothing and the wall clock is used.
typedef AnalyticsClock = DateTime Function();

/// Buckets install age into the closed tenure vocabulary. A first-launch
/// date in the future (clock skew, corrupt store) yields no bucket rather
/// than a lie.
String tenureBucketFor({
  required DateTime firstLaunchAt,
  required DateTime now,
}) {
  final days = now.difference(firstLaunchAt).inDays;
  if (days < 0) {
    return '';
  }
  if (days < 7) {
    return 'new_7d';
  }
  if (days < 30) {
    return 'active_30d';
  }
  return 'established';
}

/// Maps milestone flags to the closed lifecycle vocabulary. Onboarding gates
/// every later stage: a contradictory flag set still reports `installed`.
/// `habitual` additionally requires established tenure, so a first-day power
/// user is `first_deploy`, not habitual.
String lifecycleStageFor({
  required bool onboarded,
  required bool firstDeploySucceeded,
  required String tenureBucket,
}) {
  if (!onboarded) {
    return 'installed';
  }
  if (!firstDeploySucceeded) {
    return 'onboarded';
  }
  if (tenureBucket == 'established') {
    return 'habitual';
  }
  return 'first_deploy';
}

/// Buckets a lifecycle count into the closed value-metric vocabulary:
/// `0`, `1`, `2`, or `3plus`. Saturating at three keeps installs with dozens
/// of servers indistinguishable from installs with three, and non-positive
/// counts (which live data never produces) report `0` rather than a
/// client-invented value.
String analyticsBucketForCount(int count) {
  if (count <= 0) {
    return '0';
  }
  if (count == 1) {
    return '1';
  }
  if (count == 2) {
    return '2';
  }
  return '3plus';
}

/// Generates one opaque session id per launch for cross-backend session
/// linkage. Unordered and unguessable enough for correlation; carries no
/// device or user information.
String generateAnalyticsSessionId() {
  final suffix = Random.secure()
      .nextInt(1 << 32)
      .toRadixString(16)
      .padLeft(8, '0');
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$suffix';
}

/// Cross-cutting event context shared by both backends.
///
/// Every event carries the envelope merged UNDER its own properties, so
/// cohort dimensions (tenure, lifecycle, session) ride along without any
/// call site knowing about them. Deliberately narrow: app version, OS, and
/// language already arrive automatically per backend, and screen/entry point
/// already ride each event -- the envelope adds only what no other layer
/// provides. Fully default-constructible to empty (no context configured),
/// in which case [envelope] is empty and events pass through byte-identical.
class AnalyticsEventContext {
  /// Creates event context. Production sources ([firstLaunchAt] from the
  /// install-date store, milestones from lifecycle callers) arrive via the
  /// backend factories; tests inject values directly.
  const AnalyticsEventContext({
    this.firstLaunchAt,
    this.completedMilestones = const <AppUserAttribute>{},
    this.sessionId = '',
    this.clock,
  });

  /// When this install first launched. Null until the install-date store
  /// (Task 2.5) feeds it; tenure is then omitted.
  final DateTime? firstLaunchAt;

  /// Lifecycle milestones reached so far. Empty until callers record them.
  final Set<AppUserAttribute> completedMilestones;

  /// Opaque per-launch id for cross-backend session linkage. Blank omits it.
  final String sessionId;

  /// Clock seam for tenure math. Null uses the wall clock.
  final AnalyticsClock? clock;

  /// The envelope to merge under event properties. Empty when nothing is
  /// configured, so unconfigured backends emit byte-identical events.
  Map<String, String> get envelope {
    final launchAt = firstLaunchAt;
    final session = sessionId.trim();
    if (launchAt == null && session.isEmpty && completedMilestones.isEmpty) {
      return const <String, String>{};
    }
    final clockNow = clock ?? DateTime.now;
    final tenure = launchAt == null
        ? ''
        : tenureBucketFor(firstLaunchAt: launchAt, now: clockNow());
    final result = <String, String>{
      'lifecycle': lifecycleStageFor(
        onboarded: completedMilestones.contains(
          AppUserAttribute.hasCompletedOnboarding,
        ),
        firstDeploySucceeded: completedMilestones.contains(
          AppUserAttribute.hasFirstDeploySucceeded,
        ),
        tenureBucket: tenure,
      ),
    };
    if (tenure.isNotEmpty) {
      result['tenure'] = tenure;
    }
    if (session.isNotEmpty) {
      result['session_id'] = session;
    }
    return result;
  }
}

/// Merges a context [envelope] under sanitized event properties: event data
/// always wins on key collision, so a forged context key can never rewrite
/// what the call site reported.
Map<String, dynamic> mergeAnalyticsContext(
  Map<String, dynamic> sanitizedProperties,
  Map<String, String> envelope,
) {
  if (envelope.isEmpty) {
    return sanitizedProperties;
  }
  final Map<String, dynamic> merged = {...envelope, ...sanitizedProperties};
  return merged;
}

/// Backends whose cross-cutting event context can be refreshed after
/// construction.
///
/// Post-unlock hydration ([refreshAnalyticsContext]) fills in production
/// values without rebuilding the backend. Mixed in once, implemented never
/// twice: both shipped backends carry a mutable [context] field, which
/// satisfies the getter/setter pair, and share this [updateContext].
mixin AnalyticsContextUpdatable {
  /// Cross-cutting context merged under every event's own properties.
  abstract AnalyticsEventContext context;

  /// Replaces the cross-cutting context, preserving the launch session id
  /// and clock.
  ///
  /// Null arguments leave the current value in place: the store only moves
  /// from unknown to known, so an unknown re-read must never clear a value
  /// hydration already filled in.
  void updateContext({
    DateTime? firstLaunchAt,
    Set<AppUserAttribute>? completedMilestones,
  }) {
    context = AnalyticsEventContext(
      firstLaunchAt: firstLaunchAt ?? context.firstLaunchAt,
      completedMilestones: completedMilestones ?? context.completedMilestones,
      sessionId: context.sessionId,
      clock: context.clock,
    );
  }
}

/// The shipped Amplitude implementation, reporting to the EU project.
///
/// The same fail-closed contract as [AptabaseAppAnalytics]: an empty API
/// key -- a build made without the define -- initializes nothing, and events
/// tracked before initialization completes are dropped rather than queued.
/// Amplitude's own `track` is asynchronous, so every tracking method funnels
/// through [trackEventAsync] and fires it without awaiting; tracker failures
/// are swallowed after a debug-only log so a backend fault can never surface
/// in the app.
class AmplitudeAppAnalytics
    with AnalyticsContextUpdatable
    implements AppAnalyticsService {
  /// Creates the implementation over injected seams.
  ///
  /// [distributionChannel] defaults to empty (attribute omitted); the shipped
  /// factory passes the `DEPLOYDASH_DISTRIBUTION` build define, and tests
  /// inject each known channel directly. Same arrangement for
  /// [hostArchitecture]: the factory passes [defaultHostArchitecture], tests
  /// inject values directly. [context] carries the cross-cutting envelope
  /// merged under every event; it defaults to empty (pass-through).
  AmplitudeAppAnalytics({
    required String apiKey,
    required AmplitudeInitializer initializer,
    required AmplitudeEventTracker tracker,
    required AmplitudeFlusher flusher,
    required AmplitudeIdentifier identifier,
    this.distributionChannel = '',
    this.hostArchitecture = '',
    this.context = const AnalyticsEventContext(),
  }) : _apiKey = apiKey.trim(),
       _initializer = initializer,
       _tracker = tracker,
       _flusher = flusher,
       _identifier = identifier,
       _sessionStart = (context.clock ?? DateTime.now)();

  final String _apiKey;
  final AmplitudeInitializer _initializer;
  final AmplitudeEventTracker _tracker;
  final AmplitudeFlusher _flusher;
  final AmplitudeIdentifier _identifier;

  /// The install channel stamped into this build (one of
  /// [_knownDistributionChannels]); anything else is omitted, never sent.
  final String distributionChannel;

  /// This machine's CPU architecture (one of [_hostArchitectureNames]'s
  /// values); blank means omitted. Trusted factory output, unlike the
  /// user-influenceable distribution define, so no second validation here.
  final String hostArchitecture;

  /// Cross-cutting context merged under every event's own properties.
  ///
  /// Mutable so post-unlock hydration ([refreshAnalyticsContext]) can fill in
  /// production values without rebuilding the backend; the launch session id
  /// is always preserved across updates.
  @override
  AnalyticsEventContext context;

  bool _initialized = false;
  Future<void>? _initializationFuture;

  /// Live usage-reporting switch. Starts on: telemetry is default-on behind
  /// a notice, and only an explicit `false` silences the funnel below.
  bool _telemetryEnabled = true;

  /// When this backend's launch session started, read from the context clock
  /// so tests control time through the existing seam.
  final DateTime _sessionStart;

  /// Events actually sent this launch. Zero means the session never started
  /// for reporting purposes, so [endSession] stays silent.
  int _trackedEvents = 0;

  /// Whether [endSession] already ran: one launch ends exactly once.
  bool _sessionEnded = false;

  @override
  Future<void> initialize() async {
    if (_initialized || _apiKey.isEmpty) {
      return;
    }
    if (_initializationFuture != null) {
      return _initializationFuture;
    }

    final future = _initializer(
      AmplitudeBackendConfig(
        apiKey: _apiKey,
        // Owner decision: a single EU project. Not a define -- there is
        // exactly one project, and the wrong default here would misroute data.
        serverZone: ServerZone.eu,
        // Explicit, never SDK defaults: IP for server-side geo and city for
        // future in-person planning stay on (owner decision); everything the
        // fork documents as mobile-only keeps its default.
        trackingOptions: TrackingOptions(
          ipAddress: true,
          city: true,
          country: true,
          language: true,
          platform: true,
        ),
      ),
    );
    _initializationFuture = future;
    try {
      await future;
      _initialized = true;
    } finally {
      _initializationFuture = null;
    }
    if (_initialized) {
      unawaited(_identifyInstallFacts());
    }
  }

  /// Reports immutable install facts once per launch in a single `Identify`
  /// call: install channel and CPU arch. Skipped entirely when there is
  /// nothing known to say; failures are swallowed like every other backend
  /// fault.
  Future<void> _identifyInstallFacts() async {
    final channel = distributionChannel.trim();
    final arch = hostArchitecture.trim();
    final attributes = <String, String>{
      if (_knownDistributionChannels.contains(channel)) 'distribution': channel,
      if (arch.isNotEmpty) 'arch': arch,
    };
    if (attributes.isEmpty) {
      return;
    }
    try {
      await _identifier(attributes);
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Amplitude identify failed: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Amplitude identify failed: $error');
      }
    }
  }

  @override
  void trackAppStarted() {
    _track('app_started', const <String, Object?>{'surface': 'desktop'});
  }

  @override
  void trackWorkspaceOpened({
    required String workspace,
    String? entryPoint,
    String? tab,
  }) {
    final properties = <String, Object?>{'workspace': workspace};
    if (entryPoint != null && entryPoint.trim().isNotEmpty) {
      properties['entry_point'] = entryPoint.trim();
    }
    if (tab != null && tab.trim().isNotEmpty) {
      properties['tab'] = tab.trim();
    }

    _track('workspace_opened', properties);
  }

  @override
  void setUserAttribute(AppUserAttribute attribute, String value) {
    if (!_initialized || !_telemetryEnabled || value.trim().isEmpty) {
      return;
    }
    unawaited(_setAttribute(attribute.storageKey, value.trim()));
  }

  @override
  void trackUnlockFailed({required UnlockFailureReason reason}) {
    _track('unlock_failed', <String, Object?>{'reason': reason.storageKey});
  }

  @override
  void trackGitHubOAuth({required GitHubOAuthStage stage}) {
    _track('github_oauth', <String, Object?>{'stage': stage.storageKey});
  }

  @override
  void trackOnboardingStep({
    required OnboardingStep step,
    required bool succeeded,
    int attempt = 1,
  }) {
    _track('onboarding_step', <String, Object?>{
      'step': step.storageKey,
      'succeeded': succeeded ? 'true' : 'false',
      'attempt': attempt,
    });
  }

  @override
  void trackOnboardingStarted() {
    _track('onboarding_started', const <String, Object?>{'surface': 'desktop'});
  }

  @override
  void trackEnrollment({required DataOperationOutcome outcome}) {
    _track('enrollment', <String, Object?>{'outcome': outcome.storageKey});
  }

  @override
  void trackSetupIncomplete({required int attempt}) {
    _track('setup_incomplete', <String, Object?>{'attempt': attempt});
  }

  @override
  void trackSetupResumed() {
    _track('setup_resumed');
  }

  @override
  void trackDeployEvent({
    required DeployProvider provider,
    required String routingMode,
    required DeployStage stage,
    required DeployOutcome outcome,
    int? durationSeconds,
  }) {
    _track('deploy_event', <String, Object?>{
      'provider': provider.storageKey,
      'routing_mode': routingMode,
      'stage': stage.storageKey,
      'outcome': outcome.storageKey,
      ...?_timedEventDurationProperties(durationSeconds),
    });
  }

  /// Sends only the closed deploy-failure metadata shape to Amplitude.
  @override
  void trackDeployFailureEvidence({
    required DeployFailurePhase phase,
    required DeployFailureSource source,
    required DeployFailureCompleteness completeness,
    required int lineCount,
    required bool agentInitiated,
  }) {
    _track(
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

  @override
  void trackControlUsed({required AppControl control, String? tab}) {
    _track('control_used', <String, Object?>{
      'control': control.storageKey,
      if (tab != null && tab.trim().isNotEmpty) 'tab': tab.trim(),
    });
  }

  @override
  void trackDatabaseEvent({
    required DatabaseEngine engine,
    required DataOperationOutcome outcome,
  }) {
    _track('database_event', <String, Object?>{
      'engine': engine.storageKey,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackBackupEvent({
    required BackupKind kind,
    required DataOperationOutcome outcome,
  }) {
    _track('backup_event', <String, Object?>{
      'kind': kind.storageKey,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackRestoreEvent({
    required DataOperationOutcome outcome,
    int? durationSeconds,
  }) => _track(
    'restore_event',
    _restoreEventProperties(outcome: outcome, durationSeconds: durationSeconds),
  );

  @override
  void trackSchedulerEvent({
    required SchedulerAction action,
    required DataOperationOutcome outcome,
  }) {
    _track('scheduler_event', <String, Object?>{
      'action': action.storageKey,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackWorkerEvent({
    required WorkerAction action,
    required DataOperationOutcome outcome,
  }) {
    _track('worker_event', <String, Object?>{
      'action': action.storageKey,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackServiceEvent({
    required ServiceAction action,
    required DataOperationOutcome outcome,
  }) {
    _track('service_event', <String, Object?>{
      'action': action.storageKey,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackFirewallEvent({
    required FirewallAction action,
    required DataOperationOutcome outcome,
  }) {
    _track('firewall_event', <String, Object?>{
      'action': action.storageKey,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackUpdateEvent({
    required UpdateAction action,
    required DataOperationOutcome outcome,
    required String fromVersion,
  }) {
    _track('update_event', <String, Object?>{
      'action': action.storageKey,
      'outcome': outcome.storageKey,
      'from_version': fromVersion,
    });
  }

  @override
  void trackTerminalCommand({required DataOperationOutcome outcome}) {
    _track('terminal_command', <String, Object?>{
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackAgentTool({
    required String tool,
    required DataOperationOutcome outcome,
  }) {
    _track('agent_tool', <String, Object?>{
      'tool': tool,
      'outcome': outcome.storageKey,
    });
  }

  @override
  void trackAgentRedeploy({
    required DataOperationOutcome outcome,
    int? durationSeconds,
  }) {
    _track('agent_redeploy', <String, Object?>{
      'outcome': outcome.storageKey,
      ...?_timedEventDurationProperties(durationSeconds),
    });
  }

  @override
  void trackOnboardingEvent({
    required DataOperationOutcome outcome,
    OnboardingAuthProvider? provider,
    OnboardingStage? stage,
  }) {
    _track('onboarding_event', <String, Object?>{
      'outcome': outcome.storageKey,
      if (provider != null) 'provider': provider.storageKey,
      if (stage != null) 'stage': stage.storageKey,
    });
  }

  @override
  void trackWorkflowFailed({
    required String workflowId,
    required String operationId,
  }) {
    _track('workflow_failed', <String, Object?>{
      'workflow_id': workflowId,
      'operation_id': operationId,
    });
  }

  @override
  void trackPreviousSessionCrash({required String errorType}) {
    _track('previous_session_crashed', <String, Object?>{
      'error_type': crashErrorTypeOrUnknown(errorType),
    });
  }

  @override
  void endSession() {
    if (_sessionEnded) {
      return;
    }
    _sessionEnded = true;
    if (_trackedEvents == 0) {
      return;
    }
    final clockNow = context.clock ?? DateTime.now;
    final elapsedSeconds = clockNow().difference(_sessionStart).inSeconds;
    // [_track] already swallows tracker faults, so ending can never throw.
    _track('session_ended', <String, Object?>{
      'duration_seconds': elapsedSeconds < 0 ? 0 : elapsedSeconds,
    });
  }

  /// Sends one attribute through the injected identifier, swallowing backend
  /// faults like every other tracking path.
  Future<void> _setAttribute(String storageKey, String value) async {
    try {
      await _identifier(<String, String>{storageKey: value});
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Amplitude identify failed for $storageKey: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Amplitude identify failed for $storageKey: $error');
      }
    }
  }

  /// Flushes queued events. Always delegates; the shipped flusher closes over
  /// a null client when unconfigured and no-ops, so this is safe to call
  /// unconditionally on close.
  Future<void> flush() async {
    try {
      await _flusher();
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Amplitude flush failed: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Amplitude flush failed: $error');
      }
    }
  }

  void _track(String eventName, [Map<String, Object?>? properties]) {
    unawaited(trackEventAsync(eventName, properties));
  }

  /// Sends one sanitized event, or nothing at all if not yet initialized.
  ///
  @override
  bool get isInitialized => _initialized;

  @override
  void setTelemetryEnabled(bool enabled) {
    _telemetryEnabled = enabled;
  }

  /// The async twin of the Aptabase funnel: awaitable so tests stay
  /// deterministic while the sync interface methods stay fire-and-forget.
  /// Properties that sanitize to nothing are sent as null rather than as an
  /// empty map. Silent while usage reporting is switched off.
  @visibleForTesting
  Future<void> trackEventAsync(
    String eventName, [
    Map<String, Object?>? properties,
  ]) async {
    if (!_initialized || !_telemetryEnabled) {
      return;
    }
    _trackedEvents += 1;
    final sanitizedProperties = sanitizeAnalyticsProperties(properties);
    final merged = mergeAnalyticsContext(sanitizedProperties, context.envelope);
    try {
      await _tracker(eventName, merged.isEmpty ? null : merged);
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Amplitude track failed for $eventName: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Amplitude track failed for $eventName: $error');
      }
    }
  }
}

/// Builds the shipped Amplitude backend over the real SDK.
///
/// The closures capture the built client so no SDK object crosses the
/// injectable seams: [AmplitudeAppAnalytics] only ever sees plain data and
/// callbacks. A backend that fails to build ([Amplitude.isBuilt] reporting
/// false) throws, keeping the service uninitialized (fail-closed). Nothing
/// here touches the network until [AppAnalyticsService.initialize] runs, so
/// constructing the backend is safe anywhere.
///
/// [distributionChannel] defaults to the `DEPLOYDASH_DISTRIBUTION` build
/// define and [hostArchitecture] to [defaultHostArchitecture]; tests inject
/// values directly so every known value is covered without build defines.
/// [firstLaunchAt] and [completedMilestones] resolve production context
/// values; [sessionId] defaults to one generated id per launch (the factory
/// passes an explicitly shared one so both backends link the same launch).
///
/// No `autocapture` is passed, deliberately (Task 3.11): the SDK default
/// keeps screen-view capture off and no navigator observer is attached, so
/// navigation can never emit outside the funnel, past the init/enabled
/// gates, or with open-vocabulary route names. Aptabase exposes no observer
/// hook at all. Revisit only with a closed name allowlist plus opt-out
/// wiring; the guard test pins this posture.
AmplitudeAppAnalytics buildAmplitudeBackend({
  required String apiKey,
  String distributionChannel = const String.fromEnvironment(
    'DEPLOYDASH_DISTRIBUTION',
    defaultValue: '',
  ),
  String hostArchitecture = '',
  DateTime? firstLaunchAt,
  Set<AppUserAttribute> completedMilestones = const <AppUserAttribute>{},
  String? sessionId,
}) {
  Amplitude? client;
  return AmplitudeAppAnalytics(
    apiKey: apiKey,
    distributionChannel: distributionChannel,
    hostArchitecture: hostArchitecture.isEmpty
        ? defaultHostArchitecture()
        : hostArchitecture,
    context: AnalyticsEventContext(
      firstLaunchAt: firstLaunchAt,
      completedMilestones: completedMilestones,
      sessionId: sessionId ?? generateAnalyticsSessionId(),
    ),
    initializer: (config) async {
      final built = Amplitude(
        Configuration(
          apiKey: config.apiKey,
          serverZone: config.serverZone,
          trackingOptions: config.trackingOptions,
        ),
      );
      final builtSuccessfully = await built.isBuilt;
      if (!builtSuccessfully) {
        throw StateError('Amplitude backend failed to initialize.');
      }
      client = built;
    },
    tracker: (eventName, props) async {
      await client?.track(BaseEvent(eventName, eventProperties: props));
    },
    flusher: () async {
      await client?.flush();
    },
    identifier: (attributes) async {
      if (attributes.isEmpty) {
        return;
      }
      final update = Identify();
      for (final entry in attributes.entries) {
        // Plain `set`, not `setOnce`: install facts are stamped per build
        // and constant within a profile, so repeated identical sets are
        // idempotent. One op keeps a single seam for Task 2.3's mutable
        // milestone attributes.
        update.set(entry.key, entry.value);
      }
      await client?.identify(update);
    },
  );
}
// end coverage-gate

// coverage-gate: analytics_fanout
/// Fans out to two analytics backends so one backend can never silence the
/// other or the app.
///
/// [first] is the primary backend, [second] the backup. Every call is
/// guarded per backend: initialization failures are contained (the composite
/// itself never throws from [initialize]), and tracking failures are
/// swallowed after a debug-only log. Built by [createAnalyticsService],
/// which selects the pair from build configuration.
class CompositeAppAnalytics implements AppAnalyticsService {
  /// Creates the fan-out over an explicit primary/backup pair.
  CompositeAppAnalytics({
    required AppAnalyticsService first,
    required AppAnalyticsService second,
  }) : _first = first,
       _second = second;

  final AppAnalyticsService _first;
  final AppAnalyticsService _second;

  /// Live usage-reporting switch, fanned out to both backends on every flip
  /// and consulted before fanning any event out.
  bool _telemetryEnabled = true;

  @override
  Future<void> initialize() async {
    await _guardedInitialize(_first);
    await _guardedInitialize(_second);
  }

  @override
  bool get isInitialized => _first.isInitialized && _second.isInitialized;

  @override
  void setTelemetryEnabled(bool enabled) {
    _telemetryEnabled = enabled;
    _first.setTelemetryEnabled(enabled);
    _second.setTelemetryEnabled(enabled);
  }

  @override
  void trackAppStarted() {
    _trackBoth((backend) => backend.trackAppStarted());
  }

  @override
  void trackWorkspaceOpened({
    required String workspace,
    String? entryPoint,
    String? tab,
  }) {
    _trackBoth(
      (backend) => backend.trackWorkspaceOpened(
        workspace: workspace,
        entryPoint: entryPoint,
        tab: tab,
      ),
    );
  }

  @override
  void setUserAttribute(AppUserAttribute attribute, String value) {
    _trackBoth((backend) => backend.setUserAttribute(attribute, value));
  }

  @override
  void trackUnlockFailed({required UnlockFailureReason reason}) {
    _trackBoth((backend) => backend.trackUnlockFailed(reason: reason));
  }

  @override
  void trackGitHubOAuth({required GitHubOAuthStage stage}) {
    _trackBoth((backend) => backend.trackGitHubOAuth(stage: stage));
  }

  @override
  void trackOnboardingStep({
    required OnboardingStep step,
    required bool succeeded,
    int attempt = 1,
  }) {
    _trackBoth(
      (backend) => backend.trackOnboardingStep(
        step: step,
        succeeded: succeeded,
        attempt: attempt,
      ),
    );
  }

  @override
  void trackOnboardingStarted() {
    _trackBoth((backend) => backend.trackOnboardingStarted());
  }

  @override
  void trackEnrollment({required DataOperationOutcome outcome}) {
    _trackBoth((backend) => backend.trackEnrollment(outcome: outcome));
  }

  @override
  void trackSetupIncomplete({required int attempt}) {
    _trackBoth((backend) => backend.trackSetupIncomplete(attempt: attempt));
  }

  @override
  void trackSetupResumed() {
    _trackBoth((backend) => backend.trackSetupResumed());
  }

  @override
  void trackDeployEvent({
    required DeployProvider provider,
    required String routingMode,
    required DeployStage stage,
    required DeployOutcome outcome,
    int? durationSeconds,
  }) {
    _trackBoth(
      (backend) => backend.trackDeployEvent(
        provider: provider,
        routingMode: routingMode,
        stage: stage,
        outcome: outcome,
        durationSeconds: durationSeconds,
      ),
    );
  }

  /// Fans the same closed deploy-failure metadata out to both backends.
  @override
  void trackDeployFailureEvidence({
    required DeployFailurePhase phase,
    required DeployFailureSource source,
    required DeployFailureCompleteness completeness,
    required int lineCount,
    required bool agentInitiated,
  }) {
    _trackBoth(
      (backend) => backend.trackDeployFailureEvidence(
        phase: phase,
        source: source,
        completeness: completeness,
        lineCount: lineCount,
        agentInitiated: agentInitiated,
      ),
    );
  }

  @override
  void trackControlUsed({required AppControl control, String? tab}) {
    _trackBoth(
      (backend) => backend.trackControlUsed(control: control, tab: tab),
    );
  }

  @override
  void trackDatabaseEvent({
    required DatabaseEngine engine,
    required DataOperationOutcome outcome,
  }) {
    _trackBoth(
      (backend) => backend.trackDatabaseEvent(engine: engine, outcome: outcome),
    );
  }

  @override
  void trackBackupEvent({
    required BackupKind kind,
    required DataOperationOutcome outcome,
  }) {
    _trackBoth(
      (backend) => backend.trackBackupEvent(kind: kind, outcome: outcome),
    );
  }

  @override
  void trackRestoreEvent({
    required DataOperationOutcome outcome,
    int? durationSeconds,
  }) => _trackBoth(
    (backend) => backend.trackRestoreEvent(
      outcome: outcome,
      durationSeconds: durationSeconds,
    ),
  );

  @override
  void trackSchedulerEvent({
    required SchedulerAction action,
    required DataOperationOutcome outcome,
  }) => _trackBoth(
    (backend) => backend.trackSchedulerEvent(action: action, outcome: outcome),
  );

  @override
  void trackWorkerEvent({
    required WorkerAction action,
    required DataOperationOutcome outcome,
  }) => _trackBoth(
    (backend) => backend.trackWorkerEvent(action: action, outcome: outcome),
  );

  @override
  void trackServiceEvent({
    required ServiceAction action,
    required DataOperationOutcome outcome,
  }) => _trackBoth(
    (backend) => backend.trackServiceEvent(action: action, outcome: outcome),
  );

  @override
  void trackFirewallEvent({
    required FirewallAction action,
    required DataOperationOutcome outcome,
  }) => _trackBoth(
    (backend) => backend.trackFirewallEvent(action: action, outcome: outcome),
  );

  @override
  void trackUpdateEvent({
    required UpdateAction action,
    required DataOperationOutcome outcome,
    required String fromVersion,
  }) => _trackBoth(
    (backend) => backend.trackUpdateEvent(
      action: action,
      outcome: outcome,
      fromVersion: fromVersion,
    ),
  );

  @override
  void trackTerminalCommand({required DataOperationOutcome outcome}) =>
      _trackBoth((backend) => backend.trackTerminalCommand(outcome: outcome));

  @override
  void trackAgentTool({
    required String tool,
    required DataOperationOutcome outcome,
  }) => _trackBoth(
    (backend) => backend.trackAgentTool(tool: tool, outcome: outcome),
  );

  @override
  void trackAgentRedeploy({
    required DataOperationOutcome outcome,
    int? durationSeconds,
  }) => _trackBoth(
    (backend) => backend.trackAgentRedeploy(
      outcome: outcome,
      durationSeconds: durationSeconds,
    ),
  );

  @override
  void trackOnboardingEvent({
    required DataOperationOutcome outcome,
    OnboardingAuthProvider? provider,
    OnboardingStage? stage,
  }) => _trackBoth(
    (backend) => backend.trackOnboardingEvent(
      outcome: outcome,
      provider: provider,
      stage: stage,
    ),
  );

  @override
  void trackWorkflowFailed({
    required String workflowId,
    required String operationId,
  }) => _trackBoth(
    (backend) => backend.trackWorkflowFailed(
      workflowId: workflowId,
      operationId: operationId,
    ),
  );

  @override
  void trackPreviousSessionCrash({required String errorType}) => _trackBoth(
    (backend) => backend.trackPreviousSessionCrash(errorType: errorType),
  );

  @override
  void endSession() => _trackBoth((backend) => backend.endSession());

  Future<void> _guardedInitialize(AppAnalyticsService backend) async {
    try {
      await backend.initialize();
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Analytics backend initialization failed: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Analytics backend initialization failed: $error');
      }
    }
  }

  void _trackBoth(void Function(AppAnalyticsService backend) track) {
    if (!_telemetryEnabled) {
      return;
    }
    _guarded(() => track(_first));
    _guarded(() => track(_second));
  }

  /// Flushes each flushable child, containing per-child failures so one
  /// backend can never break closing.
  Future<void> flush() async {
    await _flushIfSupported(_first);
    await _flushIfSupported(_second);
  }

  Future<void> _flushIfSupported(AppAnalyticsService backend) async {
    // NOTE: written as a guarded `as` cast rather than relying on `is`
    // promotion: Dart 3.13 does not promote through these checks (verified by
    // analyzer repro), while the cast form analyzes clean. CI pins this exact
    // SDK (see .github/actions/setup-flutter), so both agree.
    if (backend is! AnalyticsFlushable) {
      return;
    }
    try {
      await (backend as AnalyticsFlushable).flush();
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Analytics backend flush failed: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Analytics backend flush failed: $error');
      }
    }
  }

  /// Pushes refreshed production values into each context-holding child,
  /// skipping backends without stored context.
  void updateContexts({
    DateTime? firstLaunchAt,
    Set<AppUserAttribute>? completedMilestones,
  }) {
    _updateIfSupported(
      _first,
      firstLaunchAt: firstLaunchAt,
      completedMilestones: completedMilestones,
    );
    _updateIfSupported(
      _second,
      firstLaunchAt: firstLaunchAt,
      completedMilestones: completedMilestones,
    );
  }

  void _updateIfSupported(
    AppAnalyticsService backend, {
    DateTime? firstLaunchAt,
    Set<AppUserAttribute>? completedMilestones,
  }) {
    // NOTE: guarded `as` casts, not `is` promotion -- see _flushIfSupported.
    if (backend is! AnalyticsContextUpdatable) {
      return;
    }
    (backend as AnalyticsContextUpdatable).updateContext(
      firstLaunchAt: firstLaunchAt,
      completedMilestones: completedMilestones,
    );
  }

  void _guarded(void Function() call) {
    try {
      call();
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Analytics backend track failed: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Analytics backend track failed: $error');
      }
    }
  }
}

/// Implemented by backends holding queued events that must be pushed out when
/// the app closes.
///
/// Deliberately separate from [AppAnalyticsService], which stays a closed
/// product contract: flushing is a transport capability, not a reportable
/// event. Backends without queued state simply do not implement it and are
/// skipped by [flushAnalyticsOnClose].
abstract class AnalyticsFlushable {
  /// Pushes queued events out. Never throws -- implementations contain their
  /// own failures so closing can never hang or crash on analytics.
  Future<void> flush();
}

/// Flushes every flushable backend behind the current global service.
///
/// Safe to call unconditionally on close with any configured service: a
/// composite flushes each flushable child, and anything else is quietly
/// skipped. Never throws.
Future<void> flushAnalyticsOnClose() async {
  // NOTE: guarded `as` casts, not `is` promotion -- see _flushIfSupported.
  final service = _appAnalyticsService;
  if (service is CompositeAppAnalytics) {
    await service.flush();
    return;
  }
  if (service is AnalyticsFlushable) {
    await (service as AnalyticsFlushable).flush();
  }
}

/// Ends the launch session, then pushes everything out.
///
/// The single close sequence behind window detach: [AppAnalyticsService.endSession]
/// enqueues the `session_ended` row first so the flush below carries it,
/// instead of leaving it for the next launch's persisted queue. Never
/// throws, like every other close-path helper here.
Future<void> endAnalyticsSessionOnClose() async {
  _appAnalyticsService.endSession();
  await flushAnalyticsOnClose();
}

/// Builds the default analytics service from build configuration.
///
/// Without an Amplitude API key (local dev, PR CI) the service is
/// Aptabase-only -- the backup path. With a key, Amplitude leads as primary
/// and Aptabase continues as backup.
@visibleForTesting
AppAnalyticsService createAnalyticsService({
  required String amplitudeApiKey,
  DateTime? firstLaunchAt,
  Set<AppUserAttribute> completedMilestones = const <AppUserAttribute>{},
  String? sessionId,
}) {
  // One session per launch, shared so both backends link the same launch.
  final resolvedSessionId = sessionId ?? generateAnalyticsSessionId();
  final aptabase = AptabaseAppAnalytics(
    appKey: _aptabaseAppKey,
    initializer: _defaultAptabaseInitializer,
    tracker: _defaultAptabaseEventTracker,
    context: AnalyticsEventContext(
      firstLaunchAt: firstLaunchAt,
      completedMilestones: completedMilestones,
      sessionId: resolvedSessionId,
    ),
  );
  if (amplitudeApiKey.isEmpty) {
    return aptabase;
  }
  return CompositeAppAnalytics(
    first: buildAmplitudeBackend(
      apiKey: amplitudeApiKey,
      firstLaunchAt: firstLaunchAt,
      completedMilestones: completedMilestones,
      sessionId: resolvedSessionId,
    ),
    second: aptabase,
  );
}

/// Persistent source of production context values: the install date and the
/// lifecycle milestone flags.
///
/// Store choice (Task 2.5): the encrypted app database, following the
/// existing repository convention -- `SharedPreferences` carries no
/// first-party state anywhere in this app, and milestone flags belong beside
/// the other per-install facts under SQLCipher. The install date itself is
/// read from the identity file ([DeviceIdentity.createdAt], written once on
/// first launch and readable before unlock); only the flags need new
/// database columns.
abstract class AnalyticsContextStore {
  /// When this install first launched, or null when unreadable.
  Future<DateTime?> readFirstLaunchAt();

  /// Lifecycle milestones reached so far, or null when unreadable (unknown
  /// keeps the current in-memory values; only a known set replaces them).
  Future<Set<AppUserAttribute>?> readMilestones();

  /// Records a milestone flag. Write-once per flag; repositories keep the
  /// first-reached timestamp.
  Future<void> recordMilestone(AppUserAttribute attribute);
}

/// [AnalyticsContextStore] over the app database and the identity file.
///
/// Milestone flags live in the single preferences row; the install date
/// comes from the identity service. Reads degrade to unknown (null) on any
/// failure -- a closed database or an unreadable identity directory must
/// never stop events flowing with their static context.
class AppDatabaseAnalyticsContextStore implements AnalyticsContextStore {
  /// Creates the store over an explicit repository and identity loader.
  ///
  /// Both are injected (never read from globals) so tests run against an
  /// in-memory database and a stub identity without touching disk.
  AppDatabaseAnalyticsContextStore({
    required AppPreferencesRepository preferences,
    required Future<DeviceIdentity> Function() loadIdentity,
  }) : _preferences = preferences,
       _loadIdentity = loadIdentity;

  final AppPreferencesRepository _preferences;
  final Future<DeviceIdentity> Function() _loadIdentity;

  @override
  Future<DateTime?> readFirstLaunchAt() async {
    try {
      final identity = await _loadIdentity();
      return identity.createdAt;
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint(
          'Analytics install date unreadable; omitting tenure: $error',
        );
      }
      return null;
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint(
          'Analytics install date unreadable; omitting tenure: $error',
        );
      }
      return null;
    }
  }

  @override
  Future<Set<AppUserAttribute>?> readMilestones() async {
    try {
      final record = await _preferences.read();
      return {
        if (record.analyticsOnboardingCompletedAt != null)
          AppUserAttribute.hasCompletedOnboarding,
        if (record.analyticsFirstDeploySucceededAt != null)
          AppUserAttribute.hasFirstDeploySucceeded,
        if (record.analyticsGitHubConnectedAt != null)
          AppUserAttribute.hasConnectedGitHub,
      };
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Analytics milestones unreadable; keeping current: $error');
      }
      return null;
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Analytics milestones unreadable; keeping current: $error');
      }
      return null;
    }
  }

  @override
  Future<void> recordMilestone(AppUserAttribute attribute) async {
    // No switch here: the repository takes the attribute itself, so a future
    // attribute value fails compilation at its storage decision instead of
    // silently landing in (or missing) the milestone columns.
    await _preferences.recordAnalyticsMilestone(attribute);
  }
}

/// Pushes stored production values into the live backends.
///
/// Safe to call any time after unlock with any configured service: unknown
/// store values keep the current in-memory ones, backends without stored
/// context are skipped, and every failure is contained so hydration can
/// never break startup. Never throws.
Future<void> refreshAnalyticsContext(AnalyticsContextStore store) async {
  try {
    final firstLaunchAt = await store.readFirstLaunchAt();
    final milestones = await store.readMilestones();
    // NOTE: guarded `as` casts, not `is` promotion -- see _flushIfSupported.
    final service = _appAnalyticsService;
    if (service is CompositeAppAnalytics) {
      service.updateContexts(
        firstLaunchAt: firstLaunchAt,
        completedMilestones: milestones,
      );
      return;
    }
    if (service is AnalyticsContextUpdatable) {
      (service as AnalyticsContextUpdatable).updateContext(
        firstLaunchAt: firstLaunchAt,
        completedMilestones: milestones,
      );
    }
  } on Exception catch (error) {
    if (kDebugMode) {
      debugPrint(
        'Analytics context refresh failed; keeping static context: $error',
      );
    }
  } on StateError catch (error) {
    if (kDebugMode) {
      debugPrint(
        'Analytics context refresh failed; keeping static context: $error',
      );
    }
  }
}

/// Hydrates the live backends from the production providers.
///
/// Called once per launch after unlock (see `DesktopStartupActions`), when
/// the encrypted database is readable. Takes the repository, never the
/// database handle: Drift rows stay behind the mapper (see
/// `data_local_boundary_test.dart`). A closed database or an unreadable
/// identity degrades to the static context -- see [refreshAnalyticsContext].
/// Never throws.
Future<void> hydrateAnalyticsContext({
  required AppPreferencesRepository preferences,
  required Future<DeviceIdentity> Function() loadIdentity,
}) async {
  await refreshAnalyticsContext(
    AppDatabaseAnalyticsContextStore(
      preferences: preferences,
      loadIdentity: loadIdentity,
    ),
  );
}
// end coverage-gate

// coverage-gate: analytics_crash_marker
/// Lightweight crash-marker reporting (Task 3.10), not a crash reporter.
///
/// Rationale: no global error handler existed in `lib/`, so fatal errors
/// were invisible. The handlers below record only the error's runtime type
/// plus a timestamp -- never the message or stack trace (paths and user
/// content) -- and the next launch reports one `previous_session_crashed`
/// row carrying `error_type`. Sentry handoff: when full crash detail lands
/// in Sentry, Sentry owns detail and this marker stays as the always-on
/// lightweight signal unless explicitly retired then.
const String crashMarkerFileName = 'analytics_crash_marker.json';

/// Writes one crash marker. Synchronous so fatal-error handlers land the
/// marker before the isolate terminates.
typedef CrashMarkerWriter = void Function(String marker);

/// Reads the stored marker, or null when no previous launch crashed.
typedef CrashMarkerReader = String? Function();

/// Deletes the stored marker after it has been reported.
typedef CrashMarkerEraser = void Function();

/// Builds the type-only crash payload: error type plus timestamp.
///
/// Only ever these two keys: the message and stack trace stay on the device
/// because they can carry paths and user content.
String buildCrashMarkerPayload({
  required String errorType,
  required DateTime timestamp,
}) {
  return jsonEncode(<String, String>{
    'error_type': crashErrorTypeOrUnknown(errorType),
    'timestamp': timestamp.toUtc().toIso8601String(),
  });
}

/// Reads the error type back out of a marker, or null when absent or corrupt.
///
/// Never throws: a corrupt marker reports nothing rather than a guessed type.
String? parseCrashMarkerErrorType(String? raw) {
  try {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }
    final errorType = decoded['error_type'];
    if (errorType is! String || errorType.trim().isEmpty) {
      return null;
    }
    return errorType.trim();
  } on Exception catch (error) {
    // No `on StateError` arm: this body only decodes JSON and reads plain
    // maps, which cannot throw StateError, so a second arm would be
    // uncoverable dead code under the 100% scoped gates.
    if (kDebugMode) {
      debugPrint('Analytics crash marker parse failed: $error');
    }
    return null;
  }
}

/// Normalizes a crash error type for the wire: blanks become `unknown` so the
/// breakdown never gains an empty value.
///
/// Runtime types are code identifiers, not user content, so the open
/// vocabulary is the point here -- unlike every closed-enum prop above.
String crashErrorTypeOrUnknown(String errorType) {
  final type = errorType.trim();
  return type.isEmpty ? 'unknown' : type;
}

/// File-backed marker store over one pre-resolved app-support directory.
///
/// Synchronous file I/O by design: the fatal-error handlers cannot await, so
/// the write must be on disk before the handler returns. Call sites contain
/// every fault (an unwritable disk skips silently); the store itself stays
/// dumb.
class FileCrashMarkerStore {
  /// Creates the store over [directory] (see `resolveAppDataDirectory`).
  FileCrashMarkerStore(this.directory);

  /// The app-support directory holding the marker file.
  final Directory directory;

  /// The marker file.
  @visibleForTesting
  File get markerFile => File(p.join(directory.path, crashMarkerFileName));

  /// Writes [marker], replacing any previous one.
  void write(String marker) {
    markerFile.writeAsStringSync(marker, flush: true);
  }

  /// Reads the stored marker, or null when no previous launch crashed.
  String? read() {
    if (!markerFile.existsSync()) {
      return null;
    }
    return markerFile.readAsStringSync();
  }

  /// Deletes the stored marker; absent is a no-op.
  void erase() {
    if (markerFile.existsSync()) {
      markerFile.deleteSync();
    }
  }
}

/// Records a framework error's type, then preserves reporting semantics.
///
/// The marker write is best-effort and never throws; afterwards the previous
/// handler runs -- [FlutterError.presentError] when nothing else is installed
/// (today's default, verified against the SDK) -- so errors still surface
/// exactly as before. Never throws.
void handleAnalyticsFlutterError(
  FlutterErrorDetails details, {
  required CrashMarkerWriter writer,
  FlutterExceptionHandler? previous,
  DateTime Function()? clock,
}) {
  try {
    writer(
      buildCrashMarkerPayload(
        errorType: details.exception.runtimeType.toString(),
        timestamp: (clock ?? DateTime.now)(),
      ),
    );
  } on Exception catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics crash marker write failed: $error');
    }
  } on StateError catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics crash marker write failed: $error');
    }
  }
  try {
    (previous ?? FlutterError.presentError)(details);
  } on Exception catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics crash handler forwarding failed: $error');
    }
  } on StateError catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics crash handler forwarding failed: $error');
    }
  }
}

/// Records a fatal async error's type, then preserves termination semantics.
///
/// Returns the previous handler's verdict, or false when none is installed
/// (nothing is today): false leaves the error unhandled so the isolate still
/// terminates -- recording a crash must never swallow one. Never throws.
bool handleAnalyticsPlatformError(
  Object error,
  StackTrace stack, {
  required CrashMarkerWriter writer,
  bool Function(Object error, StackTrace stack)? previous,
  DateTime Function()? clock,
}) {
  try {
    writer(
      buildCrashMarkerPayload(
        errorType: error.runtimeType.toString(),
        timestamp: (clock ?? DateTime.now)(),
      ),
    );
  } on Exception catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics crash marker write failed: $error');
    }
  } on StateError catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics crash marker write failed: $error');
    }
  }
  try {
    return previous?.call(error, stack) ?? false;
  } on Exception catch (forwardError) {
    if (kDebugMode) {
      debugPrint('Analytics crash handler forwarding failed: $forwardError');
    }
    return false;
  } on StateError catch (forwardError) {
    if (kDebugMode) {
      debugPrint('Analytics crash handler forwarding failed: $forwardError');
    }
    return false;
  }
}

/// Assigns the framework-error handler behind [installAnalyticsCrashHandlers].
///
/// Injectable so tests can fault installation without a backend.
typedef FlutterCrashHandlerInstaller =
    void Function(FlutterExceptionHandler? handler);

/// Assigns the fatal-async-error handler behind [installAnalyticsCrashHandlers].
///
/// Injectable so tests can fault installation without a backend.
typedef PlatformCrashHandlerInstaller =
    void Function(bool Function(Object error, StackTrace stack)? handler);

/// The production framework-error installer: a plain global assignment.
void defaultFlutterCrashHandlerInstaller(FlutterExceptionHandler? handler) {
  FlutterError.onError = handler;
}

/// The production fatal-async-error installer: a plain global assignment.
void defaultPlatformCrashHandlerInstaller(
  bool Function(Object error, StackTrace stack)? handler,
) {
  PlatformDispatcher.instance.onError = handler;
}

/// Installs both crash handlers, chaining whatever is installed today.
///
/// Each step is guarded so startup can never fail on analytics wiring. Call
/// once from `main()` before `runApp`.
void installAnalyticsCrashHandlers({
  required CrashMarkerWriter writer,
  FlutterCrashHandlerInstaller flutterInstaller =
      defaultFlutterCrashHandlerInstaller,
  PlatformCrashHandlerInstaller platformInstaller =
      defaultPlatformCrashHandlerInstaller,
}) {
  try {
    final previousFlutter = FlutterError.onError;
    flutterInstaller(
      (details) => handleAnalyticsFlutterError(
        details,
        writer: writer,
        previous: previousFlutter,
      ),
    );
  } on Exception catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics Flutter crash handler install failed: $error');
    }
  } on StateError catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics Flutter crash handler install failed: $error');
    }
  }
  try {
    final previousPlatform = PlatformDispatcher.instance.onError;
    platformInstaller(
      (error, stack) => handleAnalyticsPlatformError(
        error,
        stack,
        writer: writer,
        previous: previousPlatform,
      ),
    );
  } on Exception catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics platform crash handler install failed: $error');
    }
  } on StateError catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics platform crash handler install failed: $error');
    }
  }
}

/// Reports the previous launch's crash, if any, then clears the marker.
///
/// Reads the marker behind [reader]; when it holds an error type, one
/// `previous_session_crashed` row fans out through the current global service
/// (both backends behind a composite) and [eraser] deletes the marker, so
/// the next launch stays silent. Absent or corrupt markers report nothing --
/// and a corrupt marker is left in place rather than guessed at. Every fault
/// (unreadable disk, throwing backend, failing erase) is contained:
/// reporting a crash must never crash the launch. Never throws.
void reportPreviousSessionCrash({
  required CrashMarkerReader reader,
  required CrashMarkerEraser eraser,
}) {
  final String? raw;
  try {
    raw = reader();
  } on Exception catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics crash marker read failed: $error');
    }
    return;
  } on StateError catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics crash marker read failed: $error');
    }
    return;
  }
  final errorType = parseCrashMarkerErrorType(raw);
  if (errorType == null) {
    return;
  }
  try {
    _appAnalyticsService.trackPreviousSessionCrash(errorType: errorType);
  } on Exception catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics crash report failed: $error');
    }
  } on StateError catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics crash report failed: $error');
    }
  }
  try {
    eraser();
  } on Exception catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics crash marker erase failed: $error');
    }
  } on StateError catch (error) {
    if (kDebugMode) {
      debugPrint('Analytics crash marker erase failed: $error');
    }
  }
}
// end coverage-gate

/// Keeps only the property values that are safe to report.
///
/// An allowlist by type, not a denylist by name: a non-empty trimmed string or
/// a number survives, and everything else -- null, a bool, a list, a map, a
/// nested object -- is dropped, along with any blank key. Structured values are
/// where user data would arrive if a caller ever passed a whole record by
/// mistake, so they never leave.
///
/// This is the last line of defence, not the first. Callers are still required
/// to pass screen identifiers rather than user content.
@visibleForTesting
Map<String, dynamic> sanitizeAnalyticsProperties(
  Map<String, Object?>? properties,
) {
  if (properties == null || properties.isEmpty) {
    return const <String, dynamic>{};
  }

  final sanitized = <String, dynamic>{};
  for (final entry in properties.entries) {
    final key = entry.key.trim();
    if (key.isEmpty) {
      continue;
    }
    final value = entry.value;
    if (value is String) {
      final normalized = value.trim();
      if (normalized.isNotEmpty) {
        sanitized[key] = normalized;
      }
      continue;
    }
    if (value is num) {
      sanitized[key] = value;
    }
  }
  return sanitized;
}

/// Replaces the global service, or restores the real one when given null.
///
/// For tests and for `debugOverride`-style setup only. Nothing in a shipped
/// path calls it.
@visibleForTesting
// end coverage-gate
void debugOverrideAppAnalyticsService(AppAnalyticsService? service) {
  _appAnalyticsService = service ?? _createDefaultAppAnalyticsService();
}
