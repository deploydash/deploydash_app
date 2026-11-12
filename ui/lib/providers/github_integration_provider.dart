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
import '../utils/app_subdirectory.dart';
import '../utils/format_clock_time.dart';
import '../utils/github_branch_pattern.dart';
import '../utils/github_fqdn_pattern.dart';
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

/// The connected status sentence (D-26): one owner for the four provider
/// sites. Takes the list because the call sites test different subjects
/// (a fresh fetch vs the stored state); the agent-access tool keeps its
/// own sentence because its second branch differs.
String _githubConnectedMessage(List<GitHubRepository> repositories) {
  return repositories.isEmpty
      ? 'GitHub connected. No repositories found.'
      : 'GitHub connected. Pick a repository to deploy.';
}

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

/// The mutable per-run half of a repository deploy (D-26).
///
/// [GitHubIntegrationNotifier.deploySelectedRepository] used to carry this
/// state in captured locals shared by nine closures; the closures are now
/// named methods and the state they share lives here instead. Everything
/// else a step needs arrives as explicit parameters, so the data flow
/// stays visible at the call sites. One instance per deploy run — never
/// stored on the notifier.
/// Validated inputs for one repository deploy (D-26).
///
/// [_GitHubDeployRunContext] carries the run identity; this carries
/// everything validation resolved or normalized before the run starts.
/// Null from [_resolveDeployRunInputs] means validation already failed
/// the run via [_failDeployBeforeRun].
class _DeployRunInputs {
  const _DeployRunInputs({
    required this.token,
    required this.selectedServer,
    required this.selectedProject,
    required this.selectedRepo,
    required this.connection,
    required this.normalizedProvider,
    required this.effectiveBuildCommand,
    required this.effectiveRunCommand,
    required this.includeBuildCommand,
    required this.includeRunCommand,
    required this.effectiveAppSubdirectory,
    required this.effectiveDomainRoutingMode,
  });

  final String token;
  final Server selectedServer;
  final Project selectedProject;
  final String selectedRepo;
  final Map<String, dynamic> connection;
  final String? normalizedProvider;
  final String effectiveBuildCommand;
  final String effectiveRunCommand;
  final bool includeBuildCommand;
  final bool includeRunCommand;
  final String? effectiveAppSubdirectory;
  final String effectiveDomainRoutingMode;
}

class _DeployRun {
  _DeployRun({
    required this.runContext,
    required this.selectedProject,
    required this.selectedServer,
    required this.selectedRepo,
    required this.branch,
    required this.primaryDomain,
    required this.deploymentStartedAt,
  });

  final _GitHubDeployRunContext runContext;
  final Project selectedProject;
  final Server selectedServer;
  final String selectedRepo;
  final String branch;
  final String primaryDomain;
  final DateTime deploymentStartedAt;
  List<String> deployTimeline = <String>[];
  bool outcomePersisted = false;
  late ProjectManagedOperationJournalRecord latestDeployJournal;
  DeployFailureEvidence? latestDeployFailureEvidence;
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

/// Settings payload one owner (D-26) threads through a deploy run.
class _DeploySettings {
  _DeploySettings({required this.baseSettings, required this.runtimeEnv});

  final Map<String, dynamic> baseSettings;
  final Map<String, String> runtimeEnv;
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

