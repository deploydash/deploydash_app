import 'package:ui/data/local/backup_repository.dart';
import 'package:ui/data/local/server_repository.dart';
import 'package:ui/services/backup_logic.dart';
import 'package:ui/utils/project_slug.dart';
import 'package:flutter_test/flutter_test.dart';

const _server = Server(
  id: 'server-backup',
  name: 'srv.backup.local',
  host: '192.168.1.10',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
  serviceDatabaseEnabled: true,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
  postgresConfig: ServerPostgresConfig(
    postgresVersion: '17',
    superuserPassword: 'postgres-root',
    enabledExtensions: ['vector'],
  ),
);

BackupDestinationRecord _destination(
  String id,
  BackupDestinationType type,
  Map<String, dynamic> config,
) {
  final now = DateTime.utc(2026, 4, 16);
  return BackupDestinationRecord(
    id: id,
    projectId: 'project-1',
    serverId: 'server-backup',
    name: id,
    type: type,
    config: config,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('backup logic helpers', () {
    test('workspace copy helpers stay novice friendly', () {
      expect(backupWorkspaceTitle(), 'Backups');
      expect(
        backupWorkspaceSubtitle(),
        'Choose where backups are stored, decide what runs automatically, and restore when you need to.',
      );
      expect(
        backupLoadErrorMessage(Exception('boom')),
        startsWith('Couldn’t load backup details.'),
      );
      expect(
        backupMissingCredentialsMessage(),
        'Deploy Dash can’t reach this server yet. Update SSH access in server settings.',
      );
      expect(
        backupDestinationDialogTitle(isEditing: false),
        'Add backup destination',
      );
      expect(
        backupDestinationDialogTitle(isEditing: true),
        'Edit backup destination',
      );
      expect(backupPolicyDialogTitle(isEditing: false), 'Add backup plan');
      expect(backupPolicyDialogTitle(isEditing: true), 'Edit backup plan');
      expect(backupEngineFieldLabel(), 'Service');
      expect(
        backupEngineSubtitle(),
        'Choose which service you want to back up or restore.',
      );
      expect(backupDestinationsHeading(), 'Where backups are stored');
      expect(
        backupDestinationsEmptyMessage(),
        'Add a destination before you create a backup plan.',
      );
      expect(
        backupPoliciesHeading(engine: BackupWorkspaceEngineChoice.postgres),
        'PostgreSQL backup plans',
      );
      expect(
        backupPoliciesEmptyMessage(
          engine: BackupWorkspaceEngineChoice.postgres,
        ),
        'No PostgreSQL backup plans yet.',
      );
      expect(backupArtifactsHeading(), 'Recent backups');
      expect(
        backupArtifactsEmptyMessage(),
        'No backups are ready to restore yet.',
      );
      expect(backupRunsHeading(), 'Recent activity');
      expect(backupRunsEmptyMessage(), 'No backup activity yet.');
    });

    test('slugifies project names with fallback', () {
      // D-26 (T-011): backupSlugifyProjectName folded into the owner; same
      // values asserted through slugifyProjectName with the explicit site
      // fallback.
      expect(
        slugifyProjectName('Hello World', fallback: 'project-backups'),
        'hello-world',
      );
      expect(
        slugifyProjectName('!!!', fallback: 'project-backups'),
        'project-backups',
      );
    });

    test('builds task id and engine selection metadata', () {
      expect(
        backupTaskIdForPolicy(
          policyId: 'Daily Main',
          engine: BackupWorkspaceEngineChoice.postgres,
        ),
        'backup-pg-daily-main',
      );
      expect(
        backupEngineRecordForSelection(BackupWorkspaceEngineChoice.postgres),
        BackupEngine.postgres,
      );
      expect(
        backupWorkflowIdForSelection(BackupWorkspaceEngineChoice.postgres),
        'postgres',
      );
    });

    test('filters eligible destinations for PostgreSQL', () {
      final destinations = [
        _destination('s3', BackupDestinationType.s3, {'prefix': 'pg'}),
        _destination('fs', BackupDestinationType.filesystem, {
          'file_prefix': '/var/backups/pg',
        }),
      ];

      expect(
        eligibleBackupDestinationsForEngine(
          engine: BackupWorkspaceEngineChoice.postgres,
          destinations: destinations,
        ),
        hasLength(2),
      );
    });

    test('builds base PostgreSQL settings', () {
      final settings = buildBackupBasePostgresSettings(
        projectName: 'Deploy Dash',
        server: _server,
      );

      // The server resolves its own managed root and identifiers
      // (T-1.1.4, T-1.4.4). A client that still sent them would be
      // rejected by the backend, so the payload must not carry them.
      expect(settings.containsKey('stack_root'), isFalse);
      expect(settings.containsKey('container_name'), isFalse);
      expect(settings.containsKey('superuser_name'), isFalse);
      expect(settings['postgres_version'], '17');
      expect(settings['superuser_password'], 'postgres-root');
      expect(settings['project_slug'], 'deploy-dash');
    });

    test('builds filesystem and s3 destination settings', () {
      expect(
        buildBackupDestinationSettings(
          engine: BackupWorkspaceEngineChoice.postgres,
          destinationType: BackupDestinationType.filesystem,
          destinationConfig: {'file_prefix': '/var/backups/pg'},
        ),
        {
          'backup_destination_type': 'filesystem',
          'backup_file_prefix': '/var/backups/pg',
        },
      );

      expect(
        buildBackupDestinationSettings(
          engine: BackupWorkspaceEngineChoice.postgres,
          destinationType: BackupDestinationType.s3,
          destinationConfig: {
            'prefix': 'pg-backups',
            'access_key_id': 'AKIA',
            'secret_access_key': 'SECRET',
            'region': 'eu-west-2',
            'endpoint': 'https://s3.example.com',
            'force_path_style': true,
          },
        ),
        {
          'backup_destination_type': 's3',
          'backup_s3_prefix': 'pg-backups',
          'backup_aws_access_key_id': 'AKIA',
          'backup_aws_secret_access_key': 'SECRET',
          'backup_aws_region': 'eu-west-2',
          'backup_aws_endpoint': 'https://s3.example.com',
          'backup_aws_force_path_style': true,
        },
      );
    });

    test('validates destination input', () {
      expect(
        validateBackupDestinationInput(
          name: '',
          destinationType: BackupDestinationType.s3,
          s3Prefix: '',
          s3AccessKeyId: '',
          s3SecretAccessKey: '',
          s3Region: '',
          filePrefix: '',
        ),
        'Destination name is required.',
      );

      expect(
        validateBackupDestinationInput(
          name: 'Local',
          destinationType: BackupDestinationType.filesystem,
          s3Prefix: '',
          s3AccessKeyId: '',
          s3SecretAccessKey: '',
          s3Region: '',
          filePrefix: '',
        ),
        'Filesystem path prefix is required.',
      );

      expect(
        validateBackupDestinationInput(
          name: 'S3',
          destinationType: BackupDestinationType.s3,
          s3Prefix: 'bucket',
          s3AccessKeyId: 'key',
          s3SecretAccessKey: 'secret',
          s3Region: '',
          filePrefix: '',
        ),
        'Bucket name, access key, secret key, and region are required.',
      );
    });

    test('formats backup response messages', () {
      expect(
        backupResponseMessageWithDetails({
          'msg': 'Done',
          'details': 'Done',
        }, fallback: 'Fallback'),
        'Done',
      );
      expect(
        backupResponseMessageWithDetails({
          'msg': 'Done',
          'details': 'Extra',
        }, fallback: 'Fallback'),
        'Done\nExtra',
      );
      expect(
        buildBackupResultLogLine(
          prefix: 'Backup run',
          response: {'msg': 'Done', 'details': 'Extra'},
        ),
        'Backup run | Done | Extra',
      );
    });

    test('normalizes endpoint display and input', () {
      expect(
        backupEndpointHostForDisplay('https://s3.example.com'),
        's3.example.com',
      );
      expect(
        normalizeBackupEndpointInput('s3.example.com'),
        'https://s3.example.com',
      );
    });

    test(
      'detects a deduped artifact refresh that must not clear stored backups',
      () {
        // Why: a deduped runWorkflow answer reports status success with code
        // ENGINE_OPERATION_DEDUPED and no artifacts key — the identical request
        // is still running. Reading it as an empty list wipes stored artifacts
        // and shows "No backups are ready to restore yet" until next refresh.
        expect(
          isBackupArtifactRefreshDuplicate(<String, dynamic>{
            'status': 'success',
            'code': 'ENGINE_OPERATION_DEDUPED',
            'msg':
                'Duplicate operation request ignored (already queued/running).',
            'duplicate_of_operation_id': 'op-1',
          }),
          isTrue,
        );
        expect(
          isBackupArtifactRefreshDuplicate(<String, dynamic>{
            'status': 'success',
            'code': 'OK',
            'artifacts': const <dynamic>[],
          }),
          isFalse,
        );
        expect(
          isBackupArtifactRefreshDuplicate(<String, dynamic>{
            'status': 'error',
            'code': 'ENGINE_RUNTIME_ERROR',
            'msg': 'boom',
          }),
          isFalse,
        );
        expect(backupArtifactRefreshDuplicateMessage(), isNotEmpty);
      },
    );

    test('formats byte counts as short human sizes', () {
      expect(backupHumanReadableBytes(0), '0 B');
      expect(backupHumanReadableBytes(512), '512 B');
      expect(backupHumanReadableBytes(1024), '1 KB');
      expect(backupHumanReadableBytes(1536), '1.5 KB');
      expect(backupHumanReadableBytes(1048576), '1 MB');
      expect(backupHumanReadableBytes(229638144), '219 MB');
      expect(backupHumanReadableBytes(5905580032), '5.5 GB');
      expect(backupHumanReadableBytes(1125899906842624), '1024 TB');
      expect(backupHumanReadableBytes(-8), '0 B');
    });

    test('reports a backlog with count, size, and protection', () {
      expect(
        backupBacklogReportMessage(
          count: 3,
          bytes: 229638144,
          unknownSizeCount: 0,
          keepLast: 1,
        ),
        '3 artifacts beyond retention (~219 MB). The newest 1 backup is kept.',
      );
      expect(
        backupBacklogReportMessage(
          count: 1,
          bytes: 1048576,
          unknownSizeCount: 0,
          keepLast: 2,
        ),
        '1 artifact beyond retention (~1 MB). The newest 2 backups are kept.',
      );
    });

    test('reports a backlog with unknown sizes honestly', () {
      expect(
        backupBacklogReportMessage(
          count: 3,
          bytes: 2097152,
          unknownSizeCount: 1,
          keepLast: 1,
        ),
        '3 artifacts beyond retention (~2 MB, 1 of 3 sizes unknown). '
        'The newest 1 backup is kept.',
      );
      expect(
        backupBacklogReportMessage(
          count: 4,
          bytes: 0,
          unknownSizeCount: 4,
          keepLast: 7,
        ),
        '4 artifacts beyond retention (size unknown). '
        'The newest 7 backups are kept.',
      );
    });

    test('announces cleanup outcomes', () {
      expect(backupBacklogCleanupEmptyMessage(), 'No old backups to clean up.');
      expect(
        backupBacklogCleanupSuccessMessage(deletedCount: 1),
        'Deleted 1 old backup.',
      );
      expect(
        backupBacklogCleanupSuccessMessage(deletedCount: 3),
        'Deleted 3 old backups.',
      );
    });

    test('parses string artifact byte sizes from backend payloads', () {
      const policy = BackupPolicyRecord(
        id: 'daily-main',
        projectId: 'project-1',
        serverId: 'server-backup',
        name: 'Daily main',
        destinationId: 's3',
        databaseName: 'app',
        scheduleMode: 'daily_once',
        time1Hhmm: '02:00',
        managedTaskId: 'backup-pg-daily-main',
      );
      final artifacts = backupArtifactsFromBackendPayload(
        artifactsPayload: const <Map<String, String>>[
          <String, String>{
            'remote_path': 'deploydash/postgres/project-1/app.dump',
            'size_bytes': ' 56194478 ',
          },
        ],
        policy: policy,
        destination: _destination(
          's3',
          BackupDestinationType.s3,
          const <String, dynamic>{'prefix': 's3://bucket/postgres'},
        ),
      );

      expect(artifacts, hasLength(1));
      expect(artifacts.single.sizeBytes, 56194478);
    });

    test('ignores malformed artifact containers and entries', () {
      const policy = BackupPolicyRecord(
        id: 'daily-main',
        projectId: 'project-1',
        serverId: 'server-backup',
        name: 'Daily main',
        destinationId: 's3',
        databaseName: 'app',
        scheduleMode: 'daily_once',
        time1Hhmm: '02:00',
        managedTaskId: 'backup-pg-daily-main',
      );
      final destination = _destination(
        's3',
        BackupDestinationType.s3,
        const <String, dynamic>{'prefix': 's3://bucket/postgres'},
      );

      expect(
        backupArtifactsFromBackendPayload(
          artifactsPayload: 'not-a-list',
          policy: policy,
          destination: destination,
        ),
        isEmpty,
      );
      expect(
        backupArtifactsFromBackendPayload(
          artifactsPayload: const <Object?>[
            'not-a-map',
            <String, Object?>{},
            <String, Object?>{'remote_path': ' '},
          ],
          policy: policy,
          destination: destination,
        ),
        isEmpty,
      );
    });
  });
}
