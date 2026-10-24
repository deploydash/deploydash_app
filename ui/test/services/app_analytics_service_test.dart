import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:amplitude_flutter/constants.dart';
import 'package:amplitude_flutter/desktop/desktop_direct_io.dart';
import 'package:amplitude_flutter/desktop/desktop_plugin.dart';
import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/models/deploy_failure_evidence.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/services/device_identity_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_support/sqlite_test_harness.dart';
import '../_support/fake_analytics_service.dart';

/// Records SDK method calls instead of running the real desktop backend: no
/// disk, no network. Installed via [debugDirectPluginFactory], which the
/// fork exposes exactly for this.
class _RecordingAmplitudePlugin extends DesktopAmplitudePlugin {
  _RecordingAmplitudePlugin(this.calls);

  final List<MethodCall> calls;

  @override
  Future<void> handleMethodCall(MethodCall call) async {
    calls.add(call);
  }
}

/// Fails every SDK call, proving the fail-closed wiring without a backend.
class _FailingAmplitudePlugin extends DesktopAmplitudePlugin {
  @override
  Future<void> handleMethodCall(MethodCall call) async {
    throw MissingPluginException('no backend in tests');
  }
}

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  test('sanitizeAnalyticsProperties keeps only supported values', () {
    expect(
      sanitizeAnalyticsProperties(<String, Object?>{
        'workspace': '  home  ',
        'count': 3,
        'ignored_bool': true,
        'ignored_null': null,
        ' ': 'skip',
        'blank_string': '   ',
      }),
      <String, dynamic>{'workspace': 'home', 'count': 3},
    );
  });

  test(
    'AptabaseAppAnalytics initializes once and tracks sanitized events',
    () async {
      var initializeCallCount = 0;
      final trackedEvents =
          <({String eventName, Map<String, dynamic>? props})>[];
      final service = AptabaseAppAnalytics(
        appKey: 'A-EU-3209480801',
        initializer: (appKey, options) async {
          initializeCallCount += 1;
          expect(appKey, 'A-EU-3209480801');
          expect(options.tickDuration, const Duration(seconds: 5));
        },
        tracker: (eventName, props) {
          trackedEvents.add((eventName: eventName, props: props));
        },
      );

      await service.initialize();
      await service.initialize();

      service.trackAppStarted();
      service.trackWorkspaceOpened(
        workspace: 'server_management',
        entryPoint: 'home_dashboard',
        tab: 'services',
      );
      service.trackEvent('invalid_props', <String, Object?>{
        'workspace': 'project',
        'skip_bool': false,
      });

      expect(initializeCallCount, 1);
      expect(trackedEvents, hasLength(3));
      expect(trackedEvents[0].eventName, 'app_started');
      expect(trackedEvents[0].props, <String, dynamic>{'surface': 'desktop'});
      expect(trackedEvents[1].eventName, 'workspace_opened');
      expect(trackedEvents[1].props, <String, dynamic>{
        'workspace': 'server_management',
        'entry_point': 'home_dashboard',
        'tab': 'services',
      });
      expect(trackedEvents[2].eventName, 'invalid_props');
      expect(trackedEvents[2].props, <String, dynamic>{'workspace': 'project'});
    },
  );

  test('AptabaseAppAnalytics reuses an in-flight initialization', () async {
    final completer = Completer<void>();
    var initializeCallCount = 0;
    final service = AptabaseAppAnalytics(
      appKey: 'A-EU-3209480801',
      initializer: (appKey, options) {
        initializeCallCount += 1;
        expect(options.tickDuration, const Duration(seconds: 5));
        return completer.future;
      },
      tracker: (eventName, props) {},
    );

    final firstInitialize = service.initialize();
    final secondInitialize = service.initialize();

    completer.complete();
    await Future.wait(<Future<void>>[firstInitialize, secondInitialize]);

    expect(initializeCallCount, 1);
  });

  test('AptabaseAppAnalytics skips tracking before initialization', () {
    var trackedEventCount = 0;
    final service = AptabaseAppAnalytics(
      appKey: 'A-EU-3209480801',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEventCount += 1;
      },
    );

    service.trackAppStarted();
    service.trackWorkspaceOpened(workspace: 'home');

    expect(trackedEventCount, 0);
  });

  test(
    'AmplitudeAppAnalytics initializes once and tracks sanitized events',
    () async {
      var initializeCallCount = 0;
      AmplitudeBackendConfig? capturedConfig;
      final trackedEvents =
          <({String eventName, Map<String, dynamic>? props})>[];
      final service = AmplitudeAppAnalytics(
        apiKey: '  test-api-key  ',
        initializer: (config) async {
          initializeCallCount += 1;
          capturedConfig = config;
        },
        tracker: (eventName, props) async {
          trackedEvents.add((eventName: eventName, props: props));
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      await service.initialize();
      await service.initialize();

      service.trackAppStarted();
      service.trackWorkspaceOpened(
        workspace: 'server_management',
        entryPoint: 'home_dashboard',
        tab: 'services',
      );
      await service.trackEventAsync('invalid_props', <String, Object?>{
        'workspace': 'project',
        'skip_bool': false,
      });
      await pumpEventQueue();

      expect(initializeCallCount, 1);
      expect(capturedConfig?.apiKey, 'test-api-key');
      expect(capturedConfig?.serverZone, ServerZone.eu);
      expect(capturedConfig?.trackingOptions.ipAddress, isTrue);
      expect(capturedConfig?.trackingOptions.city, isTrue);
      expect(trackedEvents, hasLength(3));
      expect(trackedEvents[0].eventName, 'app_started');
      expect(trackedEvents[0].props, <String, dynamic>{'surface': 'desktop'});
      expect(trackedEvents[1].eventName, 'workspace_opened');
      expect(trackedEvents[1].props, <String, dynamic>{
        'workspace': 'server_management',
        'entry_point': 'home_dashboard',
        'tab': 'services',
      });
      expect(trackedEvents[2].eventName, 'invalid_props');
      expect(trackedEvents[2].props, <String, dynamic>{'workspace': 'project'});
    },
  );

  test('AmplitudeAppAnalytics reuses an in-flight initialization', () async {
    final completer = Completer<void>();
    var initializeCallCount = 0;
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) {
        initializeCallCount += 1;
        return completer.future;
      },
      tracker: (eventName, props) async {},
      flusher: () async {},
      identifier: (attributes) async {},
    );

    final firstInitialize = service.initialize();
    final secondInitialize = service.initialize();

    completer.complete();
    await Future.wait(<Future<void>>[firstInitialize, secondInitialize]);

    expect(initializeCallCount, 1);
  });

  test(
    'AmplitudeAppAnalytics initializes nothing on an empty api key',
    () async {
      var initializeCallCount = 0;
      var flushCallCount = 0;
      var trackedEventCount = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: '   ',
        initializer: (config) async {
          initializeCallCount += 1;
        },
        tracker: (eventName, props) async {
          trackedEventCount += 1;
        },
        flusher: () async {
          flushCallCount += 1;
        },
        identifier: (attributes) async {},
      );

      await service.initialize();

      service.trackAppStarted();
      await pumpEventQueue();
      // Flush always delegates; the shipped flusher no-ops when unconfigured.
      await service.flush();

      expect(initializeCallCount, 0);
      expect(trackedEventCount, 0);
      expect(flushCallCount, 1);
    },
  );

  test('AmplitudeAppAnalytics swallows tracker and flusher failures', () async {
    var trackerAttempts = 0;
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackerAttempts += 1;
        throw StateError('backend down');
      },
      flusher: () async {
        throw StateError('backend down');
      },
      identifier: (attributes) async {},
    );

    await service.initialize();

    await service.trackEventAsync('app_started', const <String, Object?>{
      'surface': 'desktop',
    });
    service.trackWorkspaceOpened(workspace: 'home');
    await service.flush();
    await pumpEventQueue();

    expect(trackerAttempts, 2);
  });

  test(
    'AmplitudeAppAnalytics swallows Exception tracker and flusher failures',
    () async {
      var trackerAttempts = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {
          trackerAttempts += 1;
          throw Exception('backend down');
        },
        flusher: () async {
          throw Exception('backend down');
        },
        identifier: (attributes) async {
          throw Exception('backend down');
        },
      );

      await service.initialize();

      await service.trackEventAsync('app_started', const <String, Object?>{
        'surface': 'desktop',
      });
      service.trackWorkspaceOpened(workspace: 'home');
      service.setUserAttribute(
        AppUserAttribute.hasFirstDeploySucceeded,
        'true',
      );
      await service.flush();
      await pumpEventQueue();

      expect(trackerAttempts, 2);
    },
  );

  test(
    'buildAmplitudeBackend stays dormant without an api key and never touches '
    'the network',
    () async {
      final service = buildAmplitudeBackend(apiKey: '');

      await service.initialize();
      service.trackAppStarted();
      await service.flush();
      await pumpEventQueue();
    },
  );

  test(
    'buildAmplitudeBackend drives the real SDK wiring without network',
    () async {
      final calls = <MethodCall>[];
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      debugDirectPluginFactory = () => _RecordingAmplitudePlugin(calls);
      try {
        final service = buildAmplitudeBackend(
          apiKey: 'test-api-key',
          distributionChannel: 'deb',
          hostArchitecture: 'linux_arm64',
        );
        await service.initialize();
        service.trackAppStarted();
        service.trackWorkspaceOpened(workspace: 'home');
        await service.flush();
        await pumpEventQueue();

        final identify = calls.singleWhere((call) => call.method == 'identify');
        final identifyEvent = (identify.arguments as Map)['event'] as Map;
        expect(identifyEvent['user_properties'], {
          r'$set': {'distribution': 'deb', 'arch': 'linux_arm64'},
        });

        final init = calls.singleWhere((call) => call.method == 'init');
        final initArgs = init.arguments as Map;
        expect(initArgs['apiKey'], 'test-api-key');
        expect(initArgs['serverZone'], 'eu');
        final trackingOptions = initArgs['trackingOptions'] as Map;
        expect(trackingOptions['ipAddress'], isTrue);
        expect(trackingOptions['city'], isTrue);

        final tracks = calls.where((call) => call.method == 'track').toList();
        expect(tracks, hasLength(2));
        Map<String, dynamic> eventProps(Map<Object?, Object?> arguments) {
          final event = arguments['event'] as Map<Object?, Object?>;
          return Map<String, dynamic>.from(
            event['event_properties'] as Map<Object?, Object?>,
          );
        }

        final firstEvent = (tracks[0].arguments as Map)['event'] as Map;
        expect(firstEvent['event_type'], 'app_started');
        final firstProps = eventProps(tracks[0].arguments as Map);
        expect(firstProps['surface'], 'desktop');
        expect(firstProps['lifecycle'], 'installed');
        final firstSession = firstProps['session_id'];
        expect(firstSession, isA<String>());
        expect((firstSession as String), isNotEmpty);
        final secondEvent = (tracks[1].arguments as Map)['event'] as Map;
        expect(secondEvent['event_type'], 'workspace_opened');
        final secondProps = eventProps(tracks[1].arguments as Map);
        expect(secondProps['workspace'], 'home');
        expect(
          secondProps['session_id'],
          firstSession,
          reason: 'one launch shares one session id',
        );

        expect(calls.where((call) => call.method == 'flush'), hasLength(1));
      } finally {
        resetDesktopDirectForTests();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  test(
    'buildAmplitudeBackend stays uninitialized when the SDK build fails',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      debugDirectPluginFactory = () => _FailingAmplitudePlugin();
      try {
        final service = buildAmplitudeBackend(apiKey: 'test-api-key');

        await expectLater(service.initialize(), throwsStateError);

        service.trackAppStarted();
        await pumpEventQueue();
      } finally {
        resetDesktopDirectForTests();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  test(
    'AmplitudeAppAnalytics stays uninitialized when the backend fails to build',
    () async {
      var initializeCallCount = 0;
      var trackedEventCount = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {
          initializeCallCount += 1;
          if (initializeCallCount == 1) {
            throw StateError('sdk build failed');
          }
        },
        tracker: (eventName, props) async {
          trackedEventCount += 1;
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      await expectLater(service.initialize(), throwsStateError);

      service.trackAppStarted();
      await pumpEventQueue();
      expect(trackedEventCount, 0);

      await service.initialize();
      service.trackAppStarted();
      await pumpEventQueue();
      expect(initializeCallCount, 2);
      expect(trackedEventCount, 1);
    },
  );

  test(
    'CompositeAppAnalytics fans out identical events to both backends',
    () async {
      final first = FakeAnalyticsService();
      final second = FakeAnalyticsService();
      final service = CompositeAppAnalytics(first: first, second: second);

      await service.initialize();
      service.trackAppStarted();
      service.trackWorkspaceOpened(
        workspace: 'home',
        entryPoint: 'rail',
        tab: 'servers',
      );

      expect(first.initializeCallCount, 1);
      expect(second.initializeCallCount, 1);
      expect(first.trackedEvents.map((event) => event.eventName), [
        'app_started',
        'workspace_opened',
      ]);
      expect(
        second.trackedEvents.map((event) => event.eventName),
        first.trackedEvents.map((event) => event.eventName),
      );
      for (var i = 0; i < first.trackedEvents.length; i++) {
        expect(second.trackedEvents[i].props, first.trackedEvents[i].props);
      }
    },
  );

  test('CompositeAppAnalytics isolates a throwing first backend', () async {
    final first = FakeAnalyticsService(
      throwOnInitialize: true,
      throwOnTrack: true,
    );
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    await service.initialize();
    service.trackAppStarted();

    expect(first.initializeCallCount, 1);
    expect(second.initializeCallCount, 1);
    expect(second.trackedEvents.map((event) => event.eventName), [
      'app_started',
    ]);
  });

  test(
    'CompositeAppAnalytics isolates an Exception-throwing backend',
    () async {
      final first = FakeAnalyticsService(
        throwOnInitialize: true,
        throwOnTrack: true,
        throwAsException: true,
      );
      final second = FakeAnalyticsService();
      final service = CompositeAppAnalytics(first: first, second: second);

      await service.initialize();
      service.trackAppStarted();

      expect(first.initializeCallCount, 1);
      expect(second.initializeCallCount, 1);
      expect(second.trackedEvents.map((event) => event.eventName), [
        'app_started',
      ]);
    },
  );

  test('CompositeAppAnalytics isolates a throwing second backend', () async {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService(
      throwOnInitialize: true,
      throwOnTrack: true,
    );
    final service = CompositeAppAnalytics(first: first, second: second);

    await service.initialize();
    service.trackAppStarted();

    expect(first.initializeCallCount, 1);
    expect(second.initializeCallCount, 1);
    expect(first.trackedEvents.map((event) => event.eventName), [
      'app_started',
    ]);
  });

  test('createAnalyticsService returns Aptabase-only without a key and a '
      'composite with one', () {
    expect(
      createAnalyticsService(amplitudeApiKey: ''),
      isA<AptabaseAppAnalytics>(),
    );
    expect(
      createAnalyticsService(amplitudeApiKey: 'test-key'),
      isA<CompositeAppAnalytics>(),
    );
  });

  test('resolveAmplitudeApiKey prefers the built-in define', () {
    expect(
      resolveAmplitudeApiKey(environmentValue: 'ci-key', isReleaseMode: false),
      'ci-key',
    );
    expect(
      resolveAmplitudeApiKey(environmentValue: 'ci-key', isReleaseMode: true),
      'ci-key',
    );
  });

  test(
    'resolveAmplitudeApiKey falls back to the shipped key in release only',
    () {
      expect(
        resolveAmplitudeApiKey(environmentValue: '', isReleaseMode: true),
        shippedAmplitudeApiKey,
      );
      expect(
        resolveAmplitudeApiKey(environmentValue: '', isReleaseMode: false),
        isEmpty,
      );
    },
  );

  test('buildAmplitudeBackend leaves observer autocapture off', () async {
    final calls = <MethodCall>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    debugDirectPluginFactory = () => _RecordingAmplitudePlugin(calls);
    try {
      final service = buildAmplitudeBackend(apiKey: 'test-api-key');
      await service.initialize();

      final init = calls.singleWhere((call) => call.method == 'init');
      final initArgs = init.arguments as Map;
      final autocapture = initArgs['autocapture'] as Map;

      // Task 3.11: no navigator observer is attached and screen-view
      // autocapture stays off, so navigation never emits outside the funnel,
      // past the init/enabled gates, or with open-vocabulary route names.
      // Aptabase 0.5.0 exposes no observer hook at all.
      expect(autocapture['screenViews'], isFalse);
    } finally {
      resetDesktopDirectForTests();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test(
    'CompositeAppAnalytics flush fans out to flushable children only',
    () async {
      final flushable = FlushableFakeAnalyticsService();
      final plain = FakeAnalyticsService();
      final service = CompositeAppAnalytics(first: flushable, second: plain);

      await service.flush();

      expect(flushable.flushCallCount, 1);
    },
  );

  test('CompositeAppAnalytics flush contains a throwing child', () async {
    final firstThrowing = FlushableFakeAnalyticsService(throwOnFlush: true);
    final secondThrowing = FlushableFakeAnalyticsService(throwOnFlush: true);
    final service = CompositeAppAnalytics(
      first: firstThrowing,
      second: secondThrowing,
    );

    await service.flush();

    expect(firstThrowing.flushCallCount, 1);
    expect(secondThrowing.flushCallCount, 1);
  });

  test(
    'CompositeAppAnalytics flush contains an Exception-throwing child',
    () async {
      final firstThrowing = FlushableFakeAnalyticsService(
        throwOnFlush: true,
        throwAsException: true,
      );
      final secondThrowing = FlushableFakeAnalyticsService(
        throwOnFlush: true,
        throwAsException: true,
      );
      final service = CompositeAppAnalytics(
        first: firstThrowing,
        second: secondThrowing,
      );

      await service.flush();

      expect(firstThrowing.flushCallCount, 1);
      expect(secondThrowing.flushCallCount, 1);
    },
  );

  test('flushAnalyticsOnClose flushes a flushable global and skips other '
      'services', () async {
    final flushable = FlushableFakeAnalyticsService();
    debugOverrideAppAnalyticsService(flushable);
    try {
      await flushAnalyticsOnClose();
      expect(flushable.flushCallCount, 1);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }

    final plain = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(plain);
    try {
      await flushAnalyticsOnClose();
    } finally {
      debugOverrideAppAnalyticsService(null);
    }

    final compositeFlushable = FlushableFakeAnalyticsService();
    debugOverrideAppAnalyticsService(
      CompositeAppAnalytics(
        first: compositeFlushable,
        second: FakeAnalyticsService(),
      ),
    );
    try {
      await flushAnalyticsOnClose();
      expect(compositeFlushable.flushCallCount, 1);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  test(
    'AmplitudeAppAnalytics sends the install channel once on init',
    () async {
      Map<String, String>? identified;
      var identifyCallCount = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        distributionChannel: 'deb',
        initializer: (config) async {},
        tracker: (eventName, props) async {},
        flusher: () async {},
        identifier: (attributes) async {
          identifyCallCount += 1;
          identified = attributes;
        },
      );

      await service.initialize();
      await pumpEventQueue();

      expect(identifyCallCount, 1);
      expect(identified, <String, String>{'distribution': 'deb'});
    },
  );

  test('AmplitudeAppAnalytics swallows Exception identify failures', () async {
    var identifyCallCount = 0;
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      distributionChannel: 'deb',
      initializer: (config) async {},
      tracker: (eventName, props) async {},
      flusher: () async {},
      identifier: (attributes) async {
        identifyCallCount += 1;
        throw Exception('backend down');
      },
    );

    await service.initialize();
    await pumpEventQueue();

    expect(identifyCallCount, 1);
  });

  test(
    'AmplitudeAppAnalytics passes every known install channel through',
    () async {
      const channels = [
        'apt',
        'deb',
        'dmg',
        'flatpak',
        'mac_app_store',
        'msi',
        'snap',
        'windows_store',
      ];
      for (final channel in channels) {
        Map<String, String>? identified;
        final service = AmplitudeAppAnalytics(
          apiKey: 'test-api-key',
          distributionChannel: channel,
          initializer: (config) async {},
          tracker: (eventName, props) async {},
          flusher: () async {},
          identifier: (attributes) async {
            identified = attributes;
          },
        );

        await service.initialize();
        await pumpEventQueue();

        expect(identified, <String, String>{
          'distribution': channel,
        }, reason: 'channel $channel');
      }
    },
  );

  test(
    'AmplitudeAppAnalytics omits empty and unknown install channels',
    () async {
      for (final channel in ['', '   ', 'side-loaded']) {
        var identifyCallCount = 0;
        final service = AmplitudeAppAnalytics(
          apiKey: 'test-api-key',
          distributionChannel: channel,
          initializer: (config) async {},
          tracker: (eventName, props) async {},
          flusher: () async {},
          identifier: (attributes) async {
            identifyCallCount += 1;
          },
        );

        await service.initialize();
        await pumpEventQueue();

        expect(identifyCallCount, 0, reason: 'channel "$channel"');
      }
    },
  );

  test('AmplitudeAppAnalytics reports channel and arch in one call', () async {
    Map<String, String>? identified;
    var identifyCallCount = 0;
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      distributionChannel: 'snap',
      hostArchitecture: 'windows_x64',
      initializer: (config) async {},
      tracker: (eventName, props) async {},
      flusher: () async {},
      identifier: (attributes) async {
        identifyCallCount += 1;
        identified = attributes;
      },
    );

    await service.initialize();
    await pumpEventQueue();

    expect(identifyCallCount, 1);
    expect(identified, <String, String>{
      'distribution': 'snap',
      'arch': 'windows_x64',
    });
  });

  test('AmplitudeAppAnalytics omits an empty host architecture', () async {
    var identifyCallCount = 0;
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      hostArchitecture: '   ',
      initializer: (config) async {},
      tracker: (eventName, props) async {},
      flusher: () async {},
      identifier: (attributes) async {
        identifyCallCount += 1;
      },
    );

    await service.initialize();
    await pumpEventQueue();

    expect(identifyCallCount, 0);
  });

  test('defaultHostArchitecture only yields closed values', () {
    expect(<String>{
      'linux_x64',
      'linux_arm64',
      'macos_x64',
      'macos_arm64',
      'windows_x64',
      'windows_arm64',
      '',
    }, contains(defaultHostArchitecture()));
  });

  test('AmplitudeAppAnalytics swallows install-channel failures', () async {
    var trackedEventCount = 0;
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      distributionChannel: 'snap',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEventCount += 1;
      },
      flusher: () async {},
      identifier: (attributes) async {
        throw StateError('backend down');
      },
    );

    await service.initialize();
    await pumpEventQueue();
    service.trackAppStarted();
    await pumpEventQueue();

    expect(trackedEventCount, 1);
  });

  test('AppUserAttribute maps every value to a storage key', () {
    expect(
      AppUserAttribute.hasCompletedOnboarding.storageKey,
      'has_completed_onboarding',
    );
    expect(
      AppUserAttribute.hasFirstDeploySucceeded.storageKey,
      'has_first_deploy_succeeded',
    );
    expect(
      AppUserAttribute.hasConnectedGitHub.storageKey,
      'has_connected_github',
    );
    expect(
      AppUserAttribute.serverCountBucket.storageKey,
      'server_count_bucket',
    );
    expect(
      AppUserAttribute.projectCountBucket.storageKey,
      'project_count_bucket',
    );
    expect(
      AppUserAttribute.deploysPerWeekBucket.storageKey,
      'deploys_per_week_bucket',
    );
  });

  test('analyticsBucketForCount saturates at three plus', () {
    expect(analyticsBucketForCount(-1), '0');
    expect(analyticsBucketForCount(0), '0');
    expect(analyticsBucketForCount(1), '1');
    expect(analyticsBucketForCount(2), '2');
    expect(analyticsBucketForCount(3), '3plus');
    expect(analyticsBucketForCount(4), '3plus');
    expect(analyticsBucketForCount(1000), '3plus');
  });

  test('AmplitudeAppAnalytics sets one user attribute per call', () async {
    final identified = <Map<String, String>>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {},
      flusher: () async {},
      identifier: (attributes) async {
        identified.add(attributes);
      },
    );

    await service.initialize();
    service.setUserAttribute(AppUserAttribute.hasCompletedOnboarding, 'true');
    await pumpEventQueue();

    expect(identified, [
      <String, String>{'has_completed_onboarding': 'true'},
    ]);
  });

  test(
    'AmplitudeAppAnalytics drops blank attributes and pre-init calls',
    () async {
      var identifyCallCount = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {},
        flusher: () async {},
        identifier: (attributes) async {
          identifyCallCount += 1;
        },
      );

      service.setUserAttribute(
        AppUserAttribute.hasFirstDeploySucceeded,
        'true',
      );
      await service.initialize();
      await pumpEventQueue();
      service.setUserAttribute(AppUserAttribute.hasFirstDeploySucceeded, '   ');
      service.setUserAttribute(AppUserAttribute.hasFirstDeploySucceeded, '');
      await pumpEventQueue();

      expect(identifyCallCount, 0);
    },
  );

  test('AmplitudeAppAnalytics swallows attribute failures', () async {
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {},
      flusher: () async {},
      identifier: (attributes) async {
        throw StateError('backend down');
      },
    );

    await service.initialize();
    service.setUserAttribute(AppUserAttribute.hasFirstDeploySucceeded, 'true');
    await pumpEventQueue();
  });

  test('AptabaseAppAnalytics ignores user attributes', () async {
    var trackedEventCount = 0;
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) async {
        trackedEventCount += 1;
      },
    );

    await service.initialize();
    service.setUserAttribute(AppUserAttribute.hasCompletedOnboarding, 'true');

    expect(trackedEventCount, 0);
  });

  test('CompositeAppAnalytics fans out user attributes', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.setUserAttribute(AppUserAttribute.hasFirstDeploySucceeded, 'true');

    for (final backend in [first, second]) {
      expect(backend.userAttributes, [
        (attribute: AppUserAttribute.hasFirstDeploySucceeded, value: 'true'),
      ]);
    }
  });

  test('tenureBucketFor buckets install age and rejects clock skew', () {
    final now = DateTime(2026, 9, 7, 12);
    // Days since first launch to expected bucket. Negative means the launch
    // date lies in the future (clock skew) and must yield no bucket.
    const cases = <int, String>{
      -1: '',
      0: 'new_7d',
      6: 'new_7d',
      7: 'active_30d',
      29: 'active_30d',
      30: 'established',
      365: 'established',
    };
    for (final entry in cases.entries) {
      expect(
        tenureBucketFor(
          firstLaunchAt: now.subtract(Duration(days: entry.key)),
          now: now,
        ),
        entry.value,
        reason: '${entry.key} days',
      );
    }
  });

  test('lifecycleStageFor walks installed to habitual in order', () {
    expect(
      lifecycleStageFor(
        onboarded: false,
        firstDeploySucceeded: false,
        tenureBucket: 'new_7d',
      ),
      'installed',
    );
    expect(
      lifecycleStageFor(
        onboarded: true,
        firstDeploySucceeded: false,
        tenureBucket: 'established',
      ),
      'onboarded',
    );
    expect(
      lifecycleStageFor(
        onboarded: true,
        firstDeploySucceeded: true,
        tenureBucket: 'new_7d',
      ),
      'first_deploy',
    );
    expect(
      lifecycleStageFor(
        onboarded: true,
        firstDeploySucceeded: true,
        tenureBucket: 'established',
      ),
      'habitual',
    );
    expect(
      lifecycleStageFor(
        onboarded: false,
        firstDeploySucceeded: true,
        tenureBucket: 'established',
      ),
      'installed',
      reason: 'onboarding gates every later stage',
    );
  });

  test('AmplitudeAppAnalytics merges context under event properties', () async {
    final tracked = <Map<String, dynamic>?>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      context: AnalyticsEventContext(
        firstLaunchAt: DateTime(2026, 8, 1, 12),
        clock: () => DateTime(2026, 9, 7, 12),
        completedMilestones: {
          AppUserAttribute.hasCompletedOnboarding,
          AppUserAttribute.hasFirstDeploySucceeded,
        },
        sessionId: 'session-1',
      ),
      initializer: (config) async {},
      tracker: (eventName, props) async {
        tracked.add(props);
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    await service.trackEventAsync('app_started', const <String, Object?>{
      'surface': 'desktop',
      'tenure': 'forged',
    });
    await pumpEventQueue();

    expect(tracked, hasLength(1));
    expect(tracked.single, {
      'tenure': 'forged',
      'lifecycle': 'habitual',
      'session_id': 'session-1',
      'surface': 'desktop',
    });
  });

  test(
    'AmplitudeAppAnalytics omits context with no context configured',
    () async {
      final tracked = <Map<String, dynamic>?>[];
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {
          tracked.add(props);
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      await service.initialize();
      await service.trackEventAsync('app_started', const <String, Object?>{
        'surface': 'desktop',
      });
      await pumpEventQueue();

      expect(tracked.single, {'surface': 'desktop'});
    },
  );

  test('AptabaseAppAnalytics merges the same context envelope', () async {
    final tracked = <Map<String, dynamic>?>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      context: AnalyticsEventContext(
        firstLaunchAt: DateTime(2026, 8, 1, 12),
        clock: () => DateTime(2026, 9, 7, 12),
        completedMilestones: {AppUserAttribute.hasCompletedOnboarding},
        sessionId: 'session-9',
      ),
      initializer: (appKey, options) async {},
      tracker: (eventName, props) async {
        tracked.add(props);
      },
    );

    await service.initialize();
    service.trackAppStarted();

    expect(tracked.single, {
      'lifecycle': 'onboarded',
      'tenure': 'established',
      'session_id': 'session-9',
      'surface': 'desktop',
    });
  });

  test('AnalyticsEventContext defaults lifecycle with session only', () async {
    final tracked = <Map<String, dynamic>?>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      context: const AnalyticsEventContext(sessionId: 'session-2'),
      initializer: (config) async {},
      tracker: (eventName, props) async {
        tracked.add(props);
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    await service.trackEventAsync('app_started', const <String, Object?>{
      'surface': 'desktop',
    });
    await pumpEventQueue();

    expect(tracked.single, {
      'lifecycle': 'installed',
      'session_id': 'session-2',
      'surface': 'desktop',
    });
  });

  test('generateAnalyticsSessionId yields opaque unique ids', () {
    final first = generateAnalyticsSessionId();
    final second = generateAnalyticsSessionId();
    expect(first, isNotEmpty);
    expect(first, isNot(second));
    expect(first, matches(RegExp(r'^[0-9a-z]+-[0-9a-f]{8}$')));
  });

  test(
    'buildAmplitudeBackend resolves production values into its context',
    () async {
      final tracked = <Map<String, dynamic>?>[];
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        context: AnalyticsEventContext(
          // 2026-08-01 is established tenure for every wall-clock date the
          // suite will ever run under, so no clock seam is needed here.
          firstLaunchAt: DateTime(2026, 8, 1, 12),
          completedMilestones: {AppUserAttribute.hasCompletedOnboarding},
          sessionId: 'session-7',
        ),
        initializer: (config) async {},
        tracker: (eventName, props) async {
          tracked.add(props);
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      await service.initialize();
      await service.trackEventAsync('app_started', const <String, Object?>{
        'surface': 'desktop',
      });
      await pumpEventQueue();

      expect(tracked.single, {
        'lifecycle': 'onboarded',
        'tenure': 'established',
        'session_id': 'session-7',
        'surface': 'desktop',
      });
    },
  );

  test(
    'AmplitudeAppAnalytics.updateContext keeps the launch session',
    () async {
      final tracked = <Map<String, dynamic>?>[];
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        context: const AnalyticsEventContext(sessionId: 'keep-me'),
        initializer: (config) async {},
        tracker: (eventName, props) async {
          tracked.add(props);
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      await service.initialize();
      service.updateContext(
        firstLaunchAt: DateTime(2026, 8, 1, 12),
        completedMilestones: {
          AppUserAttribute.hasCompletedOnboarding,
          AppUserAttribute.hasFirstDeploySucceeded,
        },
      );
      await service.trackEventAsync('app_started', const <String, Object?>{
        'surface': 'desktop',
      });
      await pumpEventQueue();

      expect(tracked.single?['session_id'], 'keep-me');
      expect(tracked.single?['lifecycle'], 'habitual');

      // Null arguments leave the current values in place.
      service.updateContext();
      await service.trackEventAsync('app_started', const <String, Object?>{
        'surface': 'desktop',
      });
      await pumpEventQueue();

      expect(tracked, hasLength(2));
      expect(tracked[1]?['session_id'], 'keep-me');
      expect(tracked[1]?['lifecycle'], 'habitual');
    },
  );

  test('AptabaseAppAnalytics.updateContext keeps the launch session', () async {
    final tracked = <Map<String, dynamic>?>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      context: const AnalyticsEventContext(sessionId: 'keep-me-too'),
      initializer: (appKey, options) async {},
      tracker: (eventName, props) async {
        tracked.add(props);
      },
    );

    await service.initialize();
    service.updateContext(
      completedMilestones: {AppUserAttribute.hasCompletedOnboarding},
    );
    service.trackAppStarted();

    expect(tracked.single, {
      'lifecycle': 'onboarded',
      'session_id': 'keep-me-too',
      'surface': 'desktop',
    });
  });

  test(
    'CompositeAppAnalytics.updateContexts fans out and skips plain backs',
    () async {
      final tracked = <Map<String, dynamic>?>[];
      final updatable = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        context: const AnalyticsEventContext(sessionId: 'session-a'),
        initializer: (config) async {},
        tracker: (eventName, props) async {
          tracked.add(props);
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );
      final plain = FakeAnalyticsService();
      final service = CompositeAppAnalytics(first: updatable, second: plain);

      await service.initialize();
      service.updateContexts(
        completedMilestones: {AppUserAttribute.hasCompletedOnboarding},
      );
      await updatable.trackEventAsync('app_started', const <String, Object?>{
        'surface': 'desktop',
      });
      await pumpEventQueue();

      expect(tracked.single?['session_id'], 'session-a');
      expect(tracked.single?['lifecycle'], 'onboarded');
    },
  );

  test(
    'refreshAnalyticsContext hydrates both backends from the store',
    () async {
      final amplitudeTracked = <Map<String, dynamic>?>[];
      final aptabaseTracked = <Map<String, dynamic>?>[];
      final amplitude = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        context: const AnalyticsEventContext(sessionId: 'launch-session'),
        initializer: (config) async {},
        tracker: (eventName, props) async {
          amplitudeTracked.add(props);
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );
      final aptabase = AptabaseAppAnalytics(
        appKey: 'test-app-key',
        context: const AnalyticsEventContext(sessionId: 'launch-session'),
        initializer: (appKey, options) async {},
        tracker: (eventName, props) async {
          aptabaseTracked.add(props);
        },
      );
      debugOverrideAppAnalyticsService(
        CompositeAppAnalytics(first: amplitude, second: aptabase),
      );
      try {
        await amplitude.initialize();
        await aptabase.initialize();
        await refreshAnalyticsContext(
          _FakeAnalyticsContextStore(
            firstLaunchAt: DateTime(2026, 8, 1, 12),
            milestones: {AppUserAttribute.hasCompletedOnboarding},
          ),
        );

        amplitude.trackAppStarted();
        aptabase.trackAppStarted();
        await pumpEventQueue();

        for (final tracked in [amplitudeTracked, aptabaseTracked]) {
          expect(tracked.single?['lifecycle'], 'onboarded');
          expect(tracked.single?['tenure'], 'established');
          expect(tracked.single?['session_id'], 'launch-session');
        }
      } finally {
        debugOverrideAppAnalyticsService(null);
      }
    },
  );

  test('refreshAnalyticsContext swallows store failures', () async {
    var trackedEventCount = 0;
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEventCount += 1;
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );
    debugOverrideAppAnalyticsService(service);
    try {
      await service.initialize();
      await refreshAnalyticsContext(
        _FakeAnalyticsContextStore(throwOnRead: true),
      );

      service.trackAppStarted();
      await pumpEventQueue();

      expect(trackedEventCount, 1);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  test('refreshAnalyticsContext lets programming errors propagate', () async {
    await expectLater(
      refreshAnalyticsContext(
        _FakeAnalyticsContextStore(throwErrorOnRead: true),
      ),
      throwsArgumentError,
    );
  });

  test('refreshAnalyticsContext swallows Exception store failures', () async {
    var trackedEventCount = 0;
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEventCount += 1;
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );
    debugOverrideAppAnalyticsService(service);
    try {
      await service.initialize();
      await refreshAnalyticsContext(
        _FakeAnalyticsContextStore(throwExceptionOnRead: true),
      );

      service.trackAppStarted();
      await pumpEventQueue();

      expect(trackedEventCount, 1);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  test(
    'refreshAnalyticsContext skips backends without stored context',
    () async {
      final plain = FakeAnalyticsService();
      debugOverrideAppAnalyticsService(plain);
      try {
        await refreshAnalyticsContext(_FakeAnalyticsContextStore());
      } finally {
        debugOverrideAppAnalyticsService(null);
      }
    },
  );

  test('context store reads identity date and milestone flags', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final preferences = AppPreferencesRepository(database);
    await preferences.recordAnalyticsMilestone(
      AppUserAttribute.hasCompletedOnboarding,
      reachedAt: DateTime.utc(2026, 9, 1, 12),
    );
    final store = AppDatabaseAnalyticsContextStore(
      preferences: preferences,
      loadIdentity: () async => DeviceIdentity(
        id: 'test-installation',
        createdAt: DateTime(2026, 8, 1, 12),
      ),
    );

    expect(await store.readFirstLaunchAt(), DateTime(2026, 8, 1, 12));
    expect(await store.readMilestones(), {
      AppUserAttribute.hasCompletedOnboarding,
    });

    await store.recordMilestone(AppUserAttribute.hasFirstDeploySucceeded);
    await store.recordMilestone(AppUserAttribute.hasConnectedGitHub);
    expect(await store.readMilestones(), {
      AppUserAttribute.hasCompletedOnboarding,
      AppUserAttribute.hasFirstDeploySucceeded,
      AppUserAttribute.hasConnectedGitHub,
    });

    // Recording through the store a second time is a write-once no-op.
    await store.recordMilestone(AppUserAttribute.hasCompletedOnboarding);
    expect(await store.readMilestones(), {
      AppUserAttribute.hasCompletedOnboarding,
      AppUserAttribute.hasFirstDeploySucceeded,
      AppUserAttribute.hasConnectedGitHub,
    });
  }, skip: !sqliteAvailable);

  test('context store degrades each source independently', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final store = AppDatabaseAnalyticsContextStore(
      preferences: AppPreferencesRepository(database),
      loadIdentity: () async => DeviceIdentity(
        id: 'test-installation',
        createdAt: DateTime(2026, 8, 1, 12),
      ),
    );
    // Open the connection first: closing an unopened database is a no-op
    // and the next read would simply open it fresh.
    expect(await store.readMilestones(), isEmpty);
    await database.close();

    // The identity file outlives the database lock state: the date survives
    // a closed database while the flags degrade to unknown.
    expect(await store.readFirstLaunchAt(), DateTime(2026, 8, 1, 12));
    expect(await store.readMilestones(), isNull);
  }, skip: !sqliteAvailable);

  test('context store omits the date when identity loading fails', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final store = AppDatabaseAnalyticsContextStore(
      preferences: AppPreferencesRepository(database),
      loadIdentity: () async =>
          throw const FileSystemException('identity unwritable'),
    );

    expect(await store.readFirstLaunchAt(), isNull);
    expect(await store.readMilestones(), isEmpty);
  }, skip: !sqliteAvailable);

  test('context store lets programming errors propagate', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final store = AppDatabaseAnalyticsContextStore(
      preferences: AppPreferencesRepository(database),
      loadIdentity: () async => throw ArgumentError('corrupt identity'),
    );

    await expectLater(store.readFirstLaunchAt(), throwsArgumentError);
  }, skip: !sqliteAvailable);

  test(
    'context store degrades to unknown on Exception identity faults',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final store = AppDatabaseAnalyticsContextStore(
        preferences: AppPreferencesRepository(database),
        loadIdentity: () async => throw Exception('identity unreadable'),
      );

      expect(await store.readFirstLaunchAt(), isNull);
    },
    skip: !sqliteAvailable,
  );

  test(
    'context store degrades to unknown on StateError identity faults',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final store = AppDatabaseAnalyticsContextStore(
        preferences: AppPreferencesRepository(database),
        loadIdentity: () async => throw StateError('identity gone'),
      );

      expect(await store.readFirstLaunchAt(), isNull);
    },
    skip: !sqliteAvailable,
  );

  test(
    'context store degrades to unknown on Exception preference faults',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final store = AppDatabaseAnalyticsContextStore(
        preferences: _ThrowingExceptionPreferences(database),
        loadIdentity: () async => DeviceIdentity(
          id: 'test-installation',
          createdAt: DateTime(2026, 8, 1, 12),
        ),
      );

      expect(await store.readMilestones(), isNull);
    },
    skip: !sqliteAvailable,
  );

  test(
    'hydrateAnalyticsContext fills the live backends from providers',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final preferences = AppPreferencesRepository(database);
      await preferences.recordAnalyticsMilestone(
        AppUserAttribute.hasCompletedOnboarding,
        reachedAt: DateTime.utc(2026, 9, 1),
      );
      final tracked = <Map<String, dynamic>?>[];
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        context: const AnalyticsEventContext(sessionId: 's-hydrate'),
        initializer: (config) async {},
        tracker: (eventName, props) async {
          tracked.add(props);
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );
      debugOverrideAppAnalyticsService(service);
      try {
        await service.initialize();
        await hydrateAnalyticsContext(
          preferences: preferences,
          loadIdentity: () async => DeviceIdentity(
            id: 'test-installation',
            createdAt: DateTime(2026, 8, 1, 12),
          ),
        );

        service.trackAppStarted();
        await pumpEventQueue();

        expect(tracked.single?['lifecycle'], 'onboarded');
        expect(tracked.single?['tenure'], 'established');
        expect(tracked.single?['session_id'], 's-hydrate');
      } finally {
        debugOverrideAppAnalyticsService(null);
      }
    },
    skip: !sqliteAvailable,
  );

  test('hydrateAnalyticsContext never throws on a closed database', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final preferences = AppPreferencesRepository(database);
    // Open the connection first: closing an unopened database is a no-op.
    expect(await preferences.read(), isA<AppPreferencesRecord>());
    await database.close();

    await hydrateAnalyticsContext(
      preferences: preferences,
      loadIdentity: () async =>
          throw const FileSystemException('identity unwritable'),
    );
  }, skip: !sqliteAvailable);

  test('UnlockFailureReason maps every value to a storage key', () {
    expect(UnlockFailureReason.authFailed.storageKey, 'auth_failed');
    expect(UnlockFailureReason.dbMissing.storageKey, 'db_missing');
    expect(UnlockFailureReason.dbCorrupt.storageKey, 'db_corrupt');
  });

  test('AmplitudeAppAnalytics reports unlock failures with reasons', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackUnlockFailed(reason: UnlockFailureReason.authFailed);
    await pumpEventQueue();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'unlock_failed');
    expect(trackedEvents.single.props?['reason'], 'auth_failed');
  });

  test('AptabaseAppAnalytics reports unlock failures with reasons', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackUnlockFailed(reason: UnlockFailureReason.dbCorrupt);

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'unlock_failed');
    expect(trackedEvents.single.props?['reason'], 'db_corrupt');
  });

  test('CompositeAppAnalytics fans out unlock failures', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackUnlockFailed(reason: UnlockFailureReason.dbMissing);

    for (final backend in [first, second]) {
      expect(backend.unlockFailures, [UnlockFailureReason.dbMissing]);
    }
  });

  test('GitHubOAuthStage maps every value to a storage key', () {
    expect(GitHubOAuthStage.started.storageKey, 'started');
    expect(GitHubOAuthStage.completed.storageKey, 'completed');
    expect(GitHubOAuthStage.failed.storageKey, 'failed');
  });

  test('AmplitudeAppAnalytics reports GitHub OAuth stages', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackGitHubOAuth(stage: GitHubOAuthStage.started);
    service.trackGitHubOAuth(stage: GitHubOAuthStage.completed);
    await pumpEventQueue();

    expect(trackedEvents.map((event) => event.eventName), [
      'github_oauth',
      'github_oauth',
    ]);
    expect(trackedEvents[0].props?['stage'], 'started');
    expect(trackedEvents[1].props?['stage'], 'completed');
  });

  test(
    'AmplitudeAppAnalytics drops OAuth stages before initialization',
    () async {
      var trackedEventCount = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {
          trackedEventCount += 1;
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      service.trackGitHubOAuth(stage: GitHubOAuthStage.started);
      await pumpEventQueue();

      expect(trackedEventCount, 0);
    },
  );

  test('AptabaseAppAnalytics reports GitHub OAuth stages', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackGitHubOAuth(stage: GitHubOAuthStage.failed);

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'github_oauth');
    expect(trackedEvents.single.props?['stage'], 'failed');
  });

  test('CompositeAppAnalytics fans out GitHub OAuth stages', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackGitHubOAuth(stage: GitHubOAuthStage.started);
    service.trackGitHubOAuth(stage: GitHubOAuthStage.completed);

    for (final backend in [first, second]) {
      expect(backend.oauthStages, [
        GitHubOAuthStage.started,
        GitHubOAuthStage.completed,
      ]);
    }
  });

  test('CompositeAppAnalytics isolates a throwing OAuth backend', () {
    final first = FakeAnalyticsService(throwOnTrack: true);
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackGitHubOAuth(stage: GitHubOAuthStage.failed);

    expect(first.oauthStages, isEmpty);
    expect(second.oauthStages, [GitHubOAuthStage.failed]);
  });

  test('OnboardingStep maps every value to a storage key', () {
    expect(
      <OnboardingStep, String>{
        for (final step in OnboardingStep.values) step: step.storageKey,
      },
      <OnboardingStep, String>{
        OnboardingStep.bootstrap: 'bootstrap',
        OnboardingStep.ubuntuLoginVerified: 'ubuntu_login_verified',
        OnboardingStep.sshHardened: 'ssh_hardened',
        OnboardingStep.firewallBaselined: 'firewall_baselined',
        OnboardingStep.fail2ban: 'fail2ban',
        OnboardingStep.autoUpdates: 'auto_updates',
        OnboardingStep.dockerPinned: 'docker_pinned',
        OnboardingStep.railpackPinned: 'railpack_pinned',
        OnboardingStep.ownershipHandoff: 'ownership_handoff',
        OnboardingStep.hostkeyMismatch: 'hostkey_mismatch',
        OnboardingStep.completed: 'completed',
        OnboardingStep.abandoned: 'abandoned',
      },
    );
  });

  test('AmplitudeAppAnalytics reports onboarding steps', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackOnboardingStep(
      step: OnboardingStep.sshHardened,
      succeeded: false,
      attempt: 2,
    );
    await pumpEventQueue();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'onboarding_step');
    expect(trackedEvents.single.props?['step'], 'ssh_hardened');
    expect(trackedEvents.single.props?['succeeded'], 'false');
    expect(trackedEvents.single.props?['attempt'], 2);
  });

  test(
    'AmplitudeAppAnalytics drops onboarding steps before initialization',
    () async {
      var trackedEventCount = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {
          trackedEventCount += 1;
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      service.trackOnboardingStep(
        step: OnboardingStep.bootstrap,
        succeeded: true,
      );
      await pumpEventQueue();

      expect(trackedEventCount, 0);
    },
  );

  test('AptabaseAppAnalytics reports onboarding steps', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackOnboardingStep(
      step: OnboardingStep.completed,
      succeeded: true,
    );

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'onboarding_step');
    expect(trackedEvents.single.props?['step'], 'completed');
    expect(trackedEvents.single.props?['succeeded'], 'true');
    expect(trackedEvents.single.props?['attempt'], 1);
  });

  test('CompositeAppAnalytics fans out onboarding steps', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackOnboardingStep(
      step: OnboardingStep.dockerPinned,
      succeeded: true,
      attempt: 3,
    );

    for (final backend in [first, second]) {
      expect(backend.onboardingSteps, [
        (step: OnboardingStep.dockerPinned, succeeded: true, attempt: 3),
      ]);
    }
  });

  test('CompositeAppAnalytics isolates a throwing onboarding backend', () {
    final first = FakeAnalyticsService(throwOnTrack: true);
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackOnboardingStep(
      step: OnboardingStep.bootstrap,
      succeeded: false,
    );

    expect(first.onboardingSteps, isEmpty);
    expect(second.onboardingSteps, [
      (step: OnboardingStep.bootstrap, succeeded: false, attempt: 1),
    ]);
  });

  test('AmplitudeAppAnalytics reports onboarding started', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackOnboardingStarted();
    await pumpEventQueue();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'onboarding_started');
    expect(trackedEvents.single.props?['surface'], 'desktop');
  });

  test('AptabaseAppAnalytics reports onboarding started', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackOnboardingStarted();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'onboarding_started');
    expect(trackedEvents.single.props?['surface'], 'desktop');
  });

  test('CompositeAppAnalytics fans out onboarding started', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackOnboardingStarted();

    for (final backend in [first, second]) {
      expect(backend.onboardingStartedCallCount, 1);
    }
  });

  test('AmplitudeAppAnalytics reports enrollment success', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackEnrollment(outcome: DataOperationOutcome.success);
    await pumpEventQueue();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'enrollment');
    expect(trackedEvents.single.props?['outcome'], 'success');
  });

  test('AptabaseAppAnalytics reports enrollment failure', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackEnrollment(outcome: DataOperationOutcome.failure);

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'enrollment');
    expect(trackedEvents.single.props?['outcome'], 'failure');
  });

  test('CompositeAppAnalytics fans out enrollment outcomes', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackEnrollment(outcome: DataOperationOutcome.failure);

    for (final backend in [first, second]) {
      expect(backend.enrollmentOutcomes, [DataOperationOutcome.failure]);
    }
  });

  test(
    'AmplitudeAppAnalytics reports setup incomplete with its attempt',
    () async {
      final trackedEvents =
          <({String eventName, Map<String, dynamic>? props})>[];
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {
          trackedEvents.add((eventName: eventName, props: props));
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      await service.initialize();
      service.trackSetupIncomplete(attempt: 2);
      await pumpEventQueue();

      expect(trackedEvents, hasLength(1));
      expect(trackedEvents.single.eventName, 'setup_incomplete');
      expect(trackedEvents.single.props?['attempt'], 2);
    },
  );

  test(
    'AptabaseAppAnalytics reports setup incomplete with its attempt',
    () async {
      final trackedEvents =
          <({String eventName, Map<String, dynamic>? props})>[];
      final service = AptabaseAppAnalytics(
        appKey: 'test-app-key',
        initializer: (appKey, options) async {},
        tracker: (eventName, props) {
          trackedEvents.add((eventName: eventName, props: props));
        },
      );

      await service.initialize();
      service.trackSetupIncomplete(attempt: 1);

      expect(trackedEvents, hasLength(1));
      expect(trackedEvents.single.eventName, 'setup_incomplete');
      expect(trackedEvents.single.props?['attempt'], 1);
    },
  );

  test('CompositeAppAnalytics fans out setup incomplete rows', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackSetupIncomplete(attempt: 3);

    for (final backend in [first, second]) {
      expect(backend.setupIncompleteAttempts, [3]);
    }
  });

  test('AmplitudeAppAnalytics reports setup resumed', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackSetupResumed();
    await pumpEventQueue();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'setup_resumed');
    expect(trackedEvents.single.props, isNull);
  });

  test('AptabaseAppAnalytics reports setup resumed', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackSetupResumed();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'setup_resumed');
    expect(trackedEvents.single.props, isNull);
  });

  test('CompositeAppAnalytics fans out setup resumed', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackSetupResumed();

    for (final backend in [first, second]) {
      expect(backend.setupResumedCallCount, 1);
    }
  });

  test('DeployProvider maps every value to a storage key', () {
    expect(
      <DeployProvider, String>{
        for (final provider in DeployProvider.values)
          provider: provider.storageKey,
      },
      <DeployProvider, String>{
        DeployProvider.node: 'node',
        DeployProvider.python: 'python',
        DeployProvider.php: 'php',
        DeployProvider.ruby: 'ruby',
        DeployProvider.golang: 'golang',
        DeployProvider.java: 'java',
        DeployProvider.rust: 'rust',
        DeployProvider.dotnet: 'dotnet',
        DeployProvider.deno: 'deno',
        DeployProvider.elixir: 'elixir',
        DeployProvider.shell: 'shell',
        DeployProvider.staticfile: 'staticfile',
        DeployProvider.autoDetect: 'auto_detect',
      },
    );
  });

  test('DeployStage maps every value to a storage key', () {
    expect(
      <DeployStage, String>{
        for (final stage in DeployStage.values) stage: stage.storageKey,
      },
      <DeployStage, String>{
        DeployStage.probe: 'probe',
        DeployStage.cutover: 'cutover',
        DeployStage.stabilize: 'stabilize',
      },
    );
  });

  test('DeployOutcome maps every value to a storage key', () {
    expect(
      <DeployOutcome, String>{
        for (final outcome in DeployOutcome.values) outcome: outcome.storageKey,
      },
      <DeployOutcome, String>{
        DeployOutcome.success: 'success',
        DeployOutcome.failure: 'failure',
        DeployOutcome.rolledBack: 'rolled_back',
        DeployOutcome.cancelled: 'cancelled',
      },
    );
  });

  test('AmplitudeAppAnalytics reports deploy events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackDeployEvent(
      provider: DeployProvider.python,
      routingMode: 'single_host',
      stage: DeployStage.cutover,
      outcome: DeployOutcome.rolledBack,
      durationSeconds: 87,
    );
    await pumpEventQueue();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'deploy_event');
    expect(trackedEvents.single.props?['provider'], 'python');
    expect(trackedEvents.single.props?['routing_mode'], 'single_host');
    expect(trackedEvents.single.props?['stage'], 'cutover');
    expect(trackedEvents.single.props?['outcome'], 'rolled_back');
    expect(trackedEvents.single.props?['duration_seconds'], 87);
  });

  test(
    'AmplitudeAppAnalytics drops deploy events before initialization',
    () async {
      var trackedEventCount = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {
          trackedEventCount += 1;
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      service.trackDeployEvent(
        provider: DeployProvider.node,
        routingMode: 'single_host',
        stage: DeployStage.stabilize,
        outcome: DeployOutcome.success,
        durationSeconds: 12,
      );
      await pumpEventQueue();

      expect(trackedEventCount, 0);
    },
  );

  test('AptabaseAppAnalytics reports deploy events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackDeployEvent(
      provider: DeployProvider.node,
      routingMode: 'single_host',
      stage: DeployStage.stabilize,
      outcome: DeployOutcome.success,
    );
    service.trackDeployEvent(
      provider: DeployProvider.node,
      routingMode: 'single_host',
      stage: DeployStage.stabilize,
      outcome: DeployOutcome.success,
      durationSeconds: 45,
    );

    expect(trackedEvents, hasLength(2));
    expect(trackedEvents[0].eventName, 'deploy_event');
    expect(trackedEvents[0].props?['provider'], 'node');
    expect(trackedEvents[0].props?['routing_mode'], 'single_host');
    expect(trackedEvents[0].props?['stage'], 'stabilize');
    expect(trackedEvents[0].props?['outcome'], 'success');
    expect(trackedEvents[0].props?.containsKey('duration_seconds'), isFalse);
    expect(trackedEvents[1].eventName, 'deploy_event');
    expect(trackedEvents[1].props?['duration_seconds'], 45);
  });

  test('CompositeAppAnalytics fans out deploy events', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackDeployEvent(
      provider: DeployProvider.staticfile,
      routingMode: 'redirect_www_to_apex',
      stage: DeployStage.probe,
      outcome: DeployOutcome.failure,
      durationSeconds: 5,
    );

    for (final backend in [first, second]) {
      expect(backend.deployEvents, [
        (
          provider: DeployProvider.staticfile,
          routingMode: 'redirect_www_to_apex',
          stage: DeployStage.probe,
          outcome: DeployOutcome.failure,
          durationSeconds: 5,
        ),
      ]);
    }
  });

  test('CompositeAppAnalytics isolates a throwing deploy backend', () {
    final first = FakeAnalyticsService(throwOnTrack: true);
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackDeployEvent(
      provider: DeployProvider.node,
      routingMode: 'single_host',
      stage: DeployStage.cutover,
      outcome: DeployOutcome.cancelled,
    );

    expect(first.deployEvents, isEmpty);
    expect(second.deployEvents, [
      (
        provider: DeployProvider.node,
        routingMode: 'single_host',
        stage: DeployStage.cutover,
        outcome: DeployOutcome.cancelled,
        durationSeconds: null,
      ),
    ]);
  });

  test('deploy failure analytics uses closed metadata and count buckets', () {
    expect(
      deployFailureAnalyticsProperties(
        phase: DeployFailurePhase.build,
        source: DeployFailureSource.failedOperation,
        completeness: DeployFailureCompleteness.diagnostic,
        lineCount: 0,
        agentInitiated: false,
      ),
      <String, Object?>{
        'phase': 'build',
        'source': 'failed_operation',
        'completeness': 'diagnostic',
        'line_count_bucket': '0',
        'actor': 'local_user',
      },
    );
    expect(
      <String>[
        for (final count in <int>[1, 3, 4, 6, 7, 12, 99])
          deployFailureAnalyticsProperties(
                phase: DeployFailurePhase.unknown,
                source: DeployFailureSource.unknown,
                completeness: DeployFailureCompleteness.unknown,
                lineCount: count,
                agentInitiated: true,
              )['line_count_bucket']!
              as String,
      ],
      <String>['1_3', '1_3', '4_6', '4_6', '7_12', '7_12', '7_12'],
    );
    expect(
      deployFailureAnalyticsProperties(
        phase: DeployFailurePhase.unknown,
        source: DeployFailureSource.unknown,
        completeness: DeployFailureCompleteness.unknown,
        lineCount: 1,
        agentInitiated: true,
      ),
      containsPair('actor', 'agent'),
    );
  });

  test('AptabaseAppAnalytics reports safe deploy failure metadata', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackDeployFailureEvidence(
      phase: DeployFailurePhase.candidateReadiness,
      source: DeployFailureSource.candidateProbe,
      completeness: DeployFailureCompleteness.diagnostic,
      lineCount: 2,
      agentInitiated: false,
    );

    expect(trackedEvents.single.eventName, 'deploy_failure_evidence');
    expect(trackedEvents.single.props, <String, dynamic>{
      'phase': 'candidate_readiness',
      'source': 'candidate_probe',
      'completeness': 'diagnostic',
      'line_count_bucket': '1_3',
      'actor': 'local_user',
    });
  });

  test('AmplitudeAppAnalytics reports safe deploy failure metadata', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackDeployFailureEvidence(
      phase: DeployFailurePhase.rollback,
      source: DeployFailureSource.exception,
      completeness: DeployFailureCompleteness.boundaryOnly,
      lineCount: 0,
      agentInitiated: true,
    );
    await pumpEventQueue();

    expect(trackedEvents.single.eventName, 'deploy_failure_evidence');
    expect(trackedEvents.single.props, <String, dynamic>{
      'phase': 'rollback',
      'source': 'exception',
      'completeness': 'boundary_only',
      'line_count_bucket': '0',
      'actor': 'agent',
    });
  });

  test('CompositeAppAnalytics fans out safe deploy failure metadata', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackDeployFailureEvidence(
      phase: DeployFailurePhase.engine,
      source: DeployFailureSource.none,
      completeness: DeployFailureCompleteness.unavailable,
      lineCount: 0,
      agentInitiated: true,
    );

    for (final backend in <FakeAnalyticsService>[first, second]) {
      expect(backend.trackedEvents.single.eventName, 'deploy_failure_evidence');
      expect(
        backend.trackedEvents.single.props,
        containsPair('actor', 'agent'),
      );
    }
  });

  test('CompositeAppAnalytics isolates a throwing failure backend', () {
    final first = FakeAnalyticsService(throwOnTrack: true);
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackDeployFailureEvidence(
      phase: DeployFailurePhase.prepare,
      source: DeployFailureSource.none,
      completeness: DeployFailureCompleteness.unavailable,
      lineCount: 0,
      agentInitiated: false,
    );

    expect(first.trackedEvents, isEmpty);
    expect(second.trackedEvents.single.eventName, 'deploy_failure_evidence');
  });

  test('AppControl maps every value to a storage key', () {
    expect(
      <AppControl, String>{
        for (final control in AppControl.values) control: control.storageKey,
      },
      <AppControl, String>{
        AppControl.railSearchSubmitted: 'rail_search_submitted',
        AppControl.deployPressed: 'deploy_pressed',
        AppControl.runNowPressed: 'run_now_pressed',
        AppControl.emptyStateAction: 'empty_state_action',
        AppControl.placeholderViewed: 'placeholder_viewed',
        AppControl.deployFailureDetailsCopied: 'deploy_failure_details_copied',
        AppControl.deployFailureLogsOpened: 'deploy_failure_logs_opened',
      },
    );
  });

  test('AmplitudeAppAnalytics reports control uses', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackControlUsed(control: AppControl.deployPressed);
    service.trackControlUsed(
      control: AppControl.placeholderViewed,
      tab: 'domain',
    );
    await pumpEventQueue();

    expect(trackedEvents, hasLength(2));
    expect(trackedEvents[0].eventName, 'control_used');
    expect(trackedEvents[0].props?['control'], 'deploy_pressed');
    expect(trackedEvents[0].props?.containsKey('tab'), isFalse);
    expect(trackedEvents[1].eventName, 'control_used');
    expect(trackedEvents[1].props?['control'], 'placeholder_viewed');
    expect(trackedEvents[1].props?['tab'], 'domain');
  });

  test(
    'AmplitudeAppAnalytics drops control uses before initialization',
    () async {
      var trackedEventCount = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {
          trackedEventCount += 1;
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      service.trackControlUsed(control: AppControl.runNowPressed);
      await pumpEventQueue();

      expect(trackedEventCount, 0);
    },
  );

  test('AptabaseAppAnalytics reports control uses', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackControlUsed(control: AppControl.emptyStateAction);
    service.trackControlUsed(
      control: AppControl.placeholderViewed,
      tab: 'email',
    );

    expect(trackedEvents, hasLength(2));
    expect(trackedEvents[0].eventName, 'control_used');
    expect(trackedEvents[0].props?['control'], 'empty_state_action');
    expect(trackedEvents[0].props?.containsKey('tab'), isFalse);
    expect(trackedEvents[1].eventName, 'control_used');
    expect(trackedEvents[1].props?['control'], 'placeholder_viewed');
    expect(trackedEvents[1].props?['tab'], 'email');
  });

  test('CompositeAppAnalytics fans out control uses', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackControlUsed(control: AppControl.railSearchSubmitted);

    for (final backend in [first, second]) {
      expect(backend.controlUses, [
        (control: AppControl.railSearchSubmitted, tab: null),
      ]);
    }
  });

  test('CompositeAppAnalytics isolates a throwing control backend', () {
    final first = FakeAnalyticsService(throwOnTrack: true);
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackControlUsed(control: AppControl.runNowPressed);

    expect(first.controlUses, isEmpty);
    expect(second.controlUses, [
      (control: AppControl.runNowPressed, tab: null),
    ]);
  });

  test('DatabaseEngine maps every value to a storage key', () {
    expect(
      <DatabaseEngine, String>{
        for (final engine in DatabaseEngine.values) engine: engine.storageKey,
      },
      <DatabaseEngine, String>{
        DatabaseEngine.postgres: 'postgres',
        DatabaseEngine.sqlite: 'sqlite',
      },
    );
  });

  test('BackupKind maps every value to a storage key', () {
    expect(
      <BackupKind, String>{
        for (final kind in BackupKind.values) kind: kind.storageKey,
      },
      <BackupKind, String>{BackupKind.postgres: 'postgres'},
    );
  });

  test('DataOperationOutcome maps every value to a storage key', () {
    expect(
      <DataOperationOutcome, String>{
        for (final outcome in DataOperationOutcome.values)
          outcome: outcome.storageKey,
      },
      <DataOperationOutcome, String>{
        DataOperationOutcome.success: 'success',
        DataOperationOutcome.failure: 'failure',
      },
    );
  });

  test('AmplitudeAppAnalytics reports database events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackDatabaseEvent(
      engine: DatabaseEngine.postgres,
      outcome: DataOperationOutcome.success,
    );
    service.trackDatabaseEvent(
      engine: DatabaseEngine.sqlite,
      outcome: DataOperationOutcome.failure,
    );
    await pumpEventQueue();

    expect(trackedEvents, hasLength(2));
    expect(trackedEvents[0].eventName, 'database_event');
    expect(trackedEvents[0].props?['engine'], 'postgres');
    expect(trackedEvents[0].props?['outcome'], 'success');
    expect(trackedEvents[1].eventName, 'database_event');
    expect(trackedEvents[1].props?['engine'], 'sqlite');
    expect(trackedEvents[1].props?['outcome'], 'failure');
  });

  test(
    'AmplitudeAppAnalytics drops database events before initialization',
    () async {
      var trackedEventCount = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {
          trackedEventCount += 1;
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      service.trackDatabaseEvent(
        engine: DatabaseEngine.postgres,
        outcome: DataOperationOutcome.success,
      );
      await pumpEventQueue();

      expect(trackedEventCount, 0);
    },
  );

  test('AptabaseAppAnalytics reports database events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackDatabaseEvent(
      engine: DatabaseEngine.sqlite,
      outcome: DataOperationOutcome.success,
    );

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'database_event');
    expect(trackedEvents.single.props?['engine'], 'sqlite');
    expect(trackedEvents.single.props?['outcome'], 'success');
  });

  test('AmplitudeAppAnalytics reports backup events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackBackupEvent(
      kind: BackupKind.postgres,
      outcome: DataOperationOutcome.failure,
    );
    await pumpEventQueue();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'backup_event');
    expect(trackedEvents.single.props?['kind'], 'postgres');
    expect(trackedEvents.single.props?['outcome'], 'failure');
  });

  test(
    'AmplitudeAppAnalytics drops backup events before initialization',
    () async {
      var trackedEventCount = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {
          trackedEventCount += 1;
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      service.trackBackupEvent(
        kind: BackupKind.postgres,
        outcome: DataOperationOutcome.success,
      );
      await pumpEventQueue();

      expect(trackedEventCount, 0);
    },
  );

  test('AptabaseAppAnalytics reports backup events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackBackupEvent(
      kind: BackupKind.postgres,
      outcome: DataOperationOutcome.success,
    );

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'backup_event');
    expect(trackedEvents.single.props?['kind'], 'postgres');
    expect(trackedEvents.single.props?['outcome'], 'success');
  });

  test('AmplitudeAppAnalytics reports restore events with durations', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackRestoreEvent(
      outcome: DataOperationOutcome.success,
      durationSeconds: 87,
    );
    service.trackRestoreEvent(outcome: DataOperationOutcome.failure);
    await pumpEventQueue();

    expect(trackedEvents, hasLength(2));
    expect(trackedEvents[0].eventName, 'restore_event');
    expect(trackedEvents[0].props?['outcome'], 'success');
    expect(trackedEvents[0].props?['duration_seconds'], 87);
    expect(trackedEvents[1].eventName, 'restore_event');
    expect(trackedEvents[1].props?['outcome'], 'failure');
    expect(trackedEvents[1].props?.containsKey('duration_seconds'), isFalse);
  });

  test(
    'AmplitudeAppAnalytics drops restore events before initialization',
    () async {
      var trackedEventCount = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {
          trackedEventCount += 1;
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      service.trackRestoreEvent(
        outcome: DataOperationOutcome.success,
        durationSeconds: 3,
      );
      await pumpEventQueue();

      expect(trackedEventCount, 0);
    },
  );

  test('AptabaseAppAnalytics reports restore events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackRestoreEvent(
      outcome: DataOperationOutcome.failure,
      durationSeconds: 5,
    );

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'restore_event');
    expect(trackedEvents.single.props?['outcome'], 'failure');
    expect(trackedEvents.single.props?['duration_seconds'], 5);
  });

  test('CompositeAppAnalytics fans out data and safety events', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackDatabaseEvent(
      engine: DatabaseEngine.postgres,
      outcome: DataOperationOutcome.success,
    );
    service.trackBackupEvent(
      kind: BackupKind.postgres,
      outcome: DataOperationOutcome.failure,
    );
    service.trackRestoreEvent(
      outcome: DataOperationOutcome.success,
      durationSeconds: 9,
    );

    for (final backend in [first, second]) {
      expect(backend.databaseEvents, [
        (
          engine: DatabaseEngine.postgres,
          outcome: DataOperationOutcome.success,
        ),
      ]);
      expect(backend.backupEvents, [
        (kind: BackupKind.postgres, outcome: DataOperationOutcome.failure),
      ]);
      expect(backend.restoreEvents, [
        (outcome: DataOperationOutcome.success, durationSeconds: 9),
      ]);
    }
  });

  test('CompositeAppAnalytics isolates throwing data backends', () {
    final first = FakeAnalyticsService(throwOnTrack: true);
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackDatabaseEvent(
      engine: DatabaseEngine.sqlite,
      outcome: DataOperationOutcome.failure,
    );
    service.trackBackupEvent(
      kind: BackupKind.postgres,
      outcome: DataOperationOutcome.success,
    );
    service.trackRestoreEvent(outcome: DataOperationOutcome.failure);

    expect(first.databaseEvents, isEmpty);
    expect(first.backupEvents, isEmpty);
    expect(first.restoreEvents, isEmpty);
    expect(second.databaseEvents, [
      (engine: DatabaseEngine.sqlite, outcome: DataOperationOutcome.failure),
    ]);
    expect(second.backupEvents, [
      (kind: BackupKind.postgres, outcome: DataOperationOutcome.success),
    ]);
    expect(second.restoreEvents, [
      (outcome: DataOperationOutcome.failure, durationSeconds: null),
    ]);
  });

  test('SchedulerAction maps every value to a storage key', () {
    expect(
      <SchedulerAction, String>{
        for (final action in SchedulerAction.values) action: action.storageKey,
      },
      <SchedulerAction, String>{
        SchedulerAction.create: 'create',
        SchedulerAction.update: 'update',
        SchedulerAction.run: 'run',
        SchedulerAction.delete: 'delete',
      },
    );
  });

  test('WorkerAction maps every value to a storage key', () {
    expect(
      <WorkerAction, String>{
        for (final action in WorkerAction.values) action: action.storageKey,
      },
      <WorkerAction, String>{WorkerAction.apply: 'apply'},
    );
  });

  test('ServiceAction maps every value to a storage key', () {
    expect(
      <ServiceAction, String>{
        for (final action in ServiceAction.values) action: action.storageKey,
      },
      <ServiceAction, String>{
        ServiceAction.enable: 'enable',
        ServiceAction.start: 'start',
        ServiceAction.stop: 'stop',
        ServiceAction.restart: 'restart',
        ServiceAction.configure: 'configure',
        ServiceAction.delete: 'delete',
        ServiceAction.migrateStorage: 'migrate_storage',
        ServiceAction.removeLegacyStorage: 'remove_legacy_storage',
        ServiceAction.upgradeMajor: 'upgrade_major',
      },
    );
  });

  test('FirewallAction maps every value to a storage key', () {
    expect(
      <FirewallAction, String>{
        for (final action in FirewallAction.values) action: action.storageKey,
      },
      <FirewallAction, String>{
        FirewallAction.apply: 'apply',
        FirewallAction.commit: 'commit',
        FirewallAction.rollback: 'rollback',
      },
    );
  });

  test('UpdateAction maps every value to a storage key', () {
    expect(
      <UpdateAction, String>{
        for (final action in UpdateAction.values) action: action.storageKey,
      },
      <UpdateAction, String>{
        UpdateAction.check: 'check',
        UpdateAction.apply: 'apply',
      },
    );
  });

  test('AmplitudeAppAnalytics reports scheduler events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackSchedulerEvent(
      action: SchedulerAction.run,
      outcome: DataOperationOutcome.success,
    );
    service.trackSchedulerEvent(
      action: SchedulerAction.delete,
      outcome: DataOperationOutcome.failure,
    );
    await pumpEventQueue();

    expect(trackedEvents, hasLength(2));
    expect(trackedEvents[0].eventName, 'scheduler_event');
    expect(trackedEvents[0].props?['action'], 'run');
    expect(trackedEvents[0].props?['outcome'], 'success');
    expect(trackedEvents[1].eventName, 'scheduler_event');
    expect(trackedEvents[1].props?['action'], 'delete');
    expect(trackedEvents[1].props?['outcome'], 'failure');
  });

  test('AmplitudeAppAnalytics reports worker events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackWorkerEvent(
      action: WorkerAction.apply,
      outcome: DataOperationOutcome.failure,
    );
    await pumpEventQueue();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'worker_event');
    expect(trackedEvents.single.props?['action'], 'apply');
    expect(trackedEvents.single.props?['outcome'], 'failure');
  });

  test('AmplitudeAppAnalytics reports service events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackServiceEvent(
      action: ServiceAction.enable,
      outcome: DataOperationOutcome.success,
    );
    await pumpEventQueue();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'service_event');
    expect(trackedEvents.single.props?['action'], 'enable');
    expect(trackedEvents.single.props?['outcome'], 'success');
  });

  test('AmplitudeAppAnalytics reports firewall events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackFirewallEvent(
      action: FirewallAction.commit,
      outcome: DataOperationOutcome.success,
    );
    await pumpEventQueue();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'firewall_event');
    expect(trackedEvents.single.props?['action'], 'commit');
    expect(trackedEvents.single.props?['outcome'], 'success');
  });

  test(
    'AmplitudeAppAnalytics reports update events with from_version',
    () async {
      final trackedEvents =
          <({String eventName, Map<String, dynamic>? props})>[];
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {
          trackedEvents.add((eventName: eventName, props: props));
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      await service.initialize();
      service.trackUpdateEvent(
        action: UpdateAction.apply,
        outcome: DataOperationOutcome.success,
        fromVersion: '1.4.2',
      );
      await pumpEventQueue();

      expect(trackedEvents, hasLength(1));
      expect(trackedEvents.single.eventName, 'update_event');
      expect(trackedEvents.single.props?['action'], 'apply');
      expect(trackedEvents.single.props?['outcome'], 'success');
      expect(trackedEvents.single.props?['from_version'], '1.4.2');
    },
  );

  test(
    'AmplitudeAppAnalytics drops operation events before initialization',
    () async {
      var trackedEventCount = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {
          trackedEventCount += 1;
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      service.trackSchedulerEvent(
        action: SchedulerAction.create,
        outcome: DataOperationOutcome.success,
      );
      service.trackWorkerEvent(
        action: WorkerAction.apply,
        outcome: DataOperationOutcome.success,
      );
      service.trackServiceEvent(
        action: ServiceAction.start,
        outcome: DataOperationOutcome.success,
      );
      service.trackFirewallEvent(
        action: FirewallAction.rollback,
        outcome: DataOperationOutcome.success,
      );
      service.trackUpdateEvent(
        action: UpdateAction.check,
        outcome: DataOperationOutcome.success,
        fromVersion: '1.4.2',
      );
      service.trackTerminalCommand(outcome: DataOperationOutcome.success);
      service.trackAgentTool(
        tool: 'deploydash_get_server_overview',
        outcome: DataOperationOutcome.success,
      );
      service.trackAgentRedeploy(
        outcome: DataOperationOutcome.success,
        durationSeconds: 12,
      );
      service.trackOnboardingEvent(outcome: DataOperationOutcome.success);
      await pumpEventQueue();

      expect(trackedEventCount, 0);
    },
  );

  test('AptabaseAppAnalytics reports scheduler events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackSchedulerEvent(
      action: SchedulerAction.update,
      outcome: DataOperationOutcome.failure,
    );

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'scheduler_event');
    expect(trackedEvents.single.props?['action'], 'update');
    expect(trackedEvents.single.props?['outcome'], 'failure');
  });

  test('AptabaseAppAnalytics reports worker events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackWorkerEvent(
      action: WorkerAction.apply,
      outcome: DataOperationOutcome.success,
    );

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'worker_event');
    expect(trackedEvents.single.props?['action'], 'apply');
    expect(trackedEvents.single.props?['outcome'], 'success');
  });

  test('AptabaseAppAnalytics reports service events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackServiceEvent(
      action: ServiceAction.restart,
      outcome: DataOperationOutcome.failure,
    );

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'service_event');
    expect(trackedEvents.single.props?['action'], 'restart');
    expect(trackedEvents.single.props?['outcome'], 'failure');
  });

  test('AptabaseAppAnalytics reports firewall events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackFirewallEvent(
      action: FirewallAction.apply,
      outcome: DataOperationOutcome.success,
    );

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'firewall_event');
    expect(trackedEvents.single.props?['action'], 'apply');
    expect(trackedEvents.single.props?['outcome'], 'success');
  });

  test('AptabaseAppAnalytics reports update events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackUpdateEvent(
      action: UpdateAction.check,
      outcome: DataOperationOutcome.success,
      fromVersion: '1.4.2',
    );

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'update_event');
    expect(trackedEvents.single.props?['action'], 'check');
    expect(trackedEvents.single.props?['outcome'], 'success');
    expect(trackedEvents.single.props?['from_version'], '1.4.2');
  });

  test('CompositeAppAnalytics fans out operation events', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackSchedulerEvent(
      action: SchedulerAction.run,
      outcome: DataOperationOutcome.success,
    );
    service.trackWorkerEvent(
      action: WorkerAction.apply,
      outcome: DataOperationOutcome.success,
    );
    service.trackServiceEvent(
      action: ServiceAction.stop,
      outcome: DataOperationOutcome.failure,
    );
    service.trackFirewallEvent(
      action: FirewallAction.rollback,
      outcome: DataOperationOutcome.success,
    );
    service.trackUpdateEvent(
      action: UpdateAction.check,
      outcome: DataOperationOutcome.failure,
      fromVersion: '1.4.2',
    );
    service.trackTerminalCommand(outcome: DataOperationOutcome.success);
    service.trackAgentTool(
      tool: 'deploydash_get_server_overview',
      outcome: DataOperationOutcome.failure,
    );
    service.trackAgentRedeploy(
      outcome: DataOperationOutcome.success,
      durationSeconds: 12,
    );
    service.trackOnboardingEvent(
      outcome: DataOperationOutcome.success,
      provider: OnboardingAuthProvider.password,
      stage: OnboardingStage.services,
    );

    for (final backend in [first, second]) {
      expect(backend.schedulerEvents, [
        (action: SchedulerAction.run, outcome: DataOperationOutcome.success),
      ]);
      expect(backend.workerEvents, [
        (action: WorkerAction.apply, outcome: DataOperationOutcome.success),
      ]);
      expect(backend.serviceEvents, [
        (action: ServiceAction.stop, outcome: DataOperationOutcome.failure),
      ]);
      expect(backend.firewallEvents, [
        (
          action: FirewallAction.rollback,
          outcome: DataOperationOutcome.success,
        ),
      ]);
      expect(backend.updateEvents, [
        (
          action: UpdateAction.check,
          outcome: DataOperationOutcome.failure,
          fromVersion: '1.4.2',
        ),
      ]);
      expect(backend.terminalCommandEvents, [DataOperationOutcome.success]);
      expect(backend.agentToolEvents, [
        (
          tool: 'deploydash_get_server_overview',
          outcome: DataOperationOutcome.failure,
        ),
      ]);
      expect(backend.agentRedeployEvents, [
        (outcome: DataOperationOutcome.success, durationSeconds: 12),
      ]);
      expect(backend.onboardingEvents, [
        (
          outcome: DataOperationOutcome.success,
          provider: OnboardingAuthProvider.password,
          stage: OnboardingStage.services,
        ),
      ]);
    }
  });

  test('CompositeAppAnalytics isolates throwing operation backends', () {
    final first = FakeAnalyticsService(throwOnTrack: true);
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackSchedulerEvent(
      action: SchedulerAction.create,
      outcome: DataOperationOutcome.success,
    );
    service.trackWorkerEvent(
      action: WorkerAction.apply,
      outcome: DataOperationOutcome.success,
    );
    service.trackServiceEvent(
      action: ServiceAction.configure,
      outcome: DataOperationOutcome.success,
    );
    service.trackFirewallEvent(
      action: FirewallAction.apply,
      outcome: DataOperationOutcome.success,
    );
    service.trackUpdateEvent(
      action: UpdateAction.apply,
      outcome: DataOperationOutcome.success,
      fromVersion: '1.4.2',
    );
    service.trackTerminalCommand(outcome: DataOperationOutcome.failure);
    service.trackAgentTool(
      tool: 'deploydash_get_deploy_history',
      outcome: DataOperationOutcome.success,
    );
    service.trackAgentRedeploy(outcome: DataOperationOutcome.failure);
    service.trackOnboardingEvent(outcome: DataOperationOutcome.failure);

    expect(first.schedulerEvents, isEmpty);
    expect(first.workerEvents, isEmpty);
    expect(first.serviceEvents, isEmpty);
    expect(first.firewallEvents, isEmpty);
    expect(first.updateEvents, isEmpty);
    expect(first.onboardingEvents, isEmpty);
    expect(first.terminalCommandEvents, isEmpty);
    expect(first.agentToolEvents, isEmpty);
    expect(first.agentRedeployEvents, isEmpty);
    expect(second.schedulerEvents, [
      (action: SchedulerAction.create, outcome: DataOperationOutcome.success),
    ]);
    expect(second.workerEvents, [
      (action: WorkerAction.apply, outcome: DataOperationOutcome.success),
    ]);
    expect(second.serviceEvents, [
      (action: ServiceAction.configure, outcome: DataOperationOutcome.success),
    ]);
    expect(second.firewallEvents, [
      (action: FirewallAction.apply, outcome: DataOperationOutcome.success),
    ]);
    expect(second.updateEvents, [
      (
        action: UpdateAction.apply,
        outcome: DataOperationOutcome.success,
        fromVersion: '1.4.2',
      ),
    ]);
    expect(second.terminalCommandEvents, [DataOperationOutcome.failure]);
    expect(second.agentToolEvents, [
      (
        tool: 'deploydash_get_deploy_history',
        outcome: DataOperationOutcome.success,
      ),
    ]);
    expect(second.agentRedeployEvents, [
      (outcome: DataOperationOutcome.failure, durationSeconds: null),
    ]);
    expect(second.onboardingEvents, [
      (outcome: DataOperationOutcome.failure, provider: null, stage: null),
    ]);
  });

  test('AmplitudeAppAnalytics reports terminal command events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackTerminalCommand(outcome: DataOperationOutcome.failure);
    await pumpEventQueue();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'terminal_command');
    // The command text never leaves the device: outcome is the whole payload.
    expect(trackedEvents.single.props?.keys, {'outcome'});
    expect(trackedEvents.single.props?['outcome'], 'failure');
  });

  test('AmplitudeAppAnalytics reports agent tool events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackAgentTool(
      tool: 'deploydash_get_server_overview',
      outcome: DataOperationOutcome.success,
    );
    await pumpEventQueue();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'agent_tool');
    expect(
      trackedEvents.single.props?['tool'],
      'deploydash_get_server_overview',
    );
    expect(trackedEvents.single.props?['outcome'], 'success');
  });

  test(
    'AmplitudeAppAnalytics reports agent redeploy events with duration',
    () async {
      final trackedEvents =
          <({String eventName, Map<String, dynamic>? props})>[];
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        initializer: (config) async {},
        tracker: (eventName, props) async {
          trackedEvents.add((eventName: eventName, props: props));
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      await service.initialize();
      service.trackAgentRedeploy(
        outcome: DataOperationOutcome.success,
        durationSeconds: 12,
      );
      service.trackAgentRedeploy(outcome: DataOperationOutcome.failure);
      await pumpEventQueue();

      expect(trackedEvents, hasLength(2));
      expect(trackedEvents[0].eventName, 'agent_redeploy');
      expect(trackedEvents[0].props?['outcome'], 'success');
      expect(trackedEvents[0].props?['duration_seconds'], 12);
      expect(trackedEvents[1].eventName, 'agent_redeploy');
      expect(trackedEvents[1].props?['outcome'], 'failure');
      expect(trackedEvents[1].props?.containsKey('duration_seconds'), isFalse);
    },
  );

  test('AptabaseAppAnalytics reports terminal command events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackTerminalCommand(outcome: DataOperationOutcome.success);

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'terminal_command');
    // The command text never leaves the device: outcome is the whole payload.
    expect(trackedEvents.single.props?.keys, {'outcome'});
    expect(trackedEvents.single.props?['outcome'], 'success');
  });

  test('AptabaseAppAnalytics reports agent tool events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackAgentTool(
      tool: 'deploydash_get_deploy_history',
      outcome: DataOperationOutcome.failure,
    );

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'agent_tool');
    expect(
      trackedEvents.single.props?['tool'],
      'deploydash_get_deploy_history',
    );
    expect(trackedEvents.single.props?['outcome'], 'failure');
  });

  test(
    'AptabaseAppAnalytics reports agent redeploy events with duration',
    () async {
      final trackedEvents =
          <({String eventName, Map<String, dynamic>? props})>[];
      final service = AptabaseAppAnalytics(
        appKey: 'test-app-key',
        initializer: (appKey, options) async {},
        tracker: (eventName, props) {
          trackedEvents.add((eventName: eventName, props: props));
        },
      );

      await service.initialize();
      service.trackAgentRedeploy(
        outcome: DataOperationOutcome.failure,
        durationSeconds: 30,
      );

      expect(trackedEvents, hasLength(1));
      expect(trackedEvents.single.eventName, 'agent_redeploy');
      expect(trackedEvents.single.props?['outcome'], 'failure');
      expect(trackedEvents.single.props?['duration_seconds'], 30);
    },
  );

  test('OnboardingAuthProvider maps every value to a storage key', () {
    expect(
      <OnboardingAuthProvider, String>{
        for (final provider in OnboardingAuthProvider.values)
          provider: provider.storageKey,
      },
      <OnboardingAuthProvider, String>{
        OnboardingAuthProvider.password: 'password',
        OnboardingAuthProvider.sshKey: 'ssh_key',
      },
    );
  });

  test('OnboardingStage maps every value to a storage key', () {
    expect(
      <OnboardingStage, String>{
        for (final stage in OnboardingStage.values) stage: stage.storageKey,
      },
      <OnboardingStage, String>{
        OnboardingStage.intro: 'intro',
        OnboardingStage.credentials: 'credentials',
        OnboardingStage.confirmation: 'confirmation',
        OnboardingStage.setupProgress: 'setup_progress',
        OnboardingStage.services: 'services',
      },
    );
  });

  test('AmplitudeAppAnalytics reports onboarding events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackOnboardingEvent(
      outcome: DataOperationOutcome.success,
      provider: OnboardingAuthProvider.password,
      stage: OnboardingStage.services,
    );
    service.trackOnboardingEvent(outcome: DataOperationOutcome.failure);
    await pumpEventQueue();

    expect(trackedEvents, hasLength(2));
    expect(trackedEvents[0].eventName, 'onboarding_event');
    expect(trackedEvents[0].props?['outcome'], 'success');
    expect(trackedEvents[0].props?['provider'], 'password');
    expect(trackedEvents[0].props?['stage'], 'services');
    expect(trackedEvents[1].eventName, 'onboarding_event');
    expect(trackedEvents[1].props?['outcome'], 'failure');
    expect(trackedEvents[1].props?.containsKey('provider'), isFalse);
    expect(trackedEvents[1].props?.containsKey('stage'), isFalse);
  });

  test('AptabaseAppAnalytics reports onboarding events', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackOnboardingEvent(
      outcome: DataOperationOutcome.failure,
      provider: OnboardingAuthProvider.sshKey,
      stage: OnboardingStage.setupProgress,
    );

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'onboarding_event');
    expect(trackedEvents.single.props?['outcome'], 'failure');
    expect(trackedEvents.single.props?['provider'], 'ssh_key');
    expect(trackedEvents.single.props?['stage'], 'setup_progress');
  });

  test('isKnownEngineWorkflowOperation gates the registry vocabulary', () {
    for (final operation in <String>{
      'project_normalize_database',
      'service_migrate_storage',
      'service_remove_legacy_storage',
      'service_upgrade_major',
    }) {
      expect(
        isKnownEngineWorkflowOperation('postgres', operation),
        isTrue,
        reason: operation,
      );
    }
    expect(
      isKnownEngineWorkflowOperation('postgres', 'service_restart'),
      isTrue,
    );
    expect(isKnownEngineWorkflowOperation('server', 'check'), isTrue);
    expect(isKnownEngineWorkflowOperation('setup', 'run'), isTrue);
    expect(
      isKnownEngineWorkflowOperation('  postgres  ', '  service_restart  '),
      isTrue,
      reason: 'hook payloads are code-built, but trim anyway',
    );
    expect(
      isKnownEngineWorkflowOperation('unknown_workflow', 'service_restart'),
      isFalse,
    );
    expect(
      isKnownEngineWorkflowOperation('postgres', 'unknown_operation'),
      isFalse,
    );
    expect(isKnownEngineWorkflowOperation('', ''), isFalse);
    expect(isKnownEngineWorkflowOperation('   ', '   '), isFalse);
  });

  test('AmplitudeAppAnalytics reports workflow failures', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackWorkflowFailed(
      workflowId: 'postgres',
      operationId: 'service_restart',
    );
    await pumpEventQueue();

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'workflow_failed');
    expect(trackedEvents.single.props?['workflow_id'], 'postgres');
    expect(trackedEvents.single.props?['operation_id'], 'service_restart');
  });

  test('AptabaseAppAnalytics reports workflow failures', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackWorkflowFailed(workflowId: 'app', operationId: 'run');

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'workflow_failed');
    expect(trackedEvents.single.props?['workflow_id'], 'app');
    expect(trackedEvents.single.props?['operation_id'], 'run');
  });

  test('CompositeAppAnalytics fans out workflow failures', () {
    final first = FakeAnalyticsService();
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackWorkflowFailed(workflowId: 'firewall', operationId: 'commit');

    for (final backend in [first, second]) {
      expect(backend.workflowFailedEvents, [
        (workflowId: 'firewall', operationId: 'commit'),
      ]);
    }
  });

  test('CompositeAppAnalytics isolates a throwing workflow backend', () {
    final first = FakeAnalyticsService(throwOnTrack: true);
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: first, second: second);

    service.trackWorkflowFailed(workflowId: 'server', operationId: 'check');

    expect(first.workflowFailedEvents, isEmpty);
    expect(second.workflowFailedEvents, [
      (workflowId: 'server', operationId: 'check'),
    ]);
  });

  group('usage-reporting switch', () {
    test('AptabaseAppAnalytics tracks only while switched on', () async {
      var trackedEventCount = 0;
      final service = AptabaseAppAnalytics(
        appKey: 'A-EU-3209480801',
        initializer: (appKey, options) async {},
        tracker: (eventName, props) {
          trackedEventCount += 1;
        },
      );

      expect(service.isInitialized, isFalse);
      service.trackAppStarted();
      expect(trackedEventCount, 0);

      await service.initialize();
      expect(service.isInitialized, isTrue);

      service.trackAppStarted();
      expect(trackedEventCount, 1);

      service.setTelemetryEnabled(false);
      service.trackAppStarted();
      service.trackWorkspaceOpened(workspace: 'home_dashboard');
      expect(trackedEventCount, 1);

      service.setTelemetryEnabled(true);
      service.trackAppStarted();
      expect(trackedEventCount, 2);
    });

    test('AmplitudeAppAnalytics tracks only while switched on', () async {
      var trackedEventCount = 0;
      final service = AmplitudeAppAnalytics(
        apiKey: 'test-api-key',
        context: AnalyticsEventContext(sessionId: 'session-switch'),
        initializer: (config) async {},
        tracker: (eventName, props) async {
          trackedEventCount += 1;
        },
        flusher: () async {},
        identifier: (attributes) async {},
      );

      expect(service.isInitialized, isFalse);

      await service.initialize();
      expect(service.isInitialized, isTrue);

      await service.trackEventAsync('probe');
      expect(trackedEventCount, 1);

      service.setTelemetryEnabled(false);
      await service.trackEventAsync('probe');
      service.setUserAttribute(AppUserAttribute.hasCompletedOnboarding, 'true');
      await pumpEventQueue();
      expect(trackedEventCount, 1);

      service.setTelemetryEnabled(true);
      await service.trackEventAsync('probe');
      expect(trackedEventCount, 2);
    });

    test('CompositeAppAnalytics fans the switch out and gates the fan-out', () {
      final first = FakeAnalyticsService();
      final second = FakeAnalyticsService();
      final service = CompositeAppAnalytics(first: first, second: second);

      expect(service.isInitialized, isFalse);

      service.setTelemetryEnabled(false);
      expect(first.setTelemetryCallCount, 1);
      expect(first.lastSetTelemetryEnabled, isFalse);
      expect(second.setTelemetryCallCount, 1);
      expect(second.lastSetTelemetryEnabled, isFalse);

      // Even with both children switched back on behind its back, the
      // composite's own gate stays silent: the fan-out consults the switch.
      first.setTelemetryEnabled(true);
      second.setTelemetryEnabled(true);
      service.trackAppStarted();
      expect(first.appStartedCallCount, 0);
      expect(second.appStartedCallCount, 0);

      service.setTelemetryEnabled(true);
      service.trackAppStarted();
      expect(first.appStartedCallCount, 1);
      expect(second.appStartedCallCount, 1);
    });
  });

  test('AmplitudeAppAnalytics ends the session once with duration', () async {
    var now = DateTime.utc(2026, 4, 1, 12);
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      context: AnalyticsEventContext(sessionId: 'session-9', clock: () => now),
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackAppStarted();
    await pumpEventQueue();
    now = now.add(const Duration(seconds: 90));
    service.endSession();
    await pumpEventQueue();
    // A repeated detach stays silent: one launch ends exactly once.
    service.endSession();
    await pumpEventQueue();

    final ends = trackedEvents
        .where((event) => event.eventName == 'session_ended')
        .toList();
    expect(ends, hasLength(1));
    expect(ends.single.props?['session_id'], 'session-9');
    expect(ends.single.props?['duration_seconds'], 90);
  });

  test('AptabaseAppAnalytics ends the session once with duration', () async {
    var now = DateTime.utc(2026, 4, 1, 12);
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      context: AnalyticsEventContext(sessionId: 'session-9', clock: () => now),
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackAppStarted();
    now = now.add(const Duration(seconds: 61));
    service.endSession();
    service.endSession();

    final ends = trackedEvents
        .where((event) => event.eventName == 'session_ended')
        .toList();
    expect(ends, hasLength(1));
    expect(ends.single.props?['session_id'], 'session-9');
    expect(ends.single.props?['duration_seconds'], 61);
  });

  test('endSession stays silent when nothing was tracked', () async {
    var now = DateTime.utc(2026, 4, 1, 12);
    final amplitudeEvents =
        <({String eventName, Map<String, dynamic>? props})>[];
    final amplitude = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      context: AnalyticsEventContext(
        sessionId: 'session-silent',
        clock: () => now,
      ),
      initializer: (config) async {},
      tracker: (eventName, props) async {
        amplitudeEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );
    final aptabaseEvents =
        <({String eventName, Map<String, dynamic>? props})>[];
    final aptabase = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      context: AnalyticsEventContext(
        sessionId: 'session-silent',
        clock: () => now,
      ),
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        aptabaseEvents.add((eventName: eventName, props: props));
      },
    );

    await amplitude.initialize();
    await aptabase.initialize();
    now = now.add(const Duration(seconds: 30));
    amplitude.endSession();
    aptabase.endSession();
    await pumpEventQueue();

    expect(amplitudeEvents, isEmpty);
    expect(aptabaseEvents, isEmpty);
  });

  test('endSession clamps a rewound clock to zero', () async {
    var now = DateTime.utc(2026, 4, 1, 12);
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      context: AnalyticsEventContext(
        sessionId: 'session-rewind',
        clock: () => now,
      ),
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackAppStarted();
    await pumpEventQueue();
    now = now.subtract(const Duration(seconds: 5));
    service.endSession();
    await pumpEventQueue();

    final ends = trackedEvents
        .where((event) => event.eventName == 'session_ended')
        .toList();
    expect(ends, hasLength(1));
    expect(ends.single.props?['duration_seconds'], 0);
  });

  test('endSession contains tracker faults', () async {
    final amplitudeEvents = <String>[];
    final amplitude = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        if (eventName == 'session_ended') {
          throw StateError('tracker unavailable');
        }
        amplitudeEvents.add(eventName);
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );
    final aptabaseEvents = <String>[];
    final aptabase = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        if (eventName == 'session_ended') {
          throw StateError('tracker unavailable');
        }
        aptabaseEvents.add(eventName);
      },
    );

    await amplitude.initialize();
    await aptabase.initialize();
    amplitude.trackAppStarted();
    aptabase.trackAppStarted();
    await pumpEventQueue();

    // The detach path must not crash on analytics, even mid-outage.
    amplitude.endSession();
    aptabase.endSession();
    await pumpEventQueue();

    expect(amplitudeEvents, ['app_started']);
    expect(aptabaseEvents, ['app_started']);
  });

  test(
    'AptabaseAppAnalytics swallows Exception session-end failures',
    () async {
      final aptabaseEvents = <String>[];
      final aptabase = AptabaseAppAnalytics(
        appKey: 'test-app-key',
        initializer: (appKey, options) async {},
        tracker: (eventName, props) {
          if (eventName == 'session_ended') {
            throw Exception('tracker unavailable');
          }
          aptabaseEvents.add(eventName);
        },
      );

      await aptabase.initialize();
      aptabase.trackAppStarted();
      await pumpEventQueue();

      aptabase.endSession();
      await pumpEventQueue();

      expect(aptabaseEvents, ['app_started']);
    },
  );

  test('CompositeAppAnalytics fans out session end and isolates faults', () {
    final throwing = FakeAnalyticsService(throwOnTrack: true);
    final second = FakeAnalyticsService();
    final service = CompositeAppAnalytics(first: throwing, second: second);

    service.endSession();

    expect(throwing.endSessionCalls, 1);
    expect(second.endSessionCalls, 1);
  });

  test('endAnalyticsSessionOnClose ends the session before flushing', () async {
    final ordered = _OrderedAnalyticsService();
    debugOverrideAppAnalyticsService(ordered);
    try {
      await endAnalyticsSessionOnClose();

      expect(ordered.calls, ['endSession', 'flush']);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  test('buildCrashMarkerPayload carries only the error type and timestamp', () {
    final payload = buildCrashMarkerPayload(
      errorType: 'StateError',
      timestamp: DateTime.utc(2026, 9, 9, 12, 30),
    );

    final decoded = jsonDecode(payload) as Map<String, dynamic>;
    expect(decoded.keys, {'error_type', 'timestamp'});
    expect(decoded['error_type'], 'StateError');
    expect(decoded['timestamp'], '2026-09-09T12:30:00.000Z');
    expect(payload, isNot(contains('something broke')));
    expect(payload, isNot(contains('app.dart')));
  });

  test('buildCrashMarkerPayload falls back to unknown for a blank type', () {
    final decoded =
        jsonDecode(
              buildCrashMarkerPayload(
                errorType: '   ',
                timestamp: DateTime.utc(2026, 9, 9),
              ),
            )
            as Map<String, dynamic>;

    expect(decoded['error_type'], 'unknown');
  });

  test('parseCrashMarkerErrorType round-trips a marker and rejects junk', () {
    final payload = buildCrashMarkerPayload(
      errorType: 'StateError',
      timestamp: DateTime.utc(2026, 9, 9),
    );

    expect(parseCrashMarkerErrorType(payload), 'StateError');
    expect(parseCrashMarkerErrorType(null), isNull);
    expect(parseCrashMarkerErrorType(''), isNull);
    expect(parseCrashMarkerErrorType('   '), isNull);
    expect(parseCrashMarkerErrorType('not-json'), isNull);
    expect(parseCrashMarkerErrorType('[]'), isNull);
    expect(parseCrashMarkerErrorType('{"timestamp":"x"}'), isNull);
    expect(parseCrashMarkerErrorType('{"error_type":"   "}'), isNull);
  });

  test('FileCrashMarkerStore writes, reads, and erases a marker', () {
    final dir = Directory.systemTemp.createTempSync('crash-marker-');
    try {
      final store = FileCrashMarkerStore(dir);

      expect(store.read(), isNull);
      store.erase();
      final payload = buildCrashMarkerPayload(
        errorType: 'StateError',
        timestamp: DateTime.utc(2026, 9, 9),
      );
      store.write(payload);

      expect(store.read(), payload);

      store.erase();
      expect(store.read(), isNull);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('AptabaseAppAnalytics reports previous-session crashes', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEvents.add((eventName: eventName, props: props));
      },
    );

    await service.initialize();
    service.trackPreviousSessionCrash(errorType: 'StateError');

    expect(trackedEvents, hasLength(1));
    expect(trackedEvents.single.eventName, 'previous_session_crashed');
    expect(trackedEvents.single.props?['error_type'], 'StateError');
  });

  test('AmplitudeAppAnalytics reports previous-session crashes', () async {
    final trackedEvents = <({String eventName, Map<String, dynamic>? props})>[];
    final service = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEvents.add((eventName: eventName, props: props));
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );

    await service.initialize();
    service.trackPreviousSessionCrash(errorType: 'StateError');
    service.trackPreviousSessionCrash(errorType: '   ');
    await pumpEventQueue();

    expect(trackedEvents, hasLength(2));
    expect(trackedEvents[0].eventName, 'previous_session_crashed');
    expect(trackedEvents[0].props?['error_type'], 'StateError');
    expect(trackedEvents[1].props?['error_type'], 'unknown');
  });

  test('previous-session crashes are dropped before initialization', () async {
    var trackedEventCount = 0;
    final amplitude = AmplitudeAppAnalytics(
      apiKey: 'test-api-key',
      initializer: (config) async {},
      tracker: (eventName, props) async {
        trackedEventCount += 1;
      },
      flusher: () async {},
      identifier: (attributes) async {},
    );
    final aptabase = AptabaseAppAnalytics(
      appKey: 'test-app-key',
      initializer: (appKey, options) async {},
      tracker: (eventName, props) {
        trackedEventCount += 1;
      },
    );

    amplitude.trackPreviousSessionCrash(errorType: 'StateError');
    aptabase.trackPreviousSessionCrash(errorType: 'StateError');
    await pumpEventQueue();

    expect(trackedEventCount, 0);
  });

  test(
    'CompositeAppAnalytics fans out crashes and isolates a throwing backend',
    () {
      final first = FakeAnalyticsService();
      final second = FakeAnalyticsService();
      CompositeAppAnalytics(
        first: first,
        second: second,
      ).trackPreviousSessionCrash(errorType: 'StateError');

      for (final backend in [first, second]) {
        expect(backend.previousSessionCrashes, ['StateError']);
      }

      final throwing = FakeAnalyticsService(throwOnTrack: true);
      final survivor = FakeAnalyticsService();
      CompositeAppAnalytics(
        first: throwing,
        second: survivor,
      ).trackPreviousSessionCrash(errorType: 'StateError');

      expect(throwing.previousSessionCrashes, isEmpty);
      expect(survivor.previousSessionCrashes, ['StateError']);
    },
  );

  test(
    'handleAnalyticsFlutterError writes a type-only marker then forwards',
    () {
      final written = <String>[];
      FlutterErrorDetails? forwarded;
      final details = FlutterErrorDetails(
        exception: StateError('something broke in /home/user/app.dart'),
        stack: StackTrace.fromString('/home/user/app.dart:42'),
      );

      handleAnalyticsFlutterError(
        details,
        writer: written.add,
        previous: (forwardedDetails) {
          forwarded = forwardedDetails;
        },
        clock: () => DateTime.utc(2026, 9, 9),
      );

      expect(written, hasLength(1));
      final decoded = jsonDecode(written.single) as Map<String, dynamic>;
      expect(decoded.keys, {'error_type', 'timestamp'});
      expect(decoded['error_type'], 'StateError');
      expect(written.single, isNot(contains('something broke')));
      expect(written.single, isNot(contains('app.dart')));
      expect(identical(forwarded, details), isTrue);
    },
  );

  test(
    'handleAnalyticsFlutterError without a previous handler still reports',
    () {
      final written = <String>[];
      final details = FlutterErrorDetails(exception: StateError('boom'));

      handleAnalyticsFlutterError(
        details,
        writer: written.add,
        clock: () => DateTime.utc(2026, 9, 9),
      );

      expect(written, hasLength(1));
      expect(parseCrashMarkerErrorType(written.single), 'StateError');
    },
  );

  test(
    'handleAnalyticsPlatformError records then preserves the previous verdict',
    () {
      final written = <String>[];
      Object? forwardedError;

      final verdict = handleAnalyticsPlatformError(
        StateError('kernel panic'),
        StackTrace.empty,
        writer: written.add,
        previous: (error, stack) {
          forwardedError = error;
          return true;
        },
        clock: () => DateTime.utc(2026, 9, 9),
      );

      expect(verdict, isTrue);
      expect(forwardedError, isA<StateError>());
      expect(written, hasLength(1));
      expect(parseCrashMarkerErrorType(written.single), 'StateError');
      expect(written.single, isNot(contains('kernel panic')));
    },
  );

  test(
    'handleAnalyticsPlatformError returns false without a previous handler',
    () {
      // No handler is installed today: false preserves termination instead of
      // swallowing the fatal error.
      final verdict = handleAnalyticsPlatformError(
        StateError('fatal'),
        StackTrace.empty,
        writer: (_) {},
      );

      expect(verdict, isFalse);
    },
  );

  test('crash handlers never throw on storage or forwarding faults', () {
    final details = FlutterErrorDetails(exception: StateError('unwritable'));

    handleAnalyticsFlutterError(
      details,
      writer: (_) => throw StateError('disk gone'),
      previous: (_) => throw StateError('reporter down'),
    );

    final verdict = handleAnalyticsPlatformError(
      StateError('unwritable'),
      StackTrace.empty,
      writer: (_) => throw StateError('disk gone'),
      previous: (error, stack) => throw StateError('reporter down'),
    );

    expect(verdict, isFalse);
  });

  test(
    'crash handlers never throw on Exception storage or forwarding faults',
    () {
      final details = FlutterErrorDetails(exception: Exception('unwritable'));

      handleAnalyticsFlutterError(
        details,
        writer: (_) => throw Exception('disk gone'),
        previous: (_) => throw Exception('reporter down'),
      );

      final verdict = handleAnalyticsPlatformError(
        Exception('unwritable'),
        StackTrace.empty,
        writer: (_) => throw Exception('disk gone'),
        previous: (error, stack) => throw Exception('reporter down'),
      );

      expect(verdict, isFalse);
    },
  );

  test('installAnalyticsCrashHandlers chains both previous handlers', () {
    final written = <String>[];
    final previousFlutter = FlutterError.onError;
    final previousPlatform = PlatformDispatcher.instance.onError;
    FlutterErrorDetails? forwardedFlutter;
    Object? forwardedPlatformError;
    FlutterError.onError = (details) {
      forwardedFlutter = details;
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      forwardedPlatformError = error;
      return true;
    };
    try {
      installAnalyticsCrashHandlers(writer: written.add);

      final details = FlutterErrorDetails(exception: StateError('wired'));
      FlutterError.onError!(details);
      expect(parseCrashMarkerErrorType(written.single), 'StateError');
      expect(identical(forwardedFlutter, details), isTrue);

      final verdict = PlatformDispatcher.instance.onError!(
        StateError('wired'),
        StackTrace.empty,
      );
      expect(verdict, isTrue);
      expect(forwardedPlatformError, isA<StateError>());
      expect(written, hasLength(2));
    } finally {
      FlutterError.onError = previousFlutter;
      PlatformDispatcher.instance.onError = previousPlatform;
    }
  });

  test('installAnalyticsCrashHandlers contains installer faults', () {
    final written = <String>[];
    final previousFlutter = FlutterError.onError;
    final previousPlatform = PlatformDispatcher.instance.onError;
    try {
      var platformInstalls = 0;
      installAnalyticsCrashHandlers(
        writer: written.add,
        flutterInstaller: (_) => throw StateError('no framework'),
        platformInstaller: (handler) {
          platformInstalls += 1;
          PlatformDispatcher.instance.onError = handler;
        },
      );

      final verdict = PlatformDispatcher.instance.onError!(
        StateError('wired'),
        StackTrace.empty,
      );
      expect(verdict, isFalse);
      expect(platformInstalls, 1);
      expect(parseCrashMarkerErrorType(written.single), 'StateError');

      installAnalyticsCrashHandlers(
        writer: written.add,
        platformInstaller: (_) => throw StateError('no dispatcher'),
      );
    } finally {
      FlutterError.onError = previousFlutter;
      PlatformDispatcher.instance.onError = previousPlatform;
    }
  });

  test('installAnalyticsCrashHandlers contains Exception installer faults', () {
    final written = <String>[];
    final previousFlutter = FlutterError.onError;
    final previousPlatform = PlatformDispatcher.instance.onError;
    try {
      var platformInstalls = 0;
      installAnalyticsCrashHandlers(
        writer: written.add,
        flutterInstaller: (_) => throw Exception('no framework'),
        platformInstaller: (handler) {
          platformInstalls += 1;
          PlatformDispatcher.instance.onError = handler;
        },
      );

      final verdict = PlatformDispatcher.instance.onError!(
        Exception('wired'),
        StackTrace.empty,
      );
      expect(verdict, isFalse);
      expect(platformInstalls, 1);
      expect(parseCrashMarkerErrorType(written.single), '_Exception');

      installAnalyticsCrashHandlers(
        writer: written.add,
        platformInstaller: (_) => throw Exception('no dispatcher'),
      );
    } finally {
      FlutterError.onError = previousFlutter;
      PlatformDispatcher.instance.onError = previousPlatform;
    }
  });

  test(
    'reportPreviousSessionCrash emits once on both backends then clears',
    () {
      String? marker = buildCrashMarkerPayload(
        errorType: 'StateError',
        timestamp: DateTime.utc(2026, 9, 9),
      );
      var eraseCalls = 0;
      final first = FakeAnalyticsService();
      final second = FakeAnalyticsService();
      debugOverrideAppAnalyticsService(
        CompositeAppAnalytics(first: first, second: second),
      );
      try {
        reportPreviousSessionCrash(
          reader: () => marker,
          eraser: () {
            eraseCalls += 1;
            marker = null;
          },
        );

        for (final backend in [first, second]) {
          expect(backend.previousSessionCrashes, ['StateError']);
        }
        expect(eraseCalls, 1);
        expect(marker, isNull);

        reportPreviousSessionCrash(
          reader: () => marker,
          eraser: () {
            eraseCalls += 1;
          },
        );
        expect(eraseCalls, 1);
        expect(first.previousSessionCrashes, hasLength(1));
      } finally {
        debugOverrideAppAnalyticsService(null);
      }
    },
  );

  test('reportPreviousSessionCrash stays silent without a marker', () {
    var eraseCalls = 0;
    final fake = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(fake);
    try {
      reportPreviousSessionCrash(
        reader: () => null,
        eraser: () {
          eraseCalls += 1;
        },
      );

      expect(fake.previousSessionCrashes, isEmpty);
      expect(eraseCalls, 0);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  test(
    'reportPreviousSessionCrash drops a corrupt marker without emitting',
    () {
      var eraseCalls = 0;
      final fake = FakeAnalyticsService();
      debugOverrideAppAnalyticsService(fake);
      try {
        reportPreviousSessionCrash(
          reader: () => 'not-json{{{',
          eraser: () {
            eraseCalls += 1;
          },
        );

        expect(fake.previousSessionCrashes, isEmpty);
        expect(eraseCalls, 0);
      } finally {
        debugOverrideAppAnalyticsService(null);
      }
    },
  );

  test('reportPreviousSessionCrash contains storage and backend faults', () {
    final fake = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(fake);
    try {
      var eraseCalls = 0;
      reportPreviousSessionCrash(
        reader: () => throw StateError('disk gone'),
        eraser: () {
          eraseCalls += 1;
        },
      );
      expect(fake.previousSessionCrashes, isEmpty);
      expect(eraseCalls, 0);

      reportPreviousSessionCrash(
        reader: () => buildCrashMarkerPayload(
          errorType: 'StateError',
          timestamp: DateTime.utc(2026, 9, 9),
        ),
        eraser: () => throw StateError('disk gone'),
      );
      expect(fake.previousSessionCrashes, ['StateError']);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }

    final throwing = FakeAnalyticsService(throwOnTrack: true);
    debugOverrideAppAnalyticsService(throwing);
    try {
      String? marker = buildCrashMarkerPayload(
        errorType: 'StateError',
        timestamp: DateTime.utc(2026, 9, 9),
      );
      reportPreviousSessionCrash(
        reader: () => marker,
        eraser: () {
          marker = null;
        },
      );
      expect(marker, isNull);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });

  test('reportPreviousSessionCrash contains Exception storage faults', () {
    final fake = FakeAnalyticsService();
    debugOverrideAppAnalyticsService(fake);
    try {
      var eraseCalls = 0;
      reportPreviousSessionCrash(
        reader: () => throw Exception('disk gone'),
        eraser: () {
          eraseCalls += 1;
        },
      );
      expect(fake.previousSessionCrashes, isEmpty);
      expect(eraseCalls, 0);

      reportPreviousSessionCrash(
        reader: () => buildCrashMarkerPayload(
          errorType: 'Exception',
          timestamp: DateTime.utc(2026, 9, 9),
        ),
        eraser: () => throw Exception('disk gone'),
      );
      expect(fake.previousSessionCrashes, ['Exception']);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }

    final throwing = FakeAnalyticsService(
      throwOnTrack: true,
      throwAsException: true,
    );
    debugOverrideAppAnalyticsService(throwing);
    try {
      String? marker = buildCrashMarkerPayload(
        errorType: 'Exception',
        timestamp: DateTime.utc(2026, 9, 9),
      );
      reportPreviousSessionCrash(
        reader: () => marker,
        eraser: () {
          marker = null;
        },
      );
      expect(marker, isNull);
    } finally {
      debugOverrideAppAnalyticsService(null);
    }
  });
}

/// Preferences whose reads always fail with an operational fault, proving
/// guarded analytics reads degrade rather than throw.
class _ThrowingExceptionPreferences extends AppPreferencesRepository {
  _ThrowingExceptionPreferences(super.database);

  @override
  Future<AppPreferencesRecord> read() async {
    throw Exception('preferences unreadable');
  }
}

/// [FlushableFakeAnalyticsService] recording the close sequence, proving the
/// session row lands before the flush pushes it out.
class _OrderedAnalyticsService extends FlushableFakeAnalyticsService {
  final calls = <String>[];

  @override
  void endSession() {
    calls.add('endSession');
    super.endSession();
  }

  @override
  Future<void> flush() async {
    calls.add('flush');
    await super.flush();
  }
}

/// In-memory [AnalyticsContextStore] with optional faults.
class _FakeAnalyticsContextStore implements AnalyticsContextStore {
  _FakeAnalyticsContextStore({
    this.firstLaunchAt,
    this.milestones = const <AppUserAttribute>{},
    this.throwOnRead = false,
    this.throwErrorOnRead = false,
    this.throwExceptionOnRead = false,
  });

  final DateTime? firstLaunchAt;
  final Set<AppUserAttribute> milestones;
  final bool throwOnRead;
  final bool throwErrorOnRead;
  final bool throwExceptionOnRead;
  final recorded = <AppUserAttribute>[];

  @override
  Future<DateTime?> readFirstLaunchAt() async {
    if (throwErrorOnRead) {
      throw ArgumentError('store programming fault');
    }
    if (throwExceptionOnRead) {
      throw Exception('store unavailable');
    }
    if (throwOnRead) {
      throw StateError('store unavailable');
    }
    return firstLaunchAt;
  }

  @override
  Future<Set<AppUserAttribute>?> readMilestones() async {
    if (throwErrorOnRead) {
      throw ArgumentError('store programming fault');
    }
    if (throwExceptionOnRead) {
      throw Exception('store unavailable');
    }
    if (throwOnRead) {
      throw StateError('store unavailable');
    }
    return milestones;
  }

  @override
  Future<void> recordMilestone(AppUserAttribute attribute) async {
    recorded.add(attribute);
  }
}
