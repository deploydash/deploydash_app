import 'package:flutter/material.dart';

import '../system/app_copy.dart';
import '../system/app_sections.dart';

/// The once-ever telemetry nag, rendered at the top of Home.
///
/// Shown only after the first deploy on installs where usage reporting was
/// explicitly switched off. Sharing switches reporting back on; dismissing
/// records the nag so it never appears again.
class HomeTelemetryNagCard extends StatelessWidget {
  const HomeTelemetryNagCard({
    super.key,
    required this.onShare,
    required this.onDismiss,
  });

  final VoidCallback onShare;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
      key: const Key('home-telemetry-nag-card'),
      icon: Icons.insights_outlined,
      title: telemetryHelpImproveTitle(),
      subtitle: telemetryNagCardDescription(),
      headerAction: TextButton(
        key: const Key('home-telemetry-nag-dismiss-button'),
        onPressed: onDismiss,
        child: Text(telemetryNagDismissLabel()),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          key: const Key('home-telemetry-nag-share-button'),
          onPressed: onShare,
          child: Text(telemetryNagShareLabel()),
        ),
      ),
    );
  }
}
