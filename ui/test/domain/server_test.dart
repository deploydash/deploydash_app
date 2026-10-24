import 'dart:io';

import 'package:ui/domain/server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Server', () {
    test('exposes only an opaque credential reference', () {
      const server = Server(
        id: 'server-1',
        name: 'Primary',
        host: '203.0.113.10',
        port: 22,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.password,
      );

      expect(server.credentialReference.serverId, 'server-1');
    });

    test('Server exposes a noChange-sentinel copyWith (shape pin)', () {
      final source = File('lib/domain/server.dart').readAsStringSync();
      expect(source.contains('Server copyWith({'), isTrue);
      expect(
        source.contains('static const Object noChange = Object();'),
        isTrue,
      );
    });

    test('config values expose copyWith copiers (shape pin)', () {
      final source = File('lib/domain/server.dart').readAsStringSync();
      expect(source.contains('ServerFirewallConfig copyWith({'), isTrue);
      expect(source.contains('ServerSystemConfig copyWith({'), isTrue);
    });

    test('ServerFirewallConfig copyWith preserves every field', () {
      const base = ServerFirewallConfig(
        strictMode: false,
        allowPostgres: true,
        allowDns: true,
        allowSmtp: true,
        allowMailReceive: true,
        rollbackTimeoutSeconds: 120,
        customRules: [
          ServerFirewallCustomRule(
            id: 'a',
            protocol: 'tcp',
            portStart: 8080,
            portEnd: 8080,
          ),
        ],
      );
      final copy = base.copyWith();

      expect(copy.strictMode, isFalse);
      expect(copy.allowPostgres, isTrue);
      expect(copy.allowDns, isTrue);
      expect(copy.allowSmtp, isTrue);
      expect(copy.allowMailReceive, isTrue);
      expect(copy.rollbackTimeoutSeconds, 120);
      expect(copy.customRules, hasLength(1));
    });

    test('ServerFirewallConfig copyWith overrides every field', () {
      // strictMode: false here proves the copier COPIES (T-026 forces).
      final copy = const ServerFirewallConfig().copyWith(
        strictMode: false,
        allowPostgres: true,
        allowDns: true,
        allowSmtp: true,
        allowMailReceive: true,
        rollbackTimeoutSeconds: 120,
        customRules: [
          ServerFirewallCustomRule(
            id: 'a',
            protocol: 'tcp',
            portStart: 8080,
            portEnd: 8080,
          ),
        ],
      );

      expect(copy.strictMode, isFalse);
      expect(copy.allowPostgres, isTrue);
      expect(copy.allowDns, isTrue);
      expect(copy.allowSmtp, isTrue);
      expect(copy.allowMailReceive, isTrue);
      expect(copy.rollbackTimeoutSeconds, 120);
      expect(copy.customRules, hasLength(1));
    });

    test('ServerSystemConfig copyWith preserves every field', () {
      const base = ServerSystemConfig(
        rootLoginMode: ServerRootLoginMode.passwordAllowed,
        passwordAuthEnabled: true,
        sshPort: 2222,
        timezone: 'Europe/Berlin',
        swapGb: 4,
        automaticSecurityUpdatesEnabled: false,
        autoRebootEnabled: true,
        maintenanceTime: '04:00',
      );
      final copy = base.copyWith();

      expect(copy.rootLoginMode, ServerRootLoginMode.passwordAllowed);
      expect(copy.passwordAuthEnabled, isTrue);
      expect(copy.sshPort, 2222);
      expect(copy.timezone, 'Europe/Berlin');
      expect(copy.swapGb, 4);
      expect(copy.automaticSecurityUpdatesEnabled, isFalse);
      expect(copy.autoRebootEnabled, isTrue);
      expect(copy.maintenanceTime, '04:00');
    });

    test('ServerSystemConfig copyWith overrides every field', () {
      final copy = const ServerSystemConfig().copyWith(
        rootLoginMode: ServerRootLoginMode.restricted,
        passwordAuthEnabled: true,
        sshPort: 2222,
        timezone: 'Europe/Berlin',
        swapGb: 4,
        automaticSecurityUpdatesEnabled: false,
        autoRebootEnabled: true,
        maintenanceTime: '04:00',
      );

      expect(copy.rootLoginMode, ServerRootLoginMode.restricted);
      expect(copy.passwordAuthEnabled, isTrue);
      expect(copy.sshPort, 2222);
      expect(copy.timezone, 'Europe/Berlin');
      expect(copy.swapGb, 4);
      expect(copy.automaticSecurityUpdatesEnabled, isFalse);
      expect(copy.autoRebootEnabled, isTrue);
      expect(copy.maintenanceTime, '04:00');
    });

    test('ServerSystemConfig copyWith resolves the legacy login bool', () {
      // Mirrors copySystemConfig: explicit mode wins; else the legacy bool
      // maps; else the current mode survives (even a non-bool mode).
      const base = ServerSystemConfig(
        rootLoginMode: ServerRootLoginMode.passwordAllowed,
      );

      expect(
        base.copyWith(rootLoginEnabled: true).rootLoginMode,
        ServerRootLoginMode.keyOnly,
      );
      expect(
        base.copyWith(rootLoginEnabled: false).rootLoginMode,
        ServerRootLoginMode.disabled,
      );
      expect(
        base
            .copyWith(
              rootLoginMode: ServerRootLoginMode.restricted,
              rootLoginEnabled: true,
            )
            .rootLoginMode,
        ServerRootLoginMode.restricted,
      );
      expect(
        base.copyWith(timezone: 'Europe/Berlin').rootLoginMode,
        ServerRootLoginMode.passwordAllowed,
      );
    });

    test('copyWith with no arguments preserves every field', () {
      final base = _populatedServer();
      final copy = base.copyWith();

      expect(_fieldValues(copy), _fieldValues(base));
    });

    test('copyWith overrides every field', () {
      final base = _populatedServer();
      final status = ServerManagedSoftwareStatus({
        'caddy': {'version': '2.8'},
      });
      final copy = base.copyWith(
        id: 'server-2',
        name: 'Secondary',
        host: '198.51.100.7',
        port: 2222,
        sshUser: 'deploy',
        authMethod: ServerAuthMethod.sshKey,
        osName: 'Debian 12',
        cpuArch: 'aarch64',
        memoryMb: 8192,
        diskGb: 160,
        serviceDatabaseEnabled: false,
        serviceEmailEnabled: true,
        serviceDomainEnabled: false,
        webServerConfig: const ServerWebServerConfig(enableAccessLogs: true),
        postgresConfig: const ServerPostgresConfig(postgresVersion: '16'),
        firewallConfig: const ServerFirewallConfig(strictMode: false),
        systemConfig: const ServerSystemConfig(timezone: 'Europe/Berlin'),
        managedSoftwareStatus: status,
        lastCheckStatus: 'fail',
        lastError: 'boom',
        lastCheckedAt: DateTime.utc(2026, 2, 2),
        createdAt: DateTime.utc(2026, 2, 3),
        updatedAt: DateTime.utc(2026, 2, 4),
      );

      expect(copy.id, 'server-2');
      expect(copy.name, 'Secondary');
      expect(copy.host, '198.51.100.7');
      expect(copy.port, 2222);
      expect(copy.sshUser, 'deploy');
      expect(copy.authMethod, ServerAuthMethod.sshKey);
      expect(copy.osName, 'Debian 12');
      expect(copy.cpuArch, 'aarch64');
      expect(copy.memoryMb, 8192);
      expect(copy.diskGb, 160);
      expect(copy.serviceDatabaseEnabled, isFalse);
      expect(copy.serviceEmailEnabled, isTrue);
      expect(copy.serviceDomainEnabled, isFalse);
      expect(copy.webServerConfig.enableAccessLogs, isTrue);
      expect(copy.postgresConfig.postgresVersion, '16');
      expect(copy.firewallConfig.strictMode, isFalse);
      expect(copy.systemConfig.timezone, 'Europe/Berlin');
      // T-007#1 still OPEN at T-022 execution: the PRESERVE-side variant —
      // copyWith passes the status object through identically; whatever
      // T-024 does with it is a call-site concern, never this method's.
      expect(identical(copy.managedSoftwareStatus, status), isTrue);
      expect(copy.lastCheckStatus, 'fail');
      expect(copy.lastError, 'boom');
      expect(copy.lastCheckedAt, DateTime.utc(2026, 2, 2));
      expect(copy.createdAt, DateTime.utc(2026, 2, 3));
      expect(copy.updatedAt, DateTime.utc(2026, 2, 4));
    });

    test('copyWith nullable parameters distinguish null from absent', () {
      final base = _populatedServer();
      final copy = base.copyWith(
        osName: null,
        cpuArch: null,
        memoryMb: null,
        diskGb: null,
        managedSoftwareStatus: null,
        lastCheckStatus: null,
        lastError: null,
        lastCheckedAt: null,
        createdAt: null,
        updatedAt: null,
      );

      expect(copy.osName, isNull);
      expect(copy.cpuArch, isNull);
      expect(copy.memoryMb, isNull);
      expect(copy.diskGb, isNull);
      expect(copy.managedSoftwareStatus, isNull);
      expect(copy.lastCheckStatus, isNull);
      expect(copy.lastError, isNull);
      expect(copy.lastCheckedAt, isNull);
      expect(copy.createdAt, isNull);
      expect(copy.updatedAt, isNull);
      expect(copy.id, base.id);
      expect(copy.name, base.name);
      expect(copy.host, base.host);
      expect(copy.port, base.port);
      expect(copy.sshUser, base.sshUser);
      expect(copy.authMethod, base.authMethod);
      expect(copy.serviceDatabaseEnabled, base.serviceDatabaseEnabled);
      expect(copy.serviceEmailEnabled, base.serviceEmailEnabled);
      expect(copy.serviceDomainEnabled, base.serviceDomainEnabled);
      expect(identical(copy.webServerConfig, base.webServerConfig), isTrue);
      expect(identical(copy.postgresConfig, base.postgresConfig), isTrue);
      expect(identical(copy.firewallConfig, base.firewallConfig), isTrue);
      expect(identical(copy.systemConfig, base.systemConfig), isTrue);
    });
  });
}

