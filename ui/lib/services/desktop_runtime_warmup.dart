import '../native_bridge.dart';
import 'deploydash_data_dir.dart';

Future<void> Function()? _deployDashDataDirPublisherOverride;

/// Publishes the desktop data path for the embedded runtime.
Future<void> publishDesktopRuntimeDataDirectory() async {
  final override = _deployDashDataDirPublisherOverride;
  if (override != null) {
    await override();
    return;
  }
  await publishDeployDashDataDir();
}

/// Test-only seam for avoiding platform path publication.
void debugOverrideDesktopRuntimeDataDirectoryPublisher(
  Future<void> Function()? publisher,
) {
  _deployDashDataDirPublisherOverride = publisher;
}

/// Warms the embedded Python runtime after its data directory is published.
Future<void> warmupDesktopPythonRuntime() async {
  await publishDesktopRuntimeDataDirectory();
  NativeBridge().warmupPythonRuntime();
}
