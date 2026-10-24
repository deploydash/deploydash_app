import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/project_provider.dart';
import '../../providers/recent_projects_provider.dart';
import '../../providers/server_list_provider.dart';
import '../../services/app_analytics_service.dart';
import '../../services/desktop_update_service.dart';
import '../../services/local_search_index.dart';
import '../layout/app_navigation_rail.dart';
import '../navigation/desktop_route.dart';
import '../project/workspace/shell/project_destinations.dart';
import '../system/app_theme.dart';

/// Applies a requested typed desktop route.
typedef ShellRouteNavigator = void Function(DesktopRoute route);

/// Selects a saved server without coupling navigation to persistence details.
typedef ShellServerSelector = void Function(String serverId);

/// Records presentation-level workspace navigation analytics.
typedef ShellWorkspaceTracker =
    void Function({required String workspace, String? entryPoint, String? tab});

/// Reports a control use on behalf of the rail, without importing
/// analytics: the shell owns the call, mirroring [ShellWorkspaceTracker].
typedef ShellControlTracker =
    void Function({required AppControl control, String? tab});

/// Coordinates presentation-level navigation requests from the shell and Home.
///
/// Route application stays with [ShellPage], where the router test fallback
/// lives, while this value owns the rail's destination semantics and analytics.
class ShellNavigationActions {
  const ShellNavigationActions({
    required ShellRouteNavigator navigate,
    required VoidCallback clearDeletedProjectNotice,
    required VoidCallback prepareAddServer,
    required ShellServerSelector selectServer,
    required String Function(String projectId) lastVisitedDestination,
    required ShellWorkspaceTracker trackWorkspaceOpened,
    required ShellControlTracker trackControlUsed,
    required ValueChanged<String> writeTerminalNavigationLine,
  }) : _navigate = navigate,
       _clearDeletedProjectNotice = clearDeletedProjectNotice,
       _prepareAddServer = prepareAddServer,
       _selectServer = selectServer,
       _lastVisitedDestination = lastVisitedDestination,
       _trackWorkspaceOpened = trackWorkspaceOpened,
       _trackControlUsed = trackControlUsed,
       _writeTerminalNavigationLine = writeTerminalNavigationLine;

  final ShellRouteNavigator _navigate;
  final VoidCallback _clearDeletedProjectNotice;
  final VoidCallback _prepareAddServer;
  final ShellServerSelector _selectServer;
  final String Function(String projectId) _lastVisitedDestination;
  final ShellWorkspaceTracker _trackWorkspaceOpened;
  final ShellControlTracker _trackControlUsed;
  final ValueChanged<String> _writeTerminalNavigationLine;

  void openCreateProject() {
    _clearDeletedProjectNotice();
    _navigate(const DesktopRoute.createProject());
    _trackWorkspaceOpened(
      workspace: 'create_project',
      entryPoint: 'home_dashboard',
    );
    _writeTerminalNavigationLine('[ui] Opening project creation form');
  }

  // coverage-gate: open_home_mode
  void openHome() {
    _navigate(const DesktopRoute.home());
    _trackWorkspaceOpened(workspace: 'home');
    _writeTerminalNavigationLine('[ui] Opening home workspace');
  }
  // end coverage-gate

  // coverage-gate: open_add_server_mode
  void openAddServer() {
    _prepareAddServer();
    _clearDeletedProjectNotice();
    _navigate(const DesktopRoute.onboarding());
    _trackWorkspaceOpened(
      workspace: 'add_server',
      entryPoint: 'home_dashboard',
    );
  }
  // end coverage-gate

  // coverage-gate: open_project
  void openProject(String projectId) {
    openProjectScreen(projectId, _lastVisitedDestination(projectId));
  }

  void openProjectScreen(String projectId, String destinationId) {
    _clearDeletedProjectNotice();
    _navigate(
      DesktopRoute.project(projectId: projectId, destinationId: destinationId),
    );
    _trackWorkspaceOpened(workspace: 'project');
    _writeTerminalNavigationLine('[ui] Opening selected project workspace');
  }
  // end coverage-gate

  void openSearchResult(LocalSearchResult result) {
    // Both submit paths (keyboard enter and row tap) converge on the
    // overlay's selection callback, whose only sink is this method: one call
    // here counts every submit exactly once, ahead of the arrival event.
    _trackControlUsed(control: AppControl.railSearchSubmitted);
    final serverId = result.serverId;
    if (serverId != null) {
      _selectServer(serverId);
    }
    final projectId = result.projectId;
    if (projectId == null) {
      openServerManagement();
      return;
    }
    openProjectScreen(
      projectId,
      result.destinationId ?? defaultProjectDestinationId,
    );
  }

