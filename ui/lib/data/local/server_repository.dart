import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/server.dart';
import '../../utils/trim_or_null.dart';
import 'app_database.dart';
import 'server_config_json_codecs.dart';
import 'server_credential_repository.dart';

export '../../domain/server.dart';

/// What the user typed on the add-server form, before anything is saved.
///
/// Carries credentials, so it never leaves this layer: a `Server` is what the
/// rest of the app sees, and it has no key or password on it.
class ServerDraft {
  /// Records one add-server attempt.
  const ServerDraft({
    required this.name,
    required this.host,
    required this.port,
    required this.sshUser,
    required this.authMethod,
    this.sshPassword,
    this.keyPath,
    this.privateKey,
    this.publicKey,
    this.managedUserPassword,
  });

  /// What the user calls this server.
  final String name;

  /// Its hostname or IP.
  final String host;

  /// The SSH port.
  final int port;

  /// The account to connect as. Usually `root` at this point; onboarding then
  /// hands ownership over to a managed `ubuntu` account.
  final String sshUser;

  /// Whether to connect with a password or a key.
  final ServerAuthMethod authMethod;

  /// The password, when connecting with one.
  final String? sshPassword;

  /// Where the key was picked from on the workstation.
  ///
  /// Kept only to show the user which file they chose. The key's *contents*
  /// are what is stored and sent -- a packaged release cannot assume a picked
  /// path is still readable later.
  final String? keyPath;

  /// The private key's contents.
  final String? privateKey;

  /// The matching public key, when the user supplied one.
  final String? publicKey;

  /// The managed account's unix password, from the setup result (#62).
  ///
  /// Carried from onboarding into the credential store alongside the managed
  /// key. Never sent as SSH authentication.
  final String? managedUserPassword;

  /// Sentinel distinguishing "not passed" from an explicit null.
  static const Object noChange = Object();

  // One canonical copier for draft derivation: the onboarding builders
  // derive managed/saved drafts through it instead of respelling fields.
  // coverage-gate: server_draft_copy_with
  /// Copies this draft, replacing only the passed fields.
  ServerDraft copyWith({
    String? name,
    String? host,
    int? port,
    String? sshUser,
    ServerAuthMethod? authMethod,
    Object? sshPassword = noChange,
    Object? keyPath = noChange,
    Object? privateKey = noChange,
    Object? publicKey = noChange,
    Object? managedUserPassword = noChange,
  }) {
    return ServerDraft(
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      sshUser: sshUser ?? this.sshUser,
      authMethod: authMethod ?? this.authMethod,
      sshPassword: identical(sshPassword, noChange)
          ? this.sshPassword
          : sshPassword as String?,
      keyPath: identical(keyPath, noChange) ? this.keyPath : keyPath as String?,
      privateKey: identical(privateKey, noChange)
          ? this.privateKey
          : privateKey as String?,
      publicKey: identical(publicKey, noChange)
          ? this.publicKey
          : publicKey as String?,
      managedUserPassword: identical(managedUserPassword, noChange)
          ? this.managedUserPassword
          : managedUserPassword as String?,
    );
  }
  // end coverage-gate
}

/// What a connectivity check learned about a server.
class ServerSpecs {
  /// Records one check's findings.
  const ServerSpecs({
    this.osName,
    this.cpuArch,
    this.memoryMb,
    this.diskGb,
    this.lastCheckStatus = 'success',
    this.lastError,
    this.rawResponse = const {},
  });

  /// The operating system reported.
  final String? osName;

  /// The CPU architecture reported.
  final String? cpuArch;

  /// Memory in MB.
  final int? memoryMb;

  /// Disk in GB.
  final int? diskGb;

  /// How the check ended.
  final String lastCheckStatus;

  /// What went wrong, when it did.
  final String? lastError;

  /// The engine's whole reply, for diagnostics.
  final Map<String, dynamic> rawResponse;
}

/// Where the app is in onboarding, and which server it is working on.
class OnboardingStateSnapshot {
  /// Records the onboarding state.
  const OnboardingStateSnapshot({
    required this.isCompleted,
    this.activeServerId,
    this.currentStep,
  });

  /// Whether at least one server has been added, which is what "onboarded"
  /// means here.
  final bool isCompleted;

  /// The server currently selected, or null when none is.
  final String? activeServerId;

  /// The onboarding step being shown, when one is.
  final String? currentStep;
}

