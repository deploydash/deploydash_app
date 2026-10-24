part of '../../project_workspace.dart';

List<AppDeploymentEnvEditorDialogRow> normalizeAppDeploymentEnvRows(
  List<AppDeploymentEnvEditorDialogRow> rows,
) {
  // A map literal keeps a key at its first insertion position when the value
  // is later replaced, so iteration order is first-appearance order: a
  // duplicated key keeps its original slot and takes the last value.
  final normalized = <String, AppDeploymentEnvEditorDialogRow>{};
  for (final row in rows) {
    final key = row.key.trim();
    if (key.isEmpty) {
      continue;
    }
    normalized[key] = AppDeploymentEnvEditorDialogRow(
      key: key,
      value: row.value,
      secret: row.secret,
      changedSinceLastDeploy: row.changedSinceLastDeploy,
    );
  }
  return normalized.values.toList(growable: false);
}

String _normalizeBulkImportedEnvValue(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2) {
    final first = trimmed[0];
    final last = trimmed[trimmed.length - 1];
    final isMatchingQuote =
        (first == '"' && last == '"') || (first == '\'' && last == '\'');
    if (isMatchingQuote) {
      return trimmed.substring(1, trimmed.length - 1);
    }
  }
  return trimmed;
}

List<AppDeploymentEnvEditorDialogRow> parseBulkAppDeploymentEnvRows(
  String input,
) {
  final parsed = <AppDeploymentEnvEditorDialogRow>[];
  for (final rawLine in input.split(RegExp(r'\r?\n'))) {
    final trimmedLine = rawLine.trim();
    if (trimmedLine.isEmpty || trimmedLine.startsWith('#')) {
      continue;
    }
    final line = trimmedLine.startsWith('export ')
        ? trimmedLine.substring(7).trimLeft()
        : trimmedLine;
    final separator = line.indexOf('=');
    if (separator <= 0) {
      continue;
    }
    final key = line.substring(0, separator).trim();
    if (key.isEmpty) {
      continue;
    }
    final value = _normalizeBulkImportedEnvValue(line.substring(separator + 1));
    parsed.add(
      AppDeploymentEnvEditorDialogRow(
        key: key,
        value: value,
        changedSinceLastDeploy: true,
      ),
    );
  }
  return normalizeAppDeploymentEnvRows(parsed);
}

class AppDeploymentEnvEditorDialogRow {
  const AppDeploymentEnvEditorDialogRow({
    required this.key,
    required this.value,
    this.secret = false,
    this.changedSinceLastDeploy = false,
  });

  final String key;
  final String value;
  final bool secret;
  final bool changedSinceLastDeploy;

  AppDeploymentEnvEditorDialogRow copyWith({
    String? key,
    String? value,
    bool? secret,
    bool? changedSinceLastDeploy,
  }) {
    return AppDeploymentEnvEditorDialogRow(
      key: key ?? this.key,
      value: value ?? this.value,
      secret: secret ?? this.secret,
      changedSinceLastDeploy:
          changedSinceLastDeploy ?? this.changedSinceLastDeploy,
    );
  }
}

class AppDeploymentEnvEditorDialogResult {
  const AppDeploymentEnvEditorDialogResult({
    required this.rows,
    required this.redeployRequested,
  });

  final List<AppDeploymentEnvEditorDialogRow> rows;
  final bool redeployRequested;
}

class AppDeploymentEnvEditorDialog extends StatefulWidget {
  const AppDeploymentEnvEditorDialog({
    super.key,
    required this.initialRows,
    required this.lastDeployedSnapshot,
    required this.canSaveAndRedeploy,
  });

  final List<AppDeploymentEnvEditorDialogRow> initialRows;
  final Map<String, String> lastDeployedSnapshot;
  final bool canSaveAndRedeploy;

  @override
  State<AppDeploymentEnvEditorDialog> createState() =>
      _AppDeploymentEnvEditorDialogState();
}

