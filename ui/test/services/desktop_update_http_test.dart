import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/device_installation_repository.dart';
import 'package:ui/services/desktop_update_service.dart';
import 'package:ui/services/device_identity_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  test('default HTTP client sends ETag and reads a signed response', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DeviceInstallationRepository(database);
    final now = DateTime.utc(2026, 8, 11, 12);
    const deviceId = '00000000-0000-4000-8000-000000000001';
    final installation = DeviceInstallationRecord(
      id: deviceId,
      displayName: 'Test device',
      platform: 'linux',
      architecture: 'x64',
      createdAt: now,
      lastSeenAt: now,
    );
    await repository.ensureCurrentDevice(
      identity: DeviceIdentity(id: deviceId, createdAt: now),
      displayName: installation.displayName,
      platform: installation.platform,
      architecture: installation.architecture,
      seenAt: now,
    );
    await repository.recordUpdateCheck(
      deviceId: deviceId,
      status: 'current',
      etag: '"previous"',
      checkedAt: now,
    );
    final signingKey = await Ed25519().newKeyPairFromSeed(
      List<int>.generate(32, (index) => index + 1),
    );
    final publicKey = base64Encode((await signingKey.extractPublicKey()).bytes);
    final payloadBytes = utf8.encode(
      jsonEncode(<String, Object?>{
        'manifest_version': 1,
        'generated_at': now.toIso8601String(),
        'expires_at': now.add(const Duration(hours: 1)).toIso8601String(),
        'request': <String, Object>{
          'platform': 'linux',
          'architecture': 'x64',
          'distribution': 'deb',
          'channel': 'stable',
          'version': '1.0.0',
          'build': '1',
          'database_schema': '$desktopDatabaseSchemaVersion',
          'protocol': '1',
        },
        'status': 'current',
        'release': null,
      }),
    );
    final signature = await Ed25519().sign(payloadBytes, keyPair: signingKey);
    final envelope = jsonEncode(<String, Object>{
      'envelope_version': 1,
      'key_id': 'test-key',
      'algorithm': 'Ed25519',
      'payload': base64UrlEncode(payloadBytes),
      'signature': base64UrlEncode(signature.bytes),
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    String? receivedEtag;
    server.listen((request) async {
      receivedEtag = request.headers.value(HttpHeaders.ifNoneMatchHeader);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.set(HttpHeaders.etagHeader, '"next"')
        ..write(envelope);
      await request.response.close();
    });
    final service = DesktopUpdateService(
      repository: repository,
      loadBuildInfo: () async =>
          const DesktopBuildInfo(version: '1.0.0', build: '1'),
      trustedPublicKeys: <String, String>{'test-key': publicKey},
      clock: () => now,
      endpoint:
          'http://${server.address.address}:${server.port}/v1/desktop/releases/check',
      distribution: 'deb',
      channel: 'stable',
    );

    final snapshot = await service.check(installation: installation);

    expect(snapshot.status, DesktopUpdateStatus.current);
    expect(receivedEtag, '"previous"');
    expect((await repository.readUpdateState(deviceId))?.cachedEtag, '"next"');
  }, skip: !sqliteAvailable);
}
