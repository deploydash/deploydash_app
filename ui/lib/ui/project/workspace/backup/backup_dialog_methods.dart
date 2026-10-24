part of '../../project_workspace.dart';

extension _BackupDialogMethods on _BackupSummaryState {
  // coverage-gate: backup_destination_dialog
  Future<_BackupDestinationDraft?> _showDestinationDialog({
    required Project project,
    required Server server,
    _BackupDestinationDraft? initial,
  }) async {
    return showDialog<_BackupDestinationDraft>(
      context: context,
      builder: (context) {
        final nameController = TextEditingController(text: initial?.name ?? '');
        var selectedType = initial?.type ?? BackupDestinationType.s3;
        final s3PrefixController = TextEditingController(
          text: initial?.config['prefix']?.toString() ?? '',
        );
        final s3AccessKeyController = TextEditingController(
          text: initial?.config['access_key_id']?.toString() ?? '',
        );
        final s3SecretController = TextEditingController(
          text: initial?.config['secret_access_key']?.toString() ?? '',
        );
        final s3RegionController = TextEditingController(
          text: initial?.config['region']?.toString() ?? '',
        );
        final s3EndpointController = TextEditingController(
          text: backupEndpointHostForDisplay(
            initial?.config['endpoint']?.toString() ?? '',
          ),
        );
        final filePrefixController = TextEditingController(
          text: initial?.config['file_prefix']?.toString() ?? '',
        );
        var forcePathStyle = initial?.config['force_path_style'] == true;
        var validationError = '';
        var testStatusMessage = '';
        var testStatusIsError = false;
        var isTesting = false;

        return StatefulBuilder(
          builder: (context, setState) {
            void clearValidationMessages() {
              if (validationError.isEmpty &&
                  testStatusMessage.isEmpty &&
                  !testStatusIsError) {
                return;
              }
              setState(() {
                validationError = '';
                testStatusMessage = '';
                testStatusIsError = false;
              });
            }

            Future<void> testConnection() async {
              final validationMessage = validateBackupDestinationInput(
                name: nameController.text,
                destinationType: selectedType,
                s3Prefix: s3PrefixController.text,
                s3AccessKeyId: s3AccessKeyController.text,
                s3SecretAccessKey: s3SecretController.text,
                s3Region: s3RegionController.text,
                filePrefix: filePrefixController.text,
              );
              if (validationMessage != null) {
                setState(() {
                  validationError = validationMessage;
                  testStatusMessage = '';
                  testStatusIsError = false;
                });
                return;
              }

              setState(() {
                validationError = '';
                isTesting = true;
                testStatusMessage = '';
                testStatusIsError = false;
              });
              _appendBackupTerminalLine(
                'Testing backup destination connectivity for PostgreSQL backups.',
                source: 'backup',
                taskType: 'backup',
              );
              try {
                final response = await _testBackupDestination(
                  project: project,
                  server: server,
                  destinationType: BackupDestinationType.s3,
                  destinationConfig: buildBackupDestinationConfig(
                    destinationType: BackupDestinationType.s3,
                    s3Prefix: s3PrefixController.text,
                    s3AccessKeyId: s3AccessKeyController.text,
                    s3SecretAccessKey: s3SecretController.text,
                    s3Region: s3RegionController.text,
                    s3Endpoint: s3EndpointController.text,
                    forcePathStyle: forcePathStyle,
                    filePrefix: filePrefixController.text,
                  ),
                );
                _appendBackupResultLog(
                  prefix: 'Backup destination test',
                  response: response,
                );
                setState(() {
                  isTesting = false;
                  testStatusIsError = response['status'] != 'success';
                  testStatusMessage = _responseMessageWithDetails(
                    response,
                    fallback: response['status'] == 'success'
                        ? 'Backup destination test succeeded.'
                        : 'Backup destination test failed.',
                  );
                });
              } catch (error) {
                setState(() {
                  isTesting = false;
                  testStatusIsError = true;
                  testStatusMessage = 'Backup destination test failed: $error';
                });
                _appendBackupTerminalLine(
                  testStatusMessage,
                  source: 'backup',
                  taskType: 'backup',
                  detail: true,
                );
              }
            }

            Future<void> submit() async {
              final name = nameController.text.trim();
              final validationMessage = validateBackupDestinationInput(
                name: nameController.text,
                destinationType: selectedType,
                s3Prefix: s3PrefixController.text,
                s3AccessKeyId: s3AccessKeyController.text,
                s3SecretAccessKey: s3SecretController.text,
                s3Region: s3RegionController.text,
                filePrefix: filePrefixController.text,
              );
              if (validationMessage != null) {
                setState(() {
                  validationError = validationMessage;
                  testStatusMessage = '';
                  testStatusIsError = false;
                });
                return;
              }
              final config = buildBackupDestinationConfig(
                destinationType: selectedType,
                s3Prefix: s3PrefixController.text,
                s3AccessKeyId: s3AccessKeyController.text,
                s3SecretAccessKey: s3SecretController.text,
                s3Region: s3RegionController.text,
                s3Endpoint: s3EndpointController.text,
                forcePathStyle: forcePathStyle,
                filePrefix: filePrefixController.text,
              );
              Navigator.of(context).pop(
                _BackupDestinationDraft(
                  id: initial?.id,
                  name: name,
                  type: selectedType,
                  config: config,
                ),
              );
            }

            return AppFormDialog(
              key: const Key('backup-destination-dialog'),
              title: backupDestinationDialogTitle(isEditing: initial != null),
              description:
                  'Choose where Deploy Dash should store backups for this project.',
              maxWidth: 480,
              actions: [
                if (selectedType == BackupDestinationType.s3)
                  TextButton(
                    key: const Key('backup-destination-test-button'),
                    onPressed: isTesting ? null : testConnection,
                    child: isTesting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Test connection'),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('backup-destination-save-button'),
                  onPressed: isTesting ? null : submit,
                  child: Text(initial == null ? 'Add destination' : 'Save'),
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppTextFormField(
                    key: const Key('backup-destination-name-field'),
                    controller: nameController,
                    labelText: 'Name',
                    onChanged: (_) => clearValidationMessages(),
                  ),
                  const SizedBox(height: 12),
                  AppSelectFormField<BackupDestinationType>(
                    key: const Key('backup-destination-type-field'),
                    value: selectedType,
                    labelText: 'Destination type',
                    items: const [
                      DropdownMenuItem(
                        value: BackupDestinationType.s3,
                        child: Text('S3'),
                      ),
                      DropdownMenuItem(
                        value: BackupDestinationType.filesystem,
                        child: Text('Local filesystem'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        selectedType = value;
                        validationError = '';
                        testStatusMessage = '';
                        testStatusIsError = false;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  if (selectedType == BackupDestinationType.s3) ...[
                    AppTextFormField(
                      key: const Key('backup-destination-bucket-field'),
                      controller: s3PrefixController,
                      labelText: 'Bucket name',
                      helperText:
                          'Deploy Dash manages the object path automatically.',
                      onChanged: (_) => clearValidationMessages(),
                    ),
                    const SizedBox(height: 12),
                    AppTextFormField(
                      key: const Key('backup-destination-access-key-field'),
                      controller: s3AccessKeyController,
                      labelText: 'Access key ID',
                      onChanged: (_) => clearValidationMessages(),
                    ),
                    const SizedBox(height: 12),
                    AppPasswordFormField(
                      key: const Key('backup-destination-secret-key-field'),
                      controller: s3SecretController,
                      labelText: 'Secret access key',
                      onChanged: (_) => clearValidationMessages(),
                    ),
                    const SizedBox(height: 12),
                    AppTextFormField(
                      key: const Key('backup-destination-region-field'),
                      controller: s3RegionController,
                      labelText: 'Region',
                      onChanged: (_) => clearValidationMessages(),
                    ),
                    const SizedBox(height: 12),
                    AppTextFormField(
                      key: const Key('backup-destination-endpoint-field'),
                      controller: s3EndpointController,
                      labelText: 'Endpoint host (optional)',
                      hintText: 's3.example.com',
                      helperText:
                          'Enter the host only. Deploy Dash adds https:// automatically.',
                      onChanged: (_) => clearValidationMessages(),
                    ),
                    const SizedBox(height: 12),
                    AppToggleField(
                      key: const Key('backup-destination-path-style-toggle'),
                      value: forcePathStyle,
                      onChanged: (value) {
                        setState(() {
                          forcePathStyle = value;
                          validationError = '';
                          testStatusMessage = '';
                          testStatusIsError = false;
                        });
                      },
                      title: 'Force path style',
                    ),
                  ] else ...[
                    AppTextFormField(
                      key: const Key('backup-destination-file-path-field'),
                      controller: filePrefixController,
                      labelText: 'Filesystem path',
                      onChanged: (_) => clearValidationMessages(),
                    ),
                  ],
                  if (validationError.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      key: const Key('backup-destination-validation-error'),
                      validationError,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (testStatusMessage.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      key: const Key('backup-destination-test-status'),
                      testStatusMessage,
                      style: TextStyle(
                        color: testStatusIsError
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  // end coverage-gate
  Future<_BackupPolicyDraft?> _showPolicyDialog({
    required List<BackupDestinationRecord> destinations,
    _BackupPolicyDraft? initial,
  }) async {
    final availableDestinations = _eligibleDestinationsForActiveEngine(
      destinations,
    );
    if (availableDestinations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Create a backup destination first.')),
      );
      return null;
    }

    return showDialog<_BackupPolicyDraft>(
      context: context,
      builder: (context) {
        final nameController = TextEditingController(text: initial?.name ?? '');
        final databaseController = TextEditingController(
          text: initial?.databaseName ?? '',
        );
        final retentionController = TextEditingController(
          text: (initial?.retentionKeepLast ?? 7).toString(),
        );
        final time1Controller = TextEditingController(
          text: initial?.time1Hhmm ?? '02:00',
        );
        final time2Controller = TextEditingController(
          text: initial?.time2Hhmm ?? '14:00',
        );
        var destinationId =
            initial?.destinationId ?? availableDestinations.first.id;
        final initialDestinationAllowed = availableDestinations.any(
          (item) => item.id == destinationId,
        );
        if (!initialDestinationAllowed) {
          destinationId = availableDestinations.first.id;
        }
        var scheduleMode = initial?.scheduleMode ?? 'daily_once';
        var enabled = initial?.enabled ?? true;
        var validationError = '';

        return StatefulBuilder(
          builder: (context, setState) {
            Future<void> submit() async {
              final policyName = nameController.text.trim();
              final databaseName = databaseController.text.trim();
              final validationMessage = validateBackupPolicyInput(
                policyName: policyName,
                databaseName: databaseName,
                scheduleMode: scheduleMode,
                time1: time1Controller.text,
                time2: time2Controller.text,
                retentionText: retentionController.text,
              );
              if (validationMessage != null) {
                setState(() {
                  validationError = validationMessage;
                });
                return;
              }
              final retention = int.parse(retentionController.text.trim());

              Navigator.of(context).pop(
                _BackupPolicyDraft(
                  id: initial?.id,
                  name: policyName,
                  destinationId: destinationId,
                  databaseName: databaseName,
                  scheduleMode: scheduleMode,
                  time1Hhmm: time1Controller.text.trim(),
                  time2Hhmm: scheduleMode == 'daily_twice'
                      ? time2Controller.text.trim()
                      : null,
                  retentionKeepLast: retention,
                  enabled: enabled,
                  managedTaskId: initial?.managedTaskId,
                ),
              );
            }

            return AppFormDialog(
              key: const Key('backup-policy-dialog'),
              title: backupPolicyDialogTitle(isEditing: initial != null),
              description:
                  'Choose what to back up, where it goes, and how often it should run.',
              maxWidth: 520,
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('backup-policy-save-button'),
                  onPressed: submit,
                  child: Text(initial == null ? 'Add plan' : 'Save'),
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppTextFormField(
                    key: const Key('backup-policy-name-field'),
                    controller: nameController,
                    labelText: 'Plan name',
                  ),
                  const SizedBox(height: 12),
                  AppSelectFormField<String>(
                    key: const Key('backup-policy-destination-field'),
                    value: destinationId,
                    labelText: 'Destination',
                    items: availableDestinations
                        .map(
                          (item) => DropdownMenuItem<String>(
                            value: item.id,
                            child: Text(item.name),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        destinationId = value;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  if (_projectDatabases.isNotEmpty)
                    AppSelectFormField<String>(
                      key: const Key('backup-policy-database-select'),
                      value:
                          _projectDatabases.contains(
                            databaseController.text.trim(),
                          )
                          ? databaseController.text.trim()
                          : null,
                      labelText: 'Database',
                      items: _projectDatabases
                          .map(
                            (item) => DropdownMenuItem<String>(
                              value: item,
                              child: Text(item),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() {
                          databaseController.text = value;
                        });
                      },
                    ),
                  if (_projectDatabases.isEmpty)
                    AppTextFormField(
                      key: const Key('backup-policy-database-field'),
                      controller: databaseController,
                      labelText: 'Database name',
                    ),
                  if (_projectDatabases.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    AppTextFormField(
                      key: const Key('backup-policy-database-manual-field'),
                      controller: databaseController,
                      labelText: 'Or enter a database name manually',
                    ),
                  ],
                  const SizedBox(height: 12),
                  AppSelectFormField<String>(
                    key: const Key('backup-policy-schedule-field'),
                    value: scheduleMode,
                    labelText: 'Schedule',
                    items: const [
                      DropdownMenuItem(
                        value: 'daily_once',
                        child: Text('Once daily'),
                      ),
                      DropdownMenuItem(
                        value: 'daily_twice',
                        child: Text('Twice daily'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        scheduleMode = value;
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  AppTextFormField(
                    key: const Key('backup-policy-time-one-field'),
                    controller: time1Controller,
                    labelText: 'Time #1 (HH:MM)',
                  ),
                  if (scheduleMode == 'daily_twice')
                    AppTextFormField(
                      key: const Key('backup-policy-time-two-field'),
                      controller: time2Controller,
                      labelText: 'Time #2 (HH:MM)',
                    ),
                  AppNumberFormField(
                    key: const Key('backup-policy-retention-field'),
                    controller: retentionController,
                    labelText: 'Keep the last N backups',
                  ),
                  AppToggleField(
                    key: const Key('backup-policy-enabled-toggle'),
                    value: enabled,
                    onChanged: (value) {
                      setState(() {
                        enabled = value;
                      });
                    },
                    title: 'Run this plan automatically',
                  ),
                  if (validationError.isNotEmpty)
                    Text(
                      key: const Key('backup-policy-validation-error'),
                      validationError,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<bool> _showBacklogCleanupDialog({
    required Map<String, dynamic> report,
    required BackupPolicyRecord policy,
  }) async {
    final count = (report['beyond_retention_count'] as num?)?.toInt() ?? 0;
    final bytes = (report['beyond_retention_bytes'] as num?)?.toInt() ?? 0;
    final unknownSizeCount =
        (report['beyond_retention_unknown_size_count'] as num?)?.toInt() ?? 0;
    final keepLast =
        (report['retention_keep_last'] as num?)?.toInt() ??
        policy.retentionKeepLast;
    return await showDialog<bool>(
          context: context,
          builder: (context) {
            return AppFormDialog(
              key: const Key('backup-backlog-cleanup-dialog'),
              title: 'Clean up old backups',
              description:
                  'Delete the backups this plan no longer needs to keep. '
                  'This cannot be undone.',
              maxWidth: 460,
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('backup-backlog-cleanup-confirm-button'),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Delete backups'),
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    backupBacklogReportMessage(
                      count: count,
                      bytes: bytes,
                      unknownSizeCount: unknownSizeCount,
                      keepLast: keepLast,
                    ),
                  ),
                ],
              ),
            );
          },
        ) ??
        false;
  }

  Future<_BackupRestoreDraft?> _showRestoreDialog({
    required BackupArtifactRecord artifact,
  }) async {
    return showDialog<_BackupRestoreDraft>(
      context: context,
      builder: (context) {
        final targetController = TextEditingController();
        var validationError = '';

        return StatefulBuilder(
          builder: (context, setState) {
            return AppFormDialog(
              key: const Key('backup-restore-dialog'),
              title: 'Restore backup',
              description:
                  'Choose a new database name. Deploy Dash restores this backup into a new database instead of overwriting an existing one.',
              maxWidth: 460,
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('backup-restore-confirm-button'),
                  onPressed: () {
                    final target = targetController.text.trim();
                    if (target.isEmpty) {
                      setState(() {
                        validationError = 'Target database is required.';
                      });
                      return;
                    }
                    Navigator.of(
                      context,
                    ).pop(_BackupRestoreDraft(targetDatabaseName: target));
                  },
                  child: const Text('Restore'),
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Backup file: ${artifact.remotePath}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  AppTextFormField(
                    key: const Key('backup-restore-database-field'),
                    controller: targetController,
                    labelText: 'New database name',
                    onChanged: (_) => setState(() {
                      validationError = '';
                    }),
                  ),
                  if (validationError.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      validationError,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}