/// Reads and writes saved servers, their configuration, and onboarding state.
///
/// Credentials are *not* stored here: they go to
/// [ServerCredentialRepository], and this class writes the two together in one
/// transaction so a server row can never exist without the credential that
/// reaches it, or outlive it.
///
/// The per-service configuration columns hold versioned JSON, encoded and
/// decoded by [ServerConfigJsonCodecs] and never by hand.
class ServerRepository {
  /// Creates the repository over the app database and the credential store.
  ServerRepository(this._database, this._credentialRepository);

  final AppDatabase _database;
  final ServerCredentialRepository _credentialRepository;

  /// Every saved server, by name.
  Future<List<Server>> listServers() async {
    final rows = await (_database.select(
      _database.servers,
    )..orderBy([(table) => OrderingTerm.asc(table.name)])).get();
    return rows.map(_mapRow).toList(growable: false);
  }

  /// The current onboarding state, or a fresh one when nothing is saved.
  Future<OnboardingStateSnapshot> readOnboardingState() async {
    final onboarding = await (_database.select(
      _database.onboardingStateEntries,
    )..where((table) => table.id.equals(1))).getSingleOrNull();
    if (onboarding == null) {
      return const OnboardingStateSnapshot(isCompleted: false);
    }
    return OnboardingStateSnapshot(
      isCompleted: onboarding.isCompleted,
      activeServerId: onboarding.activeServerId,
      currentStep: onboarding.currentStep,
    );
  }

  /// Saves a checked server with its credentials and marks onboarding done.
  ///
  /// All in one transaction: the row, the credential, and the onboarding state
  /// that points at it. A server saved without its credential would appear in
  /// the list and fail on every operation.
  ///
  /// The four service configurations are written at their defaults rather than
  /// left null, so every saved server has a complete, decodable configuration
  /// from the moment it exists.
  Future<Server> createServer({
    required ServerDraft draft,
    required ServerSpecs specs,
    String onboardingStep = 'services_selection',
    bool setupComplete = true,
  }) async {
    final timestamp = DateTime.now();
    final serverId = _createServerId(draft.name, timestamp);

    await _database.transaction(() async {
      await _database
          .into(_database.servers)
          .insert(
            ServersCompanion.insert(
              id: serverId,
              name: draft.name.trim(),
              host: draft.host.trim(),
              port: Value(draft.port),
              sshUser: draft.sshUser.trim(),
              authMethod: Value(_authMethodToStorage(draft.authMethod)),
              osName: Value(trimOrNull(specs.osName)),
              cpuArch: Value(trimOrNull(specs.cpuArch)),
              memoryMb: Value(specs.memoryMb),
              diskGb: Value(specs.diskGb),
              serviceDatabaseEnabled: const Value(false),
              serviceEmailEnabled: const Value(false),
              serviceDomainEnabled: const Value(false),
              serviceWebServerConfigJson: Value(
                ServerConfigJsonCodecs.webServer.encode(
                  ServerWebServerConfig.defaults,
                ),
              ),
              servicePostgresConfigJson: Value(
                ServerConfigJsonCodecs.postgres.encode(
                  ServerPostgresConfig.defaults,
                ),
              ),
              serviceFirewallConfigJson: Value(
                ServerConfigJsonCodecs.firewall.encode(
                  ServerFirewallConfig.defaults,
                ),
              ),
              serviceSystemConfigJson: Value(
                ServerConfigJsonCodecs.system.encode(
                  ServerSystemConfig.defaults,
                ),
              ),
              lastCheckStatus: Value(specs.lastCheckStatus),
              lastError: Value(trimOrNull(specs.lastError)),
              lastCheckedAt: Value(timestamp),
              createdAt: Value(timestamp),
              updatedAt: Value(timestamp),
              setupComplete: Value(setupComplete),
            ),
          );

      // coverage-gate: server_repository_managed_password_create
      await _credentialRepository.write(
        reference: ServerCredentialReference(serverId),
        sshPassword: draft.sshPassword,
        privateKey: draft.privateKey,
        publicKey: draft.publicKey,
        managedUserPassword: draft.managedUserPassword,
      );
      // end coverage-gate

      await _database
          .into(_database.onboardingStateEntries)
          .insertOnConflictUpdate(
            OnboardingStateEntriesCompanion(
              id: const Value(1),
              isCompleted: const Value(true),
              activeServerId: Value(serverId),
              currentStep: Value(onboardingStep),
              updatedAt: Value(timestamp),
            ),
          );
    });

    final row = await (_database.select(
      _database.servers,
    )..where((table) => table.id.equals(serverId))).getSingle();
    return _mapRow(row);
  }

