import 'package:flutter_test/flutter_test.dart';
import 'package:ui/services/app_analytics_service.dart';

import '../../../_support/fake_analytics_service.dart';
import '_support/server_management_harness.dart';

class _FirewallHookSshService extends FirewallWorkflowSshService {
  _FirewallHookSshService({
    this.applyResponse,
    this.commitResponse,
    this.rollbackResponse,
    this.throwOperationId,
    super.stagedPostgresAccess,
  });

  final Map<String, dynamic>? applyResponse;
  final Map<String, dynamic>? commitResponse;
  final Map<String, dynamic>? rollbackResponse;
  final String? throwOperationId;

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    if (operationId == throwOperationId) {
      throw StateError('ssh unavailable');
    }
    if (workflowId == 'firewall' && operationId == 'apply_staged') {
      return applyResponse ??
          const <String, dynamic>{
            'status': 'success',
            'msg': 'Staged firewall changes apply.',
          };
    }
    if (workflowId == 'firewall' && operationId == 'commit') {
      return commitResponse ??
          const <String, dynamic>{
            'status': 'success',
            'msg': 'Staged firewall changes committed.',
          };
    }
    if (workflowId == 'firewall' && operationId == 'rollback') {
      return rollbackResponse ??
          const <String, dynamic>{
            'status': 'success',
            'msg': 'Staged firewall rules rolled back.',
          };
    }
    return super.runWorkflowLegacy(
      workflowId: workflowId,
      operationId: operationId,
      connection: connection,
      params: params,
      onEvent: onEvent,
      onTaskStarted: onTaskStarted,
      serializePerHost: serializePerHost,
    );
  }
}

Future<void> _pumpFirewallWithAnalytics(
  WidgetTester tester, {
  required FakeAnalyticsService analytics,
  _FirewallHookSshService? sshService,
}) async {
  final service = sshService ?? _FirewallHookSshService();
  addTearDown(service.dispose);
  await pumpServerManagement(
    tester,
    server: serverWithCredentials,
    overrides: [
      sshServiceProvider.overrideWithValue(service),
      appAnalyticsServiceProvider.overrideWithValue(analytics),
    ],
  );
  await tester.tap(find.widgetWithText(Tab, 'Security'));
  await tester.pumpAndSettle();
}

Future<void> _stagePostgresRule(WidgetTester tester) async {
  final firewallScrollable = find
      .descendant(
        of: find.byKey(const Key('server-management-firewall-tab')),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(
    find.byKey(const Key('firewall-curated-postgres'), skipOffstage: false),
    320,
    scrollable: firewallScrollable,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('firewall-curated-postgres')));
  await tester.pumpAndSettle();
}

