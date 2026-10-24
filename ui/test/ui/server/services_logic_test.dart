import 'package:ui/services/concurrency_engine.dart';
import 'package:ui/ui/server/management/services_tab_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('services copy helpers use novice-friendly language', () {
    expect(
      servicesUnsupportedEnableReason(),
      'This service will appear here later. You can’t turn it on from this screen yet.',
    );
    expect(
      servicesCredentialsRequiredMessage(),
      'Deploy Dash can’t reach this server yet. Update SSH access in server settings.',
    );
    expect(serviceOperationLabel('service_enable'), 'Turned on');
    expect(serviceOperationLabel('service_disable'), 'Stopped');
    expect(serviceOperationLabel('service_start'), 'Started');
    expect(serviceOperationLabel('service_stop'), 'Stopped');
    expect(serviceOperationLabel('service_restart'), 'Restarted');
    expect(serviceOperationLabel('service_delete'), 'Deleted');
    expect(serviceOperationLabel('service_configure'), 'Saved settings');
    expect(serviceOperationLabel('service_status'), 'Checked status');
    expect(
      serviceOperationLabel('service_migrate_storage'),
      'Migrated storage',
    );
    expect(
      serviceOperationLabel('service_remove_legacy_storage'),
      'Removed old storage',
    );
    expect(
      serviceOperationLabel('service_upgrade_major'),
      'Upgraded major version',
    );
    expect(serviceOperationLabel('other'), 'Updated service');
    expect(
      servicesConfigureUnavailableMessage('Email'),
      'Email settings are not available here yet.',
    );
    expect(servicesAvailableHeading(), 'Available services');
    expect(servicesEnabledHeading(), 'Turned on');
    expect(servicesOperationCenterHeading(), 'Active changes');
    expect(servicesRecentActivityHeading(), 'Recent changes');
    expect(
      servicesWorkspaceSubtitle(),
      'Turn services on, adjust settings, and review recent changes here.',
    );
    expect(servicesTemporaryDatabaseAccessTitle(), 'Temporary database access');
    expect(
      servicesTemporaryDatabaseAccessOpenMessage(),
      'Temporary database access is on.',
    );
    expect(
      servicesTemporaryDatabaseAccessSubtitle(),
      'Open a short-lived connection for imports, admin tools, or direct psql access. Deploy Dash closes it automatically after 1 hour.',
    );
    expect(
      servicesTemporaryDatabaseAccessClosedHint(),
      'Use this when you need a short-lived external connection to PostgreSQL.',
    );
    expect(
      servicesTemporaryDatabaseAccessBlockedByFirewallChange(),
      'Another firewall change is already waiting. Finish or roll it back in Security first.',
    );
    expect(servicesTemporaryDatabaseAccessOpenButton(), 'Open for 1 hour');
    expect(servicesTemporaryDatabaseAccessCloseButton(), 'Close access now');
    expect(servicesTemporaryDatabaseAccessRefreshButton(), 'Refresh');
  });

  test('postgres storage copy stays novice-friendly and exact', () {
    expect(postgresStorageSectionTitle(), 'Database storage');
    expect(
      postgresStorageSectionSubtitle(),
      'Where PostgreSQL keeps its data, and how much it holds.',
    );
    expect(postgresStorageUnknownValue(), 'Unknown');
    expect(postgresStorageVolumeLabel(name: null, anonymous: null), 'Unknown');
    expect(postgresStorageVolumeLabel(name: '  ', anonymous: false), 'Unknown');
    expect(
      postgresStorageVolumeLabel(
        name: 'postgres_postgres_data',
        anonymous: false,
      ),
      'postgres_postgres_data (named volume)',
    );
    expect(
      postgresStorageVolumeLabel(
        name: 'postgres_postgres_data',
        anonymous: null,
      ),
      'postgres_postgres_data (named volume)',
    );
    expect(
      postgresStorageVolumeLabel(name: 'abc123', anonymous: true),
      'abc123 (anonymous volume)',
    );
    expect(
      postgresStorageVolumeLabel(name: 'a' * 64, anonymous: true),
      '${'a' * 12}… (anonymous volume)',
    );
    expect(postgresStorageLayoutLabel(true), 'Up to date');
    expect(postgresStorageLayoutLabel(false), 'Needs migration');
    expect(postgresStorageLayoutLabel(null), 'Unknown');
    expect(
      postgresStorageDataDirectoryLabel('/var/lib/postgresql/data/pgdata'),
      '/var/lib/postgresql/data/pgdata',
    );
    expect(postgresStorageDataDirectoryLabel(null), 'Unknown');
    expect(postgresStorageDataDirectoryLabel('  '), 'Unknown');
    expect(postgresStorageDetachedTitle(), 'Data volume may be detached');
    expect(postgresStorageOldCopiesTitle(2), 'Old data copies (2)');
    expect(
      postgresStorageRetainedSubpathsTitle(2),
      'Kept migration folders (2)',
    );
    expect(
      postgresStorageRetainedSubpathSubtitle('18/docker'),
      'Folder 18/docker, kept after storage migration.',
    );
    expect(postgresStorageMigrateButton(), 'Migrate storage');
    expect(postgresStorageMigrateDialogTitle(), 'Migrate database storage');
    expect(
      postgresStorageMigrateDialogDescription(),
      'Copies the database into the named volume. The database stops for a '
      'few minutes, and the old copy stays behind until you remove it.',
    );
    expect(postgresStorageMigrateDialogConfirm(), 'Migrate');
    expect(
      postgresStorageRemoveDialogWarning(),
      'This permanently deletes the old data copy kept from migration. Only '
      'remove it after confirming the database works.',
    );
    expect(
      postgresStorageRemoveDialogAcknowledge(),
      'I understand the old copy is deleted permanently.',
    );
    expect(
      postgresStorageUnknownHint(),
      'Storage details are unavailable for this service.',
    );
    expect(
      postgresStorageBusyReason(),
      'Please wait for the current service action to finish.',
    );
    expect(
      postgresStorageStartFirstReason(),
      'Start the database service before migrating storage.',
    );
    expect(
      postgresStorageDetachedFirstReason(),
      'Resolve the detached data volume before changing storage.',
    );
    expect(
      postgresStorageMigrateDialogNote(),
      'Deploy Dash restarts the database on the new volume automatically.',
    );
  });

  test('postgres major-upgrade copy stays novice-friendly and exact', () {
    expect(postgresUpgradeButton(), 'Upgrade major version…');
    expect(postgresUpgradeDialogTitle(), 'Upgrade PostgreSQL version');
    expect(
      postgresUpgradeDialogDescription(),
      'Moves every database to the new version. The database stops during '
      'the move — larger databases take longer — and restarts automatically.',
    );
    expect(postgresUpgradeDialogConfirm(), 'Upgrade');
    expect(
      postgresUpgradeDialogNote(),
      'Deploy Dash dumps every database first, verifies the restored data, '
      'and keeps the old copy until you remove it.',
    );
    expect(
      postgresUpgradeFixedVersionLabel('17'),
      'PostgreSQL 17 (current version)',
    );
    expect(
      postgresUpgradeFixedVersionHint(),
      'The major version cannot change here. Upgrade to move your data '
      'safely.',
    );
    expect(
      postgresUpgradeSuccessMessage('18'),
      'Database upgraded to PostgreSQL 18.',
    );
    expect(
      postgresUpgradeNotReadyReason(),
      'Start the database service before upgrading the major version.',
    );
    expect(postgresUpgradeDefaultTarget('16'), '18');
    expect(postgresUpgradeDefaultTarget('17'), '18');
    expect(postgresUpgradeDefaultTarget('18'), '17');
    expect(postgresUpgradeRetainedTitle(2), 'Kept upgrade copies (2)');
    expect(
      postgresUpgradeRetainedSubtitle(from: '17', to: '18'),
      'PostgreSQL 17 data, kept when upgrading to 18.',
    );
    expect(
      postgresUpgradeRemoveDialogWarning(),
      'This permanently deletes the pre-upgrade data copy. Only remove it '
      'after confirming the upgraded database works.',
    );
    expect(
      postgresUpgradeRemoveDialogAcknowledge(),
      'I understand the pre-upgrade copy is deleted permanently.',
    );
    expect(
      postgresUpgradeRemoveSuccessMessage(),
      'Pre-upgrade database copy removed.',
    );
    expect(postgresStorageRemoveVolumeButton(), 'Remove');
  });

  test('service lifecycle projection rejects checks and terminal history', () {
    expect(
      isServiceLifecycleOperation(
        workflowId: 'postgres',
        operationId: 'service_restart',
      ),
      isTrue,
    );
    expect(
      isServiceLifecycleOperation(
        workflowId: 'http',
        operationId: 'service_restart',
      ),
      isTrue,
    );
    expect(
      isServiceLifecycleOperation(
        workflowId: 'postgres',
        operationId: 'service_status',
      ),
      isFalse,
    );
    expect(
      isServiceLifecycleOperation(
        workflowId: 'postgres',
        operationId: 'service_migrate_storage',
      ),
      isTrue,
    );
    expect(
      isServiceLifecycleOperation(
        workflowId: 'postgres',
        operationId: 'service_remove_legacy_storage',
      ),
      isTrue,
    );
    expect(
      isServiceLifecycleOperation(
        workflowId: 'postgres',
        operationId: 'service_upgrade_major',
      ),
      isTrue,
    );
    expect(
      isServiceLifecycleOperation(
        workflowId: 'app',
        operationId: 'service_restart',
      ),
      isFalse,
    );
  });

  test(
    'active service projection accepts only non-terminal lifecycle work',
    () {
      OperationQueueSnapshot snapshot({
        required OperationQueueState state,
        String workflowId = 'postgres',
        String operationId = 'service_restart',
      }) {
        return OperationQueueSnapshot(
          operationInstanceId: 'operation-1',
          operationType: '$workflowId/$operationId',
          workflowId: workflowId,
          workflowOperationId: operationId,
          state: state,
          submittedAt: DateTime(2026),
          claims: const <OperationResourceClaim>[],
          metadata: const <String, dynamic>{},
          message: 'Operation accepted.',
        );
      }

      for (final state in <OperationQueueState>{
        OperationQueueState.queued,
        OperationQueueState.dispatching,
        OperationQueueState.running,
        OperationQueueState.cancelling,
      }) {
        expect(
          isActiveServiceLifecycleOperation(snapshot(state: state)),
          isTrue,
        );
      }
      expect(
        isActiveServiceLifecycleOperation(
          snapshot(state: OperationQueueState.succeeded),
        ),
        isFalse,
      );
      expect(
        isActiveServiceLifecycleOperation(
          snapshot(
            state: OperationQueueState.running,
            operationId: 'service_status',
          ),
        ),
        isFalse,
      );
    },
  );
}
