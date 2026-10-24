part of '../server_management_view.dart';

/// Asks whether to migrate the database into the named volume.
///
/// A plain confirm, not the DELETE-typing flow: migration keeps the old
/// copy behind, so there is nothing irreversible to type for. Dismissing
/// the dialog reads as declining.
Future<bool> _showMigratePostgresStorageDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AppFormDialog(
      key: const Key('service-migrate-storage-dialog'),
      title: postgresStorageMigrateDialogTitle(),
      description: postgresStorageMigrateDialogDescription(),
      maxWidth: 460,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('service-migrate-storage-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(postgresStorageMigrateDialogConfirm()),
        ),
      ],
      child: Text(postgresStorageMigrateDialogNote()),
    ),
  );
  return result ?? false;
}
