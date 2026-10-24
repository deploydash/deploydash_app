import '../data/local/server_repository.dart';
import '../domain/project.dart';
import '../models/project_destination.dart';

/// What kind of thing a search result points at.
///
/// Also the section order in the rail: servers, then projects, then screens
/// inside a project. Broadest first, so a user typing a server name is not
/// pushed past nine of its screens to reach it.
enum LocalSearchResultKind {
  /// A saved server.
  server,

  /// A project on a saved server.
  project,

  /// One screen within a project's workspace.
  screen,
}

/// One row in the rail's search results.
///
/// Carries the ids needed to navigate rather than a route string, so the
/// caller decides what opening a result means -- the same result opens a
/// workspace from the rail and pre-selects a server elsewhere.
class LocalSearchResult {
  /// Creates a result row.
  const LocalSearchResult({
    required this.kind,
    required this.title,
    this.subtitle,
    this.context,
    this.serverId,
    this.projectId,
    this.destinationId,
  });

  /// Which section this row belongs to.
  final LocalSearchResultKind kind;

  /// The matched name, shown as the row's first line.
  final String title;

  /// The second line: what this is. Host and OS for a server, type and domain
  /// for a project, the owning project's name for a screen.
  final String? subtitle;

  /// The owning server's name, when there is one to show. Null when the
  /// project has no server, which is a real state during onboarding.
  final String? context;

  /// The server to select when this row is opened.
  final String? serverId;

  /// The project to open, for a project or screen row.
  final String? projectId;

  /// The workspace screen to land on. A project row carries
  /// [defaultProjectDestinationId] rather than null, so opening a project from
  /// search behaves the same as opening it from Home.
  final String? destinationId;
}

class _RankedResult {
  const _RankedResult(this.rank, this.sortKey, this.result);

  final int rank;
  final String sortKey;
  final LocalSearchResult result;
}

/// Matches [query] against everything already held in the local database.
///
/// Returns servers first, then projects, then project screens, capped at
/// [limitPerKind] entries per section. Prefix matches rank above interior
/// matches so typing the start of a name surfaces it first.
List<LocalSearchResult> searchLocalIndex({
  required String query,
  required List<Server> servers,
  required List<Project> projects,
  int limitPerKind = 8,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty || limitPerKind <= 0) {
    return const <LocalSearchResult>[];
  }

  final serverNamesById = <String, String>{
    for (final server in servers) server.id: server.name,
  };

  final serverMatches = <_RankedResult>[];
  for (final server in servers) {
    final rank = _bestRank(needle, [server.name, server.host]);
    if (rank == null) {
      continue;
    }
    serverMatches.add(
      _RankedResult(
        rank,
        server.name.toLowerCase(),
        LocalSearchResult(
          kind: LocalSearchResultKind.server,
          title: server.name,
          subtitle: _serverSubtitle(server),
          serverId: server.id,
        ),
      ),
    );
  }

  final projectMatches = <_RankedResult>[];
  final screenMatches = <_RankedResult>[];
  for (final project in projects) {
    final serverId = project.serverId;
    final serverName = serverId == null ? null : serverNamesById[serverId];
    final projectRank = _bestRank(needle, [
      project.name,
      project.primaryDomain,
      project.repositoryFullName,
    ]);
    if (projectRank != null) {
      projectMatches.add(
        _RankedResult(
          projectRank,
          project.name.toLowerCase(),
          LocalSearchResult(
            kind: LocalSearchResultKind.project,
            title: project.name,
            subtitle: _projectSubtitle(project),
            context: serverName,
            serverId: serverId,
            projectId: project.id,
            destinationId: defaultProjectDestinationId,
          ),
        ),
      );
    }
    for (final destination in projectWorkspaceDestinations) {
      final screenRank = _rankOf(needle, destination.label);
      if (screenRank == null) {
        continue;
      }
      screenMatches.add(
        _RankedResult(
          screenRank,
          '${project.name.toLowerCase()} ${destination.label.toLowerCase()}',
          LocalSearchResult(
            kind: LocalSearchResultKind.screen,
            title: destination.label,
            subtitle: project.name,
            context: serverName,
            serverId: serverId,
            projectId: project.id,
            destinationId: destination.id,
          ),
        ),
      );
    }
  }

  return <LocalSearchResult>[
    ..._take(serverMatches, limitPerKind),
    ..._take(projectMatches, limitPerKind),
    ..._take(screenMatches, limitPerKind),
  ];
}

List<LocalSearchResult> _take(List<_RankedResult> matches, int limit) {
  matches.sort((left, right) {
    final byRank = left.rank.compareTo(right.rank);
    return byRank != 0 ? byRank : left.sortKey.compareTo(right.sortKey);
  });
  return matches
      .take(limit)
      .map((match) => match.result)
      .toList(growable: false);
}

int? _bestRank(String needle, List<String?> candidates) {
  int? best;
  for (final candidate in candidates) {
    final rank = _rankOf(needle, candidate);
    if (rank == null) {
      continue;
    }
    if (best == null || rank < best) {
      best = rank;
    }
  }
  return best;
}

int? _rankOf(String needle, String? candidate) {
  final haystack = candidate?.trim().toLowerCase();
  if (haystack == null || haystack.isEmpty) {
    return null;
  }
  if (haystack.startsWith(needle)) {
    return 0;
  }
  return haystack.contains(needle) ? 1 : null;
}

String _serverSubtitle(Server server) {
  final osName = server.osName?.trim();
  if (osName == null || osName.isEmpty) {
    return server.host;
  }
  return '${server.host} - $osName';
}

String _projectSubtitle(Project project) {
  final domain = project.primaryDomain.trim();
  if (domain.isEmpty || domain.toLowerCase() == 'not configured') {
    return project.type;
  }
  return '${project.type} - $domain';
}
