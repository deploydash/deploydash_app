import 'package:ui/data/local/server_repository.dart';
import 'package:ui/ui/server/management/server_system_settings_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serverRebootStatusFromPayload decodes required restart evidence', () {
    final status = serverRebootStatusFromPayload(<String, dynamic>{
      'settings': <String, dynamic>{
        'reboot_required': true,
        'reboot_required_packages': <Object>[
          'linux-image-6.8.0-85-generic',
          ' libc6 ',
          '',
        ],
        'reboot_required_packages_readable': true,
        'reboot_required_since': '1790784000',
      },
    });

    expect(status.required, isTrue);
    expect(status.packages, <String>['linux-image-6.8.0-85-generic', 'libc6']);
    expect(status.packagesReadable, isTrue);
    expect(status.requiredSince, DateTime.utc(2026, 9, 30, 16));
  });

  test('serverRebootStatusFromPayload keeps unavailable evidence honest', () {
    final unreadable = serverRebootStatusFromPayload(<String, dynamic>{
      'settings': <String, dynamic>{
        'reboot_required': true,
        'reboot_required_packages': <String>['ignored'],
        'reboot_required_packages_readable': false,
        'reboot_required_since': 0,
      },
    });
    final malformed = serverRebootStatusFromPayload(<String, dynamic>{
      'settings': 'not-a-map',
    });
    final absent = serverRebootStatusFromPayload(<String, dynamic>{
      'settings': <String, dynamic>{
        'reboot_required': false,
        'reboot_required_packages': 'not-a-list',
        'reboot_required_since': 'not-a-number',
      },
    });

    expect(unreadable.required, isTrue);
    expect(unreadable.packages, isEmpty);
    expect(unreadable.packagesReadable, isFalse);
    expect(unreadable.requiredSince, isNull);
    expect(malformed, same(ServerRebootStatus.none));
    expect(absent.required, isFalse);
    expect(absent.packages, isEmpty);
    expect(absent.packagesReadable, isTrue);
    expect(absent.requiredSince, isNull);
  });

  test('stagedSystemSettingsPayload includes automatic security updates', () {
    const config = ServerSystemConfig(
      rootLoginEnabled: false,
      passwordAuthEnabled: true,
      sshPort: 22,
      timezone: 'UTC',
      swapGb: 2,
      automaticSecurityUpdatesEnabled: true,
      autoRebootEnabled: false,
      maintenanceTime: '03:00',
    );

    expect(stagedSystemSettingsPayload(config), <String, dynamic>{
      'root_login_mode': 'disabled',
      'root_login_enabled': false,
      'password_auth_enabled': true,
      'ssh_port': 22,
      'timezone': 'UTC',
      'swap_gb': 2.0,
      'automatic_security_updates_enabled': true,
      'auto_reboot_enabled': false,
      'maintenance_time': '03:00',
    });
  });

  test('copySystemConfig overrides only requested fields', () {
    const config = ServerSystemConfig(
      rootLoginEnabled: false,
      passwordAuthEnabled: true,
      sshPort: 22,
      timezone: 'UTC',
      swapGb: 2,
      automaticSecurityUpdatesEnabled: true,
      autoRebootEnabled: false,
      maintenanceTime: '03:00',
    );

    final updated = copySystemConfig(
      config,
      sshPort: 2022,
      automaticSecurityUpdatesEnabled: false,
      autoRebootEnabled: true,
    );

    expect(updated.rootLoginEnabled, isFalse);
    expect(updated.passwordAuthEnabled, isTrue);
    expect(updated.sshPort, 2022);
    expect(updated.automaticSecurityUpdatesEnabled, isFalse);
    expect(updated.autoRebootEnabled, isTrue);
    expect(updated.maintenanceTime, '03:00');
  });

  test('ServerSystemConfig preserves every root login mode on the wire', () {
    for (final mode in ServerRootLoginMode.values) {
      final decoded = ServerSystemConfig.fromJsonMap(<String, dynamic>{
        'root_login_mode': mode.wireValue,
        'root_login_enabled': mode.rootLoginEnabled,
      });

      expect(decoded.rootLoginMode, mode);
      expect(decoded.toJsonMap()['root_login_mode'], mode.wireValue);
      expect(decoded.toJsonMap()['root_login_enabled'], mode.rootLoginEnabled);
    }
  });

  test('legacy root login booleans migrate to the safer available modes', () {
    final enabled = ServerSystemConfig.fromJsonMap(const <String, dynamic>{
      'root_login_enabled': true,
    });
    final disabled = ServerSystemConfig.fromJsonMap(const <String, dynamic>{
      'root_login_enabled': false,
    });

    expect(enabled.rootLoginMode, ServerRootLoginMode.keyOnly);
    expect(disabled.rootLoginMode, ServerRootLoginMode.disabled);
  });

  test('persisted string booleans decode without weakening safe defaults', () {
    final decoded = ServerSystemConfig.fromJsonMap(const <String, dynamic>{
      'root_login_enabled': 'true',
      'password_auth_enabled': 'false',
      'automatic_security_updates_enabled': 'invalid',
      'auto_reboot_enabled': 1,
    });

    expect(decoded.rootLoginMode, ServerRootLoginMode.keyOnly);
    expect(decoded.passwordAuthEnabled, isFalse);
    expect(decoded.automaticSecurityUpdatesEnabled, isTrue);
    expect(decoded.autoRebootEnabled, isFalse);
  });

  test('copySystemConfig can explicitly select password root access', () {
    const config = ServerSystemConfig();

    final updated = copySystemConfig(
      config,
      rootLoginMode: ServerRootLoginMode.passwordAllowed,
    );

    expect(updated.rootLoginMode, ServerRootLoginMode.passwordAllowed);
    expect(updated.rootLoginEnabled, isTrue);
  });

  test('copySystemConfig keeps legacy boolean callers on safe modes', () {
    const config = ServerSystemConfig(
      rootLoginMode: ServerRootLoginMode.passwordAllowed,
    );

    final enabled = copySystemConfig(config, rootLoginEnabled: true);
    final disabled = copySystemConfig(config, rootLoginEnabled: false);

    expect(enabled.rootLoginMode, ServerRootLoginMode.keyOnly);
    expect(disabled.rootLoginMode, ServerRootLoginMode.disabled);
  });
}
