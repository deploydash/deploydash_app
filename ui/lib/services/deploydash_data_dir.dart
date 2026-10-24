import 'dart:io';

import '../data/local/app_data_directory.dart';
import '../native_bridge.dart';

/// Resolves the shared app-data root and publishes it for the embedded Python
/// runtime as `DEPLOYDASH_DATA_DIR` before any engine/SSH work starts.
Future<Directory> publishDeployDashDataDir({NativeBridge? bridge}) async {
  final directory = await resolveAppDataDirectory();
  (bridge ?? NativeBridge()).setDeployDashDataDir(directory.path);
  return directory;
}
