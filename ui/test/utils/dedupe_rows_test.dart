import 'package:ui/utils/dedupe_rows.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dedupeRowsByKey', () {
    test('last duplicate wins while keeping its first position', () {
      final rows = dedupeRowsByKey<String>(
        rows: const ['a=1', 'b=2', 'a=3'],
        keyOf: (row) => row.split('=').first,
        rebuild: (row, key) => '$key:${row.split('=').last}',
      );

      expect(rows, ['a:3', 'b:2']);
    });

    test('drops rows whose key is null', () {
      final rows = dedupeRowsByKey<String>(
        rows: const ['a=1', '=empty', 'b=2'],
        keyOf: (row) {
          final key = row.split('=').first;
          return key.isEmpty ? null : key;
        },
        rebuild: (row, key) => key,
      );

      expect(rows, ['a', 'b']);
    });

    test('drops rows the keep predicate refuses', () {
      final rows = dedupeRowsByKey<String>(
        rows: const ['a=1', 'b=', 'c=3'],
        keyOf: (row) => row.split('=').first,
        rebuild: (row, key) => key,
        keep: (row) => row.split('=').last.isNotEmpty,
      );

      expect(rows, ['a', 'c']);
    });

    test('rebuilds every kept row through the caller closure', () {
      var rebuilt = 0;
      final rows = dedupeRowsByKey<int>(
        rows: const [1, 2],
        keyOf: (row) => 'k$row',
        rebuild: (row, key) {
          rebuilt += 1;
          return row * 10;
        },
      );

      expect(rows, [10, 20]);
      expect(rebuilt, 2);
    });
  });
}
