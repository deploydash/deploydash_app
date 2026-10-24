import 'package:ui/models/workspace_scope.dart';
import 'package:ui/ui/project/workspace/settings/settings_tab_logic.dart';
import 'package:flutter_test/flutter_test.dart';

/// The guard that stops a confirmed delete running against a different project.
///
/// Deleting is irreversible and remote, and the confirmation dialog is modal
/// but not instantaneous. Before T-3.3.6 this rule could only be reached by
/// pumping the workspace, opening the dialog, and changing the selection
/// underneath it.
void main() {
  const blogOnProd = WorkspaceScope(
    projectId: 'project-blog',
    serverId: 'server-prod',
  );
  const shopOnProd = WorkspaceScope(
    projectId: 'project-shop',
    serverId: 'server-prod',
  );
  const blogOnStaging = WorkspaceScope(
    projectId: 'project-blog',
    serverId: 'server-staging',
  );

  group('with a scoped project', () {
    test('an unchanged selection proceeds', () {
      expect(
        projectDeletionSelectionChanged(
          scopeAtConfirm: blogOnProd,
          projectIdAtConfirm: 'project-blog',
          serverIdAtConfirm: 'server-prod',
          currentScope: blogOnProd,
          currentProjectId: 'project-blog',
          currentServerId: 'server-prod',
        ),
        isFalse,
      );
    });

    test('a different project is refused', () {
      expect(
        projectDeletionSelectionChanged(
          scopeAtConfirm: blogOnProd,
          projectIdAtConfirm: 'project-blog',
          serverIdAtConfirm: 'server-prod',
          currentScope: shopOnProd,
          currentProjectId: 'project-shop',
          currentServerId: 'server-prod',
        ),
        isTrue,
      );
    });

    test('the same project on another server is refused', () {
      // The project id alone is not enough: the same project on a different
      // server is a different set of remote resources.
      expect(
        projectDeletionSelectionChanged(
          scopeAtConfirm: blogOnProd,
          projectIdAtConfirm: 'project-blog',
          serverIdAtConfirm: 'server-prod',
          currentScope: blogOnStaging,
          currentProjectId: 'project-blog',
          currentServerId: 'server-staging',
        ),
        isTrue,
      );
    });

    test('losing the selection entirely is refused', () {
      expect(
        projectDeletionSelectionChanged(
          scopeAtConfirm: blogOnProd,
          projectIdAtConfirm: 'project-blog',
          serverIdAtConfirm: 'server-prod',
          currentScope: null,
          currentProjectId: null,
          currentServerId: null,
        ),
        isTrue,
      );
    });
  });

  group('with an unscoped project', () {
    // A project with no server has no scope key, so the ids are compared
    // directly rather than treating "no scope" as "nothing changed".
    test('an unchanged serverless selection proceeds', () {
      expect(
        projectDeletionSelectionChanged(
          scopeAtConfirm: null,
          projectIdAtConfirm: 'project-blog',
          serverIdAtConfirm: null,
          currentScope: null,
          currentProjectId: 'project-blog',
          currentServerId: null,
        ),
        isFalse,
      );
    });

    test('a different project is refused', () {
      expect(
        projectDeletionSelectionChanged(
          scopeAtConfirm: null,
          projectIdAtConfirm: 'project-blog',
          serverIdAtConfirm: null,
          currentScope: null,
          currentProjectId: 'project-shop',
          currentServerId: null,
        ),
        isTrue,
      );
    });

    test('gaining a server is refused', () {
      // The project was serverless when confirmed and now has one, so the
      // delete would reach resources the user never saw.
      expect(
        projectDeletionSelectionChanged(
          scopeAtConfirm: null,
          projectIdAtConfirm: 'project-blog',
          serverIdAtConfirm: null,
          currentScope: blogOnProd,
          currentProjectId: 'project-blog',
          currentServerId: 'server-prod',
        ),
        isTrue,
      );
    });
  });
}