  // coverage-gate: select_server_from_home
  void selectServerFromHome(String serverId) => _selectServer(serverId);
  // end coverage-gate

  void openServerManagement() {
    _clearDeletedProjectNotice();
    _navigate(const DesktopRoute.serverManagement());
    _trackWorkspaceOpened(workspace: 'server_management', tab: 'overview');
    _writeTerminalNavigationLine('[ui] Opening server management workspace');
  }

  void openServerManagementServices() {
    _clearDeletedProjectNotice();
    _navigate(
      const DesktopRoute.serverManagement(
        tab: DesktopServerManagementTab.services,
      ),
    );
    _trackWorkspaceOpened(workspace: 'server_management', tab: 'services');
    _writeTerminalNavigationLine(
      '[ui] Opening server management services tab.',
    );
  }

  void openAppSettings() {
    _clearDeletedProjectNotice();
    _navigate(const DesktopRoute.appSettings());
    _trackWorkspaceOpened(workspace: 'app_settings', entryPoint: 'sidebar');
    _writeTerminalNavigationLine('[ui] Opening app settings workspace');
  }

  void openDesktopUpdates() {
    _clearDeletedProjectNotice();
    _navigate(
      const DesktopRoute.appSettings(
        destination: DesktopAppSettingsDestination.updates,
      ),
    );
    _trackWorkspaceOpened(
      workspace: 'app_settings',
      entryPoint: 'update_badge',
    );
  }

  void openProjectDestination({
    required String projectId,
    required String destinationId,
  }) {
    if (projectId.trim().isEmpty) {
      return;
    }
    _navigate(
      DesktopRoute.project(projectId: projectId, destinationId: destinationId),
    );
  }

  void openServerManagementDestination(int index) {
    final tabs = DesktopServerManagementTab.values;
    if (index < 0 || index >= tabs.length) {
      return;
    }
    _navigate(DesktopRoute.serverManagement(tab: tabs[index]));
  }

  void openAppSettingsDestination(String destinationId) {
    _navigate(
      DesktopRoute.appSettings(
        destination: DesktopAppSettingsDestination.fromId(destinationId),
      ),
    );
  }
}

/// Immutable route context used to derive the rail's provider-owned state.
@immutable
class ShellNavigationRailContext {
  const ShellNavigationRailContext({
    required this.route,
    required this.showFirstRunOnboarding,
  });

  final DesktopRoute route;
  final bool showFirstRunOnboarding;

  @override
  bool operator ==(Object other) {
    return other is ShellNavigationRailContext &&
        other.route == route &&
        other.showFirstRunOnboarding == showFirstRunOnboarding;
  }

  @override
  int get hashCode => Object.hash(route, showFirstRunOnboarding);
}

/// The provider-owned data needed by [ShellNavigationRail].
@immutable
class ShellNavigationRailState {
  const ShellNavigationRailState({
    required this.selectedSection,
    required this.recentProjectGroups,
    required this.currentProjectId,
    required this.currentDestinationId,
    required this.currentServerName,
    required this.showCurrentServer,
    required this.hasServers,
    required this.updateAvailable,
    required List<LocalSearchResult> Function(String query) search,
  }) : _search = search;

  final AppNavigationSection selectedSection;
  final List<RecentProjectGroup> recentProjectGroups;
  final String? currentProjectId;
  final String currentDestinationId;
  final String? currentServerName;
  final bool showCurrentServer;
  final bool hasServers;
  final bool updateAvailable;
  final List<LocalSearchResult> Function(String query) _search;

  List<LocalSearchResult> search(String query) => _search(query);
}

