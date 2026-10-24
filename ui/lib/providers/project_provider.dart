import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../data/local/project_repository.dart';
import '../models/app_user_attribute.dart';
import '../models/railpack_runtime.dart';
import '../services/app_analytics_service.dart';
import '../utils/trim_or_null.dart';
import 'server_list_provider.dart';

export '../domain/project.dart';

class ProjectListNotifier extends Notifier<List<Project>> {
  bool _didInitialize = false;

  @override
  List<Project> build() {
    if (!_didInitialize) {
      _didInitialize = true;
      scheduleMicrotask(_loadFromDatabase);
    }
    return const [];
  }

  // coverage-gate: add_project
  Project addProject({
    String? serverId,
    required String name,
    required String type,
    required String gitUrl,
    required String primaryDomain,
    String? railpackProvider,
    String railpackBuildCommand = 'npm run build',
    String railpackRunCommand = 'npm run start',
    int appPort = 3000,
  }) {
    final normalizedName = name.trim();
    final slug = normalizedName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final id = 'project-$slug-${DateTime.now().millisecondsSinceEpoch}';
    final normalizedServerId = trimOrNull(serverId);

    final project = Project(
      id: id,
      serverId: normalizedServerId,
      name: normalizedName,
      type: type.trim(),
      gitUrl: gitUrl.trim(),
      primaryDomain: primaryDomain.trim(),
      domainRoutingMode: 'single_host',
      appPort: appPort,
      railpackBuildCommand: railpackBuildCommand.trim(),
      railpackRunCommand: railpackRunCommand.trim(),
      railpackProvider: normalizeRailpackProvider(railpackProvider),
      isActive: true,
    );

    state = [
      for (final existing in state)
        existing.copyWith(
          isActive: normalizedServerId == null
              ? false
              : existing.serverId == normalizedServerId
              ? false
              : existing.isActive,
        ),
      project,
    ];
    ref
        .read(appAnalyticsServiceProvider)
        .setUserAttribute(
          AppUserAttribute.projectCountBucket,
          analyticsBucketForCount(state.length),
        );
    final persist = ref.read(projectRepositoryProvider).createProject(project);
    unawaited(persist.catchError((_) {}));
    return project;
  }
  // end coverage-gate

