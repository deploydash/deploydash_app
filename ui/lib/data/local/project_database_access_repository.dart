import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/trim_or_null.dart';
import 'app_database.dart';
import 'project_network_trust_repository.dart';

/// Permission for one project to use another project's managed database.
///
/// The grant is the owner's decision, and it is what the consumer's own users
/// hang off. Revoking it takes those users with it -- see
/// [ProjectDatabaseAccessRepository.deleteGrantAndUsers].
class ProjectDatabaseAccessGrantRecord {
  /// Records one grant.
  const ProjectDatabaseAccessGrantRecord({
    required this.id,
    required this.serverId,
    required this.ownerProjectId,
    required this.consumerProjectId,
    required this.engine,
    required this.databaseName,
    required this.createdAt,
    required this.updatedAt,
  });

  /// The grant's id. Generated once and reused when the same owner, consumer
  /// and database are granted again, so re-granting cannot create a duplicate.
  final String id;

  /// The server both projects are on. Sharing is same-server only, because a
  /// managed database is not reachable from another machine.
  final String serverId;

  /// The project that owns the database.
  final String ownerProjectId;

  /// The project allowed to use it.
  final String consumerProjectId;

  /// The database engine. `postgres` today; SQLite sharing works by snapshot
  /// instead, since it has no server to grant access through.
  final String engine;

  /// Which of the owner's databases is shared.
  final String databaseName;

  /// When the grant was first made.
  final DateTime createdAt;

  /// When it last changed.
  final DateTime updatedAt;
}

/// A database user the consumer created against a granted database.
///
/// The consumer manages its own users under the grant -- it can add, copy and
/// delete them -- but it can never create or drop the owner's *database*. That
/// split is what makes sharing safe to offer.
class ProjectDatabaseAccessUserRecord {
  /// Records one user under a grant.
  const ProjectDatabaseAccessUserRecord({
    required this.id,
    required this.grantId,
    required this.engine,
    required this.databaseName,
    required this.username,
    required this.accessMode,
    this.host,
    this.port,
    this.connectionUri,
    required this.createdAt,
    required this.updatedAt,
  });

  /// The user record's id. Generated when the caller leaves it blank.
  final String id;

  /// The grant that authorises this user. Deleting the grant deletes it.
  final String grantId;

  /// The engine. See [ProjectDatabaseAccessGrantRecord.engine].
  final String engine;

  /// The database this user connects to.
  final String databaseName;

  /// The PostgreSQL role name as it exists on the server.
  final String username;

  /// `read_only` or `read_write`. Anything else normalizes to `read_write`,
  /// matching what the managed-database workflow will actually create.
  final String accessMode;

  /// The host to connect to, as observed from the server.
  final String? host;

  /// The port to connect on.
  final int? port;

  /// The full connection URI, for the connection-details panel.
  final String? connectionUri;

  /// When the user was created.
  final DateTime createdAt;

  /// When it last changed.
  final DateTime updatedAt;
}

/// Stores who may use whose managed database, and the users created under
/// those grants.
///
/// Granting access also links the two projects on a shared Docker network, and
/// revoking the last grant between them unlinks it again -- a credential the
/// consumer cannot reach is not access, so the two are kept together here
/// rather than left to the caller to remember.
class ProjectDatabaseAccessRepository {
  /// Creates the repository over the app database.
  ///
  /// Why the trust repository travels along: granting access links the two
  /// projects on a shared Docker network, and the same-server check plus the
  /// group-id derivation live there (D-17) -- one owner, reached through
  /// composition rather than rewritten here.
  ProjectDatabaseAccessRepository(
    this._database, [
    ProjectNetworkTrustRepository? trustRepository,
  ]) : _trustRepository =
           trustRepository ?? ProjectNetworkTrustRepository(_database);

  final AppDatabase _database;
  final ProjectNetworkTrustRepository _trustRepository;

  /// Grants a project has made, as the owner.
  Future<List<ProjectDatabaseAccessGrantRecord>> listOwnerGrants({
    required String serverId,
    required String ownerProjectId,
  }) =>
      _listGrants(serverId: serverId, projectId: ownerProjectId, byOwner: true);

