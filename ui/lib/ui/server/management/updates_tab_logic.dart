import '../../../models/container_runtime_status.dart';
import '../../../utils/payload_codecs.dart';

/// The Updates tab's pure logic: the managed-software payload the backend
/// returns, parsed into what the tab renders, plus the labels derived from it.
///
/// Extracted by T-3.3.6. `updates_tab.dart` is a `part` of
/// `server_management_view.dart`, so until now the only way to exercise the
/// three payload shapes this parser accepts -- `managed_software`, the older
/// `capabilities`, and the legacy `tooling` fallback -- was to pump the whole
/// server-management view against a fake engine response.

/// The human-readable status of a managed capability or one of its artifacts.
///
/// One owner: the capability and detail view models carried byte-identical
/// copies of this switch, which is two places for the same five strings to
/// drift apart.
String managedCapabilityStatusLabel(String status) {
  return switch (status) {
    'current' => 'Version current',
    'update_available' => 'Update available',
    'missing' => 'Missing',
    'not_configured' => 'Not enabled',
    _ => 'Needs attention',
  };
}

class ManagedCapabilityViewModel {
  const ManagedCapabilityViewModel({
    required this.id,
    required this.category,
    required this.label,
    required this.description,
    required this.status,
    required this.summary,
    required this.canUpdate,
    required this.canRollback,
    required this.riskLevel,
    required this.actionLabel,
    required this.rollbackLabel,
    required this.details,
    this.serviceStatus,
    this.dataRestoreLabel = '',
    this.dataRestoreRiskLevel = '',
  });

  final String id;
  final String category;
  final String label;
  final String description;
  final String status;
  final String summary;
  final bool canUpdate;
  final bool canRollback;
  final String riskLevel;
  final String actionLabel;
  final String rollbackLabel;
  final List<CapabilityDetailViewModel> details;
  final ContainerRuntimeStatus? serviceStatus;

  /// The engine's label for the explicit data-restoring rollback path,
  /// empty when the capability rolls back exactly one way. Only the
  /// PostgreSQL service offers it.
  final String dataRestoreLabel;

  /// The risk level of that data-restoring path. Kept beside the label so
  /// the tab never guesses which treatment the choice deserves.
  final String dataRestoreRiskLevel;

  factory ManagedCapabilityViewModel.fromMap(
    Map<String, dynamic> payload, {
    required String fallbackId,
  }) {
    final rawDetails = payload['details'];
    final details = rawDetails is List
        ? rawDetails
              .map((value) {
                return CapabilityDetailViewModel.fromMap(mapFrom(value));
              })
              .toList(growable: false)
        : const <CapabilityDetailViewModel>[];
    return ManagedCapabilityViewModel(
      id: payload['id']?.toString() ?? fallbackId,
      category: payload['category']?.toString() ?? 'Server maintenance',
      label: payload['label']?.toString() ?? 'Managed capability',
      description: payload['description']?.toString() ?? '',
      status: payload['status']?.toString() ?? 'missing',
      summary: payload['summary']?.toString() ?? '',
      canUpdate: payload['can_update'] == true,
      canRollback: payload['can_rollback'] == true,
      riskLevel: payload['risk_level']?.toString() ?? 'low',
      actionLabel: payload['action_label']?.toString().trim().isNotEmpty == true
          ? payload['action_label'].toString()
          : 'Update capability',
      rollbackLabel:
          payload['rollback_label']?.toString().trim().isNotEmpty == true
          ? payload['rollback_label'].toString()
          : 'Rollback capability',
      // coverage-gate: postgres_rollback_choice_fields
      dataRestoreLabel: payload['data_restore_label']?.toString() ?? '',
      dataRestoreRiskLevel:
          payload['data_restore_risk_level']?.toString() ?? '',
      // end coverage-gate
      details: details,
      serviceStatus: payload['service_status'] is Map
          ? ContainerRuntimeStatus.fromMap(payload['service_status'])
          : null,
    );
  }

  String get statusLabel => managedCapabilityStatusLabel(status);

  // coverage-gate: postgres_rollback_choice_offer
  /// Whether the backend offers an explicit data-restoring rollback path
  /// for this capability. Only the PostgreSQL service does.
  bool get offersDataRestore => dataRestoreLabel.isNotEmpty;
  // end coverage-gate
}

