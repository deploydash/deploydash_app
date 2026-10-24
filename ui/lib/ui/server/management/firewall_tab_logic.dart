import '../../../domain/server.dart';

class FirewallProtectionMetric {
  const FirewallProtectionMetric({required this.label, required this.value});

  final String label;
  final String value;
}

class FirewallObservedPortView {
  const FirewallObservedPortView({
    required this.source,
    required this.protocol,
    required this.port,
    required this.bindAddress,
    required this.details,
    required this.owner,
    required this.risk,
    this.observationCount = 1,
  });

  final String source;
  final String protocol;
  final String port;
  final String bindAddress;
  final String details;
  final String owner;
  final String risk;
  final int observationCount;
}

class FirewallStagedStateView {
  const FirewallStagedStateView({required this.token, required this.expiresAt});

  final String token;
  final DateTime? expiresAt;
}

class FirewallStatusViewModel {
  const FirewallStatusViewModel({
    required this.firewallEnabled,
    required this.firewallIpv4Enabled,
    required this.firewallIpv6Enabled,
    required this.fail2banActive,
    required this.fail2banEnabled,
    required this.fail2banSshdJailActive,
    required this.fail2banCurrentlyBanned,
    required this.fail2banTotalFailed,
    required this.persistentRulesPresent,
    required this.persistentRulesV4Present,
    required this.persistentRulesV6Present,
    required this.netfilterPersistentEnabled,
    required this.statusMessage,
    required this.statusError,
    required this.externalInterface,
    required this.stagedState,
    required this.openPorts,
  });

  final bool firewallEnabled;
  final bool? firewallIpv4Enabled;
  final bool? firewallIpv6Enabled;
  final bool? fail2banActive;
  final bool? fail2banEnabled;
  final bool? fail2banSshdJailActive;
  final int? fail2banCurrentlyBanned;
  final int? fail2banTotalFailed;
  final bool? persistentRulesPresent;
  final bool? persistentRulesV4Present;
  final bool? persistentRulesV6Present;
  final bool? netfilterPersistentEnabled;
  final String? statusMessage;
  final String? statusError;
  final String? externalInterface;
  final FirewallStagedStateView? stagedState;
  final List<FirewallObservedPortView> openPorts;
}

Map<String, dynamic> buildFirewallSettings(
  ServerFirewallConfig config, {
  required int sshPort,
}) {
  return <String, dynamic>{
    ...config.toJsonMap(),
    'strict_mode': true,
    'locked_ports': lockedPortsForSshPort(sshPort),
  };
}

List<int> lockedPortsForSshPort(int sshPort) {
  final ports = <int>{22, 80, 443};
  if (sshPort >= 1 && sshPort <= 65535) {
    ports.add(sshPort);
  }
  final sorted = ports.toList(growable: false)..sort();
  return sorted;
}

ServerFirewallConfig updateCuratedFirewallConfig(
  ServerFirewallConfig config, {
  bool? allowPostgres,
  bool? allowDns,
  bool? allowSmtp,
  bool? allowMailReceive,
}) {
  return ServerFirewallConfig(
    strictMode: true,
    allowPostgres: allowPostgres ?? config.allowPostgres,
    allowDns: allowDns ?? config.allowDns,
    allowSmtp: allowSmtp ?? config.allowSmtp,
    allowMailReceive: allowMailReceive ?? config.allowMailReceive,
    rollbackTimeoutSeconds: config.rollbackTimeoutSeconds,
    customRules: config.customRules,
  );
}

ServerFirewallConfig updateRollbackTimeoutConfig(
  ServerFirewallConfig config,
  int seconds,
) {
  return ServerFirewallConfig(
    strictMode: true,
    allowPostgres: config.allowPostgres,
    allowDns: config.allowDns,
    allowSmtp: config.allowSmtp,
    allowMailReceive: config.allowMailReceive,
    rollbackTimeoutSeconds: seconds,
    customRules: config.customRules,
  );
}

ServerFirewallConfig upsertCustomRuleConfig(
  ServerFirewallConfig config,
  ServerFirewallCustomRule rule, {
  ServerFirewallCustomRule? current,
}) {
  final nextRules = <ServerFirewallCustomRule>[];
  for (final existing in config.customRules) {
    if (current != null && existing.id == current.id) {
      continue;
    }
    nextRules.add(existing);
  }
  nextRules.add(rule);
  return ServerFirewallConfig(
    strictMode: true,
    allowPostgres: config.allowPostgres,
    allowDns: config.allowDns,
    allowSmtp: config.allowSmtp,
    allowMailReceive: config.allowMailReceive,
    rollbackTimeoutSeconds: config.rollbackTimeoutSeconds,
    customRules: nextRules,
  );
}

