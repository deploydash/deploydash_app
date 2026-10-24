import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ui/utils/first_present_value.dart';

import '../../integration_test/support/e2e_checklist.dart';

void main() {
  group('firstPresentValue', () {
    test('returns the first present value verbatim', () {
      expect(firstPresentValue(['  abc  ', 'def'], 'fallback'), '  abc  ');
      expect(firstPresentValue(['abc'], 'fallback'), 'abc');
    });

    test('skips null and blank values', () {
      expect(firstPresentValue([null, '   ', '', 'late'], 'fallback'), 'late');
      expect(firstPresentValue(['  ', null], 'fallback'), 'fallback');
    });

    test('returns the fallback when nothing is present', () {
      expect(firstPresentValue([], 'fallback'), 'fallback');
      expect(firstPresentValue([null], 'fallback'), 'fallback');
    });

    test('returns a blank fallback verbatim', () {
      // The fallback is not presence-checked: callers that pass
      // `something ?? default` keep blank-passthrough semantics.
      expect(firstPresentValue([], '   '), '   ');
    });
  });

  group('firstPresentValue routing (D-83)', () {
    test('read-model trim chains route through the shared owner', () {
      // Guard-style: the two family-1 trim chains call the shared owner.
      // Zero joins route (all eight are recorded pointers -- see commit).
      final root = findRepositoryRoot();
      final source = File(
        '${root.path}/ui/lib/providers/project_web_app_read_model_provider.dart',
      ).readAsStringSync();
      expect('firstPresentValue('.allMatches(source).length, 2);
    });
  });
}
