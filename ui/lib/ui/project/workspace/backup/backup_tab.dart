part of '../../project_workspace.dart';

class _BackupDestinationDraft {
  const _BackupDestinationDraft({
    this.id,
    required this.name,
    required this.type,
    required this.config,
  });

  final String? id;
  final String name;
  final BackupDestinationType type;
  final Map<String, dynamic> config;

  static _BackupDestinationDraft fromRecord(BackupDestinationRecord record) {
    return _BackupDestinationDraft(
      id: record.id,
      name: record.name,
      type: record.type,
      config: Map<String, dynamic>.from(record.config),
    );
  }
}

class _BackupPolicyDraft {
  const _BackupPolicyDraft({
    this.id,
    required this.name,
    required this.destinationId,
    required this.databaseName,
    required this.scheduleMode,
    required this.time1Hhmm,
    this.time2Hhmm,
    required this.retentionKeepLast,
    required this.enabled,
    this.managedTaskId,
  });

  final String? id;
  final String name;
  final String destinationId;
  final String databaseName;
  final String scheduleMode;
  final String time1Hhmm;
  final String? time2Hhmm;
  final int retentionKeepLast;
  final bool enabled;
  final String? managedTaskId;

  static _BackupPolicyDraft fromRecord(BackupPolicyRecord record) {
    return _BackupPolicyDraft(
      id: record.id,
      name: record.name,
      destinationId: record.destinationId,
      databaseName: record.databaseName,
      scheduleMode: record.scheduleMode,
      time1Hhmm: record.time1Hhmm,
      time2Hhmm: record.time2Hhmm,
      retentionKeepLast: record.retentionKeepLast,
      enabled: record.enabled,
      managedTaskId: record.managedTaskId,
    );
  }
}

class _BackupRestoreDraft {
  const _BackupRestoreDraft({required this.targetDatabaseName});

  final String targetDatabaseName;
}

enum _BackupEngineChoice { postgres }

BackupWorkspaceEngineChoice _workspaceBackupEngineChoice(
  _BackupEngineChoice engine,
) {
  return BackupWorkspaceEngineChoice.postgres;
}

class _BackupTabView extends StatelessWidget {
  const _BackupTabView({this.onTerminalLine, this.onOpenServerServices});

  final ProjectTerminalLineWriter? onTerminalLine;
  final VoidCallback? onOpenServerServices;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        AppWorkspaceSection(
          icon: Icons.backup,
          title: backupWorkspaceTitle(),
          subtitle: backupWorkspaceSubtitle(),
          child: _BackupSummary(
            onTerminalLine: onTerminalLine,
            onOpenServerServices: onOpenServerServices,
          ),
        ),
      ],
    );
  }
}

class _BackupSummary extends ConsumerStatefulWidget {
  const _BackupSummary({this.onTerminalLine, this.onOpenServerServices});

  final ProjectTerminalLineWriter? onTerminalLine;
  final VoidCallback? onOpenServerServices;

  @override
  ConsumerState<_BackupSummary> createState() => _BackupSummaryState();
}