/// The answer from the PostgreSQL rollback choice dialog.
///
/// Managed PostgreSQL updates never cross a major version, so rolling back
/// only swaps the image and keeps every row ([keepData]). Replaying the
/// pre-update backup ([restoreData]) is the explicit destructive alternative.
enum PostgresRollbackChoice { keepData, restoreData }

class CapabilityDetailViewModel {
  const CapabilityDetailViewModel({
    required this.label,
    required this.status,
    required this.current,
    required this.target,
  });

  final String label;
  final String status;
  final String current;
  final String target;

  factory CapabilityDetailViewModel.fromMap(Map<String, dynamic> payload) {
    return CapabilityDetailViewModel(
      label: payload['label']?.toString() ?? 'Managed artifact',
      status: payload['status']?.toString() ?? 'missing',
      current: payload['current']?.toString() ?? '',
      target: payload['target']?.toString() ?? '',
    );
  }

  String get statusLabel => managedCapabilityStatusLabel(status);
}

Map<String, ManagedCapabilityViewModel> parseManagedCapabilities(
  Map<String, dynamic> result,
) {
  final rawCapabilities = result['capabilities'];
  final rawManagedSoftware = result['managed_software'];
  if (rawManagedSoftware is Map) {
    final capabilities = <String, ManagedCapabilityViewModel>{};
    for (final entry in rawManagedSoftware.entries) {
      final id = entry.key.toString();
      final payload = mapFrom(entry.value);
      capabilities[id] = ManagedCapabilityViewModel.fromMap(
        payload,
        fallbackId: id,
      );
    }
    return capabilities;
  }
  if (rawCapabilities is Map) {
    final capabilities = <String, ManagedCapabilityViewModel>{};
    for (final entry in rawCapabilities.entries) {
      final id = entry.key.toString();
      final payload = mapFrom(entry.value);
      capabilities[id] = ManagedCapabilityViewModel.fromMap(
        payload,
        fallbackId: id,
      );
    }
    return capabilities;
  }
  final legacyTooling = result['tooling'];
  if (legacyTooling is! Map) {
    return const <String, ManagedCapabilityViewModel>{};
  }
  final details = legacyTooling.values
      .whereType<Map<dynamic, dynamic>>()
      .map((value) => CapabilityDetailViewModel.fromMap(mapFrom(value)))
      .toList(growable: false);
  final status = details.any((detail) => detail.status != 'current')
      ? 'update_available'
      : 'current';
  return {
    'railpack_build_system': ManagedCapabilityViewModel(
      id: 'railpack_build_system',
      category: 'Build and deployment',
      label: 'Railpack build system',
      description:
          'Builds web app images from source repositories with one managed Railpack contract.',
      status: status,
      summary: status == 'current'
          ? 'Railpack build system is current'
          : 'Railpack build system needs an update',
      canUpdate: status != 'current',
      canRollback: false,
      riskLevel: 'low',
      actionLabel: 'Update Railpack build system',
      rollbackLabel: 'Rollback Railpack build system',
      details: details,
    ),
  };
}

/// Ids of the capabilities that both can be and need to be updated.
List<String> updateableCapabilityIds(
  Map<String, ManagedCapabilityViewModel> capabilities,
) {
  return capabilities.values
      .where((capability) {
        return capability.canUpdate && capability.status != 'current';
      })
      .map((capability) => capability.id)
      .toList(growable: false);
}

/// The update button's label for the current capability set.
///
/// Names the single capability when exactly one needs updating, so the user
/// reads what will happen rather than a count.
String managedUpdateButtonLabel({
  required Map<String, ManagedCapabilityViewModel> capabilities,
  required bool isUpdating,
}) {
  if (isUpdating) {
    return 'Updating...';
  }
  final updateable = updateableCapabilityIds(capabilities);
  if (updateable.length == 1) {
    final onlyId = updateable.single;
    // Found by `id`, not by map key. `ManagedCapabilityViewModel` takes its id
    // from the payload and only falls back to the key it was stored under, so
    // the two can differ and `capabilities[onlyId]` would then be null. The id
    // came from `capabilities.values`, so this cannot fail to find one.
    return capabilities.values
        .firstWhere((capability) => capability.id == onlyId)
        .actionLabel;
  }
  if (updateable.length > 1) {
    return 'Update all available';
  }
  return 'Managed software up to date';
}

String managedCapabilityRiskLabel(String riskLevel) {
  return switch (riskLevel) {
    'low' => 'Low',
    'medium' => 'Medium',
    'high' => 'High',
    'destructive' => 'Destructive',
    _ => 'Needs review',
  };
}
