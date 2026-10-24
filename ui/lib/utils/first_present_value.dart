/// Returns the first value that counts as present, untrimmed.
///
/// Why: read-model precedence chains share "trim decides presence, the
/// stored value is used verbatim" -- which matches NEITHER `_firstNonEmpty`
/// contract (the engine's lowercases without trimming; the onboarding
/// view's returns the trimmed value with an `''` fallback). One owner keeps
/// precedence lists honest. The [fallback] is returned verbatim, never
/// presence-checked: callers keep `x ?? default` blank-passthrough by
/// passing the whole expression as the fallback.
library;

String firstPresentValue(List<String?> values, String fallback) {
  for (final value in values) {
    if (value != null && value.trim().isNotEmpty) {
      return value;
    }
  }
  return fallback;
}
