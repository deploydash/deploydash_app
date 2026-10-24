import 'package:ui/utils/payload_codecs.dart';
import 'package:flutter_test/flutter_test.dart';

// D-45 pair 2 (T-021): the three routed stringify steps called this exact
// inline lambda on `decoded` after an `is Map` check. `mapFrom` replaces
// those calls, so it must agree with the lambda on every input class the
// arms can see — including a null key.
//
// Correction to the ticket's premise (verified by probe 2026-10-05): NEITHER
// side throws on a null key. Dart's `Null.toString()` yields the string
// `'null'`, so both produce `{'null': ...}`. The parity requirement holds
// (identical behavior); only the throw-belief was wrong.
Map<String, dynamic> _inlineStringify(Map<dynamic, dynamic> decoded) {
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}

void main() {
  test('mapFrom matches the routed stringify arms on every map shape', () {
    final cases = <Map<dynamic, dynamic>>[
      <dynamic, dynamic>{'a': 1, 'b': 'two'},
      <dynamic, dynamic>{7: 'seven', 'a': 1},
      <dynamic, dynamic>{null: 'x'},
      <dynamic, dynamic>{null: 'x', 7: 'seven', 'a': 1},
      <String, dynamic>{'typed': true},
      <dynamic, dynamic>{},
    ];
    for (final input in cases) {
      expect(mapFrom(input), _inlineStringify(input), reason: 'input $input');
    }
  });

  test(
    'mapFrom stringifies a null key to the string null without throwing',
    () {
      expect(mapFrom(<dynamic, dynamic>{null: 'x'}), {'null': 'x'});
    },
  );
}
