/// Fixtures and fakes for the Server Management view tests.
///
/// Extracted by T-3.6.2 from `server_management_view_test.dart` (4,065 lines,
/// 68 tests directly in `main`). The nine files beside this one are one per
/// tab, mirroring `lib/ui/server/management/`.
///
/// The `server`/`project` constants at the top of the original `main` are
/// hoisted here: every tab used them, and a closure inside `main` cannot be
/// shared across files.
library;

import 'package:ui/data/local/app_database.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/providers/server_provider.dart';
import 'package:ui/services/concurrency_engine.dart';
import 'package:ui/services/ssh_service.dart';
import 'package:ui/ui/server/server_management_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../_support/legacy_ssh_service.dart';

import 'package:drift/native.dart';

export 'package:ui/data/local/app_database.dart';
export 'package:ui/data/local/server_credential_repository.dart';
export 'package:ui/providers/server_list_provider.dart';
export 'package:ui/providers/server_provider.dart';
export 'package:ui/services/concurrency_engine.dart';
export 'package:ui/services/ssh_service.dart';
export 'package:ui/ui/server/management/system_ssh_key_import.dart';
export 'package:ui/ui/server/server_management_view.dart';
export 'package:ui/ui/system/app_dialogs.dart';
export 'package:ui/ui/system/app_window_title.dart';
export 'package:file_selector/file_selector.dart';
export 'package:flutter/material.dart';
export 'package:flutter_riverpod/flutter_riverpod.dart';

export '../../../../_support/sqlite_test_harness.dart';
export '../../../../_support/legacy_ssh_service.dart';

export 'package:drift/native.dart';

const server = Server(
  id: 'server-prod-01',
  name: 'Prod-01',
  host: '203.0.113.10',
  port: 22,
  sshUser: 'root',
  authMethod: ServerAuthMethod.password,
  osName: 'Ubuntu 22.04 LTS',
  serviceDatabaseEnabled: false,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
);
const serverWithCredentials = Server(
  id: 'server-prod-03',
  name: 'Prod-03',
  host: '203.0.113.12',
  port: 22,
  sshUser: 'root',
  authMethod: ServerAuthMethod.password,
  osName: 'Ubuntu 22.04 LTS',
  serviceDatabaseEnabled: false,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
);
const serverWithAlternateCredentials = Server(
  id: 'server-prod-05',
  name: 'Prod-05',
  host: '203.0.113.13',
  port: 22,
  sshUser: 'root',
  authMethod: ServerAuthMethod.password,
  osName: 'Ubuntu 22.04 LTS',
  serviceDatabaseEnabled: false,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
);
const serverWithDatabaseEnabled = Server(
  id: 'server-prod-02',
  name: 'Prod-02',
  host: '203.0.113.11',
  port: 22,
  sshUser: 'root',
  authMethod: ServerAuthMethod.password,
  osName: 'Ubuntu 22.04 LTS',
  serviceDatabaseEnabled: true,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
);
const serverWithCredentialsAndDatabaseEnabled = Server(
  id: 'server-prod-04',
  name: 'Prod-04',
  host: '203.0.113.11',
  port: 22,
  sshUser: 'root',
  authMethod: ServerAuthMethod.password,
  osName: 'Ubuntu 22.04 LTS',
  serviceDatabaseEnabled: true,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
);
const serverWithImportedKey = Server(
  id: 'server-prod-05',
  name: 'Prod-Key',
  host: '203.0.113.50',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.sshKey,
  osName: 'Ubuntu 22.04 LTS',
  serviceDatabaseEnabled: false,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
);

class NoopTaskClient implements EngineTaskClient {
  @override
  String cancelTask(int taskId) => '{"status":"success","cancelled":true}';

  @override
  String getRecentTaskHistory({int limit = 50}) =>
      '{"status":"success","history":[]}';

  @override
  String getTaskResult(int taskId) => '{"status":"success","result":{}}';

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) =>
      '{"status":"success","events":[],"done":true}';

  @override
  String startTask(String jsonPayload) => '{"status":"success","task_id":1}';
}

class HistoryAwareSshService extends LegacySshService {
  HistoryAwareSshService() : super(taskClient: NoopTaskClient());

