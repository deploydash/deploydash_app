import '../../../../models/workspace_scope.dart';

/// The Settings tab's one piece of pure logic: whether the workspace selection
/// moved while the delete confirmation was open.
///
/// Extracted by T-3.3.6. The tab is otherwise rendering, which is why its logic
/// file is short -- but this rule is the one that matters. Deleting a project
/// is irreversible and remote, and the confirmation dialog is modal but not
/// instantaneous: between opening it and confirming, the user can switch
/// project or server. Without this check the delete would run against whatever
/// is selected now rather than what was confirmed.
///
/// Reachable before only by pumping the workspace, opening the dialog, and
/// changing the selection underneath it.
bool projectDeletionSelectionChanged({
  required WorkspaceScope? scopeAtConfirm,
  required String projectIdAtConfirm,
  required String? serverIdAtConfirm,
  required WorkspaceScope? currentScope,
  required String? currentProjectId,
  required String? currentServerId,
}) {
  // A project with no server has no scope key to compare, so fall back to
  // comparing the two ids directly rather than treating "no scope" as "no
  // change".
  if (scopeAtConfirm == null) {
    return currentProjectId != projectIdAtConfirm ||
        currentServerId != serverIdAtConfirm;
  }
  return currentScope?.key != scopeAtConfirm.key;
}