  /// Pivots an early-saved server to its verified managed identity.
  ///
  /// All in one transaction: the row takes the managed user and key
  /// authentication, the credential row is replaced with the managed key
  /// (the bootstrap password or key is dropped, never rewritten), and the
  /// onboarding step advances to service selection. A server left behind by
  /// a failed setup keeps its bootstrap material under `setup_in_progress`
  /// so a retry can still reach the machine.
  Future<Server> adoptManagedIdentity({
    required String serverId,
    required String sshUser,
    required ServerAuthMethod authMethod,
    String? privateKey,
    String? publicKey,
    String? managedUserPassword,
  }) async {
    final timestamp = DateTime.now();

    await _database.transaction(() async {
      await (_database.update(
        _database.servers,
      )..where((table) => table.id.equals(serverId))).write(
        ServersCompanion(
          sshUser: Value(sshUser.trim()),
          authMethod: Value(_authMethodToStorage(authMethod)),
          setupComplete: const Value(true),
          updatedAt: Value(timestamp),
        ),
      );

      await _credentialRepository.write(
        reference: ServerCredentialReference(serverId),
        privateKey: privateKey,
        publicKey: publicKey,
        managedUserPassword: managedUserPassword,
      );

      await _database
          .into(_database.onboardingStateEntries)
          .insertOnConflictUpdate(
            OnboardingStateEntriesCompanion(
              id: const Value(1),
              activeServerId: Value(serverId),
              currentStep: const Value('services_selection'),
              updatedAt: Value(timestamp),
            ),
          );
    });

    final row = await (_database.select(
      _database.servers,
    )..where((table) => table.id.equals(serverId))).getSingle();
    return _mapRow(row);
  }

  // coverage-gate: server_onboarding_writers
  // One owner of the stamp-and-upsert skeleton behind the onboarding-state
  // writers: the clock read and the singleton-row upsert live here, while
  // each writer keeps its exact column set (including id 1 and its own
  // updatedAt stamp). Mirrors _writeServerColumn one table over.
  Future<void> _writeOnboardingColumn(
    OnboardingStateEntriesCompanion Function(DateTime now) build,
  ) async {
    final now = DateTime.now();
    await _database
        .into(_database.onboardingStateEntries)
        .insertOnConflictUpdate(build(now));
  }

  /// Rewrites the bootstrap identity of a server that has not finished
  /// setup, keeping its id and pending state.
  ///
  /// The wizard saves once per opening and updates on every later Finish:
  /// reprovisioning the same record instead of creating a duplicate, and
  /// picking up credential edits made after the first save. Only
  /// bootstrap-identity columns move; service configs stay as created.
  /// Refuses a missing id or a server that already finished setup.
  Future<Server> updatePendingServer({
    required String serverId,
    required ServerDraft draft,
    required ServerSpecs specs,
  }) async {
    final timestamp = DateTime.now();

    await _database.transaction(() async {
      final updated =
          await (_database.update(_database.servers)..where(
                (table) =>
                    table.id.equals(serverId) &
                    table.setupComplete.equals(false),
              ))
              .write(
                ServersCompanion(
                  name: Value(draft.name.trim()),
                  host: Value(draft.host.trim()),
                  port: Value(draft.port),
                  sshUser: Value(draft.sshUser.trim()),
                  authMethod: Value(_authMethodToStorage(draft.authMethod)),
                  osName: Value(trimOrNull(specs.osName)),
                  cpuArch: Value(trimOrNull(specs.cpuArch)),
                  memoryMb: Value(specs.memoryMb),
                  diskGb: Value(specs.diskGb),
                  lastCheckStatus: Value(specs.lastCheckStatus),
                  lastError: Value(trimOrNull(specs.lastError)),
                  lastCheckedAt: Value(timestamp),
                  updatedAt: Value(timestamp),
                ),
              );
      if (updated == 0) {
        throw StateError(
          'updatePendingServer called for $serverId, which is missing or '
          'already finished setup.',
        );
      }

      await _credentialRepository.write(
        reference: ServerCredentialReference(serverId),
        sshPassword: draft.sshPassword,
        privateKey: draft.privateKey,
        publicKey: draft.publicKey,
        managedUserPassword: draft.managedUserPassword,
      );
    });

    final row = await (_database.select(
      _database.servers,
    )..where((table) => table.id.equals(serverId))).getSingle();
    return _mapRow(row);
  }