  @override
  Future<List<EngineTaskHistoryEntry>> getRecentTaskHistoryLegacy({
    int limit = 50,
  }) async {
    return const <EngineTaskHistoryEntry>[
      EngineTaskHistoryEntry(
        taskId: 32,
        status: 'error',
        code: 'ENGINE_RUNTIME_ERROR',
        message: 'Could not enable database extensions.',
        cancelled: false,
        cooperativeCancel: false,
        startedAt: null,
        completedAt: null,
        action: 'run_workflow',
        workflowId: 'postgres',
        operationId: 'service_enable',
        clientOperationId: null,
        idempotencyKey: null,
      ),
    ];
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
    if (workflowId == 'postgres' && operationId == 'service_status') {
      return <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{
          'running': false,
          'configured': true,
        },
      };
    }
    if (workflowId == 'http' && operationId == 'service_status') {
      return <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{'running': true},
      };
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class PostgresStatusSshService extends LegacySshService {
  PostgresStatusSshService({
    required this.configured,
    required this.running,
    this.health = 'healthy',
  }) : super(taskClient: NoopTaskClient());

  final bool configured;
  final bool running;
  final String health;

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
    if (workflowId == 'postgres' && operationId == 'service_status') {
      return <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{
          'running': running,
          'health': health,
          'configured': configured,
          'container_status': <String, dynamic>{
            'present': configured,
            'docker_state': running ? 'running' : 'exited',
            'running': running,
            'health': health,
            'exit_code': 0,
            'image': 'deploydash/postgres-ext:17.10-bookworm-vector',
            'started_at': '2026-07-01T12:00:00Z',
            'effective_status': running && health == 'unhealthy'
                ? 'unhealthy'
                : (running ? 'ready' : 'stopped'),
            'readiness': <String, dynamic>{
              'status': running && health == 'unhealthy'
                  ? 'unhealthy'
                  : 'ready',
              'detail': '',
            },
          },
        },
      };
    }
    if (workflowId == 'http' && operationId == 'service_status') {
      return const <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{'running': true},
      };
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class DatabaseEnableSshService extends LegacySshService {
  DatabaseEnableSshService({this.failEnable = false, this.throwEnable = false})
    : super(taskClient: NoopTaskClient());

  bool configured = false;
  final bool failEnable;
  final bool throwEnable;

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
    if (workflowId == 'http' && operationId == 'service_status') {
      return const <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{'running': true},
      };
    }
    if (workflowId == 'postgres' && operationId == 'service_enable') {
      if (throwEnable) {
        throw StateError('ssh unavailable');
      }
      if (failEnable) {
        return const <String, dynamic>{
          'status': 'error',
          'msg': 'Service engine exploded.',
        };
      }
      configured = true;
      return const <String, dynamic>{
        'status': 'success',
        'msg': 'Database service enabled.',
      };
    }
    if (workflowId == 'postgres' && operationId == 'service_status') {
      return <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{
          'configured': configured,
          'running': configured,
          'health': configured ? 'healthy' : 'none',
        },
      };
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class OverviewMetricsSshService extends LegacySshService {
  OverviewMetricsSshService({
    required this.succeedOverview,
    this.message,
    this.overviewDelay = Duration.zero,
  }) : super(taskClient: NoopTaskClient());

  final bool succeedOverview;
  final String? message;
  final Duration overviewDelay;

  /// When set, the overview call raises instead of returning a payload.
  ///
  /// Distinct from `succeedOverview: false`, which models the ordinary
  /// backend error: a workflow that fails still returns a response. This
  /// models the call itself blowing up, which is the only route to the tab's
  /// `catch`.
  Object? overviewRaises;
  int overviewCalls = 0;

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
    if (workflowId == 'server' && operationId == 'overview_metrics') {
      overviewCalls += 1;
      if (overviewRaises != null) {
        throw overviewRaises!;
      }
      if (overviewDelay > Duration.zero) {
        await Future<void>.delayed(overviewDelay);
      }
      if (!succeedOverview) {
        return <String, dynamic>{
          'status': 'error',
          'msg': message ?? 'Failed collecting metrics.',
        };
      }
      return <String, dynamic>{
        'status': 'success',
        'msg': message ?? 'Metrics fetched from sysstat.',
        'metrics': <String, dynamic>{
          'system': <String, dynamic>{
            'uptime_seconds': 93784,
            'booted_at': '2026-04-17T12:56:16Z',
          },
          'cpu': <String, dynamic>{'usage_percent': 31.5, 'load_1m': 0.44},
          'memory': <String, dynamic>{
            'used_mb': 1024,
            'total_mb': 4096,
            'used_percent': 25.0,
            'swap_used_percent': 0.0,
          },
          'disk': <String, dynamic>{
            'root_used_percent': 42.0,
            'root_free_gb': 88.2,
            'root_total_gb': 128.0,
            'root_inode_used_percent': 12.0,
          },
          'network': <String, dynamic>{
            'total_rx_kbps': 12.5,
            'total_tx_kbps': 8.0,
            'interfaces': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'eth0',
                'rx_kbps': 12.5,
                'tx_kbps': 8.0,
              },
            ],
            'top_interface': <String, dynamic>{
              'name': 'eth0',
              'rx_kbps': 12.5,
              'tx_kbps': 8.0,
            },
          },
          'io': <String, dynamic>{
            'total_read_kbps': 4.0,
            'total_write_kbps': 2.0,
            'devices': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'nvme0n1',
                'read_kbps': 4.0,
                'write_kbps': 2.0,
                'util_percent': 9.0,
              },
            ],
            'top_device': <String, dynamic>{
              'name': 'nvme0n1',
              'util_percent': 9.0,
            },
          },
          'collection': <String, dynamic>{
            'window_seconds': 60,
            'oldest_file': '/var/log/sysstat/sa20260417',
            'newest_file': '/var/log/sysstat/sa20260418',
          },
        },
      };
    }
    if (operationId == 'service_status') {
      return const <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{
          'running': true,
          'configured': true,
        },
      };
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

