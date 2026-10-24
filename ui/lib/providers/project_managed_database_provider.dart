import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/project_managed_database_repository.dart';
import '../models/workspace_scope.dart';

class ProjectManagedDatabaseScopeState {
  const ProjectManagedDatabaseScopeState({
    this.databases = const <ProjectManagedDatabaseRecord>[],
    this.users = const <ProjectManagedDatabaseUserRecord>[],
  });

  final List<ProjectManagedDatabaseRecord> databases;
  final List<ProjectManagedDatabaseUserRecord> users;
}

class ProjectManagedDatabaseState {
  const ProjectManagedDatabaseState({
    this.scopes = const <String, ProjectManagedDatabaseScopeState>{},
  });

  final Map<String, ProjectManagedDatabaseScopeState> scopes;

  ProjectManagedDatabaseScopeState scopeFor({
    required String projectId,
    required String serverId,
  }) {
    final key = _scopeKey(projectId: projectId, serverId: serverId);
    if (key == null) {
      return const ProjectManagedDatabaseScopeState();
    }
    return scopes[key] ?? const ProjectManagedDatabaseScopeState();
  }

  ProjectManagedDatabaseState copyWith({
    Map<String, ProjectManagedDatabaseScopeState>? scopes,
  }) {
    return ProjectManagedDatabaseState(scopes: scopes ?? this.scopes);
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

class ProjectDatabaseActionFeedback {
  const ProjectDatabaseActionFeedback({
    required this.projectId,
    required this.serverId,
    required this.message,
    this.details,
    this.title,
  });

  final String projectId;
  final String serverId;
  final String message;
  final String? details;
  final String? title;
}

class ProjectDatabaseActionFeedbackState {
  const ProjectDatabaseActionFeedbackState({
    this.feedbackByScope = const <String, ProjectDatabaseActionFeedback>{},
  });

  final Map<String, ProjectDatabaseActionFeedback> feedbackByScope;

  ProjectDatabaseActionFeedback? forScope({
    required String projectId,
    required String serverId,
  }) {
    final scope = WorkspaceScope.fromIds(
      projectId: projectId,
      serverId: serverId,
    );
    if (scope == null) {
      return null;
    }
    return feedbackByScope[scope.cacheKey];
  }
}

class ProjectDatabaseActionFeedbackNotifier
    extends Notifier<ProjectDatabaseActionFeedbackState> {
  @override
  ProjectDatabaseActionFeedbackState build() =>
      const ProjectDatabaseActionFeedbackState();

  void clear({required String projectId, required String serverId}) {
    final scope = WorkspaceScope.fromIds(
      projectId: projectId,
      serverId: serverId,
    );
    if (scope == null || !state.feedbackByScope.containsKey(scope.cacheKey)) {
      return;
    }
    final nextFeedback = Map<String, ProjectDatabaseActionFeedback>.from(
      state.feedbackByScope,
    )..remove(scope.cacheKey);
    state = ProjectDatabaseActionFeedbackState(feedbackByScope: nextFeedback);
  }

  void showFailure({
    required String projectId,
    required String serverId,
    required String message,
    String? details,
    String? title,
  }) {
    final scope = WorkspaceScope.fromIds(
      projectId: projectId,
      serverId: serverId,
    );
    final normalizedMessage = message.trim();
    if (scope == null || normalizedMessage.isEmpty) {
      return;
    }
    final normalizedDetails = details?.trim();
    final normalizedTitle = title?.trim();
    state = ProjectDatabaseActionFeedbackState(
      feedbackByScope: {
        ...state.feedbackByScope,
        scope.cacheKey: ProjectDatabaseActionFeedback(
          projectId: scope.projectId,
          serverId: scope.serverId,
          message: normalizedMessage,
          details: normalizedDetails == null || normalizedDetails.isEmpty
              ? null
              : normalizedDetails,
          title: normalizedTitle == null || normalizedTitle.isEmpty
              ? null
              : normalizedTitle,
        ),
      },
    );
  }
}

class ProjectManagedDatabaseNotifier
    extends Notifier<ProjectManagedDatabaseState> {
  @override
  ProjectManagedDatabaseState build() => const ProjectManagedDatabaseState();

  Future<void> loadScope({
    required String projectId,
    required String serverId,
  }) async {
    final scopeKey = ProjectManagedDatabaseState._scopeKey(
      projectId: projectId,
      serverId: serverId,
    );
    if (scopeKey == null) {
      return;
    }
    final repository = ref.read(projectManagedDatabaseRepositoryProvider);
    final databases = await repository.listDatabasesForScope(
      projectId: projectId,
      serverId: serverId,
    );
    final users = await repository.listUsersForScope(
      projectId: projectId,
      serverId: serverId,
    );
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      scopes: {
        ...state.scopes,
        scopeKey: ProjectManagedDatabaseScopeState(
          databases: databases,
          users: users,
        ),
      },
    );
  }

  Future<void> replaceScope({
    required String projectId,
    required String serverId,
    required List<ProjectManagedDatabaseRecord> databases,
    required List<ProjectManagedDatabaseUserRecord> users,
  }) async {
    await ref
        .read(projectManagedDatabaseRepositoryProvider)
        .replaceScope(
          projectId: projectId,
          serverId: serverId,
          databases: databases,
          users: users,
        );
    await loadScope(projectId: projectId, serverId: serverId);
  }

  Future<void> upsertDatabase(ProjectManagedDatabaseRecord database) async {
    await ref
        .read(projectManagedDatabaseRepositoryProvider)
        .upsertDatabase(database);
    await loadScope(projectId: database.projectId, serverId: database.serverId);
  }

  Future<void> upsertUser(ProjectManagedDatabaseUserRecord user) async {
    await ref.read(projectManagedDatabaseRepositoryProvider).upsertUser(user);
    await loadScope(projectId: user.projectId, serverId: user.serverId);
  }

  Future<void> deleteDatabase({
    required String projectId,
    required String serverId,
    required String databaseName,
  }) async {
    await ref
        .read(projectManagedDatabaseRepositoryProvider)
        .deleteDatabase(
          projectId: projectId,
          serverId: serverId,
          databaseName: databaseName,
        );
    await loadScope(projectId: projectId, serverId: serverId);
  }

  Future<void> deleteUser({
    required String projectId,
    required String serverId,
    required String databaseName,
    required String username,
  }) async {
    await ref
        .read(projectManagedDatabaseRepositoryProvider)
        .deleteUser(
          projectId: projectId,
          serverId: serverId,
          databaseName: databaseName,
          username: username,
        );
    await loadScope(projectId: projectId, serverId: serverId);
  }
}

final projectManagedDatabaseProvider =
    NotifierProvider<
      ProjectManagedDatabaseNotifier,
      ProjectManagedDatabaseState
    >(ProjectManagedDatabaseNotifier.new);

final projectDatabaseActionFeedbackProvider =
    NotifierProvider<
      ProjectDatabaseActionFeedbackNotifier,
      ProjectDatabaseActionFeedbackState
    >(ProjectDatabaseActionFeedbackNotifier.new);
