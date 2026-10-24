part of '../server_management_view.dart';

Future<bool> _showDeleteDatabaseConfirmationDialog(BuildContext context) {
  return _showDeleteServiceConfirmationDialog(
    context: context,
    serviceName: 'database service',
    warning:
        'This will permanently remove the PostgreSQL container, configuration, and all database data from this server.',
    acknowledgeLabel: 'I understand this action permanently deletes all data.',
    dialogKey: const Key('service-delete-dialog-database'),
  );
}

Future<bool> _showDeleteServiceConfirmationDialog({
  required BuildContext context,
  required String serviceName,
  required String warning,
  required String acknowledgeLabel,
  required Key dialogKey,
}) async {
  final confirmationController = TextEditingController();
  var acknowledge = false;

  ModalRoute<void>? dialogRoute;
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      dialogRoute ??= ModalRoute.of(dialogContext);
      return StatefulBuilder(
        builder: (context, setDialogState) {
          final typedConfirm =
              confirmationController.text.trim().toUpperCase() == 'DELETE';
          final canDelete = acknowledge && typedConfirm;

          return AppDestructiveConfirmDialog(
            key: dialogKey,
            title: 'Delete $serviceName',
            description: warning,
            confirmLabel: 'Delete',
            confirmButtonKey: const Key('service-delete-confirm-button'),
            confirmEnabled: canDelete,
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppCheckboxField(
                  value: acknowledge,
                  onChanged: (value) {
                    setDialogState(() => acknowledge = value ?? false);
                  },
                  title: acknowledgeLabel,
                ),
                const SizedBox(height: 8),
                AppTextFormField(
                  key: const Key('service-delete-confirm-input'),
                  controller: confirmationController,
                  labelText: 'Type DELETE to confirm',
                  onChanged: (_) => setDialogState(() {}),
                ),
              ],
            ),
          );
        },
      );
    },
  );

  // The dialog subtree stays mounted through the exit transition, and the
  // focused text field can still rebuild against this controller while focus
  // settles (its listeners re-subscribe on rebuild). Disposing right after
  // pop crashes those exit frames with a used-after-dispose, so release the
  // controller only once the route itself is gone.
  try {
    await dialogRoute?.completed;
  } finally {
    confirmationController.dispose();
  }
  return result ?? false;
}