  void updateDeploymentConfig({
    required String projectId,
    required String primaryDomain,
    required String domainRoutingMode,
    required String repositoryFullName,
    required String? appSubdirectory,
    required String deployBranch,
    required int appPort,
    bool? publicHealthCheckEnabled,
    String? publicHealthCheckPath,
    required String railpackNodeMode,
    String? railpackProvider,
    required String tlsChallengeMode,
    required String? tlsDnsProvider,
    required Map<String, String> tlsDnsCredentials,
    required bool sqliteStorageEnabled,
    String? sqliteVolumeName,
    String? sqliteMountPath,
    String? sqliteFileName,
    String? railpackBuildCommand,
    String? railpackRunCommand,
  }) {
    final normalizedDomainConfig = _normalizedDomainConfig(
      primaryDomain: primaryDomain,
      domainRoutingMode: domainRoutingMode,
    );
    final nextState = [
      for (final project in state)
        if (project.id == projectId)
          project.copyWith(
            primaryDomain: normalizedDomainConfig.primaryDomain,
            domainRoutingMode: normalizedDomainConfig.domainRoutingMode,
            repositoryFullName: repositoryFullName.trim(),
            appSubdirectory: _normalizedAppSubdirectory(appSubdirectory),
            deployBranch: deployBranch.trim(),
            appPort: appPort,
            publicHealthCheckEnabled: publicHealthCheckEnabled,
            publicHealthCheckPath: publicHealthCheckPath,
            railpackBuildCommand: railpackBuildCommand == null
                ? project.railpackBuildCommand
                : railpackBuildCommand.trim(),
            railpackRunCommand: railpackRunCommand == null
                ? project.railpackRunCommand
                : railpackRunCommand.trim(),
            railpackProvider: normalizeRailpackProvider(railpackProvider),
            railpackNodeMode: railpackNodeMode.trim().toLowerCase(),
            tlsChallengeMode: _normalizedTlsChallengeMode(tlsChallengeMode),
            tlsDnsProvider: tlsDnsProvider?.trim().toLowerCase(),
            tlsDnsCredentials: _normalizedTlsDnsCredentials(tlsDnsCredentials),
            sqliteStorageEnabled: sqliteStorageEnabled,
            sqliteVolumeName: _normalizedSqliteVolumeName(sqliteVolumeName),
            sqliteMountPath: _normalizedSqliteMountPath(sqliteMountPath),
            sqliteFileName: _normalizedSqliteFileName(sqliteFileName),
          )
        else
          project,
    ];
    state = nextState;

    final persist = ref
        .read(projectRepositoryProvider)
        .updateDeploymentConfig(
          projectId: projectId,
          primaryDomain: normalizedDomainConfig.primaryDomain,
          domainRoutingMode: normalizedDomainConfig.domainRoutingMode,
          repositoryFullName: repositoryFullName,
          appSubdirectory: appSubdirectory,
          deployBranch: deployBranch,
          appPort: appPort,
          publicHealthCheckEnabled: publicHealthCheckEnabled,
          publicHealthCheckPath: publicHealthCheckPath,
          railpackNodeMode: railpackNodeMode,
          railpackProvider: railpackProvider,
          tlsChallengeMode: tlsChallengeMode,
          tlsDnsProvider: tlsDnsProvider,
          tlsDnsCredentials: tlsDnsCredentials,
          sqliteStorageEnabled: sqliteStorageEnabled,
          sqliteVolumeName: sqliteVolumeName,
          sqliteMountPath: sqliteMountPath,
          sqliteFileName: sqliteFileName,
          railpackBuildCommand: railpackBuildCommand,
          railpackRunCommand: railpackRunCommand,
        );
    unawaited(persist.catchError((_) {}));
  }

  void updateRuntimeState({required String projectId, bool? appDisconnected}) {
    final nextState = [
      for (final project in state)
        if (project.id == projectId)
          project.copyWith(
            appDisconnected: appDisconnected ?? project.appDisconnected,
          )
        else
          project,
    ];
    state = nextState;

    final persist = ref
        .read(projectRepositoryProvider)
        .updateRuntimeState(
          projectId: projectId,
          appDisconnected: appDisconnected,
        );
    unawaited(persist.catchError((_) {}));
  }

  void updateDatabaseWiring({
    required String projectId,
    required bool injectPostgresEnv,
  }) {
    state = [
      for (final project in state)
        if (project.id == projectId)
          project.copyWith(injectPostgresEnv: injectPostgresEnv)
        else
          project,
    ];
    final persist = ref
        .read(projectRepositoryProvider)
        .updateDatabaseWiring(
          projectId: projectId,
          injectPostgresEnv: injectPostgresEnv,
        );
    unawaited(persist.catchError((_) {}));
  }

  void updateLastDeployState({
    required String projectId,
    required String commit,
    required DateTime deployedAt,
  }) {
    final normalizedCommit = commit.trim().isEmpty ? null : commit.trim();
    final nextState = [
      for (final project in state)
        if (project.id == projectId)
          project.copyWith(
            lastDeployCommit: normalizedCommit,
            lastDeployedAt: deployedAt,
          )
        else
          project,
    ];
    state = nextState;

    final persist = ref
        .read(projectRepositoryProvider)
        .updateLastDeployState(
          projectId: projectId,
          commit: normalizedCommit ?? '',
          deployedAt: deployedAt,
        );
    unawaited(persist.catchError((_) {}));
  }

  Future<String?> deleteProject(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return null;
    }

    final repository = ref.read(projectRepositoryProvider);
    final persistedNextActiveId = await repository
        .deleteProjectAndRelatedRecords(normalizedProjectId);

    if (!ref.mounted) {
      return persistedNextActiveId;
    }

