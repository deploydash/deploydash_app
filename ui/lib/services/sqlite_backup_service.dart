import 'dart:io';

import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../data/local/app_database.dart';
import '../data/local/app_preferences_repository.dart';
import '../utils/trim_or_null.dart';

const String _sqliteBackupMetadataTable = 'deploydash_backup_metadata';
const String _appBuildName = String.fromEnvironment(
  'FLUTTER_BUILD_NAME',
  defaultValue: 'dev',
);
const String _appBuildNumber = String.fromEnvironment(
  'FLUTTER_BUILD_NUMBER',
  defaultValue: '0',
);

/// Where the encrypted local database is backed up to, and how many copies to
/// keep.
///
/// S3-compatible rather than S3-only: [endpoint] and [forcePathStyle] exist so
/// a user can point this at Backblaze, Wasabi, MinIO or their own server. That
/// is a deliberate product position -- the backup of a local-first app should
/// not require an AWS account.
class SqliteBackupS3Config {
  /// Creates a destination configuration.
  const SqliteBackupS3Config({
    required this.bucket,
    required this.region,
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.prefix,
    this.endpoint,
    this.forcePathStyle = false,
    this.retentionKeepLast = 7,
  });

  /// The bucket backups are written to.
  final String bucket;

  /// The region used for request signing, and for the default AWS hostname.
  final String region;

  /// The access key id half of the credential.
  final String accessKeyId;

  /// The secret half of the credential. Stored in the encrypted local
  /// database and never written to a log -- `sanitizeSensitiveText` redacts it
  /// by key name if one ever reaches a message.
  final String secretAccessKey;

  /// The key prefix backups live under, without leading or trailing slashes.
  /// May be empty, putting backups at the bucket root.
  final String prefix;

  /// The S3-compatible endpoint, or null for AWS itself.
  ///
  /// A value without a scheme is read as HTTPS.
  final String? endpoint;

  /// Whether to address the bucket as a path segment rather than a hostname
  /// prefix. Required by most self-hosted S3 implementations.
  final bool forcePathStyle;

  /// How many backups to keep. Older ones are removed after a successful
  /// upload; see the pruning contract on [SqliteBackupService.backupNow].
  final int retentionKeepLast;

  /// Reads a stored configuration.
  ///
  /// Missing fields become empty strings rather than throwing, and an
  /// unreadable retention becomes the default of 7 -- the configuration is
  /// checked by [validate] at the point of use, where a specific message can
  /// be shown, not at the point of decoding, where it would only break the
  /// settings screen that exists to fix it.
  factory SqliteBackupS3Config.fromJson(Map<String, dynamic> json) {
    final bucket = json['bucket']?.toString().trim() ?? '';
    final region = json['region']?.toString().trim() ?? '';
    final accessKeyId = json['access_key_id']?.toString().trim() ?? '';
    final secretAccessKey = json['secret_access_key']?.toString().trim() ?? '';
    final prefix = json['prefix']?.toString().trim() ?? '';
    final endpointCandidate = json['endpoint']?.toString().trim();
    final retentionRaw = json['retention_keep_last'];
    final retentionKeepLast = switch (retentionRaw) {
      final int value => value,
      final String value => int.tryParse(value.trim()) ?? 7,
      _ => 7,
    };
    return SqliteBackupS3Config(
      bucket: bucket,
      region: region,
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      prefix: prefix,
      endpoint: endpointCandidate == null || endpointCandidate.isEmpty
          ? null
          : endpointCandidate,
      forcePathStyle: json['force_path_style'] == true,
      retentionKeepLast: retentionKeepLast,
    );
  }

  /// This configuration as the JSON stored in app preferences.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'bucket': bucket,
      'region': region,
      'access_key_id': accessKeyId,
      'secret_access_key': secretAccessKey,
      'prefix': prefix,
      'endpoint': endpoint,
      'force_path_style': forcePathStyle,
      'retention_keep_last': retentionKeepLast,
    };
  }

  /// Throws [FormatException] naming the first missing or invalid field.
  ///
  /// Called at the start of every operation rather than once at construction,
  /// because a configuration is loaded from storage long before it is used and
  /// the message needs to reach whoever pressed the button.
  void validate() {
    if (bucket.isEmpty) {
      throw const FormatException('S3 bucket is required.');
    }
    if (region.isEmpty) {
      throw const FormatException('S3 region is required.');
    }
    if (accessKeyId.isEmpty) {
      throw const FormatException('S3 access key ID is required.');
    }
    if (secretAccessKey.isEmpty) {
      throw const FormatException('S3 secret access key is required.');
    }
    if (retentionKeepLast < 1 || retentionKeepLast > 3650) {
      throw const FormatException(
        'Retention keep last must be between 1 and 3650.',
      );
    }
  }
}

