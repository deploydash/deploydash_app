import 'package:ui/utils/payload_codecs.dart';
import 'package:flutter_test/flutter_test.dart';

// Characterization for D-58 (T-014, commit 1): the payload codec + overview
// unit-format truth tables. Written against the overview_tab_logic defs at
// base (same public names), then re-pointed at utils/payload_codecs.dart
// after the move with IDENTICAL bodies — green on both sides proves the move
// preserved every branch, byte, and const. The four format members folded
// into formatOverviewUnit keep their shipped bytes, pinned below.
void main() {
  test('mapFrom stringifies guarded keys and defaults non-maps', () {
    expect(mapFrom(<dynamic, dynamic>{'a': 1, 7: 'seven'}), <String, dynamic>{
      'a': 1,
      '7': 'seven',
    });
    expect(mapFrom(null), <String, dynamic>{});
    expect(mapFrom('nope'), <String, dynamic>{});
    expect(mapFrom(<dynamic>[1]), <String, dynamic>{});
    expect(identical(mapFrom(null), const <String, dynamic>{}), isTrue);
  });

  test('mapFrom yields null-string for null keys (no throw)', () {
    // CORRECTION (empirically verified in T-013): key.toString() does NOT
    // throw on null — Null.toString() is 'null'. Both spellings agree.
    expect(mapFrom(<dynamic, dynamic>{null: 'x'}), <String, dynamic>{
      'null': 'x',
    });
  });

  test('mapListFrom drops non-maps and freezes the list', () {
    expect(
      mapListFrom(<dynamic>[
        <dynamic, dynamic>{'a': 1},
        'dropped',
        <dynamic, dynamic>{2: 'two'},
      ]),
      <Map<String, dynamic>>[
        <String, dynamic>{'a': 1},
        <String, dynamic>{'2': 'two'},
      ],
    );
    expect(mapListFrom(null), <Map<String, dynamic>>[]);
    expect(mapListFrom(<String, dynamic>{}), <Map<String, dynamic>>[]);
    expect(
      identical(mapListFrom(null), const <Map<String, dynamic>>[]),
      isTrue,
    );
  });

  test('intFrom keeps fast-path, round, trim-parse, and null', () {
    expect(intFrom(3), 3);
    expect(identical(intFrom(3), 3), isTrue);
    expect(intFrom(3.5), 4);
    expect(intFrom(3.2), 3);
    expect(intFrom(' 12 '), 12);
    expect(intFrom('x'), isNull);
    expect(intFrom(null), isNull);
    expect(intFrom(true), isNull);
  });

  test('doubleFrom widens without rounding', () {
    expect(doubleFrom(3), 3.0);
    expect(doubleFrom(3.5), 3.5);
    expect(doubleFrom(' 2.5 '), 2.5);
    expect(doubleFrom('x'), isNull);
    expect(doubleFrom(null), isNull);
  });

  test('overview percent/gigabyte/kilobyte formats keep bytes', () {
    expect(formatOverviewUnit(12.34, '%'), '12.3%');
    expect(formatOverviewUnit(null, '%'), 'Unavailable');
    expect(formatOverviewUnit(7.89, ' GB'), '7.9 GB');
    expect(formatOverviewUnit(null, ' GB'), 'Unavailable');
    expect(formatOverviewUnit(1024.26, ' kB/s'), '1024.3 kB/s');
    expect(formatOverviewUnit(null, ' kB/s'), 'Unavailable');
  });

  test('overview Gb-from-Mb divides by 1024 before formatting', () {
    expect(formatOverviewUnit(2048, ' GB', divisor: 1024), '2.0 GB');
    expect(formatOverviewUnit(1536, ' GB', divisor: 1024), '1.5 GB');
    expect(formatOverviewUnit(null, ' GB', divisor: 1024), 'Unavailable');
  });
}
