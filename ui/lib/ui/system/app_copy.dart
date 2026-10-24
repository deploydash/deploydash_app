/// The user-facing strings shared across workspaces.
///
/// Copy lives in functions here, not inline in widgets, for two reasons: the
/// wording rules -- sentence case, novice-first, no `payload` or `operation
/// id` on a primary path -- are reviewable in one place, and a string used on
/// two screens cannot drift into two spellings. Strings used by exactly one
/// screen stay with that screen.
library;

import '../../utils/trim_or_null.dart';

/// Shown when an operation needs a server whose credentials no longer work.
String serverCredentialsReconnectMessage() {
  return 'This server connection needs to be reconnected before Deploy Dash '
      'can finish this step.';
}

/// The delete section's heading in project settings.
String projectDangerZoneTitle() => 'Danger zone';

/// What the danger zone does, including that cleanup warnings do not stop
/// the local deletion.
String projectDangerZoneSubtitle() {
  return 'Deploy Dash removes the local project after attempting to remove its '
      'managed server resources. Any cleanup failures are reported as warnings.';
}

/// Shown in the danger zone when no project is selected.
String projectDangerZoneMissingSelectionMessage() {
  return 'Choose a project before you use the danger zone.';
}

/// The delete dialog's body: what is removed from the server, what is removed
/// locally, and that the local record cannot be restored.
String projectDeleteDialogDescription(String projectName) {
  return 'Deploy Dash will first attempt to remove "$projectName" web app '
      'runtime, backup plans, scheduled jobs, and managed PostgreSQL resources '
      'from the server. It will then permanently delete the project and its '
      'saved local catalog from this app, even if some server cleanup reports '
      'warnings. Those warnings identify resources that need manual cleanup; '
      'the deleted local project cannot be restored automatically.';
}

/// Asks the user to type the project's name.
///
/// Typing the name is what makes the confirmation deliberate rather than a
/// button press.
String projectDeleteDialogTypePrompt(String projectName) {
  return 'Type "$projectName" to continue.';
}

/// The checkbox stating that cleanup warnings need manual follow-up.
String projectDeleteDialogAcknowledgeLabel() {
  return 'I understand the local project is permanently deleted and any '
      'reported server cleanup warnings require manual follow-up.';
}

/// Reports a completed deletion, saying plainly when server cleanup still
/// needs attention rather than reporting an unqualified success.
String projectDeleteSuccessMessage(String projectName, bool hasWarnings) {
  if (hasWarnings) {
    return 'Project "$projectName" was removed from Deploy Dash. Some server '
        'cleanup still needs manual follow-up.';
  }
  return 'Project "$projectName" was removed from Deploy Dash.';
}

/// Reports a failure that keeps the raw error on a second line.
///
/// Why: sixteen one-line "Couldn’t \<action\>" builders are one concept;
/// the action clause is the parameter, the wording is never normalized.
/// [action] is the verbatim clause without a trailing period.
String couldntMessage(String action, Object error) {
  return 'Couldn’t $action.\n$error';
}

/// The chosen backup needs a different password.
///
/// Says so plainly rather than as a decryption error: the user's password is
/// not wrong, the backup is simply older than their last password change.
String appSettingsBackupPasswordMismatchMessage() {
  return 'This backup does not match your current app password.';
}

/// One bullet-separated line describing an agent action, for the audit list.
///
/// Blank parts are dropped rather than rendered as empty bullets.
String formatAgentActivitySummary({
  String? workflowId,
  String? operationId,
  int? taskId,
  required String status,
  required String message,
}) {
  final parts = <String>[
    ?trimOrNull(workflowId),
    ?trimOrNull(operationId),
    if (taskId != null) 'run $taskId',
    status.trim(),
  ];
  final trimmedMessage = message.trim();
  if (trimmedMessage.isNotEmpty) {
    parts.add(trimmedMessage);
  }
  return parts.join(' • ');
}

/// What Agent Access allows, and that redeploy is opt-in and short-lived.
String appSettingsAgentSectionSubtitle() {
  return 'Let desktop agents inspect your app and managed PostgreSQL '
      'databases through a local endpoint. Start a short-lived redeploy '
      'session only when you want an agent to ship an update.';
}