/// What one successful backup produced.
class SqliteBackupRunResult {
  /// Records a completed upload.
  const SqliteBackupRunResult({
    required this.objectKey,
    required this.completedAt,
    required this.message,
  });

  /// The key the snapshot was written to, prefix included.
  final String objectKey;

  /// When the run finished.
  final DateTime completedAt;

  /// The line shown to the user and stored as the last run's status.
  ///
  /// Names the destination, and appends a note when retention pruning did not
  /// fully succeed -- the upload is still a success, but silently is not how
  /// the user should learn that old backups are accumulating.
  final String message;
}

/// A backup fetched from S3, waiting to be restored.
class SqliteBackupDownloadResult {
  /// Records a completed download.
  const SqliteBackupDownloadResult({
    required this.objectKey,
    required this.localFile,
  });

  /// The key that was downloaded.
  final String objectKey;

  /// The downloaded file, in a temporary directory the caller owns.
  final File localFile;
}

/// The provenance stamped inside every snapshot.
///
/// Written into the snapshot itself rather than kept alongside it, because a
/// backup file is restored on a machine that has none of the surrounding
/// context -- possibly years later, possibly by a different app build. See
/// `docs/contracts/artifact-formats.md`.
class SqliteBackupSnapshotMetadata {
  /// Records what to stamp into a snapshot.
  const SqliteBackupSnapshotMetadata({
    required this.createdAtUtc,
    required this.appBuildName,
    required this.appBuildNumber,
  });

  /// When the snapshot was taken, in UTC.
  final DateTime createdAtUtc;

  /// The app version that wrote it.
  final String appBuildName;

  /// The build number that wrote it.
  final String appBuildNumber;
}

/// Reads the current time. Injectable so a test can assert on a fixed
/// timestamp slug.
typedef BackupClock = DateTime Function();

/// Creates the scratch directory a snapshot is staged in.
typedef BackupTempDirectoryFactory = Future<Directory> Function();

/// Locates the live database file to copy from.
typedef BackupSourceFileResolver = Future<File> Function();

/// Copies the live database into a consistent encrypted snapshot.
typedef BackupSnapshotCreator =
    Future<void> Function({
      required String sourcePath,
      required String snapshotPath,
      required String passphrase,
      required SqliteBackupSnapshotMetadata metadata,
    });

/// Uploads a finished snapshot. Overridable so a test can exercise
/// [SqliteBackupService.backupNow] end to end without a network.
typedef BackupUploader =
    Future<void> Function({
      required SqliteBackupS3Config config,
      required String objectKey,
      required File payloadFile,
    });

/// Sends one signed HTTP request. The seam that makes every S3 error path --
/// a 403, a truncated listing, a mid-upload failure -- reachable from a unit
/// test.
typedef BackupRequestSender =
    Future<AWSBaseHttpResponse> Function(AWSBaseHttpRequest request);

/// Exports, uploads, lists and downloads snapshots of the encrypted local
/// database.
///
/// The snapshot is taken with SQLite's own backup API against an open
/// connection, not by copying the file, so a backup running while the app
/// writes cannot capture a torn page. It stays encrypted with the same
/// passphrase throughout: nothing here ever holds a decrypted copy, and a
/// snapshot restored on another machine needs the password it was made with.
class SqliteBackupService {
  /// Creates the service. Every collaborator has a real default and exists as
  /// a parameter so the error paths can be injected in tests.
  const SqliteBackupService({
    required this.databasePassphrase,
    required this.preferencesRepository,
    this.clock = DateTime.now,
    this.tempDirectoryFactory = _defaultBackupTempDirectoryFactory,
    this.sourceFileResolver = resolveAppDatabaseFile,
    this.snapshotCreator = createConsistentEncryptedSnapshot,
    this.uploader,
    this.requestSender = _defaultBackupRequestSender,
  });

