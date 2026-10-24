import 'package:ui/data/local/server_repository.dart';
import 'package:ui/ui/server/management/firewall_tab_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buildFirewallSettings forces strict mode and locked ports', () {
    const config = ServerFirewallConfig(
      strictMode: false,
      allowPostgres: true,
      allowDns: true,
      rollbackTimeoutSeconds: 120,
    );

    expect(buildFirewallSettings(config, sshPort: 2200), {
      'strict_mode': true,
      'allow_postgres': true,
      'allow_dns': true,
      'allow_smtp': false,
      'allow_mail_receive': false,
      'rollback_timeout_seconds': 120,
      'custom_rules': const <dynamic>[],
      'locked_ports': [22, 80, 443, 2200],
    });
  });

  test('lockedPortsForSshPort validates and sorts', () {
    expect(lockedPortsForSshPort(22), [22, 80, 443]);
    expect(lockedPortsForSshPort(2200), [22, 80, 443, 2200]);
    expect(lockedPortsForSshPort(70000), [22, 80, 443]);
  });

  test('config helpers keep strict mode enabled', () {
    final current = ServerFirewallConfig(
      strictMode: false,
      allowPostgres: false,
      allowDns: false,
      allowSmtp: true,
      allowMailReceive: true,
      rollbackTimeoutSeconds: 90,
      customRules: const [
        ServerFirewallCustomRule(
          id: 'a',
          protocol: 'tcp',
          portStart: 80,
          portEnd: 80,
        ),
      ],
    );
    const replacement = ServerFirewallCustomRule(
      id: 'b',
      protocol: 'udp',
      portStart: 53,
      portEnd: 53,
      description: 'dns',
    );

    final curated = updateCuratedFirewallConfig(
      current,
      allowPostgres: true,
      allowDns: true,
    );
    expect(curated.strictMode, isTrue);
    expect(curated.allowPostgres, isTrue);
    expect(curated.allowDns, isTrue);

    final curatedFallbacks = updateCuratedFirewallConfig(current);
    expect(curatedFallbacks.allowPostgres, isFalse);
    expect(curatedFallbacks.allowDns, isFalse);

    final timeout = updateRollbackTimeoutConfig(current, 300);
    expect(timeout.strictMode, isTrue);
    expect(timeout.rollbackTimeoutSeconds, 300);

    final upserted = upsertCustomRuleConfig(
      current,
      replacement,
      current: current.customRules.first,
    );
    expect(upserted.strictMode, isTrue);
    expect(upserted.customRules, [replacement]);

    final appended = upsertCustomRuleConfig(current, replacement);
    expect(appended.customRules.length, 2);

    final removed = removeCustomRuleConfig(current, current.customRules.first);
    expect(removed.strictMode, isTrue);
    expect(removed.customRules, isEmpty);
  });

  test('parseFirewallStagedState parses valid and invalid payloads', () {
    expect(parseFirewallStagedState(null), isNull);
    expect(parseFirewallStagedState({'token': '   '}), isNull);

    final parsed = parseFirewallStagedState({
      'token': 'stage-1',
      'expires_at': '2026-04-18T15:00:00Z',
    });
    expect(parsed?.token, 'stage-1');
    expect(parsed?.expiresAt, isNotNull);
  });

  test('nullable readers only accept matching types', () {
    expect(readNullableBool({'ok': true}, 'ok'), isTrue);
    expect(readNullableBool({'ok': 'true'}, 'ok'), isNull);
    expect(readNullableInt({'n': 4}, 'n'), 4);
    expect(readNullableInt({'n': '4'}, 'n'), isNull);
  });

  test('parseOpenPorts normalizes, deduplicates, and sorts rows', () {
    final ports = parseOpenPorts([
      {
        'source': 'docker_published',
        'protocol': 'tcp',
        'port': '5432',
        'bind': '0.0.0.0',
        'details': 'postgres',
      },
      {
        'source': 'host_listener',
        'protocol': 'tcp',
        'port': '5432',
        'bind': '::',
        'details': 'postgres',
      },
      {'source': 'z-source', 'protocol': 'udp', 'port': '22'},
      {'source': 'host_listener', 'protocol': 'tcp', 'port': '22'},
      {'source': 'a-source', 'protocol': 'udp', 'port': '22'},
      'skip',
    ]);

    expect(parseOpenPorts('bad'), isEmpty);
    expect(
      ports
          .map(
            (entry) =>
                '${entry.port}:${entry.protocol}:${entry.source}:${entry.risk}',
          )
          .toList(),
      [
        '22:tcp:host_listener:Unknown',
        '22:udp:a-source, z-source:Unknown',
        '5432:tcp:docker_published, host_listener:Public',
      ],
    );
    expect(ports.first.bindAddress, '-');
    expect(ports.first.owner, '-');
    expect(ports.last.bindAddress, '0.0.0.0, ::');
    expect(ports.last.observationCount, 2);

    final samePortAndProtocol = parseOpenPorts([
      {
        'source': 'z-public',
        'protocol': 'tcp',
        'port': '9000',
        'bind': '0.0.0.0',
      },
      {
        'source': 'a-local',
        'protocol': 'tcp',
        'port': '9000',
        'bind': '127.0.0.1',
      },
    ]);
    expect(samePortAndProtocol.map((entry) => entry.source), [
      'a-local',
      'z-public',
    ]);
  });

  test('firewallBindRisk classifies public, local, and specific binds', () {
    expect(firewallBindRisk('0.0.0.0'), 'Public');
    expect(firewallBindRisk('[::]'), 'Public');
    expect(firewallBindRisk('*'), 'Public');
    expect(firewallBindRisk('127.0.0.1'), 'Local only');
    expect(firewallBindRisk('[::1]'), 'Local only');
    expect(firewallBindRisk('localhost'), 'Local only');
    expect(firewallBindRisk('192.0.2.4'), 'Specific address');
    expect(firewallBindRisk('-'), 'Unknown');
  });

  test('firewallAllowedPortSummary describes every enabled rule', () {
    const config = ServerFirewallConfig(
      allowPostgres: true,
      allowDns: true,
      allowSmtp: true,
      allowMailReceive: true,
      customRules: [
        ServerFirewallCustomRule(
          id: 'one',
          protocol: 'tcp',
          portStart: 9000,
          portEnd: 9000,
          description: 'Metrics',
        ),
        ServerFirewallCustomRule(
          id: 'range',
          protocol: 'udp',
          portStart: 9100,
          portEnd: 9102,
        ),
        ServerFirewallCustomRule(
          id: 'off',
          protocol: 'tcp',
          portStart: 9999,
          portEnd: 9999,
          enabled: false,
        ),
      ],
    );

    final summary = firewallAllowedPortSummary(config, sshPort: 2200);

    expect(
      summary,
      containsAll(<String>[
        '2200/tcp (SSH)',
        '80/tcp (HTTP)',
        '443/tcp (HTTPS)',
        '443/udp (HTTP/3)',
        '5432/tcp (PostgreSQL)',
        '53/tcp (DNS)',
        '53/udp (DNS)',
        '25/tcp (SMTP)',
        '465/tcp (SMTP)',
        '587/tcp (SMTP)',
        '110/tcp (POP3)',
        '143/tcp (IMAP)',
        '993/tcp (IMAPS)',
        '995/tcp (POP3S)',
        '9000/tcp (Metrics)',
        '9100-9102/udp',
      ]),
    );
    expect(summary, isNot(contains('9999/tcp')));
  });

  test('parseFirewallStatusViewModel merges status and port errors', () {
    final parsed = parseFirewallStatusViewModel(
      statusResult: {
        'firewall_enabled': true,
        'firewall_ipv4_enabled': true,
        'firewall_ipv6_enabled': false,
        'fail2ban_active': true,
        'fail2ban_enabled': true,
        'fail2ban_sshd_jail_active': true,
        'fail2ban_currently_banned': 2,
        'fail2ban_total_failed': 17,
        'persistent_rules_present': true,
        'persistent_rules_v4_present': true,
        'persistent_rules_v6_present': false,
        'netfilter_persistent_enabled': true,
        'msg': 'Firewall status collected.',
        'external_interface': 'eth0',
        'staged_state': {
          'token': 'fw-token',
          'expires_at': '2026-04-18T15:10:00Z',
        },
      },
      portsResult: {
        'status': 'error',
        'msg': 'Unable to read open ports.',
        'open_ports': [
          {'source': 'host_listener', 'protocol': 'tcp', 'port': '22'},
        ],
      },
    );

    expect(parsed.firewallEnabled, isTrue);
    expect(parsed.firewallIpv6Enabled, isFalse);
    expect(parsed.fail2banTotalFailed, 17);
    expect(parsed.persistentRulesV6Present, isFalse);
    expect(parsed.statusMessage, 'Firewall status collected.');
    expect(parsed.statusError, 'Unable to read open ports.');
    expect(parsed.externalInterface, 'eth0');
    expect(parsed.stagedState?.token, 'fw-token');
    expect(parsed.openPorts.single.port, '22');

    final unprotected = parseFirewallStatusViewModel(
      statusResult: {
        'firewall_state': 'unprotected',
        'msg': 'Firewall status collected.',
      },
      portsResult: {'status': 'error', 'msg': 'Unable to read open ports.'},
    );
    expect(
      unprotected.statusError,
      'This server currently has no active firewall because Deploy Dash replaced '
      'ufw and the staged rules were rolled back. Retry Apply changes immediately.',
    );
  });

  test('buildProtectionMetrics derives visible labels and values', () {
    expect(
      buildProtectionMetrics(
        sshPort: 22,
        fail2banActive: null,
        fail2banSshdJailActive: null,
        fail2banCurrentlyBanned: null,
        fail2banTotalFailed: null,
      ).map((metric) => '${metric.label}:${metric.value}').toList(),
      [
        'SSH port:22',
        'Fail2ban service:Unknown',
        'SSH jail:Unknown',
        'Current bans:0',
        'Failed attempts:0',
      ],
    );

    expect(
      buildProtectionMetrics(
        sshPort: 2222,
        fail2banActive: false,
        fail2banSshdJailActive: false,
        fail2banCurrentlyBanned: 3,
        fail2banTotalFailed: 9,
      ).map((metric) => metric.value).toList(),
      ['2222', 'Inactive', 'Unavailable', '3', '9'],
    );

    expect(
      buildProtectionMetrics(
        sshPort: 2200,
        fail2banActive: true,
        fail2banSshdJailActive: true,
        fail2banCurrentlyBanned: 1,
        fail2banTotalFailed: 5,
      )[1].value,
      'Active',
    );
  });
}
