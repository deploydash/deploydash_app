import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_deployment_history_repository.dart';
import '../data/local/app_environment_variable_repository.dart';
import '../data/local/app_preferences_repository.dart';
import '../data/local/app_release_repository.dart';
import '../data/local/github_secret_repository.dart';
import '../data/local/project_network_trust_repository.dart';
import '../data/local/project_sqlite_database_repository.dart';
import '../data/local/project_sqlite_snapshot_repository.dart';
import '../data/local/terminal_log_repository.dart';
import '../models/deploy_failure_evidence.dart';
import '../models/railpack_runtime.dart';
import '../models/app_public_health.dart';
import '../models/app_user_attribute.dart';
import '../models/github_repository.dart';
import '../models/workspace_scope.dart';
import '../models/result.dart';
import '../services/app_analytics_service.dart';
import '../utils/format_clock_time.dart';
import '../utils/project_slug.dart';
import '../utils/trim_or_null.dart';
import 'telemetry_settings_provider.dart';
import 'app_release_provider.dart';
import 'project_provider.dart';
import 'server_list_provider.dart';
import 'server_provider.dart';

export '../models/github_repository.dart';
// Re-exported so every existing `import 'github_integration_provider.dart'`
// keeps resolving the state types and the gateway. T-3.3.6 moved where they
// are defined, not what they are; a caller should not have to know.
export 'github_api_gateway.dart';
export 'github_integration_state.dart';

import 'github_api_gateway.dart';
import 'github_deploy_diagnostics.dart';
import 'github_integration_state.dart';

const _deployFailureEvidenceTerminalSource = 'app_deploy_failure_evidence';

// coverage-gate: deploy_failure_result_decoding
/// Reads typed evidence from the one engine-result decoding boundary.
DeployFailureEvidence? _deployFailureEvidenceFromResult(
  Result<Map<String, dynamic>> result,
) {
  if (_deployOutcomeCannotOwnFailureEvidence(result.diagnosticPayload)) {
    return null;
  }
  return switch (result) {
    Err<Map<String, dynamic>>(failure: EngineFailure(:final failureEvidence)) =>
      failureEvidence,
    Ok<Map<String, dynamic>>(:final value) =>
      DeployFailureEvidence.fromEnvelope(value),
    _ => null,
  };
}

/// Preserves legacy readiness copy while the typed evidence rollout overlaps.
String? _deploymentFailureMessage(Map<String, dynamic> deployResult) {
  if (deployResult['status'] == 'success') {
    return null;
  }
  final readinessSummary = deployResult['readiness_failure_summary']
      ?.toString()
      .trim();
  if (readinessSummary != null && readinessSummary.isNotEmpty) {
    return readinessSummary;
  }
  final rawFailureMessage = deployResult['msg']?.toString().trim();
  return rawFailureMessage == null || rawFailureMessage.isEmpty
      ? 'Web app deployment failed on server.'
      : rawFailureMessage;
}

