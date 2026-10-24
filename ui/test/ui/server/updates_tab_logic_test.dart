import 'package:ui/ui/server/management/updates_tab_logic.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Updates tab's payload parsing, exercised without the server-management
/// widget.
///
/// `updates_tab.dart` is a `part` of `server_management_view.dart`, so before
/// T-3.3.6 the only way to reach the three payload shapes this parser accepts
/// was to pump the whole view against a fake engine response. The shapes are a
/// wire contract with the backend, which is exactly the kind of thing that
/// should be assertable as a value.
void main() {
  group('parseManagedCapabilities', () {
    test('reads the current managed_software shape', () {
      final capabilities = parseManagedCapabilities(<String, dynamic>{
        'managed_software': <String, dynamic>{
          'http_gateway': <String, dynamic>{
            'id': 'http_gateway',
            'category': 'Traffic',
            'label': 'HTTP gateway',
            'description': 'Caddy reverse proxy.',
            'status': 'update_available',
            'summary': 'Caddy needs an update',
            'can_update': true,
            'can_rollback': true,
            'risk_level': 'medium',
            'action_label': 'Update HTTP gateway',
            'rollback_label': 'Roll back HTTP gateway',
            'details': <dynamic>[
              <String, dynamic>{
                'label': 'Caddy image',
                'status': 'update_available',
                'current': '2.11.1',
                'target': '2.11.2',
              },
            ],
          },
        },
      });

      final gateway = capabilities['http_gateway']!;
      expect(gateway.label, 'HTTP gateway');
      expect(gateway.status, 'update_available');
      expect(gateway.statusLabel, 'Update available');
      expect(gateway.canUpdate, isTrue);
      expect(gateway.canRollback, isTrue);
      expect(gateway.actionLabel, 'Update HTTP gateway');
      expect(gateway.details.single.current, '2.11.1');
      expect(gateway.details.single.target, '2.11.2');
      expect(gateway.details.single.statusLabel, 'Update available');
    });

    test('falls back to the older capabilities shape', () {
      final capabilities = parseManagedCapabilities(<String, dynamic>{
        'capabilities': <String, dynamic>{
          'dns_service': <String, dynamic>{'status': 'current'},
        },
      });

      final dns = capabilities['dns_service']!;
      // The key is the fallback id when the payload carries none.
      expect(dns.id, 'dns_service');
      expect(dns.status, 'current');
      expect(dns.statusLabel, 'Version current');
      // Defaults, so a sparse payload still renders something sensible.
      expect(dns.category, 'Server maintenance');
      expect(dns.label, 'Managed capability');
      expect(dns.actionLabel, 'Update capability');
      expect(dns.canUpdate, isFalse);
    });

    test('synthesises one capability from the legacy tooling shape', () {
      final capabilities = parseManagedCapabilities(<String, dynamic>{
        'tooling': <String, dynamic>{
          'railpack': <String, dynamic>{
            'label': 'Railpack',
            'status': 'update_available',
            'current': 'v0.29.0',
            'target': 'v0.30.0',
          },
          'buildkit': <String, dynamic>{
            'label': 'BuildKit',
            'status': 'current',
          },
        },
      });

      // The legacy shape has no capability grouping, so the whole of it
      // becomes one Railpack capability whose status is the worst of its parts.
      expect(capabilities.keys, <String>['railpack_build_system']);
      final railpack = capabilities['railpack_build_system']!;
      expect(railpack.status, 'update_available');
      expect(railpack.summary, 'Railpack build system needs an update');
      expect(railpack.canUpdate, isTrue);
      expect(railpack.canRollback, isFalse);
      expect(railpack.details, hasLength(2));
    });

    test('a legacy payload with everything current reports current', () {
      final capabilities = parseManagedCapabilities(<String, dynamic>{
        'tooling': <String, dynamic>{
          'railpack': <String, dynamic>{'status': 'current'},
        },
      });

      final railpack = capabilities['railpack_build_system']!;
      expect(railpack.status, 'current');
      expect(railpack.summary, 'Railpack build system is current');
      expect(railpack.canUpdate, isFalse);
    });

    test(
      'an unrecognised payload yields no capabilities rather than throwing',
      () {
        expect(parseManagedCapabilities(const <String, dynamic>{}), isEmpty);
        expect(
          parseManagedCapabilities(const <String, dynamic>{
            'tooling': 'nonsense',
          }),
          isEmpty,
        );
      },
    );
  });

  group('derived labels', () {
    ManagedCapabilityViewModel capability({
      required String id,
      required String status,
      bool canUpdate = true,
      String actionLabel = 'Update it',
    }) {
      return ManagedCapabilityViewModel(
        id: id,
        category: 'Traffic',
        label: id,
        description: '',
        status: status,
        summary: '',
        canUpdate: canUpdate,
        canRollback: false,
        riskLevel: 'low',
        actionLabel: actionLabel,
        rollbackLabel: 'Roll it back',
        details: const <CapabilityDetailViewModel>[],
      );
    }

    test('only capabilities that can and should update are offered', () {
      final capabilities = <String, ManagedCapabilityViewModel>{
        'a': capability(id: 'a', status: 'update_available'),
        // Needs an update but the server cannot apply it.
        'b': capability(id: 'b', status: 'update_available', canUpdate: false),
        // Can update, but there is nothing to do.
        'c': capability(id: 'c', status: 'current'),
      };

      expect(updateableCapabilityIds(capabilities), <String>['a']);
    });

    test(
      'the button names the one capability when only one needs updating',
      () {
        final one = <String, ManagedCapabilityViewModel>{
          'a': capability(
            id: 'a',
            status: 'update_available',
            actionLabel: 'Update HTTP gateway',
          ),
          'b': capability(id: 'b', status: 'current'),
        };

        expect(
          managedUpdateButtonLabel(capabilities: one, isUpdating: false),
          'Update HTTP gateway',
        );
      },
    );

    test('the button counts nothing and states the outcome instead', () {
      final many = <String, ManagedCapabilityViewModel>{
        'a': capability(id: 'a', status: 'update_available'),
        'b': capability(id: 'b', status: 'update_available'),
      };
      final none = <String, ManagedCapabilityViewModel>{
        'a': capability(id: 'a', status: 'current'),
      };

      expect(
        managedUpdateButtonLabel(capabilities: many, isUpdating: false),
        'Update all available',
      );
      expect(
        managedUpdateButtonLabel(capabilities: none, isUpdating: false),
        'Managed software up to date',
      );
      expect(
        managedUpdateButtonLabel(capabilities: many, isUpdating: true),
        'Updating...',
      );
    });

    test('status and risk read as plain English', () {
      expect(managedCapabilityStatusLabel('current'), 'Version current');
      expect(managedCapabilityStatusLabel('not_configured'), 'Not enabled');
      expect(managedCapabilityStatusLabel('anything-else'), 'Needs attention');
      expect(managedCapabilityRiskLabel('destructive'), 'Destructive');
      expect(managedCapabilityRiskLabel('anything-else'), 'Needs review');
    });

    test('only a capability with a restore label offers data restore', () {
      final capabilities = parseManagedCapabilities(<String, dynamic>{
        'managed_software': <String, dynamic>{
          'postgresql_database_service': <String, dynamic>{
            'id': 'postgresql_database_service',
            'status': 'current',
            'data_restore_label': 'Restore data from the pre-update backup',
            'data_restore_risk_level': 'destructive',
          },
          'http_gateway': <String, dynamic>{
            'id': 'http_gateway',
            'status': 'current',
          },
        },
      });

      final postgres = capabilities['postgresql_database_service']!;
      expect(
        postgres.dataRestoreLabel,
        'Restore data from the pre-update backup',
      );
      expect(postgres.dataRestoreRiskLevel, 'destructive');
      expect(postgres.offersDataRestore, isTrue);

      final gateway = capabilities['http_gateway']!;
      expect(gateway.dataRestoreLabel, isEmpty);
      expect(gateway.offersDataRestore, isFalse);
    });
  });
}
