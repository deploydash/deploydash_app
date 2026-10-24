import '../data/local/server_repository.dart';
import '../domain/project.dart';
import '../utils/project_slug.dart';

/// The PostgreSQL object-name prefix reserved for one project's managed
/// databases and users.
///
/// Every managed object a project owns is named `dd_<project>_<something>`.
/// Server-side scoping reads the ownership registry rather than this prefix;
/// [logicalManagedPostgresName] uses the prefix to recover the logical name
/// behind a listed remote name.
///
/// The result is forced into what PostgreSQL will accept as an identifier: the
/// slug's hyphens become underscores, anything else outside `[a-z0-9_]`
/// collapses to a single underscore, a leading digit gains an `n_` (an
/// identifier may not start with one), and the whole prefix is truncated to
/// PostgreSQL's 63-byte limit. A name that survives none of that -- one made
/// entirely of punctuation, say -- falls back to `dd_project_app_`, because a
/// blank prefix would match every object on the server.
String managedPostgresProjectPrefix(String projectName) {
  var normalized = slugifyProjectName(projectName)
      .replaceAll('-', '_')
      .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (normalized.isEmpty) {
    normalized = 'project_app';
  }
  if (normalized[0].contains(RegExp(r'[0-9]'))) {
    normalized = 'n_$normalized';
  }
  final prefix = 'dd_${normalized}_';
  if (prefix.length <= 63) {
    return prefix;
  }
  final allowedLength = (63 - 'dd__'.length).clamp(1, normalized.length);
  normalized = normalized
      .substring(0, allowedLength)
      .replaceAll(RegExp(r'_+$'), '');
  if (normalized.isEmpty) {
    normalized = 'p';
  }
  return 'dd_${normalized}_';
}

/// The logical (unprefixed) name behind a managed-PostgreSQL remote name.
///
/// The engine accepts logical names only: a payload carrying an
/// already-prefixed name is rejected, so every surface that echoes a listed
/// remote name back into a request strips the project prefix first. A name
/// that does not carry this project's prefix passes through unchanged; the
/// engine's ownership check, not this strip, decides whether a nested
/// remainder belongs to the calling project.
String logicalManagedPostgresName({
  required String projectName,
  required String remoteName,
}) {
  final prefix = managedPostgresProjectPrefix(projectName);
  if (remoteName.startsWith(prefix)) {
    return remoteName.substring(prefix.length);
  }
  return remoteName;
}

/// Slugs of every project the desktop knows on one server, sorted.
///
/// The engine's backfill matches legacy databases against this set to pick
/// the longest project prefix, so it must see every candidate, not just the
/// calling project. Sorted for wire-stable payloads.
List<String> knownProjectSlugsOnServer({
  required Iterable<Project> projects,
  required String serverId,
}) {
  final slugs =
      projects
          .where((project) => project.serverId == serverId)
          .map((project) => slugifyProjectName(project.name))
          .toSet()
          .toList(growable: false)
        ..sort();
  return slugs;
}

/// The settings payload for a managed-PostgreSQL operation on one project.
///
/// Carries only the server's own configuration and the project's slug -- user
/// intent, in the settings-ownership contract's terms. [overrides] is applied
/// last so an operation can add the keys it needs; it cannot be used to smuggle
/// a backend-owned path or pin past the contract, because the engine rejects
/// those on arrival rather than trusting what was sent.
Map<String, dynamic> buildManagedPostgresProjectSettings({
  required String projectName,
  required ServerPostgresConfig config,
  Map<String, dynamic>? overrides,
}) {
  return <String, dynamic>{
    'postgres_version': config.postgresVersion,
    'superuser_password': config.superuserPassword,
    'enabled_extensions': config.enabledExtensions,
    'project_slug': slugifyProjectName(projectName),
    ...?overrides,
  };
}

/// The 3-key PostgreSQL settings for a service operation — never slugged.
///
/// Why no slug and no overrides: service payloads address the server's own
/// postgres, not a project's managed databases (D-28). The twins this
/// replaces carried exactly these three keys; a slug key here would be
/// silently ignored at best and a contract violation at worst.
Map<String, dynamic> buildPostgresServiceSettings(ServerPostgresConfig config) {
  return <String, dynamic>{
    'postgres_version': config.postgresVersion,
    'superuser_password': config.superuserPassword,
    'enabled_extensions': config.enabledExtensions,
  };
}
