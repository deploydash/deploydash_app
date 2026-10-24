import '../models/app_public_health.dart';
import '../models/deploy_failure_evidence.dart';
import '../models/github_repository.dart';

/// The value types the GitHub integration keeps in Riverpod state.
///
/// Split out of `github_integration_provider.dart` by T-3.3.6. They are plain
/// values -- no Riverpod, no HTTP, no I/O -- so they can be constructed and
/// asserted directly instead of only through the notifier that holds them.

enum GitHubConnectStatus {
  disconnected,
  launchingBrowser,
  awaitingCallback,
  exchangingCode,
  loadingRepositories,
  connected,
  error,
}

enum GitHubDeployStatus {
  idle,
  generatingServerKey,
  registeringDeployKey,
  cloningRepository,
  buildingRelease,
  awaitingRepositoryHostKeyConfirmation,
  success,
  error,
}

class GitHubRepositoryHostKeyConfirmation {
  const GitHubRepositoryHostKeyConfirmation({
    required this.host,
    required this.port,
    required this.reason,
    required this.scannedFingerprint,
    this.previousFingerprint,
  });

  final String host;
  final String port;
  final String reason;
  final String scannedFingerprint;
  final String? previousFingerprint;

  String get promptId =>
      '$host:$port:$reason:${previousFingerprint ?? ''}:$scannedFingerprint';

  String get trustPolicy =>
      reason == 'changed' ? 'replace_confirmed' : 'accept_new';

  static GitHubRepositoryHostKeyConfirmation? fromPayload(Object? payload) {
    if (payload is! Map) {
      return null;
    }
    final host = payload['host']?.toString().trim() ?? '';
    final port = payload['port']?.toString().trim() ?? '22';
    final reason = payload['reason']?.toString().trim() ?? '';
    final scannedFingerprint = payload['scanned_fingerprint']
        ?.toString()
        .trim();
    final previousFingerprint = payload['previous_fingerprint']
        ?.toString()
        .trim();
    if (host.isEmpty ||
        reason.isEmpty ||
        scannedFingerprint == null ||
        scannedFingerprint.isEmpty) {
      return null;
    }
    return GitHubRepositoryHostKeyConfirmation(
      host: host,
      port: port.isEmpty ? '22' : port,
      reason: reason,
      scannedFingerprint: scannedFingerprint,
      previousFingerprint:
          previousFingerprint == null || previousFingerprint.isEmpty
          ? null
          : previousFingerprint,
    );
  }
}

class GitHubProjectDeployState {
  const GitHubProjectDeployState({
    this.selectedRepositoryFullName,
    this.deployStatus = GitHubDeployStatus.idle,
    this.statusMessage = 'Ready to deploy this web app.',
    this.deployTimeline = const <String>[],
    this.activeRunId,
    this.activeRepositoryFullName,
    this.activeServerId,
    this.activeBranch,
    this.activePrimaryDomain,
    this.startedAt,
    this.repositoryHostKeyConfirmation,
    this.processReadinessStatus,
    this.publicHealth,
    this.failureEvidence,
    this.suggestedNextStep,
  });

  final String? selectedRepositoryFullName;
  final GitHubDeployStatus deployStatus;
  final String statusMessage;
  final List<String> deployTimeline;
  final String? activeRunId;
  final String? activeRepositoryFullName;
  final String? activeServerId;
  final String? activeBranch;
  final String? activePrimaryDomain;
  final DateTime? startedAt;
  final GitHubRepositoryHostKeyConfirmation? repositoryHostKeyConfirmation;
  final String? processReadinessStatus;
  final AppPublicHealthSnapshot? publicHealth;
  final DeployFailureEvidence? failureEvidence;
  final String? suggestedNextStep;

  bool get isRunning => isDeployStatusRunning(deployStatus);

