part of '../server_management_view.dart';

mixin ServerScopedConsumerState<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  final ScopedRunRegistry _serverRuns = ScopedRunRegistry();
  ServerScope? _serverScope;

  ServerScope? get currentServerScope => _serverScope;

  ServerScope? serverScopeFor(Server? server) {
    return ServerScope.fromServer(server);
  }

  void bindServerScope(Server? server) {
    final nextScope = serverScopeFor(server);
    if (_serverScope?.key == nextScope?.key) {
      return;
    }
    final previousScope = _serverScope;
    if (previousScope != null) {
      _serverRuns.clearScope(previousScope.key);
    }
    _serverScope = nextScope;
  }

  ScopedRunContext captureServerRun({
    required Server server,
    required String kind,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final scope = ServerScope.fromServer(server);
    if (scope == null) {
      throw StateError('No server scope is available for this run.');
    }
    bindServerScope(server);
    return _serverRuns.capture(
      scopeKey: scope.key,
      kind: kind,
      metadata: metadata,
    );
  }

  bool isCurrentServerRun(ScopedRunContext run) {
    return mounted &&
        _serverScope?.key == run.scopeKey &&
        _serverRuns.isCurrent(run);
  }

  void guardServerSetState(ScopedRunContext run, VoidCallback update) {
    if (!isCurrentServerRun(run)) {
      return;
    }
    setState(update);
  }
}
