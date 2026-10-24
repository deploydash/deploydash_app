import '../../../domain/server.dart';

/// Transient Ubuntu evidence that must be refreshed rather than persisted.
class ServerRebootStatus {
  /// Creates the reboot-required snapshot returned by one system status read.
  const ServerRebootStatus({
    required this.required,
    required this.packages,
    required this.packagesReadable,
    required this.requiredSince,
  });

  static const none = ServerRebootStatus(
    required: false,
    packages: <String>[],
    packagesReadable: true,
    requiredSince: null,
  );

  final bool required;
  final List<String> packages;
  final bool packagesReadable;
  final DateTime? requiredSince;
}

/// Decodes transient reboot evidence without persisting it as server settings.
ServerRebootStatus serverRebootStatusFromPayload(Map<String, dynamic> payload) {
  final rawSettings = payload['settings'];
  if (rawSettings is! Map) {
    return ServerRebootStatus.none;
  }
  final settings = rawSettings.map(
    (key, value) => MapEntry(key.toString(), value),
  );
  final required = settings['reboot_required'] == true;
  final packagesReadable =
      settings['reboot_required_packages_readable'] != false;
  final rawPackages = settings['reboot_required_packages'];
  final packages = required && packagesReadable && rawPackages is List
      ? rawPackages
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false)
      : const <String>[];
  final rawSince = settings['reboot_required_since'];
  final sinceSeconds = rawSince is int
      ? rawSince
      : int.tryParse(rawSince?.toString() ?? '');
  final requiredSince = sinceSeconds != null && sinceSeconds > 0
      ? DateTime.fromMillisecondsSinceEpoch(
          sinceSeconds * Duration.millisecondsPerSecond,
          isUtc: true,
        )
      : null;
  return ServerRebootStatus(
    required: required,
    packages: packages,
    packagesReadable: packagesReadable,
    requiredSince: requiredSince,
  );
}

/// Encodes only persisted settings, leaving transient host status out of storage.
Map<String, dynamic> stagedSystemSettingsPayload(ServerSystemConfig config) {
  return <String, dynamic>{
    'root_login_mode': config.rootLoginMode.wireValue,
    'root_login_enabled': config.rootLoginEnabled,
    'password_auth_enabled': config.passwordAuthEnabled,
    'ssh_port': config.sshPort,
    'timezone': config.timezone,
    'swap_gb': config.swapGb,
    'automatic_security_updates_enabled':
        config.automaticSecurityUpdatesEnabled,
    'auto_reboot_enabled': config.autoRebootEnabled,
    'maintenance_time': config.maintenanceTime,
  };
}

/// Copies the immutable settings model while preserving every unspecified value.
ServerSystemConfig copySystemConfig(
  ServerSystemConfig current, {
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
            ? current.rootLoginMode
            : rootLoginEnabled
            ? ServerRootLoginMode.keyOnly
            : ServerRootLoginMode.disabled),
    passwordAuthEnabled: passwordAuthEnabled ?? current.passwordAuthEnabled,
    sshPort: sshPort ?? current.sshPort,
    timezone: timezone ?? current.timezone,
    swapGb: swapGb ?? current.swapGb,
    automaticSecurityUpdatesEnabled:
        automaticSecurityUpdatesEnabled ??
        current.automaticSecurityUpdatesEnabled,
    autoRebootEnabled: autoRebootEnabled ?? current.autoRebootEnabled,
    maintenanceTime: maintenanceTime ?? current.maintenanceTime,
  );
}