/// Builds the rail snapshot from the providers that own its source data.
final shellNavigationRailStateProvider =
    Provider.family<ShellNavigationRailState, ShellNavigationRailContext>((
      ref,
      context,
    ) {
      final serverCatalog = ref.watch(serverCatalogProvider);
      final projects = ref.watch(projectListProvider);
      final recentProjectGroups = ref.watch(recentProjectGroupsProvider);
      final desktopUpdate = ref.watch(desktopUpdateControllerProvider);
      final routeKind = context.showFirstRunOnboarding
          ? DesktopRouteKind.onboarding
          : context.route.kind;
      final selectedServer = serverCatalog.selectedServer;
      final updateAvailable = switch (desktopUpdate) {
        AsyncData<DesktopUpdateSnapshot>(:final value) => value.showBadge,
        _ => false,
      };
      final selectedSection = switch (routeKind) {
        DesktopRouteKind.home => AppNavigationSection.home,
        DesktopRouteKind.onboarding ||
        DesktopRouteKind.serverManagement => AppNavigationSection.server,
        DesktopRouteKind.createProject ||
        DesktopRouteKind.project => AppNavigationSection.project,
        DesktopRouteKind.appSettings ||
        DesktopRouteKind.unlock => AppNavigationSection.settings,
      };

      return ShellNavigationRailState(
        selectedSection: selectedSection,
        recentProjectGroups: recentProjectGroups,
        currentProjectId: routeKind == DesktopRouteKind.project
            ? context.route.projectId
            : null,
        currentDestinationId:
            context.route.projectDestinationId ?? defaultProjectDestinationId,
        currentServerName: selectedServer?.name,
        showCurrentServer:
            selectedServer != null && routeKind == DesktopRouteKind.onboarding,
        hasServers: serverCatalog.hasServers,
        updateAvailable: updateAvailable,
        search: (query) => searchLocalIndex(
          query: query,
          servers: serverCatalog.servers,
          projects: projects,
        ),
      );
    });

/// Renders the shell's responsive rail from its own provider snapshot.
class ShellNavigationRail extends ConsumerWidget {
  const ShellNavigationRail({
    super.key,
    required this.route,
    required this.showFirstRunOnboarding,
    required this.actions,
  });

  final DesktopRoute route;
  final bool showFirstRunOnboarding;
  final ShellNavigationActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(
      shellNavigationRailStateProvider(
        ShellNavigationRailContext(
          route: route,
          showFirstRunOnboarding: showFirstRunOnboarding,
        ),
      ),
    );
    final extended =
        MediaQuery.sizeOf(context).width >= AppWorkspaceBreakpoints.twoColumn;

    return SizedBox(
      width: extended ? 240 : 72,
      child: AppNavigationRail(
        extended: extended,
        selectedSection: state.selectedSection,
        recentProjectGroups: state.recentProjectGroups,
        onOpenProjectScreen: actions.openProjectScreen,
        currentProjectId: state.currentProjectId,
        currentDestinationId: state.currentDestinationId,
        currentServerName: state.currentServerName,
        showCurrentServer: state.showCurrentServer,
        searchFocusNode: ShellNavigationSearchShortcutScope.maybeFocusNodeOf(
          context,
        ),
        searchResultsBuilder: state.search,
        onSearchResultSelected: actions.openSearchResult,
        onOpenHome: actions.openHome,
        onOpenServerManagement: state.hasServers
            ? actions.openServerManagement
            : null,
        onOpenAppSettings: actions.openAppSettings,
        onOpenUpdates: actions.openDesktopUpdates,
        updateAvailable: state.updateAvailable,
      ),
    );
  }
}

/// Gives the full shell a shared Ctrl/Cmd+K handler and rail search focus.
class ShellNavigationSearchShortcutScope extends StatefulWidget {
  const ShellNavigationSearchShortcutScope({super.key, required this.child});

  final Widget child;

  /// Returns the rail search focus node when [context] is inside this scope.
  static FocusNode? maybeFocusNodeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_ShellNavigationSearchFocus>()
        ?.focusNode;
  }

  @override
  State<ShellNavigationSearchShortcutScope> createState() =>
      _ShellNavigationSearchShortcutScopeState();
}

class _ShellNavigationSearchShortcutScopeState
    extends State<ShellNavigationSearchShortcutScope> {
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'shell-search');

  @override
  void dispose() {
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _ShellNavigationSearchFocus(
      focusNode: _searchFocusNode,
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _FocusSearchIntent(),
          SingleActivator(LogicalKeyboardKey.keyK, meta: true):
              _FocusSearchIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _FocusSearchIntent: CallbackAction<_FocusSearchIntent>(
              onInvoke: (_) {
                _searchFocusNode.requestFocus();
                return null;
              },
            ),
          },
          child: widget.child,
        ),
      ),
    );
  }
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

class _ShellNavigationSearchFocus extends InheritedWidget {
  const _ShellNavigationSearchFocus({
    required this.focusNode,
    required super.child,
  });

  final FocusNode focusNode;

  @override
  bool updateShouldNotify(_ShellNavigationSearchFocus oldWidget) {
    return oldWidget.focusNode != focusNode;
  }
}
