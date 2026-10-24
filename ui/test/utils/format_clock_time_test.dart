import 'package:ui/utils/format_clock_time.dart';
import 'package:flutter_test/flutter_test.dart';

// D-57 (T-015) characterization: the six-site HH:MM:SS clock truth table.
// Local-time-in/local-string-out: the owner formats the fields it is given
// and never converts (callers pass already-local DateTimes).
void main() {
  test('formatClockTime pads single digits', () {
    expect(formatClockTime(DateTime(2026, 5, 1, 3, 4, 5)), '03:04:05');
  });

  test('formatClockTime renders midnight and noon', () {
    expect(formatClockTime(DateTime(2026, 5, 1, 0, 0, 0)), '00:00:00');
    expect(formatClockTime(DateTime(2026, 5, 1, 12, 0, 0)), '12:00:00');
  });

  test('formatClockTime renders end of day unpadded', () {
    expect(formatClockTime(DateTime(2026, 5, 1, 23, 59, 59)), '23:59:59');
  });

  test('formatClockTime formats fields as given without converting', () {
    expect(formatClockTime(DateTime.utc(2026, 5, 1, 3, 4, 5)), '03:04:05');
  });
}
