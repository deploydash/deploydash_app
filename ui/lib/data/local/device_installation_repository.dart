import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/device_identity.dart';
import '../../utils/trim_or_null.dart';
import 'app_database.dart';

/// This installation, as the local database records it.
///
/// The identity itself lives in a plain file outside the database, because it
/// must be readable before unlock; this row adds the descriptive facts about
/// the machine, which can change without the installation changing.
class DeviceInstallationRecord {
  /// Records one installation.
  const DeviceInstallationRecord({
    required this.id,
    required this.displayName,
    required this.platform,
    required this.architecture,
    required this.createdAt,
    required this.lastSeenAt,
  });

  /// The permanent installation id, from the identity file.
  final String id;

  /// The machine's hostname, or `This device` when it has none to give.
  final String displayName;

  /// `linux`, `macos`, `windows`, or `unknown`.
  final String platform;

  /// `arm64`, `x64`, or `unknown`.
  final String architecture;

  /// When the identity was first created, in UTC.
  final DateTime createdAt;

  /// When the app last ran, in UTC.
  final DateTime lastSeenAt;
}

/// What this installation remembers about desktop update checks.
class DeviceUpdateStateRecord {
  /// Records one installation's update state.
  const DeviceUpdateStateRecord({
    required this.deviceId,
    required this.releaseChannel,
    this.lastCheckedAt,
    this.lastCheckStatus,
    this.lastKnownReleaseId,
    this.dismissedReleaseId,
    this.cachedSignedEnvelope,
    this.cachedEtag,
    required this.updatedAt,
  });

  /// Which installation this belongs to.
  final String deviceId;

  /// The channel being followed.
  final String releaseChannel;

  /// When the last check ran, in UTC.
  final DateTime? lastCheckedAt;

  /// What it concluded, by [DesktopUpdateStatus] name.
  final String? lastCheckStatus;

  /// The newest release seen, so a failed check can still say what was known.
  final String? lastKnownReleaseId;

  /// The release the user asked to stop being told about. Survives restarts,
  /// which is the point -- a dismissal that forgets itself is a nag.
  final String? dismissedReleaseId;

  /// The last signed response, kept so a `304 Not Modified` has something to
  /// re-verify. Cached, never trusted: it is checked again on every use.
  final String? cachedSignedEnvelope;

  /// The `ETag` that makes the next check conditional.
  final String? cachedEtag;

  /// When this row last changed, in UTC.
  final DateTime updatedAt;
}

/// Stores this installation's record and its update state.
class DeviceInstallationRepository {
  /// Creates the repository over the app database.
  const DeviceInstallationRepository(this._database);

  final AppDatabase _database;

  /// Records this installation and refreshes what is known about the machine.
  ///
  /// One transaction: the installation row is written, and an update-state row
  /// is created if this is the first run. The two are created together so no
  /// code path has to handle an installation without update state.
  ///
  /// Everything is normalized -- a blank hostname becomes `This device`, and an
  /// unrecognised platform or architecture becomes `unknown` rather than being
  /// stored raw. Those values are sent to the update service, which answers on
  /// what they say.
  Future<DeviceInstallationRecord> ensureCurrentDevice({
    required DeviceIdentity identity,
    required String displayName,
    required String platform,
    required String architecture,
    DateTime? seenAt,
  }) async {
    final now = (seenAt ?? DateTime.now()).toUtc();
    final normalizedDisplayName = displayName.trim().isEmpty
        ? 'This device'
        : displayName.trim();
    final normalizedPlatform = normalizeDevicePlatform(platform);
    final normalizedArchitecture = normalizeDeviceArchitecture(architecture);

    await _database.transaction(() async {
      await _database
          .into(_database.deviceInstallations)
          .insertOnConflictUpdate(
            DeviceInstallationsCompanion.insert(
              id: identity.id,
              displayName: normalizedDisplayName,
              platform: normalizedPlatform,
              architecture: normalizedArchitecture,
              createdAt: identity.createdAt.toUtc(),
              lastSeenAt: now,
            ),
          );
      final updateState =
          await (_database.select(_database.deviceUpdateStates)
                ..where((table) => table.deviceId.equals(identity.id)))
              .getSingleOrNull();
      if (updateState == null) {
        await _database
            .into(_database.deviceUpdateStates)
            .insert(
              DeviceUpdateStatesCompanion.insert(
                deviceId: identity.id,
                updatedAt: now,
              ),
            );
      }
    });

    return DeviceInstallationRecord(
      id: identity.id,
      displayName: normalizedDisplayName,
      platform: normalizedPlatform,
      architecture: normalizedArchitecture,
      createdAt: identity.createdAt.toUtc(),
      lastSeenAt: now,
    );
  }

  /// One installation's record, or null when there is none.
  Future<DeviceInstallationRecord?> readInstallation(String deviceId) {
    return _readDeviceRow(
      deviceId,
      (id) => (_database.select(
        _database.deviceInstallations,
      )..where((table) => table.id.equals(id))).getSingleOrNull(),
      (row) => DeviceInstallationRecord(
        id: row.id,
        displayName: row.displayName,
        platform: row.platform,
        architecture: row.architecture,
        createdAt: row.createdAt.toUtc(),
        lastSeenAt: row.lastSeenAt.toUtc(),
      ),
    );
  }

