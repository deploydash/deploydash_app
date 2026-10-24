import 'dart:io';

import 'package:drift/native.dart';
import 'package:ui/data/local/app_data_directory.dart';
import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/providers/desktop_startup_provider.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_support/fake_analytics_service.dart';
import '../_support/sqlite_test_harness.dart';

void main() {
  test(
    'startup actions run update checking and runtime warmup outside a widget',
    () async {
      var updateChecks = 0;
      var runtimeWarmups = 0;
      final container = ProviderContainer(
        overrides: [
          desktopUpdateCheckerProvider.overrideWithValue(() async {
            updateChecks += 1;
          }),
          desktopRuntimeWarmupProvider.overrideWithValue(() async {
            runtimeWarmups += 1;
          }),
        ],
      );
      addTearDown(container.dispose);

      final actions = container.read(desktopStartupActionsProvider);
      await actions.checkForDesktopUpdates();
      await actions.preloadPythonRuntime();

      expect(updateChecks, 1);
      expect(runtimeWarmups, 1);
    },
  );

  test(
    'startup runtime warmup suppresses local runtime loading failures',
    () async {
      final container = ProviderContainer(
        overrides: [
          desktopRuntimeWarmupProvider.overrideWithValue(
            () async => throw FileSystemException('data directory unavailable'),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(desktopStartupActionsProvider)
          .preloadPythonRuntime();
    },
  );

  test('startup actions hydrate analytics context through the seam', () async {
    var hydrations = 0;
    final container = ProviderContainer(
      overrides: [
        analyticsContextHydratorProvider.overrideWithValue(() async {
          hydrations += 1;
        }),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(desktopStartupActionsProvider)
        .hydrateAnalyticsContext();

    expect(hydrations, 1);
  });

  group('syncTelemetryEnabled', () {
    final sqliteAvailable = ensureSqliteRuntimeAvailable();

    Future<ProviderContainer> consentContainer({
      required AppPreferencesRepository repository,
      required FakeAnalyticsService analytics,
      required void Function() onHydrate,
    }) async {
      final appDataDir = Directory.systemTemp.createTempSync(
        'deploydash-telemetry-sync-test-',
      );
      debugOverrideAppDataDirectoryResolver(() async => appDataDir);
      debugOverrideAppAnalyticsService(analytics);
      final container = ProviderContainer(
        overrides: [
          appPreferencesRepositoryProvider.overrideWithValue(repository),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
          analyticsContextHydratorProvider.overrideWithValue(() async {
            onHydrate();
          }),
        ],
      );
      addTearDown(() async {
        container.dispose();
        debugOverrideAppAnalyticsService(null);
        debugResetAppDataDirectoryTestState();
        if (await appDataDir.exists()) {
          await appDataDir.delete(recursive: true);
        }
      });
      return container;
    }

    test('syncs the stored switch and reports once when unasked', () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = AppPreferencesRepository(database);
      final analytics = FakeAnalyticsService();
      var hydrations = 0;
      final container = await consentContainer(
        repository: repository,
        analytics: analytics,
        onHydrate: () => hydrations += 1,
      );

      await container
          .read(desktopStartupActionsProvider)
          .syncTelemetryEnabled();
      await container
          .read(desktopStartupActionsProvider)
          .syncTelemetryEnabled();

      // Unasked reads as on: one init, one applied switch, one app_started,
      // one hydration -- and the second call is a no-op.
      expect(analytics.initializeCallCount, 1);
      expect(analytics.setTelemetryCallCount, 1);
      expect(analytics.lastSetTelemetryEnabled, isTrue);
      expect(analytics.appStartedCallCount, 1);
      expect(hydrations, 1);
    }, skip: !sqliteAvailable);

    test('reports a previous crash as part of the on sync', () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = AppPreferencesRepository(database);
      await repository.setTelemetryEnabled(enabled: true);
      final analytics = FakeAnalyticsService();
      final container = await consentContainer(
        repository: repository,
        analytics: analytics,
        onHydrate: () {},
      );
      final crashStore = FileCrashMarkerStore(await resolveAppDataDirectory());
      crashStore.write(
        buildCrashMarkerPayload(
          errorType: 'StateError',
          timestamp: DateTime.utc(2026, 9, 10),
        ),
      );

      await container
          .read(desktopStartupActionsProvider)
          .syncTelemetryEnabled();

      expect(analytics.previousSessionCrashes, ['StateError']);
      expect(crashStore.markerFile.existsSync(), isFalse);
    }, skip: !sqliteAvailable);

    test('applies opt-out without reporting or hydrating', () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = AppPreferencesRepository(database);
      await repository.setTelemetryEnabled(enabled: false);
      final analytics = FakeAnalyticsService();
      var hydrations = 0;
      final container = await consentContainer(
        repository: repository,
        analytics: analytics,
        onHydrate: () => hydrations += 1,
      );
      final crashStore = FileCrashMarkerStore(await resolveAppDataDirectory());
      crashStore.write(
        buildCrashMarkerPayload(
          errorType: 'StateError',
          timestamp: DateTime.utc(2026, 9, 10),
        ),
      );

      await container
          .read(desktopStartupActionsProvider)
          .syncTelemetryEnabled();

      expect(analytics.initializeCallCount, 0);
      expect(analytics.setTelemetryCallCount, 1);
      expect(analytics.lastSetTelemetryEnabled, isFalse);
      expect(analytics.appStartedCallCount, 0);
      expect(analytics.previousSessionCrashes, isEmpty);
      expect(hydrations, 0);
      expect(crashStore.markerFile.existsSync(), isTrue);
    }, skip: !sqliteAvailable);

    test('never reports twice when already initialized', () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = AppPreferencesRepository(database);
      final analytics = FakeAnalyticsService();
      // As-shipped `main` already initialized and reported pre-unlock.
      await analytics.initialize();
      analytics.trackAppStarted();
      var hydrations = 0;
      final container = await consentContainer(
        repository: repository,
        analytics: analytics,
        onHydrate: () => hydrations += 1,
      );

      await container
          .read(desktopStartupActionsProvider)
          .syncTelemetryEnabled();

      expect(analytics.initializeCallCount, 1);
      expect(analytics.setTelemetryCallCount, 1);
      expect(analytics.lastSetTelemetryEnabled, isTrue);
      expect(analytics.appStartedCallCount, 1);
      expect(hydrations, 1);
    }, skip: !sqliteAvailable);
  });
}
