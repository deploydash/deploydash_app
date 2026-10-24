import 'dart:convert';
import 'dart:io';

import 'package:ui/services/device_identity_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceIdentityService', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'deploydash-device-identity-',
      );
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test(
      'creates a stable UUID file with restrictive POSIX permissions',
      () async {
        final createdAt = DateTime.utc(2026, 8, 11, 10, 30);
        final service = DeviceIdentityService(
          resolveDirectory: () async => directory,
          clock: () => createdAt,
          platformResolver: () => 'linux',
        );

        final first = await service.loadOrCreate();
        final second = await service.loadOrCreate();

        expect(first.id, second.id);
        expect(
          first.id,
          matches(
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
        expect(first.createdAt, createdAt);
        final file = File('${directory.path}/$deviceIdentityFileName');
        final decoded =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        expect(decoded['schema_version'], deviceIdentityFileSchemaVersion);
        expect(decoded['device_id'], first.id);
        expect((await directory.stat()).mode & 0x1FF, 0x1C0);
        expect((await file.stat()).mode & 0x1FF, 0x180);
      },
    );

    test(
      'loads a valid existing identity without generating another',
      () async {
        const id = '00000000-0000-4000-8000-000000000001';
        final createdAt = DateTime.utc(2026, 1, 2, 3, 4, 5);
        final file = File('${directory.path}/$deviceIdentityFileName');
        await file.writeAsString(
          jsonEncode(<String, Object>{
            'schema_version': deviceIdentityFileSchemaVersion,
            'device_id': id,
            'created_at': createdAt.toIso8601String(),
          }),
        );
        final service = DeviceIdentityService(
          resolveDirectory: () async => directory,
          generateId: () => throw StateError('must not generate'),
          platformResolver: () => 'windows',
        );

        final identity = await service.loadOrCreate();

        expect(identity.id, id);
        expect(identity.createdAt, createdAt);
      },
    );

    for (final invalid in <Object>[
      'not-json',
      <String, Object>{
        'schema_version': 2,
        'device_id': '00000000-0000-4000-8000-000000000001',
        'created_at': '2026-01-01T00:00:00Z',
      },
      <String, Object>{
        'schema_version': 1,
        'device_id': 'not-a-uuid',
        'created_at': '2026-01-01T00:00:00Z',
      },
      <String, Object>{
        'schema_version': 1,
        'device_id': '00000000-0000-4000-8000-000000000001',
        'created_at': 'not-a-date',
      },
      <String, Object>{
        'schema_version': 1,
        'device_id': '00000000-0000-1000-8000-000000000001',
        'created_at': '2026-01-01T00:00:00Z',
      },
    ]) {
      test('preserves and replaces malformed identity: $invalid', () async {
        final file = File('${directory.path}/$deviceIdentityFileName');
        await file.writeAsString(
          invalid is String ? invalid : jsonEncode(invalid),
        );
        const replacementId = '00000000-0000-4000-8000-000000000002';
        final service = DeviceIdentityService(
          resolveDirectory: () async => directory,
          generateId: () => replacementId,
          clock: () => DateTime.utc(2026, 8, 11),
          platformResolver: () => 'windows',
        );

        final identity = await service.loadOrCreate();

        expect(identity.id, replacementId);
        expect(
          directory.listSync().whereType<File>().where(
            (entry) => entry.path.contains('.invalid-'),
          ),
          hasLength(1),
        );
      });
    }

    test('adopts a valid identity created by a concurrent process', () async {
      const localId = '00000000-0000-4000-8000-000000000003';
      const concurrentId = '00000000-0000-4000-8000-000000000004';
      final createdAt = DateTime.utc(2026, 8, 11);
      final service = DeviceIdentityService(
        resolveDirectory: () async => directory,
        generateId: () => localId,
        clock: () => createdAt,
        platformResolver: () => 'windows',
        beforePublish: (temporaryFile, identityFile) {
          return identityFile.writeAsString(
            jsonEncode(<String, Object>{
              'schema_version': deviceIdentityFileSchemaVersion,
              'device_id': concurrentId,
              'created_at': createdAt.toIso8601String(),
            }),
          );
        },
      );

      final identity = await service.loadOrCreate();

      expect(identity.id, concurrentId);
      expect(
        directory.listSync().whereType<File>().any(
          (entry) => entry.path.endsWith('.tmp'),
        ),
        isFalse,
      );
    });

    test('replaces an invalid identity created during publication', () async {
      var publishCalls = 0;
      const id = '00000000-0000-4000-8000-000000000005';
      final service = DeviceIdentityService(
        resolveDirectory: () async => directory,
        generateId: () => id,
        clock: () => DateTime.utc(2026, 8, 11),
        platformResolver: () => 'windows',
        beforePublish: (temporaryFile, identityFile) async {
          publishCalls += 1;
          await identityFile.writeAsString('invalid');
        },
      );

      final identity = await service.loadOrCreate();

      expect(identity.id, id);
      expect(publishCalls, 1);
      expect(
        directory.listSync().whereType<File>().where(
          (entry) => entry.path.contains('.invalid-'),
        ),
        hasLength(1),
      );
    });

    test('provider returns the configured service', () {
      final service = DeviceIdentityService(
        resolveDirectory: () async => directory,
      );
      final container = ProviderContainer(
        overrides: [deviceIdentityServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      expect(container.read(deviceIdentityServiceProvider), same(service));
    });

    test('default service provider creates the platform service', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        container.read(deviceIdentityServiceProvider),
        isA<DeviceIdentityService>(),
      );
    });

    test('identity provider loads through the configured service', () async {
      const id = '00000000-0000-4000-8000-000000000006';
      final service = DeviceIdentityService(
        resolveDirectory: () async => directory,
        generateId: () => id,
        clock: () => DateTime.utc(2026, 8, 11),
        platformResolver: () => 'windows',
      );
      final container = ProviderContainer(
        overrides: [deviceIdentityServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      expect((await container.read(deviceIdentityProvider.future)).id, id);
    });

    test('does not hide identity file-system failures', () async {
      if (Platform.isWindows) {
        return;
      }
      final identityFile = File('${directory.path}/$deviceIdentityFileName');
      await identityFile.writeAsString('unreadable');
      await Process.run('chmod', <String>['000', identityFile.path]);
      addTearDown(
        () => Process.run('chmod', <String>['600', identityFile.path]),
      );
      final service = DeviceIdentityService(
        resolveDirectory: () async => directory,
      );

      await expectLater(
        service.loadOrCreate(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('uses the real platform resolver by default', () async {
      const id = '00000000-0000-4000-8000-000000000007';
      final service = DeviceIdentityService(
        resolveDirectory: () async => directory,
        generateId: () => id,
        clock: () => DateTime.utc(2026, 8, 11),
      );

      expect((await service.loadOrCreate()).id, id);
    });
  });
}