class _AppDeploymentEnvEditorDialogState
    extends State<AppDeploymentEnvEditorDialog> {
  late final TextEditingController _searchController = TextEditingController();
  late final TextEditingController _newKeyController = TextEditingController();
  late final TextEditingController _newValueController =
      TextEditingController();
  late final List<AppDeploymentEnvEditorDialogRow> _draftRows =
      List<AppDeploymentEnvEditorDialogRow>.from(widget.initialRows);

  bool _newSecret = false;

  @override
  void initState() {
    super.initState();
    _recomputeDraftChanges();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _newKeyController.dispose();
    _newValueController.dispose();
    super.dispose();
  }

  void _recomputeDraftChanges() {
    for (int index = 0; index < _draftRows.length; index += 1) {
      final row = _draftRows[index];
      final key = row.key.trim();
      final previous = key.isEmpty ? null : widget.lastDeployedSnapshot[key];
      _draftRows[index] = row.copyWith(
        changedSinceLastDeploy: key.isNotEmpty && previous != row.value.trim(),
      );
    }
  }

  List<int> _filteredIndexes() {
    final search = _searchController.text.trim().toLowerCase();
    final indexes = <int>[];
    for (int index = 0; index < _draftRows.length; index += 1) {
      final key = _draftRows[index].key.toLowerCase();
      if (search.isEmpty || key.contains(search)) {
        indexes.add(index);
      }
    }
    return indexes;
  }

  void _closeWithResult(bool redeployRequested) {
    Navigator.of(context).pop(
      AppDeploymentEnvEditorDialogResult(
        rows: normalizeAppDeploymentEnvRows(_draftRows),
        redeployRequested: redeployRequested,
      ),
    );
  }

  Future<void> _showBulkImportDialog() async {
    final importedRows =
        await showDialog<List<AppDeploymentEnvEditorDialogRow>>(
          context: context,
          builder: (_) => const _BulkEnvImportDialog(),
        );
    if (importedRows == null || importedRows.isEmpty) {
      return;
    }
    final blankDraftRows = _draftRows
        .where((row) => row.key.trim().isEmpty)
        .toList(growable: false);
    final existingRows = normalizeAppDeploymentEnvRows(
      _draftRows.where((row) => row.key.trim().isNotEmpty).toList(),
    );
    _draftRows
      ..clear()
      ..addAll(blankDraftRows)
      ..addAll(
        normalizeAppDeploymentEnvRows([...existingRows, ...importedRows]),
      );
    _recomputeDraftChanges();
    setState(() {});
  }

  _EnvVarRowState _toPrivateRow(AppDeploymentEnvEditorDialogRow row) {
    return _EnvVarRowState(
      key: row.key,
      value: row.value,
      secret: row.secret,
      changedSinceLastDeploy: row.changedSinceLastDeploy,
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredIndexes = _filteredIndexes();

    return AppFormDialog(
      title: deploymentEnvEditorTitle(),
      description: deploymentEnvEditorSubtitle(),
      maxWidth: 760,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        OutlinedButton.icon(
          key: const Key('env-save-button'),
          onPressed: () => _closeWithResult(false),
          icon: const Icon(Icons.save),
          label: const Text('Save'),
        ),
        FilledButton.icon(
          key: const Key('env-save-redeploy-button'),
          onPressed: widget.canSaveAndRedeploy
              ? () => _closeWithResult(true)
              : null,
          icon: const Icon(Icons.rocket_launch),
          label: const Text('Save and redeploy'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppFormSection(
            title: 'Current variables',
            description:
                'Search, update, or remove the values your app uses at runtime.',
            children: [
              AppTextFormField(
                key: const Key('env-search-field'),
                controller: _searchController,
                labelText: 'Search variables',
                hintText: 'Find a variable by name',
                onChanged: (_) => setState(() {}),
              ),
              if (filteredIndexes.isEmpty)
                Text(
                  'No variables match this search yet.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else
                Column(
                  children: [
                    for (final index in filteredIndexes)
                      _EnvVarEditorRow(
                        key: ValueKey('env-row-$index'),
                        row: _toPrivateRow(_draftRows[index]),
                        onKeyChanged: (value) {
                          _draftRows[index] = _draftRows[index].copyWith(
                            key: value,
                          );
                          _recomputeDraftChanges();
                          setState(() {});
                        },
                        onValueChanged: (value) {
                          _draftRows[index] = _draftRows[index].copyWith(
                            value: value,
                          );
                          _recomputeDraftChanges();
                          setState(() {});
                        },
                        onSecretChanged: (secret) {
                          _draftRows[index] = _draftRows[index].copyWith(
                            secret: secret,
                          );
                          setState(() {});
                        },
                        onDelete: () {
                          _draftRows.removeAt(index);
                          _recomputeDraftChanges();
                          setState(() {});
                        },
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 16),
          AppFormSection(
            title: 'Add a variable',
            description: 'Use this for one new value, or import many at once.',
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 210,
                    child: AppTextFormField(
                      key: const Key('env-new-key-field'),
                      controller: _newKeyController,
                      labelText: 'Variable name',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AppTextFormField(
                      key: const Key('env-new-value-field'),
                      controller: _newValueController,
                      labelText: 'Value',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Secret'),
                      const SizedBox(width: 4),
                      Switch(
                        key: const Key('env-new-secret-switch'),
                        value: _newSecret,
                        onChanged: (value) {
                          setState(() {
                            _newSecret = value;
                          });
                        },
                      ),
                    ],
                  ),
                  IconButton(
                    key: const Key('env-add-row-button'),
                    tooltip: 'Add variable',
                    onPressed: () {
                      final key = _newKeyController.text.trim();
                      if (key.isEmpty) {
                        return;
                      }
                      _draftRows.add(
                        AppDeploymentEnvEditorDialogRow(
                          key: key,
                          value: _newValueController.text,
                          secret: _newSecret,
                          changedSinceLastDeploy: true,
                        ),
                      );
                      _newKeyController.clear();
                      _newValueController.clear();
                      _newSecret = false;
                      _recomputeDraftChanges();
                      setState(() {});
                    },
                    icon: const Icon(Icons.add, semanticLabel: 'Add variable'),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('env-bulk-add-button'),
                  onPressed: _showBulkImportDialog,
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Import in bulk'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BulkEnvImportDialog extends StatefulWidget {
  const _BulkEnvImportDialog();

  @override
  State<_BulkEnvImportDialog> createState() => _BulkEnvImportDialogState();
}

class _BulkEnvImportDialogState extends State<_BulkEnvImportDialog> {
  late final TextEditingController _controller = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply() {
    final parsed = parseBulkAppDeploymentEnvRows(_controller.text);
    if (parsed.isEmpty) {
      setState(() {
        _errorText = 'Paste at least one valid KEY=value line.';
      });
      return;
    }
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AppFormDialog(
      title: deploymentEnvBulkImportTitle(),
      description: deploymentEnvBulkImportSubtitle(),
      maxWidth: 720,
      actions: [
        TextButton(
          key: const Key('env-bulk-import-cancel-button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('env-bulk-import-apply-button'),
          onPressed: _apply,
          icon: const Icon(Icons.playlist_add_check),
          label: const Text('Import rows'),
        ),
      ],
      child: AppFormSection(
        title: 'Variable lines',
        description:
            'Blank lines and lines starting with # are ignored. Imported values start as non-sensitive unless you change them later.',
        children: [
          TextFormField(
            key: const Key('env-bulk-import-field'),
            controller: _controller,
            maxLines: 14,
            minLines: 10,
            decoration: InputDecoration(
              hintText:
                  'APP_NAME=Laravel\nAPP_ENV=production\nAPP_KEY=base64:...',
              errorText: _errorText,
            ),
          ),
        ],
      ),
    );
  }
}
