import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/e2e_checklist.dart';

/// Architecture invariant: one owner per GitHub-integration concept.
///
/// T-037 (issue #38, D-26): the paged-GET loop, session-expiry reset, hint
/// scan, OAuth failure reset, connected message, idle select-reset, FQDN /
/// branch validation, and slugification each live in exactly one place.
/// This guard fails if a converted site regrows its own copy.
///
/// Deliberate non-owner hits, pinned below: the connected-message 5th site
/// in `agent_access/tools/github.dart` keeps its own sentence (different
/// second branch — record-left per the ticket), and the workspace-shell
/// null-adapter keeps its explicit `null` mapping on top of the bool owner.
int _count(String source, Pattern pattern) => pattern.allMatches(source).length;

String _readLib(Directory root, String relativePath) {
  final file = File('${root.path}/ui/lib/$relativePath');
  expect(
    file.existsSync(),
    isTrue,
    reason: 'the guard must scan $relativePath',
  );
  return file.readAsStringSync();
}

void main() {
  late String gatewaySource;
  late String providerSource;
  late String diagnosticsSource;
  late String stateSource;
  late String agentAccessSource;
  late String agentGithubToolSource;
  late String deletionCoordinatorSource;
  late String workspaceShellSource;
  late String settingsDialogSource;
  late String dialogMethodsSource;
  late String environmentMethodsSource;
  late String workersTabSource;
  late String readModelSource;
  late String projectProviderSource;
  late String runtimeLogSettingsSource;
  late String githubRepositoryPatternSource;
  late String githubBranchPatternSource;
  late String githubFqdnPatternSource;
  late String appSubdirectorySource;

  setUpAll(() {
    final root = findRepositoryRoot();
    gatewaySource = _readLib(root, 'providers/github_api_gateway.dart');
    providerSource = _readLib(
      root,
      'providers/github_integration_provider.dart',
    );
    diagnosticsSource = _readLib(
      root,
      'providers/github_deploy_diagnostics.dart',
    );
    stateSource = _readLib(root, 'providers/github_integration_state.dart');
    agentAccessSource = _readLib(root, 'providers/agent_access_service.dart');
    agentGithubToolSource = _readLib(
      root,
      'providers/agent_access/tools/github.dart',
    );
    deletionCoordinatorSource = _readLib(
      root,
      'services/project_deletion_coordinator.dart',
    );
    workspaceShellSource = _readLib(
      root,
      'ui/project/workspace/shell/workspace_shell.dart',
    );
    settingsDialogSource = _readLib(
      root,
      'ui/project/workspace/app/app_deployment_settings_dialog.dart',
    );
    dialogMethodsSource = _readLib(
      root,
      'ui/project/workspace/app/app_deployment_dialog_methods.dart',
    );
    environmentMethodsSource = _readLib(
      root,
      'ui/project/workspace/app/app_deployment_environment_methods.dart',
    );
    workersTabSource = _readLib(
      root,
      'ui/project/workspace/workers/workers_tab.dart',
    );
    readModelSource = _readLib(
      root,
      'providers/project_web_app_read_model_provider.dart',
    );
    projectProviderSource = _readLib(root, 'providers/project_provider.dart');
    runtimeLogSettingsSource = _readLib(
      root,
      'services/runtime_log_settings.dart',
    );
    githubRepositoryPatternSource = _readLib(
      root,
      'utils/github_repository_pattern.dart',
    );
    githubBranchPatternSource = _readLib(
      root,
      'utils/github_branch_pattern.dart',
    );
    githubFqdnPatternSource = _readLib(root, 'utils/github_fqdn_pattern.dart');
    appSubdirectorySource = _readLib(root, 'utils/app_subdirectory.dart');
  });

  test(
    'the connected sentence lives in the helper plus the record-left 5th',
    () {
      const sentence = 'GitHub connected. No repositories found.';
      final convertedSources = [
        providerSource,
        diagnosticsSource,
        stateSource,
        gatewaySource,
      ].join('\n');
      expect(
        _count(convertedSources, sentence),
        1,
        reason: 'one githubConnectedMessage helper owns the sentence',
      );
      expect(
        _count(agentGithubToolSource, sentence),
        1,
        reason: 'the tools/github.dart 5th site keeps its own sentence',
      );
    },
  );

  test('the branch pattern compiles in exactly one hoisted const', () {
    const pattern = '^[A-Za-z0-9._/-]+\$';
    final convertedSources = [
      providerSource,
      agentAccessSource,
      settingsDialogSource,
      dialogMethodsSource,
      runtimeLogSettingsSource,
      githubBranchPatternSource,
    ].join('\n');
    expect(
      _count(convertedSources, pattern),
      1,
      reason: 'one hoisted branch RegExp owns the pattern string',
    );
  });

  test('the FQDN pattern compiles in exactly one hoisted const', () {
    const patternFragment = 'a-z0-9-]{0,61}';
    final convertedSources = [
      providerSource,
      agentAccessSource,
      deletionCoordinatorSource,
      workspaceShellSource,
      settingsDialogSource,
      dialogMethodsSource,
      workersTabSource,
      readModelSource,
      githubFqdnPatternSource,
    ].join('\n');
    expect(
      _count(convertedSources, patternFragment),
      2,
      reason:
          'one hoisted FQDN RegExp owns the pattern string '
          '(the pattern repeats the fragment twice)',
    );
  });

  test('the paged-GET loop lives only in the gateway owner', () {
    expect(
      _count(gatewaySource, 'pageCount < 10'),
      1,
      reason: 'one _paginatedGitHubGet owns the page-cap loop',
    );
    expect(
      _count(
        gatewaySource + githubRepositoryPatternSource,
        '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\$',
      ),
      1,
      reason: 'one hoisted repo-full-name RegExp owns the pattern',
    );
  });

  test('the session-expiry reset lives in one closure', () {
    expect(
      _count(
        providerSource,
        'Stored GitHub session expired. Please reconnect.',
      ),
      1,
      reason: 'one sessionExpired closure owns the sentence',
    );
  });

  test('OAuth failures funnel through one helper', () {
    expect(
      _count(providerSource, '_failOauth('),
      greaterThanOrEqualTo(4),
      reason: 'the 4 OAuth sites call the shared helper',
    );
    expect(
      _count(providerSource, '_trackOAuthStage(GitHubOAuthStage.failed)'),
      1,
      reason: 'the helper owns the failure-stage track',
    );
  });

  test('idle select-resets share one record', () {
    expect(
      _count(providerSource, 'deployTimeline: deployRunning ? null : const []'),
      4,
      reason: 'the 4 select sites share one spelling',
    );
    expect(
      _count(
        providerSource,
        'deployTimeline: deployRunning ? null : const <String>[]',
      ),
      0,
      reason: 'the alternate empty-timeline spelling is gone',
    );
  });

  test('deploy orchestration steps are named methods, not closures', () {
    // Four/six-space indent pins the closure definitions; the extracted
    // methods sit at two spaces and their call sites keep the bare names.
    for (final closure in [
      '    void failBeforeRun(',
      '    void updateRunState(',
      '    void appendRunTimeline(',
      '    Future<void> recordFirstDeployMilestone(',
      '    void trackDeployResolution(',
      '    Future<void> persistDeployOutcome(',
      '      acquireDeployKey(',
      '      Future<void> registerDeployKey(',
      '      Future<Map<String, dynamic>> runDeploymentWithKey(',
    ]) {
      expect(
        _count(providerSource, closure),
        0,
        reason: '$closure must be an extracted method, not a closure',
      );
    }
  });

  test('subdirectory normalization has one owner', () {
    final convertedSources = [
      providerSource,
      projectProviderSource,
      environmentMethodsSource,
      workersTabSource,
      appSubdirectorySource,
    ].join('\n');
    expect(
      _count(convertedSources, "replaceAll(RegExp(r'^/+|/+\$'), '')"),
      1,
      reason: 'one normalizeSubPath owner strips edge slashes',
    );
  });
}
