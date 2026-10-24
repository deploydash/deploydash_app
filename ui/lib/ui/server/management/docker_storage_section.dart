part of '../server_management_view.dart';

class _DockerStorageSection extends ConsumerStatefulWidget {
  const _DockerStorageSection(this.server, {super.key, this.onTerminalLine});

  final Server? server;
  final ServerTerminalLineWriter? onTerminalLine;

  @override
  ConsumerState<_DockerStorageSection> createState() =>
      _DockerStorageSectionState();
}

class _DockerStorageSectionState extends ConsumerState<_DockerStorageSection> {
  bool _isRefreshing = false;
  bool _isPruningImages = false;
  bool _isPruningBuildCache = false;
  String? _statusMessage;
  String? _statusError;
  Map<String, dynamic> _storage = const <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    unawaited(_refreshDockerStorage());
  }

  Future<Map<String, dynamic>?> _buildConnectionPayload(Server server) {
    return ref.read(serverConnectionPayloadResolverProvider)(server);
  }

  void _appendDockerStorageLogEvent(Map<String, dynamic> event) {
    final writer = widget.onTerminalLine;
    if (writer == null) {
      return;
    }
    final message = event['message']?.toString().trim();
    if (message == null || message.isEmpty) {
      return;
    }
    final eventType = event['type']?.toString().trim();
    final detail = event['level']?.toString().toLowerCase() == 'debug';
    writer(
      message,
      detail: detail,
      source: eventType == null || eventType.isEmpty
          ? 'docker-storage'
          : 'docker-storage:$eventType',
      taskType: 'docker-storage',
    );
  }

  Future<void> _refreshDockerStorage() async {
    if (_isRefreshing) {
      return;
    }
    final server = widget.server;
    if (server == null) {
      setState(() {
        _statusError = 'No server selected.';
      });
      return;
    }
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      setState(() {
        _statusError =
            'This server is missing SSH access details. Update the connection first.';
      });
      return;
    }

    setState(() {
      _isRefreshing = true;
      _statusError = null;
      _statusMessage = null;
    });

    try {
      final result =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'server',
                    operationId: 'docker_storage_status',
                    connection: connection,
                    params: const <String, dynamic>{'dry_run': false},
                    onEvent: _appendDockerStorageLogEvent,
                  ))
              .diagnosticPayload;
      if (!mounted) {
        return;
      }

      if (result['status'] == 'success') {
        setState(() {
          _storage = mapFrom(result['storage']);
          _statusMessage =
              result['msg']?.toString() ?? 'Docker storage usage refreshed.';
          _statusError = null;
          _isRefreshing = false;
        });
      } else {
        setState(() {
          _statusError =
              result['msg']?.toString() ??
              'Couldn’t load Docker storage usage.';
          _isRefreshing = false;
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusError = 'Couldn’t load Docker storage usage: $error';
        _isRefreshing = false;
      });
    }
  }

  Future<void> _showDockerStorageErrorDialog(String message) async {
    await showAppNotice(
      context,
      title: 'Couldn’t finish Docker cleanup',
      message: message,
    );
  }

  Future<bool> _confirmCleanup({
    required String title,
    required String description,
    required String confirmLabel,
    required Widget body,
    required Key confirmButtonKey,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDestructiveConfirmDialog(
        title: title,
        description: description,
        confirmLabel: confirmLabel,
        confirmButtonKey: confirmButtonKey,
        body: body,
      ),
    );
    return confirmed == true;
  }

  Future<void> _runCleanup(String target) async {
    final server = widget.server;
    if (server == null) {
      return;
    }
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      await _showDockerStorageErrorDialog(
        'This server is missing SSH access details. Update the connection first.',
      );
      return;
    }

    final cleaningImages = target == 'unused_images';
    setState(() {
      if (cleaningImages) {
        _isPruningImages = true;
      } else {
        _isPruningBuildCache = true;
      }
      _statusError = null;
      _statusMessage = null;
    });

    try {
      final result =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'server',
                    operationId: 'docker_storage_prune',
                    connection: connection,
                    params: <String, dynamic>{
                      'dry_run': false,
                      'target': target,
                    },
                    onEvent: _appendDockerStorageLogEvent,
                  ))
              .diagnosticPayload;
      if (!mounted) {
        return;
      }

      if (result['status'] == 'success') {
        final reclaimedBytes = result['reclaimed_bytes'] as int?;
        setState(() {
          _storage = mapFrom(result['storage']);
          _statusMessage = reclaimedBytes == null
              ? (result['msg']?.toString() ?? 'Docker cleanup finished.')
              : '${result['msg']?.toString() ?? 'Docker cleanup finished.'} '
                    'Freed ${formatDockerStorageBytes(reclaimedBytes, fallback: '0 B')}.';
          _statusError = null;
        });
      } else {
        final message =
            result['msg']?.toString() ?? 'Docker cleanup did not finish.';
        setState(() {
          _statusError = message;
        });
        await _showDockerStorageErrorDialog(message);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = 'Docker cleanup did not finish: $error';
      setState(() {
        _statusError = message;
      });
      await _showDockerStorageErrorDialog(message);
    } finally {
      if (mounted) {
        setState(() {
          _isPruningImages = false;
          _isPruningBuildCache = false;
        });
      }
    }
  }

  Future<void> _removeUnusedImages() async {
    final confirmed = await _confirmCleanup(
      title: 'Delete unused Docker images?',
      description:
          'This removes Docker images that are not being used by a container.',
      confirmLabel: 'Delete unused images',
      confirmButtonKey: const Key(
        'docker-storage-confirm-unused-images-button',
      ),
      body: const Text(
        'Use this when the server is running low on disk space. '
        'Deploy Dash services and apps will pull images again when they need '
        'them later.',
      ),
    );
    if (!mounted || !confirmed) {
      return;
    }
    await _runCleanup('unused_images');
  }

  Future<void> _clearBuildCache() async {
    final confirmed = await _confirmCleanup(
      title: 'Delete Docker build cache?',
      description: 'This removes cached build layers from the server.',
      confirmLabel: 'Delete build cache',
      confirmButtonKey: const Key('docker-storage-confirm-build-cache-button'),
      body: const Text(
        'Future builds will take longer until Docker warms the cache again.',
      ),
    );
    if (!mounted || !confirmed) {
      return;
    }
    await _runCleanup('build_cache');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusLine = _statusError ?? _statusMessage;
    final view = buildServerDockerStorageView(_storage);

    return AppWorkspaceSection(
      key: const Key('server-management-docker-storage-section'),
      title: 'Docker storage',
      subtitle:
          'Review image and build cache usage when the server is running low on disk space.',
      contentSpacing: 12,
      headerAction: IconButton(
        key: const Key('docker-storage-refresh-button'),
        onPressed: _isRefreshing ? null : _refreshDockerStorage,
        tooltip: 'Refresh',
        icon: _isRefreshing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(YaruIcons.refresh, size: 18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 180,
                child: _CompactMetricTile(
                  label: 'Unused images',
                  value: formatDockerStorageBytes(view.imagesBytes),
                ),
              ),
              SizedBox(
                width: 180,
                child: _CompactMetricTile(
                  label: 'Build cache',
                  value: formatDockerStorageBytes(view.buildCacheBytes),
                ),
              ),
              SizedBox(
                width: 180,
                child: _CompactMetricTile(
                  label: 'Reclaimable now',
                  value: formatDockerStorageBytes(view.totalReclaimableBytes),
                  subtle: true,
                ),
              ),
              SizedBox(
                width: 180,
                child: _CompactMetricTile(
                  label: 'Unused image count',
                  value: formatDockerStorageCount(view.imagesCount),
                  subtle: true,
                ),
              ),
              SizedBox(
                width: 180,
                child: _CompactMetricTile(
                  label: 'Build cache entries',
                  value: formatDockerStorageCount(view.buildCacheCount),
                  subtle: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('docker-storage-prune-images-button'),
                onPressed: (_isPruningImages || _isPruningBuildCache)
                    ? null
                    : _removeUnusedImages,
                icon: _isPruningImages
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_sweep_rounded, size: 16),
                label: Text(
                  _isPruningImages
                      ? 'Deleting unused images'
                      : 'Delete unused images',
                ),
              ),
              OutlinedButton.icon(
                key: const Key('docker-storage-prune-cache-button'),
                onPressed: (_isPruningImages || _isPruningBuildCache)
                    ? null
                    : _clearBuildCache,
                icon: _isPruningBuildCache
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.layers_clear_rounded, size: 16),
                label: Text(
                  _isPruningBuildCache
                      ? 'Deleting build cache'
                      : 'Delete build cache',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Last checked: ${formatOverviewTimestamp(view.checkedAt, fallback: 'Not yet')}',
            style: theme.textTheme.bodySmall,
          ),
          if (statusLine != null) ...[
            const SizedBox(height: 8),
            Text(
              statusLine,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _statusError != null ? YaruColors.red : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
