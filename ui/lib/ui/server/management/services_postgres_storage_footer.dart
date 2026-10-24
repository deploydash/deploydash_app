part of '../server_management_view.dart';

/// The database row's storage section: shape, detached warning, and actions.
///
/// Renders what the engine reported about the data volume — backing volume,
/// data directory, size, layout currency — plus the detached-cluster banner,
/// the migrate button, and one explicit remove button per old copy, whether
/// a dangling anonymous volume or a kept pre-upgrade copy. Enable-decisions
/// live here from plain inputs, so the widget tests pin every combination
/// without reaching into tab state.
class _PostgresStorageFooter extends StatelessWidget {
  const _PostgresStorageFooter({
    required this.service,
    required this.storage,
    required this.migrateConflictReason,
    required this.removeConflictReason,
    required this.onMigrate,
    required this.onRemoveDetachedVolume,
    required this.onRemoveRetainedVolume,
    required this.onRemoveRetainedStorageSubpath,
  });

  /// The database service record, for busy state and readiness.
  final _ServerServiceRecord service;

  /// The parsed storage enrichment, unknown when the engine sent none.
  final PostgresStorageStatus storage;

  /// The formatted migrate conflict, null when nothing blocks it.
  final String? migrateConflictReason;

  /// The formatted remove conflict, null when nothing blocks it.
  final String? removeConflictReason;

  /// Starts the migrate confirm flow.
  final VoidCallback onMigrate;

  /// Starts the remove confirm flow for one dangling anonymous volume.
  final void Function(String volume) onRemoveDetachedVolume;

  /// Starts the remove confirm flow for one kept pre-upgrade copy.
  final void Function(String volume) onRemoveRetainedVolume;

  /// Starts removal for one ledger-attributed directory inside a volume.
  final void Function(PostgresRetainedStorageSubpath retained)
  onRemoveRetainedStorageSubpath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Hoisted so the `!= null` checks promote them; widget fields are never
    // promoted.
    final storage = this.storage;
    final detachedError = storage.storageError;
    final migrateConflictReason = this.migrateConflictReason;
    final removeConflictReason = this.removeConflictReason;
    final buttonsBusy = service.isBusy;

    String? migrateBlockedReason;
    if (buttonsBusy) {
      migrateBlockedReason = postgresStorageBusyReason();
    } else if (migrateConflictReason != null) {
      migrateBlockedReason = migrateConflictReason;
    } else if (storage.hasDetachedError) {
      migrateBlockedReason = postgresStorageDetachedFirstReason();
    } else if (!service.status.isReady) {
      migrateBlockedReason = postgresStorageStartFirstReason();
    }
    String? removeBlockedReason;
    if (buttonsBusy) {
      removeBlockedReason = postgresStorageBusyReason();
    } else if (removeConflictReason != null) {
      removeBlockedReason = removeConflictReason;
    } else if (storage.hasDetachedError) {
      removeBlockedReason = postgresStorageDetachedFirstReason();
    }

    final migrateButton = FilledButton(
      key: const Key('service-postgres-storage-migrate'),
      onPressed: migrateBlockedReason == null ? onMigrate : null,
      child: Text(postgresStorageMigrateButton()),
    );
    final dataSizeBytes = storage.dataSizeBytes;

