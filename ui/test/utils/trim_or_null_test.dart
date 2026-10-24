import 'package:ui/utils/trim_or_null.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('returns null for an absent value', () {
    expect(trimOrNull(null), isNull);
  });

  test('returns null for a value that is only whitespace', () {
    // Blank means absent: a column holding spaces must read back as null,
    // not as whitespace that later comparisons would treat as a real value.
    expect(trimOrNull(''), isNull);
    expect(trimOrNull('   '), isNull);
    expect(trimOrNull('\t\n '), isNull);
  });

  test('returns the trimmed value when content survives trimming', () {
    expect(trimOrNull('  hello  '), 'hello');
    expect(trimOrNull('hello'), 'hello');
  });

  test('keeps interior whitespace', () {
    // Only the ends are trimmed; a project name with a space in it must
    // survive a round trip through the database unchanged.
    expect(trimOrNull('  my project  '), 'my project');
  });

  test('toString-first conversion handles dynamic map reads', () {
    // D-87 gaps 2-4 converge onto this idiom: dynamic map reads stringify
    // before the blank-means-absent check, so a non-string value can never
    // crash the conversion the way a direct dynamic-to-String? pass would.
    final Map<String, dynamic> values = <String, dynamic>{
      'number': 42,
      'blank': '   ',
      'padded': '  x  ',
    };
    expect(trimOrNull(values['missing']?.toString()), isNull);
    expect(trimOrNull(values['number']?.toString()), '42');
    expect(trimOrNull(values['blank']?.toString()), isNull);
    expect(trimOrNull(values['padded']?.toString()), 'x');
  });
}
