import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_data_directory.dart';
import '../data/local/app_preferences_repository.dart';
import '../services/app_analytics_service.dart';
import 'telemetry_settings_provider.dart';
import '../services/desktop_runtime_warmup.dart';
import '../services/desktop_update_service.dart';
import '../services/device_identity_service.dart';

final desktopStartupActionsProvider = Provider<DesktopStartupActions>(
  DesktopStartupActions.new,
);

typedef DesktopUpdateChecker = Future<void> Function();

final desktopUpdateCheckerProvider = Provider<DesktopUpdateChecker>((ref) {
  return ref.read(desktopUpdateControllerProvider.notifier).check;
});

typedef DesktopRuntimeWarmup = Future<void> Function();

final desktopRuntimeWarmupProvider = Provider<DesktopRuntimeWarmup>(
  (ref) => warmupDesktopPythonRuntime,
);

/// Hydrates analytics context from the production store. Injectable so
/// widget tests never touch the real identity file or database.
typedef AnalyticsContextHydrator = Future<void> Function();

final analyticsContextHydratorProvider = Provider<AnalyticsContextHydrator>((
  ref,
) {
  return () => hydrateAnalyticsContext(
    preferences: ref.read(appPreferencesRepositoryProvider),
    loadIdentity: ref.read(deviceIdentityServiceProvider).loadOrCreate,
  );
});

/// Owns non-UI desktop startup work triggered after the shell is mounted.
class DesktopStartupActions {
  DesktopStartupActions(this._ref);

  final Ref _ref;

  /// Whether this launch already ran the telemetry sync below.
  /// `app_started` reports once per launch, between `main()` and this.
  bool _telemetrySyncDidRun = false;

  Future<void> checkForDesktopUpdates() {
    return _ref.read(desktopUpdateCheckerProvider)();
  }

  /// Fills the live analytics backends with stored production values.
  ///
  /// Runs after unlock, when the encrypted database is readable. Fail-closed
  /// inside: hydration degrades to the static context rather than surfacing.
  Future<void> hydrateAnalyticsContext() {
    return _ref.read(analyticsContextHydratorProvider)();
  }

  /// Applies the stored usage-reporting switch to the live service after
  /// unlock, then hydrates context and -- only when `main` did not already
  /// initialize and report pre-unlock -- reports a previous crash and the
  /// launch's `app_started`.
  ///
  /// The stored switch lives in the encrypted database, unreadable before
  /// unlock, so `main` runs the as-shipped init first and this applies the
  /// answer second: unasked reads as on, and an explicit off silences the
  /// initialized service with no further event and no hydration. Runs once
  /// per launch. Never throws: reporting must never break the shell it
  /// observes.
  Future<void> syncTelemetryEnabled() async {
    if (_telemetrySyncDidRun) {
      return;
    }
    _telemetrySyncDidRun = true;
    try {
      final service = _ref.read(appAnalyticsServiceProvider);
      final wasInitialized = service.isInitialized;
      final enabled = await _ref
          .read(telemetrySettingsProvider.notifier)
          .syncFromStored();
      if (!enabled) {
        return;
      }
      if (!wasInitialized) {
        await service.initialize();
        try {
          final crashStore = FileCrashMarkerStore(
            await resolveAppDataDirectory(),
          );
          reportPreviousSessionCrash(
            reader: crashStore.read,
            eraser: crashStore.erase,
          );
        } on Exception catch (error) {
          if (kDebugMode) {
            debugPrint(
              'Analytics crash report skipped; staying on schedule: $error',
            );
          }
        } on StateError catch (error) {
          if (kDebugMode) {
            debugPrint(
              'Analytics crash report skipped; staying on schedule: $error',
            );
          }
        }
        service.trackAppStarted();
      }
      await _ref.read(analyticsContextHydratorProvider)();
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Telemetry launch sync skipped; startup continues: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Telemetry launch sync skipped; startup continues: $error');
      }
    }
  }

  Future<void> preloadPythonRuntime() async {
    try {
      await _ref.read(desktopRuntimeWarmupProvider)();
    } on FileSystemException {
      // Runtime warmup is an optimisation; a user-initiated engine action can
      // surface an actionable data-directory failure later.
    } on ArgumentError {
      // Runtime warmup is an optimisation; later engine work surfaces the
      // bridge's detailed loader diagnostics.
    } on UnsupportedError {
      // Runtime warmup is an optimisation; later engine work surfaces the
      // bridge's detailed loader diagnostics.
    }
  }
}
