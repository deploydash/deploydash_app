import 'package:ui/ui/server/management/system_ssh_key_import.dart';
import 'package:ui/ui/server/management/system_ssh_key_replacement_logic.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('returns cancelled when the picker does not choose a file', () async {
    var imported = false;

    final result = await replaceStoredSshKeyWithDependencies(
      pickFile: () async => null,
      importFile: (_) async {
        imported = true;
        return const ImportedSshKeyFile(
          fileName: 'unused',
          privateKey: 'unused',
        );
      },
      saveImportedKey: ({required privateKey, publicKey}) async {},
    );

    expect(result.cancelled, isTrue);
    expect(result.importedKey, isNull);
    expect(result.error, isNull);
    expect(imported, isFalse);
  });

  test('returns the imported key when replacement succeeds', () async {
    String? savedPrivateKey;
    String? savedPublicKey;

    final result = await replaceStoredSshKeyWithDependencies(
      pickFile: () async => XFile('/tmp/id_ed25519'),
      importFile: (filePath) async {
        expect(filePath, '/tmp/id_ed25519');
        return const ImportedSshKeyFile(
          fileName: 'id_ed25519',
          privateKey: 'PRIVATE KEY',
          publicKey: 'ssh-ed25519 AAA',
        );
      },
      saveImportedKey: ({required privateKey, publicKey}) async {
        savedPrivateKey = privateKey;
        savedPublicKey = publicKey;
      },
    );

    expect(result.cancelled, isFalse);
    expect(result.error, isNull);
    expect(result.importedKey?.fileName, 'id_ed25519');
    expect(savedPrivateKey, 'PRIVATE KEY');
    expect(savedPublicKey, 'ssh-ed25519 AAA');
  });

  test('returns a failure when import throws', () async {
    final result = await replaceStoredSshKeyWithDependencies(
      pickFile: () async => XFile('/tmp/id_ed25519'),
      importFile: (_) => Future<ImportedSshKeyFile>.error(
        const FormatException('The selected private key file is empty.'),
      ),
      saveImportedKey: ({required privateKey, publicKey}) async {},
    );

    expect(result.cancelled, isFalse);
    expect(result.importedKey, isNull);
    expect(
      result.error,
      isA<FormatException>().having(
        (error) => error.message,
        'message',
        'The selected private key file is empty.',
      ),
    );
  });

  test('returns a failure when saving the imported key throws', () async {
    final result = await replaceStoredSshKeyWithDependencies(
      pickFile: () async => XFile('/tmp/id_ed25519'),
      importFile: (_) async => const ImportedSshKeyFile(
        fileName: 'id_ed25519',
        privateKey: 'PRIVATE KEY',
      ),
      saveImportedKey: ({required privateKey, publicKey}) {
        return Future<void>.error(StateError('db write failed'));
      },
    );

    expect(result.cancelled, isFalse);
    expect(result.importedKey, isNull);
    expect(
      result.error,
      isA<StateError>().having(
        (error) => error.message,
        'message',
        'db write failed',
      ),
    );
  });
}
