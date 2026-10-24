import 'dart:async';

import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/providers/terminal_view_preferences_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

Future<void> _flushAsync() async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
}

class _FakeAppPreferencesRepository implements AppPreferencesRepository {
  _FakeAppPreferencesRepository({
    AppPreferencesRecord? readValue,
    this.readError,
    this.writeError,
    this.readGate,
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
  final Completer<void>? readGate;
  final List<bool> writes = <bool>[];

  @override
  Future<AppPreferencesRecord> read() async {
    final gate = readGate;
    if (gate != null) {
      await gate.future;
    }
    if (readError != null) {
      throw readError!;
    }
    return readValue;
  }

  @override
  Future<void> setTerminalDebugView(bool enabled) async {
    writes.add(enabled);
    if (writeError != null) {
      throw writeError!;
    }
    readValue = AppPreferencesRecord(
      terminalDebugView: enabled,
      themeMode: readValue.themeMode,
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
  Future<void> setThemeMode(String mode) async {}

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

void main() {
  test('loads stored preference on first build', () async {
    final repository = _FakeAppPreferencesRepository(
      readValue: AppPreferencesRecord(
        terminalDebugView: true,
        themeMode: 'system',
        gitHubPendingOauthState: null,
        sqliteBackupS3Config: null,
        agentAccessEnabled: false,
        agentAccessPermissionMode: agentAccessPermissionReadOnly,
        agentSessionToken: null,
        agentSessionExpiresAt: null,
        updatedAt: DateTime.utc(2026, 2, 20),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        appPreferencesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(terminalDebugViewProvider), isFalse);
    await _flushAsync();
    expect(container.read(terminalDebugViewProvider), isTrue);
  });

  test('read failure falls back to false state', () async {
    final repository = _FakeAppPreferencesRepository(
      readError: StateError('boom'),
    );
    final container = ProviderContainer(
      overrides: [
        appPreferencesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    container.read(terminalDebugViewProvider);
    await _flushAsync();
    expect(container.read(terminalDebugViewProvider), isFalse);
  });

  test('setEnabled updates state immediately and persists value', () async {
    final repository = _FakeAppPreferencesRepository();
    final container = ProviderContainer(
      overrides: [
        appPreferencesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    container.read(terminalDebugViewProvider);
    await _flushAsync();

    await container.read(terminalDebugViewProvider.notifier).setEnabled(true);

    expect(container.read(terminalDebugViewProvider), isTrue);
    expect(repository.writes, <bool>[true]);
  });

  test('setEnabled keeps state even when persistence fails', () async {
    final repository = _FakeAppPreferencesRepository(
      writeError: StateError('write failed'),
    );
    final container = ProviderContainer(
      overrides: [
        appPreferencesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    container.read(terminalDebugViewProvider);
    await _flushAsync();
    await container.read(terminalDebugViewProvider.notifier).setEnabled(true);

    expect(container.read(terminalDebugViewProvider), isTrue);
    expect(repository.writes, <bool>[true]);
  });

  test('sqlite read failure falls back to false state', () async {
    final repository = _FakeAppPreferencesRepository(
      readError: sqlite.SqliteException(
        extendedResultCode: 1,
        message: 'disk I/O error',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        appPreferencesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    container.read(terminalDebugViewProvider);
    await _flushAsync();
    expect(container.read(terminalDebugViewProvider), isFalse);
  });

  test('setEnabled keeps state when persistence throws sqlite', () async {
    final repository = _FakeAppPreferencesRepository(
      writeError: sqlite.SqliteException(
        extendedResultCode: 1,
        message: 'disk I/O error',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        appPreferencesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    container.read(terminalDebugViewProvider);
    await _flushAsync();
    await container.read(terminalDebugViewProvider.notifier).setEnabled(true);

    expect(container.read(terminalDebugViewProvider), isTrue);
    expect(repository.writes, <bool>[true]);
  });

  test('setEnabled applies state before persistence completes', () async {
    final repository = _FakeAppPreferencesRepository();
    final container = ProviderContainer(
      overrides: [
        appPreferencesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    container.read(terminalDebugViewProvider);
    await _flushAsync();

    final pending = container
        .read(terminalDebugViewProvider.notifier)
        .setEnabled(true);
    expect(container.read(terminalDebugViewProvider), isTrue);
    await pending;
    expect(repository.writes, <bool>[true]);
  });

  test('load disposed before starting stays silent', () async {
    final repository = _FakeAppPreferencesRepository();
    final container = ProviderContainer(
      overrides: [
        appPreferencesRepositoryProvider.overrideWithValue(repository),
      ],
    );

    container.read(terminalDebugViewProvider);
    container.dispose();
    await _flushAsync();
    // Reached: the scheduled load saw the disposed container and returned
    // instead of throwing an unhandled async error.
    expect(true, isTrue);
  });

  test('load disposed mid-read stays silent', () async {
    final gate = Completer<void>();
    final repository = _FakeAppPreferencesRepository(readGate: gate);
    final container = ProviderContainer(
      overrides: [
        appPreferencesRepositoryProvider.overrideWithValue(repository),
      ],
    );

    container.read(terminalDebugViewProvider);
    await Future<void>.delayed(Duration.zero);
    container.dispose();
    gate.complete();
    await _flushAsync();
    expect(true, isTrue);
  });

  test('load disposed before error handling stays silent', () async {
    for (final error in [
      sqlite.SqliteException(extendedResultCode: 1, message: 'disk I/O error'),
      StateError('boom'),
    ]) {
      final gate = Completer<void>();
      final repository = _FakeAppPreferencesRepository(
        readGate: gate,
        readError: error,
      );
      final container = ProviderContainer(
        overrides: [
          appPreferencesRepositoryProvider.overrideWithValue(repository),
        ],
      );

      container.read(terminalDebugViewProvider);
      await Future<void>.delayed(Duration.zero);
      container.dispose();
      gate.complete();
      await _flushAsync();
    }
    expect(true, isTrue);
  });

  test('refresh rebuilds without rescheduling the load', () async {
    final repository = _FakeAppPreferencesRepository(
      readValue: AppPreferencesRecord(
        terminalDebugView: true,
        themeMode: 'system',
        gitHubPendingOauthState: null,
        sqliteBackupS3Config: null,
        agentAccessEnabled: false,
        agentAccessPermissionMode: agentAccessPermissionReadOnly,
        agentSessionToken: null,
        agentSessionExpiresAt: null,
        updatedAt: DateTime.utc(2026, 2, 20),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        appPreferencesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    container.read(terminalDebugViewProvider);
    await _flushAsync();
    expect(container.read(terminalDebugViewProvider), isTrue);

    // The init-once guard reuses the notifier: refresh re-runs build
    // (fallback, synchronously) but schedules no second load.
    expect(container.refresh(terminalDebugViewProvider), isFalse);
    await _flushAsync();
    expect(container.read(terminalDebugViewProvider), isFalse);
  });
}