ServerFirewallConfig removeCustomRuleConfig(
  ServerFirewallConfig config,
  ServerFirewallCustomRule current,
) {
  return ServerFirewallConfig(
    strictMode: true,
    allowPostgres: config.allowPostgres,
    allowDns: config.allowDns,
    allowSmtp: config.allowSmtp,
    allowMailReceive: config.allowMailReceive,
    rollbackTimeoutSeconds: config.rollbackTimeoutSeconds,
    customRules: config.customRules
        .where((rule) => rule.id != current.id)
        .toList(growable: false),
  );
}

FirewallStagedStateView? parseFirewallStagedState(dynamic raw) {
  if (raw is! Map) {
    return null;
  }
  final token = raw['token']?.toString().trim();
  if (token == null || token.isEmpty) {
    return null;
  }
  final expiresAtRaw = raw['expires_at']?.toString().trim();
  DateTime? expiresAt;
  if (expiresAtRaw != null && expiresAtRaw.isNotEmpty) {
    expiresAt = DateTime.tryParse(expiresAtRaw)?.toLocal();
  }
  return FirewallStagedStateView(token: token, expiresAt: expiresAt);
}

bool? readNullableBool(Map<String, dynamic> payload, String key) {
  final value = payload[key];
  if (value is bool) {
    return value;
  }
  return null;
}

int? readNullableInt(Map<String, dynamic> payload, String key) {
  final value = payload[key];
  if (value is int) {
    return value;
  }
  return null;
}

List<FirewallObservedPortView> parseOpenPorts(dynamic raw) {
  if (raw is! List) {
    return const <FirewallObservedPortView>[];
  }
  final grouped = <String, _MutableObservedPort>{};
  for (final entry in raw) {
    if (entry is! Map) {
      continue;
    }
    final source = _normalizedPortValue(entry['source'], fallback: 'Unknown');
    final protocol = _normalizedPortValue(entry['protocol'], fallback: '-');
    final port = _normalizedPortValue(entry['port'], fallback: '-');
    final bindAddress = _normalizedPortValue(entry['bind'], fallback: '-');
    final details = _normalizedPortValue(entry['details'], fallback: '-');
    final risk = firewallBindRisk(bindAddress);
    final key = '${protocol.toLowerCase()}|$port|$risk';
    grouped
        .putIfAbsent(
          key,
          () => _MutableObservedPort(protocol: protocol, port: port),
        )
        .add(source: source, bindAddress: bindAddress, owner: details);
  }
  final result = grouped.values.map((entry) => entry.build()).toList();
  result.sort((a, b) {
    final portA = int.tryParse(a.port) ?? 0;
    final portB = int.tryParse(b.port) ?? 0;
    final portComparison = portA.compareTo(portB);
    if (portComparison != 0) {
      return portComparison;
    }
    final protocolComparison = a.protocol.compareTo(b.protocol);
    if (protocolComparison != 0) {
      return protocolComparison;
    }
    return a.source.compareTo(b.source);
  });
  return result;
}

String _normalizedPortValue(dynamic raw, {required String fallback}) {
  final value = raw?.toString().trim();
  return value == null || value.isEmpty ? fallback : value;
}

String firewallBindRisk(String bindAddress) {
  final normalized = bindAddress.trim().toLowerCase();
  if (normalized == '0.0.0.0' ||
      normalized == '::' ||
      normalized == '[::]' ||
      normalized == '*') {
    return 'Public';
  }
  if (normalized == '127.0.0.1' ||
      normalized == '::1' ||
      normalized == '[::1]' ||
      normalized == 'localhost') {
    return 'Local only';
  }
  if (normalized == '-' || normalized.isEmpty) {
    return 'Unknown';
  }
  return 'Specific address';
}

List<String> firewallAllowedPortSummary(
  ServerFirewallConfig config, {
  required int sshPort,
}) {
  final ports = <String>{
    '$sshPort/tcp (SSH)',
    '80/tcp (HTTP)',
    '443/tcp (HTTPS)',
    '443/udp (HTTP/3)',
  };
  if (config.allowPostgres) {
    ports.add('5432/tcp (PostgreSQL)');
  }
  if (config.allowDns) {
    ports.addAll(const ['53/tcp (DNS)', '53/udp (DNS)']);
  }
  if (config.allowSmtp) {
    ports.addAll(const ['25/tcp (SMTP)', '465/tcp (SMTP)', '587/tcp (SMTP)']);
  }
  if (config.allowMailReceive) {
    ports.addAll(const [
      '110/tcp (POP3)',
      '143/tcp (IMAP)',
      '993/tcp (IMAPS)',
      '995/tcp (POP3S)',
    ]);
  }
  for (final rule in config.customRules.where((rule) => rule.enabled)) {
    final range = rule.portStart == rule.portEnd
        ? '${rule.portStart}'
        : '${rule.portStart}-${rule.portEnd}';
    final description = rule.description?.trim();
    ports.add(
      '$range/${rule.protocol}'
      '${description == null || description.isEmpty ? '' : ' ($description)'}',
    );
  }
  return ports.toList(growable: false);
}

