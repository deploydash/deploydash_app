part of '../server_management_view.dart';

/// Asks which major version to move the database to.
///
/// Returns the chosen target, or null when the dialog is cancelled or
/// dismissed. The current version is excluded from the picker: confirming
/// the running version would be a no-op upgrade, so it is not offered.
Future<String?> _showPostgresUpgradeDialog({
  required BuildContext context,
  required String currentVersion,
}) async {
  final targets =
      ServerPostgresConfig.supportedVersions
          .where((version) => version != currentVersion)
          .toList(growable: false)
        ..sort();
  var selectedTarget = postgresUpgradeDefaultTarget(currentVersion);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AppFormDialog(
            key: const Key('service-upgrade-major-dialog'),
            title: postgresUpgradeDialogTitle(),
            description: postgresUpgradeDialogDescription(),
            maxWidth: 460,
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('service-upgrade-major-confirm'),
                onPressed: () =>
                    Navigator.of(dialogContext).pop(selectedTarget),
                child: Text(postgresUpgradeDialogConfirm()),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppSelectFormField<String>(
                  key: const Key('postgres-upgrade-target-dropdown'),
                  value: selectedTarget,
                  labelText: 'Target version',
                  helperText:
                      'The database restarts on this version after the move.',
                  items: [
                    for (final target in targets)
                      DropdownMenuItem(
                        value: target,
                        child: Text(target == '18' ? '18 (newest)' : target),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setDialogState(() => selectedTarget = value);
                  },
                ),
                const SizedBox(height: 12),
                Text(postgresUpgradeDialogNote()),
              ],
            ),
          );
        },
      );
    },
  );
}
