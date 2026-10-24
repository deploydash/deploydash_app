import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/server_credential_repository.dart';
import 'package:ui/data/local/server_repository.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ServerCredentialRepository', () {
    late AppDatabase database;
    late ServerCredentialRepository credentials;
    late ServerRepository servers;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      credentials = ServerCredentialRepository(database);
      servers = ServerRepository(database, credentials);
    });

    tearDown(() => database.close());

    test('stores SSH material outside the returned Server value', () async {
      final server = await servers.createServer(
        draft: const ServerDraft(
          name: 'Production',
          host: '198.51.100.18',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.sshKey,
          privateKey: '  PRIVATE KEY  ',
          publicKey: ' ssh-ed25519 public ',
        ),
        specs: const ServerSpecs(),
      );

      expect(server.credentialReference.serverId, server.id);
      final stored = await credentials.read(server.credentialReference);
      expect(stored?.privateKey, 'PRIVATE KEY');
      expect(stored?.publicKey, 'ssh-ed25519 public');
      expect(await credentials.connectionPayload(server), {
        'host': '198.51.100.18',
        'port': 22,
        'username': 'ubuntu',
        'private_key': 'PRIVATE KEY',
      });
    });

    test('write and read round-trip the managed user password', () async {
      final server = await servers.createServer(
        draft: const ServerDraft(
          name: 'Production',
          host: '198.51.100.24',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.sshKey,
          privateKey: 'PRIVATE KEY',
        ),
        specs: const ServerSpecs(),
      );

      await credentials.write(
        reference: server.credentialReference,
        privateKey: 'PRIVATE KEY',
        publicKey: 'ssh-ed25519 public',
        managedUserPassword: '  managed-secret  ',
      );

      final stored = await credentials.read(server.credentialReference);
      expect(stored?.managedUserPassword, 'managed-secret');
      expect(stored?.privateKey, 'PRIVATE KEY');
    });

    test('a blank managed user password clears the stored value', () async {
      final server = await servers.createServer(
        draft: const ServerDraft(
          name: 'Production',
          host: '198.51.100.25',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.sshKey,
          privateKey: 'PRIVATE KEY',
        ),
        specs: const ServerSpecs(),
      );

      await credentials.write(
        reference: server.credentialReference,
        privateKey: 'PRIVATE KEY',
        managedUserPassword: 'managed-secret',
      );
      expect(
        (await credentials.read(
          server.credentialReference,
        ))?.managedUserPassword,
        'managed-secret',
      );

      await credentials.write(
        reference: server.credentialReference,
        privateKey: 'PRIVATE KEY',
        managedUserPassword: '   ',
      );
      expect(
        (await credentials.read(
          server.credentialReference,
        ))?.managedUserPassword,
        isNull,
      );
    });

    test(
      'connection payload never carries the managed user password',
      () async {
        final server = await servers.createServer(
          draft: const ServerDraft(
            name: 'Production',
            host: '198.51.100.26',
            port: 22,
            sshUser: 'ubuntu',
            authMethod: ServerAuthMethod.sshKey,
            privateKey: 'PRIVATE KEY',
          ),
          specs: const ServerSpecs(),
        );
        await credentials.write(
          reference: server.credentialReference,
          privateKey: 'PRIVATE KEY',
          managedUserPassword: 'managed-secret',
        );

        // The managed unix password is a stored recovery record, not SSH
        // authentication: the managed connection authenticates by key.
        final payload = await credentials.connectionPayload(server);
        expect(payload, isNotNull);
        expect(payload!.containsKey('password'), isFalse);
        expect(payload.values, isNot(contains('managed-secret')));
      },
    );

    test('deleting a server deletes its credential row', () async {
      final server = await servers.createServer(
        draft: const ServerDraft(
          name: 'Staging',
          host: '198.51.100.19',
          port: 22,
          sshUser: 'root',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'password',
        ),
        specs: const ServerSpecs(),
      );

      await servers.deleteServer(server.id);

      expect(await credentials.read(server.credentialReference), isNull);
    });

    test('rejects mismatched, absent, and incomplete credentials', () async {
      final passwordServer = await servers.createServer(
        draft: const ServerDraft(
          name: 'Password server',
          host: '198.51.100.21',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.password,
          sshPassword: 'password',
        ),
        specs: const ServerSpecs(),
      );
      final keyServer = await servers.createServer(
        draft: const ServerDraft(
          name: 'Key server',
          host: '198.51.100.22',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.sshKey,
        ),
        specs: const ServerSpecs(),
      );
      final passwordCredential = await credentials.read(
        passwordServer.credentialReference,
      );

      expect(passwordCredential, isNotNull);
      expect(
        () => passwordCredential!.connectionPayload(keyServer),
        throwsArgumentError,
      );
      expect(await credentials.connectionPayload(keyServer), isNull);
      expect(
        ServerCredential(
          reference: passwordServer.credentialReference,
        ).connectionPayload(passwordServer),
        isNull,
      );
    });

    test('server_credentials stores the managed user password', () async {
      final server = await servers.createServer(
        draft: const ServerDraft(
          name: 'Production',
          host: '198.51.100.23',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.sshKey,
          privateKey: 'PRIVATE KEY',
        ),
        specs: const ServerSpecs(),
      );

      // Red-first for #62: onboarding sets a random unix password on the
      // managed account and returns it for storage alongside the key, so
      // the owner keeps a recoverable record. The column does not exist
      // yet, so this fails with "no such column" until the schema gains it.
      final rows = await database
          .customSelect(
            'SELECT managed_user_password FROM server_credentials '
            'WHERE server_id = ?;',
            variables: [Variable<String>(server.id)],
          )
          .get();
      expect(rows, hasLength(1));
    });

    test('credential normalization treats blank as absent', () {
      // D-87 gap 1: normalizeServerCredentialValue keeps its domain name
      // and rationale but delegates to trimOrNull; a whitespace-only key
      // must never be stored as though it were real.
      expect(normalizeServerCredentialValue(null), isNull);
      expect(normalizeServerCredentialValue(''), isNull);
      expect(normalizeServerCredentialValue('   '), isNull);
      expect(normalizeServerCredentialValue('  key  '), 'key');
    });

    test('provider owns the database-backed credential accessor', () {
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);

      expect(
        container.read(serverCredentialRepositoryProvider),
        isA<ServerCredentialRepository>(),
      );
    });

    test('fresh schema 2 isolates credentials from server rows', () async {
      final server = await servers.createServer(
        draft: const ServerDraft(
          name: 'Production',
          host: '198.51.100.20',
          port: 22,
          sshUser: 'ubuntu',
          authMethod: ServerAuthMethod.sshKey,
          privateKey: 'PRIVATE KEY',
          publicKey: 'ssh-ed25519 public',
        ),
        specs: const ServerSpecs(),
      );

      final version = await database
          .customSelect('PRAGMA user_version;')
          .getSingle();
      expect(version.data['user_version'], 2);

      final credentialRows = await database
          .customSelect(
            'SELECT server_id, private_key, public_key FROM server_credentials;',
          )
          .get();
      expect(credentialRows, hasLength(1));
      expect(credentialRows.single.data, {
        'server_id': server.id,
        'private_key': 'PRIVATE KEY',
        'public_key': 'ssh-ed25519 public',
      });
      final serverColumns = await database
          .customSelect('PRAGMA table_info(servers);')
          .get();
      final names = serverColumns
          .map((row) => row.data['name'])
          .whereType<String>()
          .toSet();
      expect(
        names.intersection({
          'ssh_password',
          'key_path',
          'private_key',
          'public_key',
          'managed_user_password',
        }),
        isEmpty,
      );
      expect(database.schemaVersion, 2);
    });
  });
}
