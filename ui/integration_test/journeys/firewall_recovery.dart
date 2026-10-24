part of '../e2e_checklist_test.dart';

Future<void> _runFirewallRecoveryScenario(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  binding.shouldPropagateDevicePointerEvents = false;
  await _ensurePostgresServiceEnabled(tester);

  await _waitForEnabledButton(
    tester,
    const Key('service-enable-postgres-remote-access'),
    description: 'temporary PostgreSQL access action',
    timeout: const Duration(minutes: 2),
  );
  await _tap(tester, const Key('service-enable-postgres-remote-access'));
  await _waitForEnabledButton(
    tester,
    const Key('service-close-postgres-remote-access'),
    description: 'open temporary PostgreSQL access',
    timeout: const Duration(minutes: 3),
  );
  await _runRequiredVmScript(
    "iptables -S DEPLOYDASH-INPUT | grep -- '--dport 5432'",
    description: 'temporary PostgreSQL firewall access',
    sudo: true,
  );
  await _tap(tester, const Key('service-close-postgres-remote-access'));
  await _waitForEnabledButton(
    tester,
    const Key('service-enable-postgres-remote-access'),
    description: 'closed temporary PostgreSQL access',
    timeout: const Duration(minutes: 3),
  );
  _pass(
    'Server Management::PostgreSQL temporary remote access',
    'Opened and closed the one-hour PostgreSQL firewall exception through Services.',
  );

  await _tap(tester, const Key('server-management-nav-security'));
  await _waitFor(
    tester,
    find.byKey(const Key('server-management-firewall-tab')),
    description: 'firewall workspace',
    timeout: const Duration(minutes: 2),
  );
  await _addFirewallRule(
    tester,
    protocol: 'tcp',
    port: 18080,
    source: '127.0.0.1/32',
    description: 'E2E TCP committed',
  );
  await _addFirewallRule(
    tester,
    protocol: 'udp',
    port: 18081,
    source: '127.0.0.1/32',
    description: 'E2E UDP committed',
  );
  await _addFirewallRule(
    tester,
    protocol: 'tcp',
    port: 18082,
    source: '::1/128',
    description: 'E2E IPv6 committed',
  );
  await _scrollFirewallToTop(tester);
  await _tap(tester, const Key('firewall-apply-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('firewall-staged-port-summary')),
    description: 'staged firewall rules',
    timeout: const Duration(minutes: 3),
  );
  await _waitForEnabledButton(
    tester,
    const Key('firewall-commit-button'),
    description: 'firewall commit action',
    timeout: const Duration(minutes: 3),
  );
  await _verifyFirewallPort(port: 18080, protocol: 'tcp');
  await _verifyFirewallPort(port: 18081, protocol: 'udp');
  await _verifyFirewallPort(port: 18082, protocol: 'tcp', ipv6: true);
  await _tap(tester, const Key('firewall-commit-button'));
  await _waitForAbsent(
    tester,
    find.byKey(const Key('firewall-staged-port-summary')),
    description: 'committed firewall rules',
    timeout: const Duration(minutes: 3),
  );
  await _verifyFirewallPort(port: 18080, protocol: 'tcp');
  await _verifyFirewallPort(port: 18081, protocol: 'udp');
  await _verifyFirewallPort(port: 18082, protocol: 'tcp', ipv6: true);
  _pass(
    'Server Management::Firewall staged apply/commit',
    'Staged and committed firewall changes while retaining the SSH session.',
  );
  _pass(
    'Server Management::Firewall custom TCP/UDP/IPv6 rules',
    'Verified committed TCP, UDP, and IPv6 rules in the managed firewall chains.',
  );
  await _verifyIcmpPreamble();
  await _verifyIpv6Traffic();

  await _addFirewallRule(
    tester,
    protocol: 'tcp',
    port: 18083,
    source: '127.0.0.1/32',
    description: 'E2E explicit rollback',
  );
  await _scrollFirewallToTop(tester);
  await _tap(tester, const Key('firewall-apply-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('firewall-staged-port-summary')),
    description: 'firewall rollback stage',
    timeout: const Duration(minutes: 3),
  );
  await _waitForEnabledButton(
    tester,
    const Key('firewall-rollback-button'),
    description: 'firewall rollback action',
    timeout: const Duration(minutes: 3),
  );
  await _verifyFirewallPort(port: 18083, protocol: 'tcp');
  await _tap(tester, const Key('firewall-rollback-button'));
  await _waitForAbsent(
    tester,
    find.byKey(const Key('firewall-staged-port-summary')),
    description: 'explicit firewall rollback',
    timeout: const Duration(minutes: 3),
  );
  await _verifyFirewallPort(port: 18083, protocol: 'tcp', present: false);

  await _scrollUntilMounted(
    tester,
    find.byKey(const Key('firewall-rollback-timeout-field')),
    within: find.byKey(const Key('server-management-firewall-tab')),
    description: 'firewall rollback timeout',
  );
  await _tap(tester, const Key('firewall-rollback-timeout-field'));
  await _tapFinder(
    tester,
    find.text('60').last,
    description: '60 second rollback timeout',
  );
  await _addFirewallRule(
    tester,
    protocol: 'tcp',
    port: 18084,
    source: '127.0.0.1/32',
    description: 'E2E timed rollback',
  );
  await _scrollFirewallToTop(tester);
  await _tap(tester, const Key('firewall-apply-button'));
  await _waitFor(
    tester,
    find.byKey(const Key('firewall-staged-port-summary')),
    description: 'timed firewall rollback stage',
    timeout: const Duration(minutes: 3),
  );
  await _waitForEnabledButton(
    tester,
    const Key('firewall-rollback-button'),
    description: 'timed firewall rollback stage readiness',
    timeout: const Duration(minutes: 3),
  );
  await _verifyFirewallPort(port: 18084, protocol: 'tcp');
  await Future<void>.delayed(const Duration(seconds: 70));
  await _tap(tester, const Key('firewall-refresh-button'));
  await _waitForAbsent(
    tester,
    find.byKey(const Key('firewall-staged-port-summary')),
    description: 'automatic firewall rollback',
    timeout: const Duration(minutes: 2),
  );
  await _verifyFirewallPort(port: 18084, protocol: 'tcp', present: false);
  _pass(
    'Server Management::Firewall rollback',
    'Verified both explicit rollback and server-side automatic timeout rollback.',
  );
}

Future<void> _addFirewallRule(
  WidgetTester tester, {
  required String protocol,
  required int port,
  required String source,
  required String description,
}) async {
  await _scrollUntilMounted(
    tester,
    find.byKey(const Key('firewall-add-custom-rule')),
    within: find.byKey(const Key('server-management-firewall-tab')),
    description: 'add custom firewall rule',
  );
  await _tap(tester, const Key('firewall-add-custom-rule'));
  await _waitFor(
    tester,
    find.byKey(const Key('firewall-custom-rule-dialog')),
    description: 'custom firewall rule dialog',
  );
  if (protocol == 'udp') {
    await _tap(tester, const Key('firewall-custom-protocol-field'));
    await _tapFinder(
      tester,
      find.text('UDP').last,
      description: 'UDP protocol',
    );
  }
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('firewall-custom-port-start-field')),
    '$port',
    description: 'firewall port start',
  );
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('firewall-custom-port-end-field')),
    '$port',
    description: 'firewall port end',
  );
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('firewall-custom-source-field')),
    source,
    description: 'firewall source',
  );
  await _enterAndVerifyText(
    tester,
    find.byKey(const Key('firewall-custom-description-field')),
    description,
    description: 'firewall description',
  );
  await _tap(tester, const Key('firewall-custom-save-button'));
  await _waitFor(tester, find.text(description), description: description);
}