  GitHubProjectDeployState copyWith({
    String? selectedRepositoryFullName,
    GitHubDeployStatus? deployStatus,
    String? statusMessage,
    List<String>? deployTimeline,
    String? activeRunId,
    String? activeRepositoryFullName,
    String? activeServerId,
    String? activeBranch,
    String? activePrimaryDomain,
    DateTime? startedAt,
    GitHubRepositoryHostKeyConfirmation? repositoryHostKeyConfirmation,
    String? processReadinessStatus,
    AppPublicHealthSnapshot? publicHealth,
    DeployFailureEvidence? failureEvidence,
    String? suggestedNextStep,
    bool clearSelectedRepositoryFullName = false,
    bool clearActiveRunId = false,
    bool clearActiveRepositoryFullName = false,
    bool clearActiveServerId = false,
    bool clearActiveBranch = false,
    bool clearActivePrimaryDomain = false,
    bool clearStartedAt = false,
    bool clearRepositoryHostKeyConfirmation = false,
    bool clearFailureEvidence = false,
    bool clearSuggestedNextStep = false,
  }) {
    return GitHubProjectDeployState(
      selectedRepositoryFullName: clearSelectedRepositoryFullName
          ? null
          : (selectedRepositoryFullName ?? this.selectedRepositoryFullName),
      deployStatus: deployStatus ?? this.deployStatus,
      statusMessage: statusMessage ?? this.statusMessage,
      deployTimeline: deployTimeline ?? this.deployTimeline,
      activeRunId: clearActiveRunId ? null : (activeRunId ?? this.activeRunId),
      activeRepositoryFullName: clearActiveRepositoryFullName
          ? null
          : (activeRepositoryFullName ?? this.activeRepositoryFullName),
      activeServerId: clearActiveServerId
          ? null
          : (activeServerId ?? this.activeServerId),
      activeBranch: clearActiveBranch
          ? null
          : (activeBranch ?? this.activeBranch),
      activePrimaryDomain: clearActivePrimaryDomain
          ? null
          : (activePrimaryDomain ?? this.activePrimaryDomain),
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
      repositoryHostKeyConfirmation: clearRepositoryHostKeyConfirmation
          ? null
          : (repositoryHostKeyConfirmation ??
                this.repositoryHostKeyConfirmation),
      processReadinessStatus:
          processReadinessStatus ?? this.processReadinessStatus,
      publicHealth: publicHealth ?? this.publicHealth,
      // coverage-gate: project_deploy_failure_evidence_copy
      failureEvidence: clearFailureEvidence
          ? null
          : (failureEvidence ?? this.failureEvidence),
      suggestedNextStep: clearSuggestedNextStep
          ? null
          : (suggestedNextStep ?? this.suggestedNextStep),
      // end coverage-gate
    );
  }
}

class GitHubIntegrationState {
  const GitHubIntegrationState({
    this.connectStatus = GitHubConnectStatus.disconnected,
    this.deployStatus = GitHubDeployStatus.idle,
    this.statusMessage = 'Connect GitHub to pick a repository.',
    this.repositories = const [],
    this.selectedRepositoryFullName,
    this.authorizationUrl,
    this.lastAuthCode,
    this.authToken,
    this.deployTimeline = const [],
    this.activeDeployProjectId,
    this.activeDeployRepositoryFullName,
    this.selectedRepositoryFullNameByProjectId = const <String, String>{},
    this.projectDeployStates = const <String, GitHubProjectDeployState>{},
    this.failureEvidence,
    this.suggestedNextStep,
  });

  final GitHubConnectStatus connectStatus;
  final GitHubDeployStatus deployStatus;
  final String statusMessage;
  final List<GitHubRepository> repositories;
  final String? selectedRepositoryFullName;
  final String? authorizationUrl;
  final String? lastAuthCode;
  final String? authToken;
  final List<String> deployTimeline;
  final String? activeDeployProjectId;
  final String? activeDeployRepositoryFullName;
  final Map<String, String> selectedRepositoryFullNameByProjectId;
  final Map<String, GitHubProjectDeployState> projectDeployStates;
  final DeployFailureEvidence? failureEvidence;
  final String? suggestedNextStep;

  bool get isConnected => connectStatus == GitHubConnectStatus.connected;

  bool get canDeploy =>
      isConnected &&
      selectedRepositoryFullName != null &&
      !isDeployStatusRunning(deployStatus);

  GitHubProjectDeployState deployStateForProject(String? projectId) {
    final normalizedProjectId = projectId?.trim();
    if (normalizedProjectId != null && normalizedProjectId.isNotEmpty) {
      final scoped = projectDeployStates[normalizedProjectId];
      if (scoped != null) {
        return scoped;
      }
      return GitHubProjectDeployState(
        selectedRepositoryFullName:
            selectedRepositoryFullNameByProjectId[normalizedProjectId],
      );
    }
    return GitHubProjectDeployState(
      selectedRepositoryFullName: selectedRepositoryFullName,
      deployStatus: deployStatus,
      statusMessage: statusMessage,
      deployTimeline: deployTimeline,
      activeRepositoryFullName: activeDeployRepositoryFullName,
      failureEvidence: failureEvidence,
      suggestedNextStep: suggestedNextStep,
    );
  }

  String? selectedRepositoryForProject(String? projectId) {
    final scoped = deployStateForProject(
      projectId,
    ).selectedRepositoryFullName?.trim();
    if (scoped != null && scoped.isNotEmpty) {
      return scoped;
    }
    return selectedRepositoryFullName;
  }

