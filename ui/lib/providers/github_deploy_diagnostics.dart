import 'dart:io';

import '../models/deploy_failure_evidence.dart';
import '../models/railpack_runtime.dart';
import '../services/app_analytics_service.dart';

const _repositorySyncActionId = 'app_part1_step2_action_sync_repository';

/// Pure helpers that read a deploy's own output and say something useful about
/// it: which timeline lines are worth keeping, which commit was deployed, and
/// which failure deserves which piece of guidance.
///
/// Split out of `github_integration_provider.dart` by T-3.3.6. Every function
/// here takes what it needs and returns a value -- no Riverpod, no I/O, no
/// state -- so the failure-hint rules can be exercised directly rather than by
/// driving a whole deploy to failure in the shape each one recognises.

/// Whether [incoming] is worth appending to a deploy timeline.
///
/// Verbose pyinfra output and heartbeats always append; anything else is
/// dropped when it repeats one of the last six lines, so a retrying step does
/// not fill the timeline with one message.
bool shouldAppendDeployTimelineLine(
  List<String> recent,
  String incoming, {
  String eventType = '',
}) {
  final normalized = incoming.trim();
  if (normalized.isEmpty) {
    return false;
  }
  if (eventType.startsWith('pyinfra_')) {
    return true;
  }
  if (eventType == 'task_heartbeat') {
    return true;
  }
  if (isVerboseDeployOutputEvent(eventType)) {
    return true;
  }
  final lookback = recent.length < 6 ? recent.length : 6;
  for (int offset = 1; offset <= lookback; offset += 1) {
    if (recent[recent.length - offset].trim() == normalized) {
      return false;
    }
  }
  return true;
}

/// Whether [eventType] is raw command output rather than a progress message.
bool isVerboseDeployOutputEvent(String eventType) {
  return eventType == 'pyinfra_operation_stdout' ||
      eventType == 'pyinfra_operation_stderr';
}

/// The name recorded as the actor of a deploy started from this workstation.
String localDeployActor() {
  final actor =
      (Platform.environment['USER'] ??
              Platform.environment['USERNAME'] ??
              'local-user')
          .trim();
  return actor.isEmpty ? 'local-user' : actor;
}

/// The deployed commit, read back out of the clone output in [timeline].
///
/// Scanned newest-first and truncated to twelve characters. Used only when the
/// engine did not report `commit_sha` itself.
String? extractCommitHashFromTimeline(List<String> timeline) {
  final headNowAt = RegExp(
    r'head is now at\s+([a-f0-9]{7,40})\b',
    caseSensitive: false,
  );
  final branchReset = RegExp(
    r'\b([a-f0-9]{7,40})\.\.\.([a-f0-9]{7,40})\b',
    caseSensitive: false,
  );
  final genericHex = RegExp(r'\b[a-f0-9]{7,40}\b', caseSensitive: false);

  for (int index = timeline.length - 1; index >= 0; index -= 1) {
    final line = timeline[index];
    final explicitHeadMatch = headNowAt.firstMatch(line);
    if (explicitHeadMatch != null) {
      final hash = explicitHeadMatch.group(1);
      if (hash != null && hash.isNotEmpty) {
        return hash.length > 12 ? hash.substring(0, 12) : hash;
      }
    }

    final branchResetMatch = branchReset.firstMatch(line);
    if (branchResetMatch != null) {
      final hash = branchResetMatch.group(2);
      if (hash != null && hash.isNotEmpty) {
        return hash.length > 12 ? hash.substring(0, 12) : hash;
      }
    }

    final match = genericHex.firstMatch(line);
    if (match == null) {
      continue;
    }
    final hash = match.group(0);
    if (hash == null || hash.isEmpty) {
      continue;
    }
    if (!RegExp(r'[a-f]', caseSensitive: false).hasMatch(hash)) {
      continue;
    }
    return hash.length > 12 ? hash.substring(0, 12) : hash;
  }
  return null;
}

