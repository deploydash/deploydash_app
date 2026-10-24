/// Backup payload and presentation logic.
///
/// Lives in `services/` rather than beside the backup screen because it
/// imports nothing from `lib/ui` and is needed by `providers/` -- a
/// provider importing `ui/` inverts the desktop layering, and importing
/// the backup provider from here would close a cycle. G-42.
library;

import 'package:ui/domain/server.dart';
import 'package:ui/data/local/backup_repository.dart';
import 'package:ui/utils/project_slug.dart';

/// Which database engine a backup screen is acting on.
///
/// One value today. It exists as an enum rather than being assumed away
/// because the payload builders, workflow ids and eligibility rules below each
/// have to branch on it once a second engine ships; several of them take it as
/// a parameter they currently ignore, which is where those branches will go.
enum BackupWorkspaceEngineChoice {
  /// Managed PostgreSQL, the only engine with backups today.
  postgres,
}

final RegExp _backupHhmmPattern = RegExp(r'^(?:[01]?\d|2[0-3]):[0-5]\d$');

/// The Backup screen's title.
String backupWorkspaceTitle() => 'Backups';

/// The sentence under the title, naming the three things this screen does.
String backupWorkspaceSubtitle() {
  return 'Choose where backups are stored, decide what runs automatically, and restore when you need to.';
}

/// What to show when backup details could not be read.
///
/// Keeps the raw error on a second line rather than discarding it: a backup
/// screen that cannot load is a situation where the user needs the detail to
/// get help, not a reassuring sentence.
String backupLoadErrorMessage(Object error) {
  return 'Couldn’t load backup details.\n$error';
}

/// What to show when the server has no usable SSH credentials, naming where
/// to fix it.
String backupMissingCredentialsMessage() {
  return 'Deploy Dash can’t reach this server yet. Update SSH access in server settings.';
}

/// The destination dialog's title, for adding or editing.
String backupDestinationDialogTitle({required bool isEditing}) {
  return isEditing ? 'Edit backup destination' : 'Add backup destination';
}

/// The plan dialog's title, for adding or editing.
String backupPolicyDialogTitle({required bool isEditing}) {
  return isEditing ? 'Edit backup plan' : 'Add backup plan';
}

/// The engine picker's label.
///
/// Reads "Service", not "Engine": the audience is a novice choosing what to
/// back up, not a DBA choosing a database engine.
String backupEngineFieldLabel() => 'Service';

/// The engine picker's helper line.
String backupEngineSubtitle() {
  return 'Choose which service you want to back up or restore.';
}

/// The destinations section heading.
String backupDestinationsHeading() => 'Where backups are stored';

// coverage-gate: backup_workspace_logic
/// The destinations empty state, which names the next action rather than
/// just reporting emptiness.
String backupDestinationsEmptyMessage() {
  return 'Add a destination before you create a backup plan.';
}

/// The plans section heading for [engine].
String backupPoliciesHeading({required BackupWorkspaceEngineChoice engine}) {
  return 'PostgreSQL backup plans';
}

/// The plans empty state for [engine].
String backupPoliciesEmptyMessage({
  required BackupWorkspaceEngineChoice engine,
}) {
  return 'No PostgreSQL backup plans yet.';
}

/// The artifacts section heading.
String backupArtifactsHeading() => 'Recent backups';

/// The artifacts empty state, phrased around restoring, which is what the
/// list is for.
String backupArtifactsEmptyMessage() {
  return 'No backups are ready to restore yet.';
}

/// The run-history section heading.
String backupRunsHeading() => 'Recent activity';

/// The run-history empty state.
String backupRunsEmptyMessage() => 'No backup activity yet.';