  /// Grants a project has received, as the consumer.
  Future<List<ProjectDatabaseAccessGrantRecord>> listConsumerGrants({
    required String serverId,
    required String consumerProjectId,
  }) => _listGrants(
    serverId: serverId,
    projectId: consumerProjectId,
    byOwner: false,
  );

  /// Lists grants on one side of a share.
  ///
  /// Why: the owner/consumer lists share select-where-orderBy-map and differ
  /// only in predicate column and third order column; one owner keeps the
  /// shared ordering (engine, databaseName) from drifting apart. [byOwner]
  /// selects both the predicate column and the third order column together:
  /// the owner view predicates owner + orders by consumer and vice versa.
  /// No empty-guard, as before: both lists issue the query unconditionally.
  Future<List<ProjectDatabaseAccessGrantRecord>> _listGrants({
    required String serverId,
    required String projectId,
    required bool byOwner,
  }) async {
    final normalizedServerId = serverId.trim();
    final normalizedProjectId = projectId.trim();
    final query = _database.select(_database.projectDatabaseAccessGrants)
      ..where((table) {
        final side = byOwner
            ? table.ownerProjectId.equals(normalizedProjectId)
            : table.consumerProjectId.equals(normalizedProjectId);
        return table.serverId.equals(normalizedServerId) & side;
      })
      ..orderBy([
        (table) => OrderingTerm.asc(table.engine),
        (table) => OrderingTerm.asc(table.databaseName),
        // Why the ternary picks whole terms (D-15): the acceptance grep
        // pins both contiguous `OrderingTerm.asc(table.X)` spellings at
        // this one site, so the branch stays visible instead of hiding
        // inside one asc() call.
        (table) => byOwner
            ? OrderingTerm.asc(table.consumerProjectId)
            : OrderingTerm.asc(table.ownerProjectId),
      ]);
    final rows = await query.get();
    return rows.map(_mapGrant).toList(growable: false);
  }

  /// Creates or refreshes a grant, and links the two projects on a network.
  ///
  /// An existing grant for the same owner, consumer, engine and database is
  /// reused rather than duplicated, keeping its original creation time.
  ///
  /// Throws [ArgumentError] when a project is granted access to itself, and
  /// [StateError] when the two are not on the same server -- a managed
  /// database is only reachable from its own machine, so such a grant could
  /// never be honoured and must not be recorded as though it had been.
  Future<ProjectDatabaseAccessGrantRecord> upsertGrant({
    required String serverId,
    required String ownerProjectId,
    required String consumerProjectId,
    String engine = 'postgres',
    String databaseName = 'owner_db',
  }) async {
    final normalizedServerId = requireNonEmptyId(serverId, 'serverId');
    final normalizedOwnerId = requireNonEmptyId(
      ownerProjectId,
      'ownerProjectId',
    );
    final normalizedConsumerId = requireNonEmptyId(
      consumerProjectId,
      'consumerProjectId',
    );
    final normalizedEngine = _normalizeEngine(engine);
    final normalizedDatabaseName = requireNonEmptyId(
      databaseName,
      'databaseName',
    );
    if (normalizedOwnerId == normalizedConsumerId) {
      throw ArgumentError.value(
        consumerProjectId,
        'consumerProjectId',
        'A project cannot grant database access to itself.',
      );
    }
    await _trustRepository.assertProjectsBelongToServer(
      serverId: normalizedServerId,
      projectIds: [normalizedOwnerId, normalizedConsumerId],
      message: 'Database sharing is only available on the same server.',
    );

    final now = DateTime.now();
    final existing = await _findGrant(
      serverId: normalizedServerId,
      ownerProjectId: normalizedOwnerId,
      consumerProjectId: normalizedConsumerId,
      engine: normalizedEngine,
      databaseName: normalizedDatabaseName,
    );
    final id =
        existing?.id ??
        'db-grant-${now.microsecondsSinceEpoch}-$normalizedConsumerId';
    await _database
        .into(_database.projectDatabaseAccessGrants)
        .insertOnConflictUpdate(
          ProjectDatabaseAccessGrantsCompanion.insert(
            id: id,
            serverId: normalizedServerId,
            ownerProjectId: normalizedOwnerId,
            consumerProjectId: normalizedConsumerId,
            engine: Value(normalizedEngine),
            databaseName: Value(normalizedDatabaseName),
            createdAt: Value(existing?.createdAt ?? now),
            updatedAt: Value(now),
          ),
        );
    await _ensureTrustGroupForProjects(
      serverId: normalizedServerId,
      ownerProjectId: normalizedOwnerId,
      consumerProjectId: normalizedConsumerId,
      now: now,
    );
    final row =
        await (_database.select(_database.projectDatabaseAccessGrants)
              ..where((table) => table.id.equals(id))
              ..limit(1))
            .getSingle();
    return _mapGrant(row);
  }

