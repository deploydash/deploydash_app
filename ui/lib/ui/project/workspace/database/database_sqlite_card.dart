part of '../../project_workspace.dart';

class _DatabaseSqliteCard extends StatelessWidget {
  const _DatabaseSqliteCard({
    required this.state,
    required this.server,
    required this.project,
    required this.sqliteDatabases,
  });

  final _DatabaseTabViewState state;
  final Server? server;
  final Project? project;
  final List<ProjectSqliteDatabase> sqliteDatabases;

  // coverage-gate: sqlite_card
  @override
  Widget build(BuildContext context) {
    final activeServer = server;
    final activeProject = project;
    final canMutate = activeServer != null && activeProject != null;
    final topBusy = state._sqliteBusyAction == 'create';
    final sqliteError = state._sqliteError;

    return AppWorkspaceSection(
      key: const Key('database-sqlite-card'),
      icon: Icons.storage_outlined,
      title: 'SQLite',
      subtitle: 'Create SQLite database configs for your app.',
      headerAction: OutlinedButton.icon(
        key: const Key('database-sqlite-create-button'),
        onPressed: !canMutate || topBusy
            ? null
            : () => state._showCreateSqliteDatabaseDialog(
                server: activeServer,
                project: activeProject,
                existingDatabases: sqliteDatabases,
              ),
        icon: topBusy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add, size: 16),
        label: const Text('Create SQLite DB'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!canMutate)
            Text(
              'Select a server and project to manage SQLite databases.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (sqliteError != null) ...[
            Text(
              sqliteError,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: YaruColors.orange),
            ),
            const SizedBox(height: 10),
          ],
          if (canMutate && sqliteDatabases.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'No SQLite databases configured yet. Create one to add '
                'persistent local storage for your app.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (canMutate && sqliteDatabases.isNotEmpty)
            for (final sqlite in sqliteDatabases) ...[
              AppCard(
                margin: const EdgeInsets.only(bottom: 10),
                radius: 10,
                borderColor: Theme.of(context).colorScheme.outlineVariant,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            sqlite.name,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        AppStatusBadge(
                          label: sqlite.volumeExists == true
                              ? 'Ready'
                              : sqlite.volumeExists == false
                              ? 'Storage missing'
                              : 'Not checked',
                          tone: sqlite.volumeExists == true
                              ? AppStatusTone.positive
                              : sqlite.volumeExists == false
                              ? AppStatusTone.warning
                              : AppStatusTone.neutral,
                          icon: sqlite.volumeExists == true
                              ? Icons.check_circle_outline
                              : Icons.storage_outlined,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 16,
                      runSpacing: 6,
                      children: [
                        Text(
                          sqlite.isPrimary
                              ? 'Role: Primary'
                              : 'Role: Secondary',
                        ),
                        Text(
                          'Size: ${state._formatByteSize(sqlite.volumeSizeBytes)}',
                        ),
                        Text(state._formatSqliteCheckAge(sqlite.lastCheckedAt)),
                        if (state._isSqliteCheckStale(sqlite.lastCheckedAt))
                          const AppStatusBadge(
                            label: 'Stale status',
                            tone: AppStatusTone.warning,
                            icon: Icons.schedule,
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      key: Key('database-sqlite-connection-${sqlite.id}'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              sqlite.databaseUrl,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontFamily: 'monospace'),
                            ),
                          ),
                          IconButton(
                            key: Key(
                              'database-sqlite-copy-connection-${sqlite.id}',
                            ),
                            tooltip: 'Copy connection value',
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              await Clipboard.setData(
                                ClipboardData(text: sqlite.databaseUrl),
                              );
                              if (!state.mounted) {
                                return;
                              }
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text('SQLite connection copied.'),
                                ),
                              );
                            },
                            icon: const Icon(
                              Icons.copy_outlined,
                              size: 18,
                              semanticLabel: 'Copy connection value',
                            ),
                          ),
                        ],
                      ),
                    ),
                    AppTechnicalDetails(
                      title: 'Technical details',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _LabeledValueRow(
                            label: 'Storage',
                            value: sqlite.volumeName,
                          ),
                          const SizedBox(height: 6),
                          _LabeledValueRow(
                            label: 'Mount path',
                            value: sqlite.mountPath,
                          ),
                          const SizedBox(height: 6),
                          _LabeledValueRow(
                            label: 'Database file',
                            value: sqlite.databasePath,
                          ),
                          if (sqlite.volumeMountpoint?.trim()
                              case final mountpoint?
                              when mountpoint.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            _LabeledValueRow(
                              label: 'Docker storage path',
                              value: mountpoint,
                            ),
                          ],
                          const SizedBox(height: 6),
                          Text(
                            'Checked at: ${state._formatTimestamp(sqlite.lastCheckedAt)}',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (sqlite.volumeExists != true)
                          OutlinedButton.icon(
                            onPressed:
                                (state._sqliteBusyDatabaseId == sqlite.id &&
                                    state._sqliteBusyAction != null)
                                ? null
                                : () => state._ensureSqliteVolume(
                                    server: activeServer,
                                    project: activeProject,
                                    sqliteDatabase: sqlite,
                                  ),
                            icon: const Icon(
                              Icons.cloud_done_outlined,
                              size: 16,
                            ),
                            label: Text(
                              state._sqliteBusyAction == 'ensure' &&
                                      state._sqliteBusyDatabaseId == sqlite.id
                                  ? 'Preparing...'
                                  : 'Prepare storage',
                            ),
                          ),
                        IconButton.outlined(
                          key: Key('database-sqlite-refresh-${sqlite.id}'),
                          tooltip:
                              state._sqliteBusyAction == 'status' &&
                                  state._sqliteBusyDatabaseId == sqlite.id
                              ? 'Refreshing storage status'
                              : 'Refresh storage status',
                          onPressed:
                              (state._sqliteBusyDatabaseId == sqlite.id &&
                                  state._sqliteBusyAction != null)
                              ? null
                              : () => state._refreshSqliteVolumeStatus(
                                  server: activeServer,
                                  project: activeProject,
                                  sqliteDatabase: sqlite,
                                ),
                          icon:
                              state._sqliteBusyAction == 'status' &&
                                  state._sqliteBusyDatabaseId == sqlite.id
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh, size: 16),
                        ),
                        if (!sqlite.isPrimary)
                          OutlinedButton.icon(
                            onPressed:
                                (state._sqliteBusyDatabaseId == sqlite.id &&
                                    state._sqliteBusyAction != null)
                                ? null
                                : () => state._setPrimarySqliteDatabase(
                                    projectId: activeProject.id,
                                    sqliteDatabaseId: sqlite.id,
                                  ),
                            icon: const Icon(Icons.star_outline, size: 16),
                            label: Text(
                              state._sqliteBusyAction == 'set_primary' &&
                                      state._sqliteBusyDatabaseId == sqlite.id
                                  ? 'Setting...'
                                  : 'Set primary',
                            ),
                          ),
                        IconButton.outlined(
                          key: Key('database-sqlite-delete-${sqlite.id}'),
                          tooltip:
                              state._sqliteBusyAction == 'delete' &&
                                  state._sqliteBusyDatabaseId == sqlite.id
                              ? 'Deleting SQLite database'
                              : 'Delete SQLite database',
                          style: IconButton.styleFrom(
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.error,
                          ),
                          onPressed:
                              (state._sqliteBusyDatabaseId == sqlite.id &&
                                  state._sqliteBusyAction != null)
                              ? null
                              : () => state._deleteSqliteDatabase(
                                  server: activeServer,
                                  project: activeProject,
                                  sqliteDatabase: sqlite,
                                ),
                          icon:
                              state._sqliteBusyAction == 'delete' &&
                                  state._sqliteBusyDatabaseId == sqlite.id
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.delete_outline, size: 16),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
        ],
      ),
    );
  }
}
// end coverage-gate
