import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/data/local/project_managed_database_repository.dart';
import 'package:ui/data/local/project_repository.dart';
import 'package:ui/providers/backup_provider.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/ui/system/app_forms.dart';

import '../../../_support/fake_analytics_service.dart';
import '_support/server_management_harness.dart';

class _FailingServiceSshService extends HistoryAwareSshService {
  _FailingServiceSshService({
    this.failOperationId,
    this.throwOperationId,
    this.postgresRunning = false,
  });

  final String? failOperationId;
  final String? throwOperationId;
  final bool postgresRunning;

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    if (operationId == throwOperationId) {
      throw StateError('ssh unavailable');
    }
    if (operationId == failOperationId) {
      return const <String, dynamic>{
        'status': 'error',
        'msg': 'Service engine exploded.',
      };
    }
    if (workflowId == 'postgres' && operationId == 'service_status') {
      return <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{
          'running': postgresRunning,
          'configured': true,
        },
      };
    }
    return super.runWorkflowLegacy(
      workflowId: workflowId,
      operationId: operationId,
      connection: connection,
      params: params,
      onEvent: onEvent,
      onTaskStarted: onTaskStarted,
      serializePerHost: serializePerHost,
    );
  }
}

class _FailingFirewallSshService extends FirewallWorkflowSshService {
  _FailingFirewallSshService({this.failOperationId, this.throwOperationId});

  final String? failOperationId;
  final String? throwOperationId;

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    if (operationId == throwOperationId) {
      throw StateError('ssh unavailable');
    }
    if (operationId == failOperationId) {
      return const <String, dynamic>{
        'status': 'error',
        'msg': 'Firewall engine exploded.',
      };
    }
    return super.runWorkflowLegacy(
      workflowId: workflowId,
      operationId: operationId,
      connection: connection,
      params: params,
      onEvent: onEvent,
      onTaskStarted: onTaskStarted,
      serializePerHost: serializePerHost,
    );
  }
}

/// Why: holds catalog deletion open so notifier disposal can be covered safely.
class _DelayedBackupRepository extends BackupRepository {
  /// Why: the real database still backs unrelated repository behavior.
  _DelayedBackupRepository(super.database);

  final started = Completer<void>();
  final release = Completer<void>();

  /// Why: creates the exact await boundary where a provider can be disposed.
  @override
  Future<void> deletePoliciesForServer(String serverId) async {
    started.complete();
    await release.future;
  }
}

/// Why: feeds enriched postgres statuses plus controllable storage actions.
class _StorageStatusSshService extends HistoryAwareSshService {
  _StorageStatusSshService({
    this.storage = const <String, dynamic>{},
    this.running = true,
    this.effectiveStatus,
    this.readinessStatus,
    this.readinessDetail = '',
    this.failOperationId,
    this.throwOperationId,
    this.pendingOperationId,
    this.conflictBlocked = false,
  });

  final Map<String, dynamic> storage;
  final bool running;
  final String? effectiveStatus;
  final String? readinessStatus;
  final String readinessDetail;
  final String? failOperationId;
  final String? throwOperationId;
  final String? pendingOperationId;
  final bool conflictBlocked;
  Completer<Map<String, dynamic>>? pendingCompletion;
  int migrateCalls = 0;
  int removeCalls = 0;
  int upgradeCalls = 0;
  final lastParamsByOperation = <String, Map<String, dynamic>?>{};

  @override
  OperationConflictEvaluation evaluateWorkflowConflict({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    bool serializePerHost = true,
  }) {
    if (conflictBlocked &&
        workflowId == 'postgres' &&
        operationId != 'service_status') {
      return const OperationConflictEvaluation(
        isBlocked: true,
        message: 'Blocked by active conflicting operation.',
        blockingOperationIds: <String>['postgres/service_restart-1'],
        blockingResources: <String>['stack:203.0.113.11:postgres'],
      );
    }
    return super.evaluateWorkflowConflict(
      workflowId: workflowId,
      operationId: operationId,
      connection: connection,
      params: params,
    );
  }

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    if (operationId == throwOperationId) {
      throw StateError('ssh unavailable');
    }
    lastParamsByOperation[operationId] = params;
    if (operationId == failOperationId) {
      return const <String, dynamic>{
        'status': 'error',
        'msg': 'Storage engine exploded.',
      };
    }
    if (operationId == pendingOperationId) {
      pendingCompletion = Completer<Map<String, dynamic>>();
      return pendingCompletion!.future;
    }
    if (operationId == 'service_migrate_storage') {
      migrateCalls += 1;
    }
    if (operationId == 'service_remove_legacy_storage') {
      removeCalls += 1;
    }
    if (operationId == 'service_upgrade_major') {
      upgradeCalls += 1;
    }
    if (workflowId == 'postgres' && operationId == 'service_status') {
      return <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{
          'running': running,
          'health': 'healthy',
          'configured': true,
          'container_status': <String, dynamic>{
            'present': true,
            'docker_state': running ? 'running' : 'exited',
            'running': running,
            'health': 'healthy',
            'exit_code': 0,
            'image': 'deploydash/postgres-ext:17.10-bookworm-vector',
            'started_at': '2026-07-01T12:00:00Z',
            'effective_status':
                effectiveStatus ?? (running ? 'ready' : 'stopped'),
            'readiness': <String, dynamic>{
              'status': readinessStatus ?? (running ? 'ready' : 'not_checked'),
              'detail': readinessDetail,
            },
          },
          ...storage,
        },
      };
    }
    return super.runWorkflowLegacy(
      workflowId: workflowId,
      operationId: operationId,
      connection: connection,
      params: params,
      onEvent: onEvent,
      onTaskStarted: onTaskStarted,
      serializePerHost: serializePerHost,
    );
  }
}

/// Why: pins the enriched keys for a healthy named-volume layout.
Map<String, dynamic> _namedVolumeStorage() => <String, dynamic>{
  'data_directory': '/var/lib/postgresql/data/pgdata',
  'storage_volume': 'postgres_postgres_data',
  'storage_volume_anonymous': false,
  'data_size_bytes': 12345,
  'storage_layout_current': true,
  'missing_expected_databases': <String>[],
  'storage_error': null,
  'detached_storage_volumes': <String>[],
};

/// Why: pins the enriched keys for a pre-migration anonymous layout.
Map<String, dynamic> _legacyVolumeStorage() => <String, dynamic>{
  'data_directory': '/var/lib/postgresql/data',
  'storage_volume': 'a' * 64,
  'storage_volume_anonymous': true,
  'data_size_bytes': 987,
  'storage_layout_current': false,
  'missing_expected_databases': <String>[],
  'storage_error': null,
  'detached_storage_volumes': <String>[],
};

const String _detachedError =
    'Detached data volume: this cluster has none of the 2 databases Deploy '
    'Dash expects; the data volume may be detached. List candidates with '
    '`docker volume ls -f dangling=true`, and do not run `docker volume '
    'prune` until it is resolved.';

/// Why: pins the enriched keys for a cluster with kept pre-upgrade copies.
Map<String, dynamic> _retainedUpgradeStorage() => <String, dynamic>{
  'data_directory': '/var/lib/postgresql/data/pgdata',
  'storage_volume': 'postgres_postgres_data_pg18',
  'storage_volume_anonymous': false,
  'data_size_bytes': 23456,
  'storage_layout_current': true,
  'missing_expected_databases': <String>[],
  'storage_error': null,
  'detached_storage_volumes': <String>[],
  'retained_upgrade_volumes': <Map<String, dynamic>>[
    <String, dynamic>{
      'volume': 'postgres_postgres_data',
      'from_major': '17',
      'to_major': '18',
      'upgraded_at': '20260923T120000Z',
    },
    <String, dynamic>{
      'volume': 'postgres_postgres_data_pg17',
      'from_major': '16',
      'to_major': '17',
      'upgraded_at': '20260601T080000Z',
    },
  ],
};

