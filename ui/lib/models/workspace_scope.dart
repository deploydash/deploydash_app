import '../domain/project.dart';
import '../domain/server.dart';
import 'run_guard.dart';

/// The project-and-server pair a workspace screen is currently showing.
///
/// Both halves are needed: a project id alone does not say which machine the
/// answer came from, and the same project can be looked at while the selected
/// server changes underneath. Passing the pair as one value is what lets a
/// caller ask "is this still the workspace I fetched for?" in a single check.
class WorkspaceScope {
  /// Creates a scope from an already-validated pair. Prefer [fromIds] or
  /// [fromSelection], which reject the blank ids this constructor accepts.
  const WorkspaceScope({required this.projectId, required this.serverId});

  /// The project being viewed.
  final String projectId;

  /// The server the project's resources live on.
  final String serverId;

  /// The pair as one string, for equality checks and log lines.
  ///
  /// Two scopes are the same workspace exactly when their keys match; the
  /// class deliberately has no `operator ==`, so compare keys rather than
  /// instances.
  String get key => '$projectId::$serverId';

  /// The same string as [key], named for its use as a cache-map key.
  ///
  /// Kept as a separate getter so a map keyed by workspace reads as
  /// `byScope[scope.cacheKey]` at the call site. The two must stay equal: a
  /// cache keyed differently from the identity check would survive a scope
  /// change that [isCurrent] rejects.
  String get cacheKey => key;

  /// Whether this scope is exactly the given project and server.
  bool matches({required String projectId, required String serverId}) {
    return this.projectId == projectId && this.serverId == serverId;
  }

  /// A scope for the given ids, or null when either is missing or blank.
  ///
  /// Null is the normal state, not an error: it is what a workspace has
  /// before a project and server are both selected, and every scope-aware
  /// helper treats it as "nothing is current".
  static WorkspaceScope? fromIds({String? projectId, String? serverId}) {
    final normalizedProjectId = projectId?.trim();
    final normalizedServerId = serverId?.trim();
    if (normalizedProjectId == null ||
        normalizedProjectId.isEmpty ||
        normalizedServerId == null ||
        normalizedServerId.isEmpty) {
      return null;
    }
    return WorkspaceScope(
      projectId: normalizedProjectId,
      serverId: normalizedServerId,
    );
  }

  /// A scope for the current selection, or null when either side is unset.
  static WorkspaceScope? fromSelection(Project? project, Server? server) {
    return fromIds(projectId: project?.id, serverId: server?.id);
  }
}

/// A token for one in-flight workspace fetch, checked before its result is
/// written into state.
///
/// The workspace-shaped counterpart to [ScopedRunContext]: it keys on a whole
/// [WorkspaceScope] rather than a single id, and adds a [discriminator] for
/// the case where the scope is unchanged but what was asked for is not.
class WorkspaceRunContext {
  /// Creates a run token for [scope] at [epoch].
  const WorkspaceRunContext({
    required this.scope,
    required this.epoch,
    required this.runId,
    this.discriminator = '',
    this.metadata = const <String, Object?>{},
  });

  /// The workspace this run was started for.
  final WorkspaceScope scope;

  /// Monotonic counter owned by the caller; a run is stale once a later epoch
  /// exists.
  final int epoch;

  /// Human-readable identity for logs, unique per run.
  final String runId;

  /// What was asked for within the scope -- a selected database, a release id.
  ///
  /// Empty means "the scope's default request". A run with a discriminator is
  /// stale once the user selects something else, even though the scope and
  /// epoch are unchanged.
  final String discriminator;

  /// Caller-supplied detail carried alongside the run.
  final Map<String, Object?> metadata;

  /// Whether this run's result is still the one the workspace is waiting for.
  ///
  /// False when nothing is selected any more, when the scope or epoch has
  /// moved on, or when [currentDiscriminator] is given and differs. Passing
  /// null for [currentDiscriminator] skips that last check, which is what a
  /// caller wants when the fetch was not selection-specific.
  bool isCurrent({
    required WorkspaceScope? currentScope,
    required int currentEpoch,
    String? currentDiscriminator,
  }) {
    if (currentScope == null) {
      return false;
    }
    if (currentScope.key != scope.key || currentEpoch != epoch) {
      return false;
    }
    return currentDiscriminator == null ||
        currentDiscriminator == discriminator;
  }
}

/// Tracks which workspace items have an action running.
///
/// A thin scope-typed face over [ScopedBusyRegistry], so workspace callers
/// pass a [WorkspaceScope] instead of hand-building a scope key -- one owner
/// for the key format, and a null scope handled once here rather than at
/// every call site.
class WorkspaceBusyRegistry {
  final ScopedBusyRegistry _registry = ScopedBusyRegistry();

  /// Whether nothing at all is running.
  bool get isEmpty => _registry.isEmpty;

  /// Forgets every busy item, in every scope.
  void clear() => _registry.clear();

  /// The registry key for one item, for use as a widget key or in a log line.
  String key({
    required WorkspaceScope scope,
    required String kind,
    required String id,
  }) {
    return _registry.key(scopeKey: scope.key, kind: kind, id: id);
  }

  /// Whether the identified item has an action running.
  ///
  /// A null [scope] is never busy: no workspace is selected, so nothing in
  /// one can be working.
  bool isBusy({
    required WorkspaceScope? scope,
    required String kind,
    required String id,
  }) {
    if (scope == null) {
      return false;
    }
    return _registry.isBusy(scopeKey: scope.key, kind: kind, id: id);
  }

  /// Marks the identified item busy and returns the key to pass to [remove].
  String markBusy({
    required WorkspaceScope scope,
    required String kind,
    required String id,
  }) {
    return _registry.markBusy(scopeKey: scope.key, kind: kind, id: id);
  }

  /// Marks the item with [key] no longer busy. Safe to call twice.
  void remove(String key) {
    _registry.remove(key);
  }

  /// Marks every item in [scope] no longer busy, across all kinds.
  void clearScope(WorkspaceScope scope) {
    _registry.clearScope(scope.key);
  }
}
