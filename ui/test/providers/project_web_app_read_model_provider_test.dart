import 'package:ui/data/local/app_deployment_history_repository.dart';
import 'package:ui/data/local/app_release_repository.dart';
import 'package:ui/models/app_public_health.dart';
import 'package:ui/providers/app_release_provider.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:ui/providers/project_web_app_read_model_provider.dart';
import 'package:ui/ui/system/container_runtime_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildProjectWebAppReadModel', () {
    test('reports no deployment from blank local state', () {
      final model = buildProjectWebAppReadModel(
        project: _project(primaryDomain: 'Not configured'),
        scope: const AppReleaseScopeState(),
      );

      expect(model.repo, 'Not selected');
      expect(model.branch, 'main');
      expect(model.commit, 'Not synced yet');
      expect(model.url, 'Not deployed yet');
      expect(
        model.health.effectiveStatus,
        ContainerRuntimeEffectiveStatus.unknown,
      );
      expect(model.deployState, ProjectWebAppReadDeployState.idle);
      expect(model.hasDeploymentRecord, isFalse);
      expect(model.lastDeployAt, isNull);
      expect(model.lastDuration, isNull);
      expect(model.latestDeployment, isNull);
    });

    test('uses project and runtime snapshot for last-known ready state', () {
      final deployedAt = DateTime.utc(2026, 1, 10, 12);
      final model = buildProjectWebAppReadModel(
        project: _project(
          primaryDomain: 'www.example.com',
          domainRoutingMode: 'redirect_www_to_apex',
          repositoryFullName: 'deploydash/example',
          lastDeployCommit: 'abc123',
          lastDeployedAt: deployedAt,
        ),
        scope: AppReleaseScopeState(
          runtimeSnapshot: _runtimeSnapshot(
            healthStatus: 'ready',
            publicHealthJson:
                '{"enabled":true,"status":"healthy","path":"/","http_status":200}',
          ),
        ),
        fallbackLastDuration: const Duration(seconds: 42),
      );

      expect(model.repo, 'deploydash/example');
      expect(model.commit, 'abc123');
      expect(model.url, 'https://example.com');
      expect(
        model.health.effectiveStatus,
        ContainerRuntimeEffectiveStatus.ready,
      );
      expect(model.deployState, ProjectWebAppReadDeployState.idle);
      expect(model.publicHealth.status, AppPublicHealthStatus.healthy);
      expect(model.publicHealth.httpStatus, 200);
      expect(model.hasDeploymentRecord, isTrue);
      expect(model.lastDeployAt, deployedAt);
      expect(model.lastDuration, const Duration(seconds: 42));
    });

    test('newer failed deployment overrides existing live release', () {
      final liveAt = DateTime.utc(2026, 1, 10, 12);
      final failedAt = DateTime.utc(2026, 1, 10, 13);
      final failedDeployment = _deployment(
        status: 'failed',
        deployedAt: failedAt,
        branch: 'buggy',
        commit: 'badc0de',
        durationSeconds: 17,
      );
      final model = buildProjectWebAppReadModel(
        project: _project(repositoryFullName: null),
        scope: AppReleaseScopeState(
          releases: [
            _release(liveAt: liveAt, branch: 'main', commitSha: 'goodc0de'),
          ],
          runtimeSnapshot: _runtimeSnapshot(healthStatus: 'ready'),
        ),
        latestDeployment: failedDeployment,
        fallbackRepo: 'fallback/repo',
      );

      expect(model.repo, 'fallback/repo');
      expect(model.branch, 'buggy');
      expect(model.commit, 'badc0de');
      expect(
        model.health.effectiveStatus,
        ContainerRuntimeEffectiveStatus.unhealthy,
      );
      expect(
        model.deployState,
        ProjectWebAppReadDeployState.latestDeploymentFailed,
      );
      expect(model.hasDeploymentRecord, isTrue);
      expect(model.lastDeployAt, failedAt);
      expect(model.lastDuration, const Duration(seconds: 17));
      expect(model.latestDeployment, same(failedDeployment));
    });

    test('older failed deployment does not replace newer live release', () {
      final failedAt = DateTime.utc(2026, 1, 10, 12);
      final liveAt = DateTime.utc(2026, 1, 10, 13);
      final model = buildProjectWebAppReadModel(
        project: _project(),
        scope: AppReleaseScopeState(
          releases: [
            _release(liveAt: liveAt, branch: 'stable', commitSha: 'goodc0de'),
          ],
        ),
        latestDeployment: _deployment(status: 'failed', deployedAt: failedAt),
      );

      expect(model.branch, 'stable');
      expect(model.commit, 'goodc0de');
      expect(
        model.health.effectiveStatus,
        ContainerRuntimeEffectiveStatus.unknown,
      );
      expect(model.deployState, ProjectWebAppReadDeployState.idle);
      expect(model.lastDeployAt, liveAt);
      expect(model.publicHealth.status, AppPublicHealthStatus.unknown);
    });

    test('uses live release details and canonical apex-to-www URL', () {
      final createdAtRemote = DateTime.utc(2026, 1, 10, 12);
      final model = buildProjectWebAppReadModel(
        project: _project(
          primaryDomain: 'example.com',
          domainRoutingMode: 'redirect_apex_to_www',
        ),
        scope: AppReleaseScopeState(
          releases: [
            _release(
              liveAt: null,
              createdAtRemote: createdAtRemote,
              branch: 'release',
              commitSha: 'livecommit',
            ),
          ],
          runtimeSnapshot: _runtimeSnapshot(healthStatus: 'checking'),
        ),
      );

      expect(model.branch, 'release');
      expect(model.commit, 'livecommit');
      expect(model.url, 'https://www.example.com');
      expect(
        model.health.effectiveStatus,
        ContainerRuntimeEffectiveStatus.starting,
      );
      expect(model.lastDeployAt, createdAtRemote);
    });

    test('chosen commit and branch show verbatim, padding included', () {
      final model = buildProjectWebAppReadModel(
        project: _project(deployBranch: 'prod', lastDeployCommit: 'abc123'),
        scope: AppReleaseScopeState(
          releases: [_release(branch: '  main  ', commitSha: '  def456  ')],
        ),
      );

      // Trim decides presence; what is shown is the stored value as-is.
      expect(model.branch, '  main  ');
      expect(model.commit, '  def456  ');
    });

    test('blank live values fall through to project values', () {
      final model = buildProjectWebAppReadModel(
        project: _project(deployBranch: 'prod', lastDeployCommit: 'abc123'),
        scope: AppReleaseScopeState(
          releases: [_release(branch: '   ', commitSha: '')],
        ),
      );

      expect(model.branch, 'prod');
      expect(model.commit, 'abc123');
    });

    test('blank commit fallback shows blank, not the default', () {
      final model = buildProjectWebAppReadModel(
        project: _project(),
        scope: const AppReleaseScopeState(),
        fallbackCommit: '   ',
      );

      // `fallbackCommit ?? 'Not synced yet'` uses a blank-but-non-null
      // fallback verbatim; the collapse must keep that (D-83 sharp edge).
      expect(model.commit, '   ');
      expect(model.hasDeploymentRecord, isFalse);
    });

    test('present commit fallback wins over the default', () {
      final model = buildProjectWebAppReadModel(
        project: _project(),
        scope: const AppReleaseScopeState(),
        fallbackCommit: 'fb123',
      );

      expect(model.commit, 'fb123');
      expect(model.hasDeploymentRecord, isTrue);
    });

    test('blank deploy branch shows blank', () {
      final model = buildProjectWebAppReadModel(
        project: _project(deployBranch: '   '),
        scope: const AppReleaseScopeState(),
      );

      expect(model.branch, '   ');
    });
  });

  test('normalizes runtime health snapshots', () {
    expect(
      projectWebAppHealthFromRuntimeSnapshot(
        _runtimeSnapshot(healthStatus: 'healthy'),
      ).effectiveStatus,
      ContainerRuntimeEffectiveStatus.ready,
    );
    expect(
      projectWebAppHealthFromRuntimeSnapshot(
        _runtimeSnapshot(healthStatus: 'warning'),
      ).effectiveStatus,
      ContainerRuntimeEffectiveStatus.unhealthy,
    );
    expect(
      projectWebAppHealthFromRuntimeSnapshot(
        _runtimeSnapshot(healthStatus: 'unhealthy'),
      ).effectiveStatus,
      ContainerRuntimeEffectiveStatus.unhealthy,
    );
    expect(
      projectWebAppHealthFromRuntimeSnapshot(
        _runtimeSnapshot(healthStatus: 'updating'),
      ).effectiveStatus,
      ContainerRuntimeEffectiveStatus.starting,
    );
    expect(
      projectWebAppHealthFromRuntimeSnapshot(
        _runtimeSnapshot(healthStatus: 'unexpected'),
      ).effectiveStatus,
      ContainerRuntimeEffectiveStatus.unknown,
    );
    expect(
      projectWebAppHealthFromRuntimeSnapshot(null).effectiveStatus,
      ContainerRuntimeEffectiveStatus.unknown,
    );
  });

  test('normalizes persisted public health snapshots', () {
    final unhealthy = projectWebAppPublicHealthFromRuntimeSnapshot(
      _runtimeSnapshot(
        publicHealthJson:
            '{"enabled":true,"status":"unhealthy","path":"/","http_status":500}',
      ),
    );

    expect(unhealthy.status, AppPublicHealthStatus.unhealthy);
    expect(unhealthy.httpStatus, 500);
    expect(
      projectWebAppPublicHealthFromRuntimeSnapshot(null).status,
      AppPublicHealthStatus.unknown,
    );
  });

  test('normalizes repository and domain helpers', () {
    expect(
      projectWebAppRepositoryLabel(
        project: _project(repositoryFullName: ' deploydash/app '),
        fallbackRepo: 'fallback/repo',
      ),
      'deploydash/app',
    );
    expect(
      projectWebAppRepositoryLabel(
        project: _project(repositoryFullName: null),
        fallbackRepo: ' fallback/repo ',
      ),
      'fallback/repo',
    );
    expect(
      projectWebAppRepositoryLabel(
        project: _project(repositoryFullName: null),
        fallbackRepo: ' ',
      ),
      'Not selected',
    );
    expect(isValidProjectWebAppDomain(''), isFalse);
    expect(isValidProjectWebAppDomain('Not configured'), isFalse);
    expect(isValidProjectWebAppDomain('invalid'), isFalse);
    expect(isValidProjectWebAppDomain('Example.COM'), isTrue);
    expect(
      canonicalProjectWebAppDomain(
        primaryDomain: 'App.Example.COM',
        domainRoutingMode: 'single_host',
      ),
      'app.example.com',
    );
    expect(
      canonicalProjectWebAppDomain(
        primaryDomain: 'example.com',
        domainRoutingMode: 'unexpected',
      ),
      'example.com',
    );
  });
}

