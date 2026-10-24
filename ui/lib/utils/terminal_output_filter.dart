const String repositoryHostKeyConfirmationMarker =
    '__DEPLOYDASH_REPOSITORY_HOST_KEY_CONFIRMATION__=';

/// Strips one leading `[bracketed] event prefix and trims (D-84).
///
/// One owner for the byte-identical server/github transcript twins.
String withoutEventPrefix(String input) {
  return input.replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '').trim();
}

/// Terminal detail vocabulary (detail-membership 3/5/6/11 — D-84).
///
/// Four nested levels sharing atoms; each site references its level.
/// service(3) ⊂ server(5) ⊂ backup(6) ⊂ technical(11) — subset relations
/// verified at execution; extend by adding atoms, never by editing a
/// composed set's meaning. (The technical level lives top-level beside its
/// siblings rather than inline in [isTechnicalTerminalActivity], so the
/// subset proof names all four levels uniformly.)
const pyinfraDetailEventTypes = <String>{
  'pyinfra_log',
  'pyinfra_operation_stdout',
  'pyinfra_operation_stderr',
};
const taskDetailEventTypes = <String>{'task_started', 'task_finished'};
const scheduleDecisionDetailEventTypes = <String>{
  'operation_schedule_decision',
};
const connectionDetailEventTypes = <String>{
  'connection_ready',
  'connection_start',
  'pyinfra_host_before_connect',
  'pyinfra_host_connected',
  'pyinfra_host_disconnected',
};
const serviceDetailEventTypes = pyinfraDetailEventTypes;
const serverDetailEventTypes = <String>{
  ...pyinfraDetailEventTypes,
  ...taskDetailEventTypes,
};
const backupDetailEventTypes = <String>{
  ...serverDetailEventTypes,
  ...scheduleDecisionDetailEventTypes,
};
const technicalDetailEventTypes = <String>{
  ...backupDetailEventTypes,
  ...connectionDetailEventTypes,
};

bool isInternalTerminalControlLine(String input) {
  final normalized = input.trim();
  return normalized.contains(repositoryHostKeyConfirmationMarker) ||
      normalized.contains('APP_REPOSITORY_HOST_KEY_CONFIRMATION_REQUIRED') ||
      normalized.contains('"repository_host_key_confirmation"') ||
      normalized.contains('"repository_host_key_confirmation_required"');
}

bool isTechnicalNavigationActivity({
  required String source,
  required String? taskType,
}) {
  return source.trim().toLowerCase() == 'ui' &&
      taskType?.trim().toLowerCase() == 'navigation';
}

bool isTechnicalTerminalActivity({
  required String message,
  required String source,
  required String? taskType,
}) {
  if (isTechnicalNavigationActivity(source: source, taskType: taskType)) {
    return true;
  }

  final normalizedSource = source.trim().toLowerCase();
  final eventType = normalizedSource.split(':').last;
  if (technicalDetailEventTypes.contains(eventType) ||
      eventType.endsWith('_runtime_plan_ready')) {
    return true;
  }

  final normalizedMessage = message.trim().toLowerCase();
  return normalizedMessage == 'operation accepted.' ||
      normalizedMessage == 'connection established.' ||
      normalizedMessage == 'task completed' ||
      normalizedMessage == 'task completed.' ||
      normalizedMessage.startsWith('connected to ') ||
      normalizedMessage.startsWith('connecting to ') ||
      normalizedMessage.startsWith('disconnected from ') ||
      normalizedMessage.startsWith('preparing connection for ') ||
      RegExp(
        r"^runtime operation '.+' prepared\.$",
      ).hasMatch(normalizedMessage);
}
