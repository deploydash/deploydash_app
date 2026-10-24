import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/server.dart';
import '../../utils/trim_or_null.dart';
import 'app_database.dart';

/// Sensitive SSH authentication material for one saved server.
///
/// This type is intentionally data-layer-owned. It must not be placed in a
/// `Server` domain value, provider state, or presentation model.
class ServerCredential {
  /// Holds the credential material for one server.
  const ServerCredential({
    required this.reference,
    this.sshPassword,
    this.privateKey,
    this.publicKey,
    this.managedUserPassword,
  });

  /// Which server this material belongs to.
  final ServerCredentialReference reference;

  /// The SSH password, when the server authenticates that way.
  ///
  /// Only ever used before onboarding completes: setup replaces password login
  /// with a Deploy Dash-managed key and then disables it on the server.
  final String? sshPassword;

  /// The private key, when the server authenticates that way.
  ///
  /// Stored inline rather than as a path to a file on the workstation: a
  /// packaged release cannot assume a picked path is still readable later.
  final String? privateKey;

  /// The matching public key, kept so the app can show what it installed.
  final String? publicKey;

  /// The managed account's unix password, set during onboarding (#62).
  ///
  /// A stored recovery record, never SSH authentication: [connectionPayload]
  /// deliberately leaves it out, since the managed connection authenticates
  /// by key and sudo is passwordless via the sudoers drop-in.
  final String? managedUserPassword;

  /// Builds the only engine-facing SSH connection payload for [server].
  Map<String, dynamic>? connectionPayload(Server server) {
    if (reference.serverId != server.credentialReference.serverId) {
      throw ArgumentError.value(
        server.id,
        'server',
        'Credentials do not belong to the supplied server.',
      );
    }
    final payload = <String, dynamic>{
      'host': server.host,
      'port': server.port,
      'username': server.sshUser,
    };
    if (server.authMethod == ServerAuthMethod.password) {
      final password = normalizeServerCredentialValue(sshPassword);
      if (password == null) {
        return null;
      }
      payload['password'] = password;
      return payload;
    }
    final key = normalizeServerCredentialValue(privateKey);
    if (key == null) {
      return null;
    }
    payload['private_key'] = key;
    return payload;
  }
}

/// The sole typed read/write boundary for `server_credentials`.
class ServerCredentialRepository {
  /// Creates the repository over the app database.
  ServerCredentialRepository(this._database);

  final AppDatabase _database;

  /// The stored credential for a server, or null when none is saved.
  Future<ServerCredential?> read(ServerCredentialReference reference) async {
    final row =
        await (_database.select(_database.serverCredentials)
              ..where((table) => table.serverId.equals(reference.serverId)))
            .getSingleOrNull();
    if (row == null) {
      return null;
    }
    return ServerCredential(
      reference: ServerCredentialReference(row.serverId),
      sshPassword: row.sshPassword,
      privateKey: row.privateKey,
      publicKey: row.publicKey,
      managedUserPassword: row.managedUserPassword,
    );
  }

  /// Materializes a workflow connection only at the credential boundary.
  Future<Map<String, dynamic>?> connectionPayload(Server server) async {
    final credential = await read(server.credentialReference);
    return credential?.connectionPayload(server);
  }

  /// Stores or replaces a server's credential material.
  ///
  /// Blank values are normalized to null, so clearing a field removes it
  /// rather than storing an empty string that would later be sent as a
  /// password.
  Future<void> write({
    required ServerCredentialReference reference,
    String? sshPassword,
    String? privateKey,
    String? publicKey,
    String? managedUserPassword,
  }) {
    return _database
        .into(_database.serverCredentials)
        .insertOnConflictUpdate(
          ServerCredentialsCompanion(
            serverId: Value(reference.serverId),
            sshPassword: Value(normalizeServerCredentialValue(sshPassword)),
            privateKey: Value(normalizeServerCredentialValue(privateKey)),
            publicKey: Value(normalizeServerCredentialValue(publicKey)),
            managedUserPassword: Value(
              normalizeServerCredentialValue(managedUserPassword),
            ),
          ),
        );
  }

  /// Removes a server's credential material.
  Future<void> delete(ServerCredentialReference reference) {
    return (_database.delete(
      _database.serverCredentials,
    )..where((table) => table.serverId.equals(reference.serverId))).go();
  }
}

/// A credential value trimmed, with blank treated as absent.
///
/// The one place that decides what "no credential" means, so a whitespace-only
/// key cannot be stored as though it were real.
String? normalizeServerCredentialValue(String? value) => trimOrNull(value);

/// The app-wide credential repository.
final serverCredentialRepositoryProvider = Provider<ServerCredentialRepository>(
  (ref) => ServerCredentialRepository(ref.watch(appDatabaseProvider)),
);