  /// The passphrase the live database is open with, or null when locked.
  ///
  /// Null is a normal state, not a bug: no backup can be taken before the user
  /// unlocks, and every entry point checks it rather than assuming.
  final String? databasePassphrase;

  /// Where the last run's status is recorded.
  final AppPreferencesRepository preferencesRepository;

  /// Reads the current time.
  final BackupClock clock;

  /// Creates the scratch directory snapshots are staged in.
  final BackupTempDirectoryFactory tempDirectoryFactory;

  /// Locates the live database file.
  final BackupSourceFileResolver sourceFileResolver;

  /// Takes the consistent encrypted snapshot.
  final BackupSnapshotCreator snapshotCreator;

  /// Uploads the snapshot, or null to use the built-in signed S3 upload.
  final BackupUploader? uploader;

  /// Sends signed requests to S3.
  final BackupRequestSender requestSender;

  /// Writes a snapshot to a path the user chose, and returns the file.
  ///
  /// Staged through a `.exporting` temporary that is renamed into place, so an
  /// interrupted export never leaves a truncated file looking like a usable
  /// backup at the destination the user picked. Refuses to write over the live
  /// database.
  ///
  /// The export stays encrypted with the *current* passphrase. Rotating the
  /// password afterwards does not re-key files already exported -- each one
  /// still needs the password in force when it was written.
  Future<File> exportNow({required String destinationPath}) async {
    final normalizedPassphrase = databasePassphrase?.trim() ?? '';
    if (normalizedPassphrase.isEmpty) {
      throw StateError(
        'Database passphrase is unavailable for backup snapshot.',
      );
    }

    final normalizedDestinationPath = destinationPath.trim();
    if (normalizedDestinationPath.isEmpty) {
      throw StateError('Export destination path is required.');
    }

    final destinationFile = File(normalizedDestinationPath);
    final sourceFile = await sourceFileResolver();
    if (!await sourceFile.exists()) {
      throw StateError('Local Deploy Dash database file is missing.');
    }
    if (sourceFile.absolute.path == destinationFile.absolute.path) {
      throw StateError(
        'Export destination must be different from the live database path.',
      );
    }
    await destinationFile.parent.create(recursive: true);
    final tempExportFile = File('${destinationFile.path}.exporting');

    try {
      if (await tempExportFile.exists()) {
        await tempExportFile.delete();
      }

      final createdAt = clock().toUtc();
      await snapshotCreator(
        sourcePath: sourceFile.path,
        snapshotPath: tempExportFile.path,
        passphrase: normalizedPassphrase,
        metadata: SqliteBackupSnapshotMetadata(
          createdAtUtc: createdAt,
          appBuildName: _appBuildName,
          appBuildNumber: _appBuildNumber,
        ),
      );

      if (await destinationFile.exists()) {
        await destinationFile.delete();
      }
      await tempExportFile.rename(destinationFile.path);
      return destinationFile;
    } finally {
      if (await tempExportFile.exists()) {
        await tempExportFile.delete();
      }
    }
  }

