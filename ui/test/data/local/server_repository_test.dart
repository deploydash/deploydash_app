import 'dart:io';

import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/server_credential_repository.dart';
import 'package:ui/data/local/server_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('ServerRepository', () {
    late AppDatabase database;
    late ServerCredentialRepository credentialRepository;
    late ServerRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      credentialRepository = ServerCredentialRepository(database);
      repository = ServerRepository(database, credentialRepository);
    });

    tearDown(() async {
      await database.close();
    });

    test('createServer persists server and onboarding state', () async {
      const draft = ServerDraft(
        name: 'Production-01',
        host: '203.0.113.10',
        port: 22,
        sshUser: 'root',
        authMethod: ServerAuthMethod.password,
        sshPassword: 'secret',
      );
      const specs = ServerSpecs(
        osName: 'Ubuntu 22.04',
        cpuArch: 'x86_64',
        memoryMb: 4096,
        diskGb: 80,
      );

      final created = await repository.createServer(draft: draft, specs: specs);
      final servers = await repository.listServers();
      final onboarding = await repository.readOnboardingState();

      expect(servers, hasLength(1));
      expect(servers.first.id, created.id);
      expect(servers.first.name, 'Production-01');
      expect(servers.first.host, '203.0.113.10');
      expect(servers.first.osName, 'Ubuntu 22.04');
      expect(servers.first.serviceDatabaseEnabled, isFalse);
      expect(servers.first.serviceEmailEnabled, isFalse);
      expect(servers.first.serviceDomainEnabled, isFalse);
      expect(servers.first.webServerConfig.enableDnsPluginCloudflare, isFalse);
      expect(servers.first.postgresConfig.postgresVersion, '17');
      expect(servers.first.systemConfig.sshPort, 22);
      expect(servers.first.systemConfig.timezone, 'UTC');
      expect(onboarding.isCompleted, isTrue);
      expect(onboarding.activeServerId, created.id);
      expect(onboarding.currentStep, 'services_selection');
    }, skip: !sqliteAvailable);

    test(
      'updateServerImportedSshKey updates only the credential row',
      () async {
        final created = await repository.createServer(
          draft: const ServerDraft(
            name: 'Prod-Key',
            host: '203.0.113.17',
            port: 22,
            sshUser: 'ubuntu',
            authMethod: ServerAuthMethod.sshKey,
            privateKey: 'old private key',
            publicKey: 'old public key',
          ),
          specs: const ServerSpecs(),
        );

        await repository.updateServerImportedSshKey(
          serverId: created.id,
          privateKey: ' new private key ',
          publicKey: ' new public key ',
        );

        final stored = await credentialRepository.read(
          created.credentialReference,
        );
        final saved = (await repository.listServers()).single;
        expect(stored?.privateKey, 'new private key');
        expect(stored?.publicKey, 'new public key');
        expect(saved.credentialReference.serverId, created.id);
      },
      skip: !sqliteAvailable,
    );

    test(
      'createServer persists the managed user password with the key',
      () async {
        final created = await repository.createServer(
          draft: const ServerDraft(
            name: 'Prod-Managed-Password',
            host: '203.0.113.20',
            port: 22,
            sshUser: 'ubuntu',
            authMethod: ServerAuthMethod.sshKey,
            privateKey: 'private-key',
            publicKey: 'public-key',
            managedUserPassword: 'managed-secret',
          ),
          specs: const ServerSpecs(),
        );

        final stored = await credentialRepository.read(
          created.credentialReference,
        );
        expect(stored?.managedUserPassword, 'managed-secret');
      },
      skip: !sqliteAvailable,
    );

    test(
      'updateServerImportedSshKey keeps the managed user password',
      () async {
        final created = await repository.createServer(
          draft: const ServerDraft(
            name: 'Prod-Key-Password',
            host: '203.0.113.21',
            port: 22,
            sshUser: 'ubuntu',
            authMethod: ServerAuthMethod.sshKey,
            privateKey: 'old private key',
            managedUserPassword: 'managed-secret',
          ),
          specs: const ServerSpecs(),
        );

        await repository.updateServerImportedSshKey(
          serverId: created.id,
          privateKey: 'new private key',
        );

        final stored = await credentialRepository.read(
          created.credentialReference,
        );
        expect(stored?.privateKey, 'new private key');
        expect(stored?.managedUserPassword, 'managed-secret');
      },
      skip: !sqliteAvailable,
    );

    test('saveConnectionFailure stores the managed user password', () async {
      const draft = ServerDraft(
        name: 'Prod-Failure-Password',
        host: '203.0.113.22',
        port: 22,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.sshKey,
        privateKey: 'private-key',
        managedUserPassword: 'managed-secret',
      );

      await repository.saveConnectionFailure(
        draft: draft,
        error: StateError('connection refused'),
      );

      final saved = (await repository.listServers()).single;
      final stored = await credentialRepository.read(saved.credentialReference);
      expect(stored?.managedUserPassword, 'managed-secret');
    }, skip: !sqliteAvailable);

    test('saveConnectionFailure stores credentials separately', () async {
      const draft = ServerDraft(
        name: 'Prod-Failure',
        host: '203.0.113.18',
        port: 22,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.password,
        sshPassword: 'failed-connection-password',
      );

      await repository.saveConnectionFailure(
        draft: draft,
        error: StateError('connection refused'),
      );

      final saved = (await repository.listServers()).single;
      final stored = await credentialRepository.read(saved.credentialReference);
      expect(saved.lastCheckStatus, 'error');
      expect(stored?.sshPassword, 'failed-connection-password');
    }, skip: !sqliteAvailable);

    test('setActiveServer updates active selection', () async {
      final serverOne = await repository.createServer(
        draft: const ServerDraft(
          name: 'Prod-01',
          host: '203.0.113.10',
          port: 22,
          sshUser: 'root',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        specs: const ServerSpecs(),
      );
      final serverTwo = await repository.createServer(
        draft: const ServerDraft(
          name: 'Staging-01',
          host: '203.0.113.11',
          port: 22,
          sshUser: 'root',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        specs: const ServerSpecs(),
      );

      await repository.setActiveServer(serverTwo.id);
      final onboarding = await repository.readOnboardingState();

      expect(serverOne.id, isNot(serverTwo.id));
      expect(onboarding.activeServerId, serverTwo.id);
      expect(onboarding.isCompleted, isTrue);
    }, skip: !sqliteAvailable);

    test(
      'deleteServer clears onboarding when the last server is removed',
      () async {
        final created = await repository.createServer(
          draft: const ServerDraft(
            name: 'Prod-Delete',
            host: '203.0.113.12',
            port: 22,
            sshUser: 'root',
            authMethod: ServerAuthMethod.password,
            sshPassword: 'secret',
          ),
          specs: const ServerSpecs(),
        );

        await repository.deleteServer(created.id);

        final servers = await repository.listServers();
        final onboarding = await repository.readOnboardingState();

        expect(servers, isEmpty);
        expect(onboarding.isCompleted, isFalse);
        expect(onboarding.activeServerId, isNull);
        expect(onboarding.currentStep, 'idle');
      },
      skip: !sqliteAvailable,
    );

    test('updateServerServices persists service toggles', () async {
      final created = await repository.createServer(
        draft: const ServerDraft(
          name: 'Prod-Services',
          host: '203.0.113.13',
          port: 22,
          sshUser: 'root',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        specs: const ServerSpecs(),
      );

      await repository.updateServerServices(
        serverId: created.id,
        enableDatabases: true,
        enableEmailAccounts: true,
        enableDomains: true,
      );

      final servers = await repository.listServers();
      expect(servers.single.serviceDatabaseEnabled, isTrue);
      expect(servers.single.serviceEmailEnabled, isTrue);
      expect(servers.single.serviceDomainEnabled, isTrue);
    }, skip: !sqliteAvailable);

    test('updateServerManagedSoftwareStatus persists cached status', () async {
      final created = await repository.createServer(
        draft: const ServerDraft(
          name: 'Prod-Updates',
          host: '203.0.113.16',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.sshKey,
          privateKey: 'private-key',
        ),
        specs: const ServerSpecs(),
      );

      await repository.updateServerManagedSoftwareStatus(
        serverId: created.id,
        status: ServerManagedSoftwareStatus(
          const <String, Map<String, dynamic>>{
            'railpack_build_system': <String, dynamic>{
              'label': 'Railpack build system',
              'status': 'current',
            },
          },
        ),
      );

      final servers = await repository.listServers();
      expect(
        servers.single.managedSoftwareStatus?.components,
        contains('railpack_build_system'),
      );
      expect(
        servers
            .single
            .managedSoftwareStatus
            ?.components['railpack_build_system']?['label'],
        'Railpack build system',
      );
    }, skip: !sqliteAvailable);

    test('updateServerPostgresConfig persists postgres config', () async {
      final created = await repository.createServer(
        draft: const ServerDraft(
          name: 'Prod-Postgres',
          host: '203.0.113.14',
          port: 22,
          sshUser: 'root',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        specs: const ServerSpecs(),
      );

      const config = ServerPostgresConfig(
        postgresVersion: '18',
        superuserPassword: 'postgres-root',
        enabledExtensions: ['vector', 'pg_trgm'],
      );
      await repository.updateServerPostgresConfig(
        serverId: created.id,
        config: config,
      );

      final servers = await repository.listServers();
      expect(servers.single.postgresConfig.postgresVersion, '18');
      expect(servers.single.postgresConfig.superuserPassword, 'postgres-root');
      expect(servers.single.postgresConfig.enabledExtensions, [
        'vector',
        'pg_trgm',
      ]);
    }, skip: !sqliteAvailable);

    test('updateServerSystemConfig persists system config', () async {
      final created = await repository.createServer(
        draft: const ServerDraft(
          name: 'Prod-System',
          host: '203.0.113.15',
          port: 22,
          sshUser: 'root',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        specs: const ServerSpecs(),
      );

      const config = ServerSystemConfig(
        timezone: 'Europe/London',
        sshPort: 2202,
        automaticSecurityUpdatesEnabled: false,
      );
      await repository.updateServerSystemConfig(
        serverId: created.id,
        config: config,
      );

      final servers = await repository.listServers();
      expect(servers.single.systemConfig.timezone, 'Europe/London');
      expect(servers.single.systemConfig.sshPort, 2202);
      expect(
        servers.single.systemConfig.automaticSecurityUpdatesEnabled,
        isFalse,
      );
    }, skip: !sqliteAvailable);

    test(
      'updateServerConnectionHost changes host without changing server id',
      () async {
        final created = await repository.createServer(
          draft: const ServerDraft(
            name: 'Prod-Host',
            host: 'www.example.com',
            port: 22,
            sshUser: 'root',
            authMethod: ServerAuthMethod.password,
            sshPassword: 'secret',
          ),
          specs: const ServerSpecs(),
        );

        await repository.updateServerConnectionHost(
          serverId: created.id,
          host: ' ssh.example.com ',
        );

        final servers = await repository.listServers();
        expect(servers, hasLength(1));
        expect(servers.single.id, created.id);
        expect(servers.single.host, 'ssh.example.com');
        expect(servers.single.port, 22);
      },
      skip: !sqliteAvailable,
    );

    test('ServerPostgresConfig drops unsupported extensions when decoding', () {
      final decoded = ServerPostgresConfig.fromJsonMap({
        'postgres_version': '18',
        'superuser_password': 'postgres-root',
        'enabled_extensions': ['vector', 'pg_session_jwt', 'pg_trgm'],
      });

      expect(decoded.postgresVersion, '18');
      expect(decoded.superuserPassword, 'postgres-root');
      expect(decoded.enabledExtensions, ['vector', 'pg_trgm']);
    });

    test('saved server exposes an opaque credential reference', () {
      const server = Server(
        id: 'server-inline-key',
        name: 'Primary',
        host: 'example.com',
        port: 22,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.sshKey,
      );

      expect(server.credentialReference.serverId, server.id);
    });

    test('updateServerConnectionHost rejects a blank host', () async {
      final created = await repository.createServer(
        draft: const ServerDraft(
          name: 'Prod-Blank-Host',
          host: 'www.example.com',
          port: 22,
          sshUser: 'root',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        specs: const ServerSpecs(),
      );

      await expectLater(
        () => repository.updateServerConnectionHost(
          serverId: created.id,
          host: '   ',
        ),
        throwsArgumentError,
      );

      final servers = await repository.listServers();
      expect(servers.single.host, 'www.example.com');
    }, skip: !sqliteAvailable);

    test('updateServerWebServerConfig persists web server config', () async {
      final created = await repository.createServer(
        draft: const ServerDraft(
          name: 'Prod-WebServer',
          host: '203.0.113.23',
          port: 22,
          sshUser: 'root',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        specs: const ServerSpecs(),
      );

      const config = ServerWebServerConfig(
        enableHttpsRedirect: false,
        enableAccessLogs: true,
        enableDnsPluginCloudflare: true,
      );
      await repository.updateServerWebServerConfig(
        serverId: created.id,
        config: config,
      );

      final servers = await repository.listServers();
      expect(servers.single.webServerConfig.enableHttpsRedirect, isFalse);
      expect(servers.single.webServerConfig.enableAccessLogs, isTrue);
      expect(servers.single.webServerConfig.enableDnsPluginCloudflare, isTrue);
    }, skip: !sqliteAvailable);

    test('updateServerFirewallConfig persists firewall config', () async {
      final created = await repository.createServer(
        draft: const ServerDraft(
          name: 'Prod-Firewall',
          host: '203.0.113.24',
          port: 22,
          sshUser: 'root',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        specs: const ServerSpecs(),
      );

      const config = ServerFirewallConfig(
        strictMode: false,
        allowPostgres: true,
        rollbackTimeoutSeconds: 120,
      );
      await repository.updateServerFirewallConfig(
        serverId: created.id,
        config: config,
      );

      final servers = await repository.listServers();
      expect(servers.single.firewallConfig.strictMode, isFalse);
      expect(servers.single.firewallConfig.allowPostgres, isTrue);
      expect(servers.single.firewallConfig.rollbackTimeoutSeconds, 120);
    }, skip: !sqliteAvailable);

    test('updateServerConnectionPort changes the port', () async {
      final created = await repository.createServer(
        draft: const ServerDraft(
          name: 'Prod-Port',
          host: '203.0.113.25',
          port: 22,
          sshUser: 'root',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        specs: const ServerSpecs(),
      );

      await repository.updateServerConnectionPort(
        serverId: created.id,
        port: 2202,
      );

      final servers = await repository.listServers();
      expect(servers.single.id, created.id);
      expect(servers.single.port, 2202);
      expect(servers.single.host, '203.0.113.25');
    }, skip: !sqliteAvailable);

    test('server writers delegate to one column writer (shape pin)', () {
      final source = File(
        'lib/data/local/server_repository.dart',
      ).readAsStringSync();
      expect(source.contains('_writeServerColumn('), isTrue);
      expect(
        '_writeServerColumn'.allMatches(source).length,
        greaterThanOrEqualTo(9),
      );
    });

    test(
      'clearActiveServer forgets the selection without touching completion',
      () async {
        final created = await repository.createServer(
          draft: const ServerDraft(
            name: 'Prod-Forget',
            host: '203.0.113.20',
            port: 22,
            sshUser: 'root',
            authMethod: ServerAuthMethod.password,
            sshPassword: 'secret',
          ),
          specs: const ServerSpecs(),
        );
        expect(created.id, isNotEmpty);

        await repository.clearActiveServer();
        final onboarding = await repository.readOnboardingState();

        // G-35: the completion flag and step survive the forget; only the
        // selection clears, and deleteServer still reconciles against it.
        expect(onboarding.activeServerId, isNull);
        expect(onboarding.isCompleted, isTrue);
        expect(onboarding.currentStep, 'services_selection');
      },
      skip: !sqliteAvailable,
    );

    test('updateOnboardingStep records the step', () async {
      await repository.createServer(
        draft: const ServerDraft(
          name: 'Prod-Step',
          host: '203.0.113.21',
          port: 22,
          sshUser: 'root',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'secret',
        ),
        specs: const ServerSpecs(),
      );

      await repository.updateOnboardingStep('connected');
      final onboarding = await repository.readOnboardingState();

      expect(onboarding.currentStep, 'connected');
      expect(onboarding.isCompleted, isTrue);
      expect(onboarding.activeServerId, isNotNull);
    }, skip: !sqliteAvailable);

    test('onboarding writers delegate to one column writer (shape pin)', () {
      final source = File(
        'lib/data/local/server_repository.dart',
      ).readAsStringSync();
      expect(source.contains('_writeOnboardingColumn('), isTrue);
      expect(
        '_writeOnboardingColumn'.allMatches(source).length,
        greaterThanOrEqualTo(4),
      );
    });

    test('ServerDraft exposes a noChange-sentinel copyWith (shape pin)', () {
      final source = File(
        'lib/data/local/server_repository.dart',
      ).readAsStringSync();
      expect(source.contains('ServerDraft copyWith({'), isTrue);
      expect(
        source.contains('static const Object noChange = Object();'),
        isTrue,
      );
    });

    test('ServerDraft copyWith with no arguments preserves every field', () {
      const base = ServerDraft(
        name: 'server.example.com',
        host: '203.0.113.10',
        port: 22,
        sshUser: 'root',
        authMethod: ServerAuthMethod.password,
        sshPassword: 'secret',
        keyPath: '/tmp/id_ed25519',
        privateKey: 'PRIVATE KEY',
        publicKey: 'ssh-ed25519 AAA',
        managedUserPassword: 'managed-secret',
      );
      final copy = base.copyWith();

      expect(copy.name, base.name);
      expect(copy.host, base.host);
      expect(copy.port, base.port);
      expect(copy.sshUser, base.sshUser);
      expect(copy.authMethod, base.authMethod);
      expect(copy.sshPassword, base.sshPassword);
      expect(copy.keyPath, base.keyPath);
      expect(copy.privateKey, base.privateKey);
      expect(copy.publicKey, base.publicKey);
      expect(copy.managedUserPassword, base.managedUserPassword);
    });

    test('ServerDraft copyWith overrides every field', () {
      const base = ServerDraft(
        name: 'server.example.com',
        host: '203.0.113.10',
        port: 22,
        sshUser: 'root',
        authMethod: ServerAuthMethod.password,
      );
      final copy = base.copyWith(
        name: 'other.example.com',
        host: '198.51.100.7',
        port: 2222,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.sshKey,
        sshPassword: 'secret',
        keyPath: '/tmp/id_ed25519',
        privateKey: 'PRIVATE KEY',
        publicKey: 'ssh-ed25519 AAA',
        managedUserPassword: 'managed-secret',
      );

      expect(copy.name, 'other.example.com');
      expect(copy.host, '198.51.100.7');
      expect(copy.port, 2222);
      expect(copy.sshUser, 'ubuntu');
      expect(copy.authMethod, ServerAuthMethod.sshKey);
      expect(copy.sshPassword, 'secret');
      expect(copy.keyPath, '/tmp/id_ed25519');
      expect(copy.privateKey, 'PRIVATE KEY');
      expect(copy.publicKey, 'ssh-ed25519 AAA');
      expect(copy.managedUserPassword, 'managed-secret');
    });

    test('ServerDraft copyWith nullables distinguish null from absent', () {
      const base = ServerDraft(
        name: 'server.example.com',
        host: '203.0.113.10',
        port: 22,
        sshUser: 'root',
        authMethod: ServerAuthMethod.password,
        sshPassword: 'secret',
        keyPath: '/tmp/id_ed25519',
        privateKey: 'PRIVATE KEY',
        publicKey: 'ssh-ed25519 AAA',
        managedUserPassword: 'managed-secret',
      );
      final copy = base.copyWith(
        sshPassword: null,
        keyPath: null,
        privateKey: null,
        publicKey: null,
        managedUserPassword: null,
      );

      expect(copy.sshPassword, isNull);
      expect(copy.keyPath, isNull);
      expect(copy.privateKey, isNull);
      expect(copy.publicKey, isNull);
      expect(copy.managedUserPassword, isNull);
      expect(copy.name, base.name);
      expect(copy.host, base.host);
      expect(copy.port, base.port);
      expect(copy.sshUser, base.sshUser);
      expect(copy.authMethod, base.authMethod);
    });

    group('early save and managed handoff', () {
      const bootstrapDraft = ServerDraft(
        name: 'Pending-01',
        host: '203.0.113.40',
        port: 22,
        sshUser: 'root',
        authMethod: ServerAuthMethod.password,
        sshPassword: 'bootstrap-secret',
      );
      const specs = ServerSpecs(
        osName: 'Ubuntu 24.04',
        cpuArch: 'x86_64',
        memoryMb: 4096,
        diskGb: 80,
      );

      test('createServer records a pending onboarding step', () async {
        final created = await repository.createServer(
          draft: bootstrapDraft,
          specs: specs,
          onboardingStep: 'setup_in_progress',
          setupComplete: false,
        );
        final onboarding = await repository.readOnboardingState();
        final credential = await credentialRepository.read(
          created.credentialReference,
        );

        expect(onboarding.isCompleted, isTrue);
        expect(onboarding.activeServerId, created.id);
        expect(onboarding.currentStep, 'setup_in_progress');
        expect(created.sshUser, 'root');
        // Bootstrap material stays until the handoff verifies: a crash
        // mid-setup resumes with the credentials provisioning needs.
        expect(credential?.sshPassword, 'bootstrap-secret');
        expect(
          await repository.readPendingSetupServerIds(),
          contains(created.id),
        );
      }, skip: !sqliteAvailable);

      test('createServer defaults to setup complete', () async {
        final created = await repository.createServer(
          draft: bootstrapDraft,
          specs: specs,
        );

        expect(
          await repository.readPendingSetupServerIds(),
          isNot(contains(created.id)),
        );
      }, skip: !sqliteAvailable);

      test(
        'adoptManagedIdentity transitions to the managed key and scrubs the bootstrap password',
        () async {
          final created = await repository.createServer(
            draft: bootstrapDraft,
            specs: specs,
            onboardingStep: 'setup_in_progress',
            setupComplete: false,
          );

          final adopted = await repository.adoptManagedIdentity(
            serverId: created.id,
            sshUser: 'ubuntu',
            authMethod: ServerAuthMethod.sshKey,
            privateKey: 'managed-private-key',
            publicKey: 'managed-public-key',
            managedUserPassword: 'managed-unix-password',
          );
          final onboarding = await repository.readOnboardingState();
          final credential = await credentialRepository.read(
            adopted.credentialReference,
          );

          expect(adopted.id, created.id);
          expect(adopted.sshUser, 'ubuntu');
          expect(adopted.authMethod, ServerAuthMethod.sshKey);
          expect(await repository.readPendingSetupServerIds(), isEmpty);
          expect(onboarding.currentStep, 'services_selection');
          expect(credential?.sshPassword, isNull);
          expect(credential?.privateKey, 'managed-private-key');
          expect(credential?.publicKey, 'managed-public-key');
          expect(credential?.managedUserPassword, 'managed-unix-password');
        },
        skip: !sqliteAvailable,
      );

      test('adoptManagedIdentity replaces a bootstrap key', () async {
        final created = await repository.createServer(
          draft: const ServerDraft(
            name: 'Pending-Key',
            host: '203.0.113.41',
            port: 22,
            sshUser: 'root',
            authMethod: ServerAuthMethod.sshKey,
            privateKey: 'bootstrap-private-key',
            publicKey: 'bootstrap-public-key',
          ),
          specs: specs,
          onboardingStep: 'setup_in_progress',
        );

        final adopted = await repository.adoptManagedIdentity(
          serverId: created.id,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.sshKey,
          privateKey: 'managed-private-key',
          publicKey: 'managed-public-key',
        );
        final credential = await credentialRepository.read(
          adopted.credentialReference,
        );

        expect(credential?.privateKey, 'managed-private-key');
        expect(credential?.publicKey, 'managed-public-key');
        expect(credential?.sshPassword, isNull);
      }, skip: !sqliteAvailable);

      test(
        'updatePendingServer rewrites the bootstrap identity in place',
        () async {
          final created = await repository.createServer(
            draft: bootstrapDraft,
            specs: specs,
            onboardingStep: 'setup_in_progress',
            setupComplete: false,
          );

          final updated = await repository.updatePendingServer(
            serverId: created.id,
            draft: const ServerDraft(
              name: 'Pending-01-renamed',
              host: '203.0.113.41',
              port: 2222,
              sshUser: 'admin',
              authMethod: ServerAuthMethod.sshKey,
              privateKey: 'new-bootstrap-key',
              publicKey: 'new-bootstrap-public',
            ),
            specs: const ServerSpecs(
              osName: 'Ubuntu 24.04',
              cpuArch: 'aarch64',
              memoryMb: 8192,
              diskGb: 160,
            ),
          );
          final credential = await credentialRepository.read(
            updated.credentialReference,
          );

          expect(updated.id, created.id);
          expect(await repository.listServers(), hasLength(1));
          expect(updated.name, 'Pending-01-renamed');
          expect(updated.host, '203.0.113.41');
          expect(updated.port, 2222);
          expect(updated.sshUser, 'admin');
          expect(updated.authMethod, ServerAuthMethod.sshKey);
          expect(updated.cpuArch, 'aarch64');
          expect(updated.memoryMb, 8192);
          expect(credential?.sshPassword, isNull);
          expect(credential?.privateKey, 'new-bootstrap-key');
          expect(credential?.publicKey, 'new-bootstrap-public');
          expect(
            await repository.readPendingSetupServerIds(),
            contains(created.id),
          );
        },
        skip: !sqliteAvailable,
      );

      test(
        'updatePendingServer refuses a server that finished setup',
        () async {
          final created = await repository.createServer(
            draft: bootstrapDraft,
            specs: specs,
          );

          expect(
            () => repository.updatePendingServer(
              serverId: created.id,
              draft: bootstrapDraft,
              specs: specs,
            ),
            throwsStateError,
          );
        },
        skip: !sqliteAvailable,
      );

      test('updatePendingServer refuses a missing server', () async {
        expect(
          () => repository.updatePendingServer(
            serverId: 'missing-server-id',
            draft: bootstrapDraft,
            specs: specs,
          ),
          throwsStateError,
        );
      }, skip: !sqliteAvailable);
    });
  });
}
