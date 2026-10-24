import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'desktop_route.dart';

typedef DesktopShellBuilder =
    Widget Function(BuildContext context, DesktopRoute route);

/// Builds the single persistent desktop shell around every workspace route.
///
/// `ShellRoute` deliberately owns the terminal and operation-stream lifecycle
/// once. Switching a workspace URL changes the route value delivered to the
/// shell without disposing that operational UI.
GoRouter buildDesktopRouter({required DesktopShellBuilder shellBuilder}) {
  Widget routeChild(BuildContext context, GoRouterState state) {
    return const SizedBox.shrink();
  }

  return GoRouter(
    initialLocation: const DesktopRoute.home().location,
    routes: [
      GoRoute(
        path: '/',
        redirect: (context, state) => const DesktopRoute.home().location,
      ),
      ShellRoute(
        builder: (context, state, child) {
          return Stack(
            children: [
              shellBuilder(context, DesktopRoute.fromUri(state.uri)),
              Offstage(offstage: true, child: child),
            ],
          );
        },
        routes: [
          GoRoute(path: '/home', builder: routeChild),
          GoRoute(path: '/projects/new', builder: routeChild),
          GoRoute(path: '/projects/:projectId', builder: routeChild),
          GoRoute(
            path: '/projects/:projectId/:destinationId',
            builder: routeChild,
          ),
          GoRoute(path: '/servers/onboarding', builder: routeChild),
          GoRoute(path: '/servers/manage', builder: routeChild),
          GoRoute(path: '/servers/manage/:tabId', builder: routeChild),
          GoRoute(path: '/settings', builder: routeChild),
          GoRoute(path: '/settings/:destinationId', builder: routeChild),
          GoRoute(path: '/unlock', builder: routeChild),
        ],
      ),
    ],
    errorBuilder: (context, state) {
      return shellBuilder(context, const DesktopRoute.home());
    },
  );
}
