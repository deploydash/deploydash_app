import 'dart:convert';
import 'dart:io';

import 'package:aws_common/aws_common.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/services/sqlite_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _D4FakeAppPreferencesRepository implements AppPreferencesRepository {
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

String _d4ListXml(List<String> keys, {String? nextToken}) {
  final entries = keys.map((k) => '<Contents><Key>$k</Key></Contents>').join();
  final token = nextToken == null
      ? ''
      : '<NextContinuationToken>$nextToken</NextContinuationToken>';
  return '<ListBucketResult>$entries$token</ListBucketResult>';
}

/// D-4 backup-list/URI/status/prefix characterization.
///
/// Pins the byte-identical contracts before the collapse: prune's
/// listing-failure diagnostics (both paths), delete selection order,
/// delete-failure diagnostics, the three status messages with the body-suffix
/// rule, find-latest messages, S3 URI bytes for every builder branch,
/// prefix normalization, and multi-page pagination. The SQL twins are pinned
/// by the existing snapshot test
/// ('consistent snapshots preserve schema and escaped provenance'); direct
/// unit tests for the public SQL owners are added with the collapse.
void main() {
  const config = SqliteBackupS3Config(
    bucket: 'deploydash-backups',
    region: 'us-east-1',
    accessKeyId: 'AKIA_TEST',
    secretAccessKey: 'test-secret',
    prefix: 'sqlite/backups',
    retentionKeepLast: 7,
  );

  List<String> backupKeys(int count) => List.generate(
    count,
    (i) =>
        'sqlite/backups/deploydash_state_202601${(i + 1).toString().padLeft(2, '0')}_000000.db',
  );

  late Directory scratchDir;
  late File sourceFile;

  setUp(() async {
    scratchDir = await Directory.systemTemp.createTemp('backup-d4-test-');
    sourceFile = File('${scratchDir.path}/source.db')
      ..writeAsStringSync('source');
  });

  tearDown(() async {
    if (await scratchDir.exists()) {
      await scratchDir.delete(recursive: true);
    }
  });

  SqliteBackupService d4Service({
    required Future<AWSBaseHttpResponse> Function(AWSBaseHttpRequest request)
    onRequest,
  }) {
    return SqliteBackupService(
      databasePassphrase: 'test-passphrase',
      preferencesRepository: _D4FakeAppPreferencesRepository(),
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
      requestSender: onRequest,
    );
  }

  const uploadedPrefix =
      'Uploaded encrypted backup to '
      's3://deploydash-backups/sqlite/backups/'
      'deploydash_state_20260316_120000.db';

  group('D-4 prune diagnostics', () {
    test('a refused listing deletes nothing and names the status', () async {
      final deletedKeys = <String>[];
      final service = d4Service(
        onRequest: (request) async {
          final readRequest = await request.read();
          if (readRequest.uri.queryParameters['list-type'] == '2') {
            return AWSHttpResponse(
              statusCode: 503,
              body: utf8.encode('service unavailable'),
            );
          }
          if (readRequest.method.value == 'DELETE') {
            deletedKeys.add(readRequest.uri.pathSegments.join('/'));
            return AWSHttpResponse(statusCode: 204);
          }
          return AWSHttpResponse(statusCode: 200);
        },
      );

      final result = await service.backupNow(config: config);

      expect(deletedKeys, isEmpty);
      // Byte-exact: no provider body suffix on this path, no 'Bad state:'.
      expect(
        result.message,
        '$uploadedPrefix. Note: old backups were not removed: '
        'listing failed with HTTP 503',
      );
    });

    test('an empty-body refused listing renders the same diagnostic', () async {
      final service = d4Service(
        onRequest: (request) async {
          final readRequest = await request.read();
          if (readRequest.uri.queryParameters['list-type'] == '2') {
            return AWSHttpResponse(statusCode: 403, body: utf8.encode(''));
          }
          return AWSHttpResponse(statusCode: 200);
        },
      );

      final result = await service.backupNow(config: config);

      expect(
        result.message,
        '$uploadedPrefix. Note: old backups were not removed: '
        'listing failed with HTTP 403',
      );
    });

    test(
      'an unparseable listing deletes nothing and names the error',
      () async {
        final deletedKeys = <String>[];
        final service = d4Service(
          onRequest: (request) async {
            final readRequest = await request.read();
            if (readRequest.uri.queryParameters['list-type'] == '2') {
              return AWSHttpResponse(
                statusCode: 200,
                body: utf8.encode('not xml at all'),
              );
            }
            if (readRequest.method.value == 'DELETE') {
              deletedKeys.add(readRequest.uri.pathSegments.join('/'));
              return AWSHttpResponse(statusCode: 204);
            }
            return AWSHttpResponse(statusCode: 200);
          },
        );

        final result = await service.backupNow(config: config);

        expect(deletedKeys, isEmpty);
        expect(
          result.message,
          '$uploadedPrefix. Note: old backups were not removed: '
          'FormatException: Malformed S3 XML response: '
          'missing <ListBucketResult>',
        );
      },
    );

    test(
      'five keys with keep-last two deletes exactly the oldest three',
      () async {
        final deletedKeys = <String>[];
        final service = d4Service(
          onRequest: (request) async {
            final readRequest = await request.read();
            if (readRequest.uri.queryParameters['list-type'] == '2') {
              return AWSHttpResponse(
                statusCode: 200,
                body: utf8.encode(_d4ListXml(backupKeys(5))),
              );
            }
            if (readRequest.method.value == 'DELETE') {
              deletedKeys.add(readRequest.uri.pathSegments.join('/'));
              return AWSHttpResponse(statusCode: 204);
            }
            return AWSHttpResponse(statusCode: 200);
          },
        );

        const keepTwo = SqliteBackupS3Config(
          bucket: 'deploydash-backups',
          region: 'us-east-1',
          accessKeyId: 'AKIA_TEST',
          secretAccessKey: 'test-secret',
          prefix: 'sqlite/backups',
          retentionKeepLast: 2,
        );
        final result = await service.backupNow(config: keepTwo);

        expect(deletedKeys, [
          'sqlite/backups/deploydash_state_20260101_000000.db',
          'sqlite/backups/deploydash_state_20260102_000000.db',
          'sqlite/backups/deploydash_state_20260103_000000.db',
        ]);
        expect(result.message, uploadedPrefix);
      },
    );

    test('refused deletes name the count and the first error', () async {
      final service = d4Service(
        onRequest: (request) async {
          final readRequest = await request.read();
          if (readRequest.uri.queryParameters['list-type'] == '2') {
            return AWSHttpResponse(
              statusCode: 200,
              body: utf8.encode(_d4ListXml(backupKeys(5))),
            );
          }
          if (readRequest.method.value == 'DELETE') {
            return AWSHttpResponse(statusCode: 403);
          }
          return AWSHttpResponse(statusCode: 200);
        },
      );

      const keepThree = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: 'sqlite/backups',
        retentionKeepLast: 3,
      );
      final result = await service.backupNow(config: keepThree);

      expect(
        result.message,
        '$uploadedPrefix. Note: 2 old backups could not be removed '
        '(HTTP 403 on sqlite/backups/deploydash_state_20260101_000000.db)',
      );
    });
  });

  group('D-4 status messages', () {
    test('upload failure carries status and provider body exactly', () async {
      final service = d4Service(
        onRequest: (request) async {
          return AWSHttpResponse(
            statusCode: 500,
            body: utf8.encode('storage unavailable'),
          );
        },
      );

      await expectLater(
        () => service.backupNow(config: config),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'S3 upload failed with HTTP 500: storage unavailable',
          ),
        ),
      );
    });

    test('upload failure without a body has no suffix', () async {
      final service = d4Service(
        onRequest: (request) async {
          return AWSHttpResponse(statusCode: 500, body: utf8.encode(''));
        },
      );

      await expectLater(
        () => service.backupNow(config: config),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'S3 upload failed with HTTP 500',
          ),
        ),
      );
    });

    test('destination check without a body has no suffix', () async {
      final service = d4Service(
        onRequest: (request) async {
          return AWSHttpResponse(statusCode: 403, body: utf8.encode('  '));
        },
      );

      await expectLater(
        () => service.verifyS3Destination(config: config),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'S3 destination check failed with HTTP 403',
          ),
        ),
      );
    });

    test('download failure carries status and provider body exactly', () async {
      final service = d4Service(
        onRequest: (request) async {
          final readRequest = await request.read();
          if (readRequest.uri.queryParameters['list-type'] == '2') {
            return AWSHttpResponse(
              statusCode: 200,
              body: utf8.encode(_d4ListXml(backupKeys(1))),
            );
          }
          return AWSHttpResponse(
            statusCode: 404,
            body: utf8.encode('object missing'),
          );
        },
      );

      await expectLater(
        () => service.downloadLatestBackupFromS3(config: config),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'S3 download failed with HTTP 404: object missing',
          ),
        ),
      );
    });
  });

  group('D-4 find-latest messages', () {
    test('an empty destination names itself exactly', () async {
      final service = d4Service(
        onRequest: (request) async {
          return AWSHttpResponse(
            statusCode: 200,
            body: utf8.encode('<ListBucketResult></ListBucketResult>'),
          );
        },
      );

      await expectLater(
        () => service.downloadLatestBackupFromS3(config: config),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'No encrypted app backups were found in this S3 destination.',
          ),
        ),
      );
    });

    test(
      'a refused listing carries status and provider body exactly',
      () async {
        final service = d4Service(
          onRequest: (request) async {
            return AWSHttpResponse(
              statusCode: 503,
              body: utf8.encode('service unavailable'),
            );
          },
        );

        await expectLater(
          () => service.downloadLatestBackupFromS3(config: config),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'S3 backup listing failed with HTTP 503: service unavailable',
            ),
          ),
        );
      },
    );
  });

  group('D-4 S3 URIs', () {
    late SqliteBackupService service;

    setUp(() {
      service = d4Service(
        onRequest: (request) async => AWSHttpResponse(statusCode: 200),
      );
    });

    test('object URIs cover the endpoint/path-style matrix', () {
      const objectKey = 'sqlite/backups/deploydash_state_20260316_120000.db';
      const aws = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: 'sqlite/backups',
      );
      const awsPath = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: 'sqlite/backups',
        forcePathStyle: true,
      );
      const custom = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: 'sqlite/backups',
        endpoint: 'https://s3.example.test:9443',
      );
      const customPath = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: 'sqlite/backups',
        endpoint: 'https://s3.example.test:9443',
        forcePathStyle: true,
      );

      expect(
        service
            .debugBuildRequestUri(config: aws, objectKey: objectKey)
            .toString(),
        'https://deploydash-backups.s3.us-east-1.amazonaws.com/$objectKey',
      );
      expect(
        service
            .debugBuildRequestUri(config: awsPath, objectKey: objectKey)
            .toString(),
        'https://s3.us-east-1.amazonaws.com/deploydash-backups/$objectKey',
      );
      expect(
        service
            .debugBuildRequestUri(config: custom, objectKey: objectKey)
            .toString(),
        'https://deploydash-backups.s3.example.test:9443/$objectKey',
      );
      expect(
        service
            .debugBuildRequestUri(config: customPath, objectKey: objectKey)
            .toString(),
        'https://s3.example.test:9443/deploydash-backups/$objectKey',
      );
    });

    test('list URIs cover the endpoint/path-style matrix', () {
      const aws = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: 'sqlite/backups',
      );
      const awsPath = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: 'sqlite/backups',
        forcePathStyle: true,
      );
      const custom = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: 'sqlite/backups',
        endpoint: 's3.example.test',
      );
      const customPath = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: 'sqlite/backups',
        endpoint: 's3.example.test',
        forcePathStyle: true,
      );
      const query = 'list-type=2&prefix=sqlite%2Fbackups%2F';

      expect(
        service.debugBuildListRequestUri(config: aws).toString(),
        'https://deploydash-backups.s3.us-east-1.amazonaws.com?$query',
      );
      expect(
        service.debugBuildListRequestUri(config: awsPath).toString(),
        'https://s3.us-east-1.amazonaws.com/deploydash-backups?$query',
      );
      expect(
        service.debugBuildListRequestUri(config: custom).toString(),
        'https://deploydash-backups.s3.example.test?$query',
      );
      expect(
        service.debugBuildListRequestUri(config: customPath).toString(),
        'https://s3.example.test/deploydash-backups?$query',
      );
    });

    test('list URIs carry the continuation token and drop empty prefixes', () {
      const aws = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: 'sqlite/backups',
        forcePathStyle: true,
      );
      const root = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: '  ',
      );

      expect(
        service
            .debugBuildListRequestUri(config: aws, continuationToken: 'tok')
            .toString(),
        'https://s3.us-east-1.amazonaws.com/deploydash-backups'
        '?list-type=2&prefix=sqlite%2Fbackups%2F&continuation-token=tok',
      );
      expect(
        service.debugBuildListRequestUri(config: root).toString(),
        'https://deploydash-backups.s3.us-east-1.amazonaws.com?list-type=2',
      );
    });

    test('list URIs normalize a messy prefix', () {
      const messy = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: r'\\sqlite\backups//',
      );
      final service = d4Service(
        onRequest: (request) async => AWSHttpResponse(statusCode: 200),
      );

      expect(
        service.debugBuildListRequestUri(config: messy).toString(),
        'https://deploydash-backups.s3.us-east-1.amazonaws.com'
        '?list-type=2&prefix=sqlite%2Fbackups%2F',
      );
    });

    test('object URIs drop blank key segments', () {
      final service = d4Service(
        onRequest: (request) async => AWSHttpResponse(statusCode: 200),
      );

      expect(
        service
            .debugBuildRequestUri(config: config, objectKey: '//a//b.db')
            .toString(),
        'https://deploydash-backups.s3.us-east-1.amazonaws.com/a/b.db',
      );
    });
  });

  group('D-4 prefix normalization', () {
    test('object keys normalize separators and slashes', () {
      final service = d4Service(
        onRequest: (request) async => AWSHttpResponse(statusCode: 200),
      );

      expect(service.debugBuildObjectKey(r'a\b/c', 'f.db'), 'a/b/c/f.db');
      expect(service.debugBuildObjectKey('/leading', 'f.db'), 'leading/f.db');
      expect(service.debugBuildObjectKey('trailing/', 'f.db'), 'trailing/f.db');
      expect(service.debugBuildObjectKey('   ', 'f.db'), 'f.db');
    });
  });

  group('D-4 pagination', () {
    test('listing follows the continuation token across pages', () async {
      final requests = <AWSBaseHttpRequest>[];
      final service = d4Service(
        onRequest: (request) async {
          final readRequest = await request.read();
          requests.add(request);
          if (readRequest.uri.queryParameters['list-type'] == '2') {
            if (readRequest.uri.queryParameters['continuation-token'] ==
                'page-2') {
              return AWSHttpResponse(
                statusCode: 200,
                body: utf8.encode(
                  _d4ListXml([
                    'sqlite/backups/deploydash_state_20260102_000000.db',
                  ]),
                ),
              );
            }
            return AWSHttpResponse(
              statusCode: 200,
              body: utf8.encode(
                _d4ListXml([
                  'sqlite/backups/deploydash_state_20260101_000000.db',
                  'sqlite/backups/deploydash_state_20260103_000000.db',
                ], nextToken: 'page-2'),
              ),
            );
          }
          return AWSHttpResponse(
            statusCode: 200,
            body: utf8.encode('encrypted-backup-bytes'),
          );
        },
      );

      final result = await service.downloadLatestBackupFromS3(config: config);

      expect(
        result.objectKey,
        'sqlite/backups/deploydash_state_20260103_000000.db',
      );
      expect(requests, hasLength(3));
    });

    test('prune sees keys from every page before selecting deletes', () async {
      final deletedKeys = <String>[];
      final service = d4Service(
        onRequest: (request) async {
          final readRequest = await request.read();
          if (readRequest.uri.queryParameters['list-type'] == '2') {
            if (readRequest.uri.queryParameters['continuation-token'] ==
                'page-2') {
              return AWSHttpResponse(
                statusCode: 200,
                body: utf8.encode(
                  _d4ListXml([
                    'sqlite/backups/deploydash_state_20260101_000000.db',
                  ]),
                ),
              );
            }
            return AWSHttpResponse(
              statusCode: 200,
              body: utf8.encode(
                _d4ListXml([
                  'sqlite/backups/deploydash_state_20260102_000000.db',
                  'sqlite/backups/deploydash_state_20260103_000000.db',
                ], nextToken: 'page-2'),
              ),
            );
          }
          if (readRequest.method.value == 'DELETE') {
            deletedKeys.add(readRequest.uri.pathSegments.join('/'));
            return AWSHttpResponse(statusCode: 204);
          }
          return AWSHttpResponse(statusCode: 200);
        },
      );

      const keepTwo = SqliteBackupS3Config(
        bucket: 'deploydash-backups',
        region: 'us-east-1',
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'test-secret',
        prefix: 'sqlite/backups',
        retentionKeepLast: 2,
      );
      await service.backupNow(config: keepTwo);

      // Three keys across two pages, keep two: only the oldest goes, even
      // though it arrived on the second page.
      expect(deletedKeys, [
        'sqlite/backups/deploydash_state_20260101_000000.db',
      ]);
    });
  });

  group('D-4 shared SQL owners', () {
    test('user-version reader defaults a fresh database to zero', () {
      final database = sqlite.sqlite3.openInMemory();
      try {
        expect(readSqliteUserVersion(database), 0);
        database.execute('PRAGMA user_version = 17;');
        expect(readSqliteUserVersion(database), 17);
      } finally {
        database.close();
      }
    });

    test(
      'literal escaper doubles single quotes and passes the rest through',
      () {
        expect(escapeSqlLiteral("release'candidate"), "release''candidate");
        expect(escapeSqlLiteral('plain'), 'plain');
        expect(escapeSqlLiteral(''), '');
        expect(escapeSqlLiteral("''"), "''''");
      },
    );
  });

  group('D-4 collapsed structure', () {
    test(
      'list loop, URI builder, status guard, prefix, and SQL twins have one owner each',
      () {
        final serviceSource = File(
          'lib/services/sqlite_backup_service.dart',
        ).readAsStringSync();
        final databaseSource = File(
          'lib/data/local/app_database.dart',
        ).readAsStringSync();
        final guardSource = File(
          'test/architecture/one_owner_per_concept_test.dart',
        ).readAsStringSync();

        expect(
          serviceSource,
          contains('Future<List<String>> _listBackupObjectKeys('),
          reason: 'one paginated-list owner',
        );
        expect(
          serviceSource,
          contains('Uri _buildS3Uri('),
          reason: 'one S3 URI builder',
        );
        expect(
          serviceSource,
          contains('Future<void> _throwUnlessSuccess('),
          reason: 'one status guard',
        );
        expect(
          serviceSource,
          contains('String _normalizeS3Prefix('),
          reason: 'one prefix normalizer',
        );
        expect(
          serviceSource,
          contains('class S3HttpFailure extends StateError'),
          reason: 'code-carrying status failure for prune diagnostics',
        );

        expect(
          '_throwUnlessSuccess'.allMatches(serviceSource).length,
          5,
          reason: 'one guard definition plus download/verify/upload/list calls',
        );
        expect(
          'continuationToken != null'.allMatches(serviceSource).length,
          1,
          reason: 'a single pagination loop',
        );
        expect(
          "replaceAll(RegExp(r'/+\$'), '')".allMatches(serviceSource).length,
          1,
          reason: 'a single prefix-normalization chain',
        );

        final readUserVersionPrivate =
            ('_readUserVersion'.allMatches(serviceSource).length) +
            ('_readUserVersion'.allMatches(databaseSource).length);
        expect(
          readUserVersionPrivate,
          0,
          reason: 'the private twin name is gone from both files',
        );
        final readUserVersionPublic =
            ('readSqliteUserVersion('.allMatches(serviceSource).length) +
            ('readSqliteUserVersion('.allMatches(databaseSource).length);
        expect(
          readUserVersionPublic,
          3,
          reason: 'one public definition plus the two routed call sites',
        );
        final escapePrivate =
            ('_escapeSqlLiteral'.allMatches(serviceSource).length) +
            ('_escapeSqlLiteral'.allMatches(databaseSource).length);
        expect(
          escapePrivate,
          0,
          reason: 'the private twin name is gone from both files',
        );
        final escapePublic =
            ('escapeSqlLiteral('.allMatches(serviceSource).length) +
            ('escapeSqlLiteral('.allMatches(databaseSource).length);
        expect(
          escapePublic,
          6,
          reason: 'one public definition plus five routed call sites',
        );

        expect(
          guardSource,
          isNot(contains("'_readUserVersion'")),
          reason: 'the same-name exemption is removed with the twin',
        );
      },
    );
  });
}