Project _project({
  String primaryDomain = 'app.example.com',
  String domainRoutingMode = 'single_host',
  String? repositoryFullName,
  String deployBranch = 'main',
  String? lastDeployCommit,
  DateTime? lastDeployedAt,
}) {
  return Project(
    id: 'project-web',
    serverId: 'server-one',
    name: 'Web app',
    type: 'web_app',
    gitUrl: '',
    primaryDomain: primaryDomain,
    domainRoutingMode: domainRoutingMode,
    repositoryFullName: repositoryFullName,
    deployBranch: deployBranch,
    lastDeployCommit: lastDeployCommit,
    lastDeployedAt: lastDeployedAt,
  );
}

AppReleaseRecord _release({
  DateTime? liveAt,
  DateTime? createdAtRemote,
  String branch = 'main',
  String? commitSha = 'abc123',
}) {
  final now = DateTime.utc(2026, 1, 1);
  return AppReleaseRecord(
    id: 'release-row',
    projectId: 'project-web',
    serverId: 'server-one',
    releaseId: 'release-one',
    status: 'live',
    branch: branch,
    commitSha: commitSha,
    createdAtRemote: createdAtRemote,
    liveAt: liveAt,
    createdAt: now,
    updatedAt: now,
  );
}

AppDeploymentHistoryRecord _deployment({
  required String status,
  DateTime? deployedAt,
  String branch = 'main',
  String commit = 'abc123',
  int durationSeconds = 5,
}) {
  final now = deployedAt ?? DateTime.utc(2026, 1, 1);
  return AppDeploymentHistoryRecord(
    id: 1,
    projectId: 'project-web',
    status: status,
    releaseId: 'release-one',
    deploymentKind: 'deploy',
    rollbackFromReleaseId: null,
    deployedAt: now,
    durationSeconds: durationSeconds,
    actor: 'local-user',
    branch: branch,
    commit: commit,
    createdAt: now,
  );
}

AppRuntimeSnapshotRecord _runtimeSnapshot({
  String? healthStatus,
  String? publicHealthJson,
}) {
  final now = DateTime.utc(2026, 1, 1);
  return AppRuntimeSnapshotRecord(
    projectId: 'project-web',
    serverId: 'server-one',
    healthStatus: healthStatus,
    publicHealthJson: publicHealthJson,
    updatedAt: now,
  );
}