/// Why: pins the exact named-volume subpath kept by a storage migration.
Map<String, dynamic> _retainedStorageSubpathStorage() => <String, dynamic>{
  'data_directory': '/var/lib/postgresql/data/pgdata',
  'storage_volume': 'postgres_postgres_data',
  'storage_volume_anonymous': false,
  'data_size_bytes': 23456,
  'storage_layout_current': true,
  'missing_expected_databases': <String>[],
  'storage_error': null,
  'detached_storage_volumes': <String>[],
  'retained_upgrade_volumes': <Map<String, dynamic>>[],
  'retained_storage_subpaths': <Map<String, dynamic>>[
    <String, dynamic>{
      'volume': 'postgres_postgres_data',
      'subpath': '18/docker',
    },
  ],
};

/// Why: seeds desktop-known databases for the expected-databases tests.
Future<void> _seedKnownDatabases(AppDatabase database) async {
  final projects = ProjectRepository(database);
  final managed = ProjectManagedDatabaseRepository(database);
  const serverId = 'server-prod-04';
  await projects.createProject(
    const Project(
      id: 'project-shop',
      serverId: serverId,
      name: 'Shop',
      type: 'app',
      gitUrl: 'git@github.com:acme/shop.git',
      primaryDomain: 'shop.example.com',
    ),
  );
  await projects.createProject(
    const Project(
      id: 'project-jobs',
      serverId: serverId,
      name: 'Jobs',
      type: 'app',
      gitUrl: 'git@github.com:acme/jobs.git',
      primaryDomain: 'jobs.example.com',
    ),
  );
  final now = DateTime.utc(2026, 1, 1);
  await managed.upsertDatabase(
    ProjectManagedDatabaseRecord(
      id: 'project-shop-server-prod-04-postgres-dd_shop_app',
      projectId: 'project-shop',
      serverId: serverId,
      databaseName: 'dd_shop_app',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await managed.upsertDatabase(
    ProjectManagedDatabaseRecord(
      id: 'project-shop-server-prod-04-postgres-dd_shop_jobs',
      projectId: 'project-shop',
      serverId: serverId,
      databaseName: 'dd_shop_jobs',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await managed.upsertDatabase(
    ProjectManagedDatabaseRecord(
      id: 'project-jobs-server-prod-04-postgres-dd_shop_jobs',
      projectId: 'project-jobs',
      serverId: serverId,
      databaseName: 'dd_shop_jobs',
      createdAt: now,
      updatedAt: now,
    ),
  );
}

/// Why: pins the enriched keys for a cluster that lost its data volume.
Map<String, dynamic> _detachedVolumeStorage() => <String, dynamic>{
  'data_directory': '/var/lib/postgresql/data/pgdata',
  'storage_volume': 'postgres_postgres_data',
  'storage_volume_anonymous': false,
  'data_size_bytes': 456,
  'storage_layout_current': true,
  'missing_expected_databases': <String>['dd_test_app', 'dd_test_jobs'],
  'storage_error': _detachedError,
  'detached_storage_volumes': <String>['c' * 64],
};

Finder _servicesScrollable() {
  return find.descendant(
    of: find.byKey(const Key('server-management-services-tab')),
    matching: find.byType(Scrollable),
  );
}

Future<void> _scrollToServiceKey(WidgetTester tester, String key) async {
  await tester.scrollUntilVisible(
    find.byKey(Key(key)),
    260,
    scrollable: _servicesScrollable(),
  );
  await tester.pumpAndSettle();
}

/// Confirms the safe current-device default in the remote-access dialog.
Future<void> _confirmCurrentDevicePostgresAccess(WidgetTester tester) async {
  expect(
    find.byKey(const Key('postgres-remote-access-dialog')),
    findsOneWidget,
  );
  await tester.tap(find.byKey(const Key('postgres-remote-access-confirm')));
  await tester.pumpAndSettle();
}

/// Server Management services tab.
///
/// One of nine files T-3.6.2 split `server_management_view_test.dart` into,
/// one per tab, mirroring `lib/ui/server/management/`.
void main() {
  ensureSqliteRuntimeAvailable();

  test('Backup policy cache cleanup stops after notifier disposal', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = _DelayedBackupRepository(database);
    final container = ProviderContainer(
      overrides: [backupRepositoryProvider.overrideWithValue(repository)],
    );

    final cleanup = container
        .read(projectBackupProvider.notifier)
        .deletePoliciesForServer('server-prod-04');
    await repository.started.future;
    container.dispose();
    repository.release.complete();

    await cleanup;
  });

  testWidgets(
    'Services tab syncs configured Postgres into local server state',
    (WidgetTester tester) async {
      final catalogNotifier = FakeServerCatalogNotifier(
        ServerCatalogState(
          isLoading: false,
          onboardingComplete: true,
          servers: const [serverWithCredentials],
          selectedServerId: serverWithCredentials.id,
        ),
      );
      await pumpServerManagement(
        tester,
        server: serverWithCredentials,
        initialTabIndex: 1,
        overrides: [
          sshServiceProvider.overrideWithValue(
            PostgresStatusSshService(configured: true, running: true),
          ),
          serverCatalogProvider.overrideWith(() => catalogNotifier),
        ],
      );

      expect(
        catalogNotifier.state.selectedServer?.serviceDatabaseEnabled,
        isTrue,
      );
    },
  );

  testWidgets('Services tab shows unhealthy Postgres as unhealthy', (
    WidgetTester tester,
  ) async {
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(
          PostgresStatusSshService(
            configured: true,
            running: true,
            health: 'unhealthy',
          ),
        ),
      ],
    );

    expect(find.text('Database (Postgres)'), findsOneWidget);
    expect(find.text('Unhealthy'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
  });

  testWidgets('Services tab keeps unsupported services disabled', (
    WidgetTester tester,
  ) async {
    final sshService = HistoryAwareSshService();
    addTearDown(sshService.dispose);
    await pumpServerManagement(
      tester,
      server: server,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    expect(find.text('Available services'), findsOneWidget);
    expect(find.text('Milvus'), findsNothing);
    expect(find.byKey(const Key('service-enable-email')), findsOneWidget);
    final enableEmailButton = tester.widget<FilledButton>(
      find.byKey(const Key('service-enable-email')),
    );
    expect(enableEmailButton.onPressed, isNull);
  });

  testWidgets('Services tab opens configure modal', (
    WidgetTester tester,
  ) async {
    await pumpServerManagement(tester, server: server, initialTabIndex: 1);

    final servicesScrollable = find.descendant(
      of: find.byKey(const Key('server-management-services-tab')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('service-configure-proxy')),
      260,
      scrollable: servicesScrollable,
    );
    await tester.pumpAndSettle();

    final configureButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('service-configure-proxy')),
    );
    configureButton.onPressed?.call();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('service-config-dialog-proxy')), findsOne);
    expect(find.text('DNS providers'), findsOneWidget);
    expect(find.text('Cloudflare'), findsOneWidget);
    expect(find.text('Porkbun'), findsOneWidget);
    expect(find.text('DNSimple'), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('service-config-dialog-proxy')), findsNothing);
  });

  testWidgets('Services tab renders recent activity from task history', (
    WidgetTester tester,
  ) async {
    final sshService = HistoryAwareSshService();
    addTearDown(sshService.dispose);
    await pumpServerManagement(
      tester,
      server: server,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    final servicesScrollable = find.descendant(
      of: find.byKey(const Key('server-management-services-tab')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('services-recent-activity')),
      260,
      scrollable: servicesScrollable,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('services-recent-activity')), findsOneWidget);
    expect(find.textContaining('Database'), findsWidgets);
    expect(find.text('Database was turned on.'), findsOneWidget);
    expect(find.textContaining('service_enable'), findsNothing);
  });

  testWidgets(
    'Services tab disables conflicting controls and shows blocking resources',
    (WidgetTester tester) async {
      final conflictService = ConflictAwareSshService();
      addTearDown(conflictService.dispose);

      await pumpServerManagement(
        tester,
        server: serverWithCredentialsAndDatabaseEnabled,
        initialTabIndex: 1,
        overrides: [sshServiceProvider.overrideWithValue(conflictService)],
      );

      final servicesScrollable = find.descendant(
        of: find.byKey(const Key('server-management-services-tab')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('service-row-database')),
        260,
        scrollable: servicesScrollable,
      );
      await tester.pumpAndSettle();

      final startStopButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('service-start-stop-database')),
      );
      final restartButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('service-restart-database')),
      );
      final configureButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('service-configure-database')),
      );
      final deleteButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('service-delete-database')),
      );

      expect(startStopButton.onPressed, isNull);
      expect(restartButton.onPressed, isNull);
      expect(configureButton.onPressed, isNull);
      expect(deleteButton.onPressed, isNull);
      expect(
        find.textContaining('Resource: stack:203.0.113.11:postgres.'),
        findsWidgets,
      );
    },
  );

  testWidgets(
    'Services tab enables temporary PostgreSQL remote access for one hour',
    (WidgetTester tester) async {
      final sshService = FirewallWorkflowSshService();
      addTearDown(sshService.dispose);

      await pumpServerManagement(
        tester,
        server: serverWithCredentialsAndDatabaseEnabled,
        initialTabIndex: 1,
        overrides: [sshServiceProvider.overrideWithValue(sshService)],
      );

      final servicesScrollable = find.descendant(
        of: find.byKey(const Key('server-management-services-tab')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('service-enable-postgres-remote-access')),
        260,
        scrollable: servicesScrollable,
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('service-enable-postgres-remote-access')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Choose who can connect'), findsOneWidget);
      expect(find.textContaining('198.51.100.24/32'), findsOneWidget);
      expect(sshService.firewallApplyCalls, 0);
      await tester.tap(
        find.byKey(const Key('postgres-remote-access-specific')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('postgres-remote-access-current-device')),
      );
      await tester.pumpAndSettle();
      await _confirmCurrentDevicePostgresAccess(tester);

      expect(sshService.firewallApplyCalls, 1);
      expect(sshService.lastFirewallApplySettings?['allow_postgres'], true);
      // D-63p3 characterization: the staged payload locks the base ports
      // for the server's SSH port (22 here — no extra member).
      expect(sshService.lastFirewallApplySettings?['locked_ports'], [
        22,
        80,
        443,
      ]);
      expect(
        sshService.lastFirewallApplySettings?['postgres_source_cidrs'],
        <String>['198.51.100.24/32'],
      );
      expect(
        sshService.lastFirewallApplySettings?['rollback_timeout_seconds'],
        3600,
      );
      expect(find.text('Temporary database access is on.'), findsOneWidget);
      expect(find.textContaining('Closes automatically at'), findsOneWidget);
      expect(find.text('TLS required (sslmode=verify-ca)'), findsOneWidget);
      expect(find.textContaining('AA:BB:CC:DD'), findsOneWidget);
    },
  );

  testWidgets('Services tab makes anywhere access an explicit warned choice', (
    WidgetTester tester,
  ) async {
    final sshService = FirewallWorkflowSshService();
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-enable-postgres-remote-access');
    await tester.tap(
      find.byKey(const Key('service-enable-postgres-remote-access')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('postgres-remote-access-anywhere')));
    await tester.pumpAndSettle();

    expect(find.textContaining('every internet address'), findsOneWidget);
    await tester.tap(find.byKey(const Key('postgres-remote-access-confirm')));
    await tester.pumpAndSettle();

    expect(sshService.firewallApplyCalls, 1);
    expect(
      sshService.lastFirewallApplySettings?['postgres_source_cidrs'],
      isEmpty,
    );
  });

  testWidgets(
    'Services tab requires explicit CIDRs when the client address is unavailable',
    (WidgetTester tester) async {
      final sshService = FirewallWorkflowSshService(
        connectionSourceAddress: null,
      );
      addTearDown(sshService.dispose);

      await pumpServerManagement(
        tester,
        server: serverWithCredentialsAndDatabaseEnabled,
        initialTabIndex: 1,
        overrides: [sshServiceProvider.overrideWithValue(sshService)],
      );

      await _scrollToServiceKey(
        tester,
        'service-enable-postgres-remote-access',
      );
      await tester.tap(
        find.byKey(const Key('service-enable-postgres-remote-access')),
      );
      await tester.pumpAndSettle();

      expect(find.text('This device (address unavailable)'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('postgres-remote-access-confirm')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sshService.firewallApplyCalls, 0);

      await tester.tap(
        find.byKey(const Key('service-enable-postgres-remote-access')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('postgres-remote-access-specific-cidrs')),
        '198.51.100.24/32, 198.51.100.24/32 2001:db8::24/128',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('postgres-remote-access-confirm')));
      await tester.pumpAndSettle();

      expect(
        sshService.lastFirewallApplySettings?['postgres_source_cidrs'],
        <String>['198.51.100.24/32', '2001:db8::24/128'],
      );
    },
  );

  testWidgets('Services tab narrows an IPv6 client to one host', (
    WidgetTester tester,
  ) async {
    final sshService = FirewallWorkflowSshService(
      connectionSourceAddress: '2001:db8::24',
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-enable-postgres-remote-access');
    await tester.tap(
      find.byKey(const Key('service-enable-postgres-remote-access')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('2001:db8::24/128'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('Services tab can close temporary PostgreSQL remote access', (
    WidgetTester tester,
  ) async {
    final clipboardWrites = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final arguments = call.arguments as Map<dynamic, dynamic>;
            clipboardWrites.add(arguments['text'] as String);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final sshService = FirewallWorkflowSshService(stagedPostgresAccess: true);
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    final servicesScrollable = find.descendant(
      of: find.byKey(const Key('server-management-services-tab')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('service-close-postgres-remote-access')),
      260,
      scrollable: servicesScrollable,
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('service-copy-postgres-ca-certificate')),
    );
    await tester.tap(
      find.byKey(const Key('service-copy-postgres-ca-certificate')),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('service-copy-postgres-tls-template')),
    );
    await tester.tap(
      find.byKey(const Key('service-copy-postgres-tls-template')),
    );
    await tester.pumpAndSettle();

    expect(clipboardWrites.first, contains('BEGIN CERTIFICATE'));
    expect(
      clipboardWrites.last,
      contains('203.0.113.11:5432/DATABASE?sslmode=verify-ca'),
    );

    await tester.tap(
      find.byKey(const Key('service-close-postgres-remote-access')),
    );
    await tester.pumpAndSettle();

    expect(sshService.firewallRollbackCalls, 1);
    expect(find.text('Temporary database access is on.'), findsNothing);
  });

  testWidgets('Services tab blocks Postgres access for another staged change', (
    WidgetTester tester,
  ) async {
    final sshService = FirewallWorkflowSshService(
      stagedState: <String, dynamic>{
        'token': 'fw-stage-other',
        'expires_at': '2026-04-10T13:00:00Z',
        'allow_postgres': false,
      },
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-enable-postgres-remote-access');
    expect(
      find.textContaining('Another firewall change is already waiting'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('service-enable-postgres-remote-access')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('Services tab blocks Postgres access until TLS is configured', (
    WidgetTester tester,
  ) async {
    final sshService = FirewallWorkflowSshService(tlsEnabled: false);
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-enable-postgres-remote-access');
    expect(
      find.byTooltip(
        'Configure the database service once to enable TLS before opening '
        'remote access.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Services tab resets Postgres access state when servers change', (
    WidgetTester tester,
  ) async {
    final firstSshService = FirewallWorkflowSshService(
      stagedPostgresAccess: true,
    );
    final secondSshService = FirewallWorkflowSshService();
    addTearDown(firstSshService.dispose);
    addTearDown(secondSshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(firstSshService)],
    );
    await _scrollToServiceKey(tester, 'service-enable-postgres-remote-access');
    expect(find.text('Temporary database access is on.'), findsOneWidget);

    await pumpServerManagement(
      tester,
      server: serverWithDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(secondSshService)],
    );
    await _scrollToServiceKey(tester, 'service-enable-postgres-remote-access');
    expect(find.text('Temporary database access is on.'), findsNothing);
  });

  testWidgets('Service enables report the service event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = DatabaseEnableSshService();
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-enable-database');
    await tester.tap(find.byKey(const Key('service-enable-database')));
    await tester.pumpAndSettle();
    // The web server row is always provisioned, so the reachable enable flow
    // is the database one behind its configure dialog.
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('service-config-dialog-database')),
        matching: find.widgetWithText(FilledButton, 'Enable'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Database service enabled.'), findsWidgets);
    expect(analytics.serviceEvents, [
      (action: ServiceAction.enable, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Service enable failures report the service event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = DatabaseEnableSshService(failEnable: true);
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-enable-database');
    await tester.tap(find.byKey(const Key('service-enable-database')));
    await tester.pumpAndSettle();
    // The web server row is always provisioned, so the reachable enable flow
    // is the database one behind its configure dialog.
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('service-config-dialog-database')),
        matching: find.widgetWithText(FilledButton, 'Enable'),
      ),
    );
    await tester.pumpAndSettle();

    expect(analytics.serviceEvents, [
      (action: ServiceAction.enable, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Service enable throws report the service event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = DatabaseEnableSshService(throwEnable: true);
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-enable-database');
    await tester.tap(find.byKey(const Key('service-enable-database')));
    await tester.pumpAndSettle();
    // The web server row is always provisioned, so the reachable enable flow
    // is the database one behind its configure dialog.
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('service-config-dialog-database')),
        matching: find.widgetWithText(FilledButton, 'Enable'),
      ),
    );
    await tester.pumpAndSettle();

    expect(analytics.serviceEvents, [
      (action: ServiceAction.enable, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Service starts report the service event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _FailingServiceSshService();
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-start-stop-database');
    expect(
      find.descendant(
        of: find.byKey(const Key('service-start-stop-database')),
        matching: find.text('Start'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('service-start-stop-database')));
    await tester.pumpAndSettle();

    // The engine double returns no message and the trailing status refresh
    // reports the double's stopped fixture, so neither the snackbar nor the
    // button label is a durable signal; the event is (as in configure).
    expect(analytics.serviceEvents, [
      (action: ServiceAction.start, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Service start failures report the service event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _FailingServiceSshService(
      failOperationId: 'service_start',
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-start-stop-database');
    await tester.tap(find.byKey(const Key('service-start-stop-database')));
    await tester.pumpAndSettle();

    expect(analytics.serviceEvents, [
      (action: ServiceAction.start, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Service start throws report the service event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _FailingServiceSshService(
      throwOperationId: 'service_start',
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-start-stop-database');
    await tester.tap(find.byKey(const Key('service-start-stop-database')));
    await tester.pumpAndSettle();

    expect(analytics.serviceEvents, [
      (action: ServiceAction.start, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Service restarts report the service event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    // Restarting a stopped database is precheck-blocked (no event by
    // design), so the double reports it running.
    final sshService = _FailingServiceSshService(postgresRunning: true);
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-restart-database');
    await tester.tap(find.byKey(const Key('service-restart-database')));
    await tester.pumpAndSettle();

    // No durable label change on restart (ready stays ready); the event is
    // the signal, as in the configure test.
    expect(analytics.serviceEvents, [
      (action: ServiceAction.restart, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Service stops report the service event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _FailingServiceSshService(postgresRunning: true);
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-start-stop-database');
    expect(
      find.descendant(
        of: find.byKey(const Key('service-start-stop-database')),
        matching: find.text('Stop'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('service-start-stop-database')));
    await tester.pumpAndSettle();

    // Same refresh clobber as start (the fixture still reports running, so
    // the label returns to Stop); the event is the signal.
    expect(analytics.serviceEvents, [
      (action: ServiceAction.stop, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Service configures report the service event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _FailingServiceSshService();
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-configure-database');
    await tester.tap(find.byKey(const Key('service-configure-database')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('service-config-dialog-database')), findsOne);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('service-config-dialog-database')),
        matching: find.widgetWithText(FilledButton, 'Save'),
      ),
    );
    await tester.pumpAndSettle();

    expect(analytics.serviceEvents, [
      (action: ServiceAction.configure, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Service deletes report the service event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _FailingServiceSshService();
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-delete-database');
    final deleteButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('service-delete-database')),
    );
    deleteButton.onPressed?.call();
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('I understand this action permanently deletes all data.'),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('service-delete-confirm-input')),
      'DELETE',
    );
    // The confirm button enables only once the checkbox and typed text both
    // validate.
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-delete-confirm-button')));
    await tester.pumpAndSettle();

    // No snackbar text survives settle and the trailing refresh
    // re-provisions from the fixture, so the event is the signal.
    expect(analytics.serviceEvents, [
      (action: ServiceAction.delete, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Deleting PostgreSQL forgets only that servers backup policies', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final backupRepository = BackupRepository(database);
    for (final policy in <BackupPolicyRecord>[
      const BackupPolicyRecord(
        id: 'daily-main',
        projectId: 'project-shop',
        serverId: 'server-prod-04',
        name: 'Daily main',
        destinationId: 'local',
        databaseName: 'dd_shop_app',
        scheduleMode: 'daily_once',
        time1Hhmm: '02:00',
        managedTaskId: 'backup-pg-daily-main',
      ),
      const BackupPolicyRecord(
        id: 'daily-other',
        projectId: 'project-shop',
        serverId: 'server-other',
        name: 'Daily other',
        destinationId: 'local',
        databaseName: 'dd_shop_app',
        scheduleMode: 'daily_once',
        time1Hhmm: '02:00',
        managedTaskId: 'backup-pg-daily-other',
      ),
    ]) {
      await backupRepository.upsertPolicy(policy);
    }
    await backupRepository.replaceArtifactsForPolicy(
      policyId: 'daily-main',
      projectId: 'project-shop',
      serverId: 'server-prod-04',
      artifacts: const <BackupArtifactRecord>[
        BackupArtifactRecord(
          id: 'artifact-main',
          policyId: 'daily-main',
          projectId: 'project-shop',
          serverId: 'server-prod-04',
          destinationId: 'local',
          databaseName: 'dd_shop_app',
          remotePath: 'backups/main.dump',
        ),
      ],
    );
    await backupRepository.appendRun(
      const BackupRunRecord(
        projectId: 'project-shop',
        serverId: 'server-prod-04',
        policyId: 'daily-main',
        operationType: BackupOperationType.backup,
        status: 'success',
      ),
    );
    await backupRepository.deletePoliciesForServer(' ');
    final sshService = _FailingServiceSshService();
    addTearDown(sshService.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            testServerConnectionPayload,
          ),
          sshServiceProvider.overrideWithValue(sshService),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ServerManagementView(
              server: serverWithCredentialsAndDatabaseEnabled,
              initialTabIndex: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ServerManagementView)),
    );
    await container
        .read(projectBackupProvider.notifier)
        .loadScope(projectId: 'project-shop', serverId: 'server-prod-04');
    await container
        .read(projectBackupProvider.notifier)
        .loadScope(projectId: 'project-shop', serverId: 'server-other');
    await container
        .read(projectBackupProvider.notifier)
        .deletePoliciesForServer(' ');
    expect(
      container
          .read(projectBackupProvider)
          .scopeFor(projectId: 'project-shop', serverId: 'server-prod-04')
          .policies,
      hasLength(1),
    );

    await _scrollToServiceKey(tester, 'service-delete-database');
    final deleteButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('service-delete-database')),
    );
    deleteButton.onPressed?.call();
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('I understand this action permanently deletes all data.'),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('service-delete-confirm-input')),
      'DELETE',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-delete-confirm-button')));
    await tester.pumpAndSettle();

    expect(
      await backupRepository.listPoliciesForScope(
        projectId: 'project-shop',
        serverId: 'server-prod-04',
      ),
      isEmpty,
    );
    expect(
      await backupRepository.listPoliciesForScope(
        projectId: 'project-shop',
        serverId: 'server-other',
      ),
      hasLength(1),
    );
    expect(
      await backupRepository.listArtifactsForScope(
        projectId: 'project-shop',
        serverId: 'server-prod-04',
      ),
      isEmpty,
    );
    expect(
      await backupRepository.listRunsForScope(
        projectId: 'project-shop',
        serverId: 'server-prod-04',
      ),
      isEmpty,
    );
    expect(
      container
          .read(projectBackupProvider)
          .scopeFor(projectId: 'project-shop', serverId: 'server-prod-04')
          .policies,
      isEmpty,
    );
    expect(
      container
          .read(projectBackupProvider)
          .scopeFor(projectId: 'project-shop', serverId: 'server-other')
          .policies,
      hasLength(1),
    );
  });

  testWidgets('Failed PostgreSQL deletion keeps local backup policies', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final backupRepository = BackupRepository(database);
    await backupRepository.upsertPolicy(
      const BackupPolicyRecord(
        id: 'daily-main',
        projectId: 'project-shop',
        serverId: 'server-prod-04',
        name: 'Daily main',
        destinationId: 'local',
        databaseName: 'dd_shop_app',
        scheduleMode: 'daily_once',
        time1Hhmm: '02:00',
        managedTaskId: 'backup-pg-daily-main',
      ),
    );
    final sshService = _FailingServiceSshService(
      failOperationId: 'service_delete',
    );
    addTearDown(sshService.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            testServerConnectionPayload,
          ),
          sshServiceProvider.overrideWithValue(sshService),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ServerManagementView(
              server: serverWithCredentialsAndDatabaseEnabled,
              initialTabIndex: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollToServiceKey(tester, 'service-delete-database');
    tester
        .widget<OutlinedButton>(
          find.byKey(const Key('service-delete-database')),
        )
        .onPressed
        ?.call();
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('I understand this action permanently deletes all data.'),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('service-delete-confirm-input')),
      'DELETE',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-delete-confirm-button')));
    await tester.pumpAndSettle();

    expect(
      await backupRepository.listPoliciesForScope(
        projectId: 'project-shop',
        serverId: 'server-prod-04',
      ),
      hasLength(1),
    );
  });

  testWidgets('Temporary access opens report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _FailingFirewallSshService();
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-enable-postgres-remote-access');
    await tester.tap(
      find.byKey(const Key('service-enable-postgres-remote-access')),
    );
    await tester.pumpAndSettle();
    await _confirmCurrentDevicePostgresAccess(tester);

    expect(find.text('Temporary database access is on.'), findsOneWidget);
    expect(analytics.firewallEvents, [
      (action: FirewallAction.apply, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Temporary access open failures report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _FailingFirewallSshService(
      failOperationId: 'apply_staged',
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-enable-postgres-remote-access');
    await tester.tap(
      find.byKey(const Key('service-enable-postgres-remote-access')),
    );
    await tester.pumpAndSettle();
    await _confirmCurrentDevicePostgresAccess(tester);

    expect(
      find.byKey(const Key('service-postgres-remote-access-error')),
      findsOneWidget,
    );
    expect(analytics.firewallEvents, [
      (action: FirewallAction.apply, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Temporary access open throws report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _FailingFirewallSshService(
      throwOperationId: 'apply_staged',
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-enable-postgres-remote-access');
    await tester.tap(
      find.byKey(const Key('service-enable-postgres-remote-access')),
    );
    await tester.pumpAndSettle();
    await _confirmCurrentDevicePostgresAccess(tester);

    expect(analytics.firewallEvents, [
      (action: FirewallAction.apply, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Temporary access closes report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _FailingFirewallSshService();
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-enable-postgres-remote-access');
    await tester.tap(
      find.byKey(const Key('service-enable-postgres-remote-access')),
    );
    await tester.pumpAndSettle();
    await _confirmCurrentDevicePostgresAccess(tester);
    await tester.tap(
      find.byKey(const Key('service-close-postgres-remote-access')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Temporary database access closed.'), findsOneWidget);
    expect(analytics.firewallEvents, [
      (action: FirewallAction.apply, outcome: DataOperationOutcome.success),
      (action: FirewallAction.rollback, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Temporary access close failures report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _FailingFirewallSshService(failOperationId: 'rollback');
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-enable-postgres-remote-access');
    await tester.tap(
      find.byKey(const Key('service-enable-postgres-remote-access')),
    );
    await tester.pumpAndSettle();
    await _confirmCurrentDevicePostgresAccess(tester);
    await tester.tap(
      find.byKey(const Key('service-close-postgres-remote-access')),
    );
    await tester.pumpAndSettle();

    expect(analytics.firewallEvents, [
      (action: FirewallAction.apply, outcome: DataOperationOutcome.success),
      (action: FirewallAction.rollback, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Temporary access close throws report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _FailingFirewallSshService(throwOperationId: 'rollback');
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-enable-postgres-remote-access');
    await tester.tap(
      find.byKey(const Key('service-enable-postgres-remote-access')),
    );
    await tester.pumpAndSettle();
    await _confirmCurrentDevicePostgresAccess(tester);
    await tester.tap(
      find.byKey(const Key('service-close-postgres-remote-access')),
    );
    await tester.pumpAndSettle();

    expect(analytics.firewallEvents, [
      (action: FirewallAction.apply, outcome: DataOperationOutcome.success),
      (action: FirewallAction.rollback, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Services tab shows database storage shape', (
    WidgetTester tester,
  ) async {
    final sshService = _StorageStatusSshService(storage: _namedVolumeStorage());
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-footer-database-storage');

    expect(find.text('Database storage'), findsOneWidget);
    expect(find.text('postgres_postgres_data (named volume)'), findsOneWidget);
    expect(find.text('/var/lib/postgresql/data/pgdata'), findsOneWidget);
    expect(find.text('12.3 kB'), findsOneWidget);
    expect(find.text('Up to date'), findsOneWidget);
    expect(find.text('Kept upgrade copies (1)'), findsNothing);
    expect(
      find.byKey(const Key('service-postgres-storage-migrate')),
      findsNothing,
    );
    expect(find.widgetWithText(OutlinedButton, 'Remove'), findsNothing);
  });

  testWidgets('Services tab migrates the old storage layout', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _StorageStatusSshService(
      storage: _legacyVolumeStorage(),
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-postgres-storage-migrate');
    expect(find.text('Needs migration'), findsOneWidget);
    expect(find.text('${'a' * 12}… (anonymous volume)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('service-postgres-storage-migrate')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('service-migrate-storage-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('service-migrate-storage-confirm')));
    await tester.pumpAndSettle();

    expect(sshService.migrateCalls, 1);
    expect(analytics.serviceEvents, [
      (
        action: ServiceAction.migrateStorage,
        outcome: DataOperationOutcome.success,
      ),
    ]);
  });

  testWidgets('Services tab reports a detached cluster instead of ready', (
    WidgetTester tester,
  ) async {
    final sshService = _StorageStatusSshService(
      storage: _detachedVolumeStorage(),
      effectiveStatus: 'unhealthy',
      readinessStatus: 'unhealthy',
      readinessDetail: _detachedError,
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-footer-database-storage');

    expect(find.text('Unhealthy'), findsOneWidget);
    expect(find.text('Data volume may be detached'), findsOneWidget);
    expect(find.text(_detachedError), findsOneWidget);
    expect(find.text('Old data copies (1)'), findsOneWidget);
    expect(
      find.byKey(const Key('service-postgres-storage-migrate')),
      findsNothing,
    );
    final removeButton = tester.widget<OutlinedButton>(
      find.byKey(Key('service-postgres-storage-remove-${'c' * 64}')),
    );
    expect(removeButton.onPressed, isNull);
  });

  testWidgets('Services tab removes the kept old copy', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final storage = _legacyVolumeStorage()
      ..['detached_storage_volumes'] = <String>['b' * 64];
    final sshService = _StorageStatusSshService(storage: storage);
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(
      tester,
      'service-postgres-storage-remove-${'b' * 64}',
    );
    expect(find.text('Old data copies (1)'), findsOneWidget);
    final removeButton = tester.widget<OutlinedButton>(
      find.byKey(Key('service-postgres-storage-remove-${'b' * 64}')),
    );
    removeButton.onPressed?.call();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('service-remove-storage-dialog')),
      findsOneWidget,
    );
    await tester.tap(
      find.text('I understand the old copy is deleted permanently.'),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('service-delete-confirm-input')),
      'DELETE',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-delete-confirm-button')));
    await tester.pumpAndSettle();

    expect(sshService.removeCalls, 1);
    final settings =
        sshService
                .lastParamsByOperation['service_remove_legacy_storage']!['settings']
            as Map<String, dynamic>;
    expect(settings['legacy_storage_volume'], 'b' * 64);
    expect(analytics.serviceEvents, [
      (
        action: ServiceAction.removeLegacyStorage,
        outcome: DataOperationOutcome.success,
      ),
    ]);
  });

  testWidgets('Services tab keeps storage unknown without enrichment', (
    WidgetTester tester,
  ) async {
    final sshService = _StorageStatusSshService();
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-footer-database-storage');

    expect(find.text('Ready'), findsWidgets);
    expect(
      find.text('Storage details are unavailable for this service.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('service-postgres-storage-migrate')),
      findsNothing,
    );
    expect(find.widgetWithText(OutlinedButton, 'Remove'), findsNothing);
  });

  testWidgets('Services tab cancels storage migration', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _StorageStatusSshService(
      storage: _legacyVolumeStorage(),
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-postgres-storage-migrate');
    await tester.tap(find.byKey(const Key('service-postgres-storage-migrate')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(sshService.migrateCalls, 0);
    expect(analytics.serviceEvents, isEmpty);
  });

  testWidgets('Services tab reports migration failures', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _StorageStatusSshService(
      storage: _legacyVolumeStorage(),
      failOperationId: 'service_migrate_storage',
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-postgres-storage-migrate');
    await tester.tap(find.byKey(const Key('service-postgres-storage-migrate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-migrate-storage-confirm')));
    await tester.pumpAndSettle();

    expect(analytics.serviceEvents, [
      (
        action: ServiceAction.migrateStorage,
        outcome: DataOperationOutcome.failure,
      ),
    ]);
  });

  testWidgets('Services tab reports migration throws', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _StorageStatusSshService(
      storage: _legacyVolumeStorage(),
      throwOperationId: 'service_migrate_storage',
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-postgres-storage-migrate');
    await tester.tap(find.byKey(const Key('service-postgres-storage-migrate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-migrate-storage-confirm')));
    await tester.pumpAndSettle();

    expect(analytics.serviceEvents, [
      (
        action: ServiceAction.migrateStorage,
        outcome: DataOperationOutcome.failure,
      ),
    ]);
  });

  testWidgets('Services tab cancels old-copy removal', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final storage = _legacyVolumeStorage()
      ..['detached_storage_volumes'] = <String>['b' * 64];
    final sshService = _StorageStatusSshService(storage: storage);
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(
      tester,
      'service-postgres-storage-remove-${'b' * 64}',
    );
    final removeButton = tester.widget<OutlinedButton>(
      find.byKey(Key('service-postgres-storage-remove-${'b' * 64}')),
    );
    removeButton.onPressed?.call();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(sshService.removeCalls, 0);
    expect(analytics.serviceEvents, isEmpty);
  });

  testWidgets('Services tab dismisses the migration dialog', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _StorageStatusSshService(
      storage: _legacyVolumeStorage(),
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-postgres-storage-migrate');
    await tester.tap(find.byKey(const Key('service-postgres-storage-migrate')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('service-migrate-storage-dialog')),
      findsNothing,
    );
    expect(sshService.migrateCalls, 0);
    expect(analytics.serviceEvents, isEmpty);
  });

  testWidgets('Services tab disables migration while stopped', (
    WidgetTester tester,
  ) async {
    final storage = _legacyVolumeStorage()..['data_size_bytes'] = null;
    final sshService = _StorageStatusSshService(
      storage: storage,
      running: false,
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-postgres-storage-migrate');
    expect(find.text('Unknown'), findsOneWidget);
    final migrateButton = tester.widget<FilledButton>(
      find.byKey(const Key('service-postgres-storage-migrate')),
    );
    expect(migrateButton.onPressed, isNull);
  });

  testWidgets('Services tab disables storage actions while one runs', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final storage = _legacyVolumeStorage()
      ..['detached_storage_volumes'] = <String>['b' * 64];
    final sshService = _StorageStatusSshService(
      storage: storage,
      pendingOperationId: 'service_migrate_storage',
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-postgres-storage-migrate');
    await tester.tap(find.byKey(const Key('service-postgres-storage-migrate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-migrate-storage-confirm')));
    for (var i = 0; i < 50 && sshService.pendingCompletion == null; i += 1) {
      await tester.pump();
    }
    expect(sshService.pendingCompletion, isNotNull);
    // The busy flag lands after the frame that started the action, so wait
    // for the disabled frame rather than reading mid-flight.
    var migrateDisabled = false;
    for (var i = 0; i < 50 && !migrateDisabled; i += 1) {
      await tester.pump();
      migrateDisabled =
          tester
              .widget<FilledButton>(
                find.byKey(const Key('service-postgres-storage-migrate')),
              )
              .onPressed ==
          null;
    }
    expect(migrateDisabled, isTrue);

    final migrateButton = tester.widget<FilledButton>(
      find.byKey(const Key('service-postgres-storage-migrate')),
    );
    final removeButton = tester.widget<OutlinedButton>(
      find.byKey(Key('service-postgres-storage-remove-${'b' * 64}')),
    );
    expect(migrateButton.onPressed, isNull);
    expect(removeButton.onPressed, isNull);

    sshService.pendingCompletion!.complete(const <String, dynamic>{
      'status': 'success',
    });
    await tester.pumpAndSettle();
    expect(analytics.serviceEvents, [
      (
        action: ServiceAction.migrateStorage,
        outcome: DataOperationOutcome.success,
      ),
    ]);
  });

  testWidgets('Services tab disables storage actions on conflict', (
    WidgetTester tester,
  ) async {
    final storage = _legacyVolumeStorage()
      ..['detached_storage_volumes'] = <String>['b' * 64];
    final sshService = _StorageStatusSshService(
      storage: storage,
      conflictBlocked: true,
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-postgres-storage-migrate');
    final migrateButton = tester.widget<FilledButton>(
      find.byKey(const Key('service-postgres-storage-migrate')),
    );
    final removeButton = tester.widget<OutlinedButton>(
      find.byKey(Key('service-postgres-storage-remove-${'b' * 64}')),
    );
    expect(migrateButton.onPressed, isNull);
    expect(removeButton.onPressed, isNull);
  });

  testWidgets('Services tab disables migration for a detached legacy cluster', (
    WidgetTester tester,
  ) async {
    final storage = _detachedVolumeStorage()
      ..['storage_layout_current'] = false;
    final sshService = _StorageStatusSshService(
      storage: storage,
      effectiveStatus: 'unhealthy',
      readinessStatus: 'unhealthy',
      readinessDetail: _detachedError,
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-postgres-storage-migrate');
    final migrateButton = tester.widget<FilledButton>(
      find.byKey(const Key('service-postgres-storage-migrate')),
    );
    final removeButton = tester.widget<OutlinedButton>(
      find.byKey(Key('service-postgres-storage-remove-${'c' * 64}')),
    );
    expect(migrateButton.onPressed, isNull);
    expect(removeButton.onPressed, isNull);
  });

  testWidgets('Services tab sends desktop-known databases with status', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await _seedKnownDatabases(database);
    final sshService = _StorageStatusSshService(storage: _namedVolumeStorage());
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        projectRepositoryProvider.overrideWithValue(
          ProjectRepository(database),
        ),
        projectManagedDatabaseRepositoryProvider.overrideWithValue(
          ProjectManagedDatabaseRepository(database),
        ),
        sshServiceProvider.overrideWithValue(sshService),
      ],
    );

    final settings =
        sshService.lastParamsByOperation['service_status']!['settings']
            as Map<String, dynamic>;
    expect(settings['expected_databases'], ['dd_shop_app', 'dd_shop_jobs']);
  });

  testWidgets('Services tab sends desktop-known databases with migration', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await _seedKnownDatabases(database);
    final sshService = _StorageStatusSshService(
      storage: _legacyVolumeStorage(),
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        projectRepositoryProvider.overrideWithValue(
          ProjectRepository(database),
        ),
        projectManagedDatabaseRepositoryProvider.overrideWithValue(
          ProjectManagedDatabaseRepository(database),
        ),
        sshServiceProvider.overrideWithValue(sshService),
      ],
    );

    await _scrollToServiceKey(tester, 'service-postgres-storage-migrate');
    await tester.tap(find.byKey(const Key('service-postgres-storage-migrate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-migrate-storage-confirm')));
    await tester.pumpAndSettle();

    final settings =
        sshService.lastParamsByOperation['service_migrate_storage']!['settings']
            as Map<String, dynamic>;
    expect(settings['expected_databases'], ['dd_shop_app', 'dd_shop_jobs']);
  });

  testWidgets('Services tab sends empty expectations without projects', (
    WidgetTester tester,
  ) async {
    final sshService = _StorageStatusSshService(storage: _namedVolumeStorage());
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    final settings =
        sshService.lastParamsByOperation['service_status']!['settings']
            as Map<String, dynamic>;
    expect(settings['expected_databases'], isEmpty);
  });

  testWidgets('Services tab survives a failing expectations read', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customStatement('DROP TABLE projects');
    final sshService = _StorageStatusSshService(storage: _namedVolumeStorage());
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        projectRepositoryProvider.overrideWithValue(
          ProjectRepository(database),
        ),
        sshServiceProvider.overrideWithValue(sshService),
      ],
    );

    await _scrollToServiceKey(tester, 'service-footer-database-storage');
    expect(find.text('Database storage'), findsOneWidget);
    final settings =
        sshService.lastParamsByOperation['service_status']!['settings']
            as Map<String, dynamic>;
    expect(settings['expected_databases'], isEmpty);
  });

  testWidgets('Services tab locks the major version in database settings', (
    WidgetTester tester,
  ) async {
    final sshService = _StorageStatusSshService(storage: _namedVolumeStorage());
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-configure-database');
    await tester.tap(find.byKey(const Key('service-configure-database')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('service-config-dialog-database')), findsOne);
    expect(find.byKey(const Key('postgres-version-dropdown')), findsNothing);
    expect(find.text('PostgreSQL 17 (current version)'), findsOneWidget);
    expect(
      find.text(
        'The major version cannot change here. Upgrade to move your data '
        'safely.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('postgres-upgrade-major-button')),
      findsOneWidget,
    );
    // Extensions stay editable while the version is fixed.
    expect(find.byKey(const Key('postgres-advanced-options')), findsOneWidget);
  });

  testWidgets('Services tab upgrades the database major version', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _StorageStatusSshService(storage: _namedVolumeStorage());
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-configure-database');
    await tester.tap(find.byKey(const Key('service-configure-database')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('postgres-upgrade-major-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('service-upgrade-major-dialog')),
      findsOneWidget,
    );
    expect(find.text('Upgrade PostgreSQL version'), findsOneWidget);
    expect(
      find.text(
        'Moves every database to the new version. The database stops during '
        'the move — larger databases take longer — and restarts automatically.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('postgres-upgrade-target-dropdown')),
      findsOneWidget,
    );
    expect(find.text('18 (newest)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('service-upgrade-major-confirm')));
    await tester.pumpAndSettle();

    expect(sshService.upgradeCalls, 1);
    final settings =
        sshService.lastParamsByOperation['service_upgrade_major']!['settings']
            as Map<String, dynamic>;
    expect(settings['postgres_version'], '18');
    expect(find.text('Database upgraded to PostgreSQL 18.'), findsWidgets);
    expect(analytics.serviceEvents, [
      (
        action: ServiceAction.upgradeMajor,
        outcome: DataOperationOutcome.success,
      ),
    ]);
  });

  testWidgets('Services tab upgrades to the selected target version', (
    WidgetTester tester,
  ) async {
    final sshService = _StorageStatusSshService(storage: _namedVolumeStorage());
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-configure-database');
    await tester.tap(find.byKey(const Key('service-configure-database')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('postgres-upgrade-major-button')));
    await tester.pumpAndSettle();

    // A cleared selection keeps the current target rather than crashing.
    tester
        .widget<AppSelectFormField<String>>(
          find.byKey(const Key('postgres-upgrade-target-dropdown')),
        )
        .onChanged
        ?.call(null);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('postgres-upgrade-target-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('16'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-upgrade-major-confirm')));
    await tester.pumpAndSettle();

    expect(sshService.upgradeCalls, 1);
    final settings =
        sshService.lastParamsByOperation['service_upgrade_major']!['settings']
            as Map<String, dynamic>;
    expect(settings['postgres_version'], '16');
    expect(find.text('Database upgraded to PostgreSQL 16.'), findsWidgets);
  });

  testWidgets('Services tab cancels the major upgrade', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _StorageStatusSshService(storage: _namedVolumeStorage());
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-configure-database');
    await tester.tap(find.byKey(const Key('service-configure-database')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('postgres-upgrade-major-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('service-upgrade-major-dialog')),
        matching: find.widgetWithText(TextButton, 'Cancel'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('service-upgrade-major-dialog')), findsNothing);
    // Back at the settings dialog; nothing was dispatched.
    expect(find.byKey(const Key('service-config-dialog-database')), findsOne);
    expect(sshService.upgradeCalls, 0);
    expect(analytics.serviceEvents, isEmpty);
  });

  testWidgets('Services tab dismisses the upgrade dialog', (
    WidgetTester tester,
  ) async {
    final sshService = _StorageStatusSshService(storage: _namedVolumeStorage());
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-configure-database');
    await tester.tap(find.byKey(const Key('service-configure-database')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('postgres-upgrade-major-button')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('service-upgrade-major-dialog')), findsNothing);
    expect(sshService.upgradeCalls, 0);
  });

  testWidgets('Services tab blocks the upgrade while stopped', (
    WidgetTester tester,
  ) async {
    final sshService = _StorageStatusSshService(
      storage: _namedVolumeStorage(),
      running: false,
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(tester, 'service-configure-database');
    await tester.tap(find.byKey(const Key('service-configure-database')));
    await tester.pumpAndSettle();

    final upgradeButton = tester.widget<TextButton>(
      find.byKey(const Key('postgres-upgrade-major-button')),
    );
    expect(upgradeButton.onPressed, isNull);
    expect(
      find.byTooltip(
        'Start the database service before upgrading the major version.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Services tab reports upgrade failures', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _StorageStatusSshService(
      storage: _namedVolumeStorage(),
      failOperationId: 'service_upgrade_major',
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(tester, 'service-configure-database');
    await tester.tap(find.byKey(const Key('service-configure-database')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('postgres-upgrade-major-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-upgrade-major-confirm')));
    await tester.pumpAndSettle();

    expect(sshService.upgradeCalls, 0);
    expect(find.text('Storage engine exploded.'), findsWidgets);
    expect(analytics.serviceEvents, [
      (
        action: ServiceAction.upgradeMajor,
        outcome: DataOperationOutcome.failure,
      ),
    ]);
  });

  testWidgets('Services tab sends desktop-known databases with upgrade', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await _seedKnownDatabases(database);
    final sshService = _StorageStatusSshService(storage: _namedVolumeStorage());
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        projectRepositoryProvider.overrideWithValue(
          ProjectRepository(database),
        ),
        projectManagedDatabaseRepositoryProvider.overrideWithValue(
          ProjectManagedDatabaseRepository(database),
        ),
        sshServiceProvider.overrideWithValue(sshService),
      ],
    );

    await _scrollToServiceKey(tester, 'service-configure-database');
    await tester.tap(find.byKey(const Key('service-configure-database')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('postgres-upgrade-major-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-upgrade-major-confirm')));
    await tester.pumpAndSettle();

    final settings =
        sshService.lastParamsByOperation['service_upgrade_major']!['settings']
            as Map<String, dynamic>;
    expect(settings['expected_databases'], ['dd_shop_app', 'dd_shop_jobs']);
  });

  testWidgets('Services tab persists the upgraded version locally', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final credentialRepository = ServerCredentialRepository(database);
    final repository = ServerRepository(database, credentialRepository);
    final created = await repository.createServer(
      draft: const ServerDraft(
        name: 'Upgrade server',
        host: '203.0.113.31',
        port: 22,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.password,
        sshPassword: 'test-password',
      ),
      specs: const ServerSpecs(osName: 'Ubuntu 24.04 LTS'),
    );
    await repository.updateServerServices(
      serverId: created.id,
      enableDatabases: true,
      enableEmailAccounts: false,
      enableDomains: false,
    );
    final savedServer = (await repository.listServers()).single;
    final analytics = FakeAnalyticsService();
    final sshService = _StorageStatusSshService(storage: _namedVolumeStorage());
    addTearDown(sshService.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          sshServiceProvider.overrideWithValue(sshService),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ServerManagementView(server: savedServer, initialTabIndex: 1),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollToServiceKey(tester, 'service-configure-database');
    await tester.tap(find.byKey(const Key('service-configure-database')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('postgres-upgrade-major-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-upgrade-major-confirm')));
    await tester.pumpAndSettle();

    expect(sshService.upgradeCalls, 1);
    final persisted = (await repository.listServers()).single;
    expect(persisted.postgresConfig.postgresVersion, '18');
    expect(analytics.serviceEvents, [
      (
        action: ServiceAction.upgradeMajor,
        outcome: DataOperationOutcome.success,
      ),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Services tab keeps the local version when the upgrade fails', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final credentialRepository = ServerCredentialRepository(database);
    final repository = ServerRepository(database, credentialRepository);
    final created = await repository.createServer(
      draft: const ServerDraft(
        name: 'Failed upgrade server',
        host: '203.0.113.32',
        port: 22,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.password,
        sshPassword: 'test-password',
      ),
      specs: const ServerSpecs(osName: 'Ubuntu 24.04 LTS'),
    );
    await repository.updateServerServices(
      serverId: created.id,
      enableDatabases: true,
      enableEmailAccounts: false,
      enableDomains: false,
    );
    final savedServer = (await repository.listServers()).single;
    final analytics = FakeAnalyticsService();
    final sshService = _StorageStatusSshService(
      storage: _namedVolumeStorage(),
      failOperationId: 'service_upgrade_major',
    );
    addTearDown(sshService.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          sshServiceProvider.overrideWithValue(sshService),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ServerManagementView(server: savedServer, initialTabIndex: 1),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollToServiceKey(tester, 'service-configure-database');
    await tester.tap(find.byKey(const Key('service-configure-database')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('postgres-upgrade-major-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-upgrade-major-confirm')));
    await tester.pumpAndSettle();

    final persisted = (await repository.listServers()).single;
    expect(persisted.postgresConfig.postgresVersion, '17');
    expect(analytics.serviceEvents, [
      (
        action: ServiceAction.upgradeMajor,
        outcome: DataOperationOutcome.failure,
      ),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Services tab removes a kept pre-upgrade copy', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _StorageStatusSshService(
      storage: _retainedUpgradeStorage(),
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(
      tester,
      'service-postgres-storage-remove-postgres_postgres_data',
    );
    expect(find.text('Kept upgrade copies (2)'), findsOneWidget);
    expect(find.text('postgres_postgres_data (named volume)'), findsWidgets);
    expect(
      find.text('PostgreSQL 17 data, kept when upgrading to 18.'),
      findsOneWidget,
    );
    expect(
      find.text('PostgreSQL 16 data, kept when upgrading to 17.'),
      findsOneWidget,
    );
    final removeButton = tester.widget<OutlinedButton>(
      find.byKey(
        const Key('service-postgres-storage-remove-postgres_postgres_data'),
      ),
    );
    removeButton.onPressed?.call();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('service-remove-storage-dialog')),
      findsOneWidget,
    );
    expect(find.text('Delete pre-upgrade database copy'), findsOneWidget);
    await tester.tap(
      find.text('I understand the pre-upgrade copy is deleted permanently.'),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('service-delete-confirm-input')),
      'DELETE',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-delete-confirm-button')));
    await tester.pumpAndSettle();

    expect(sshService.removeCalls, 1);
    final settings =
        sshService
                .lastParamsByOperation['service_remove_legacy_storage']!['settings']
            as Map<String, dynamic>;
    expect(settings['legacy_storage_volume'], 'postgres_postgres_data');
    expect(find.text('Pre-upgrade database copy removed.'), findsWidgets);
    expect(analytics.serviceEvents, [
      (
        action: ServiceAction.removeLegacyStorage,
        outcome: DataOperationOutcome.success,
      ),
    ]);
  });

  testWidgets('Services tab removes a kept storage-migration subpath', (
    WidgetTester tester,
  ) async {
    final sshService = _StorageStatusSshService(
      storage: _retainedStorageSubpathStorage(),
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    const removeKeyValue =
        'service-postgres-storage-remove-postgres_postgres_data-18/docker';
    const removeKey = Key(removeKeyValue);
    await _scrollToServiceKey(tester, removeKeyValue);
    expect(find.text('Kept migration folders (1)'), findsOneWidget);
    expect(find.text('postgres_postgres_data (named volume)'), findsWidgets);
    expect(
      find.text('Folder 18/docker, kept after storage migration.'),
      findsOneWidget,
    );
    tester.widget<OutlinedButton>(find.byKey(removeKey)).onPressed?.call();
    await tester.pumpAndSettle();

    await tester.tap(
      find.text('I understand the old copy is deleted permanently.'),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('service-delete-confirm-input')),
      'DELETE',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('service-delete-confirm-button')));
    await tester.pumpAndSettle();

    expect(sshService.removeCalls, 1);
    final settings =
        sshService
                .lastParamsByOperation['service_remove_legacy_storage']!['settings']
            as Map<String, dynamic>;
    expect(settings['legacy_storage_volume'], 'postgres_postgres_data');
    expect(settings['legacy_storage_subpath'], '18/docker');
  });

  testWidgets('Services tab cancels a kept-copy removal', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    final sshService = _StorageStatusSshService(
      storage: _retainedUpgradeStorage(),
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );

    await _scrollToServiceKey(
      tester,
      'service-postgres-storage-remove-postgres_postgres_data_pg17',
    );
    final removeButton = tester.widget<OutlinedButton>(
      find.byKey(
        const Key(
          'service-postgres-storage-remove-postgres_postgres_data_pg17',
        ),
      ),
    );
    removeButton.onPressed?.call();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(sshService.removeCalls, 0);
    expect(analytics.serviceEvents, isEmpty);
  });

  testWidgets('Services tab disables kept-copy removal on conflict', (
    WidgetTester tester,
  ) async {
    final sshService = _StorageStatusSshService(
      storage: _retainedUpgradeStorage(),
      conflictBlocked: true,
    );
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 1,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await _scrollToServiceKey(
      tester,
      'service-postgres-storage-remove-postgres_postgres_data',
    );
    final removeButton = tester.widget<OutlinedButton>(
      find.byKey(
        const Key('service-postgres-storage-remove-postgres_postgres_data'),
      ),
    );
    expect(removeButton.onPressed, isNull);
  });
}