  /// Takes a snapshot, uploads it, and prunes older backups past retention.
  ///
  /// The run is recorded either way: a success stores the destination line, a
  /// failure stores the error and rethrows. The scratch snapshot is deleted in
  /// a `finally` on every path, so a failed upload does not leave a copy of
  /// the user's database in the system temp directory.
  ///
  /// **Pruning never fails the run.** By the time it happens the upload has
  /// already succeeded, and reporting a good backup as failed would be the
  /// worse error. A prune that could not complete is appended to
  /// [SqliteBackupRunResult.message] instead -- reported, not silent.
  Future<SqliteBackupRunResult> backupNow({
    required SqliteBackupS3Config config,
  }) async {
    final normalizedPassphrase = databasePassphrase?.trim() ?? '';
    if (normalizedPassphrase.isEmpty) {
      throw StateError(
        'Database passphrase is unavailable for backup snapshot.',
      );
    }
    config.validate();

    final startedAt = clock();
    Directory? scratchDir;
    File? snapshotFile;

    try {
      scratchDir = await tempDirectoryFactory();
      final sourceFile = await sourceFileResolver();
      if (!await sourceFile.exists()) {
        throw StateError('Local Deploy Dash database file is missing.');
      }

      final snapshotName = buildSqliteBackupFilename(startedAt.toUtc());
      snapshotFile = File('${scratchDir.path}/$snapshotName');

      await snapshotCreator(
        sourcePath: sourceFile.path,
        snapshotPath: snapshotFile.path,
        passphrase: normalizedPassphrase,
        metadata: SqliteBackupSnapshotMetadata(
          createdAtUtc: startedAt.toUtc(),
          appBuildName: _appBuildName,
          appBuildNumber: _appBuildNumber,
        ),
      );

      final objectKey = _buildObjectKey(config.prefix, snapshotName);
      await (uploader ?? _uploadToS3)(
        config: config,
        objectKey: objectKey,
        payloadFile: snapshotFile,
      );

      final pruneWarning = await _pruneOldBackups(config);

      final completedAt = clock();
      final message =
          'Uploaded encrypted backup to s3://${config.bucket}/'
          '$objectKey'
          '${pruneWarning == null ? '' : '. Note: $pruneWarning'}';
      await preferencesRepository.recordSqliteBackupRun(
        status: 'success',
        message: message,
        runAt: completedAt,
      );
      return SqliteBackupRunResult(
        objectKey: objectKey,
        completedAt: completedAt,
        message: message,
      );
    } catch (error) {
      await preferencesRepository.recordSqliteBackupRun(
        status: 'failed',
        message: error.toString(),
        runAt: clock(),
      );
      rethrow;
    } finally {
      if (snapshotFile != null && await snapshotFile.exists()) {
        await snapshotFile.delete();
      }
      if (scratchDir != null && await scratchDir.exists()) {
        await scratchDir.delete(recursive: true);
      }
    }
  }

  /// Downloads the newest backup in the destination.
  ///
  /// "Newest" is decided by sorting keys, which works because
  /// [buildSqliteBackupFilename] stamps a fixed-width `YYYYMMDD_HHMMSS` slug --
  /// lexical order is chronological order. Only keys matching that filename
  /// shape are considered, so unrelated objects sharing the prefix cannot be
  /// offered as a restore.
  ///
  /// Throws [StateError] when the destination holds no recognisable backup.
  Future<SqliteBackupDownloadResult> downloadLatestBackupFromS3({
    required SqliteBackupS3Config config,
  }) async {
    config.validate();

    final objectKey = await _findLatestBackupObjectKey(config);
    final requestUri = _buildRequestUri(config: config, objectKey: objectKey);
    final response = await _sendSignedRequest(
      AWSHttpRequest.get(requestUri, headers: _buildSignedHeaders(requestUri)),
      config: config,
    );

    await _throwUnlessSuccess(response, 'S3 download failed');

    final scratchDir = await tempDirectoryFactory();
    final file = File('${scratchDir.path}/${p.basename(objectKey)}');
    await file.writeAsBytes(await response.bodyBytes, flush: true);
    return SqliteBackupDownloadResult(objectKey: objectKey, localFile: file);
  }

  /// Checks the destination is reachable and the credentials work.
  ///
  /// Performs a listing rather than a write, so testing a destination cannot
  /// leave an object behind. Throws [StateError] carrying the provider's own
  /// status and body, which `mapStorageFailure` turns into a sentence.
  Future<void> verifyS3Destination({
    required SqliteBackupS3Config config,
  }) async {
    config.validate();
    final requestUri = _buildListRequestUri(
      config: config,
      continuationToken: null,
    );
    final response = await _sendSignedRequest(
      AWSHttpRequest.get(requestUri, headers: _buildSignedHeaders(requestUri)),
      config: config,
    );
    await _throwUnlessSuccess(response, 'S3 destination check failed');
  }

  Future<void> _uploadToS3({
    required SqliteBackupS3Config config,
    required String objectKey,
    required File payloadFile,
  }) async {
    final requestUri = _buildRequestUri(config: config, objectKey: objectKey);
    final payloadLength = await payloadFile.length();
    final request = AWSStreamedHttpRequest.put(
      requestUri,
      body: payloadFile.openRead(),
      contentLength: payloadLength,
      headers: <String, String>{
        ..._buildSignedHeaders(requestUri),
        AWSHeaders.contentType: 'application/octet-stream',
      },
    );

    final response = await _sendSignedRequest(request, config: config);
    await _throwUnlessSuccess(response, 'S3 upload failed');
  }

