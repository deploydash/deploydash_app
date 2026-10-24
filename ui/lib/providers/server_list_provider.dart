import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/server_repository.dart';
import '../models/app_user_attribute.dart';
import '../services/app_analytics_service.dart';

class ServerCatalogState {
  const ServerCatalogState({
    this.isLoading = true,
    this.onboardingComplete = false,
    this.servers = const [],
    this.selectedServerId,
    this.onboardingStep,
    this.pendingSetupServerIds = const {},
    this.error,
  });

  final bool isLoading;
  final bool onboardingComplete;
  final List<Server> servers;
  final String? selectedServerId;
  final String? onboardingStep;

  /// Ids of servers saved before provisioning finished. Renderers and
  /// guards read this instead of the global [onboardingStep], which cannot
  /// say *which* server is mid-setup.
  final Set<String> pendingSetupServerIds;
  final String? error;

  bool get hasServers => servers.isNotEmpty;

  /// Whether [serverId] is saved but not yet provisioned.
  bool isServerSetupPending(String serverId) =>
      pendingSetupServerIds.contains(serverId);

  Server? get selectedServer {
    if (servers.isEmpty) {
      return null;
    }
    final selectedId = selectedServerId;
    if (selectedId == null) {
      return servers.first;
    }
    for (final server in servers) {
      if (server.id == selectedId) {
        return server;
      }
    }
    return servers.first;
  }

