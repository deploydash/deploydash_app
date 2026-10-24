import '../../models/project_destination.dart';

/// The durable, URL-shaped destinations exposed by the desktop shell.
///
/// Keeping the route value independent from widgets lets route configuration,
/// rail actions, and direct tests agree on one representation of a workspace
/// destination.
enum DesktopRouteKind {
  home,
  project,
  createProject,
  onboarding,
  serverManagement,
  appSettings,
  unlock,
}

enum DesktopServerManagementTab {
  overview,
  services,
  updates,
  security,
  settings;

  String get id => switch (this) {
    DesktopServerManagementTab.overview => 'overview',
    DesktopServerManagementTab.services => 'services',
    DesktopServerManagementTab.updates => 'updates',
    DesktopServerManagementTab.security => 'security',
    DesktopServerManagementTab.settings => 'settings',
  };

  static DesktopServerManagementTab fromId(String? value) {
    return DesktopServerManagementTab.values.firstWhere(
      (tab) => tab.id == value,
      orElse: () => DesktopServerManagementTab.overview,
    );
  }
}

enum DesktopAppSettingsDestination {
  appearance,
  updates,
  agentAccess,
  appBackup,
  security,
  privacy;

  String get id => switch (this) {
    DesktopAppSettingsDestination.appearance => 'appearance',
    DesktopAppSettingsDestination.updates => 'updates',
    DesktopAppSettingsDestination.agentAccess => 'agent-access',
    DesktopAppSettingsDestination.appBackup => 'app-backup',
    DesktopAppSettingsDestination.security => 'security',
    DesktopAppSettingsDestination.privacy => 'privacy',
  };

  static DesktopAppSettingsDestination fromId(String? value) {
    return DesktopAppSettingsDestination.values.firstWhere(
      (destination) => destination.id == value,
      orElse: () => DesktopAppSettingsDestination.appearance,
    );
  }
}

/// A typed shell route with validated contextual-destination parameters.
class DesktopRoute {
  const DesktopRoute._({
    required this.kind,
    this.projectId,
    this.projectDestinationId,
    this.serverManagementTab,
    this.appSettingsDestination,
  });

  const DesktopRoute.home() : this._(kind: DesktopRouteKind.home);

  const DesktopRoute.createProject()
    : this._(kind: DesktopRouteKind.createProject);

  const DesktopRoute.onboarding() : this._(kind: DesktopRouteKind.onboarding);

  const DesktopRoute.unlock() : this._(kind: DesktopRouteKind.unlock);

  const DesktopRoute.serverManagement({
    DesktopServerManagementTab tab = DesktopServerManagementTab.overview,
  }) : this._(
         kind: DesktopRouteKind.serverManagement,
         serverManagementTab: tab,
       );

  const DesktopRoute.appSettings({
    DesktopAppSettingsDestination destination =
        DesktopAppSettingsDestination.appearance,
  }) : this._(
         kind: DesktopRouteKind.appSettings,
         appSettingsDestination: destination,
       );

  factory DesktopRoute.project({
    required String projectId,
    String destinationId = defaultProjectDestinationId,
  }) {
    final destinationIndex = projectDestinationIndex(destinationId) ?? 0;
    return DesktopRoute._(
      kind: DesktopRouteKind.project,
      projectId: projectId.trim(),
      projectDestinationId: projectWorkspaceDestinations[destinationIndex].id,
    );
  }

  final DesktopRouteKind kind;
  final String? projectId;
  final String? projectDestinationId;
  final DesktopServerManagementTab? serverManagementTab;
  final DesktopAppSettingsDestination? appSettingsDestination;

  /// This route as a URL path.
  ///
  /// The two assertions are deliberate. `DesktopRoute.project` is the only
  /// constructor that produces [DesktopRouteKind.project], and it always sets
  /// both fields; the private constructor that could disagree is not reachable
  /// from outside this class. Falling back to an empty segment instead would
  /// emit `/projects//web-app`, and a silently malformed route is worse to
  /// diagnose than a loud failure at the point it was built.
  ///
  /// The other two fields have real defaults, so they use them -- the same
  /// ones [serverManagementTabIndex] and [appSettingsDestinationId] apply two
  /// lines below.
  String get location => switch (kind) {
    DesktopRouteKind.home => '/home',
    DesktopRouteKind.createProject => '/projects/new',
    DesktopRouteKind.onboarding => '/servers/onboarding',
    DesktopRouteKind.unlock => '/unlock',
    DesktopRouteKind.project =>
      '/projects/${Uri.encodeComponent(projectId!)}'
          '/${Uri.encodeComponent(projectDestinationId!)}',
    DesktopRouteKind.serverManagement =>
      '/servers/manage/'
          '${(serverManagementTab ?? DesktopServerManagementTab.overview).id}',
    DesktopRouteKind.appSettings => '/settings/$appSettingsDestinationId',
  };

  int get projectDestinationTabIndex {
    if (kind != DesktopRouteKind.project) {
      return 0;
    }
    return projectDestinationIndexFor(projectDestinationId);
  }

  int get serverManagementTabIndex =>
      (serverManagementTab ?? DesktopServerManagementTab.overview).index;

  String get appSettingsDestinationId =>
      (appSettingsDestination ?? DesktopAppSettingsDestination.appearance).id;

  static DesktopRoute fromUri(Uri uri) {
    final segments = uri.pathSegments;
    return switch (segments) {
      [] || [''] || ['home'] => const DesktopRoute.home(),
      ['projects', 'new'] => const DesktopRoute.createProject(),
      ['projects', final String projectId] ||
      [
        'projects',
        final String projectId,
        '',
      ] => DesktopRoute.project(projectId: projectId),
      ['projects', final String projectId, final String destinationId] =>
        DesktopRoute.project(
          projectId: projectId,
          destinationId: destinationId,
        ),
      ['servers', 'onboarding'] => const DesktopRoute.onboarding(),
      ['servers', 'manage'] => const DesktopRoute.serverManagement(),
      ['servers', 'manage', final String tabId] =>
        DesktopRoute.serverManagement(
          tab: DesktopServerManagementTab.fromId(tabId),
        ),
      ['settings'] => const DesktopRoute.appSettings(),
      ['settings', final String destinationId] => DesktopRoute.appSettings(
        destination: DesktopAppSettingsDestination.fromId(destinationId),
      ),
      ['unlock'] => const DesktopRoute.unlock(),
      _ => const DesktopRoute.home(),
    };
  }

  @override
  bool operator ==(Object other) {
    return other is DesktopRoute &&
        kind == other.kind &&
        projectId == other.projectId &&
        projectDestinationId == other.projectDestinationId &&
        serverManagementTab == other.serverManagementTab &&
        appSettingsDestination == other.appSettingsDestination;
  }

  @override
  int get hashCode => Object.hash(
    kind,
    projectId,
    projectDestinationId,
    serverManagementTab,
    appSettingsDestination,
  );
}

int projectDestinationIndexFor(String? destinationId) {
  return projectDestinationIndex(destinationId ?? '') ?? 0;
}
