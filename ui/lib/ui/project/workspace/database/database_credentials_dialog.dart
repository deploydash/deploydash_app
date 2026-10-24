part of '../../project_workspace.dart';

extension _DatabaseCredentialsDialog on _DatabaseTabViewState {
  Future<void> _showCredentialsDialog({
    required String title,
    required String message,
    String? password,
    String? connectionUri,
  }) async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AppDialogScaffold(
          key: const Key('database-credentials-dialog'),
          title: title,
          actions: [
            if (connectionUri != null && connectionUri.isNotEmpty)
              OutlinedButton.icon(
                key: const Key('database-credentials-copy-button'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: connectionUri));
                  Navigator.of(dialogContext).pop();
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            TextButton(
              key: const Key('database-credentials-close-button'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
          child: SizedBox(
            width: 420,
            child: AppFormSection(
              children: [
                Text(message),
                if (password != null && password.isNotEmpty)
                  _LabeledValueRow(label: 'Password', value: password),
                if (connectionUri != null && connectionUri.isNotEmpty)
                  _LabeledValueRow(label: 'Connection', value: connectionUri),
              ],
            ),
          ),
        );
      },
    );
  }
}
