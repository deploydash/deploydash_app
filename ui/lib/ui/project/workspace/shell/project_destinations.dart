import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';

import '../../../../models/project_destination.dart';

export '../../../../models/project_destination.dart';

/// Presentation icon for a shared workspace destination value.
extension ProjectDestinationIcon on ProjectDestination {
  IconData get icon {
    return switch (id) {
      'web-app' => YaruIcons.app_grid,
      'workers' => Icons.work_outline,
      'database' => YaruIcons.drive_harddisk,
      'email' => YaruIcons.mail,
      'domain' => YaruIcons.globe,
      'backup' => Icons.backup,
      'scheduler' => Icons.schedule,
      'log' => Icons.receipt_long,
      'settings' => YaruIcons.settings,
      _ => Icons.question_mark_outlined,
    };
  }
}