    final remainingProjects = state
        .where((project) => project.id != normalizedProjectId)
        .toList(growable: false);

    String? nextActiveId = persistedNextActiveId;
    if (nextActiveId != null &&
        remainingProjects.every((project) => project.id != nextActiveId)) {
      nextActiveId = null;
    }
    nextActiveId ??= remainingProjects.isEmpty
        ? null
        : remainingProjects.first.id;

    state = [
      for (final project in remainingProjects)
        project.copyWith(
          isActive: nextActiveId != null && project.id == nextActiveId,
        ),
    ];
    ref
        .read(appAnalyticsServiceProvider)
        .setUserAttribute(
          AppUserAttribute.projectCountBucket,
          analyticsBucketForCount(remainingProjects.length),
        );
    return nextActiveId;
  }

  void hidePendingProject(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }
    final remaining = state
        .where((project) => project.id != normalizedProjectId)
        .toList(growable: false);
    var nextActiveId = '';
    for (final project in remaining) {
      if (project.isActive) {
        nextActiveId = project.id;
        break;
      }
    }
    if (nextActiveId.isEmpty && remaining.isNotEmpty) {
      nextActiveId = remaining.first.id;
    }
    state = [
      for (final project in remaining)
        project.copyWith(isActive: project.id == nextActiveId),
    ];
    ref
        .read(appAnalyticsServiceProvider)
        .setUserAttribute(
          AppUserAttribute.projectCountBucket,
          analyticsBucketForCount(remaining.length),
        );
  }

  Future<void> reloadFromDatabase() => _loadFromDatabase();

  Future<void> _loadFromDatabase() async {
    if (!ref.mounted) {
      return;
    }
    try {
      final repository = ref.read(projectRepositoryProvider);
      final projects = await repository.listProjects();
      if (!ref.mounted) {
        return;
      }
      state = projects;
    } on sqlite.SqliteException {
      if (!ref.mounted) {
        return;
      }
      state = const [];
    } on StateError {
      // A closed repository cannot restore persisted projects; keep the
      // session list empty instead of reviving stale state.
      if (!ref.mounted) {
        return;
      }
      state = const [];
    }
  }

  static String _normalizedTlsChallengeMode(String raw) {
    final normalized = raw.trim().toLowerCase();
    return normalized == 'dns' ? 'dns' : 'http';
  }

  static ({String primaryDomain, String domainRoutingMode})
  _normalizedDomainConfig({
    required String primaryDomain,
    required String domainRoutingMode,
  }) {
    final normalizedPrimaryDomain = primaryDomain.trim().toLowerCase();
    final normalizedMode = _normalizedDomainRoutingMode(domainRoutingMode);
    if (normalizedMode == 'single_host') {
      return (
        primaryDomain: normalizedPrimaryDomain,
        domainRoutingMode: normalizedMode,
      );
    }
    return (
      primaryDomain: _stripLeadingWww(normalizedPrimaryDomain),
      domainRoutingMode: normalizedMode,
    );
  }

  static String _normalizedDomainRoutingMode(String raw) {
    final normalized = raw.trim().toLowerCase();
    return switch (normalized) {
      'redirect_www_to_apex' => 'redirect_www_to_apex',
      'redirect_apex_to_www' => 'redirect_apex_to_www',
      _ => 'single_host',
    };
  }

  static String _stripLeadingWww(String value) {
    if (value.startsWith('www.') && value.length > 4) {
      return value.substring(4);
    }
    return value;
  }

  static Map<String, String> _normalizedTlsDnsCredentials(
    Map<String, String> raw,
  ) {
    final normalized = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key.trim().toLowerCase();
      final value = entry.value.trim();
      if (key.isEmpty || value.isEmpty) {
        continue;
      }
      normalized[key] = value;
    }
    return normalized;
  }

  static String? _normalizedAppSubdirectory(String? raw) {
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
    final segments = normalized.split('/');
    final cleaned = <String>[];
    for (final segment in segments) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') {
        return null;
      }
      cleaned.add(trimmed);
    }
    if (cleaned.isEmpty) {
      return null;
    }
    return cleaned.join('/');
  }

  static String? _normalizedSqliteVolumeName(String? raw) {
    if (raw == null) {
      return null;
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(trimmed)) {
      return null;
    }
    return trimmed;
  }

  static String? _normalizedSqliteMountPath(String? raw) {
    if (raw == null) {
      return null;
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('/')) {
      return null;
    }
    final parts = trimmed.split('/');
    final cleaned = <String>[];
    for (final part in parts) {
      final segment = part.trim();
      if (segment.isEmpty) {
        continue;
      }
      if (segment == '.' || segment == '..') {
        return null;
      }
      cleaned.add(segment);
    }
    if (cleaned.isEmpty) {
      return null;
    }
    return '/${cleaned.join('/')}';
  }

  static String? _normalizedSqliteFileName(String? raw) {
    if (raw == null) {
      return null;
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.contains('/')) {
      return null;
    }
    if (trimmed == '.' || trimmed == '..') {
      return null;
    }
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(trimmed)) {
      return null;
    }
    return trimmed;
  }
}