  /// The users created under one grant.
  Future<List<ProjectDatabaseAccessUserRecord>> listUsersForGrant(
    String grantId,
  ) => _listUsersForGrantIds([grantId]);

  /// The users created under several grants, in one query.
  ///
  /// Blank ids are dropped, and an empty list short-circuits rather than
  /// issuing a query that would match everything.
  Future<List<ProjectDatabaseAccessUserRecord>> listUsersForGrants(
    Iterable<String> grantIds,
  ) => _listUsersForGrantIds(grantIds);

  /// Lists users under several grants, in one query.
  ///
  /// Why: the single-grant list is the one-element case of the multi-grant
  /// list; one owner keeps the ordering and the empty-guard in one place.
  Future<List<ProjectDatabaseAccessUserRecord>> _listUsersForGrantIds(
    Iterable<String> grantIds,
  ) async {
    final ids = grantIds.map((id) => id.trim()).where((id) => id.isNotEmpty);
    final idList = ids.toList(growable: false);
    if (idList.isEmpty) {
      return const <ProjectDatabaseAccessUserRecord>[];
    }
    final query = _database.select(_database.projectDatabaseAccessUsers)
      ..where((table) => table.grantId.isIn(idList))
      ..orderBy([
        (table) => OrderingTerm.asc(table.engine),
        (table) => OrderingTerm.asc(table.databaseName),
        (table) => OrderingTerm.asc(table.username),
      ]);
    final rows = await query.get();
    return rows.map(_mapUser).toList(growable: false);
  }

  /// Creates or updates a user under a grant, returning what was stored.
  ///
  /// A blank id means "new user" and one is generated. The creation time of an
  /// existing row is preserved rather than taken from the argument, so
  /// updating a user does not make it look newly created.
  ///
  /// Throws [ArgumentError] when the grant, database or username is blank.
  Future<ProjectDatabaseAccessUserRecord> upsertUser(
    ProjectDatabaseAccessUserRecord user,
  ) async {
    final now = DateTime.now();
    final id = user.id.trim().isEmpty
        ? 'db-access-user-${now.microsecondsSinceEpoch}'
        : user.id.trim();
    final existing =
        await (_database.select(_database.projectDatabaseAccessUsers)
              ..where((table) => table.id.equals(id))
              ..limit(1))
            .getSingleOrNull();
    await _database
        .into(_database.projectDatabaseAccessUsers)
        .insertOnConflictUpdate(
          ProjectDatabaseAccessUsersCompanion.insert(
            id: id,
            grantId: requireNonEmptyId(user.grantId, 'grantId'),
            engine: _normalizeEngine(user.engine),
            databaseName: requireNonEmptyId(user.databaseName, 'databaseName'),
            username: requireNonEmptyId(user.username, 'username'),
            accessMode: Value(_normalizeAccessMode(user.accessMode)),
            host: Value(trimOrNull(user.host)),
            port: Value(user.port),
            connectionUri: Value(trimOrNull(user.connectionUri)),
            createdAt: Value(existing?.createdAt ?? user.createdAt),
            updatedAt: Value(now),
          ),
        );
    final row =
        await (_database.select(_database.projectDatabaseAccessUsers)
              ..where((table) => table.id.equals(id))
              ..limit(1))
            .getSingle();
    return _mapUser(row);
  }

  /// Removes one user record.
  ///
  /// Local only: dropping the role on the server is the managed-database
  /// workflow's job, and this should follow it.
  Future<void> deleteUser(String userId) async {
    await (_database.delete(
      _database.projectDatabaseAccessUsers,
    )..where((table) => table.id.equals(userId.trim()))).go();
  }

