part of '../project_workspace.dart';

mixin WorkspaceScopedConsumerState<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  WorkspaceScope? _workspaceScope;
  String? _pendingWorkspaceBindKey;
  String _workspaceBindDiscriminator = '';
  int _workspaceBindEpoch = 0;

  WorkspaceScope? get currentWorkspaceScope => _workspaceScope;
  int get workspaceBindEpoch => _workspaceBindEpoch;
  String get workspaceBindDiscriminator => _workspaceBindDiscriminator;

  WorkspaceScope? workspaceScopeFor(Project? project, Server? server) {
    return WorkspaceScope.fromSelection(project, server);
  }

  void clearPendingWorkspaceBind() {
    _pendingWorkspaceBindKey = null;
  }

  void scheduleWorkspaceSelectionBind({
    required Project? project,
    required Server? server,
    String discriminator = '',
    required void Function(Project project, Server server) onBind,
  }) {
    final scope = workspaceScopeFor(project, server);
    if (scope == null || project == null || server == null) {
      _pendingWorkspaceBindKey = null;
      return;
    }

    final bindKey = '${scope.key}::$discriminator';
    if ((_workspaceScope?.key == scope.key &&
            _workspaceBindDiscriminator == discriminator) ||
        _pendingWorkspaceBindKey == bindKey) {
      return;
    }

    _pendingWorkspaceBindKey = bindKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingWorkspaceBindKey = null;
      if (!mounted) {
        return;
      }
      onBind(project, server);
    });
  }

  void scheduleScopeBind({
    required Project? project,
    required Server? server,
    String discriminator = '',
    required void Function(Project project, Server server) onBind,
  }) {
    scheduleWorkspaceSelectionBind(
      project: project,
      server: server,
      discriminator: discriminator,
      onBind: onBind,
    );
  }

  int bindWorkspaceSelection(
    Project project,
    Server server, {
    String discriminator = '',
  }) {
    final scope = WorkspaceScope(projectId: project.id, serverId: server.id);
    _workspaceScope = scope;
    _workspaceBindDiscriminator = discriminator;
    _workspaceBindEpoch += 1;
    return _workspaceBindEpoch;
  }

  int advanceWorkspaceEpoch() {
    _workspaceBindEpoch += 1;
    return _workspaceBindEpoch;
  }

  int updateWorkspaceDiscriminator(String discriminator) {
    _workspaceBindDiscriminator = discriminator;
    return advanceWorkspaceEpoch();
  }

  WorkspaceRunContext captureWorkspaceRun({
    String discriminator = '',
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final scope = _workspaceScope;
    if (scope == null) {
      throw StateError('No workspace scope is currently bound.');
    }
    return WorkspaceRunContext(
      scope: scope,
      epoch: _workspaceBindEpoch,
      discriminator: discriminator,
      runId:
          '${scope.key}::$_workspaceBindEpoch::'
          '${DateTime.now().microsecondsSinceEpoch}',
      metadata: metadata,
    );
  }

  bool isCurrentWorkspaceRun(WorkspaceRunContext run) {
    return mounted &&
        run.isCurrent(
          currentScope: _workspaceScope,
          currentEpoch: _workspaceBindEpoch,
          currentDiscriminator: _workspaceBindDiscriminator,
        );
  }

  void guardSetState(WorkspaceRunContext run, VoidCallback update) {
    if (!isCurrentWorkspaceRun(run)) {
      return;
    }
    setState(update);
  }

  bool isCurrentWorkspaceSelection(
    Project project,
    Server server, [
    int? expectedEpoch,
  ]) {
    final scope = _workspaceScope;
    return mounted &&
        scope != null &&
        scope.matches(projectId: project.id, serverId: server.id) &&
        (expectedEpoch == null || expectedEpoch == _workspaceBindEpoch);
  }

  bool isCurrentWorkspaceIds({
    required String projectId,
    required String serverId,
    int? expectedEpoch,
  }) {
    final scope = _workspaceScope;
    if (!mounted) {
      return false;
    }
    if (scope != null) {
      return scope.matches(projectId: projectId, serverId: serverId) &&
          (expectedEpoch == null || expectedEpoch == _workspaceBindEpoch);
    }
    if (expectedEpoch != null) {
      return false;
    }
    final selectedProject = ref.read(selectedProjectProvider);
    final selectedServer = ref.read(selectedServerProvider);
    return selectedProject?.id == projectId && selectedServer?.id == serverId;
  }
}
