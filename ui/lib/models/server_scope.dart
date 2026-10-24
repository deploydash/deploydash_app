import '../domain/server.dart';

/// The server a screen is currently showing, as a value.
///
/// The single-id counterpart to `WorkspaceScope`, for surfaces that belong to
/// a server rather than to a project on one. Passing the scope rather than a
/// bare id is what lets a caller ask "is this still the server it was for?"
/// in one call after an await, instead of comparing ids by hand at every
/// site.
class ServerScope {
  /// Creates a scope from an already-validated id. Prefer [fromId] or
  /// [fromServer], which reject the blank id this constructor accepts.
  const ServerScope({required this.serverId});

  /// The server being viewed.
  final String serverId;

  /// The scope as one string, for use as a map key and in log lines.
  ///
  /// Equal to [serverId] today; it exists so a caller keys on the scope
  /// rather than on the id, and keeps working if a scope ever needs a second
  /// part.
  String get key => serverId;

  /// Whether this scope is exactly the given server.
  bool matches(String serverId) {
    return this.serverId == serverId;
  }

  /// A scope for [serverId], or null when it is missing or blank.
  ///
  /// Null is the normal state, not an error: it is what a screen has before a
  /// server is selected, and every scope-aware helper reads it as "nothing is
  /// current".
  static ServerScope? fromId(String? serverId) {
    final normalizedServerId = serverId?.trim();
    if (normalizedServerId == null || normalizedServerId.isEmpty) {
      return null;
    }
    return ServerScope(serverId: normalizedServerId);
  }

  /// A scope for the selected server, or null when none is selected.
  static ServerScope? fromServer(Server? server) {
    return fromId(server?.id);
  }
}