  GitHubDeployStatus deployStatusForProject(String? projectId) {
    return deployStateForProject(projectId).deployStatus;
  }

  String statusMessageForProject(String? projectId) {
    return deployStateForProject(projectId).statusMessage;
  }

  List<String> deployTimelineForProject(String? projectId) {
    return deployStateForProject(projectId).deployTimeline;
  }

  // coverage-gate: project_deploy_failure_evidence_scope
  /// Returns evidence only from the requested project scope.
  DeployFailureEvidence? failureEvidenceForProject(String? projectId) {
    return deployStateForProject(projectId).failureEvidence;
  }

  /// Returns heuristic advice only from the requested project scope.
  String? suggestedNextStepForProject(String? projectId) {
    return deployStateForProject(projectId).suggestedNextStep;
  }
  // end coverage-gate

  bool isDeployRunningForProject(String? projectId) {
    return deployStateForProject(projectId).isRunning;
  }

  bool canDeployForProject(String? projectId) {
    final selectedRepository = selectedRepositoryForProject(projectId);
    final scopedDeployState = deployStateForProject(projectId);
    return isConnected &&
        selectedRepository != null &&
        !scopedDeployState.isRunning;
  }

  GitHubIntegrationState copyWith({
    GitHubConnectStatus? connectStatus,
    GitHubDeployStatus? deployStatus,
    String? statusMessage,
    List<GitHubRepository>? repositories,
    String? selectedRepositoryFullName,
    String? authorizationUrl,
    String? lastAuthCode,
    String? authToken,
    List<String>? deployTimeline,
    String? activeDeployProjectId,
    String? activeDeployRepositoryFullName,
    Map<String, String>? selectedRepositoryFullNameByProjectId,
    Map<String, GitHubProjectDeployState>? projectDeployStates,
    DeployFailureEvidence? failureEvidence,
    String? suggestedNextStep,
    bool clearSelectedRepository = false,
    bool clearAuthorizationUrl = false,
    bool clearLastAuthCode = false,
    bool clearAuthToken = false,
    bool clearActiveDeployProjectId = false,
    bool clearActiveDeployRepositoryFullName = false,
    bool clearFailureEvidence = false,
    bool clearSuggestedNextStep = false,
  }) {
    return GitHubIntegrationState(
      connectStatus: connectStatus ?? this.connectStatus,
      deployStatus: deployStatus ?? this.deployStatus,
      statusMessage: statusMessage ?? this.statusMessage,
      repositories: repositories ?? this.repositories,
      selectedRepositoryFullName: clearSelectedRepository
          ? null
          : (selectedRepositoryFullName ?? this.selectedRepositoryFullName),
      authorizationUrl: clearAuthorizationUrl
          ? null
          : (authorizationUrl ?? this.authorizationUrl),
      lastAuthCode: clearLastAuthCode
          ? null
          : (lastAuthCode ?? this.lastAuthCode),
      authToken: clearAuthToken ? null : (authToken ?? this.authToken),
      deployTimeline: deployTimeline ?? this.deployTimeline,
      activeDeployProjectId: clearActiveDeployProjectId
          ? null
          : (activeDeployProjectId ?? this.activeDeployProjectId),
      activeDeployRepositoryFullName: clearActiveDeployRepositoryFullName
          ? null
          : (activeDeployRepositoryFullName ??
                this.activeDeployRepositoryFullName),
      selectedRepositoryFullNameByProjectId:
          selectedRepositoryFullNameByProjectId ??
          this.selectedRepositoryFullNameByProjectId,
      projectDeployStates: projectDeployStates ?? this.projectDeployStates,
      // coverage-gate: integration_deploy_failure_evidence_copy
      failureEvidence: clearFailureEvidence
          ? null
          : (failureEvidence ?? this.failureEvidence),
      suggestedNextStep: clearSuggestedNextStep
          ? null
          : (suggestedNextStep ?? this.suggestedNextStep),
      // end coverage-gate
    );
  }
}

/// Whether [status] is one of the four in-flight deploy phases.
///
/// Public because both `GitHubIntegrationState.canDeploy` here and the
/// notifier that drives the deploy need the same answer, and two copies of a
/// four-way enum comparison is exactly how they drift apart.
bool isDeployStatusRunning(GitHubDeployStatus status) {
  return status == GitHubDeployStatus.generatingServerKey ||
      status == GitHubDeployStatus.registeringDeployKey ||
      status == GitHubDeployStatus.cloningRepository ||
      status == GitHubDeployStatus.buildingRelease;
}
