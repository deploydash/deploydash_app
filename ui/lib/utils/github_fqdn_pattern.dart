/// The shape a fully-qualified domain name must have for Deploy Dash.
///
/// One owner (D-26 family B): eight validators — the github provider,
/// agent access, the project web-app read model, the deletion
/// coordinator, the workspace shell, the workers tab, and the two
/// app-deployment dialog validators — all compiled this same pattern.
/// The per-site guards (trim, lowercase, `not configured`, null-vs-false)
/// stay at the call sites — only the pattern string is shared.
final RegExp githubFqdnPattern = RegExp(
  r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$',
);
