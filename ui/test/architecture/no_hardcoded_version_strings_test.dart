import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/e2e_checklist.dart';

/// Architecture invariant: the Services and Updates tabs must show pinned
/// versions from
/// the backend's `resolved_config` response, not a local Dart literal that
/// could drift from what the server actually resolved. This scans the raw
/// source rather than exercising the widgets, because the defect this
/// guards is a literal appearing in the file at all -- exactly the shape
/// already used for `platform_versions_test.py` on the backend side.
///
/// Measurement: the two presentation files are scanned for the five formerly
/// duplicated container and image literals.
void main() {
  test(
    'services and updates tabs contain no hardcoded platform-version literal',
    () {
      final root = findRepositoryRoot();
      final managementDir = Directory(
        '${root.path}/ui/lib/ui/server/management',
      );
      final targets = [
        File('${managementDir.path}/services_tab.dart'),
        File('${managementDir.path}/updates_tab.dart'),
      ];

      // The exact literals removed from services_tab.dart in T-1.4.5 --
      // the caddy_image pin and both managed container names it used to
      // send over the wire.
      const forbiddenLiterals = [
        'caddy:2.11.2-alpine',
        'internetsystemsconsortium/bind9:9.20',
        "'deploydash_caddy'",
        "'deploydash_bind9'",
        "'deploydash_postgres'",
      ];

      for (final file in targets) {
        expect(file.existsSync(), isTrue, reason: '${file.path} must exist');
        final source = file.readAsStringSync();
        for (final literal in forbiddenLiterals) {
          expect(
            source.contains(literal),
            isFalse,
            reason:
                '${file.path} must not hardcode $literal -- it should come '
                "from the backend's resolved_config response instead.",
          );
        }
      }
    },
  );
}
