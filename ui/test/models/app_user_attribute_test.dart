import 'package:flutter_test/flutter_test.dart';
import 'package:ui/models/app_user_attribute.dart';

void main() {
  test('storage keys are the stable analytics identifiers', () {
    expect(
      AppUserAttribute.hasCompletedOnboarding.storageKey,
      'has_completed_onboarding',
    );
    expect(
      AppUserAttribute.hasFirstDeploySucceeded.storageKey,
      'has_first_deploy_succeeded',
    );
    expect(
      AppUserAttribute.hasConnectedGitHub.storageKey,
      'has_connected_github',
    );
    expect(
      AppUserAttribute.serverCountBucket.storageKey,
      'server_count_bucket',
    );
    expect(
      AppUserAttribute.projectCountBucket.storageKey,
      'project_count_bucket',
    );
    expect(
      AppUserAttribute.deploysPerWeekBucket.storageKey,
      'deploys_per_week_bucket',
    );
  });

  test('every attribute maps to a distinct storage key', () {
    final keys = AppUserAttribute.values.map((a) => a.storageKey).toSet();
    expect(keys, hasLength(AppUserAttribute.values.length));
  });
}
