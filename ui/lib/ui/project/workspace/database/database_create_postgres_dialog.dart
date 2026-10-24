part of '../../project_workspace.dart';

extension _DatabaseCreatePostgresDialog on _DatabaseTabViewState {
  Future<void> _showCreateDatabaseDialog({
    required Server server,
    required Project project,
  }) async {
    final databaseController = TextEditingController();
    var accessMode = 'read_write';
    final formKey = GlobalKey<FormState>();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AppFormDialog(
              key: const Key('database-create-dialog'),
              title: 'Create database',
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('database-create-confirm-button'),
                  onPressed: () async {
                    if (!(formKey.currentState?.validate() ?? false)) {
                      return;
                    }
                    final databaseName = databaseController.text.trim();
                    Navigator.of(dialogContext).pop();
                    await _runDatabaseMutation(
                      engine: _selectedEngine,
                      server: server,
                      project: project,
                      operationId: 'project_create_database',
                      busyAction: 'create_database',
                      settingsOverrides: <String, dynamic>{
                        'database_name': databaseName,
                        'access_mode': accessMode,
                      },
                      defaultSuccessMessage: 'Database created.',
                      showCredentials: true,
                    );
                  },
                  child: const Text('Create'),
                ),
              ],
              child: Form(
                key: formKey,
                child: AppFormSection(
                  children: [
                    AppTextFormField(
                      key: const Key('database-create-name-field'),
                      controller: databaseController,
                      labelText: 'Database name',
                      hintText: 'app_data',
                      validator: (value) =>
                          _validatePostgresDatabaseName(value ?? ''),
                      inputFormatters: [
                        TextInputFormatter.withFunction((oldValue, newValue) {
                          final sanitized = newValue.text
                              .toLowerCase()
                              .replaceAll(RegExp(r'[^a-z0-9_]'), '');
                          return TextEditingValue(
                            text: sanitized,
                            selection: TextSelection.collapsed(
                              offset: sanitized.length,
                            ),
                          );
                        }),
                      ],
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