/// What the local database backup section does.
String appSettingsBackupSectionSubtitle() {
  return 'Back up or export the encrypted local Deploy Dash database without '
      'unlocking it.';
}

/// What the password section changes.
String appSettingsPasswordSectionSubtitle() {
  return 'Update the password that unlocks and encrypts the local Deploy '
      'Dash database.';
}

/// The unlock screen's heading, for creating, restoring, or unlocking.
String startupTitle({required bool isCreateMode, required bool isRestoreMode}) {
  if (isRestoreMode) {
    return 'Restore your app data';
  }
  return isCreateMode ? 'Protect this app' : 'Unlock Deploy Dash';
}

/// The unlock screen's explanation for whichever of the three modes is
/// showing.
String startupDescription({
  required bool isCreateMode,
  required bool isRestoreMode,
}) {
  if (isRestoreMode) {
    return 'Choose a downloaded backup file. Deploy Dash will install it as '
        'the local encrypted database before you sign in.';
  }
  if (isCreateMode) {
    return 'Create a password to protect the servers, keys, and project data '
        'stored on this computer.';
  }
  return 'Enter your password to open your local Deploy Dash workspace.';
}

/// A backup was installed and the user can now sign in.
String startupRestoreSuccessMessage() {
  return 'Backup restored. Enter your password to continue.';
}

/// A backup file could not be installed.
///
/// Single-sourced through [couldntMessage], which owns this string
/// family since the dup-collapse pilot; the name stays for its callers.
String startupRestoreFailureMessage(Object error) {
  return couldntMessage('restore that backup file', error);
}

/// The passphrase field was submitted empty, on the create screen or the
/// in-wizard passphrase step: both surfaces share this copy.
String startupPassphraseEmptyMessage() {
  return 'Enter a passphrase to continue.';
}

/// The two passphrase fields disagree, on the create screen or the
/// in-wizard passphrase step: both surfaces share this copy.
String startupPassphraseMismatchMessage() {
  return 'Passphrases do not match.';
}

/// Database creation failed.
///
/// Says the password was not saved, because the alternative reading -- that a
/// half-created database now holds it -- is the one that would worry a user.
String startupCreateFailureMessage() {
  return 'Couldn’t create the local encrypted database. Your password was '
      'not saved. Review the technical details and try again.';
}

/// The button that opens the file picker on the unlock screen.
String startupBrowseBackupButtonLabel() => 'Choose backup file';

/// The restore button, which names its own progress while running.
String startupRestoreButtonLabel(bool isRestoring) {
  return isRestoring ? 'Restoring...' : 'Restore backup';
}

/// The shared heading for the telemetry notice, nag, and Privacy section.
String telemetryHelpImproveTitle() => 'Help improve Deploy Dash';

/// What the setup-progress notice says: why anonymous telemetry is used and
/// which sensitive or user-entered values never leave the device.
String telemetryNoticeCardDescription() {
  return 'Deploy Dash uses anonymous telemetry to measure which features get '
      'used. Never hostnames, keys, passwords, or anything you type.';
}

/// The live usage-reporting switch label, shared by the setup notice and
/// the Privacy destination.
String telemetryShareSwitchLabel() => 'Share usage statistics';

/// What the Home nag says: reporting is currently off, and switching it
/// back on helps guide what gets built next.
String telemetryNagCardDescription() {
  return 'Anonymous feature usage is currently off. Turn it back on to help '
      'guide what gets built next. Deploy Dash never collects project '
      'names, hostnames, keys, or file contents.';
}

/// The nag's opt-in action: sharing usage stats resumes reporting.
String telemetryNagShareLabel() => 'OK';

/// The nag's deferral action: the card goes away and never returns.
String telemetryNagDismissLabel() => 'Dismiss';

/// The Privacy destination's subtitle: what the switch does and where the
/// lists below come in.
String privacySectionSubtitle() {
  return 'See what Deploy Dash collects, and turn anonymous usage reporting '
      'on or off at any time.';
}

/// The Privacy heading over what leaves the device.
String privacyCollectedTitle() => 'What Deploy Dash collects';

