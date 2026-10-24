import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/e2e_checklist.dart';

/// Contract guard: a server domain value is non-secret metadata only.
///
/// The separate credential repository is the only persistence boundary that
/// may materialize SSH authentication values. This source-level check fails
/// before a future convenience field can reintroduce those values to every
/// loaded server, state snapshot, or accidental serialization.
void main() {
  final root = findRepositoryRoot();
  final desktopRoot = '${root.path}/ui';
  final serverSource = File('$desktopRoot/lib/domain/server.dart');
  final databaseSource = File('$desktopRoot/lib/data/local/app_database.dart');
  final credentialRepository = File(
    '$desktopRoot/lib/data/local/server_credential_repository.dart',
  );

  test('server values use a non-secret credential reference', () {
    final source = serverSource.readAsStringSync();

    expect(
      source.contains('class ServerCredentialReference'),
      isTrue,
      reason: 'ServerCredentialReference must name the non-secret boundary.',
    );
    expect(
      source.contains('ServerCredentialReference get credentialReference'),
      isTrue,
      reason:
          'Server must expose a credential reference, not credential values.',
    );
    expect(
      source,
      isNot(
        contains(
          RegExp(
            r'final String\? (?:sshPassword|keyPath|privateKey|publicKey|managedUserPassword);',
          ),
        ),
      ),
      reason: 'Server must not carry SSH secrets or workstation key paths.',
    );
    expect(
      source,
      isNot(
        contains(
          RegExp(
            r'String\? (?:sshPassword|keyPath|privateKey|publicKey|managedUserPassword),',
          ),
        ),
      ),
      reason:
          'Server constructors must not retain compatibility parameters that '
          'could reintroduce secret material to a serialized domain value.',
    );
  });

  test('credentials have one separate persistence owner', () {
    final source = databaseSource.readAsStringSync();
    final serversStart = source.indexOf('class Servers extends Table');
    final credentialsStart = source.indexOf(
      'class ServerCredentials extends Table',
    );
    expect(serversStart, greaterThanOrEqualTo(0));
    expect(credentialsStart, greaterThan(serversStart));
    final serversTable = source.substring(serversStart, credentialsStart);

    expect(
      source.contains('class ServerCredentials extends Table'),
      isTrue,
      reason: 'The dedicated server_credentials table must exist.',
    );
    expect(
      serversTable.contains(
        RegExp(
          r'(?:TextColumn get )?(?:sshPassword|keyPath|privateKey|publicKey|managedUserPassword|managed_user_password)',
        ),
      ),
      isFalse,
      reason:
          'The servers table must not retain credential columns after the '
          'schema migration.',
    );
    expect(
      credentialRepository.existsSync(),
      isTrue,
      reason:
          'ServerCredentialRepository is the sole typed credential accessor.',
    );
  });
}
