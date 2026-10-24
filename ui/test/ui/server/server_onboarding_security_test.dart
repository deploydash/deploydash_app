import 'dart:io';

import 'package:ui/providers/server_provider.dart';
import 'package:ui/services/managed_ssh_key_service.dart';
import 'package:ui/ui/server/server_onboarding_security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('host key mismatch helpers detect payload and messages', () {
    final state = ServerState(
      error: 'Permission denied',
      errorPayload: const <String, dynamic>{
        'host_key_confirmation_required': true,
        'host_key_mismatch': <String, dynamic>{
          'host': 'srv.example.com',
          'port': 22,
          'old_fingerprint': 'SHA256:old',
          'new_fingerprint': 'SHA256:new',
        },
      },
      events: const <Map<String, dynamic>>[],
    );

    expect(
      isHostKeyMismatchMessage('REMOTE HOST IDENTIFICATION HAS CHANGED'),
      isTrue,
    );
    expect(hasHostKeyMismatch(state), isTrue);
    expect(
      hostKeyConfirmationDetails(
        state,
        fallbackHost: 'fallback.example.com',
        fallbackPort: '2022',
      ),
      (
        host: 'srv.example.com',
        port: '22',
        oldFingerprint: 'SHA256:old',
        newFingerprint: 'SHA256:new',
      ),
    );
  });

  test('host key confirmation details fall back cleanly', () {
    final state = ServerState(
      error: 'permission denied',
      errorPayload: const <String, dynamic>{},
      events: const <Map<String, dynamic>>[
        <String, dynamic>{'message': 'SSH host key error'},
      ],
    );

    expect(hasHostKeyMismatch(state), isTrue);
    expect(
      hostKeyConfirmationDetails(
        state,
        fallbackHost: 'fallback.example.com',
        fallbackPort: '2022',
      ),
      (
        host: 'fallback.example.com',
        port: '2022',
        oldFingerprint: 'Not available',
        newFingerprint: 'Not available',
      ),
    );
  });

  test('managed onboarding draft helpers build ubuntu key flow payloads', () {
    const bootstrapDraft = ServerDraft(
      name: 'server.example.com',
      host: '203.0.113.10',
      port: 22,
      sshUser: 'root',
      authMethod: ServerAuthMethod.password,
      sshPassword: 'secret',
    );
    const keyPair = ManagedSshKeyPair(
      privateKey: 'PRIVATE KEY',
      publicKey: 'ssh-ed25519 AAAATEST deploydash-managed',
    );

    final managedDraft = buildManagedDraft(
      bootstrapDraft: bootstrapDraft,
      managedKeyPair: keyPair,
    );
    final managedConnection = buildManagedConnectionPayload(managedDraft);
    final settings = buildManagedSetupSettings(
      bootstrapDraft: bootstrapDraft,
      managedDraft: managedDraft,
    );
    final savedDraft = buildSavedManagedDraft(
      managedDraft: managedDraft,
      managedConnectionResult: const <String, dynamic>{
        'username': 'ubuntu',
        'port': 2022,
      },
    );

    expect(managedDraft.sshUser, 'ubuntu');
    expect(managedDraft.authMethod, ServerAuthMethod.sshKey);
    expect(managedConnection['username'], 'ubuntu');
    expect(managedConnection['private_key'], 'PRIVATE KEY');
    expect(managedConnection.containsKey('key_path'), isFalse);
    expect(settings, <String, dynamic>{
      // admin_user is server-owned (T-1.4.8); not part of the built payload.
      'hostname': 'server.example.com',
      'timezone': 'UTC',
      'ssh_public_key': 'ssh-ed25519 AAAATEST deploydash-managed',
      'disable_password_auth': true,
      'disable_root_login': true,
      'ssh_banner_text': 'Authorized uses only.',
    });
    expect(savedDraft.port, 2022);
    expect(savedDraft.privateKey, 'PRIVATE KEY');
  });

  test('managed password extraction reads the setup result password', () {
    expect(managedUserPasswordFromSetupResult(null), isNull);
    expect(
      managedUserPasswordFromSetupResult(const <String, dynamic>{
        'status': 'success',
      }),
      isNull,
    );
    expect(
      managedUserPasswordFromSetupResult(const <String, dynamic>{
        'managed_user_password': '   ',
      }),
      isNull,
    );
    expect(
      managedUserPasswordFromSetupResult(const <String, dynamic>{
        'managed_user_password': 123,
      }),
      isNull,
    );
    expect(
      managedUserPasswordFromSetupResult(const <String, dynamic>{
        'managed_user_password': '  secret-value  ',
      }),
      'secret-value',
    );
  });

  test('saved managed draft carries the managed user password', () {
    const managedDraft = ServerDraft(
      name: 'server.example.com',
      host: '203.0.113.10',
      port: 22,
      sshUser: 'ubuntu',
      authMethod: ServerAuthMethod.sshKey,
      privateKey: 'PRIVATE KEY',
      publicKey: 'ssh-ed25519 AAAATEST deploydash-managed',
    );

    final withoutPassword = buildSavedManagedDraft(
      managedDraft: managedDraft,
      managedConnectionResult: null,
    );
    expect(withoutPassword.managedUserPassword, isNull);

    final withPassword = buildSavedManagedDraft(
      managedDraft: managedDraft,
      managedConnectionResult: const <String, dynamic>{
        'username': 'ubuntu',
        'port': 22,
      },
      managedUserPassword: 'managed-secret',
    );
    expect(withPassword.managedUserPassword, 'managed-secret');
    expect(withPassword.privateKey, 'PRIVATE KEY');
  });

  test(
    'buildManagedDraft drops bootstrap password, key path, and password',
    () {
      // T-025 characterization: the auth-method switch drops all three
      // bootstrap secrets (the rewrite must null them explicitly — a
      // sentinel default would preserve them across the switch).
      const bootstrapDraft = ServerDraft(
        name: 'server.example.com',
        host: '203.0.113.10',
        port: 22,
        sshUser: 'root',
        authMethod: ServerAuthMethod.password,
        sshPassword: 'secret',
        keyPath: '/tmp/id_ed25519',
        managedUserPassword: 'stale-managed',
      );
      const keyPair = ManagedSshKeyPair(
        privateKey: 'PRIVATE KEY',
        publicKey: 'ssh-ed25519 AAAATEST deploydash-managed',
      );

      final managedDraft = buildManagedDraft(
        bootstrapDraft: bootstrapDraft,
        managedKeyPair: keyPair,
      );

      expect(managedDraft.sshPassword, isNull);
      expect(managedDraft.keyPath, isNull);
      expect(managedDraft.managedUserPassword, isNull);
      expect(managedDraft.name, 'server.example.com');
      expect(managedDraft.host, '203.0.113.10');
      expect(managedDraft.port, 22);
      expect(managedDraft.privateKey, 'PRIVATE KEY');
      expect(managedDraft.publicKey, 'ssh-ed25519 AAAATEST deploydash-managed');
    },
  );

  test('buildSavedManagedDraft keeps draft values on null result', () {
    // T-025 characterization: a null result keeps the draft's port/user
    // (fallback chain) and never carries the draft's managed password
    // (only the builder's own parameter sets it).
    const managedDraft = ServerDraft(
      name: 'server.example.com',
      host: '203.0.113.10',
      port: 2222,
      sshUser: 'deploy',
      authMethod: ServerAuthMethod.sshKey,
      privateKey: 'PRIVATE KEY',
      publicKey: 'ssh-ed25519 AAAATEST deploydash-managed',
      managedUserPassword: 'stale-managed',
    );

    final savedDraft = buildSavedManagedDraft(
      managedDraft: managedDraft,
      managedConnectionResult: null,
    );

    expect(savedDraft.port, 2222);
    expect(savedDraft.sshUser, 'deploy');
    expect(savedDraft.privateKey, 'PRIVATE KEY');
    expect(savedDraft.publicKey, 'ssh-ed25519 AAAATEST deploydash-managed');
    expect(savedDraft.managedUserPassword, isNull);
  });

  test('managed draft builders delegate to copyWith (shape pin)', () {
    final securitySource = File(
      'lib/ui/server/server_onboarding_security.dart',
    ).readAsStringSync();
    expect(securitySource.contains('.copyWith('), isTrue);
  });

  test('retry bootstrap draft carries the resolved password', () {
    const server = Server(
      id: 'server-1',
      name: 'Pending',
      host: '203.0.113.10',
      port: 22,
      sshUser: 'root',
      authMethod: ServerAuthMethod.password,
    );

    final draft = buildRetryBootstrapDraft(
      server: server,
      connectionPayload: const <String, dynamic>{
        'host': '203.0.113.10',
        'port': 22,
        'username': 'root',
        'password': 'bootstrap-secret',
      },
    );

    expect(draft.name, 'Pending');
    expect(draft.host, '203.0.113.10');
    expect(draft.sshUser, 'root');
    expect(draft.authMethod, ServerAuthMethod.password);
    expect(draft.sshPassword, 'bootstrap-secret');
    expect(draft.privateKey, isNull);
  });

  test('retry bootstrap draft carries the resolved key', () {
    const server = Server(
      id: 'server-1',
      name: 'Pending',
      host: '203.0.113.10',
      port: 2222,
      sshUser: 'admin',
      authMethod: ServerAuthMethod.sshKey,
    );

    final draft = buildRetryBootstrapDraft(
      server: server,
      connectionPayload: const <String, dynamic>{
        'host': '203.0.113.10',
        'port': 2222,
        'username': 'admin',
        'private_key': 'bootstrap-key',
      },
    );

    expect(draft.port, 2222);
    expect(draft.authMethod, ServerAuthMethod.sshKey);
    expect(draft.privateKey, 'bootstrap-key');
    expect(draft.sshPassword, isNull);
  });
}
