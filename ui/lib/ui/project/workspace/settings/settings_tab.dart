part of '../../project_workspace.dart';

class _SettingsTabView extends StatelessWidget {
  const _SettingsTabView({this.onProjectDeleted});

  final ValueChanged<ProjectDeletionOutcome>? onProjectDeleted;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        AppWorkspaceSection(
          icon: YaruIcons.settings,
          title: 'Project settings',
          subtitle:
              'This project currently has one available setting: permanent deletion.',
          child: _SettingsDangerZone(onProjectDeleted: onProjectDeleted),
        ),
      ],
    );
  }
}

class _SettingsDangerZone extends ConsumerStatefulWidget {
  const _SettingsDangerZone({this.onProjectDeleted});

  final ValueChanged<ProjectDeletionOutcome>? onProjectDeleted;

  @override
  ConsumerState<_SettingsDangerZone> createState() =>
      _SettingsDangerZoneState();
}

class _SettingsDangerZoneState extends ConsumerState<_SettingsDangerZone> {
  bool _isDeleting = false;
  String? _deleteError;
  List<String> _deleteWarnings = const <String>[];

  Future<bool> _confirmDelete(Project project) async {
    final confirmController = TextEditingController();
    var acknowledged = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final typed = confirmController.text.trim();
            final canDelete =
                typed == project.name.trim() && acknowledged && !_isDeleting;
            return AppDestructiveConfirmDialog(
              key: const Key('settings-delete-confirm-dialog'),
              title: 'Delete project',
              description: projectDeleteDialogDescription(project.name),
              confirmLabel: 'Delete project',
              confirmEnabled: canDelete,
              confirmButtonKey: const Key('settings-delete-confirm-button'),
              body: SizedBox(
                width: 460,
                child: AppFormSection(
                  children: [
                    Text(
                      projectDeleteDialogTypePrompt(project.name),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    AppTextFormField(
                      fieldKey: const Key('settings-delete-confirm-input'),
                      controller: confirmController,
                      onChanged: (_) => setDialogState(() {}),
                      labelText: 'Project name',
                      hintText: project.name,
                    ),
                    AppCheckboxField(
                      key: const Key('settings-delete-confirm-checkbox'),
                      value: acknowledged,
                      onChanged: (value) {
                        setDialogState(() {
                          acknowledged = value ?? false;
                        });
                      },
                      title: projectDeleteDialogAcknowledgeLabel(),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    return confirmed == true;
  }

  Future<void> _deleteProject() async {
    final project = ref.read(selectedProjectProvider);
    final server = ref.read(selectedServerProvider);
    if (project == null || _isDeleting) {
      return;
    }
    final deleteScope = WorkspaceScope.fromSelection(project, server);

    final confirmed = await _confirmDelete(project);
    if (!confirmed || !mounted) {
      return;
    }
    final currentProject = ref.read(selectedProjectProvider);
    final currentServer = ref.read(selectedServerProvider);
    final currentScope = WorkspaceScope.fromSelection(
      currentProject,
      currentServer,
    );
    final selectionChanged = projectDeletionSelectionChanged(
      scopeAtConfirm: deleteScope,
      projectIdAtConfirm: project.id,
      serverIdAtConfirm: server?.id,
      currentScope: currentScope,
      currentProjectId: currentProject?.id,
      currentServerId: currentServer?.id,
    );
    if (selectionChanged) {
      setState(() {
        _deleteError =
            'Project selection changed before deletion started. Open the project again and retry.';
      });
      return;
    }

    setState(() {
      _isDeleting = true;
      _deleteError = null;
      _deleteWarnings = const <String>[];
    });

    try {
      final outcome = await ref
          .read(projectDeletionCoordinatorProvider)
          .start(project: project, server: server);
      ref.invalidate(projectDeletionRecoveriesProvider);
      final projectNotifier = ref.read(projectListProvider.notifier);
      if (outcome.completed) {
        await projectNotifier.deleteProject(project.id);
        ref
            .read(projectLifecycleActionsProvider)
            .forgetProjectState(project.id);
      } else {
        projectNotifier.hidePendingProject(project.id);
      }
      ref.read(selectedProjectIdProvider.notifier).clear();

      if (!mounted) {
        return;
      }

      final message = outcome.completed
          ? projectDeleteSuccessMessage(project.name, false)
          : 'Project cleanup needs attention. Retry it from Home.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      widget.onProjectDeleted?.call(outcome);
      if (widget.onProjectDeleted == null) {
        setState(() {
          _deleteWarnings = outcome.messages;
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      final deleteError = couldntMessage('remove this project', error);
      setState(() {
        _deleteError = deleteError;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(deleteError)));
    } finally {
      if (mounted) {
        setState(() {
          _isDeleting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedProject = ref.watch(selectedProjectProvider);
    final buttonDisabled = selectedProject == null || _isDeleting;
    // Hoisted so the `!= null` check promotes it; a State field is never
    // promoted.
    final deleteError = _deleteError;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              YaruIcons.trash,
              key: Key('settings-delete-icon'),
              color: YaruColors.red,
            ),
            SizedBox(width: 8),
            Text(
              projectDangerZoneTitle(),
              key: Key('settings-delete-text'),
              style: TextStyle(
                color: YaruColors.red,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(projectDangerZoneSubtitle()),
        if (selectedProject == null) ...[
          const SizedBox(height: 6),
          Text(
            projectDangerZoneMissingSelectionMessage(),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (deleteError != null) ...[
          Text(
            deleteError,
            key: const Key('settings-delete-error-text'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (_deleteWarnings.isNotEmpty) ...[
          Text(
            'Remote cleanup warnings:',
            key: const Key('settings-delete-warnings-title'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          for (final warning in _deleteWarnings.take(4))
            Text(
              '- $warning',
              key: Key('settings-delete-warning-${warning.hashCode}'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 8),
        ],
        ElevatedButton.icon(
          key: const Key('settings-delete-button'),
          onPressed: buttonDisabled ? null : _deleteProject,
          style: ElevatedButton.styleFrom(
            backgroundColor: YaruColors.red,
            foregroundColor: Colors.white,
          ),
          icon: _isDeleting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(YaruIcons.trash),
          label: Text(_isDeleting ? 'Deleting...' : 'Delete project'),
        ),
      ],
    );
  }
}