    return Container(
      key: const Key('service-footer-database-storage'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            postgresStorageSectionTitle(),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            postgresStorageSectionSubtitle(),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          if (detachedError != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.error,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        postgresStorageDetachedTitle(),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detachedError,
                        key: const Key('service-postgres-storage-error'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          if (storage.hasKnownShape) ...[
            _PostgresStorageRow(
              label: 'Volume',
              value: postgresStorageVolumeLabel(
                name: storage.storageVolume,
                anonymous: storage.storageVolumeAnonymous,
              ),
            ),
            _PostgresStorageRow(
              label: 'Data directory',
              value: postgresStorageDataDirectoryLabel(storage.dataDirectory),
            ),
            _PostgresStorageRow(
              label: 'Size',
              value: dataSizeBytes == null
                  ? postgresStorageUnknownValue()
                  : formatDockerStorageBytes(dataSizeBytes),
            ),
            _PostgresStorageRow(
              label: 'Layout',
              value: postgresStorageLayoutLabel(storage.storageLayoutCurrent),
            ),
          ] else ...[
            Text(
              postgresStorageUnknownHint(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (storage.needsMigration) ...[
            const SizedBox(height: 10),
            if (migrateBlockedReason == null)
              migrateButton
            else
              Tooltip(message: migrateBlockedReason, child: migrateButton),
          ],
          if (storage.hasRemovalCandidates) ...[
            const SizedBox(height: 10),
            Text(
              postgresStorageOldCopiesTitle(
                storage.detachedStorageVolumes.length,
              ),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            for (final volume in storage.detachedStorageVolumes)
              _PostgresVolumeRemoveRow(
                label: postgresStorageVolumeLabel(
                  name: volume,
                  anonymous: true,
                ),
                removeKey: Key('service-postgres-storage-remove-$volume'),
                blockedReason: removeBlockedReason,
                onRemove: () => onRemoveDetachedVolume(volume),
              ),
          ],
          if (storage.hasRetainedUpgradeVolumes) ...[
            const SizedBox(height: 10),
            Text(
              postgresUpgradeRetainedTitle(
                storage.retainedUpgradeVolumes.length,
              ),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            for (final retained in storage.retainedUpgradeVolumes)
              _PostgresVolumeRemoveRow(
                label: postgresStorageVolumeLabel(
                  name: retained.volume,
                  anonymous: false,
                ),
                subtitle: postgresUpgradeRetainedSubtitle(
                  from: retained.fromMajor,
                  to: retained.toMajor,
                ),
                removeKey: Key(
                  'service-postgres-storage-remove-${retained.volume}',
                ),
                blockedReason: removeBlockedReason,
                onRemove: () => onRemoveRetainedVolume(retained.volume),
              ),
          ],
          if (storage.hasRetainedStorageSubpaths) ...[
            const SizedBox(height: 10),
            Text(
              postgresStorageRetainedSubpathsTitle(
                storage.retainedStorageSubpaths.length,
              ),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            for (final retained in storage.retainedStorageSubpaths)
              _PostgresVolumeRemoveRow(
                label: postgresStorageVolumeLabel(
                  name: retained.volume,
                  anonymous: false,
                ),
                subtitle: postgresStorageRetainedSubpathSubtitle(
                  retained.subpath,
                ),
                removeKey: Key(
                  'service-postgres-storage-remove-'
                  '${retained.volume}-${retained.subpath}',
                ),
                blockedReason: removeBlockedReason,
                onRemove: () => onRemoveRetainedStorageSubpath(retained),
              ),
          ],
        ],
      ),
    );
  }
}

/// One old copy with its own explicit remove button.
///
/// A widget rather than a helper method so both old-copies lists read as
/// data: the label names the volume, the optional subtitle says where it
/// came from, and the button removes exactly this copy. The removal engine
/// operation acts on one named volume, which is why each row carries its
/// own button instead of sharing one per list.
class _PostgresVolumeRemoveRow extends StatelessWidget {
  const _PostgresVolumeRemoveRow({
    required this.label,
    required this.removeKey,
    required this.blockedReason,
    required this.onRemove,
    this.subtitle,
  });

  /// How the volume reads, via [postgresStorageVolumeLabel].
  final String label;

  /// What the kept copy is, shown only for ledgered pre-upgrade copies.
  final String? subtitle;

  /// The remove button's key, namespaced by volume.
  final Key removeKey;

  /// Why removal waits, null when the button is live.
  final String? blockedReason;

  /// Starts the remove confirm flow for this copy.
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Hoisted so the `!= null` check promotes it; a widget field is never
    // promoted.
    final subtitle = this.subtitle;
    final blockedReason = this.blockedReason;
    final button = OutlinedButton(
      key: removeKey,
      onPressed: blockedReason == null ? onRemove : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: YaruColors.red,
        side: const BorderSide(color: YaruColors.red),
      ),
      child: Text(postgresStorageRemoveVolumeButton()),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 1),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (blockedReason == null)
            button
          else
            Tooltip(message: blockedReason, child: button),
        ],
      ),
    );
  }
}

/// One label/value line in the storage section.
///
/// A widget rather than a helper method so the section reads as data:
/// label above, value below, nothing else to decide.
class _PostgresStorageRow extends StatelessWidget {
  const _PostgresStorageRow({required this.label, required this.value});

  /// The small heading, such as 'Volume'.
  final String label;

  /// The reading, or 'Unknown' when that read failed.
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 1),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