Server _populatedServer() {
  return Server(
    id: 'server-1',
    name: 'Primary',
    host: '203.0.113.10',
    port: 22,
    sshUser: 'ubuntu',
    authMethod: ServerAuthMethod.password,
    osName: 'Ubuntu 24.04',
    cpuArch: 'x86_64',
    memoryMb: 4096,
    diskGb: 80,
    serviceDatabaseEnabled: true,
    serviceEmailEnabled: false,
    serviceDomainEnabled: true,
    managedSoftwareStatus: ServerManagedSoftwareStatus({
      'docker': {'version': '26'},
    }),
    lastCheckStatus: 'pass',
    lastError: 'stale error',
    lastCheckedAt: DateTime.utc(2026, 1, 1),
    createdAt: DateTime.utc(2026, 1, 2),
    updatedAt: DateTime.utc(2026, 1, 3),
  );
}

/// All 23 fields in constructor order, for whole-value equality.
List<Object?> _fieldValues(Server server) {
  return [
    server.id,
    server.name,
    server.host,
    server.port,
    server.sshUser,
    server.authMethod,
    server.osName,
    server.cpuArch,
    server.memoryMb,
    server.diskGb,
    server.serviceDatabaseEnabled,
    server.serviceEmailEnabled,
    server.serviceDomainEnabled,
    server.webServerConfig,
    server.postgresConfig,
    server.firewallConfig,
    server.systemConfig,
    server.managedSoftwareStatus,
    server.lastCheckStatus,
    server.lastError,
    server.lastCheckedAt,
    server.createdAt,
    server.updatedAt,
  ];
}
