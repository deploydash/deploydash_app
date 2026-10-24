/// The once-ever telemetry nag on Home, shown after the first deploy when
/// usage reporting was explicitly switched off.
enum TelemetryMoment {
  /// The Home nag offered after the first successful deploy.
  homeNag,
}

/// One telemetry prompt, or null from [telemetryPromptFor] when nothing
/// should show.
class TelemetryPrompt {
  /// Describes the visible prompt.
  const TelemetryPrompt({required this.moment, this.visible = true});

  /// Which moment this prompt belongs to.
  final TelemetryMoment moment;

  /// Whether the prompt is currently visible. Always true when constructed;
  /// hidden is represented by [telemetryPromptFor] returning null instead.
  final bool visible;
}

/// Decides whether Home shows the telemetry nag.
///
/// Telemetry is default-on behind the setup-progress notice, so there is no
/// onboarding ask: the single nag fires only when reporting was explicitly
/// switched off (`false`, never null) and the first deploy has succeeded,
/// and only until it has been shown once. Anything else returns null.
TelemetryPrompt? telemetryPromptFor({
  required DateTime? firstDeploySucceededAt,
  required bool? telemetryEnabled,
  required DateTime? telemetryNagShownAt,
}) {
  if (telemetryEnabled == false &&
      firstDeploySucceededAt != null &&
      telemetryNagShownAt == null) {
    return const TelemetryPrompt(moment: TelemetryMoment.homeNag);
  }
  return null;
}