  ServerCatalogState copyWith({
    bool? isLoading,
    bool? onboardingComplete,
    List<Server>? servers,
    String? selectedServerId,
    String? onboardingStep,
    Set<String>? pendingSetupServerIds,
    String? error,
    bool clearSelectedServerId = false,
    bool clearError = false,
  }) {
    return ServerCatalogState(
      isLoading: isLoading ?? this.isLoading,
      onboardingComplete: onboardingComplete ?? this.onboardingComplete,
      servers: servers ?? this.servers,
      selectedServerId: clearSelectedServerId
          ? null
          : (selectedServerId ?? this.selectedServerId),
      onboardingStep: onboardingStep ?? this.onboardingStep,
      pendingSetupServerIds:
          pendingSetupServerIds ?? this.pendingSetupServerIds,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ServerCatalogNotifier extends Notifier<ServerCatalogState> {
  bool _didInitialize = false;

  @override
  ServerCatalogState build() {
    if (!_didInitialize) {
      _didInitialize = true;
      scheduleMicrotask(_loadFromDatabase);
    }
    return const ServerCatalogState(isLoading: true);
  }

  Future<void> refresh() => _loadFromDatabase();

  Future<void> selectServer(String serverId) async {
    await ref.read(serverRepositoryProvider).setActiveServer(serverId);
    state = state.copyWith(selectedServerId: serverId, clearError: true);
  }

  Future<void> setOnboardingStep(String step) async {
    await ref.read(serverRepositoryProvider).updateOnboardingStep(step);
    state = state.copyWith(onboardingStep: step);
  }

  Future<String?> removeSelectedServer() async {
    final selected = state.selectedServer;
    if (selected == null) {
      return null;
    }
    await ref.read(serverRepositoryProvider).deleteServer(selected.id);
    await _loadFromDatabase();
    if (state.error == null) {
      // coverage-gate: server_count_bucket_remove
      ref
          .read(appAnalyticsServiceProvider)
          .setUserAttribute(
            AppUserAttribute.serverCountBucket,
            analyticsBucketForCount(state.servers.length),
          );
      // end coverage-gate
    }
    return selected.name;
  }

  Future<void> updateSelectedServerServices({
    required bool enableDatabases,
    required bool enableEmailAccounts,
    required bool enableDomains,
  }) async {
    final selected = state.selectedServer;
    if (selected == null) {
      return;
    }
    await ref
        .read(serverRepositoryProvider)
        .updateServerServices(
          serverId: selected.id,
          enableDatabases: enableDatabases,
          enableEmailAccounts: enableEmailAccounts,
          enableDomains: enableDomains,
        );

    final updatedServers = state.servers
        .map((server) {
          if (server.id != selected.id) {
            return server;
          }
          return Server(
            id: server.id,
            name: server.name,
            host: server.host,
            port: server.port,
            sshUser: server.sshUser,
            authMethod: server.authMethod,
            osName: server.osName,
            cpuArch: server.cpuArch,
            memoryMb: server.memoryMb,
            diskGb: server.diskGb,
            serviceDatabaseEnabled: enableDatabases,
            serviceEmailEnabled: enableEmailAccounts,
            serviceDomainEnabled: enableDomains,
            webServerConfig: server.webServerConfig,
            postgresConfig: server.postgresConfig,
            firewallConfig: server.firewallConfig,
            systemConfig: server.systemConfig,
            lastCheckStatus: server.lastCheckStatus,
            lastError: server.lastError,
            lastCheckedAt: server.lastCheckedAt,
            createdAt: server.createdAt,
            updatedAt: DateTime.now(),
          );
        })
        .toList(growable: false);
    state = state.copyWith(servers: updatedServers);
  }

  Future<void> updateSelectedServerWebServerConfig(
    ServerWebServerConfig config,
  ) async {
    final selected = state.selectedServer;
    if (selected == null) {
      return;
    }

    await ref
        .read(serverRepositoryProvider)
        .updateServerWebServerConfig(serverId: selected.id, config: config);

    final updatedServers = state.servers
        .map((server) {
          if (server.id != selected.id) {
            return server;
          }
          return Server(
            id: server.id,
            name: server.name,
            host: server.host,
            port: server.port,
            sshUser: server.sshUser,
            authMethod: server.authMethod,
            osName: server.osName,
            cpuArch: server.cpuArch,
            memoryMb: server.memoryMb,
            diskGb: server.diskGb,
            serviceDatabaseEnabled: server.serviceDatabaseEnabled,
            serviceEmailEnabled: server.serviceEmailEnabled,
            serviceDomainEnabled: server.serviceDomainEnabled,
            webServerConfig: config,
            postgresConfig: server.postgresConfig,
            firewallConfig: server.firewallConfig,
            systemConfig: server.systemConfig,
            lastCheckStatus: server.lastCheckStatus,
            lastError: server.lastError,
            lastCheckedAt: server.lastCheckedAt,
            createdAt: server.createdAt,
            updatedAt: DateTime.now(),
          );
        })
        .toList(growable: false);

    state = state.copyWith(servers: updatedServers);
  }

  Future<void> updateSelectedServerPostgresConfig(
    ServerPostgresConfig config,
  ) async {
    final selected = state.selectedServer;
    if (selected == null) {
      return;
    }

    await ref
        .read(serverRepositoryProvider)
        .updateServerPostgresConfig(serverId: selected.id, config: config);

    final updatedServers = state.servers
        .map((server) {
          if (server.id != selected.id) {
            return server;
          }
          return Server(
            id: server.id,
            name: server.name,
            host: server.host,
            port: server.port,
            sshUser: server.sshUser,
            authMethod: server.authMethod,
            osName: server.osName,
            cpuArch: server.cpuArch,
            memoryMb: server.memoryMb,
            diskGb: server.diskGb,
            serviceDatabaseEnabled: server.serviceDatabaseEnabled,
            serviceEmailEnabled: server.serviceEmailEnabled,
            serviceDomainEnabled: server.serviceDomainEnabled,
            webServerConfig: server.webServerConfig,
            postgresConfig: config,
            firewallConfig: server.firewallConfig,
            systemConfig: server.systemConfig,
            lastCheckStatus: server.lastCheckStatus,
            lastError: server.lastError,
            lastCheckedAt: server.lastCheckedAt,
            createdAt: server.createdAt,
            updatedAt: DateTime.now(),
          );
        })
        .toList(growable: false);

    state = state.copyWith(servers: updatedServers);
  }

  Future<void> updateSelectedServerFirewallConfig(
    ServerFirewallConfig config,
  ) async {
    final selected = state.selectedServer;
    if (selected == null) {
      return;
    }

    await ref
        .read(serverRepositoryProvider)
        .updateServerFirewallConfig(serverId: selected.id, config: config);

    final updatedServers = state.servers
        .map((server) {
          if (server.id != selected.id) {
            return server;
          }
          return Server(
            id: server.id,
            name: server.name,
            host: server.host,
            port: server.port,
            sshUser: server.sshUser,
            authMethod: server.authMethod,
            osName: server.osName,
            cpuArch: server.cpuArch,
            memoryMb: server.memoryMb,
            diskGb: server.diskGb,
            serviceDatabaseEnabled: server.serviceDatabaseEnabled,
            serviceEmailEnabled: server.serviceEmailEnabled,
            serviceDomainEnabled: server.serviceDomainEnabled,
            webServerConfig: server.webServerConfig,
            postgresConfig: server.postgresConfig,
            firewallConfig: config,
            systemConfig: server.systemConfig,
            lastCheckStatus: server.lastCheckStatus,
            lastError: server.lastError,
            lastCheckedAt: server.lastCheckedAt,
            createdAt: server.createdAt,
            updatedAt: DateTime.now(),
          );
        })
        .toList(growable: false);

    state = state.copyWith(servers: updatedServers);
  }

  Future<void> updateSelectedServerSystemConfig(
    ServerSystemConfig config,
  ) async {
    final selected = state.selectedServer;
    if (selected == null) {
      return;
    }

    await ref
        .read(serverRepositoryProvider)
        .updateServerSystemConfig(serverId: selected.id, config: config);

    final updatedServers = state.servers
        .map((server) {
          if (server.id != selected.id) {
            return server;
          }
          return Server(
            id: server.id,
            name: server.name,
            host: server.host,
            port: server.port,
            sshUser: server.sshUser,
            authMethod: server.authMethod,
            osName: server.osName,
            cpuArch: server.cpuArch,
            memoryMb: server.memoryMb,
            diskGb: server.diskGb,
            serviceDatabaseEnabled: server.serviceDatabaseEnabled,
            serviceEmailEnabled: server.serviceEmailEnabled,
            serviceDomainEnabled: server.serviceDomainEnabled,
            webServerConfig: server.webServerConfig,
            postgresConfig: server.postgresConfig,
            firewallConfig: server.firewallConfig,
            systemConfig: config,
            lastCheckStatus: server.lastCheckStatus,
            lastError: server.lastError,
            lastCheckedAt: server.lastCheckedAt,
            createdAt: server.createdAt,
            updatedAt: DateTime.now(),
          );
        })
        .toList(growable: false);

    state = state.copyWith(servers: updatedServers);
  }

  Future<void> updateSelectedServerConnectionPort(int port) async {
    final selected = state.selectedServer;
    if (selected == null) {
      return;
    }
    await ref
        .read(serverRepositoryProvider)
        .updateServerConnectionPort(serverId: selected.id, port: port);

    final updatedServers = state.servers
        .map((server) {
          if (server.id != selected.id) {
            return server;
          }
          return Server(
            id: server.id,
            name: server.name,
            host: server.host,
            port: port,
            sshUser: server.sshUser,
            authMethod: server.authMethod,
            osName: server.osName,
            cpuArch: server.cpuArch,
            memoryMb: server.memoryMb,
            diskGb: server.diskGb,
            serviceDatabaseEnabled: server.serviceDatabaseEnabled,
            serviceEmailEnabled: server.serviceEmailEnabled,
            serviceDomainEnabled: server.serviceDomainEnabled,
            webServerConfig: server.webServerConfig,
            postgresConfig: server.postgresConfig,
            firewallConfig: server.firewallConfig,
            systemConfig: server.systemConfig,
            lastCheckStatus: server.lastCheckStatus,
            lastError: server.lastError,
            lastCheckedAt: server.lastCheckedAt,
            createdAt: server.createdAt,
            updatedAt: DateTime.now(),
          );
        })
        .toList(growable: false);
    state = state.copyWith(servers: updatedServers);
  }

  Future<void> updateSelectedServerConnectionHost(String host) async {
    final selected = state.selectedServer;
    if (selected == null) {
      return;
    }
    final normalizedHost = host.trim();
    await ref
        .read(serverRepositoryProvider)
        .updateServerConnectionHost(
          serverId: selected.id,
          host: normalizedHost,
        );

    final updatedServers = state.servers
        .map((server) {
          if (server.id != selected.id) {
            return server;
          }
          return Server(
            id: server.id,
            name: server.name,
            host: normalizedHost,
            port: server.port,
            sshUser: server.sshUser,
            authMethod: server.authMethod,
            osName: server.osName,
            cpuArch: server.cpuArch,
            memoryMb: server.memoryMb,
            diskGb: server.diskGb,
            serviceDatabaseEnabled: server.serviceDatabaseEnabled,
            serviceEmailEnabled: server.serviceEmailEnabled,
            serviceDomainEnabled: server.serviceDomainEnabled,
            webServerConfig: server.webServerConfig,
            postgresConfig: server.postgresConfig,
            firewallConfig: server.firewallConfig,
            systemConfig: server.systemConfig,
            lastCheckStatus: server.lastCheckStatus,
            lastError: server.lastError,
            lastCheckedAt: server.lastCheckedAt,
            createdAt: server.createdAt,
            updatedAt: DateTime.now(),
          );
        })
        .toList(growable: false);
    state = state.copyWith(servers: updatedServers);
  }

  // coverage-gate: update_selected_server_imported_ssh_key
  Future<void> updateSelectedServerImportedSshKey({
    required String privateKey,
    String? publicKey,
  }) async {
    final selected = state.selectedServer;
    if (selected == null) {
      return;
    }
    await ref
        .read(serverRepositoryProvider)
        .updateServerImportedSshKey(
          serverId: selected.id,
          privateKey: privateKey,
          publicKey: publicKey,
        );

    final updatedServers = state.servers
        .map((server) {
          if (server.id != selected.id) {
            return server;
          }
          return Server(
            id: server.id,
            name: server.name,
            host: server.host,
            port: server.port,
            sshUser: server.sshUser,
            authMethod: server.authMethod,
            osName: server.osName,
            cpuArch: server.cpuArch,
            memoryMb: server.memoryMb,
            diskGb: server.diskGb,
            serviceDatabaseEnabled: server.serviceDatabaseEnabled,
            serviceEmailEnabled: server.serviceEmailEnabled,
            serviceDomainEnabled: server.serviceDomainEnabled,
            webServerConfig: server.webServerConfig,
            postgresConfig: server.postgresConfig,
            firewallConfig: server.firewallConfig,
            systemConfig: server.systemConfig,
            lastCheckStatus: server.lastCheckStatus,
            lastError: server.lastError,
            lastCheckedAt: server.lastCheckedAt,
            createdAt: server.createdAt,
            updatedAt: DateTime.now(),
          );
        })
        .toList(growable: false);
    state = state.copyWith(servers: updatedServers);
  }
  // end coverage-gate

  Future<Server> saveConnectedServer({
    required ServerDraft draft,
    required Map<String, dynamic> checkResult,
    String onboardingStep = 'services_selection',
    bool setupComplete = true,
  }) async {
    final repository = ref.read(serverRepositoryProvider);
    state = state.copyWith(isLoading: true, clearError: true);

    final specs = _specsFromCheckResult(checkResult);

    try {
      final server = await repository.createServer(
        draft: draft,
        specs: specs,
        onboardingStep: onboardingStep,
        setupComplete: setupComplete,
      );
      final updatedServers = [...state.servers, server]
        ..sort((left, right) => left.name.compareTo(right.name));
      final updatedPending = {...state.pendingSetupServerIds};
      if (setupComplete) {
        updatedPending.remove(server.id);
      } else {
        updatedPending.add(server.id);
      }

      state = state.copyWith(
        isLoading: false,
        onboardingComplete: true,
        servers: updatedServers,
        selectedServerId: server.id,
        onboardingStep: onboardingStep,
        pendingSetupServerIds: updatedPending,
        clearError: true,
      );
      // coverage-gate: server_count_bucket_save
      ref
          .read(appAnalyticsServiceProvider)
          .setUserAttribute(
            AppUserAttribute.serverCountBucket,
            analyticsBucketForCount(updatedServers.length),
          );
      // end coverage-gate
      return server;
    } catch (error) {
      await repository.saveConnectionFailure(draft: draft, error: error);
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to persist server details: $error',
        onboardingStep: 'failed',
      );
      rethrow;
    }
  }

  /// Rewrites the bootstrap identity of an early-saved server in place.
  ///
  /// The wizard saves once per opening and updates on every later Finish,
  /// so reprovisioning the same record never creates a duplicate. The
  /// entry keeps its id, selection, and pending state.
  Future<Server> updatePendingServer({
    required String serverId,
    required ServerDraft draft,
    required Map<String, dynamic> checkResult,
  }) async {
    final repository = ref.read(serverRepositoryProvider);
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final server = await repository.updatePendingServer(
        serverId: serverId,
        draft: draft,
        specs: _specsFromCheckResult(checkResult),
      );
      state = state.copyWith(
        isLoading: false,
        servers: _replaceServer(state.servers, server),
        clearError: true,
      );
      return server;
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to update server details: $error',
      );
      rethrow;
    }
  }

