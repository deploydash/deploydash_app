part of '../../project_workspace.dart';

extension _DatabaseProjectSharingOperations on _DatabaseTabViewState {
  // coverage-gate: refresh_linked_projects
  Future<void> _refreshLinkedProjects({
    required Project project,
    required Server server,
  }) async {
    final projectId = project.id;
    final serverId = server.id;
    _applyState(() => _sharingLoading = true);
    try {
      final linkedGroups = await ref
          .read(projectNetworkTrustRepositoryProvider)
          .listGroupsForProject(projectId);
      if (!isCurrentWorkspaceIds(projectId: projectId, serverId: serverId)) {
        return;
      }
      _applyState(() {
        _linkedProjectGroups = linkedGroups;
        _sharingLoading = false;
      });
    } catch (error) {
      if (!isCurrentWorkspaceIds(projectId: projectId, serverId: serverId)) {
        return;
      }
      _applyState(() {
        _sharingLoading = false;
        _setDatabaseErrorState(
          message: 'Could not load linked projects: $error',
        );
      });
    }
  }

  // end coverage-gate
}

class _ProjectDatabaseSharingCard extends StatelessWidget {
  const _ProjectDatabaseSharingCard({
    required this.state,
    required this.project,
    required this.projects,
  });

  final _DatabaseTabViewState state;
  final Project project;
  final List<Project> projects;

  @override
  Widget build(BuildContext context) {
    return AppWorkspaceSection(
      key: const Key('database-owner-sharing-card'),
      icon: Icons.hub_outlined,
      title: 'Linked projects',
      subtitle: 'Linked projects share private network reachability.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state._sharingLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            ),
          if (state._linkedProjectGroups.isEmpty)
            const Text(
              'This project is not linked to another project yet. Link projects when they are designed to trust each other and call private services directly.',
            )
          else
            for (final group in state._linkedProjectGroups) ...[
              Builder(
                builder: (context) {
                  final memberNames = group.memberProjectIds
                      .where((projectId) => projectId != project.id)
                      .map(
                        (projectId) =>
                            state._projectById(projects, projectId)?.name,
                      )
                      .whereType<String>()
                      .toList(growable: false);
                  return AppCard(
                    margin: const EdgeInsets.only(bottom: 10),
                    radius: 10,
                    borderColor: Theme.of(context).colorScheme.outlineVariant,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                group.displayName,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                memberNames.isEmpty
                                    ? 'No other linked project is visible locally.'
                                    : 'Linked with ${memberNames.join(', ')}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                group.networkName,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          const SizedBox(height: 8),
          Text(
            'Database users are normal credentials. If you copy a credential into a linked project, that project can use it when the service permissions allow it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