  /// Throws when [response] is not 2xx, carrying the provider's own detail.
  ///
  /// Why: download, verify, upload, and backup-listing share the status range,
  /// the body decode, and the `: body` suffix rule; one guard keeps the four
  /// failure sentences from drifting apart. The failure is an [S3HttpFailure]
  /// (a [StateError] carrying its status) so prune can render its own
  /// never-fails diagnostic from the code rather than parsing a message.
  Future<void> _throwUnlessSuccess(
    AWSBaseHttpResponse response,
    String action,
  ) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.decodeBody();
      throw S3HttpFailure(
        statusCode: response.statusCode,
        message:
            '$action with HTTP ${response.statusCode}'
            '${body.trim().isEmpty ? '' : ': $body'}',
      );
    }
  }

  Uri _buildRequestUri({
    required SqliteBackupS3Config config,
    required String objectKey,
  }) {
    return _buildS3Uri(config: config, objectKey: objectKey);
  }

  Uri _buildListRequestUri({
    required SqliteBackupS3Config config,
    String? continuationToken,
  }) {
    final normalizedPrefix = _normalizeS3Prefix(config.prefix);
    final trimmedContinuationToken = trimOrNull(continuationToken);
    return _buildS3Uri(
      config: config,
      queryParameters: <String, Object>{
        'list-type': '2',
        if (normalizedPrefix.isNotEmpty) 'prefix': '$normalizedPrefix/',
        'continuation-token': ?trimmedContinuationToken,
      },
    );
  }

  /// Builds an S3 URI for [config], addressing either one object or a listing.
  ///
  /// Why: object and listing URIs share the endpoint/path-style four-branch
  /// shape and differ only in path vs query; one builder keeps the hosts from
  /// drifting apart. [objectKey] selects the object form (blank segments
  /// dropped); [queryParameters] selects the listing form. A null
  /// [queryParameters] builds no query string, and a null [objectKey] builds
  /// no key path, so each delegate's bytes are unchanged.
  Uri _buildS3Uri({
    required SqliteBackupS3Config config,
    String? objectKey,
    Map<String, Object>? queryParameters,
  }) {
    final endpointUri = _parseEndpoint(config.endpoint);
    final keySegments = objectKey
        ?.split('/')
        .where((segment) => segment.trim().isNotEmpty)
        .toList(growable: false);
    final queryStrings = queryParameters?.map(
      (key, value) => MapEntry(key, value.toString()),
    );

    if (endpointUri != null) {
      final scheme = endpointUri.scheme;
      final host = endpointUri.host;
      final port = endpointUri.hasPort ? endpointUri.port : null;
      if (config.forcePathStyle) {
        return Uri(
          scheme: scheme,
          host: host,
          port: port,
          pathSegments: <String>[config.bucket, ...?keySegments],
          queryParameters: queryStrings,
        );
      }
      return Uri(
        scheme: scheme,
        host: '${config.bucket}.$host',
        port: port,
        pathSegments: keySegments,
        queryParameters: queryStrings,
      );
    }

    if (config.forcePathStyle) {
      return Uri(
        scheme: 'https',
        host: 's3.${config.region}.amazonaws.com',
        pathSegments: <String>[config.bucket, ...?keySegments],
        queryParameters: queryStrings,
      );
    }
    return Uri(
      scheme: 'https',
      host: '${config.bucket}.s3.${config.region}.amazonaws.com',
      pathSegments: keySegments,
      queryParameters: queryStrings,
    );
  }

  Uri? _parseEndpoint(String? endpoint) {
    if (endpoint == null || endpoint.trim().isEmpty) {
      return null;
    }
    final candidate = endpoint.trim();
    final parsed = candidate.contains('://')
        ? Uri.parse(candidate)
        : Uri.parse('https://$candidate');
    if (parsed.host.trim().isEmpty) {
      throw const FormatException('S3 endpoint must include a host.');
    }
    return parsed;
  }

  /// Trims [prefix] and unifies its separators, dropping edge slashes.
  ///
  /// Why: the listing query and the object-key builder share this four-step
  /// chain; one owner keeps the prefix spelling single.
  String _normalizeS3Prefix(String prefix) {
    return prefix
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), '');
  }

  String _buildObjectKey(String prefix, String filename) {
    final normalized = _normalizeS3Prefix(prefix);
    if (normalized.isEmpty) {
      return filename;
    }
    return '$normalized/$filename';
  }

  String _timestampSlug(DateTime value) {
    return buildSqliteBackupTimestampSlug(value);
  }

  /// Removes backups beyond the retention count, oldest first.
  ///
  /// Returns `null` when nothing needed pruning or everything succeeded, and a
  /// short diagnostic when it did not. **Pruning never fails the backup**: the
  /// upload already succeeded, and failing the run would mark a good backup as
  /// failed. That mirrors the managed-database prune, which reports
  /// `prune_failures=` on stderr and still exits zero. What it must not do is
  /// stay silent — a delete that fails while the caller reports success is the
  /// exact defect the backend half of G-44 removed.
  Future<String?> _pruneOldBackups(SqliteBackupS3Config config) async {
    final objectKeys = <String>[];

    try {
      objectKeys.addAll(await _listBackupObjectKeys(config));
    } on S3HttpFailure catch (failure) {
      // A refused listing deletes nothing and names the status, exactly as
      // the inline early return did before the list loop had one owner.
      return 'old backups were not removed: listing failed with HTTP '
          '${failure.statusCode}';
    } on Object catch (error) {
      // A listing that failed or could not be parsed must delete nothing: an
      // empty or partial list would otherwise look like "few backups exist".
      return 'old backups were not removed: $error';
    }

    if (objectKeys.length <= config.retentionKeepLast) {
      return null;
    }

    objectKeys.sort();
    final keysToDelete = objectKeys.sublist(
      0,
      objectKeys.length - config.retentionKeepLast,
    );

    var failedDeletes = 0;
    String? firstDeleteError;
    for (final key in keysToDelete) {
      try {
        final requestUri = _buildRequestUri(config: config, objectKey: key);
        final response = await _sendSignedRequest(
          AWSHttpRequest.delete(
            requestUri,
            headers: _buildSignedHeaders(requestUri),
          ),
          config: config,
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          failedDeletes += 1;
          firstDeleteError ??= 'HTTP ${response.statusCode} on $key';
        }
      } on Object catch (error) {
        failedDeletes += 1;
        firstDeleteError ??= '$error';
      }
    }

    if (failedDeletes == 0) {
      return null;
    }
    return '$failedDeletes old backup'
        '${failedDeletes == 1 ? '' : 's'} could not be removed '
        '($firstDeleteError)';
  }

  /// Lists backup object keys in this destination, oldest first.
  ///
  /// Why: prune and find-latest share the continuation-token loop, the
  /// list-URI, the status check, the parse, and the backup-key filter; one
  /// owner keeps pagination + filtering from drifting apart. It throws on a
  /// failed or unparseable listing; prune converts that to its diagnostic
  /// (pruning never fails the backup), find-latest lets it propagate.
  Future<List<String>> _listBackupObjectKeys(
    SqliteBackupS3Config config,
  ) async {
    final objectKeys = <String>[];
    String? continuationToken;
    do {
      final requestUri = _buildListRequestUri(
        config: config,
        continuationToken: continuationToken,
      );
      final response = await _sendSignedRequest(
        AWSHttpRequest.get(
          requestUri,
          headers: _buildSignedHeaders(requestUri),
        ),
        config: config,
      );
      await _throwUnlessSuccess(response, 'S3 backup listing failed');
      final parsed = _parseListObjectsResponse(await response.decodeBody());
      objectKeys.addAll(parsed.objectKeys.where(_looksLikeBackupObjectKey));
      continuationToken = parsed.nextContinuationToken;
    } while (continuationToken != null);
    objectKeys.sort();
    return objectKeys;
  }

  Future<String> _findLatestBackupObjectKey(SqliteBackupS3Config config) async {
    final objectKeys = await _listBackupObjectKeys(config);

    if (objectKeys.isEmpty) {
      throw StateError(
        'No encrypted app backups were found in this S3 destination.',
      );
    }

    return objectKeys.last;
  }

  bool _looksLikeBackupObjectKey(String objectKey) {
    final filename = p.basename(objectKey.trim());
    return RegExp(r'^deploydash_state_\d{8}_\d{6}\.db$').hasMatch(filename);
  }

  Map<String, String> _buildSignedHeaders(Uri requestUri) {
    final hostHeader = requestUri.hasPort
        ? '${requestUri.host}:${requestUri.port}'
        : requestUri.host;
    return <String, String>{AWSHeaders.host: hostHeader};
  }

  Future<AWSBaseHttpResponse> _sendSignedRequest(
    AWSBaseHttpRequest request, {
    required SqliteBackupS3Config config,
  }) async {
    final signer = AWSSigV4Signer(
      credentialsProvider: AWSCredentialsProvider(
        AWSCredentials(config.accessKeyId, config.secretAccessKey),
      ),
    );
    final credentialScope = AWSCredentialScope(
      region: config.region,
      service: AWSService.s3,
    );
    final signedRequest = await signer.sign(
      request,
      credentialScope: credentialScope,
      serviceConfiguration: S3ServiceConfiguration(),
    );
    return requestSender(signedRequest);
  }

  /// The object URI for [objectKey], exposed for tests.
  @visibleForTesting
  Uri debugBuildRequestUri({
    required SqliteBackupS3Config config,
    required String objectKey,
  }) {
    return _buildRequestUri(config: config, objectKey: objectKey);
  }

  /// The parsed endpoint, exposed for tests.
  @visibleForTesting
  Uri? debugParseEndpoint(String? endpoint) {
    return _parseEndpoint(endpoint);
  }

  /// The object key for a prefix and filename, exposed for tests.
  @visibleForTesting
  String debugBuildObjectKey(String prefix, String filename) {
    return _buildObjectKey(prefix, filename);
  }

  /// The timestamp slug for [value], exposed for tests.
  @visibleForTesting
  String debugTimestampSlug(DateTime value) {
    return _timestampSlug(value);
  }

  /// The listing URI, exposed for tests.
  @visibleForTesting
  Uri debugBuildListRequestUri({
    required SqliteBackupS3Config config,
    String? continuationToken,
  }) {
    return _buildListRequestUri(
      config: config,
      continuationToken: continuationToken,
    );
  }

  /// The parsed listing response, exposed for tests.
  @visibleForTesting
  ListObjectsParseResult debugParseListObjectsResponse(String responseBody) {
    return _parseListObjectsResponse(responseBody);
  }
}