class _BackupSummaryState extends ConsumerState<_BackupSummary>
    with WorkspaceScopedConsumerState<_BackupSummary> {
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;
  List<String> _projectDatabases = const <String>[];
  _BackupEngineChoice _selectedEngine = _BackupEngineChoice.postgres;

  @override
  // coverage-gate: backup_tab_build
  Widget build(BuildContext context) {
    final selectedProject = ref.watch(selectedProjectProvider);
    final selectedServer = ref.watch(selectedServerProvider);
    _scheduleSelectionBind(selectedProject, selectedServer);

    if (selectedProject == null || selectedServer == null) {
      return const Text(
        'Select a project and server to manage backups.',
        key: Key('backup-missing-selection-message'),
      );
    }
    final postgresEnabled = selectedServer.serviceDatabaseEnabled;
    if (!postgresEnabled) {
      return Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text(
            'Enable PostgreSQL in Server Management to manage backups.',
            key: Key('backup-service-disabled-message'),
          ),
          OutlinedButton(
            key: const Key('backup-open-server-services-button'),
            onPressed: widget.onOpenServerServices,
            child: const Text('Open server services'),
          ),
        ],
      );
    }

    final scope = ref
        .watch(projectBackupProvider)
        .scopeFor(projectId: selectedProject.id, serverId: selectedServer.id);
    final destinations = scope.destinations;
    final visibleDestinations = _eligibleDestinationsForActiveEngine(
      destinations,
    );
    final activeEngine = _activeEngineRecord();
    final policies = scope.policies
        .where((policy) => policy.engine == activeEngine)
        .toList(growable: false);
    final artifacts = scope.artifacts
        .where((artifact) => artifact.engine == activeEngine)
        .toList(growable: false);
    final runs = scope.runs
        .where((run) => run.engine == activeEngine)
        .toList(growable: false);

    final destinationsById = {
      for (final destination in destinations) destination.id: destination,
    };
    final artifactsByPolicy = <String, List<BackupArtifactRecord>>{};
    for (final artifact in artifacts) {
      final policyArtifacts = artifactsByPolicy.putIfAbsent(
        artifact.policyId,
        () => <BackupArtifactRecord>[],
      );
      policyArtifacts.add(artifact);
    }

    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    // Hoisted so the `!= null` check promotes it; a State field is never
    // promoted.
    final error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(
            key: const Key('backup-inline-error-text'),
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Text(
                backupDestinationsHeading(),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            IconButton(
              key: const Key('backup-add-destination-button'),
              tooltip: 'Add backup destination',
              onPressed: _isSaving
                  ? null
                  : () async {
                      final draft = await _showDestinationDialog(
                        project: selectedProject,
                        server: selectedServer,
                      );
                      if (draft == null) {
                        return;
                      }
                      await _saveDestination(
                        project: selectedProject,
                        server: selectedServer,
                        draft: draft,
                      );
                    },
              icon: const Icon(
                Icons.add,
                semanticLabel: 'Add backup destination',
              ),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (visibleDestinations.isEmpty)
          Text(backupDestinationsEmptyMessage())
        else
          ...visibleDestinations.map(
            (destination) => AppResourceRow(
              key: Key('backup-destination-${destination.id}'),
              leading: Icon(
                destination.type == BackupDestinationType.s3
                    ? Icons.cloud_outlined
                    : Icons.folder_open_outlined,
              ),
              title: destination.name,
              subtitle: destination.type == BackupDestinationType.s3
                  ? (destination.config['prefix']?.toString() ?? '')
                  : (destination.config['file_prefix']?.toString() ?? ''),
              actions: [
                IconButton(
                  key: Key('backup-destination-edit-${destination.id}'),
                  tooltip: 'Edit destination',
                  icon: const Icon(
                    Icons.edit_outlined,
                    semanticLabel: 'Edit destination',
                  ),
                  onPressed: _isSaving
                      ? null
                      : () async {
                          final draft = await _showDestinationDialog(
                            project: selectedProject,
                            server: selectedServer,
                            initial: _BackupDestinationDraft.fromRecord(
                              destination,
                            ),
                          );
                          if (draft == null) {
                            return;
                          }
                          await _saveDestination(
                            project: selectedProject,
                            server: selectedServer,
                            draft: draft,
                          );
                        },
                ),
                IconButton(
                  key: Key('backup-destination-delete-${destination.id}'),
                  tooltip: 'Delete destination',
                  icon: const Icon(
                    Icons.delete_outline,
                    semanticLabel: 'Delete destination',
                  ),
                  onPressed: _isSaving
                      ? null
                      : () => _deleteDestination(
                          project: selectedProject,
                          server: selectedServer,
                          destination: destination,
                        ),
                ),
              ],
            ),
          ),
        if (visibleDestinations.isNotEmpty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('backup-add-policy-button'),
              onPressed: _isSaving
                  ? null
                  : () async {
                      final scaffoldMessenger = ScaffoldMessenger.of(context);
                      final draft = await _showPolicyDialog(
                        destinations: destinations,
                      );
                      if (draft == null) {
                        return;
                      }
                      if (!isCurrentWorkspaceSelection(
                        selectedProject,
                        selectedServer,
                      )) {
                        return;
                      }
                      final destination = _currentDestinationForScope(
                        project: selectedProject,
                        server: selectedServer,
                        destinationId: draft.destinationId,
                      );
                      if (destination == null) {
                        scaffoldMessenger.showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Selected destination no longer exists.',
                            ),
                          ),
                        );
                        return;
                      }
                      await _savePolicy(
                        project: selectedProject,
                        server: selectedServer,
                        draft: draft,
                        destination: destination,
                      );
                    },
              icon: const Icon(Icons.schedule),
              label: const Text('Add PostgreSQL policy'),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          backupPoliciesHeading(
            engine: _workspaceBackupEngineChoice(_selectedEngine),
          ),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        if (policies.isEmpty)
          Text(
            backupPoliciesEmptyMessage(
              engine: _workspaceBackupEngineChoice(_selectedEngine),
            ),
          )
        else
          ...policies.map((policy) {
            final destination = destinationsById[policy.destinationId];
            final policyArtifacts =
                artifactsByPolicy[policy.id] ?? const <BackupArtifactRecord>[];

            return Card(
              key: Key('backup-policy-${policy.id}'),
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            policy.name,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        Wrap(
                          spacing: 4,
                          children: [
                            IconButton(
                              key: Key('backup-policy-run-${policy.id}'),
                              tooltip: 'Run backup now',
                              onPressed: _isSaving || destination == null
                                  ? null
                                  : () => _runBackupNow(
                                      project: selectedProject,
                                      server: selectedServer,
                                      policy: policy,
                                      destination: destination,
                                    ),
                              icon: const Icon(
                                Icons.play_arrow,
                                semanticLabel: 'Run backup now',
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            IconButton(
                              key: Key('backup-policy-cleanup-${policy.id}'),
                              tooltip: 'Clean up old backups',
                              onPressed: _isSaving || destination == null
                                  ? null
                                  : () => _cleanupBacklog(
                                      project: selectedProject,
                                      server: selectedServer,
                                      policy: policy,
                                      destination: destination,
                                    ),
                              icon: const Icon(
                                Icons.delete_sweep_outlined,
                                semanticLabel: 'Clean up old backups',
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            IconButton(
                              key: Key('backup-policy-edit-${policy.id}'),
                              tooltip: 'Edit backup plan',
                              onPressed: _isSaving
                                  ? null
                                  : () async {
                                      final scaffoldMessenger =
                                          ScaffoldMessenger.of(context);
                                      final draft = await _showPolicyDialog(
                                        destinations: destinations,
                                        initial: _BackupPolicyDraft.fromRecord(
                                          policy,
                                        ),
                                      );
                                      if (draft == null) {
                                        return;
                                      }
                                      if (!isCurrentWorkspaceSelection(
                                        selectedProject,
                                        selectedServer,
                                      )) {
                                        return;
                                      }
                                      final resolvedDestination =
                                          _currentDestinationForScope(
                                            project: selectedProject,
                                            server: selectedServer,
                                            destinationId: draft.destinationId,
                                          );
                                      if (resolvedDestination == null) {
                                        scaffoldMessenger.showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Selected destination no longer exists.',
                                            ),
                                          ),
                                        );
                                        return;
                                      }
                                      await _savePolicy(
                                        project: selectedProject,
                                        server: selectedServer,
                                        draft: draft,
                                        destination: resolvedDestination,
                                      );
                                    },
                              icon: const Icon(
                                Icons.edit_outlined,
                                semanticLabel: 'Edit backup plan',
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            IconButton(
                              key: Key('backup-policy-delete-${policy.id}'),
                              tooltip: 'Delete backup plan',
                              onPressed: _isSaving
                                  ? null
                                  : () => _deletePolicy(
                                      project: selectedProject,
                                      server: selectedServer,
                                      policy: policy,
                                    ),
                              icon: const Icon(
                                Icons.delete_outline,
                                semanticLabel: 'Delete backup plan',
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('Database: ${policy.databaseName}'),
                    Text(
                      'Destination: ${destination?.name ?? policy.destinationId}',
                    ),
                    Text(
                      policy.scheduleMode == 'daily_twice'
                          ? 'Schedule: ${policy.time1Hhmm} and ${policy.time2Hhmm ?? ''} daily'
                          : 'Schedule: ${policy.time1Hhmm} daily',
                    ),
                    Text('Retention: keep last ${policy.retentionKeepLast}'),
                    if (policy.lastRunAt != null)
                      Text('Last run: ${policy.lastRunAt}'),
                    if (policy.lastStatus != null)
                      Text(
                        'Status: ${policy.lastStatus}${policy.lastMessage == null ? '' : ' · ${policy.lastMessage}'}',
                      ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          backupArtifactsHeading(),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          key: Key('backup-policy-refresh-${policy.id}'),
                          tooltip: 'Refresh backups',
                          onPressed: _isSaving || destination == null
                              ? null
                              : () => _refreshArtifacts(
                                  project: selectedProject,
                                  server: selectedServer,
                                  policy: policy,
                                  destination: destination,
                                ),
                          icon: const Icon(
                            Icons.refresh,
                            semanticLabel: 'Refresh backups',
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (policyArtifacts.isEmpty)
                      Text(backupArtifactsEmptyMessage())
                    else
                      ...policyArtifacts
                          .take(8)
                          .map(
                            (artifact) => ListTile(
                              key: Key('backup-artifact-${artifact.id}'),
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              leading: const Icon(
                                Icons.insert_drive_file_outlined,
                              ),
                              title: Text(
                                artifact.remotePath,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${artifact.createdAtRemote ?? artifact.discoveredAt ?? ''}${artifact.sizeBytes == null ? '' : ' · ${artifact.sizeBytes} bytes'}',
                              ),
                              trailing: destination == null
                                  ? null
                                  : OutlinedButton(
                                      key: Key(
                                        'backup-artifact-restore-${artifact.id}',
                                      ),
                                      onPressed: _isSaving
                                          ? null
                                          : () => _restoreArtifact(
                                              project: selectedProject,
                                              server: selectedServer,
                                              policy: policy,
                                              destination: destination,
                                              artifact: artifact,
                                            ),
                                      child: const Text(
                                        'Restore into new database',
                                      ),
                                    ),
                            ),
                          ),
                  ],
                ),
              ),
            );
          }),
        const SizedBox(height: 12),
        Text(
          backupRunsHeading(),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        if (runs.isEmpty)
          Text(backupRunsEmptyMessage())
        else
          ...runs
              .take(20)
              .map(
                (run) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    run.operationType == BackupOperationType.restore
                        ? Icons.restore
                        : run.operationType == BackupOperationType.cleanup
                        ? Icons.delete_outline
                        : Icons.backup,
                    size: 20,
                  ),
                  title: Text(
                    '${run.operationType.name.toUpperCase()} · ${run.status}',
                  ),
                  subtitle: Text(
                    '${run.startedAt}${run.message == null ? '' : ' · ${run.message}'}',
                  ),
                  trailing: run.triggeredManually
                      ? const Chip(
                          label: Text('Manual'),
                          visualDensity: VisualDensity.compact,
                        )
                      : null,
                ),
              ),
      ],
    );
  }
}
// end coverage-gate
