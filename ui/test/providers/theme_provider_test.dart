import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/providers/theme_provider.dart';

import '../../integration_test/support/e2e_checklist.dart';

Future<void> _flushAsync() async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
}

class _FakeAppPreferencesRepository implements AppPreferencesRepository {
  _FakeAppPreferencesRepository({
    AppPreferencesRecord? readValue,
    this.readError,
    this.writeError,
  }) : readValue =
           readValue ??
           AppPreferencesRecord(
             terminalDebugView: false,
             themeMode: 'system',
             gitHubPendingOauthState: null,
             sqliteBackupS3Config: null,
             agentAccessEnabled: false,
             agentAccessPermissionMode: agentAccessPermissionReadOnly,
             agentSessionToken: null,
             agentSessionExpiresAt: null,
             updatedAt: DateTime.utc(2026, 1, 1),
           );

  AppPreferencesRecord readValue;
  Object? readError;
  Object? writeError;
  final List<String> writes = <String>[];

  @override
  Future<AppPreferencesRecord> read() async {
    if (readError != null) {
      throw readError!;
    }
    return readValue;
  }

  @override
  Future<void> setTerminalDebugView(bool enabled) async {}

  @override
  Future<void> setThemeMode(String mode) async {
    writes.add(mode);
    if (writeError != null) {
      throw writeError!;
    }
    readValue = AppPreferencesRecord(
      terminalDebugView: readValue.terminalDebugView,
      themeMode: mode,
      gitHubPendingOauthState: readValue.gitHubPendingOauthState,
      sqliteBackupS3Config: readValue.sqliteBackupS3Config,
      sqliteBackupLastRunAt: readValue.sqliteBackupLastRunAt,
      sqliteBackupLastStatus: readValue.sqliteBackupLastStatus,
      sqliteBackupLastMessage: readValue.sqliteBackupLastMessage,
      agentAccessEnabled: readValue.agentAccessEnabled,
      agentAccessPermissionMode: readValue.agentAccessPermissionMode,
      agentSessionToken: readValue.agentSessionToken,
      agentSessionExpiresAt: readValue.agentSessionExpiresAt,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<void> setGitHubPendingOauthState(String? oauthState) async {}

  @override
  Future<void> setSqliteBackupS3Config(Map<String, dynamic>? config) async {}

  @override
  Future<void> recordSqliteBackupRun({
    required String status,
    String? message,
    DateTime? runAt,
  }) async {}

  @override
  Future<void> setAgentAccessEnabled(bool enabled) async {}

  @override
  Future<void> setAgentAccessPermissionMode(String mode) async {}

  @override
  Future<void> issueAgentSession({
    required String token,
    required DateTime expiresAt,
  }) async {}

  @override
  Future<void> clearAgentSession() async {}

  @override
  Future<void> recordAnalyticsMilestone(
    AppUserAttribute attribute, {
    DateTime? reachedAt,
  }) async {}

  @override
  Future<void> setTelemetryEnabled({required bool enabled}) async {}

  @override
  Future<void> markTelemetryNoticeShown() async {}

  @override
  Future<void> markTelemetryNagShown() async {}
}

AppPreferencesRecord _recordWithTheme(String themeMode) {
  return AppPreferencesRecord(
    terminalDebugView: false,
    themeMode: themeMode,
    gitHubPendingOauthState: null,
    sqliteBackupS3Config: null,
    agentAccessEnabled: false,
    agentAccessPermissionMode: agentAccessPermissionReadOnly,
    agentSessionToken: null,
    agentSessionExpiresAt: null,
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

void main() {
  group('ThemeNotifier (D-24)', () {
    test('loads stored theme after system fallback', () async {
      final repository = _FakeAppPreferencesRepository(
        readValue: _recordWithTheme('dark'),
      );
      final container = ProviderContainer(
        overrides: [
          appPreferencesRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(themeProvider), ThemeMode.system);
      await _flushAsync();
      expect(container.read(themeProvider), ThemeMode.dark);
    });

    test('maps stored theme strings', () async {
      for (final (stored, expected) in [
        ('light', ThemeMode.light),
        ('  Dark ', ThemeMode.dark),
        ('LIGHT', ThemeMode.light),
        ('system', ThemeMode.system),
        ('', ThemeMode.system),
        ('weird', ThemeMode.system),
      ]) {
        final repository = _FakeAppPreferencesRepository(
          readValue: _recordWithTheme(stored),
        );
        final container = ProviderContainer(
          overrides: [
            appPreferencesRepositoryProvider.overrideWithValue(repository),
          ],
        );
        addTearDown(container.dispose);

        container.read(themeProvider);
        await _flushAsync();
        expect(
          container.read(themeProvider),
          expected,
          reason: 'stored "$stored"',
        );
      }
    });

    test('setThemeMode persists mapped storage strings', () async {
      final repository = _FakeAppPreferencesRepository();
      final container = ProviderContainer(
        overrides: [
          appPreferencesRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);

      container.read(themeProvider);
      await _flushAsync();
      await container.read(themeProvider.notifier).setThemeMode(ThemeMode.dark);
      await container
          .read(themeProvider.notifier)
          .setThemeMode(ThemeMode.light);
      await container
          .read(themeProvider.notifier)
          .setThemeMode(ThemeMode.system);

      expect(repository.writes, ['dark', 'light', 'system']);
      expect(container.read(themeProvider), ThemeMode.system);
    });

    test('read failures fall back to system', () async {
      for (final error in [
        sqlite.SqliteException(
          extendedResultCode: 1,
          message: 'disk I/O error',
        ),
        StateError('boom'),
      ]) {
        final repository = _FakeAppPreferencesRepository(readError: error);
        final container = ProviderContainer(
          overrides: [
            appPreferencesRepositoryProvider.overrideWithValue(repository),
          ],
        );
        addTearDown(container.dispose);

        container.read(themeProvider);
        await _flushAsync();
        expect(container.read(themeProvider), ThemeMode.system);
      }
    });

    test('setThemeMode keeps state when persistence fails', () async {
      for (final error in [
        sqlite.SqliteException(
          extendedResultCode: 1,
          message: 'disk I/O error',
        ),
        StateError('write failed'),
      ]) {
        final repository = _FakeAppPreferencesRepository(writeError: error);
        final container = ProviderContainer(
          overrides: [
            appPreferencesRepositoryProvider.overrideWithValue(repository),
          ],
        );
        addTearDown(container.dispose);

        container.read(themeProvider);
        await _flushAsync();
        await container
            .read(themeProvider.notifier)
            .setThemeMode(ThemeMode.dark);

        expect(container.read(themeProvider), ThemeMode.dark);
        expect(repository.writes, ['dark']);
      }
    });

    test('setThemeMode applies state before persistence completes', () async {
      final repository = _FakeAppPreferencesRepository();
      final container = ProviderContainer(
        overrides: [
          appPreferencesRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);

      container.read(themeProvider);
      await _flushAsync();

      final pending = container
          .read(themeProvider.notifier)
          .setThemeMode(ThemeMode.dark);
      expect(container.read(themeProvider), ThemeMode.dark);
      await pending;
      expect(repository.writes, ['dark']);
    });
  });

  group('PreferenceNotifier collapsed base (D-24)', () {
    test('preference notifiers share one base', () {
      // Guard-style: both notifiers extend the shared base, and the base
      // keeps the four mounted checks the two files carried separately.
      final root = findRepositoryRoot();
      var extendsCount = 0;
      for (final file in [
        'terminal_view_preferences_provider.dart',
        'theme_provider.dart',
      ]) {
        final source = File(
          '${root.path}/ui/lib/providers/$file',
        ).readAsStringSync();
        extendsCount += 'extends PreferenceNotifier'.allMatches(source).length;
      }
      expect(extendsCount, 2);

      final base = File(
        '${root.path}/ui/lib/providers/preference_notifier.dart',
      ).readAsStringSync();
      expect('!ref.mounted'.allMatches(base).length, 4);
    });
  });
}
