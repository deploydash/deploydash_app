import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_release_repository.dart';
import '../models/workspace_scope.dart';

class AppReleaseScopeState {
  const AppReleaseScopeState({
    this.releases = const <AppReleaseRecord>[],
    this.runtimeSnapshot,
    this.workerRuntimeSnapshot,
    this.importState,
  });

  final List<AppReleaseRecord> releases;
  final AppRuntimeSnapshotRecord? runtimeSnapshot;
  final WorkerRuntimeSnapshotRecord? workerRuntimeSnapshot;
  final ProjectWorkspaceImportStateRecord? importState;

  AppReleaseRecord? get liveRelease {
    for (final release in releases) {
      if (release.isLive) {
        return release;
      }
    }
    return null;
  }

  List<AppReleaseRecord> get retainedReleases {
    return releases
        .where((release) => release.status == 'retained')
        .toList(growable: false);
  }
}

class AppReleaseState {
  const AppReleaseState({this.scopes = const <String, AppReleaseScopeState>{}});

  final Map<String, AppReleaseScopeState> scopes;

  AppReleaseScopeState scopeFor({
    required String projectId,
    required String serverId,
  }) {
    final key = _scopeKey(projectId: projectId, serverId: serverId);
    if (key == null) {
      return const AppReleaseScopeState();
    }
    return scopes[key] ?? const AppReleaseScopeState();
  }

  AppReleaseState copyWith({Map<String, AppReleaseScopeState>? scopes}) {
    return AppReleaseState(scopes: scopes ?? this.scopes);
  }

  static String? _scopeKey({
    required String projectId,
    required String serverId,
  }) {
    return WorkspaceScope.fromIds(
      projectId: projectId,
      serverId: serverId,
    )?.cacheKey;
  }
}

class AppReleaseNotifier extends Notifier<AppReleaseState> {
  @override
  AppReleaseState build() => const AppReleaseState();

  Future<void> loadScope({
    required String projectId,
    required String serverId,
  }) async {
    final scopeKey = AppReleaseState._scopeKey(
      projectId: projectId,
      serverId: serverId,
    );
    if (scopeKey == null) {
      return;
    }
    final repository = ref.read(appReleaseRepositoryProvider);
    final releases = await repository.listReleasesForScope(
      projectId: projectId,
      serverId: serverId,
    );
    final runtimeSnapshot = await repository.readRuntimeSnapshot(
      projectId: projectId,
      serverId: serverId,
    );
    final workerRuntimeSnapshot = await repository.readWorkerRuntimeSnapshot(
      projectId: projectId,
      serverId: serverId,
    );
    final importState = await repository.readImportState(
      projectId: projectId,
      serverId: serverId,
    );
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      scopes: {
        ...state.scopes,
        scopeKey: AppReleaseScopeState(
          releases: releases,
          runtimeSnapshot: runtimeSnapshot,
          workerRuntimeSnapshot: workerRuntimeSnapshot,
          importState: importState,
        ),
      },
    );
  }

  Future<void> replaceReleases({
    required String projectId,
    required String serverId,
    required List<AppReleaseRecord> releases,
  }) async {
    await ref
        .read(appReleaseRepositoryProvider)
        .replaceReleasesForScope(
          projectId: projectId,
          serverId: serverId,
          releases: releases,
        );
    await loadScope(projectId: projectId, serverId: serverId);
  }

  Future<void> upsertRelease(AppReleaseRecord release) async {
    await ref.read(appReleaseRepositoryProvider).upsertRelease(release);
    await loadScope(projectId: release.projectId, serverId: release.serverId);
  }

  // coverage-gate: upsert_runtime_snapshot
  Future<void> upsertRuntimeSnapshot(AppRuntimeSnapshotRecord snapshot) async {
    final repository = ref.read(appReleaseRepositoryProvider);
    final existing = await repository.readRuntimeSnapshot(
      projectId: snapshot.projectId,
      serverId: snapshot.serverId,
    );
    await repository.upsertRuntimeSnapshot(
      AppRuntimeSnapshotRecord(
        projectId: snapshot.projectId,
        serverId: snapshot.serverId,
        resourceUsageJson:
            snapshot.resourceUsageJson ?? existing?.resourceUsageJson,
        healthStatus: snapshot.healthStatus ?? existing?.healthStatus,
        publicHealthJson:
            snapshot.publicHealthJson ?? existing?.publicHealthJson,
        healthCheckedAt: snapshot.healthCheckedAt ?? existing?.healthCheckedAt,
        resourceCheckedAt:
            snapshot.resourceCheckedAt ?? existing?.resourceCheckedAt,
        updatedAt: snapshot.updatedAt,
      ),
    );
    await loadScope(projectId: snapshot.projectId, serverId: snapshot.serverId);
  }

  // end coverage-gate
  Future<void> upsertWorkerRuntimeSnapshot(
    WorkerRuntimeSnapshotRecord snapshot,
  ) async {
    await ref
        .read(appReleaseRepositoryProvider)
        .upsertWorkerRuntimeSnapshot(snapshot);
    await loadScope(projectId: snapshot.projectId, serverId: snapshot.serverId);
  }

  Future<void> updateImportState({
    required String projectId,
    required String serverId,
    required String status,
    DateTime? startedAt,
    DateTime? finishedAt,
    String? errorMessage,
  }) async {
    await ref
        .read(appReleaseRepositoryProvider)
        .upsertImportState(
          projectId: projectId,
          serverId: serverId,
          status: status,
          startedAt: startedAt,
          finishedAt: finishedAt,
          errorMessage: errorMessage,
        );
    await loadScope(projectId: projectId, serverId: serverId);
  }
}

final appReleaseProvider =
    NotifierProvider<AppReleaseNotifier, AppReleaseState>(
      AppReleaseNotifier.new,
    );