/// The collected kinds, in plain words: which screens and actions are used
/// and whether they succeed, with coarse install context and no user
/// content. One owner for this list: the Privacy destination renders it.
List<String> privacyCollectedKinds() {
  return const <String>[
    'Which screens are opened and which controls are used, with outcomes.',
    'Server setup checkpoints, deploy stages and outcomes, and how long runs take.',
    'Database, backup, restore, scheduler, worker, service, firewall, update, terminal, and agent actions, with outcomes.',
    'Coarse install context: lifecycle stage, install-age bucket, an opaque per-launch session id, and 0/1/2/3+ buckets for servers, projects, and weekly deploys.',
    'Install facts on Amplitude only: app version on update checks, distribution channel, CPU architecture, operating system, language, and approximate region.',
  ];
}

/// The Privacy heading over what never leaves the device.
String privacyNeverCollectedTitle() => 'What is never collected';

/// The never-collected kinds. One owner for this list, beside the collected
/// one above.
List<String> privacyNeverCollectedKinds() {
  return const <String>[
    'Project names, server hostnames, repository names, and file contents.',
    'Keys, passwords, tokens, and command text.',
    'Exact server, project, or deploy counts.',
    'Error messages and stack traces; crashes report only the error type.',
  ];
}

/// The unlock screen's primary button, for creating or unlocking.
String startupPrimaryButtonLabel({
  required bool isCreateMode,
  required bool isSubmitting,
}) {
  if (isSubmitting) {
    return 'Please wait...';
  }
  return isCreateMode ? 'Create app database' : 'Unlock app';
}

/// The Workers screen's title.
String workersWorkspaceTitle() => 'Background workers';

/// What the Workers screen is for, in a novice's terms.
String workersWorkspaceSubtitle() {
  return 'Add long-running jobs, choose how much space they can use, and '
      'keep an eye on their status.';
}

/// Shown on Workers when no project and server are selected.
String workersMissingSelectionMessage() {
  return 'Choose a project and server before you set up background workers.';
}

/// The configured-workers section heading.
String workersConfiguredTitle() => 'Worker list';

/// What a worker is: one background job with its own command and limits.
String workersConfiguredSubtitle() {
  return 'Each worker runs one background job with its own command and '
      'resource limits.';
}

/// The workers empty state, naming the next action.
String workersEmptyMessage() {
  return 'No workers yet. Add one to run background jobs for this project.';
}

/// The heading over one worker's log output.
String workersLogsTitle(String workerName) => '$workerName activity';

/// Shown when a worker has produced no output yet.
String workersLogsEmptyMessage() {
  return 'No log lines are available yet.';
}

/// The worker editor's title, for adding or editing.
String workersEditorTitle(bool isEditing) {
  return isEditing ? 'Edit worker' : 'Add worker';
}

/// What the worker editor asks for.
String workersEditorDescription() {
  return 'Tell Deploy Dash how to start this background job and what '
      'resources it can use.';
}

/// The worker delete confirmation.
///
/// Says explicitly that the running container is untouched until the runtime
/// is applied, so removing a row does not read as stopping a job.
String workersDeleteDescription(String workerName) {
  return 'Remove "$workerName" from this project? The running container is '
      'not changed until you apply the worker runtime again.';
}

/// The apply-changes button, which names its own progress while running.
String workersRuntimeApplyLabel(bool busy) {
  return busy ? 'Applying changes...' : 'Apply worker changes';
}

/// Shown on Scheduler when no project and server are selected.
String schedulerMissingSelectionMessage() {
  return 'Choose a project and server before you manage scheduled jobs.';
}

/// The scheduled-job delete confirmation.
String schedulerDeleteDescription(String taskName) {
  return 'Delete the scheduled job "$taskName"?';
}

/// A scheduled job was deleted.
String schedulerTaskDeletedMessage() => 'Scheduled job deleted.';

/// A scheduled job was started by hand.
String schedulerTaskStartedMessage() => 'Scheduled job started.';

/// A scheduled job finished.
String schedulerTaskCompletedMessage() => 'Scheduled job completed.';

/// The scheduled-job editor's title, for adding or editing.
String schedulerEditorTitle(bool isEditing) {
  return isEditing ? 'Edit scheduled job' : 'Add scheduled job';
}

