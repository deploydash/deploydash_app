import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;

import '../data/local/app_data_directory.dart';
import '../data/local/device_installation_repository.dart';
import '../models/device_identity.dart';

export '../models/device_identity.dart';

/// The schema version written into, and required back out of, the identity
/// file.
///
/// A file carrying any other version is treated as unreadable rather than
/// migrated -- see [DeviceIdentityService.loadOrCreate] for why that is the
/// safe direction here.
const int deviceIdentityFileSchemaVersion = 1;

/// The identity file's name inside the application support directory.
const String deviceIdentityFileName = 'device_identity.json';

/// Resolves the directory holding the identity file. Injectable so tests do
/// not write to the real application support directory.
typedef DeviceIdentityDirectoryResolver = Future<Directory> Function();

/// Produces a new device id. Injectable to make a created identity
/// predictable.
typedef DeviceIdentityIdGenerator = String Function();

/// Reads the current time. Injectable for the created-at stamp and the
/// invalid-file suffix.
typedef DeviceIdentityClock = DateTime Function();

/// Names the current operating system, which decides whether POSIX
/// permissions are applied.
typedef DeviceIdentityPlatformResolver = String Function();

/// Runs between writing the temporary file and renaming it into place.
///
/// The seam exists solely to test the concurrent-creation path: a hook that
/// writes an identity file at that moment reproduces two app instances racing
/// to create one, which is otherwise not reachable from a single test isolate.
typedef DeviceIdentityBeforePublish =
    Future<void> Function(File temporaryFile, File identityFile);

/// Reads, or creates once, this installation's permanent identity.
///
/// The id identifies the *installation*, never the person -- see
/// `docs/contracts/identity.md`. It lives in a plain JSON file beside the
/// encrypted database rather than inside it, because it must be readable
/// before the user has unlocked anything.
class DeviceIdentityService {
  /// Creates the service. Every parameter is a test seam with a real default.
  DeviceIdentityService({
    DeviceIdentityDirectoryResolver? resolveDirectory,
    DeviceIdentityIdGenerator? generateId,
    DeviceIdentityClock? clock,
    DeviceIdentityPlatformResolver? platformResolver,
    DeviceIdentityBeforePublish? beforePublish,
  }) : _resolveDirectory = resolveDirectory ?? resolveAppDataDirectory,
       _generateId = generateId ?? _generateUuidV4,
       _clock = clock ?? DateTime.now,
       _platformResolver = platformResolver ?? (() => Platform.operatingSystem),
       _beforePublish = beforePublish;

  final DeviceIdentityDirectoryResolver _resolveDirectory;
  final DeviceIdentityIdGenerator _generateId;
  final DeviceIdentityClock _clock;
  final DeviceIdentityPlatformResolver _platformResolver;
  final DeviceIdentityBeforePublish? _beforePublish;