Future<void> _scrollToFirewallKey(WidgetTester tester, String key) async {
  final firewallScrollable = find
      .descendant(
        of: find.byKey(const Key('server-management-firewall-tab')),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(
    find.byKey(Key(key), skipOffstage: false),
    320,
    scrollable: firewallScrollable,
  );
  await tester.pumpAndSettle();
}

/// Server Management firewall tab.
///
/// One of nine files T-3.6.2 split `server_management_view_test.dart` into,
/// one per tab, mirroring `lib/ui/server/management/`.
void main() {
  ensureSqliteRuntimeAvailable();

  testWidgets('Firewall tab renders locked ports and custom controls', (
    WidgetTester tester,
  ) async {
    await pumpServerManagement(tester, server: server);
    await tester.tap(find.widgetWithText(Tab, 'Security'));
    await tester.pumpAndSettle();

    final firewallTab = find.byKey(const Key('server-management-firewall-tab'));
    expect(find.text('SSH port protection'), findsOneWidget);
    expect(find.text('Fail2ban service'), findsOneWidget);
    expect(
      find.descendant(
        of: firewallTab,
        matching: find.text('Locked required ports'),
      ),
      findsOneWidget,
    );
    await tester.drag(firewallTab, const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('firewall-add-custom-rule'), skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('Firewall tab shows dual-stack and persistence status', (
    WidgetTester tester,
  ) async {
    final sshService = FirewallWorkflowSshService(
      firewallEnabled: true,
      firewallIpv4Enabled: true,
      firewallIpv6Enabled: false,
      persistentRulesPresent: false,
      persistentRulesV4Present: true,
      persistentRulesV6Present: false,
      netfilterPersistentEnabled: true,
    );
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Security'));
    await tester.pumpAndSettle();

    expect(find.text('IPv4: Active'), findsOneWidget);
    expect(find.text('IPv6: Not active'), findsOneWidget);
    expect(find.text('Persistence: Missing'), findsOneWidget);
    expect(find.text('Restore on boot: Enabled'), findsOneWidget);
    expect(find.text('Starts on boot: Enabled'), findsOneWidget);
    expect(find.text('Current bans'), findsOneWidget);
    expect(find.text('Failed attempts'), findsOneWidget);
    expect(
      find.text('Saved rule files: IPv4 present, IPv6 missing.'),
      findsOneWidget,
    );
  });

  testWidgets('Firewall stages only changed settings and summarizes them', (
    WidgetTester tester,
  ) async {
    final sshService = FirewallWorkflowSshService();
    final catalogNotifier = FakeServerCatalogNotifier(
      ServerCatalogState(
        isLoading: false,
        onboardingComplete: true,
        servers: const [serverWithCredentials],
        selectedServerId: serverWithCredentials.id,
      ),
    );
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        serverCatalogProvider.overrideWith(() => catalogNotifier),
      ],
    );
    await tester.tap(find.widgetWithText(Tab, 'Security'));
    await tester.pumpAndSettle();

    var stageButton = tester.widget<FilledButton>(
      find.byKey(const Key('firewall-apply-button')),
    );
    expect(stageButton.onPressed, isNull);
    expect(
      find.byKey(const Key('firewall-no-pending-changes')),
      findsOneWidget,
    );

    final firewallScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-firewall-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('firewall-curated-postgres'), skipOffstage: false),
      320,
      scrollable: firewallScrollable,
    );
    await tester.ensureVisible(
      find.byKey(const Key('firewall-curated-postgres'), skipOffstage: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('firewall-curated-postgres'), skipOffstage: false),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('server-management-firewall-tab')),
      const Offset(0, 900),
    );
    await tester.pumpAndSettle();
    stageButton = tester.widget<FilledButton>(
      find.byKey(const Key('firewall-apply-button'), skipOffstage: false),
    );
    expect(stageButton.onPressed, isNotNull);

    await tester.tap(
      find.byKey(const Key('firewall-apply-button'), skipOffstage: false),
    );
    await tester.pumpAndSettle();

    expect(sshService.firewallApplyCalls, 1);
    expect(
      find.byKey(const Key('firewall-staged-port-summary')),
      findsOneWidget,
    );
    expect(find.textContaining('5432/tcp (PostgreSQL)'), findsOneWidget);
    expect(find.textContaining('unless you commit'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('firewall-apply-button')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('Firewall compact listener cards retain exposure details', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(760, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sshService = FirewallWorkflowSshService(
      openPorts: const <Map<String, dynamic>>[
        <String, dynamic>{
          'source': 'docker_published',
          'bind': '0.0.0.0',
          'protocol': 'tcp',
          'port': '5432',
          'details': 'deploydash_postgres',
        },
        <String, dynamic>{
          'source': 'host_listener',
          'bind': '::',
          'protocol': 'tcp',
          'port': '5432',
          'details': 'postgres',
        },
      ],
    );
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Security'));
    await tester.pumpAndSettle();
    final firewallScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-firewall-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('firewall-open-port-cards'), skipOffstage: false),
      500,
      scrollable: firewallScrollable,
    );
    await tester.pumpAndSettle();

    expect(find.text('5432/TCP'), findsOneWidget);
    expect(find.text('Public'), findsOneWidget);
    expect(find.textContaining('Address: 0.0.0.0, ::'), findsOneWidget);
    expect(
      find.textContaining('Source: docker_published, host_listener'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Owner: deploydash_postgres, postgres'),
      findsOneWidget,
    );
    expect(find.text('2 equivalent listeners grouped'), findsOneWidget);
  });

  testWidgets('Firewall tab resets status when the server changes', (
    WidgetTester tester,
  ) async {
    final firstSshService = FirewallWorkflowSshService(
      firewallEnabled: true,
      firewallIpv4Enabled: true,
      firewallIpv6Enabled: false,
      persistentRulesPresent: false,
      persistentRulesV4Present: true,
      persistentRulesV6Present: false,
      netfilterPersistentEnabled: true,
    );
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(firstSshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Security'));
    await tester.pumpAndSettle();

    expect(find.text('IPv6: Not active'), findsOneWidget);
    expect(find.text('Persistence: Missing'), findsOneWidget);

    final secondSshService = FirewallWorkflowSshService(
      firewallEnabled: true,
      firewallIpv4Enabled: true,
      firewallIpv6Enabled: true,
      persistentRulesPresent: true,
      persistentRulesV4Present: true,
      persistentRulesV6Present: true,
      netfilterPersistentEnabled: false,
      fail2banActive: true,
      fail2banEnabled: true,
      fail2banSshdJailActive: true,
      fail2banCurrentlyBanned: 2,
      fail2banTotalFailed: 17,
    );
    await pumpServerManagement(
      tester,
      server: serverWithCredentialsAndDatabaseEnabled,
      overrides: [sshServiceProvider.overrideWithValue(secondSshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Security'));
    await tester.pumpAndSettle();

    expect(find.text('IPv6: Active'), findsOneWidget);
    expect(find.text('Restore on boot: Disabled'), findsOneWidget);
  });

  testWidgets('Firewall custom rule dialog accepts IPv6 CIDR', (
    WidgetTester tester,
  ) async {
    final sshService = FirewallWorkflowSshService();
    final catalogNotifier = FakeServerCatalogNotifier(
      ServerCatalogState(
        isLoading: false,
        onboardingComplete: true,
        servers: const [serverWithCredentials],
        selectedServerId: serverWithCredentials.id,
      ),
    );
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        serverCatalogProvider.overrideWith(() => catalogNotifier),
      ],
    );
    await tester.tap(find.widgetWithText(Tab, 'Security'));
    await tester.pumpAndSettle();

    final firewallScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-firewall-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('firewall-add-custom-rule'), skipOffstage: false),
      260,
      scrollable: firewallScrollable,
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('firewall-add-custom-rule'), skipOffstage: false),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Port start'),
      '9443',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Port end'), '9443');
    await tester.enterText(
      find.widgetWithText(TextField, 'Source CIDR (optional)'),
      '2001:db8::/64',
    );

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Save'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('2001:db8::/64'), findsOneWidget);
  });

  testWidgets('Firewall custom rule dialog rejects invalid IPv6 CIDR', (
    WidgetTester tester,
  ) async {
    final sshService = FirewallWorkflowSshService();
    final catalogNotifier = FakeServerCatalogNotifier(
      ServerCatalogState(
        isLoading: false,
        onboardingComplete: true,
        servers: const [serverWithCredentials],
        selectedServerId: serverWithCredentials.id,
      ),
    );
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        serverCatalogProvider.overrideWith(() => catalogNotifier),
      ],
    );
    await tester.tap(find.widgetWithText(Tab, 'Security'));
    await tester.pumpAndSettle();

    final firewallScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-firewall-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('firewall-add-custom-rule'), skipOffstage: false),
      260,
      scrollable: firewallScrollable,
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('firewall-add-custom-rule'), skipOffstage: false),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Port start'),
      '9443',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Port end'), '9443');
    await tester.enterText(
      find.widgetWithText(TextField, 'Source CIDR (optional)'),
      '2001:db8::/129',
    );

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Save'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text('Source CIDR must be a valid IPv4 or IPv6 CIDR block.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'Firewall custom rule dialog saves UDP rules as disabled when toggled off',
    (WidgetTester tester) async {
      final sshService = FirewallWorkflowSshService();
      final catalogNotifier = FakeServerCatalogNotifier(
        ServerCatalogState(
          isLoading: false,
          onboardingComplete: true,
          servers: const [serverWithCredentials],
          selectedServerId: serverWithCredentials.id,
        ),
      );
      await pumpServerManagement(
        tester,
        server: serverWithCredentials,
        overrides: [
          sshServiceProvider.overrideWithValue(sshService),
          serverCatalogProvider.overrideWith(() => catalogNotifier),
        ],
      );
      await tester.tap(find.widgetWithText(Tab, 'Security'));
      await tester.pumpAndSettle();

      final firewallScrollable = find
          .descendant(
            of: find.byKey(const Key('server-management-firewall-tab')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('firewall-add-custom-rule'), skipOffstage: false),
        260,
        scrollable: firewallScrollable,
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('firewall-add-custom-rule'), skipOffstage: false),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('TCP').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('UDP').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Port start'),
        '53',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Port end'), '53');
      await tester.enterText(
        find.widgetWithText(TextField, 'Description (optional)'),
        'DNS over UDP',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Save'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('UDP'), findsOneWidget);
      expect(find.text('DNS over UDP'), findsOneWidget);
      expect(find.text('Disabled'), findsOneWidget);
    },
  );

  testWidgets('Firewall applies report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpFirewallWithAnalytics(tester, analytics: analytics);
    await _stagePostgresRule(tester);

    await _scrollToFirewallKey(tester, 'firewall-apply-button');
    await tester.tap(find.byKey(const Key('firewall-apply-button')));
    await tester.pumpAndSettle();

    expect(analytics.firewallEvents, [
      (action: FirewallAction.apply, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Firewall apply failures report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpFirewallWithAnalytics(
      tester,
      analytics: analytics,
      sshService: _FirewallHookSshService(
        applyResponse: const <String, dynamic>{
          'status': 'error',
          'msg': 'Firewall engine exploded.',
        },
      ),
    );
    await _stagePostgresRule(tester);

    await _scrollToFirewallKey(tester, 'firewall-apply-button');
    await tester.tap(find.byKey(const Key('firewall-apply-button')));
    await tester.pumpAndSettle();

    expect(find.text('Firewall engine exploded.'), findsOneWidget);
    expect(analytics.firewallEvents, [
      (action: FirewallAction.apply, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Firewall apply throws report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpFirewallWithAnalytics(
      tester,
      analytics: analytics,
      sshService: _FirewallHookSshService(throwOperationId: 'apply_staged'),
    );
    await _stagePostgresRule(tester);

    await _scrollToFirewallKey(tester, 'firewall-apply-button');
    await tester.tap(find.byKey(const Key('firewall-apply-button')));
    await tester.pumpAndSettle();

    expect(analytics.firewallEvents, [
      (action: FirewallAction.apply, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Firewall commits report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpFirewallWithAnalytics(
      tester,
      analytics: analytics,
      sshService: _FirewallHookSshService(stagedPostgresAccess: true),
    );

    await _scrollToFirewallKey(tester, 'firewall-commit-button');
    await tester.tap(find.byKey(const Key('firewall-commit-button')));
    await tester.pumpAndSettle();

    expect(analytics.firewallEvents, [
      (action: FirewallAction.commit, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Firewall commit failures report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpFirewallWithAnalytics(
      tester,
      analytics: analytics,
      sshService: _FirewallHookSshService(
        stagedPostgresAccess: true,
        commitResponse: const <String, dynamic>{
          'status': 'error',
          'msg': 'Firewall engine exploded.',
        },
      ),
    );

    await _scrollToFirewallKey(tester, 'firewall-commit-button');
    await tester.tap(find.byKey(const Key('firewall-commit-button')));
    await tester.pumpAndSettle();

    expect(find.text('Firewall engine exploded.'), findsOneWidget);
    expect(analytics.firewallEvents, [
      (action: FirewallAction.commit, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Firewall commit throws report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpFirewallWithAnalytics(
      tester,
      analytics: analytics,
      sshService: _FirewallHookSshService(
        stagedPostgresAccess: true,
        throwOperationId: 'commit',
      ),
    );

    await _scrollToFirewallKey(tester, 'firewall-commit-button');
    await tester.tap(find.byKey(const Key('firewall-commit-button')));
    await tester.pumpAndSettle();

    expect(analytics.firewallEvents, [
      (action: FirewallAction.commit, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Firewall rollbacks report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpFirewallWithAnalytics(
      tester,
      analytics: analytics,
      sshService: _FirewallHookSshService(stagedPostgresAccess: true),
    );

    await _scrollToFirewallKey(tester, 'firewall-rollback-button');
    await tester.tap(find.byKey(const Key('firewall-rollback-button')));
    await tester.pumpAndSettle();

    expect(analytics.firewallEvents, [
      (action: FirewallAction.rollback, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Firewall rollback failures report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpFirewallWithAnalytics(
      tester,
      analytics: analytics,
      sshService: _FirewallHookSshService(
        stagedPostgresAccess: true,
        rollbackResponse: const <String, dynamic>{
          'status': 'error',
          'msg': 'Firewall engine exploded.',
        },
      ),
    );

    await _scrollToFirewallKey(tester, 'firewall-rollback-button');
    await tester.tap(find.byKey(const Key('firewall-rollback-button')));
    await tester.pumpAndSettle();

    expect(find.text('Firewall engine exploded.'), findsOneWidget);
    expect(analytics.firewallEvents, [
      (action: FirewallAction.rollback, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Firewall rollback throws report the firewall event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpFirewallWithAnalytics(
      tester,
      analytics: analytics,
      sshService: _FirewallHookSshService(
        stagedPostgresAccess: true,
        throwOperationId: 'rollback',
      ),
    );

    await _scrollToFirewallKey(tester, 'firewall-rollback-button');
    await tester.tap(find.byKey(const Key('firewall-rollback-button')));
    await tester.pumpAndSettle();

    expect(analytics.firewallEvents, [
      (action: FirewallAction.rollback, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Firewall custom rule dialog cancel pops null silently', (
    WidgetTester tester,
  ) async {
    // D-70 (T-012): Cancel pops with NO argument (null, not false), so even
    // invalid input dismisses silently instead of surfacing a validation
    // message the way Save would.
    final sshService = FirewallWorkflowSshService();
    final catalogNotifier = FakeServerCatalogNotifier(
      ServerCatalogState(
        isLoading: false,
        onboardingComplete: true,
        servers: const [serverWithCredentials],
        selectedServerId: serverWithCredentials.id,
      ),
    );
    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [
        sshServiceProvider.overrideWithValue(sshService),
        serverCatalogProvider.overrideWith(() => catalogNotifier),
      ],
    );
    await tester.tap(find.widgetWithText(Tab, 'Security'));
    await tester.pumpAndSettle();

    await _scrollToFirewallKey(tester, 'firewall-add-custom-rule');
    await tester.tap(
      find.byKey(const Key('firewall-add-custom-rule'), skipOffstage: false),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Port start'),
      'not-a-port',
    );
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, 'Cancel'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('not-a-port'), findsNothing);
  });
}
