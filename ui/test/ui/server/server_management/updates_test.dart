import 'package:flutter_test/flutter_test.dart';

import '_support/server_management_harness.dart';

/// Server Management updates tab.
///
/// One of nine files T-3.6.2 split `server_management_view_test.dart` into,
/// one per tab, mirroring `lib/ui/server/management/`.
void main() {
  ensureSqliteRuntimeAvailable();

  testWidgets('Updates tab refreshes and updates Deploy Dash tooling', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService();
    addTearDown(sshService.dispose);
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    expect(find.byKey(const Key('server-management-updates-tab')), findsOne);
    expect(find.text('Railpack build system'), findsOneWidget);
    expect(find.text('Docker runtime'), findsOneWidget);
    expect(find.text('HTTP gateway'), findsOneWidget);
    expect(find.text('PostgreSQL database service'), findsOneWidget);
    expect(find.text('Update available'), findsAtLeastNWidgets(1));
    expect(find.text('Update Railpack build system'), findsOneWidget);
    expect(sshService.toolingStatusCalls, 1);

    await tester.tap(
      find.byKey(const Key('server-updates-capability-railpack_build_system')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Railpack CLI'), findsOneWidget);
    expect(find.textContaining('0.18.0'), findsOneWidget);

    await tapUpdatesButton(tester);
    expect(
      find.descendant(
        of: find.byKey(const Key('server-management-updates-tab')),
        matching: find.text('Updates'),
      ),
      findsNothing,
    );

    expect(sshService.toolingUpdateCalls, 1);
    expect(sshService.lastUpdateComponentIds, ['railpack_build_system']);
    expect(find.text('Server tooling updated successfully.'), findsOneWidget);
    expect(find.text('Railpack 0.29.0'), findsOneWidget);
    expect(find.text('Version current'), findsAtLeastNWidgets(1));
  });

  testWidgets(
    'Updates tab separates PostgreSQL version state from service health',
    (WidgetTester tester) async {
      final sshService = UpdatesWorkflowSshService()
        ..postgresServiceUnhealthy = true;
      addTearDown(sshService.dispose);
      await pumpServerManagement(
        tester,
        server: serverWithCredentials,
        initialTabIndex: 2,
        overrides: [sshServiceProvider.overrideWithValue(sshService)],
      );

      expect(find.text('PostgreSQL database service'), findsOneWidget);
      expect(find.text('Version current'), findsAtLeastNWidgets(1));
      expect(find.text('Service Unhealthy'), findsOneWidget);
      expect(find.byIcon(Icons.verified_outlined), findsAtLeastNWidgets(1));
      expect(find.byIcon(Icons.heart_broken_outlined), findsOneWidget);
    },
  );

  for (final entry in <String, IconData>{
    'stopped': Icons.stop_circle_outlined,
    'missing': Icons.remove_circle_outline,
    'not_configured': Icons.remove_circle_outline,
    'unknown': Icons.help_outline,
  }.entries) {
    testWidgets('Updates tab distinguishes ${entry.key} service status', (
      WidgetTester tester,
    ) async {
      final sshService = UpdatesWorkflowSshService()
        ..postgresServiceEffectiveStatus = entry.key;
      addTearDown(sshService.dispose);
      await pumpServerManagement(
        tester,
        server: serverWithCredentials,
        initialTabIndex: 2,
        overrides: [sshServiceProvider.overrideWithValue(sshService)],
      );

      expect(
        find.byIcon(entry.value),
        findsAtLeastNWidgets(1),
        reason: 'service status ${entry.key}',
      );
    });
  }

  testWidgets('Updates tab shows cached managed software while refreshing', (
    WidgetTester tester,
  ) async {
    final cachedServer = Server(
      id: serverWithCredentials.id,
      name: serverWithCredentials.name,
      host: serverWithCredentials.host,
      port: serverWithCredentials.port,
      sshUser: serverWithCredentials.sshUser,
      authMethod: serverWithCredentials.authMethod,
      osName: serverWithCredentials.osName,
      serviceDatabaseEnabled: serverWithCredentials.serviceDatabaseEnabled,
      serviceEmailEnabled: serverWithCredentials.serviceEmailEnabled,
      serviceDomainEnabled: serverWithCredentials.serviceDomainEnabled,
      managedSoftwareStatus: ServerManagedSoftwareStatus(
        const <String, Map<String, dynamic>>{
          'cached_component': <String, dynamic>{
            'id': 'cached_component',
            'category': 'Server maintenance',
            'label': 'Cached component',
            'description': 'Loaded from the local server cache.',
            'status': 'current',
            'summary': 'Cached component was checked earlier',
            'can_update': false,
            'can_rollback': false,
            'risk_level': 'low',
            'details': <Map<String, dynamic>>[],
          },
        },
      ),
    );
    final sshService = UpdatesWorkflowSshService()..statusMode = 'throw';
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: cachedServer,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    expect(find.text('Cached component'), findsOneWidget);
    expect(find.text('Cached component was checked earlier'), findsOneWidget);
    expect(find.text('Update failed'), findsOneWidget);
  });

  testWidgets('Updates tab supports legacy capability payloads', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService()
      ..statusMode = 'legacy_capabilities';
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    expect(find.text('Edge cache'), findsOneWidget);
    expect(find.text('Risk: Medium'), findsNothing);

    await tester.tap(
      find.byKey(const Key('server-updates-capability-edge_cache')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cache helper'), findsOneWidget);
    expect(find.text('Risk: Medium'), findsOneWidget);
  });

  testWidgets('Updates tab can update a single expanded capability row', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService();
    addTearDown(sshService.dispose);
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await tester.tap(
      find.byKey(const Key('server-updates-capability-railpack_build_system')),
    );
    await tester.pumpAndSettle();
    final updateButton = find.byKey(
      const Key('server-updates-update-railpack_build_system'),
    );
    await tester.ensureVisible(updateButton);
    await tester.pumpAndSettle();
    await tester.tap(updateButton);
    await tester.pumpAndSettle();

    expect(sshService.toolingUpdateCalls, 1);
    expect(sshService.lastUpdateComponentIds, ['railpack_build_system']);
    expect(find.text('Server tooling updated successfully.'), findsOneWidget);
  });

  testWidgets('Updates tab rolls back selected managed software', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService()..toolingCurrent = true;
    addTearDown(sshService.dispose);
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await tester.tap(
      find.byKey(const Key('server-updates-capability-http_gateway')),
    );
    await tester.pumpAndSettle();
    final rollbackButton = find.byKey(
      const Key('server-updates-rollback-http_gateway'),
    );
    await tester.ensureVisible(rollbackButton);
    await tester.pumpAndSettle();
    await tester.tap(rollbackButton);
    await tester.pumpAndSettle();

    expect(find.text('Rollback HTTP gateway?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Rollback'));
    await tester.pumpAndSettle();

    expect(sshService.toolingRollbackCalls, 1);
    expect(sshService.lastRollbackComponentId, 'http_gateway');
    expect(find.text('Managed server software rolled back.'), findsOneWidget);
  });

  testWidgets('Updates tab surfaces rollback failures in a dialog', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService()
      ..toolingCurrent = true
      ..rollbackMode = 'error';
    addTearDown(sshService.dispose);
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    Future<void> rollbackHttpGateway() async {
      final capability = find.byKey(
        const Key('server-updates-capability-http_gateway'),
      );
      await tester.ensureVisible(capability);
      await tester.pumpAndSettle();
      await tester.tap(capability);
      await tester.pumpAndSettle();
      final rollbackButton = find.byKey(
        const Key('server-updates-rollback-http_gateway'),
      );
      await tester.ensureVisible(rollbackButton);
      await tester.pumpAndSettle();
      await tester.tap(rollbackButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Rollback'));
      await tester.pumpAndSettle();
    }

    await rollbackHttpGateway();

    expect(find.text('Update failed'), findsOneWidget);
    expect(find.text('Could not rollback managed software.'), findsWidgets);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    sshService.rollbackMode = 'throw';
    await rollbackHttpGateway();

    expect(find.text('Update failed'), findsOneWidget);
    expect(
      find.textContaining('Failed to rollback managed software:'),
      findsWidgets,
    );
  });

  testWidgets('Updates tab confirms high-risk Docker rollback', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService()
      ..toolingCurrent = true
      ..riskyRollbacksAvailable = true;
    addTearDown(sshService.dispose);
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await tester.tap(
      find.byKey(const Key('server-updates-capability-docker_runtime')),
    );
    await tester.pumpAndSettle();
    final rollbackButton = find.byKey(
      const Key('server-updates-rollback-docker_runtime'),
    );
    await tester.ensureVisible(rollbackButton);
    await tester.pumpAndSettle();
    await tester.tap(rollbackButton);
    await tester.pumpAndSettle();

    expect(find.byType(AppDestructiveConfirmDialog), findsOneWidget);
    expect(find.text('Rollback Docker runtime?'), findsOneWidget);
    expect(
      find.textContaining(
        'Deploy Dash will restore the last recorded rollback snapshot',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Updates tab rolls back PostgreSQL without data loss', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService()
      ..toolingCurrent = true
      ..riskyRollbacksAvailable = true;
    addTearDown(sshService.dispose);
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await openPostgresRollbackChoice(tester);

    // The default choice keeps every row, so it must not read as
    // destructive: no destructive dialog, no data-loss warning.
    expect(find.byType(AppDestructiveConfirmDialog), findsNothing);
    expect(find.text('Rollback PostgreSQL database service?'), findsOneWidget);
    expect(
      find.textContaining('Your data stays exactly as it is.'),
      findsOneWidget,
    );
    expect(
      find.text('Restore data from the pre-update backup'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Roll back'));
    await tester.pumpAndSettle();

    expect(sshService.toolingRollbackCalls, 1);
    expect(sshService.lastRollbackComponentId, 'postgresql_database_service');
    expect(sshService.lastRollbackRestoreData, isFalse);
    expect(find.text('Managed server software rolled back.'), findsOneWidget);
  });

  testWidgets('Updates tab confirms PostgreSQL data restore as destructive', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService()
      ..toolingCurrent = true
      ..riskyRollbacksAvailable = true;
    addTearDown(sshService.dispose);
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await openPostgresRollbackChoice(tester);

    await tester.tap(find.text('Restore data from the pre-update backup'));
    await tester.pumpAndSettle();

    // The explicit data-restore choice replays the pre-update backup, so
    // it keeps the destructive treatment and its own confirmation.
    expect(find.byType(AppDestructiveConfirmDialog), findsOneWidget);
    expect(
      find.text('Restore data from the pre-update backup?'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Everything written since the update will be lost.'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Restore data'));
    await tester.pumpAndSettle();

    expect(sshService.toolingRollbackCalls, 1);
    expect(sshService.lastRollbackRestoreData, isTrue);
    expect(find.text('Managed server software rolled back.'), findsOneWidget);
  });

  testWidgets('Updates tab cancels PostgreSQL data restore cleanly', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService()
      ..toolingCurrent = true
      ..riskyRollbacksAvailable = true;
    addTearDown(sshService.dispose);
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await openPostgresRollbackChoice(tester);

    await tester.tap(find.text('Restore data from the pre-update backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(sshService.toolingRollbackCalls, 0);
    expect(find.byType(AppDestructiveConfirmDialog), findsNothing);
  });

  testWidgets('Updates tab cancels the PostgreSQL rollback choice cleanly', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService()
      ..toolingCurrent = true
      ..riskyRollbacksAvailable = true;
    addTearDown(sshService.dispose);
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await openPostgresRollbackChoice(tester);

    // The choice itself is not destructive: cancelling it must never have
    // shown the destructive dialog.
    expect(find.byType(AppDestructiveConfirmDialog), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(sshService.toolingRollbackCalls, 0);
    expect(find.text('Rollback PostgreSQL database service?'), findsNothing);
  });

  testWidgets('Updates tab reports missing server connection details', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService();
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    expect(find.text('No server selected.'), findsOneWidget);

    await pumpServerManagement(
      tester,
      server: server,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    expect(
      find.text(
        'This server is missing the saved SSH details needed to check updates.',
      ),
      findsOneWidget,
    );
    expect(sshService.toolingStatusCalls, 0);
  });

  testWidgets('Updates tab surfaces refresh failures in a dialog', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService()..statusMode = 'error';
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    expect(find.text('Update failed'), findsOneWidget);
    expect(find.text('Could not read update status.'), findsWidgets);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    sshService.statusMode = 'throw';
    await tester.tap(find.byKey(const Key('server-updates-refresh-tooling')));
    await tester.pumpAndSettle();

    expect(find.text('Update failed'), findsOneWidget);
    expect(
      find.textContaining('Failed to refresh update status:'),
      findsWidgets,
    );
  });

  testWidgets('Updates tab surfaces update failures in a dialog', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService()..updateMode = 'error';
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await tapUpdatesButton(tester);

    expect(find.text('Update failed'), findsOneWidget);
    expect(find.text('Could not update server tooling.'), findsWidgets);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    sshService.updateMode = 'throw';
    await tapUpdatesButton(tester);

    expect(find.text('Update failed'), findsOneWidget);
    expect(
      find.textContaining('Failed to update server tooling:'),
      findsWidgets,
    );
  });

  testWidgets('Updates tab refreshes after update responses without tooling', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService()..updateMode = 'no_tooling';
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    await tapUpdatesButton(tester);

    expect(sshService.toolingUpdateCalls, 1);
    expect(sshService.toolingStatusCalls, 2);
    expect(find.text('Server capabilities are up to date.'), findsOneWidget);
    expect(find.text('Railpack 0.29.0'), findsOneWidget);
  });

  testWidgets('Updates tab handles unknown tooling payloads and log events', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService()
      ..statusMode = 'invalid_payload'
      ..emitLogEvents = true;
    final terminalLines = <String>[];
    final terminalSources = <String>[];
    final terminalDetails = <bool>[];
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
      onTerminalLine: (line, {detail = false, source = '', taskType}) {
        terminalLines.add(line);
        terminalSources.add(source);
        terminalDetails.add(detail);
      },
    );

    await tester.tap(
      find.byKey(const Key('server-updates-capability-railpack_build_system')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Custom tool'), findsOneWidget);
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Current: Not installed'), findsAtLeastNWidgets(1));
    expect(
      find.text('Target: Managed by Deploy Dash'),
      findsAtLeastNWidgets(1),
    );

    sshService.statusMode = 'success';
    await tester.tap(find.byKey(const Key('server-updates-refresh-tooling')));
    await tester.pumpAndSettle();
    await tapUpdatesButton(tester);

    expect(terminalLines, contains('Writing Railpack helper.'));
    expect(terminalSources, contains('updates'));
    expect(terminalSources, contains('updates:server_tooling_update_started'));
    expect(terminalDetails, contains(true));
  });

  testWidgets('Updates tab falls back to capability descriptions', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService()
      ..statusMode = 'empty_summary';
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    expect(find.text('Runs app, gateway, and database containers.'), findsOne);
  });

  testWidgets('Updates tab resets status when the selected server changes', (
    WidgetTester tester,
  ) async {
    final sshService = UpdatesWorkflowSshService();
    addTearDown(sshService.dispose);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    expect(sshService.toolingStatusCalls, 1);

    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      initialTabIndex: 2,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    expect(sshService.toolingStatusCalls, 2);
    expect(find.text('Railpack build system'), findsOneWidget);
  });
}

/// Expands the PostgreSQL capability row and taps its rollback button,
/// leaving the rollback choice dialog open for the test to answer.
Future<void> openPostgresRollbackChoice(WidgetTester tester) async {
  final capability = find.byKey(
    const Key('server-updates-capability-postgresql_database_service'),
  );
  await tester.ensureVisible(capability);
  await tester.pumpAndSettle();
  await tester.tap(capability, warnIfMissed: false);
  await tester.pumpAndSettle();
  final rollbackButton = find.byKey(
    const Key('server-updates-rollback-postgresql_database_service'),
  );
  await tester.ensureVisible(rollbackButton);
  await tester.pumpAndSettle();
  await tester.tap(rollbackButton);
  await tester.pumpAndSettle();
}
