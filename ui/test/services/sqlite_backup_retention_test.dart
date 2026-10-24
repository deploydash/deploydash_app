import 'dart:convert';
import 'dart:io';

import 'package:aws_common/aws_common.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/services/sqlite_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAppPreferencesRepository implements AppPreferencesRepository {
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
  }) async {}

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

String _buildListXml(List<String> keys) {
  final entries = keys.map((k) => '<Contents><Key>$k</Key></Contents>').join();
  return '<ListBucketResult>$entries</ListBucketResult>';
}

void main() {
  const config = SqliteBackupS3Config(
    bucket: 'deploydash-backups',
    region: 'us-east-1',
    accessKeyId: 'AKIA_TEST',
    secretAccessKey: 'test-secret',
    prefix: 'sqlite/backups',
    retentionKeepLast: 7,
  );

  final tenBackupKeys = List.generate(
    10,
    (i) =>
        'sqlite/backups/deploydash_state_202601${(i + 1).toString().padLeft(2, '0')}_000000.db',
  );

  late Directory scratchDir;
  late File sourceFile;

  setUp(() async {
    scratchDir = await Directory.systemTemp.createTemp(
      'backup-retention-test-',
    );
    sourceFile = File('${scratchDir.path}/source.db')
      ..writeAsStringSync('source');
  });

  tearDown(() async {
    if (await scratchDir.exists()) {
      await scratchDir.delete(recursive: true);
    }
  });

  SqliteBackupService createService({
    required bool uploadSucceeds,
    required String listResponseBody,
    required List<String> deletedKeys,
    int deleteStatusCode = 204,
    bool deleteThrows = false,
  }) {
    return SqliteBackupService(
      databasePassphrase: 'test-passphrase',
      preferencesRepository: _FakeAppPreferencesRepository(),
      clock: () => DateTime.utc(2026, 3, 16, 12, 0, 0),
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
        final method = readRequest.method.value;

        if (method == 'PUT') {
          if (!uploadSucceeds) {
            return AWSHttpResponse(
              statusCode: 500,
              body: utf8.encode('upload failed'),
            );
          }
          return AWSHttpResponse(statusCode: 200);
        }

        if (method == 'GET' &&
            readRequest.uri.queryParameters['list-type'] == '2') {
          return AWSHttpResponse(
            statusCode: 200,
            body: utf8.encode(listResponseBody),
          );
        }

        if (method == 'DELETE') {
          final objectKey = readRequest.uri.pathSegments.join('/');
          deletedKeys.add(objectKey);
          if (deleteThrows) {
            throw const SocketException('connection reset while deleting');
          }
          return AWSHttpResponse(statusCode: deleteStatusCode);
        }

        return AWSHttpResponse(statusCode: 200);
      },
    );
  }

  test('1. Upload fails -> zero deletes issued', () async {
    final deletedKeys = <String>[];
    final service = createService(
      uploadSucceeds: false,
      listResponseBody: _buildListXml(tenBackupKeys),
      deletedKeys: deletedKeys,
    );

    await expectLater(
      () => service.backupNow(config: config),
      throwsA(isA<StateError>()),
    );

    expect(deletedKeys, isEmpty);
  });

  test('2. Five objects, retention 7 -> zero deletes', () async {
    final deletedKeys = <String>[];
    final fiveKeys = tenBackupKeys.take(5).toList();
    final service = createService(
      uploadSucceeds: true,
      listResponseBody: _buildListXml(fiveKeys),
      deletedKeys: deletedKeys,
    );

    await service.backupNow(config: config);

    expect(deletedKeys, isEmpty);
  });

  test(
    '3. Ten objects, retention 7 -> exactly three deletes, and they are the three oldest by name',
    () async {
      final deletedKeys = <String>[];
      final service = createService(
        uploadSucceeds: true,
        listResponseBody: _buildListXml(tenBackupKeys),
        deletedKeys: deletedKeys,
      );

      await service.backupNow(config: config);

      expect(deletedKeys, [
        'sqlite/backups/deploydash_state_20260101_000000.db',
        'sqlite/backups/deploydash_state_20260102_000000.db',
        'sqlite/backups/deploydash_state_20260103_000000.db',
      ]);
    },
  );

  test('4. Malformed list response -> zero deletes', () async {
    final deletedKeys = <String>[];
    final service = createService(
      uploadSucceeds: true,
      listResponseBody: 'This is not valid S3 XML <Error>Some error</Error>',
      deletedKeys: deletedKeys,
    );

    await service.backupNow(config: config);

    expect(deletedKeys, isEmpty);
  });

  test(
    '5. Exactly seven objects, retention 7 -> zero deletes (boundary)',
    () async {
      final deletedKeys = <String>[];
      final sevenKeys = tenBackupKeys.take(7).toList();
      final service = createService(
        uploadSucceeds: true,
        listResponseBody: _buildListXml(sevenKeys),
        deletedKeys: deletedKeys,
      );

      await service.backupNow(config: config);

      expect(deletedKeys, isEmpty);
    },
  );

  test(
    '6. A delete the bucket refuses is reported, not counted as a clean prune',
    () async {
      final deletedKeys = <String>[];
      final service = createService(
        uploadSucceeds: true,
        listResponseBody: _buildListXml(tenBackupKeys),
        deletedKeys: deletedKeys,
        deleteStatusCode: 403,
      );

      final result = await service.backupNow(config: config);

      // The backup itself succeeded and must still be reported as success --
      // failing the run would mark a good backup as failed.
      expect(deletedKeys, hasLength(3));
      expect(
        result.message,
        contains('3 old backups could not be removed'),
        reason:
            'a refused delete must never be reported as a clean prune '
            '(G-44: the backend half removed the same swallowing)',
      );
      expect(result.message, contains('HTTP 403'));
    },
  );

  test('7. A listing the bucket refuses deletes nothing and says so', () async {
    final deletedKeys = <String>[];
    final service = createService(
      uploadSucceeds: true,
      listResponseBody: 'This is not valid S3 XML',
      deletedKeys: deletedKeys,
    );

    final result = await service.backupNow(config: config);

    expect(deletedKeys, isEmpty);
    expect(result.message, contains('old backups were not removed'));
  });

  test(
    '8. A delete that throws is reported, and the backup still succeeds',
    () async {
      final deletedKeys = <String>[];
      final service = createService(
        uploadSucceeds: true,
        listResponseBody: _buildListXml(tenBackupKeys),
        deletedKeys: deletedKeys,
        deleteThrows: true,
      );

      final result = await service.backupNow(config: config);

      expect(deletedKeys, hasLength(3), reason: 'every delete was attempted');
      expect(result.message, contains('3 old backups could not be removed'));
      expect(result.message, contains('connection reset while deleting'));
    },
  );
}
