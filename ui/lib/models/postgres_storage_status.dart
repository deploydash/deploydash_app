/// Which volume holds PostgreSQL's data, and whether the cluster on it is
/// the one Deploy Dash expects.
///
/// The engine enriches `service_status` with these keys; the services tab
/// reads them here once instead of scattering string keys through widgets.
/// Every field stays nullable-or-empty on an unreadable payload, so a
/// missing enrichment shows "unknown" rather than a wrong shape.
class PostgresStorageStatus {
  /// Creates a storage status from already-interpreted fields.
  ///
  /// The defaults describe a service whose storage was never read. Prefer
  /// [PostgresStorageStatus.fromServiceStatus] for anything that arrived
  /// from the engine.
  const PostgresStorageStatus({
    this.dataDirectory,
    this.storageVolume,
    this.storageVolumeAnonymous,
    this.dataSizeBytes,
    this.storageLayoutCurrent,
    this.missingExpectedDatabases = const <String>[],
    this.storageError,
    this.detachedStorageVolumes = const <String>[],
    this.retainedUpgradeVolumes = const <PostgresRetainedVolume>[],
    this.retainedStorageSubpaths = const <PostgresRetainedStorageSubpath>[],
  });

  /// The live `SHOW data_directory`, or null when the read failed.
  final String? dataDirectory;

  /// The volume backing PGDATA: a name, a 64-hex id, or null when unknown.
  final String? storageVolume;

  /// Whether [storageVolume] is an anonymous Docker volume, when known.
  final bool? storageVolumeAnonymous;

  /// The live databases' total size in bytes, or null when unread.
  final int? dataSizeBytes;

  /// Whether PGDATA already sits in the named volume, when known.
  final bool? storageLayoutCurrent;

  /// Managed databases absent from the live cluster; empty means none.
  final List<String> missingExpectedDatabases;

  /// The detached-volume failure, set only when databases are missing.
  final String? storageError;

  /// Dangling volumes the retained-copy ledger attributes to this service.
  final List<String> detachedStorageVolumes;

  /// Pre-upgrade data copies the ledger retains for explicit removal.
  final List<PostgresRetainedVolume> retainedUpgradeVolumes;

  /// Old in-volume directories the migration ledger retains for removal.
  final List<PostgresRetainedStorageSubpath> retainedStorageSubpaths;

  /// Whether any part of the storage shape is known.
  ///
  /// The footer renders its rows only when this holds; otherwise it says
  /// the shape is unknown instead of showing blank rows.
  bool get hasKnownShape =>
      dataDirectory != null || storageVolume != null || dataSizeBytes != null;

  /// Whether the cluster lost databases Deploy Dash expects.
  bool get hasDetachedError => storageError != null;

  /// Whether the layout predates the named volume and can migrate.
  ///
  /// Null (unknown) reads as false: migration is offered only on a
  /// positively identified old layout, never on a failed read.
  bool get needsMigration => storageLayoutCurrent == false;

  /// Whether dangling volumes wait for a removal decision.
  bool get hasRemovalCandidates => detachedStorageVolumes.isNotEmpty;

  /// Whether kept pre-upgrade copies wait for a removal decision.
  bool get hasRetainedUpgradeVolumes => retainedUpgradeVolumes.isNotEmpty;

  /// Whether storage-migration directories wait for a removal decision.
  bool get hasRetainedStorageSubpaths => retainedStorageSubpaths.isNotEmpty;

  /// Reads the storage keys from an enriched service-status payload.
  ///
  /// Anything that is not a map yields an unknown status: older engines
  /// send no storage keys at all, which must read as unknown rather than
  /// as an empty cluster.
  factory PostgresStorageStatus.fromServiceStatus(Object? raw) {
    if (raw is! Map) return const PostgresStorageStatus();
    final map = raw.map((key, value) => MapEntry(key.toString(), value));
    return PostgresStorageStatus(
      dataDirectory: _textOrNull(map['data_directory']),
      storageVolume: _textOrNull(map['storage_volume']),
      storageVolumeAnonymous: _boolOrNull(map['storage_volume_anonymous']),
      dataSizeBytes: _intOrNull(map['data_size_bytes']),
      storageLayoutCurrent: _boolOrNull(map['storage_layout_current']),
      missingExpectedDatabases: _namesOrEmpty(
        map['missing_expected_databases'],
      ),
      storageError: _textOrNull(map['storage_error']),
      detachedStorageVolumes: _namesOrEmpty(map['detached_storage_volumes']),
      retainedUpgradeVolumes: _retainedVolumesOrEmpty(
        map['retained_upgrade_volumes'],
      ),
      retainedStorageSubpaths: _retainedStorageSubpathsOrEmpty(
        map['retained_storage_subpaths'],
      ),
    );
  }
}

