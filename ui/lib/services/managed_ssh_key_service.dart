import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:openssh_ed25519/openssh_ed25519.dart';

/// Produces the raw Ed25519 keypair. Injectable so tests can supply a fixed
/// key instead of a random one.
typedef ManagedSshKeyPairGenerator = Future<SimpleKeyPairData> Function();

/// Produces the OpenSSH private-key `checkint`. Injectable for the same
/// reason: it is random, and a golden encoding cannot be asserted against a
/// random field.
typedef ManagedSshCheckintGenerator = int Function();

/// A Deploy Dash-managed SSH keypair, in OpenSSH text form.
///
/// The private half is stored in the encrypted local database and sent inline
/// with each engine request; the public half is installed on the server. It is
/// never written to a file on the workstation -- release packaging cannot
/// assume a persisted key path exists, and a key on disk is a key that outlives
/// the app that made it.
class ManagedSshKeyPair {
  /// Pairs the two halves of one generated key.
  const ManagedSshKeyPair({required this.privateKey, required this.publicKey});

  /// The OpenSSH-format private key, unencrypted.
  ///
  /// It has no passphrase because nothing could supply one unattended; the
  /// encrypted local database is what protects it.
  final String privateKey;

  /// The `ssh-ed25519 ...` line to append to the server's `authorized_keys`.
  final String publicKey;
}

/// Generates the Ed25519 keypair Deploy Dash adds to a managed server.
///
/// Onboarding creates one of these per server, installs the public half on the
/// managed `ubuntu` account, verifies a login with it, and only then disables
/// password and root SSH. Ed25519 is not configurable: a weaker or
/// larger-attack-surface algorithm here would be a silent downgrade of the
/// whole ownership handoff.
class ManagedSshKeyService {
  /// Creates the service. Both generators default to secure randomness and
  /// exist as parameters only so tests can make the output deterministic.
  ManagedSshKeyService({
    ManagedSshKeyPairGenerator? keyPairGenerator,
    ManagedSshCheckintGenerator? checkintGenerator,
  }) : _keyPairGenerator = keyPairGenerator ?? _defaultKeyPairGenerator,
       _checkintGenerator = checkintGenerator ?? _defaultCheckintGenerator;

  final ManagedSshKeyPairGenerator _keyPairGenerator;
  final ManagedSshCheckintGenerator _checkintGenerator;

  static Future<SimpleKeyPairData> _defaultKeyPairGenerator() async {
    final random = Random.secure();
    final seed = List<int>.generate(32, (_) => random.nextInt(256));
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    return await keyPair.extract();
  }

  static int _defaultCheckintGenerator() {
    return Random.secure().nextInt(1 << 32);
  }

  /// Generates a keypair whose public half is commented with [identifier].
  ///
  /// The comment is what a user sees in `authorized_keys` when auditing their
  /// server, so it names the server this key was made for -- slugified,
  /// because an arbitrary name could otherwise inject whitespace into that
  /// file's line format.
  ///
  /// Throws [StateError] if the generator returns anything but an Ed25519
  /// keypair. That is a programming error rather than a runtime condition, but
  /// it is checked rather than assumed: silently encoding a different key type
  /// as Ed25519 would produce a key the server rejects, in the middle of the
  /// step where password login is about to be turned off.
  Future<ManagedSshKeyPair> createKeyPair({required String identifier}) async {
    final keyPairData = await _keyPairGenerator();
    if (keyPairData.type != KeyPairType.ed25519) {
      throw StateError(
        'Unable to generate the Deploy Dash SSH key. '
        'Expected an Ed25519 keypair.',
      );
    }

    final publicKey = keyPairData.publicKey;
    if (publicKey.type != KeyPairType.ed25519) {
      throw StateError(
        'Unable to generate the Deploy Dash SSH key. '
        'Expected an Ed25519 public key.',
      );
    }

    // D-26 slug census (T-011): left unique — inline block building the
    // key comment, not a callable function; D-88 owns this site.
    final safeIdentifier = identifier
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final comment = safeIdentifier.isEmpty
        ? 'deploydash-managed-access'
        : 'deploydash-managed-access-$safeIdentifier';

    return ManagedSshKeyPair(
      privateKey: encodeEd25519Private(
        privateBytes: keyPairData.bytes,
        publicBytes: publicKey.bytes,
        nonce: _checkintGenerator(),
      ),
      publicKey: encodeEd25519Public(publicKey.bytes, comment).trim(),
    );
  }
}

/// The app-wide key service.
final managedSshKeyServiceProvider = Provider<ManagedSshKeyService>((ref) {
  return ManagedSshKeyService();
});