class _MutableObservedPort {
  _MutableObservedPort({required this.protocol, required this.port});

  final String protocol;
  final String port;
  final Set<String> _sources = <String>{};
  final Set<String> _bindAddresses = <String>{};
  final Set<String> _owners = <String>{};
  int _observationCount = 0;

  void add({
    required String source,
    required String bindAddress,
    required String owner,
  }) {
    _sources.add(source);
    _bindAddresses.add(bindAddress);
    _owners.add(owner);
    _observationCount += 1;
  }

  FirewallObservedPortView build() {
    final bindAddresses = _bindAddresses.toList()..sort();
    final sources = _sources.toList()..sort();
    final owners = _owners.toList()..sort();
    final risk = bindAddresses.map(firewallBindRisk).reduce(_moreExposedRisk);
    return FirewallObservedPortView(
      source: sources.join(', '),
      protocol: protocol,
      port: port,
      bindAddress: bindAddresses.join(', '),
      details: owners.join(', '),
      owner: owners.join(', '),
      risk: risk,
      observationCount: _observationCount,
    );
  }
}

String _moreExposedRisk(String left, String right) {
  const priority = <String, int>{
    'Unknown': 0,
    'Local only': 1,
    'Specific address': 2,
    'Public': 3,
  };
  return (priority[left] ?? 0) >= (priority[right] ?? 0) ? left : right;
}

FirewallStatusViewModel parseFirewallStatusViewModel({
  required Map<String, dynamic> statusResult,
  required Map<String, dynamic> portsResult,
}) {
  final portsError = portsResult['status'] != 'success'
      ? portsResult['msg']?.toString() ?? 'Unable to read open ports.'
      : null;
  final protectionError = statusResult['firewall_state'] == 'unprotected'
      ? 'This server currently has no active firewall because Deploy Dash '
            'replaced ufw and the staged rules were rolled back. Retry Apply '
            'changes immediately.'
      : null;
  return FirewallStatusViewModel(
    firewallEnabled: statusResult['firewall_enabled'] == true,
    firewallIpv4Enabled: readNullableBool(
      statusResult,
      'firewall_ipv4_enabled',
    ),
    firewallIpv6Enabled: readNullableBool(
      statusResult,
      'firewall_ipv6_enabled',
    ),
    fail2banActive: readNullableBool(statusResult, 'fail2ban_active'),
    fail2banEnabled: readNullableBool(statusResult, 'fail2ban_enabled'),
    fail2banSshdJailActive: readNullableBool(
      statusResult,
      'fail2ban_sshd_jail_active',
    ),
    fail2banCurrentlyBanned: readNullableInt(
      statusResult,
      'fail2ban_currently_banned',
    ),
    fail2banTotalFailed: readNullableInt(statusResult, 'fail2ban_total_failed'),
    persistentRulesPresent: readNullableBool(
      statusResult,
      'persistent_rules_present',
    ),
    persistentRulesV4Present: readNullableBool(
      statusResult,
      'persistent_rules_v4_present',
    ),
    persistentRulesV6Present: readNullableBool(
      statusResult,
      'persistent_rules_v6_present',
    ),
    netfilterPersistentEnabled: readNullableBool(
      statusResult,
      'netfilter_persistent_enabled',
    ),
    statusMessage: statusResult['msg']?.toString(),
    statusError: protectionError ?? portsError,
    externalInterface: statusResult['external_interface']?.toString(),
    stagedState: parseFirewallStagedState(statusResult['staged_state']),
    openPorts: parseOpenPorts(portsResult['open_ports']),
  );
}

List<FirewallProtectionMetric> buildProtectionMetrics({
  required int sshPort,
  required bool? fail2banActive,
  required bool? fail2banSshdJailActive,
  required int? fail2banCurrentlyBanned,
  required int? fail2banTotalFailed,
}) {
  return <FirewallProtectionMetric>[
    FirewallProtectionMetric(label: 'SSH port', value: '$sshPort'),
    FirewallProtectionMetric(
      label: 'Fail2ban service',
      value: fail2banActive == null
          ? 'Unknown'
          : fail2banActive
          ? 'Active'
          : 'Inactive',
    ),
    FirewallProtectionMetric(
      label: 'SSH jail',
      value: fail2banSshdJailActive == null
          ? 'Unknown'
          : fail2banSshdJailActive
          ? 'Protecting'
          : 'Unavailable',
    ),
    FirewallProtectionMetric(
      label: 'Current bans',
      value: '${fail2banCurrentlyBanned ?? 0}',
    ),
    FirewallProtectionMetric(
      label: 'Failed attempts',
      value: '${fail2banTotalFailed ?? 0}',
    ),
  ];
}
