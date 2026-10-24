part of '../../agent_access_service.dart';

/// Tools listing the connected GitHub account's repositories and branches,
/// and the connection snapshot the redeploy preview validates against.
extension _AgentAccessGitHubTools on AgentAccessService {
  // coverage-gate: reply_list_github_repositories
  Future<AgentAccessReply> _replyListGitHubRepositories() async {
    final snapshot = await _readGitHubRepositorySnapshot();
    await _audit(
      toolName: 'list_github_repositories',
      accessLevel: 'read_only',
      status: 'success',
      summary: snapshot.connected
          ? 'Listed connected GitHub repositories.'
          : 'GitHub is disconnected for agent access.',
      details: <String, dynamic>{'count': snapshot.repositories.length},
    );
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'github_connected': snapshot.connected,
      'reconnect_required': !snapshot.connected,
      'message': snapshot.message,
      'repositories': snapshot.repositories
          .map(
            (repository) => <String, dynamic>{
              'name': repository.name,
              'full_name': repository.fullName,
              'is_private': repository.isPrivate,
            },
          )
          .toList(growable: false),
    });
  }
  // end coverage-gate

  Future<AgentAccessReply> _replyListRepositoryBranches(
    String repositoryFullName,
  ) async {
    if (repositoryFullName.trim().isEmpty) {
      return const AgentAccessReply(HttpStatus.badRequest, <String, dynamic>{
        'error': 'invalid_repository',
        'message': 'repository_full_name is required.',
      });
    }
    final snapshot = await _readGitHubRepositorySnapshot();
    if (!snapshot.connected) {
      return AgentAccessReply(HttpStatus.preconditionFailed, <String, dynamic>{
        'error': 'github_reconnect_required',
        'message': snapshot.message ?? 'Reconnect GitHub first.',
      });
    }
    try {
      final branches = await ref
          .read(gitHubIntegrationProvider.notifier)
          .listRepositoryBranches(repositoryFullName);
      await _audit(
        toolName: 'list_repository_branches',
        accessLevel: 'read_only',
        status: 'success',
        summary: 'Listed repository branches for agent redeploy selection.',
        details: <String, dynamic>{'repository_full_name': repositoryFullName},
      );
      return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
        'repository_full_name': repositoryFullName,
        'branches': branches,
      });
    } catch (error) {
      return AgentAccessReply(HttpStatus.preconditionFailed, <String, dynamic>{
        'error': 'github_reconnect_required',
        'message': 'GitHub branch listing failed: $error',
      });
    }
  }

  Future<_GitHubRepositorySnapshot> _readGitHubRepositorySnapshot() async {
    final token = await ref
        .read(gitHubSecretRepositoryProvider)
        .readAuthToken();
    if (token == null || token.trim().isEmpty) {
      return const _GitHubRepositorySnapshot(
        connected: false,
        message: 'GitHub is not connected. Reconnect GitHub first.',
      );
    }
    try {
      final repositories = await ref
          .read(gitHubAuthGatewayProvider)
          .fetchRepositories(accessToken: token);
      return _GitHubRepositorySnapshot(
        connected: true,
        repositories: repositories,
        message: repositories.isEmpty
            ? 'GitHub connected. No repositories found.'
            : 'GitHub connected.',
      );
    } catch (error) {
      return _GitHubRepositorySnapshot(
        connected: false,
        message: 'GitHub repository listing failed: $error',
      );
    }
  }
}

class _GitHubRepositorySnapshot {
  const _GitHubRepositorySnapshot({
    required this.connected,
    this.repositories = const <GitHubRepository>[],
    this.message,
  });

  final bool connected;
  final List<GitHubRepository> repositories;
  final String? message;
}