  /// Ids of servers saved before provisioning finished.
  ///
  /// The `Server` domain value deliberately carries no setup state (it
  /// would ride along on every one of its copies); callers that render or
  /// gate on incompleteness read this set instead.
  Future<Set<String>> readPendingSetupServerIds() async {
    final rows =
        await (_database.selectOnly(_database.servers)
              ..addColumns([_database.servers.id])
              ..where(_database.servers.setupComplete.equals(false)))
            .get();
    return rows.map((row) => row.read(_database.servers.id)!).toSet();
  }

  /// Forgets the chosen server without touching onboarding completion.
  /// The column stays -- `deleteServer` still reconciles against it. G-35.
  Future<void> clearActiveServer() async => _writeOnboardingColumn(
    (now) => OnboardingStateEntriesCompanion(
      id: const Value(1),
      activeServerId: const Value(null),
      updatedAt: Value(now),
    ),
  );

  /// Selects a server, and marks onboarding complete.
  Future<void> setActiveServer(String serverId) async => _writeOnboardingColumn(
    (now) => OnboardingStateEntriesCompanion(
      id: const Value(1),
      activeServerId: Value(serverId),
      isCompleted: const Value(true),
      updatedAt: Value(now),
    ),
  );

  /// Records which onboarding step is showing, so a restart resumes there.
  Future<void> updateOnboardingStep(String step) async =>
      _writeOnboardingColumn(
        (now) => OnboardingStateEntriesCompanion(
          id: const Value(1),
          currentStep: Value(step),
          updatedAt: Value(now),
        ),
      );
  // end coverage-gate

  // coverage-gate: server_column_writers
  // One owner of the stamp-and-write skeleton behind the updateServer*
  // writers: the clock read and the update-by-id live here, while each
  // writer keeps its columns, codec calls, and validation.
  Future<void> _writeServerColumn(
    String serverId,
    ServersCompanion Function(DateTime now) build,
  ) async {
    final now = DateTime.now();
    await (_database.update(
      _database.servers,
    )..where((table) => table.id.equals(serverId))).write(build(now));
  }

  /// Records which managed services are enabled for a server.
  Future<void> updateServerServices({
    required String serverId,
    required bool enableDatabases,
    required bool enableEmailAccounts,
    required bool enableDomains,
  }) async => _writeServerColumn(
    serverId,
    (now) => ServersCompanion(
      serviceDatabaseEnabled: Value(enableDatabases),
      serviceEmailEnabled: Value(enableEmailAccounts),
      serviceDomainEnabled: Value(enableDomains),
      updatedAt: Value(now),
    ),
  );

  /// Saves the web-server (Caddy) configuration.
  Future<void> updateServerWebServerConfig({
    required String serverId,
    required ServerWebServerConfig config,
  }) async => _writeServerColumn(
    serverId,
    (now) => ServersCompanion(
      serviceWebServerConfigJson: Value(
        ServerConfigJsonCodecs.webServer.encode(config),
      ),
      updatedAt: Value(now),
    ),
  );

  /// Saves the managed PostgreSQL configuration.
  Future<void> updateServerPostgresConfig({
    required String serverId,
    required ServerPostgresConfig config,
  }) async => _writeServerColumn(
    serverId,
    (now) => ServersCompanion(
      servicePostgresConfigJson: Value(
        ServerConfigJsonCodecs.postgres.encode(config),
      ),
      updatedAt: Value(now),
    ),
  );

  /// Saves the firewall configuration.
  Future<void> updateServerFirewallConfig({
    required String serverId,
    required ServerFirewallConfig config,
  }) async => _writeServerColumn(
    serverId,
    (now) => ServersCompanion(
      serviceFirewallConfigJson: Value(
        ServerConfigJsonCodecs.firewall.encode(config),
      ),
      updatedAt: Value(now),
    ),
  );

  /// Saves the system configuration, such as automatic security updates.
  Future<void> updateServerSystemConfig({
    required String serverId,
    required ServerSystemConfig config,
  }) async => _writeServerColumn(
    serverId,
    (now) => ServersCompanion(
      serviceSystemConfigJson: Value(
        ServerConfigJsonCodecs.system.encode(config),
      ),
      updatedAt: Value(now),
    ),
  );

