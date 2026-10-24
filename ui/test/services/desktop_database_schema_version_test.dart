import 'package:ui/data/local/app_database.dart';
import 'package:ui/services/desktop_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('database schema version has one source of truth', () {
    test('the update service reports the database schema the app uses', () {
      // desktop_update_service.dart used to declare its own copy of this
      // number. The value is sent to the update service as `database_schema`
      // and compared against a release's minimum/maximum, so a drifted copy
      // does not fail loudly -- it makes the update service quietly stop
      // offering updates, which is close to the worst failure a mismatch
      // could have.
      //
      // This test outlives the unification. It exists so a future
      // re-duplication is caught immediately rather than at the point
      // someone notices updates have stopped arriving.
      expect(desktopDatabaseSchemaVersion, appDatabaseSchemaVersion);
    });

    test('the schema version is the collapsed value', () {
      // Stated as a literal on purpose. Asserting against the constant would
      // only prove the constant equals itself.
      expect(appDatabaseSchemaVersion, 2);
    });
  });
}