/// An S3 request that did not return 2xx, carrying its HTTP status.
///
/// A [StateError] subclass so existing callers keep catching what they
/// caught; the [statusCode] lets prune render its never-fails diagnostic
/// from the code instead of parsing a message.
class S3HttpFailure extends StateError {
  /// Records a failed S3 response.
  S3HttpFailure({required this.statusCode, required String message})
    : super(message);

  /// The HTTP status the provider returned.
  final int statusCode;
}

/// One page of an S3 `ListObjectsV2` response.
class ListObjectsParseResult {
  /// Records one parsed page.
  const ListObjectsParseResult({
    required this.objectKeys,
    required this.nextContinuationToken,
  });

  /// Every key on this page, in the order S3 returned them.
  final List<String> objectKeys;

  /// The token for the next page, or null when this was the last.
  ///
  /// Callers must follow it. A truncated listing treated as complete would
  /// make a full bucket look nearly empty, which for pruning means deleting
  /// nothing and for restore means offering the wrong backup as newest.
  final String? nextContinuationToken;
}

ListObjectsParseResult _parseListObjectsResponse(String responseBody) {
  if (!responseBody.contains('<ListBucketResult')) {
    throw const FormatException(
      'Malformed S3 XML response: missing <ListBucketResult>',
    );
  }
  final objectKeys = RegExp(r'<Key>([^<]+)</Key>')
      .allMatches(responseBody)
      .map((match) => match.group(1))
      .whereType<String>()
      .map(_decodeXmlText)
      .toList(growable: false);

  final tokenMatch = RegExp(
    r'<NextContinuationToken>([^<]+)</NextContinuationToken>',
  ).firstMatch(responseBody);
  final tokenValue = tokenMatch?.group(1);
  final nextContinuationToken = tokenValue == null
      ? null
      : _decodeXmlText(tokenValue);

  return ListObjectsParseResult(
    objectKeys: objectKeys,
    nextContinuationToken: nextContinuationToken,
  );
}

