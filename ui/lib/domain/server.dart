import '../utils/payload_codecs.dart';

enum ServerAuthMethod { password, sshKey }

// coverage-gate: server_config_bool_decode
/// Keeps tolerant persisted-boolean decoding owned by one configuration seam.
bool _decodeConfigBool(Map<String, dynamic> raw, String key, bool fallback) {
  final value = raw[key];
  if (value is bool) {
    return value;
  }
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true') {
      return true;
    }
    if (normalized == 'false') {
      return false;
    }
  }
  return fallback;
}
// end coverage-gate

/// Opaque handle for the separately stored local SSH credentials of a server.
///
/// This value deliberately carries only the server identity. Its secret values
/// can be materialized only by the data-layer credential accessor.
class ServerCredentialReference {
  const ServerCredentialReference(this.serverId);

  final String serverId;
}

class ServerWebServerConfig {
  const ServerWebServerConfig({
    this.enableHttpsRedirect = true,
    this.enableCompression = true,
    this.enableAccessLogs = false,
    this.enableDnsPluginCloudflare = false,
    this.enableDnsPluginPorkbun = false,
    this.enableDnsPluginNamecheap = false,
    this.enableDnsPluginCloudns = false,
    this.enableDnsPluginEasydns = false,
  });

  static const ServerWebServerConfig defaults = ServerWebServerConfig();

  final bool enableHttpsRedirect;
  final bool enableCompression;
  final bool enableAccessLogs;
  final bool enableDnsPluginCloudflare;
  final bool enableDnsPluginPorkbun;
  final bool enableDnsPluginNamecheap;
  final bool enableDnsPluginCloudns;
  final bool enableDnsPluginEasydns;

  factory ServerWebServerConfig.fromJsonMap(Map<String, dynamic> raw) {
    return ServerWebServerConfig(
      enableHttpsRedirect: _decodeConfigBool(
        raw,
        'enable_https_redirect',
        true,
      ),
      enableCompression: _decodeConfigBool(
        raw,
        'enable_response_compression',
        true,
      ),
      enableAccessLogs: _decodeConfigBool(raw, 'enable_access_logs', false),
      enableDnsPluginCloudflare: _decodeConfigBool(
        raw,
        'enable_dns_plugin_cloudflare',
        false,
      ),
      enableDnsPluginPorkbun: _decodeConfigBool(
        raw,
        'enable_dns_plugin_porkbun',
        false,
      ),
      enableDnsPluginNamecheap: _decodeConfigBool(
        raw,
        'enable_dns_plugin_namecheap',
        false,
      ),
      enableDnsPluginCloudns: _decodeConfigBool(
        raw,
        'enable_dns_plugin_cloudns',
        false,
      ),
      enableDnsPluginEasydns: _decodeConfigBool(
        raw,
        'enable_dns_plugin_easydns',
        false,
      ),
    );
  }

  Map<String, dynamic> toJsonMap() {
    return <String, dynamic>{
      'enable_https_redirect': enableHttpsRedirect,
      'enable_response_compression': enableCompression,
      'enable_access_logs': enableAccessLogs,
      'enable_dns_plugin_cloudflare': enableDnsPluginCloudflare,
      'enable_dns_plugin_porkbun': enableDnsPluginPorkbun,
      'enable_dns_plugin_namecheap': enableDnsPluginNamecheap,
      'enable_dns_plugin_cloudns': enableDnsPluginCloudns,
      'enable_dns_plugin_easydns': enableDnsPluginEasydns,
    };
  }

  List<String> get enabledDnsProviders {
    final providers = <String>[];
    if (enableDnsPluginCloudflare) {
      providers.add('cloudflare');
    }
    if (enableDnsPluginPorkbun) {
      providers.add('porkbun');
    }
    if (enableDnsPluginNamecheap) {
      providers.add('namecheap');
    }
    if (enableDnsPluginCloudns) {
      providers.add('cloudns');
    }
    if (enableDnsPluginEasydns) {
      providers.add('easydns');
    }
    return providers;
  }
}