Future<void> _scrollFirewallToTop(WidgetTester tester) async {
  final firewallTab = find.byKey(const Key('server-management-firewall-tab'));
  final scrollable = find
      .descendant(of: firewallTab, matching: find.byType(Scrollable))
      .first;
  await _waitFor(tester, scrollable, description: 'firewall scrollable');
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
}

/// Verifies the fixed ICMP preamble is live in both managed INPUT chains.
///
/// The preamble is what keeps IPv6 neighbor discovery and ping working
/// behind the strict fallback DROP; a committed stage that lost it must fail
/// here rather than ship. Each rule replays through `iptables -C`, which
/// compares parsed rules instead of `-S` text (`-S` normalizes `-p icmpv6`
/// to `-p ipv6-icmp` and `--icmp-type echo-request` to `--icmp-type 8`, so
/// grepping staged text would fail on a correct chain).
Future<void> _verifyIcmpPreamble() async {
  const chains = <(String, String, List<String>)>[
    (
      'iptables',
      'DEPLOYDASH-INPUT',
      <String>['-p icmp --icmp-type echo-request -m limit --limit 30/minute'],
    ),
    (
      'ip6tables',
      'DEPLOYDASH6-INPUT',
      <String>[
        '-p icmpv6 --icmpv6-type 1',
        '-p icmpv6 --icmpv6-type 2',
        '-p icmpv6 --icmpv6-type 3',
        '-p icmpv6 --icmpv6-type 4',
        '-p icmpv6 --icmpv6-type 133 -m hl --hl-eq 255',
        '-p icmpv6 --icmpv6-type 134 -m hl --hl-eq 255',
        '-p icmpv6 --icmpv6-type 135 -m hl --hl-eq 255',
        '-p icmpv6 --icmpv6-type 136 -m hl --hl-eq 255',
        '-p icmpv6 --icmpv6-type 130 -s fe80::/10 -m hl --hl-eq 1',
        '-p icmpv6 --icmpv6-type 131 -s fe80::/10 -m hl --hl-eq 1',
        '-p icmpv6 --icmpv6-type 132 -s fe80::/10 -m hl --hl-eq 1',
        '-p icmpv6 --icmpv6-type 143 -s fe80::/10 -m hl --hl-eq 1',
        '-p icmpv6 --icmpv6-type 128 -m limit --limit 30/minute',
        '-p udp -s fe80::/10 --sport 547 --dport 546',
      ],
    ),
  ];
  for (final (binary, chain, matches) in chains) {
    for (final match in matches) {
      await _runRequiredVmScript(
        '$binary -w -C $chain $match -j ACCEPT',
        description: 'ICMP preamble $chain $match',
        sudo: true,
      );
    }
  }
}