String _decodeXmlText(String value) {
  return value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
}

/// The filename one snapshot is stored under.
///
/// The `deploydash_state_<slug>.db` shape is load-bearing in three places: the
/// restore picker recognises it, listing filters on it, and sorting these
/// names is what "newest backup" means.
String buildSqliteBackupFilename(DateTime value) {
  return 'deploydash_state_${buildSqliteBackupTimestampSlug(value)}.db';
}

/// A fixed-width `YYYYMMDD_HHMMSS` stamp, so lexical order is chronological.
///
/// Every component is zero-padded for exactly that reason; an unpadded month
/// would sort October before February.
String buildSqliteBackupTimestampSlug(DateTime value) {
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${value.year}'
      '${twoDigits(value.month)}'
      '${twoDigits(value.day)}_'
      '${twoDigits(value.hour)}'
      '${twoDigits(value.minute)}'
      '${twoDigits(value.second)}';
}

/// Copies the live database into a new encrypted file, consistently.
///
/// Uses SQLite's backup API against an open connection rather than copying
/// bytes, which is what makes a snapshot taken during a write safe to restore.
/// The destination is opened with the same passphrase, so the snapshot is
/// encrypted from the moment it exists -- there is never a plaintext
/// intermediate on disk.
///
/// The source's `user_version` is carried over and the snapshot's metadata
/// table written, so a restore can tell which schema and which app build
/// produced the file before trying to open it.
@visibleForTesting
Future<void> createConsistentEncryptedSnapshot({
  required String sourcePath,
  required String snapshotPath,
  required String passphrase,
  required SqliteBackupSnapshotMetadata metadata,
}) async {
  final sourceDb = sqlite.sqlite3.open(sourcePath);
  try {
    configureAppDatabaseEncryption(sourceDb, passphrase: passphrase);
    final sourceUserVersion = readSqliteUserVersion(sourceDb);
    final snapshotDb = sqlite.sqlite3.open(snapshotPath);
    try {
      configureAppDatabaseEncryption(snapshotDb, passphrase: passphrase);
      await sourceDb.backup(snapshotDb, nPage: -1).drain<void>();
      _writeSnapshotMetadata(
        snapshotDb,
        sourceUserVersion: sourceUserVersion,
        metadata: metadata,
      );
    } finally {
      snapshotDb.close();
    }
  } finally {
    sourceDb.close();
  }
}

