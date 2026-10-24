import 'dart:convert';
import 'dart:io';

import 'package:aws_common/aws_common.dart';
import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/services/sqlite_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

class _RecordedBackupRun {
  const _RecordedBackupRun({
    required this.status,
    required this.message,
    required this.runAt,
  });

  final String status;
  final String? message;
  final DateTime? runAt;
}

class _FakeAppPreferencesRepository implements AppPreferencesRepository {
  final List<_RecordedBackupRun> recordedRuns = <_RecordedBackupRun>[];

  @override
  Future<AppPreferencesRecord> read() async {
    return AppPreferencesRecord(
      terminalDebugView: false,
      themeMode: 'system',
      gitHubPendingOauthState: null,
      sqliteBackupS3Config: null,
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
  }) async {
    recordedRuns.add(
      _RecordedBackupRun(status: status, message: message, runAt: runAt),
    );
  }

  @override
  Future<void> setSqliteBackupS3Config(Map<String, dynamic>? config) async {}

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

class _BackupUploadCall {
  const _BackupUploadCall({
    required this.objectKey,
    required this.payloadPath,
    required this.payloadExistsDuringUpload,
    required this.payloadBytes,
  });

  final String objectKey;
  final String payloadPath;
  final bool payloadExistsDuringUpload;
  final List<int> payloadBytes;
}

void main() {
  const backupConfig = SqliteBackupS3Config(
    bucket: 'deploydash-backups',
    region: 'us-east-1',
    accessKeyId: 'AKIA_TEST',
    secretAccessKey: 'test-secret',
    prefix: 'sqlite/backups',
  );
  test('SqliteBackupS3Config validates required S3 fields', () {
    const config = SqliteBackupS3Config(
      bucket: '',
      region: 'us-east-1',
      accessKeyId: 'AKIA_TEST',
      secretAccessKey: 'secret',
      prefix: 'sqlite',
    );

    expect(config.validate, throwsFormatException);
  });

  test('SqliteBackupS3Config.fromJson decodes optional endpoint fields', () {
    final config = SqliteBackupS3Config.fromJson(const <String, dynamic>{
      'bucket': 'deploydash-backups',
      'region': 'us-east-1',
      'access_key_id': 'AKIA_TEST',
      'secret_access_key': 'test-secret',
      'prefix': 'sqlite/backups',
      'endpoint': 'https://s3.us-east-1.amazonaws.com',
      'force_path_style': true,
    });

    expect(config.bucket, 'deploydash-backups');
    expect(config.endpoint, 'https://s3.us-east-1.amazonaws.com');
    expect(config.forcePathStyle, isTrue);
  });

  test('SqliteBackupS3Config round-trips every stored field and default', () {
    final intRetention = SqliteBackupS3Config.fromJson(const <String, dynamic>{
      'bucket': ' bucket ',
      'region': ' region ',
      'access_key_id': ' key ',
      'secret_access_key': ' secret ',
      'prefix': ' prefix ',
      'endpoint': ' ',
      'retention_keep_last': 30,
    });
    final stringRetention = SqliteBackupS3Config.fromJson(
      const <String, dynamic>{'retention_keep_last': ' 14 '},
    );
    final invalidRetention = SqliteBackupS3Config.fromJson(
      const <String, dynamic>{'retention_keep_last': 'invalid'},
    );
    final defaulted = SqliteBackupS3Config.fromJson(const <String, dynamic>{});

    expect(intRetention.endpoint, isNull);
    expect(intRetention.retentionKeepLast, 30);
    expect(stringRetention.retentionKeepLast, 14);
    expect(invalidRetention.retentionKeepLast, 7);
    expect(defaulted.retentionKeepLast, 7);
    expect(intRetention.toJson(), <String, dynamic>{
      'bucket': 'bucket',
      'region': 'region',
      'access_key_id': 'key',
      'secret_access_key': 'secret',
      'prefix': 'prefix',
      'endpoint': null,
      'force_path_style': false,
      'retention_keep_last': 30,
    });
  });

  test('SqliteBackupS3Config rejects every invalid required boundary', () {
    final invalidConfigs = <SqliteBackupS3Config>[
      const SqliteBackupS3Config(
        bucket: 'bucket',
        region: '',
        accessKeyId: 'key',
        secretAccessKey: 'secret',
        prefix: '',
      ),
      const SqliteBackupS3Config(
        bucket: 'bucket',
        region: 'region',
        accessKeyId: '',
        secretAccessKey: 'secret',
        prefix: '',
      ),
      const SqliteBackupS3Config(
        bucket: 'bucket',
        region: 'region',
        accessKeyId: 'key',
        secretAccessKey: '',
        prefix: '',
      ),
      const SqliteBackupS3Config(
        bucket: 'bucket',
        region: 'region',
        accessKeyId: 'key',
        secretAccessKey: 'secret',
        prefix: '',
        retentionKeepLast: 0,
      ),
      const SqliteBackupS3Config(
        bucket: 'bucket',
        region: 'region',
        accessKeyId: 'key',
        secretAccessKey: 'secret',
        prefix: '',
        retentionKeepLast: 3651,
      ),
    ];

    for (final config in invalidConfigs) {
      expect(config.validate, throwsFormatException);
    }
    expect(backupConfig.validate, returnsNormally);
  });

  test(
    'backupNow fails fast when database passphrase is unavailable',
    () async {
      final repository = _FakeAppPreferencesRepository();
      final service = SqliteBackupService(
        databasePassphrase: null,
        preferencesRepository: repository,
      );

      await expectLater(
        () => service.backupNow(config: backupConfig),
        throwsA(isA<StateError>()),
      );
      expect(repository.recordedRuns, isEmpty);
    },
  );

  test(
    'exportNow fails fast when database passphrase is unavailable',
    () async {
      final repository = _FakeAppPreferencesRepository();
      final service = SqliteBackupService(
        databasePassphrase: null,
        preferencesRepository: repository,
      );

      await expectLater(
        () => service.exportNow(destinationPath: '/tmp/export.db'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Database passphrase is unavailable'),
          ),
        ),
      );
      expect(repository.recordedRuns, isEmpty);
    },
  );

