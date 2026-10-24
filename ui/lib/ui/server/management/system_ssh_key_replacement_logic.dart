import 'package:file_selector/file_selector.dart';

import 'system_ssh_key_import.dart';

typedef ServerSshKeyFilePicker = Future<XFile?> Function();
typedef ServerSshKeyFileImporter =
    Future<ImportedSshKeyFile> Function(String filePath);
typedef ServerSshKeySaver =
    Future<void> Function({required String privateKey, String? publicKey});

class SshKeyReplacementResult {
  const SshKeyReplacementResult._({
    required this.cancelled,
    this.importedKey,
    this.error,
  });

  const SshKeyReplacementResult.cancelled()
    : this._(cancelled: true, importedKey: null, error: null);

  const SshKeyReplacementResult.success(ImportedSshKeyFile importedKey)
    : this._(cancelled: false, importedKey: importedKey, error: null);

  const SshKeyReplacementResult.failure(Object error)
    : this._(cancelled: false, importedKey: null, error: error);

  final bool cancelled;
  final ImportedSshKeyFile? importedKey;
  final Object? error;
}

Future<SshKeyReplacementResult> replaceStoredSshKeyWithDependencies({
  required ServerSshKeyFilePicker pickFile,
  required ServerSshKeyFileImporter importFile,
  required ServerSshKeySaver saveImportedKey,
}) async {
  final file = await pickFile();
  if (file == null) {
    return const SshKeyReplacementResult.cancelled();
  }

  try {
    final importedKey = await importFile(file.path);
    await saveImportedKey(
      privateKey: importedKey.privateKey,
      publicKey: importedKey.publicKey,
    );
    return SshKeyReplacementResult.success(importedKey);
  } catch (error) {
    return SshKeyReplacementResult.failure(error);
  }
}
