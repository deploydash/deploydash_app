import 'package:cryptography/cryptography.dart';
import 'package:ui/services/managed_ssh_key_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('createKeyPair generates an ed25519 keypair', () async {
    final service = ManagedSshKeyService();

    final result = await service.createKeyPair(identifier: 'Server 01');

    expect(result.privateKey, contains('BEGIN OPENSSH PRIVATE KEY'));
    expect(result.publicKey, startsWith('ssh-ed25519 '));
    expect(result.publicKey, contains('deploydash-managed-access'));
  });

  test('createKeyPair surfaces generator failures', () async {
    final service = ManagedSshKeyService(
      keyPairGenerator: () async {
        throw StateError('boom');
      },
    );

    await expectLater(
      service.createKeyPair(identifier: 'Server 01'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('boom'),
        ),
      ),
    );
  });

  test('createKeyPair rejects non-ed25519 keypairs', () async {
    final service = ManagedSshKeyService(
      keyPairGenerator: () async {
        return SimpleKeyPairData(
          List<int>.filled(32, 1),
          publicKey: SimplePublicKey(
            List<int>.filled(32, 2),
            type: KeyPairType.x25519,
          ),
          type: KeyPairType.x25519,
        );
      },
    );

    await expectLater(
      service.createKeyPair(identifier: 'Server 01'),
      throwsA(isA<StateError>()),
    );
  });

  test('createKeyPair rejects a non-ed25519 public key', () async {
    final service = ManagedSshKeyService(
      keyPairGenerator: () async {
        return SimpleKeyPairData(
          List<int>.filled(32, 1),
          publicKey: SimplePublicKey(
            List<int>.filled(32, 2),
            type: KeyPairType.x25519,
          ),
          type: KeyPairType.ed25519,
        );
      },
    );

    await expectLater(
      service.createKeyPair(identifier: 'Server 01'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Expected an Ed25519 public key'),
        ),
      ),
    );
  });

  test('managedSshKeyServiceProvider returns the default service', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(managedSshKeyServiceProvider),
      isA<ManagedSshKeyService>(),
    );
  });
}
