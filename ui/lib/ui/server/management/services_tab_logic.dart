import '../../../services/concurrency_engine.dart';

const Set<String> _serviceLifecycleOperationIds = <String>{
  'service_enable',
  'service_start',
  'service_stop',
  'service_disable',
  'service_restart',
  'service_configure',
  'service_delete',
  'service_migrate_storage',
  'service_remove_legacy_storage',
  'service_upgrade_major',
};

bool isServiceLifecycleOperation({
  required String? workflowId,
  required String? operationId,
}) {
  return (workflowId == 'http' || workflowId == 'postgres') &&
      _serviceLifecycleOperationIds.contains(operationId);
}

bool isActiveServiceLifecycleOperation(OperationQueueSnapshot entry) {
  final isActive = switch (entry.state) {
    OperationQueueState.queued ||
    OperationQueueState.dispatching ||
    OperationQueueState.running ||
    OperationQueueState.cancelling => true,
    _ => false,
  };
  return isActive &&
      isServiceLifecycleOperation(
        workflowId: entry.workflowId,
        operationId: entry.workflowOperationId,
      );
}

String servicesUnsupportedEnableReason() {
  return 'This service will appear here later. You can’t turn it on from this screen yet.';
}

String servicesCredentialsRequiredMessage() {
  return 'Deploy Dash can’t reach this server yet. Update SSH access in server settings.';
}

String serviceOperationLabel(String? operationId) {
  return switch (operationId) {
    'service_enable' => 'Turned on',
    'service_disable' => 'Stopped',
    'service_start' => 'Started',
    'service_stop' => 'Stopped',
    'service_restart' => 'Restarted',
    'service_delete' => 'Deleted',
    'service_configure' => 'Saved settings',
    'service_status' => 'Checked status',
    'service_migrate_storage' => 'Migrated storage',
    'service_remove_legacy_storage' => 'Removed old storage',
    'service_upgrade_major' => 'Upgraded major version',
    _ => 'Updated service',
  };
}

String servicesConfigureUnavailableMessage(String serviceName) {
  return '$serviceName settings are not available here yet.';
}

String servicesAvailableHeading() => 'Available services';

String servicesEnabledHeading() => 'Turned on';

String servicesOperationCenterHeading() => 'Active changes';

String servicesRecentActivityHeading() => 'Recent changes';

String servicesWorkspaceSubtitle() {
  return 'Turn services on, adjust settings, and review recent changes here.';
}

String servicesTemporaryDatabaseAccessTitle() => 'Temporary database access';

String servicesTemporaryDatabaseAccessSubtitle() {
  return 'Open a short-lived connection for imports, admin tools, or direct psql access. Deploy Dash closes it automatically after 1 hour.';
}

String servicesTemporaryDatabaseAccessOpenMessage() {
  return 'Temporary database access is on.';
}

String servicesTemporaryDatabaseAccessClosedHint() {
  return 'Use this when you need a short-lived external connection to PostgreSQL.';
}

String servicesTemporaryDatabaseAccessBlockedByFirewallChange() {
  return 'Another firewall change is already waiting. Finish or roll it back in Security first.';
}

String servicesTemporaryDatabaseAccessOpenButton() => 'Open for 1 hour';

String servicesTemporaryDatabaseAccessCloseButton() => 'Close access now';

String servicesTemporaryDatabaseAccessRefreshButton() => 'Refresh';

/// The storage section heading on the database service row.
///
/// One owner for the wording: the footer renders it, and the tests pin it
/// here, so a rename cannot drift between the two.
String postgresStorageSectionTitle() => 'Database storage';

/// What the storage section covers, for a reader who has never met Docker
/// volumes.
String postgresStorageSectionSubtitle() {
  return 'Where PostgreSQL keeps its data, and how much it holds.';
}

/// The shared placeholder when a storage reading is unavailable.
String postgresStorageUnknownValue() => 'Unknown';

/// How the backing volume reads: its name plus its kind.
///
/// Anonymous volumes are 64-hex ids, so only the Docker-short-id prefix
/// shows; a named volume shows whole. An unknown anonymity reads as named:
/// the engine only flags what it positively identified as anonymous.
String postgresStorageVolumeLabel({
  required String? name,
  required bool? anonymous,
}) {
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty) return postgresStorageUnknownValue();
  if (anonymous == true && trimmed.length > 12) {
    return '${trimmed.substring(0, 12)}… (anonymous volume)';
  }
  if (anonymous == true) return '$trimmed (anonymous volume)';
  return '$trimmed (named volume)';
}

/// How the layout currency reads: up to date, migratable, or unknown.
String postgresStorageLayoutLabel(bool? current) {
  if (current == null) return postgresStorageUnknownValue();
  return current ? 'Up to date' : 'Needs migration';
}

/// How the live data directory reads, or unknown when the read failed.
String postgresStorageDataDirectoryLabel(String? dataDirectory) {
  final trimmed = dataDirectory?.trim() ?? '';
  return trimmed.isEmpty ? postgresStorageUnknownValue() : trimmed;
}

/// The detached-cluster banner heading; the engine owns the detail text.
String postgresStorageDetachedTitle() => 'Data volume may be detached';

/// The kept-old-copies list heading, with its count.
String postgresStorageOldCopiesTitle(int count) => 'Old data copies ($count)';

