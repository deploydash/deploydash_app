import 'dart:io';

import 'package:ui/ui/server/management/system_ssh_key_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads a private key and sibling public key', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'deploydash-ssh-import-',
    );
    addTearDown(() async {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final privateKeyFile = File('${tempDirectory.path}/id_ed25519');
    await privateKeyFile.writeAsString('PRIVATE KEY\n');
    await File('${privateKeyFile.path}.pub').writeAsString('ssh-ed25519 AAA\n');

    final imported = await readImportedSshKeyFile(privateKeyFile.path);

    expect(imported.fileName, 'id_ed25519');
    expect(imported.privateKey, 'PRIVATE KEY\n');
    expect(imported.publicKey, 'ssh-ed25519 AAA');
  });

  test('reads a private key without a sibling public key', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'deploydash-ssh-import-',
    );
    addTearDown(() async {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final privateKeyFile = File('${tempDirectory.path}/id_ed25519');
    await privateKeyFile.writeAsString('PRIVATE KEY\n');

    final imported = await readImportedSshKeyFile(privateKeyFile.path);

    expect(imported.fileName, 'id_ed25519');
    expect(imported.privateKey, 'PRIVATE KEY\n');
    expect(imported.publicKey, isNull);
  });

  test('rejects an empty private key file', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'deploydash-ssh-import-',
    );
    addTearDown(() async {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final privateKeyFile = File('${tempDirectory.path}/id_ed25519');
    await privateKeyFile.writeAsString('   \n');

    await expectLater(
      () => readImportedSshKeyFile(privateKeyFile.path),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'The selected private key file is empty.',
        ),
      ),
    );
  });
}
