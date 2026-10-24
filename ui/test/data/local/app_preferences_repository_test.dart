import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('AppPreferencesRepository', () {
    late AppDatabase database;
    late AppPreferencesRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = AppPreferencesRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('read returns default seeded preferences row', () async {
      final record = await repository.read();

      expect(record.terminalDebugView, isFalse);
      expect(record.themeMode, 'system');
      expect(record.sqliteBackupS3Config, isNull);
      expect(record.updatedAt, isA<DateTime>());
    }, skip: !sqliteAvailable);

    test(
      'setTerminalDebugView persists and read returns updated state',
      () async {
        await repository.setTerminalDebugView(true);

        final record = await repository.read();
        expect(record.terminalDebugView, isTrue);
        expect(record.themeMode, 'system');
      },
      skip: !sqliteAvailable,
    );

    test('setThemeMode persists and normalizes values', () async {
      await repository.setThemeMode('DaRk');

      final record = await repository.read();
      expect(record.themeMode, 'dark');
    }, skip: !sqliteAvailable);

    test(
      'setSqliteBackupS3Config persists backup destination config',
      () async {
        await repository.setSqliteBackupS3Config(const <String, dynamic>{
          'bucket': 'deploydash-backups',
          'region': 'us-east-1',
          'prefix': 'sqlite',
        });

        final record = await repository.read();
        expect(record.sqliteBackupS3Config, isNotNull);
        expect(record.sqliteBackupS3Config?['bucket'], 'deploydash-backups');
      },
      skip: !sqliteAvailable,
    );

    test(
      'normalizeAgentAccessPermissionMode defaults invalid input to read only',
      () {
        expect(
          normalizeAgentAccessPermissionMode(' redeploy '),
          agentAccessPermissionRedeploy,
        );
        expect(
          normalizeAgentAccessPermissionMode('anything-else'),
          agentAccessPermissionReadOnly,
        );
      },
    );

    test('agent access settings and sessions persist through read', () async {
      final expiresAt = DateTime.now().add(const Duration(hours: 1));
      await repository.setAgentAccessEnabled(true);
      await repository.setAgentAccessPermissionMode(' redeploy ');
      await repository.issueAgentSession(
        token: '  session-token  ',
        expiresAt: expiresAt,
      );
      await repository.setGitHubPendingOauthState('  oauth-state  ');
      await repository.recordSqliteBackupRun(
        status: ' SUCCESS ',
        message: '  ok  ',
        runAt: DateTime.utc(2026, 4, 13, 12),
      );

      final record = await repository.read();
      expect(record.agentAccessEnabled, isTrue);
      expect(record.agentAccessPermissionMode, agentAccessPermissionRedeploy);
      expect(record.agentSessionToken, 'session-token');
      expect(record.agentSessionExpiresAt, isNotNull);
      expect(
        record.agentSessionExpiresAt!
            .difference(expiresAt)
            .inMilliseconds
            .abs(),
        lessThan(1000),
      );
      expect(record.hasActiveAgentSession, isTrue);
      expect(record.gitHubPendingOauthState, 'oauth-state');
      expect(record.sqliteBackupLastStatus, 'success');
      expect(record.sqliteBackupLastMessage, 'ok');
    }, skip: !sqliteAvailable);

    test(
      'read normalizes invalid stored values and clearAgentSession removes token',
      () async {
        final now = DateTime.now().subtract(const Duration(hours: 1));
        await database
            .into(database.appPreferences)
            .insertOnConflictUpdate(
              AppPreferencesCompanion(
                id: const Value(1),
                terminalDebugView: const Value(false),
                themeMode: const Value(''),
                gitHubPendingOauthState: const Value('   '),
                sqliteBackupS3ConfigJson: const Value('[]'),
                agentAccessEnabled: const Value(true),
                agentAccessPermissionMode: const Value('invalid-mode'),
                agentSessionToken: const Value('   expired-token   '),
                agentSessionExpiresAt: Value(now),
                updatedAt: Value(now),
              ),
            );

        var record = await repository.read();
        expect(record.themeMode, 'system');
        expect(record.gitHubPendingOauthState, isEmpty);
        expect(record.sqliteBackupS3Config, isNull);
        expect(record.agentAccessPermissionMode, agentAccessPermissionReadOnly);
        expect(record.agentSessionToken, 'expired-token');
        expect(record.hasActiveAgentSession, isFalse);

        await repository.clearAgentSession();
        record = await repository.read();
        expect(record.agentSessionToken, isNull);
        expect(record.agentSessionExpiresAt, isNull);
      },
      skip: !sqliteAvailable,
    );

    test(
      'issueAgentSession with blank token stores null session fields',
      () async {
        await repository.issueAgentSession(
          token: '   ',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        );

        final record = await repository.read();
        expect(record.agentSessionToken, isNull);
        expect(record.agentSessionExpiresAt, isNull);
      },
      skip: !sqliteAvailable,
    );
    test('analytics milestones start unset and persist write-once', () async {
      var record = await repository.read();
      expect(record.analyticsOnboardingCompletedAt, isNull);
      expect(record.analyticsFirstDeploySucceededAt, isNull);
      expect(record.analyticsGitHubConnectedAt, isNull);

      final firstReached = DateTime.utc(2026, 9, 1, 12);
      await repository.recordAnalyticsMilestone(
        AppUserAttribute.hasCompletedOnboarding,
        reachedAt: firstReached,
      );
      await repository.recordAnalyticsMilestone(
        AppUserAttribute.hasFirstDeploySucceeded,
      );
      await repository.recordAnalyticsMilestone(
        AppUserAttribute.hasConnectedGitHub,
        reachedAt: firstReached,
      );

      record = await repository.read();
      expect(record.analyticsOnboardingCompletedAt?.toUtc(), firstReached);
      expect(record.analyticsFirstDeploySucceededAt, isNotNull);
      expect(record.analyticsGitHubConnectedAt?.toUtc(), firstReached);

      // Write-once: recording again keeps the first-reached timestamp.
      await repository.recordAnalyticsMilestone(
        AppUserAttribute.hasCompletedOnboarding,
        reachedAt: DateTime.utc(2026, 10, 1, 12),
      );
      await repository.recordAnalyticsMilestone(
        AppUserAttribute.hasConnectedGitHub,
        reachedAt: DateTime.utc(2026, 10, 1, 12),
      );
      record = await repository.read();
      expect(record.analyticsOnboardingCompletedAt?.toUtc(), firstReached);
      expect(record.analyticsGitHubConnectedAt?.toUtc(), firstReached);
    }, skip: !sqliteAvailable);

    test(
      'recording a value bucket leaves milestone columns untouched',
      () async {
        await repository.recordAnalyticsMilestone(
          AppUserAttribute.serverCountBucket,
        );
        await repository.recordAnalyticsMilestone(
          AppUserAttribute.projectCountBucket,
        );
        await repository.recordAnalyticsMilestone(
          AppUserAttribute.deploysPerWeekBucket,
        );

        final record = await repository.read();
        expect(record.analyticsOnboardingCompletedAt, isNull);
        expect(record.analyticsFirstDeploySucceededAt, isNull);
        expect(record.analyticsGitHubConnectedAt, isNull);
      },
      skip: !sqliteAvailable,
    );

    test('telemetry starts on by default and persists either answer', () async {
      var record = await repository.read();
      expect(record.telemetryEnabled, isNull);

      await repository.setTelemetryEnabled(enabled: false);
      record = await repository.read();
      expect(record.telemetryEnabled, isFalse);

      await repository.setTelemetryEnabled(enabled: true);
      record = await repository.read();
      expect(record.telemetryEnabled, isTrue);
    }, skip: !sqliteAvailable);

    test('telemetry notice and nag moments are marked shown once', () async {
      await repository.markTelemetryNoticeShown();
      var record = await repository.read();
      expect(record.telemetryNoticeShownAt, isNotNull);
      expect(record.telemetryNagShownAt, isNull);

      await repository.markTelemetryNagShown();
      record = await repository.read();
      expect(record.telemetryNagShownAt, isNotNull);

      // Write-once: marking again keeps the first-shown timestamps.
      final noticeShownAt = record.telemetryNoticeShownAt;
      final nagShownAt = record.telemetryNagShownAt;
      await repository.markTelemetryNoticeShown();
      await repository.markTelemetryNagShown();
      record = await repository.read();
      expect(record.telemetryNoticeShownAt, noticeShownAt);
      expect(record.telemetryNagShownAt, nagShownAt);
    }, skip: !sqliteAvailable);

    test('read recreates row when preferences row is missing', () async {
      await (database.delete(
        database.appPreferences,
      )..where((table) => table.id.equals(1))).go();

      final record = await repository.read();
      final row =
          await (database.select(database.appPreferences)
                ..where((table) => table.id.equals(1))
                ..limit(1))
              .getSingleOrNull();

      expect(record.terminalDebugView, isFalse);
      expect(record.themeMode, 'system');
      expect(row, isNotNull);
      expect(row!.id, 1);
      expect(row.terminalDebugView, isFalse);
      expect(row.themeMode, 'system');
    }, skip: !sqliteAvailable);
  });
}
