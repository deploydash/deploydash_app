import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../data/local/app_preferences_repository.dart';

/// A notifier that loads one persisted preference and writes it back.
///
/// Why: every persisted UI preference shares init-once + guarded load with
/// storage-fallback + optimistic write with swallowed errors; one owner keeps
/// the mounted-guard discipline (four checks) from drifting per preference.
abstract class PreferenceNotifier<T> extends Notifier<T> {
  bool _didInitialize = false;

  /// The value used before the load completes and when storage fails.
  T get fallback;

  /// Reads the preference from already-loaded preferences.
  T readFrom(AppPreferencesRecord preferences);

  /// Persists a new value.
  Future<void> writeTo(AppPreferencesRepository repository, T value);

  @override
  T build() {
    if (!_didInitialize) {
      _didInitialize = true;
      scheduleMicrotask(_loadFromDatabase);
    }
    return fallback;
  }

  Future<void> _loadFromDatabase() async {
    if (!ref.mounted) {
      return;
    }
    try {
      final preferences = await ref
          .read(appPreferencesRepositoryProvider)
          .read();
      if (!ref.mounted) {
        return;
      }
      state = readFrom(preferences);
    } on sqlite.SqliteException {
      if (!ref.mounted) {
        return;
      }
      state = fallback;
    } on StateError {
      // A database disposed during startup leaves the fallback in place;
      // the preference stays usable for this session.
      if (!ref.mounted) {
        return;
      }
      state = fallback;
    }
  }

  /// Optimistically applies [value], then persists it, swallowing storage
  /// errors.
  Future<void> saveValue(T value) async {
    state = value;
    try {
      await writeTo(ref.read(appPreferencesRepositoryProvider), value);
    } on sqlite.SqliteException {
      // The in-memory value remains usable for this session when storage
      // is temporarily unavailable; it can be retried on the next change.
    } on StateError {
      // A disposed local store cannot persist this optional preference.
    }
  }
}
