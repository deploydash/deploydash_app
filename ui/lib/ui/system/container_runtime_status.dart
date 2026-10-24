import 'package:flutter/material.dart';

import '../../models/container_runtime_status.dart';

export '../../models/container_runtime_status.dart';

/// Presentation color for a shared container-runtime value.
extension ContainerRuntimeStatusColor on ContainerRuntimeStatus {
  /// The colour a status badge uses for this state.
  ///
  /// Lives in `ui/` and not on the model: colour is presentation, and
  /// `models/` may not import Flutter. Mostly theme colours so it follows the
  /// user's scheme; green and orange are literal because "running" and
  /// "stopped" have no scheme role that means them.
  Color color(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (effectiveStatus) {
      ContainerRuntimeEffectiveStatus.ready => Colors.green,
      ContainerRuntimeEffectiveStatus.starting ||
      ContainerRuntimeEffectiveStatus.restarting ||
      ContainerRuntimeEffectiveStatus.provisioning => scheme.primary,
      ContainerRuntimeEffectiveStatus.unhealthy ||
      ContainerRuntimeEffectiveStatus.missing => scheme.error,
      ContainerRuntimeEffectiveStatus.stopped => Colors.orange,
      ContainerRuntimeEffectiveStatus.notConfigured ||
      ContainerRuntimeEffectiveStatus.unknown => scheme.onSurfaceVariant,
    };
  }
}