  test(
    'backupNow records success and cleans up temporary snapshot files',
    () async {
      final repository = _FakeAppPreferencesRepository();
      final scratchDir = await Directory.systemTemp.createTemp(
        'deploydash-backup-success-',
      );
      final sourceFile = File('${scratchDir.path}/source.db')
        ..writeAsStringSync('source');
      late String createdSnapshotPath;
      _BackupUploadCall? uploadCall;
      var nowCallCount = 0;

      final service = SqliteBackupService(
        databasePassphrase: 'test-passphrase',
        preferencesRepository: repository,
        clock: () {
          nowCallCount += 1;
          return DateTime.utc(2026, 3, 15, 12, nowCallCount);
        },
        tempDirectoryFactory: () async => scratchDir,
        sourceFileResolver: () async => sourceFile,
        snapshotCreator:
            ({
              required sourcePath,
              required snapshotPath,
              required passphrase,
              required metadata,
            }) async {
              createdSnapshotPath = snapshotPath;
              expect(sourcePath, sourceFile.path);
              expect(passphrase, 'test-passphrase');
              expect(metadata.createdAtUtc, DateTime.utc(2026, 3, 15, 12, 1));
              await File(snapshotPath).writeAsString('encrypted snapshot');
            },
        uploader:
            ({
              required config,
              required objectKey,
              required payloadFile,
            }) async {
              uploadCall = _BackupUploadCall(
                objectKey: objectKey,
                payloadPath: payloadFile.path,
                payloadExistsDuringUpload: await payloadFile.exists(),
                payloadBytes: await payloadFile.readAsBytes(),
              );
            },
      );

      final result = await service.backupNow(config: backupConfig);

      expect(result.objectKey, startsWith('sqlite/backups/deploydash_state_'));
      expect(result.message, contains('s3://deploydash-backups/'));
      expect(uploadCall, isNotNull);
      expect(uploadCall!.objectKey, result.objectKey);
      expect(uploadCall!.payloadExistsDuringUpload, isTrue);
      expect(
        String.fromCharCodes(uploadCall!.payloadBytes),
        'encrypted snapshot',
      );
      expect(await File(createdSnapshotPath).exists(), isFalse);
      expect(await scratchDir.exists(), isFalse);
      expect(repository.recordedRuns, hasLength(1));
      expect(repository.recordedRuns.single.status, 'success');
      expect(repository.recordedRuns.single.message, result.message);
    },
  );

