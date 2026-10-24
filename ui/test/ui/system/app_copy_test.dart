import 'package:ui/ui/system/app_copy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shared desktop copy helpers stay novice friendly', () {
    expect(serverCredentialsReconnectMessage(), contains('reconnected'));

    expect(projectDangerZoneTitle(), 'Danger zone');
    expect(projectDangerZoneSubtitle(), contains('cleanup failures'));
    expect(projectDangerZoneMissingSelectionMessage(), contains('Choose'));
    expect(projectDeleteDialogDescription('Blog'), contains('remove "Blog"'));
    expect(projectDeleteDialogTypePrompt('Blog'), contains('"Blog"'));
    expect(projectDeleteDialogAcknowledgeLabel(), contains('permanently'));
    expect(projectDeleteDialogDescription('Blog'), contains('local catalog'));
    expect(projectDeleteDialogDescription('Blog'), contains('manual cleanup'));
    expect(
      projectDeleteSuccessMessage('Blog', false),
      'Project "Blog" was removed from Deploy Dash.',
    );
    expect(
      projectDeleteSuccessMessage('Blog', true),
      contains('manual follow-up'),
    );
    // The sixteen Couldn’t wrappers are gone (D-73): each action clause is
    // pinned exactly by 'couldntMessage pins all sixteen failure strings
    // verbatim' below, which supersedes these contains() checks.
    expect(
      appSettingsBackupPasswordMismatchMessage(),
      contains('current app password'),
    );
    expect(
      formatAgentActivitySummary(
        workflowId: 'app',
        operationId: 'deploy',
        taskId: 42,
        status: 'success',
        message: 'Done.',
      ),
      'app • deploy • run 42 • success • Done.',
    );
    expect(appSettingsAgentSectionSubtitle(), contains('short-lived'));
    expect(appSettingsBackupSectionSubtitle(), contains('encrypted'));
    expect(appSettingsPasswordSectionSubtitle(), contains('unlocks'));

    expect(
      startupTitle(isCreateMode: false, isRestoreMode: true),
      'Restore your app data',
    );
    expect(
      startupTitle(isCreateMode: true, isRestoreMode: false),
      'Protect this app',
    );
    expect(
      startupTitle(isCreateMode: false, isRestoreMode: false),
      'Unlock Deploy Dash',
    );
    expect(
      startupDescription(isCreateMode: false, isRestoreMode: true),
      contains('downloaded backup'),
    );
    expect(
      startupDescription(isCreateMode: true, isRestoreMode: false),
      contains('stored on this computer'),
    );
    expect(
      startupDescription(isCreateMode: false, isRestoreMode: false),
      contains('local Deploy Dash workspace'),
    );
    expect(startupRestoreSuccessMessage(), contains('Enter your password'));
    expect(startupRestoreFailureMessage('boom'), contains('Couldn’t'));
    expect(startupCreateFailureMessage(), contains('technical details'));
    expect(startupBrowseBackupButtonLabel(), 'Choose backup file');
    expect(startupRestoreButtonLabel(true), 'Restoring...');
    expect(startupRestoreButtonLabel(false), 'Restore backup');
    expect(telemetryHelpImproveTitle(), 'Help improve Deploy Dash');
    expect(
      telemetryNoticeCardDescription(),
      'Deploy Dash uses anonymous telemetry to measure which features get '
      'used. Never hostnames, keys, passwords, or anything you type.',
    );
    expect(telemetryShareSwitchLabel(), 'Share usage statistics');
    expect(telemetryNagCardDescription(), contains('currently off'));
    expect(telemetryNagShareLabel(), 'OK');
    expect(telemetryNagDismissLabel(), 'Dismiss');
    expect(privacySectionSubtitle(), contains('on or off'));
    expect(privacyCollectedTitle(), 'What Deploy Dash collects');
    expect(privacyCollectedKinds(), hasLength(5));
    expect(privacyNeverCollectedTitle(), 'What is never collected');
    expect(privacyNeverCollectedKinds(), hasLength(4));
    expect(
      startupPrimaryButtonLabel(isCreateMode: true, isSubmitting: false),
      'Create app database',
    );
    expect(
      startupPrimaryButtonLabel(isCreateMode: false, isSubmitting: false),
      'Unlock app',
    );
    expect(
      startupPrimaryButtonLabel(isCreateMode: false, isSubmitting: true),
      'Please wait...',
    );

    expect(workersWorkspaceTitle(), 'Background workers');
    expect(workersWorkspaceSubtitle(), contains('long-running jobs'));
    expect(workersMissingSelectionMessage(), contains('background workers'));
    expect(workersConfiguredTitle(), 'Worker list');
    expect(workersConfiguredSubtitle(), contains('resource limits'));
    expect(workersEmptyMessage(), contains('No workers'));
    expect(workersLogsTitle('Queue worker'), 'Queue worker activity');
    expect(workersLogsEmptyMessage(), contains('No log lines'));
    expect(workersEditorTitle(false), 'Add worker');
    expect(workersEditorTitle(true), 'Edit worker');
    expect(workersEditorDescription(), contains('background job'));
    expect(workersDeleteDescription('Queue worker'), contains('Queue worker'));
    expect(workersRuntimeApplyLabel(true), 'Applying changes...');
    expect(workersRuntimeApplyLabel(false), 'Apply worker changes');

    expect(schedulerMissingSelectionMessage(), contains('scheduled jobs'));
    expect(schedulerDeleteDescription('Nightly sync'), contains('Nightly'));
    expect(schedulerTaskDeletedMessage(), 'Scheduled job deleted.');
    expect(schedulerTaskStartedMessage(), 'Scheduled job started.');
    expect(schedulerTaskCompletedMessage(), 'Scheduled job completed.');
    expect(schedulerEditorTitle(false), 'Add scheduled job');
    expect(schedulerEditorTitle(true), 'Edit scheduled job');
    expect(schedulerEditorDescription(), contains('how often'));
    expect(schedulerSaveLabel(), 'Save job');
    expect(schedulerCustomSectionTitle(), 'Scheduled jobs');
    // G-40: this message is the empty state's next-action guidance, not a
    // restatement of its title ('No scheduled jobs yet').
    expect(
      schedulerCustomSectionEmptyMessage(),
      'Add a command and choose when Deploy Dash should run it.',
    );
    expect(schedulerManagedSectionTitle(), 'Built-in schedules');
    expect(schedulerManagedSectionEmptyMessage(), contains('built-in'));
    expect(schedulerRunsSectionTitle(), 'Recent activity');
    expect(schedulerRunsSectionEmptyMessage(), 'No recent activity yet.');

    expect(emailWorkspaceTitle(), 'Project email');
    expect(emailWorkspaceSubtitle(), contains('inboxes'));
    expect(
      emailServiceDisabledMessage('Email'),
      'Email is not turned on for this server yet.',
    );
    expect(emailServiceDisabledActionLabel(), 'Open services');
    expect(domainActionsTitle(), 'Quick actions');
    expect(domainActionsSubtitle(), contains('Refresh'));
    expect(domainRecordsTitle(), 'DNS records');
    expect(domainRecordsSubtitle(), contains('visitors'));

    expect(logsRuntimeTitle(), 'App activity');
    expect(logsRuntimeSubtitle(), contains('running app'));
    expect(logsDeploymentTitle(), 'Deploy history');
    expect(logsDeploymentSubtitle(), contains('shipped'));
    expect(
      runtimeLogsFetchStatus(background: true),
      'Keeping app activity up to date...',
    );
    expect(
      runtimeLogsFetchStatus(background: false),
      'Loading the latest app activity...',
    );
    expect(runtimeLogsFetchSuccessMessage(), 'App activity updated.');
    expect(runtimeLogsFetchFailureMessage(), 'Couldn’t load app activity.');
  });

  test('couldntMessage pins all sixteen failure strings verbatim', () {
    // Exact pins (curly ’ U+2019 + \n placement): the action clause is the
    // parameter, the wording is never normalized.
    expect(
      couldntMessage('remove this project', 'boom'),
      'Couldn’t remove this project.\nboom',
    );
    expect(
      couldntMessage('load app settings', 'boom'),
      'Couldn’t load app settings.\nboom',
    );
    expect(
      couldntMessage('save the S3 backup destination', 'boom'),
      'Couldn’t save the S3 backup destination.\nboom',
    );
    expect(
      couldntMessage('back up the local app database', 'boom'),
      'Couldn’t back up the local app database.\nboom',
    );
    expect(
      couldntMessage('save the encrypted database copy', 'boom'),
      'Couldn’t save the encrypted database copy.\nboom',
    );
    expect(
      couldntMessage('restore the app backup', 'boom'),
      'Couldn’t restore the app backup.\nboom',
    );
    expect(
      couldntMessage('update the app password', 'boom'),
      'Couldn’t update the app password.\nboom',
    );
    expect(
      couldntMessage('update local agent access', 'boom'),
      'Couldn’t update local agent access.\nboom',
    );
    expect(
      couldntMessage('update local agent access mode', 'boom'),
      'Couldn’t update local agent access mode.\nboom',
    );
    expect(
      couldntMessage('start a redeploy session', 'boom'),
      'Couldn’t start a redeploy session.\nboom',
    );
    expect(
      couldntMessage('end the redeploy session', 'boom'),
      'Couldn’t end the redeploy session.\nboom',
    );
    expect(
      couldntMessage('restore that backup file', 'boom'),
      'Couldn’t restore that backup file.\nboom',
    );
    expect(
      couldntMessage('update usage reporting', 'boom'),
      'Couldn’t update usage reporting.\nboom',
    );
    expect(
      couldntMessage('load worker settings', 'boom'),
      'Couldn’t load worker settings.\nboom',
    );
    expect(
      couldntMessage('load worker activity', 'boom'),
      'Couldn’t load worker activity.\nboom',
    );
    expect(
      couldntMessage('load scheduled jobs', 'boom'),
      'Couldn’t load scheduled jobs.\nboom',
    );
  });

  test('relative timestamps use plain-English projects', () {
    final now = DateTime.utc(2026, 8, 18, 12);

    expect(formatRelativeTimestamp(null), 'Not deployed yet');
    expect(formatRelativeTimestamp(now, now: now), 'just now');
    expect(
      formatRelativeTimestamp(now.add(const Duration(minutes: 5)), now: now),
      'just now',
    );
    expect(
      formatRelativeTimestamp(
        now.subtract(const Duration(seconds: 30)),
        now: now,
      ),
      'just now',
    );
    expect(
      formatRelativeTimestamp(
        now.subtract(const Duration(minutes: 42)),
        now: now,
      ),
      '42 min ago',
    );
    expect(
      formatRelativeTimestamp(now.subtract(const Duration(hours: 5)), now: now),
      '5 hr ago',
    );
    expect(
      formatRelativeTimestamp(now.subtract(const Duration(days: 3)), now: now),
      '3 days ago',
    );
    expect(
      formatRelativeTimestamp(now.subtract(const Duration(days: 9)), now: now),
      '2026-08-09',
    );
  });

  test('absolute timestamps render local wall-clock minutes', () {
    expect(formatAbsoluteTimestamp(null), 'Not recorded');

    final value = DateTime.utc(2026, 3, 4, 5, 6).toLocal();
    expect(
      formatAbsoluteTimestamp(value),
      '${value.year}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}',
    );
  });
}
