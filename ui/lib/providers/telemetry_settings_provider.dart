import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_preferences_repository.dart';
import '../models/telemetry_prompt.dart';
import '../services/app_analytics_service.dart';

/// The usage-reporting switch plus the Home nag, loaded from preferences.
final telemetrySettingsProvider =
    NotifierProvider<TelemetrySettingsNotifier, TelemetrySettingsState>(
      TelemetrySettingsNotifier.new,
    );

/// Owns the default-on telemetry switch and the once-ever Home nag.
///
/// [TelemetrySettingsState.enabled] reads null storage as on. [homeNag] is
/// non-null only for the single post-first-deploy nag on explicitly
/// opted-out installs. Reads degrade to on-and-quiet: a closed database
/// must never crash a surface or invent a nag. Every switch flip writes
/// storage and the live service flag together, so no path can persist one
/// without the other.
class TelemetrySettingsNotifier extends Notifier<TelemetrySettingsState> {
  @override
  TelemetrySettingsState build() {
    return const TelemetrySettingsState(enabled: true);
  }

  /// Loads the switch and nag from storage. Called once per launch after
  /// unlock, when the encrypted database is readable.
  Future<void> load() async {
    state = await _settingsFromStorage();
  }

  /// Re-reads the switch and nag, after a milestone landed that may have
  /// earned the nag.
  Future<void> refresh() async {
    state = await _settingsFromStorage();
  }

  /// Flips the usage-reporting switch either way, in storage and on the
  /// live service together.
  Future<void> setEnabled(bool enabled) async {
    try {
      await ref
          .read(appPreferencesRepositoryProvider)
          .setTelemetryEnabled(enabled: enabled);
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Telemetry switch could not be stored: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Telemetry switch could not be stored: $error');
      }
    }
    ref.read(appAnalyticsServiceProvider).setTelemetryEnabled(enabled);
    state = TelemetrySettingsState(enabled: enabled, homeNag: state.homeNag);
  }

  /// Answers the Home nag: sharing switches reporting back on, dismissing
  /// keeps it off. Either way the nag moment is marked shown, so re-opting
  /// out later does not re-nag.
  Future<void> answerNag({required bool share}) async {
    try {
      final preferences = ref.read(appPreferencesRepositoryProvider);
      if (share) {
        await preferences.setTelemetryEnabled(enabled: true);
      }
      await preferences.markTelemetryNagShown();
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Telemetry nag answer could not be stored: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Telemetry nag answer could not be stored: $error');
      }
    }
    if (share) {
      ref.read(appAnalyticsServiceProvider).setTelemetryEnabled(true);
    }
    state = TelemetrySettingsState(
      enabled: share ? true : state.enabled,
      homeNag: null,
    );
  }

  /// Stamps the setup-progress notice as shown. Storage only: the notice's
  /// live switch already drives the service while setup runs.
  Future<void> markNoticeShown() async {
    try {
      await ref
          .read(appPreferencesRepositoryProvider)
          .markTelemetryNoticeShown();
    } on Exception catch (error) {
      if (kDebugMode) {
        debugPrint('Telemetry notice could not be marked shown: $error');
      }
    } on StateError catch (error) {
      if (kDebugMode) {
        debugPrint('Telemetry notice could not be marked shown: $error');
      }
    }
  }

  /// Reads storage, applies the stored switch to the live service, and
  /// returns the effective flag. The launch-sync path: ShellPage calls this
  /// post-unlock, then hydrates and reports from there.
  Future<bool> syncFromStored() async {
    final settings = await _settingsFromStorage();
    ref.read(appAnalyticsServiceProvider).setTelemetryEnabled(settings.enabled);
    state = settings;
    return settings.enabled;
  }

  Future<TelemetrySettingsState> _settingsFromStorage() async {
    try {
      final record = await ref.read(appPreferencesRepositoryProvider).read();
      return TelemetrySettingsState(
        enabled: record.telemetryEnabled ?? true,
        homeNag: telemetryPromptFor(
          firstDeploySucceededAt: record.analyticsFirstDeploySucceededAt,
          telemetryEnabled: record.telemetryEnabled,
          telemetryNagShownAt: record.telemetryNagShownAt,
        ),
      );
    } on Exception {
      return const TelemetrySettingsState(enabled: true);
    } on StateError {
      return const TelemetrySettingsState(enabled: true);
    }
  }
}

/// The usage-reporting switch and the Home nag.
class TelemetrySettingsState {
  /// Describes the current switch and nag.
  const TelemetrySettingsState({required this.enabled, this.homeNag});

  /// Effective switch: null storage reads as on.
  final bool enabled;

  /// The nag to show, or null when quiet.
  final TelemetryPrompt? homeNag;
}
