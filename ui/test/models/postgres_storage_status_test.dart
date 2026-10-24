import 'package:flutter_test/flutter_test.dart';
import 'package:ui/models/postgres_storage_status.dart';

void main() {
  test('storage status reads the enriched service payload', () {
    final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
      'data_directory': '/var/lib/postgresql/data/pgdata',
      'storage_volume': 'postgres_postgres_data',
      'storage_volume_anonymous': false,
      'data_size_bytes': 12345,
      'storage_layout_current': true,
      'missing_expected_databases': <String>[],
      'storage_error': null,
      'detached_storage_volumes': <String>[],
    });

    expect(status.dataDirectory, '/var/lib/postgresql/data/pgdata');
    expect(status.storageVolume, 'postgres_postgres_data');
    expect(status.storageVolumeAnonymous, isFalse);
    expect(status.dataSizeBytes, 12345);
    expect(status.storageLayoutCurrent, isTrue);
    expect(status.missingExpectedDatabases, isEmpty);
    expect(status.storageError, isNull);
    expect(status.detachedStorageVolumes, isEmpty);
    expect(status.hasKnownShape, isTrue);
    expect(status.hasDetachedError, isFalse);
    expect(status.needsMigration, isFalse);
    expect(status.hasRemovalCandidates, isFalse);
  });

  test('storage status reports an anonymous legacy volume as migratable', () {
    final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
      'data_directory': '/var/lib/postgresql/data',
      'storage_volume': 'a' * 64,
      'storage_volume_anonymous': true,
      'data_size_bytes': 987,
      'storage_layout_current': false,
      'missing_expected_databases': <String>[],
      'storage_error': null,
      'detached_storage_volumes': <String>['b' * 64],
    });

    expect(status.storageVolumeAnonymous, isTrue);
    expect(status.needsMigration, isTrue);
    expect(status.hasRemovalCandidates, isTrue);
    expect(status.detachedStorageVolumes, ['b' * 64]);
  });

  test('storage status carries the detached-volume error with its detail', () {
    const error =
        'Detached data volume: this cluster has none of the 2 databases '
        'Deploy Dash expects; the data volume may be detached.';
    final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
      'data_directory': '/var/lib/postgresql/data/pgdata',
      'storage_volume': 'postgres_postgres_data',
      'storage_volume_anonymous': false,
      'data_size_bytes': 456,
      'storage_layout_current': true,
      'missing_expected_databases': <String>['dd_test_app', 'dd_test_jobs'],
      'storage_error': error,
      'detached_storage_volumes': <String>['c' * 64],
    });

    expect(status.hasDetachedError, isTrue);
    expect(status.storageError, error);
    expect(status.missingExpectedDatabases, ['dd_test_app', 'dd_test_jobs']);
  });

  test('storage status reads nothing from a non-map payload', () {
    for (final raw in <Object?>[null, 'nope', 42, <String>[]]) {
      final status = PostgresStorageStatus.fromServiceStatus(raw);

      expect(status.dataDirectory, isNull);
      expect(status.storageVolume, isNull);
      expect(status.storageVolumeAnonymous, isNull);
      expect(status.dataSizeBytes, isNull);
      expect(status.storageLayoutCurrent, isNull);
      expect(status.missingExpectedDatabases, isEmpty);
      expect(status.storageError, isNull);
      expect(status.detachedStorageVolumes, isEmpty);
      expect(status.retainedUpgradeVolumes, isEmpty);
      expect(status.hasKnownShape, isFalse);
      expect(status.hasDetachedError, isFalse);
      expect(status.needsMigration, isFalse);
      expect(status.hasRemovalCandidates, isFalse);
      expect(status.hasRetainedUpgradeVolumes, isFalse);
    }
  });

  test('storage status tolerates stringly and blank wire values', () {
    final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
      'data_directory': '  ',
      'storage_volume': 42,
      'storage_volume_anonymous': 'yes',
      'data_size_bytes': '12345',
      'storage_layout_current': 1,
      'missing_expected_databases': 'dd_test_app',
      'storage_error': '   ',
      'detached_storage_volumes': <Object?>['d' * 64, 7, null, '  '],
    });

    expect(status.dataDirectory, isNull);
    expect(status.storageVolume, '42');
    expect(status.storageVolumeAnonymous, isNull);
    expect(status.dataSizeBytes, 12345);
    expect(status.storageLayoutCurrent, isNull);
    expect(status.missingExpectedDatabases, isEmpty);
    expect(status.storageError, isNull);
    expect(status.detachedStorageVolumes, ['d' * 64]);
  });

  test('storage status rejects a garbage size', () {
    final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
      'data_size_bytes': 'big',
    });

    expect(status.dataSizeBytes, isNull);
    expect(status.hasKnownShape, isFalse);
  });

  test('storage status truncates a decimal size like the shared twin', () {
    final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
      'data_size_bytes': 12.0,
    });

    expect(status.dataSizeBytes, 12);
  });

  test('storage status without a size still has a known shape', () {
    final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
      'data_directory': '/var/lib/postgresql/data/pgdata',
      'storage_volume': null,
      'data_size_bytes': null,
    });

    expect(status.hasKnownShape, isTrue);
  });

  test('storage status with only a size still has a known shape', () {
    final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
      'data_directory': null,
      'storage_volume': null,
      'data_size_bytes': 8,
    });

    expect(status.hasKnownShape, isTrue);
  });

  test('storage status reads retained pre-upgrade volumes', () {
    final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
      'retained_upgrade_volumes': <Object?>[
        <String, dynamic>{
          'volume': 'postgres_postgres_data',
          'from_major': '17',
          'to_major': '18',
          'upgraded_at': '20260923T120000Z',
        },
        <String, dynamic>{
          'volume': 'postgres_postgres_data_pg17',
          'from_major': '16',
          'to_major': '17',
          'upgraded_at': '20260601T080000Z',
        },
      ],
    });

    expect(status.hasRetainedUpgradeVolumes, isTrue);
    expect(status.retainedUpgradeVolumes, hasLength(2));
    expect(status.retainedUpgradeVolumes[0].volume, 'postgres_postgres_data');
    expect(status.retainedUpgradeVolumes[0].fromMajor, '17');
    expect(status.retainedUpgradeVolumes[0].toMajor, '18');
    expect(
      status.retainedUpgradeVolumes[1].volume,
      'postgres_postgres_data_pg17',
    );
    expect(status.retainedUpgradeVolumes[1].fromMajor, '16');
    expect(status.retainedUpgradeVolumes[1].toMajor, '17');
  });

  test('storage status reads retained storage subpaths', () {
    final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
      'retained_storage_subpaths': <Object?>[
        <String, dynamic>{
          'volume': 'postgres_postgres_data',
          'subpath': '18/docker',
        },
      ],
    });

    expect(status.hasRetainedStorageSubpaths, isTrue);
    expect(status.retainedStorageSubpaths, hasLength(1));
    expect(
      status.retainedStorageSubpaths.single.volume,
      'postgres_postgres_data',
    );
    expect(status.retainedStorageSubpaths.single.subpath, '18/docker');
  });

  test('storage status drops malformed retained storage subpaths', () {
    final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
      'retained_storage_subpaths': <Object?>[
        '18/docker',
        <String, dynamic>{'subpath': '18/docker'},
        <String, dynamic>{'volume': 'postgres_postgres_data', 'subpath': '  '},
        <String, dynamic>{'volume': '  ', 'subpath': '18/docker'},
        <String, dynamic>{
          'volume': 'postgres_postgres_data',
          'subpath': '18/docker',
        },
      ],
    });

    expect(status.retainedStorageSubpaths, hasLength(1));
    expect(status.hasRetainedStorageSubpaths, isTrue);
  });

  test('storage status reads no retained subpaths from non-list values', () {
    for (final raw in <Object?>[null, 'nope', 42]) {
      final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
        'retained_storage_subpaths': raw,
      });

      expect(status.retainedStorageSubpaths, isEmpty);
      expect(status.hasRetainedStorageSubpaths, isFalse);
    }
  });

  test('storage status drops malformed retained entries', () {
    final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
      'retained_upgrade_volumes': <Object?>[
        'postgres_postgres_data',
        42,
        <String, dynamic>{'from_major': '17', 'to_major': '18'},
        <String, dynamic>{'volume': '  ', 'from_major': '17', 'to_major': '18'},
        <String, dynamic>{'volume': 'postgres_postgres_data', 'to_major': '18'},
        <String, dynamic>{
          'volume': 'postgres_postgres_data',
          'from_major': '17',
        },
        <String, dynamic>{
          'volume': 'postgres_postgres_data',
          'from_major': '17',
          'to_major': '18',
        },
      ],
    });

    expect(status.hasRetainedUpgradeVolumes, isTrue);
    expect(status.retainedUpgradeVolumes, hasLength(1));
    expect(
      status.retainedUpgradeVolumes.single.volume,
      'postgres_postgres_data',
    );
    expect(status.retainedUpgradeVolumes.single.fromMajor, '17');
    expect(status.retainedUpgradeVolumes.single.toMajor, '18');
  });

  test('storage status reads no retained volumes from a non-list value', () {
    for (final raw in <Object?>[null, 'nope', 42]) {
      final status = PostgresStorageStatus.fromServiceStatus(<String, dynamic>{
        'retained_upgrade_volumes': raw,
      });

      expect(status.retainedUpgradeVolumes, isEmpty);
      expect(status.hasRetainedUpgradeVolumes, isFalse);
    }
  });
}
