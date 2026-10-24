import 'package:ui/models/railpack_runtime.dart';
import 'package:flutter/foundation.dart';

bool appDeploymentShouldSelectUpdatedRepository({
  required String? currentRepository,
  required String nextRepository,
}) {
  return nextRepository != currentRepository;
}

RailpackRuntimeOption appDeploymentRuntimeForProvider(
  String? railpackProvider,
) {
  return railpackRuntimeForProvider(
    normalizeRailpackProvider(railpackProvider),
  );
}

String appDeploymentResolvedBuildCommand({
  required String? railpackProvider,
  required String? configuredBuildCommand,
}) {
  return configuredBuildCommand ??
      appDeploymentRuntimeForProvider(railpackProvider).defaultBuildCommand;
}

String appDeploymentResolvedRunCommand({
  required String? railpackProvider,
  required String? configuredRunCommand,
}) {
  return configuredRunCommand ??
      appDeploymentRuntimeForProvider(railpackProvider).defaultRunCommand;
}

void appDeploymentMaybeSelectUpdatedRepository({
  required String? currentRepository,
  required String nextRepository,
  required ValueChanged<String> onRepositorySelected,
}) {
  if (appDeploymentShouldSelectUpdatedRepository(
    currentRepository: currentRepository,
    nextRepository: nextRepository,
  )) {
    onRepositorySelected(nextRepository);
  }
}

String deploymentPrimaryTitle({required bool hasSuccessfulDeployment}) {
  return hasSuccessfulDeployment ? 'Deploy updates' : 'Deploy your app';
}

String deploymentPrimarySubtitle({
  required bool hasRepositorySetup,
  required bool hasSuccessfulDeployment,
}) {
  if (!hasRepositorySetup) {
    return 'Complete the steps below to connect code and publish your app.';
  }
  if (hasSuccessfulDeployment) {
    return 'Publish the latest code with your saved settings.';
  }
  return 'Review the setup, then publish the first version.';
}

String deploymentCurrentStateTitle() => 'Current web app';

String deploymentCurrentStateSubtitle() {
  return 'Check what is live and whether it is healthy.';
}

String deploymentStepHeading({
  required bool gitHubConnected,
  required bool repositorySelected,
  required bool hasSuccessfulDeployment,
}) {
  if (hasSuccessfulDeployment) {
    return 'Publish your next release';
  }
  if (!gitHubConnected) {
    return 'Step 1: Connect GitHub';
  }
  if (!repositorySelected) {
    return 'Step 2: Choose repository';
  }
  return 'Step 3: Review settings';
}

String? deploymentBlockedReason({
  required bool disconnected,
  required bool gitHubConnected,
  required bool repositorySelected,
  required bool domainValid,
  required bool branchValid,
  required bool portValid,
  String? tlsValidationError,
  required bool canDeploy,
}) {
  if (disconnected) {
    return 'Reconnect this web app before you deploy again.';
  }
  if (!gitHubConnected) {
    return 'Connect GitHub to continue.';
  }
  if (!repositorySelected) {
    return 'Choose a repository to continue.';
  }
  if (!domainValid) {
    return 'Enter a valid domain before you deploy.';
  }
  if (!branchValid) {
    return 'Use a valid branch name before you deploy.';
  }
  if (!portValid) {
    return 'Enter a port between 1 and 65535.';
  }
  if (tlsValidationError != null && tlsValidationError.trim().isNotEmpty) {
    return tlsValidationError;
  }
  if (!canDeploy) {
    return 'A deployment is already in progress.';
  }
  return null;
}

String deploymentOneOffToolsTitle() => 'Maintenance tools';

String deploymentOneOffToolsSubtitle() {
  return 'Run one-off commands inside the live app for migrations and maintenance.';
}

String deploymentOneOffStatusEmpty() {
  return 'No maintenance command has run yet.';
}

String deploymentOneOffOutputEmpty() => 'Command output will appear here.';

String deploymentOneOffHistoryTitle() => 'Recent maintenance commands';

String deploymentOneOffHistoryEmpty() {
  return 'No maintenance commands have been run yet.';
}

String deploymentEnvEditorTitle() => 'Environment variables';

String deploymentEnvEditorSubtitle() {
  return 'Add the settings your app needs here. Save now, or save and redeploy when you want the changes to go live right away.';
}

String deploymentEnvBulkImportTitle() => 'Import variables in bulk';

String deploymentEnvBulkImportSubtitle() {
  return 'Paste KEY=value lines. Matching names replace existing values.';
}