final projectListProvider =
    NotifierProvider<ProjectListNotifier, List<Project>>(
      ProjectListNotifier.new,
    );

// coverage-gate: selected_project_id_notifier
class SelectedProjectIdNotifier extends Notifier<String> {
  bool _didLoadActiveProject = false;
  String? _loadedServerId;

  @override
  String build() {
    final serverId = ref.watch(selectedServerIdProvider);
    if (!_didLoadActiveProject || _loadedServerId != serverId) {
      _didLoadActiveProject = true;
      _loadedServerId = serverId;
      scheduleMicrotask(() => _loadActiveProject(serverId));
    }
    return '';
  }

  void select(String id) {
    state = id;
    final persist = ref.read(projectRepositoryProvider).setActiveProject(id);
    unawaited(persist.catchError((_) {}));
  }

  void clear() {
    state = '';
  }

  Future<void> _loadActiveProject(String? serverId) async {
    if (!ref.mounted) {
      return;
    }
    try {
      final activeId = await ref
          .read(projectRepositoryProvider)
          .readActiveProjectId(serverId: serverId);
      if (!ref.mounted || activeId == null) {
        return;
      }
      state = activeId;
    } on sqlite.SqliteException {
      // No active-project preference can be restored from an unavailable
      // local database, so retain the current session selection.
      //
      // Deliberately empty. Both handlers used to end with
      // `if (!ref.mounted) { return; }`, which could not change anything:
      // the method returns at the closing brace either way. What it did do
      // was add a line no test could execute -- reaching it needs the
      // container disposed *between* the throw and the check -- which is
      // why this file sat one line short of the 100% its gate requires.
    } on StateError {
      // A disposed repository has no active-project preference to restore.
    }
  }
}
// end coverage-gate

final selectedProjectIdProvider =
    NotifierProvider<SelectedProjectIdNotifier, String>(
      SelectedProjectIdNotifier.new,
    );

// coverage-gate: selected_project_provider
final selectedProjectProvider = Provider<Project?>((ref) {
  final projects = ref.watch(projectListProvider);
  final selectedId = ref.watch(selectedProjectIdProvider);
  final selectedServerId = ref.watch(selectedServerIdProvider);
  final scopedProjects = _projectsForServer(projects, selectedServerId);

  if (scopedProjects.isEmpty) {
    return null;
  }

  for (final project in scopedProjects) {
    if (project.id == selectedId) {
      return project;
    }
  }

  for (final project in scopedProjects) {
    if (project.isActive) {
      return project;
    }
  }

  return scopedProjects.first;
});
// end coverage-gate

List<Project> _projectsForServer(List<Project> projects, String? serverId) {
  final normalizedServerId = trimOrNull(serverId);
  if (normalizedServerId == null) {
    return projects;
  }
  return projects
      .where((project) => project.serverId == normalizedServerId)
      .toList(growable: false);
}
