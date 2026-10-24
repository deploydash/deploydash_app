import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Shared local data root for Deploy Dash (DB, device identity, SSH known_hosts).
///
/// Prefer this over calling [getApplicationSupportDirectory] directly so Windows
/// Store builds stay on package-managed LocalState with the rest of the app.
Future<Directory> Function()? _appDataDirectoryResolverOverride;
bool Function() _appDataRunsOnWindows = () => Platform.isWindows;
String Function() _windowsStorePackageFamilyLoader = () =>
    const String.fromEnvironment('DEPLOYDASH_WINDOWS_PACKAGE_FAMILY_NAME');
String? Function() _windowsLocalAppDataLoader = () =>
    Platform.environment['LOCALAPPDATA'];

/// The directory holding the encrypted database, the device identity, and the
/// SSH `known_hosts` file, created if it does not exist.
///
/// Everything Deploy Dash persists locally lives here, so all of it moves
/// together and a user can find or back up one directory.
Future<Directory> resolveAppDataDirectory() async {
  final override = _appDataDirectoryResolverOverride;
  if (override != null) {
    return override();
  }

  final windowsStoreDirectory = resolveWindowsStoreAppSupportDirectory(
    runsOnWindows: _appDataRunsOnWindows(),
    packageFamilyName: _windowsStorePackageFamilyLoader(),
    localAppData: _windowsLocalAppDataLoader(),
  );
  final appSupportDirectory = windowsStoreDirectory == null
      ? await getApplicationSupportDirectory()
      : Directory(windowsStoreDirectory);
  await appSupportDirectory.create(recursive: true);
  return appSupportDirectory;
}

/// The Windows Store data directory, or null when this is not a Store build.
///
/// A packaged Store build must write inside its own `LocalState`, which
/// `getApplicationSupportDirectory` does not return; using the wrong one leaves
/// a user's database somewhere the package cannot reach after an update.
/// Null means "not a Store build, use the normal directory".
///
/// Throws [StateError] when this *is* a Store build and `LOCALAPPDATA` is
/// missing -- there is no safe fallback, and writing the database to the wrong
/// place would silently lose it.
String? resolveWindowsStoreAppSupportDirectory({
  required bool runsOnWindows,
  required String packageFamilyName,
  required String? localAppData,
}) {
  final normalizedPackageFamilyName = packageFamilyName.trim();
  if (!runsOnWindows || normalizedPackageFamilyName.isEmpty) {
    return null;
  }
  final normalizedLocalAppData = localAppData?.trim() ?? '';
  if (normalizedLocalAppData.isEmpty) {
    throw StateError(
      'Windows Store application data directory is unavailable.',
    );
  }
  return p.join(
    normalizedLocalAppData,
    'Packages',
    normalizedPackageFamilyName,
    'LocalState',
    'Deploy Dash',
  );
}

/// Points the app data directory somewhere else, for tests. Null restores the
/// real resolver.
void debugOverrideAppDataDirectoryResolver(
  Future<Directory> Function()? resolver,
) {
  _appDataDirectoryResolverOverride = resolver;
}

/// Overrides the Windows platform check, so the Store path can be exercised
/// from any host. Null restores the real check.
void debugOverrideAppDataDirectoryWindowsCheck(bool Function()? check) {
  _appDataRunsOnWindows = check ?? (() => Platform.isWindows);
}

/// Overrides the two environment lookups the Store path depends on. Omitted
/// arguments are restored to the real loaders.
void debugOverrideWindowsStoreAppDataEnvironment({
  String Function()? packageFamilyLoader,
  String? Function()? localAppDataLoader,
}) {
  _windowsStorePackageFamilyLoader =
      packageFamilyLoader ??
      () => const String.fromEnvironment(
        'DEPLOYDASH_WINDOWS_PACKAGE_FAMILY_NAME',
      );
  _windowsLocalAppDataLoader =
      localAppDataLoader ?? () => Platform.environment['LOCALAPPDATA'];
}

/// Restores every override in this file. Call from a test teardown; these are
/// process-wide globals, so a leaked override affects later tests.
void debugResetAppDataDirectoryTestState() {
  _appDataDirectoryResolverOverride = null;
  _appDataRunsOnWindows = () => Platform.isWindows;
  debugOverrideWindowsStoreAppDataEnvironment();
}

/// Whether the app currently considers itself to be running on Windows,
/// honouring any test override.
bool appDataDirectoryRunsOnWindows() => _appDataRunsOnWindows();
