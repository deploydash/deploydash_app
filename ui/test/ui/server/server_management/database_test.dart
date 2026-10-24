import 'package:flutter_test/flutter_test.dart';

import '_support/server_management_harness.dart';

/// Server Management database service.
///
/// One of nine files T-3.6.2 split `server_management_view_test.dart` into,
/// one per tab, mirroring `lib/ui/server/management/`.
void main() {
  ensureSqliteRuntimeAvailable();

  testWidgets('Database enable opens version picker modal first', (
    WidgetTester tester,
  ) async {
    await pumpServerManagement(tester, server: server, initialTabIndex: 1);

    await tester.tap(find.byKey(const Key('service-enable-database')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('service-config-dialog-database')), findsOne);
    expect(find.byKey(const Key('postgres-version-dropdown')), findsOneWidget);
    expect(find.text('17 (recommended default)'), findsOneWidget);
    // A fresh service has no live data, so the enable flow keeps the version
    // picker instead of the locked-version upgrade entry.
    expect(
      find.byKey(const Key('postgres-upgrade-major-button')),
      findsNothing,
    );
    final enableButton = find.descendant(
      of: find.byKey(const Key('service-config-dialog-database')),
      matching: find.widgetWithText(FilledButton, 'Enable'),
    );
    expect(enableButton, findsOneWidget);
    expect(
      tester.getTopLeft(enableButton).dy,
      lessThan(tester.view.physicalSize.height / tester.view.devicePixelRatio),
    );
    expect(find.byKey(const Key('postgres-advanced-options')), findsOneWidget);
    expect(find.text('pg_stat_statements'), findsNothing);
    expect(find.text('pgcrypto'), findsNothing);
    expect(find.text('pg_trgm'), findsNothing);
    expect(find.text('pgvector'), findsNothing);
    expect(find.text('pg_search'), findsNothing);
    expect(find.text('postgis'), findsNothing);
    expect(find.text('pg_session_jwt'), findsNothing);

    await tester.tap(find.byKey(const Key('postgres-advanced-options')));
    await tester.pumpAndSettle();

    expect(find.text('pg_stat_statements'), findsOneWidget);
    expect(find.text('pgcrypto'), findsOneWidget);
    expect(find.text('pg_trgm'), findsOneWidget);
    expect(find.text('pgvector'), findsOneWidget);
    expect(find.text('pg_search'), findsOneWidget);
    expect(find.text('postgis'), findsOneWidget);
    expect(find.text('pg_session_jwt'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('service-config-dialog-database')),
      findsNothing,
    );
  });

  testWidgets('Database enable persists capability before showing completion', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final credentialRepository = ServerCredentialRepository(database);
    final repository = ServerRepository(database, credentialRepository);
    final savedServer = await repository.createServer(
      draft: const ServerDraft(
        name: 'Lifecycle server',
        host: '203.0.113.30',
        port: 22,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.password,
        sshPassword: 'test-password',
      ),
      specs: const ServerSpecs(osName: 'Ubuntu 24.04 LTS'),
    );
    final sshService = DatabaseEnableSshService();
    addTearDown(sshService.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          sshServiceProvider.overrideWithValue(sshService),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ServerManagementView(server: savedServer, initialTabIndex: 1),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('service-enable-database')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('service-config-dialog-database')),
        matching: find.widgetWithText(FilledButton, 'Enable'),
      ),
    );
    await tester.pumpAndSettle();

    final persisted = (await repository.listServers()).single;
    expect(persisted.serviceDatabaseEnabled, isTrue);
    expect(find.text('Database service enabled.'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Database delete requires safety confirmation', (
    WidgetTester tester,
  ) async {
    await pumpServerManagement(
      tester,
      server: serverWithDatabaseEnabled,
      initialTabIndex: 1,
    );

    final servicesScrollable = find.descendant(
      of: find.byKey(const Key('server-management-services-tab')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('service-delete-database')),
      260,
      scrollable: servicesScrollable,
    );
    await tester.pumpAndSettle();

    final deleteButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('service-delete-database')),
    );
    deleteButton.onPressed?.call();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('service-delete-dialog-database')), findsOne);
    expect(find.byKey(const Key('service-delete-confirm-input')), findsOne);
    expect(find.byKey(const Key('service-delete-confirm-button')), findsOne);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('service-delete-dialog-database')),
      findsNothing,
    );
  });
}