  /// One installation's update state, or null before its first check.
  Future<DeviceUpdateStateRecord?> readUpdateState(String deviceId) {
    return _readDeviceRow(
      deviceId,
      (id) => (_database.select(
        _database.deviceUpdateStates,
      )..where((table) => table.deviceId.equals(id))).getSingleOrNull(),
      _mapUpdateState,
    );
  }

  /// Reads one row by id, or null when there is none.
  ///
  /// Why: the two device readers share trim-guard + select-by-id + null-or-map
  /// and differ only in table and mapper; one owner keeps the empty-id contract
  /// (null, never throw) in one place. Generic over the row ([TRow]) and the
  /// record ([R]) instead of dynamic: the two tables' row types are unrelated,
  /// but the callbacks pin both ends, so inference keeps call sites clean.
  Future<R?> _readDeviceRow<R, TRow>(
    String deviceId,
    Future<TRow?> Function(String normalizedId) select,
    R Function(TRow row) map,
  ) async {
    final normalizedId = deviceId.trim();
    if (normalizedId.isEmpty) {
      return null;
    }
    final row = await select(normalizedId);
    if (row == null) {
      return null;
    }
    return map(row);
  }

  /// Records the outcome of an update check, including a failed one.
  ///
  /// Deliberately does not touch [DeviceUpdateStateRecord.dismissedReleaseId]:
  /// checking again is not a reason to start nagging about a release the user
  /// already dismissed.
  ///
  /// Throws [ArgumentError] for a blank device id -- writing update state
  /// against no installation would silently accumulate rows nothing reads.
  Future<void> recordUpdateCheck({
    required String deviceId,
    required String status,
    String? releaseId,
    String? signedEnvelope,
    String? etag,
    DateTime? checkedAt,
  }) {
    return _writeUpdateState(
      deviceId,
      checkedAt,
      (id, now) => DeviceUpdateStatesCompanion(
        deviceId: Value(id),
        lastCheckedAt: Value(now),
        lastCheckStatus: Value(trimOrNull(status)),
        lastKnownReleaseId: Value(trimOrNull(releaseId)),
        cachedSignedEnvelope: Value(trimOrNull(signedEnvelope)),
        cachedEtag: Value(trimOrNull(etag)),
        updatedAt: Value(now),
      ),
    );
  }

  /// Records that the user dismissed a release.
  ///
  /// Only touches the dismissal, leaving the cached envelope and check status
  /// intact, so dismissing does not discard what the last check learned.
  Future<void> dismissRelease({
    required String deviceId,
    String? releaseId,
    DateTime? updatedAt,
  }) {
    return _writeUpdateState(
      deviceId,
      updatedAt,
      (id, now) => DeviceUpdateStatesCompanion(
        deviceId: Value(id),
        dismissedReleaseId: Value(trimOrNull(releaseId)),
        updatedAt: Value(now),
      ),
    );
  }

  /// Writes one device-update-state row, refusing a blank device id.
  ///
  /// Why: both update-state writers share trim-throw-guard + upsert and differ
  /// only in columns; one owner keeps the throw contract and the single `now`
  /// stamp in one place. Each caller spells its own companion so the
  /// dismissed-vs-envelope column split stays visible at the call sites.
  Future<void> _writeUpdateState(
    String deviceId,
    DateTime? at,
    DeviceUpdateStatesCompanion Function(String normalizedId, DateTime now)
    build,
  ) async {
    final normalizedId = deviceId.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError.value(deviceId, 'deviceId', 'Must not be empty.');
    }
    final now = (at ?? DateTime.now()).toUtc();
    await _database
        .into(_database.deviceUpdateStates)
        .insertOnConflictUpdate(build(normalizedId, now));
  }

  DeviceUpdateStateRecord _mapUpdateState(DeviceUpdateStateRow row) {
    return DeviceUpdateStateRecord(
      deviceId: row.deviceId,
      releaseChannel: row.releaseChannel,
      lastCheckedAt: row.lastCheckedAt?.toUtc(),
      lastCheckStatus: row.lastCheckStatus,
      lastKnownReleaseId: row.lastKnownReleaseId,
      dismissedReleaseId: row.dismissedReleaseId,
      cachedSignedEnvelope: row.cachedSignedEnvelope,
      cachedEtag: row.cachedEtag,
      updatedAt: row.updatedAt.toUtc(),
    );
  }
}

/// The platform name the update service is told, from the OS's own name.
///
/// A closed set: anything unrecognised becomes `unknown` rather than being
/// passed through, so the update service is never asked about a platform this
/// build cannot install for.
String normalizeDevicePlatform(String value) {
  return switch (value.trim().toLowerCase()) {
    'linux' => 'linux',
    'macos' || 'darwin' => 'macos',
    'windows' => 'windows',
    _ => 'unknown',
  };
}

/// The architecture the update service is told, from the ABI's own name.
///
/// Matches on substrings because the ABI string varies by platform
/// (`x86_64`, `amd64`, `aarch64`). Anything unrecognised becomes `unknown`, for
/// the same reason as [normalizeDevicePlatform].
String normalizeDeviceArchitecture(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.contains('arm64') || normalized.contains('aarch64')) {
    return 'arm64';
  }
  if (normalized.contains('x64') ||
      normalized.contains('x86_64') ||
      normalized.contains('amd64')) {
    return 'x64';
  }
  return 'unknown';
}

/// The app-wide installation repository.
final deviceInstallationRepositoryProvider =
    Provider<DeviceInstallationRepository>((ref) {
      return DeviceInstallationRepository(ref.watch(appDatabaseProvider));
    });