  test(
    'exportNow writes an encrypted snapshot without recording backup status',
    () async {
      final repository = _FakeAppPreferencesRepository();
      final sourceDir = await Directory.systemTemp.createTemp(
        'deploydash-export-success-',
      );
      addTearDown(() async {
        if (await sourceDir.exists()) {
          await sourceDir.delete(recursive: true);
        }
      });
      final sourceFile = File('${sourceDir.path}/source.db')
        ..writeAsStringSync('source');
      late String recordedSnapshotPath;

      final service = SqliteBackupService(
        databasePassphrase: 'test-passphrase',
        preferencesRepository: repository,
        clock: () => DateTime.utc(2026, 3, 15, 12, 34, 56),
        sourceFileResolver: () async => sourceFile,
        snapshotCreator:
            ({
              required sourcePath,
              required snapshotPath,
              required passphrase,
              required metadata,
            }) async {
              recordedSnapshotPath = snapshotPath;
              expect(sourcePath, sourceFile.path);
              expect(passphrase, 'test-passphrase');
              expect(
                metadata.createdAtUtc,
                DateTime.utc(2026, 3, 15, 12, 34, 56),
              );
              await File(snapshotPath).writeAsString('encrypted export');
            },
      );

      final destinationFile = File('${sourceDir.path}/exports/backup.db');
      final exportedFile = await service.exportNow(
        destinationPath: destinationFile.path,
      );

      expect(exportedFile.path, destinationFile.path);
      expect(await destinationFile.readAsString(), 'encrypted export');
      expect(await File(recordedSnapshotPath).exists(), isFalse);
      expect(repository.recordedRuns, isEmpty);
    },
  );

  test('exportNow replaces an existing destination file', () async {
    final repository = _FakeAppPreferencesRepository();
    final sourceDir = await Directory.systemTemp.createTemp(
      'deploydash-export-replace-',
    );
    addTearDown(() async {
      if (await sourceDir.exists()) {
        await sourceDir.delete(recursive: true);
      }
    });
    final sourceFile = File('${sourceDir.path}/source.db')
      ..writeAsStringSync('source');
    final destinationFile = File('${sourceDir.path}/backup.db')
      ..writeAsStringSync('stale-destination');

    final service = SqliteBackupService(
      databasePassphrase: 'test-passphrase',
      preferencesRepository: repository,
      sourceFileResolver: () async => sourceFile,
      snapshotCreator:
          ({
            required sourcePath,
            required snapshotPath,
            required passphrase,
            required metadata,
          }) async {
            await File(snapshotPath).writeAsString('fresh-encrypted-export');
          },
    );

    await service.exportNow(destinationPath: destinationFile.path);

    expect(await destinationFile.readAsString(), 'fresh-encrypted-export');
    expect(repository.recordedRuns, isEmpty);
  });

