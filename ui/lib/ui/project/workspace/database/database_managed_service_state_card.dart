part of '../../project_workspace.dart';

class _DatabaseManagedServiceStateCard extends StatelessWidget {
  const _DatabaseManagedServiceStateCard({
    required this.state,
    required this.message,
    required this.description,
  });

  final _DatabaseTabViewState state;
  final String message;
  final String description;

  @override
  Widget build(BuildContext context) {
    return AppWorkspaceSection(
      key: const Key('database-managed-service-state-card'),
      icon: Icons.info_outline,
      title: 'Managed databases',
      subtitle: message,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(description),
          const SizedBox(height: 12),
          OutlinedButton(
            key: const Key('database-open-server-services-button'),
            onPressed: state.widget.onOpenServerServices,
            child: const Text('Open server services'),
          ),
        ],
      ),
    );
  }
}
