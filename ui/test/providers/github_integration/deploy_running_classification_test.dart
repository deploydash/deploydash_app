import 'package:flutter_test/flutter_test.dart';
import 'package:ui/providers/github_integration_provider.dart';

// Characterization for D-45 (T-008): every spelling of "is this deploy
// status in-flight" agrees with the owner [isDeployStatusRunning] on every
// lifecycle phase. The routed-away twins (`_isDeployRunning`,
// `isGitHubDeploymentRunning`) were proven identical by read and by this
// test at base, then deleted; the full suite staying green is the behavioral
// evidence the routing preserved them.
void main() {
  const expectedByStatus = <GitHubDeployStatus, bool>{
    GitHubDeployStatus.idle: false,
    GitHubDeployStatus.generatingServerKey: true,
    GitHubDeployStatus.registeringDeployKey: true,
    GitHubDeployStatus.cloningRepository: true,
    GitHubDeployStatus.buildingRelease: true,
    GitHubDeployStatus.awaitingRepositoryHostKeyConfirmation: false,
    GitHubDeployStatus.success: false,
    GitHubDeployStatus.error: false,
  };

  test('deploy running classification covers every lifecycle phase', () {
    expect(
      expectedByStatus.keys.toSet(),
      GitHubDeployStatus.values.toSet(),
      reason: 'A new phase must update the truth table, not slip through.',
    );
    for (final status in GitHubDeployStatus.values) {
      expect(
        isDeployStatusRunning(status),
        expectedByStatus[status],
        reason: 'Owner disagrees on $status.',
      );
    }
  });

  test('project deploy state running getter agrees with the owner', () {
    for (final status in GitHubDeployStatus.values) {
      const state = GitHubProjectDeployState();
      expect(
        state.copyWith(deployStatus: status).isRunning,
        expectedByStatus[status],
        reason: 'isRunning getter disagrees on $status.',
      );
    }
  });
}