/// Decodes a stored result object without letting malformed JSON escape recovery.
Map<String, dynamic>? _decodeJournalResult(String? resultJson) {
  if (resultJson == null || resultJson.trim().isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(resultJson);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// Excludes outcomes that require user choice or represent cancellation.
bool _deployOutcomeCannotOwnFailureEvidence(Map<String, dynamic> result) {
  final code = result['code']?.toString();
  return result['repository_host_key_confirmation_required'] == true ||
      code == 'ENGINE_TASK_CANCELLED' ||
      code == 'ENGINE_TASK_CANCELLED_FORCED';
}
// end coverage-gate

class _GitHubDeployRunContext {
  const _GitHubDeployRunContext({
    required this.run,
    required this.repositoryFullName,
    required this.branch,
    required this.primaryDomain,
    required this.startedAt,
  });

  final WorkspaceRunContext run;
  final String repositoryFullName;
  final String branch;
  final String primaryDomain;
  final DateTime startedAt;

  String get runId => run.runId;
  String get projectId => run.scope.projectId;
  String get serverId => run.scope.serverId;
}

class _PendingRepositoryHostKeyRetry {
  const _PendingRepositoryHostKeyRetry({
    required this.primaryDomain,
    required this.branch,
    required this.appPort,
    required this.repositoryFullName,
    required this.domainRoutingMode,
    required this.railpackBuildCommand,
    required this.railpackRunCommand,
    required this.railpackProvider,
    required this.appSubdirectory,
    required this.selectedServer,
    required this.selectedProject,
    required this.actorLabel,
    required this.onTaskStarted,
  });

  final String primaryDomain;
  final String branch;
  final int appPort;
  final String? repositoryFullName;
  final String? domainRoutingMode;
  final String? railpackBuildCommand;
  final String? railpackRunCommand;
  final String? railpackProvider;
  final String? appSubdirectory;
  final Server? selectedServer;
  final Project? selectedProject;
  final String? actorLabel;
  final void Function(int taskId, String phase)? onTaskStarted;
}

class GitHubIntegrationNotifier extends Notifier<GitHubIntegrationState> {
  static const _clientId = String.fromEnvironment(
    'DEPLOYDASH_GITHUB_CLIENT_ID',
    defaultValue: 'Ov23li3hzh5iO3xBe4pt',
  );
  static const _clientSecret = String.fromEnvironment(
    'DEPLOYDASH_GITHUB_CLIENT_SECRET',
    defaultValue: '',
  );
  static const _redirectUri = 'deploydash://callback';
  static const _oauthStatePrefix = 'deploydash_oauth_state';

  StreamSubscription<Uri>? _callbackSubscription;
  bool _sessionRestoreScheduled = false;
  String? _pendingOauthState;
  final Map<String, _PendingRepositoryHostKeyRetry>
  _pendingRepositoryHostKeyRetryByProject = {};
  final Map<String, String> _acceptedRepositoryHostKeyPromptIdByProject = {};

  bool _deployIsRunning(GitHubDeployStatus status) {
    return isDeployStatusRunning(status);
  }

  GitHubProjectDeployState _projectDeployState(String projectId) {
    return state.deployStateForProject(projectId);
  }

  void _setProjectDeployState({
    required String projectId,
    required GitHubProjectDeployState projectState,
    bool mirrorToActiveDeploy = false,
  }) {
    final projectStates = Map<String, GitHubProjectDeployState>.from(
      state.projectDeployStates,
    );
    projectStates[projectId] = projectState;

    final repositoryByProject = Map<String, String>.from(
      state.selectedRepositoryFullNameByProjectId,
    );
    final selectedRepository = projectState.selectedRepositoryFullName?.trim();
    if (selectedRepository != null && selectedRepository.isNotEmpty) {
      repositoryByProject[projectId] = selectedRepository;
    } else {
      repositoryByProject.remove(projectId);
    }

    final shouldMirror =
        mirrorToActiveDeploy || state.activeDeployProjectId == projectId;
    state = state.copyWith(
      projectDeployStates: projectStates,
      selectedRepositoryFullNameByProjectId: repositoryByProject,
      selectedRepositoryFullName: shouldMirror
          ? projectState.selectedRepositoryFullName
          : null,
      clearSelectedRepository:
          shouldMirror && projectState.selectedRepositoryFullName == null,
      deployStatus: shouldMirror ? projectState.deployStatus : null,
      statusMessage: shouldMirror ? projectState.statusMessage : null,
      deployTimeline: shouldMirror ? projectState.deployTimeline : null,
      activeDeployRepositoryFullName: shouldMirror
          ? projectState.activeRepositoryFullName
          : null,
      clearActiveDeployRepositoryFullName:
          shouldMirror && projectState.activeRepositoryFullName == null,
      clearActiveDeployProjectId:
          shouldMirror &&
          state.activeDeployProjectId == projectId &&
          projectState.activeRunId == null &&
          projectState.deployStatus !=
              GitHubDeployStatus.awaitingRepositoryHostKeyConfirmation,
      failureEvidence: shouldMirror ? projectState.failureEvidence : null,
      clearFailureEvidence:
          shouldMirror && projectState.failureEvidence == null,
      suggestedNextStep: shouldMirror ? projectState.suggestedNextStep : null,
      clearSuggestedNextStep:
          shouldMirror && projectState.suggestedNextStep == null,
    );
  }

  bool _isCurrentDeployRun(_GitHubDeployRunContext context) {
    final scopedState = state.projectDeployStates[context.projectId];
    return scopedState?.activeRunId == context.runId &&
        scopedState?.activeServerId == context.serverId &&
        scopedState?.activeRepositoryFullName == context.repositoryFullName;
  }

  /// Mirrors one selected project's scoped state into legacy top-level fields.
  void mirrorProjectDeployState(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }
    final projectState = _projectDeployState(normalizedProjectId);
    _setProjectDeployState(
      projectId: normalizedProjectId,
      projectState: projectState,
      mirrorToActiveDeploy: true,
    );
  }

  /// Mirrors only failure evidence when a workspace changes selected project.
  void mirrorProjectFailureEvidence(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }
    final evidence = _projectDeployState(normalizedProjectId).failureEvidence;
    state = state.copyWith(
      failureEvidence: evidence,
      clearFailureEvidence: evidence == null,
    );
  }

  // coverage-gate: deploy_failure_restore
  /// Restores a still-current failed deploy without reviving stale outcomes.
  Future<void> restoreLatestDeployFailure({
    required String projectId,
    required Server server,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty || server.id.trim().isEmpty) {
      return;
    }
    final journal = await ref
        .read(appReleaseRepositoryProvider)
        .readLatestFailedJournalForOperation(
          projectId: normalizedProjectId,
          serverId: server.id,
          surface: 'app',
          operationType: 'run',
        );
    if (!ref.mounted || journal == null) {
      return;
    }
    final result = _decodeJournalResult(journal.resultJson);
    if (result == null || _deployOutcomeCannotOwnFailureEvidence(result)) {
      return;
    }
    final evidence = DeployFailureEvidence.fromEnvelope(result);
    if (evidence == null) {
      return;
    }
    var current = _projectDeployState(normalizedProjectId);
    if (current.isRunning ||
        current.activeRunId != null ||
        current.deployStatus == GitHubDeployStatus.success) {
      return;
    }
    await _persistDeployFailureEvidence(
      projectId: normalizedProjectId,
      server: server,
      evidence: evidence,
      journal: journal,
    );
    if (!ref.mounted) {
      return;
    }
    current = _projectDeployState(normalizedProjectId);
    if (current.isRunning ||
        current.activeRunId != null ||
        current.deployStatus == GitHubDeployStatus.success) {
      return;
    }
    _setProjectDeployState(
      projectId: normalizedProjectId,
      projectState: current.copyWith(
        deployStatus: GitHubDeployStatus.error,
        statusMessage:
            _deploymentFailureMessage(result) ?? current.statusMessage,
        failureEvidence: evidence,
        clearSuggestedNextStep: true,
      ),
      mirrorToActiveDeploy:
          ref.read(selectedProjectProvider)?.id == normalizedProjectId,
    );
  }
  // end coverage-gate

  @override
  GitHubIntegrationState build() {
    ref.onDispose(() => _callbackSubscription?.cancel());
    _ensureCallbackListener();
    if (!_sessionRestoreScheduled) {
      _sessionRestoreScheduled = true;
      unawaited(_restoreStoredGitHubSession());
      unawaited(_restorePendingOauthCallback());
    }
    return const GitHubIntegrationState();
  }

  Future<void> _restoreStoredGitHubSession() async {
    final secretRepo = ref.read(gitHubSecretRepositoryProvider);
    final token = await secretRepo.readAuthToken();
    if (token == null || token.trim().isEmpty) {
      return;
    }

    state = state.copyWith(
      connectStatus: GitHubConnectStatus.loadingRepositories,
      statusMessage: 'Restoring GitHub session...',
      authToken: token,
    );

    try {
      final repos = await ref
          .read(gitHubAuthGatewayProvider)
          .fetchRepositories(accessToken: token);
      if (!ref.mounted) {
        return;
      }
      final preferredRepository = _preferredRepositorySelection(repos);
      state = state.copyWith(
        connectStatus: GitHubConnectStatus.connected,
        repositories: repos,
        selectedRepositoryFullName: preferredRepository,
        statusMessage: repos.isEmpty
            ? 'GitHub connected. No repositories found.'
            : 'GitHub connected. Pick a repository to deploy.',
      );
    } on IOException {
      await secretRepo.clearAuthToken();
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(
        connectStatus: GitHubConnectStatus.disconnected,
        statusMessage: 'Stored GitHub session expired. Please reconnect.',
        clearAuthToken: true,
        repositories: const [],
        clearSelectedRepository: true,
      );
    } on StateError {
      await secretRepo.clearAuthToken();
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(
        connectStatus: GitHubConnectStatus.disconnected,
        statusMessage: 'Stored GitHub session expired. Please reconnect.',
        clearAuthToken: true,
        repositories: const [],
        clearSelectedRepository: true,
      );
    }
  }

  Future<void> _restorePendingOauthCallback() async {
    final initialCallback = await ref
        .read(gitHubAuthGatewayProvider)
        .getInitialCallbackLink();
    if (!ref.mounted || initialCallback == null) {
      return;
    }
    // A pending callback means a flow began before this launch: count it as
    // started so the funnel pairs it with the outcome processed below.
    _trackOAuthStage(GitHubOAuthStage.started);
    await processCallbackUri(initialCallback);
  }

  Uri _buildAuthorizationUrl(String oauthState) {
    return Uri.https('github.com', '/login/oauth/authorize', {
      'client_id': _clientId,
      'redirect_uri': _redirectUri,
      'scope': 'repo read:user',
      'state': oauthState,
    });
  }

  String _createOauthState() {
    final random = Random.secure().nextInt(1 << 32).toRadixString(16);
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return '${_oauthStatePrefix}_$ts$random';
  }

  void _ensureCallbackListener() {
    if (_callbackSubscription != null) {
      return;
    }

    _callbackSubscription = ref
        .read(gitHubAuthGatewayProvider)
        .callbackLinks
        .listen(
          (uri) => processCallbackUri(uri),
          onError: (_) {
            state = state.copyWith(
              connectStatus: GitHubConnectStatus.error,
              statusMessage:
                  'Deep-link listener failed. Retry GitHub connection.',
            );
          },
        );
  }

  // coverage-gate: github_oauth_connect
  /// Reports one OAuth stage. Single seam so the seven hook sites cannot
  /// drift onto different providers or method spellings. A completed stage
  /// also records the first-connect activation milestone alongside the event,
  /// mirroring how the deploy funnel records first-deploy success.
  void _trackOAuthStage(GitHubOAuthStage stage) {
    final analytics = ref.read(appAnalyticsServiceProvider);
    analytics.trackGitHubOAuth(stage: stage);
    if (stage == GitHubOAuthStage.completed) {
      analytics.setUserAttribute(AppUserAttribute.hasConnectedGitHub, 'true');
    }
  }

  Future<void> connectGitHub() async {
    _trackOAuthStage(GitHubOAuthStage.started);
    final preferences = ref.read(appPreferencesRepositoryProvider);
    await ref.read(gitHubSecretRepositoryProvider).clearAuthToken();
    final oauthState = _createOauthState();
    _pendingOauthState = oauthState;
    await preferences.setGitHubPendingOauthState(oauthState);
    final authUrl = _buildAuthorizationUrl(oauthState);
    state = state.copyWith(
      connectStatus: GitHubConnectStatus.launchingBrowser,
      deployStatus: GitHubDeployStatus.idle,
      statusMessage: 'Opening browser for GitHub authorization...',
      authorizationUrl: authUrl.toString(),
      repositories: const [],
      clearSelectedRepository: true,
      deployTimeline: const [],
      clearLastAuthCode: true,
      clearAuthToken: true,
    );

    final launched = await ref
        .read(gitHubAuthGatewayProvider)
        .openAuthorizationUrl(authUrl);

    if (!launched) {
      _pendingOauthState = null;
      await preferences.setGitHubPendingOauthState(null);
      _trackOAuthStage(GitHubOAuthStage.failed);
      state = state.copyWith(
        connectStatus: GitHubConnectStatus.error,
        statusMessage: 'Could not open browser. Open OAuth URL manually.',
      );
      return;
    }

    state = state.copyWith(
      connectStatus: GitHubConnectStatus.awaitingCallback,
      statusMessage:
          'Authorize Deploy Dash in browser, then return via deploydash://callback.',
    );
  }

  Future<void> processCallbackUrl(String callbackUrl) async {
    final parsedUri = Uri.tryParse(callbackUrl.trim());
    if (parsedUri == null) {
      state = state.copyWith(
        connectStatus: GitHubConnectStatus.error,
        statusMessage: 'Invalid callback URL.',
      );
      return;
    }

    await processCallbackUri(parsedUri);
  }

  Future<void> processCallbackUri(Uri callbackUri) async {
    if (callbackUri.scheme != 'deploydash' || callbackUri.host != 'callback') {
      return;
    }

    final preferences = ref.read(appPreferencesRepositoryProvider);
    final callbackState = callbackUri.queryParameters['state'];
    final expectedState =
        _pendingOauthState ??
        (await preferences.read()).gitHubPendingOauthState;
    if (expectedState == null ||
        callbackState == null ||
        callbackState != expectedState) {
      if (expectedState == null) {
        return;
      }
      _pendingOauthState = null;
      await preferences.setGitHubPendingOauthState(null);
      _trackOAuthStage(GitHubOAuthStage.failed);
      state = state.copyWith(
        connectStatus: GitHubConnectStatus.error,
        statusMessage: 'OAuth state mismatch. Please reconnect GitHub.',
      );
      return;
    }

    final code = callbackUri.queryParameters['code'];
    if (code == null || code.isEmpty) {
      _pendingOauthState = null;
      await preferences.setGitHubPendingOauthState(null);
      _trackOAuthStage(GitHubOAuthStage.failed);
      state = state.copyWith(
        connectStatus: GitHubConnectStatus.error,
        statusMessage: 'Missing GitHub authorization code in callback.',
      );
      return;
    }

    state = state.copyWith(
      connectStatus: GitHubConnectStatus.exchangingCode,
      statusMessage: 'Exchanging authorization code...',
      lastAuthCode: code,
    );

    try {
      final gateway = ref.read(gitHubAuthGatewayProvider);
      final secretRepo = ref.read(gitHubSecretRepositoryProvider);
      final token = await gateway.exchangeCodeForToken(
        code: code,
        clientId: _clientId,
        clientSecret: _clientSecret,
        redirectUri: _redirectUri,
      );
      await secretRepo.saveAuthToken(token);
      _pendingOauthState = null;
      await preferences.setGitHubPendingOauthState(null);

      state = state.copyWith(
        connectStatus: GitHubConnectStatus.loadingRepositories,
        statusMessage: 'Loading repositories...',
        authToken: token,
      );

      final repos = await gateway.fetchRepositories(accessToken: token);
      final preferredRepository = _preferredRepositorySelection(repos);
      state = state.copyWith(
        connectStatus: GitHubConnectStatus.connected,
        repositories: repos,
        selectedRepositoryFullName: preferredRepository,
        statusMessage: repos.isEmpty
            ? 'GitHub connected. No repositories found.'
            : 'GitHub connected. Pick a repository to deploy.',
      );
      _trackOAuthStage(GitHubOAuthStage.completed);
    } catch (error) {
      await ref.read(gitHubSecretRepositoryProvider).clearAuthToken();
      _pendingOauthState = null;
      await preferences.setGitHubPendingOauthState(null);
      _trackOAuthStage(GitHubOAuthStage.failed);
      state = state.copyWith(
        connectStatus: GitHubConnectStatus.error,
        statusMessage: formatGitHubAuthError(error),
      );
    }
  }

  // end coverage-gate

  void selectRepository(String? repositoryFullName, {String? projectId}) {
    final normalizedRepository = repositoryFullName?.trim();
    final scopedProjectId =
        trimOrNull(projectId) ?? ref.read(selectedProjectProvider)?.id.trim();
    final repositoryByProject = Map<String, String>.from(
      state.selectedRepositoryFullNameByProjectId,
    );
    final deployRunning = _deployIsRunning(state.deployStatus);
    if (normalizedRepository == null || normalizedRepository.isEmpty) {
      if (scopedProjectId != null && scopedProjectId.isNotEmpty) {
        final scopedState = _projectDeployState(scopedProjectId).copyWith(
          clearSelectedRepositoryFullName: true,
          deployStatus: deployRunning ? null : GitHubDeployStatus.idle,
          deployTimeline: deployRunning ? null : const <String>[],
          clearSuggestedNextStep: !deployRunning,
          statusMessage: state.repositories.isEmpty
              ? 'GitHub connected. No repositories found.'
              : 'GitHub connected. Pick a repository to deploy.',
        );
        _setProjectDeployState(
          projectId: scopedProjectId,
          projectState: scopedState,
          mirrorToActiveDeploy:
              state.activeDeployProjectId == scopedProjectId ||
              ref.read(selectedProjectProvider)?.id == scopedProjectId,
        );
        return;
      }
      final connectedMessage = state.repositories.isEmpty
          ? 'GitHub connected. No repositories found.'
          : 'GitHub connected. Pick a repository to deploy.';
      state = state.copyWith(
        clearSelectedRepository: true,
        selectedRepositoryFullNameByProjectId: repositoryByProject,
        statusMessage: state.isConnected
            ? connectedMessage
            : 'Connect GitHub to pick a repository.',
        deployStatus: deployRunning ? null : GitHubDeployStatus.idle,
        deployTimeline: deployRunning ? null : const [],
        clearSuggestedNextStep: !deployRunning,
      );
      return;
    }

    if (scopedProjectId != null && scopedProjectId.isNotEmpty) {
      final scopedState = _projectDeployState(scopedProjectId).copyWith(
        selectedRepositoryFullName: normalizedRepository,
        statusMessage: 'Repository selected: $normalizedRepository',
        deployStatus: deployRunning ? null : GitHubDeployStatus.idle,
        deployTimeline: deployRunning ? null : const <String>[],
        clearSuggestedNextStep: !deployRunning,
      );
      _setProjectDeployState(
        projectId: scopedProjectId,
        projectState: scopedState,
        mirrorToActiveDeploy:
            state.activeDeployProjectId == scopedProjectId ||
            ref.read(selectedProjectProvider)?.id == scopedProjectId,
      );
      return;
    }
    state = state.copyWith(
      selectedRepositoryFullName: normalizedRepository,
      selectedRepositoryFullNameByProjectId: repositoryByProject,
      statusMessage: 'Repository selected: $normalizedRepository',
      deployStatus: deployRunning ? null : GitHubDeployStatus.idle,
      deployTimeline: deployRunning ? null : const [],
      clearSuggestedNextStep: !deployRunning,
    );
  }

  Future<List<String>> listRepositoryBranches(String repositoryFullName) async {
    final normalizedRepository = repositoryFullName.trim();
    if (normalizedRepository.isEmpty) {
      return const [];
    }
    final token =
        state.authToken ??
        await ref.read(gitHubSecretRepositoryProvider).readAuthToken();
    if (token == null || token.trim().isEmpty) {
      throw StateError('GitHub is not connected. Reconnect GitHub first.');
    }
    return ref
        .read(gitHubAuthGatewayProvider)
        .fetchBranches(
          accessToken: token,
          repositoryFullName: normalizedRepository,
        );
  }

  void cancelRepositoryHostKeyConfirmation(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }
    _pendingRepositoryHostKeyRetryByProject.remove(normalizedProjectId);
    _acceptedRepositoryHostKeyPromptIdByProject.remove(normalizedProjectId);
    final current = _projectDeployState(normalizedProjectId);
    _setProjectDeployState(
      projectId: normalizedProjectId,
      mirrorToActiveDeploy: state.activeDeployProjectId == normalizedProjectId,
      projectState: current.copyWith(
        deployStatus: GitHubDeployStatus.error,
        statusMessage:
            'Deployment paused because the GitHub SSH identity was not trusted.',
        clearActiveRunId: true,
        clearActiveRepositoryFullName: true,
        clearActiveServerId: true,
        clearActiveBranch: true,
        clearActivePrimaryDomain: true,
        clearStartedAt: true,
        clearRepositoryHostKeyConfirmation: true,
        clearSuggestedNextStep: true,
      ),
    );
  }

  Future<void> trustRepositoryHostKeyAndRetry(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }
    final current = _projectDeployState(normalizedProjectId);
    final confirmation = current.repositoryHostKeyConfirmation;
    final pending =
        _pendingRepositoryHostKeyRetryByProject[normalizedProjectId];
    if (confirmation == null || pending == null) {
      _setProjectDeployState(
        projectId: normalizedProjectId,
        mirrorToActiveDeploy:
            state.activeDeployProjectId == normalizedProjectId,
        projectState: current.copyWith(
          deployStatus: GitHubDeployStatus.error,
          statusMessage:
              'Deployment could not retry because the previous deploy details are no longer available.',
          clearRepositoryHostKeyConfirmation: true,
          clearSuggestedNextStep: true,
        ),
      );
      return;
    }
    _pendingRepositoryHostKeyRetryByProject.remove(normalizedProjectId);
    _acceptedRepositoryHostKeyPromptIdByProject[normalizedProjectId] =
        confirmation.promptId;
    _setProjectDeployState(
      projectId: normalizedProjectId,
      mirrorToActiveDeploy: state.activeDeployProjectId == normalizedProjectId,
      projectState: current.copyWith(
        deployStatus: GitHubDeployStatus.cloningRepository,
        statusMessage: 'GitHub SSH identity trusted. Retrying deployment...',
        clearRepositoryHostKeyConfirmation: true,
        clearSuggestedNextStep: true,
      ),
    );
    await deploySelectedRepository(
      primaryDomain: pending.primaryDomain,
      branch: pending.branch,
      appPort: pending.appPort,
      repositoryFullName: pending.repositoryFullName,
      domainRoutingMode: pending.domainRoutingMode,
      railpackBuildCommand: pending.railpackBuildCommand,
      railpackRunCommand: pending.railpackRunCommand,
      railpackProvider: pending.railpackProvider,
      appSubdirectory: pending.appSubdirectory,
      repositoryHostKeyPolicy: confirmation.trustPolicy,
      acceptedRepositoryHostKeyFingerprint: confirmation.scannedFingerprint,
      selectedServerOverride: pending.selectedServer,
      selectedProjectOverride: pending.selectedProject,
      actorLabel: pending.actorLabel,
      onTaskStarted: pending.onTaskStarted,
    );
  }

  // coverage-gate: deploy_selected_repository
  Future<void> deploySelectedRepository({
    required String primaryDomain,
    required String branch,
    required int appPort,
    String? repositoryFullName,
    String? domainRoutingMode,
    String? railpackBuildCommand,
    String? railpackRunCommand,
    String? railpackProvider,
    String? appSubdirectory,
    String? repositoryHostKeyPolicy,
    String? acceptedRepositoryHostKeyFingerprint,
    Server? selectedServerOverride,
    Project? selectedProjectOverride,
    String? actorLabel,
    void Function(int taskId, String phase)? onTaskStarted,
  }) async {
    final token =
        state.authToken ??
        await ref.read(gitHubSecretRepositoryProvider).readAuthToken();
    final selectedServer =
        selectedServerOverride ?? ref.read(selectedServerProvider);
    final selectedProject =
        selectedProjectOverride ?? ref.read(selectedProjectProvider);
    final normalizedRepository = repositoryFullName?.trim();
    final selectedRepo =
        normalizedRepository == null || normalizedRepository.isEmpty
        ? state.selectedRepositoryForProject(selectedProject?.id)
        : normalizedRepository;

    void failBeforeRun(String message) {
      if (selectedProject != null) {
        _setProjectDeployState(
          projectId: selectedProject.id,
          mirrorToActiveDeploy: false,
          projectState: _projectDeployState(selectedProject.id).copyWith(
            selectedRepositoryFullName: selectedRepo,
            deployStatus: GitHubDeployStatus.error,
            statusMessage: message,
            deployTimeline: const <String>[],
            clearActiveRunId: true,
            clearActiveRepositoryFullName: true,
            clearActiveServerId: true,
            clearActiveBranch: true,
            clearActivePrimaryDomain: true,
            clearStartedAt: true,
            clearRepositoryHostKeyConfirmation: true,
            clearFailureEvidence: true,
            clearSuggestedNextStep: true,
          ),
        );
      }
      state = state.copyWith(
        deployStatus: GitHubDeployStatus.error,
        statusMessage: message,
        clearFailureEvidence: true,
        clearSuggestedNextStep: true,
      );
    }

    if (normalizedRepository != null && normalizedRepository.isNotEmpty) {
      final repositoryByProject = Map<String, String>.from(
        state.selectedRepositoryFullNameByProjectId,
      );
      if (selectedProject != null) {
        repositoryByProject[selectedProject.id] = normalizedRepository;
      }
      state = state.copyWith(
        selectedRepositoryFullName: normalizedRepository,
        selectedRepositoryFullNameByProjectId: repositoryByProject,
      );
    }
    // A press is the invocation itself, so it reports before validation:
    // taps that validation rejects still name user intent. Agent redeploys
    // (3.6c owns those via `trackAgentRedeploy`) and the internal host-key
    // trust retry (a continuation carrying its policy, not a fresh tap) are
    // not presses.
    if (actorLabel != 'agent-mcp' && repositoryHostKeyPolicy == null) {
      ref
          .read(appAnalyticsServiceProvider)
          .trackControlUsed(control: AppControl.deployPressed);
    }
    if (selectedRepo == null || token == null) {
      failBeforeRun('Connect GitHub and select a repository before deploying.');
      return;
    }
    if (!_isValidDomain(primaryDomain)) {
      failBeforeRun(
        'Primary domain is required and must be a valid FQDN before deploy.',
      );
      return;
    }
    if (!_isValidBranch(branch)) {
      failBeforeRun('Branch name is invalid.');
      return;
    }
    if (appPort < 1 || appPort > 65535) {
      failBeforeRun('Web app port must be between 1 and 65535.');
      return;
    }
    if (selectedServer == null) {
      failBeforeRun('No active server selected for deploy.');
      return;
    }
    if (selectedProject == null) {
      failBeforeRun('No project selected for deploy.');
      return;
    }

    final connection = await _buildConnectionPayload(selectedServer);
    if (connection == null) {
      failBeforeRun(
        'Selected server credentials are incomplete. Reconnect server first.',
      );
      return;
    }
    final normalizedBuildCommand = railpackBuildCommand?.trim();
    final normalizedRunCommand = railpackRunCommand?.trim();
    final normalizedProvider = normalizeRailpackProvider(
      railpackProvider ?? selectedProject.railpackProvider,
    );
    final effectiveBuildCommand =
        normalizedBuildCommand == null || normalizedBuildCommand.isEmpty
        ? selectedProject.effectiveBuildCommand
        : normalizedBuildCommand;
    final effectiveRunCommand =
        normalizedRunCommand == null || normalizedRunCommand.isEmpty
        ? selectedProject.railpackRunCommand
        : normalizedRunCommand;
    final includeBuildCommand = effectiveBuildCommand.isNotEmpty;
    final includeRunCommand = effectiveRunCommand.isNotEmpty;
    final effectiveAppSubdirectory = _normalizeAppSubdirectory(
      appSubdirectory ?? selectedProject.appSubdirectory,
    );
    if (effectiveAppSubdirectory == _invalidAppSubdirectory) {
      failBeforeRun(
        'App subdirectory is invalid. Use a relative path like "website".',
      );
      return;
    }

    final effectiveDomainRoutingMode =
        domainRoutingMode == null || domainRoutingMode.trim().isEmpty
        ? selectedProject.domainRoutingMode
        : domainRoutingMode.trim().toLowerCase();
    final deploymentStartedAt = DateTime.now();
    final runContext = _GitHubDeployRunContext(
      run: WorkspaceRunContext(
        scope: WorkspaceScope(
          projectId: selectedProject.id,
          serverId: selectedServer.id,
        ),
        epoch: deploymentStartedAt.microsecondsSinceEpoch,
        runId:
            '${selectedProject.id}-${deploymentStartedAt.microsecondsSinceEpoch}',
        metadata: <String, Object?>{
          'repositoryFullName': selectedRepo,
          'branch': branch,
          'primaryDomain': primaryDomain,
        },
      ),
      repositoryFullName: selectedRepo,
      branch: branch,
      primaryDomain: primaryDomain,
      startedAt: deploymentStartedAt,
    );
    var deployTimeline = <String>[];
    void updateRunState({
      GitHubDeployStatus? deployStatus,
      String? statusMessage,
      List<String>? deployTimelineOverride,
      GitHubRepositoryHostKeyConfirmation? repositoryHostKeyConfirmation,
      String? processReadinessStatus,
      AppPublicHealthSnapshot? publicHealth,
      DeployFailureEvidence? failureEvidence,
      String? suggestedNextStep,
      bool clearFailureEvidence = false,
      bool clearSuggestedNextStep = false,
      bool clearActiveRun = false,
    }) {
      if (!_isCurrentDeployRun(runContext)) {
        return;
      }
      if (deployTimelineOverride != null) {
        deployTimeline = List<String>.from(deployTimelineOverride);
      }
      final current = _projectDeployState(selectedProject.id);
      _setProjectDeployState(
        projectId: selectedProject.id,
        mirrorToActiveDeploy: true,
        projectState: current.copyWith(
          selectedRepositoryFullName: selectedRepo,
          deployStatus: deployStatus,
          statusMessage: statusMessage,
          deployTimeline: deployTimeline,
          activeRunId: clearActiveRun ? null : runContext.runId,
          activeRepositoryFullName: clearActiveRun ? null : selectedRepo,
          activeServerId: clearActiveRun ? null : selectedServer.id,
          activeBranch: clearActiveRun ? null : branch,
          activePrimaryDomain: clearActiveRun ? null : primaryDomain,
          startedAt: clearActiveRun ? null : deploymentStartedAt,
          repositoryHostKeyConfirmation: repositoryHostKeyConfirmation,
          processReadinessStatus: processReadinessStatus,
          publicHealth: publicHealth,
          failureEvidence: failureEvidence,
          suggestedNextStep: suggestedNextStep,
          clearFailureEvidence: clearFailureEvidence,
          clearSuggestedNextStep: clearSuggestedNextStep,
          clearActiveRunId: clearActiveRun,
          clearActiveRepositoryFullName: clearActiveRun,
          clearActiveServerId: clearActiveRun,
          clearActiveBranch: clearActiveRun,
          clearActivePrimaryDomain: clearActiveRun,
          clearStartedAt: clearActiveRun,
          clearRepositoryHostKeyConfirmation:
              clearActiveRun && repositoryHostKeyConfirmation == null,
        ),
      );
    }

    void appendRunTimeline(String message, {String eventType = ''}) {
      if (!_isCurrentDeployRun(runContext)) {
        return;
      }
      if (!shouldAppendDeployTimelineLine(
        deployTimeline,
        message,
        eventType: eventType,
      )) {
        return;
      }
      deployTimeline = [...deployTimeline, message.trim()];
      updateRunState(deployTimelineOverride: deployTimeline);
    }

    state = state.copyWith(
      activeDeployProjectId: selectedProject.id,
      activeDeployRepositoryFullName: selectedRepo,
    );
    if (repositoryHostKeyPolicy == null) {
      _acceptedRepositoryHostKeyPromptIdByProject.remove(selectedProject.id);
    }
    _setProjectDeployState(
      projectId: selectedProject.id,
      mirrorToActiveDeploy: true,
      projectState: _projectDeployState(selectedProject.id).copyWith(
        selectedRepositoryFullName: selectedRepo,
        deployStatus: GitHubDeployStatus.generatingServerKey,
        statusMessage: 'Starting deployment...',
        deployTimeline: const <String>[],
        activeRunId: runContext.runId,
        activeRepositoryFullName: selectedRepo,
        activeServerId: selectedServer.id,
        activeBranch: branch,
        activePrimaryDomain: primaryDomain,
        startedAt: deploymentStartedAt,
        clearRepositoryHostKeyConfirmation: true,
        clearFailureEvidence: true,
        clearSuggestedNextStep: true,
      ),
    );
    var outcomePersisted = false;

    // Reports one deploy resolution. Single seam so the six outcome sites
    // funnelled through [persistDeployOutcome] cannot drift onto different
    // providers or method spellings; success also records the first-deploy
    // activation attribute alongside the event.
    // Persists the first-deploy milestone so Home can offer the once-ever
    // telemetry nag. Best-effort: a timestamp write must never fail a
    // deploy that already succeeded.
    Future<void> recordFirstDeployMilestone() async {
      try {
        await ref
            .read(appPreferencesRepositoryProvider)
            .recordAnalyticsMilestone(AppUserAttribute.hasFirstDeploySucceeded);
        await ref.read(telemetrySettingsProvider.notifier).refresh();
      } on Exception catch (error) {
        if (kDebugMode) {
          debugPrint(
            'First-deploy milestone skipped; the deploy stands: $error',
          );
        }
      } on StateError catch (error) {
        if (kDebugMode) {
          debugPrint(
            'First-deploy milestone skipped; the deploy stands: $error',
          );
        }
      }
    }

    // coverage-gate: deploy_failure_analytics
    void trackDeployResolution(
      bool success, {
      Map<String, dynamic>? deployResult,
      required int durationSeconds,
    }) {
      final analytics = ref.read(appAnalyticsServiceProvider);
      analytics.trackDeployEvent(
        provider: deployProviderForName(normalizedProvider),
        routingMode: effectiveDomainRoutingMode,
        stage: deployStageForResult(
          success: success,
          deployResult: deployResult,
        ),
        outcome: deployOutcomeForResult(
          success: success,
          deployResult: deployResult,
        ),
        durationSeconds: durationSeconds,
      );
      if (success) {
        analytics.setUserAttribute(
          AppUserAttribute.hasFirstDeploySucceeded,
          'true',
        );
      } else {
        final evidence = deployResult == null
            ? null
            : DeployFailureEvidence.fromEnvelope(deployResult);
        analytics.trackDeployFailureEvidence(
          phase: evidence?.phase ?? DeployFailurePhase.unknown,
          source: evidence?.source ?? DeployFailureSource.none,
          completeness:
              evidence?.completeness ?? DeployFailureCompleteness.unavailable,
          lineCount: evidence?.lines.length ?? 0,
          agentInitiated: actorLabel == 'agent-mcp',
        );
      }
    }
    // end coverage-gate

    Future<void> persistDeployOutcome(
      bool success, {
      Map<String, dynamic>? deployResult,
    }) async {
      if (outcomePersisted || !_isCurrentDeployRun(runContext)) {
        return;
      }
      outcomePersisted = true;

      final completedAt = DateTime.now();
      final duration = completedAt.difference(deploymentStartedAt);
      trackDeployResolution(
        success,
        deployResult: deployResult,
        durationSeconds: duration.inSeconds,
      );
      if (success) {
        await recordFirstDeployMilestone();
      }
      // `trimOrNull` is the repository's one owner for "trim it, and treat
      // blank as absent", which is exactly what each of these asked for in
      // six lines apiece.
      final resolvedCommit =
          trimOrNull(deployResult?['commit_sha']?.toString()) ??
          extractCommitHashFromTimeline(deployTimeline) ??
          'unknown';
      final resolvedReleaseId = trimOrNull(
        deployResult?['release_id']?.toString(),
      );
      final resolvedDeploymentKind =
          trimOrNull(deployResult?['deployment_kind']?.toString()) ?? 'deploy';
      final resolvedRollbackFromReleaseId = trimOrNull(
        deployResult?['rollback_from_release_id']?.toString(),
      );
      final resolvedActor = trimOrNull(actorLabel) ?? localDeployActor();

      if (deployResult != null) {
        await _persistDeployReleaseResult(
          projectId: selectedProject.id,
          serverId: selectedServer.id,
          deployResult: deployResult,
        );
      }

      if (success) {
        final processReadiness = deployResult?['process_readiness'];
        final processStatus = processReadiness is Map
            ? processReadiness['status']?.toString().trim()
            : null;
        final publicHealthPayload = deployResult?['public_health'];
        final publicHealth = AppPublicHealthSnapshot.fromPayload(
          publicHealthPayload is Map ? publicHealthPayload : null,
        );
        ref
            .read(projectListProvider.notifier)
            .updateLastDeployState(
              projectId: selectedProject.id,
              commit: resolvedCommit,
              deployedAt: completedAt,
            );
        await ref
            .read(appReleaseProvider.notifier)
            .upsertRuntimeSnapshot(
              AppRuntimeSnapshotRecord(
                projectId: selectedProject.id,
                serverId: selectedServer.id,
                healthStatus: processStatus == 'ready' ? 'ready' : 'unknown',
                publicHealthJson: publicHealth.encode(),
                healthCheckedAt: completedAt.toUtc(),
                updatedAt: completedAt.toUtc(),
              ),
            );
      }

      try {
        await ref
            .read(appDeploymentHistoryRepositoryProvider)
            .append(
              projectId: selectedProject.id,
              status: success ? 'success' : 'failed',
              releaseId: resolvedReleaseId,
              deploymentKind: resolvedDeploymentKind,
              rollbackFromReleaseId: resolvedRollbackFromReleaseId,
              deployedAt: completedAt,
              durationSeconds: duration.inSeconds,
              actor: resolvedActor,
              branch: branch,
              commit: resolvedCommit,
            );
        if (!success &&
            deployResult?['rollback_status'] == 'reverted_to_previous_live') {
          final fallbackReleaseId = deployResult?['rollback_from_release_id']
              ?.toString()
              .trim();
          await ref
              .read(appDeploymentHistoryRepositoryProvider)
              .append(
                projectId: selectedProject.id,
                status: 'success',
                releaseId: fallbackReleaseId,
                deploymentKind: 'auto_fallback',
                rollbackFromReleaseId: resolvedReleaseId,
                deployedAt: completedAt,
                durationSeconds: duration.inSeconds,
                actor: resolvedActor,
                branch: branch,
                commit: resolvedCommit,
              );
        }
      } on StateError {
        // Deployment history is supplementary local audit data; a disposed
        // repository must not change the completed deployment result.
      }
      if (success) {
        await _refreshDeploysPerWeekBucket();
      }
    }

    ref
        .read(projectListProvider.notifier)
        .updateDeploymentConfig(
          projectId: selectedProject.id,
          primaryDomain: primaryDomain,
          domainRoutingMode: effectiveDomainRoutingMode,
          repositoryFullName: selectedRepo,
          appSubdirectory: effectiveAppSubdirectory,
          deployBranch: branch,
          appPort: appPort,
          publicHealthCheckEnabled: selectedProject.publicHealthCheckEnabled,
          publicHealthCheckPath: selectedProject.publicHealthCheckPath,
          railpackNodeMode: 'auto',
          railpackProvider: normalizedProvider,
          tlsChallengeMode: selectedProject.tlsChallengeMode,
          tlsDnsProvider: selectedProject.tlsDnsProvider,
          tlsDnsCredentials: selectedProject.tlsDnsCredentials,
          sqliteStorageEnabled: selectedProject.sqliteStorageEnabled,
          sqliteVolumeName: selectedProject.sqliteVolumeName,
          sqliteMountPath: selectedProject.sqliteMountPath,
          sqliteFileName: selectedProject.sqliteFileName,
          railpackBuildCommand: effectiveBuildCommand,
          railpackRunCommand: effectiveRunCommand,
        );

    final delay = ref.read(gitHubInteractionStepDelayProvider);
    final gateway = ref.read(gitHubAuthGatewayProvider);
    final secretRepo = ref.read(gitHubSecretRepositoryProvider);
    final sshService = ref.read(sshServiceProvider);
    final projectSlug = slugifyProjectName(
      selectedProject.name,
      fallback: 'project-app',
    );
    ProjectSqliteDatabase? primarySqliteDatabase;
    try {
      primarySqliteDatabase = await ref
          .read(projectSqliteDatabaseRepositoryProvider)
          .readPrimaryForProject(selectedProject.id);
    } on StateError {
      // SQLite storage is optional for a deployment. A database that closes
      // during this lookup falls back to the project's saved storage settings.
    }
    final sqliteStorageEnabled =
        primarySqliteDatabase != null || selectedProject.sqliteStorageEnabled;
    final sqliteVolumeName =
        primarySqliteDatabase?.volumeName ??
        trimOrNull(selectedProject.sqliteVolumeName) ??
        'deploydash_sqlite_$projectSlug';
    final sqliteMountPath =
        primarySqliteDatabase?.mountPath ??
        trimOrNull(selectedProject.sqliteMountPath) ??
        '/var/lib/deploydash/sqlite';
    final sqliteFileName =
        primarySqliteDatabase?.fileName ??
        trimOrNull(selectedProject.sqliteFileName) ??
        'app.sqlite3';
    final baseSettings = <String, dynamic>{
      'project_slug': projectSlug,
      'repository_full_name': selectedRepo,
      'branch': branch,
      'primary_domain': primaryDomain,
      'domain_routing_mode': effectiveDomainRoutingMode,
      'app_port': appPort,
      'public_health_check_enabled': selectedProject.publicHealthCheckEnabled,
      'public_health_check_path': selectedProject.publicHealthCheckPath,
      'railpack_node_mode': 'auto',
      ...?switch (normalizedProvider) {
        final String provider => <String, dynamic>{
          'railpack_provider': provider,
        },
        null => null,
      },
      if (includeBuildCommand) 'railpack_build_cmd': effectiveBuildCommand,
      if (includeRunCommand) 'railpack_start_cmd': effectiveRunCommand,
      'tls_challenge_mode': selectedProject.tlsChallengeMode,
      if (selectedProject.tlsChallengeMode == 'dns' &&
          selectedProject.tlsDnsProvider != null)
        'tls_dns_provider': selectedProject.tlsDnsProvider,
      if (selectedProject.tlsChallengeMode == 'dns' &&
          selectedProject.tlsDnsCredentials.isNotEmpty)
        'tls_dns_credentials': selectedProject.tlsDnsCredentials,
      if (sqliteStorageEnabled)
        'sqlite_storage': <String, dynamic>{
          'enabled': true,
          'volume_name': sqliteVolumeName,
          'mount_path': sqliteMountPath,
          'file_name': sqliteFileName,
        },
    };
    final trustNetworkNames = await ref
        .read(projectNetworkTrustRepositoryProvider)
        .listTrustNetworkNamesForProject(selectedProject.id);
    if (trustNetworkNames.isNotEmpty) {
      baseSettings['trust_network_names'] = trustNetworkNames;
    }
    final sqliteSnapshotMounts = await ref
        .read(projectSqliteSnapshotRepositoryProvider)
        .buildSnapshotMountPayloadsForConsumer(selectedProject.id);
    if (sqliteSnapshotMounts.isNotEmpty) {
      baseSettings['sqlite_snapshot_mounts'] = sqliteSnapshotMounts;
    }
    final runtimeEnv = <String, String>{};
    try {
      final envRows = await ref
          .read(appEnvironmentVariableRepositoryProvider)
          .listForProject(selectedProject.id);
      for (final row in envRows) {
        final key = row.key.trim();
        if (key.isEmpty) {
          continue;
        }
        runtimeEnv[key] = row.value;
      }
    } on StateError {
      // Environment rows are optional local input. A closed repository must
      // not block a deploy whose explicit settings remain valid.
    }
    if (runtimeEnv.isNotEmpty) {
      baseSettings['runtime_env'] = runtimeEnv;
    }
    if (effectiveAppSubdirectory != null) {
      baseSettings['app_subdirectory'] = effectiveAppSubdirectory;
    }

    try {
      Future<({String publicKey, String privateKey, bool reusedStoredKey})>
      acquireDeployKey({required bool forceFreshKey}) async {
        if (!forceFreshKey) {
          final storedKey = await secretRepo.readDeployKey(selectedRepo);
          if (storedKey != null) {
            deployTimeline = const ['Reuse locally stored deploy key'];
            updateRunState(
              deployStatus: GitHubDeployStatus.generatingServerKey,
              statusMessage: 'Using stored deploy key...',
              deployTimelineOverride: deployTimeline,
            );
            appendRunTimeline(
              'Using existing local deploy key for $selectedRepo',
            );
            return (
              publicKey: storedKey.publicKey,
              privateKey: storedKey.privateKey,
              reusedStoredKey: true,
            );
          }
        }

        deployTimeline = forceFreshKey
            ? [...deployTimeline, 'Generate fresh deploy key on server']
            : const ['Generate SSH deploy key on server'];
        updateRunState(
          deployStatus: GitHubDeployStatus.generatingServerKey,
          statusMessage: 'Generating deploy key on server...',
          deployTimelineOverride: deployTimeline,
        );

        final prepareOutcome = await sshService.runWorkflow(
          workflowId: 'app',
          operationId: 'prepare_key',
          connection: connection,
          params: {'dry_run': false, 'settings': baseSettings},
          onTaskStarted: (taskId) => onTaskStarted?.call(taskId, 'prepare_key'),
          onEvent: (event) {
            final type = event['type']?.toString().trim() ?? '';
            final message = event['message']?.toString().trim();
            if (message == null || message.isEmpty) {
              return;
            }
            appendRunTimeline(message, eventType: type);
          },
        );
        final prepareEvidence = _deployFailureEvidenceFromResult(
          prepareOutcome,
        );
        final prepareResult = prepareOutcome.diagnosticPayload;
        if (!_isCurrentDeployRun(runContext)) {
          throw _AbortDeploymentException();
        }
        if (prepareResult['status'] != 'success') {
          await persistDeployOutcome(false, deployResult: prepareResult);
          updateRunState(
            deployStatus: GitHubDeployStatus.error,
            statusMessage:
                prepareResult['msg']?.toString() ??
                'Failed preparing deploy key on server.',
            failureEvidence: prepareEvidence,
            clearFailureEvidence: prepareEvidence == null,
            clearSuggestedNextStep: true,
            clearActiveRun: true,
          );
          throw _AbortDeploymentException();
        }

        final preparedPublicKey = prepareResult['deploy_public_key']
            ?.toString();
        final preparedPrivateKey = prepareResult['deploy_private_key']
            ?.toString();
        if (preparedPublicKey == null ||
            preparedPublicKey.trim().isEmpty ||
            preparedPrivateKey == null ||
            preparedPrivateKey.trim().isEmpty) {
          await persistDeployOutcome(false);
          updateRunState(
            deployStatus: GitHubDeployStatus.error,
            statusMessage:
                'Server deploy key prepared, but key material was incomplete.',
            clearFailureEvidence: true,
            clearSuggestedNextStep: true,
            clearActiveRun: true,
          );
          throw _AbortDeploymentException();
        }

        final deployPublicKey = preparedPublicKey.trim();
        final deployPrivateKey = preparedPrivateKey.trim();
        await secretRepo.saveDeployKey(
          repositoryFullName: selectedRepo,
          publicKey: deployPublicKey,
          privateKey: deployPrivateKey,
        );

        appendRunTimeline(
          'Copied deploy key to local secure store and wiped it from server',
        );
        return (
          publicKey: deployPublicKey,
          privateKey: deployPrivateKey,
          reusedStoredKey: false,
        );
      }

      Future<void> registerDeployKey(String publicKey) async {
        deployTimeline = [
          ...deployTimeline,
          'Register local public key as GitHub Deploy Key (read-only)',
        ];
        updateRunState(
          deployStatus: GitHubDeployStatus.registeringDeployKey,
          statusMessage: 'Registering deploy key with GitHub...',
          deployTimelineOverride: deployTimeline,
        );

        await gateway.registerDeployKey(
          accessToken: token,
          repositoryFullName: selectedRepo,
          publicKey: publicKey,
        );
        await Future<void>.delayed(delay);
        if (!_isCurrentDeployRun(runContext)) {
          throw _AbortDeploymentException();
        }
      }

      late ProjectManagedOperationJournalRecord latestDeployJournal;
      DeployFailureEvidence? latestDeployFailureEvidence;

      Future<Map<String, dynamic>> runDeploymentWithKey(
        String privateKey,
      ) async {
        deployTimeline = [
          ...deployTimeline,
          'Clone $selectedRepo using runtime-injected deploy key',
        ];
        updateRunState(
          deployStatus: GitHubDeployStatus.cloningRepository,
          statusMessage: 'Cloning repository on server...',
          deployTimelineOverride: deployTimeline,
        );
        deployTimeline = [
          ...deployTimeline,
          if (runtimeEnv.isNotEmpty)
            'Apply ${runtimeEnv.length} app runtime env vars to container',
          'Build image and publish through Caddy',
        ];
        updateRunState(
          deployStatus: GitHubDeployStatus.buildingRelease,
          statusMessage: 'Running web app build and deployment on server...',
          deployTimelineOverride: deployTimeline,
        );
        final deploymentSettings = <String, dynamic>{
          ...baseSettings,
          'deploy_private_key': privateKey,
          ...?(repositoryHostKeyPolicy == null
              ? null
              : {'repository_host_key_policy': repositoryHostKeyPolicy}),
          ...?(acceptedRepositoryHostKeyFingerprint == null
              ? null
              : {
                  'accepted_repository_host_key_fingerprint':
                      acceptedRepositoryHostKeyFingerprint,
                }),
        };
        final journalRepository = ref.read(appReleaseRepositoryProvider);
        final journal = await journalRepository.createJournalEntry(
          projectId: selectedProject.id,
          serverId: selectedServer.id,
          surface: 'app',
          operationType: 'run',
          request: <String, dynamic>{
            'workflow_id': 'app',
            'operation_id': 'run',
            'repository': selectedRepo,
            'branch': branch,
            'app_port': appPort,
            'domain_routing_mode': effectiveDomainRoutingMode,
            'railpack_provider': normalizedProvider,
            'runtime_env_count': runtimeEnv.length,
          },
        );
        latestDeployJournal = journal;
        Map<String, dynamic> result;
        try {
          final outcome = await sshService.runWorkflow(
            workflowId: 'app',
            operationId: 'run',
            connection: connection,
            params: {'dry_run': false, 'settings': deploymentSettings},
            onTaskStarted: (taskId) => onTaskStarted?.call(taskId, 'run'),
            onEvent: (event) {
              final type = event['type']?.toString().trim() ?? '';
              final message = event['message']?.toString().trim();
              if (message == null || message.isEmpty) {
                return;
              }
              appendRunTimeline(message, eventType: type);
            },
          );
          latestDeployFailureEvidence = _deployFailureEvidenceFromResult(
            outcome,
          );
          result = outcome.diagnosticPayload;
        } catch (error) {
          latestDeployFailureEvidence = null;
          await journalRepository.updateJournalStatus(
            id: journal.id,
            status: 'failed',
            errorMessage: error.toString(),
          );
          rethrow;
        }
        if (result['status'] == 'success') {
          await journalRepository.updateJournalStatus(
            id: journal.id,
            status: 'remote_success',
            result: result,
          );
        } else {
          await journalRepository.updateJournalStatus(
            id: journal.id,
            status: 'failed',
            result: result,
            errorMessage: result['msg']?.toString(),
          );
        }
        if (!_isCurrentDeployRun(runContext)) {
          throw _AbortDeploymentException();
        }
        return result;
      }

      var keyMaterial = await acquireDeployKey(forceFreshKey: false);
      await registerDeployKey(keyMaterial.publicKey);
      var attemptTimelineStartIndex = deployTimeline.length;
      var deployResult = await runDeploymentWithKey(keyMaterial.privateKey);
      var failureMessage = _deploymentFailureMessage(deployResult);
      var attemptTimeline = deployTimeline.sublist(attemptTimelineStartIndex);

      // coverage-gate: repository_key_rotation_retry
      if (failureMessage != null &&
          keyMaterial.reusedStoredKey &&
          isRepositoryCloneAccessFailure(
            failureMessage: failureMessage,
            timeline: attemptTimeline,
            failureEvidence: latestDeployFailureEvidence,
          )) {
        appendRunTimeline(
          'Stored deploy key could not access repository; rotating key and retrying once',
        );
        await secretRepo.deleteDeployKey(selectedRepo);
        keyMaterial = await acquireDeployKey(forceFreshKey: true);
        await registerDeployKey(keyMaterial.publicKey);
        attemptTimelineStartIndex = deployTimeline.length;
        deployResult = await runDeploymentWithKey(keyMaterial.privateKey);
        failureMessage = _deploymentFailureMessage(deployResult);
        attemptTimeline = deployTimeline.sublist(attemptTimelineStartIndex);
      }
      // end coverage-gate

      if (failureMessage != null) {
        final hostKeyConfirmation =
            GitHubRepositoryHostKeyConfirmation.fromPayload(
              deployResult['repository_host_key_confirmation'],
            );
        if (deployResult['repository_host_key_confirmation_required'] == true &&
            hostKeyConfirmation != null) {
          final acceptedPromptId =
              _acceptedRepositoryHostKeyPromptIdByProject[selectedProject.id];
          if (acceptedPromptId == hostKeyConfirmation.promptId) {
            _pendingRepositoryHostKeyRetryByProject.remove(selectedProject.id);
            _acceptedRepositoryHostKeyPromptIdByProject.remove(
              selectedProject.id,
            );
            await persistDeployOutcome(false, deployResult: deployResult);
            updateRunState(
              deployStatus: GitHubDeployStatus.error,
              statusMessage:
                  'Deploy Dash still could not save the trusted GitHub SSH identity on the server. Check the deployment log and try again.',
              deployTimelineOverride: [
                ...deployTimeline,
                'GitHub SSH identity was trusted, but the server still asked for the same confirmation.',
              ],
              clearFailureEvidence: true,
              clearSuggestedNextStep: true,
              clearActiveRun: true,
            );
            return;
          }
          _pendingRepositoryHostKeyRetryByProject[selectedProject.id] =
              _PendingRepositoryHostKeyRetry(
                primaryDomain: primaryDomain,
                branch: branch,
                appPort: appPort,
                repositoryFullName: selectedRepo,
                domainRoutingMode: effectiveDomainRoutingMode,
                railpackBuildCommand: effectiveBuildCommand,
                railpackRunCommand: effectiveRunCommand,
                railpackProvider: normalizedProvider,
                appSubdirectory: effectiveAppSubdirectory,
                selectedServer: selectedServer,
                selectedProject: selectedProject,
                actorLabel: actorLabel,
                onTaskStarted: onTaskStarted,
              );
          updateRunState(
            deployStatus:
                GitHubDeployStatus.awaitingRepositoryHostKeyConfirmation,
            statusMessage:
                'Confirm the GitHub SSH identity before Deploy Dash fetches this repository.',
            deployTimelineOverride: [
              ...deployTimeline,
              'GitHub SSH identity needs confirmation before retrying.',
            ],
            repositoryHostKeyConfirmation: hostKeyConfirmation,
            clearFailureEvidence: true,
            clearSuggestedNextStep: true,
            clearActiveRun: true,
          );
          return;
        }
        _acceptedRepositoryHostKeyPromptIdByProject.remove(selectedProject.id);
        // coverage-gate: deploy_failure_advice
        await persistDeployOutcome(false, deployResult: deployResult);
        final subdirectoryHint = hintForMissingRailpackApp(
          failureMessage: failureMessage,
          timeline: attemptTimeline,
          configuredSubdirectory: effectiveAppSubdirectory,
        );
        final buildCommandHint = hintForWrongBuildOutputPath(
          failureMessage: failureMessage,
          timeline: attemptTimeline,
        );
        final domainOwnershipHint = hintForDomainOwnershipConflict(
          failureMessage: failureMessage,
        );
        final repositoryAccessHint = hintForRepositoryAccessFailure(
          failureMessage: failureMessage,
          timeline: attemptTimeline,
          failureEvidence: latestDeployFailureEvidence,
        );
        final hints = <String>[
          ?subdirectoryHint,
          ?buildCommandHint,
          ?domainOwnershipHint,
          ?repositoryAccessHint,
        ];
        final failureEvidence = latestDeployFailureEvidence;
        if (failureEvidence != null) {
          await _persistDeployFailureEvidence(
            projectId: selectedProject.id,
            server: selectedServer,
            evidence: failureEvidence,
            journal: latestDeployJournal,
          );
        } else {
          await _persistLegacyDeployRuntimeLogExcerpt(
            projectId: selectedProject.id,
            server: selectedServer,
            deployResult: deployResult,
          );
        }
        updateRunState(
          deployStatus: GitHubDeployStatus.error,
          statusMessage: failureMessage,
          deployTimelineOverride: deployTimeline,
          failureEvidence: failureEvidence,
          suggestedNextStep: hints.isEmpty ? null : hints.join(' '),
          clearFailureEvidence: failureEvidence == null,
          clearSuggestedNextStep: hints.isEmpty,
          clearActiveRun: true,
        );
        // end coverage-gate
        return;
      }

      deployTimeline = [
        ...deployTimeline,
        'Deployment completed successfully',
        if (deployResult['http_url'] != null)
          'HTTP: ${deployResult['http_url']}',
        if (deployResult['https_url'] != null)
          'HTTPS: ${deployResult['https_url']}',
      ];
      final publicHealthPayload = deployResult['public_health'];
      final publicHealth = AppPublicHealthSnapshot.fromPayload(
        publicHealthPayload is Map ? publicHealthPayload : null,
      );
      final processReadiness = deployResult['process_readiness'];
      final processReadinessStatus = processReadiness is Map
          ? processReadiness['status']?.toString().trim()
          : null;
      _acceptedRepositoryHostKeyPromptIdByProject.remove(selectedProject.id);
      await persistDeployOutcome(true, deployResult: deployResult);
      await ref
          .read(appReleaseRepositoryProvider)
          .updateJournalStatus(
            id: latestDeployJournal.id,
            status: 'committed_local',
            result: deployResult,
          );
      updateRunState(
        deployStatus: GitHubDeployStatus.success,
        statusMessage: publicHealth.needsAttention
            ? 'Deploy completed, but the public URL check failed. Review runtime logs or environment settings.'
            : 'Deploy completed. ${deployResult['https_url'] ?? 'HTTPS URL ready.'} App runtime logs are in the Log screen.',
        processReadinessStatus: processReadinessStatus ?? 'unknown',
        publicHealth: publicHealth,
        deployTimelineOverride: deployTimeline,
        clearFailureEvidence: true,
        clearSuggestedNextStep: true,
        clearActiveRun: true,
      );
    } on _AbortDeploymentException {
      return;
    } catch (error) {
      await persistDeployOutcome(false);
      updateRunState(
        deployStatus: GitHubDeployStatus.error,
        statusMessage: 'Deployment failed: $error',
        clearFailureEvidence: true,
        clearSuggestedNextStep: true,
        clearActiveRun: true,
      );
    }
  }

  /// Refreshes the trailing-week deploy bucket after a successful deploy.
  ///
  /// Called after the history row lands, so the just-finished deploy counts.
  /// Supplementary like the history write itself: any fault skips the
  /// refresh rather than changing the completed deployment result.
  Future<void> _refreshDeploysPerWeekBucket() async {
    try {
      final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 7));
      final count = await ref
          .read(appDeploymentHistoryRepositoryProvider)
          .countSuccessfulDeploysSince(cutoff);
      ref
          .read(appAnalyticsServiceProvider)
          .setUserAttribute(
            AppUserAttribute.deploysPerWeekBucket,
            analyticsBucketForCount(count),
          );
    } on Exception catch (error) {
      // Same contract as the history write above: analytics must not change
      // a completed deployment result.
      if (kDebugMode) {
        debugPrint('Deploys-per-week bucket refresh failed: $error');
      }
    } on StateError catch (error) {
      // Same contract as the history write above: analytics must not change
      // a completed deployment result.
      if (kDebugMode) {
        debugPrint('Deploys-per-week bucket refresh failed: $error');
      }
    }
  }

  static bool _isValidDomain(String value) {
    final candidate = value.trim().toLowerCase();
    if (candidate.isEmpty || candidate == 'not configured') {
      return false;
    }
    final fqdn = RegExp(
      r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$',
    );
    return fqdn.hasMatch(candidate);
  }

  static bool _isValidBranch(String value) {
    final candidate = value.trim();
    if (candidate.isEmpty) {
      return false;
    }
    return RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(candidate);
  }

  static const String _invalidAppSubdirectory = '__invalid__';

  static String? _normalizeAppSubdirectory(String? raw) {
    if (raw == null) {
      return null;
    }
    final normalized = raw
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) {
      return null;
    }
    final parts = normalized.split('/');
    final cleaned = <String>[];
    for (final part in parts) {
      final segment = part.trim();
      if (segment.isEmpty || segment == '.' || segment == '..') {
        return _invalidAppSubdirectory;
      }
      cleaned.add(segment);
    }
    if (cleaned.isEmpty) {
      return null;
    }
    return cleaned.join('/');
  }

  // end coverage-gate
  String? _preferredRepositorySelection(List<GitHubRepository> repos) {
    if (repos.isEmpty) {
      return null;
    }

    final preferredFromProject = ref
        .read(selectedProjectProvider)
        ?.repositoryFullName
        ?.trim();
    if (preferredFromProject != null &&
        preferredFromProject.isNotEmpty &&
        repos.any((repo) => repo.fullName == preferredFromProject)) {
      return preferredFromProject;
    }

    final existingSelection = state.selectedRepositoryFullName?.trim();
    if (existingSelection != null &&
        existingSelection.isNotEmpty &&
        repos.any((repo) => repo.fullName == existingSelection)) {
      return existingSelection;
    }

    return null;
  }

  Future<Map<String, dynamic>?> _buildConnectionPayload(Server server) {
    return ref.read(serverConnectionPayloadResolverProvider)(server);
  }

  Future<void> _persistDeployReleaseResult({
    required String projectId,
    required String serverId,
    required Map<String, dynamic> deployResult,
  }) async {
    final records = AppReleaseRepository.recordsFromBackendResponse(
      projectId: projectId,
      serverId: serverId,
      payload: deployResult,
      observedAt: DateTime.now().toUtc(),
    );
    if (records.isEmpty) {
      return;
    }
    final hasFullInventory =
        deployResult['release_inventory'] is Map ||
        deployResult['releases'] is List;
    final notifier = ref.read(appReleaseProvider.notifier);
    if (hasFullInventory) {
      await notifier.replaceReleases(
        projectId: projectId,
        serverId: serverId,
        releases: records,
      );
      return;
    }
    for (final record in records) {
      await notifier.upsertRelease(record);
    }
  }

  // coverage-gate: deploy_failure_terminal_persistence
  /// Persists typed deploy evidence once per journal for restart-safe replay.
  Future<void> _persistDeployFailureEvidence({
    required String projectId,
    required Server server,
    required DeployFailureEvidence evidence,
    required ProjectManagedOperationJournalRecord journal,
  }) async {
    if (evidence.lines.isEmpty) {
      return;
    }
    final serverLabel = server.name.trim().isEmpty
        ? 'Server'
        : server.name.trim();
    final capturedAt = journal.createdAt;
    final timestamp = formatClockTime(capturedAt);
    await ref
        .read(terminalLogRepositoryProvider)
        .appendLogBatchOnce(
          lines: evidence.lines
              .map(
                (line) => (
                  message: line,
                  renderedLine: '[$serverLabel $timestamp] $line',
                ),
              )
              .toList(growable: false),
          projectId: projectId,
          serverId: server.id,
          serverLabel: serverLabel,
          source: _deployFailureEvidenceTerminalSource,
          taskType: 'app_deploy',
          createdAt: capturedAt,
        );
  }
  // end coverage-gate

  /// Retains pre-contract candidate excerpts when typed evidence is absent.
  Future<void> _persistLegacyDeployRuntimeLogExcerpt({
    required String projectId,
    required Server server,
    required Map<String, dynamic> deployResult,
  }) async {
    final source = deployResult['runtime_log_source']?.toString().trim();
    final rawLines = deployResult['runtime_log_excerpt'];
    if (source == null ||
        !source.contains('candidate') ||
        rawLines is! Iterable) {
      return;
    }

    final lines = rawLines
        .map((line) => line?.toString().trim() ?? '')
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) {
      return;
    }

    final serverLabel = server.name.trim().isEmpty
        ? 'Server'
        : server.name.trim();
    final capturedAt = DateTime.now();
    final timestamp = formatClockTime(capturedAt);
    final logSource = source == 'failed_rollback_candidate'
        ? 'app_runtime_failed_rollback_candidate'
        : 'app_runtime_failed_candidate';
    final repository = ref.read(terminalLogRepositoryProvider);

    for (final line in lines) {
      await repository.appendLog(
        message: line,
        renderedLine: '[$serverLabel $timestamp] $line',
        projectId: projectId,
        serverId: server.id,
        serverLabel: serverLabel,
        source: logSource,
        taskType: 'app_runtime_logs',
        createdAt: capturedAt,
      );
    }
  }
}

class _AbortDeploymentException implements Exception {}

final gitHubIntegrationProvider =
    NotifierProvider<GitHubIntegrationNotifier, GitHubIntegrationState>(
      GitHubIntegrationNotifier.new,
    );