/// A GitHub authorization failure as a sentence, with Dart's `Bad state: `
/// prefix stripped -- that prefix is an implementation detail leaking into
/// user-facing copy.
String formatGitHubAuthError(Object error) {
  final message = error.toString();
  const statePrefix = 'Bad state: ';
  final normalized = message.startsWith(statePrefix)
      ? message.substring(statePrefix.length)
      : message;
  if (normalized.isEmpty) {
    return 'GitHub authorization failed. Try connecting again.';
  }
  return 'GitHub authorization failed: $normalized';
}

/// Guidance when the build failed because Railpack could not find the app.
///
/// The monorepo case: the app is real but lives in a subdirectory nobody has
/// configured yet.
String? hintForMissingRailpackApp({
  required String failureMessage,
  required List<String> timeline,
  required String? configuredSubdirectory,
}) {
  final normalizedFailure = failureMessage.toLowerCase();
  if (normalizedFailure.contains('app subdirectory')) {
    return null;
  }

  final hasRailpackDetectionFailure =
      normalizedFailure.contains(
        'railpack could not determine how to build the app',
      ) ||
      normalizedFailure.contains('script start.sh not found') ||
      timeline.any((line) {
        final normalized = line.toLowerCase();
        return normalized.contains(
              'railpack could not determine how to build the app',
            ) ||
            normalized.contains('script start.sh not found');
      });

  if (!hasRailpackDetectionFailure) {
    return null;
  }

  if (configuredSubdirectory == null || configuredSubdirectory.isEmpty) {
    return 'Automatic build detection could not find your app at repository '
        'root. If this '
        'is a monorepo, open Deployment Settings and set "App subdirectory" '
        '(for example: website), then redeploy.';
  }

  return 'Automatic build detection still could not find an app in '
      'subdirectory '
      '"$configuredSubdirectory". Verify build files (for example '
      'package.json) exist there, or update "App subdirectory".';
}

/// Guidance when the build script copied into an output path it did not create.
String? hintForWrongBuildOutputPath({
  required String failureMessage,
  required List<String> timeline,
}) {
  final normalizedFailure = failureMessage.toLowerCase();
  final hasOutputCopyFailure =
      normalizedFailure.contains(
        "cp: cannot create regular file '.output/server'",
      ) ||
      timeline.any((line) {
        final normalized = line.toLowerCase();
        return normalized.contains(
          "cp: cannot create regular file '.output/server'",
        );
      });
  if (!hasOutputCopyFailure) {
    return null;
  }
  return 'Your build script is copying into `.output/server`, but this build '
      'produced `dist/server`. Update the app build script (or Deployment '
      'Settings build command) to use the correct output path.';
}

/// Guidance when another project already owns one of the requested domains.
String? hintForDomainOwnershipConflict({required String failureMessage}) {
  final normalizedFailure = failureMessage.toLowerCase();
  if (!normalizedFailure.contains('domain ownership conflict')) {
    return null;
  }
  return 'Another project already owns one of these domains. Open that '
      'project and change or disconnect its domain routing before retrying.';
}

/// Guidance when the clone failed for an access reason rather than a build one.
// coverage-gate: repository_access_hint
String? hintForRepositoryAccessFailure({
  required String failureMessage,
  required List<String> timeline,
  DeployFailureEvidence? failureEvidence,
}) {
  if (!isRepositoryCloneAccessFailure(
    failureMessage: failureMessage,
    timeline: timeline,
    failureEvidence: failureEvidence,
  )) {
    return null;
  }
  return 'Repository clone failed. Confirm the selected repository exists '
      'at the exact owner/name, and that the GitHub token can manage deploy '
      'keys for it.';
}
// end coverage-gate

/// Which provider a deploy ran under, for the deploy funnel.
///
/// Total: a canonical id names its member, while null, blank, and ids this
/// build does not know degrade to [DeployProvider.autoDetect] -- the same
/// rule as [railpackRuntimeForProvider]. Auto-detect is the picker's default,
/// so dropping it would lose the default path from the funnel; reporting what
/// the user chose is honest, guessing a provider is not.
DeployProvider deployProviderForName(String? raw) {
  final normalized = normalizeRailpackProvider(raw);
  switch (normalized) {
    case 'node':
      return DeployProvider.node;
    case 'python':
      return DeployProvider.python;
    case 'php':
      return DeployProvider.php;
    case 'ruby':
      return DeployProvider.ruby;
    case 'golang':
      return DeployProvider.golang;
    case 'java':
      return DeployProvider.java;
    case 'rust':
      return DeployProvider.rust;
    case 'dotnet':
      return DeployProvider.dotnet;
    case 'deno':
      return DeployProvider.deno;
    case 'elixir':
      return DeployProvider.elixir;
    case 'shell':
      return DeployProvider.shell;
    case 'staticfile':
      return DeployProvider.staticfile;
    default:
      return DeployProvider.autoDetect;
  }
}