/// A byte count as a short human size like "219 MB".
///
/// The single owner for byte sizes in backlog copy: the cleanup dialog
/// reports "~X GB" from engine byte counts, and every rendering must agree
/// on units and rounding or the dialog contradicts itself across plans.
String backupHumanReadableBytes(int bytes) {
  final value = bytes < 0 ? 0 : bytes;
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = value.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final text = size == size.truncateToDouble()
      ? size.toInt().toString()
      : size.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// The cleanup dialog's report line for a backlog [count] with [bytes]
/// known bytes, [unknownSizeCount] of them size-unknown, keeping [keepLast].
///
/// Names the count, the approximate size, and the protection ("the newest
/// N are kept") in one sentence: the dialog's whole job is informed
/// consent for a destructive action, so the sentence must stand alone.
String backupBacklogReportMessage({
  required int count,
  required int bytes,
  required int unknownSizeCount,
  required int keepLast,
}) {
  final artifacts = count == 1 ? 'artifact' : 'artifacts';
  final size = unknownSizeCount <= 0
      ? '~${backupHumanReadableBytes(bytes)}'
      : unknownSizeCount >= count
      ? 'size unknown'
      : '~${backupHumanReadableBytes(bytes)}, '
            '$unknownSizeCount of $count sizes unknown';
  final kept = keepLast == 1
      ? 'The newest 1 backup is kept.'
      : 'The newest $keepLast backups are kept.';
  return '$count $artifacts beyond retention ($size). $kept';
}

/// What to show when a backlog report finds nothing beyond retention.
String backupBacklogCleanupEmptyMessage() => 'No old backups to clean up.';

/// The success notice after a cleanup deleted [deletedCount] artifacts.
String backupBacklogCleanupSuccessMessage({required int deletedCount}) =>
    deletedCount == 1
    ? 'Deleted 1 old backup.'
    : 'Deleted $deletedCount old backups.';

// D-26 slug census (T-011): left unique — keeps hyphens for UUID policy
// ids and prefixes backup-pg-; D-28 pair 2 needs no further ticket.
/// The scheduler task id for the plan with [policyId].
///
/// Derived from the policy id rather than stored, so the desktop app and the
/// server agree on which task belongs to which plan without a second record to
/// keep in sync. The `backup-pg-` prefix is what lets project deletion find
/// and remove these tasks.
String backupTaskIdForPolicy({
  required String policyId,
  required BackupWorkspaceEngineChoice engine,
}) {
  final normalized = policyId
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final base = normalized.isEmpty ? 'policy' : normalized;
  return 'backup-pg-$base';
}

/// The persisted engine value for a screen's [engine] selection.
BackupEngine backupEngineRecordForSelection(
  BackupWorkspaceEngineChoice engine,
) {
  return BackupEngine.postgres;
}

/// The engine workflow that runs backups for [engine].
String backupWorkflowIdForSelection(BackupWorkspaceEngineChoice engine) {
  return 'postgres';
}

/// Whether [engine] can back up to [destinationType].
///
/// Every combination is supported today. The check exists so the screen asks
/// the question in one place, rather than growing the answer inline once it
/// stops being yes.
bool backupDestinationSupportedForEngine({
  required BackupWorkspaceEngineChoice engine,
  required BackupDestinationType destinationType,
}) {
  return true;
}

/// The destinations offerable for [engine], filtered by
/// [backupDestinationSupportedForEngine]'s rule.
List<BackupDestinationRecord> eligibleBackupDestinationsForEngine({
  required BackupWorkspaceEngineChoice engine,
  required List<BackupDestinationRecord> destinations,
}) {
  return destinations;
}

/// The PostgreSQL settings every backup operation starts from.
///
/// Server configuration plus the project's slug -- the caller adds the
/// destination and plan keys on top.
Map<String, dynamic> buildBackupBasePostgresSettings({
  required String projectName,
  required Server server,
}) {
  return <String, dynamic>{
    'postgres_version': server.postgresConfig.postgresVersion,
    'superuser_password': server.postgresConfig.superuserPassword,
    'enabled_extensions': server.postgresConfig.enabledExtensions,
    'project_slug': slugifyProjectName(
      projectName,
      fallback: 'project-backups',
    ),
  };
}

/// The settings keys describing where a backup goes.
///
/// S3 carries its credentials in the payload because the server performs the
/// upload, not the desktop app. Anything that is not S3 is treated as a
/// filesystem path on the managed server itself -- which is a destination on
/// the same machine as the database, and so is a convenience rather than a
/// disaster-recovery destination.
Map<String, dynamic> buildBackupDestinationSettings({
  required BackupWorkspaceEngineChoice engine,
  required BackupDestinationType destinationType,
  required Map<String, dynamic> destinationConfig,
}) {
  if (destinationType == BackupDestinationType.s3) {
    return <String, dynamic>{
      'backup_destination_type': 's3',
      'backup_s3_prefix': destinationConfig['prefix'],
      'backup_aws_access_key_id': destinationConfig['access_key_id'],
      'backup_aws_secret_access_key': destinationConfig['secret_access_key'],
      'backup_aws_region': destinationConfig['region'],
      'backup_aws_endpoint': destinationConfig['endpoint'],
      'backup_aws_force_path_style':
          destinationConfig['force_path_style'] == true,
    };
  }
  return <String, dynamic>{
    'backup_destination_type': 'filesystem',
    'backup_file_prefix': destinationConfig['file_prefix'],
  };
}

/// Reads the artifact list an engine backup operation returns.
///
/// Skips any entry without a remote path: the path is the artifact's identity
/// and what a restore acts on, so an entry lacking one cannot be offered.
/// A missing or unparseable timestamp or size is kept as null rather than
/// guessed -- the row still restores, it just shows less.
///
/// Ids are synthesized as `<policy>:<remote path>` with unsafe characters
/// replaced, so re-reading the same remote listing produces the same ids and
/// does not duplicate rows.
List<BackupArtifactRecord> backupArtifactsFromBackendPayload({
  required Object? artifactsPayload,
  required BackupPolicyRecord policy,
  required BackupDestinationRecord destination,
  DateTime? discoveredAt,
}) {
  if (artifactsPayload is! List) {
    return const <BackupArtifactRecord>[];
  }
  final observedAt = discoveredAt ?? DateTime.now().toUtc();
  final artifacts = <BackupArtifactRecord>[];
  for (final item in artifactsPayload) {
    if (item is! Map) {
      continue;
    }
    final map = item.map((key, value) => MapEntry(key.toString(), value));
    final remotePath = map['remote_path']?.toString().trim();
    if (remotePath == null || remotePath.isEmpty) {
      continue;
    }
    final createdAtRaw = map['created_at']?.toString().trim();
    final createdAt = createdAtRaw == null || createdAtRaw.isEmpty
        ? null
        : DateTime.tryParse(createdAtRaw);
    final sizeBytes = switch (map['size_bytes']) {
      final int value => value,
      final String value => int.tryParse(value.trim()),
      _ => null,
    };
    artifacts.add(
      BackupArtifactRecord(
        id: '${policy.id}:$remotePath'.replaceAll(
          RegExp(r'[^a-zA-Z0-9:_./-]+'),
          '_',
        ),
        engine: policy.engine,
        policyId: policy.id,
        projectId: policy.projectId,
        serverId: policy.serverId,
        destinationId: destination.id,
        databaseName: policy.databaseName,
        remotePath: remotePath,
        createdAtRemote: createdAt,
        sizeBytes: sizeBytes,
        metadataJson: null,
        discoveredAt: observedAt,
      ),
    );
  }
  return artifacts;
}

/// Whether an artifact-list response is a scheduler dedup, not a listing.
///
/// A deduped `runWorkflow` answer reports `status: success` with
/// `code: ENGINE_OPERATION_DEDUPED` and no `artifacts` key — the identical
/// request is still queued or running under another operation id. It must
/// never be read as an empty list: replacing stored artifacts from it would
/// delete every known backup and show "No backups are ready to restore yet"
/// until the next refresh.
bool isBackupArtifactRefreshDuplicate(Map<String, dynamic> response) {
  return response['code']?.toString() == 'ENGINE_OPERATION_DEDUPED';
}

/// What to tell the user when a refresh dedupes instead of listing.
///
/// The running original will populate the list when it finishes; this names
/// the wait rather than reporting success or failure.
String backupArtifactRefreshDuplicateMessage() {
  return 'A backup refresh is already running. '
      'Wait for it to finish and the list will update.';
}

/// The engine's message for display, with its details appended when they add
/// something.
///
/// Identical details are dropped rather than shown twice, and a blank message
/// falls back to [fallback] -- a backup failure that renders as an empty
/// dialog is worse than a generic sentence.
String backupResponseMessageWithDetails(
  Map<String, dynamic> response, {
  required String fallback,
}) {
  final message = response['msg']?.toString().trim();
  final details = response['details']?.toString().trim();
  final resolvedMessage = (message == null || message.isEmpty)
      ? fallback
      : message;
  if (details == null || details.isEmpty || details == resolvedMessage) {
    return resolvedMessage;
  }
  return '$resolvedMessage\n$details';
}

/// One pipe-separated line for the activity log.
///
/// The log is dense by design, so this is deliberately not
/// [backupResponseMessageWithDetails]: same inputs, one line instead of two.
String buildBackupResultLogLine({
  required String prefix,
  required Map<String, dynamic> response,
}) {
  final baseMessage = response['msg']?.toString().trim();
  final details = response['details']?.toString().trim();
  final segments = <String>[
    prefix,
    if (baseMessage != null && baseMessage.isNotEmpty) baseMessage,
    if (details != null && details.isNotEmpty && details != baseMessage)
      details,
  ];
  return segments.join(' | ');
}

/// The first problem with the destination form, or null when it is valid.
///
/// Which fields are required depends on the destination type, so this cannot
/// live on the individual fields. S3 needs bucket, key, secret and region;
/// a filesystem destination needs only its path prefix.
String? validateBackupDestinationInput({
  required String name,
  required BackupDestinationType destinationType,
  required String s3Prefix,
  required String s3AccessKeyId,
  required String s3SecretAccessKey,
  required String s3Region,
  required String filePrefix,
}) {
  if (name.trim().isEmpty) {
    return 'Destination name is required.';
  }
  if (destinationType == BackupDestinationType.s3) {
    if (s3Prefix.trim().isEmpty ||
        s3AccessKeyId.trim().isEmpty ||
        s3SecretAccessKey.trim().isEmpty ||
        s3Region.trim().isEmpty) {
      return 'Bucket name, access key, secret key, and region are required.';
    }
    return null;
  }
  if (filePrefix.trim().isEmpty) {
    return 'Filesystem path prefix is required.';
  }
  return null;
}

// end coverage-gate
/// A stored S3 endpoint with its scheme stripped, for display in the form.
///
/// Users think of an endpoint as a host. Showing the scheme invites them to
/// edit it, and the scheme is not theirs to choose -- see
/// [normalizeBackupEndpointInput].
String backupEndpointHostForDisplay(String rawEndpoint) {
  return rawEndpoint.trim().replaceFirst(
    RegExp(r'^https?://', caseSensitive: false),
    '',
  );
}

/// A typed endpoint stored back as `https://<host>`.
///
/// The scheme is forced to HTTPS whatever was typed: this endpoint carries
/// backup credentials to a third-party provider, and letting a stray `http://`
/// through would send them in the clear. A blank input stays blank, meaning
/// "use the provider default".
String normalizeBackupEndpointInput(String rawEndpoint) {
  final host = backupEndpointHostForDisplay(rawEndpoint);
  if (host.isEmpty) {
    return '';
  }
  return 'https://$host';
}

/// The destination form's values as the config map stored on the record.
///
/// The counterpart to [buildBackupDestinationSettings], which turns this same
/// config into engine settings.
Map<String, dynamic> buildBackupDestinationConfig({
  required BackupDestinationType destinationType,
  required String s3Prefix,
  required String s3AccessKeyId,
  required String s3SecretAccessKey,
  required String s3Region,
  required String s3Endpoint,
  required bool forcePathStyle,
  required String filePrefix,
}) {
  if (destinationType == BackupDestinationType.s3) {
    return <String, dynamic>{
      'prefix': s3Prefix.trim(),
      'access_key_id': s3AccessKeyId.trim(),
      'secret_access_key': s3SecretAccessKey.trim(),
      'region': s3Region.trim(),
      'endpoint': normalizeBackupEndpointInput(s3Endpoint),
      'force_path_style': forcePathStyle,
    };
  }
  return <String, dynamic>{'file_prefix': filePrefix.trim()};
}

/// The first problem with the plan form, or null when it is valid.
///
/// The second time is required only for a twice-daily schedule, and retention
/// must be at least one -- a plan that keeps zero backups would delete each
/// one as soon as it was made.
String? validateBackupPolicyInput({
  required String policyName,
  required String databaseName,
  required String scheduleMode,
  required String time1,
  required String time2,
  required String retentionText,
}) {
  if (policyName.trim().isEmpty || databaseName.trim().isEmpty) {
    return 'Policy name and database are required.';
  }
  if (!_backupHhmmPattern.hasMatch(time1.trim())) {
    return 'Time #1 must be HH:MM (24h).';
  }
  if (scheduleMode == 'daily_twice' &&
      !_backupHhmmPattern.hasMatch(time2.trim())) {
    return 'Time #2 must be HH:MM (24h).';
  }
  final retention = int.tryParse(retentionText.trim());
  if (retention == null || retention < 1) {
    return 'Retention must be at least 1.';
  }
  return null;
}