  /// Pivots an early-saved server to its verified managed identity.
  ///
  /// The repository replaces the bootstrap credential with the managed key
  /// in the same transaction; this refreshes the matching list entry and
  /// advances the step to service selection.
  Future<Server> adoptManagedServerIdentity({
    required String serverId,
    required String sshUser,
    required ServerAuthMethod authMethod,
    String? privateKey,
    String? publicKey,
    String? managedUserPassword,
  }) async {
    final adopted = await ref
        .read(serverRepositoryProvider)
        .adoptManagedIdentity(
          serverId: serverId,
          sshUser: sshUser,
          authMethod: authMethod,
          privateKey: privateKey,
          publicKey: publicKey,
          managedUserPassword: managedUserPassword,
        );
    final updatedServers = _replaceServer(state.servers, adopted);
    final updatedPending = {...state.pendingSetupServerIds}..remove(adopted.id);
    state = state.copyWith(
      isLoading: false,
      servers: updatedServers,
      selectedServerId: adopted.id,
      onboardingStep: 'services_selection',
      pendingSetupServerIds: updatedPending,
      clearError: true,
    );
    return adopted;
  }

  Future<void> _loadFromDatabase() async {
    final repository = ref.read(serverRepositoryProvider);
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final servers = await repository.listServers();
      final onboarding = await repository.readOnboardingState();
      final pendingSetupServerIds = await repository
          .readPendingSetupServerIds();

      // G-35: the chosen server is session state, not durable state. The
      // candidate comes from the in-memory selection, which is null only on
      // the first load of a process -- so a relaunch starts with nothing
      // selected, while an in-session refresh() keeps what the user chose.
      // `onboarding.activeServerId` is deliberately not read here.
      String? selectedId = state.selectedServerId;
      if (selectedId != null &&
          !servers.any((server) => server.id == selectedId)) {
        selectedId = null;
      }

      if (selectedId != null) {
        await repository.setActiveServer(selectedId);
      } else {
        // Leave no stale value on disk for a future read path to resurrect,
        // and none in an exported database snapshot. G-35.
        await repository.clearActiveServer();
      }

      state = state.copyWith(
        isLoading: false,
        onboardingComplete: onboarding.isCompleted || servers.isNotEmpty,
        servers: servers,
        // `copyWith` treats a null `selectedServerId` as "leave unchanged", so
        // clearing needs the explicit flag. Passing null alone would keep a
        // selection pointing at a server that no longer exists. G-35.
        selectedServerId: selectedId,
        clearSelectedServerId: selectedId == null,
        onboardingStep:
            onboarding.currentStep ?? (servers.isEmpty ? 'idle' : 'connected'),
        pendingSetupServerIds: pendingSetupServerIds,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        onboardingComplete: false,
        servers: const [],
        clearSelectedServerId: true,
        pendingSetupServerIds: const {},
        error: 'Failed to load servers: $error',
      );
    }
  }

  static ServerSpecs _specsFromCheckResult(Map<String, dynamic> checkResult) {
    return ServerSpecs(
      osName: _readString(checkResult['os']),
      cpuArch: _readString(checkResult['cpu']),
      memoryMb: _readInt(checkResult['memory_mb'] ?? checkResult['memory']),
      diskGb: _readInt(checkResult['disk_gb'] ?? checkResult['disk']),
      lastCheckStatus: _readString(checkResult['status']) ?? 'success',
      lastError: _readString(checkResult['msg']),
      rawResponse: checkResult,
    );
  }

  static List<Server> _replaceServer(List<Server> servers, Server updated) {
    final replaced =
        servers
            .map((server) => server.id == updated.id ? updated : server)
            .toList(growable: false)
          ..sort((left, right) => left.name.compareTo(right.name));
    return replaced;
  }

  static String? _readString(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return value.toString();
  }

  static int? _readInt(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString());
  }
}

final serverCatalogProvider =
    NotifierProvider<ServerCatalogNotifier, ServerCatalogState>(
      ServerCatalogNotifier.new,
    );

final serverListProvider = Provider<List<Server>>((ref) {
  return ref.watch(serverCatalogProvider).servers;
});

final selectedServerIdProvider = Provider<String?>((ref) {
  return ref.watch(serverCatalogProvider).selectedServerId;
});

final selectedServerProvider = Provider<Server?>((ref) {
  return ref.watch(serverCatalogProvider).selectedServer;
});
