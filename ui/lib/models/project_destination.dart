/// A selectable destination in a project's workspace.
///
/// The value is shared by navigation, recents, and local search. Visual icon
/// selection remains in the UI layer.
class ProjectDestination {
  /// Creates a destination with its stable [id] and its display copy.
  const ProjectDestination({
    required this.id,
    required this.label,
    required this.subtitle,
  });

  /// Stable identifier, persisted in recents and routes.
  ///
  /// Never derive it from [label]: the id is written to the local database
  /// and appears in URLs, so renaming a tab must not orphan a saved visit.
  final String id;

  /// Tab title, in sentence case.
  final String label;

  /// One line saying what the screen is for, shown to a novice choosing it.
  final String subtitle;
}

/// The destination a project opens on when nothing else is remembered.
const String defaultProjectDestinationId = 'web-app';

/// Every destination in a project workspace, in tab order.
///
/// One list, read by navigation, recents and local search alike, so a tab
/// cannot exist in one of them and not the others. Order is display order:
/// [projectDestinationIndex] returns a position in this list.
const List<ProjectDestination> projectWorkspaceDestinations = [
  ProjectDestination(
    id: 'web-app',
    label: 'Web app',
    subtitle: 'Deploy code, review releases, and inspect runtime state.',
  ),
  ProjectDestination(
    id: 'workers',
    label: 'Workers',
    subtitle: 'Manage background processes for this project.',
  ),
  ProjectDestination(
    id: 'database',
    label: 'Database',
    subtitle: 'Manage project databases, users, and connection details.',
  ),
  ProjectDestination(
    id: 'email',
    label: 'Email',
    subtitle: 'Manage project mailboxes, aliases, and delivery settings.',
  ),
  ProjectDestination(
    id: 'domain',
    label: 'Domain',
    subtitle: 'Review project domains and DNS requirements.',
  ),
  ProjectDestination(
    id: 'backup',
    label: 'Backup',
    subtitle: 'Configure backup destinations, plans, and restores.',
  ),
  ProjectDestination(
    id: 'scheduler',
    label: 'Scheduler',
    subtitle: 'Run and manage recurring project commands.',
  ),
  ProjectDestination(
    id: 'log',
    label: 'Log',
    subtitle: 'Inspect deployment and application output.',
  ),
  ProjectDestination(
    id: 'settings',
    label: 'Settings',
    subtitle: 'Remove this project and review exactly what will be deleted.',
  ),
];

/// Index of the destination with [id], or `null` when it is not a known screen.
int? projectDestinationIndex(String id) {
  final normalized = id.trim();
  for (var index = 0; index < projectWorkspaceDestinations.length; index++) {
    if (projectWorkspaceDestinations[index].id == normalized) {
      return index;
    }
  }
  return null;
}

/// The destination with [id], falling back to the default web app screen.
ProjectDestination projectDestinationOrDefault(String id) {
  final index = projectDestinationIndex(id);
  return projectWorkspaceDestinations[index ?? 0];
}