  /// Records which pinned versions of managed software the server is running.
  Future<void> updateServerManagedSoftwareStatus({
    required String serverId,
    required ServerManagedSoftwareStatus status,
  }) async => _writeServerColumn(
    serverId,
    (now) => ServersCompanion(
      managedSoftwareStatusJson: Value(
        ServerConfigJsonCodecs.managedSoftware.encode(status),
      ),
      updatedAt: Value(now),
    ),
  );

  /// Changes the SSH port a server is reached on.
  Future<void> updateServerConnectionPort({
    required String serverId,
    required int port,
  }) async => _writeServerColumn(
    serverId,
    (now) => ServersCompanion(port: Value(port), updatedAt: Value(now)),
  );

  /// Changes the host a server is reached at.
  ///
  /// Throws [ArgumentError] for a blank host: a server row with no host would
  /// fail on every later operation, with the cause long out of sight.
  Future<void> updateServerConnectionHost({
    required String serverId,
    required String host,
  }) async {
    final normalizedHost = host.trim();
    if (normalizedHost.isEmpty) {
      throw ArgumentError.value(host, 'host', 'Server host cannot be empty.');
    }
    return _writeServerColumn(
      serverId,
      (now) =>
          ServersCompanion(host: Value(normalizedHost), updatedAt: Value(now)),
    );
  }
  // end coverage-gate

  /// Replaces a server's private key, keeping any stored passwords.
  ///
  /// One transaction, and the existing passwords are read and rewritten
  /// rather than dropped: a user importing a key has not asked to lose the
  /// login password that is currently the only way in, nor the managed
  /// account password stored as a recovery record.
  ///
  /// Throws [ArgumentError] for a blank key.
  Future<void> updateServerImportedSshKey({
    required String serverId,
    required String privateKey,
    String? publicKey,
  }) async {
    final normalizedPrivateKey = trimOrNull(privateKey);
    if (normalizedPrivateKey == null) {
      throw ArgumentError.value(
        privateKey,
        'privateKey',
        'SSH private key cannot be empty.',
      );
    }
    final now = DateTime.now();
    final reference = ServerCredentialReference(serverId);
    await _database.transaction(() async {
      final existing = await _credentialRepository.read(reference);
      // coverage-gate: server_repository_managed_password_key_import
      await _credentialRepository.write(
        reference: reference,
        sshPassword: existing?.sshPassword,
        privateKey: normalizedPrivateKey,
        publicKey: publicKey,
        managedUserPassword: existing?.managedUserPassword,
      );
      // end coverage-gate
      await (_database.update(_database.servers)
            ..where((table) => table.id.equals(serverId)))
          .write(ServersCompanion(updatedAt: Value(now)));
    });
  }