/// Keeps the retained-directory count owned with the rest of the service copy.
String postgresStorageRetainedSubpathsTitle(int count) =>
    'Kept migration folders ($count)';

/// Makes the destructive target explicit before the user chooses removal.
String postgresStorageRetainedSubpathSubtitle(String subpath) =>
    'Folder $subpath, kept after storage migration.';

/// The button starting the named-volume migration.
String postgresStorageMigrateButton() => 'Migrate storage';

/// The migration confirm dialog title.
String postgresStorageMigrateDialogTitle() => 'Migrate database storage';

/// What the migration does, including the downtime and the kept old copy.
///
/// States both consequences up front: the stop is the surprise to avoid,
/// and the kept copy is the safety net to mention.
String postgresStorageMigrateDialogDescription() {
  return 'Copies the database into the named volume. The database stops for '
      'a few minutes, and the old copy stays behind until you remove it.';
}

/// The migration confirm dialog action.
String postgresStorageMigrateDialogConfirm() => 'Migrate';

/// The remove-old-copy confirm warning: permanent, and conditional on the
/// new copy working.
String postgresStorageRemoveDialogWarning() {
  return 'This permanently deletes the old data copy kept from migration. '
      'Only remove it after confirming the database works.';
}

/// The remove-old-copy checkbox: names the old copy, not "all data".
String postgresStorageRemoveDialogAcknowledge() {
  return 'I understand the old copy is deleted permanently.';
}

/// The single line shown when no storage reading exists at all.
String postgresStorageUnknownHint() {
  return 'Storage details are unavailable for this service.';
}

/// Why a storage button waits while another service action runs.
String postgresStorageBusyReason() {
  return 'Please wait for the current service action to finish.';
}

/// Why migration waits for a stopped database to start.
String postgresStorageStartFirstReason() {
  return 'Start the database service before migrating storage.';
}

/// Why storage changes wait while the data volume is detached.
///
/// Removing a dangling volume while detached could delete the very data
/// being recovered, so both buttons share this block.
String postgresStorageDetachedFirstReason() {
  return 'Resolve the detached data volume before changing storage.';
}

/// The migration dialog note: the restart back onto the new volume is
/// automatic, not a follow-up step for the reader.
String postgresStorageMigrateDialogNote() {
  return 'Deploy Dash restarts the database on the new volume automatically.';
}

/// The button opening the major-upgrade flow from the database settings.
String postgresUpgradeButton() => 'Upgrade major version…';

/// The upgrade dialog title.
String postgresUpgradeDialogTitle() => 'Upgrade PostgreSQL version';

/// What the upgrade does: the downtime warning first, then the automatic
/// restart, so the surprise lands before the reassurance.
String postgresUpgradeDialogDescription() {
  return 'Moves every database to the new version. The database stops during '
      'the move — larger databases take longer — and restarts automatically.';
}

/// The upgrade confirm dialog action.
String postgresUpgradeDialogConfirm() => 'Upgrade';

/// The upgrade dialog note: the dump, the verification, and the kept old
/// copy — the three facts that make the downtime acceptable.
String postgresUpgradeDialogNote() {
  return 'Deploy Dash dumps every database first, verifies the restored '
      'data, and keeps the old copy until you remove it.';
}

/// How the locked major version reads in the database settings.
String postgresUpgradeFixedVersionLabel(String version) =>
    'PostgreSQL $version (current version)';

/// Why the settings show the version fixed instead of a picker.
String postgresUpgradeFixedVersionHint() {
  return 'The major version cannot change here. Upgrade to move your data '
      'safely.';
}

/// The success message after an upgrade, naming the new major.
String postgresUpgradeSuccessMessage(String version) =>
    'Database upgraded to PostgreSQL $version.';

/// Why the upgrade waits for a stopped database to start.
String postgresUpgradeNotReadyReason() {
  return 'Start the database service before upgrading the major version.';
}

/// The pre-selected upgrade target: newest, unless already there.
///
/// Upgrades move forward; downgrades stay possible through the picker but
/// are never the default.
String postgresUpgradeDefaultTarget(String currentVersion) {
  if (currentVersion == '18') {
    return '17';
  }
  return '18';
}

/// The kept pre-upgrade copies list heading, with its count.
String postgresUpgradeRetainedTitle(int count) =>
    'Kept upgrade copies ($count)';

/// What one kept copy is: which major's data, and which upgrade kept it.
String postgresUpgradeRetainedSubtitle({
  required String from,
  required String to,
}) => 'PostgreSQL $from data, kept when upgrading to $to.';

/// The remove-kept-copy confirm warning: permanent, and conditional on the
/// upgraded database working.
String postgresUpgradeRemoveDialogWarning() {
  return 'This permanently deletes the pre-upgrade data copy. Only remove it '
      'after confirming the upgraded database works.';
}

/// The remove-kept-copy checkbox: names the pre-upgrade copy, not "all data".
String postgresUpgradeRemoveDialogAcknowledge() {
  return 'I understand the pre-upgrade copy is deleted permanently.';
}

/// The success message after removing a kept pre-upgrade copy.
String postgresUpgradeRemoveSuccessMessage() {
  return 'Pre-upgrade database copy removed.';
}

/// The per-volume remove button in the old-copies lists.
String postgresStorageRemoveVolumeButton() => 'Remove';
