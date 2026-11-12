/// The `owner/name` shape a GitHub repository full name must have.
///
/// One owner (D-26): the gateway validated this inline in both
/// `fetchBranches` and `registerDeployKey`, and the runtime-log settings
/// builder carries the same pattern for its placeholder substitution. The
/// call shapes differ (throw vs substitute), so only the pattern string is
/// shared — each site keeps its own verdict contract.
final RegExp githubRepositoryFullNamePattern = RegExp(
  r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$',
);
