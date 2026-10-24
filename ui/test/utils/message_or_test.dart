import 'package:ui/utils/message_or.dart';
import 'package:flutter_test/flutter_test.dart';

// Characterization for D-43 (T-013, commit 1): the response-message shape
// shared by D-43's six occurrences and D-40's vocabulary — trim-aware,
// toString-first (a non-string value stringifies, never crashes), and
// single-eval (identical results to the double-eval ternary it replaces on
// plain maps, whose reads have no side effects).
void main() {
  test('falls back on absent, empty, or blank values', () {
    expect(messageOr(null, 'fallback'), 'fallback');
    expect(messageOr('', 'fallback'), 'fallback');
    expect(messageOr('   ', 'fallback'), 'fallback');
  });

  test('returns the trimmed value when content survives', () {
    expect(messageOr('  done  ', 'fallback'), 'done');
    expect(messageOr('done', 'fallback'), 'done');
  });

  test('stringifies non-string values before trimming', () {
    expect(messageOr(42, 'fallback'), '42');
    expect(messageOr(true, 'fallback'), 'true');
  });

  test('matches the double-eval ternary on plain map reads', () {
    final response = <String, dynamic>{
      'msg': '  Release inventory captured.  ',
    };
    // The :58 site read response['msg'] twice (probe, then value); the
    // single-eval owner must agree on plain maps.
    final ternary = response['msg']?.toString().trim().isNotEmpty == true
        ? response['msg'].toString().trim()
        : 'fallback';
    expect(messageOr(response['msg'], 'fallback'), ternary);
    expect(
      messageOr(response['msg'], 'fallback'),
      'Release inventory captured.',
    );
  });
}
