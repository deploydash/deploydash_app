/// Coarse user attributes for cohort analysis.
///
/// Closed by construction: call sites pass enum values, never strings, so a
/// typo is a compile error. Each value maps to one analytics storage key via
/// [storageKey] (exhaustive switch, no default -- adding a value without a
/// key fails compilation). Values stay coarse forever: lifecycle milestones
/// and install facts, never identity, never free text.
///
/// Lives in `models/` rather than beside the analytics service so the
/// preferences repository (data layer, which owns the milestone columns) can
/// take it as a parameter without importing the service layer above it.
///
/// The last three values are computed value-metric buckets, not persisted
/// milestones: lifecycle providers recompute them from live counts on every
/// change and report them via `setUserAttribute`, so recording one through
/// the milestone store is a documented no-op.
enum AppUserAttribute {
  /// The user completed server onboarding at least once.
  hasCompletedOnboarding,

  /// The user completed their first deploy at least once.
  hasFirstDeploySucceeded,

  /// The user connected GitHub at least once.
  hasConnectedGitHub,

  /// Coarse saved-server count: `0`, `1`, `2`, or `3plus`. Never the count.
  serverCountBucket,

  /// Coarse project count: `0`, `1`, `2`, or `3plus`. Never the count.
  projectCountBucket,

  /// Coarse successful deploys in the trailing 7 days: `0`, `1`, `2`, or
  /// `3plus`. Never timestamps, names, or addresses.
  deploysPerWeekBucket;

  /// The analytics storage key for this attribute.
  String get storageKey {
    switch (this) {
      case AppUserAttribute.hasCompletedOnboarding:
        return 'has_completed_onboarding';
      case AppUserAttribute.hasFirstDeploySucceeded:
        return 'has_first_deploy_succeeded';
      case AppUserAttribute.hasConnectedGitHub:
        return 'has_connected_github';
      case AppUserAttribute.serverCountBucket:
        return 'server_count_bucket';
      case AppUserAttribute.projectCountBucket:
        return 'project_count_bucket';
      case AppUserAttribute.deploysPerWeekBucket:
        return 'deploys_per_week_bucket';
    }
  }
}