class ServerPostgresConfig {
  const ServerPostgresConfig({
    this.postgresVersion = '17',
    this.superuserPassword,
    this.enabledExtensions = const <String>[],
  });

  static const ServerPostgresConfig defaults = ServerPostgresConfig();
  static const Set<String> supportedVersions = {'16', '17', '18'};
  static const List<String> requestedExtensions = <String>[
    'pg_stat_statements',
    'plpgsql',
    'pgcrypto',
    'pg_trgm',
    'vector',
    'pg_search',
    'uuid-ossp',
    'pg_session_jwt',
    'hstore',
    'postgis',
    'btree_gin',
  ];
  static const Set<String> supportedExtensions = <String>{
    'pg_stat_statements',
    'plpgsql',
    'pgcrypto',
    'pg_trgm',
    'vector',
    'pg_search',
    'uuid-ossp',
    'hstore',
    'postgis',
    'btree_gin',
  };
  static const Set<String> unsupportedExtensions = <String>{'pg_session_jwt'};

  final String postgresVersion;
  final String? superuserPassword;
  final List<String> enabledExtensions;

  factory ServerPostgresConfig.fromJsonMap(Map<String, dynamic> raw) {
    final versionRaw = raw['postgres_version'];
    String? superuserPassword;
    final passwordRaw = raw['superuser_password'];
    if (passwordRaw is String && passwordRaw.trim().isNotEmpty) {
      superuserPassword = passwordRaw.trim();
    }
    final enabledExtensions = <String>[];
    final extensionsRaw = raw['enabled_extensions'];
    if (extensionsRaw is List) {
      for (final item in extensionsRaw) {
        if (item is! String) {
          continue;
        }
        final normalized = item.trim();
        if (normalized.isEmpty) {
          continue;
        }
        if (!supportedExtensions.contains(normalized)) {
          continue;
        }
        if (enabledExtensions.contains(normalized)) {
          continue;
        }
        enabledExtensions.add(normalized);
      }
    }
    if (versionRaw is String) {
      final version = versionRaw.trim();
      if (supportedVersions.contains(version)) {
        return ServerPostgresConfig(
          postgresVersion: version,
          superuserPassword: superuserPassword,
          enabledExtensions: enabledExtensions,
        );
      }
    }
    return defaults;
  }

  Map<String, dynamic> toJsonMap() {
    return <String, dynamic>{
      'postgres_version': postgresVersion,
      'superuser_password': superuserPassword,
      'enabled_extensions': enabledExtensions,
    };
  }
}

class ServerFirewallCustomRule {
  const ServerFirewallCustomRule({
    required this.id,
    required this.protocol,
    required this.portStart,
    required this.portEnd,
    this.sourceCidr,
    this.description,
    this.enabled = true,
  });

  final String id;
  final String protocol;
  final int portStart;
  final int portEnd;
  final String? sourceCidr;
  final String? description;
  final bool enabled;

  factory ServerFirewallCustomRule.fromJsonMap(Map<String, dynamic> raw) {
    String parseId(dynamic value) {
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
      return DateTime.now().microsecondsSinceEpoch.toString();
    }

    String parseProtocol(dynamic value) {
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (normalized == 'udp') {
          return 'udp';
        }
      }
      return 'tcp';
    }

    int parsePort(dynamic value, int fallback) {
      if (value is int) {
        return value.clamp(1, 65535);
      }
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) {
          return parsed.clamp(1, 65535);
        }
      }
      return fallback;
    }

    String? parseText(dynamic value) {
      if (value is! String) {
        return null;
      }
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    bool parseEnabled(dynamic value) {
      if (value is bool) {
        return value;
      }
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (normalized == 'false' || normalized == '0') {
          return false;
        }
      }
      return true;
    }

    final start = parsePort(raw['port_start'], 1);
    final end = parsePort(raw['port_end'], start);
    return ServerFirewallCustomRule(
      id: parseId(raw['id']),
      protocol: parseProtocol(raw['protocol']),
      portStart: start <= end ? start : end,
      portEnd: end >= start ? end : start,
      sourceCidr: parseText(raw['source_cidr']),
      description: parseText(raw['description']),
      enabled: parseEnabled(raw['enabled']),
    );
  }

  Map<String, dynamic> toJsonMap() {
    return <String, dynamic>{
      'id': id,
      'protocol': protocol,
      'port_start': portStart,
      'port_end': portEnd,
      'source_cidr': sourceCidr,
      'description': description,
      'enabled': enabled,
    };
  }
}

