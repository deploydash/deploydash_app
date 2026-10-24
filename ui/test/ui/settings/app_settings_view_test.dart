import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/agent_audit_repository.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/providers/agent_access_service.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/services/desktop_update_service.dart';
import 'package:ui/services/sqlite_backup_service.dart';
import 'package:ui/services/ssh_service.dart';
import 'package:ui/ui/settings/app_settings_view.dart';
import 'package:drift/native.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/fake_analytics_service.dart';
import '../../_support/sqlite_test_harness.dart';

class _SettingsUpdateController extends DesktopUpdateController {
  @override
  Future<DesktopUpdateSnapshot> build() async {
    return DesktopUpdateSnapshot.notChecked(
      const DesktopBuildInfo(version: '1.0.0', build: '1'),
    );
  }
}

class _FakeSqliteBackupService extends SqliteBackupService {
  _FakeSqliteBackupService({
    required this.onBackup,
    required this.onExport,
    this.onDownloadLatest,
    this.onVerify,
    required super.preferencesRepository,
  }) : super(databasePassphrase: 'test-passphrase');

  final Future<SqliteBackupRunResult> Function(SqliteBackupS3Config config)
  onBackup;
  final Future<File> Function(String destinationPath) onExport;
  final Future<SqliteBackupDownloadResult> Function(
    SqliteBackupS3Config config,
  )?
  onDownloadLatest;
  final Future<void> Function(SqliteBackupS3Config config)? onVerify;
  SqliteBackupS3Config? lastConfig;
  String? lastExportPath;
  SqliteBackupS3Config? lastDownloadConfig;
  SqliteBackupS3Config? lastVerifiedConfig;

  @override
  Future<SqliteBackupRunResult> backupNow({
    required SqliteBackupS3Config config,
  }) {
    lastConfig = config;
    return onBackup(config);
  }

  @override
  Future<File> exportNow({required String destinationPath}) {
    lastExportPath = destinationPath;
    return onExport(destinationPath);
  }

  @override
  Future<SqliteBackupDownloadResult> downloadLatestBackupFromS3({
    required SqliteBackupS3Config config,
  }) {
    lastDownloadConfig = config;
    final handler = onDownloadLatest;
    if (handler == null) {
      return Future<SqliteBackupDownloadResult>.error(UnimplementedError());
    }
    return handler(config);
  }

  @override
  Future<void> verifyS3Destination({
    required SqliteBackupS3Config config,
  }) async {
    lastVerifiedConfig = config;
    await onVerify?.call(config);
  }
}

class _ThrowingAppPreferencesRepository implements AppPreferencesRepository {
  _ThrowingAppPreferencesRepository({
    this.readError,
    this.setConfigError,
    this.themeMode = 'system',
    this.sqliteBackupS3Config,
  });

  final Object? readError;
  final Object? setConfigError;
  final String themeMode;
  final Map<String, dynamic>? sqliteBackupS3Config;

  @override
  Future<AppPreferencesRecord> read() async {
    if (readError != null) {
      throw readError!;
    }
    return AppPreferencesRecord(
      terminalDebugView: false,
      themeMode: themeMode,
      gitHubPendingOauthState: null,
      sqliteBackupS3Config: sqliteBackupS3Config,
      agentAccessEnabled: false,
      agentAccessPermissionMode: agentAccessPermissionReadOnly,
      updatedAt: DateTime.utc(2026, 1, 1),
    );
  }

  @override
  Future<void> recordSqliteBackupRun({
    required String status,
    String? message,
    DateTime? runAt,
  }) async {}

  @override
  Future<void> setSqliteBackupS3Config(Map<String, dynamic>? config) async {
    if (setConfigError != null) {
      throw setConfigError!;
    }
  }

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
  Future<void> setGitHubPendingOauthState(String? oauthState) async {}

  @override
  Future<void> setTerminalDebugView(bool enabled) async {}

  @override
  Future<void> setThemeMode(String mode) async {}

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

class _FakeFileSelectorPlatform extends FileSelectorPlatform {
  _FakeFileSelectorPlatform(this.saveLocationPath);

