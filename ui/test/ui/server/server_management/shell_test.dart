import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '_support/server_management_harness.dart';

/// Server Management shell and navigation.
///
/// One of nine files T-3.6.2 split `server_management_view_test.dart` into,
/// one per tab, mirroring `lib/ui/server/management/`.
void main() {
  ensureSqliteRuntimeAvailable();

  testWidgets('ServerManagementView renders header and tabs', (
    WidgetTester tester,
  ) async {
    await pumpServerManagement(tester, server: server);

    expect(find.byKey(const Key('server-management-nav-overview')), findsOne);
    expect(find.byKey(const Key('server-management-nav-services')), findsOne);
    expect(find.byKey(const Key('server-management-nav-updates')), findsOne);
    expect(find.byKey(const Key('server-management-nav-security')), findsOne);
    expect(find.byKey(const Key('server-management-nav-settings')), findsOne);
  });

  testWidgets('ServerManagementView switches tabs', (
    WidgetTester tester,
  ) async {
    final titles = <String>[];
    debugOverrideAppWindowTitleSetter((title) async => titles.add(title));
    addTearDown(() => debugOverrideAppWindowTitleSetter(null));
    await pumpServerManagement(tester, server: server);
    expect(titles.last, 'Deploy Dash - Server management - Overview');

    await tester.tap(find.widgetWithText(Tab, 'Services'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('server-management-services-tab')), findsOne);
    expect(titles.last, 'Deploy Dash - Server management - Services');

    await tester.tap(find.widgetWithText(Tab, 'Updates'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('server-management-updates-tab')), findsOne);

    await tester.tap(find.widgetWithText(Tab, 'Security'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('server-management-firewall-tab')), findsOne);

    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('server-management-system-tab')), findsOne);
    expect(titles.last, 'Deploy Dash - Server management - Settings');
  });

  testWidgets(
    'ServerManagementView reports a contextual destination selection',
    (WidgetTester tester) async {
      final selectedIndexes = <int>[];
      await pumpServerManagement(
        tester,
        server: server,
        onDestinationSelected: selectedIndexes.add,
      );

      await tester.tap(find.byKey(const Key('server-management-nav-services')));
      await tester.pumpAndSettle();

      expect(selectedIndexes, [1]);
    },
  );

  testWidgets('ServerManagementView respects initialTabIndex', (
    WidgetTester tester,
  ) async {
    await pumpServerManagement(tester, server: server, initialTabIndex: 1);

    expect(find.byKey(const Key('server-management-services-tab')), findsOne);
    expect(
      find.byKey(const Key('server-management-overview-tab')),
      findsNothing,
    );
  });

  testWidgets('ServerManagementView replaces tabs with the incomplete card', (
    WidgetTester tester,
  ) async {
    var retried = false;
    await pumpServerManagement(
      tester,
      server: server,
      isSetupPending: true,
      onRetrySetup: () => retried = true,
    );

    expect(find.text('Finish setting up Prod-01'), findsOneWidget);
    expect(
      find.byKey(const Key('server-management-nav-overview')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('server-management-retry-setup-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('server-management-remove-server-button')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('server-management-retry-setup-button')),
    );
    expect(retried, isTrue);
  });

  testWidgets('ServerManagementView incomplete card removes after confirm', (
    WidgetTester tester,
  ) async {
    var removed = 0;
    await pumpServerManagement(
      tester,
      server: server,
      isSetupPending: true,
      onRemoveServer: () async => removed += 1,
    );

    await tester.tap(
      find.byKey(const Key('server-management-remove-server-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Remove this server?'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('setup-incomplete-remove-confirm-button')),
    );
    await tester.pumpAndSettle();

    expect(removed, 1);
  });

  testWidgets('ServerManagementView incomplete card keeps on cancel', (
    WidgetTester tester,
  ) async {
    var removed = 0;
    await pumpServerManagement(
      tester,
      server: server,
      isSetupPending: true,
      onRemoveServer: () async => removed += 1,
    );

    await tester.tap(
      find.byKey(const Key('server-management-remove-server-button')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(removed, 0);
    expect(find.text('Finish setting up Prod-01'), findsOneWidget);
  });

  testWidgets('ServerManagementView incomplete card ignores remove unhandled', (
    WidgetTester tester,
  ) async {
    await pumpServerManagement(tester, server: server, isSetupPending: true);

    await tester.tap(
      find.byKey(const Key('server-management-remove-server-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Remove this server?'), findsNothing);
  });

  testWidgets('ServerManagementView incomplete card spins while removing', (
    WidgetTester tester,
  ) async {
    final removeGate = Completer<void>();
    await pumpServerManagement(
      tester,
      server: server,
      isSetupPending: true,
      onRemoveServer: () => removeGate.future,
    );

    await tester.tap(
      find.byKey(const Key('server-management-remove-server-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('setup-incomplete-remove-confirm-button')),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    removeGate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
