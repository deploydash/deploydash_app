import 'dart:io';

import 'package:path/path.dart' as path;

class ImportedSshKeyFile {
  const ImportedSshKeyFile({
    required this.fileName,
    required this.privateKey,
    this.publicKey,
  });

  final String fileName;
  final String privateKey;
  final String? publicKey;
}

Future<ImportedSshKeyFile> readImportedSshKeyFile(String filePath) async {
  final privateKey = await File(filePath).readAsString();
  final trimmedPrivateKey = privateKey.trim();
  if (trimmedPrivateKey.isEmpty) {
    throw const FormatException('The selected private key file is empty.');
  }

  String? publicKey;
  final siblingPublicKey = File('$filePath.pub');
  if (await siblingPublicKey.exists()) {
    final siblingContents = await siblingPublicKey.readAsString();
    final trimmedPublicKey = siblingContents.trim();
    if (trimmedPublicKey.isNotEmpty) {
      publicKey = trimmedPublicKey;
    }
  }

  return ImportedSshKeyFile(
    fileName: path.basename(filePath),
    privateKey: privateKey,
    publicKey: publicKey,
  );
}