class ServerFirewallConfig {
  const ServerFirewallConfig({
    this.strictMode = true,
    this.allowPostgres = false,
    this.allowDns = false,
    this.allowSmtp = false,
    this.allowMailReceive = false,
    this.rollbackTimeoutSeconds = 90,
    this.customRules = const <ServerFirewallCustomRule>[],
  });

  static const ServerFirewallConfig defaults = ServerFirewallConfig();

  final bool strictMode;
  final bool allowPostgres;
  final bool allowDns;
  final bool allowSmtp;
  final bool allowMailReceive;
  final int rollbackTimeoutSeconds;
  final List<ServerFirewallCustomRule> customRules;

  // One canonical copier for firewall edits: the D-59 quad's bespoke
  // rebuilds route through it in T-026 instead of respelling all fields.
  // coverage-gate: server_firewall_config_copy_with
  ServerFirewallConfig copyWith({
    bool? strictMode,
    bool? allowPostgres,
    bool? allowDns,
    bool? allowSmtp,
    bool? allowMailReceive,
    int? rollbackTimeoutSeconds,
    List<ServerFirewallCustomRule>? customRules,
  }) {
    return ServerFirewallConfig(
      strictMode: strictMode ?? this.strictMode,
      allowPostgres: allowPostgres ?? this.allowPostgres,
      allowDns: allowDns ?? this.allowDns,
      allowSmtp: allowSmtp ?? this.allowSmtp,
      allowMailReceive: allowMailReceive ?? this.allowMailReceive,
      rollbackTimeoutSeconds:
          rollbackTimeoutSeconds ?? this.rollbackTimeoutSeconds,
      customRules: customRules ?? this.customRules,
    );
  }
  // end coverage-gate

  factory ServerFirewallConfig.fromJsonMap(Map<String, dynamic> raw) {
    int parseRollback(dynamic value) {
      if (value is int) {
        return value.clamp(30, 3600);
      }
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) {
          return parsed.clamp(30, 3600);
        }
      }
      return 90;
    }

    final customRules = <ServerFirewallCustomRule>[];
    final rawRules = raw['custom_rules'];
    if (rawRules is List) {
      for (final entry in rawRules) {
        if (entry is! Map) {
          continue;
        }
        customRules.add(ServerFirewallCustomRule.fromJsonMap(mapFrom(entry)));
      }
    }

    return ServerFirewallConfig(
      strictMode: _decodeConfigBool(raw, 'strict_mode', true),
      allowPostgres: _decodeConfigBool(raw, 'allow_postgres', false),
      allowDns: _decodeConfigBool(raw, 'allow_dns', false),
      allowSmtp: _decodeConfigBool(raw, 'allow_smtp', false),
      allowMailReceive: _decodeConfigBool(raw, 'allow_mail_receive', false),
      rollbackTimeoutSeconds: parseRollback(raw['rollback_timeout_seconds']),
      customRules: customRules,
    );
  }

  Map<String, dynamic> toJsonMap() {
    return <String, dynamic>{
      'strict_mode': strictMode,
      'allow_postgres': allowPostgres,
      'allow_dns': allowDns,
      'allow_smtp': allowSmtp,
      'allow_mail_receive': allowMailReceive,
      'rollback_timeout_seconds': rollbackTimeoutSeconds,
      'custom_rules': customRules
          .map((rule) => rule.toJsonMap())
          .toList(growable: false),
    };
  }
}

// coverage-gate: server_root_login_mode
enum ServerRootLoginMode {
  disabled('disabled', 'Disabled'),
  keyOnly('key_only', 'Key only'),
  passwordAllowed('password_allowed', 'Password allowed'),
  restricted('restricted', 'Restricted (forced commands only)');

  const ServerRootLoginMode(this.wireValue, this.displayLabel);

