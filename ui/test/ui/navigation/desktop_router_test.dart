import 'package:ui/ui/navigation/desktop_route.dart';
import 'package:ui/ui/navigation/desktop_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'every typed destination is reachable inside one persistent shell',
    (tester) async {
      var shellInitializations = 0;
      final router = buildDesktopRouter(
        shellBuilder: (context, route) {
          return _RouteShellProbe(
            route: route,
            onInitialize: () => shellInitializations += 1,
          );
        },
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      expect(find.text('/home'), findsOneWidget);

      const destinations = <DesktopRoute>[
        DesktopRoute.createProject(),
        DesktopRoute.onboarding(),
        DesktopRoute.serverManagement(tab: DesktopServerManagementTab.security),
        DesktopRoute.appSettings(
          destination: DesktopAppSettingsDestination.agentAccess,
        ),
        DesktopRoute.unlock(),
      ];
      final project = DesktopRoute.project(
        projectId: 'project-1',
        destinationId: 'database',
      );

      for (final destination in [...destinations, project]) {
        router.go(destination.location);
        await tester.pumpAndSettle();
        expect(find.text(destination.location), findsOneWidget);
      }

      router.go('/');
      await tester.pumpAndSettle();
      expect(find.text('/home'), findsOneWidget);
      expect(shellInitializations, 1);

      router.go('/not-a-route');
      await tester.pumpAndSettle();
      expect(find.text('/home'), findsOneWidget);
      expect(shellInitializations, 2);
    },
  );
}

class _RouteShellProbe extends StatefulWidget {
  const _RouteShellProbe({required this.route, required this.onInitialize});

  final DesktopRoute route;
  final VoidCallback onInitialize;

  @override
  State<_RouteShellProbe> createState() => _RouteShellProbeState();
}

class _RouteShellProbeState extends State<_RouteShellProbe> {
  @override
  void initState() {
    super.initState();
    widget.onInitialize();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      child: Text(widget.route.location, textDirection: TextDirection.ltr),
    );
  }
}
