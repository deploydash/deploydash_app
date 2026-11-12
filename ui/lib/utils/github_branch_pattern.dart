/// The shape a git branch name must have for Deploy Dash deploys.
///
/// One owner (D-26 family B): the github provider, agent access, the two
/// app-deployment dialog validators, and the runtime-log settings builder
/// all compiled this same pattern. The trim/empty guards stay at the call
/// sites — only the pattern string is shared.
final RegExp githubBranchPattern = RegExp(r'^[A-Za-z0-9._/-]+$');
