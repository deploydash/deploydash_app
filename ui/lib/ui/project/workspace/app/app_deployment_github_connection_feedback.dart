part of '../../project_workspace.dart';

class _GitHubConnectionFeedback extends StatelessWidget {
  const _GitHubConnectionFeedback({
    required this.gitState,
    required this.onCopyAuthorizationUrl,
  });

  final GitHubIntegrationState gitState;
  final Future<void> Function(String authorizationUrl) onCopyAuthorizationUrl;

  @override
  Widget build(BuildContext context) {
    final status = gitState.connectStatus;
    final shouldShow =
        status != GitHubConnectStatus.disconnected ||
        (gitState.authorizationUrl?.trim().isNotEmpty ?? false);
    if (!shouldShow) return const SizedBox.shrink();
    final busy =
        status == GitHubConnectStatus.launchingBrowser ||
        status == GitHubConnectStatus.awaitingCallback ||
        status == GitHubConnectStatus.exchangingCode ||
        status == GitHubConnectStatus.loadingRepositories;
    final failed = status == GitHubConnectStatus.error;
    final authorizationUrl = gitState.authorizationUrl?.trim();
    final canCopyUrl = authorizationUrl != null && authorizationUrl.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        key: const Key('github-connect-feedback'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (busy)
                const SizedBox(
                  key: Key('github-connect-progress'),
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  failed ? Icons.error_outline : Icons.check_circle_outline,
                  size: 16,
                  color: failed ? YaruColors.red : Colors.green,
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  gitState.statusMessage,
                  key: const Key('github-connect-status-message'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (canCopyUrl &&
              (status == GitHubConnectStatus.awaitingCallback || failed)) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('github-copy-oauth-url-button'),
                  onPressed: () => onCopyAuthorizationUrl(authorizationUrl),
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy authorization link'),
                ),
                OutlinedButton.icon(
                  key: const Key('github-open-oauth-url-button'),
                  onPressed: () => openExternalUrl(authorizationUrl),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open GitHub'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
