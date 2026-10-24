import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/models/result.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/providers/server_onboarding_provider.dart';
import 'package:ui/providers/server_provider.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_support/fake_analytics_service.dart';

ServerDraft _draft(String name) {
  return ServerDraft(
    name: name,
    host: '203.0.113.10',
    port: 22,
    sshUser: 'root',
    authMethod: ServerAuthMethod.password,
    sshPassword: 'secret',
  );
}

ServerSpecs _specs() {
  return const ServerSpecs(
    osName: 'Ubuntu 22.04',
    cpuArch: 'x86_64',
    memoryMb: 4096,
    diskGb: 100,
    lastCheckStatus: 'success',
  );
}

Future<void> _waitForLoaded(ProviderContainer container) async {
  for (var i = 0; i < 50; i += 1) {
    final state = container.read(serverCatalogProvider);
    if (!state.isLoading) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  late ProviderContainer container;
  late _FakeServerRepository repository;
  late _FakeAppPreferencesRepository preferences;
  late FakeAnalyticsService analytics;
  late Map<String, dynamic>? workflowConnection;
  late Map<String, dynamic>? workflowSettings;
  late int serverStateResetCount;

  setUp(() {
    repository = _FakeServerRepository();
    preferences = _FakeAppPreferencesRepository();
    analytics = FakeAnalyticsService();
    workflowConnection = null;
    workflowSettings = null;
    serverStateResetCount = 0;
    container = ProviderContainer(
      overrides: [
        serverRepositoryProvider.overrideWithValue(repository),
        appPreferencesRepositoryProvider.overrideWithValue(preferences),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
        serverConnectionPayloadResolverProvider.overrideWithValue(
          (server) async => <String, dynamic>{'host': server.host},
        ),
        serverStateResetterProvider.overrideWithValue(
          () => serverStateResetCount += 1,
        ),
        postgresServicePasswordGeneratorProvider.overrideWithValue(
          () => 'generated-postgres-service-password',
        ),
        postgresServiceWorkflowProvider.overrideWithValue(({
          required connection,
          required settings,
          required onEvent,
        }) async {
          workflowConnection = connection;
          workflowSettings = settings;
          onEvent(<String, dynamic>{
            'type': 'pyinfra_log',
            'message': 'superuser_password=workflow-secret',
          });
          return Ok<Map<String, dynamic>>(<String, dynamic>{
            'msg': 'Database service enabled; password=reply-secret',
          });
        }),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  test('loads empty onboarding state by default', () async {
    container.read(serverCatalogProvider);
    await _waitForLoaded(container);

    final state = container.read(serverCatalogProvider);
    expect(state.isLoading, isFalse);
    expect(state.onboardingComplete, isFalse);
    expect(state.servers, isEmpty);
    expect(state.selectedServerId, isNull);
    expect(state.onboardingStep, 'idle');
  });

  test('saveConnectedServer persists server and updates selection', () async {
    container.read(serverCatalogProvider);
    await _waitForLoaded(container);
    final notifier = container.read(serverCatalogProvider.notifier);

    final saved = await notifier.saveConnectedServer(
      draft: _draft('Prod-01'),
      checkResult: const {
        'status': 'success',
        'os': 'Ubuntu 24.04',
        'cpu': 'arm64',
        'memory_mb': 8192,
        'disk_gb': 250,
      },
    );

    final state = container.read(serverCatalogProvider);
    expect(state.isLoading, isFalse);
    expect(state.onboardingComplete, isTrue);
    expect(state.servers, hasLength(1));
    expect(state.selectedServerId, saved.id);
    expect(state.onboardingStep, 'services_selection');
    expect(state.selectedServer?.name, 'Prod-01');
  });

  test('saveConnectedServer records a pending step for early saves', () async {
    container.read(serverCatalogProvider);
    await _waitForLoaded(container);
    final notifier = container.read(serverCatalogProvider.notifier);

    final saved = await notifier.saveConnectedServer(
      draft: _draft('Pending-01'),
      checkResult: const {'status': 'success'},
      onboardingStep: 'setup_in_progress',
      setupComplete: false,
    );

    final state = container.read(serverCatalogProvider);
    expect(state.servers, hasLength(1));
    expect(state.selectedServerId, saved.id);
    expect(state.onboardingStep, 'setup_in_progress');
    expect(state.selectedServer?.sshUser, 'root');
    expect(state.pendingSetupServerIds, contains(saved.id));
    expect(state.isServerSetupPending(saved.id), isTrue);
  });

  test('a reload repopulates the pending setup set', () async {
    container.read(serverCatalogProvider);
    await _waitForLoaded(container);
    final notifier = container.read(serverCatalogProvider.notifier);
    final saved = await notifier.saveConnectedServer(
      draft: _draft('Pending-01'),
      checkResult: const {'status': 'success'},
      onboardingStep: 'setup_in_progress',
      setupComplete: false,
    );

    await notifier.refresh();
    await _waitForLoaded(container);

    final state = container.read(serverCatalogProvider);
    expect(state.pendingSetupServerIds, contains(saved.id));
  });

  test(
    'adoptManagedServerIdentity pivots the selected server to the managed key',
    () async {
      container.read(serverCatalogProvider);
      await _waitForLoaded(container);
      final notifier = container.read(serverCatalogProvider.notifier);
      final saved = await notifier.saveConnectedServer(
        draft: _draft('Pending-01'),
        checkResult: const {'status': 'success'},
        onboardingStep: 'setup_in_progress',
        setupComplete: false,
      );

      final adopted = await notifier.adoptManagedServerIdentity(
        serverId: saved.id,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.sshKey,
        privateKey: 'managed-private-key',
        publicKey: 'managed-public-key',
        managedUserPassword: 'managed-unix-password',
      );

      final state = container.read(serverCatalogProvider);
      expect(adopted.id, saved.id);
      expect(state.onboardingStep, 'services_selection');
      expect(state.selectedServer?.sshUser, 'ubuntu');
      expect(state.selectedServer?.authMethod, ServerAuthMethod.sshKey);
      expect(state.pendingSetupServerIds, isEmpty);
      expect(state.isServerSetupPending(saved.id), isFalse);
      expect(repository.adoptedServerId, saved.id);
    },
  );

  test(
    'updatePendingServer rewrites the entry in place and stays pending',
    () async {
      container.read(serverCatalogProvider);
      await _waitForLoaded(container);
      final notifier = container.read(serverCatalogProvider.notifier);
      final saved = await notifier.saveConnectedServer(
        draft: _draft('Pending-01'),
        checkResult: const {'status': 'success'},
        onboardingStep: 'setup_in_progress',
        setupComplete: false,
      );

      final updated = await notifier.updatePendingServer(
        serverId: saved.id,
        draft: _draft('Pending-01-renamed'),
        checkResult: const {'status': 'success', 'os': 'Ubuntu 24.04'},
      );

      final state = container.read(serverCatalogProvider);
      expect(updated.id, saved.id);
      expect(state.servers, hasLength(1));
      expect(state.selectedServerId, saved.id);
      expect(state.selectedServer?.name, 'Pending-01-renamed');
      expect(state.selectedServer?.osName, 'Ubuntu 24.04');
      expect(state.onboardingStep, 'setup_in_progress');
      expect(state.pendingSetupServerIds, contains(saved.id));
      expect(state.isServerSetupPending(saved.id), isTrue);
      expect(repository.updateCalls, 1);
    },
  );

  test(
    'updatePendingServer surfaces update failures without moving the step',
    () async {
      container.read(serverCatalogProvider);
      await _waitForLoaded(container);
      final notifier = container.read(serverCatalogProvider.notifier);
      final saved = await notifier.saveConnectedServer(
        draft: _draft('Pending-01'),
        checkResult: const {'status': 'success'},
        onboardingStep: 'setup_in_progress',
        setupComplete: false,
      );
      repository.throwOnUpdate = Exception('disk is gone');

      await expectLater(
        notifier.updatePendingServer(
          serverId: saved.id,
          draft: _draft('Pending-01-renamed'),
          checkResult: const {'status': 'success'},
        ),
        throwsA(isA<Exception>()),
      );

      final state = container.read(serverCatalogProvider);
      expect(state.error, contains('Failed to update server details'));
      expect(state.onboardingStep, 'setup_in_progress');
      expect(state.selectedServer?.name, 'Pending-01');
      expect(state.pendingSetupServerIds, contains(saved.id));
    },
  );

  test(
    'server onboarding actions update the pending server in place',
    () async {
      container.read(serverCatalogProvider);
      await _waitForLoaded(container);
      final actions = container.read(serverOnboardingActionsProvider);
      final saved = await actions.savePendingServer(
        draft: _draft('Prod-01'),
        checkResult: const {'status': 'success'},
      );

      final updated = await actions.updatePendingServer(
        serverId: saved.id,
        draft: _draft('Prod-01-renamed'),
        checkResult: const {'status': 'success'},
      );

      expect(updated.id, saved.id);
      expect(updated.name, 'Prod-01-renamed');
      expect(repository.updateCalls, 1);
    },
  );

  test(
    'server onboarding actions persist a sanitized Postgres service selection',
    () async {
      container.read(serverCatalogProvider);
      await _waitForLoaded(container);
      final actions = container.read(serverOnboardingActionsProvider);
      final saved = await actions.savePendingServer(
        draft: _draft('Prod-01'),
        checkResult: const {'status': 'success'},
      );
      final events = <ServerOnboardingTerminalEvent>[];

      final config = await actions.completeServiceSelection(
        enableEmailAccounts: true,
        enableDomains: false,
        enableDatabases: true,
        postgresVersion: '18',
        postgresExtensions: const ['postgis', 'vector', 'postgis', 'invalid'],
        onEvent: events.add,
      );

      expect(config.postgresVersion, '18');
      expect(config.enabledExtensions, ['postgis', 'vector']);
      expect(config.superuserPassword, 'generated-postgres-service-password');
      expect(workflowConnection, <String, dynamic>{'host': saved.host});
      expect(workflowSettings?['postgres_version'], '18');
      expect(
        workflowSettings?['superuser_password'],
        'generated-postgres-service-password',
      );
      expect(
        events.map((event) => event.message).join('\n'),
        isNot(contains('workflow-secret')),
      );
      expect(
        events.map((event) => event.message).join('\n'),
        isNot(contains('reply-secret')),
      );

      final selected = container.read(serverCatalogProvider).selectedServer;
      expect(selected?.serviceDatabaseEnabled, isTrue);
      expect(selected?.serviceEmailEnabled, isTrue);
      expect(selected?.postgresConfig, config);
      expect(container.read(serverCatalogProvider).onboardingStep, 'connected');
      expect(
        preferences.milestones,
        contains(AppUserAttribute.hasCompletedOnboarding),
      );
    },
  );

  test(
    'server onboarding actions save a pending server before setup',
    () async {
      container.read(serverCatalogProvider);
      await _waitForLoaded(container);
      final actions = container.read(serverOnboardingActionsProvider);

      final saved = await actions.savePendingServer(
        draft: _draft('Pending-01'),
        checkResult: const {'status': 'success'},
      );

      final state = container.read(serverCatalogProvider);
      expect(state.selectedServerId, saved.id);
      expect(state.onboardingStep, 'setup_in_progress');
      expect(state.selectedServer?.sshUser, 'root');
    },
  );

  test(
    'server onboarding actions complete the managed handoff after setup',
    () async {
      container.read(serverCatalogProvider);
      await _waitForLoaded(container);
      final actions = container.read(serverOnboardingActionsProvider);
      final saved = await actions.savePendingServer(
        draft: _draft('Pending-01'),
        checkResult: const {'status': 'success'},
      );

      final adopted = await actions.completeManagedHandoff(
        serverId: saved.id,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.sshKey,
        privateKey: 'managed-private-key',
        publicKey: 'managed-public-key',
        managedUserPassword: 'managed-unix-password',
      );

      final state = container.read(serverCatalogProvider);
      expect(adopted.id, saved.id);
      expect(state.onboardingStep, 'services_selection');
      expect(state.selectedServer?.sshUser, 'ubuntu');
      expect(state.selectedServer?.authMethod, ServerAuthMethod.sshKey);
    },
  );

  test('updates selected server service and config flags', () async {
    container.read(serverCatalogProvider);
    await _waitForLoaded(container);
    final notifier = container.read(serverCatalogProvider.notifier);
    await notifier.saveConnectedServer(
      draft: _draft('Prod-01'),
      checkResult: const {'status': 'success'},
    );

    await notifier.updateSelectedServerServices(
      enableDatabases: true,
      enableEmailAccounts: true,
      enableDomains: false,
    );
    await notifier.updateSelectedServerWebServerConfig(
      const ServerWebServerConfig(
        enableHttpsRedirect: false,
        enableDnsPluginCloudflare: true,
      ),
    );
    await notifier.updateSelectedServerPostgresConfig(
      const ServerPostgresConfig(
        postgresVersion: '16',
        enabledExtensions: ['pgcrypto', 'pg_trgm'],
      ),
    );
    await notifier.updateSelectedServerSystemConfig(
      const ServerSystemConfig(
        rootLoginEnabled: true,
        passwordAuthEnabled: true,
        sshPort: 2022,
        timezone: 'America/New_York',
        swapGb: 4,
        autoRebootEnabled: true,
        maintenanceTime: '01:00',
      ),
    );
    await notifier.updateSelectedServerConnectionPort(2022);
    await notifier.updateSelectedServerConnectionHost('ssh.example.com');
    await notifier.updateSelectedServerImportedSshKey(
      privateKey: 'NEW PRIVATE KEY',
      publicKey: 'ssh-ed25519 NEW',
    );

    final selected = container.read(serverCatalogProvider).selectedServer;
    expect(selected, isNotNull);
    expect(selected!.serviceDatabaseEnabled, isTrue);
    expect(selected.serviceEmailEnabled, isTrue);
    expect(selected.serviceDomainEnabled, isFalse);
    expect(selected.webServerConfig.enableHttpsRedirect, isFalse);
    expect(selected.webServerConfig.enableDnsPluginCloudflare, isTrue);
    expect(selected.postgresConfig.postgresVersion, '16');
    expect(selected.postgresConfig.enabledExtensions, contains('pgcrypto'));
    expect(selected.host, 'ssh.example.com');
    expect(selected.port, 2022);
    expect(selected.systemConfig.timezone, 'America/New_York');
    expect(selected.systemConfig.autoRebootEnabled, isTrue);
    expect(repository.importedPrivateKey, 'NEW PRIVATE KEY');
    expect(repository.importedPublicKey, 'ssh-ed25519 NEW');
  });

  test('selectServer and setOnboardingStep persist to repository', () async {
    final first = await repository.createServer(
      draft: _draft('A'),
      specs: _specs(),
    );
    final second = await repository.createServer(
      draft: _draft('B'),
      specs: _specs(),
    );
    container.read(serverCatalogProvider);
    await _waitForLoaded(container);
    final notifier = container.read(serverCatalogProvider.notifier);
    await notifier.refresh();
    await _waitForLoaded(container);

    await notifier.selectServer(first.id);
    await notifier.selectServer(second.id);
    await notifier.setOnboardingStep('services_selection');

    final state = container.read(serverCatalogProvider);
    expect(state.selectedServerId, second.id);
    expect(state.selectedServer?.id, second.id);
    expect(state.onboardingStep, 'services_selection');

    final onboarding = await repository.readOnboardingState();
    expect(onboarding.activeServerId, second.id);
    expect(onboarding.currentStep, 'services_selection');
  });

  test(
    'server onboarding actions prepare a new server outside widget state',
    () async {
      container.read(serverCatalogProvider);
      await _waitForLoaded(container);

      await container.read(serverOnboardingActionsProvider).prepareAddServer();

      expect(serverStateResetCount, 1);
      expect(
        container.read(serverCatalogProvider).onboardingStep,
        'credentials',
      );
    },
  );

  test(
    'server onboarding actions persist only a changed server selection',
    () async {
      final first = await repository.createServer(
        draft: _draft('A'),
        specs: _specs(),
      );
      final second = await repository.createServer(
        draft: _draft('B'),
        specs: _specs(),
      );
      container.read(serverCatalogProvider);
      await _waitForLoaded(container);
      final actions = container.read(serverOnboardingActionsProvider);

      await actions.selectServerIfDifferent(first.id);
      await actions.selectServerIfDifferent(second.id);
      await actions.selectServerIfDifferent(second.id);

      final state = container.read(serverCatalogProvider);
      final onboarding = await repository.readOnboardingState();
      expect(state.selectedServerId, second.id);
      expect(onboarding.activeServerId, second.id);
    },
  );

  test('a relaunch starts with no server chosen', () async {
    final first = await repository.createServer(
      draft: _draft('Alpha'),
      specs: _specs(),
    );
    await repository.createServer(draft: _draft('Bravo'), specs: _specs());

    container.read(serverCatalogProvider);
    await _waitForLoaded(container);
    await container.read(serverCatalogProvider.notifier).selectServer(first.id);
    expect(
      container.read(serverCatalogProvider).selectedServerId,
      first.id,
      reason: 'precondition: the session remembers what the user chose',
    );
    expect(
      (await repository.readOnboardingState()).activeServerId,
      first.id,
      reason: 'precondition: the choice reaches the database while running',
    );

    // A relaunch: a fresh container over the same database.
    final relaunched = ProviderContainer(
      overrides: [
        serverRepositoryProvider.overrideWithValue(repository),
        serverConnectionPayloadResolverProvider.overrideWithValue(
          (server) async => <String, dynamic>{'host': server.host},
        ),
      ],
    );
    addTearDown(relaunched.dispose);
    relaunched.read(serverCatalogProvider);
    await _waitForLoaded(relaunched);

    final state = relaunched.read(serverCatalogProvider);
    expect(
      state.selectedServerId,
      isNull,
      reason:
          'the app must open with nothing selected, not pre-filtered to '
          'a server the user did not just choose (G-35)',
    );
    expect(state.servers, hasLength(2));
    final onboarding = await repository.readOnboardingState();
    expect(
      onboarding.activeServerId,
      isNull,
      reason: 'no stale value is left on disk for a later read to resurrect',
    );
    expect(
      onboarding.isCompleted,
      isTrue,
      reason: 'clearing a selection must not undo onboarding completion',
    );
  });

  test('an in-session refresh keeps the chosen server', () async {
    await repository.createServer(draft: _draft('Alpha'), specs: _specs());
    final second = await repository.createServer(
      draft: _draft('Bravo'),
      specs: _specs(),
    );

    container.read(serverCatalogProvider);
    await _waitForLoaded(container);
    final notifier = container.read(serverCatalogProvider.notifier);
    await notifier.selectServer(second.id);

    await notifier.refresh();
    await _waitForLoaded(container);

    expect(
      container.read(serverCatalogProvider).selectedServerId,
      second.id,
      reason:
          '_loadFromDatabase has three callers and only one is boot; a '
          'mid-session refresh must not wipe the selection (G-35)',
    );
  });

  test('refresh clears a selection whose server no longer exists', () async {
    final first = await repository.createServer(
      draft: _draft('Only'),
      specs: _specs(),
    );

    container.read(serverCatalogProvider);
    await _waitForLoaded(container);
    final notifier = container.read(serverCatalogProvider.notifier);
    await notifier.selectServer(first.id);
    expect(
      container.read(serverCatalogProvider).selectedServerId,
      first.id,
      reason: 'precondition: the session has a real selection',
    );

    // The server disappears underneath the session.
    await repository.deleteServer(first.id);
    await notifier.refresh();
    await _waitForLoaded(container);

    expect(
      container.read(serverCatalogProvider).selectedServerId,
      isNull,
      reason:
          'a selection pointing at a deleted server becomes no selection, '
          'not a silent jump to a different server (G-35)',
    );
  });

  test(
    'removeSelectedServer deletes the active server and resets onboarding',
    () async {
      container.read(serverCatalogProvider);
      await _waitForLoaded(container);
      final notifier = container.read(serverCatalogProvider.notifier);

      final first = await notifier.saveConnectedServer(
        draft: _draft('Alpha'),
        checkResult: const {'status': 'success'},
      );
      await notifier.saveConnectedServer(
        draft: _draft('Bravo'),
        checkResult: const {'status': 'success'},
      );
      await notifier.selectServer(first.id);
      await notifier.setOnboardingStep('services_selection');

      final removedName = await notifier.removeSelectedServer();

      final state = container.read(serverCatalogProvider);
      expect(removedName, 'Alpha');
      expect(state.servers.map((server) => server.name), ['Bravo']);
      expect(state.selectedServer?.name, 'Bravo');
      expect(state.onboardingStep, 'connected');
    },
  );

  test(
    'saveConnectedServer surfaces failure and sets failed onboarding step',
    () async {
      repository.throwOnCreate = StateError('persist failed');
      container.read(serverCatalogProvider);
      await _waitForLoaded(container);
      final notifier = container.read(serverCatalogProvider.notifier);

      await expectLater(
        () => notifier.saveConnectedServer(
          draft: _draft('Prod-01'),
          checkResult: const {'status': 'error'},
        ),
        throwsA(isA<StateError>()),
      );

      final state = container.read(serverCatalogProvider);
      expect(state.isLoading, isFalse);
      expect(state.onboardingStep, 'failed');
      expect(state.error, contains('Failed to persist server details'));
      expect(repository.savedFailures, hasLength(1));
    },
  );

  test('server lifecycle refreshes the server count bucket', () async {
    container.read(serverCatalogProvider);
    await _waitForLoaded(container);
    final notifier = container.read(serverCatalogProvider.notifier);

    await notifier.saveConnectedServer(
      draft: _draft('Alpha'),
      checkResult: const {'status': 'success'},
    );
    await notifier.saveConnectedServer(
      draft: _draft('Bravo'),
      checkResult: const {'status': 'success'},
    );
    await notifier.saveConnectedServer(
      draft: _draft('Charlie'),
      checkResult: const {'status': 'success'},
    );

    expect(analytics.userAttributes, [
      (attribute: AppUserAttribute.serverCountBucket, value: '1'),
      (attribute: AppUserAttribute.serverCountBucket, value: '2'),
      (attribute: AppUserAttribute.serverCountBucket, value: '3plus'),
    ]);

    expect(await notifier.removeSelectedServer(), 'Charlie');
    expect(await notifier.removeSelectedServer(), 'Alpha');

    expect(analytics.userAttributes, hasLength(5));
    expect(analytics.userAttributes[3], (
      attribute: AppUserAttribute.serverCountBucket,
      value: '2',
    ));
    expect(analytics.userAttributes[4], (
      attribute: AppUserAttribute.serverCountBucket,
      value: '1',
    ));
  });

  test('server failures leave the server count bucket alone', () async {
    container.read(serverCatalogProvider);
    await _waitForLoaded(container);
    final notifier = container.read(serverCatalogProvider.notifier);

    // No selection yet: nothing changed, nothing reported.
    expect(await notifier.removeSelectedServer(), isNull);

    repository.throwOnCreate = StateError('persist failed');
    await expectLater(
      () => notifier.saveConnectedServer(
        draft: _draft('Prod-01'),
        checkResult: const {'status': 'error'},
      ),
      throwsA(isA<StateError>()),
    );

    repository.throwOnCreate = null;
    await notifier.saveConnectedServer(
      draft: _draft('Prod-01'),
      checkResult: const {'status': 'success'},
    );
    repository.throwOnDelete = StateError('delete failed');
    await expectLater(
      () => notifier.removeSelectedServer(),
      throwsA(isA<StateError>()),
    );

    // Only the one successful save moved the bucket.
    expect(analytics.userAttributes, [
      (attribute: AppUserAttribute.serverCountBucket, value: '1'),
    ]);
  });
}

class _FakeAppPreferencesRepository implements AppPreferencesRepository {
  final Set<AppUserAttribute> milestones = <AppUserAttribute>{};

  @override
  Future<AppPreferencesRecord> read() async {
    return AppPreferencesRecord(
      terminalDebugView: false,
      themeMode: 'system',
      gitHubPendingOauthState: null,
      sqliteBackupS3Config: null,
      agentAccessEnabled: false,
      agentAccessPermissionMode: agentAccessPermissionReadOnly,
      agentSessionToken: null,
      agentSessionExpiresAt: null,
      analyticsOnboardingCompletedAt:
          milestones.contains(AppUserAttribute.hasCompletedOnboarding)
          ? DateTime.utc(2026, 9, 10)
          : null,
      updatedAt: DateTime.utc(2026, 9, 10),
    );
  }

  @override
  Future<void> setTerminalDebugView(bool enabled) async {}

  @override
  Future<void> setThemeMode(String mode) async {}

  @override
  Future<void> setGitHubPendingOauthState(String? oauthState) async {}

  @override
  Future<void> setSqliteBackupS3Config(Map<String, dynamic>? config) async {}

  @override
  Future<void> recordSqliteBackupRun({
    required String status,
    String? message,
    DateTime? runAt,
  }) async {}

  @override
  Future<void> setAgentAccessEnabled(bool enabled) async {}

  @override
  Future<void> setAgentAccessPermissionMode(String mode) async {}

  @override
  Future<void> issueAgentSession({
    required String token,
    required DateTime expiresAt,
  }) async {}

  @override
  Future<void> clearAgentSession() async {}

  @override
  Future<void> recordAnalyticsMilestone(
    AppUserAttribute attribute, {
    DateTime? reachedAt,
  }) async {
    milestones.add(attribute);
  }

  @override
  Future<void> setTelemetryEnabled({required bool enabled}) async {}

  @override
  Future<void> markTelemetryNoticeShown() async {}

  @override
  Future<void> markTelemetryNagShown() async {}
}

class _FakeServerRepository implements ServerRepository {
  final List<Server> _servers = [];
  final Set<String> _pendingSetupServerIds = {};
  OnboardingStateSnapshot _onboarding = const OnboardingStateSnapshot(
    isCompleted: false,
    currentStep: 'idle',
  );
  final List<Map<String, Object?>> savedFailures = [];
  String? importedPrivateKey;
  String? importedPublicKey;
  int _sequence = 0;
  Object? throwOnCreate;
  Object? throwOnDelete;
  Object? throwOnUpdate;

  String? adoptedServerId;
  int updateCalls = 0;

  @override
  Future<Server> createServer({
    required ServerDraft draft,
    required ServerSpecs specs,
    String onboardingStep = 'services_selection',
    bool setupComplete = true,
  }) async {
    final error = throwOnCreate;
    if (error != null) {
      throw error;
    }
    _sequence += 1;
    final now = DateTime.now();
    final server = Server(
      id: 'server-$_sequence',
      name: draft.name.trim(),
      host: draft.host.trim(),
      port: draft.port,
      sshUser: draft.sshUser.trim(),
      authMethod: draft.authMethod,
      osName: specs.osName,
      cpuArch: specs.cpuArch,
      memoryMb: specs.memoryMb,
      diskGb: specs.diskGb,
      serviceDatabaseEnabled: false,
      serviceEmailEnabled: false,
      serviceDomainEnabled: false,
      webServerConfig: const ServerWebServerConfig(),
      postgresConfig: const ServerPostgresConfig(),
      firewallConfig: const ServerFirewallConfig(),
      systemConfig: const ServerSystemConfig(),
      lastCheckStatus: specs.lastCheckStatus,
      lastError: specs.lastError,
      lastCheckedAt: now,
      createdAt: now,
      updatedAt: now,
    );
    _servers.add(server);
    if (setupComplete) {
      _pendingSetupServerIds.remove(server.id);
    } else {
      _pendingSetupServerIds.add(server.id);
    }
    _onboarding = OnboardingStateSnapshot(
      isCompleted: true,
      activeServerId: server.id,
      currentStep: onboardingStep,
    );
    return server;
  }

  @override
  Future<Server> updatePendingServer({
    required String serverId,
    required ServerDraft draft,
    required ServerSpecs specs,
  }) async {
    final error = throwOnUpdate;
    if (error != null) {
      throw error;
    }
    updateCalls += 1;
    final index = _servers.indexWhere((server) => server.id == serverId);
    final current = _servers[index];
    final now = DateTime.now();
    final updated = Server(
      id: current.id,
      name: draft.name.trim(),
      host: draft.host.trim(),
      port: draft.port,
      sshUser: draft.sshUser.trim(),
      authMethod: draft.authMethod,
      osName: specs.osName,
      cpuArch: specs.cpuArch,
      memoryMb: specs.memoryMb,
      diskGb: specs.diskGb,
      serviceDatabaseEnabled: current.serviceDatabaseEnabled,
      serviceEmailEnabled: current.serviceEmailEnabled,
      serviceDomainEnabled: current.serviceDomainEnabled,
      webServerConfig: current.webServerConfig,
      postgresConfig: current.postgresConfig,
      firewallConfig: current.firewallConfig,
      systemConfig: current.systemConfig,
      lastCheckStatus: specs.lastCheckStatus,
      lastError: specs.lastError,
      lastCheckedAt: now,
      createdAt: current.createdAt,
      updatedAt: now,
    );
    _servers[index] = updated;
    return updated;
  }

  @override
  Future<Set<String>> readPendingSetupServerIds() async {
    return Set.of(_pendingSetupServerIds);
  }

  @override
  Future<Server> adoptManagedIdentity({
    required String serverId,
    required String sshUser,
    required ServerAuthMethod authMethod,
    String? privateKey,
    String? publicKey,
    String? managedUserPassword,
  }) async {
    adoptedServerId = serverId;
    _pendingSetupServerIds.remove(serverId);
    final index = _servers.indexWhere((server) => server.id == serverId);
    final current = _servers[index];
    final adopted = Server(
      id: current.id,
      name: current.name,
      host: current.host,
      port: current.port,
      sshUser: sshUser,
      authMethod: authMethod,
      osName: current.osName,
      cpuArch: current.cpuArch,
      memoryMb: current.memoryMb,
      diskGb: current.diskGb,
      serviceDatabaseEnabled: current.serviceDatabaseEnabled,
      serviceEmailEnabled: current.serviceEmailEnabled,
      serviceDomainEnabled: current.serviceDomainEnabled,
      webServerConfig: current.webServerConfig,
      postgresConfig: current.postgresConfig,
      firewallConfig: current.firewallConfig,
      systemConfig: current.systemConfig,
      lastCheckStatus: current.lastCheckStatus,
      lastError: current.lastError,
      lastCheckedAt: current.lastCheckedAt,
      createdAt: current.createdAt,
      updatedAt: DateTime.now(),
    );
    _servers[index] = adopted;
    _onboarding = OnboardingStateSnapshot(
      isCompleted: true,
      activeServerId: serverId,
      currentStep: 'services_selection',
    );
    return adopted;
  }

  @override
  Future<List<Server>> listServers() async {
    final copy = [..._servers];
    copy.sort((left, right) => left.name.compareTo(right.name));
    return copy;
  }

  @override
  Future<OnboardingStateSnapshot> readOnboardingState() async {
    return _onboarding;
  }

  @override
  Future<void> saveConnectionFailure({
    required ServerDraft draft,
    required Object error,
  }) async {
    savedFailures.add(<String, Object?>{'draft': draft, 'error': error});
  }

  @override
  Future<void> deleteServer(String serverId) async {
    final error = throwOnDelete;
    if (error != null) {
      throw error;
    }
    _servers.removeWhere((server) => server.id == serverId);
    _pendingSetupServerIds.remove(serverId);
    final activeStillExists =
        _onboarding.activeServerId != null &&
        _servers.any((server) => server.id == _onboarding.activeServerId);
    final nextActiveServerId = _servers.isEmpty
        ? null
        : (activeStillExists ? _onboarding.activeServerId : _servers.first.id);
    final nextStep = nextActiveServerId == null
        ? 'idle'
        : (activeStillExists &&
                  _onboarding.currentStep != null &&
                  _onboarding.currentStep != 'services_selection'
              ? _onboarding.currentStep
              : 'connected');
    _onboarding = OnboardingStateSnapshot(
      isCompleted: _servers.isNotEmpty,
      activeServerId: nextActiveServerId,
      currentStep: nextStep,
    );
  }

  @override
  Future<void> clearActiveServer() async {
    _onboarding = OnboardingStateSnapshot(
      isCompleted: _onboarding.isCompleted,
      activeServerId: null,
      currentStep: _onboarding.currentStep,
    );
  }

  @override
  Future<void> setActiveServer(String serverId) async {
    _onboarding = OnboardingStateSnapshot(
      isCompleted: _onboarding.isCompleted || _servers.isNotEmpty,
      activeServerId: serverId,
      currentStep: _onboarding.currentStep,
    );
  }

  @override
  Future<void> updateOnboardingStep(String step) async {
    _onboarding = OnboardingStateSnapshot(
      isCompleted: _onboarding.isCompleted,
      activeServerId: _onboarding.activeServerId,
      currentStep: step,
    );
  }

  @override
  Future<void> updateServerPostgresConfig({
    required String serverId,
    required ServerPostgresConfig config,
  }) async {
    _updateServer(
      serverId,
      (server) => _copyServer(server, postgresConfig: config),
    );
  }

  @override
  Future<void> updateServerServices({
    required String serverId,
    required bool enableDatabases,
    required bool enableEmailAccounts,
    required bool enableDomains,
  }) async {
    _updateServer(
      serverId,
      (server) => _copyServer(
        server,
        serviceDatabaseEnabled: enableDatabases,
        serviceEmailEnabled: enableEmailAccounts,
        serviceDomainEnabled: enableDomains,
      ),
    );
  }

  @override
  Future<void> updateServerWebServerConfig({
    required String serverId,
    required ServerWebServerConfig config,
  }) async {
    _updateServer(
      serverId,
      (server) => _copyServer(server, webServerConfig: config),
    );
  }

  @override
  Future<void> updateServerFirewallConfig({
    required String serverId,
    required ServerFirewallConfig config,
  }) async {
    _updateServer(
      serverId,
      (server) => _copyServer(server, firewallConfig: config),
    );
  }

  @override
  Future<void> updateServerSystemConfig({
    required String serverId,
    required ServerSystemConfig config,
  }) async {
    _updateServer(
      serverId,
      (server) => _copyServer(server, systemConfig: config),
    );
  }

  @override
  Future<void> updateServerManagedSoftwareStatus({
    required String serverId,
    required ServerManagedSoftwareStatus status,
  }) async {}

  @override
  Future<void> updateServerConnectionPort({
    required String serverId,
    required int port,
  }) async {
    _updateServer(serverId, (server) => _copyServer(server, port: port));
  }

  @override
  Future<void> updateServerConnectionHost({
    required String serverId,
    required String host,
  }) async {
    _updateServer(serverId, (server) => _copyServer(server, host: host));
  }

  @override
  Future<void> updateServerImportedSshKey({
    required String serverId,
    required String privateKey,
    String? publicKey,
  }) async {
    importedPrivateKey = privateKey;
    importedPublicKey = publicKey;
  }

  void _updateServer(
    String serverId,
    Server Function(Server server) transform,
  ) {
    final index = _servers.indexWhere((server) => server.id == serverId);
    if (index < 0) {
      return;
    }
    _servers[index] = transform(_servers[index]);
  }

  Server _copyServer(
    Server server, {
    bool? serviceDatabaseEnabled,
    bool? serviceEmailEnabled,
    bool? serviceDomainEnabled,
    ServerWebServerConfig? webServerConfig,
    ServerPostgresConfig? postgresConfig,
    ServerFirewallConfig? firewallConfig,
    ServerSystemConfig? systemConfig,
    String? host,
    int? port,
  }) {
    return Server(
      id: server.id,
      name: server.name,
      host: host ?? server.host,
      port: port ?? server.port,
      sshUser: server.sshUser,
      authMethod: server.authMethod,
      osName: server.osName,
      cpuArch: server.cpuArch,
      memoryMb: server.memoryMb,
      diskGb: server.diskGb,
      serviceDatabaseEnabled:
          serviceDatabaseEnabled ?? server.serviceDatabaseEnabled,
      serviceEmailEnabled: serviceEmailEnabled ?? server.serviceEmailEnabled,
      serviceDomainEnabled: serviceDomainEnabled ?? server.serviceDomainEnabled,
      webServerConfig: webServerConfig ?? server.webServerConfig,
      postgresConfig: postgresConfig ?? server.postgresConfig,
      firewallConfig: firewallConfig ?? server.firewallConfig,
      systemConfig: systemConfig ?? server.systemConfig,
      lastCheckStatus: server.lastCheckStatus,
      lastError: server.lastError,
      lastCheckedAt: server.lastCheckedAt,
      createdAt: server.createdAt,
      updatedAt: DateTime.now(),
    );
  }
}