  final String wireValue;
  final String displayLabel;

  /// Decodes the lossless mode while keeping old boolean snapshots safe.
  static ServerRootLoginMode fromWireValue(
    Object? rawValue, {
    required bool legacyEnabled,
  }) {
    final normalized = rawValue?.toString().trim().toLowerCase();
    return switch (normalized) {
      'disabled' => disabled,
      'key_only' => keyOnly,
      'password_allowed' => passwordAllowed,
      'restricted' => restricted,
      _ => legacyEnabled ? keyOnly : disabled,
    };
  }

  /// Retains the old summary meaning without using it to choose sshd policy.
  bool get rootLoginEnabled => this != disabled;
}
// end coverage-gate

class ServerSystemConfig {
  // coverage-gate: server_system_root_login_constructor
  const ServerSystemConfig({
    ServerRootLoginMode? rootLoginMode,
    bool? rootLoginEnabled,
    this.passwordAuthEnabled = false,
    this.sshPort = 22,
    this.timezone = 'UTC',
    this.swapGb = 2,
    this.automaticSecurityUpdatesEnabled = true,
    this.autoRebootEnabled = false,
    this.maintenanceTime = '03:00',
  }) : rootLoginMode =
           rootLoginMode ??
           (rootLoginEnabled == true
               ? ServerRootLoginMode.keyOnly
               : ServerRootLoginMode.disabled);
  // end coverage-gate

  static const ServerSystemConfig defaults = ServerSystemConfig();

  final ServerRootLoginMode rootLoginMode;

  /// Keeps legacy persistence and callers readable without losing the mode.
  bool get rootLoginEnabled => rootLoginMode.rootLoginEnabled;
  final bool passwordAuthEnabled;
  final int sshPort;
  final String timezone;
  final double swapGb;
  final bool automaticSecurityUpdatesEnabled;
  final bool autoRebootEnabled;
  final String maintenanceTime;

  // One canonical copier for system-settings edits: T-027 deletes the
  // hand-rolled copySystemConfig and routes its 8 closures through this.
  // Parameter names + the rootLoginMode/rootLoginEnabled resolution mirror
  // copySystemConfig exactly, so that swap is behavior-neutral.
  // coverage-gate: server_system_config_copy_with
  ServerSystemConfig copyWith({
    ServerRootLoginMode? rootLoginMode,
    bool? rootLoginEnabled,
    bool? passwordAuthEnabled,
    int? sshPort,
    String? timezone,
    double? swapGb,
    bool? automaticSecurityUpdatesEnabled,
    bool? autoRebootEnabled,
    String? maintenanceTime,
  }) {
    return ServerSystemConfig(
      rootLoginMode:
          rootLoginMode ??
          (rootLoginEnabled == null
              ? this.rootLoginMode
              : rootLoginEnabled
              ? ServerRootLoginMode.keyOnly
              : ServerRootLoginMode.disabled),
      passwordAuthEnabled: passwordAuthEnabled ?? this.passwordAuthEnabled,
      sshPort: sshPort ?? this.sshPort,
      timezone: timezone ?? this.timezone,
      swapGb: swapGb ?? this.swapGb,
      automaticSecurityUpdatesEnabled:
          automaticSecurityUpdatesEnabled ??
          this.automaticSecurityUpdatesEnabled,
      autoRebootEnabled: autoRebootEnabled ?? this.autoRebootEnabled,
      maintenanceTime: maintenanceTime ?? this.maintenanceTime,
    );
  }
  // end coverage-gate

