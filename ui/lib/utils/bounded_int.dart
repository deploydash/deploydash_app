/// Bounds [value] below by [min], defaulting to [fallback] when under it,
/// and above by [max] when given.
///
/// Why one owner with a nullable max (D-20): one-sided limits (no upper
/// bound) and two-sided clamps share a shape but differ in whether large
/// values pass through. A shared owner with a defaulted max would silently
/// cap the one-sided sites, so [max] stays null-off: absent means
/// pass-through, present means cap. [fallback] and [min] travel separately
/// because one-sided sites fall back to their default (20, 5) rather than
/// to the bound (1).
library;

int boundedInt(int value, {required int fallback, int min = 1, int? max}) {
  if (value < min) {
    return fallback;
  }
  if (max != null && value > max) {
    return max;
  }
  return value;
}
