import 'package:flutter_test/flutter_test.dart';

import '_support/server_management_harness.dart';

/// Server Management overview tab.
///
/// One of nine files T-3.6.2 split `server_management_view_test.dart` into,
/// one per tab, mirroring `lib/ui/server/management/`.
void main() {
  ensureSqliteRuntimeAvailable();

  testWidgets('Overview tab shows no-server error', (
    WidgetTester tester,
  ) async {
    await pumpServerManagement(tester, server: null);
    expect(find.text('No server selected.'), findsOneWidget);
  });

  testWidgets('Overview tab shows incomplete-credentials error', (
    WidgetTester tester,
  ) async {
    await pumpServerManagement(tester, server: server);
    expect(
      find.text(
        'This server is missing SSH access details. Update the connection first.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Overview tab refreshes metrics via workflow', (
    WidgetTester tester,
  ) async {
    final sshService = OverviewMetricsSshService(
      succeedOverview: true,
      message: 'Metrics fetched from sysstat.',
    );
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    expect(sshService.overviewCalls, 1);
    expect(find.text('Refresh Metrics'), findsNothing);
    expect(find.text('Metrics fetched from sysstat.'), findsNothing);
    expect(find.byKey(const Key('overview-refresh-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('overview-refresh-button')));
    await tester.pumpAndSettle();
    expect(sshService.overviewCalls, 2);
    expect(find.byKey(const Key('overview-last-updated')), findsOneWidget);
    expect(find.textContaining('Last updated:'), findsOneWidget);
    expect(find.text('Uptime'), findsOneWidget);
    expect(find.text('1d 2h'), findsOneWidget);
    expect(find.text('Root storage'), findsOneWidget);
    expect(find.text('Primary interface'), findsOneWidget);
    expect(find.text('Oldest file: /var/log/sysstat/sa20260417'), findsNothing);
    final bootedAt = DateTime.parse('2026-04-17T12:56:16Z').toLocal();
    final bootedAtLabel =
        '${bootedAt.year}-${bootedAt.month.toString().padLeft(2, '0')}-${bootedAt.day.toString().padLeft(2, '0')} '
        '${bootedAt.hour.toString().padLeft(2, '0')}:${bootedAt.minute.toString().padLeft(2, '0')}:${bootedAt.second.toString().padLeft(2, '0')}';
    expect(find.text('Started $bootedAtLabel'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('server-management-overview-tab')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('All network interfaces'));
    await tester.pumpAndSettle();
    expect(find.text('eth0'), findsAtLeastNWidgets(1));
    expect(find.text('RX 12.5 kB/s'), findsOneWidget);
    expect(find.text('TX 8.0 kB/s'), findsOneWidget);

    await tester.drag(
      find.byKey(const Key('server-management-overview-tab')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('All storage devices'));
    await tester.pumpAndSettle();
    expect(find.text('nvme0n1'), findsAtLeastNWidgets(1));
    expect(
      find.text('Read 4.0 kB/s • Write 2.0 kB/s • Used 9.0%'),
      findsOneWidget,
    );

    await tester.drag(
      find.byKey(const Key('server-management-overview-tab')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Metric collection details'));
    await tester.pumpAndSettle();
    expect(
      find.text('Oldest file: /var/log/sysstat/sa20260417'),
      findsOneWidget,
    );
    expect(
      find.text('Newest file: /var/log/sysstat/sa20260418'),
      findsOneWidget,
    );
  });

  testWidgets('Overview tab shows workflow failure message', (
    WidgetTester tester,
  ) async {
    final sshService = OverviewMetricsSshService(
      succeedOverview: false,
      message: 'Failed collecting metrics.',
    );
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    expect(find.text('Failed collecting metrics.'), findsOneWidget);
  });

  testWidgets('Overview tab reports a refresh that threw', (
    WidgetTester tester,
  ) async {
    // The other half of the failure path. A workflow reporting an error
    // returns a response; the call itself blowing up does not, and that is
    // the only route to the tab's `catch`. Without this the user would see
    // the spinner forever, because `_isLoading` is cleared only there.
    final sshService = OverviewMetricsSshService(succeedOverview: true)
      ..overviewRaises = StateError('overview transport dropped');

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );

    // The message proves the catch ran: it is the only place this copy is
    // built with the error appended, and building it is what clears
    // `_isLoading`.
    expect(
      find.textContaining('Couldn’t load server activity.'),
      findsOneWidget,
    );
    expect(find.textContaining('overview transport dropped'), findsOneWidget);
  });

  testWidgets('Overview tab shows centered spinner before metrics load', (
    WidgetTester tester,
  ) async {
    final sshService = OverviewMetricsSshService(
      succeedOverview: true,
      overviewDelay: const Duration(milliseconds: 200),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sshServiceProvider.overrideWithValue(sshService),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            testServerConnectionPayload,
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ServerManagementView(server: serverWithCredentials),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('CPU'), findsNothing);
    expect(find.byKey(const Key('overview-refresh-button')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(find.text('CPU'), findsOneWidget);
    expect(find.byKey(const Key('overview-refresh-button')), findsOneWidget);
  });

  testWidgets('Overview tab refreshes when the selected server changes', (
    WidgetTester tester,
  ) async {
    final sshService = OverviewMetricsSshService(succeedOverview: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sshServiceProvider.overrideWithValue(sshService),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            testServerConnectionPayload,
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ServerManagementView(server: serverWithCredentials),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(sshService.overviewCalls, 1);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sshServiceProvider.overrideWithValue(sshService),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            testServerConnectionPayload,
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ServerManagementView(server: serverWithAlternateCredentials),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(sshService.overviewCalls, 2);
  });
}
