/// A repository the signed-in GitHub account may deploy from.
class GitHubRepository {
  /// Creates a repository description.
  const GitHubRepository({
    required this.name,
    required this.fullName,
    required this.isPrivate,
  });

  /// Repository name without its owner, as GitHub displays it.
  final String name;

  /// `owner/name`, which is the form every deploy payload carries.
  final String fullName;

  /// Whether cloning it needs the deploy key rather than anonymous HTTPS.
  final bool isPrivate;
}

/// Fetches the repositories visible to [accessToken].
///
/// A typedef rather than an interface so the provider layer can inject a fake
/// without the models layer knowing that the real one talks to GitHub.
typedef GitHubRepositoryReader =
    Future<List<GitHubRepository>> Function({required String accessToken});