/// What the scheduled-job editor asks for.
String schedulerEditorDescription() {
  return 'Choose what should run, where it should run, and how often it '
      'should start.';
}

/// The scheduled-job editor's save button.
String schedulerSaveLabel() => 'Save job';

/// The heading over jobs the user wrote.
String schedulerCustomSectionTitle() => 'Scheduled jobs';

/// The empty state for user-written jobs, naming the next action.
String schedulerCustomSectionEmptyMessage() {
  return 'Add a command and choose when Deploy Dash should run it.';
}

/// The heading over jobs a Deploy Dash feature owns.
String schedulerManagedSectionTitle() => 'Built-in schedules';

/// The empty state for feature-owned jobs.
String schedulerManagedSectionEmptyMessage() {
  return 'No built-in schedules are registered yet.';
}

/// The heading over recent scheduled-job runs.
String schedulerRunsSectionTitle() => 'Recent activity';

/// The empty state for run history.
String schedulerRunsSectionEmptyMessage() => 'No recent activity yet.';

/// The Email screen's title. Email is a navigation placeholder today.
String emailWorkspaceTitle() => 'Project email';

/// What Email will do once it ships.
String emailWorkspaceSubtitle() {
  return 'Create inboxes, forward messages, and review the email health for '
      'this project.';
}

/// Shown when a service is not enabled for this server yet.
String emailServiceDisabledMessage(String serviceName) {
  return '$serviceName is not turned on for this server yet.';
}

/// The button that opens Server Services from that message.
String emailServiceDisabledActionLabel() => 'Open services';

/// The Domain screen's actions heading.
String domainActionsTitle() => 'Quick actions';

/// What the domain actions do.
String domainActionsSubtitle() {
  return 'Refresh the checks or add the next DNS record you need.';
}

/// The DNS records section heading.
String domainRecordsTitle() => 'DNS records';

/// What DNS records are, for a user who has not met them before.
String domainRecordsSubtitle() {
  return 'These are the records visitors and providers use to reach your '
      'site.';
}

/// The heading over the running app's output.
String logsRuntimeTitle() => 'App activity';

/// What the runtime log shows.
String logsRuntimeSubtitle() {
  return 'Read the latest messages from the running app container.';
}

/// The heading over deploy history.
String logsDeploymentTitle() => 'Deploy history';

/// What the deploy history shows.
String logsDeploymentSubtitle() {
  return 'Review what happened while Deploy Dash prepared and shipped this '
      'app.';
}

/// The status line while runtime logs load.
///
/// A background refresh says it is keeping up to date; a first load says it is
/// loading, so a refresh does not read as though nothing had been fetched.
String runtimeLogsFetchStatus({required bool background}) {
  return background
      ? 'Keeping app activity up to date...'
      : 'Loading the latest app activity...';
}

/// Runtime logs were refreshed.
String runtimeLogsFetchSuccessMessage() => 'App activity updated.';

/// Runtime logs could not be loaded.
String runtimeLogsFetchFailureMessage() => 'Couldn’t load app activity.';

String _twoDigits(int value) => value.toString().padLeft(2, '0');

/// Human-friendly age of [value], switching to a plain date past a week.
String formatRelativeTimestamp(DateTime? value, {DateTime? now}) {
  if (value == null) {
    return 'Not deployed yet';
  }
  final local = value.toLocal();
  final reference = (now ?? DateTime.now()).toLocal();
  final age = reference.difference(local);
  if (age.isNegative || age < const Duration(minutes: 1)) {
    return 'just now';
  }
  if (age < const Duration(hours: 1)) {
    return '${age.inMinutes} min ago';
  }
  if (age < const Duration(days: 1)) {
    return '${age.inHours} hr ago';
  }
  if (age < const Duration(days: 7)) {
    return '${age.inDays} days ago';
  }
  return '${local.year}-${_twoDigits(local.month)}-${_twoDigits(local.day)}';
}

/// Local wall-clock rendering of [value] as `yyyy-MM-dd HH:mm`.
String formatAbsoluteTimestamp(DateTime? value) {
  if (value == null) {
    return 'Not recorded';
  }
  final local = value.toLocal();
  return '${local.year}-${_twoDigits(local.month)}-${_twoDigits(local.day)} '
      '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
}
