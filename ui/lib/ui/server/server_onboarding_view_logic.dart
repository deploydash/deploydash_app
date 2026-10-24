import '../../services/app_analytics_service.dart';

List<String> onboardingIntroSteps() {
  return const <String>[
    'Add the server details Deploy Dash needs to connect.',
    'Review the server and confirm it is ready.',
    'Choose the services you want to install.',
    'Finish setup and add secure Deploy Dash access.',
  ];
}

String onboardingCheckConnectionLabel({required bool isLoading}) {
  return isLoading ? 'Checking connection...' : 'Check connection';
}

String onboardingConnectionErrorHeadline({required bool hostKeyMismatch}) {
  if (hostKeyMismatch) {
    return 'This server looks different than before.';
  }
  return 'Couldn’t connect to this server.';
}

String onboardingCompatibilityHeading() => 'What we’ll check';

String onboardingCompatibilityHint({
  required bool compatibilityPassed,
  required String summary,
}) {
  if (compatibilityPassed) {
    return 'Everything looks ready. You can finish setup now.';
  }
  final trimmed = summary.trim();
  if (trimmed.isEmpty) {
    return 'Fix the items below before you finish setup.';
  }
  return trimmed;
}

String onboardingFinishButtonLabel({required bool isSaving}) {
  return isSaving ? 'Finishing setup...' : 'Finish setup';
}

String onboardingFinishBlockedMessage() {
  return 'Finish setup becomes available after these checks pass.';
}

String onboardingSetupProgressTitle({
  required bool isRunning,
  required bool hasError,
}) {
  if (isRunning) {
    return 'Setting up server';
  }
  if (hasError) {
    return 'Setup needs attention';
  }
  return 'Setup progress';
}

String onboardingSetupProgressDescription({
  required bool isRunning,
  required bool hasError,
}) {
  if (isRunning) {
    return 'Deploy Dash is applying the secure server baseline. Keep this window open while setup runs.';
  }
  if (hasError) {
    return 'Fix the issue below, then retry setup from this screen.';
  }
  return 'Deploy Dash will show the current setup progress here.';
}

/// Plain-English copy for the setup failures the backend names by code.
///
/// Keyed by the backend error code rather than by matching on message text.
/// A code is a statement; a substring match is a guess, and the two disagree
/// exactly when it matters most -- a layout error whose message happens to
/// mention a hostname would otherwise be reported as a network problem and
/// send the user to check their firewall.
///
/// The code itself never appears here. It reaches the user through the
/// technical-details reveal, per the progressive-disclosure rule.
const Map<String, String> _codedFailureSummaries = <String, String>{
  'ENGINE_LAYOUT_TOO_NEW':
      'This server was set up by a newer version of Deploy Dash. '
      'Update Deploy Dash on this computer, then try again.',
  'ENGINE_LAYOUT_UNVERSIONED':
      'This server was set up by an earlier version of Deploy Dash that did '
      'not record how it was configured, so this version cannot manage it '
      'safely. Use a fresh server, or contact support before continuing.',
  'ENGINE_LAYOUT_MIGRATION_REQUIRED':
      'This server uses an earlier Deploy Dash layout and needs to be '
      'upgraded before it can be managed. Deploy Dash will guide you '
      'through the upgrade.',
  'ENGINE_LAYOUT_UNREADABLE':
      'Deploy Dash could not check how this server is set up. Check the '
      'connection to the server, then try again.',
  // The one setup failure whose advice is "do not retry". Every other
  // summary here ends by sending the user back to this screen; this one
  // cannot, because the server may no longer accept the connection a retry
  // would need. See I-6b in docs/contracts/onboarding-invariants.md.
  'ENGINE_SSH_HARDENING_ROLLBACK_FAILED':
      'Deploy Dash changed this server’s SSH settings, could not sign in '
      'afterwards, and could not undo the change. This server may no longer '
      'accept connections it accepted before. Do not retry setup — open your '
      'hosting provider’s console and restore the SSH configuration backup '
      'named in the details below.',
};

String onboardingSetupFailureSummary({
  String? error,
  Map<String, dynamic>? errorPayload,
  Map<String, dynamic>? setupResult,
}) {
  // Checked before the message heuristics below: where a code is present it
  // is authoritative, and the heuristics must not be allowed to override it.
  final code = _firstNonEmpty(<String?>[
    errorPayload?['code']?.toString(),
    setupResult?['code']?.toString(),
  ]);
  final codedSummary = _codedFailureSummaries[code];
  if (codedSummary != null) {
    return codedSummary;
  }

  final raw = _firstNonEmpty(<String?>[
    errorPayload?['msg']?.toString(),
    errorPayload?['error']?.toString(),
    setupResult?['msg']?.toString(),
    setupResult?['error']?.toString(),
    error,
  ]);
  if (raw.isEmpty) {
    return 'Setup stopped before the server was fully configured. Review the details below, fix the issue, then retry.';
  }

  final normalized = raw.toLowerCase();
  if (_containsAny(normalized, const <String>[
    'apt',
    'archive.ubuntu.com',
    'download.docker.com',
    'ghcr.io',
    'registry-1.docker.io',
    'github.com',
    'could not resolve',
    'temporary failure resolving',
    'connection timed out',
    'network is unreachable',
    'unable to fetch',
    'repository',
    'release asset',
  ])) {
    return 'The server could not reach a required package or download source. Check DNS, outbound HTTPS, proxy, or firewall rules, then retry setup.';
  }
  if (_containsAny(normalized, const <String>[
    'permission denied',
    'authentication',
    'publickey',
    'password',
    'sudo',
  ])) {
    return 'Deploy Dash could not keep administrator access while setting up the server. Check the saved sign-in details, then retry setup.';
  }
  if (_containsAny(normalized, const <String>[
    'disk',
    'no space left',
    'not enough space',
  ])) {
    return 'The server does not have enough usable disk space to finish setup. Free space or choose a larger server, then retry.';
  }
  return raw;
}

String _firstNonEmpty(List<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return '';
}

bool _containsAny(String value, List<String> needles) {
  return needles.any(value.contains);
}

/// The onboarding checkpoint a setup failure code names, if it names one.
///
/// Only codes that identify a checkpoint map: the SSH hardening rollback
/// names [OnboardingStep.sshHardened], and the layout codes name
/// [OnboardingStep.bootstrap] because layout validation gates the whole run
/// before provisioning starts. Every other code -- network faults, package
/// failures, cancellations -- says where the run stopped only by message
/// text, and the funnel reports nothing for those rather than a guessed
/// step.
OnboardingStep? onboardingFailedStepForCode(String? code) {
  switch (code?.trim()) {
    case 'ENGINE_SSH_HARDENING_ROLLBACK_FAILED':
      return OnboardingStep.sshHardened;
    case 'ENGINE_LAYOUT_TOO_NEW':
    case 'ENGINE_LAYOUT_UNVERSIONED':
    case 'ENGINE_LAYOUT_MIGRATION_REQUIRED':
    case 'ENGINE_LAYOUT_UNREADABLE':
      return OnboardingStep.bootstrap;
    default:
      return null;
  }
}
