import 'package:ui/utils/safe_token.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('safeToken', () {
    test('scrubs to lowercase identifier-safe text', () {
      expect(safeToken('  API Gateway!! '), 'api-gateway');
      expect(safeToken('Release_2.0'), 'release_2.0');
    });

    test('keeps dots underscores and dashes', () {
      expect(safeToken('a.b_c-d'), 'a.b_c-d');
    });

    test('falls back to item when nothing survives', () {
      expect(safeToken('!!!'), 'item');
      expect(safeToken('   '), 'item');
      expect(safeToken('---'), 'item');
    });

    test('does not truncate', () {
      const longId =
          'averylongdatabasename-that-exceeds-fortyeight-characters-easily';
      expect(longId.length, greaterThan(48));
      expect(safeToken(longId), longId);
    });
  });
}
