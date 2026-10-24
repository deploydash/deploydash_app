import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_preferences_repository.dart';
import 'preference_notifier.dart';

class TerminalDebugViewNotifier extends PreferenceNotifier<bool> {
  @override
  bool get fallback => false;

  @override
  bool readFrom(AppPreferencesRecord preferences) =>
      preferences.terminalDebugView;

  @override
  Future<void> writeTo(AppPreferencesRepository repository, bool value) =>
      repository.setTerminalDebugView(value);

  Future<void> setEnabled(bool enabled) => saveValue(enabled);
}

final terminalDebugViewProvider =
    NotifierProvider<TerminalDebugViewNotifier, bool>(
      TerminalDebugViewNotifier.new,
    );
