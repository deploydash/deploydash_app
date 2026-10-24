part of '../../project_workspace.dart';

// coverage-gate: app_deployment_models

class _EnvVarReadOnlyKeyToken extends StatelessWidget {
  const _EnvVarReadOnlyKeyToken({required this.row});

  final _EnvVarRowState row;

  @override
  Widget build(BuildContext context) {
    final borderColor = Theme.of(
      context,
    ).colorScheme.outlineVariant.withValues(alpha: 0.75);
    final backgroundColor = Theme.of(
      context,
    ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35);
    return Container(
      constraints: const BoxConstraints(minHeight: 32, maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        row.key,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _EnvVarEditorRow extends StatefulWidget {
  const _EnvVarEditorRow({
    super.key,
    required this.row,
    required this.onKeyChanged,
    required this.onValueChanged,
    required this.onSecretChanged,
    required this.onDelete,
  });

  final _EnvVarRowState row;
  final ValueChanged<String> onKeyChanged;
  final ValueChanged<String> onValueChanged;
  final ValueChanged<bool> onSecretChanged;
  final VoidCallback onDelete;

  @override
  State<_EnvVarEditorRow> createState() => _EnvVarEditorRowState();
}

class _EnvVarEditorRowState extends State<_EnvVarEditorRow> {
  bool _showSecret = false;
  late final TextEditingController _keyController;
  late final TextEditingController _valueController;

  @override
  void initState() {
    super.initState();
    _keyController = TextEditingController(text: widget.row.key);
    _valueController = TextEditingController(text: widget.row.value);
  }

  @override
  void didUpdateWidget(covariant _EnvVarEditorRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.row.key != _keyController.text) {
      _keyController.text = widget.row.key;
    }
    if (widget.row.value != _valueController.text) {
      _valueController.text = widget.row.value;
    }
  }

  @override
  void dispose() {
    _keyController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 190,
            child: TextFormField(
              controller: _keyController,
              onChanged: widget.onKeyChanged,
              decoration: InputDecoration(
                labelText: 'Key',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextFormField(
              controller: _valueController,
              onChanged: widget.onValueChanged,
              obscureText: widget.row.secret && !_showSecret,
              decoration: InputDecoration(
                labelText: 'Value',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                suffixIcon: widget.row.secret
                    ? IconButton(
                        onPressed: () {
                          setState(() {
                            _showSecret = !_showSecret;
                          });
                        },
                        icon: Icon(
                          _showSecret ? Icons.visibility_off : Icons.visibility,
                        ),
                      )
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Secret'),
              const SizedBox(width: 4),
              Switch(
                value: widget.row.secret,
                onChanged: widget.onSecretChanged,
              ),
            ],
          ),
          IconButton(
            onPressed: widget.onDelete,
            icon: const Icon(
              Icons.delete_outline,
              semanticLabel: 'Remove env key',
            ),
            tooltip: 'Remove env key',
          ),
        ],
      ),
    );
  }
}

class _EnvVarRowState {
  const _EnvVarRowState({
    required this.key,
    required this.value,
    this.secret = false,
    this.changedSinceLastDeploy = false,
  });

  final String key;
  final String value;
  final bool secret;
  final bool changedSinceLastDeploy;

  _EnvVarRowState copyWith({
    String? key,
    String? value,
    bool? secret,
    required bool changedSinceLastDeploy,
  }) {
    return _EnvVarRowState(
      key: key ?? this.key,
      value: value ?? this.value,
      secret: secret ?? this.secret,
      changedSinceLastDeploy: changedSinceLastDeploy,
    );
  }
}

class _ResourceUsageSnapshot {
  const _ResourceUsageSnapshot({
    required this.containerId,
    required this.name,
    required this.cpuPerc,
    required this.memUsage,
    required this.memPerc,
    required this.netIo,
    required this.blockIo,
    required this.pids,
    required this.collectedAt,
  });

  final String containerId;
  final String name;
  final String cpuPerc;
  final String memUsage;
  final String memPerc;
  final String netIo;
  final String blockIo;
  final String pids;
  final DateTime collectedAt;

  static _ResourceUsageSnapshot? fromPayload(Map<String, dynamic> payload) {
    final collectedAtRaw = payload['collected_at']?.toString();
    final collectedAt = collectedAtRaw == null
        ? null
        : DateTime.tryParse(collectedAtRaw);

    final name = payload['Name']?.toString().trim();
    if (name == null || name.isEmpty) {
      return null;
    }

    return _ResourceUsageSnapshot(
      containerId: payload['Container']?.toString() ?? '-',
      name: name,
      cpuPerc: payload['CPUPerc']?.toString() ?? '-',
      memUsage: payload['MemUsage']?.toString() ?? '-',
      memPerc: payload['MemPerc']?.toString() ?? '-',
      netIo: payload['NetIO']?.toString() ?? '-',
      blockIo: payload['BlockIO']?.toString() ?? '-',
      pids: payload['PIDs']?.toString() ?? '-',
      collectedAt: collectedAt ?? DateTime.now(),
    );
  }
}

class _SqliteStorageSnapshot {
  const _SqliteStorageSnapshot({
    required this.enabled,
    required this.volumeName,
    required this.mountPath,
    required this.fileName,
    required this.databasePath,
    required this.databaseUrl,
    this.volumeExists,
    this.volumeMountpoint,
    this.volumeSizeBytes,
    this.checkedAt,
  });

  final bool enabled;
  final String volumeName;
  final String mountPath;
  final String fileName;
  final String databasePath;
  final String databaseUrl;
  final bool? volumeExists;
  final String? volumeMountpoint;
  final int? volumeSizeBytes;
  final DateTime? checkedAt;

  static _SqliteStorageSnapshot? fromProject(Project project) {
    if (!project.sqliteStorageEnabled) {
      return null;
    }
    final volumeName =
        trimOrNull(project.sqliteVolumeName) ??
        'deploydash_sqlite_${slugifyProjectName(project.name, fallback: 'project-app')}';
    final mountPath =
        trimOrNull(project.sqliteMountPath) ?? '/var/lib/deploydash/sqlite';
    final fileName = trimOrNull(project.sqliteFileName) ?? 'app.sqlite3';
    final databasePath = '$mountPath/$fileName';
    return _SqliteStorageSnapshot(
      enabled: true,
      volumeName: volumeName,
      mountPath: mountPath,
      fileName: fileName,
      databasePath: databasePath,
      databaseUrl: 'sqlite:///$databasePath',
    );
  }

  static _SqliteStorageSnapshot? fromPayload(Map<String, dynamic> payload) {
    final enabled = payload['enabled'] == true;
    if (!enabled) {
      return null;
    }
    final volumeName = payload['volume_name']?.toString().trim();
    final mountPath = payload['mount_path']?.toString().trim();
    final fileName = payload['file_name']?.toString().trim();
    final databasePath = payload['database_path']?.toString().trim();
    final databaseUrl = payload['database_url']?.toString().trim();
    if (volumeName == null ||
        volumeName.isEmpty ||
        mountPath == null ||
        mountPath.isEmpty ||
        fileName == null ||
        fileName.isEmpty ||
        databasePath == null ||
        databasePath.isEmpty ||
        databaseUrl == null ||
        databaseUrl.isEmpty) {
      return null;
    }

    final checkedAtRaw = payload['checked_at']?.toString();
    final checkedAt = checkedAtRaw == null
        ? null
        : DateTime.tryParse(checkedAtRaw);

    int? volumeSizeBytes;
    final rawVolumeSize = payload['volume_size_bytes'];
    if (rawVolumeSize is int) {
      volumeSizeBytes = rawVolumeSize >= 0 ? rawVolumeSize : null;
    } else if (rawVolumeSize is String) {
      final parsed = int.tryParse(rawVolumeSize.trim());
      if (parsed != null && parsed >= 0) {
        volumeSizeBytes = parsed;
      }
    }

    return _SqliteStorageSnapshot(
      enabled: true,
      volumeName: volumeName,
      mountPath: mountPath,
      fileName: fileName,
      databasePath: databasePath,
      databaseUrl: databaseUrl,
      volumeExists: payload['volume_exists'] is bool
          ? payload['volume_exists'] as bool
          : null,
      volumeMountpoint: payload['volume_mountpoint']?.toString(),
      volumeSizeBytes: volumeSizeBytes,
      checkedAt: checkedAt,
    );
  }
}

class _LiveAppSnapshot {
  const _LiveAppSnapshot({
    required this.repo,
    required this.branch,
    required this.commit,
    required this.url,
    required this.health,
    required this.publicHealth,
    required this.deployStatus,
    this.lastDeployAt,
    this.lastDuration,
  });

  final String repo;
  final String branch;
  final String commit;
  final String url;
  final ContainerRuntimeStatus health;
  final AppPublicHealthSnapshot publicHealth;
  final GitHubDeployStatus deployStatus;
  final DateTime? lastDeployAt;
  final Duration? lastDuration;

  _LiveAppSnapshot copyWith({
    String? repo,
    String? branch,
    String? commit,
    String? url,
    ContainerRuntimeStatus? health,
    AppPublicHealthSnapshot? publicHealth,
    GitHubDeployStatus? deployStatus,
    DateTime? lastDeployAt,
    Duration? lastDuration,
  }) {
    return _LiveAppSnapshot(
      repo: repo ?? this.repo,
      branch: branch ?? this.branch,
      commit: commit ?? this.commit,
      url: url ?? this.url,
      health: health ?? this.health,
      publicHealth: publicHealth ?? this.publicHealth,
      deployStatus: deployStatus ?? this.deployStatus,
      lastDeployAt: lastDeployAt ?? this.lastDeployAt,
      lastDuration: lastDuration ?? this.lastDuration,
    );
  }
}

class _PreflightCheck {
  const _PreflightCheck({
    required this.label,
    required this.passed,
    required this.detail,
  });

  final String label;
  final bool passed;
  final String detail;
}

class _PreflightReport {
  const _PreflightReport({required this.executedAt, required this.checks});

  final DateTime executedAt;
  final List<_PreflightCheck> checks;
}

class _RuntimeActionResult {
  const _RuntimeActionResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}
// end coverage-gate
