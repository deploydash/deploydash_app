import 'package:ui/utils/stringify_keys.dart';
import 'package:flutter_test/flutter_test.dart';

// Characterization for D-43 (T-013, commit 2): the entry-lambda stringify
// shape shared by three runtime sites. CORRECTION to the ticket's §5/§6
// premise (verified empirically 2026-10-05): `key.toString()` does NOT throw
// on a null key — Dart's Null.toString() yields 'null', exactly like '$key'.
// Both pre-routing spellings were already null-safe and identical on every
// input, so converging on the '$key' spelling changes no behavior on any
// edge (and null keys are unreachable anyway: the stringified maps are
// nested engine-JSON objects — result.dart diagnosticPayload +
// ssh_service.dart jsonDecode — whose keys are strings by construction).
void main() {
  test('stringifies keys and preserves values', () {
    expect(
      stringifyJsonKeys(<dynamic, dynamic>{'a': 1, 7: 'seven', true: null}),
      <String, dynamic>{'a': 1, '7': 'seven', 'true': null},
    );
  });

  test('both pre-routing spellings already agreed on null keys', () {
    // The divergence the ticket feared does not exist in Dart.
    dynamic nullKey;
    expect(nullKey.toString(), 'null');
    expect('$nullKey', 'null');
    expect(stringifyJsonKeys(<dynamic, dynamic>{null: 'x'}), <String, dynamic>{
      'null': 'x',
    });
  });
}