  final String? saveLocationPath;
  int saveLocationCallCount = 0;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    saveLocationCallCount += 1;
    final path = saveLocationPath;
    return path == null ? null : FileSaveLocation(path);
  }
}

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('AppSettingsView SQLite backup', () {
    late AppDatabase database;
    late AppPreferencesRepository repository;

    setUp(() {
      debugOverrideAppSettingsLocalBackupPickers();
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = AppPreferencesRepository(database);
    });

    tearDown(() async {
      debugOverrideAppSettingsLocalBackupPickers();
      await database.close();
    });

    Future<void> pumpSettingsView(
      WidgetTester tester, {
      required SqliteBackupService backupService,
      AppPreferencesRepository? preferencesRepository,
      LocalBackupExportPathPicker? pickExportPath,
      LocalBackupRestorePathPicker? pickRestorePath,
      AppDatabaseBackupPassphraseValidator? validateRestorePassphrase,
      AppDatabaseBackupFormatEnforcer? enforceBackupFormatVersion,
      AppDatabaseRestoreHandler? restoreBackupFile,
      AppDatabasePassphraseRotator? rotateDatabasePassphrase,
      AgentAccessStatusLoader? loadAgentAccessStatus,
      AgentAccessEnabledSetter? setAgentAccessEnabled,
      AgentAccessPermissionSetter? setAgentAccessPermissionMode,
      AgentAccessSessionIssuer? issueAgentAccessSession,
      AgentAccessSessionRevoker? revokeAgentAccessSession,
      ProviderContainer? container,
      bool useDefaultExportPathPicker = false,
      String destinationId = 'app-backup',
      String? initialDestinationId,
      ValueChanged<String>? onDestinationSelected,
    }) async {
      tester.view.physicalSize = const Size(1280, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final providerContainer =
          container ??
          ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(database),
              appPreferencesRepositoryProvider.overrideWithValue(
                preferencesRepository ?? repository,
              ),
              sqliteBackupServiceProvider.overrideWithValue(backupService),
              desktopUpdateControllerProvider.overrideWith(
                _SettingsUpdateController.new,
              ),
            ],
          );
      if (container == null) {
        addTearDown(providerContainer.dispose);
      }

      final effectiveLoadAgentAccessStatus =
          loadAgentAccessStatus ??
          () async => const AgentAccessStatusSnapshot(
            enabled: false,
            permissionMode: agentAccessPermissionReadOnly,
            serverRunning: false,
            port: deployDashAgentControlPort,
          );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: providerContainer,
          child: MaterialApp(
            home: Scaffold(
              body: useDefaultExportPathPicker
                  ? AppSettingsView(
                      pickRestorePath:
                          pickRestorePath ??
                          () async => '/tmp/restored-backup.db',
                      validateRestorePassphrase:
                          validateRestorePassphrase ??
                          ({required sourcePath, required passphrase}) async =>
                              true,
                      enforceBackupFormatVersion:
                          enforceBackupFormatVersion ??
                          ({required sourcePath, required passphrase}) async {},
                      restoreBackupFile:
                          restoreBackupFile ??
                          ({required sourcePath, overwriteExisting = false}) {
                            return Future<File>.value(File(sourcePath));
                          },
                      rotateDatabasePassphrase:
                          rotateDatabasePassphrase ??
                          ({
                            required database,
                            required currentPassphrase,
                            required newPassphrase,
                          }) async {},
                      loadAgentAccessStatus: effectiveLoadAgentAccessStatus,
                      setAgentAccessEnabled: setAgentAccessEnabled,
                      setAgentAccessPermissionMode:
                          setAgentAccessPermissionMode,
                      issueAgentAccessSession: issueAgentAccessSession,
                      revokeAgentAccessSession: revokeAgentAccessSession,
                      initialDestinationId: initialDestinationId,
                      onDestinationSelected: onDestinationSelected,
                    )
                  : AppSettingsView(
                      pickExportPath:
                          pickExportPath ??
                          (_) async => '/tmp/exported-backup.db',
                      pickRestorePath:
                          pickRestorePath ??
                          () async => '/tmp/restored-backup.db',
                      validateRestorePassphrase:
                          validateRestorePassphrase ??
                          ({required sourcePath, required passphrase}) async =>
                              true,
                      enforceBackupFormatVersion:
                          enforceBackupFormatVersion ??
                          ({required sourcePath, required passphrase}) async {},
                      restoreBackupFile:
                          restoreBackupFile ??
                          ({required sourcePath, overwriteExisting = false}) {
                            return Future<File>.value(File(sourcePath));
                          },
                      rotateDatabasePassphrase:
                          rotateDatabasePassphrase ??
                          ({
                            required database,
                            required currentPassphrase,
                            required newPassphrase,
                          }) async {},
                      loadAgentAccessStatus: effectiveLoadAgentAccessStatus,
                      setAgentAccessEnabled: setAgentAccessEnabled,
                      setAgentAccessPermissionMode:
                          setAgentAccessPermissionMode,
                      issueAgentAccessSession: issueAgentAccessSession,
                      revokeAgentAccessSession: revokeAgentAccessSession,
                      initialDestinationId: initialDestinationId,
                      onDestinationSelected: onDestinationSelected,
                    ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (destinationId != 'appearance') {
        await tester.tap(find.byKey(Key('app-settings-nav-$destinationId')));
        await tester.pumpAndSettle();
      }
    }

    Future<void> fillS3Form(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('app-settings-nav-app-backup')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('app-settings-s3-bucket-field')),
        'deploydash-backups',
      );
      await tester.enterText(
        find.byKey(const Key('app-settings-s3-region-field')),
        'us-east-1',
      );
      await tester.enterText(
        find.byKey(const Key('app-settings-s3-prefix-field')),
        'sqlite/backups',
      );
      await tester.enterText(
        find.byKey(const Key('app-settings-s3-access-key-field')),
        'AKIA_TEST',
      );
      await tester.enterText(
        find.byKey(const Key('app-settings-s3-secret-key-field')),
        'test-secret',
      );
      await tester.enterText(
        find.byKey(const Key('app-settings-s3-endpoint-field')),
        'https://s3.example.com',
      );
      await tester.tap(
        find.byKey(const Key('app-settings-s3-force-path-style-toggle')),
      );
      await tester.pumpAndSettle();
    }

    Future<void> testAndSaveS3Destination(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('app-settings-s3-save-button')));
      await tester.pumpAndSettle();
    }

    Future<void> ensurePasswordChangeButtonVisible(WidgetTester tester) async {
      if (find
          .byKey(const Key('app-settings-password-change-button'))
          .evaluate()
          .isEmpty) {
        await tester.tap(find.byKey(const Key('app-settings-nav-security')));
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(
        find.byKey(const Key('app-settings-password-change-button')),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows updated app backup labels', (tester) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(tester, backupService: backupService);
      await tester.tap(find.byKey(const Key('app-settings-nav-app-backup')));
      await tester.pumpAndSettle();

      expect(find.text('App backup'), findsNWidgets(2));
      expect(find.text('S3 destination'), findsOneWidget);
      expect(find.text('Create backup'), findsOneWidget);
      expect(find.text('Restore app data'), findsOneWidget);
      expect(find.text('Test and save destination'), findsOneWidget);
      expect(find.text('Backup to S3'), findsOneWidget);
      expect(find.text('Save local backup'), findsOneWidget);
      expect(find.text('Restore latest S3 backup'), findsOneWidget);
      expect(find.text('Restore a local backup'), findsOneWidget);
      expect(find.text('Latest result: No S3 backup run yet'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('app-settings-backup-run-button')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('app-settings-backup-restore-s3-button')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('app-settings-backup-export-button')),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        find.byKey(const Key('app-settings-s3-blocking-reason')),
        findsOneWidget,
      );

      final saveY = tester
          .getTopLeft(find.byKey(const Key('app-settings-s3-save-button')))
          .dy;
      final lastRunY = tester
          .getTopLeft(find.text('Latest result: No S3 backup run yet'))
          .dy;
      final backupY = tester
          .getTopLeft(find.byKey(const Key('app-settings-backup-run-button')))
          .dy;

      expect(saveY, lessThan(lastRunY));
      expect(lastRunY, lessThan(backupY));
    }, skip: !sqliteAvailable);

    testWidgets('reports a contextual settings destination selection', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );
      final selectedDestinationIds = <String>[];

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'appearance',
        onDestinationSelected: selectedDestinationIds.add,
      );
      await tester.tap(find.byKey(const Key('app-settings-nav-security')));
      await tester.pumpAndSettle();

      expect(selectedDestinationIds, ['security']);
    }, skip: !sqliteAvailable);

    testWidgets('settings navigation shows only the selected destination', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );
      await pumpSettingsView(tester, backupService: backupService);

      expect(
        find.byKey(const Key('app-context-navigation-app-settings-vertical')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('app-settings-nav-security')));
      await tester.pumpAndSettle();

      expect(
        tester
            .getSemantics(find.byKey(const Key('app-settings-nav-security')))
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      expect(
        find.byKey(const Key('app-settings-appearance-section')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('app-settings-security-section')),
        findsOneWidget,
      );
      expect(find.text('App lock password'), findsOneWidget);
    }, skip: !sqliteAvailable);

    testWidgets('Privacy destination switches usage reporting both ways', (
      tester,
    ) async {
      final analytics = FakeAnalyticsService();
      debugOverrideAppAnalyticsService(analytics);
      addTearDown(() => debugOverrideAppAnalyticsService(null));
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'privacy',
        initialDestinationId: 'privacy',
      );

      expect(
        find.byKey(const Key('app-settings-privacy-section')),
        findsOneWidget,
      );
      expect(find.text('What Deploy Dash collects'), findsOneWidget);
      expect(find.text('What is never collected'), findsOneWidget);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('app-settings-privacy-telemetry-toggle')),
            )
            .value,
        isTrue,
      );

      await tester.tap(
        find.byKey(const Key('app-settings-privacy-telemetry-toggle')),
      );
      await tester.pumpAndSettle();

      expect(analytics.setTelemetryCallCount, 1);
      expect(analytics.lastSetTelemetryEnabled, isFalse);
      expect((await repository.read()).telemetryEnabled, isFalse);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('app-settings-privacy-telemetry-toggle')),
            )
            .value,
        isFalse,
      );

      await tester.tap(
        find.byKey(const Key('app-settings-privacy-telemetry-toggle')),
      );
      await tester.pumpAndSettle();

      expect(analytics.setTelemetryCallCount, 2);
      expect(analytics.lastSetTelemetryEnabled, isTrue);
      expect((await repository.read()).telemetryEnabled, isTrue);
    }, skip: !sqliteAvailable);

    testWidgets('can open the Updates destination directly', (tester) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'updates',
        initialDestinationId: 'updates',
      );

      expect(
        tester
            .getSemantics(find.byKey(const Key('app-settings-nav-updates')))
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      expect(
        find.byKey(const Key('app-settings-updates-section')),
        findsOneWidget,
      );
    }, skip: !sqliteAvailable);

    testWidgets('reacts when the requested destination changes', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          appPreferencesRepositoryProvider.overrideWithValue(repository),
          sqliteBackupServiceProvider.overrideWithValue(backupService),
          desktopUpdateControllerProvider.overrideWith(
            _SettingsUpdateController.new,
          ),
        ],
      );
      addTearDown(container.dispose);

      await pumpSettingsView(
        tester,
        backupService: backupService,
        container: container,
        destinationId: 'appearance',
        initialDestinationId: 'appearance',
      );
      expect(
        find.byKey(const Key('app-settings-appearance-section')),
        findsOneWidget,
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: AppSettingsView(initialDestinationId: 'updates'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .getSemantics(find.byKey(const Key('app-settings-nav-updates')))
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      expect(
        find.byKey(const Key('app-settings-updates-section')),
        findsOneWidget,
      );
    }, skip: !sqliteAvailable);

    testWidgets('save destination persists S3 config and shows confirmation', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(tester, backupService: backupService);
      await fillS3Form(tester);

      await tester.tap(find.byKey(const Key('app-settings-s3-save-button')));
      await tester.pumpAndSettle();

      final record = await repository.read();
      expect(record.sqliteBackupS3Config, isNotNull);
      expect(record.sqliteBackupS3Config?['bucket'], 'deploydash-backups');
      expect(record.sqliteBackupS3Config?['region'], 'us-east-1');
      expect(record.sqliteBackupS3Config?['prefix'], 'sqlite/backups');
      expect(record.sqliteBackupS3Config?['access_key_id'], 'AKIA_TEST');
      expect(record.sqliteBackupS3Config?['secret_access_key'], 'test-secret');
      expect(
        record.sqliteBackupS3Config?['endpoint'],
        'https://s3.example.com',
      );
      expect(record.sqliteBackupS3Config?['force_path_style'], isTrue);
      expect(backupService.lastVerifiedConfig?.bucket, 'deploydash-backups');
      expect(find.text('S3 destination tested and saved.'), findsOneWidget);
      expect(find.text('Tested and ready'), findsOneWidget);
    }, skip: !sqliteAvailable);

    testWidgets(
      'S3 actions require a successful destination check and reset after edits',
      (tester) async {
        final backupService = _FakeSqliteBackupService(
          preferencesRepository: repository,
          onBackup: (_) async => throw UnimplementedError(),
          onExport: (_) async => throw UnimplementedError(),
        );
        await pumpSettingsView(tester, backupService: backupService);
        await fillS3Form(tester);
        await testAndSaveS3Destination(tester);

        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('app-settings-backup-run-button')),
              )
              .onPressed,
          isNotNull,
        );
        await tester.enterText(
          find.byKey(const Key('app-settings-s3-bucket-field')),
          'changed-bucket',
        );
        await tester.pumpAndSettle();

        expect(find.text('Setup required'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('app-settings-backup-run-button')),
              )
              .onPressed,
          isNull,
        );
      },
      skip: !sqliteAvailable,
    );

    testWidgets('failed destination check keeps S3 actions unavailable', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
        onVerify: (_) async => throw StateError('access denied'),
      );
      await pumpSettingsView(tester, backupService: backupService);
      await fillS3Form(tester);
      await testAndSaveS3Destination(tester);

      // G-38: 'Bad state: access denied' carries no S3 <Code>, so the mapper
      // falls back rather than guessing -- but the raw text is still reachable
      // behind the details reveal instead of being interpolated into the
      // sentence.
      expect(
        find.byKey(const Key('app-settings-s3-destination-error')),
        findsOneWidget,
      );
      expect(
        find.text('Deploy Dash could not reach the storage destination.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Bad state: access denied'),
        findsNothing,
        reason: 'raw provider text never appears on the primary path',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('app-settings-backup-run-button')),
            )
            .onPressed,
        isNull,
      );
    }, skip: !sqliteAvailable);

    testWidgets('loads existing SQLite backup settings from preferences', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );
      final preferencesRepository = _ThrowingAppPreferencesRepository(
        themeMode: 'dark',
        sqliteBackupS3Config: const <String, dynamic>{
          'bucket': 'saved-bucket',
          'region': 'eu-west-1',
          'prefix': 'saved/prefix',
          'access_key_id': 'SAVED_KEY',
          'secret_access_key': 'SAVED_SECRET',
          'endpoint': 'https://s3.saved.example.com',
          'force_path_style': true,
        },
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        preferencesRepository: preferencesRepository,
      );

      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('app-settings-s3-bucket-field')),
            )
            .controller!
            .text,
        'saved-bucket',
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('app-settings-s3-force-path-style-toggle')),
            )
            .value,
        isTrue,
      );
    }, skip: !sqliteAvailable);

    testWidgets('shows a load error when preferences cannot be read', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        preferencesRepository: _ThrowingAppPreferencesRepository(
          readError: StateError('preferences unavailable'),
        ),
      );

      expect(
        find.textContaining(
          'Couldn’t load app settings.\nBad state: preferences unavailable',
        ),
        findsOneWidget,
      );
    }, skip: !sqliteAvailable);

    testWidgets(
      'backup now persists config, runs service, and updates status',
      (tester) async {
        final backupService = _FakeSqliteBackupService(
          preferencesRepository: repository,
          onBackup: (config) async => SqliteBackupRunResult(
            objectKey: 'sqlite/backups/deploydash_state.db',
            completedAt: DateTime.utc(2026, 3, 15, 10, 30),
            message: 'Uploaded encrypted backup to s3://bucket/object',
          ),
          onExport: (_) async => throw UnimplementedError(),
        );

        await pumpSettingsView(tester, backupService: backupService);
        await fillS3Form(tester);
        await testAndSaveS3Destination(tester);

        await tester.tap(
          find.byKey(const Key('app-settings-backup-run-button')),
        );
        await tester.pumpAndSettle();

        final record = await repository.read();
        expect(record.sqliteBackupS3Config?['bucket'], 'deploydash-backups');
        expect(backupService.lastConfig, isNotNull);
        expect(backupService.lastConfig?.bucket, 'deploydash-backups');
        expect(find.text('Status: success'), findsOneWidget);
        expect(
          find.text('Uploaded encrypted backup to s3://bucket/object'),
          findsWidgets,
        );
      },
      skip: !sqliteAvailable,
    );

    testWidgets('backup now surfaces service failures in the UI', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async {
          throw StateError('database backup is locked');
        },
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(tester, backupService: backupService);
      await fillS3Form(tester);
      await testAndSaveS3Destination(tester);

      await tester.tap(find.byKey(const Key('app-settings-backup-run-button')));
      await tester.pumpAndSettle();

      expect(find.text('Status: failed'), findsOneWidget);
      expect(
        find.textContaining(
          'Couldn’t back up the local app database.\nBad state: database backup is locked',
        ),
        findsOneWidget,
      );
    }, skip: !sqliteAvailable);

    testWidgets('save destination validates required S3 fields', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(tester, backupService: backupService);
      await tester.tap(find.byKey(const Key('app-settings-s3-save-button')));
      await tester.pumpAndSettle();

      // G-39: the blocking reason beside the button already states the
      // missing field, so nothing else is rendered -- exactly one message,
      // not two, and not one in a card a hundred lines further down.
      expect(
        find.byKey(const Key('app-settings-s3-blocking-reason')),
        findsOneWidget,
      );
      expect(find.text('S3 bucket is required.'), findsOneWidget);
      expect(
        find.textContaining('FormatException'),
        findsNothing,
        reason: 'an exception type name is not user-facing copy',
      );
      expect(
        find.byKey(const Key('app-settings-s3-destination-error')),
        findsNothing,
        reason: 'local validation does not need a second slot',
      );
    }, skip: !sqliteAvailable);

    testWidgets(
      'a recognised S3 code becomes a sentence with the body behind a reveal',
      (tester) async {
        final backupService = _FakeSqliteBackupService(
          preferencesRepository: repository,
          onBackup: (_) async => throw UnimplementedError(),
          onExport: (_) async => throw UnimplementedError(),
          onVerify: (_) async => throw StateError(
            'S3 destination check failed with HTTP 403: '
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Error><Code>SignatureDoesNotMatch</Code>'
            '<Message>Signature validation failed</Message></Error>',
          ),
        );
        await pumpSettingsView(tester, backupService: backupService);
        await fillS3Form(tester);
        await testAndSaveS3Destination(tester);

        expect(
          find.text(
            'The secret access key is not correct for this access key ID.',
          ),
          findsOneWidget,
          reason: 'the primary path names what the user should change',
        );
        expect(
          find.textContaining('<Code>'),
          findsNothing,
          reason: 'provider XML never appears on the primary path (G-38)',
        );
        expect(
          find.byKey(const Key('app-settings-s3-destination-error-details')),
          findsOneWidget,
          reason: 'the raw body is still reachable, not discarded',
        );

        // G-39: beside the button that produced it, not in the actions card
        // a hundred lines further down.
        final errorY = tester
            .getTopLeft(
              find.byKey(const Key('app-settings-s3-destination-error')),
            )
            .dy;
        final buttonY = tester
            .getTopLeft(find.byKey(const Key('app-settings-s3-save-button')))
            .dy;
        expect(
          errorY - buttonY,
          lessThan(200),
          reason: 'the message sits with its control, not in another card',
        );
      },
      skip: !sqliteAvailable,
    );

    testWidgets(
      'the retention setting round-trips instead of resetting to the default',
      (tester) async {
        final backupService = _FakeSqliteBackupService(
          preferencesRepository: repository,
          onBackup: (_) async => throw UnimplementedError(),
          onExport: (_) async => throw UnimplementedError(),
          onVerify: (_) async {},
        );
        await pumpSettingsView(tester, backupService: backupService);
        await fillS3Form(tester);

        await tester.enterText(
          find.byKey(const Key('app-settings-s3-retention-field')),
          '30',
        );
        await tester.pumpAndSettle();
        await testAndSaveS3Destination(tester);

        final stored = (await repository.read()).sqliteBackupS3Config;
        expect(
          stored?['retention_keep_last'],
          30,
          reason:
              'G-44: saving the destination must not overwrite the '
              'retention the user chose with the default',
        );
      },
      skip: !sqliteAvailable,
    );

    testWidgets('a retention outside the supported range blocks saving', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
        onVerify: (_) async {},
      );
      await pumpSettingsView(tester, backupService: backupService);
      await fillS3Form(tester);

      await tester.enterText(
        find.byKey(const Key('app-settings-s3-retention-field')),
        '0',
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Retention keep last must be between 1 and 3650.'),
        findsOneWidget,
        reason: 'the blocking reason states the bound, beside the button',
      );
    }, skip: !sqliteAvailable);

    testWidgets('save destination surfaces repository failures', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );
      final preferencesRepository = _ThrowingAppPreferencesRepository(
        setConfigError: StateError('write failed'),
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        preferencesRepository: preferencesRepository,
      );
      await fillS3Form(tester);

      await tester.tap(find.byKey(const Key('app-settings-s3-save-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('app-settings-s3-destination-error')),
        findsOneWidget,
      );
      expect(
        find.text('Deploy Dash could not reach the storage destination.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Bad state: write failed'),
        findsNothing,
        reason: 'raw provider text never appears on the primary path',
      );
    }, skip: !sqliteAvailable);

    testWidgets('backup now validates required S3 fields before running', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(tester, backupService: backupService);
      final runButton = tester.widget<FilledButton>(
        find.byKey(const Key('app-settings-backup-run-button')),
      );
      expect(runButton.onPressed, isNull);
      expect(find.text('S3 bucket is required.'), findsOneWidget);
    }, skip: !sqliteAvailable);

    testWidgets('theme dropdown persists the selected theme mode', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'appearance',
      );

      await tester.tap(find.byKey(const Key('app-settings-theme-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark').last);
      await tester.pumpAndSettle();

      expect((await repository.read()).themeMode, 'dark');
    }, skip: !sqliteAvailable);

    testWidgets('export encrypted database file runs local export flow', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (destinationPath) async => File(destinationPath),
      );
      debugOverrideAppSettingsLocalBackupPickers(
        exportPathPicker: (_) async => '/tmp/local-encrypted-export.db',
      );

      await pumpSettingsView(tester, backupService: backupService);

      await tester.tap(
        find.byKey(const Key('app-settings-backup-export-button')),
      );
      await tester.pumpAndSettle();

      expect(backupService.lastExportPath, '/tmp/local-encrypted-export.db');
      expect(
        find.text(
          'Encrypted database exported to /tmp/local-encrypted-export.db.',
        ),
        findsOneWidget,
      );
    }, skip: !sqliteAvailable);

    testWidgets(
      'export encrypted database file returns early when user cancels save dialog',
      (tester) async {
        final backupService = _FakeSqliteBackupService(
          preferencesRepository: repository,
          onBackup: (_) async => throw UnimplementedError(),
          onExport: (destinationPath) async => File(destinationPath),
        );

        await pumpSettingsView(
          tester,
          backupService: backupService,
          pickExportPath: (_) async => null,
        );

        await tester.tap(
          find.byKey(const Key('app-settings-backup-export-button')),
        );
        await tester.pumpAndSettle();

        expect(backupService.lastExportPath, isNull);
      },
      skip: !sqliteAvailable,
    );

    testWidgets(
      'export encrypted database file uses default save picker path',
      (tester) async {
        final backupService = _FakeSqliteBackupService(
          preferencesRepository: repository,
          onBackup: (_) async => throw UnimplementedError(),
          onExport: (destinationPath) async => File(destinationPath),
        );
        final originalSelector = FileSelectorPlatform.instance;
        final selector = _FakeFileSelectorPlatform('/tmp/default-picker.db');
        FileSelectorPlatform.instance = selector;
        addTearDown(() => FileSelectorPlatform.instance = originalSelector);

        await pumpSettingsView(
          tester,
          backupService: backupService,
          useDefaultExportPathPicker: true,
        );

        await tester.tap(
          find.byKey(const Key('app-settings-backup-export-button')),
        );
        await tester.pumpAndSettle();

        expect(selector.saveLocationCallCount, 1);
        expect(backupService.lastExportPath, '/tmp/default-picker.db');
      },
      skip: !sqliteAvailable,
    );

    testWidgets('export encrypted database file surfaces export failures', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async {
          throw StateError('destination is not writable');
        },
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        pickExportPath: (_) async => '/tmp/local-encrypted-export.db',
      );

      await tester.tap(
        find.byKey(const Key('app-settings-backup-export-button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'Couldn’t save the encrypted database copy.\nBad state: destination is not '
          'writable',
        ),
        findsOneWidget,
      );
    }, skip: !sqliteAvailable);

    testWidgets('restore from S3 surfaces download failures in a modal', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
        onDownloadLatest: (_) async {
          throw StateError('bucket access denied');
        },
      );

      await pumpSettingsView(tester, backupService: backupService);
      await fillS3Form(tester);
      await testAndSaveS3Destination(tester);

      await tester.tap(
        find.byKey(const Key('app-settings-backup-restore-s3-button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Restore the latest S3 backup?'), findsOneWidget);
      expect(
        find.textContaining(
          'permanently replace the current local app database',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Replace app data from S3').last);
      await tester.pumpAndSettle();

      expect(backupService.lastDownloadConfig?.bucket, 'deploydash-backups');
      expect(
        find.textContaining(
          'Couldn’t restore the app backup.\nBad state: bucket access denied',
        ),
        findsWidgets,
      );
    }, skip: !sqliteAvailable);

    testWidgets('restore uses selected local backup file', (tester) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      final databases = <AppDatabase>[];
      final container = ProviderContainer(
        overrides: [
          initialDatabasePassphraseProvider.overrideWithValue(
            'test-passphrase',
          ),
          appDatabaseProvider.overrideWith((ref) {
            final database = AppDatabase.forTesting(NativeDatabase.memory());
            databases.add(database);
            return database;
          }),
          sqliteBackupServiceProvider.overrideWithValue(backupService),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(() async {
        for (final database in databases) {
          await database.close();
        }
      });

      String? validatedPath;
      String? restoredPath;
      debugOverrideAppSettingsLocalBackupPickers(
        restorePathPicker: () async => '/tmp/local-copy.db',
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        container: container,
        validateRestorePassphrase:
            ({required sourcePath, required passphrase}) async {
              validatedPath = sourcePath;
              return true;
            },
        restoreBackupFile:
            ({required sourcePath, overwriteExisting = false}) async {
              restoredPath = sourcePath;
              return File(sourcePath);
            },
      );

      await tester.tap(
        find.byKey(const Key('app-settings-backup-restore-local-button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Restore this local backup?'), findsOneWidget);
      expect(
        find.textContaining('including saved servers, projects, and settings'),
        findsOneWidget,
      );
      await tester.tap(find.text('Replace app data from local backup').last);
      await tester.pumpAndSettle();

      expect(validatedPath, '/tmp/local-copy.db');
      expect(restoredPath, '/tmp/local-copy.db');
      expect(
        find.textContaining('App backup restored from local-copy.db.'),
        findsOneWidget,
      );
    }, skip: !sqliteAvailable);

    testWidgets(
      'restore shows a modal when the selected backup does not match the current password',
      (tester) async {
        final backupService = _FakeSqliteBackupService(
          preferencesRepository: repository,
          onBackup: (_) async => throw UnimplementedError(),
          onExport: (_) async => throw UnimplementedError(),
        );

        final databases = <AppDatabase>[];
        final container = ProviderContainer(
          overrides: [
            initialDatabasePassphraseProvider.overrideWithValue(
              'test-passphrase',
            ),
            appDatabaseProvider.overrideWith((ref) {
              final database = AppDatabase.forTesting(NativeDatabase.memory());
              databases.add(database);
              return database;
            }),
            sqliteBackupServiceProvider.overrideWithValue(backupService),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(() async {
          for (final database in databases) {
            await database.close();
          }
        });

        await pumpSettingsView(
          tester,
          backupService: backupService,
          container: container,
          pickRestorePath: () async => '/tmp/old-password-backup.db',
          validateRestorePassphrase:
              ({required sourcePath, required passphrase}) async => false,
        );

        await tester.tap(
          find.byKey(const Key('app-settings-backup-restore-local-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Replace app data from local backup').last);
        await tester.pumpAndSettle();

        expect(find.text('Couldn\'t restore app backup'), findsOneWidget);
        expect(
          find.textContaining(
            'This backup does not match your current app password.',
          ),
          findsWidgets,
        );
      },
      skip: !sqliteAvailable,
    );

    testWidgets('password change validates mismatched new passwords', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'security',
      );

      expect(find.byTooltip('Show password'), findsNWidgets(3));
      await tester.tap(find.byTooltip('Show password').first);
      await tester.pump();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(
                  const Key('app-settings-password-current-field'),
                ),
                matching: find.byType(EditableText),
              ),
            )
            .obscureText,
        isFalse,
      );
      expect(find.byTooltip('Hide password'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('app-settings-password-current-field')),
        'current-password',
      );
      await tester.enterText(
        find.byKey(const Key('app-settings-password-new-field')),
        'new-password',
      );
      await tester.enterText(
        find.byKey(const Key('app-settings-password-confirm-field')),
        'different-password',
      );
      await ensurePasswordChangeButtonVisible(tester);

      await tester.tap(
        find.byKey(const Key('app-settings-password-change-button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('New passwords do not match.'), findsOneWidget);
      expect(
        find.text(
          'Existing exported or downloaded database files will still require '
          'the old password.',
        ),
        findsOneWidget,
      );
    }, skip: !sqliteAvailable);

    testWidgets('password change validates empty current password', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'security',
      );

      await tester.enterText(
        find.byKey(const Key('app-settings-password-new-field')),
        'new-password',
      );
      await tester.enterText(
        find.byKey(const Key('app-settings-password-confirm-field')),
        'new-password',
      );
      await ensurePasswordChangeButtonVisible(tester);

      await tester.tap(
        find.byKey(const Key('app-settings-password-change-button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Enter your current password.'), findsOneWidget);
    }, skip: !sqliteAvailable);

    testWidgets('password change validates empty new password', (tester) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'security',
      );

      await tester.enterText(
        find.byKey(const Key('app-settings-password-current-field')),
        'current-password',
      );
      await tester.enterText(
        find.byKey(const Key('app-settings-password-confirm-field')),
        'new-password',
      );
      await ensurePasswordChangeButtonVisible(tester);

      await tester.tap(
        find.byKey(const Key('app-settings-password-change-button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Enter a new password.'), findsOneWidget);
    }, skip: !sqliteAvailable);

    testWidgets('password change updates in-memory passphrase on success', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          appPreferencesRepositoryProvider.overrideWithValue(repository),
          sqliteBackupServiceProvider.overrideWithValue(backupService),
          initialDatabasePassphraseProvider.overrideWithValue(
            'current-password',
          ),
        ],
      );
      String? rotatedCurrentPassword;
      String? rotatedNewPassword;

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'security',
        container: container,
        rotateDatabasePassphrase:
            ({
              required database,
              required currentPassphrase,
              required newPassphrase,
            }) async {
              rotatedCurrentPassword = currentPassphrase;
              rotatedNewPassword = newPassphrase;
            },
      );

      await tester.enterText(
        find.byKey(const Key('app-settings-password-current-field')),
        'current-password',
      );
      await tester.enterText(
        find.byKey(const Key('app-settings-password-new-field')),
        'new-password',
      );
      await tester.enterText(
        find.byKey(const Key('app-settings-password-confirm-field')),
        'new-password',
      );
      await ensurePasswordChangeButtonVisible(tester);

      await tester.tap(
        find.byKey(const Key('app-settings-password-change-button')),
      );
      await tester.pumpAndSettle();

      expect(rotatedCurrentPassword, 'current-password');
      expect(rotatedNewPassword, 'new-password');
      expect(container.read(databasePassphraseProvider), 'new-password');
      expect(find.text('Password updated.'), findsOneWidget);
    }, skip: !sqliteAvailable);

    testWidgets('agent access controls load status and allow session actions', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );
      var setEnabledValue = false;
      String? permissionMode;
      var issueCount = 0;

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'agent-access',
        loadAgentAccessStatus: () async => AgentAccessStatusSnapshot(
          enabled: true,
          permissionMode: agentAccessPermissionRedeploy,
          serverRunning: true,
          port: deployDashAgentControlPort,
          recentActions: [
            AgentAuditEntryRecord(
              id: 1,
              toolName: 'deploydash_redeploy_web_app',
              accessLevel: 'redeploy',
              status: 'success',
              summary: 'Redeployed blog app.',
              details: {'task_id': 42},
              createdAt: DateTime.utc(2026, 4, 13, 10),
            ),
          ],
          runningTasks: [
            EngineTaskHistoryEntry(
              taskId: 42,
              status: 'running',
              code: null,
              message: 'Building image',
              cancelled: false,
              cooperativeCancel: false,
              startedAt: DateTime.utc(2026, 4, 13, 10, 5),
              completedAt: null,
              action: 'run_workflow',
              workflowId: 'app',
              operationId: 'run',
              clientOperationId: 'op-42',
              idempotencyKey: 'key-42',
            ),
          ],
          recentTaskResults: [
            EngineTaskHistoryEntry(
              taskId: 41,
              status: 'success',
              code: null,
              message: 'Deployment completed',
              cancelled: false,
              cooperativeCancel: false,
              startedAt: DateTime.utc(2026, 4, 13, 9, 55),
              completedAt: DateTime.utc(2026, 4, 13, 10),
              action: 'run_workflow',
              workflowId: 'app',
              operationId: 'run',
              clientOperationId: 'op-41',
              idempotencyKey: 'key-41',
            ),
          ],
        ),
        setAgentAccessEnabled: (enabled) async {
          setEnabledValue = enabled;
        },
        setAgentAccessPermissionMode: (mode) async {
          permissionMode = mode;
        },
        issueAgentAccessSession: () async {
          issueCount += 1;
          return 'new-session-token';
        },
      );

      expect(find.text('Agent Access'), findsNWidgets(2));
      expect(find.text('Local agent access'), findsOneWidget);
      expect(
        find.byKey(const Key('app-settings-agent-endpoint-text')),
        findsOneWidget,
      );
      expect(find.textContaining('Recent agent actions'), findsOneWidget);
      expect(find.textContaining('Redeployed blog app.'), findsOneWidget);
      expect(find.text('Current agent activity'), findsOneWidget);
      expect(
        find.textContaining('run 42 • running • Building image'),
        findsOneWidget,
      );
      expect(find.text('Recent redeploy results'), findsOneWidget);
      expect(
        find.textContaining('run 41 • success • Deployment completed'),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('app-settings-agent-issue-session-button')),
      );
      await tester.pumpAndSettle();
      expect(issueCount, 1);
      expect(find.text('Agent session issued.'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('app-settings-agent-permission-dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read-only').last);
      await tester.pumpAndSettle();
      expect(permissionMode, agentAccessPermissionReadOnly);

      await tester.tap(
        find.byKey(const Key('app-settings-agent-access-toggle')),
      );
      await tester.pumpAndSettle();
      expect(setEnabledValue, isFalse);
    }, skip: !sqliteAvailable);

    testWidgets(
      'agent access toggle reloads settings after a successful update',
      (tester) async {
        final backupService = _FakeSqliteBackupService(
          preferencesRepository: repository,
          onBackup: (_) async => throw UnimplementedError(),
          onExport: (_) async => throw UnimplementedError(),
        );
        var snapshot = const AgentAccessStatusSnapshot(
          enabled: false,
          permissionMode: agentAccessPermissionReadOnly,
          serverRunning: false,
          port: deployDashAgentControlPort,
        );

        await pumpSettingsView(
          tester,
          backupService: backupService,
          destinationId: 'agent-access',
          loadAgentAccessStatus: () async => snapshot,
          setAgentAccessEnabled: (enabled) async {
            snapshot = AgentAccessStatusSnapshot(
              enabled: enabled,
              permissionMode: agentAccessPermissionRedeploy,
              serverRunning: enabled,
              port: deployDashAgentControlPort,
            );
          },
        );

        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const Key('app-settings-agent-access-toggle')),
              )
              .value,
          isFalse,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(
                  const Key('app-settings-agent-issue-session-button'),
                ),
              )
              .onPressed,
          isNull,
        );

        await tester.tap(
          find.byKey(const Key('app-settings-agent-access-toggle')),
        );
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const Key('app-settings-agent-access-toggle')),
              )
              .value,
          isTrue,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(
                  const Key('app-settings-agent-issue-session-button'),
                ),
              )
              .onPressed,
          isNotNull,
        );
      },
      skip: !sqliteAvailable,
    );

    testWidgets('agent access remains interactive after enabling', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );
      var snapshot = const AgentAccessStatusSnapshot(
        enabled: false,
        permissionMode: agentAccessPermissionReadOnly,
        serverRunning: false,
        port: deployDashAgentControlPort,
      );
      var setEnabledCalls = 0;
      final permissionModes = <String>[];

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'agent-access',
        loadAgentAccessStatus: () async => snapshot,
        setAgentAccessEnabled: (enabled) async {
          setEnabledCalls += 1;
          snapshot = AgentAccessStatusSnapshot(
            enabled: enabled,
            permissionMode: snapshot.permissionMode,
            serverRunning: enabled,
            port: deployDashAgentControlPort,
          );
        },
        setAgentAccessPermissionMode: (mode) async {
          permissionModes.add(mode);
          snapshot = AgentAccessStatusSnapshot(
            enabled: snapshot.enabled,
            permissionMode: mode,
            serverRunning: snapshot.serverRunning,
            port: deployDashAgentControlPort,
          );
        },
      );

      await tester.tap(
        find.byKey(const Key('app-settings-agent-access-toggle')),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('app-settings-agent-permission-dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read-only + redeploy').last);
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('app-settings-agent-access-toggle')),
      );
      await tester.pumpAndSettle();

      expect(setEnabledCalls, 2);
      expect(permissionModes, <String>[agentAccessPermissionRedeploy]);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('app-settings-agent-access-toggle')),
            )
            .value,
        isFalse,
      );
    }, skip: !sqliteAvailable);

    testWidgets('agent access allows only one active session at a time', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );
      var issueCount = 0;
      var revokeCount = 0;

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'agent-access',
        loadAgentAccessStatus: () async => AgentAccessStatusSnapshot(
          enabled: true,
          permissionMode: agentAccessPermissionRedeploy,
          serverRunning: true,
          port: deployDashAgentControlPort,
          sessionToken: 'session-token-123',
          sessionExpiresAt: DateTime.utc(2099, 4, 29, 9),
        ),
        issueAgentAccessSession: () async {
          issueCount += 1;
          return 'should-not-be-issued';
        },
        revokeAgentAccessSession: () async {
          revokeCount += 1;
        },
      );

      expect(
        find.textContaining(
          'Only one redeploy session can be active at a time',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('app-settings-agent-issue-session-button')),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(
        find.byKey(const Key('app-settings-agent-revoke-session-button')),
      );
      await tester.pumpAndSettle();

      expect(issueCount, 0);
      expect(revokeCount, 1);
    }, skip: !sqliteAvailable);

    testWidgets('agent access surfaces control failures', (tester) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'agent-access',
        loadAgentAccessStatus: () async => const AgentAccessStatusSnapshot(
          enabled: true,
          permissionMode: agentAccessPermissionRedeploy,
          serverRunning: true,
          port: deployDashAgentControlPort,
        ),
        setAgentAccessEnabled: (_) async {
          throw StateError('toggle failed');
        },
        issueAgentAccessSession: () async {
          throw StateError('session failed');
        },
      );

      await tester.tap(
        find.byKey(const Key('app-settings-agent-access-toggle')),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Couldn’t update local agent access.'),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('app-settings-agent-issue-session-button')),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Couldn’t start a redeploy session.'),
        findsOneWidget,
      );
    }, skip: !sqliteAvailable);

    testWidgets('agent access shows mode revoke and server status errors', (
      tester,
    ) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'agent-access',
        loadAgentAccessStatus: () async => AgentAccessStatusSnapshot(
          enabled: true,
          permissionMode: agentAccessPermissionRedeploy,
          serverRunning: false,
          port: deployDashAgentControlPort,
          serverError: 'Bind failed.',
          sessionToken: 'session-token',
          sessionExpiresAt: DateTime.utc(2026, 4, 14, 9),
        ),
        setAgentAccessPermissionMode: (_) async {
          throw StateError('mode failed');
        },
        revokeAgentAccessSession: () async {
          throw StateError('revoke failed');
        },
      );

      expect(find.text('Bind failed.'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('app-settings-agent-permission-dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read-only').last);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Couldn’t update local agent access mode.'),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('app-settings-agent-revoke-session-button')),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Couldn’t end the redeploy session.'),
        findsOneWidget,
      );
    }, skip: !sqliteAvailable);

    testWidgets('password change surfaces rotation failures', (tester) async {
      final backupService = _FakeSqliteBackupService(
        preferencesRepository: repository,
        onBackup: (_) async => throw UnimplementedError(),
        onExport: (_) async => throw UnimplementedError(),
      );

      await pumpSettingsView(
        tester,
        backupService: backupService,
        destinationId: 'security',
        rotateDatabasePassphrase:
            ({
              required database,
              required currentPassphrase,
              required newPassphrase,
            }) async {
              throw StateError('Current password is incorrect.');
            },
      );

      await tester.enterText(
        find.byKey(const Key('app-settings-password-current-field')),
        'wrong-password',
      );
      await tester.enterText(
        find.byKey(const Key('app-settings-password-new-field')),
        'new-password',
      );
      await tester.enterText(
        find.byKey(const Key('app-settings-password-confirm-field')),
        'new-password',
      );
      await ensurePasswordChangeButtonVisible(tester);

      await tester.tap(
        find.byKey(const Key('app-settings-password-change-button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'Couldn’t update the app password.\nBad state: Current password is '
          'incorrect.',
        ),
        findsOneWidget,
      );
    }, skip: !sqliteAvailable);
  });
}