/// Verifies IPv6 still flows after neighbor expiry behind strict filtering.
///
/// Flushes the neighbor cache and pings the default IPv6 gateway, forcing
/// fresh neighbor discovery through the managed chain. The runner then curls
/// a configured site over IPv6 from outside the server, so the scenario never
/// certifies IPv6 from an internal-only probe.
Future<void> _verifyIpv6Traffic() async {
  const script = r'''
set -eu
ROUTE="$(ip -6 route show default 2>/dev/null | head -n 1)"
GATEWAY="$(echo "$ROUTE" | awk '{print $3; exit}')"
GATEWAY_DEV="$(echo "$ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
if [ -z "$GATEWAY" ] || [ "$GATEWAY" = "dev" ] || [ -z "$GATEWAY_DEV" ]; then
  echo "E2E_SKIP_NO_IPV6_ROUTE"
  exit 0
fi
ip -6 neigh flush all
ping -6 -I "$GATEWAY_DEV" -c 3 -W 10 "$GATEWAY"
''';
  final result = await _runRequiredVmScript(
    script,
    description: 'IPv6 gateway traffic after neighbor flush',
    sudo: true,
  );
  if (result.stdout.toString().contains('E2E_SKIP_NO_IPV6_ROUTE')) {
    fail(
      'Firewall recovery requires a dual-stack E2E target; the server has no IPv6 default route.',
    );
  }

  const definedSiteUrl = String.fromEnvironment('DEPLOYDASH_E2E_IPV6_SITE_URL');
  final siteUrl = definedSiteUrl.trim().isNotEmpty
      ? definedSiteUrl.trim()
      : Platform.environment['DEPLOYDASH_E2E_IPV6_SITE_URL']?.trim() ?? '';
  if (siteUrl.isEmpty) {
    fail(
      'Set DEPLOYDASH_E2E_IPV6_SITE_URL to a served HTTPS site on the target so inbound IPv6 can be proved.',
    );
  }
  final curlResult = await Process.run(
    'curl',
    <String>[
      '--ipv6',
      '--fail',
      '--silent',
      '--show-error',
      '--max-time',
      '30',
      siteUrl,
    ],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  ).timeout(const Duration(seconds: 40));
  if (curlResult.exitCode != 0) {
    fail(
      'Inbound IPv6 request to $siteUrl failed.\n'
      'stdout:\n${curlResult.stdout}\n'
      'stderr:\n${curlResult.stderr}',
    );
  }
  _pass(
    'Server Management::Firewall ICMPv6 preamble and IPv6 traffic',
    'Preamble verified live; refreshed neighbor discovery, reached the IPv6 gateway, and curled the served site over inbound IPv6.',
  );
}

Future<void> _verifyFirewallPort({
  required int port,
  required String protocol,
  bool ipv6 = false,
  bool present = true,
}) async {
  final command = ipv6 ? 'ip6tables' : 'iptables';
  final script = present
      ? "$command -S ${ipv6 ? 'DEPLOYDASH6-INPUT' : 'DEPLOYDASH-INPUT'} | grep -- '--dport $port' | grep -F -- '-p $protocol'"
      : "! $command -S ${ipv6 ? 'DEPLOYDASH6-INPUT' : 'DEPLOYDASH-INPUT'} | grep -- '--dport $port' | grep -F -- '-p $protocol'";
  await _runRequiredVmScript(
    script,
    description:
        '${present ? 'present' : 'absent'} firewall rule $port/$protocol',
    sudo: true,
  );
}