  /// Removes every shared user of one owner database, across all its grants.
  ///
  /// What deleting the owner's database calls: the database is gone, so every
  /// credential pointing at it is stale, whoever created it.
  Future<void> deleteUsersForOwnerDatabase({
    required String serverId,
    required String ownerProjectId,
    required String engine,
    required String databaseName,
  }) async {
    final normalizedServerId = serverId.trim();
    final normalizedOwnerProjectId = ownerProjectId.trim();
    final normalizedDatabaseName = databaseName.trim();
    if (normalizedServerId.isEmpty ||
        normalizedOwnerProjectId.isEmpty ||
        normalizedDatabaseName.isEmpty) {
      return;
    }
    final grants =
        await (_database.select(_database.projectDatabaseAccessGrants)
              ..where((table) {
                return table.serverId.equals(normalizedServerId) &
                    table.ownerProjectId.equals(normalizedOwnerProjectId);
              }))
            .get();
    final grantIds = grants.map((grant) => grant.id).toList(growable: false);
    if (grantIds.isEmpty) {
      return;
    }
    await (_database.delete(_database.projectDatabaseAccessUsers)
          ..where((table) {
            return table.grantId.isIn(grantIds) &
                table.engine.equals(_normalizeEngine(engine)) &
                table.databaseName.equals(normalizedDatabaseName);
          }))
        .go();
  }

  /// Revokes a grant and removes the users created under it.
  ///
  /// One transaction. If that was the last grant between the two projects, the
  /// network group linking them is removed too -- leaving them connected would
  /// keep a route open that no grant justifies any more.
  Future<void> deleteGrantAndUsers(String grantId) async {
    final normalizedGrantId = grantId.trim();
    if (normalizedGrantId.isEmpty) {
      return;
    }
    final grant =
        await (_database.select(_database.projectDatabaseAccessGrants)
              ..where((table) => table.id.equals(normalizedGrantId))
              ..limit(1))
            .getSingleOrNull();
    await _database.transaction(() async {
      await (_database.delete(
        _database.projectDatabaseAccessUsers,
      )..where((table) => table.grantId.equals(normalizedGrantId))).go();
      await (_database.delete(
        _database.projectDatabaseAccessGrants,
      )..where((table) => table.id.equals(normalizedGrantId))).go();
      if (grant != null) {
        await _deleteTrustGroupIfNoLegacyGrantsRemain(grant);
      }
    });
  }

