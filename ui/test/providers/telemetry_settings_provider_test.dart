import 'dart:io';

import 'package:drift/native.dart';
import 'package:ui/data/local/app_data_directory.dart';
import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/models/telemetry_prompt.dart';
import 'package:ui/providers/desktop_startup_provider.dart';
import 'package:ui/providers/telemetry_settings_provider.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_support/fake_analytics_service.dart';
import '../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('TelemetrySettingsNotifier', () {
    late AppDatabase database;
    late AppPreferencesRepository repository;
    late FakeAnalyticsService analytics;
    late ProviderContainer container;

    setUp(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = AppPreferencesRepository(database);
      analytics = FakeAnalyticsService();
      final appDataDir = Directory.systemTemp.createTempSync(
        'deploydash-telemetry-settings-test-',
      );
      debugOverrideAppDataDirectoryResolver(() async => appDataDir);
      debugOverrideAppAnalyticsService(analytics);
      container = ProviderContainer(
        overrides: [
          appPreferencesRepositoryProvider.overrideWithValue(repository),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
          analyticsContextHydratorProvider.overrideWithValue(() async {}),
        ],
      );
      addTearDown(() async {
        container.dispose();
        debugOverrideAppAnalyticsService(null);
        debugResetAppDataDirectoryTestState();
        await database.close();
        if (await appDataDir.exists()) {
          await appDataDir.delete(recursive: true);
        }
      });
    });

    TelemetrySettingsNotifier notifier() =>
        container.read(telemetrySettingsProvider.notifier);

    TelemetrySettingsState settings() =>
        container.read(telemetrySettingsProvider);

    test('loads on and quiet before any milestone', () async {
      await notifier().load();

      expect(settings().enabled, isTrue);
      expect(settings().homeNag, isNull);
    }, skip: !sqliteAvailable);

    test('setEnabled persists the switch and the live service flag', () async {
      await notifier().load();

      await notifier().setEnabled(false);

      expect(settings().enabled, isFalse);
      final record = await repository.read();
      expect(record.telemetryEnabled, isFalse);
      expect(analytics.setTelemetryCallCount, 1);
      expect(analytics.lastSetTelemetryEnabled, isFalse);

      await notifier().setEnabled(true);

      expect(settings().enabled, isTrue);
      expect((await repository.read()).telemetryEnabled, isTrue);
      expect(analytics.setTelemetryCallCount, 2);
      expect(analytics.lastSetTelemetryEnabled, isTrue);
    }, skip: !sqliteAvailable);

    test('nags once after the first deploy while opted out', () async {
      await repository.setTelemetryEnabled(enabled: false);
      await repository.recordAnalyticsMilestone(
        AppUserAttribute.hasFirstDeploySucceeded,
      );

      await notifier().load();

      final nag = settings().homeNag;
      expect(nag, isNotNull);
      expect(nag!.moment, TelemetryMoment.homeNag);
    }, skip: !sqliteAvailable);

    test('answering the nag with share switches reporting back on', () async {
      await repository.setTelemetryEnabled(enabled: false);
      await repository.recordAnalyticsMilestone(
        AppUserAttribute.hasFirstDeploySucceeded,
      );
      await notifier().load();

      await notifier().answerNag(share: true);

      expect(settings().enabled, isTrue);
      expect(settings().homeNag, isNull);
      final record = await repository.read();
      expect(record.telemetryEnabled, isTrue);
      expect(record.telemetryNagShownAt, isNotNull);
      expect(analytics.setTelemetryCallCount, 1);
      expect(analytics.lastSetTelemetryEnabled, isTrue);
    }, skip: !sqliteAvailable);

    test('dismissing the nag keeps reporting off and never re-nags', () async {
      await repository.setTelemetryEnabled(enabled: false);
      await repository.recordAnalyticsMilestone(
        AppUserAttribute.hasFirstDeploySucceeded,
      );
      await notifier().load();

      await notifier().answerNag(share: false);

      expect(settings().enabled, isFalse);
      expect(settings().homeNag, isNull);
      final record = await repository.read();
      expect(record.telemetryEnabled, isFalse);
      expect(record.telemetryNagShownAt, isNotNull);
      expect(analytics.setTelemetryCallCount, 0);

      await notifier().refresh();

      expect(settings().homeNag, isNull);
    }, skip: !sqliteAvailable);

    test('markNoticeShown stamps the notice moment', () async {
      await notifier().load();

      await notifier().markNoticeShown();

      expect((await repository.read()).telemetryNoticeShownAt, isNotNull);
    }, skip: !sqliteAvailable);

    test('syncFromStored applies the stored switch to the service', () async {
      await repository.setTelemetryEnabled(enabled: false);

      final enabled = await notifier().syncFromStored();

      expect(enabled, isFalse);
      expect(settings().enabled, isFalse);
      expect(analytics.setTelemetryCallCount, 1);
      expect(analytics.lastSetTelemetryEnabled, isFalse);
    }, skip: !sqliteAvailable);

    test('loads on and quiet when the database is closed', () async {
      await repository.recordAnalyticsMilestone(
        AppUserAttribute.hasCompletedOnboarding,
      );
      await database.close();

      await notifier().load();

      expect(settings().enabled, isTrue);
      expect(settings().homeNag, isNull);
    }, skip: !sqliteAvailable);
  });
}
