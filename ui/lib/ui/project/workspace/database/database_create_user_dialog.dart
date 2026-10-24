part of '../../project_workspace.dart';

extension _DatabaseCreateUserDialog on _DatabaseTabViewState {
  Future<void> _showConnectExistingDialog({
    required Server server,
    required Project project,
  }) async {
    final existingDatabases = _databases.toList(growable: false);
    final usernameController = TextEditingController();
    var selectedDatabase =
        _selectedDatabase != null &&
            existingDatabases.contains(_selectedDatabase)
        ? _selectedDatabase
        : (existingDatabases.isNotEmpty ? existingDatabases.first : null);
    var accessMode = 'read_write';
    final formKey = GlobalKey<FormState>();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AppFormDialog(
              key: const Key('database-create-user-dialog'),
              title: 'Create user for existing database',
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('database-create-user-confirm-button'),
                  onPressed: () async {
                    if (existingDatabases.isEmpty) {
                      Navigator.of(dialogContext).pop();
                      return;
                    }
                    if (!(formKey.currentState?.validate() ?? false)) {
                      return;
                    }
                    final username = usernameController.text.trim();
                    final databaseName = selectedDatabase;
                    if (databaseName == null) {
                      return;
                    }
                    Navigator.of(dialogContext).pop();
                    await _runDatabaseMutation(
                      engine: _selectedEngine,
                      server: server,
                      project: project,
                      operationId: 'project_create_user',
                      busyAction: 'connect_existing',
                      settingsOverrides: <String, dynamic>{
                        'database_name': logicalManagedPostgresName(
                          projectName: project.name,
                          remoteName: databaseName,
                        ),
                        'username': username,
                        'access_mode': accessMode,
                      },
                      defaultSuccessMessage:
                          'Database user created for $databaseName.',
                      showCredentials: true,
                    );
                  },
                  child: const Text('Create user'),
                ),
              ],
              child: existingDatabases.isEmpty
                  ? const AppEmptyStateView(
                      key: Key('database-connect-existing-empty-state'),
                      icon: Icons.storage_outlined,
                      title: 'No existing project databases found',
                      message: 'Create one first.',
                    )
                  : Form(
                      key: formKey,
                      child: AppFormSection(
                        children: [
                          AppSelectFormField<String>(
                            key: const Key(
                              'database-connect-existing-dropdown',
                            ),
                            labelText: 'Database',
                            value: selectedDatabase,
                            items: existingDatabases
                                .map(
                                  (databaseName) => DropdownMenuItem<String>(
                                    value: databaseName,
                                    child: Text(databaseName),
                                  ),
                                )
                                .toList(growable: false),
                            onChanged: (value) {
                              setDialogState(() {
                                selectedDatabase = value;
                              });
                            },
                          ),
                          AppTextFormField(
                            key: const Key(
                              'database-connect-existing-username-field',
                            ),
                            controller: usernameController,
                            labelText: 'Username',
                            hintText: 'reader_user',
                            validator: (value) => _validatePostgresIdentifier(
                              value ?? '',
                              fieldLabel: 'Username',
                              requiredField: true,
                              identifierPattern: _postgresIdentifierPattern,
                              patternHelp:
                                  'must start with a letter and use lowercase letters, numbers, or underscores.',
                            ),
                          ),
                          AppSelectFormField<String>(
                            labelText: 'User permission',
                            value: accessMode,
                            items: const [
                              DropdownMenuItem(
                                value: 'read_write',
                                child: Text('Can read data and manage tables'),
                              ),
                              DropdownMenuItem(
                                value: 'read_only',
                                child: Text('Can read data only'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value == null) {
                                return;
                              }
                              setDialogState(() => accessMode = value);
                            },
                          ),
                          Text(
                            _postgresPermissionHelpText(accessMode),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
            );
          },
        );
      },
    );
  }
}
