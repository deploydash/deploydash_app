import 'package:flutter_test/flutter_test.dart';

import '_support/app_database_harness.dart';

/// database passphrase creation diagnostics.
///
/// One of six files T-3.6.2 split `app_database_test.dart` into, one per
/// group. Fixtures live in `_support/app_database_harness.dart`.
void main() {
  group('database passphrase creation diagnostics', () {
    test('redacts the entered passphrase and bounds technical details', () {
      const passphrase = 'correct horse battery staple';
      final redacted = debugSanitizeAppDatabasePassphraseCreationFailure(
        error: StateError('Could not use $passphrase'),
        passphrase: passphrase,
      );
      final bounded = debugSanitizeAppDatabasePassphraseCreationFailure(
        error: StateError('x' * 1200),
        passphrase: passphrase,
      );

      expect(redacted, contains('[redacted]'));
      expect(redacted, isNot(contains(passphrase)));
      expect(bounded, endsWith('...'));
      expect(bounded.length, 1003);
    });
  });
}