  factory ServerSystemConfig.fromJsonMap(Map<String, dynamic> raw) {
    int parsePort(dynamic value) {
      if (value is int && value >= 1 && value <= 65535) {
        return value;
      }
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null && parsed >= 1 && parsed <= 65535) {
          return parsed;
        }
      }
      return defaults.sshPort;
    }

    double parseSwap(dynamic value) {
      if (value is num) {
        final clamped = value.toDouble().clamp(0, 64);
        return clamped.toDouble();
      }
      if (value is String) {
        final parsed = double.tryParse(value.trim());
        if (parsed != null) {
          return parsed.clamp(0, 64).toDouble();
        }
      }
      return defaults.swapGb;
    }

    String parseTimezone(dynamic value) {
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
      return defaults.timezone;
    }

    String parseMaintenanceTime(dynamic value) {
      if (value is String && value.trim().isNotEmpty) {
        final trimmed = value.trim();
        final parts = trimmed.split(':');
        if (parts.length == 2) {
          final hour = int.tryParse(parts.first);
          final minute = int.tryParse(parts.last);
          if (hour != null &&
              minute != null &&
              hour >= 0 &&
              hour <= 23 &&
              minute >= 0 &&
              minute <= 59) {
            return '${hour.toString().padLeft(2, '0')}:'
                '${minute.toString().padLeft(2, '0')}';
          }
        }
      }
      return defaults.maintenanceTime;
    }

    return ServerSystemConfig(
      // coverage-gate: server_system_root_login_decode
      rootLoginMode: ServerRootLoginMode.fromWireValue(
        raw['root_login_mode'],
        legacyEnabled: _decodeConfigBool(
          raw,
          'root_login_enabled',
          defaults.rootLoginEnabled,
        ),
      ),
      // end coverage-gate
      passwordAuthEnabled: _decodeConfigBool(
        raw,
        'password_auth_enabled',
        defaults.passwordAuthEnabled,
      ),
      sshPort: parsePort(raw['ssh_port']),
      timezone: parseTimezone(raw['timezone']),
      swapGb: parseSwap(raw['swap_gb']),
      automaticSecurityUpdatesEnabled: _decodeConfigBool(
        raw,
        'automatic_security_updates_enabled',
        defaults.automaticSecurityUpdatesEnabled,
      ),
      autoRebootEnabled: _decodeConfigBool(
        raw,
        'auto_reboot_enabled',
        defaults.autoRebootEnabled,
      ),
      maintenanceTime: parseMaintenanceTime(raw['maintenance_time']),
    );
  }

  Map<String, dynamic> toJsonMap() {
    return <String, dynamic>{
      // coverage-gate: server_system_root_login_encode
      'root_login_mode': rootLoginMode.wireValue,
      'root_login_enabled': rootLoginEnabled,
      // end coverage-gate
      'password_auth_enabled': passwordAuthEnabled,
      'ssh_port': sshPort,
      'timezone': timezone,
      'swap_gb': swapGb,
      'automatic_security_updates_enabled': automaticSecurityUpdatesEnabled,
      'auto_reboot_enabled': autoRebootEnabled,
      'maintenance_time': maintenanceTime,
    };
  }
}

/// Typed cache of the engine's managed-software inventory for one server.
///
/// The engine owns the fields inside each component. This value makes the
/// locally persisted boundary explicit without leaking a JSON string into UI.
class ServerManagedSoftwareStatus {
  ServerManagedSoftwareStatus(Map<String, Map<String, dynamic>> components)
    : components = Map.unmodifiable(
        components.map(
          (id, payload) =>
              MapEntry(id, Map<String, dynamic>.unmodifiable(payload)),
        ),
      );

  factory ServerManagedSoftwareStatus.fromJsonMap(Map<String, dynamic> raw) {
    final components = <String, Map<String, dynamic>>{};
    for (final entry in raw.entries) {
      final id = entry.key.trim();
      if (id.isEmpty) {
        continue;
      }
      final value = entry.value;
      components[id] = mapFrom(value);
    }
    return ServerManagedSoftwareStatus(components);
  }

  final Map<String, Map<String, dynamic>> components;

  Map<String, dynamic> toJsonMap() {
    return Map<String, dynamic>.fromEntries(
      components.entries.map(
        (entry) => MapEntry(entry.key, Map<String, dynamic>.from(entry.value)),
      ),
    );
  }
}