  /// Removes every grant a project is on either side of, with their users.
  ///
  /// Part of deleting a project. Both directions, in one transaction: a
  /// deleted project must not remain as either an owner or a consumer.
  Future<void> deleteForProject(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }
    final grants =
        await (_database.select(_database.projectDatabaseAccessGrants)
              ..where((table) {
                return table.ownerProjectId.equals(normalizedProjectId) |
                    table.consumerProjectId.equals(normalizedProjectId);
              }))
            .get();
    final grantIds = grants.map((grant) => grant.id).toList(growable: false);
    await _database.transaction(() async {
      if (grantIds.isNotEmpty) {
        await (_database.delete(
          _database.projectDatabaseAccessUsers,
        )..where((table) => table.grantId.isIn(grantIds))).go();
      }
      await (_database.delete(_database.projectDatabaseAccessGrants)
            ..where((table) {
              return table.ownerProjectId.equals(normalizedProjectId) |
                  table.consumerProjectId.equals(normalizedProjectId);
            }))
          .go();
    });
  }

  Future<ProjectDatabaseAccessGrantRow?> _findGrant({
    required String serverId,
    required String ownerProjectId,
    required String consumerProjectId,
    required String engine,
    required String databaseName,
  }) {
    return (_database.select(_database.projectDatabaseAccessGrants)
          ..where((table) {
            return table.serverId.equals(serverId) &
                table.ownerProjectId.equals(ownerProjectId) &
                table.consumerProjectId.equals(consumerProjectId) &
                table.engine.equals(engine) &
                table.databaseName.equals(databaseName);
          })
          ..limit(1))
        .getSingleOrNull();
  }

  // Discovered work (D-17): this ensure stays local rather than delegating
  // to `ProjectNetworkTrustRepository.linkProjects`, because the two halves
  // differ in load-bearing ways no parameter reconciles in one pass: this
  // one re-stamps `createdAt` on every grant with the grant's own `now` and
  // carries a fixed `'Linked projects'` display name with no transaction,
  // while `linkProjects` preserves `createdAt`, mints its own timestamps,
  // takes the display name from the caller, and wraps the writes in a
  // transaction. Merging them means deciding which createdAt policy wins --
  // a behavior choice, not a tidy-up -- so both halves keep their pinned
  // behavior (see the re-stamp/re-link tests) until that decision lands.
  // The group id itself is already shared via [trustGroupIdFor].
  Future<void> _ensureTrustGroupForProjects({
    required String serverId,
    required String ownerProjectId,
    required String consumerProjectId,
    required DateTime now,
  }) async {
    final sortedProjectIds = [ownerProjectId, consumerProjectId]..sort();
    final groupId = trustGroupIdFor(
      serverId: serverId,
      projectIds: sortedProjectIds,
    );
    await _database
        .into(_database.projectNetworkGroups)
        .insertOnConflictUpdate(
          ProjectNetworkGroupsCompanion.insert(
            id: groupId,
            serverId: serverId,
            displayName: 'Linked projects',
            networkName: 'deploydash_trust_$groupId',
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    for (final projectId in sortedProjectIds) {
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
  }

  // Discovered work (D-17): this prune stays local rather than joining the
  // trust repository's `_deleteGroupsWithFewerThanTwoMembers`, because the
  // trigger differs: this one deletes the pair's group when no grant between
  // the two projects remains, while the trust one sweeps groups by member
  // count. Same tables, different scopes -- one pass cannot merge them
  // without changing when groups disappear.
  Future<void> _deleteTrustGroupIfNoLegacyGrantsRemain(
    ProjectDatabaseAccessGrantRow deletedGrant,
  ) async {
    final remaining =
        await (_database.select(_database.projectDatabaseAccessGrants)
              ..where((table) {
                return table.serverId.equals(deletedGrant.serverId) &
                    table.ownerProjectId.equals(deletedGrant.ownerProjectId) &
                    table.consumerProjectId.equals(
                      deletedGrant.consumerProjectId,
                    );
              })
              ..limit(1))
            .getSingleOrNull();
    if (remaining != null) {
      return;
    }
    final sortedProjectIds = [
      deletedGrant.ownerProjectId,
      deletedGrant.consumerProjectId,
    ]..sort();
    final groupId = trustGroupIdFor(
      serverId: deletedGrant.serverId,
      projectIds: sortedProjectIds,
    );
    await (_database.delete(
      _database.projectNetworkGroupMembers,
    )..where((table) => table.groupId.equals(groupId))).go();
    await (_database.delete(
      _database.projectNetworkGroups,
    )..where((table) => table.id.equals(groupId))).go();
  }

  static ProjectDatabaseAccessGrantRecord _mapGrant(
    ProjectDatabaseAccessGrantRow row,
  ) {
    return ProjectDatabaseAccessGrantRecord(
      id: row.id,
      serverId: row.serverId,
      ownerProjectId: row.ownerProjectId,
      consumerProjectId: row.consumerProjectId,
      engine: _normalizeEngine(row.engine),
      databaseName: row.databaseName,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  static ProjectDatabaseAccessUserRecord _mapUser(
    ProjectDatabaseAccessUserRow row,
  ) {
    return ProjectDatabaseAccessUserRecord(
      id: row.id,
      grantId: row.grantId,
      engine: _normalizeEngine(row.engine),
      databaseName: row.databaseName,
      username: row.username,
      accessMode: _normalizeAccessMode(row.accessMode),
      host: trimOrNull(row.host),
      port: row.port,
      connectionUri: trimOrNull(row.connectionUri),
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  static String _normalizeEngine(String value) {
    return 'postgres';
  }

  static String _normalizeAccessMode(String value) {
    return value.trim().toLowerCase() == 'read_only'
        ? 'read_only'
        : 'read_write';
  }
}

/// The app-wide database-access repository.
final projectDatabaseAccessRepositoryProvider =
    Provider<ProjectDatabaseAccessRepository>((ref) {
      final database = ref.watch(appDatabaseProvider);
      return ProjectDatabaseAccessRepository(database);
    });
