import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_preferences_repository.dart';
import 'preference_notifier.dart';

class ThemeNotifier extends PreferenceNotifier<ThemeMode> {
  @override
  ThemeMode get fallback => ThemeMode.system;

  @override
  ThemeMode readFrom(AppPreferencesRecord preferences) =>
      _themeModeFromStorage(preferences.themeMode);

  @override
  Future<void> writeTo(AppPreferencesRepository repository, ThemeMode value) {
    final storageValue = switch (value) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    };
    return repository.setThemeMode(storageValue);
  }

  Future<void> setThemeMode(ThemeMode mode) => saveValue(mode);

  ThemeMode _themeModeFromStorage(String raw) {
    return switch (raw.trim().toLowerCase()) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }
}

final themeProvider = NotifierProvider<ThemeNotifier, ThemeMode>(
  ThemeNotifier.new,
);
