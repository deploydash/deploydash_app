/// Returns [value] stringified and trimmed, or [fallback] when blank.
///
/// The single owner of "a trimmed engine message or a fallback" for the
/// desktop app. Six hand-rolled ternaries and ifs in
/// `app_deployment_runtime_methods.dart` preceded it (D-43), and D-40's
/// message tails share the vocabulary — which is why it is a top-level
/// function in `utils/` rather than a static on whichever class happened to
/// need it first: a helper that can only be reached through one class is a
/// helper the next class will rewrite.
///
/// Stringifies before trimming, so a non-string value (`42`) yields `'42'`
/// instead of crashing the way a direct `dynamic`-to-`String?` pass would.
/// Reads [value] once: on plain maps (whose reads have no side effects) this
/// agrees exactly with the double-eval probe-then-read ternary it replaces.
String messageOr(Object? value, String fallback) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? fallback : text;
}
