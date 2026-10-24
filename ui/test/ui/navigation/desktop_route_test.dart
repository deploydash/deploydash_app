import 'package:ui/ui/navigation/desktop_route.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('project route normalizes a contextual destination and round-trips', () {
    final route = DesktopRoute.project(
      projectId: 'project one',
      destinationId: 'not-a-destination',
    );

    expect(route.location, '/projects/project%20one/web-app');
    expect(DesktopRoute.fromUri(Uri.parse(route.location)), route);
  });

  test(
    'server management and settings routes use their typed destinations',
    () {
      const server = DesktopRoute.serverManagement(
        tab: DesktopServerManagementTab.security,
      );
      const settings = DesktopRoute.appSettings(
        destination: DesktopAppSettingsDestination.agentAccess,
      );

      expect(server.location, '/servers/manage/security');
      expect(DesktopRoute.fromUri(Uri.parse(server.location)), server);
      expect(settings.location, '/settings/agent-access');
      expect(DesktopRoute.fromUri(Uri.parse(settings.location)), settings);
    },
  );

  test('route enums cover every stable destination id and safe fallback', () {
    expect(DesktopServerManagementTab.values.map((tab) => tab.id), [
      'overview',
      'services',
      'updates',
      'security',
      'settings',
    ]);
    expect(
      DesktopAppSettingsDestination.values.map((destination) => destination.id),
      [
        'appearance',
        'updates',
        'agent-access',
        'app-backup',
        'security',
        'privacy',
      ],
    );
    expect(
      DesktopServerManagementTab.fromId('missing'),
      DesktopServerManagementTab.overview,
    );
    expect(
      DesktopAppSettingsDestination.fromId('missing'),
      DesktopAppSettingsDestination.appearance,
    );
  });

  test('route defaults cover bare contextual paths and value hashing', () {
    final project = DesktopRoute.fromUri(Uri.parse('/projects/project-1'));

    expect(project.projectDestinationTabIndex, 0);
    expect(const DesktopRoute.home().projectDestinationTabIndex, 0);
    expect(
      DesktopRoute.fromUri(Uri.parse('/servers/manage')),
      const DesktopRoute.serverManagement(),
    );
    expect(
      DesktopRoute.fromUri(Uri.parse('/settings')),
      const DesktopRoute.appSettings(),
    );
    expect(
      const DesktopRoute.serverManagement().serverManagementTabIndex,
      DesktopServerManagementTab.overview.index,
    );
    expect(
      const DesktopRoute.appSettings().appSettingsDestinationId,
      DesktopAppSettingsDestination.appearance.id,
    );
    expect({const DesktopRoute.home()}, contains(const DesktopRoute.home()));
  });

  test('unknown locations fall back to the home route', () {
    expect(
      DesktopRoute.fromUri(Uri.parse('/not-a-route')),
      const DesktopRoute.home(),
    );
  });
}
