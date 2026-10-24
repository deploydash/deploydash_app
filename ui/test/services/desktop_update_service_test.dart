import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/device_installation_repository.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/services/desktop_update_service.dart';
import 'package:ui/services/device_identity_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../_support/fake_analytics_service.dart';
import '../_support/sqlite_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('DesktopUpdateService', () {
    late AppDatabase database;
    late DeviceInstallationRepository repository;
    late SimpleKeyPair signingKey;
    late String publicKey;
    late DateTime now;
    late DeviceInstallationRecord installation;

    setUp(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = DeviceInstallationRepository(database);
      signingKey = await Ed25519().newKeyPairFromSeed(
        List<int>.generate(32, (index) => index + 1),
      );
      publicKey = base64Encode((await signingKey.extractPublicKey()).bytes);
      now = DateTime.utc(2026, 8, 11, 12);
      installation = DeviceInstallationRecord(
        id: '00000000-0000-4000-8000-000000000001',
        displayName: 'Test device',
        platform: 'linux',
        architecture: 'x64',
        createdAt: DateTime.utc(2026, 1, 1),
        lastSeenAt: now,
      );
      await repository.ensureCurrentDevice(
        identity: DeviceIdentity(
          id: installation.id,
          createdAt: installation.createdAt,
        ),
        displayName: installation.displayName,
        platform: installation.platform,
        architecture: installation.architecture,
        seenAt: now,
      );
    });

    tearDown(() => database.close());

    test('verifies update response, binds request, and stores cache', () async {
      Uri? requestedUri;
      String? requestedEtag;
      final envelope = await _envelope(
        signingKey: signingKey,
        payload: _payload(now: now),
      );
      final service = _service(
        repository: repository,
        publicKey: publicKey,
        now: now,
        httpGet: (uri, {etag}) async {
          requestedUri = uri;
          requestedEtag = etag;
          return DesktopUpdateHttpResponse(
            statusCode: 200,
            body: envelope,
            etag: '"release-2"',
          );
        },
      );

      final snapshot = await service.check(installation: installation);

      expect(snapshot.status, DesktopUpdateStatus.updateAvailable);
      expect(snapshot.release?.releaseId, 'release-2');
      expect(snapshot.showBadge, isTrue);
      expect(snapshot.currentBuild.displayVersion, '1.0.0+1');
      expect(requestedEtag, isNull);
      expect(requestedUri?.host, 'updates.example.test');
      expect(requestedUri?.queryParameters, <String, String>{
        'platform': 'linux',
        'architecture': 'x64',
        'distribution': 'deb',
        'channel': 'stable',
        'version': '1.0.0',
        'build': '1',
        'database_schema': '$desktopDatabaseSchemaVersion',
        'protocol': '1',
      });
      expect(requestedUri.toString(), isNot(contains(installation.id)));
      final state = await repository.readUpdateState(installation.id);
      expect(state?.cachedSignedEnvelope, envelope);
      expect(state?.cachedEtag, '"release-2"');
    }, skip: !sqliteAvailable);

    test('revalidates a cached signed response after HTTP 304', () async {
      final envelope = await _envelope(
        signingKey: signingKey,
        payload: _payload(now: now, status: 'current', release: null),
      );
      await repository.recordUpdateCheck(
        deviceId: installation.id,
        status: 'current',
        signedEnvelope: envelope,
        etag: '"cached"',
        checkedAt: now,
      );
      String? sentEtag;
      final service = _service(
        repository: repository,
        publicKey: publicKey,
        now: now,
        httpGet: (uri, {etag}) async {
          sentEtag = etag;
          return const DesktopUpdateHttpResponse(statusCode: 304, body: '');
        },
      );

      final snapshot = await service.check(installation: installation);

      expect(snapshot.status, DesktopUpdateStatus.current);
      expect(sentEtag, '"cached"');
      expect(
        (await repository.readUpdateState(installation.id))?.cachedEtag,
        '"cached"',
      );
    }, skip: !sqliteAvailable);

    for (final testCase in <(int, String)>[
      (400, 'invalid update request'),
      (429, 'rate limited'),
      (500, 'temporarily unavailable'),
      (418, 'HTTP 418'),
      (304, 'HTTP 304'),
    ]) {
      test('HTTP ${testCase.$1} fails without blocking the app', () async {
        final service = _service(
          repository: repository,
          publicKey: publicKey,
          now: now,
          httpGet: (uri, {etag}) async =>
              DesktopUpdateHttpResponse(statusCode: testCase.$1, body: ''),
        );

        final snapshot = await service.check(installation: installation);

        expect(snapshot.status, DesktopUpdateStatus.failed);
        expect(snapshot.message, contains(testCase.$2));
        expect(snapshot.hasUpdate, isFalse);
      }, skip: !sqliteAvailable);
    }

    test(
      'unexpected transport failures use calm copy and preserve cache',
      () async {
        await repository.recordUpdateCheck(
          deviceId: installation.id,
          status: 'current',
          releaseId: 'release-1',
          signedEnvelope: 'cached',
          etag: 'etag',
          checkedAt: now,
        );
        final service = _service(
          repository: repository,
          publicKey: publicKey,
          now: now,
          httpGet: (uri, {etag}) => throw StateError('network internals'),
        );

        final snapshot = await service.check(installation: installation);

        expect(snapshot.status, DesktopUpdateStatus.failed);
        expect(snapshot.message, 'Deploy Dash could not check for updates.');
        final state = await repository.readUpdateState(installation.id);
        expect(state?.cachedSignedEnvelope, 'cached');
        expect(state?.cachedEtag, 'etag');
      },
      skip: !sqliteAvailable,
    );

    test(
      'dismisses releases and opens install and release note URIs',
      () async {
        final launched = <Uri>[];
        final service = _service(
          repository: repository,
          publicKey: publicKey,
          now: now,
          launchUri: (uri) async {
            launched.add(uri);
            return true;
          },
          installUpdate: (release) async {
            launched.add(release.installUri);
            return true;
          },
        );
        final release = _release(now: now);

        expect(await service.startUpdate(release), isTrue);
        expect(await service.openReleaseNotes(release), isTrue);
        await service.dismiss(deviceId: installation.id, release: release);

        expect(launched, <Uri>[
          Uri.parse('apt://deploydash'),
          Uri.parse('https://updates.example.test/releases/2'),
        ]);
        expect(
          (await repository.readUpdateState(
            installation.id,
          ))?.dismissedReleaseId,
          'release-2',
        );
      },
      skip: !sqliteAvailable,
    );

    test('default installer opens non-Sparkle install URIs', () async {
      Uri? launchedUri;
      final service = _service(
        repository: repository,
        publicKey: publicKey,
        now: now,
        launchUri: (uri) async {
          launchedUri = uri;
          return true;
        },
      );

      expect(await service.startUpdate(_release(now: now)), isTrue);
      expect(launchedUri, Uri.parse('apt://deploydash'));
    });

    for (final status in <String>['current', 'unsupported']) {
      test('accepts signed $status responses without a release', () async {
        final envelope = await _envelope(
          signingKey: signingKey,
          payload: _payload(now: now, status: status, release: null),
        );
        final service = _serviceWithEnvelope(
          repository: repository,
          publicKey: publicKey,
          now: now,
          envelope: envelope,
        );

        final snapshot = await service.check(installation: installation);

        expect(
          snapshot.status,
          status == 'current'
              ? DesktopUpdateStatus.current
              : DesktopUpdateStatus.unsupported,
        );
        expect(snapshot.release, isNull);
      }, skip: !sqliteAvailable);
    }

    test(
      'required updates bypass staged rollout and remain non-blocking',
      () async {
        final envelope = await _envelope(
          signingKey: signingKey,
          payload: _payload(
            now: now,
            status: 'update_required',
            release: _releaseJson(now: now, rolloutPercentage: 0),
          ),
        );
        final snapshot = await _serviceWithEnvelope(
          repository: repository,
          publicKey: publicKey,
          now: now,
          envelope: envelope,
        ).check(installation: installation);

        expect(snapshot.status, DesktopUpdateStatus.updateRequired);
        expect(snapshot.hasUpdate, isTrue);
      },
      skip: !sqliteAvailable,
    );

    test(
      'defers an available release outside a zero percent rollout',
      () async {
        final envelope = await _envelope(
          signingKey: signingKey,
          payload: _payload(
            now: now,
            release: _releaseJson(now: now, rolloutPercentage: 0),
          ),
        );
        final snapshot = await _serviceWithEnvelope(
          repository: repository,
          publicKey: publicKey,
          now: now,
          envelope: envelope,
        ).check(installation: installation);

        expect(snapshot.status, DesktopUpdateStatus.deferred);
        expect(snapshot.message, contains('gradually'));
      },
      skip: !sqliteAvailable,
    );

    test(
      'uses deterministic rollout projects between zero and one hundred',
      () async {
        final envelope = await _envelope(
          signingKey: signingKey,
          payload: _payload(
            now: now,
            release: _releaseJson(now: now, rolloutPercentage: 50),
          ),
        );
        final service = _serviceWithEnvelope(
          repository: repository,
          publicKey: publicKey,
          now: now,
          envelope: envelope,
        );

        final first = await service.check(installation: installation);
        final second = await service.check(installation: installation);

        expect(second.status, first.status);
        expect(
          first.status,
          anyOf(
            DesktopUpdateStatus.updateAvailable,
            DesktopUpdateStatus.deferred,
          ),
        );
      },
      skip: !sqliteAvailable,
    );

    for (final entry in <String, (String, String, String)>{
      'apt_repository': ('apt://deploydash', 'deb', 'linux'),
      'snap': ('snap://deploydash', 'snap', 'linux'),
      'flatpak': ('appstream://com.deploydash.desktop', 'flatpak', 'linux'),
      'sparkle': ('https://updates.example.test/appcast.xml', 'dmg', 'macos'),
      'mac_app_store': (
        'macappstore://itunes.apple.com/app/id6797314237',
        'mac_app_store',
        'macos',
      ),
      'windows_store': (
        desktopWindowsStoreInstallUri,
        'windows_store',
        'windows',
      ),
    }.entries) {
      test('parses ${entry.key} installation strategy', () async {
        final release = _releaseJson(
          now: now,
          strategy: entry.key,
          installUri: entry.value.$1,
        );
        final envelope = await _envelope(
          signingKey: signingKey,
          payload: _payload(
            now: now,
            release: release,
            distribution: entry.value.$2,
            platform: entry.value.$3,
          ),
        );
        final snapshot =
            await _serviceWithEnvelope(
              repository: repository,
              publicKey: publicKey,
              now: now,
              envelope: envelope,
              distribution: entry.value.$2,
            ).check(
              installation: DeviceInstallationRecord(
                id: installation.id,
                displayName: installation.displayName,
                platform: entry.value.$3,
                architecture: installation.architecture,
                createdAt: installation.createdAt,
                lastSeenAt: installation.lastSeenAt,
              ),
            );

        expect(snapshot.release?.installUri.toString(), entry.value.$1);
      }, skip: !sqliteAvailable);
    }

    test('rejects an install strategy for a different distribution', () async {
      final envelope = await _envelope(
        signingKey: signingKey,
        payload: _payload(
          now: now,
          release: _releaseJson(
            now: now,
            strategy: 'windows_store',
            installUri: desktopWindowsStoreInstallUri,
          ),
        ),
      );

      final snapshot = await _serviceWithEnvelope(
        repository: repository,
        publicKey: publicKey,
        now: now,
        envelope: envelope,
      ).check(installation: installation);

      expect(snapshot.status, DesktopUpdateStatus.failed);
      expect(snapshot.message, contains('installation source'));
    }, skip: !sqliteAvailable);

    test('default Sparkle installer calls the macOS update channel', () async {
      const channel = MethodChannel('com.deploydash.desktop/updates');
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            capturedCall = call;
            return true;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final service = _service(
        repository: repository,
        publicKey: publicKey,
        now: now,
      );
      final release = _release(
        now: now,
        strategy: DesktopUpdateInstallStrategy.sparkle,
        installUri: 'https://updates.example.test/appcast.xml',
      );

      expect(await service.startUpdate(release), isTrue);
      expect(capturedCall?.method, 'checkForUpdates');
      expect(capturedCall?.arguments, <String, String>{
        'feedUrl': 'https://updates.example.test/appcast.xml',
      });
    });

    for (final error in <Object>[
      PlatformException(code: 'unavailable'),
      MissingPluginException('not bundled'),
    ]) {
      test(
        'default Sparkle installer reports ${error.runtimeType} failures',
        () async {
          const channel = MethodChannel('com.deploydash.desktop/updates');
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) => throw error);
          addTearDown(() {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null);
          });
          final service = _service(
            repository: repository,
            publicKey: publicKey,
            now: now,
          );

          expect(
            await service.startUpdate(
              _release(
                now: now,
                strategy: DesktopUpdateInstallStrategy.sparkle,
                installUri: 'https://updates.example.test/appcast.xml',
              ),
            ),
            isFalse,
          );
        },
      );
    }

    test('default Sparkle installer rejects an empty native result', () async {
      const channel = MethodChannel('com.deploydash.desktop/updates');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final service = _service(
        repository: repository,
        publicKey: publicKey,
        now: now,
      );

      expect(
        await service.startUpdate(
          _release(
            now: now,
            strategy: DesktopUpdateInstallStrategy.sparkle,
            installUri: 'https://updates.example.test/appcast.xml',
          ),
        ),
        isFalse,
      );
    });

    for (final severity in <String>[
      'normal',
      'recommended',
      'security',
      'critical',
    ]) {
      test('parses $severity release severity', () async {
        final envelope = await _envelope(
          signingKey: signingKey,
          payload: _payload(
            now: now,
            release: _releaseJson(now: now, severity: severity),
          ),
        );
        final snapshot = await _serviceWithEnvelope(
          repository: repository,
          publicKey: publicKey,
          now: now,
          envelope: envelope,
        ).check(installation: installation);

        expect(snapshot.release?.severity.name, severity);
      }, skip: !sqliteAvailable);
    }

    test(
      'rejects untrusted, altered, expired, and mismatched envelopes',
      () async {
        final validPayload = _payload(now: now);
        final cases = <Future<String>>[
          Future.value('not-json'),
          Future.value(jsonEncode(<String, Object>{})),
          _envelope(
            signingKey: signingKey,
            payload: validPayload,
            algorithm: 'RSA',
          ),
          _envelope(
            signingKey: signingKey,
            payload: validPayload,
            keyId: 'unknown',
          ),
          _envelope(
            signingKey: signingKey,
            payload: validPayload,
            signatureOverride: base64UrlEncode(List<int>.filled(64, 0)),
          ),
          _envelope(
            signingKey: signingKey,
            payload: _payload(
              now: now,
              expiresAt: now.subtract(const Duration(seconds: 1)),
            ),
          ),
          _envelope(
            signingKey: signingKey,
            payload: _payload(
              now: now,
              generatedAt: now.add(const Duration(minutes: 6)),
            ),
          ),
          _envelope(
            signingKey: signingKey,
            payload: _payload(now: now)..['request'] = <String, Object>{},
          ),
        ];

        for (final envelopeFuture in cases) {
          final snapshot = await _serviceWithEnvelope(
            repository: repository,
            publicKey: publicKey,
            now: now,
            envelope: await envelopeFuture,
          ).check(installation: installation);
          expect(snapshot.status, DesktopUpdateStatus.failed);
        }
      },
      skip: !sqliteAvailable,
    );

    test('rejects malformed release contracts safely', () async {
      final missingArtifactMetadata = _releaseJson(now: now);
      (missingArtifactMetadata['install']! as Map<String, Object?>)
        ..remove('sha256')
        ..remove('size');
      final invalidPayloads = <Map<String, dynamic>>[
        _payload(now: now)..['manifest_version'] = 2,
        _payload(now: now)..['generated_at'] = 'not-a-date',
        _payload(now: now)..['status'] = 'mystery',
        _payload(now: now, release: null),
        _payload(now: now)
          ..['release'] = (_releaseJson(now: now)..['severity'] = 'urgent'),
        _payload(now: now)
          ..['release'] = (_releaseJson(now: now)
            ..['database_compatibility'] = <String, Object>{
              'minimum_schema': desktopDatabaseSchemaVersion + 1,
              'maximum_schema': desktopDatabaseSchemaVersion + 2,
            }),
        _payload(now: now)
          ..['release'] = (_releaseJson(now: now)
            ..['database_compatibility'] = <String, Object>{
              'minimum_schema': -1,
              'maximum_schema': desktopDatabaseSchemaVersion - 1,
            }),
        _payload(now: now)
          ..['release'] = (_releaseJson(now: now)
            ..['database_compatibility'] = <String, Object>{
              'minimum_schema': desktopDatabaseSchemaVersion,
              'maximum_schema': desktopDatabaseSchemaVersion - 1,
            }),
        _payload(now: now)
          ..['release'] = (_releaseJson(now: now)
            ..['rollout'] = <String, Object>{'percentage': 101, 'salt': 'x'}),
        _payload(now: now)
          ..['release'] = (_releaseJson(now: now)
            ..['install'] = <String, Object>{
              'strategy': 'unknown',
              'uri': 'https://example.test',
            }),
        _payload(now: now)
          ..['release'] = (_releaseJson(now: now)
            ..['release_notes_url'] = 'http://updates.example.test/releases/2'),
        _payload(now: now)
          ..['release'] = (_releaseJson(now: now)
            ..['release_notes_url'] = 'release-notes'),
        _payload(now: now)
          ..['release'] = _releaseJson(
            now: now,
            installUri: 'https://updates.example.test/install',
          ),
        _payload(now: now)
          ..['release'] = _releaseJson(
            now: now,
            strategy: 'windows_store',
            installUri: 'ms-windows-store://pdp/?productid=OTHER',
          ),
        _payload(now: now)
          ..['release'] = (_releaseJson(now: now)
            ..['install'] = <String, Object>{
              'strategy': 'apt_repository',
              'uri': 'not-a-uri',
            }),
        _payload(now: now)
          ..['release'] = (_releaseJson(now: now)
            ..['install'] = <String, Object>{
              'strategy': 'apt_repository',
              'uri': 'apt://deploydash',
              'sha256': 'INVALID',
              'size': 12345,
            }),
        _payload(now: now)
          ..['release'] = (_releaseJson(now: now)
            ..['install'] = <String, Object>{
              'strategy': 'apt_repository',
              'uri': 'apt://deploydash',
              'sha256': List<String>.filled(64, 'a').join(),
              'size': 0,
            }),
      ];

      for (final payload in invalidPayloads) {
        final snapshot = await _serviceWithEnvelope(
          repository: repository,
          publicKey: publicKey,
          now: now,
          envelope: await _envelope(signingKey: signingKey, payload: payload),
        ).check(installation: installation);
        expect(snapshot.status, DesktopUpdateStatus.failed);
      }

      final validWithoutArtifactMetadata = await _serviceWithEnvelope(
        repository: repository,
        publicKey: publicKey,
        now: now,
        envelope: await _envelope(
          signingKey: signingKey,
          payload: _payload(now: now, release: missingArtifactMetadata),
        ),
      ).check(installation: installation);
      expect(
        validWithoutArtifactMetadata.status,
        DesktopUpdateStatus.updateAvailable,
      );
      expect(validWithoutArtifactMetadata.release?.artifactSha256, isNull);
      expect(validWithoutArtifactMetadata.release?.artifactSize, isNull);
    }, skip: !sqliteAvailable);

    test('rejects non-object payloads and malformed signed data', () async {
      final nonObjectPayload = await _envelopeFromText(
        signingKey: signingKey,
        payloadText: '[]',
      );
      final invalidBase64 = jsonEncode(<String, Object>{
        'envelope_version': 1,
        'key_id': 'test-key',
        'algorithm': 'Ed25519',
        'payload': '%',
        'signature': '%',
      });
      final missingAlgorithm = jsonEncode(<String, Object>{
        'envelope_version': 1,
        'key_id': 'test-key',
        'algorithm': '',
        'payload': 'x',
        'signature': 'x',
      });

      for (final envelope in <String>[
        nonObjectPayload,
        invalidBase64,
        missingAlgorithm,
      ]) {
        final snapshot = await _serviceWithEnvelope(
          repository: repository,
          publicKey: publicKey,
          now: now,
          envelope: envelope,
        ).check(installation: installation);
        expect(snapshot.status, DesktopUpdateStatus.failed);
      }
      expect(const DesktopUpdateException('failure').toString(), 'failure');
    }, skip: !sqliteAvailable);

    test(
      'controller exposes checks, actions, dismissal, and failures',
      () async {
        final envelope = await _envelope(
          signingKey: signingKey,
          payload: _payload(now: now),
        );
        final launched = <Uri>[];
        final service = _service(
          repository: repository,
          publicKey: publicKey,
          now: now,
          httpGet: (uri, {etag}) async =>
              DesktopUpdateHttpResponse(statusCode: 200, body: envelope),
          launchUri: (uri) async {
            launched.add(uri);
            return true;
          },
          installUpdate: (release) async {
            launched.add(release.installUri);
            return true;
          },
        );
        final container = ProviderContainer(
          overrides: [
            desktopUpdateServiceProvider.overrideWithValue(service),
            currentDeviceInstallationProvider.overrideWith(
              (ref) async => installation,
            ),
          ],
        );
        addTearDown(container.dispose);

        final initial = await container.read(
          desktopUpdateControllerProvider.future,
        );
        final controller = container.read(
          desktopUpdateControllerProvider.notifier,
        );
        expect(initial.status, DesktopUpdateStatus.notChecked);
        expect(await controller.startUpdate(), isFalse);
        expect(await controller.openReleaseNotes(), isFalse);
        await controller.dismiss();

        await controller.check();
        expect(
          container.read(desktopUpdateControllerProvider).requireValue.status,
          DesktopUpdateStatus.updateAvailable,
        );
        expect(await controller.startUpdate(), isTrue);
        expect(await controller.openReleaseNotes(), isTrue);
        await controller.dismiss();

        final dismissed = container
            .read(desktopUpdateControllerProvider)
            .requireValue;
        expect(dismissed.showBadge, isFalse);
        expect(dismissed.dismissedReleaseId, 'release-2');
        expect(launched, <Uri>[
          Uri.parse('apt://deploydash'),
          Uri.parse('https://updates.example.test/releases/2'),
        ]);
      },
      skip: !sqliteAvailable,
    );

    test('controller surfaces local device identity failures', () async {
      final service = _service(
        repository: repository,
        publicKey: publicKey,
        now: now,
      );
      final container = ProviderContainer(
        overrides: [
          desktopUpdateServiceProvider.overrideWithValue(service),
          currentDeviceInstallationProvider.overrideWith(
            (ref) => Future<DeviceInstallationRecord>.error(
              StateError('device unavailable'),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(desktopUpdateControllerProvider.future);
      final controller = container.read(
        desktopUpdateControllerProvider.notifier,
      );

      await controller.check();

      expect(container.read(desktopUpdateControllerProvider).hasError, isTrue);
      expect(await controller.startUpdate(), isFalse);
      expect(await controller.openReleaseNotes(), isFalse);
      await controller.dismiss();
    }, skip: !sqliteAvailable);

    // These two run before 'default provider loads...' below: that test's
    // setMockInitialValues poisons PackageInfo's static cache for the rest
    // of the file, which would mask the channel and defeat both tests.
    test(
      'default build info falls back when the platform channel fails',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              channel,
              (call) async => throw PlatformException(code: 'unavailable'),
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final build = await DesktopUpdateService(
          repository: repository,
        ).loadBuildInfo();
        expect(build.version, desktopReleaseVersion);
        expect(build.build, desktopReleaseBuild);
      },
      skip: !sqliteAvailable,
    );

    test('default build info falls back when the plugin is missing', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => throw MissingPluginException(),
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final build = await DesktopUpdateService(
        repository: repository,
      ).loadBuildInfo();
      expect(build.version, desktopReleaseVersion);
      expect(build.build, desktopReleaseBuild);
    }, skip: !sqliteAvailable);

    test(
      'default provider loads package info and opens external URIs',
      () async {
        PackageInfo.setMockInitialValues(
          appName: 'Deploy Dash',
          packageName: 'com.deploydash.desktop',
          version: '1.2.3',
          buildNumber: '45',
          buildSignature: '',
        );
        final previousLauncher = UrlLauncherPlatform.instance;
        final launcher = _FakeUrlLauncher();
        UrlLauncherPlatform.instance = launcher;
        addTearDown(() => UrlLauncherPlatform.instance = previousLauncher);
        final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(database)],
        );
        addTearDown(container.dispose);

        final service = container.read(desktopUpdateServiceProvider);
        final build = await service.loadBuildInfo();
        final release = _release(now: now);

        expect(build.displayVersion, '1.2.3+45');
        expect(await service.openReleaseNotes(release), isTrue);
        expect(launcher.launchedUri, release.releaseNotesUri.toString());
      },
      skip: !sqliteAvailable,
    );

    test(
      'controller checks report the update event with from_version',
      () async {
        final envelope = await _envelope(
          signingKey: signingKey,
          payload: _payload(now: now),
        );
        final service = _serviceWithEnvelope(
          repository: repository,
          publicKey: publicKey,
          now: now,
          envelope: envelope,
        );
        final analytics = FakeAnalyticsService();
        final container = ProviderContainer(
          overrides: [
            desktopUpdateServiceProvider.overrideWithValue(service),
            currentDeviceInstallationProvider.overrideWith(
              (ref) async => installation,
            ),
            appAnalyticsServiceProvider.overrideWithValue(analytics),
          ],
        );
        addTearDown(container.dispose);
        final controller = container.read(
          desktopUpdateControllerProvider.notifier,
        );

        await controller.check();

        expect(
          container.read(desktopUpdateControllerProvider).requireValue.status,
          DesktopUpdateStatus.updateAvailable,
        );
        expect(analytics.updateEvents, [
          (
            action: UpdateAction.check,
            outcome: DataOperationOutcome.success,
            fromVersion: '1.0.0',
          ),
        ]);
      },
      skip: !sqliteAvailable,
    );

    test('controller check failures report the update event', () async {
      final service = _service(
        repository: repository,
        publicKey: publicKey,
        now: now,
      );
      final analytics = FakeAnalyticsService();
      final container = ProviderContainer(
        overrides: [
          desktopUpdateServiceProvider.overrideWithValue(service),
          currentDeviceInstallationProvider.overrideWith(
            (ref) async => installation,
          ),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(
        desktopUpdateControllerProvider.notifier,
      );

      await controller.check();

      expect(
        container.read(desktopUpdateControllerProvider).requireValue.status,
        DesktopUpdateStatus.failed,
      );
      expect(analytics.updateEvents, [
        (
          action: UpdateAction.check,
          outcome: DataOperationOutcome.failure,
          fromVersion: '1.0.0',
        ),
      ]);
    }, skip: !sqliteAvailable);

    test('controller install handoffs report the update event', () async {
      final envelope = await _envelope(
        signingKey: signingKey,
        payload: _payload(now: now),
      );
      final service = _serviceWithEnvelope(
        repository: repository,
        publicKey: publicKey,
        now: now,
        envelope: envelope,
        installUpdate: (release) async => true,
      );
      final analytics = FakeAnalyticsService();
      final container = ProviderContainer(
        overrides: [
          desktopUpdateServiceProvider.overrideWithValue(service),
          currentDeviceInstallationProvider.overrideWith(
            (ref) async => installation,
          ),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(
        desktopUpdateControllerProvider.notifier,
      );

      await controller.check();
      expect(await controller.startUpdate(), isTrue);

      expect(analytics.updateEvents, [
        (
          action: UpdateAction.check,
          outcome: DataOperationOutcome.success,
          fromVersion: '1.0.0',
        ),
        (
          action: UpdateAction.apply,
          outcome: DataOperationOutcome.success,
          fromVersion: '1.0.0',
        ),
      ]);
    }, skip: !sqliteAvailable);

    test('controller handoff failures report the update event', () async {
      final envelope = await _envelope(
        signingKey: signingKey,
        payload: _payload(now: now),
      );
      final service = _serviceWithEnvelope(
        repository: repository,
        publicKey: publicKey,
        now: now,
        envelope: envelope,
        installUpdate: (release) async => false,
      );
      final analytics = FakeAnalyticsService();
      final container = ProviderContainer(
        overrides: [
          desktopUpdateServiceProvider.overrideWithValue(service),
          currentDeviceInstallationProvider.overrideWith(
            (ref) async => installation,
          ),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(
        desktopUpdateControllerProvider.notifier,
      );

      await controller.check();
      expect(await controller.startUpdate(), isFalse);

      expect(analytics.updateEvents, [
        (
          action: UpdateAction.check,
          outcome: DataOperationOutcome.success,
          fromVersion: '1.0.0',
        ),
        (
          action: UpdateAction.apply,
          outcome: DataOperationOutcome.failure,
          fromVersion: '1.0.0',
        ),
      ]);
    }, skip: !sqliteAvailable);
  });
}

class _FakeUrlLauncher extends UrlLauncherPlatform {
  String? launchedUri;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launchedUri = url;
    return true;
  }
}

DesktopUpdateService _service({
  required DeviceInstallationRepository repository,
  required String publicKey,
  required DateTime now,
  DesktopUpdateHttpGet? httpGet,
  DesktopUpdateUriLauncher? launchUri,
  DesktopUpdateInstaller? installUpdate,
  String distribution = 'deb',
}) {
  return DesktopUpdateService(
    repository: repository,
    httpGet:
        httpGet ??
        (uri, {etag}) async =>
            const DesktopUpdateHttpResponse(statusCode: 500, body: ''),
    loadBuildInfo: () async =>
        const DesktopBuildInfo(version: '1.0.0', build: '1'),
    launchUri: launchUri,
    installUpdate: installUpdate,
    trustedPublicKeys: <String, String>{'test-key': publicKey},
    clock: () => now,
    endpoint: 'https://updates.example.test/v1/desktop/releases/check',
    distribution: distribution,
    channel: 'stable',
  );
}

DesktopUpdateService _serviceWithEnvelope({
  required DeviceInstallationRepository repository,
  required String publicKey,
  required DateTime now,
  required String envelope,
  String distribution = 'deb',
  DesktopUpdateInstaller? installUpdate,
}) {
  return _service(
    repository: repository,
    publicKey: publicKey,
    now: now,
    httpGet: (uri, {etag}) async =>
        DesktopUpdateHttpResponse(statusCode: 200, body: envelope),
    distribution: distribution,
    installUpdate: installUpdate,
  );
}

Map<String, dynamic> _payload({
  required DateTime now,
  DateTime? generatedAt,
  DateTime? expiresAt,
  String status = 'update_available',
  Map<String, dynamic>? release = const <String, dynamic>{},
  String distribution = 'deb',
  String platform = 'linux',
}) {
  return <String, dynamic>{
    'manifest_version': 1,
    'generated_at': (generatedAt ?? now).toIso8601String(),
    'expires_at': (expiresAt ?? now.add(const Duration(hours: 1)))
        .toIso8601String(),
    'request': <String, Object>{
      'platform': platform,
      'architecture': 'x64',
      'distribution': distribution,
      'channel': 'stable',
      'version': '1.0.0',
      'build': '1',
      'database_schema': '$desktopDatabaseSchemaVersion',
      'protocol': '1',
    },
    'status': status,
    'message': 'Signed status message.',
    'release': release == null
        ? null
        : release.isEmpty
        ? _releaseJson(now: now)
        : release,
  };
}

Map<String, dynamic> _releaseJson({
  required DateTime now,
  String severity = 'recommended',
  int rolloutPercentage = 100,
  String strategy = 'apt_repository',
  String installUri = 'apt://deploydash',
}) {
  return <String, dynamic>{
    'release_id': 'release-2',
    'version': '1.1.0',
    'build': '2',
    'published_at': now.subtract(const Duration(days: 1)).toIso8601String(),
    'severity': severity,
    'title': 'Deploy Dash 1.1.0',
    'summary': 'Security and reliability improvements.',
    'release_notes_url': 'https://updates.example.test/releases/2',
    'minimum_supported_version': '0.9.0',
    'minimum_supported_build': '1',
    'database_compatibility': <String, Object>{
      'minimum_schema': 1,
      'maximum_schema': desktopDatabaseSchemaVersion,
    },
    'rollout': <String, Object>{
      'percentage': rolloutPercentage,
      'salt': 'stable-rollout',
    },
    'install': <String, Object?>{
      'strategy': strategy,
      'uri': installUri,
      'sha256': List<String>.filled(64, 'a').join(),
      'size': 12345,
    },
  };
}

DesktopUpdateRelease _release({
  required DateTime now,
  DesktopUpdateInstallStrategy strategy =
      DesktopUpdateInstallStrategy.aptRepository,
  String installUri = 'apt://deploydash',
}) {
  return DesktopUpdateRelease(
    releaseId: 'release-2',
    version: '1.1.0',
    build: '2',
    publishedAt: now,
    severity: DesktopUpdateSeverity.recommended,
    title: 'Deploy Dash 1.1.0',
    summary: 'Security and reliability improvements.',
    releaseNotesUri: Uri.parse('https://updates.example.test/releases/2'),
    minimumSupportedVersion: '0.9.0',
    minimumSupportedBuild: '1',
    minimumDatabaseSchema: 1,
    maximumDatabaseSchema: 47,
    rolloutPercentage: 100,
    rolloutSalt: 'salt',
    installStrategy: strategy,
    installUri: Uri.parse(installUri),
  );
}

Future<String> _envelope({
  required KeyPair signingKey,
  required Map<String, dynamic> payload,
  String keyId = 'test-key',
  String algorithm = 'Ed25519',
  String? signatureOverride,
}) async {
  return _envelopeFromText(
    signingKey: signingKey,
    payloadText: jsonEncode(payload),
    keyId: keyId,
    algorithm: algorithm,
    signatureOverride: signatureOverride,
  );
}

Future<String> _envelopeFromText({
  required KeyPair signingKey,
  required String payloadText,
  String keyId = 'test-key',
  String algorithm = 'Ed25519',
  String? signatureOverride,
}) async {
  final payloadBytes = utf8.encode(payloadText);
  final signature = await Ed25519().sign(payloadBytes, keyPair: signingKey);
  return jsonEncode(<String, Object>{
    'envelope_version': 1,
    'key_id': keyId,
    'algorithm': algorithm,
    'payload': base64UrlEncode(payloadBytes),
    'signature': signatureOverride ?? base64UrlEncode(signature.bytes),
  });
}
