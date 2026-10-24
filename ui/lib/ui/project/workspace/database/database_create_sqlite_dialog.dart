part of '../../project_workspace.dart';

extension _DatabaseCreateSqliteDialog on _DatabaseTabViewState {
  // coverage-gate: create_sqlite_database_dialog
  Future<void> _showCreateSqliteDatabaseDialog({
    required Server server,
    required Project project,
    required List<ProjectSqliteDatabase> existingDatabases,
  }) async {
    final nameController = TextEditingController(
      text: existingDatabases.isEmpty ? 'primary' : '',
    );
    var makePrimary = existingDatabases.isEmpty;
    final formKey = GlobalKey<FormState>();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AppFormDialog(
              title: 'Create SQLite database',
              maxWidth: 520,
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    if (!(formKey.currentState?.validate() ?? false)) {
                      return;
                    }
                    final name = nameController.text.trim();
                    final volumeName = _defaultSqliteVolumeName(
                      project: project,
                      sqliteName: name,
                    );
                    final fileName = this._defaultSqliteFileName(name);

                    final sqliteDatabase = ProjectSqliteDatabase(
                      id: 'sqlite-${DateTime.now().microsecondsSinceEpoch}',
                      projectId: project.id,
                      name: name,
                      volumeName: volumeName,
                      mountPath: _DatabaseTabViewState._sqliteDefaultMountPath,
                      fileName: fileName,
                      isPrimary: makePrimary,
                    );

                    Navigator.of(dialogContext).pop();
                    _applyState(() {
                      _sqliteBusyAction = 'create';
                      _sqliteBusyDatabaseId = sqliteDatabase.id;
                      _sqliteError = null;
                    });
                    try {
                      await ref
                          .read(projectSqliteDatabasesProvider.notifier)
                          .upsert(sqliteDatabase);
                      await _ensureSqliteVolume(
                        server: server,
                        project: project,
                        sqliteDatabase: sqliteDatabase,
                      );
                    } catch (error) {
                      if (!mounted) {
                        return;
                      }
                      _applyState(() {
                        _sqliteError =
                            'Could not create SQLite database: $error';
                        _sqliteBusyAction = null;
                        _sqliteBusyDatabaseId = null;
                      });
                    }
                  },
                  child: const Text('Create'),
                ),
              ],
              child: Form(
                key: formKey,
                child: AppFormSection(
                  children: [
                    AppTextFormField(
                      key: const Key('database-sqlite-name-field'),
                      controller: nameController,
                      labelText: 'Name',
                      hintText: 'primary',
                      validator: (value) {
                        final nextNameError = _validateSqliteConfigName(
                          value ?? '',
                        );
                        if (nextNameError != null) {
                          return nextNameError;
                        }
                        final normalized = (value ?? '').trim().toLowerCase();
                        if (existingDatabases.any(
                          (row) => row.name.trim().toLowerCase() == normalized,
                        )) {
                          return 'A SQLite config with this name already exists.';
                        }
                        return null;
                      },
                    ),
                    SwitchListTile.adaptive(
                      key: const Key('database-sqlite-primary-toggle'),
                      contentPadding: EdgeInsets.zero,
                      value: makePrimary,
                      onChanged: (value) {
                        setDialogState(() {
                          makePrimary = value;
                        });
                      },
                      title: const Text('Set as primary SQLite database'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameController.dispose();
    });
  }

  // end coverage-gate
}
