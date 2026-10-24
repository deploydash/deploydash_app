import '../domain/project.dart';
import '../utils/project_slug.dart';

final RegExp _repositoryPattern = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');
final RegExp _branchPattern = RegExp(r'^[A-Za-z0-9._/-]+$');

// Stand-ins for saved values that fail validation. See
// [buildRuntimeLogSettings] for why substituting them is safe here.
const String _placeholderRepository = 'example-org/example-repo';
const String _placeholderBranch = 'main';
const int _placeholderAppPort = 3000;

/// Builds the `settings` payload for the `app/runtime_logs` engine operation.
///
/// One owner, shared by the Logs workspace and the Agent Access MCP endpoint.
/// It used to live in `ui/project/workspace/logs/log_tab_logic.dart`, which a
/// provider cannot import without reversing the desktop layer direction, so
/// `agent_access_service.dart` carried a verbatim second copy of the whole
/// thing — the regexes and the slug included. Moving the read model to a layer
/// both callers can reach is what removes the copy rather than the rule that
/// forbade the import (T-3.5.2).
///
/// A value that fails validation is replaced with a placeholder rather than
/// rejected. This operation only reads logs, and a malformed saved branch
/// should not stop a user seeing why their app is failing.
///
/// **Which of these the operation actually reads.** `project_slug` alone
/// selects the container: `app_config.container_name` is
/// `server_identifiers.app_container(project_slug)`, and nothing in the
/// `app/runtime_logs` path consults the other three. They are here because
/// `params_schema` requires the complete settings shape before the handler
/// runs, not because their values mean anything to it — which is what makes
/// substituting a placeholder safe rather than merely convenient. Verified
/// against `app_runtime_parts/runtime_operation_plans.py` on 2026-09-04.
///
/// The placeholders are named rather than inlined, so a reader who finds
/// `example-org/example-repo` in a log or a request body can tell it is this
/// substitution and not a real saved value. Do not reuse them for an
/// operation that reads these fields; add validation there instead.
Map<String, dynamic> buildRuntimeLogSettings(Project project) {
  final normalizedRepository = project.repositoryFullName?.trim();
  final normalizedBranch = project.deployBranch.trim();
  final normalizedPort = project.appPort;

  return <String, dynamic>{
    'project_slug': slugifyProjectName(project.name),
    'repository_full_name':
        normalizedRepository != null &&
            _repositoryPattern.hasMatch(normalizedRepository)
        ? normalizedRepository
        : _placeholderRepository,
    'branch': _branchPattern.hasMatch(normalizedBranch)
        ? normalizedBranch
        : _placeholderBranch,
    // Always null: the log read does not route by domain, and sending a saved
    // domain here would imply it does.
    'primary_domain': null,
    'app_port': normalizedPort >= 1 && normalizedPort <= 65535
        ? normalizedPort
        : _placeholderAppPort,
  };
}