class Server {
  const Server({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.sshUser,
    required this.authMethod,
    this.osName,
    this.cpuArch,
    this.memoryMb,
    this.diskGb,
    this.serviceDatabaseEnabled = false,
    this.serviceEmailEnabled = false,
    this.serviceDomainEnabled = false,
    this.webServerConfig = const ServerWebServerConfig(),
    this.postgresConfig = const ServerPostgresConfig(),
    this.firewallConfig = const ServerFirewallConfig(),
    this.systemConfig = const ServerSystemConfig(),
    this.managedSoftwareStatus,
    this.lastCheckStatus,
    this.lastError,
    this.lastCheckedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String sshUser;
  final ServerAuthMethod authMethod;

  /// The only credential handle a domain server exposes.
  ServerCredentialReference get credentialReference =>
      ServerCredentialReference(id);
  final String? osName;
  final String? cpuArch;
  final int? memoryMb;
  final int? diskGb;
  final bool serviceDatabaseEnabled;
  final bool serviceEmailEnabled;
  final bool serviceDomainEnabled;
  final ServerWebServerConfig webServerConfig;
  final ServerPostgresConfig postgresConfig;
  final ServerFirewallConfig firewallConfig;
  final ServerSystemConfig systemConfig;
  final ServerManagedSoftwareStatus? managedSoftwareStatus;
  final String? lastCheckStatus;
  final String? lastError;
  final DateTime? lastCheckedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  static const Object noChange = Object();

  // One canonical copier because the eight provider rebuilds each respell
  // every field by hand, and that shape has already dropped one field
  // (managedSoftwareStatus — see T-007): deriving here removes the
  // omission class instead of respelling it a ninth time.
  // coverage-gate: server_copy_with
  Server copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? sshUser,
    ServerAuthMethod? authMethod,
    Object? osName = noChange,
    Object? cpuArch = noChange,
    Object? memoryMb = noChange,
    Object? diskGb = noChange,
    bool? serviceDatabaseEnabled,
    bool? serviceEmailEnabled,
    bool? serviceDomainEnabled,
    ServerWebServerConfig? webServerConfig,
    ServerPostgresConfig? postgresConfig,
    ServerFirewallConfig? firewallConfig,
    ServerSystemConfig? systemConfig,
    Object? managedSoftwareStatus = noChange,
    Object? lastCheckStatus = noChange,
    Object? lastError = noChange,
    Object? lastCheckedAt = noChange,
    Object? createdAt = noChange,
    Object? updatedAt = noChange,
  }) {
    return Server(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      sshUser: sshUser ?? this.sshUser,
      authMethod: authMethod ?? this.authMethod,
      osName: identical(osName, noChange) ? this.osName : osName as String?,
      cpuArch: identical(cpuArch, noChange) ? this.cpuArch : cpuArch as String?,
      memoryMb: identical(memoryMb, noChange)
          ? this.memoryMb
          : memoryMb as int?,
      diskGb: identical(diskGb, noChange) ? this.diskGb : diskGb as int?,
      serviceDatabaseEnabled:
          serviceDatabaseEnabled ?? this.serviceDatabaseEnabled,
      serviceEmailEnabled: serviceEmailEnabled ?? this.serviceEmailEnabled,
      serviceDomainEnabled: serviceDomainEnabled ?? this.serviceDomainEnabled,
      webServerConfig: webServerConfig ?? this.webServerConfig,
      postgresConfig: postgresConfig ?? this.postgresConfig,
      firewallConfig: firewallConfig ?? this.firewallConfig,
      systemConfig: systemConfig ?? this.systemConfig,
      managedSoftwareStatus: identical(managedSoftwareStatus, noChange)
          ? this.managedSoftwareStatus
          : managedSoftwareStatus as ServerManagedSoftwareStatus?,
      lastCheckStatus: identical(lastCheckStatus, noChange)
          ? this.lastCheckStatus
          : lastCheckStatus as String?,
      lastError: identical(lastError, noChange)
          ? this.lastError
          : lastError as String?,
      lastCheckedAt: identical(lastCheckedAt, noChange)
          ? this.lastCheckedAt
          : lastCheckedAt as DateTime?,
      createdAt: identical(createdAt, noChange)
          ? this.createdAt
          : createdAt as DateTime?,
      updatedAt: identical(updatedAt, noChange)
          ? this.updatedAt
          : updatedAt as DateTime?,
    );
  }
  // end coverage-gate
}