    // One owner (D-26 pair D): the IOException/StateError twins were
    // byte-identical. Returning from the closure is the same as returning
    // from the method here — the call is the last statement of each block.
    Future<void> sessionExpired() async {
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
        statusMessage: _githubConnectedMessage(repos),
      );
    } on IOException {
      await sessionExpired();
    } on StateError {
      await sessionExpired();
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

  /// One owner (D-26) for the four OAuth failure tails: drop the pending
  /// state, track the failed stage, and land on the error message. Only
  /// the exchange catch also drops a saved token, so that stays opt-in.
  Future<void> _failOauth(
    String statusMessage, {
    bool clearToken = false,
  }) async {
    if (clearToken) {
      await ref.read(gitHubSecretRepositoryProvider).clearAuthToken();
    }
    _pendingOauthState = null;
    await ref
        .read(appPreferencesRepositoryProvider)
        .setGitHubPendingOauthState(null);
    _trackOAuthStage(GitHubOAuthStage.failed);
    state = state.copyWith(
      connectStatus: GitHubConnectStatus.error,
      statusMessage: statusMessage,
    );
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
      await _failOauth('Could not open browser. Open OAuth URL manually.');
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
      await _failOauth('OAuth state mismatch. Please reconnect GitHub.');
      return;
    }

    final code = callbackUri.queryParameters['code'];
    if (code == null || code.isEmpty) {
      await _failOauth('Missing GitHub authorization code in callback.');
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
        statusMessage: _githubConnectedMessage(repos),
      );
      _trackOAuthStage(GitHubOAuthStage.completed);
    } catch (error) {
      await _failOauth(formatGitHubAuthError(error), clearToken: true);
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
          deployTimeline: deployRunning ? null : const [],
          clearSuggestedNextStep: !deployRunning,
          statusMessage: _githubConnectedMessage(state.repositories),
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
      final connectedMessage = _githubConnectedMessage(state.repositories);
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
        deployTimeline: deployRunning ? null : const [],
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

  /// One owner (D-26): lands a pre-run validation failure. Takes the
  /// project/repo as parameters because validation runs before the
  /// [_DeployRun] exists.
  void _failDeployBeforeRun({
    required Project? selectedProject,
    required String? selectedRepo,
    required String message,
  }) {
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

  /// One owner (D-26): writes one run-state update for [run], ignoring
  /// stale runs.
  void _updateDeployRunState(
    _DeployRun run, {
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
    if (!_isCurrentDeployRun(run.runContext)) {
      return;
    }
    if (deployTimelineOverride != null) {
      run.deployTimeline = List<String>.from(deployTimelineOverride);
    }
    final current = _projectDeployState(run.selectedProject.id);
    _setProjectDeployState(
      projectId: run.selectedProject.id,
      mirrorToActiveDeploy: true,
      projectState: current.copyWith(
        selectedRepositoryFullName: run.selectedRepo,
        deployStatus: deployStatus,
        statusMessage: statusMessage,
        deployTimeline: run.deployTimeline,
        activeRunId: clearActiveRun ? null : run.runContext.runId,
        activeRepositoryFullName: clearActiveRun ? null : run.selectedRepo,
        activeServerId: clearActiveRun ? null : run.selectedServer.id,
        activeBranch: clearActiveRun ? null : run.branch,
        activePrimaryDomain: clearActiveRun ? null : run.primaryDomain,
        startedAt: clearActiveRun ? null : run.deploymentStartedAt,
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

  /// One owner (D-26): appends one timeline line for [run], ignoring
  /// stale runs and duplicate/noise lines.
  void _appendDeployRunTimeline(
    _DeployRun run,
    String message, {
    String eventType = '',
  }) {
    if (!_isCurrentDeployRun(run.runContext)) {
      return;
    }
    if (!shouldAppendDeployTimelineLine(
      run.deployTimeline,
      message,
      eventType: eventType,
    )) {
      return;
    }
    run.deployTimeline = [...run.deployTimeline, message.trim()];
    _updateDeployRunState(run, deployTimelineOverride: run.deployTimeline);
  }

  /// Persists the first-deploy milestone so Home can offer the once-ever
  /// telemetry nag. Best-effort: a timestamp write must never fail a
  /// deploy that already succeeded.
  Future<void> _recordFirstDeployMilestone() async {
    try {
      await ref
          .read(appPreferencesRepositoryProvider)
          .recordAnalyticsMilestone(AppUserAttribute.hasFirstDeploySucceeded);
      await ref.read(telemetrySettingsProvider.notifier).refresh();
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('First-deploy milestone skipped; the deploy stands: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('First-deploy milestone skipped; the deploy stands: $error');
      }
    }
  }

  // coverage-gate: deploy_failure_analytics
  /// Reports one deploy resolution. Single seam so the six outcome sites
  /// funnelled through [_persistDeployOutcome] cannot drift onto different
  /// providers or method spellings; success also records the first-deploy
  /// activation attribute alongside the event.
  void _trackDeployResolution(
    bool success, {
    Map<String, dynamic>? deployResult,
    required int durationSeconds,
    required String? normalizedProvider,
    required String effectiveDomainRoutingMode,
    required String? actorLabel,
  }) {
    final analytics = ref.read(appAnalyticsServiceProvider);
    analytics.trackDeployEvent(
      provider: deployProviderForName(normalizedProvider),
      routingMode: effectiveDomainRoutingMode,
      stage: deployStageForResult(success: success, deployResult: deployResult),
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

  /// One owner (D-26): persists one deploy outcome exactly once per run.
  Future<void> _persistDeployOutcome(
    _DeployRun run,
    bool success, {
    Map<String, dynamic>? deployResult,
    required String? normalizedProvider,
    required String effectiveDomainRoutingMode,
    required String? actorLabel,
  }) async {
    if (run.outcomePersisted || !_isCurrentDeployRun(run.runContext)) {
      return;
    }
    run.outcomePersisted = true;

    final completedAt = DateTime.now();
    final duration = completedAt.difference(run.deploymentStartedAt);
    _trackDeployResolution(
      success,
      deployResult: deployResult,
      durationSeconds: duration.inSeconds,
      normalizedProvider: normalizedProvider,
      effectiveDomainRoutingMode: effectiveDomainRoutingMode,
      actorLabel: actorLabel,
    );
    if (success) {
      await _recordFirstDeployMilestone();
    }
    // `trimOrNull` is the repository's one owner for "trim it, and treat
    // blank as absent", which is exactly what each of these asked for in
    // six lines apiece.
    final resolvedCommit =
        trimOrNull(deployResult?['commit_sha']?.toString()) ??
        extractCommitHashFromTimeline(run.deployTimeline) ??
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
        projectId: run.selectedProject.id,
        serverId: run.selectedServer.id,
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
            projectId: run.selectedProject.id,
            commit: resolvedCommit,
            deployedAt: completedAt,
          );
      await ref
          .read(appReleaseProvider.notifier)
          .upsertRuntimeSnapshot(
            AppRuntimeSnapshotRecord(
              projectId: run.selectedProject.id,
              serverId: run.selectedServer.id,
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
            projectId: run.selectedProject.id,
            status: success ? 'success' : 'failed',
            releaseId: resolvedReleaseId,
            deploymentKind: resolvedDeploymentKind,
            rollbackFromReleaseId: resolvedRollbackFromReleaseId,
            deployedAt: completedAt,
            durationSeconds: duration.inSeconds,
            actor: resolvedActor,
            branch: run.branch,
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
              projectId: run.selectedProject.id,
              status: 'success',
              releaseId: fallbackReleaseId,
              deploymentKind: 'auto_fallback',
              rollbackFromReleaseId: resolvedReleaseId,
              deployedAt: completedAt,
              durationSeconds: duration.inSeconds,
              actor: resolvedActor,
              branch: run.branch,
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

  /// One owner (D-26): reuses the stored deploy key or generates a fresh
  /// one on the server.
  Future<({String publicKey, String privateKey, bool reusedStoredKey})>
  _acquireDeployKey(
    _DeployRun run, {
    required bool forceFreshKey,
    required Map<String, dynamic> connection,
    required Map<String, dynamic> baseSettings,
    required void Function(int taskId, String phase)? onTaskStarted,
    required String? normalizedProvider,
    required String effectiveDomainRoutingMode,
    required String? actorLabel,
  }) async {
    final secretRepo = ref.read(gitHubSecretRepositoryProvider);
    final sshService = ref.read(sshServiceProvider);
    if (!forceFreshKey) {
      final storedKey = await secretRepo.readDeployKey(run.selectedRepo);
      if (storedKey != null) {
        run.deployTimeline = const ['Reuse locally stored deploy key'];
        _updateDeployRunState(
          run,
          deployStatus: GitHubDeployStatus.generatingServerKey,
          statusMessage: 'Using stored deploy key...',
          deployTimelineOverride: run.deployTimeline,
        );
        _appendDeployRunTimeline(
          run,
          'Using existing local deploy key for ${run.selectedRepo}',
        );
        return (
          publicKey: storedKey.publicKey,
          privateKey: storedKey.privateKey,
          reusedStoredKey: true,
        );
      }
    }

    run.deployTimeline = forceFreshKey
        ? [...run.deployTimeline, 'Generate fresh deploy key on server']
        : const ['Generate SSH deploy key on server'];
    _updateDeployRunState(
      run,
      deployStatus: GitHubDeployStatus.generatingServerKey,
      statusMessage: 'Generating deploy key on server...',
      deployTimelineOverride: run.deployTimeline,
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
        _appendDeployRunTimeline(run, message, eventType: type);
      },
    );
    final prepareEvidence = _deployFailureEvidenceFromResult(prepareOutcome);
    final prepareResult = prepareOutcome.diagnosticPayload;
    if (!_isCurrentDeployRun(run.runContext)) {
      throw _AbortDeploymentException();
    }
    if (prepareResult['status'] != 'success') {
      await _persistDeployOutcome(
        run,
        false,
        deployResult: prepareResult,
        normalizedProvider: normalizedProvider,
        effectiveDomainRoutingMode: effectiveDomainRoutingMode,
        actorLabel: actorLabel,
      );
      _updateDeployRunState(
        run,
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

    final preparedPublicKey = prepareResult['deploy_public_key']?.toString();
    final preparedPrivateKey = prepareResult['deploy_private_key']?.toString();
    if (preparedPublicKey == null ||
        preparedPublicKey.trim().isEmpty ||
        preparedPrivateKey == null ||
        preparedPrivateKey.trim().isEmpty) {
      await _persistDeployOutcome(
        run,
        false,
        normalizedProvider: normalizedProvider,
        effectiveDomainRoutingMode: effectiveDomainRoutingMode,
        actorLabel: actorLabel,
      );
      _updateDeployRunState(
        run,
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
      repositoryFullName: run.selectedRepo,
      publicKey: deployPublicKey,
      privateKey: deployPrivateKey,
    );

    _appendDeployRunTimeline(
      run,
      'Copied deploy key to local secure store and wiped it from server',
    );
    return (
      publicKey: deployPublicKey,
      privateKey: deployPrivateKey,
      reusedStoredKey: false,
    );
  }

  /// One owner (D-26): registers the deploy key with GitHub.
  Future<void> _registerDeployKey(
    _DeployRun run,
    String publicKey, {
    required String token,
  }) async {
    final gateway = ref.read(gitHubAuthGatewayProvider);
    final delay = ref.read(gitHubInteractionStepDelayProvider);
    run.deployTimeline = [
      ...run.deployTimeline,
      'Register local public key as GitHub Deploy Key (read-only)',
    ];
    _updateDeployRunState(
      run,
      deployStatus: GitHubDeployStatus.registeringDeployKey,
      statusMessage: 'Registering deploy key with GitHub...',
      deployTimelineOverride: run.deployTimeline,
    );

    await gateway.registerDeployKey(
      accessToken: token,
      repositoryFullName: run.selectedRepo,
      publicKey: publicKey,
    );
    await Future<void>.delayed(delay);
    if (!_isCurrentDeployRun(run.runContext)) {
      throw _AbortDeploymentException();
    }
  }

  /// One owner (D-26): runs the deployment with the deploy key and journals
  /// the attempt.
  Future<Map<String, dynamic>> _runDeploymentWithKey(
    _DeployRun run,
    String privateKey, {
    required Map<String, dynamic> connection,
    required Map<String, dynamic> baseSettings,
    required Map<String, String> runtimeEnv,
    required String? repositoryHostKeyPolicy,
    required String? acceptedRepositoryHostKeyFingerprint,
    required int appPort,
    required String effectiveDomainRoutingMode,
    required String? normalizedProvider,
    required void Function(int taskId, String phase)? onTaskStarted,
  }) async {
    final sshService = ref.read(sshServiceProvider);
    run.deployTimeline = [
      ...run.deployTimeline,
      'Clone ${run.selectedRepo} using runtime-injected deploy key',
    ];
    _updateDeployRunState(
      run,
      deployStatus: GitHubDeployStatus.cloningRepository,
      statusMessage: 'Cloning repository on server...',
      deployTimelineOverride: run.deployTimeline,
    );
    run.deployTimeline = [
      ...run.deployTimeline,
      if (runtimeEnv.isNotEmpty)
        'Apply ${runtimeEnv.length} app runtime env vars to container',
      'Build image and publish through Caddy',
    ];
    _updateDeployRunState(
      run,
      deployStatus: GitHubDeployStatus.buildingRelease,
      statusMessage: 'Running web app build and deployment on server...',
      deployTimelineOverride: run.deployTimeline,
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
      projectId: run.selectedProject.id,
      serverId: run.selectedServer.id,
      surface: 'app',
      operationType: 'run',
      request: <String, dynamic>{
        'workflow_id': 'app',
        'operation_id': 'run',
        'repository': run.selectedRepo,
        'branch': run.branch,
        'app_port': appPort,
        'domain_routing_mode': effectiveDomainRoutingMode,
        'railpack_provider': normalizedProvider,
        'runtime_env_count': runtimeEnv.length,
      },
    );
    run.latestDeployJournal = journal;
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
          _appendDeployRunTimeline(run, message, eventType: type);
        },
      );
      run.latestDeployFailureEvidence = _deployFailureEvidenceFromResult(
        outcome,
      );
      result = outcome.diagnosticPayload;
    } catch (error) {
      run.latestDeployFailureEvidence = null;
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
    if (!_isCurrentDeployRun(run.runContext)) {
      throw _AbortDeploymentException();
    }
    return result;
  }

  /// One owner (D-26): resolves and validates every deploy input,
  /// returning null when validation already failed the run.
  Future<_DeployRunInputs?> _resolveDeployRunInputs({
    required String? repositoryFullName,
    required String primaryDomain,
    required String branch,
    required int appPort,
    required String? domainRoutingMode,
    required String? railpackBuildCommand,
    required String? railpackRunCommand,
    required String? railpackProvider,
    required String? appSubdirectory,
    required Server? selectedServerOverride,
    required Project? selectedProjectOverride,
    required String? actorLabel,
    required String? repositoryHostKeyPolicy,
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
      _failDeployBeforeRun(
        selectedProject: selectedProject,
        selectedRepo: selectedRepo,
        message: 'Connect GitHub and select a repository before deploying.',
      );
      return null;
    }
    if (!_isValidDomain(primaryDomain)) {
      _failDeployBeforeRun(
        selectedProject: selectedProject,
        selectedRepo: selectedRepo,
        message:
            'Primary domain is required and must be a valid FQDN before deploy.',
      );
      return null;
    }
    if (!_isValidBranch(branch)) {
      _failDeployBeforeRun(
        selectedProject: selectedProject,
        selectedRepo: selectedRepo,
        message: 'Branch name is invalid.',
      );
      return null;
    }
    if (appPort < 1 || appPort > 65535) {
      _failDeployBeforeRun(
        selectedProject: selectedProject,
        selectedRepo: selectedRepo,
        message: 'Web app port must be between 1 and 65535.',
      );
      return null;
    }
    if (selectedServer == null) {
      _failDeployBeforeRun(
        selectedProject: selectedProject,
        selectedRepo: selectedRepo,
        message: 'No active server selected for deploy.',
      );
      return null;
    }
    if (selectedProject == null) {
      _failDeployBeforeRun(
        selectedProject: selectedProject,
        selectedRepo: selectedRepo,
        message: 'No project selected for deploy.',
      );
      return null;
    }

    final connection = await _buildConnectionPayload(selectedServer);
    if (connection == null) {
      _failDeployBeforeRun(
        selectedProject: selectedProject,
        selectedRepo: selectedRepo,
        message:
            'Selected server credentials are incomplete. Reconnect server first.',
      );
      return null;
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
    final effectiveAppSubdirectory = normalizeAppSubdirectory(
      appSubdirectory ?? selectedProject.appSubdirectory,
      invalidValue: _invalidAppSubdirectory,
    );
    if (effectiveAppSubdirectory == _invalidAppSubdirectory) {
      _failDeployBeforeRun(
        selectedProject: selectedProject,
        selectedRepo: selectedRepo,
        message:
            'App subdirectory is invalid. Use a relative path like "website".',
      );
      return null;
    }

    final effectiveDomainRoutingMode =
        domainRoutingMode == null || domainRoutingMode.trim().isEmpty
        ? selectedProject.domainRoutingMode
        : domainRoutingMode.trim().toLowerCase();
    return _DeployRunInputs(
      token: token,
      selectedServer: selectedServer,
      selectedProject: selectedProject,
      selectedRepo: selectedRepo,
      connection: connection,
      normalizedProvider: normalizedProvider,
      effectiveBuildCommand: effectiveBuildCommand,
      effectiveRunCommand: effectiveRunCommand,
      includeBuildCommand: includeBuildCommand,
      includeRunCommand: includeRunCommand,
      effectiveAppSubdirectory: effectiveAppSubdirectory,
      effectiveDomainRoutingMode: effectiveDomainRoutingMode,
    );
  }

  /// One owner (D-26): builds the [_DeployRun] and writes the initial
  /// run state. Returns the run the rest of the deploy threads through.
  _DeployRun _beginDeployRun({
    required Project selectedProject,
    required Server selectedServer,
    required String selectedRepo,
    required String branch,
    required String primaryDomain,
    required String? repositoryHostKeyPolicy,
  }) {
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
    final run = _DeployRun(
      runContext: runContext,
      selectedProject: selectedProject,
      selectedServer: selectedServer,
      selectedRepo: selectedRepo,
      branch: branch,
      primaryDomain: primaryDomain,
      deploymentStartedAt: deploymentStartedAt,
    );
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
    return run;
  }

  /// One owner (D-26): persists the resolved deployment configuration
  /// before the run starts mutating server state.
  void _persistDeployConfiguration({
    required Project selectedProject,
    required String selectedRepo,
    required String primaryDomain,
    required String effectiveDomainRoutingMode,
    required String? effectiveAppSubdirectory,
    required String branch,
    required int appPort,
    required String? normalizedProvider,
    required String effectiveBuildCommand,
    required String effectiveRunCommand,
  }) {
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
  }

  /// One owner (D-26): resolves the SQLite/env/trust inputs and assembles
  /// the settings payload the attempt loop consumes.
  Future<_DeploySettings> _buildDeploySettings({
    required Project selectedProject,
    required String selectedRepo,
    required String branch,
    required String primaryDomain,
    required String effectiveDomainRoutingMode,
    required int appPort,
    required String? normalizedProvider,
    required bool includeBuildCommand,
    required String effectiveBuildCommand,
    required bool includeRunCommand,
    required String effectiveRunCommand,
    required String? effectiveAppSubdirectory,
  }) async {
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
    return _DeploySettings(baseSettings: baseSettings, runtimeEnv: runtimeEnv);
  }

  /// One owner (D-26): finishes a deploy attempt whose result carried a
  /// failure — host-key confirmation, persisted evidence, error state.
  Future<void> _finishFailedDeployAttempt({
    required _DeployRun run,
    required Map<String, dynamic> deployResult,
    required String failureMessage,
    required List<String> attemptTimeline,
    required Project selectedProject,
    required Server selectedServer,
    required String selectedRepo,
    required String branch,
    required String primaryDomain,
    required int appPort,
    required String effectiveDomainRoutingMode,
    required String effectiveBuildCommand,
    required String effectiveRunCommand,
    required String? normalizedProvider,
    required String? effectiveAppSubdirectory,
    required String? actorLabel,
    required void Function(int taskId, String phase)? onTaskStarted,
  }) async {
    final hostKeyConfirmation = GitHubRepositoryHostKeyConfirmation.fromPayload(
      deployResult['repository_host_key_confirmation'],
    );
    if (deployResult['repository_host_key_confirmation_required'] == true &&
        hostKeyConfirmation != null) {
      final acceptedPromptId =
          _acceptedRepositoryHostKeyPromptIdByProject[selectedProject.id];
      if (acceptedPromptId == hostKeyConfirmation.promptId) {
        _pendingRepositoryHostKeyRetryByProject.remove(selectedProject.id);
        _acceptedRepositoryHostKeyPromptIdByProject.remove(selectedProject.id);
        await _persistDeployOutcome(
          run,
          false,
          deployResult: deployResult,
          normalizedProvider: normalizedProvider,
          effectiveDomainRoutingMode: effectiveDomainRoutingMode,
          actorLabel: actorLabel,
        );
        _updateDeployRunState(
          run,
          deployStatus: GitHubDeployStatus.error,
          statusMessage:
              'Deploy Dash still could not save the trusted GitHub SSH identity on the server. Check the deployment log and try again.',
          deployTimelineOverride: [
            ...run.deployTimeline,
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
      _updateDeployRunState(
        run,
        deployStatus: GitHubDeployStatus.awaitingRepositoryHostKeyConfirmation,
        statusMessage:
            'Confirm the GitHub SSH identity before Deploy Dash fetches this repository.',
        deployTimelineOverride: [
          ...run.deployTimeline,
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
    await _persistDeployOutcome(
      run,
      false,
      deployResult: deployResult,
      normalizedProvider: normalizedProvider,
      effectiveDomainRoutingMode: effectiveDomainRoutingMode,
      actorLabel: actorLabel,
    );
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
      failureEvidence: run.latestDeployFailureEvidence,
    );
    final hints = <String>[
      ?subdirectoryHint,
      ?buildCommandHint,
      ?domainOwnershipHint,
      ?repositoryAccessHint,
    ];
    final failureEvidence = run.latestDeployFailureEvidence;
    if (failureEvidence != null) {
      await _persistDeployFailureEvidence(
        projectId: selectedProject.id,
        server: selectedServer,
        evidence: failureEvidence,
        journal: run.latestDeployJournal,
      );
    } else {
      await _persistLegacyDeployRuntimeLogExcerpt(
        projectId: selectedProject.id,
        server: selectedServer,
        deployResult: deployResult,
      );
    }
    _updateDeployRunState(
      run,
      deployStatus: GitHubDeployStatus.error,
      statusMessage: failureMessage,
      deployTimelineOverride: run.deployTimeline,
      failureEvidence: failureEvidence,
      suggestedNextStep: hints.isEmpty ? null : hints.join(' '),
      clearFailureEvidence: failureEvidence == null,
      clearSuggestedNextStep: hints.isEmpty,
      clearActiveRun: true,
    );
    // end coverage-gate
    return;
  }

  /// One owner (D-26): finishes a deploy attempt whose result carried no
  /// failure — success timeline, persisted outcome, success state.
  Future<void> _finishSuccessfulDeployAttempt({
    required _DeployRun run,
    required Map<String, dynamic> deployResult,
    required Project selectedProject,
    required String? normalizedProvider,
    required String effectiveDomainRoutingMode,
    required String? actorLabel,
  }) async {
    run.deployTimeline = [
      ...run.deployTimeline,
      'Deployment completed successfully',
      if (deployResult['http_url'] != null) 'HTTP: ${deployResult['http_url']}',
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
    await _persistDeployOutcome(
      run,
      true,
      deployResult: deployResult,
      normalizedProvider: normalizedProvider,
      effectiveDomainRoutingMode: effectiveDomainRoutingMode,
      actorLabel: actorLabel,
    );
    await ref
        .read(appReleaseRepositoryProvider)
        .updateJournalStatus(
          id: run.latestDeployJournal.id,
          status: 'committed_local',
          result: deployResult,
        );
    _updateDeployRunState(
      run,
      deployStatus: GitHubDeployStatus.success,
      statusMessage: publicHealth.needsAttention
          ? 'Deploy completed, but the public URL check failed. Review runtime logs or environment settings.'
          : 'Deploy completed. ${deployResult['https_url'] ?? 'HTTPS URL ready.'} App runtime logs are in the Log screen.',
      processReadinessStatus: processReadinessStatus ?? 'unknown',
      publicHealth: publicHealth,
      deployTimelineOverride: run.deployTimeline,
      clearFailureEvidence: true,
      clearSuggestedNextStep: true,
      clearActiveRun: true,
    );
  }

  /// One owner (D-26): runs the deploy attempts — key acquire, register,
  /// run, single key-rotation retry — then dispatches to the failure or
  /// success finishers.
  Future<void> _runDeployAttemptLoop({
    required _DeployRun run,
    required Map<String, dynamic> connection,
    required Map<String, dynamic> baseSettings,
    required Map<String, String> runtimeEnv,
    required String token,
    required String? repositoryHostKeyPolicy,
    required String? acceptedRepositoryHostKeyFingerprint,
    required int appPort,
    required String? normalizedProvider,
    required String effectiveDomainRoutingMode,
    required String effectiveBuildCommand,
    required String effectiveRunCommand,
    required String? effectiveAppSubdirectory,
    required Project selectedProject,
    required Server selectedServer,
    required String selectedRepo,
    required String branch,
    required String primaryDomain,
    required String? actorLabel,
    required void Function(int taskId, String phase)? onTaskStarted,
  }) async {
    var keyMaterial = await _acquireDeployKey(
      run,
      forceFreshKey: false,
      connection: connection,
      baseSettings: baseSettings,
      onTaskStarted: onTaskStarted,
      normalizedProvider: normalizedProvider,
      effectiveDomainRoutingMode: effectiveDomainRoutingMode,
      actorLabel: actorLabel,
    );
    await _registerDeployKey(run, keyMaterial.publicKey, token: token);
    var attemptTimelineStartIndex = run.deployTimeline.length;
    var deployResult = await _runDeploymentWithKey(
      run,
      keyMaterial.privateKey,
      connection: connection,
      baseSettings: baseSettings,
      runtimeEnv: runtimeEnv,
      repositoryHostKeyPolicy: repositoryHostKeyPolicy,
      acceptedRepositoryHostKeyFingerprint:
          acceptedRepositoryHostKeyFingerprint,
      appPort: appPort,
      effectiveDomainRoutingMode: effectiveDomainRoutingMode,
      normalizedProvider: normalizedProvider,
      onTaskStarted: onTaskStarted,
    );
    var failureMessage = _deploymentFailureMessage(deployResult);
    var attemptTimeline = run.deployTimeline.sublist(attemptTimelineStartIndex);

    // coverage-gate: repository_key_rotation_retry
    if (failureMessage != null &&
        keyMaterial.reusedStoredKey &&
        isRepositoryCloneAccessFailure(
          failureMessage: failureMessage,
          timeline: attemptTimeline,
          failureEvidence: run.latestDeployFailureEvidence,
        )) {
      _appendDeployRunTimeline(
        run,
        'Stored deploy key could not access repository; rotating key and retrying once',
      );
      await ref
          .read(gitHubSecretRepositoryProvider)
          .deleteDeployKey(selectedRepo);
      keyMaterial = await _acquireDeployKey(
        run,
        forceFreshKey: true,
        connection: connection,
        baseSettings: baseSettings,
        onTaskStarted: onTaskStarted,
        normalizedProvider: normalizedProvider,
        effectiveDomainRoutingMode: effectiveDomainRoutingMode,
        actorLabel: actorLabel,
      );
      await _registerDeployKey(run, keyMaterial.publicKey, token: token);
      attemptTimelineStartIndex = run.deployTimeline.length;
      deployResult = await _runDeploymentWithKey(
        run,
        keyMaterial.privateKey,
        connection: connection,
        baseSettings: baseSettings,
        runtimeEnv: runtimeEnv,
        repositoryHostKeyPolicy: repositoryHostKeyPolicy,
        acceptedRepositoryHostKeyFingerprint:
            acceptedRepositoryHostKeyFingerprint,
        appPort: appPort,
        effectiveDomainRoutingMode: effectiveDomainRoutingMode,
        normalizedProvider: normalizedProvider,
        onTaskStarted: onTaskStarted,
      );
      failureMessage = _deploymentFailureMessage(deployResult);
      attemptTimeline = run.deployTimeline.sublist(attemptTimelineStartIndex);
    }
    // end coverage-gate

    if (failureMessage != null) {
      await _finishFailedDeployAttempt(
        run: run,
        deployResult: deployResult,
        failureMessage: failureMessage,
        attemptTimeline: attemptTimeline,
        selectedProject: selectedProject,
        selectedServer: selectedServer,
        selectedRepo: selectedRepo,
        branch: branch,
        primaryDomain: primaryDomain,
        appPort: appPort,
        effectiveDomainRoutingMode: effectiveDomainRoutingMode,
        effectiveBuildCommand: effectiveBuildCommand,
        effectiveRunCommand: effectiveRunCommand,
        normalizedProvider: normalizedProvider,
        effectiveAppSubdirectory: effectiveAppSubdirectory,
        actorLabel: actorLabel,
        onTaskStarted: onTaskStarted,
      );
      return;
    }

    await _finishSuccessfulDeployAttempt(
      run: run,
      deployResult: deployResult,
      selectedProject: selectedProject,
      normalizedProvider: normalizedProvider,
      effectiveDomainRoutingMode: effectiveDomainRoutingMode,
      actorLabel: actorLabel,
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
    final inputs = await _resolveDeployRunInputs(
      repositoryFullName: repositoryFullName,
      primaryDomain: primaryDomain,
      branch: branch,
      appPort: appPort,
      domainRoutingMode: domainRoutingMode,
      railpackBuildCommand: railpackBuildCommand,
      railpackRunCommand: railpackRunCommand,
      railpackProvider: railpackProvider,
      appSubdirectory: appSubdirectory,
      selectedServerOverride: selectedServerOverride,
      selectedProjectOverride: selectedProjectOverride,
      actorLabel: actorLabel,
      repositoryHostKeyPolicy: repositoryHostKeyPolicy,
    );
    if (inputs == null) {
      return;
    }
    final token = inputs.token;
    final selectedServer = inputs.selectedServer;
    final selectedProject = inputs.selectedProject;
    final selectedRepo = inputs.selectedRepo;
    final connection = inputs.connection;
    final normalizedProvider = inputs.normalizedProvider;
    final effectiveBuildCommand = inputs.effectiveBuildCommand;
    final effectiveRunCommand = inputs.effectiveRunCommand;
    final includeBuildCommand = inputs.includeBuildCommand;
    final includeRunCommand = inputs.includeRunCommand;
    final effectiveAppSubdirectory = inputs.effectiveAppSubdirectory;
    final effectiveDomainRoutingMode = inputs.effectiveDomainRoutingMode;

    final run = _beginDeployRun(
      selectedProject: selectedProject,
      selectedServer: selectedServer,
      selectedRepo: selectedRepo,
      branch: branch,
      primaryDomain: primaryDomain,
      repositoryHostKeyPolicy: repositoryHostKeyPolicy,
    );

    _persistDeployConfiguration(
      selectedProject: selectedProject,
      selectedRepo: selectedRepo,
      primaryDomain: primaryDomain,
      effectiveDomainRoutingMode: effectiveDomainRoutingMode,
      effectiveAppSubdirectory: effectiveAppSubdirectory,
      branch: branch,
      appPort: appPort,
      normalizedProvider: normalizedProvider,
      effectiveBuildCommand: effectiveBuildCommand,
      effectiveRunCommand: effectiveRunCommand,
    );

    final deploySettings = await _buildDeploySettings(
      selectedProject: selectedProject,
      selectedRepo: selectedRepo,
      branch: branch,
      primaryDomain: primaryDomain,
      effectiveDomainRoutingMode: effectiveDomainRoutingMode,
      appPort: appPort,
      normalizedProvider: normalizedProvider,
      includeBuildCommand: includeBuildCommand,
      effectiveBuildCommand: effectiveBuildCommand,
      includeRunCommand: includeRunCommand,
      effectiveRunCommand: effectiveRunCommand,
      effectiveAppSubdirectory: effectiveAppSubdirectory,
    );
    final baseSettings = deploySettings.baseSettings;
    final runtimeEnv = deploySettings.runtimeEnv;

    try {
      await _runDeployAttemptLoop(
        run: run,
        connection: connection,
        baseSettings: baseSettings,
        runtimeEnv: runtimeEnv,
        token: token,
        repositoryHostKeyPolicy: repositoryHostKeyPolicy,
        acceptedRepositoryHostKeyFingerprint:
            acceptedRepositoryHostKeyFingerprint,
        appPort: appPort,
        normalizedProvider: normalizedProvider,
        effectiveDomainRoutingMode: effectiveDomainRoutingMode,
        effectiveBuildCommand: effectiveBuildCommand,
        effectiveRunCommand: effectiveRunCommand,
        effectiveAppSubdirectory: effectiveAppSubdirectory,
        selectedProject: selectedProject,
        selectedServer: selectedServer,
        selectedRepo: selectedRepo,
        branch: branch,
        primaryDomain: primaryDomain,
        actorLabel: actorLabel,
        onTaskStarted: onTaskStarted,
      );
    } on _AbortDeploymentException {
      return;
    } catch (error) {
      await _persistDeployOutcome(
        run,
        false,
        normalizedProvider: normalizedProvider,
        effectiveDomainRoutingMode: effectiveDomainRoutingMode,
        actorLabel: actorLabel,
      );
      _updateDeployRunState(
        run,
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
    return githubFqdnPattern.hasMatch(candidate);
  }

  static bool _isValidBranch(String value) {
    final candidate = value.trim();
    if (candidate.isEmpty) {
      return false;
    }
    return githubBranchPattern.hasMatch(candidate);
  }

  static const String _invalidAppSubdirectory = '__invalid__';

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