void _writeSnapshotMetadata(
  sqlite.Database database, {
  required int sourceUserVersion,
  required SqliteBackupSnapshotMetadata metadata,
}) {
  database.execute('PRAGMA user_version = $sourceUserVersion;');
  database.execute(
    'CREATE TABLE IF NOT EXISTS $_sqliteBackupMetadataTable ('
    'id INTEGER PRIMARY KEY, '
    'backup_format_version INTEGER NOT NULL, '
    'created_at_utc TEXT NOT NULL, '
    'source_schema_version INTEGER NOT NULL, '
    'app_build_name TEXT NOT NULL, '
    'app_build_number TEXT NOT NULL'
    ');',
  );
  database.execute('DELETE FROM $_sqliteBackupMetadataTable;');
  database.execute(
    'INSERT INTO $_sqliteBackupMetadataTable '
    '(id, backup_format_version, created_at_utc, source_schema_version, '
    'app_build_name, app_build_number) VALUES '
    "(1, $sqliteBackupFormatVersion, "
    "'${escapeSqlLiteral(metadata.createdAtUtc.toIso8601String())}', "
    "$sourceUserVersion, "
    "'${escapeSqlLiteral(metadata.appBuildName)}', "
    "'${escapeSqlLiteral(metadata.appBuildNumber)}');",
  );
}

Future<Directory> _defaultBackupTempDirectoryFactory() {
  return Directory.systemTemp.createTemp('deploydash-backup-');
}

Future<AWSBaseHttpResponse> _defaultBackupRequestSender(
  AWSBaseHttpRequest request,
) {
  return request.send().response;
}

/// The app-wide backup service, bound to the current passphrase.
final sqliteBackupServiceProvider = Provider<SqliteBackupService>((ref) {
  return SqliteBackupService(
    databasePassphrase: ref.watch(databasePassphraseProvider),
    preferencesRepository: ref.watch(appPreferencesRepositoryProvider),
  );
});