/// Where in the health-gated pipeline a deploy resolved.
///
/// Read off the backend's `cutover_status` vocabulary
/// (`release_lifecycle.py` is the owner; these ids are read, never sent):
/// `pre_cutover_probe_failed` never left probes, `traffic_switch_failed` and
/// `cancelled_after_traffic_switch` resolved at the switch, the two
/// `reverted_after_*` ids resolved in stabilization, and `live` means the
/// candidate held traffic through it. Success always reports
/// [DeployStage.stabilize] regardless of payload -- the desktop only reaches
/// the success path after the full pipeline passed. Anything unrecognised
/// (no result, `not_started`, a future id) reports [DeployStage.probe]: the
/// run never demonstrably entered the pipeline, so the first stage is
/// nearest rather than a guessed later one.
DeployStage deployStageForResult({
  required bool success,
  Map<String, dynamic>? deployResult,
}) {
  if (success) {
    return DeployStage.stabilize;
  }
  switch (deployResult?['cutover_status']?.toString()) {
    case 'pre_cutover_probe_failed':
      return DeployStage.probe;
    case 'traffic_switch_failed':
    case 'cancelled_after_traffic_switch':
      return DeployStage.cutover;
    case 'reverted_after_stabilization_failure':
    case 'reverted_after_unexpected_error':
      return DeployStage.stabilize;
    case 'live':
      return DeployStage.stabilize;
    default:
      return DeployStage.probe;
  }
}

/// How a deploy resolved, for the deploy funnel.
///
/// The success boolean rules: only the backend's own success verdict reports
/// [DeployOutcome.success]. Below that, `cancelled_after_traffic_switch`
/// names itself even when a revert also ran (the user stopped the deploy;
/// the revert was cleanup), `reverted_to_previous_live` means
/// [DeployOutcome.rolledBack], and everything else -- including failures
/// before the pipeline produced a result -- is [DeployOutcome.failure].
DeployOutcome deployOutcomeForResult({
  required bool success,
  Map<String, dynamic>? deployResult,
}) {
  if (success) {
    return DeployOutcome.success;
  }
  if (deployResult?['cutover_status']?.toString() ==
      'cancelled_after_traffic_switch') {
    return DeployOutcome.cancelled;
  }
  if (deployResult?['rollback_status']?.toString() ==
      'reverted_to_previous_live') {
    return DeployOutcome.rolledBack;
  }
  return DeployOutcome.failure;
}

/// Whether the failure looks like the repository could not be reached at all.
///
/// Distinguishes "the deploy key cannot read this repository" from "the build
/// broke", which is what decides whether rotating the key is worth a retry.
// coverage-gate: repository_access_detection
bool isRepositoryCloneAccessFailure({
  required String failureMessage,
  required List<String> timeline,
  DeployFailureEvidence? failureEvidence,
}) {
  if (failureEvidence?.phase != DeployFailurePhase.repositorySync ||
      failureEvidence?.failedActionId != _repositorySyncActionId) {
    return false;
  }
  const hardAccessFailureMarkers = <String>[
    'repository not found',
    'could not read from remote repository',
    'correct access rights',
    'permission denied (publickey)',
  ];
  final normalizedFailure = failureMessage.toLowerCase();
  if (hardAccessFailureMarkers.any(normalizedFailure.contains)) {
    return true;
  }
  for (final line in timeline) {
    final normalizedLine = line.toLowerCase();
    if (hardAccessFailureMarkers.any(normalizedLine.contains)) {
      return true;
    }
  }
  return false;
}
// end coverage-gate
