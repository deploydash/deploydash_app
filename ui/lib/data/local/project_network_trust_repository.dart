import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/trim_or_null.dart';
import 'app_database.dart';

/// A set of projects on one server that can reach each other over a shared
/// Docker network.
///
/// Two or more projects, never one: a group of one connects nothing, so the
/// repository deletes a group the moment it drops below two members.
class ProjectNetworkGroupRecord {
  /// Records one trust group.
  const ProjectNetworkGroupRecord({
    required this.id,
    required this.serverId,
    required this.displayName,
    required this.networkName,
    required this.memberProjectIds,
    required this.createdAt,
    required this.updatedAt,
  });

  /// The group's id, derived from its server and members rather than
  /// generated -- so linking the same projects twice reuses the same group and
  /// the same network.
  final String id;

  /// The server every member is on. Cross-server groups are refused.
  final String serverId;

  /// What the user calls this group.
  final String displayName;

  /// The Docker network name, `deploydash_trust_<id>`. What actually appears
  /// on the server.
  final String networkName;

  /// The member project ids, sorted.
  final List<String> memberProjectIds;

  /// When the group was first created.
  final DateTime createdAt;

  /// When its membership or name last changed.
  final DateTime updatedAt;
}

/// Stores which projects are allowed to reach each other on a server.
///
/// Container networking is what actually enforces this, so the records here
/// decide what the deploy attaches. Two invariants are kept by this class
/// rather than by callers: every member of a group is on the same server, and
/// no group has fewer than two members.
class ProjectNetworkTrustRepository {
  /// Creates the repository over the app database.
  ProjectNetworkTrustRepository(this._database);

  final AppDatabase _database;