  test('exportNow rejects missing local database files', () async {
    final repository = _FakeAppPreferencesRepository();
    final sourceDir = await Directory.systemTemp.createTemp(
      'deploydash-export-missing-',
    );
    addTearDown(() async {
      if (await sourceDir.exists()) {
        await sourceDir.delete(recursive: true);
      }
    });

    final service = SqliteBackupService(
      databasePassphrase: 'test-passphrase',
      preferencesRepository: repository,
      sourceFileResolver: () async => File('${sourceDir.path}/missing.db'),
    );

    await expectLater(
      () => service.exportNow(destinationPath: '${sourceDir.path}/backup.db'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Local Deploy Dash database file is missing'),
        ),
      ),
    );
    expect(repository.recordedRuns, isEmpty);
  });

  test(
    'exportNow rejects using the live database path as the export target',
    () async {
      final repository = _FakeAppPreferencesRepository();
      final sourceDir = await Directory.systemTemp.createTemp(
        'deploydash-export-same-path-',
      );
      addTearDown(() async {
        if (await sourceDir.exists()) {
          await sourceDir.delete(recursive: true);
        }
      });
      final sourceFile = File('${sourceDir.path}/deploydash_state.db')
        ..writeAsStringSync('source');

      final service = SqliteBackupService(
        databasePassphrase: 'test-passphrase',
        preferencesRepository: repository,
        sourceFileResolver: () async => sourceFile,
      );

      await expectLater(
        () => service.exportNow(destinationPath: sourceFile.path),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('must be different from the live database path'),
          ),
        ),
      );
      expect(repository.recordedRuns, isEmpty);
    },
  );

  test('exportNow rejects empty destination paths', () async {
    final repository = _FakeAppPreferencesRepository();
    final service = SqliteBackupService(
      databasePassphrase: 'test-passphrase',
      preferencesRepository: repository,
    );

    await expectLater(
      () => service.exportNow(destinationPath: '   '),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Export destination path is required'),
        ),
      ),
    );
    expect(repository.recordedRuns, isEmpty);
  });

  test(
    'exportNow removes temporary export file on snapshot creation failure',
    () async {
      final repository = _FakeAppPreferencesRepository();
      final sourceDir = await Directory.systemTemp.createTemp(
        'deploydash-export-temp-cleanup-',
      );
      addTearDown(() async {
        if (await sourceDir.exists()) {
          await sourceDir.delete(recursive: true);
        }
      });
      final sourceFile = File('${sourceDir.path}/source.db')
        ..writeAsStringSync('source');
      final destinationFile = File('${sourceDir.path}/backup.db');
      final staleTempFile = File('${destinationFile.path}.exporting')
        ..writeAsStringSync('stale-temp');

      final service = SqliteBackupService(
        databasePassphrase: 'test-passphrase',
        preferencesRepository: repository,
        sourceFileResolver: () async => sourceFile,
        snapshotCreator:
            ({
              required sourcePath,
              required snapshotPath,
              required passphrase,
              required metadata,
            }) async {
              await File(snapshotPath).writeAsString('temp-data');
              throw StateError('snapshot failure');
            },
      );

      await expectLater(
        () => service.exportNow(destinationPath: destinationFile.path),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'snapshot failure',
          ),
        ),
      );

      expect(await staleTempFile.exists(), isFalse);
      expect(await destinationFile.exists(), isFalse);
      expect(repository.recordedRuns, isEmpty);
    },
  );

  test(
    'backupNow records failure when local database file is missing',
    () async {
      final repository = _FakeAppPreferencesRepository();
      final scratchDir = await Directory.systemTemp.createTemp(
        'deploydash-backup-missing-db-',
      );
      final missingSource = File('${scratchDir.path}/missing.db');

      final service = SqliteBackupService(
        databasePassphrase: 'test-passphrase',
        preferencesRepository: repository,
        tempDirectoryFactory: () async => scratchDir,
        sourceFileResolver: () async => missingSource,
      );

      await expectLater(
        () => service.backupNow(config: backupConfig),
        throwsA(isA<StateError>()),
      );

      expect(repository.recordedRuns, hasLength(1));
      expect(repository.recordedRuns.single.status, 'failed');
      expect(
        repository.recordedRuns.single.message,
        'Bad state: Local Deploy Dash database file is missing.',
      );
      expect(await scratchDir.exists(), isFalse);
    },
  );

  test('backupNow records failure when snapshot creation fails', () async {
    final repository = _FakeAppPreferencesRepository();
    final scratchDir = await Directory.systemTemp.createTemp(
      'deploydash-backup-snapshot-failure-',
    );
    final sourceFile = File('${scratchDir.path}/source.db')
      ..writeAsStringSync('source');
    var uploadInvoked = false;

    final service = SqliteBackupService(
      databasePassphrase: 'test-passphrase',
      preferencesRepository: repository,
      tempDirectoryFactory: () async => scratchDir,
      sourceFileResolver: () async => sourceFile,
      snapshotCreator:
          ({
            required sourcePath,
            required snapshotPath,
            required passphrase,
            required metadata,
          }) async {
            throw StateError('snapshot failed');
          },
      uploader:
          ({required config, required objectKey, required payloadFile}) async {
            uploadInvoked = true;
          },
    );

    await expectLater(
      () => service.backupNow(config: backupConfig),
      throwsA(isA<StateError>()),
    );

    expect(uploadInvoked, isFalse);
    expect(repository.recordedRuns, hasLength(1));
    expect(repository.recordedRuns.single.status, 'failed');
    expect(
      repository.recordedRuns.single.message,
      'Bad state: snapshot failed',
    );
    expect(await scratchDir.exists(), isFalse);
  });

  test(
    'backupNow records failure when upload fails and deletes snapshot',
    () async {
      final repository = _FakeAppPreferencesRepository();
      final scratchDir = await Directory.systemTemp.createTemp(
        'deploydash-backup-upload-failure-',
      );
      final sourceFile = File('${scratchDir.path}/source.db')
        ..writeAsStringSync('source');
      late String createdSnapshotPath;

      final service = SqliteBackupService(
        databasePassphrase: 'test-passphrase',
        preferencesRepository: repository,
        tempDirectoryFactory: () async => scratchDir,
        sourceFileResolver: () async => sourceFile,
        snapshotCreator:
            ({
              required sourcePath,
              required snapshotPath,
              required passphrase,
              required metadata,
            }) async {
              createdSnapshotPath = snapshotPath;
              await File(snapshotPath).writeAsString('encrypted snapshot');
            },
        uploader:
            ({
              required config,
              required objectKey,
              required payloadFile,
            }) async {
              expect(await payloadFile.exists(), isTrue);
              throw StateError('upload failed');
            },
      );

      await expectLater(
        () => service.backupNow(config: backupConfig),
        throwsA(isA<StateError>()),
      );

      expect(repository.recordedRuns, hasLength(1));
      expect(repository.recordedRuns.single.status, 'failed');
      expect(
        repository.recordedRuns.single.message,
        'Bad state: upload failed',
      );
      expect(await File(createdSnapshotPath).exists(), isFalse);
      expect(await scratchDir.exists(), isFalse);
    },
  );

  test(
    'backupNow uses the default temp directory and request sender wiring',
    () async {
      final repository = _FakeAppPreferencesRepository();
      final sourceDir = await Directory.systemTemp.createTemp(
        'deploydash-backup-default-wiring-',
      );
      final sourceFile = File('${sourceDir.path}/source.db')
        ..writeAsStringSync('source');
      String? createdSnapshotPath;

      final service = SqliteBackupService(
        databasePassphrase: 'test-passphrase',
        preferencesRepository: repository,
        clock: () => DateTime.utc(2026, 3, 16, 12, 34, 56),
        sourceFileResolver: () async => sourceFile,
        snapshotCreator:
            ({
              required sourcePath,
              required snapshotPath,
              required passphrase,
              required metadata,
            }) async {
              createdSnapshotPath = snapshotPath;
              await File(snapshotPath).writeAsString('encrypted snapshot');
            },
      );

      await expectLater(
        () => service.backupNow(
          config: const SqliteBackupS3Config(
            bucket: 'deploydash-backups',
            region: 'us-east-1',
            accessKeyId: 'AKIA_TEST',
            secretAccessKey: 'test-secret',
            prefix: 'sqlite/backups',
            endpoint: 'http://127.0.0.1:1',
            forcePathStyle: true,
          ),
        ),
        throwsA(anything),
      );

      expect(createdSnapshotPath, isNotNull);
      expect(
        createdSnapshotPath,
        contains('${Directory.systemTemp.path}/deploydash-backup-'),
      );
      expect(await File(createdSnapshotPath!).exists(), isFalse);
      expect(await sourceDir.exists(), isTrue);
      await sourceDir.delete(recursive: true);
    },
  );

  test('backupNow uploads snapshot to a custom S3 endpoint', () async {
    final repository = _FakeAppPreferencesRepository();
    final scratchDir = await Directory.systemTemp.createTemp(
      'deploydash-backup-real-upload-success-',
    );
    final sourceFile = File('${scratchDir.path}/source.db')
      ..writeAsStringSync('source');
    String? requestMethod;
    Uri? requestUri;
    String? hostHeader;
    List<int>? payloadBytes;

    final service = SqliteBackupService(
      databasePassphrase: 'test-passphrase',
      preferencesRepository: repository,
      clock: () => DateTime.utc(2026, 3, 16, 12, 34, 56),
      tempDirectoryFactory: () async => scratchDir,
      sourceFileResolver: () async => sourceFile,
      snapshotCreator:
          ({
            required sourcePath,
            required snapshotPath,
            required passphrase,
            required metadata,
          }) async {
            await File(snapshotPath).writeAsString('encrypted snapshot');
          },
      requestSender: (request) async {
        final readRequest = await request.read();
        if (readRequest.method.value == 'PUT') {
          requestMethod = readRequest.method.value;
          requestUri = readRequest.uri;
          hostHeader = readRequest.headers['host'];
          payloadBytes = readRequest.bodyBytes;
        }
        return AWSHttpResponse(statusCode: 200);
      },
    );

    final result = await service.backupNow(
      config: SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: 'sqlite/backups',
        endpoint: 'https://s3.example.test:9443',
        forcePathStyle: true,
      ),
    );

    expect(
      result.objectKey,
      'sqlite/backups/deploydash_state_20260316_123456.db',
    );
    expect(requestMethod, 'PUT');
    expect(
      requestUri?.path,
      '/deploydash-backups/sqlite/backups/deploydash_state_20260316_123456.db',
    );
    expect(hostHeader, 's3.example.test:9443');
    expect(String.fromCharCodes(payloadBytes!), 'encrypted snapshot');
  });

  test('backupNow surfaces S3 HTTP failures with response body', () async {
    final repository = _FakeAppPreferencesRepository();
    final scratchDir = await Directory.systemTemp.createTemp(
      'deploydash-backup-real-upload-failure-',
    );
    final sourceFile = File('${scratchDir.path}/source.db')
      ..writeAsStringSync('source');

    final service = SqliteBackupService(
      databasePassphrase: 'test-passphrase',
      preferencesRepository: repository,
      clock: () => DateTime.utc(2026, 3, 16, 12, 34, 56),
      tempDirectoryFactory: () async => scratchDir,
      sourceFileResolver: () async => sourceFile,
      snapshotCreator:
          ({
            required sourcePath,
            required snapshotPath,
            required passphrase,
            required metadata,
          }) async {
            await File(snapshotPath).writeAsString('encrypted snapshot');
          },
      requestSender: (request) async {
        final readRequest = await request.read();
        expect(readRequest.method.value, 'PUT');
        return AWSHttpResponse(
          statusCode: 500,
          body: 'storage unavailable'.codeUnits,
        );
      },
    );

    await expectLater(
      () => service.backupNow(
        config: SqliteBackupS3Config(
          bucket: 'deploydash-backups',
          region: 'us-east-1',
          accessKeyId: 'AKIA_TEST',
          secretAccessKey: 'test-secret',
          prefix: 'sqlite/backups',
          endpoint: 'https://s3.example.test:9443',
          forcePathStyle: true,
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.toString(),
          'message',
          contains('storage unavailable'),
        ),
      ),
    );
  });

  test(
    'verifyS3Destination accepts a readable destination and rejects failures',
    () async {
      var responseStatus = 200;
      Uri? requestedUri;
      final service = SqliteBackupService(
        databasePassphrase: 'test-passphrase',
        preferencesRepository: _FakeAppPreferencesRepository(),
        requestSender: (request) async {
          final readRequest = await request.read();
          requestedUri = readRequest.uri;
          return AWSHttpResponse(
            statusCode: responseStatus,
            body: utf8.encode(responseStatus == 200 ? '' : 'access denied'),
          );
        },
      );

      await service.verifyS3Destination(config: backupConfig);

      expect(requestedUri?.queryParameters['list-type'], '2');
      expect(requestedUri?.queryParameters['prefix'], 'sqlite/backups/');

      responseStatus = 403;
      await expectLater(
        () => service.verifyS3Destination(config: backupConfig),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('HTTP 403: access denied'),
          ),
        ),
      );
      await expectLater(
        () => service.verifyS3Destination(
          config: const SqliteBackupS3Config(
            bucket: '',
            region: '',
            accessKeyId: '',
            secretAccessKey: '',
            prefix: '',
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'downloadLatestBackupFromS3 lists and downloads the newest backup',
    () async {
      final repository = _FakeAppPreferencesRepository();
      final requests = <Uri>[];

      final service = SqliteBackupService(
        databasePassphrase: 'test-passphrase',
        preferencesRepository: repository,
        tempDirectoryFactory: () async =>
            Directory.systemTemp.createTemp('deploydash-download-latest-'),
        requestSender: (request) async {
          final readRequest = await request.read();
          requests.add(readRequest.uri);
          if (readRequest.uri.queryParameters['list-type'] == '2') {
            return AWSHttpResponse(
              statusCode: 200,
              body: utf8.encode(
                '<ListBucketResult>'
                '<Contents><Key>sqlite/backups/deploydash_state_20260419_120000.db</Key></Contents>'
                '<Contents><Key>sqlite/backups/deploydash_state_20260420_121500.db</Key></Contents>'
                '</ListBucketResult>',
              ),
            );
          }
          return AWSHttpResponse(
            statusCode: 200,
            body: utf8.encode('encrypted-backup-bytes'),
          );
        },
      );

      final result = await service.downloadLatestBackupFromS3(
        config: backupConfig,
      );

      expect(
        result.objectKey,
        'sqlite/backups/deploydash_state_20260420_121500.db',
      );
      expect(await result.localFile.readAsString(), 'encrypted-backup-bytes');
      expect(requests, hasLength(2));
      expect(requests.first.queryParameters['prefix'], 'sqlite/backups/');
      expect(
        requests.last.path,
        '/sqlite/backups/deploydash_state_20260420_121500.db',
      );
      await result.localFile.parent.delete(recursive: true);
    },
  );

  test(
    'downloadLatestBackupFromS3 fails when no backups exist in S3',
    () async {
      final service = SqliteBackupService(
        databasePassphrase: 'test-passphrase',
        preferencesRepository: _FakeAppPreferencesRepository(),
        requestSender: (request) async {
          return AWSHttpResponse(
            statusCode: 200,
            body: utf8.encode('<ListBucketResult></ListBucketResult>'),
          );
        },
      );

      await expectLater(
        () => service.downloadLatestBackupFromS3(config: backupConfig),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('No encrypted app backups were found'),
          ),
        ),
      );
    },
  );

  test(
    'download failures preserve status and optional provider details',
    () async {
      var downloadStatus = 404;
      var downloadBody = 'object missing';
      final service = SqliteBackupService(
        databasePassphrase: 'test-passphrase',
        preferencesRepository: _FakeAppPreferencesRepository(),
        requestSender: (request) async {
          final readRequest = await request.read();
          if (readRequest.uri.queryParameters['list-type'] == '2') {
            return AWSHttpResponse(
              statusCode: 200,
              body: utf8.encode(
                '<ListBucketResult><Contents><Key>'
                'sqlite/backups/deploydash_state_20260420_121500.db'
                '</Key></Contents></ListBucketResult>',
              ),
            );
          }
          return AWSHttpResponse(
            statusCode: downloadStatus,
            body: utf8.encode(downloadBody),
          );
        },
      );

      await expectLater(
        () => service.downloadLatestBackupFromS3(config: backupConfig),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('HTTP 404: object missing'),
          ),
        ),
      );
      downloadStatus = 199;
      downloadBody = '';
      await expectLater(
        () => service.downloadLatestBackupFromS3(config: backupConfig),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'S3 download failed with HTTP 199',
          ),
        ),
      );
    },
  );

  test(
    'listing failures preserve status and optional provider details',
    () async {
      var listStatus = 503;
      var listBody = 'service unavailable';
      final service = SqliteBackupService(
        databasePassphrase: 'test-passphrase',
        preferencesRepository: _FakeAppPreferencesRepository(),
        requestSender: (request) async => AWSHttpResponse(
          statusCode: listStatus,
          body: utf8.encode(listBody),
        ),
      );

      await expectLater(
        () => service.downloadLatestBackupFromS3(config: backupConfig),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('HTTP 503: service unavailable'),
          ),
        ),
      );
      listStatus = 199;
      listBody = '';
      await expectLater(
        () => service.downloadLatestBackupFromS3(config: backupConfig),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'S3 backup listing failed with HTTP 199',
          ),
        ),
      );
    },
  );

  test(
    'debug helpers cover request URI, endpoint, object key, and timestamp branches',
    () {
      final service = SqliteBackupService(
        databasePassphrase: 'test-passphrase',
        preferencesRepository: _FakeAppPreferencesRepository(),
      );

      expect(service.debugParseEndpoint(null), isNull);
      expect(service.debugParseEndpoint('   '), isNull);
      expect(
        service.debugParseEndpoint('s3.example.com')!.toString(),
        'https://s3.example.com',
      );
      expect(
        () => service.debugParseEndpoint('https://'),
        throwsFormatException,
      );

      expect(
        service.debugBuildObjectKey(r'//sqlite\backups//', 'backup.db'),
        'sqlite/backups/backup.db',
      );
      expect(service.debugBuildObjectKey('   ', 'backup.db'), 'backup.db');
      expect(
        service
            .debugBuildListRequestUri(
              config: backupConfig,
              continuationToken: 'token-1',
            )
            .toString(),
        'https://deploydash-backups.s3.us-east-1.amazonaws.com?list-type=2&prefix=sqlite%2Fbackups%2F&continuation-token=token-1',
      );
      final parsedListResponse = service.debugParseListObjectsResponse(
        '<ListBucketResult>'
        '<Contents><Key>sqlite/backups/deploydash_state_20260419_120000.db</Key></Contents>'
        '<NextContinuationToken>next-token</NextContinuationToken>'
        '</ListBucketResult>',
      );
      expect(parsedListResponse.objectKeys, [
        'sqlite/backups/deploydash_state_20260419_120000.db',
      ]);
      expect(parsedListResponse.nextContinuationToken, 'next-token');
      expect(
        service.debugTimestampSlug(DateTime.utc(2026, 3, 5, 4, 3, 2)),
        '20260305_040302',
      );

      final endpointConfig = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: 'sqlite/backups',
        endpoint: 'https://s3.example.com:9443',
      );
      expect(
        service
            .debugBuildRequestUri(
              config: endpointConfig,
              objectKey: 'sqlite/backups/backup.db',
            )
            .toString(),
        'https://deploydash-backups.s3.example.com:9443/sqlite/backups/backup.db',
      );
      expect(
        service
            .debugBuildRequestUri(
              config: SqliteBackupS3Config(
                bucket: 'deploydash-backups',
                region: 'us-east-1',
                accessKeyId: 'AKIA_TEST',
                secretAccessKey: 'test-secret',
                prefix: 'sqlite/backups',
                endpoint: 'https://s3.example.com:9443',
                forcePathStyle: true,
              ),
              objectKey: 'sqlite/backups/backup.db',
            )
            .toString(),
        'https://s3.example.com:9443/deploydash-backups/sqlite/backups/backup.db',
      );
      expect(
        service
            .debugBuildRequestUri(
              config: backupConfig,
              objectKey: 'sqlite/backups/backup.db',
            )
            .toString(),
        'https://deploydash-backups.s3.us-east-1.amazonaws.com/sqlite/backups/backup.db',
      );
      expect(
        service
            .debugBuildRequestUri(
              config: const SqliteBackupS3Config(
                bucket: 'deploydash-backups',
                region: 'us-east-1',
                accessKeyId: 'AKIA_TEST',
                secretAccessKey: 'test-secret',
                prefix: 'sqlite/backups',
                forcePathStyle: true,
              ),
              objectKey: 'sqlite/backups/backup.db',
            )
            .toString(),
        'https://s3.us-east-1.amazonaws.com/deploydash-backups/sqlite/backups/backup.db',
      );
      expect(
        service
            .debugBuildListRequestUri(
              config: endpointConfig,
              continuationToken: ' ',
            )
            .toString(),
        'https://deploydash-backups.s3.example.com:9443?list-type=2&prefix=sqlite%2Fbackups%2F',
      );
      expect(
        service
            .debugBuildListRequestUri(
              config: SqliteBackupS3Config(
                bucket: 'deploydash-backups',
                region: 'us-east-1',
                accessKeyId: 'AKIA_TEST',
                secretAccessKey: 'test-secret',
                prefix: '',
                endpoint: 'https://s3.example.com:9443',
                forcePathStyle: true,
              ),
            )
            .toString(),
        'https://s3.example.com:9443/deploydash-backups?list-type=2',
      );
      expect(
        service
            .debugBuildListRequestUri(
              config: const SqliteBackupS3Config(
                bucket: 'deploydash-backups',
                region: 'us-east-1',
                accessKeyId: 'AKIA_TEST',
                secretAccessKey: 'test-secret',
                prefix: '',
                forcePathStyle: true,
              ),
            )
            .toString(),
        'https://s3.us-east-1.amazonaws.com/deploydash-backups?list-type=2',
      );
      final decodedXml = service.debugParseListObjectsResponse(
        '<ListBucketResult><Contents><Key>'
        'a&amp;b&lt;c&gt;d&quot;e&apos;f'
        '</Key></Contents></ListBucketResult>',
      );
      expect(decodedXml.objectKeys, <String>[r'''a&b<c>d"e'f''']);
      expect(decodedXml.nextContinuationToken, isNull);
    },
  );

  test('consistent snapshots preserve schema and escaped provenance', () async {
    final directory = await Directory.systemTemp.createTemp(
      'deploydash-consistent-snapshot-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final sourcePath = '${directory.path}/source.db';
    final snapshotPath = '${directory.path}/snapshot.db';
    final source = sqlite.sqlite3.open(sourcePath);
    configureAppDatabaseEncryption(source, passphrase: 'test-passphrase');
    source.execute('PRAGMA user_version = 17;');
    source.execute('CREATE TABLE records (value TEXT NOT NULL);');
    source.execute("INSERT INTO records (value) VALUES ('preserved');");
    source.close();

    await createConsistentEncryptedSnapshot(
      sourcePath: sourcePath,
      snapshotPath: snapshotPath,
      passphrase: 'test-passphrase',
      metadata: SqliteBackupSnapshotMetadata(
        createdAtUtc: DateTime.utc(2026, 4, 20, 12, 15),
        appBuildName: "release'candidate",
        appBuildNumber: "42'b",
      ),
    );

    final snapshot = sqlite.sqlite3.open(snapshotPath);
    addTearDown(snapshot.close);
    configureAppDatabaseEncryption(snapshot, passphrase: 'test-passphrase');
    expect(snapshot.select('PRAGMA user_version;').single.columnAt(0), 17);
    expect(
      snapshot.select('SELECT value FROM records;').single['value'],
      'preserved',
    );
    final metadata = snapshot
        .select(
          'SELECT app_build_name, app_build_number, source_schema_version '
          'FROM deploydash_backup_metadata;',
        )
        .single;
    expect(metadata['app_build_name'], "release'candidate");
    expect(metadata['app_build_number'], "42'b");
    expect(metadata['source_schema_version'], 17);
  });

  test('provider wires repository and passphrase into backup service', () {
    final repository = _FakeAppPreferencesRepository();
    final container = ProviderContainer(
      overrides: [
        initialDatabasePassphraseProvider.overrideWithValue(
          'provider-passphrase',
        ),
        appPreferencesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    final service = container.read(sqliteBackupServiceProvider);

    expect(service.databasePassphrase, 'provider-passphrase');
    expect(identical(service.preferencesRepository, repository), isTrue);
  });
}
