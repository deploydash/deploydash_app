import 'package:ui/ui/project/workspace/app/app_deployment_tab_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('deployment copy helpers prioritize the primary path', () {
    expect(
      deploymentPrimaryTitle(hasSuccessfulDeployment: false),
      'Deploy your app',
    );
    expect(
      deploymentPrimaryTitle(hasSuccessfulDeployment: true),
      'Deploy updates',
    );
    expect(
      deploymentPrimarySubtitle(
        hasRepositorySetup: false,
        hasSuccessfulDeployment: false,
      ),
      'Complete the steps below to connect code and publish your app.',
    );
    expect(
      deploymentPrimarySubtitle(
        hasRepositorySetup: true,
        hasSuccessfulDeployment: true,
      ),
      'Publish the latest code with your saved settings.',
    );
    expect(deploymentCurrentStateTitle(), 'Current web app');
    expect(
      deploymentCurrentStateSubtitle(),
      'Check what is live and whether it is healthy.',
    );
  });

  test('deployment step headings and blockers explain what to fix next', () {
    expect(
      deploymentStepHeading(
        gitHubConnected: false,
        repositorySelected: false,
        hasSuccessfulDeployment: false,
      ),
      'Step 1: Connect GitHub',
    );
    expect(
      deploymentStepHeading(
        gitHubConnected: true,
        repositorySelected: false,
        hasSuccessfulDeployment: false,
      ),
      'Step 2: Choose repository',
    );
    expect(
      deploymentStepHeading(
        gitHubConnected: true,
        repositorySelected: true,
        hasSuccessfulDeployment: false,
      ),
      'Step 3: Review settings',
    );
    expect(
      deploymentStepHeading(
        gitHubConnected: true,
        repositorySelected: true,
        hasSuccessfulDeployment: true,
      ),
      'Publish your next release',
    );

    expect(
      deploymentBlockedReason(
        disconnected: true,
        gitHubConnected: true,
        repositorySelected: true,
        domainValid: true,
        branchValid: true,
        portValid: true,
        tlsValidationError: null,
        canDeploy: true,
      ),
      'Reconnect this web app before you deploy again.',
    );
    expect(
      deploymentBlockedReason(
        disconnected: false,
        gitHubConnected: false,
        repositorySelected: false,
        domainValid: true,
        branchValid: true,
        portValid: true,
        tlsValidationError: null,
        canDeploy: true,
      ),
      'Connect GitHub to continue.',
    );
    expect(
      deploymentBlockedReason(
        disconnected: false,
        gitHubConnected: true,
        repositorySelected: true,
        domainValid: true,
        branchValid: true,
        portValid: true,
        tlsValidationError: 'Choose a DNS provider.',
        canDeploy: true,
      ),
      'Choose a DNS provider.',
    );
    expect(deploymentOneOffToolsTitle(), 'Maintenance tools');
    expect(
      deploymentOneOffToolsSubtitle(),
      'Run one-off commands inside the live app for migrations and maintenance.',
    );
    expect(
      deploymentOneOffStatusEmpty(),
      'No maintenance command has run yet.',
    );
    expect(deploymentOneOffOutputEmpty(), 'Command output will appear here.');
    expect(deploymentOneOffHistoryTitle(), 'Recent maintenance commands');
    expect(
      deploymentOneOffHistoryEmpty(),
      'No maintenance commands have been run yet.',
    );
    expect(deploymentEnvEditorTitle(), 'Environment variables');
    expect(
      deploymentEnvEditorSubtitle(),
      'Add the settings your app needs here. Save now, or save and redeploy when you want the changes to go live right away.',
    );
    expect(deploymentEnvBulkImportTitle(), 'Import variables in bulk');
    expect(
      deploymentEnvBulkImportSubtitle(),
      'Paste KEY=value lines. Matching names replace existing values.',
    );
  });
}