/// The proven Docker storage fake, but only the first status call succeeds.
/// A second call failing is what "before the new server's data arrives" looks
/// like, which is the window G-33 is about.
class FirstCallOnlyDockerStorageSshService extends DockerStorageSshService {
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
    if (workflowId == 'server' &&
        operationId == 'docker_storage_status' &&
        statusCalls >= 1) {
      statusCalls += 1;
      return const <String, dynamic>{
        'status': 'error',
        'msg': 'Couldn\u2019t load Docker storage usage.',
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

class SystemWorkflowSshService extends LegacySshService {
  SystemWorkflowSshService({
    this.rootLoginMode = 'disabled',
    this.rebootRequired = false,
  }) : super(taskClient: NoopTaskClient());

  final String rootLoginMode;
  final bool rebootRequired;
  int systemStatusCalls = 0;
  int systemApplyCalls = 0;
  int systemRestartCalls = 0;
  Map<String, dynamic>? lastApplySettings;

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
    if (workflowId == 'server' && operationId == 'system_status') {
      systemStatusCalls += 1;
      return <String, dynamic>{
        'status': 'success',
        'msg': 'Server system settings refreshed.',
        'settings': <String, dynamic>{
          'root_login_mode': rootLoginMode,
          'root_login_enabled': rootLoginMode != 'disabled',
          'password_auth_enabled': true,
          'ssh_port': 22,
          'timezone': 'UTC',
          'swap_gb': 2,
          'automatic_security_updates_enabled': true,
          'auto_reboot_enabled': false,
          'maintenance_time': '03:00',
          'reboot_required': rebootRequired,
          'reboot_required_packages': rebootRequired
              ? <String>['linux-image-6.8.0-85-generic', 'libc6']
              : <String>[],
          'reboot_required_packages_readable': true,
          'reboot_required_since': rebootRequired ? 1790784000 : null,
        },
      };
    }
    if (workflowId == 'server' && operationId == 'system_restart') {
      systemRestartCalls += 1;
      return const <String, dynamic>{
        'status': 'success',
        'msg': 'Server restarted and health checks passed.',
      };
    }
    if (workflowId == 'server' && operationId == 'system_apply') {
      systemApplyCalls += 1;
      final rawSettings = params?['settings'];
      lastApplySettings = rawSettings is Map
          ? rawSettings.map((key, value) => MapEntry(key.toString(), value))
          : <String, dynamic>{};
      final sshPort = lastApplySettings?['ssh_port'];
      return <String, dynamic>{
        'status': 'success',
        'msg': 'Server system settings applied successfully.',
        'applied_settings': lastApplySettings,
        'connection_update': <String, dynamic>{'port': sshPort ?? 22},
      };
    }
    if (operationId == 'service_status') {
      return const <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{
          'running': true,
          'configured': true,
        },
      };
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class DockerStorageSshService extends LegacySshService {
  DockerStorageSshService({
    this.statusSucceeds = true,
    this.pruneSucceeds = true,
    this.throwOnStatus = false,
    this.throwOnPrune = false,
    this.includeReclaimedBytes = true,
    this.statusEvents = const <Map<String, dynamic>>[],
  }) : super(taskClient: NoopTaskClient());

  final bool statusSucceeds;
  final bool pruneSucceeds;
  final bool throwOnStatus;
  final bool throwOnPrune;
  final bool includeReclaimedBytes;
  final List<Map<String, dynamic>> statusEvents;
  int statusCalls = 0;
  int pruneCalls = 0;
  String? lastPruneTarget;

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
    if (workflowId == 'server' && operationId == 'system_status') {
      return <String, dynamic>{
        'status': 'success',
        'msg': 'Server system settings refreshed.',
        'settings': <String, dynamic>{
          'root_login_enabled': false,
          'password_auth_enabled': true,
          'ssh_port': 22,
          'timezone': 'UTC',
          'swap_gb': 2,
          'automatic_security_updates_enabled': true,
          'auto_reboot_enabled': false,
          'maintenance_time': '03:00',
        },
      };
    }
    if (workflowId == 'server' && operationId == 'docker_storage_status') {
      statusCalls += 1;
      for (final event in statusEvents) {
        onEvent?.call(event);
      }
      if (throwOnStatus) {
        throw Exception('Docker storage status crashed.');
      }
      if (!statusSucceeds) {
        return const <String, dynamic>{
          'status': 'error',
          'msg': 'Couldn’t load Docker storage usage.',
        };
      }
      return <String, dynamic>{
        'status': 'success',
        'msg': 'Docker storage usage refreshed.',
        'storage': <String, dynamic>{
          'images': <String, dynamic>{
            'size_bytes': 1250000000,
            'reclaimable_bytes': 700000000,
            'total_count': 14,
          },
          'build_cache': <String, dynamic>{
            'size_bytes': 450000000,
            'reclaimable_bytes': 450000000,
            'total_count': 28,
          },
          'checked_at': '2026-05-30T12:00:00Z',
        },
      };
    }
    if (workflowId == 'server' && operationId == 'docker_storage_prune') {
      pruneCalls += 1;
      lastPruneTarget = params?['target']?.toString();
      if (throwOnPrune) {
        throw Exception('Docker prune crashed.');
      }
      if (!pruneSucceeds) {
        return const <String, dynamic>{
          'status': 'error',
          'msg': 'Docker cleanup did not finish.',
        };
      }
      final remainingImages = lastPruneTarget == 'unused_images'
          ? 0
          : 1250000000;
      final remainingCache = lastPruneTarget == 'build_cache' ? 0 : 450000000;
      final reclaimedBytes = lastPruneTarget == 'unused_images'
          ? 1250000000
          : 450000000;
      return <String, dynamic>{
        'status': 'success',
        'msg': lastPruneTarget == 'unused_images'
            ? 'Finished removing unused Docker images.'
            : 'Finished removing the Docker build cache.',
        'storage': <String, dynamic>{
          'images': <String, dynamic>{
            'size_bytes': remainingImages,
            'reclaimable_bytes': 0,
            'total_count': lastPruneTarget == 'unused_images' ? 0 : 14,
          },
          'build_cache': <String, dynamic>{
            'size_bytes': remainingCache,
            'reclaimable_bytes': 0,
            'total_count': lastPruneTarget == 'build_cache' ? 0 : 28,
          },
          'checked_at': '2026-05-30T12:05:00Z',
        },
        if (includeReclaimedBytes) 'reclaimed_bytes': reclaimedBytes,
      };
    }
    if (operationId == 'service_status') {
      return const <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{
          'running': true,
          'configured': true,
        },
      };
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class UpdatesWorkflowSshService extends LegacySshService {
  UpdatesWorkflowSshService() : super(taskClient: NoopTaskClient());

  int toolingStatusCalls = 0;
  int toolingUpdateCalls = 0;
  int toolingRollbackCalls = 0;
  List<String> lastUpdateComponentIds = const <String>[];
  String? lastRollbackComponentId;
  bool lastRollbackRestoreData = false;
  bool toolingCurrent = false;
  String statusMode = 'success';
  String updateMode = 'success';
  String rollbackMode = 'success';
  bool emitLogEvents = false;
  bool riskyRollbacksAvailable = false;
  bool postgresServiceUnhealthy = false;
  String? postgresServiceEffectiveStatus;

  Map<String, dynamic> toolingPayload() {
    final railpackCurrent = toolingCurrent;
    return <String, dynamic>{
      'railpack': <String, dynamic>{
        'label': 'Railpack CLI',
        'status': railpackCurrent ? 'current' : 'update_available',
        'current': railpackCurrent ? '0.29.0' : '0.18.0',
        'target': '0.29.0',
      },
      'railpack_build_helper': <String, dynamic>{
        'label': 'Railpack build helper',
        'status': railpackCurrent ? 'current' : 'update_available',
        'current': 'installed',
        'target': 'ghcr.io/railwayapp/railpack-frontend:v0.29.0',
      },
      'railpack_defaults': <String, dynamic>{
        'label': 'Railpack defaults',
        'status': railpackCurrent ? 'current' : 'missing',
        'current': railpackCurrent ? 'installed' : '',
        'target':
            'RAILPACK_FRONTEND_IMAGE=ghcr.io/railwayapp/railpack-frontend:v0.29.0',
      },
    };
  }

  Map<String, dynamic> capabilitiesPayload() {
    final railpackCurrent = toolingCurrent;
    final railpackStatus = railpackCurrent ? 'current' : 'update_available';
    final postgresServiceStatus =
        postgresServiceEffectiveStatus ??
        (postgresServiceUnhealthy ? 'unhealthy' : null);
    return <String, dynamic>{
      'railpack_build_system': <String, dynamic>{
        'id': 'railpack_build_system',
        'category': 'Build and deployment',
        'label': 'Railpack build system',
        'description':
            'Builds web app images from source repositories with one managed Railpack contract.',
        'status': railpackStatus,
        'summary': railpackCurrent
            ? 'Railpack 0.29.0'
            : 'Target Railpack 0.29.0',
        'can_update': !railpackCurrent,
        'can_rollback': railpackCurrent,
        'risk_level': 'low',
        'action_label': 'Update Railpack build system',
        'rollback_label': 'Rollback Railpack build system',
        'details': toolingPayload().values.toList(growable: false),
      },
      'docker_runtime': <String, dynamic>{
        'id': 'docker_runtime',
        'category': 'Build and deployment',
        'label': 'Docker runtime',
        'description': 'Runs app, gateway, and database containers.',
        'status': 'current',
        'summary': 'Docker engine, Compose plugin, and containerd',
        'can_update': false,
        'can_rollback': riskyRollbacksAvailable,
        'risk_level': 'high',
        'rollback_label': 'Rollback Docker runtime',
        'details': const [
          {
            'label': 'Docker engine',
            'status': 'current',
            'current': '26.1.0',
            'target': 'Installed',
          },
        ],
      },
      'http_gateway': <String, dynamic>{
        'id': 'http_gateway',
        'category': 'Traffic',
        'label': 'HTTP gateway',
        'description': 'Routes HTTP and HTTPS traffic through Caddy.',
        'status': 'current',
        'summary': 'Target Caddy image caddy:2.11.2-alpine',
        'can_update': false,
        'can_rollback': true,
        'risk_level': 'low',
        'rollback_label': 'Rollback HTTP gateway',
        'details': const [
          {
            'label': 'Caddy image',
            'status': 'current',
            'current': 'caddy:2.11.2-alpine',
            'target': 'caddy:2.11.2-alpine',
          },
        ],
      },
      'postgresql_database_service': <String, dynamic>{
        'id': 'postgresql_database_service',
        'category': 'Databases',
        'label': 'PostgreSQL database service',
        'description':
            'Managed PostgreSQL service, extensions, roles, and backups.',
        'status': postgresServiceStatus != null ? 'current' : 'not_configured',
        'summary': postgresServiceStatus != null
            ? 'PostgreSQL image is current'
            : 'Not enabled on this server',
        'can_update': false,
        'can_rollback': riskyRollbacksAvailable,
        'risk_level': 'medium',
        'rollback_label': 'Rollback PostgreSQL database service',
        'data_restore_mode': 'restore_recorded_pg_dumpall_backup',
        'data_restore_risk_level': 'destructive',
        'data_restore_label': 'Restore data from the pre-update backup',
        if (postgresServiceStatus != null)
          'service_status': <String, dynamic>{
            'present': postgresServiceStatus != 'missing',
            'docker_state': postgresServiceStatus == 'stopped'
                ? 'exited'
                : 'running',
            'running':
                postgresServiceStatus != 'stopped' &&
                postgresServiceStatus != 'missing',
            'health': postgresServiceStatus,
            'exit_code': 0,
            'image': 'deploydash/postgres-ext:17.10-bookworm-vector',
            'started_at': '2026-07-01T12:00:00Z',
            'effective_status': postgresServiceStatus,
            'readiness': const <String, dynamic>{
              'status': 'unknown',
              'detail': 'pg_isready failed',
            },
          },
        'details': const [
          {
            'label': 'Service image',
            'status': 'not_configured',
            'current': '',
            'target': 'Managed PostgreSQL 17 service',
          },
        ],
      },
      'server_security_baseline': <String, dynamic>{
        'id': 'server_security_baseline',
        'category': 'Server maintenance',
        'label': 'Server security baseline',
        'description':
            'Security and diagnostics packages installed during onboarding.',
        'status': 'current',
        'summary': 'fail2ban, auditd, sysstat, unattended upgrades',
        'can_update': false,
        'can_rollback': false,
        'risk_level': 'low',
        'details': const [
          {
            'label': 'fail2ban',
            'status': 'current',
            'current': '1.0',
            'target': 'Installed',
          },
        ],
      },
      'ubuntu_system_packages': <String, dynamic>{
        'id': 'ubuntu_system_packages',
        'category': 'Server maintenance',
        'label': 'Ubuntu system packages',
        'description': 'Ubuntu package updates managed by apt.',
        'status': 'current',
        'summary': 'Security updates handled by Ubuntu unattended upgrades',
        'can_update': false,
        'can_rollback': false,
        'risk_level': 'low',
        'details': const [
          {
            'label': 'Automatic security updates',
            'status': 'current',
            'current': 'enabled',
            'target': 'Enabled',
          },
        ],
      },
    };
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
    if (workflowId == 'server' && operationId == 'tooling_status') {
      toolingStatusCalls += 1;
      if (statusMode == 'error') {
        return const <String, dynamic>{
          'status': 'error',
          'msg': 'Could not read update status.',
        };
      }
      if (statusMode == 'throw') {
        throw StateError('status exploded');
      }
      if (statusMode == 'invalid_payload') {
        return const <String, dynamic>{
          'status': 'success',
          'tooling': <String, dynamic>{
            'custom_tool': <String, dynamic>{
              'label': 'Custom tool',
              'status': 'unknown',
            },
            'invalid_tool': 'not a map',
          },
          'update_available': false,
        };
      }
      if (statusMode == 'legacy_capabilities') {
        return const <String, dynamic>{
          'status': 'success',
          'capabilities': <String, dynamic>{
            'edge_cache': <String, dynamic>{
              'id': 'edge_cache',
              'category': 'Traffic',
              'label': 'Edge cache',
              'description': 'Caches static responses near the gateway.',
              'status': 'update_available',
              'summary': 'Edge cache needs review',
              'can_update': true,
              'can_rollback': false,
              'risk_level': 'medium',
              'details': <Map<String, dynamic>>[
                <String, dynamic>{
                  'label': 'Cache helper',
                  'status': 'missing',
                  'current': '',
                  'target': 'Installed',
                },
              ],
            },
          },
          'update_available': true,
        };
      }
      final capabilities = capabilitiesPayload();
      if (statusMode == 'empty_summary') {
        final dockerRuntime =
            capabilities['docker_runtime']! as Map<String, dynamic>;
        dockerRuntime['summary'] = '';
      }
      return <String, dynamic>{
        'status': 'success',
        'msg': toolingCurrent
            ? 'Server capabilities are up to date.'
            : 'Server capability updates are available.',
        'managed_software': capabilities,
        'update_available': !toolingCurrent,
      };
    }
    if (workflowId == 'server' && operationId == 'tooling_update') {
      toolingUpdateCalls += 1;
      final rawComponentIds = params?['component_ids'];
      lastUpdateComponentIds = rawComponentIds is List
          ? rawComponentIds.map((value) => value.toString()).toList()
          : const <String>[];
      if (updateMode == 'error') {
        return const <String, dynamic>{
          'status': 'error',
          'msg': 'Could not update server tooling.',
        };
      }
      if (updateMode == 'throw') {
        throw StateError('update exploded');
      }
      toolingCurrent = true;
      if (emitLogEvents) {
        onEvent?.call(const <String, dynamic>{
          'message': 'Writing Railpack helper.',
          'level': 'debug',
        });
        onEvent?.call(const <String, dynamic>{
          'message': '   ',
          'level': 'info',
        });
      }
      onEvent?.call(<String, dynamic>{
        'type': 'server_tooling_update_started',
        'message': 'Updating Deploy Dash server tooling.',
      });
      if (updateMode == 'no_tooling') {
        return const <String, dynamic>{'status': 'success'};
      }
      return <String, dynamic>{
        'status': 'success',
        'msg': 'Server tooling updated successfully.',
        'managed_software': capabilitiesPayload(),
        'update_available': false,
      };
    }
    if (workflowId == 'server' && operationId == 'tooling_rollback') {
      toolingRollbackCalls += 1;
      lastRollbackComponentId = params?['component_id']?.toString();
      lastRollbackRestoreData = params?['restore_data'] == true;
      if (rollbackMode == 'error') {
        return const <String, dynamic>{
          'status': 'error',
          'msg': 'Could not rollback managed software.',
        };
      }
      if (rollbackMode == 'throw') {
        throw StateError('rollback exploded');
      }
      onEvent?.call(<String, dynamic>{
        'type': 'server_tooling_rollback_started',
        'message': 'Rolling back managed server software.',
      });
      return <String, dynamic>{
        'status': 'success',
        'msg': 'Managed server software rolled back.',
        'managed_software': capabilitiesPayload(),
        'update_available': false,
      };
    }
    if (operationId == 'service_status') {
      return const <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{
          'running': true,
          'configured': true,
        },
      };
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class FirewallWorkflowSshService extends LegacySshService {
  FirewallWorkflowSshService({
    this.firewallEnabled = true,
    this.firewallIpv4Enabled = true,
    this.firewallIpv6Enabled = true,
    this.persistentRulesPresent = true,
    this.persistentRulesV4Present = true,
    this.persistentRulesV6Present = true,
    this.netfilterPersistentEnabled = true,
    this.fail2banActive = true,
    this.fail2banEnabled = true,
    this.fail2banSshdJailActive = true,
    this.fail2banCurrentlyBanned = 2,
    this.fail2banTotalFailed = 17,
    this.connectionSourceAddress = '198.51.100.24',
    this.tlsEnabled = true,
    this.tlsCaFingerprint = 'AA:BB:CC:DD',
    this.tlsCaCertificateBase64 =
        'LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCkNBCl0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0K',
    bool stagedPostgresAccess = false,
    Map<String, dynamic>? stagedState,
    this.openPorts = const <Map<String, dynamic>>[
      <String, dynamic>{
        'source': 'host_listener',
        'bind': '::',
        'protocol': 'tcp',
        'port': '22',
        'details': 'sshd',
      },
    ],
  }) : _stagedState =
           stagedState ??
           (stagedPostgresAccess
               ? <String, dynamic>{
                   'token': 'fw-stage-postgres',
                   'expires_at': '2026-04-10T13:00:00Z',
                   'allow_postgres': true,
                   'postgres_source_cidrs': <String>['198.51.100.24/32'],
                 }
               : null),
       super(taskClient: NoopTaskClient());

  final bool firewallEnabled;
  final bool firewallIpv4Enabled;
  final bool firewallIpv6Enabled;
  final bool persistentRulesPresent;
  final bool persistentRulesV4Present;
  final bool persistentRulesV6Present;
  final bool netfilterPersistentEnabled;
  final bool fail2banActive;
  final bool fail2banEnabled;
  final bool fail2banSshdJailActive;
  final int fail2banCurrentlyBanned;
  final int fail2banTotalFailed;
  final String? connectionSourceAddress;
  final bool tlsEnabled;
  final String? tlsCaFingerprint;
  final String? tlsCaCertificateBase64;
  final List<Map<String, dynamic>> openPorts;
  Map<String, dynamic>? lastFirewallApplySettings;
  int firewallApplyCalls = 0;
  int firewallRollbackCalls = 0;
  Map<String, dynamic>? _stagedState;

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
    if (workflowId == 'firewall' && operationId == 'status') {
      return <String, dynamic>{
        'status': 'success',
        'msg': 'Firewall status collected.',
        'firewall_enabled': firewallEnabled,
        'firewall_ipv4_enabled': firewallIpv4Enabled,
        'firewall_ipv6_enabled': firewallIpv6Enabled,
        'persistent_rules_present': persistentRulesPresent,
        'persistent_rules_v4_present': persistentRulesV4Present,
        'persistent_rules_v6_present': persistentRulesV6Present,
        'netfilter_persistent_enabled': netfilterPersistentEnabled,
        'fail2ban_active': fail2banActive,
        'fail2ban_enabled': fail2banEnabled,
        'fail2ban_sshd_jail_active': fail2banSshdJailActive,
        'fail2ban_currently_banned': fail2banCurrentlyBanned,
        'fail2ban_total_failed': fail2banTotalFailed,
        'external_interface': 'eth0',
        'connection_source_address': connectionSourceAddress,
        'staged_state': _stagedState,
      };
    }
    if (workflowId == 'firewall' && operationId == 'apply_staged') {
      firewallApplyCalls += 1;
      final rawSettings = params?['settings'];
      lastFirewallApplySettings = rawSettings is Map
          ? rawSettings.map((key, value) => MapEntry(key.toString(), value))
          : <String, dynamic>{};
      _stagedState = <String, dynamic>{
        'token': 'fw-stage-postgres',
        'expires_at': '2026-04-10T13:00:00Z',
        'allow_postgres': true,
        'postgres_source_cidrs':
            lastFirewallApplySettings?['postgres_source_cidrs'] ??
            const <String>[],
      };
      return <String, dynamic>{
        'status': 'success',
        'msg': 'Firewall rules staged. Commit before rollback deadline.',
        'staged_state': _stagedState,
      };
    }
    if (workflowId == 'firewall' && operationId == 'rollback') {
      firewallRollbackCalls += 1;
      _stagedState = null;
      return const <String, dynamic>{
        'status': 'success',
        'msg': 'Firewall rollback complete.',
      };
    }
    if (workflowId == 'firewall' && operationId == 'scan_open_ports') {
      return <String, dynamic>{'status': 'success', 'open_ports': openPorts};
    }
    if (operationId == 'service_status') {
      return <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{
          'running': true,
          'configured': true,
          'tls_enabled': tlsEnabled,
          'tls_ca_fingerprint': tlsCaFingerprint,
          'tls_ca_certificate_base64': tlsCaCertificateBase64,
        },
      };
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class FakeServerCatalogNotifier extends ServerCatalogNotifier {
  FakeServerCatalogNotifier(this._seedState);

  final ServerCatalogState _seedState;
  String? importedPrivateKey;
  String? importedPublicKey;

  @override
  ServerCatalogState build() => _seedState;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> selectServer(String serverId) async {
    state = state.copyWith(selectedServerId: serverId);
  }

  @override
  Future<void> updateSelectedServerSystemConfig(
    ServerSystemConfig config,
  ) async {
    final selected = state.selectedServer;
    if (selected == null) {
      return;
    }
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

  @override
  Future<void> updateSelectedServerConnectionPort(int port) async {
    final selected = state.selectedServer;
    if (selected == null) {
      return;
    }
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

  @override
  Future<void> updateSelectedServerConnectionHost(String host) async {
    final selected = state.selectedServer;
    if (selected == null) {
      return;
    }
    final updatedServers = state.servers
        .map((server) {
          if (server.id != selected.id) {
            return server;
          }
          return Server(
            id: server.id,
            name: server.name,
            host: host,
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

  @override
  Future<void> updateSelectedServerFirewallConfig(
    ServerFirewallConfig config,
  ) async {
    final selected = state.selectedServer;
    if (selected == null) {
      return;
    }
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

  @override
  Future<void> updateSelectedServerImportedSshKey({
    required String privateKey,
    String? publicKey,
  }) async {
    importedPrivateKey = privateKey;
    importedPublicKey = publicKey;
  }
}

Future<Map<String, dynamic>?> testServerConnectionPayload(Server server) async {
  final credential = switch ((server.id, server.authMethod)) {
    ('server-prod-03', ServerAuthMethod.password) ||
    ('server-prod-04', ServerAuthMethod.password) ||
    (
      'server-prod-05',
      ServerAuthMethod.password,
    ) => <String, dynamic>{'password': 'super-secret'},
    ('server-prod-05', ServerAuthMethod.sshKey) => <String, dynamic>{
      'private_key': 'OLD PRIVATE KEY',
    },
    _ => null,
  };
  if (credential == null) {
    return null;
  }
  return <String, dynamic>{
    'host': server.host,
    'port': server.port,
    'username': server.sshUser,
    ...credential,
  };
}

class ConflictAwareSshService extends LegacySshService {
  ConflictAwareSshService() : super(taskClient: NoopTaskClient());

  @override
  OperationConflictEvaluation evaluateWorkflowConflict({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    bool serializePerHost = true,
  }) {
    if (workflowId == 'postgres' && operationId != 'service_status') {
      return const OperationConflictEvaluation(
        isBlocked: true,
        message: 'Blocked by active conflicting operation.',
        blockingOperationIds: <String>['postgres/service_restart-1'],
        blockingResources: <String>['stack:203.0.113.11:postgres'],
      );
    }
    return const OperationConflictEvaluation(
      isBlocked: false,
      message: 'No resource conflicts detected.',
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
    if (workflowId == 'postgres' && operationId == 'service_status') {
      return const <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{
          'running': true,
          'configured': true,
        },
      };
    }
    if (workflowId == 'http' && operationId == 'service_status') {
      return const <String, dynamic>{
        'status': 'success',
        'service_status': <String, dynamic>{'running': true},
      };
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

Future<void> pumpServerManagement(
  WidgetTester tester, {
  Server? server,
  int initialTabIndex = 0,
  bool isSetupPending = false,
  VoidCallback? onRetrySetup,
  // riverpod 3.x's Override type is intentionally not exported from
  // the public riverpod.dart/flutter_riverpod.dart barrel (ProviderScope
  // itself still declares `final List<Override> overrides` -- it's just
  // not nameable outside the package). No supported way to spell this
  // parameter's type explicitly; ignore is the documented escape hatch.
  // ignore: strict_raw_type
  List overrides = const [],
  Future<void> Function()? onRemoveServer,
  ServerTerminalLineWriter? onTerminalLine,
  ValueChanged<int>? onDestinationSelected,
  ServerSshKeyPicker? pickSshKeyFile,
  ServerSshKeyImporter? importSshKeyFile,
}) async {
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(database.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        serverConnectionPayloadResolverProvider.overrideWithValue(
          testServerConnectionPayload,
        ),
        // ignore: list_element_type_not_assignable
        ...overrides,
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ServerManagementView(
            server: server,
            initialTabIndex: initialTabIndex,
            isSetupPending: isSetupPending,
            onDestinationSelected: onDestinationSelected,
            onTerminalLine: onTerminalLine,
            onRemoveServer: onRemoveServer,
            onRetrySetup: onRetrySetup,
            pickSshKeyFile: pickSshKeyFile,
            importSshKeyFile: importSshKeyFile,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapUpdatesButton(WidgetTester tester) async {
  final button = find.byKey(const Key('server-updates-update-tooling'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}
