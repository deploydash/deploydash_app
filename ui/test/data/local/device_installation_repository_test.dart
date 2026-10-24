import 'dart:io';

import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/device_installation_repository.dart';
import 'package:ui/services/device_identity_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';
import '../../../integration_test/support/e2e_checklist.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('DeviceInstallationRepository', () {
    late AppDatabase database;
    late DeviceInstallationRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = DeviceInstallationRepository(database);
    });

    tearDown(() => database.close());

    test(
      'creates and refreshes the current installation and update state',
      () async {
        final createdAt = DateTime.utc(2026, 1, 1);
        final firstSeen = DateTime.utc(2026, 8, 11, 10);
        final secondSeen = DateTime.utc(2026, 8, 11, 11);
        final identity = DeviceIdentity(
          id: '00000000-0000-4000-8000-000000000001',
          createdAt: _createdAt,
        );

        final first = await repository.ensureCurrentDevice(
          identity: DeviceIdentity(id: identity.id, createdAt: createdAt),
          displayName: ' Workstation ',
          platform: 'darwin',
          architecture: 'Abi.macosArm64',
          seenAt: firstSeen,
        );
        final second = await repository.ensureCurrentDevice(
          identity: DeviceIdentity(id: identity.id, createdAt: createdAt),
          displayName: ' ',
          platform: 'macos',
          architecture: 'aarch64',
          seenAt: secondSeen,
        );

        expect(first.displayName, 'Workstation');
        expect(first.platform, 'macos');
        expect(first.architecture, 'arm64');
        expect(second.displayName, 'This device');
        expect(second.lastSeenAt, secondSeen);
        expect(
          (await repository.readInstallation(identity.id))?.createdAt,
          createdAt,
        );
        final updateState = await repository.readUpdateState(identity.id);
        expect(updateState?.releaseChannel, 'stable');
        expect(updateState?.lastCheckedAt, isNull);
      },
      skip: !sqliteAvailable,
    );

    test('reads empty identifiers as absent', () async {
      expect(await repository.readInstallation(' '), isNull);
      expect(await repository.readUpdateState(''), isNull);
      expect(await repository.readInstallation('missing'), isNull);
      expect(await repository.readUpdateState('missing'), isNull);
    }, skip: !sqliteAvailable);

    test('records checks, cached envelopes, etags, and dismissals', () async {
      final identity = DeviceIdentity(
        id: '00000000-0000-4000-8000-000000000002',
        createdAt: _createdAt,
      );
      await repository.ensureCurrentDevice(
        identity: identity,
        displayName: 'Laptop',
        platform: 'windows',
        architecture: 'x86_64',
      );
      final checkedAt = DateTime.utc(2026, 8, 11, 12);
      await repository.recordUpdateCheck(
        deviceId: identity.id,
        status: ' updateAvailable ',
        releaseId: ' release-1 ',
        signedEnvelope: ' signed ',
        etag: ' "etag" ',
        checkedAt: checkedAt,
      );
      await repository.dismissRelease(
        deviceId: identity.id,
        releaseId: ' release-1 ',
        updatedAt: checkedAt.add(const Duration(minutes: 1)),
      );

      final state = await repository.readUpdateState(identity.id);
      expect(state?.lastCheckStatus, 'updateAvailable');
      expect(state?.lastKnownReleaseId, 'release-1');
      expect(state?.cachedSignedEnvelope, 'signed');
      expect(state?.cachedEtag, '"etag"');
      expect(state?.dismissedReleaseId, 'release-1');
      expect(state?.lastCheckedAt, checkedAt);

      await repository.recordUpdateCheck(
        deviceId: identity.id,
        status: ' ',
        releaseId: ' ',
        signedEnvelope: null,
        etag: null,
        checkedAt: checkedAt,
      );
      await repository.dismissRelease(
        deviceId: identity.id,
        updatedAt: checkedAt,
      );
      final cleared = await repository.readUpdateState(identity.id);
      expect(cleared?.lastCheckStatus, isNull);
      expect(cleared?.lastKnownReleaseId, isNull);
      expect(cleared?.cachedSignedEnvelope, isNull);
      expect(cleared?.cachedEtag, isNull);
      expect(cleared?.dismissedReleaseId, isNull);
    }, skip: !sqliteAvailable);

    test('rejects blank device ids for update writes', () async {
      await expectLater(
        repository.recordUpdateCheck(deviceId: ' ', status: 'current'),
        throwsArgumentError,
      );
      await expectLater(
        repository.dismissRelease(deviceId: ''),
        throwsArgumentError,
      );
    }, skip: !sqliteAvailable);

    test(
      'normalizes supported and unknown platform and architecture values',
      () {
        expect(normalizeDevicePlatform('LINUX'), 'linux');
        expect(normalizeDevicePlatform('Windows'), 'windows');
        expect(normalizeDevicePlatform('freebsd'), 'unknown');
        expect(normalizeDeviceArchitecture('arm64-v8'), 'arm64');
        expect(normalizeDeviceArchitecture('AMD64'), 'x64');
        expect(normalizeDeviceArchitecture('riscv64'), 'unknown');
      },
    );

    test('providers expose repository and current installation', () async {
      final identity = DeviceIdentity(
        id: '00000000-0000-4000-8000-000000000003',
        createdAt: _createdAt,
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          deviceIdentityProvider.overrideWith((ref) async => identity),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(deviceInstallationRepositoryProvider),
        isA<DeviceInstallationRepository>(),
      );
      final installation = await container.read(
        currentDeviceInstallationProvider.future,
      );
      expect(installation.id, identity.id);
      expect(installation.platform, isNot('unknown'));
      expect(installation.architecture, anyOf('x64', 'arm64'));
    }, skip: !sqliteAvailable);
  });

  group('DeviceInstallationRepository writer contracts (D-19)', () {
    late AppDatabase database;
    late DeviceInstallationRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = DeviceInstallationRepository(database);
    });

    tearDown(() => database.close());

    Future<void> ensureDevice(String id) {
      return repository.ensureCurrentDevice(
        identity: DeviceIdentity(id: id, createdAt: _createdAt),
        displayName: 'Device',
        platform: 'linux',
        architecture: 'x86_64',
      );
    }

    test('writers name the blank device id identically', () async {
      for (final write in [
        () => repository.recordUpdateCheck(deviceId: '  ', status: 'current'),
        () => repository.dismissRelease(deviceId: ''),
      ]) {
        await expectLater(
          write(),
          throwsA(
            isA<ArgumentError>()
                .having((error) => error.name, 'name', 'deviceId')
                .having(
                  (error) => error.message,
                  'message',
                  'Must not be empty.',
                ),
          ),
        );
      }
    }, skip: !sqliteAvailable);

    test('recording a check preserves an existing dismissal', () async {
      const id = '00000000-0000-4000-8000-000000000004';
      await ensureDevice(id);
      final checkedAt = DateTime.utc(2026, 8, 11, 12);
      await repository.dismissRelease(
        deviceId: id,
        releaseId: 'release-9',
        updatedAt: checkedAt,
      );
      await repository.recordUpdateCheck(
        deviceId: id,
        status: 'updateAvailable',
        releaseId: 'release-9',
        signedEnvelope: 'signed',
        etag: '"etag"',
        checkedAt: checkedAt.add(const Duration(minutes: 1)),
      );

      final state = await repository.readUpdateState(id);
      expect(state?.dismissedReleaseId, 'release-9');
      expect(state?.lastCheckStatus, 'updateAvailable');
      expect(state?.cachedSignedEnvelope, 'signed');
      expect(state?.cachedEtag, '"etag"');
      expect(state?.lastCheckedAt, checkedAt.add(const Duration(minutes: 1)));
    }, skip: !sqliteAvailable);
  });

  group('DeviceInstallationRepository collapsed owners (D-19)', () {
    test('readers and writers delegate to single owners', () {
      // Guard-style: one reader definition + two delegate call sites, one
      // writer definition + two delegate call sites.
      final root = findRepositoryRoot();
      final source = File(
        '${root.path}/ui/lib/data/local/device_installation_repository.dart',
      ).readAsStringSync();
      expect('_readDeviceRow'.allMatches(source).length, 3);
      expect('_writeUpdateState'.allMatches(source).length, 3);
    });
  });
}

final _createdAt = DateTime.utc(2026, 1, 1);