  /// Saves a server whose connectivity check failed, with the error.
  ///
  /// The row is kept deliberately: a user who mistyped a host should find
  /// their server in the list with an explanation, not an empty list and the
  /// need to type it all again.
  Future<void> saveConnectionFailure({
    required ServerDraft draft,
    required Object error,
  }) async {
    final now = DateTime.now();
    final payload = jsonEncode({'error': error.toString()});
    final serverId = _createServerId(draft.name, now);
    await _database.transaction(() async {
      await _database
          .into(_database.servers)
          .insert(
            ServersCompanion.insert(
              id: serverId,
              name: draft.name.trim(),
              host: draft.host.trim(),
              port: Value(draft.port),
              sshUser: draft.sshUser.trim(),
              authMethod: Value(_authMethodToStorage(draft.authMethod)),
              lastCheckStatus: const Value('error'),
              lastError: Value(payload),
              lastCheckedAt: Value(now),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
      // coverage-gate: server_repository_managed_password_failure
      await _credentialRepository.write(
        reference: ServerCredentialReference(serverId),
        sshPassword: draft.sshPassword,
        privateKey: draft.privateKey,
        publicKey: draft.publicKey,
        managedUserPassword: draft.managedUserPassword,
      );
      // end coverage-gate
    });
  }

  /// Removes a server, its credentials, and reconciles onboarding state.
  ///
  /// One transaction. Selection moves to the first remaining server, or to
  /// nothing when that was the last one -- and the onboarding step follows:
  /// `idle` with no servers left, the preserved step when the selected server
  /// is unaffected, `connected` otherwise. Without that, deleting a server
  /// could leave the app pointing at a row that no longer exists.
  Future<void> deleteServer(String serverId) async {
    final now = DateTime.now();
    await _database.transaction(() async {
      await _credentialRepository.delete(ServerCredentialReference(serverId));
      await (_database.delete(
        _database.servers,
      )..where((table) => table.id.equals(serverId))).go();

      final remainingRows = await (_database.select(
        _database.servers,
      )..orderBy([(table) => OrderingTerm.asc(table.name)])).get();
      final onboarding = await (_database.select(
        _database.onboardingStateEntries,
      )..where((table) => table.id.equals(1))).getSingleOrNull();

      final existingActiveServerId = onboarding?.activeServerId;
      final activeServerStillExists =
          existingActiveServerId != null &&
          remainingRows.any((server) => server.id == existingActiveServerId);
      final nextActiveServerId = remainingRows.isEmpty
          ? null
          : (activeServerStillExists
                ? existingActiveServerId
                : remainingRows.first.id);

      // Hoisted so the checks promote it. A null-aware read being non-null
      // does not promote the receiver, and a row field is never promoted.
      final currentStep = onboarding?.currentStep;
      final nextStep = nextActiveServerId == null
          ? 'idle'
          : (activeServerStillExists &&
                    currentStep != null &&
                    currentStep.trim().isNotEmpty &&
                    currentStep != 'services_selection'
                ? currentStep
                : 'connected');

      await _database
          .into(_database.onboardingStateEntries)
          .insertOnConflictUpdate(
            OnboardingStateEntriesCompanion(
              id: const Value(1),
              isCompleted: Value(remainingRows.isNotEmpty),
              activeServerId: Value(nextActiveServerId),
              currentStep: Value(nextStep),
              updatedAt: Value(now),
            ),
          );
    });
  }

  Server _mapRow(ServerRow row) {
    return Server(
      id: row.id,
      name: row.name,
      host: row.host,
      port: row.port,
      sshUser: row.sshUser,
      authMethod: _authMethodFromStorage(row.authMethod),
      osName: row.osName,
      cpuArch: row.cpuArch,
      memoryMb: row.memoryMb,
      diskGb: row.diskGb,
      serviceDatabaseEnabled: row.serviceDatabaseEnabled,
      serviceEmailEnabled: row.serviceEmailEnabled,
      serviceDomainEnabled: row.serviceDomainEnabled,
      webServerConfig: ServerConfigJsonCodecs.webServer.decode(
        row.serviceWebServerConfigJson,
        fallback: ServerWebServerConfig.defaults,
      ),
      postgresConfig: ServerConfigJsonCodecs.postgres.decode(
        row.servicePostgresConfigJson,
        fallback: ServerPostgresConfig.defaults,
      ),
      firewallConfig: ServerConfigJsonCodecs.firewall.decode(
        row.serviceFirewallConfigJson,
        fallback: ServerFirewallConfig.defaults,
      ),
      systemConfig: ServerConfigJsonCodecs.system.decode(
        row.serviceSystemConfigJson,
        fallback: ServerSystemConfig.defaults,
      ),
      managedSoftwareStatus: row.managedSoftwareStatusJson == null
          ? null
          : ServerConfigJsonCodecs.managedSoftware.decode(
              row.managedSoftwareStatusJson,
              fallback: ServerManagedSoftwareStatus(
                const <String, Map<String, dynamic>>{},
              ),
            ),
      lastCheckStatus: row.lastCheckStatus,
      lastError: row.lastError,
      lastCheckedAt: row.lastCheckedAt,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  static String _createServerId(String name, DateTime timestamp) {
    final slug = name
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final normalized = slug.isEmpty ? 'server' : slug;
    return '${normalized}_${timestamp.microsecondsSinceEpoch}';
  }

  // coverage-gate: server_repository_key_storage

  static String _authMethodToStorage(ServerAuthMethod authMethod) {
    return switch (authMethod) {
      ServerAuthMethod.password => 'password',
      ServerAuthMethod.sshKey => 'ssh_key',
    };
  }

  static ServerAuthMethod _authMethodFromStorage(String value) {
    return value == 'ssh_key'
        ? ServerAuthMethod.sshKey
        : ServerAuthMethod.password;
  }
  // end coverage-gate
}

/// The app-wide server repository.
final serverRepositoryProvider = Provider<ServerRepository>((ref) {
  final database = ref.watch(appDatabaseProvider);
  return ServerRepository(
    database,
    ref.watch(serverCredentialRepositoryProvider),
  );
});

/// Whether a draft carries a usable private key, blank treated as absent.
bool hasServerDraftPrivateKey(ServerDraft draft) {
  return trimOrNull(draft.privateKey) != null;
}
