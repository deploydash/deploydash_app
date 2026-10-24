import 'app_release_provider.dart';
import 'project_provider.dart';
import '../data/local/app_deployment_history_repository.dart';
import '../data/local/app_release_repository.dart';
import '../models/app_public_health.dart';
import '../models/container_runtime_status.dart';
import '../utils/first_present_value.dart';

enum ProjectWebAppReadDeployState { idle, latestDeploymentFailed }

class ProjectWebAppReadModel {
  const ProjectWebAppReadModel({
    required this.repo,
    required this.branch,
    required this.commit,
    required this.url,
    required this.health,
    required this.publicHealth,
    required this.deployState,
    required this.hasDeploymentRecord,
    this.lastDeployAt,
    this.lastDuration,
    this.latestDeployment,
  });

  final String repo;
  final String branch;
  final String commit;
  final String url;
  final ContainerRuntimeStatus health;
  final AppPublicHealthSnapshot publicHealth;
  final ProjectWebAppReadDeployState deployState;
  final bool hasDeploymentRecord;
  final DateTime? lastDeployAt;
  final Duration? lastDuration;
  final AppDeploymentHistoryRecord? latestDeployment;
}

ProjectWebAppReadModel buildProjectWebAppReadModel({
  required Project project,
  required AppReleaseScopeState scope,
  AppDeploymentHistoryRecord? latestDeployment,
  String? fallbackRepo,
  String? fallbackCommit,
  Duration? fallbackLastDuration,
}) {
  final liveRelease = scope.liveRelease;
  final lastSuccessfulAt =
      liveRelease?.liveAt ??
      liveRelease?.createdAtRemote ??
      project.lastDeployedAt;
  final latestFailedDeployment =
      latestDeployment != null &&
      latestDeployment.status == 'failed' &&
      (lastSuccessfulAt == null ||
          latestDeployment.deployedAt.isAfter(lastSuccessfulAt));
  final runtimeHealth = projectWebAppHealthFromRuntimeSnapshot(
    scope.runtimeSnapshot,
  );
  final health = latestFailedDeployment
      ? ContainerRuntimeStatus.fromStoredHealthStatus('unhealthy')
      : runtimeHealth;
  final publicHealth = projectWebAppPublicHealthFromRuntimeSnapshot(
    scope.runtimeSnapshot,
  );
  // Precedence inputs, hoisted for readability. Each counts as present
  // only when non-blank, and is used untrimmed once chosen.
  final liveCommitSha = liveRelease?.commitSha;
  final projectDeployCommit = project.lastDeployCommit;
  final liveBranch = liveRelease?.branch;
  // Why the fallbacks sit OUTSIDE the helper (D-83 sharp edge): today a
  // blank-but-non-null fallbackCommit shows blank and a blank deployBranch
  // shows blank; listing them as precedence values would skip them instead.
  final commit = latestFailedDeployment
      ? latestDeployment.commit
      : firstPresentValue([
          liveCommitSha,
          projectDeployCommit,
        ], fallbackCommit ?? 'Not synced yet');
  final branch = latestFailedDeployment
      ? latestDeployment.branch
      : firstPresentValue([liveBranch], project.deployBranch);
  final lastDeployAt = latestFailedDeployment
      ? latestDeployment.deployedAt
      : (liveRelease?.liveAt ??
            liveRelease?.createdAtRemote ??
            project.lastDeployedAt);
  final primaryDomain = project.primaryDomain.trim();
  final url = isValidProjectWebAppDomain(primaryDomain)
      ? 'https://${canonicalProjectWebAppDomain(primaryDomain: primaryDomain, domainRoutingMode: project.domainRoutingMode)}'
      : 'Not deployed yet';
  final hasDeploymentRecord =
      lastDeployAt != null ||
      (commit.trim().isNotEmpty && commit != 'Not synced yet') ||
      latestDeployment != null;

  return ProjectWebAppReadModel(
    repo: projectWebAppRepositoryLabel(
      project: project,
      fallbackRepo: fallbackRepo,
    ),
    branch: branch,
    commit: commit,
    url: url,
    health: health,
    publicHealth: publicHealth,
    deployState: latestFailedDeployment
        ? ProjectWebAppReadDeployState.latestDeploymentFailed
        : ProjectWebAppReadDeployState.idle,
    hasDeploymentRecord: hasDeploymentRecord,
    lastDeployAt: lastDeployAt,
    lastDuration: latestDeployment == null
        ? fallbackLastDuration
        : Duration(seconds: latestDeployment.durationSeconds),
    latestDeployment: latestDeployment,
  );
}

AppPublicHealthSnapshot projectWebAppPublicHealthFromRuntimeSnapshot(
  AppRuntimeSnapshotRecord? snapshot,
) {
  return AppPublicHealthSnapshot.fromJson(snapshot?.publicHealthJson);
}

ContainerRuntimeStatus projectWebAppHealthFromRuntimeSnapshot(
  AppRuntimeSnapshotRecord? snapshot,
) {
  return ContainerRuntimeStatus.fromStoredHealthStatus(snapshot?.healthStatus);
}

String projectWebAppRepositoryLabel({
  required Project project,
  String? fallbackRepo,
}) {
  final projectRepository = project.repositoryFullName?.trim();
  if (projectRepository != null && projectRepository.isNotEmpty) {
    return projectRepository;
  }
  final fallback = fallbackRepo?.trim();
  if (fallback != null && fallback.isNotEmpty) {
    return fallback;
  }
  return 'Not selected';
}

bool isValidProjectWebAppDomain(String value) {
  final candidate = value.trim().toLowerCase();
  if (candidate.isEmpty || candidate == 'not configured') {
    return false;
  }
  final fqdn = RegExp(
    r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$',
  );
  return fqdn.hasMatch(candidate);
}

String canonicalProjectWebAppDomain({
  required String primaryDomain,
  required String domainRoutingMode,
}) {
  final normalizedDomain = primaryDomain.trim().toLowerCase();
  final normalizedMode = _normalizedProjectWebAppDomainRoutingMode(
    domainRoutingMode,
  );
  return switch (normalizedMode) {
    'redirect_apex_to_www' =>
      'www.${_stripLeadingWwwForProjectWebApp(normalizedDomain)}',
    'redirect_www_to_apex' => _stripLeadingWwwForProjectWebApp(
      normalizedDomain,
    ),
    _ => normalizedDomain,
  };
}

String _normalizedProjectWebAppDomainRoutingMode(String value) {
  return switch (value.trim()) {
    'redirect_www_to_apex' => 'redirect_www_to_apex',
    'redirect_apex_to_www' => 'redirect_apex_to_www',
    _ => 'single_host',
  };
}

String _stripLeadingWwwForProjectWebApp(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.startsWith('www.')) {
    return normalized.substring(4);
  }
  return normalized;
}