  /// Returns this installation's identity, creating it on first run.
  ///
  /// Creation is atomic: the identity is written to a temporary file, given
  /// owner-only permissions, and renamed into place, so a crash mid-write
  /// cannot leave a half-written identity that later reads as a *different*
  /// installation. The file is re-checked immediately before the rename, so
  /// two instances starting together converge on whichever won rather than
  /// overwriting each other.
  ///
  /// A file that cannot be read -- wrong schema version, malformed JSON, an id
  /// that is not a v4 UUID -- is renamed aside with an `.invalid-<timestamp>`
  /// suffix and a fresh identity is created. It is kept rather than deleted
  /// because it is the only evidence of what the previous identity was, and
  /// this app has no way to recover one it cannot parse.
  ///
  /// On POSIX platforms the directory becomes `0700` and the file `0600`;
  /// Windows is skipped, where the application support directory is already
  /// per-user. A [FileSystemException] propagates: an identity that cannot be
  /// persisted must not be returned as though it will still be there next
  /// launch.
  Future<DeviceIdentity> loadOrCreate() async {
    final directory = await _resolveDirectory();
    await directory.create(recursive: true);
    await _applyRestrictedPermissions(directory.path, isDirectory: true);

    final identityFile = File(p.join(directory.path, deviceIdentityFileName));
    if (await identityFile.exists()) {
      final identity = await _read(identityFile);
      if (identity != null) {
        await _applyRestrictedPermissions(identityFile.path);
        return identity;
      }
      await _preserveInvalidFile(identityFile);
    }

    final identity = DeviceIdentity(
      id: _generateId(),
      createdAt: _clock().toUtc(),
    );
    final temporaryFile = File('${identityFile.path}.${identity.id}.tmp');
    await temporaryFile.writeAsString(
      jsonEncode(<String, Object>{
        'schema_version': deviceIdentityFileSchemaVersion,
        'device_id': identity.id,
        'created_at': identity.createdAt.toIso8601String(),
      }),
      flush: true,
    );
    await _applyRestrictedPermissions(temporaryFile.path);
    await _beforePublish?.call(temporaryFile, identityFile);

    if (await identityFile.exists()) {
      final concurrentIdentity = await _read(identityFile);
      if (concurrentIdentity != null) {
        await temporaryFile.delete();
        return concurrentIdentity;
      }
      await _preserveInvalidFile(identityFile);
    }

    await temporaryFile.rename(identityFile.path);
    await _applyRestrictedPermissions(identityFile.path);
    return identity;
  }

  Future<DeviceIdentity?> _read(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schema_version'] != deviceIdentityFileSchemaVersion) {
        return null;
      }
      final id = decoded['device_id']?.toString().trim() ?? '';
      final createdAt = DateTime.tryParse(
        decoded['created_at']?.toString() ?? '',
      );
      if (!_isUuidV4(id) || createdAt == null) {
        return null;
      }
      return DeviceIdentity(id: id, createdAt: createdAt.toUtc());
    } on FormatException {
      return null;
    } on FileSystemException {
      rethrow;
    }
  }

  Future<void> _preserveInvalidFile(File file) async {
    final timestamp = _clock().toUtc().microsecondsSinceEpoch;
    await file.rename('${file.path}.invalid-$timestamp');
  }

  Future<void> _applyRestrictedPermissions(
    String path, {
    bool isDirectory = false,
  }) async {
    if (_platformResolver() == 'windows') {
      return;
    }
    posix.chmodWithMode(path, isDirectory ? 0x1C0 : 0x180);
  }
}

bool _isUuidV4(String value) {
  return RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(value.toLowerCase());
}

String _generateUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0'));
  final compact = hex.join();
  return '${compact.substring(0, 8)}-'
      '${compact.substring(8, 12)}-'
      '${compact.substring(12, 16)}-'
      '${compact.substring(16, 20)}-'
      '${compact.substring(20)}';
}

/// The app-wide identity service.
final deviceIdentityServiceProvider = Provider<DeviceIdentityService>((ref) {
  return DeviceIdentityService();
});

/// This installation's identity, read or created once per app run.
final deviceIdentityProvider = FutureProvider<DeviceIdentity>((ref) {
  return ref.watch(deviceIdentityServiceProvider).loadOrCreate();
});

/// This installation's row in the local database, created or refreshed on
/// first read.
///
/// Adds the descriptive facts the identity file deliberately does not hold --
/// hostname, platform, architecture -- so they can change without the identity
/// changing. A user renaming their machine is the same installation.
final currentDeviceInstallationProvider =
    FutureProvider<DeviceInstallationRecord>((ref) async {
      final identity = await ref.watch(deviceIdentityProvider.future);
      final repository = ref.watch(deviceInstallationRepositoryProvider);
      return repository.ensureCurrentDevice(
        identity: identity,
        displayName: Platform.localHostname,
        platform: Platform.operatingSystem,
        architecture: Abi.current().toString(),
      );
    });