/// One directory left inside a named volume by a storage migration.
///
/// PostgreSQL 18's image layout can leave `18/docker` beside the new PGDATA
/// directory. Both coordinates are required because deleting the enclosing
/// named volume would also delete the live database.
class PostgresRetainedStorageSubpath {
  /// Requires both coordinates so callers cannot imply whole-volume removal.
  const PostgresRetainedStorageSubpath({
    required this.volume,
    required this.subpath,
  });

  /// The named volume containing the retained directory.
  final String volume;

  /// The relative directory the engine may remove from that volume.
  final String subpath;
}

/// One pre-upgrade data copy the upgrade ledger retains.
///
/// The engine records these when a major upgrade keeps the old volume; the
/// storage section lists them for explicit removal only. All three fields
/// are required: an entry missing any of them is dropped by
/// [_retainedVolumesOrEmpty] rather than shown half-identified.
class PostgresRetainedVolume {
  /// Creates a retained copy from already-interpreted fields.
  const PostgresRetainedVolume({
    required this.volume,
    required this.fromMajor,
    required this.toMajor,
  });

  /// The kept volume's name.
  final String volume;

  /// The major version whose data the copy holds.
  final String fromMajor;

  /// The major version the upgrade moved to.
  final String toMajor;
}

/// Reads trimmed text, collapsing blank and missing to null.
///
/// Values arrive as strings; a non-string is stringified rather than
/// dropped, because a volume id rendered as `42` still identifies it.
String? _textOrNull(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

/// Reads a strict boolean, collapsing anything else to null.
///
/// Strict on purpose: the engine sends real booleans, and a stringly
/// "yes" for a layout verdict must read as unknown, not as true.
bool? _boolOrNull(Object? value) => value is bool ? value : null;

/// Reads an integer size, collapsing anything unparseable to null.
///
/// Same name and body as the agent-access twin on purpose: the int-or-null
/// family collapses under D-38, and one shared name keeps this copy part of
/// that single future collapse instead of a divergent twin.
int? _intOrNull(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value.toString().trim());
}

/// Reads a name list, keeping only the non-blank strings.
///
/// A non-list (or a missing key) reads as empty: no names claimed means
/// no names missing, which keeps a fresh service silent.
List<String> _namesOrEmpty(Object? value) {
  if (value is! List) return const <String>[];
  return <String>[
    for (final entry in value)
      if (entry is String && entry.trim().isNotEmpty) entry,
  ];
}

/// Reads the kept pre-upgrade copies, dropping anything unparseable.
///
/// A non-list (or a missing key) reads as empty: older engines send no
/// ledger enrichment at all, which must read as nothing kept rather than
/// as a broken list.
List<PostgresRetainedVolume> _retainedVolumesOrEmpty(Object? value) {
  if (value is! List) return const <PostgresRetainedVolume>[];
  final retained = <PostgresRetainedVolume>[];
  for (final entry in value) {
    final parsed = _retainedVolumeOrNull(entry);
    if (parsed != null) {
      retained.add(parsed);
    }
  }
  return retained;
}

/// Reads one kept copy, or null when any of its three fields is missing.
///
/// Strict on purpose: removal acts on the volume name, so a copy that
/// cannot be fully identified is dropped instead of offered half-named.
PostgresRetainedVolume? _retainedVolumeOrNull(Object? entry) {
  if (entry is! Map) return null;
  final volume = _textOrNull(entry['volume']);
  final fromMajor = _textOrNull(entry['from_major']);
  final toMajor = _textOrNull(entry['to_major']);
  if (volume == null || fromMajor == null || toMajor == null) return null;
  return PostgresRetainedVolume(
    volume: volume,
    fromMajor: fromMajor,
    toMajor: toMajor,
  );
}

/// Reads retained migration directories, dropping incomplete coordinates.
///
/// The removal boundary needs both a volume and a relative subpath; older
/// engines and malformed entries therefore read as no removable directory.
List<PostgresRetainedStorageSubpath> _retainedStorageSubpathsOrEmpty(
  Object? value,
) {
  if (value is! List) return const <PostgresRetainedStorageSubpath>[];
  final retained = <PostgresRetainedStorageSubpath>[];
  for (final entry in value) {
    final parsed = _retainedStorageSubpathOrNull(entry);
    if (parsed != null) {
      retained.add(parsed);
    }
  }
  return retained;
}

/// Reads one migration directory only when both deletion coordinates exist.
PostgresRetainedStorageSubpath? _retainedStorageSubpathOrNull(Object? entry) {
  if (entry is! Map) return null;
  final volume = _textOrNull(entry['volume']);
  final subpath = _textOrNull(entry['subpath']);
  if (volume == null || subpath == null) return null;
  return PostgresRetainedStorageSubpath(volume: volume, subpath: subpath);
}