  /// Every group a project belongs to, by display name.
  Future<List<ProjectNetworkGroupRecord>> listGroupsForProject(
    String projectId,
  ) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return const <ProjectNetworkGroupRecord>[];
    }
    final memberships = await (_database.select(
      _database.projectNetworkGroupMembers,
    )..where((table) => table.projectId.equals(normalizedProjectId))).get();
    final groupIds = memberships.map((row) => row.groupId).toSet();
    if (groupIds.isEmpty) {
      return const <ProjectNetworkGroupRecord>[];
    }
    return _listGroupsByIds(groupIds);
  }

  /// The Docker networks a project's containers should join, sorted.
  ///
  /// What a deploy actually consumes -- the names, not the groups.
  Future<List<String>> listTrustNetworkNamesForProject(String projectId) async {
    final groups = await listGroupsForProject(projectId);
    final names = groups
        .map((group) => group.networkName.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList(growable: false);
    names.sort();
    return names;
  }

  /// Creates or updates the group linking the given projects.
  ///
  /// The group id is derived from the server and the sorted member ids, so
  /// linking the same set again updates that group rather than making a second
  /// one with a second network.
  ///
  /// Throws [ArgumentError] for fewer than two distinct projects, and
  /// [StateError] when any of them is on a different server -- a Docker network
  /// exists on one machine, so a cross-server group could not be honoured and
  /// must not be recorded as though it had been.
  Future<ProjectNetworkGroupRecord> linkProjects({
    required String serverId,
    required Iterable<String> projectIds,
    String? displayName,
  }) async {
    final normalizedServerId = requireNonEmptyId(serverId, 'serverId');
    final normalizedProjectIds =
        projectIds
            .map((projectId) => projectId.trim())
            .where((projectId) => projectId.isNotEmpty)
            .toSet()
            .toList(growable: false)
          ..sort();
    if (normalizedProjectIds.length < 2) {
      throw ArgumentError.value(
        projectIds,
        'projectIds',
        'At least two projects are required for a trust group.',
      );
    }
    await assertProjectsBelongToServer(
      serverId: normalizedServerId,
      projectIds: normalizedProjectIds,
      message: 'Linked projects must be on the same server.',
    );

    final groupId = trustGroupIdFor(
      serverId: normalizedServerId,
      projectIds: normalizedProjectIds,
    );
    final networkName = 'deploydash_trust_$groupId';
    final now = DateTime.now();
    final existing =
        await (_database.select(_database.projectNetworkGroups)
              ..where((table) => table.id.equals(groupId))
              ..limit(1))
            .getSingleOrNull();
    final normalizedDisplayName = trimOrNull(displayName) ?? 'Linked projects';
    await _database.transaction(() async {
      await _database
          .into(_database.projectNetworkGroups)
          .insertOnConflictUpdate(
            ProjectNetworkGroupsCompanion.insert(
              id: groupId,
              serverId: normalizedServerId,
              displayName: normalizedDisplayName,
              networkName: networkName,
              createdAt: Value(existing?.createdAt ?? now),
              updatedAt: Value(now),
            ),
          );
      for (final projectId in normalizedProjectIds) {
        await _database
            .into(_database.projectNetworkGroupMembers)
            .insertOnConflictUpdate(
              ProjectNetworkGroupMembersCompanion.insert(
                groupId: groupId,
                projectId: projectId,
                createdAt: Value(now),
              ),
            );
      }
    });

    return (await _listGroupsByIds({groupId})).single;
  }

  /// Removes a project from every group, deleting any left below two members.
  ///
  /// One transaction, so a group cannot briefly exist with a single member.
  Future<void> removeProjectFromGroups(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }
    final affected = await (_database.select(
      _database.projectNetworkGroupMembers,
    )..where((table) => table.projectId.equals(normalizedProjectId))).get();
    final groupIds = affected.map((row) => row.groupId).toSet();
    await _database.transaction(() async {
      await (_database.delete(
        _database.projectNetworkGroupMembers,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await _deleteGroupsWithFewerThanTwoMembers(groupIds);
    });
  }

  Future<List<ProjectNetworkGroupRecord>> _listGroupsByIds(
    Set<String> groupIds,
  ) async {
    if (groupIds.isEmpty) {
      return const <ProjectNetworkGroupRecord>[];
    }
    final groups =
        await (_database.select(_database.projectNetworkGroups)
              ..where((table) => table.id.isIn(groupIds.toList()))
              ..orderBy([(table) => OrderingTerm.asc(table.displayName)]))
            .get();
    final members =
        await (_database.select(_database.projectNetworkGroupMembers)
              ..where((table) => table.groupId.isIn(groupIds.toList()))
              ..orderBy([
                (table) => OrderingTerm.asc(table.groupId),
                (table) => OrderingTerm.asc(table.projectId),
              ]))
            .get();
    final membersByGroup = <String, List<String>>{};
    for (final member in members) {
      membersByGroup
          .putIfAbsent(member.groupId, () => [])
          .add(member.projectId);
    }
    return groups
        .map(
          (group) => ProjectNetworkGroupRecord(
            id: group.id,
            serverId: group.serverId,
            displayName: group.displayName,
            networkName: group.networkName,
            memberProjectIds: List.unmodifiable(
              membersByGroup[group.id] ?? const [],
            ),
            createdAt: group.createdAt,
            updatedAt: group.updatedAt,
          ),
        )
        .toList(growable: false);
  }

  Future<void> _deleteGroupsWithFewerThanTwoMembers(
    Set<String> groupIds,
  ) async {
    for (final groupId in groupIds) {
      final count =
          await (_database.select(_database.projectNetworkGroupMembers)
                ..where((table) => table.groupId.equals(groupId)))
              .get()
              .then((rows) => rows.length);
      if (count >= 2) {
        continue;
      }
      await (_database.delete(
        _database.projectNetworkGroupMembers,
      )..where((table) => table.groupId.equals(groupId))).go();
      await (_database.delete(
        _database.projectNetworkGroups,
      )..where((table) => table.id.equals(groupId))).go();
    }
  }

  /// Refuses to record a group whose members are not all on [serverId].
  ///
  /// Why one owner with a message parameter: the trust path and the
  /// database-sharing path check the same violation but report different
  /// user-facing errors for it, so the message travels with the caller (the
  /// `settings_ownership.reject_server_owned_keys` precedent: take the
  /// caller's error shape as an argument rather than forking the check).
  Future<void> assertProjectsBelongToServer({
    required String serverId,
    required List<String> projectIds,
    required String message,
  }) async {
    final rows = await (_database.select(
      _database.projects,
    )..where((table) => table.id.isIn(projectIds))).get();
    final byId = <String, ProjectRow>{for (final row in rows) row.id: row};
    for (final projectId in projectIds) {
      if (byId[projectId]?.serverId != serverId) {
        throw StateError(message);
      }
    }
  }
}

/// The app-wide network trust repository.
final projectNetworkTrustRepositoryProvider =
    Provider<ProjectNetworkTrustRepository>((ref) {
      final database = ref.watch(appDatabaseProvider);
      return ProjectNetworkTrustRepository(database);
    });

/// Trims [value] or throws when it is blank.
///
/// Why a wrapper over [trimOrNull] rather than a twin trim-or-throw: the
/// trust and access repositories carried the same trim-or-throw body under
/// different names. The throw keeps [ArgumentError.value] with the original
/// [value] so the failure names what the caller passed, not the trimmed
/// result.
String requireNonEmptyId(String value, String fieldName) {
  final trimmed = trimOrNull(value);
  if (trimmed == null) {
    throw ArgumentError.value(value, fieldName, 'Value is required.');
  }
  return trimmed;
}

/// Derives a trust-group id from [serverId] and [projectIds].
///
/// Why one owner: the trust repository and the database-access repository
/// built the same `'trust-<server>-<members>'` token under different names.
/// Callers sort [projectIds] first; the owner joins them verbatim so the id
/// is deterministic for a set regardless of who links it.
String trustGroupIdFor({
  required String serverId,
  required List<String> projectIds,
}) {
  return dockerSafeToken('trust-$serverId-${projectIds.join('-')}');
}

/// Renders [value] safe for Docker identifiers, lowercased and capped.
///
/// Why one owner with parameters: the trust/access twins share the fixed-48,
/// `'group'`-fallback contract, while the snapshot sibling (D-6) needs its
/// own bound and `'sqlite'` fallback -- so [maxLength] and [emptyFallback]
/// travel with the caller instead of forking the scrubber.
String dockerSafeToken(
  String value, {
  int maxLength = 48,
  String emptyFallback = 'group',
}) {
  final normalized = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_.-]+'), '-')
      .replaceAll(RegExp(r'^[-_.]+|[-_.]+$'), '');
  if (normalized.isEmpty) {
    return emptyFallback;
  }
  return normalized.length > maxLength
      ? normalized.substring(0, maxLength)
      : normalized;
}
